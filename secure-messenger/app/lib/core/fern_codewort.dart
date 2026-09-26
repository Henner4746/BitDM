// fern_codewort.dart — das Codewort, mit dem Vertrauenskontakte eine
// Fernloeschung anstossen koennen, ohne /wipe zu tippen.
//
// WOZU: /wipe verschickt eine eigene Nachrichtenart (PayloadKind.
// loeschanfrage). Das kann nur eine BitDM-Fassung, die sie kennt, und es
// verlangt, dass der Vertrauenskontakt den Befehl findet. Ein Codewort ist
// einfacher: der Vertrauenskontakt schreibt eine gewoehnliche Nachricht mit
// dem vereinbarten Wort oder Satz. Kommt sie von einem Vertrauten, zaehlt sie
// hier GENAU wie eine Loeschanfrage (Fernloeschung.nimmAnfrage — k von n,
// 24 Stunden, 10 Minuten Countdown) und erscheint nirgends.
//
// GESPEICHERT WIRD NUR EIN GESALZENER HASH, nie das Wort selbst:
//   {"v":1,"s":<16 Byte Salz, base64>,"h":<SHA-256, base64>}
//   h = SHA-256("bitdm-fern-codewort-v1|" ‖ salz ‖ UTF-8(normalisiert))
// in der verschluesselten Datenbank (meta 'fern_codewort'). Wer das
// entsperrte Telefon hat, liest das Wort damit nicht aus den Einstellungen
// ab — er muesste es raten.
//
// NORMALISIERT wird an beiden Stellen gleich ([normalisiere]): Rand weg,
// Leerraum innen zu einem Leerzeichen, klein geschrieben. Unicode-NFC nicht:
// dafuer gibt es kein Paket im Bau, und Tastaturen liefern Umlaute ohnehin
// zusammengesetzt.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import 'lock/key_vault.dart' show gleichInKonstanterZeit, zufallsBytes;

class FernCodewort {
  const FernCodewort._(this._salz, this._hash);

  final Uint8List _salz;
  final Uint8List _hash;

  /// Mindestens so viele Zeichen NACH dem Normalisieren.
  static const int minLaenge = 6;

  /// Hoechstens so viele — laengere Nachrichten koennen es nicht sein und
  /// werden gar nicht erst gerechnet.
  static const int maxLaenge = 200;

  static const _praefix = 'bitdm-fern-codewort-v1|';

  static final _leerraum = RegExp(r'\s+');

  /// Die Form, in der verglichen wird.
  static String normalisiere(String s) =>
      s.trim().replaceAll(_leerraum, ' ').toLowerCase();

  /// Ob [wort] als Codewort taugt.
  static bool taugt(String wort) {
    final n = normalisiere(wort);
    return n.length >= minLaenge && n.length <= maxLaenge;
  }

  /// Baut aus [wort] den Eintrag. Wirft [ArgumentError], wenn es nicht taugt.
  static FernCodewort aus(String wort) {
    if (!taugt(wort)) {
      throw ArgumentError('Codewort braucht $minLaenge bis $maxLaenge Zeichen');
    }
    final salz = zufallsBytes(16);
    return FernCodewort._(salz, _rechne(salz, normalisiere(wort)));
  }

  static Uint8List _rechne(Uint8List salz, String normal) =>
      Uint8List.fromList(const DartSha256().hashSync([
        ...utf8.encode(_praefix),
        ...salz,
        ...utf8.encode(normal),
      ]).bytes);

  /// Ob [text] das Codewort ist (nach dem Normalisieren).
  bool passt(String text) {
    final n = normalisiere(text);
    if (n.length < minLaenge || n.length > maxLaenge) return false;
    return gleichInKonstanterZeit(_rechne(_salz, n), _hash);
  }

  String alsJson() => jsonEncode({
        'v': 1,
        's': base64.encode(_salz),
        'h': base64.encode(_hash),
      });

  /// Liest einen gespeicherten Eintrag — oder null, wenn keiner da ist oder
  /// er nicht lesbar ist.
  static FernCodewort? ausJson(String? roh) {
    if (roh == null || roh.isEmpty) return null;
    try {
      final j = (jsonDecode(roh) as Map).cast<String, Object?>();
      if (j['v'] != 1) return null;
      final salz = base64.decode(j['s']! as String);
      final hash = base64.decode(j['h']! as String);
      if (salz.length != 16 || hash.length != 32) return null;
      return FernCodewort._(salz, hash);
    } catch (_) {
      return null;
    }
  }
}
