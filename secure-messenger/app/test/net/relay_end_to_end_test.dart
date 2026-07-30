// relay_end_to_end_test.dart — die erste echte Nachricht ueber den Relay.
//
// Kein nachgebauter Server. Dieser Test startet relay_server.py als eigenen
// Prozess und laesst zwei vollstaendige BitDM-Clients darueber miteinander
// reden: eigene Seed-Phrase, eigene verschluesselte Datenbank, X3DH,
// Double Ratchet, WebSocket.
//
// Der Grund fuer diesen Aufwand steht in der Projektgeschichte. Ein Server-Test
// gegen einen Dart-Client-Nachbau und ein Client-Test gegen einen
// Server-Nachbau koennen beide gruen sein, waehrend nichts zusammenpasst —
// genau so hat der Relay einmal 47 % aller gueltigen Signaturen abgelehnt, ohne
// dass ein Test es gemerkt haette. Nur wenn beide ECHTEN Seiten miteinander
// sprechen, ist die Frage beantwortet.
//
// Der Test wird uebersprungen, wenn Python oder die Abhaengigkeiten des Relays
// fehlen — dann sagt er das aber laut, statt still durchzurutschen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/relay_process.dart';

/// Ein vollstaendiger Client: Identitaet, verschluesselte Datenbank,
/// Relay-Verbindung.
class Teilnehmer {
  Teilnehmer._(this.name, this.db, this.repo, this.store, this.client,
      this.preKeys, this.signedPreKey);

  final String name;
  final EncryptedDatabase db;
  final SignalStoreRepository repo;
  final BitdmSignalStore store;
  final RelayClient client;
  final List<PreKeyRecord> preKeys;
  final SignedPreKeyRecord signedPreKey;

  final _posteingang = <String>[];

  /// Was nicht zu entschluesseln war — seit dem Empfangsnachweis vor allem
  /// Wiederholungen, die der Ratchet abweist.
  final verworfen = <Object>[];

  /// Wie viele Umschlaege ueberhaupt hereinkamen, lesbar oder nicht.
  ///
  /// Der Posteingang taugt fuer die Frage "kam sie noch einmal" nicht: eine
  /// wiederholte Nachricht laesst sich per Bauart nicht ein zweites Mal
  /// entschluesseln und landet deshalb nie dort.
  var rohEingang = 0;

  StreamSubscription<RelayEvent>? _abo;

  String get address => store.identity.address;
  SignalProtocolAddress get protocolAddress =>
      SignalProtocolAddress(address, 1);

  static Future<Teilnehmer> neu(String name, Uri relayUri, String pfad,
      {int otkAnzahl = 5}) async {
    final derived = await KeyDerivation.fromMnemonic(Bip39.generate());
    final db = EncryptedDatabase.open(pfad, derived.databaseKey);
    final repo = SignalStoreRepository(db);
    final store = repo.openStore(derived);

    final preKeys = generatePreKeys(1, otkAnzahl);
    for (final pk in preKeys) {
      await store.storePreKey(pk.id, pk);
    }
    final spk = generateSignedPreKey(store.identity.keyPair, 1);
    await store.storeSignedPreKey(spk.id, spk);
    repo.commit(store);

    final client =
        RelayClient(baseUri: relayUri, identity: store.identity);

    return Teilnehmer._(name, db, repo, store, client, preKeys, spk);
  }

  Future<int> anmelden() => client.register(PreKeyBundleBridge.toRelay(
        identity: store.identity,
        signedPreKey: signedPreKey,
        oneTimePreKeys: preKeys,
      ));

