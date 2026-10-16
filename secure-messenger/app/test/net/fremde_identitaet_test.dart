// fremde_identitaet_test.dart — der Riegel gegen einen Relay, der fremde
// Schluessel unterschiebt, am ECHTEN Kern.
//
// Die Anbindung der offiziellen libsignal ruft `isTrustedIdentity` nie auf und
// legt beim Sitzungsaufbau die Sitzung ab, bevor `saveIdentity` laeuft
// (Befund vom 16.10.2026, Bibliotheksverhalten festgehalten in
// test/crypto/signal_bibliothek_test.dart, Gruppe "BEFUND 16.10.2026"). Ohne
// Gegenmittel koennte ein feindlicher Relay unter Doras Adresse Mallorys
// Buendel ausliefern, und Mallory laese mit, was man Dora schreibt.
//
// Hier wird geprueft, dass BitDMs Riegel VOR libsignal greifen:
//   - PreKeyBundleBridge.fromRelay: der Schluessel muss die Adresse ergeben,
//   - _bauSitzungen: das Buendel muss fuer die angefragte Adresse sein,
//   - _nimmUmschlagJetzt: der Schluessel einer Erstnachricht muss zum
//     Absender passen,
// und dass bei einem Fehlschlag nichts im Speicher zurueckbleibt.

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/core/crypto/signal_errors.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/absender.dart';
import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;
  late ZaehlRelay relay;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 5)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return fertig();
  }

  setUpAll(signalBereit);

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-fremde-identitaet');
    lage = Relaylage();
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) => relay = ZaehlRelay(id, lage),
    );
    kern.quittungsVerzug = () => Duration.zero;
    await kern.initialize();
    woerter = await kern.createIdentity();
    await kern.connect();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  void kontakt(String adresse) =>
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));

  bool sitzungMit(String adresse) => kern.signalStoreFuerTest.state.sessions
      .keys
      .any((k) => k.startsWith('$adresse:'));

  group('Die Buendel-Bruecke', () {
    test('ein Buendel, dessen Schluessel nicht die userId ergibt, wird '
        'abgewiesen, bevor libsignal es sieht', () async {
      final dora = await Absender.neu();
      final mallory = await Absender.neu();
      final gefaelscht = RelayBundleResponse.fromJson(
          {...mallory.karte(), 'user_id': dora.adresse});
      expect(() => PreKeyBundleBridge.fromRelay(gefaelscht),
          throwsA(isA<FremdeIdentitaet>()));
    });

    test('ein echtes Buendel geht durch', () async {
      final dora = await Absender.neu();
      expect(
          PreKeyBundleBridge.fromRelay(
              RelayBundleResponse.fromJson(dora.karte())),
          isNotNull);
    });
  });

  group('Senden an einen Kontakt', () {
    test('Mallorys Buendel unter Doras Adresse: nichts geht hinaus, keine '
        'Sitzung bleibt', () async {
      final dora = await Absender.neu();
      final mallory = await Absender.neu();
      kontakt(dora.adresse);
      lage.buendel = (adresse) => {...mallory.karte(), 'user_id': dora.adresse};

      try {
        await kern.sendMessage(dora.adresse, 'nur fuer Dora');
      } catch (_) {
        // Ob der Kern wirft oder die Nachricht zurueckstellt, ist hier
        // gleich — entscheidend ist, was hinausging und was im Speicher steht.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(lage.gesendet.where((g) => g.an == dora.adresse), isEmpty,
          reason: 'ein Umschlag ging ueber eine Sitzung mit Mallorys '
              'Schluesseln hinaus');
      expect(sitzungMit(dora.adresse), isFalse,
          reason: 'eine Sitzung mit Mallorys Schluesseln steht unter Doras '
              'Adresse im Speicher');
      expect(kern.signalStoreFuerTest.state.identities[dora.adresse], isNull);
    });

    test('ein Buendel fuer eine ANDERE Adresse (echt, aber falsch '
        'zugeordnet) wird ebenso abgewiesen', () async {
      final dora = await Absender.neu();
      final mallory = await Absender.neu();
      kontakt(dora.adresse);
      // Mallorys echtes Buendel, ehrlich mit Mallorys Adresse — aber als
      // Antwort auf die Frage nach Dora.
      lage.buendel = (adresse) => mallory.karte();

      try {
        await kern.sendMessage(dora.adresse, 'nur fuer Dora');
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(lage.gesendet, isEmpty);
      expect(sitzungMit(dora.adresse), isFalse);
      expect(sitzungMit(mallory.adresse), isFalse);
    });

    test('zum Vergleich: Doras echtes Buendel fuehrt zum Versand', () async {
      final dora = await Absender.neu();
      kontakt(dora.adresse);
      lage.buendel = (adresse) => dora.karte();

      await kern.sendMessage(dora.adresse, 'hallo Dora');
      expect(
          await warteBis(
              () => lage.gesendet.any((g) => g.an == dora.adresse)),
          isTrue);
      expect(sitzungMit(dora.adresse), isTrue);
    });
  });

  group('Empfang einer Erstnachricht', () {
    Future<RelayBundleResponse> eigenesBuendel() async {
      final store = SignalStoreRepository(kern.datenbankFuerTest)
          .openStore(await KeyDerivation.fromMnemonic(woerter));
      return buendelAusSpeicher(store);
    }

    test('Mallory schreibt als Alice: still verworfen, quittiert, keine '
        'Kontaktanfrage, keine Sitzung', () async {
      final alice = await Absender.neu();
      final mallory = await Absender.neu();
      kontakt(alice.adresse);
      final ereignisse = <ContactEvent>[];
      final abo = kern.contactEvents.listen(ereignisse.add);
      addTearDown(abo.cancel);
      final eingang = <Message>[];
      final abo2 = kern.incomingMessages.listen(eingang.add);
      addTearDown(abo2.cancel);

      final umschlag = await mallory.an(kern.myId, await eigenesBuendel(),
          Payload.text('m-1', 'ich bin Alice', DateTime.now().toUtc()));
      relay.herein(RelayMessage(
          from: alice.adresse,
          ciphertext: umschlag,
          at: DateTime.now().toUtc(),
          q: 91));

      expect(await warteBis(() => relay.bestaetigt.contains(91)), isTrue,
          reason: 'ein Umschlag, der nie lesbar wird, soll nicht 14 Tage '
              'lang wiederkommen');
      expect(eingang, isEmpty);
      expect(
          ereignisse.where((e) =>
              e.type == ContactEventType.incomingRequest &&
              e.contactId == alice.adresse),
          isEmpty,
          reason: 'der Relay erzeugte eine Kontaktanfrage fuer einen '
              'bekannten Kontakt');
      expect(sitzungMit(alice.adresse), isFalse);
      expect(kern.ablageFuerTest.verlauf(alice.adresse), isEmpty);
    });

    test('zum Vergleich: Alices echte Erstnachricht kommt an', () async {
      final alice = await Absender.neu();
      kontakt(alice.adresse);
      final eingang = <Message>[];
      final abo = kern.incomingMessages.listen(eingang.add);
      addTearDown(abo.cancel);

      final umschlag = await alice.an(kern.myId, await eigenesBuendel(),
          Payload.text('a-1', 'hallo', DateTime.now().toUtc()));
      relay.herein(RelayMessage(
          from: alice.adresse,
          ciphertext: umschlag,
          at: DateTime.now().toUtc(),
          q: 92));

      expect(await warteBis(() => eingang.isNotEmpty), isTrue);
      expect(eingang.single.text, 'hallo');
      expect(base64.encode(kern.signalStoreFuerTest.state.identities[
              alice.adresse]!),
          isNotEmpty);
    });
  });
}
