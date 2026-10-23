// relay_process.dart — startet den echten relay_server.py fuer Tests.
//
// Kein Nachbau. Die Projektgeschichte zeigt, warum das noetig ist: Relay und
// App hatten je einen Test gegen einen Nachbau der Gegenseite, beide gruen,
// waehrend der Relay 47 % aller gueltigen Signaturen ablehnte.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'python_befehl.dart';

class Relay {
  Relay._(this.process, this.port, this.datenverzeichnis);

  final Process process;
  final int port;
  final Directory datenverzeichnis;

  Uri get uri => Uri.parse('http://127.0.0.1:$port');

  /// Was jeder Test-Relay anders hat als der ausgelieferte.
  ///
  /// EIN GROSSER EIMER FUER DIE HERKUNFTSBREMSE. Im Test teilen sich alle
  /// simulierten Nutzer einer Datei die Herkunft 127.0.0.1 und damit je
  /// Familie einen Eimer (relay_server.py, herkunft_ok); im Betrieb hat jeder
  /// Nutzer seine eigene. Mit den ausgelieferten 120 Marken und 2 je Sekunde
  /// blieben am 18.10.2026 zwei_geraete_test.dart noch 7 Marken bei /prekey
  /// und /geraeteliste (174 Abrufe in 31 s), real_core_test.dart und
  /// nachrichten_funktionen_test.dart noch 9 bei /register (25 und 28
  /// Anmeldungen zu je 5). Der naechste Fall waere mit 429 rot geworden — ein
  /// Fehler der Testanordnung, nicht der App. Keine Datei brauchte mehr als
  /// 174 Marken je Familie; 5000 reichen auch ohne Nachfuellen.
  ///
  /// Die Bremse selbst prueft test_relay.py mit den ausgelieferten Werten.
  /// Ein App-Test, der sie am echten Relay braucht, setzt BITDM_RATE_BURST
  /// ueber [umgebung] zurueck.
  ///
  /// DER NAME DES TEST-RELAYS (Audit KR-2, seit 23.10.2026): mit ihm nennt die
  /// Challenge 127.0.0.1, und jeder Test hier meldet sich in der neuen Form
  /// mit Kontext an - Registrierung, WebSocket, Geraeteliste, mehrere
  /// Geraete. Die alte Form der App 2.0.0 prueft test_relay.py; ein App-Test,
  /// der sie am echten Relay braucht, setzt BITDM_RELAY_NAMEN ueber
  /// [umgebung] auf ''.
  ///
  /// DERSELBE GRUND FUER DIE NEUEN ADRESSEN (Audit SV-3, seit 23.10.2026):
  /// der Relay nimmt je Herkunft nur 100 neue Adressen am Tag an, und hier
  /// kommen alle Nutzer einer Datei von 127.0.0.1. test_relay.py prueft den
  /// Eimer mit kleinen Werten.
  static const _testvorgaben = {
    'BITDM_RATE_BURST': '5000',
    'BITDM_RELAY_NAMEN': '127.0.0.1',
    'BITDM_NEUE_ADRESSEN': '5000',
  };

  /// Startet den Relay. Gibt null zurueck, wenn Python oder die
  /// Abhaengigkeiten fehlen — der Aufrufer soll das laut sagen, statt
  /// stillschweigend nichts zu pruefen.
  ///
  /// [blobGeheimnis] setzt BITDM_BLOB_SECRET. Ohne das lehnt der Relay jede
  /// Marken-Anfrage mit "Zwischenlager nicht eingerichtet" ab — richtig so,
  /// aber fuer einen Anhang-Test muss es dastehen.
  ///
  /// [umgebung] reicht weitere Umgebungsvariablen durch und geht vor
  /// [_testvorgaben]. Gebraucht fuer BITDM_GERAETE_MAX: die Obergrenze steht
  /// sonst bei 5, und ein Test, der sie erreicht, muesste sechs vollstaendige
  /// Clients aufsetzen — sechs Datenbanken, sechs Identitaeten, sechs
  /// Anmeldungen fuer eine Zahl, die der Betreiber ohnehin per
  /// Umgebungsvariable setzt (relay_server.py:186).
  static Future<Relay?> starten({
    String? blobGeheimnis,
    Map<String, String>? umgebung,
  }) async {
    final serverDir = Directory('../server').absolute.path.replaceAll('\\', '/');
    if (!Directory(serverDir).existsSync()) return null;

    final tmp = Directory.systemTemp.createTempSync('bitdm_relay');
    final port = await _freierPort();

    final Process p;
    try {
      p = await startePython(
        [
          '-m', 'uvicorn', 'relay_server:app',
          '--app-dir', serverDir,
          '--host', '127.0.0.1',
          '--port', '$port',
          '--log-level', 'warning',
        ],
        environment: {
          'BITDM_DB': '${tmp.path}/relay.db',
          ..._testvorgaben,
          if (blobGeheimnis != null) 'BITDM_BLOB_SECRET': blobGeheimnis,
          ...?umgebung,
        },
      );
    } on ProcessException {
      tmp.deleteSync(recursive: true);
      return null;
    }

    final meldungen = <String>[];
    p.stdout.transform(utf8.decoder).listen(meldungen.add);
    p.stderr.transform(utf8.decoder).listen(meldungen.add);

    final relay = Relay._(p, port, tmp);
    if (await relay._warteAufBereitschaft()) return relay;

    await relay.beenden();
    // ignore: avoid_print
    print('Relay startete nicht:\n${meldungen.join()}');
    return null;
  }

  Future<bool> _warteAufBereitschaft() async {
    // MIT FRIST JE ANFRAGE. Ohne sie wartet ein `await req.close()` auf einen
    // Port, der annimmt, aber nie antwortet, beliebig lange — die 30 s unten
    // pruefen nur ZWISCHEN den Versuchen, und der Test hing dann bis zu
    // seinem eigenen Zeitlimit (Pruefung vom 14.10.2026, N4).
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final frist = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(frist)) {
        try {
          final req = await client.getUrl(uri.replace(path: '/health'));
          final resp = await req.close().timeout(const Duration(seconds: 5));
          await resp.drain<void>();
          if (resp.statusCode == 200) return true;
        } on SocketException {
          // noch nicht oben
        } on HttpException {
          // noch nicht oben
        } on TimeoutException {
          // nimmt an, antwortet aber noch nicht
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return false;
    } finally {
      client.close();
    }
  }

  static Future<int> _freierPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<void> beenden() async {
    process.kill();
    await process.exitCode
        .timeout(const Duration(seconds: 10), onTimeout: () => -1);
    try {
      datenverzeichnis.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  }
}
