// key_derivation_test.dart — prueft die Kette von zwoelf Woertern bis zur Adresse.
//
// Kernstueck sind die Kreuzvektoren: dieselbe Ableitung wurde in Python mit
// voellig anderen Bibliotheken nachgerechnet (hashlib fuer PBKDF2, eine direkte
// RFC-5869-Implementierung fuer HKDF, libxeddsa fuer den oeffentlichen
// Schluessel). Stimmen beide Seiten ueberein, ist die Kette in zwei
// unabhaengigen Implementierungen bestaetigt — nicht bloss gegen sich selbst.

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'derivation_vectors.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Kreuzprobe gegen die unabhaengige Python-Nachrechnung', () {
    for (var i = 0; i < derivationCrossVectors.length; i++) {
      final (mnemonic, privHex, pubHex, dbHex, address) =
          derivationCrossVectors[i];
      final words = mnemonic.split(' ');

      test('Vektor $i: Identitaets-Privatschluessel', () async {
        final keys = await KeyDerivation.fromMnemonic(words);
        expect(_hex(keys.identityPrivateKey), privHex);
      });

      test('Vektor $i: oeffentlicher Schluessel', () async {
        final keys = await KeyDerivation.fromMnemonic(words);
        expect(_hex(keys.identityPublicKey), pubHex);
      });

      test('Vektor $i: Datenbankschluessel', () async {
        final keys = await KeyDerivation.fromMnemonic(words);
        expect(_hex(keys.databaseKey), dbHex);
      });

      test('Vektor $i: Adresse', () async {
        expect(await KeyDerivation.addressFromMnemonic(words), address);
      });
    }
  });

  group('Eigenschaften der Ableitung', () {
    const words = [
      'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
      'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'about',
    ];

    test('ist deterministisch — gleiche Woerter, gleiche Identitaet', () async {
      // Das ist der ganze Sinn der Wiederherstellung: auf einem neuen Geraet
      // muessen dieselben zwoelf Woerter exakt dieselbe Adresse ergeben.
      final a = await KeyDerivation.fromMnemonic(words);
      final b = await KeyDerivation.fromMnemonic(words);
      expect(a.identityPrivateKey, b.identityPrivateKey);
      expect(a.databaseKey, b.databaseKey);
      expect(a.address, b.address);
    });

    test('Identitaets- und Datenbankschluessel sind verschieden', () async {
      // Getrennte HKDF-Labels: wer den Datenbankschluessel erbeutet, darf
      // daraus nicht auf die Identitaet schliessen koennen.
      final keys = await KeyDerivation.fromMnemonic(words);
      expect(keys.identityPrivateKey, isNot(equals(keys.databaseKey)));
    });

    test('alle Schluessel sind 32 Byte lang', () async {
      final keys = await KeyDerivation.fromMnemonic(words);
      expect(keys.identityPrivateKey.length, 32);
      expect(keys.identityPublicKey.length, 32);
      expect(keys.databaseKey.length, 32);
      expect(keys.attachmentKey.length, 32);
    });

    test('der Ablageschluessel der Anhaenge ist fest und von allen anderen getrennt', () async {
      // Fest: nach dem Wiederherstellen mit denselben Woertern muessen sich
      // die abgelegten Anhaenge wieder oeffnen lassen. Getrennt: wer den
      // Datenbankschluessel hat, hat damit nicht die Dateien, und umgekehrt.
      final a = await KeyDerivation.fromMnemonic(words);
      final b = await KeyDerivation.fromMnemonic(words);
      expect(a.attachmentKey, b.attachmentKey);
      expect(a.attachmentKey, isNot(equals(a.databaseKey)));
      expect(a.attachmentKey, isNot(equals(a.identityPrivateKey)));
    });

    test('privater Schluessel ist RFC-7748-konform geclamped', () async {
      final keys = await KeyDerivation.fromMnemonic(words);
      final k = keys.identityPrivateKey;
      expect(k[0] & 0x07, 0, reason: 'unterste drei Bits muessen 0 sein');
      expect(k[31] & 0x80, 0, reason: 'oberstes Bit muss 0 sein');
      expect(k[31] & 0x40, 0x40, reason: 'zweitoberstes Bit muss 1 sein');
    });

    test('verschiedene Phrasen ergeben verschiedene Identitaeten', () async {
      final seen = <String>{};
      for (var i = 0; i < 8; i++) {
        seen.add(await KeyDerivation.addressFromMnemonic(Bip39.generate()));
      }
      expect(seen.length, 8);
    });

    test('erzeugte Phrase ergibt eine gueltige 56-Zeichen-Adresse', () async {
      final address = await KeyDerivation.addressFromMnemonic(Bip39.generate());
      expect(address.length, 56);
      expect(RegExp(r'^[a-z2-7]{56}$').hasMatch(address), isTrue);
    });
  });

  group('Fehlerbehandlung', () {
    test('vertippte Phrase wird abgelehnt, bevor abgeleitet wird', () async {
      // Ohne diese Pruefung entstuende aus einer vertippten Phrase klaglos eine
      // falsche, aber gueltig aussehende Identitaet — und der Nutzer wuerde erst
      // merken, dass etwas nicht stimmt, wenn ihn niemand mehr erreicht.
      const broken = [
        'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
        'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'zoo',
      ];
      expect(() => KeyDerivation.fromMnemonic(broken),
          throwsA(isA<MnemonicException>()));
    });

    test('unbekanntes Wort wird abgelehnt', () async {
      const broken = [
        'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
        'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'nichteinwort',
      ];
      expect(() => KeyDerivation.fromMnemonic(broken),
          throwsA(isA<MnemonicException>()));
    });
  });

  group('Label-Konstanten', () {
    test('tragen eine Versionsnummer', () {
      // Aendert sich ein Label ohne Versionswechsel, ergeben dieselben zwoelf
      // Woerter eine andere Identitaet und alle bestehenden Konten waeren weg.
      expect(KeyDerivation.identityInfo, endsWith('v1'));
      expect(KeyDerivation.databaseInfo, endsWith('v1'));
      expect(KeyDerivation.identityInfo,
          isNot(equals(KeyDerivation.databaseInfo)));
      expect(KeyDerivation.attachmentInfo, endsWith('v1'));
      expect({
        KeyDerivation.identityInfo,
        KeyDerivation.databaseInfo,
        KeyDerivation.attachmentInfo,
      }, hasLength(3));
    });
  });
}
