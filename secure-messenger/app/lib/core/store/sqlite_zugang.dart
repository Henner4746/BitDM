// sqlite_zugang.dart — die Plattformweiche fuer SQLite.
//
// ============================================================================
// STAND WEB am 30.07.2026: BITDM LAEUFT IM BROWSER NICHT. Was hier steht, ist
// die Datenbankweiche und sonst nichts. `flutter build web --release` endet mit
// 0 — das ist eine Aussage ueber den Uebersetzer, nicht ueber eine startfaehige
// App. Wer weitermacht, muss diese vier Brocken erledigen:
//
// 1. web/sqlite3mc.wasm FEHLT. Gemessen: `find web/ -name "*.wasm"` -> 0
//    Treffer, web/ enthaelt nur favicon.png, icons/, index.html,
//    manifest.json. sqliteVorbereiten() laeuft also im Browser bis
//    `WasmSqlite3.loadFromUrlString('sqlite3mc.wasm')` in
//    sqlite_zugang_web.dart und wirft aus dem catch daneben den StateError mit
//    der 404-Erklaerung. Die Datei wird ABSICHTLICH nicht mitgeliefert: sie
//    ist ein fremdes Binaerpaket aus den GitHub-Releases von
//    simolus3/sqlite3.dart und braucht Henriks ausdrueckliches Ja, bevor sie
//    ins Verzeichnis kommt.
//
// 2. relay_client.dart nutzt dart:io-Netzwerk. Nachgelesen am 30.07.2026 in
//    lib/core/net/relay_client.dart: `WebSocket.connect` in Zeile 197 und
//    `HttpClient()` in Zeile 522 — diese ZWEI Stellen werfen im Browser
//    UnsupportedError. Zeile 137 (`_ws?.readyState == WebSocket.open`) und 485
//    (`ws.readyState != WebSocket.open`) lesen nur die Zustands-KONSTANTE, das
//    wirft nichts; sie fallen mit der Umstellung trotzdem weg, weil es den Typ
//    dart:io-WebSocket dann nicht mehr gibt. Ersatz waere package:web_socket_channel
//    und package:http — beides eine eigene Baustelle, kein Suchen-Ersetzen,
//    weil dart:io-WebSocket Kopfzeilen und Zertifikatspruefung anbietet, die
//    der Browser gar nicht hergibt.
//
// 3. Der Datenbankpfad kommt aus path_provider. Gemessen: `grep -rn
//    path_provider lib/` trifft genau eine Stelle, lib/main.dart:7, benutzt in
//    lib/main.dart:57 (`getApplicationSupportDirectory()`). Das Paket hat keine
//    Web-Umsetzung, der Aufruf endet vor dem ersten Bildaufbau in einer
//    MissingPluginException. lib/app_state.dart braucht dart:io nur fuer den
//    Typ `File` in der Signatur von `anhangSenden` (Zeile 909) — das
//    uebersetzt, aber Anhaenge waehlen kann der Browser damit nicht.
//
// 4. Die Plattformkanaele haben kein Web-Gegenstueck. `grep -rn
//    "MethodChannel(\|EventChannel(" lib/` gibt zehn Zeilen; eine davon ist
//    diese hier, bleiben NEUN Anlagestellen. Dieselbe Ausgabe durch
//    `grep -o "bitdm/[a-z_]*" | sort -u | wc -l` geschickt gibt aber nur ACHT
//    verschiedene Kanal-NAMEN — bitdm/fenster wird zweimal angelegt
//    (lib/core/fenster.dart:13 in Fenster, :42 in FremdeApp). Darunter
//    bitdm/empfang (lib/core/empfang.dart:92 — der EmpfangsDienst) und
//    bitdm/nahfunk plus bitdm/nahfunk_ereignisse (lib/core/nah/funk.dart:166
//    und 168 — der Nahfunk), ausserdem bitdm/krypto, bitdm/dateien,
//    bitdm/usb_hid, bitdm/schluesselfach. Alle antworten im
//    Browser mit MissingPluginException. Nahfunk ist dort ueberhaupt nicht
//    nachbaubar: Web Bluetooth kennt kein Werben und kein Lauschen.
//
// dart:io im Ganzen: `grep -rl "^import 'dart:io'" lib/` findet am 30.07.2026
// 13 Dateien — app_state.dart, core/anhang/anhang_empfang.dart,
// core/anhang/anhang_versand.dart, core/anhang/lager_client.dart,
// core/dateien.dart, core/fake_messenger_core.dart,
// core/lock/geraete_fach.dart, core/lock/vault_store.dart,
// core/messenger_core.dart, core/net/relay_client.dart,
// core/real_messenger_core.dart, core/store/sqlite_zugang_native.dart,
// core/verbindungstest.dart. Nur eine davon ist harmlos:
// sqlite_zugang_native.dart steht hinter dieser Weiche und wird fuer Web nie
// uebersetzt. Bleiben 12 offene.
// ============================================================================
//
// WARUM ES DIESE DATEI GIBT: `package:sqlite3/sqlite3.dart` zieht ueber
// src/ffi/api.dart `dart:ffi` herein, und dart:ffi gibt es im Browser nicht.
// Nachgemessen am 30.07.2026, indem die Weiche unten kurz durch
// `export 'sqlite_zugang_native.dart';` ersetzt wurde: `flutter build web
// --release` brach mit genau 13.904 Ausgabezeilen ab (`wc -l` auf das
// umgeleitete Bauprotokoll), alle aus dieser einen Wurzel — 9x "Dart library
// 'dart:ffi' is not available on this platform.", danach 878x "Type
// 'ffi.Pointer' not found." und 650x "'Pointer' isn't a type." als Folgen.
// dart:io dagegen bricht den Bau NICHT — dart2js hat einen io_patch. dart:io
// ist ein LAUFZEIT-Problem (UnsupportedError), deshalb liegen [absoluterPfad]
// und [journalModus] hier gleich mit dahinter.
//
// WARUM `dart.library.io` UND NICHT `dart.library.ffi`: nachgesehen am
// 30.07.2026 in bin/cache/dart-sdk/lib/libraries.json, nach Aufloesung der
// include-Ketten der Ziele dart2js, dartdevc und wasm_js_compatibility. Beim
// Wasm-Ziel (das ist `flutter build web --wasm`) steht ffi OHNE
// support_conditional_import eingetragen, und "ohne" heisst Standard TRUE — eine
// Weiche auf dart.library.ffi waehlt dort also den ffi-Zweig und bricht wieder.
// io steht bei allen drei Web-Zielen auf false und ist damit der einzige
// Schluessel, der alle drei erwischt. package:cryptography macht in
// lib/src/dart/argon2.dart:23 genau diesen Fehler.
export 'sqlite_zugang_web.dart' if (dart.library.io) 'sqlite_zugang_native.dart';
