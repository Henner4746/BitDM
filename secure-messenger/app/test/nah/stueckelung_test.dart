// stueckelung_test.dart — was auf einer Funkstrecke wirklich passiert.
//
// Der leichte Teil ist "zerlegen und wieder zusammensetzen". Der schwere ist
// alles andere: Stuecke kommen doppelt, verspaetet, gar nicht, in falscher
// Reihenfolge oder von jemandem, der die App gar nicht hat. Ueber den Relay
// nimmt TCP einem das ab. Hier nicht.
//
// Und: WER IN REICHWEITE IST, KANN EINWERFEN. Es gibt keine Anmeldung wie
// beim Relay. Die Haelfte dieser Tests prueft deshalb nicht, dass etwas
// funktioniert, sondern dass etwas NICHT passiert — dass ein Fremder mit
// angefangenen Sendungen den Speicher nicht vollschreiben kann.

import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/nah/stueckelung.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List zufall(int n, [int saat = 1]) {
  final w = Random(saat);
  return Uint8List.fromList(List.generate(n, (_) => w.nextInt(256)));
}

/// Ein typischer Umschlag: 400 bis 700 Byte.
final umschlag = zufall(612);

void main() {
  group('Hin und zurueck', () {
    test('ein Umschlag ueberlebt die Reise', () {
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 7, nutzlastJeStueck: 176);

      Uint8List? fertig;
      for (final st in stuecke) {
        fertig ??= s.nimm(st);
      }
      expect(fertig, umschlag);
    });

    test('auch bei winziger Paketgroesse', () {
      // Ohne ausgehandelte MTU laesst BLE nur 20 Byte durch, davon gehen 9
      // fuer den Rahmen ab. 612 Byte werden so zu 56 Stuecken.
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 1, nutzlastJeStueck: 11);
      expect(stuecke.length, 56);
      expect(stuecke.every((x) => x.length <= 20), isTrue);

      Uint8List? fertig;
      for (final st in stuecke) {
        fertig ??= s.nimm(st);
      }
      expect(fertig, umschlag);
    });

    test('ein einziges Byte ist auch eine Sendung', () {
      final s = Sammler();
      final eins = Uint8List.fromList([0x42]);
      final st = zerlege(eins, sendungsnummer: 0, nutzlastJeStueck: 500);
      expect(st.length, 1);
      expect(s.nimm(st.single), eins);
    });

    test('EINE SENDUNG GILT ERST ALS FERTIG, WENN SIE ES IST', () {
      // Die wichtigste Zusage dieser Schicht. Kaeme sie frueher heraus,
      // bekaeme libsignal einen halben Umschlag und meldete einen
      // Krypto-Fehler — und danach suchte jemand an der falschen Stelle.
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 3, nutzlastJeStueck: 100);
      for (final st in stuecke.take(stuecke.length - 1)) {
        expect(s.nimm(st), isNull);
      }
      expect(s.nimm(stuecke.last), umschlag);
    });
  });

  group('Was der Funk anstellt', () {
    test('verkehrte Reihenfolge macht nichts', () {
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 9, nutzlastJeStueck: 90)
        ..shuffle(Random(5));
      Uint8List? fertig;
      for (final st in stuecke) {
        fertig ??= s.nimm(st);
      }
      expect(fertig, umschlag);
    });

    test('DOPPELTE STUECKE VERAENDERN NICHTS', () {
      // Eine Wiederholung nach einem Aussetzer ist der Normalfall. Wuerde
      // sie mitgezaehlt, gaelte die Sendung als fertig, bevor sie es ist —
      // und zusammengesetzt kaeme Unsinn heraus.
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 2, nutzlastJeStueck: 120);
      Uint8List? fertig;
      for (final st in stuecke) {
        fertig ??= s.nimm(st);
        if (fertig == null) expect(s.nimm(st), isNull, reason: 'dasselbe nochmal');
      }
      expect(fertig, umschlag);
    });

    test('ein verlorenes Stueck laesst die Sendung offen', () {
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 4, nutzlastJeStueck: 100);
      for (var i = 0; i < stuecke.length; i++) {
        if (i == 2) continue;
        expect(s.nimm(stuecke[i]), isNull);
      }
      expect(s.offeneSendungen, 1);
      // Und geht weiter, sobald es nachkommt.
      expect(s.nimm(stuecke[2]), umschlag);
      expect(s.offeneSendungen, 0);
    });

    test('EIN GEKIPPTES BIT wird bemerkt', () {
      final s = Sammler();
      final stuecke = zerlege(umschlag, sendungsnummer: 6, nutzlastJeStueck: 200);
      for (final st in stuecke.take(stuecke.length - 1)) {
        s.nimm(st);
      }
      final letztes = Uint8List.fromList(stuecke.last);
      letztes[Rahmen.laenge] ^= 0x01;
      expect(() => s.nimm(letztes), throwsA(isA<StueckKaputt>()));
    });

    test('zwei Sendungen gleichzeitig kommen sich nicht ins Gehege', () {
      final s = Sammler();
      final a = zufall(300, 2), b = zufall(450, 3);
      final sa = zerlege(a, sendungsnummer: 11, nutzlastJeStueck: 100);
      final sb = zerlege(b, sendungsnummer: 12, nutzlastJeStueck: 100);

      Uint8List? fa, fb;
      for (var i = 0; i < max(sa.length, sb.length); i++) {
        if (i < sa.length) fa ??= s.nimm(sa[i]);
        if (i < sb.length) fb ??= s.nimm(sb[i]);
      }
      expect(fa, a);
      expect(fb, b);
    });

    test('dieselbe Nummer mit anderem Inhalt beginnt neu', () {
      // Kommt nach einem Neustart der Gegenstelle vor. Die alten Stuecke
      // stehenzulassen hiesse, die neue Sendung nie vollstaendig zu bekommen.
      final s = Sammler();
      final alt = zufall(300, 8), neu = zufall(300, 9);
      final sa = zerlege(alt, sendungsnummer: 5, nutzlastJeStueck: 100);
      final sn = zerlege(neu, sendungsnummer: 5, nutzlastJeStueck: 100);

      s.nimm(sa[0]);
      s.nimm(sa[1]);
      Uint8List? fertig;
      for (final st in sn) {
        fertig ??= s.nimm(st);
      }
      expect(fertig, neu);
    });
  });

  group('Was ein Fremder nicht darf', () {
    test('den Speicher vollschreiben — Zahl der Sendungen', () {
      final s = Sammler(hoechstZahlOffen: 3);
      for (var n = 0; n < 20; n++) {
        s.nimm(zerlege(zufall(500, n), sendungsnummer: n, nutzlastJeStueck: 50)[0]);
      }
      expect(s.offeneSendungen, lessThanOrEqualTo(3));
    });

    test('den Speicher vollschreiben — Menge der Bytes', () {
      // NUR DAS ERSTE STUECK je Sendung. Genau so sieht der Angriff aus: viele
      // angefangene Sendungen, keine davon je fertig. Wer sie fertig machte,
      // gaebe den Speicher ja selbst wieder frei — mein erster Versuch hat
      // deshalb gar nichts geprueft.
      final s = Sammler(hoechstZahlOffen: 100, hoechstBytesOffen: 4000);
      var abgelehnt = false;
      for (var n = 0; n < 50 && !abgelehnt; n++) {
        try {
          s.nimm(zerlege(zufall(2000, n),
              sendungsnummer: n, nutzlastJeStueck: 500)[0]);
        } on SendungZuGross {
          abgelehnt = true;
        }
      }
      expect(abgelehnt, isTrue, reason: 'irgendwann muss Schluss sein');
      expect(s.offeneBytes, lessThanOrEqualTo(4000));
    });

    test('DIESELBE WIEDERHOLUNG ZAEHLT NICHT GEGEN DIE SPEICHERGRENZE', () {
      // Aufgefallen bei einem Mutationstest: die Sperre gegen doppelte
      // Stuecke ist fuers ZAEHLEN ueberfluessig — die Teile liegen nach
      // Nummer sortiert, ein zweites Mal dieselbe Nummer waechst also nicht.
      //
      // Sie traegt aber hier: die Schranke rechnet "schon belegt + das neue
      // Stueck". Bei einer Wiederholung ist das neue Stueck gar nicht neu, es
      // ersetzt ein schon gezaehltes. Ohne die Sperre wird es trotzdem
      // dazugerechnet, die Summe schiesst ueber die Grenze, und die GANZE
      // Sendung fliegt raus — ausgerechnet auf einer schlechten Funkstrecke,
      // auf der wiederholt werden MUSS.
      //
      // DIE SCHRANKE MUSS KNAPP SEIN, sonst sagt der Test nichts: bei viel
      // Luft ueberschiesst die Doppelzaehlung nicht. Sie muss aber auch
      // reichen — 612 Byte in Stuecken zu 300 belegen am Ende 612. Ein erster
      // Anlauf mit 500 war so eng, dass schon der echte Ablauf scheiterte.
      final s = Sammler(hoechstBytesOffen: 620);
      final stuecke = zerlege(umschlag, sendungsnummer: 1, nutzlastJeStueck: 300);
      expect(stuecke.length, 3);

      expect(s.nimm(stuecke[0]), isNull);
      expect(s.nimm(stuecke[1]), isNull);
      expect(s.offeneBytes, 600);

      // Jetzt zwanzigmal dasselbe noch einmal — so sieht eine Strecke mit
      // Aussetzern aus.
      for (var i = 0; i < 20; i++) {
        expect(s.nimm(stuecke[0]), isNull, reason: 'Wiederholung $i');
      }
      expect(s.offeneBytes, 600, reason: 'Wiederholungen belegen nichts');

      expect(s.nimm(stuecke[2]), umschlag,
          reason: 'die Sendung muss trotz zwanzig Wiederholungen durchkommen');
    });

    test('EINE ANGEFANGENE SENDUNG LIEGEN LASSEN', () {
      // Wer aus der Reichweite laeuft, hinterlaesst eine halbe Sendung. Ohne
      // Frist blieben die fuer immer im Speicher.
      var jetzt = DateTime.utc(2026, 7, 26, 12);
      final s = Sammler(haltbarkeit: const Duration(seconds: 30), uhr: () => jetzt);

      s.nimm(zerlege(umschlag, sendungsnummer: 1, nutzlastJeStueck: 100)[0]);
      expect(s.offeneSendungen, 1);

      jetzt = jetzt.add(const Duration(seconds: 31));
      // Der naechste Wurf raeumt ab — auch der einer ganz anderen Sendung.
      // MEHRTEILIG, sonst waere die neue Sendung sofort fertig und wieder weg,
      // und der Test saehe eine Null, ohne dass er etwas ueber das Abraeumen
      // gesagt haette.
      s.nimm(zerlege(zufall(500, 4), sendungsnummer: 2, nutzlastJeStueck: 100)[0]);
      expect(s.offeneSendungen, 1, reason: 'die alte ist weg, die neue steht');
    });

    test('eine noch laufende Sendung wird NICHT weggeraeumt', () {
      // Die Gegenprobe. Eine Frist, die zu frueh greift, macht grosse
      // Sendungen unmoeglich — und zwar sporadisch, was am schwersten zu
      // finden ist.
      var jetzt = DateTime.utc(2026, 7, 26, 12);
      final s = Sammler(haltbarkeit: const Duration(seconds: 30), uhr: () => jetzt);
      final stuecke = zerlege(umschlag, sendungsnummer: 1, nutzlastJeStueck: 100);
      for (final st in stuecke.take(stuecke.length - 1)) {
        s.nimm(st);
        jetzt = jetzt.add(const Duration(seconds: 4));
      }
      expect(s.nimm(stuecke.last), umschlag);
    });

    test('Unsinn im Rahmen fliegt raus, ohne alles mitzureissen', () {
      final s = Sammler();
      final gut = zerlege(umschlag, sendungsnummer: 1, nutzlastJeStueck: 200);
      s.nimm(gut[0]);

      final faelle = <String, Uint8List>{
        'zu kurz': Uint8List(4),
        'falsche Fassung': (Uint8List.fromList(gut[1])..[0] = 99),
        'ohne Nutzlast': Uint8List(Rahmen.laenge)..[0] = Rahmen.fassung,
      };
      for (final e in faelle.entries) {
        expect(() => s.nimm(e.value), throwsA(isA<StueckKaputt>()),
            reason: e.key);
      }

      // Und die begonnene Sendung laeuft trotzdem weiter.
      Uint8List? fertig;
      for (final st in gut.skip(1)) {
        fertig ??= s.nimm(st);
      }
      expect(fertig, umschlag);
    });

    test('Stueck 5 von 3 gibt es nicht', () {
      final s = Sammler();
      final roh = Uint8List(Rahmen.laenge + 1);
      final b = ByteData.sublistView(roh);
      roh[0] = Rahmen.fassung;
      b.setUint16(1, 1);
      b.setUint16(3, 5);
      b.setUint16(5, 3);
      expect(() => s.nimm(roh), throwsA(isA<StueckKaputt>()));
    });

    test('eine Stueckzahl jenseits der Grenze wird abgelehnt', () {
      final s = Sammler();
      final roh = Uint8List(Rahmen.laenge + 1);
      final b = ByteData.sublistView(roh);
      roh[0] = Rahmen.fassung;
      b.setUint16(3, 0);
      b.setUint16(5, 60000);
      expect(() => s.nimm(roh), throwsA(isA<StueckKaputt>()));
    });
  });

  group('Was gar nicht erst losgeschickt wird', () {
    test('eine leere Sendung', () {
      expect(() => zerlege(Uint8List(0), sendungsnummer: 1, nutzlastJeStueck: 100),
          throwsA(isA<StueckKaputt>()));
    });

    test('etwas Groesseres als die Obergrenze', () {
      expect(
          () => zerlege(Uint8List(Rahmen.hoechstgroesse + 1),
              sendungsnummer: 1, nutzlastJeStueck: 500),
          throwsA(isA<SendungZuGross>()));
    });

    test('zu viele Stuecke', () {
      expect(
          () => zerlege(Uint8List(50000), sendungsnummer: 1, nutzlastJeStueck: 1),
          throwsA(isA<SendungZuGross>()));
    });
  });

  group('Die Pruefsumme', () {
    test('unterscheidet, was sich unterscheidet', () {
      expect(crc16(Uint8List.fromList([1, 2, 3])),
          isNot(crc16(Uint8List.fromList([1, 2, 4]))));
      // Auch bei vertauschter Reihenfolge — ein blosses Aufaddieren nicht.
      expect(crc16(Uint8List.fromList([1, 2])),
          isNot(crc16(Uint8List.fromList([2, 1]))));
    });

    test('bleibt in zwei Byte', () {
      for (var n = 0; n < 200; n += 17) {
        final c = crc16(zufall(n + 1, n));
        expect(c, inInclusiveRange(0, 0xFFFF));
      }
    });
  });
}
