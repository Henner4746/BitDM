// rezept_test.dart — die Anleitung, aus der ein Anhang zusammenwaechst.
//
// DIE ANLEITUNG KOMMT VON DER GEGENSTELLE. Sie ist echt in dem Sinne, dass
// die Signal-Sitzung sie beglaubigt hat — aber die Gegenstelle selbst kann
// fehlerhaft oder boesartig sein. Alles, was hier geprueft wird, ist deshalb
// eine Pruefung gegen den GESPRAECHSPARTNER, nicht gegen den Server.
//
// Die Faelle, die wirklich zaehlen, tragen ihren Grund im Namen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/rezept.dart';
import 'package:flutter_test/flutter_test.dart';

Stueck stueck(String kennung, int groesse) => Stueck(
      kennung: kennung,
      schluessel: Uint8List(32),
      nonce: Uint8List(12),
      klarGroesse: groesse,
    );

String k(String buchstabe) => buchstabe * 52;

/// Eine GUELTIGE Kennung je Nummer.
///
/// Der naheliegende Weg — `i.toString().padLeft(52, 'a')` — sieht richtig aus
/// und ist es nicht: Base32 kennt hier nur [a-z2-7], also weder 0, 1, 8 noch
/// 9. Eine so gebaute Kennung faellt schon am Muster durch, und ein Test, der
/// eigentlich die STUECKZAHL pruefen soll, besteht dann aus dem falschen
/// Grund. Genau das war er bis zur Mutationsprobe am 25.07.2026.
String kennungNr(int i) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final b = StringBuffer();
  var n = i;
  for (var j = 0; j < 52; j++) {
    b.write(alphabet[n % 32]);
    n ~/= 32;
  }
  return b.toString();
}

Rezept beispiel({List<Stueck>? stuecke, int? gesamt}) {
  final st = stuecke ?? [stueck(k('a'), 100), stueck(k('b'), 50)];
  return Rezept(
    name: 'urlaub.zip',
    gesamtGroesse: gesamt ?? st.fold(0, (a, s) => a + s.klarGroesse),
    pruefsumme: Uint8List(32),
    stuecke: st,
  );
}

/// Aendert ein Feld in der fertigen Anleitung — so, wie es eine boesartige
/// Gegenstelle taete.
String mitAenderung(Rezept r, void Function(Map<String, Object?>) was) {
  final j = (jsonDecode(r.alsText()) as Map).cast<String, Object?>();
  was(j);
  return jsonEncode(j);
}

