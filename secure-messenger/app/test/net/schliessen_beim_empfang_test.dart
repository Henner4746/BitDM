// schliessen_beim_empfang_test.dart — der Kern wird geschlossen, waehrend
// libsignal noch entschluesselt.
//
// Gefunden am 17.10.2026 im Gesamtlauf auf Linux (Mini-PC): Ein Umschlag kam
// herein, `huelle.decrypt` lief in Rust, und waehrenddessen wurde der Kern
// geschlossen (im Test der Abbau, im Betrieb Sperren oder Loeschen). Nach dem
// `await` las `_nimmUmschlagJetzt` `myId` und warf "call initialize() first"
// — ungefangen, aus einem Stream-Listener heraus. Mit der Dart-Nachbildung war
// das Fenster winzig, mit der Rust-Anbindung ist es breit genug fuer den
// Gesamtlauf.
//
// Der Test schliesst den Kern nach 0 bis 24 Runden der Ereignisschleife und
// trifft damit jede Stelle des Ablaufs, an der gewartet wird. Eine ungefangene
// Ausnahme laesst flutter_test den Test scheitern.

import 'dart:io';

import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/absender.dart';
import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

void main() {
  setUpAll(signalBereit);

  test('SCHLIESSEN WAEHREND DER ENTSCHLUESSELUNG wirft nichts ins Leere',
      () async {
    final alice = await Absender.neu();
    for (var runden = 0; runden < 25; runden++) {
      final ordner = await Directory.systemTemp.createTemp('bitdm-schliessen');
      final lage = Relaylage();
      late RelayAttrappe relay;
      final kern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
        relayFactory: (uri, id) => relay = RelayAttrappe(id, lage),
      );
      await kern.initialize();
      final woerter = await kern.createIdentity();
      await kern.connect();

      final eigenes = SignalStoreRepository(kern.datenbankFuerTest)
          .openStore(await KeyDerivation.fromMnemonic(woerter));
      final umschlag = await alice.an(kern.myId, await buendelAusSpeicher(eigenes),
          Payload.text('m-$runden', 'hallo', DateTime.now().toUtc()));
      relay.herein(RelayMessage(
          from: alice.adresse,
          ciphertext: umschlag,
          at: DateTime.now().toUtc(),
          q: runden + 1));

      for (var i = 0; i < runden; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await kern.dispose();
      // Was nach dem Schliessen noch aus dem Ablauf kommt, soll hier landen,
      // nicht im naechsten Durchgang.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      try {
        await ordner.delete(recursive: true);
      } catch (_) {}
    }
  });
}
