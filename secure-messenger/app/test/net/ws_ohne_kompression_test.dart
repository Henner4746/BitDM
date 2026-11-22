// ws_ohne_kompression_test.dart — keine Kompression auf der WebSocket
// (QA-Bericht vom 18.11.2026, T3-COVER).
//
// Mit permessage-deflate schrumpft eine echte Quittung (die Adresse kam auf
// der Verbindung schon vor) auf rund 20 Byte, die eines Tarnrahmens (56
// zufaellige Zeichen) bleibt bei rund 75. Wer mitliest, trennt beide an der
// Groesse. Zwei Riegel: die App bietet die Kompression nicht an, und der
// Relay nimmt sie nicht an (fuer Browser, die sie immer anbieten).

import 'dart:async';
import 'dart:io';

import 'package:bitdm/core/net/netz_zugang.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/relay_process.dart';

void main() {
  test('DIE APP BIETET KEINE KOMPRESSION AN', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final kopf = Completer<String?>();
    server.listen((req) async {
      kopf.complete(req.headers.value('sec-websocket-extensions'));
      // Der Server WUERDE annehmen (Vorgabe von dart:io) — es kommt also
      // allein auf das Angebot des Clients an.
      final ws = await WebSocketTransformer.upgrade(req);
      await ws.close();
    });
    final leitung =
        await wsOeffnen(Uri.parse('ws://127.0.0.1:${server.port}/ws'));
    addTearDown(leitung.schliesse);
    expect(await kopf.future, isNull,
        reason: 'der Handschlag bot permessage-deflate an');
  });

  group('der echte Relay', () {
    Relay? relay;
    setUpAll(() async => relay = await Relay.starten());
    tearDownAll(() async => relay?.beenden());

    test('NIMMT KEINE KOMPRESSION AN, AUCH WENN JEMAND SIE ANBIETET', () async {
      expect(relay, isNotNull, reason: 'relay_server.py liess sich nicht starten');
      // EIN ROHER HANDSCHLAG, wie ihn ein Browser schickt — mit Angebot.
      // `WebSocket.extensions` von dart:io zeigt die Antwort nicht
      // verlaesslich (gemessen 22.11.2026: leer, obwohl uvicorn ohne den
      // Schalter mit "Sec-WebSocket-Extensions: permessage-deflate" antwortete).
      const zeile = '\r\n';
      final uri = relay!.uri;
      final s = await Socket.connect(uri.host, uri.port);
      addTearDown(s.destroy);
      s.write([
        'GET /ws HTTP/1.1',
        'Host: ${uri.host}:${uri.port}',
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        'Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits',
        '',
        '',
      ].join(zeile));
      final kopf = StringBuffer();
      await for (final teil in s.timeout(const Duration(seconds: 5))) {
        kopf.write(String.fromCharCodes(teil));
        if (kopf.toString().contains('$zeile$zeile')) break;
      }
      final antwort = kopf.toString().split('$zeile$zeile').first.toLowerCase();
      expect(antwort, startsWith('http/1.1 101'),
          reason: 'kein WebSocket-Handschlag: $antwort');
      expect(antwort, isNot(contains('sec-websocket-extensions')),
          reason: 'der Relay hat die Kompression angenommen: $antwort');
    });
  });
}
