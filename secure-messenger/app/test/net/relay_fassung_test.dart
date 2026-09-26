// relay_fassung_test.dart — liest der Client die neueste App-Fassung aus der
// Anmeldung des Relays?
//
// Ein ECHTER WebSocket-Server auf 127.0.0.1: er schickt die Challenge, nimmt
// die Signatur entgegen (geprueft wird sie hier nicht — das ist nicht die
// Frage) und antwortet mit `auth_result`, mal mit `neueste`, mal ohne (so
// antwortet jeder Relay von vor dem Update-Hinweis).

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late SignalIdentity ich;

  /// Was im `auth_result` zusaetzlich steht.
  var zusatz = <String, Object?>{};

  setUp(() async {
    ich = SignalIdentityBridge.fromDerived(
        await KeyDerivation.fromMnemonic(Bip39.generate()),
        registrationId: SignalIdentityBridge.newRegistrationId());
    zusatz = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode({'type': 'challenge', 'nonce': base64.encode(List.filled(32, 7))}));
      ws.listen((_) {
        ws.add(jsonEncode({'type': 'auth_result', 'ok': true, ...zusatz}));
      });
    });
  });

  tearDown(() async => server.close(force: true));

  Future<(RelayClient, List<RelayEvent>)> verbinde() async {
    final c = RelayClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'), identity: ich);
    final ereignisse = <RelayEvent>[];
    c.events.listen(ereignisse.add);
    await c.connect();
    // Die Ereignisse kommen ueber einen Broadcast-Strom — eine Runde warten.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    addTearDown(c.dispose);
    return (c, ereignisse);
  }

  test('MIT dem Feld: die Fassung steht am Client und kommt als Ereignis', () async {
    zusatz = {'neueste': '1.9.0'};
    final (c, ereignisse) = await verbinde();
    expect(c.neuesteFassung, '1.9.0');
    expect(ereignisse.whereType<RelayNeuesteFassung>().map((e) => e.fassung), ['1.9.0']);
  });

  test('OHNE das Feld (alter Relay): nichts, und die Anmeldung gelingt trotzdem', () async {
    final (c, ereignisse) = await verbinde();
    expect(c.isConnected, isTrue);
    expect(c.neuesteFassung, isNull);
    expect(ereignisse.whereType<RelayNeuesteFassung>(), isEmpty);
  });

  test('Unsinn im Feld gilt als nicht gesagt', () async {
    zusatz = {'neueste': 'Bitte hier klicken: https://boese.example'};
    final (c, ereignisse) = await verbinde();
    expect(c.neuesteFassung, isNull);
    expect(ereignisse.whereType<RelayNeuesteFassung>(), isEmpty);
  });

  test('liesFassung: was durchgeht und was nicht', () {
    expect(RelayClient.liesFassung('1.9.0'), '1.9.0');
    expect(RelayClient.liesFassung(' 1.10.2 '), '1.10.2');
    expect(RelayClient.liesFassung('2.0.0-beta.1'), '2.0.0-beta.1');
    expect(RelayClient.liesFassung(190), isNull);
    expect(RelayClient.liesFassung(null), isNull);
    expect(RelayClient.liesFassung(''), isNull);
    expect(RelayClient.liesFassung('v1.9.0'), isNull);
    expect(RelayClient.liesFassung('1.9.0 <script>'), isNull);
    expect(RelayClient.liesFassung('1.${'9' * 40}'), isNull);
  });
}
