// libsignal_ohne_eval_test.dart — haelt web/libsignal_ohne_eval.js und den
// Lader von flutter_rust_bridge zusammen.
//
// Die Web-App laedt libsignal als WASM. flutter_rust_bridge macht die
// Anbindung dabei mit `new Function("window.wasm_bindgen = wasm_bindgen")`
// global, und die CSP von bitdm.net/app/ verbietet eval. Das Skript
// web/libsignal_ohne_eval.js erledigt genau diesen einen Text ohne eval
// (Begruendung dort). Es wirkt nur, solange der Text Zeichen fuer Zeichen
// derselbe ist und kein weiterer eval-Weg dazukommt. Beides prueft dieser
// Test an den Quellen der Pakete, die dieser Bau wirklich benutzt — nicht an
// einer Abschrift. Am 16.10.2026 blieb die Web-App ohne das Skript beim
// Anlegen der Identitaet stehen; im Browser faellt so etwas erst auf, wenn es
// jemand oeffnet.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Der Ordner `lib/` eines Pakets, so wie dieser Bau es aufloest.
Directory paketLib(String name) {
  final config = File('.dart_tool/package_config.json').absolute;
  final pakete = (jsonDecode(config.readAsStringSync())
          as Map<String, dynamic>)['packages'] as List<dynamic>;
  final eintrag = pakete.cast<Map<String, dynamic>>().singleWhere(
      (p) => p['name'] == name,
      orElse: () => throw StateError('$name fehlt in package_config.json'));
  var wurzel = eintrag['rootUri'] as String;
  if (!wurzel.endsWith('/')) wurzel = '$wurzel/';
  final lib = config.uri
      .resolve(wurzel)
      .resolve(eintrag['packageUri'] as String? ?? 'lib/');
  return Directory.fromUri(lib);
}

String lies(Directory ordner, String pfad) =>
    File('${ordner.path}${Platform.pathSeparator}$pfad').readAsStringSync();

void main() {
  const erwartet = 'window.wasm_bindgen = wasm_bindgen';

  group('flutter_rust_bridge laedt die Anbindung so, wie das Skript es erwartet',
      () {
    late Directory frb;
    setUpAll(() => frb = paketLib('flutter_rust_bridge'));

    test('mit genau diesem Text', () {
      // Mit dem Standardnamen ergibt das Muster den Text in `erwartet`.
      expect(lies(frb, 'src/wasm_module/_web.dart'),
          contains(r"jsEval('window.$wasmBindgenName = $wasmBindgenName')"));
      expect(lies(frb, 'src/loader/_common.dart'),
          contains("this.wasmBindgenName = 'wasm_bindgen'"));
    });

    test('und libsignal benutzt den Standardnamen', () {
      final erzeugt = lies(paketLib('libsignal'), 'src/rust/frb_generated.dart');
      final start = erzeugt.indexOf('kDefaultExternalLibraryLoaderConfig =');
      expect(start, isNonNegative);
      final ende = erzeugt.indexOf(');', start);
      final name = RegExp(r"wasmBindgenName:\s*'([^']*)'")
          .firstMatch(erzeugt.substring(start, ende))
          ?.group(1);
      // Kein eigener Eintrag heisst: der Standard aus dem Test darueber.
      expect(name ?? 'wasm_bindgen', 'wasm_bindgen',
          reason: 'libsignal setzt einen eigenen Namen; das Skript faengt '
              'dann den falschen Text ab');
    });

    test('und eval steht im Dart-Teil nur an dieser einen Stelle', () {
      final aufrufe = <String>[];
      for (final f in frb.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        final n = RegExp(r'\bjsEval\(').allMatches(text).length;
        if (n > 0) aufrufe.add('${f.uri.pathSegments.last}: $n');
      }
      // Die Definition in platform_utils/_web.dart und der eine Aufruf im
      // Lader. Ein dritter Treffer heisst: ein neuer eval-Weg, den das Skript
      // nicht kennt.
      expect(aufrufe..sort(), ['_web.dart: 1', '_web.dart: 1'],
          reason: 'neue eval-Stelle in flutter_rust_bridge: $aufrufe');
    });
  });

  test('das Skript faengt genau diesen Text ab, und nur ihn', () {
    final skript = File('web/libsignal_ohne_eval.js').readAsStringSync();
    expect(skript, contains("var ERWARTET = '$erwartet';"));
    expect(skript, isNot(contains('eval(')),
        reason: 'das Skript selbst darf nichts auswerten');
  });

  test('index.html laedt es vor flutter_bootstrap.js, und zwar synchron', () {
    final html = File('web/index.html').readAsStringSync();
    final skript =
        RegExp(r'<script src="libsignal_ohne_eval\.js"([^>]*)>').firstMatch(html);
    expect(skript, isNotNull, reason: 'libsignal_ohne_eval.js fehlt');
    expect(skript!.group(1), isNot(matches(RegExp(r'\b(async|defer)\b'))),
        reason: 'mit async/defer liefe es womoeglich erst nach dem Lader');
    // Das Skript-Element, nicht die Erwaehnung im Kommentar davor.
    expect(skript.start,
        lessThan(html.indexOf('<script src="flutter_bootstrap.js"')));
  });
}
