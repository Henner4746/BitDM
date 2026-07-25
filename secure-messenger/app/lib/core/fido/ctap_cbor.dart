// ctap_cbor.dart — CBOR so, wie CTAP2 es verlangt.
//
// WARUM NICHT DIE BIBLIOTHEK
// Zum LESEN ist package:cbor richtig. Zum SCHREIBEN nicht: CTAP2 verlangt
// "canonical CBOR", und dazu gehoert eine feste Reihenfolge der
// Schluessel in jedem Objekt. Die Bibliothek schreibt in Einfuegereihenfolge
// und hat keinen kanonischen Modus.
//
// Das ist kein Feinschliff. Der Stick rechnet ueber die gesendeten Bytes einen
// Pruefwert und vergleicht ihn mit dem, den wir mitschicken. Steht auch nur ein
// Schluessel an der falschen Stelle, weicht der Pruefwert ab, und der Stick
// lehnt ab — mit einer Fehlermeldung, die auf alles Moegliche hindeutet, nur
// nicht auf die Reihenfolge von CBOR-Schluesseln.
//
// DIE SORTIERREGEL AUS DER CTAP2-SPEZIFIKATION
//   1. Unterschiedliche Haupttypen: der niedrigere zuerst.
//      Praktisch heisst das: positive Zahlen VOR negativen. Bei einem
//      COSE-Schluessel mit den Feldern 1, 3, -1, -2, -3 ist die richtige
//      Reihenfolge also 1, 3, -1, -2, -3 — nicht -3, -2, -1, 1, 3, wie man
//      beim Sortieren nach Zahlenwert erwarten wuerde. Genau hier liegt die
//      Falle.
//   2. Bei gleichem Haupttyp: der kuerzere zuerst, sonst byteweise.
//
// Geschrieben wird nur, was CTAP2 wirklich braucht: ganze Zahlen, Bytefolgen,
// Zeichenketten, Listen, Objekte und Wahrheitswerte. Kein Gleitkomma, keine
// Tags, keine unbestimmten Laengen — was hier fehlt, kommt in CTAP2 nicht vor.

import 'dart:convert';
import 'dart:typed_data';

class CtapCbor {
  /// Kodiert kanonisch.
  static Uint8List kodiere(Object? wert) {
    final aus = BytesBuilder();
    _schreibe(aus, wert);
    return aus.toBytes();
  }

  /// EINE REGEL, DIE MAN KENNEN MUSS: nur Uint8List wird zur Bytefolge,
  /// jede andere Liste zu einer CBOR-Liste.
  ///
  /// Eine Unterscheidung nach Inhalt gibt es nicht — in Dart IST eine `List<int>`\r
  /// auch eine `List<Object?>`, beide sind zur Laufzeit dasselbe.
  /// Wer Bytes meint, muss Uint8List uebergeben. Sonst schickt man dem Stick
  /// eine Liste von Zahlen, wo er eine Bytefolge erwartet, und bekommt eine
  /// Ablehnung ohne Hinweis.
  static void _schreibe(BytesBuilder aus, Object? wert) {
    if (wert is int) {
      if (wert >= 0) {
        _kopf(aus, 0, wert);
      } else {
        // Negative Zahlen werden als -(n+1) gespeichert.
        _kopf(aus, 1, -wert - 1);
      }
    } else if (wert is Uint8List) {
      _kopf(aus, 2, wert.length);
      aus.add(wert);
    } else if (wert is String) {
      final b = utf8.encode(wert);
      _kopf(aus, 3, b.length);
      aus.add(b);
    } else if (wert is List) {
      _kopf(aus, 4, wert.length);
      for (final e in wert) {
        _schreibe(aus, e);
      }
    } else if (wert is Map) {
      final eintraege = wert.entries.toList()
        ..sort((a, b) => _vergleiche(a.key, b.key));
      _kopf(aus, 5, eintraege.length);
      for (final e in eintraege) {
        _schreibe(aus, e.key);
        _schreibe(aus, e.value);
      }
    } else if (wert is bool) {
      aus.addByte(wert ? 0xF5 : 0xF4);
    } else if (wert == null) {
      aus.addByte(0xF6);
    } else {
      throw ArgumentError('CBOR: ${wert.runtimeType} kommt in CTAP2 nicht vor');
    }
  }

  /// Sortiert zwei Schluessel nach der CTAP2-Regel.
  static int _vergleiche(Object? a, Object? b) {
    final ka = kodiere(a);
    final kb = kodiere(b);

    // Regel 1: unterschiedlicher Haupttyp — der niedrigere zuerst. Der
    // Haupttyp steht in den oberen drei Bit des ersten Bytes.
    final ta = ka[0] >> 5;
    final tb = kb[0] >> 5;
    if (ta != tb) return ta.compareTo(tb);

    // Regel 2: der kuerzere zuerst, sonst byteweise.
    if (ka.length != kb.length) return ka.length.compareTo(kb.length);
    for (var i = 0; i < ka.length; i++) {
      if (ka[i] != kb[i]) return ka[i].compareTo(kb[i]);
    }
    return 0;
  }

  /// Schreibt Haupttyp und Laenge/Wert in der KUERZEST moeglichen Form.
  ///
  /// Auch das gehoert zu "kanonisch": die Zahl 1 muss als ein Byte kodiert
  /// werden, nicht als vier. Die laengere Form waere gueltiges CBOR und ergaebe
  /// denselben Wert — aber andere Bytes, und damit einen anderen Pruefwert.
  static void _kopf(BytesBuilder aus, int typ, int wert) {
    final t = typ << 5;
    if (wert < 24) {
      aus.addByte(t | wert);
    } else if (wert < 0x100) {
      aus..addByte(t | 24)..addByte(wert);
    } else if (wert < 0x10000) {
      aus..addByte(t | 25)..addByte(wert >> 8)..addByte(wert & 0xFF);
    } else if (wert < 0x100000000) {
      aus
        ..addByte(t | 26)
        ..addByte((wert >> 24) & 0xFF)
        ..addByte((wert >> 16) & 0xFF)
        ..addByte((wert >> 8) & 0xFF)
        ..addByte(wert & 0xFF);
    } else {
      aus.addByte(t | 27);
      for (var s = 56; s >= 0; s -= 8) {
        aus.addByte((wert >> s) & 0xFF);
      }
    }
  }
}
