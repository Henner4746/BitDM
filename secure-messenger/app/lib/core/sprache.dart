// sprache.dart — Sprachnachrichten aufnehmen und abspielen, ueber den Kanal
// in SprachKanal.kt.
//
// NUR ANDROID. Am Rechner und im Browser gibt es den Kanal nicht; [verfuegbar]
// sagt dann false, und die Oberflaeche zeigt keinen Knopf, statt einen, der
// nichts tut. Verschickt wird eine Aufnahme wie jeder andere Anhang — die
// Verschluesselung, das Zwischenlager und der Nachversand sind dieselben.

import 'package:flutter/services.dart';

/// Eine fertige Aufnahme.
class Aufnahme {
  const Aufnahme(this.pfad, this.dauer);
  final String pfad;
  final Duration dauer;
}

/// Wie ein Dateiname einer Sprachnachricht aussieht. Der Empfaenger erkennt
/// sie daran und zeigt einen Abspielknopf statt "Oeffnen".
///
/// AM NAMEN UND NICHT AN EINEM FELD: die Anleitung eines Anhangs traegt nur
/// Name, Groesse und Stuecke. Ein neues Feld dafuer muesste durch jede
/// Fassung des Rezepts; der Name kommt ohnehin mit, und eine alte App zeigt
/// dann eben eine .m4a-Datei, die sich mit jedem Spieler oeffnen laesst.
final RegExp sprachName = RegExp(r'^Sprachnachricht-\d{8}-\d{6}\.m4a$');

String sprachDateiname(DateTime t) {
  String z(int n, [int b = 2]) => n.toString().padLeft(b, '0');
  return 'Sprachnachricht-${z(t.year, 4)}${z(t.month)}${z(t.day)}-'
      '${z(t.hour)}${z(t.minute)}${z(t.second)}.m4a';
}

class Sprache {
  static const _kanal = MethodChannel('bitdm/sprache');

  static Future<bool> verfuegbar() async {
    try {
      return await _kanal.invokeMethod<bool>('verfuegbar') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 'ja', 'nein' oder 'dauerhaft' (dann hilft nur noch die
  /// Systemeinstellung).
  static Future<String> rechte() async =>
      await _kanal.invokeMethod<String>('rechte') ?? 'nein';

  static Future<bool> starte() async {
    try {
      return await _kanal.invokeMethod<bool>('starte') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Beendet die Aufnahme. Null, wenn nichts aufgenommen wurde (zu kurz).
  static Future<Aufnahme?> stoppe() async {
    final m = await _kanal.invokeMapMethod<String, Object?>('stoppe');
    if (m == null) return null;
    return Aufnahme(
        m['pfad']! as String, Duration(milliseconds: m['ms']! as int));
  }

  static Future<void> verwirf() => _kanal.invokeMethod<void>('verwirf');

  static Future<bool> spiele(String pfad) async {
    try {
      return await _kanal.invokeMethod<bool>('spiele', {'pfad': pfad}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> halt() async {
    try {
      await _kanal.invokeMethod<void>('halt');
    } on MissingPluginException {
      // nichts zu halten
    }
  }
}
