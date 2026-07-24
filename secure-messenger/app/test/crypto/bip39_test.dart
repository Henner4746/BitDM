// bip39_test.dart — prueft unsere BIP39-Implementierung gegen die offiziellen
// Testvektoren der Referenzimplementierung.
//
// Das ist der Grund, warum BIP39 hier selbst implementiert werden darf statt
// per Paket eingebunden: die Korrektheit ist gegen den Standard nachweisbar,
// nicht bloss geglaubt.

import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/wordlist_english.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bip39_vectors.dart';

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Wortliste', () {
    test('enthaelt genau 2048 Woerter', () {
      expect(bip39EnglishWordlist.length, 2048);
    });

    test('ist alphabetisch sortiert und frei von Duplikaten', () {
      // Beides ist Teil des Standards. Eine falsche Reihenfolge wuerde
      // Seed-Phrasen erzeugen, die kein anderes Werkzeug versteht.
      final sorted = [...bip39EnglishWordlist]..sort();
      expect(bip39EnglishWordlist, orderedEquals(sorted));
      expect(bip39EnglishWordlist.toSet().length, 2048);
    });

    test('beginnt mit "abandon" und endet mit "zoo"', () {
      expect(bip39EnglishWordlist.first, 'abandon');
      expect(bip39EnglishWordlist.last, 'zoo');
    });
  });

  group('Offizielle Testvektoren', () {
    for (var i = 0; i < bip39TestVectors.length; i++) {
      final (entropyHex, mnemonic, seedHex) = bip39TestVectors[i];
      final words = mnemonic.split(' ');

      test('Vektor $i (${words.length} Woerter): Entropie -> Wortfolge', () {
        expect(Bip39.entropyToMnemonic(_hexToBytes(entropyHex)), words);
      });

      test('Vektor $i: Wortfolge -> Entropie', () {
        expect(_bytesToHex(Bip39.mnemonicToEntropy(words)), entropyHex);
      });

      test('Vektor $i: Wortfolge -> Seed', () async {
        // Die Vektordatei verwendet die Passphrase "TREZOR".
        final seed = await Bip39.mnemonicToSeed(words, passphrase: 'TREZOR');
        expect(_bytesToHex(seed), seedHex);
      });
    }
  });

  group('Pruefsumme faengt Fehler ab', () {
    // Gueltige 12-Wort-Phrase aus Vektor 0.
    const valid =
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about';

    test('gueltige Phrase wird angenommen', () {
      expect(Bip39.validate(valid.split(' ')), isTrue);
    });

    test('vertauschte Woerter werden erkannt', () {
      final words = valid.split(' ');
      final swapped = [...words];
      swapped[0] = words[11];
      swapped[11] = words[0];
      expect(Bip39.validate(swapped), isFalse);
    });

    test('falsches letztes Wort wird erkannt', () {
      final words = valid.split(' ')..[11] = 'zoo';
      expect(Bip39.validate(words), isFalse);
    });

    test('unbekanntes Wort wird erkannt', () {
      final words = valid.split(' ')..[3] = 'nichteinwort';
      expect(Bip39.validate(words), isFalse);
      expect(() => Bip39.mnemonicToEntropy(words),
          throwsA(isA<MnemonicException>()));
    });

    test('falsche Wortanzahl wird erkannt', () {
      expect(Bip39.validate(valid.split(' ').sublist(0, 11)), isFalse);
    });
  });

  group('Erzeugung', () {
    test('liefert 12 Woerter aus der Liste', () {
      final words = Bip39.generate();
      expect(words.length, Bip39.wordCount);
      for (final w in words) {
        expect(bip39EnglishWordlist, contains(w));
      }
    });

    test('erzeugte Phrase ist immer gueltig', () {
      for (var i = 0; i < 50; i++) {
        expect(Bip39.validate(Bip39.generate()), isTrue);
      }
    });

    test('zwei Aufrufe liefern verschiedene Phrasen', () {
      // Waere das nicht so, kaeme der Zufall nicht aus einer sicheren Quelle —
      // jede Identitaet waere vorhersagbar.
      final seen = <String>{};
      for (var i = 0; i < 20; i++) {
        seen.add(Bip39.generate().join(' '));
      }
      expect(seen.length, 20);
    });

    test('Rundlauf Entropie -> Woerter -> Entropie', () {
      for (var i = 0; i < 20; i++) {
        final words = Bip39.generate();
        final entropy = Bip39.mnemonicToEntropy(words);
        expect(Bip39.entropyToMnemonic(entropy), words);
      }
    });
  });
}