void main() {
  group('Hin und zurueck', () {
    test('eine Anleitung uebersteht die Reise unveraendert', () {
      final vorher = beispiel();
      final nachher = Rezept.ausText(vorher.alsText());

      expect(nachher.name, vorher.name);
      expect(nachher.gesamtGroesse, vorher.gesamtGroesse);
      expect(nachher.pruefsumme, vorher.pruefsumme);
      expect(nachher.stuecke, hasLength(2));
      expect(nachher.stuecke[0].kennung, k('a'));
      expect(nachher.stuecke[1].klarGroesse, 50);
    });

    test('Einmal-Ansicht: das Kennzeichen reist mit, ohne es bleibt alles beim Alten', () {
      final gewoehnlich = beispiel();
      expect(gewoehnlich.alsText().contains('"e"'), isFalse,
          reason: 'eine gewoehnliche Anleitung soll byte-gleich wie bisher aussehen');
      expect(Rezept.ausText(gewoehnlich.alsText()).einmal, isFalse);
      final einmal = gewoehnlich.alsEinmal();
      expect(Rezept.ausText(einmal.alsText()).einmal, isTrue);
      expect(Rezept.ausText(einmal.alsText()).stuecke, hasLength(2));
    });

    test('die Lagergroesse zaehlt die Beglaubigungsanhaenge mit', () {
      // Das ist die Zahl, fuer die Marken gebraucht werden. Wer hier die
      // Klargroesse nimmt, bekommt beim letzten Stueck ein 413 vom Lager —
      // nach dem Hochladen, nicht davor.
      final r = beispiel();
      expect(r.gesamtGroesse, 150);
      expect(r.lagerGroesse, 150 + 2 * 16);
    });
  });

  group('Was eine boesartige Gegenstelle schicken koennte', () {
    test('DIE STUECKE MUESSEN DIE DATEI ERGEBEN', () {
      // Ohne diese Pruefung kuendigt eine Anleitung 3 GB an und fuehrt drei
      // Stuecke zu je 1 KB auf. Die Oberflaeche zeigt "3 GB", der Fortschritt
      // bleibt stehen, und niemand weiss warum.
      final text = mitAenderung(beispiel(), (j) => j['g'] = 999999);
      expect(() => Rezept.ausText(text),
          throwsA(isA<RezeptFormatException>()));
    });

    test('doppelte Kennung', () {
      // Zwei Stuecke, die dieselben Bytes holen. Faellt sonst erst ganz am
      // Ende ueber die Pruefsumme auf.
      expect(
          () => Rezept.ausText(
              beispiel(stuecke: [stueck(k('a'), 100), stueck(k('a'), 50)])
                  .alsText()),
          throwsA(isA<RezeptFormatException>()));
    });

    test('gar keine Stuecke', () {
      final text = mitAenderung(beispiel(), (j) => j['st'] = []);
      expect(() => Rezept.ausText(text),
          throwsA(isA<RezeptFormatException>()));
    });

    test('ABSURD VIELE STUECKE', () {
      // Eine kurze Nachricht darf keine sehr lange Arbeit ausloesen.
      //
      // Die Kennungen sind hier bewusst GUELTIG. Waeren sie es nicht, fiele
      // die Anleitung schon am Muster durch und der Test bestuende, ohne die
      // Stueckzahl je zu beruehren.
      final viele = List.generate(
          Rezept.hoechstStueckzahl + 1, (i) => stueck(kennungNr(i), 1));
      final r = Rezept(
          name: 'x',
          gesamtGroesse: viele.length,
          pruefsumme: Uint8List(32),
          stuecke: viele);

      // Erst nachweisen, dass ohne die Zahl alles in Ordnung waere: eines
      // weniger muss durchgehen. Sonst koennte der Test aus irgendeinem
      // anderen Grund bestehen.
      final knappDrunter = Rezept(
          name: 'x',
          gesamtGroesse: Rezept.hoechstStueckzahl,
          pruefsumme: Uint8List(32),
          stuecke: viele.take(Rezept.hoechstStueckzahl).toList());
      expect(Rezept.ausText(knappDrunter.alsText()).stuecke,
          hasLength(Rezept.hoechstStueckzahl));

      expect(() => Rezept.ausText(r.alsText()),
          throwsA(isA<RezeptFormatException>()));
    });

    test('eine Kennung, die keine ist', () {
      for (final schlecht in [
        'zu-kurz',
        'A' * 52, // Grossbuchstaben gibt es in Base32 hier nicht
        '${'a' * 51}1', // 1 und 8 kommen in Base32 nicht vor
        '../../etc/passwd',
        '${'a' * 51}/',
      ]) {
        final text = mitAenderung(beispiel(), (j) {
          (j['st']! as List)[0] = {
            'k': schlecht,
            's': base64.encode(Uint8List(32)),
            'n': base64.encode(Uint8List(12)),
            'g': 100,
          };
        });
        expect(() => Rezept.ausText(text),
            throwsA(isA<RezeptFormatException>()),
            reason: 'bei "$schlecht"');
      }
    });

    test('ein Schluessel mit falscher Laenge', () {
      // Ein 1-Byte-Schluessel wuerde sonst irgendwo weit unten scheitern —
      // hier scheitert er dort, wo man beim Lesen nachsieht.
      for (final laenge in [0, 16, 31, 33, 64]) {
        final text = mitAenderung(beispiel(), (j) {
          ((j['st']! as List)[0] as Map)['s'] =
              base64.encode(Uint8List(laenge));
        });
        expect(() => Rezept.ausText(text),
            throwsA(isA<RezeptFormatException>()),
            reason: 'bei $laenge Byte');
      }
    });

    test('ein Nonce mit falscher Laenge', () {
      for (final laenge in [0, 11, 13, 16]) {
        final text = mitAenderung(beispiel(), (j) {
          ((j['st']! as List)[0] as Map)['n'] =
              base64.encode(Uint8List(laenge));
        });
        expect(() => Rezept.ausText(text),
            throwsA(isA<RezeptFormatException>()),
            reason: 'bei $laenge Byte');
      }
    });

    test('eine Pruefsumme mit falscher Laenge', () {
      final text = mitAenderung(
          beispiel(), (j) => j['p'] = base64.encode(Uint8List(16)));
      expect(() => Rezept.ausText(text),
          throwsA(isA<RezeptFormatException>()));
    });

    test('ein Name, der kein Name ist', () {
      for (final schlecht in ['', 'x' * 256]) {
        final text = mitAenderung(beispiel(), (j) => j['n'] = schlecht);
        expect(() => Rezept.ausText(text),
            throwsA(isA<RezeptFormatException>()),
            reason: 'bei ${schlecht.length} Zeichen');
      }
    });

    test('eine Stueckgroesse von null oder negativ', () {
      for (final g in [0, -1]) {
        final text = mitAenderung(beispiel(), (j) {
          ((j['st']! as List)[0] as Map)['g'] = g;
        });
        expect(() => Rezept.ausText(text),
            throwsA(isA<RezeptFormatException>()), reason: 'bei $g');
      }
    });

    test('eine kuenftige Fassung wird abgelehnt, nicht geraten', () {
      final text = mitAenderung(beispiel(), (j) => j['v'] = 2);
      expect(() => Rezept.ausText(text),
          throwsA(isA<RezeptFormatException>()));
    });

    test('gar kein JSON', () {
      for (final muell in ['', 'nicht mal JSON', '[1,2,3]', '{']) {
        expect(() => Rezept.ausText(muell),
            throwsA(isA<RezeptFormatException>()), reason: 'bei "$muell"');
      }
    });
  });

  group('Passt die Anleitung in einen Umschlag?', () {
    test('das groesste erlaubte Rezept bleibt unter 64 KiB', () {
      // Der Relay laesst 64 KiB Chiffretext durch. Waere die Anleitung
      // groesser, liesse sich der Anhang zwar hochladen, aber nicht ankuendigen
      // — und das faellt erst nach der ganzen Uebertragung auf.
      final viele = List.generate(
          Rezept.hoechstStueckzahl,
          (i) => Stueck(
                kennung: kennungNr(i),
                schluessel: Uint8List(32),
                nonce: Uint8List(12),
                klarGroesse: 16 * 1024 * 1024,
              ));
      final r = Rezept(
        name: 'x' * 255,
        gesamtGroesse: viele.fold(0, (a, s) => a + s.klarGroesse),
        pruefsumme: Uint8List(32),
        stuecke: viele,
      );

      final laenge = utf8.encode(r.alsText()).length;
      expect(laenge, lessThan(48 * 1024),
          reason: 'gemessen: $laenge Byte — es muss Luft bleiben fuer '
              'Auffuellung und den Aufschlag der Verschluesselung');
    });

    test('und 256 Stuecke reichen fuer die groesste erlaubte Datei', () {
      // Das Lager nimmt 3 GiB. Bei 16-MiB-Stuecken sind das 192 — sonst
      // muesste die Stueckgroesse mitwachsen, und das waere eine Rechnung,
      // die irgendwo stimmen muss.
      const groesstDatei = 3 * 1024 * 1024 * 1024;
      const stueckGroesse = 16 * 1024 * 1024;
      expect((groesstDatei / stueckGroesse).ceil(),
          lessThanOrEqualTo(Rezept.hoechstStueckzahl));
    });
  });
}