  /// Verbindet und entschluesselt alles, was hereinkommt.
  ///
  /// [bestaetigen] steuert, ob der Empfangsnachweis hinausgeht. Er steht hier
  /// als Schalter und nicht fest, weil die eine Haelfte des Nachweises nur
  /// pruefbar ist, wenn sich auch das UNTERLASSEN nachstellen laesst — ohne
  /// das koennte der Relay die Zeilen genauso gut wie frueher sofort loeschen
  /// und alle Tests blieben gruen.
  Future<void> verbinden({bool bestaetigen = true}) async {
    _abo = client.events.listen((e) async {
      if (e is! RelayMessage) return;
      rohEingang++;
      try {
        final umschlag = Envelope.fromBytes(e.ciphertext);
        final klar = await umschlag.decrypt(
            SessionCipher.fromStore(store, SignalProtocolAddress(e.from, 1)));
        repo.commit(store);
        _posteingang.add(utf8.decode(klar));
      } catch (fehler) {
        // Seit der Relay auf den Nachweis wartet, ist die Wiederholung der
        // Normalfall und nicht mehr die Ausnahme. Die Ratchet-Schicht weist
        // sie ab; festgeschrieben wird trotzdem, weil der Ratchet auch bei
        // einem Fehlschlag weitergerueckt sein kann.
        repo.commit(store);
        verworfen.add(fehler);
      }
      // ERST HIER, nach commit: der Relay loescht auf diesen Nachweis hin
      // seine Zeile. Ginge er vorher hinaus, waere der Verlust nur von der
      // Leitung in die App verschoben.
      final q = e.q;
      if (bestaetigen && q != null) client.bestaetigeEmpfang(q);
    });
    await client.connect();
  }

  /// Wartet, bis [anzahl] Umschlaege hereingekommen sind — lesbar oder nicht.
  Future<int> warteAufUmschlaege(int anzahl,
      {Duration frist = const Duration(seconds: 15)}) async {
    final ende = DateTime.now().add(frist);
    while (rohEingang < anzahl && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return rohEingang;
  }

  Future<void> trennen() async {
    await _abo?.cancel();
    _abo = null;
    await client.close();
  }

  /// Baut bei Bedarf eine Sitzung auf und schickt die Nachricht.
  Future<void> schreibeAn(String zieladresse, String text) async {
    final ziel = SignalProtocolAddress(zieladresse, 1);
    if (!await store.containsSession(ziel)) {
      final antwort = await client.fetchBundle(zieladresse);
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(antwort));
    }
    final ct = await SessionCipher.fromStore(store, ziel)
        .encrypt(Uint8List.fromList(utf8.encode(text)));
    repo.commit(store);
    await client.send(zieladresse, Envelope.of(ct).toBytes());
  }

