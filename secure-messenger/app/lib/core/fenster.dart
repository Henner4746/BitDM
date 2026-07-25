// fenster.dart — die Screenshot-Sperre.
//
// Duenne Dart-Seite zum Kanal in MainActivity.kt. Die Begruendung steht dort.
//
// WARUM DAS NICHT IM KERN LIEGT: der Kern ist reines Dart und laeuft in Tests
// ohne Flutter-Bindung. Ein Plattform-Kanal tut das nicht. Die Einstellung
// gehoert in den Kern (sie ist Teil dessen, was BitDM verspricht), das
// Ausfuehren gehoert hierher.

import 'package:flutter/services.dart';

class Fenster {
  static const _kanal = MethodChannel('bitdm/fenster');

  /// Setzt oder loest die Screenshot-Sperre.
  ///
  /// Wirft nie. Auf einer Plattform ohne diesen Kanal — im Test, auf dem
  /// Rechner — passiert schlicht nichts. Eine Ausnahme hier wuerde die
  /// Oberflaeche stoppen, obwohl es um eine Einstellung geht, die auf einem
  /// Rechner ohnehin bedeutungslos ist.
  ///
  /// Rueckgabe: ob es tatsaechlich gesetzt wurde. Die Oberflaeche kann damit
  /// ehrlich bleiben, statt einen Haken zu zeigen, hinter dem nichts steht.
  static Future<bool> screenshotSperre(bool an) async {
    try {
      final ok = await _kanal
          .invokeMethod<bool>('setzeScreenshotSperre', {'an': an});
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
