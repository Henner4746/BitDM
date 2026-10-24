// anmeldung_kontext_test.dart - die Anmeldung nennt Zweck, Relay, Adresse und
// Geraet (Audit vom 16.10.2026, KR-2).
//
// Bis 2.0.0 signiert die App das Nonce des Relays roh. Die 32-Byte-Pruefung
// (anmeldung_nonce_test.dart) haelt fremde FORMATE ab, aber nicht die
// weitergereichte Challenge eines anderen Relays: Relay A gibt die 32 Byte
// von Relay B an das Opfer weiter und meldet sich mit der Signatur bei B als
// das Opfer an. In der neuen Form steht der Name, unter dem die App den Relay
// erreicht hat, mit in den Bytes - eine Signatur fuer A gilt bei B nicht.
//
// Zwei Haelften:
//   1. Ein nachgebauter Relay auf 127.0.0.1 schreibt mit, WAS signiert wurde,
//      und prueft die Signatur gegen die ausgeschriebenen Bytes.
//   2. Der ECHTE relay_server.py mit BITDM_ANMELDUNG_PFLICHT=1: er nimmt nur
//      noch die neue Form an. Kommt ein vollstaendiger Nutzer damit online,
//      sprechen App und Relay dieselbe Form - ohne die App-Seite bleibt er
//      draussen.

// DIE FRIST FUER JEDEN TEST DIESER DATEI, der keine eigene hat. Sie bauen
// echte Kerne auf und reden ueber einen Relay; auf dem Windows-Runner der CI
// brauchten solche Tests bis zu 35 s, voreingestellt sind 30 (CI-Laeufe bis
// 24.10.2026). Dieselben 3 Minuten wie bei den Tests, die eine eigene haben.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

/// Die Bytes der neuen Form, ABSICHTLICH ausgeschrieben und nicht ueber
/// _erwartet gebaut - dieselben Zeichen stehen in
/// test_relay.py (test_kr2_die_nachrichten_sind_die_der_app).
Uint8List _erwartet(String host, String adresse, int geraet, List<int> nonce) =>
    Uint8List.fromList([
      ...utf8.encode('BitDM-Relay-Anmeldung-v1\n$host\n$adresse\n$geraet\n'),
      ...nonce,
    ]);

void main() {
  group('was signiert wird', () {
    late HttpServer server;
    late SignalIdentity ich;
    final nonce = List<int>.generate(32, (i) => i + 1);

    /// Was die Challenge zusaetzlich nennt.
    Object? angekuendigt;

    /// Jeder Rahmen, den der Client geschickt hat.
    late List<Map<String, Object?>> vomClient;

    setUp(() async {
      ich = SignalIdentityBridge.fromDerived(
          await KeyDerivation.fromMnemonic(Bip39.generate()),
          registrationId: SignalIdentityBridge.newRegistrationId());
      angekuendigt = null;
      vomClient = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add(jsonEncode({
          'type': 'challenge',
          'nonce': base64.encode(nonce),
          'relay': ?angekuendigt,
        }));
        ws.listen((roh) {
          vomClient
              .add((jsonDecode(roh as String) as Map).cast<String, Object?>());
          ws.add(jsonEncode({'type': 'auth_result', 'ok': true}));
        });
      });
    });

    tearDown(() async => server.close(force: true));

    Future<Map<String, Object?>> melde({int? geraet}) async {
      final c = RelayClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          identity: ich,
          geraeteKennung: geraet,
          handshakeTimeout: const Duration(seconds: 3));
      addTearDown(c.dispose);
      await c.connect();
      expect(c.isConnected, isTrue);
      return vomClient.single;
    }

    bool gilt(Map<String, Object?> antwort, List<int> bytes) =>
        ich.publicKey.verify(
            message: bytes,
            signature: base64.decode(antwort['signature']! as String));

    test('NENNT DER RELAY DEN EIGENEN NAMEN: die neue Form, mit Name', () async {
      angekuendigt = ['relay.bitdm.net', '127.0.0.1'];
      final antwort = await melde();

      expect(antwort['relay'], '127.0.0.1');
      expect(gilt(antwort, _erwartet('127.0.0.1', ich.address, 1, nonce)), isTrue,
          reason: 'Geraet 1 steht ausdruecklich in den Bytes');
      expect(gilt(antwort, nonce), isFalse,
          reason: 'das rohe Nonce darf nicht mehr signiert sein');
    });

    test('mit Geraetekennung steht sie in den Bytes', () async {
      angekuendigt = ['127.0.0.1'];
      final antwort = await melde(geraet: 3);
      expect(gilt(antwort, _erwartet('127.0.0.1', ich.address, 3, nonce)), isTrue);
    });

    test('OHNE Namen (Relay bis 2.0.0): die alte Form, kein Feld', () async {
      final antwort = await melde();
      expect(antwort.containsKey('relay'), isFalse);
      expect(gilt(antwort, nonce), isTrue);
    });

    test('FEHLT DER EIGENE NAME in der Liste: die alte Form statt Aussperren',
        () async {
      // Etwa ein Relay, dem beim Einrichten die Onion-Adresse fehlt. Die neue
      // Form haette er abgelehnt; die alte nimmt er an.
      angekuendigt = ['relay.bitdm.net'];
      final antwort = await melde();
      expect(antwort.containsKey('relay'), isFalse);
      expect(gilt(antwort, nonce), isTrue);
    });

    test('Unsinn im Feld gilt als nicht gesagt', () async {
      angekuendigt = '127.0.0.1';
      final antwort = await melde();
      expect(antwort.containsKey('relay'), isFalse);
      expect(gilt(antwort, nonce), isTrue);
    });

    test('die Bytes sind die des Relays', () {
      expect(RelayClient.anmeldeNachricht('relay.bitdm.net', 'abcd', 1,
              List<int>.generate(32, (i) => i)),
          [
            ...utf8.encode('BitDM-Relay-Anmeldung-v1\nrelay.bitdm.net\nabcd\n1\n'),
            ...List<int>.generate(32, (i) => i),
          ]);
      expect(RelayClient.registrierNachricht('relay.bitdm.net', [1, 2, 3]), [
        ...utf8.encode('BitDM-Relay-Registrierung-v1\nrelay.bitdm.net\n'),
        1, 2, 3,
      ]);
    });
  });

  group('gegen den echten Relay, der nur noch die neue Form annimmt', () {
    Relay? relay;
    late Directory tmp;

    setUpAll(() async => relay = await Relay.starten(umgebung: {
          'BITDM_RELAY_NAMEN': '127.0.0.1',
          'BITDM_ANMELDUNG_PFLICHT': '1',
        }));
    tearDownAll(() async => relay?.beenden());

    setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_kontext'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows gibt Handles verzoegert frei.
      }
    });

    test('REGISTRIERUNG UND ANMELDUNG GEHEN DURCH', () async {
      if (relay == null) {
        markTestSkipped('relay_server.py liess sich nicht starten '
            '(BITDM_PYTHON auf ein Python mit requirements.txt setzen)');
        return;
      }
      final alice = Nutzer('alice', '${tmp.path}/alice.db', relay!.uri);
      addTearDown(alice.aufraeumen);
      await alice.starten();
      await alice.core.createIdentity();
      await alice.core.connect();
      expect(
          await Nutzer.warteBis(
              () => alice.core.connectionState == ConnectionState.online),
          isTrue,
          reason: 'der Relay nimmt nur die neue Form an - '
              'Alice kam nicht online');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
