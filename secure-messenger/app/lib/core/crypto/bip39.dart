// bip39.dart — Seed-Phrase nach BIP-0039.
//
// Die zwoelf Woerter sind die Wurzel JEDER Identitaet in BitDM. Aus ihnen wird
// der Identitaetsschluessel abgeleitet (und damit die Adresse) sowie der
// Schluessel der lokalen Nachrichtendatenbank — siehe key_derivation.dart.
//
// Warum selbst implementiert statt Paket:
// Das gaengige `bip39`-Paket ist fuenf Jahre alt und stammt von einem
// unverifizierten Uploader. Fuer die Wurzel des gesamten Schluesselmaterials
// ist das die falsche Abhaengigkeit. BIP39 ist ohnehin kein Krypto-Primitiv,
// sondern eine Kodierung: Bitpackung plus Wortlisten-Nachschlag. Die
// eigentliche Kryptographie (PBKDF2-HMAC-SHA512, SHA-256) kommt aus dem
// `cryptography`-Paket. Der hier liegende Teil ist vollstaendig gegen die
// offiziellen Testvektoren geprueft (test/crypto/bip39_test.dart).
//
// Spezifikation:
// https://github.com/bitcoin/bips/blob/master/bip-0039/bip-0039-spec.mediawiki

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
// DartSha256 liegt im reinen Dart-Export, nicht im Haupt-Export — nur diese
// Variante bietet mit hashSync() eine synchrone Auswertung, die die Bitlogik
// der Pruefsumme braucht.
import 'package:cryptography/dart.dart';

import 'wordlist_english.dart';

/// Fehler beim Einlesen oder Pruefen einer Seed-Phrase.
class MnemonicException implements Exception {
  final String message;
  const MnemonicException(this.message);
  @override
  String toString() => 'MnemonicException: $message';
}

class Bip39 {
  Bip39._();

  /// Anzahl Woerter, die BitDM verwendet.
  ///
  /// 12 Woerter entsprechen 128 Bit Entropie. Das passt exakt zum
  /// Sicherheitsniveau von X25519 (~128 Bit) — 24 Woerter waeren an dieser
  /// Stelle reine Zahlenkosmetik, weil der Schluessel darunter nicht staerker
  /// wird, die Abtippfehlerquote aber steigt.
  static const int wordCount = 12;
  static const int _entropyBytes = 16; // 128 Bit

  /// Erzeugt eine neue Seed-Phrase aus kryptographisch sicherem Zufall.
  ///
  /// [randomBytes] existiert ausschliesslich fuer Tests mit festen Vektoren.
  /// Im Betrieb NIE setzen — dann kommt [Random.secure] zum Einsatz.
  static List<String> generate({Uint8List? randomBytes}) {
    final entropy = randomBytes ?? _secureRandomBytes(_entropyBytes);
    if (entropy.length != _entropyBytes) {
      throw MnemonicException(
          'Entropie muss $_entropyBytes Byte sein, war ${entropy.length}');
    }
    return entropyToMnemonic(entropy);
  }

  /// Entropie -> Wortfolge.
  ///
  /// An die Entropie werden die obersten (Bitlaenge / 32) Bits ihres
  /// SHA-256-Hashes angehaengt; das Ergebnis wird in 11-Bit-Gruppen zerlegt,
  /// von denen jede einen Index in die 2048 Woerter lange Liste bildet.
  static List<String> entropyToMnemonic(Uint8List entropy) {
    if (entropy.isEmpty || entropy.length % 4 != 0 || entropy.length > 32) {
      throw MnemonicException('ungueltige Entropielaenge: ${entropy.length}');
    }
    final checksumBits = entropy.length * 8 ~/ 32;
    final hash = _sha256Sync(entropy);

    final bits = StringBuffer()
      ..writeAll(entropy.map((b) => b.toRadixString(2).padLeft(8, '0')))
      ..write(_bytesToBits(hash).substring(0, checksumBits));

    final all = bits.toString();
    return <String>[
      for (var i = 0; i < all.length ~/ 11; i++)
        bip39EnglishWordlist[int.parse(all.substring(i * 11, (i + 1) * 11), radix: 2)],
    ];
  }

  /// Wortfolge -> Entropie. Wirft bei unbekanntem Wort oder falscher Pruefsumme.
  static Uint8List mnemonicToEntropy(List<String> words) {
    if (words.length % 3 != 0 || words.isEmpty || words.length > 24) {
      throw MnemonicException('ungueltige Wortanzahl: ${words.length}');
    }

    final bits = StringBuffer();
    for (final word in words) {
      final index = bip39EnglishWordlist.indexOf(word);
      if (index < 0) {
        throw MnemonicException('unbekanntes Wort: "$word"');
      }
      bits.write(index.toRadixString(2).padLeft(11, '0'));
    }

    final all = bits.toString();
    final dividerIndex = all.length ~/ 33 * 32;
    final entropyBits = all.substring(0, dividerIndex);
    final checksumBits = all.substring(dividerIndex);

    final entropy = Uint8List.fromList([
      for (var i = 0; i < entropyBits.length ~/ 8; i++)
        int.parse(entropyBits.substring(i * 8, (i + 1) * 8), radix: 2),
    ]);

    final expected =
        _bytesToBits(_sha256Sync(entropy)).substring(0, checksumBits.length);
    if (expected != checksumBits) {
      throw const MnemonicException(
          'Pruefsumme stimmt nicht — vertippt oder Woerter vertauscht?');
    }
    return entropy;
  }

  /// Prueft eine Wortfolge, ohne zu werfen.
  static bool validate(List<String> words) {
    try {
      mnemonicToEntropy(words);
      return true;
    } on MnemonicException {
      return false;
    }
  }

  /// Wortfolge -> 64-Byte-Seed (BIP39: PBKDF2-HMAC-SHA512, 2048 Runden).
  ///
  /// [passphrase] ist BitDM-seitig immer leer. BIP39 erlaubt eine zusaetzliche
  /// Passphrase; sie wird hier nur unterstuetzt, damit die offiziellen
  /// Testvektoren (die "TREZOR" verwenden) geprueft werden koennen.
  static Future<Uint8List> mnemonicToSeed(
    List<String> words, {
    String passphrase = '',
  }) async {
    final mnemonic = words.join(' ');
    final salt = utf8.encode('mnemonic$passphrase');

    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: 2048,
      bits: 512,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(mnemonic)),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  // ------------------------------------------------------------------ intern

  static String _bytesToBits(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(2).padLeft(8, '0')).join();

  static Uint8List _secureRandomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => rng.nextInt(256)));
  }

  /// SHA-256 synchron.
  ///
  /// Das `cryptography`-Paket ist durchgaengig asynchron; fuer die Pruefsumme
  /// wird der Hash aber mitten in synchroner Bitlogik gebraucht. `DartSha256`
  /// bietet dafuer `hashSync`.
  static Uint8List _sha256Sync(Uint8List data) =>
      Uint8List.fromList(const DartSha256().hashSync(data).bytes);
}
