// lager_process.dart — startet den echten blob_server.py fuer Tests.
//
// Derselbe Grund wie bei relay_process.dart: kein Nachbau. Zwischen dem Relay
// und dem Lager liegt ein geteiltes Geheimnis und ein HMAC ueber
// "kennung|groesse|ablauf". Das rechnen zwei Programme in zwei Sprachen aus,
// und weicht das Format um ein Zeichen ab, laeuft alles andere weiter — nur
// die Uploads scheitern, mit 403 und ohne Hinweis worauf.
//
// Ein Nachbau des Lagers in Dart wuerde genau diese Stelle ueberspringen.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Lager {
  Lager._(this.process, this.port, this.verzeichnis, this._vorbau);

  final Process process;

  /// Der Port, auf dem blob_server.py selbst lauscht.
  final int port;

  final Directory verzeichnis;

  /// DAS NGINX-ERSATZSTUECK.
  ///
  /// Im Betrieb liegt vor blob_server.py ein nginx, und der teilt die Wege
  /// auf:
  ///
  ///   PUT    /ablegen/<kennung>     -> an den Dienst
  ///   DELETE /wegwerfen/<kennung>   -> an den Dienst
  ///   GET    /blob/<kennung>        -> von nginx selbst, direkt von der Platte
  ///
  /// Der Dienst kennt den GET-Weg GAR NICHT — das ist Absicht und steht so in
  /// blob_server.py: ein 3-GB-Download durch Python zu schleifen kostet
  /// Speicher und einen Prozess, der eine Viertelstunde beschaeftigt ist.
  ///
  /// Ohne dieses Stueck hier laeuft der Test gegen einen Dienst, der auf
  /// jedes GET mit 404 antwortet — genau so ist er am 25.07.2026 zuerst
  /// gescheitert. Das Ersatzstueck macht dasselbe wie nginx, inklusive
  /// Bereichs-Anfragen.
  final HttpServer _vorbau;

  /// Die Adresse, die der Client benutzt — also die des Vorbaus.
  Uri get uri => Uri.parse('http://127.0.0.1:${_vorbau.port}');

  /// Dasselbe Geheimnis bekommt der Relay ueber BITDM_BLOB_SECRET. Nur ein
  /// Testwert; auf den Servern steht er in /etc/bitdm/blob.secret.
  static const geheimnis = 'testgeheimnis-testgeheimnis-testgeheimnis-48z';

  /// Gibt null zurueck, wenn Python oder die Abhaengigkeiten fehlen — der
  /// Aufrufer soll das laut sagen, statt stillschweigend nichts zu pruefen.
  static Future<Lager?> starten() async {
    final serverDir = Directory('../server').absolute.path.replaceAll('\\', '/');
    if (!File('$serverDir/blob_server.py').existsSync()) return null;

    final tmp = Directory.systemTemp.createTempSync('bitdm_lager');
    final port = await _freierPort();

    final Process p;
    try {
      p = await Process.start(
        'py',
        [
          '-3', '-m', 'uvicorn', 'blob_server:app',
          '--app-dir', serverDir,
          '--host', '127.0.0.1',
          '--port', '$port',
          '--log-level', 'warning',
        ],
        environment: {
          'BITDM_BLOB_DIR': tmp.path,
          'BITDM_BLOB_SECRET': geheimnis,
          // Auf einer Testmaschine sind keine 50 GB frei zu verlangen.
          'BITDM_BLOB_MIN_FREE': '0',
        },
      );
    } on ProcessException {
      tmp.deleteSync(recursive: true);
      return null;
    }

    final meldungen = <String>[];
    p.stdout.transform(utf8.decoder).listen(meldungen.add);
    p.stderr.transform(utf8.decoder).listen(meldungen.add);

    final vorbau = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final lager = Lager._(p, port, tmp, vorbau);
    lager._bedieneVorbau();

    if (await lager._warteAufBereitschaft()) return lager;

    await lager.beenden();
    // ignore: avoid_print
    print('Lager startete nicht:\n${meldungen.join()}');
    return null;
  }

  /// Teilt die Wege auf, so wie nginx es tut.
  void _bedieneVorbau() {
    final durchreiche = HttpClient();
    _vorbau.listen((a) async {
      final teile = a.uri.pathSegments;
      final erstes = teile.isEmpty ? '' : teile.first;

      // GET /blob/<kennung> — direkt von der Platte, mit Bereichs-Anfragen.
      if (a.method == 'GET' && erstes == 'blob' && teile.length == 2) {
        final datei =
            File('${verzeichnis.path}${Platform.pathSeparator}${teile[1]}');
        if (!datei.existsSync()) {
          a.response.statusCode = 404;
        } else {
          final bytes = await datei.readAsBytes();
          final bereich = a.headers.value(HttpHeaders.rangeHeader);
          var ab = 0;
          if (bereich != null) {
            ab = int.parse(
                RegExp(r'bytes=(\d+)-').firstMatch(bereich)!.group(1)!);
            a.response.statusCode = 206;
          }
          a.response.add(Uint8List.sublistView(bytes, ab));
        }
        await a.response.close();
        return;
      }

      // Alles andere an den Dienst weiterreichen. /health bleibt hier drin,
      // damit der Test die Zahl der Bloecke abfragen kann — im Betrieb laesst
      // nginx ihn NICHT durch, weil er verriete, wie viel gerade unterwegs
      // ist.
      final weiter = await durchreiche.openUrl(
          a.method, Uri.parse('http://127.0.0.1:$port${a.uri.path}'));
      a.headers.forEach((name, werte) {
        if (name.toLowerCase() == 'host') return;
        for (final w in werte) {
          weiter.headers.add(name, w);
        }
      });
      await weiter.addStream(a);
      final antwort = await weiter.close();
      a.response.statusCode = antwort.statusCode;
      await antwort.pipe(a.response);
    });
  }

  /// Wie viele Bloecke gerade liegen. Ueber /health, den nginx im Betrieb
  /// nicht durchlaesst — hier ist kein nginx davor.
  Future<int> anzahlBloecke() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri.replace(path: '/health'));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      return (jsonDecode(text) as Map)['dateien'] as int;
    } finally {
      client.close();
    }
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
    await _vorbau.close(force: true);
    process.kill();
    await process.exitCode
        .timeout(const Duration(seconds: 10), onTimeout: () => -1);
    try {
      verzeichnis.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  }
}
