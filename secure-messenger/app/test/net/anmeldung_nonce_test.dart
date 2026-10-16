// anmeldung_nonce_test.dart — die Challenge des Relays muss genau 32 Byte
// lang sein, sonst wird nichts signiert.
//
// Warum das ein Sicherheitstest ist und keine Formalie: Bei der Anmeldung
// signiert der Client das Nonce des Servers mit dem IDENTITAETSSCHLUESSEL —
// mit derselben Funktion, die auch die signierten Prekeys signiert. Ohne
// Laengenpruefung ist die Anmeldung damit ein Signaturorakel. Ein boesartiger
// Relay schickt als „Challenge“:
//
//   * 33 Byte `0x05 ‖ K` und erhaelt eine gueltige Signed-Prekey-Signatur
//     fuer einen Schluessel K, dessen privaten Teil er selbst kennt,
//   * 64 Byte `nonce ‖ sha256(bundle)` und erhaelt eine gueltige
//     Registrierungssignatur fuer ein selbst gewaehltes Buendel.
//
// Den Inhalt der Nachrichten kann er damit nicht lesen — X3DH verlangt
// zusaetzlich DH(EK_A, IK_B). Er kann sich aber gegenueber anderen Relays als
// der Nutzer ausgeben und untergeschobene Prekeys verteilen.
//
// Ein ECHTER WebSocket-Server auf 127.0.0.1 spielt den boesartigen Relay und
// schreibt mit, ob eine Signatur zurueckkam. Vorlage: relay_fassung_test.dart.

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

  /// Was der Server als Nonce schickt.
  late List<int> nonce;

  /// Jeder Rahmen, den der Client geschickt hat.
  late List<Map<String, Object?>> vomClient;

  setUp(() async {
    ich = SignalIdentityBridge.fromDerived(
        await KeyDerivation.fromMnemonic(Bip39.generate()),
        registrationId: SignalIdentityBridge.newRegistrationId());
    nonce = List.filled(32, 7);
    vomClient = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode({'type': 'challenge', 'nonce': base64.encode(nonce)}));
      ws.listen((roh) {
        vomClient
            .add((jsonDecode(roh as String) as Map).cast<String, Object?>());
        ws.add(jsonEncode({'type': 'auth_result', 'ok': true}));
      });
    });
  });

  tearDown(() async => server.close(force: true));

  Future<(Object?, RelayClient)> versucheAnmeldung() async {
    final c = RelayClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        identity: ich,
        handshakeTimeout: const Duration(seconds: 3));
    addTearDown(c.dispose);
    Object? fehler;
    try {
      await c.connect();
    } catch (e) {
      fehler = e;
    }
    // Der Ereignisstrom ist ein Broadcast — eine Runde warten.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (fehler, c);
  }

  test('32 BYTE: die Anmeldung laeuft wie immer', () async {
    // Die Gegenprobe. Ohne sie koennte die Pruefung auch alles abweisen.
    final (fehler, c) = await versucheAnmeldung();

    expect(fehler, isNull);
    expect(c.isConnected, isTrue);
    expect(vomClient.single.containsKey('signature'), isTrue,
        reason: 'genau ein Rahmen, und der traegt die Signatur');
  });

  for (final (name, laenge) in [
    ('33 BYTE (0x05 ‖ K, das Format eines signierten Prekeys)', 33),
    ('64 BYTE (nonce ‖ sha256(bundle), eine Registrierung)', 64),
    ('31 BYTE', 31),
    ('0 BYTE', 0),
  ]) {
    test('$name: NICHTS wird signiert, die Verbindung endet', () async {
      nonce = List.filled(laenge, 5);
      final (fehler, c) = await versucheAnmeldung();

      expect(vomClient, isEmpty,
          reason: 'der Identitaetsschluessel darf fremde Bytes nicht '
              'signieren — das ist der ganze Befund');
      expect(fehler, isA<RelayException>(),
          reason: 'und der Aufrufer muss es erfahren');
      expect(c.isConnected, isFalse);
    });
  }

  test('die Laenge steht als Konstante am Client', () {
    // Damit niemand sie an zwei Stellen anders schreibt: der Server erzeugt
    // `secrets.token_bytes(32)`.
    expect(RelayClient.nonceLaenge, 32);
  });
}
