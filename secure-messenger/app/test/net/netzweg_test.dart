// netzweg_test.dart — Verbindungen ueber SOCKS5 (Tor/Orbot).
//
// Ein kleiner SOCKS5-Server im Test spielt den Proxy. Er merkt sich, welchen
// Hostnamen der Client verlangt: kommt dort ein NAME an und keine Adresse,
// hat das Telefon den Namen nicht selbst aufgeloest — kein DNS-Leck.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/netzweg.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/relay_process.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

class ProbeSocks {
  late final ServerSocket server;
  final verlangt = <String>[];

  Future<void> starte() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_bediene);
  }

  int get port => server.port;

  Future<void> _bediene(Socket client) async {
    final puffer = <int>[];
    Socket? ziel;
    var stufe = 0;
    client.listen((d) async {
      if (ziel != null) {
        ziel!.add(d);
        return;
      }
      puffer.addAll(d);
      if (stufe == 0 && puffer.length >= 3) {
        puffer.removeRange(0, 3);
        client.add([5, 0]);
        stufe = 1;
      }
      if (stufe == 1 && puffer.length >= 5 && puffer.length >= 7 + puffer[4]) {
        final n = puffer[4];
        final host = String.fromCharCodes(puffer.sublist(5, 5 + n));
        final port = (puffer[5 + n] << 8) | puffer[6 + n];
        puffer.removeRange(0, 7 + n);
        verlangt.add('$host:$port');
        stufe = 2;
        try {
          ziel = await Socket.connect(host, port, timeout: const Duration(seconds: 10));
          client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
          ziel!.listen(client.add, onDone: client.destroy, onError: (_) => client.destroy());
          if (puffer.isNotEmpty) ziel!.add(puffer);
        } catch (_) {
          client.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
          client.destroy();
        }
      }
    }, onDone: () => ziel?.destroy(), onError: (_) => ziel?.destroy());
  }
}

void main() {
  late ProbeSocks socks;
  setUp(() async {
    socks = ProbeSocks();
    await socks.starte();
    Netzweg.proxy = SocksZiel('127.0.0.1', socks.port);
  });
  tearDown(() async {
    Netzweg.proxy = null;
    await socks.server.close();
  });

  test('HTTP UEBER SOCKS5: der Name geht an den Proxy, nicht an den DNS', () async {
    final echt = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    echt.listen((r) => r.response
      ..write('hallo durch den tunnel')
      ..close());
    addTearDown(echt.close);
    final c = Netzweg.httpClient();
    final antwort = await (await c.getUrl(Uri.parse('http://localhost:${echt.port}/'))).close();
    expect(await antwort.transform(utf8.decoder).join(), 'hallo durch den tunnel');
    expect(socks.verlangt, ['localhost:${echt.port}'],
        reason: 'der Proxy bekam keinen Hostnamen — das Telefon hat selbst aufgeloest');
    c.close();
  });

  test('HTTPS UEBER SOCKS5 mit echtem TLS (bitdm.net)', () async {
    final c = Netzweg.httpClient();
    try {
      final antwort = await (await c.getUrl(Uri.parse('https://bitdm.net/'))).close()
          .timeout(const Duration(seconds: 30));
      expect(antwort.statusCode, 200);
      expect(socks.verlangt, ['bitdm.net:443']);
      await antwort.drain<void>();
    } on SocketException {
      markTestSkipped('kein Netz');
    } finally {
      c.close();
    }
  });

  test('ein abweisender Proxy ist ein klarer Fehler, kein Haengen', () async {
    final c = Netzweg.httpClient();
    await expectLater(
        () async => (await c.getUrl(Uri.parse('http://127.0.0.1:1/'))).close(),
        throwsA(anything));
    c.close();
  });

  test('ohne Proxy ist alles wie vorher', () {
    Netzweg.proxy = null;
    final c = Netzweg.httpClient();
    expect(c, isA<HttpClient>());
    c.close();
  });

  test('DER KERN MIT TOR: Anmeldung und Verbindung zum Relay gehen durch den Proxy', () async {
    Netzweg.proxy = null;
    final relay = await Relay.starten();
    if (relay == null) {
      markTestSkipped('Relay startet nicht');
      return;
    }
    addTearDown(relay.beenden);
    final ordner = Directory.systemTemp.createTempSync('bitdm_tor');
    // Die "Onion-Adresse" ist hier derselbe Relay unter anderem Namen —
    // kommt sie beim Proxy an, nimmt der Kern mit Tor den zweiten Weg.
    final kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}k.db',
      relayUri: relay.uri,
      relayUriTor: Uri.parse('http://localhost:${relay.uri.port}'),
    );
    addTearDown(() async {
      await kern.dispose();
      Netzweg.proxy = null;
    });
    await kern.initialize();
    await kern.createIdentity();
    final p = await kern.getPreferences();
    await kern.setPreferences(p.copyWith(tor: true, torPort: socks.port));
    await kern.connect();
    final online = await kern.connectionStateChanges
        .firstWhere((z) => z == ConnectionState.online)
        .timeout(const Duration(seconds: 20), onTimeout: () => kern.connectionState);
    expect(online, ConnectionState.online, reason: 'ueber den Proxy kam keine Verbindung zustande');
    expect(socks.verlangt.where((v) => v == 'localhost:${relay.uri.port}'), isNotEmpty,
        reason: 'mit Tor ging die Verbindung nicht an die Onion-Adresse');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
