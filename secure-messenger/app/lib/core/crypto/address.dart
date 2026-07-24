// address.dart — die "lange Nummer", die Nutzer weitergeben.
//
// Die Adresse IST der oeffentliche Identitaetsschluessel, lesbar kodiert und mit
// Pruefsumme gegen Tippfehler. Es gibt keine Registrierung und keine Zuordnung
// auf dem Server: wer die richtige Adresse hat, hat zwangslaeufig den richtigen
// Schluessel. Ein boesartiger Server kann keinen Schluessel unterschieben —
// er wuerde die Adresse veraendern und damit auffliegen.
//
// FORMAT (muss byteweise mit encode_id/decode_id in server/relay_server.py
// uebereinstimmen — andernfalls reden Client und Server aneinander vorbei):
//
//   base32( pubkey[32] || sha256(pubkey)[0..3] )   -> exakt 56 Zeichen, klein
//
// Warum 3 Byte Pruefsumme und nicht 2:
// 35 Byte gehen in Base32 glatt auf (7 Bloecke a 5 Byte -> 56 Zeichen). Es
// entsteht also nie ein '='-Padding, das man abschneiden und spaeter wieder
// anhaengen muesste. Nebeneffekt: die Tippfehlererkennung steigt von 16 auf
// 24 Bit — die Wahrscheinlichkeit, dass eine verfaelschte Adresse trotzdem
// gueltig aussieht, faellt von 1:65.000 auf etwa 1:16.000.000.

import 'dart:typed_data';

import 'package:cryptography/dart.dart';

/// Die Adresse ist unbrauchbar (falsche Laenge, fremdes Zeichen, Pruefsumme).
class InvalidAddressFormatException implements Exception {
  final String message;
  const InvalidAddressFormatException(this.message);
  @override
  String toString() => 'InvalidAddressFormatException: $message';
}

class BitdmAddress {
  BitdmAddress._();

  /// RFC-4648-Alphabet — identisch zu Pythons `base64.b32encode`.
  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Laenge des Identitaetsschluessels (Curve25519).
  static const int keyBytes = 32;

  /// Laenge der Pruefsumme.
  static const int checksumBytes = 3;

  /// Laenge der fertigen Adresse in Zeichen.
  static const int addressLength = 56;

  /// Gruppengroesse fuer die Anzeige.
  static const int displayGroupSize = 4;

  /// Oeffentlicher Schluessel -> Adresse.
  static String encode(Uint8List publicKey) {
    if (publicKey.length != keyBytes) {
      throw InvalidAddressFormatException(
          'Schluessel muss $keyBytes Byte sein, war ${publicKey.length}');
    }
    final checksum = _sha256(publicKey).sublist(0, checksumBytes);
    final payload = Uint8List(keyBytes + checksumBytes)
      ..setRange(0, keyBytes, publicKey)
      ..setRange(keyBytes, keyBytes + checksumBytes, checksum);
    return _base32Encode(payload).toLowerCase();
  }

  /// Adresse -> oeffentlicher Schluessel. Wirft bei jedem Formfehler.
  ///
  /// Toleriert Leerzeichen und Bindestriche aus der Anzeige sowie
  /// Gross-/Kleinschreibung — Nutzer tippen Adressen ab und fuegen sie aus
  /// formatierten Darstellungen ein.
  static Uint8List decode(String address) {
    final clean = normalize(address);
    if (clean.length != addressLength) {
      throw InvalidAddressFormatException(
          'Adresse muss $addressLength Zeichen haben, hatte ${clean.length}');
    }
    final payload = _base32Decode(clean.toUpperCase());
    final key = Uint8List.sublistView(payload, 0, keyBytes);
    final checksum = Uint8List.sublistView(payload, keyBytes);
    final expected = _sha256(key).sublist(0, checksumBytes);
    for (var i = 0; i < checksumBytes; i++) {
      if (checksum[i] != expected[i]) {
        throw const InvalidAddressFormatException(
            'Pruefsumme stimmt nicht — vertippt?');
      }
    }
    return Uint8List.fromList(key);
  }

  /// Schnelle Formpruefung ohne Netzwerk, fuer das Einfuegefeld der UI.
  static bool isValid(String address) {
    try {
      decode(address);
      return true;
    } on InvalidAddressFormatException {
      return false;
    }
  }

  /// Entfernt Anzeigeformatierung (Leerzeichen, Bindestriche) und normalisiert
  /// auf Kleinschreibung.
  static String normalize(String address) =>
      address.replaceAll(RegExp(r'[\s\-]'), '').toLowerCase();

  /// Fuer die Anzeige: 14 Gruppen a 4 Zeichen, getrennt durch [separator].
  static String format(String address, {String separator = '-'}) {
    final clean = normalize(address);
    return [
      for (var i = 0; i < clean.length; i += displayGroupSize)
        clean.substring(
            i,
            i + displayGroupSize > clean.length
                ? clean.length
                : i + displayGroupSize),
    ].join(separator);
  }

  // ------------------------------------------------------------------ intern

  static Uint8List _sha256(Uint8List data) =>
      Uint8List.fromList(const DartSha256().hashSync(data).bytes);

  /// Base32 nach RFC 4648, ohne Padding.
  ///
  /// Wir kodieren immer genau 35 Byte = 280 Bit = 56 Zeichen; das ist ein
  /// Vielfaches von 40 Bit, deshalb entsteht nie ein Rest und nie ein '='.
  static String _base32Encode(Uint8List data) {
    final out = StringBuffer();
    var buffer = 0;
    var bitsLeft = 0;
    for (final byte in data) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        out.write(_alphabet[(buffer >> (bitsLeft - 5)) & 0x1F]);
        bitsLeft -= 5;
      }
    }
    if (bitsLeft > 0) {
      out.write(_alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return out.toString();
  }

  static Uint8List _base32Decode(String input) {
    final out = <int>[];
    var buffer = 0;
    var bitsLeft = 0;
    for (final char in input.split('')) {
      final value = _alphabet.indexOf(char);
      if (value < 0) {
        throw InvalidAddressFormatException('unerlaubtes Zeichen: "$char"');
      }
      buffer = (buffer << 5) | value;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        out.add((buffer >> (bitsLeft - 8)) & 0xFF);
        bitsLeft -= 8;
      }
    }
    return Uint8List.fromList(out);
  }
}
