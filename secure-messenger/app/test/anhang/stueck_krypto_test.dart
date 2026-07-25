// stueck_krypto_test.dart — ein Stueck ver- und entschluesseln.
//
// Diese Tests pruefen EIGENSCHAFTEN, keine Bibliothek. Wenn die Umsetzung
// eines Tages gegen eine schnellere getauscht wird (siehe den Kommentar in
// stueck_krypto.dart), gelten sie unveraendert weiter — und genau dann sind
// sie am meisten wert.

import 'dart:typed_data';

import 'package:bitdm/core/anhang/stueck_krypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List zaehlend(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 7 + 3) % 251));

void main() {
  const krypto = GcmStueckKrypto();
  final schluessel = zaehlend(32);
  final nonce = zaehlend(12);

  Future<Uint8List> zu(Uint8List klar,
          {int nummer = 0, int von = 4, Uint8List? s, Uint8List? n}) =>
      krypto.verschluessle(
          klar: klar,
          schluessel: s ?? schluessel,
          nonce: n ?? nonce,
          nummer: nummer,
          vonWievielen: von);

  Future<Uint8List> auf(Uint8List geheim,
          {int nummer = 0, int von = 4, Uint8List? s, Uint8List? n}) =>
      krypto.entschluessle(
          geheim: geheim,
          schluessel: s ?? schluessel,
          nonce: n ?? nonce,
          nummer: nummer,
          vonWievielen: von);

  group('Der Normalfall', () {
    test('hin und zurueck ergibt dieselben Bytes', () async {
      final klar = zaehlend(100000);
      expect(await auf(await zu(klar)), klar);
    });

    test('auch ein leeres Stueck', () async {
      final leer = Uint8List(0);
      expect(await auf(await zu(leer)), leer);
    });

    test('der Beglaubigungsanhang kostet genau 16 Byte', () async {
      // Die Zahl steht auch in rezept.dart (lagerGroesse). Weichen die beiden
      // voneinander ab, wird die Marke fuer die falsche Groesse geholt — und
      // das Lager lehnt nach der Uebertragung ab.
      for (final n in [0, 1, 15, 16, 17, 4096]) {
        expect((await zu(zaehlend(n))).length, n + 16, reason: 'bei $n Byte');
      }
    });

    test('der Chiffretext sieht nicht aus wie der Klartext', () async {
      final klar = Uint8List(4096); // lauter Nullen
      final geheim = await zu(klar);
      expect(geheim.sublist(0, 4096), isNot(klar));
    });
  });

  group('Was auffliegen muss', () {
    test('ein falscher Schluessel', () async {
      final geheim = await zu(zaehlend(1000));
      final anderer = Uint8List.fromList(schluessel)..[0] ^= 1;
      expect(auf(geheim, s: anderer), throwsA(isA<StueckKaputt>()));
    });

    test('ein falscher Nonce', () async {
      final geheim = await zu(zaehlend(1000));
      final anderer = Uint8List.fromList(nonce)..[11] ^= 1;
      expect(auf(geheim, n: anderer), throwsA(isA<StueckKaputt>()));
    });

    test('ein veraendertes Byte im Chiffretext', () async {
      final geheim = await zu(zaehlend(1000));
      geheim[500] ^= 1;
      expect(auf(geheim), throwsA(isA<StueckKaputt>()));
    });

    test('ein veraenderter Beglaubigungsanhang', () async {
      final geheim = await zu(zaehlend(1000));
      geheim[geheim.length - 1] ^= 1;
      expect(auf(geheim), throwsA(isA<StueckKaputt>()));
    });

    test('ein abgeschnittenes Stueck', () async {
      final geheim = await zu(zaehlend(1000));
      expect(auf(Uint8List.sublistView(geheim, 0, 500)),
          throwsA(isA<StueckKaputt>()));
    });

    test('etwas, das zu kurz fuer einen Anhang ist', () async {
      // Was hier geprueft wird, ist das VERHALTEN: kein Absturz, keine
      // RangeError nach oben, sondern derselbe Fehler wie sonst. Die
      // ausdrueckliche Laengenpruefung in stueck_krypto.dart laesst sich
      // damit NICHT nachweisen — ohne sie kaeme dasselbe heraus, nur ueber
      // den Umweg einer fremden Bereichspruefung. Das steht dort so im
      // Kommentar, damit niemand sie fuer ueberfluessig haelt.
      for (final n in [0, 1, 15]) {
        expect(auf(Uint8List(n)), throwsA(isA<StueckKaputt>()),
            reason: 'bei $n Byte');
      }
    });
  });

  group('DIE NUMMER STECKT IN DER BEGLAUBIGUNG', () {
    // Der Grund fuer diese ganze Gruppe: das Lager kann nicht faelschen, aber
    // es kann VERTAUSCHEN — unter der Kennung von Stueck 3 die Bytes von
    // Stueck 5 ausliefern. Ohne die Nummer im beglaubigten Zusatz wuerde das
    // sauber entschluesseln und still die falsche Datei ergeben.

    test('ein Stueck an der falschen Stelle geht NICHT auf', () async {
      final geheim = await zu(zaehlend(1000), nummer: 3, von: 8);
      expect(auf(geheim, nummer: 5, von: 8), throwsA(isA<StueckKaputt>()));
    });

    test('an der richtigen Stelle schon', () async {
      final klar = zaehlend(1000);
      final geheim = await zu(klar, nummer: 3, von: 8);
      expect(await auf(geheim, nummer: 3, von: 8), klar);
    });

    test('auch die GESAMTZAHL zaehlt mit', () async {
      // Sonst liesse sich eine Anleitung kuerzen: dieselben Stuecke, aber nur
      // die ersten drei aufgefuehrt. Die Datei waere abgeschnitten, jedes
      // Stueck fuer sich sauber.
      final geheim = await zu(zaehlend(1000), nummer: 2, von: 8);
      expect(auf(geheim, nummer: 2, von: 3), throwsA(isA<StueckKaputt>()));
    });

    test('Stueck 1 von 12 ist nicht Stueck 11 von 2', () async {
      // Der Zusatz wird als Text gebaut. Waeren die Zahlen einfach
      // aneinandergehaengt, waeren "1|12" und "11|2" derselbe Zusatz.
      final geheim = await zu(zaehlend(64), nummer: 1, von: 12);
      expect(auf(geheim, nummer: 11, von: 2), throwsA(isA<StueckKaputt>()));
    });

    test('der Zusatz ist fuer jede Stelle ein anderer', () {
      final gesehen = <String>{};
      for (var von = 1; von <= 20; von++) {
        for (var nr = 0; nr < von; nr++) {
          final z = String.fromCharCodes(StueckKrypto.zusatz(nr, von));
          expect(gesehen.add(z), isTrue, reason: 'doppelt bei $nr/$von');
        }
      }
    });
  });

  group('Der Fehler verraet nichts', () {
    test('alle Arten zu scheitern sehen gleich aus', () async {
      // Wer unterscheiden kann, ob der Schluessel falsch war oder die
      // Beglaubigung, kann raten. Es gibt deshalb genau einen Fehler.
      final geheim = await zu(zaehlend(1000));
      final versuche = <Future<void>>[
        auf(geheim, s: Uint8List(32)),
        auf(geheim, n: Uint8List(12)),
        auf(geheim, nummer: 9),
        auf(Uint8List.sublistView(geheim, 0, 20)),
      ];
      for (final v in versuche) {
        await expectLater(v, throwsA(isA<StueckKaputt>()));
      }
    });

    test('und traegt keine Bytes im Text', () async {
      final geheim = await zu(zaehlend(1000));
      try {
        await auf(geheim, s: Uint8List(32));
        fail('haette werfen muessen');
      } on StueckKaputt catch (e) {
        expect(e.toString(), isNot(contains('[')));
        expect(e.toString().length, lessThan(80));
      }
    });
  });
}
