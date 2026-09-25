// sicherung.dart — der Verlauf als verschluesselte Datei.
//
// WAS DRIN IST: Kontakte, Nachrichten, Reaktionen, Stimmen und die
// Anleitungen der Anhaenge (damit sich ein Anhang holen laesst, solange er
// noch im Zwischenlager liegt — 14 Tage). Die Dateien selbst NICHT: sie
// koennen Gigabyte gross sein, und eine Sicherung, die man nicht verschicken
// oder ablegen kann, macht niemand.
//
// WAS BEWUSST NICHT DRIN IST: Schluessel und Signal-Sitzungen. Eine Sitzung
// ist eine Hashkette mit genau einer gueltigen Zukunft (docs/MEHRGERAETE.md
// §0). Spielte man eine alte Sitzung ein, waehrend das alte Geraet noch
// laeuft, rasteten zwei Geraete dieselbe Kette weiter — und Nachrichten
// gingen still verloren. Eingespielt wird deshalb nach dem Wiederherstellen
// mit den zwoelf Woertern: die Identitaet ist dieselbe, die Sitzungen
// entstehen frisch.
//
// DER SCHLUESSEL kommt aus denselben zwoelf Woertern wie alles andere, ueber
// ein eigenes HKDF-Label. Wer die Datei hat, aber nicht die Woerter, hat
// Rauschen; wer die Woerter hat, hat ohnehin die Identitaet. Ein zusaetzliches
// Sicherungspasswort waere ein weiteres Geheimnis, das man verlieren kann,
// ohne dass es etwas schuetzt, was die Woerter nicht schon schuetzen.
//
// FORMAT: "BITDM-SICHERUNG-1" (17 Byte) ‖ Nonce (12) ‖ Chiffretext ‖ MAC (16).
// ChaCha20-Poly1305, die Magie steht als zusaetzliche Daten mit im MAC — eine
// Datei mit vertauschtem Kopf geht nicht auf.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/bip39.dart';

/// Die Datei ist keine Sicherung dieser Identitaet — andere Woerter,
/// beschaedigt, oder gar keine BitDM-Sicherung.
class SicherungPasstNichtException implements Exception {
  const SicherungPasstNichtException(this.grund);
  final String grund;
  @override
  String toString() => 'SicherungPasstNichtException: $grund';
}

class Sicherung {
  static final Uint8List magie =
      Uint8List.fromList(utf8.encode('BITDM-SICHERUNG-1'));
  static const String info = 'bitdm backup key v1';

  /// Wie viele Bytes Anhangdateien hoechstens in eine Sicherung gehen.
  ///
  /// Die ganze Sicherung liegt beim Erstellen und Einspielen einmal im
  /// Speicher (und als base64 um ein Drittel groesser). 100 MB sind auf
  /// jedem Telefon, auf dem BitDM laeuft, noch unkritisch; ein Gigabyte
  /// waere es nicht.
  static const int dateienGrenze = 100 * 1024 * 1024;
  static final _aead = Chacha20.poly1305Aead();

  /// Der Sicherungsschluessel aus der Entropie der Identitaet.
  static Future<SecretKey> schluessel(Uint8List entropie) async {
    final seed = await Bip39.mnemonicToSeed(Bip39.entropyToMnemonic(entropie));
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(secretKey: SecretKey(seed), info: utf8.encode(info));
  }

  static Future<Uint8List> verpacke(
      Map<String, Object?> inhalt, SecretKey schluessel) async {
    final klar = utf8.encode(jsonEncode(inhalt));
    final box = await _aead.encrypt(klar,
        secretKey: schluessel, aad: magie, nonce: _aead.newNonce());
    return Uint8List.fromList(
        [...magie, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Map<String, Object?>> entpacke(
      Uint8List daten, SecretKey schluessel) async {
    const nonceLaenge = 12;
    const macLaenge = 16;
    if (daten.length < magie.length + nonceLaenge + macLaenge) {
      throw const SicherungPasstNichtException('zu kurz');
    }
    for (var i = 0; i < magie.length; i++) {
      if (daten[i] != magie[i]) {
        throw const SicherungPasstNichtException('keine BitDM-Sicherung');
      }
    }
    final nonce = daten.sublist(magie.length, magie.length + nonceLaenge);
    final chiffre =
        daten.sublist(magie.length + nonceLaenge, daten.length - macLaenge);
    final mac = daten.sublist(daten.length - macLaenge);
    final List<int> klar;
    try {
      klar = await _aead.decrypt(
          SecretBox(chiffre, nonce: nonce, mac: Mac(mac)),
          secretKey: schluessel,
          aad: magie);
    } on SecretBoxAuthenticationError {
      // DIE HAEUFIGSTE URSACHE ist keine Beschaedigung, sondern eine andere
      // Identitaet: die Sicherung stammt von anderen zwoelf Woertern.
      throw const SicherungPasstNichtException(
          'gehoert zu einer anderen Identitaet oder ist beschaedigt');
    }
    final j = jsonDecode(utf8.decode(klar));
    if (j is! Map || j['v'] != 1) {
      throw const SicherungPasstNichtException('unbekannte Fassung');
    }
    return j.cast<String, Object?>();
  }
}
