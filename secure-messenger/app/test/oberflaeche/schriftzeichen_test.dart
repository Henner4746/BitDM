// schriftzeichen_test.dart — bringt die App die Glyphen fuer ihre eigenen
// Sonderzeichen mit, und passt web/fontfallback/ zur Flutter-Engine?
//
// WARUM. Ein Zeichen, das der Schrift eines Textes fehlt, holt die
// Flutter-Engine im Browser zur Laufzeit nach (bei uns aus web/fontfallback/).
// Fehlt die Datei dort, versucht sie es bei JEDEM neuen Layout wieder — am
// 16.10.2026 im offenen Chat alle zwei Sekunden eine 404, ausgeloest von ✓ und
// ◷ am Zustellstatus. Auf dem Telefon faellt das nie auf, weil das System die
// Zeichen hat. Dieser Test sieht es ohne Browser.
//
// ZWEI STUFEN. Die erste laeuft immer (auch in der CI): jedes Zeichen jenseits
// von Latin muss in [symbolSchriften] stecken. Die zweite braucht die
// Web-Engine dieser Flutter-Fassung (liegt nach einem Web-Bau im Flutter-Cache)
// und rechnet fuer alle uebrigen Zeichen nach, welche Datei die Engine holen
// wuerde — die muss in web/fontfallback/ liegen.
//
// Was er NICHT abdeckt: Text, den Kontakte schicken. Der kann jedes Zeichen
// enthalten; siehe web/fontfallback/README.md.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bitdm/themen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Zeichen, die bewusst ohne eingebettete Glyphe bleiben — mit Grund.
const _ohneGlyphe = <int, String>{
  // Die Schnellreaktionen sollen bunt sein, aus der Emoji-Schrift des
  // Systems. Eine Ersatzschrift kaeme VOR ihr und machte sie schwarz-weiss.
  // Im Browser fehlen sie noch (Noto Color Emoji ist nicht gehostet).
  0x1F44D: 'Reaktion 👍', 0x2764: 'Reaktion ❤', 0xFE0F: 'Emoji-Darstellung',
  0x1F602: 'Reaktion 😂', 0x1F62E: 'Reaktion 😮', 0x1F622: 'Reaktion 😢',
  0x1F64F: 'Reaktion 🙏',
  // Steht nur in den CJK-Schriften der Engine. Im Browser noch offen.
  0x2592: 'Spoiler-Platzhalter ▒',
  0x30C4: '/shrug ¯\\_(ツ)_/¯',
};

/// Die latin-Untermenge der Roboto (unicode-range bei Google Fonts). Diese
/// Zeichen haben Chivo Mono und Doto selbst; Text in der Systemschrift holt
/// sie im Browser aus der gehosteten Noto Sans Symbols (Stufe zwei prueft das).
bool _inLatin(int z) =>
    z <= 0xFF ||
    (z >= 0x2000 && z <= 0x206F) ||
    const {
      0x131, 0x152, 0x153, 0x2BB, 0x2BC, 0x2C6, 0x2DA, 0x2DC, 0x304, 0x308, //
      0x329, 0x20AC, 0x2122, 0x2191, 0x2193, 0x2212, 0x2215, 0xFEFF, 0xFFFD,
    }.contains(z);

String _u(int z) => 'U+${z.toRadixString(16).toUpperCase().padLeft(4, '0')} ${String.fromCharCode(z)}';

