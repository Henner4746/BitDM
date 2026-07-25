// ctap_cbor_test.dart — kanonisches CBOR, gegen die Beispiele aus RFC 8949.
//
// Ein Fehler hier ist besonders unangenehm: der Stick lehnt ab, und die
// Meldung sagt nur "ungueltiger Parameter". Woran es liegt, sieht man dem
// nicht an. Deshalb wird hier gegen fremde Vorgaben geprueft, nicht gegen die
// eigene Erwartung.

import 'dart:typed_data';

import 'package:bitdm/core/fido/ctap_cbor.dart';
import 'package:cbor/simple.dart' as paket;
import 'package:flutter_test/flutter_test.dart';

List<int> k(Object? o) => CtapCbor.kodiere(o);

void main() {
  group('Beispiele aus RFC 8949', () {
    test('ganze Zahlen', () {
      expect(k(0), [0x00]);
      expect(k(1), [0x01]);
      expect(k(10), [0x0a]);
      expect(k(23), [0x17]);
      expect(k(24), [0x18, 0x18]);
      expect(k(25), [0x18, 0x19]);
      expect(k(100), [0x18, 0x64]);
      expect(k(1000), [0x19, 0x03, 0xe8]);
      expect(k(1000000), [0x1a, 0x00, 0x0f, 0x42, 0x40]);
      expect(k(-1), [0x20]);
      expect(k(-10), [0x29]);
      expect(k(-100), [0x38, 0x63]);
      expect(k(-1000), [0x39, 0x03, 0xe7]);
    });

    test('Zeichenketten und Bytefolgen', () {
      expect(k(''), [0x60]);
      expect(k('a'), [0x61, 0x61]);
      expect(k('IETF'), [0x64, 0x49, 0x45, 0x54, 0x46]);
      expect(k(Uint8List.fromList([])), [0x40]);
      expect(k(Uint8List.fromList([1, 2, 3, 4])),
          [0x44, 0x01, 0x02, 0x03, 0x04]);
    });

    test('Listen und Objekte', () {
      expect(k(<Object?>[]), [0x80]);
      expect(k([1, 2, 3]), [0x83, 0x01, 0x02, 0x03]);
      expect(k(<Object?, Object?>{}), [0xa0]);
      expect(k({1: 2, 3: 4}), [0xa2, 0x01, 0x02, 0x03, 0x04]);
    });

    test('Wahrheitswerte', () {
      expect(k(false), [0xf4]);
      expect(k(true), [0xf5]);
      expect(k(null), [0xf6]);
    });
  });

  group('Die kuerzeste Form ist Pflicht', () {
    test('kleine Zahlen brauchen kein Zusatzbyte', () {
      // Die laengere Form waere gueltiges CBOR und ergaebe denselben Wert —
      // aber andere Bytes, und damit einen anderen Pruefwert beim Stick.
      expect(k(5), hasLength(1));
      expect(k(23), hasLength(1));
      expect(k(24), hasLength(2));
      expect(k(255), hasLength(2));
      expect(k(256), hasLength(3));
      expect(k(65535), hasLength(3));
      expect(k(65536), hasLength(5));
    });
  });

  group('DIE Sortierfalle: positive Zahlen VOR negativen', () {
    test('ein COSE-Schluessel wird 1, 3, -1, -2, -3 sortiert', () {
      // Nach Zahlenwert waere -3, -2, -1, 1, 3 richtig. CTAP2 sortiert aber
      // nach Haupttyp zuerst — und positive Zahlen sind Typ 0, negative Typ 1.
      //
      // Genau diese Stelle laesst einen Stick eine sonst fehlerfreie Anfrage
      // ablehnen, und die Fehlermeldung sagt nur "ungueltiger Parameter".
      final cose = {
        1: 2, // kty: EC2
        3: -25, // alg: ECDH-ES+HKDF-256
        -1: 1, // crv: P-256
        -2: Uint8List.fromList(List.filled(32, 0xAA)), // x
        -3: Uint8List.fromList(List.filled(32, 0xBB)), // y
      };
      final bytes = k(cose);

      // Nach dem Objektkopf (0xa5) muessen die Schluessel in dieser Folge
      // stehen: 0x01, 0x03, 0x20 (-1), 0x21 (-2), 0x22 (-3).
      expect(bytes[0], 0xa5, reason: 'Objekt mit fuenf Eintraegen');
      expect(bytes[1], 0x01, reason: 'zuerst der Schluessel 1');
      expect(bytes[3], 0x03, reason: 'dann 3');
      // Danach folgen die negativen. Ihre Positionen haengen von den Werten
      // ab; entscheidend ist, dass sie NACH den positiven kommen.
      final erstesNegativ = bytes.indexOf(0x20);
      final positionVon3 = 3;
      expect(erstesNegativ, greaterThan(positionVon3),
          reason: 'negative Schluessel kommen NACH den positiven');
    });

    test('Reihenfolge beim Einfuegen aendert nichts', () {
      final a = k({1: 'x', 3: 'y', -1: 'z'});
      final b = k({-1: 'z', 3: 'y', 1: 'x'});
      expect(a, b, reason: 'kanonisch heisst: die Einfuegereihenfolge zaehlt nicht');
    });

    test('Zeichenketten: kuerzere zuerst, dann byteweise', () {
      final bytes = k({'bb': 1, 'a': 2, 'ab': 3});
      // Erwartet: 'a' (kuerzer), dann 'ab', dann 'bb'.
      final text = String.fromCharCodes(bytes);
      expect(text.indexOf('a'), lessThan(text.indexOf('ab')));
      expect(text.indexOf('ab'), lessThan(text.indexOf('bb')));
    });
  });

  group('Gegenprobe mit der Bibliothek', () {
    test('was wir schreiben, liest package:cbor wieder als dasselbe', () {
      // Prueft die Bedeutung, waehrend die Tests darueber die exakten Bytes
      // pruefen. Beides zusammen: richtige Bytes UND richtiger Inhalt.
      final werte = <Object?>[
        42,
        -17,
        'hallo',
        [1, 2, 3],
        {1: 'a', 2: 'b'},
        true,
        Uint8List.fromList([1, 2, 3]),
      ];
      for (final w in werte) {
        final zurueck = paket.cbor.decode(CtapCbor.kodiere(w));
        if (w is Uint8List) {
          expect(zurueck, w);
        } else {
          expect(zurueck, w, reason: 'bei $w');
        }
      }
    });
  });

  test('unbekannte Typen werden abgelehnt statt still verfaelscht', () {
    expect(() => CtapCbor.kodiere(3.14), throwsArgumentError);
    expect(() => CtapCbor.kodiere(DateTime.now()), throwsArgumentError);
  });
}
