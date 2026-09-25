// relay_kennt_geraete_test.dart — die Frage, die gegen den alten Relay Geld
// kostet.
//
// `?nur_geraete=1` ist beim NEUEN Relay umsonst: er antwortet mit `geraete`
// und zieht keinen Einmalschluessel (Spezifikation §3.3). Gegen den Relay, der
// heute laeuft, ist dieselbe Frage NICHT umsonst — er kennt den Parameter
// nicht, FastAPI verwirft ihn stumm, und der Handler laeuft seinen Normalweg
// samt `DELETE FROM one_time_prekeys ... RETURNING`. Jede Frage zieht also
// einen Einmalschluessel der ABGEFRAGTEN Adresse, und die Antwort wird
// weggeworfen, weil `geraete` fehlt.
//
// Ohne Gedaechtnis wiederholt sich das je gesendeter Nutzlast: Text, Anhang,
// Lese- und Empfangsquittung — jedes Mal ein Umlauf und ein fremder
// Einmalschluessel.
//
// EIN ECHTER HTTP-SERVER UND KEINE ATTRAPPE: gemessen wird, wie oft wirklich
// eine Anfrage auf der Leitung liegt. Ein nachgebauter `_getJson` zaehlte
// Aufrufe einer Methode und nicht Umlaeufe — und genau die Umlaeufe sind der
// Schaden.
//
// ═══════════════════════════════════════════════════ MUTATIONSPROBE 01.08.2026

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
  var anfragen = 0;

  /// Ob der Server `geraete` mittraegt — also die Erweiterung kennt.
  var mitGeraeten = false;

  setUp(() async {
    ich = SignalIdentityBridge.fromDerived(
        await KeyDerivation.fromMnemonic(Bip39.generate()),
        registrationId: SignalIdentityBridge.newRegistrationId());
    anfragen = 0;
    mitGeraeten = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      anfragen++;
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'user_id': 'x' * 56,
          'identity_key': 'aWQ=',
          'registration_id': 7,
          'signed_prekey_id': 1,
          'signed_prekey': 'c3Br',
          'signed_prekey_sig': 'c2ln',
          'one_time_prekey': null,
          // DER GANZE UNTERSCHIED. Ein Relay vor der Umstellung ignoriert den
          // Parameter und antwortet mit dem gewoehnlichen Buendel — ohne
          // `geraete`.
          if (mitGeraeten)
            'geraete': [
              {'device_id': 1},
              {'device_id': 2},
            ],
        }));
      await req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  RelayClient neuerClient() => RelayClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        identity: ich,
      );

  test('EIN RELAY OHNE DIE ERWEITERUNG WIRD NUR EINMAL JE VERBINDUNG GEFRAGT',
      () async {
    // MUTATION: in `geraeteliste` `if (!_kenntGeraete) return null;`
    //           gestrichen
    final client = neuerClient();
    addTearDown(client.dispose);

    expect(await client.geraeteliste('a' * 56), isNull,
        reason: 'NULL heisst "dieser Relay kennt die Frage nicht" und nicht '
            '"keine Geraete" — an dem Unterschied haengt, ob es beim heutigen '
            'Verhalten bleibt oder die Adresse als unbekannt gilt');
    expect(anfragen, 1);

    // Dreimal weiterfragen — so oft, wie eine Nachricht mit Quittungen es
    // ausloesen wuerde.
    for (var i = 0; i < 3; i++) {
      expect(await client.geraeteliste('a' * 56), isNull);
    }

    expect(anfragen, 1,
        reason: 'jede weitere Frage kostet gegen den alten Relay einen '
            'Einmalschluessel der abgefragten Adresse — und die Antwort wird '
            'ohnehin weggeworfen. Anfragen=$anfragen');
  });

  test('EIN NEUER CLIENT FRAGT WIEDER — sonst waere ein Update nie zu merken',
      () async {
    // `connect()` baut fuer jeden Versuch einen frischen RelayClient
    // (real_messenger_core `_neuerRelay`). Waere das Gedaechtnis dauerhaft,
    // wuerde ein aktualisierter Relay NIE erkannt, und die Mehrgeraete-
    // Zustellung bliebe fuer diese Installation fuer immer aus.
    final alt = neuerClient();
    addTearDown(alt.dispose);
    expect(await alt.geraeteliste('a' * 56), isNull);
    expect(anfragen, 1);

    // Der Betreiber hat inzwischen aktualisiert.
    mitGeraeten = true;
    final neu = neuerClient();
    addTearDown(neu.dispose);

    expect(await neu.geraeteliste('a' * 56), [1, 2],
        reason: 'ein frischer Client muss unbefangen fragen');
    expect(anfragen, 2);

    // Und gegen den neuen Relay wird bei JEDER Nutzlast wieder gefragt — die
    // Frage ist dort umsonst, und die Geraeteliste soll aktuell sein.
    expect(await neu.geraeteliste('a' * 56), [1, 2],
        reason: 'gegen einen Relay MIT der Erweiterung darf das Gedaechtnis '
            'nicht greifen — null hiesse hier "kennt die Frage nicht", und '
            'der Kern bliebe beim Ein-Geraet-Verhalten');
    expect(anfragen, 3,
        reason: 'und die Frage muss wirklich auf der Leitung liegen: sonst '
            'saehe man ein neu hinzugekommenes Geraet der Gegenstelle bis zum '
            'naechsten Verbinden nicht');
  });
}