  /// Wartet, bis [anzahl] Nachrichten angekommen und entschluesselt sind.
  Future<List<String>> warteAufPost(int anzahl,
      {Duration frist = const Duration(seconds: 15)}) async {
    final ende = DateTime.now().add(frist);
    while (_posteingang.length < anzahl && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return List.of(_posteingang);
  }

  Future<void> aufraeumen() async {
    await trennen();
    await client.dispose();
    db.close();
  }
}

void main() {
  late Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async {
    relay = await Relay.starten();
  });

  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_e2e'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows
    }
  });

  String pfad(String name) => '${tmp.path}/${name}_${n++}.db';

  Future<Teilnehmer> teilnehmer(String name, {int otkAnzahl = 5}) =>
      Teilnehmer.neu(name, relay!.uri, pfad(name), otkAnzahl: otkAnzahl);

  /// Wie viele Zeilen beim Relay fuer [empfaenger] noch offen sind.
  ///
  /// EIN BLICK IN DIE TABELLE und nicht bloss "es kam nichts mehr": das
  /// Ausbleiben einer zweiten Zustellung waere auch dann wahr, wenn der Relay
  /// die Zeile aus einem ganz anderen Grund losgeworden waere. Nur die Zahl
  /// hier beantwortet, ob der Nachweis gewirkt hat.
  ///
  /// Schreibend geoeffnet, weil die Datenbank in WAL laeuft: lesend allein
  /// koennte SQLite den -wal-Teil nicht einbeziehen, und dann staende hier der
  /// Stand vor dem letzten Commit.
  int offeneZeilen(String empfaenger) {
    final db = sqlite3.open('${relay!.datenverzeichnis.path}/relay.db');
    try {
      final zeilen = db.select(
          'SELECT COUNT(*) AS n FROM queue WHERE recipient = ?', [empfaenger]);
      return zeilen.first['n'] as int;
    } finally {
      db.dispose();
    }
  }

  /// Wartet, bis der Relay auf [erwartet] Zeilen gekommen ist.
  ///
  /// Der Nachweis geht ohne Antwort hinaus — es gibt also keinen Zeitpunkt,
  /// an dem der Client wuesste, dass geloescht wurde. Deshalb nachsehen statt
  /// warten auf etwas.
  Future<int> warteAufZeilen(String empfaenger, int erwartet,
      {Duration frist = const Duration(seconds: 10)}) async {
    final ende = DateTime.now().add(frist);
    var jetzt = offeneZeilen(empfaenger);
    while (jetzt != erwartet && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      jetzt = offeneZeilen(empfaenger);
    }
    return jetzt;
  }

  test('Relay laeuft — sonst sagen die folgenden Tests nichts aus', () {
    expect(relay, isNotNull,
        reason: 'relay_server.py liess sich nicht starten. Abhaengigkeiten: '
            'py -3 -m pip install -r secure-messenger/server/requirements.txt');
  });

  group('ueber den echten Relay', () {
    test('Alice schreibt Bob, Bob antwortet', () async {
      final alice = await teilnehmer('alice');
      final bob = await teilnehmer('bob');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);

      expect(await alice.anmelden(), 5);
      expect(await bob.anmelden(), 5);

      await alice.verbinden();
      await bob.verbinden();

      await alice.schreibeAn(bob.address, 'Hallo Bob, das ist die erste.');
      expect(await bob.warteAufPost(1), ['Hallo Bob, das ist die erste.']);

      await bob.schreibeAn(alice.address, 'Angekommen. Gruss zurueck.');
      expect(await alice.warteAufPost(1), ['Angekommen. Gruss zurueck.']);

      // Und weiter in beide Richtungen — jetzt laeuft der Ratchet.
      await alice.schreibeAn(bob.address, 'zwei');
      await alice.schreibeAn(bob.address, 'drei');
      expect(await bob.warteAufPost(3),
          ['Hallo Bob, das ist die erste.', 'zwei', 'drei']);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('eine Nachricht an jemanden, der offline ist, wartet auf ihn',
        () async {
      // Der Fall, fuer den es die Warteschlange gibt. Ohne ihn waere ein
      // Messenger nur brauchbar, wenn beide gleichzeitig online sind.
      final alice = await teilnehmer('alice');
      final bob = await teilnehmer('bob');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);

      await alice.anmelden();
      await bob.anmelden();
      await alice.verbinden();

      // Bob war nie verbunden.
      await alice.schreibeAn(bob.address, 'Das liest du spaeter.');

      await bob.verbinden();
      expect(await bob.warteAufPost(1), ['Das liest du spaeter.']);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('der Umschlag auf der Leitung ist nicht lesbar', () async {
      // Beweist, dass der Relay wirklich nur Rauschen sieht. Geprueft wird
      // nicht die Behauptung, sondern der Inhalt der Warteschlangentabelle
      // ueber das, was der Client verschickt hat.
      final alice = await teilnehmer('alice');
      final bob = await teilnehmer('bob');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);

      await alice.anmelden();
      await bob.anmelden();
      await alice.verbinden();

      const klartext = 'GEHEIMER_TEXT_DER_NICHT_AUFTAUCHEN_DARF';
      final ziel = SignalProtocolAddress(bob.address, 1);
      final antwort = await alice.client.fetchBundle(bob.address);
      await SessionBuilder.fromSignalStore(alice.store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(antwort));
      final ct = await SessionCipher.fromStore(alice.store, ziel)
          .encrypt(Uint8List.fromList(utf8.encode(klartext)));

      final aufDerLeitung = utf8.decode(ct.serialize(), allowMalformed: true);
      expect(aufDerLeitung.contains(klartext), isFalse);
      expect(aufDerLeitung.contains('GEHEIMER'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('ein fremder Schluessel zu einer Adresse wird abgelehnt', () async {
      // Der Angriff, gegen den isTrustedIdentity nachrechnet statt zu
      // vertrauen: ein boesartiger Relay liefert im Bundle den Schluessel
      // eines Dritten. Hier wird das nachgestellt, indem Mallorys Bundle unter
      // Bobs Adresse verwendet wird.
      final alice = await teilnehmer('alice');
      final bob = await teilnehmer('bob');
      final mallory = await teilnehmer('mallory');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);
      addTearDown(mallory.aufraeumen);

      await alice.anmelden();
      await bob.anmelden();
      await mallory.anmelden();
      await alice.verbinden();

      final mallorysBundle = await alice.client.fetchBundle(mallory.address);
      final unterBobsAdresse =
          PreKeyBundleBridge.fromRelay(mallorysBundle);

      expect(
          () => SessionBuilder.fromSignalStore(
                  alice.store, SignalProtocolAddress(bob.address, 1))
              .processPreKeyBundle(unterBobsAdresse),
          throwsA(isA<UntrustedIdentityException>()),
          reason: 'ein fremder Schluessel unter Bobs Adresse muss auffallen — '
              'beim ALLERERSTEN Kontakt, ohne Sicherheitsnummernvergleich');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('ohne Anmeldung laesst der Relay niemanden herein', () async {
      final niemand = await teilnehmer('niemand');
      addTearDown(niemand.aufraeumen);
      // anmelden() wurde absichtlich NICHT aufgerufen.
      expect(niemand.verbinden(), throwsA(isA<RelayException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('ohne Empfangsnachweis kommt die Nachricht noch einmal', () async {
      // DER BEFUND, von der Clientseite aus. Vorher loeschte der Relay die
      // Zeile, sobald der Rahmen im Schreibpuffer stand — was danach abriss,
      // war weg, und der Absender hatte sein ack seit Tagen.
      final alice = await teilnehmer('alice');
      final bob = await teilnehmer('bob');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);

      await alice.anmelden();
      await bob.anmelden();
      await alice.verbinden();
      await alice.schreibeAn(bob.address, 'Das darf nicht verlorengehen.');

      await bob.verbinden(bestaetigen: false);
      expect(await bob.warteAufUmschlaege(1), 1);
      expect(await bob.warteAufPost(1), ['Das darf nicht verlorengehen.']);
      // Sie ist beim Client — und liegt trotzdem noch beim Relay, weil
      // niemand bestaetigt hat.
      expect(offeneZeilen(bob.address), 1);

      await bob.trennen();
      await bob.verbinden(bestaetigen: false);
      expect(await bob.warteAufUmschlaege(2), 2,
          reason: 'ohne Nachweis muss der Relay sie erneut zustellen');

      // Und die Wiederholung behelligt niemanden: der Ratchet weist sie ab,
      // im Verlauf steht sie weiterhin genau einmal.
      expect(bob.verworfen, hasLength(1));
      expect(await bob.warteAufPost(1), ['Das darf nicht verlorengehen.']);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('mit Empfangsnachweis ist die Zeile beim Relay weg', () async {
      // Das Gegenstueck. Ohne diesen Test bliebe die Warteschlange voll, und
      // aus einem Datenverlust waere ein Dauerlauf geworden.
      final alice = await teilnehmer('alice');
      final bob = await teilnehmer('bob');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);

      await alice.anmelden();
      await bob.anmelden();
      await alice.verbinden();
      await alice.schreibeAn(bob.address, 'Angekommen ist angekommen.');
      expect(offeneZeilen(bob.address), 1);

      await bob.verbinden();
      expect(await bob.warteAufPost(1), ['Angekommen ist angekommen.']);
      expect(await warteAufZeilen(bob.address, 0), 0,
          reason: 'der Nachweis muss die Zeile beim Relay loeschen');

      await bob.trennen();
      await bob.verbinden();
      // Kurz Zeit lassen — eine Nachzustellung waere sofort da.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(bob.rohEingang, 1, reason: 'sie darf kein zweites Mal kommen');
      expect(bob.verworfen, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('eine Adresse, die es nicht gibt, meldet 404', () async {
      final alice = await teilnehmer('alice');
      addTearDown(alice.aufraeumen);
      await alice.anmelden();

      expect(
          () => alice.client.fetchBundle('a' * 56),
          throwsA(isA<RelayException>()
              .having((e) => e.statusCode, 'statusCode', 404)));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
