// relay_process.dart — startet den echten relay_server.py fuer Tests.
//
// Kein Nachbau. Die Projektgeschichte zeigt, warum das noetig ist: Relay und
// App hatten je einen Test gegen einen Nachbau der Gegenseite, beide gruen,
// waehrend der Relay 47 % aller gueltigen Signaturen ablehnte.

import 'dart:convert';
import 'dart:io';

class Relay {
  Relay._(this.process, this.port, this.datenverzeichnis);

  final Process process;
  final int port;
  final Directory datenverzeichnis;

  Uri get uri => Uri.parse('http://127.0.0.1:$port');

  /// Startet den Relay. Gibt null zurueck, wenn Python oder die
  /// Abhaengigkeiten fehlen — der Aufrufer soll das laut sagen, statt
  /// stillschweigend nichts zu pruefen.
  static Future<Relay?> starten() async {
    final serverDir = Directory('../server').absolute.path.replaceAll('\\', '/');
    if (!Directory(serverDir).existsSync()) return null;

    final tmp = Directory.systemTemp.createTempSync('bitdm_relay');
    final port = await _freierPort();

    final Process p;
    try {
      p = await Process.start(
        'py',
        [
          '-3', '-m', 'uvicorn', 'relay_server:app',
          '--app-dir', serverDir,
          '--host', '127.0.0.1',
          '--port', '$port',
          '--log-level', 'warning',
        ],
        environment: {'BITDM_DB': '${tmp.path}/relay.db'},
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
    final client = HttpClient();
    try {
      final frist = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(frist)) {
        try {
          final req = await client.getUrl(uri.replace(path: '/health'));
          final resp = await req.close();
          await resp.drain<void>();
          if (resp.statusCode == 200) return true;
        } on SocketException {
          // noch nicht oben
        } on HttpException {
          // noch nicht oben
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