void main() {
  final schriften = _schriftenAusPubspec();
  final ersatz = <int>{
    for (final familie in symbolSchriften)
      for (final datei in schriften[familie] ?? const <String>[])
        ...glyphenDerSchrift(File(datei).readAsBytesSync()),
  };
  final zeichen = zeichenDerOberflaeche(Directory('lib'));

  test('symbolSchriften stehen in der pubspec', () {
    expect(schriften.keys, containsAll(symbolSchriften));
  });

  test('JEDES SONDERZEICHEN JENSEITS VON LATIN STECKT IN DEN ERSATZSCHRIFTEN', () {
    final fehlend = [
      for (final MapEntry(key: z, value: orte) in zeichen.entries)
        if (!_inLatin(z) && !ersatz.contains(z) && !_ohneGlyphe.containsKey(z))
          '${_u(z)}  ${orte.take(3).join(', ')}',
    ];
    expect(fehlend, isEmpty,
        reason: 'Im Browser holt die Engine diese Zeichen zur Laufzeit nach (und bei '
            'fehlender Datei immer wieder). In tool/schrift/untermenge.py aufnehmen.');
  });

  test('die Ausnahmen werden noch gebraucht', () {
    final ueberfluessig = [
      for (final z in _ohneGlyphe.keys)
        if (!zeichen.containsKey(z) || ersatz.contains(z)) _ohneGlyphe[z],
    ];
    expect(ueberfluessig, isEmpty);
  });

  final engine = _engineOrdner();
  group('im Browser', skip: engine == null ? 'Flutter-Web-Engine nicht gefunden (vorher einmal flutter build web)' : false, () {
    late final _Engine e;
    setUpAll(() => e = _Engine(engine!));

    test('Roboto liegt unter dem Pfad, den die Engine bei jedem Start laedt', () {
      expect(File('web/fontfallback/${e.roboto}').existsSync(), isTrue,
          reason: 'Flutter will ${e.roboto}, web/fontfallback/ hat ihn nicht');
    });

    test('jede Datei in web/fontfallback kennt die Engine noch', () {
      final ordner = Directory('web/fontfallback');
      for (final f in ordner.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.woff2')) continue;
        final pfad = f.path.substring(ordner.path.length + 1).replaceAll(r'\', '/');
        expect(pfad == e.roboto || e.urls.contains(pfad), isTrue,
            reason: '$pfad kennt diese Engine nicht mehr — Flutter-Update? '
                'Neuen Pfad holen, siehe web/fontfallback/README.md.');
      }
    });

    test('was die Engine fuer die uebrigen Zeichen holt, liegt in web/fontfallback', () {
      final fehlend = [
        for (final MapEntry(key: z, value: orte) in zeichen.entries)
          if (!ersatz.contains(z) && !_ohneGlyphe.containsKey(z))
            if (e.wahl(z) case final url? when !File('web/fontfallback/$url').existsSync())
              '${_u(z)} -> $url  ${orte.first}',
      ];
      expect(fehlend, isEmpty,
          reason: 'Diese Dateien fragte die Web-Fassung ins Leere an — in einer Schleife.');
    });
  });
}

/// Familie -> Dateien, aus dem fonts-Abschnitt der pubspec.yaml.
Map<String, List<String>> _schriftenAusPubspec() {
  final ergebnis = <String, List<String>>{};
  String? familie;
  for (final zeile in File('pubspec.yaml').readAsLinesSync()) {
    final f = RegExp(r'^\s*- family:\s*(.+?)\s*$').firstMatch(zeile);
    if (f != null) familie = f.group(1);
    final a = RegExp(r'^\s*- asset:\s*(\S+\.[ot]tf)\s*$').firstMatch(zeile);
    if (a != null && familie != null) (ergebnis[familie] ??= []).add(a.group(1)!);
  }
  return ergebnis;
}

/// Wo die Web-Engine liegt: im Flutter, das gerade testet, oder im Submodul.
String? _engineOrdner() {
  final wurzel = Platform.environment['FLUTTER_ROOT'];
  for (final k in [
    if (wurzel != null) '$wurzel/bin/cache/flutter_web_sdk/lib/_engine/engine',
    '.flutter/bin/cache/flutter_web_sdk/lib/_engine/engine',
    '.flutter/engine/src/flutter/lib/web_ui/lib/src/engine',
  ]) {
    if (File('$k/font_fallback_data.dart').existsSync()) return k;
  }
  return null;
}

/// Was die Web-Engine fuer ein fehlendes Zeichen nachladen wuerde: Daten aus
/// font_fallback_data.dart, Auswahl wie FontFallbackManager._selectFont in
/// font_fallbacks.dart (fuer ein einzelnes Zeichen, Sprache nicht zh/ja/ko).
class _Engine {
  _Engine(String ordner) {
    final q = File('$ordner/font_fallback_data.dart').readAsStringSync();
    for (final m in RegExp(r"NotoFont\(\s*'([^']+)',\s*'([^']+)'").allMatches(q)) {
      namen.add(m[1]!);
      urls.add(m[2]!);
    }
    // Die erzeugte Datei schreibt jede Schriftmenge im Klartext dazu, mit dem
    // Index als Tiefzahl: "// #5: 1 font: Symbols 2 3₁₅."
    for (final m in RegExp(r'^\s*// #(\d+): \d+ fonts?: (.*)\.$', multiLine: true).allMatches(q)) {
      mengen[int.parse(m[1]!)] = [for (final t in m[2]!.split(', ')) _tiefzahl(t)];
    }
    // ... und jeden Bereich: "'78L' // 2605         #2039". Ohne # keine Schrift.
    final ab = q.indexOf('const String encodedFontSetRanges');
    for (final m in RegExp(r"//[ \t]*([0-9a-f]+)(?:-([0-9a-f]+))?[ \t]+#(\d+)").allMatches(q, ab)) {
      von.add(int.parse(m[1]!, radix: 16));
      bis.add(int.parse(m[2] ?? m[1]!, radix: 16));
      menge.add(int.parse(m[3]!));
    }
    roboto = RegExp(r"fontFallbackBaseUrl\}(roboto/[^']+\.woff2)")
        .firstMatch(File('$ordner/canvaskit/fonts.dart').readAsStringSync())
        ?.group(1);
    if (urls.length < 100 || mengen.length < 100 || von.length < 1000 || roboto == null) {
      throw StateError('Format der Engine-Daten geaendert — diesen Test anpassen');
    }
  }

  final namen = <String>[];
  final urls = <String>[];
  final mengen = <int, List<int>>{};
  final von = <int>[], bis = <int>[], menge = <int>[];
  late final String? roboto;

  static int _tiefzahl(String t) {
    var wert = 0, stelle = 1;
    for (final r in t.runes.toList().reversed) {
      if (r < 0x2080 || r > 0x2089) break;
      wert += (r - 0x2080) * stelle;
      stelle *= 10;
    }
    return wert;
  }

  String? wahl(int z) {
    var lo = 0, hi = von.length - 1, k = -1;
    while (lo <= hi) {
      final mitte = (lo + hi) ~/ 2;
      if (von[mitte] <= z) {
        k = mitte;
        lo = mitte + 1;
      } else {
        hi = mitte - 1;
      }
    }
    if (k < 0 || z > bis[k]) return null;
    final kandidaten = mengen[menge[k]] ?? const <int>[];
    if (kandidaten.isEmpty) return null;
    // Bei Gleichstand: Noto Sans Symbols, sonst Noto Sans SC, sonst die
    // Schrift mit dem kleinsten Index.
    final symbole = namen.indexOf('Noto Sans Symbols');
    final sc = kandidaten.where((i) => namen[i].startsWith('Noto Sans SC'));
    final beste = kandidaten.length == 1
        ? kandidaten.single
        : kandidaten.contains(symbole)
            ? symbole
            : sc.isNotEmpty
                ? sc.first
                : kandidaten.reduce(math.min);
    return urls[beste];
  }
}

/// Zeichen ab U+00A0, die in String-Literalen stehen, mit Fundorten.
/// Kommentare zaehlen nicht — dort darf alles stehen.
Map<int, List<String>> zeichenDerOberflaeche(Directory lib) {
  final ergebnis = <int, List<String>>{};
  final dateien = lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
  for (final datei in dateien) {
    final name = datei.path.replaceAll(r'\', '/');
    _Leser(datei.readAsStringSync(), (z, zeile) {
      (ergebnis[z] ??= []).add('$name:$zeile');
    }).code();
  }
  return ergebnis;
}

/// Ein kleiner Dart-Lexer: Kommentare (verschachtelt), Literale (roh,
/// dreifach) und Interpolationen, die selbst wieder Literale enthalten.
class _Leser {
  _Leser(this.q, this.melde);
  final String q;
  final void Function(int zeichen, int zeile) melde;
  int i = 0;
  int zeile = 1;

  bool _ab(String s) => q.startsWith(s, i);

  void _vor([int n = 1]) {
    for (var k = 0; k < n && i < q.length; k++) {
      if (q.codeUnitAt(i) == 0x0A) zeile++;
      i++;
    }
  }

  void code({bool interpolation = false}) {
    var tiefe = 0;
    while (i < q.length) {
      if (_ab('//')) {
        while (i < q.length && q.codeUnitAt(i) != 0x0A) {
          i++;
        }
      } else if (_ab('/*')) {
        _blockKommentar();
      } else if (q[i] == '{') {
        tiefe++;
        _vor();
      } else if (q[i] == '}') {
        _vor();
        if (interpolation && tiefe == 0) return;
        tiefe--;
      } else if (q[i] == 'r' && i + 1 < q.length && (q[i + 1] == "'" || q[i + 1] == '"') &&
          (i == 0 || !RegExp(r'[\w$]').hasMatch(q[i - 1]))) {
        _vor();
        _literal(roh: true);
      } else if (q[i] == "'" || q[i] == '"') {
        _literal(roh: false);
      } else {
        _vor();
      }
    }
  }

  void _blockKommentar() {
    var tiefe = 0;
    while (i < q.length) {
      if (_ab('/*')) {
        tiefe++;
        _vor(2);
      } else if (_ab('*/')) {
        tiefe--;
        _vor(2);
        if (tiefe == 0) return;
      } else {
        _vor();
      }
    }
  }

  void _literal({required bool roh}) {
    final ende = _ab(q[i] * 3) ? q[i] * 3 : q[i];
    _vor(ende.length);
    while (i < q.length) {
      if (_ab(ende)) {
        _vor(ende.length);
        return;
      }
      final e = q.codeUnitAt(i);
      if (e == 0x0A && ende.length == 1) return; // kaputtes Literal
      if (!roh && _ab(r'\u{')) {
        final zu = q.indexOf('}', i);
        melde(int.parse(q.substring(i + 3, zu), radix: 16), zeile);
        _vor(zu + 1 - i);
      } else if (!roh && _ab(r'\u')) {
        melde(int.parse(q.substring(i + 2, i + 6), radix: 16), zeile);
        _vor(6);
      } else if (!roh && e == 0x5C) {
        _vor(2);
      } else if (!roh && _ab(r'${')) {
        _vor(2);
        code(interpolation: true);
      } else if (e >= 0xD800 && e < 0xDC00 && i + 1 < q.length) {
        melde(0x10000 + ((e - 0xD800) << 10) + (q.codeUnitAt(i + 1) - 0xDC00), zeile);
        _vor(2);
      } else {
        if (e >= 0xA0) melde(e, zeile);
        _vor();
      }
    }
  }
}

/// Die Zeichen, fuer die eine TrueType-Schrift eine Glyphe hat (cmap-Tabelle,
/// Format 4 und 12 — mehr nutzen Doto, Chivo Mono und Noto nicht).
Set<int> glyphenDerSchrift(Uint8List b) {
  final d = ByteData.sublistView(b);
  int? cmap;
  for (var k = 0; k < d.getUint16(4); k++) {
    final o = 12 + 16 * k;
    if (String.fromCharCodes(b, o, o + 4) == 'cmap') cmap = d.getUint32(o + 8);
  }
  if (cmap == null) throw StateError('keine cmap-Tabelle');
  final ergebnis = <int>{};
  for (var k = 0; k < d.getUint16(cmap + 2); k++) {
    final t = cmap + d.getUint32(cmap + 4 + 8 * k + 4);
    switch (d.getUint16(t)) {
      case 4:
        final seg = d.getUint16(t + 6) ~/ 2;
        for (var j = 0; j < seg; j++) {
          final hoch = d.getUint16(t + 14 + 2 * j);
          final tief = d.getUint16(t + 16 + 2 * seg + 2 * j);
          if (tief != 0xFFFF) ergebnis.addAll([for (var z = tief; z <= hoch; z++) z]);
        }
      case 12:
        for (var j = 0; j < d.getUint32(t + 12); j++) {
          final g = t + 16 + 12 * j;
          ergebnis.addAll([for (var z = d.getUint32(g); z <= d.getUint32(g + 4); z++) z]);
        }
    }
  }
  return ergebnis;
}
