// key_derivation.dart — von zwoelf Woertern zu allen Schluesseln des Geraets.
//
//   BIP39-Wortfolge (12 Woerter)
//        │  PBKDF2-HMAC-SHA512, 2048 Runden        (bip39.dart)
//        ▼
//   Seed (64 Byte)
//        ├── HKDF-SHA256, info="bitdm identity key v1" ──▶ Identitaetsschluessel
//        │                                                  └─▶ Adresse
//        ├── HKDF-SHA256, info="bitdm database key v1" ──▶ Datenbankschluessel
//        └── HKDF-SHA256, info="bitdm attachments at rest v1"
//                                                   ──▶ Ablageschluessel
//
// Der Ablageschluessel (seit 25.09.2026) verschluesselt die Anhangdateien
// auf dem Geraet (anhang/ruhe_datei.dart). Er liegt, wie der
// Datenbankschluessel, nur im Speicher, solange die App entsperrt ist.
//
// Warum getrennte Labels statt eines Schluessels fuer alles:
// HKDF liefert fuer verschiedene info-Werte kryptographisch unabhaengige
// Ergebnisse. Wer den Datenbankschluessel erbeutet, kann daraus NICHT auf den
// Identitaetsschluessel schliessen — und umgekehrt. Nur der Seed oeffnet beides.
//
// Warum der Datenbankschluessel ueberhaupt aus dem Seed stammt und nicht aus
// reinem Zufall: nur so bleibt ein verschluesseltes Verlaufs-Backup spaeter
// nachruestbar, ohne ein zweites Geheimnis einzufuehren, das Nutzer separat
// sichern muessten. Der Preis ist bewusst in Kauf genommen und in PLAN.md §2
// festgehalten.
//
// ACHTUNG: Die info-Zeichenketten sind Teil des Formats. Wird eine davon
// geaendert, ergeben dieselben zwoelf Woerter eine ANDERE Identitaet — alle
// bestehenden Konten waeren unwiederbringlich verloren. Deshalb tragen sie
// eine Versionsnummer; eine kuenftige Aenderung bekaeme "v2" und eine
// Migration, statt v1 stillschweigend umzudeuten.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'address.dart';
import 'bip39.dart';

/// Alle aus einer Seed-Phrase abgeleiteten Schluessel eines Geraets.
class DerivedKeys {
  /// Privater Curve25519-Identitaetsschluessel, RFC-7748-konform geclamped.
  final Uint8List identityPrivateKey;

  /// Zugehoeriger oeffentlicher Schluessel.
  final Uint8List identityPublicKey;

  /// 32-Byte-Schluessel fuer die verschluesselte Nachrichtendatenbank.
  final Uint8List databaseKey;

  /// 32-Byte-Schluessel fuer die Anhangdateien auf dem Geraet
  /// ("attachments at rest", siehe anhang/ruhe_datei.dart).
  final Uint8List attachmentKey;

  const DerivedKeys({
    required this.identityPrivateKey,
    required this.identityPublicKey,
    required this.databaseKey,
    required this.attachmentKey,
  });

  /// Die "lange Nummer", die der Nutzer weitergibt.
  String get address => BitdmAddress.encode(identityPublicKey);

  /// Bewusst ohne Schluesselmaterial — damit ein versehentliches Loggen der
  /// Struktur keine Geheimnisse preisgibt.
  @override
  String toString() => 'DerivedKeys(address: $address)';
}

class KeyDerivation {
  KeyDerivation._();

  /// HKDF-Label des Identitaetsschluessels. Aenderung = neue Identitaeten.
  static const String identityInfo = 'bitdm identity key v1';

  /// HKDF-Label des Datenbankschluessels. Aenderung = unlesbare Datenbanken.
  static const String databaseInfo = 'bitdm database key v1';

  /// HKDF-Label des Ablageschluessels fuer Anhaenge. Aenderung = alle bereits
  /// abgelegten Anhangdateien werden unlesbar.
  static const String attachmentInfo = 'bitdm attachments at rest v1';

  static const int _keyLength = 32;

  /// Zwoelf Woerter -> alle Schluessel. Wirft [MnemonicException] bei falscher
  /// Pruefsumme oder unbekanntem Wort.
  static Future<DerivedKeys> fromMnemonic(List<String> words) async {
    // Wirft, wenn die Wortfolge ungueltig ist — bevor irgendetwas abgeleitet
    // wird. Sonst entstuende aus einer vertippten Phrase klaglos eine falsche,
    // aber gueltig aussehende Identitaet.
    Bip39.mnemonicToEntropy(words);
    return fromSeed(await Bip39.mnemonicToSeed(words));
  }

  /// Seed -> alle Schluessel.
  static Future<DerivedKeys> fromSeed(Uint8List seed) async {
    final identityRaw = await _hkdf(seed, identityInfo);
    final databaseKey = await _hkdf(seed, databaseInfo);
    final attachmentKey = await _hkdf(seed, attachmentInfo);

    // Explizites Clamping: Manche Bibliotheken clampen beim Erzeugen, andere
    // erst bei der Verwendung. Wird der Schluessel hier kanonisiert, liefern
    // alle dieselbe Adresse — sonst haengt die Identitaet davon ab, welche
    // Implementierung sie gerade berechnet.
    final identityPrivateKey = _clampX25519(identityRaw);

    final keyPair =
        await X25519().newKeyPairFromSeed(identityPrivateKey);
    final publicKey = await keyPair.extractPublicKey();

    return DerivedKeys(
      identityPrivateKey: identityPrivateKey,
      identityPublicKey: Uint8List.fromList(publicKey.bytes),
      databaseKey: databaseKey,
      attachmentKey: attachmentKey,
    );
  }

  /// Bequemer Kurzweg: Wortfolge -> Adresse.
  static Future<String> addressFromMnemonic(List<String> words) async =>
      (await fromMnemonic(words)).address;

  // ------------------------------------------------------------------ intern

  static Future<Uint8List> _hkdf(Uint8List seed, String info) async {
    // Salt bleibt leer. RFC 5869 erlaubt das ausdruecklich, wenn das
    // Eingangsmaterial bereits gleichverteilt und hochentropisch ist — der
    // BIP39-Seed ist beides. Getrennt werden die Ausgaben ueber `info`.
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: _keyLength);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(seed),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Clamping nach RFC 7748 Abschnitt 5.
  static Uint8List _clampX25519(Uint8List key) {
    final out = Uint8List.fromList(key);
    out[0] &= 0xF8; // unterste drei Bits loeschen
    out[31] &= 0x7F; // oberstes Bit loeschen
    out[31] |= 0x40; // zweitoberstes Bit setzen
    return out;
  }
}
