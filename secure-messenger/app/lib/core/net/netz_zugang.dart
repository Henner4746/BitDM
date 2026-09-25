// netz_zugang.dart — die Plattformweiche fuer HTTP und WebSocket zum Relay.
//
// WARUM: RelayClient sprach bis 25.09.2026 direkt dart:io (`WebSocket.connect`
// und `HttpClient()`), und beides wirft im Browser UnsupportedError — der
// Bau laeuft durch (dart2js hat einen io_patch), die App kommt aber nie beim
// Relay an. Die Browser-Fassung nimmt die WebSocket und `fetch` des Browsers
// ueber package:web.
//
// WAS DER BROWSER NICHT HERGIBT, und was deshalb im Web-Zweig fehlt:
//   * eigene Kopfzeilen auf der WebSocket (RelayClient setzt keine — die
//     Kennung steht in der Query, der Besitznachweis im ersten Rahmen);
//   * eine eigene Zertifikatspruefung (RelayClient hatte keine; es galt die
//     des Systems, im Browser gilt die des Browsers);
//   * HTTP zu einer FREMDEN Herkunft ohne CORS-Kopfzeilen. Das ist die harte
//     Grenze: relay_server.py schickt keine (Stand 25.09.2026), also kann eine
//     Web-Fassung, die NICHT unter derselben Herkunft wie der Relay liegt,
//     sich dort nicht anmelden und keine Buendel holen. Die WebSocket selbst
//     ist von CORS nicht betroffen. Abhilfe ist Sache der Auslieferung (Web-
//     Fassung und Relay hinter einer Herkunft, oder CORS am Relay), nicht
//     dieses Codes — siehe sqlite_zugang.dart, Kopf.
//
// dart.library.io und nicht dart.library.js_interop: dieselbe Begruendung wie
// in store/sqlite_zugang.dart — io ist bei allen drei Web-Zielen false.
export 'netz_typen.dart';
export 'netz_zugang_web.dart' if (dart.library.io) 'netz_zugang_native.dart';
