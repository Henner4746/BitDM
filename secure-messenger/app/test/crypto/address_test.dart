// address_test.dart — prueft das Adressformat, insbesondere gegen den Server.
//
// Der wichtigste Teil sind die Kreuzvektoren: sie stammen aus der
// Python-Implementierung in server/relay_server.py. Berechnen Client und Server
// unterschiedliche Adressen fuer denselben Schluessel, koennte niemand jemanden
// hinzufuegen — und der Fehler wuerde erst im Betrieb auffallen, nicht im Test.

import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:flutter_test/flutter_test.dart';

import 'address_vectors.dart';

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Kreuzprobe gegen den Python-Server', () {
    for (var i = 0; i < addressCrossVectors.length; i++) {
      final (keyHex, expectedAddress) = addressCrossVectors[i];

      test('Vektor $i: Schluessel -> Adresse stimmt mit Server ueberein', () {
        expect(BitdmAddress.encode(_hexToBytes(keyHex)), expectedAddress);
      });

      test('Vektor $i: Adresse -> Schluessel', () {
        expect(_bytesToHex(BitdmAddress.decode(expectedAddress)), keyHex);
      });
    }
  });

  group('Format', () {
    final key = _hexToBytes(addressCrossVectors.first.$1);
    final address = BitdmAddress.encode(key);

    test('ist exakt 56 Zeichen lang', () {
      expect(address.length, BitdmAddress.addressLength);
    });

    test('enthaelt nie ein Padding-Zeichen', () {
      // 35 Byte sind ein Vielfaches von 40 Bit — es darf nie ein '=' entstehen.
      expect(address, isNot(contains('=')));
    });

    test('nutzt nur Kleinbuchstaben und Ziffern 2-7', () {
      expect(RegExp(r'^[a-z2-7]{56}$').hasMatch(address), isTrue);
    });

    test('wird in 14 Gruppen a 4 Zeichen angezeigt', () {
      final formatted = BitdmAddress.format(address);
      final groups = formatted.split('-');
      expect(groups.length, 14);
      expect(groups.every((g) => g.length == 4), isTrue);
    });

    test('formatierte Adresse laesst sich wieder einlesen', () {
      final formatted = BitdmAddress.format(address);
      expect(BitdmAddress.decode(formatted), key);
    });
  });

  group('Eingabetoleranz', () {
    final key = _hexToBytes(addressCrossVectors.first.$1);
    final address = BitdmAddress.encode(key);

    test('akzeptiert Grossschreibung', () {
      expect(BitdmAddress.decode(address.toUpperCase()), key);
    });

    test('akzeptiert Leerzeichen aus der Zwischenablage', () {
      final spaced = BitdmAddress.format(address, separator: ' ');
      expect(BitdmAddress.decode(spaced), key);
    });

    test('akzeptiert fuehrende und nachgestellte Leerzeichen', () {
      expect(BitdmAddress.decode('  $address \n'), key);
    });
  });

  group('Pruefsumme faengt Tippfehler ab', () {
    final key = _hexToBytes(addressCrossVectors.first.$1);
    final address = BitdmAddress.encode(key);

    test('gueltige Adresse wird angenommen', () {
      expect(BitdmAddress.isValid(address), isTrue);
    });

    test('ein einzelnes veraendertes Zeichen wird erkannt', () {
      // Genau dafuer ist die Pruefsumme da: ein Vertipper darf nie eine
      // gueltige Adresse eines anderen ergeben.
      var caught = 0;
      for (var pos = 0; pos < address.length; pos++) {
        final orig = address[pos];
        final replacement = orig == 'a' ? 'b' : 'a';
        final broken =
            address.replaceRange(pos, pos + 1, replacement);
        if (!BitdmAddress.isValid(broken)) caught++;
      }
      expect(caught, address.length,
          reason: 'jede Einzelzeichen-Aenderung muss auffallen');
    });

    test('vertauschte Nachbarzeichen werden erkannt', () {
      var caught = 0;
      var tried = 0;
      for (var pos = 0; pos < address.length - 1; pos++) {
        if (address[pos] == address[pos + 1]) continue;
        tried++;
        final chars = address.split('');
        final tmp = chars[pos];
        chars[pos] = chars[pos + 1];
        chars[pos + 1] = tmp;
        if (!BitdmAddress.isValid(chars.join())) caught++;
      }
      expect(caught, tried);
    });

    test('zu kurze und zu lange Adressen werden abgelehnt', () {
      expect(BitdmAddress.isValid(address.substring(0, 55)), isFalse);
      expect(BitdmAddress.isValid('${address}a'), isFalse);
      expect(BitdmAddress.isValid(''), isFalse);
    });

    test('unerlaubte Zeichen werden abgelehnt', () {
      // '0', '1', '8' und '9' sind nicht Teil des Base32-Alphabets.
      expect(BitdmAddress.isValid(address.replaceRange(0, 1, '0')), isFalse);
      expect(BitdmAddress.isValid(address.replaceRange(0, 1, '1')), isFalse);
      expect(BitdmAddress.isValid(address.replaceRange(0, 1, '9')), isFalse);
    });

    test('falsche Schluessellaenge wird beim Kodieren abgelehnt', () {
      expect(() => BitdmAddress.encode(Uint8List(31)),
          throwsA(isA<InvalidAddressFormatException>()));
      expect(() => BitdmAddress.encode(Uint8List(33)),
          throwsA(isA<InvalidAddressFormatException>()));
    });
  });
}
