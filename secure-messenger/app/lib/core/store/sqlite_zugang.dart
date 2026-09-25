// sqlite_zugang.dart — die Plattformweiche fuer SQLite.
//
// ============================================================================
// STAND WEB am 25.09.2026: BITDM LAEUFT IM BROWSER — eingeschraenkt, und was
// fehlt, fehlt mit Absicht oder weil der Browser es nicht hergibt.
//
// GEMESSEN (Chrome headless, `flutter build web`, Seite ueber
// `py -m http.server`): Identitaet anlegen, zwoelf Woerter, App-Passwort
// einrichten, Seite neu laden, mit dem Passwort entsperren; ohne Passwort
// neu laden und mit den zwoelf Woertern wiederherstellen — die Notiz von
// vorher war wieder da. Gegen einen lokalen relay_server.py unter DERSELBEN
// Herkunft (siehe Punkt 2): zwei getrennte Browserprofile, Kontaktanfrage,
// Annehmen, Nachricht von einem zum anderen, Double Ratchet Ende-zu-Ende. In
// IndexedDB lagen danach 200 KB Datenbankbloecke ohne "SQLite format 3",
// ohne "CREATE TABLE", ohne ein einziges lesbares Wort.
//
// Die vier Brocken vom 30.07.2026 und was aus ihnen wurde:
//
// 1. sqlite3mc.wasm liegt in web/ (Tag sqlite3-3.5.0, sha256 3430d5f6...,
//    derselbe Wert wie in package:sqlite3/src/hook/asset_hashes.dart:63).
//    DAS ALLEIN REICHTE NICHT: geoeffnet werden muss ueber die VFS-Schicht
//    "multipleciphers-<name>", sonst scheitert `PRAGMA key` — siehe
//    `_vfsMitVerschluesselung` in sqlite_zugang_web.dart. Bis dahin endete im
//    Browser jedes "Identitaet erstellen" in einer DatabaseUnlockException.
//
// 2. relay_client.dart spricht jetzt ueber die Weiche net/netz_zugang.dart:
//    dart:io auf dem Geraet, WebSocket und fetch des Browsers im Web. Dabei
//    kam ein zweiter Fehler heraus, den kein Uebersetzer meldet:
//    `nextInt(1 << 32)` ist unter dart2js `nextInt(0)` und warf bei JEDER
//    Nachricht (Begruendung an der Stelle in relay_client.dart).
//    HARTE GRENZE, NICHT IM CODE LOESBAR: relay_server.py schickt keine
//    CORS-Kopfzeilen. Eine Web-Fassung unter einer anderen Herkunft als der
//    Relay (etwa localhost gegen relay.bitdm.net) kommt ueber die WebSocket
//    zwar hinein, aber `fetch` fuer Anmeldung und Schluesselbuendel verweigert
//    der Browser — die App zeigt dann dauerhaft "keine Verbindung". Abhilfe
//    ist eine Entscheidung ueber die AUSLIEFERUNG: Web-Fassung unter derselben
//    Herkunft wie der Relay ausliefern (`--dart-define=BITDM_RELAY=...` auf
//    einen Pfad dort), oder CORS am Relay fuer genau diese Herkunft.
//
// 3. path_provider: im Browser gar nicht mehr aufgerufen (main.dart), der
//    Datenbankpfad ist dort ein Name in IndexedDB. Die Fachdatei der
//    App-Sperre liegt in localStorage (core/lock/fach_ablage.dart,
//    core/browser/browser_zugang_web.dart).
//
// 4. Plattformkanaele: die Aufrufer fangen MissingPluginException bereits
//    ab (fenster, empfang, sprache, krypto, dateien); Nahfunk wird im
//    Browser gar nicht erst angelegt. Was im Browser NICHT geht und
//    deshalb dort ausgeblendet oder mit einem Satz beantwortet wird:
//    Nahfunk (Web Bluetooth kennt kein Werben und kein Lauschen),
//    Dateianhaenge (der ganze Anhang-Weg ist an dart:io-Dateien gebaut),
//    Sprachnachrichten, Screenshot-Schutz, Geraetesperre/Biometrie und
//    Hardware-Stick als Faktor, Hintergrundempfang und UnifiedPush.
//
// VERSCHLUESSELUNG IM RUHEZUSTAND, bewusst entschieden: die Datenbank ist in
// IndexedDB mit sqlite3mc (ChaCha20-Poly1305) verschluesselt, ihr Schluessel
// kommt aus der Entropie. Die Entropie liegt im Browser OHNE App-Passwort nur
// im Arbeitsspeicher und ueberlebt das Neuladen nicht — flutter_secure_storage
// legte sie dort samt AES-Schluessel nebeneinander in localStorage ab, und das
// waere Verschluesselung nur dem Namen nach (Begruendung in main.dart bei
// `basis:`). Die Oberflaeche sagt das dauerhaft an. MIT App-Passwort liegt die
// Entropie in einem Argon2id-Fach und alles bleibt ueber den Neustart
// erhalten. Klartext wird im Browser an keiner Stelle abgelegt.
//
// HALTBARKEIT: IndexedDbFileSystem schreibt asynchron nach (siehe
// sqlite_zugang_web.dart bei writeAutomatically). Ein bestaetigtes COMMIT kann
// einen sofort geschlossenen Tab also verlieren — auf dem Geraet nicht.
//
// dart:io im Ganzen: Die Dateien, die dart:io noch importieren, uebersetzen
// fuer Web mit (dart2js hat einen io_patch) und werfen erst beim Aufruf. Die
// verbliebenen Aufrufe liegen alle auf Wegen, die im Browser gesperrt sind
// (Anhaenge, Sprachnachrichten, Geraetefach) oder hinter `kIsWeb` stehen
// (Sicherung als Download statt Datei, Loeschen der Anhaenge beim Wipe).
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
