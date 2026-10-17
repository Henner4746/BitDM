// real_core_test.dart — die App als Ganzes.
//
// Hier laeuft nichts Nachgebautes mehr: echter Kern, echte verschluesselte
// Datenbank, echter relay_server.py als eigener Prozess. Was dieser Test
// durchspielt, ist genau das, was ein Nutzer tut — Identitaet anlegen,
// jemanden hinzufuegen, schreiben, App schliessen, App oeffnen.
//
// Nur der Schluesselspeicher des Geraets ist ersetzt: er ist ein
// Plattform-Plugin und laeuft ausserhalb eines Telefons nicht. Genau dafuer
// gibt es die Schnittstelle in secret_store.dart.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_core'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Nutzer nutzer(String name) =>
      Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);

  test('Relay laeuft — sonst sagen die folgenden Tests nichts aus', () {
    expect(relay, isNotNull,
        reason: 'relay_server.py liess sich nicht starten. '
            'py -3 -m pip install -r secure-messenger/server/requirements.txt');
  });

  group('Identitaet', () {
    test('erster Start hat keine, nach dem Anlegen schon', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);

      a.core = RealMessengerCore(
          secretStore: a.tresor, databasePath: a.pfad, relayUri: relay!.uri);
      expect(await a.core.initialize(), isFalse,
          reason: 'ohne Zutun darf keine Identitaet entstehen — sonst haette '
              'jemand, der wiederherstellen will, schon eine falsche');
      expect(a.core.hasIdentity, isFalse);

      final woerter = await a.core.createIdentity();
      expect(woerter, hasLength(kRecoveryPhraseWords));
      expect(a.core.isInitialized, isTrue);
      expect(a.core.myId, hasLength(56));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('die Identitaet ueberlebt den Neustart', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();
      final adresse = a.core.myId;

      await a.neustart();
      expect(a.core.myId, adresse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('die Phrase ist spaeter noch abrufbar', () async {
      // Nur moeglich, weil die ENTROPIE gespeichert wird und nicht der Seed —
      // BIP39 fuehrt die Woerter durch PBKDF2, das laesst sich nicht umkehren.
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      final woerter = await a.core.createIdentity();

      await a.neustart();
      expect(await a.core.getRecoveryPhrase(), woerter);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('dieselbe Phrase auf einem anderen Geraet ergibt dieselbe Adresse',
        () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      final woerter = await a.core.createIdentity();
      final adresse = a.core.myId;

      final b = nutzer('alice-neues-telefon');
      addTearDown(b.aufraeumen);
      await b.starten();
      expect(await b.core.restoreIdentity(woerter), adresse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('eine kaputte Phrase wird abgelehnt, ohne etwas anzulegen', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();

      final kaputt = List.filled(12, 'abandon'); // Pruefsumme stimmt nicht
      expect(a.core.isValidRecoveryPhrase(kaputt), isFalse);
      await expectLater(a.core.restoreIdentity(kaputt),
          throwsA(isA<InvalidRecoveryPhraseException>()));
      expect(await a.tresor.read(), isNull,
          reason: 'ein Fehlversuch darf nichts hinterlassen');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('Zwei Nutzer, echter Relay', () {
    late Nutzer alice;
    late Nutzer bob;

    Future<void> beideBereit() async {
      alice = nutzer('alice');
      bob = nutzer('bob');
      addTearDown(alice.aufraeumen);
      addTearDown(bob.aufraeumen);
      await alice.starten();
      await bob.starten();
      await alice.core.createIdentity();
      await bob.core.createIdentity();
      await alice.core.connect();
      await bob.core.connect();
      expect(alice.core.connectionState, ConnectionState.online);
      expect(bob.core.connectionState, ConnectionState.online);
    }

    test('Kontaktanfrage, Annahme, Nachricht — der ganze Ablauf', () async {
      await beideBereit();

      // Alice fuegt Bob hinzu. Das verschickt eine Anfrage.
      final kontakt = await alice.core.addContact(bob.core.myId,
          displayName: 'Bob');
      expect(kontakt.state, ContactState.outgoingPending);

      // Bei Bob taucht sie als eingehende Anfrage auf.
      expect(
          await Nutzer.warteBis(() => bob.kontaktEreignisse
              .any((e) => e.type == ContactEventType.incomingRequest)),
          isTrue,
          reason: 'Bob hat keine Kontaktanfrage bekommen');
      final beiBob = (await bob.core.getContacts()).single;
      expect(beiBob.id, alice.core.myId);
      expect(beiBob.state, ContactState.incomingPending);

      // Bob nimmt an.
      await bob.core.acceptRequest(alice.core.myId);
      expect(
          await Nutzer.warteBis(() => alice.kontaktEreignisse
              .any((e) => e.type == ContactEventType.requestAccepted)),
          isTrue,
          reason: 'Alice hat die Annahme nicht mitbekommen');
      expect((await alice.core.getContacts()).single.state,
          ContactState.active);

      // Und jetzt eine echte Nachricht.
      final gesendet =
          await alice.core.sendMessage(bob.core.myId, 'Hallo Bob!');
      expect(gesendet.status, MessageStatus.sending);

      expect(await Nutzer.warteBis(() => bob.eingang.isNotEmpty), isTrue,
          reason: 'die Nachricht kam nicht an');
      expect(bob.eingang.single.text, 'Hallo Bob!');
      expect(bob.eingang.single.isMine, isFalse);
      expect(bob.eingang.single.chatId, alice.core.myId);

      // Bob quittiert automatisch — Alices Nachricht wird zugestellt gemeldet.
      expect(
          await Nutzer.warteBis(() => alice.statusEreignisse
              .any((s) => s.status == MessageStatus.delivered)),
          isTrue,
          reason: 'keine Zustellbestaetigung');

      final beiAlice =
          await alice.core.getMessages(bob.core.myId);
      expect(beiAlice.single.status, MessageStatus.delivered);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('der Verlauf ueberlebt den Neustart BEIDER Geraete', () async {
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(() => bob.kontaktEreignisse.isNotEmpty);
      await bob.core.acceptRequest(alice.core.myId);
      await Nutzer.warteBis(() => alice.kontaktEreignisse.isNotEmpty);

      await alice.core.sendMessage(bob.core.myId, 'eins');
      await Nutzer.warteBis(() => bob.eingang.length == 1);
      await bob.core.sendMessage(alice.core.myId, 'zwei');
      await Nutzer.warteBis(() => alice.eingang.length == 1);

      final bobAdresse = bob.core.myId;
      final aliceAdresse = alice.core.myId;

      await alice.neustart();
      await bob.neustart();

      // Der Verlauf ist noch da ...
      final verlaufA = await alice.core.getMessages(bobAdresse);
      expect(verlaufA.map((m) => m.text), ['eins', 'zwei']);
      expect(verlaufA.map((m) => m.isMine), [true, false]);

      final verlaufB = await bob.core.getMessages(aliceAdresse);
      expect(verlaufB.map((m) => m.text), ['eins', 'zwei']);
      expect(verlaufB.map((m) => m.isMine), [false, true]);

      // ... und die Unterhaltung laeuft weiter, mit dem Ratchet-Stand von
      // vorher.
      await alice.core.connect();
      await bob.core.connect();
      await alice.core.sendMessage(bobAdresse, 'drei');
      expect(await Nutzer.warteBis(() => bob.eingang.isNotEmpty), isTrue,
          reason: 'nach dem Neustart kam nichts mehr an');
      expect(bob.eingang.single.text, 'drei');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('eine Nachricht im Offline-Zustand geht spaeter raus', () async {
      // Der haeufigste Fall auf einem Telefon: Funkloch, tippen, absenden.
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(() => bob.kontaktEreignisse.isNotEmpty);
      await bob.core.acceptRequest(alice.core.myId);
      await Nutzer.warteBis(() => alice.kontaktEreignisse.isNotEmpty);

      await alice.core.disconnect();
      final m = await alice.core.sendMessage(bob.core.myId, 'aus dem Funkloch');
      expect(m.status, MessageStatus.sending);

      // Sie liegt in der Datenbank und wartet.
      expect((await alice.core.getMessages(bob.core.myId)).single.status,
          MessageStatus.sending);

      await alice.core.connect();
      expect(await Nutzer.warteBis(() => bob.eingang.isNotEmpty), isTrue,
          reason: 'die zurueckgestellte Nachricht ging nie raus');
      expect(bob.eingang.single.text, 'aus dem Funkloch');
    }, timeout: const Timeout(Duration(minutes: 3)));


    test('EINE KONTAKTANFRAGE IM FUNKLOCH GEHT SPAETER RAUS', () async {
      // DER FEHLER, DEN ES HIERHER GEBRACHT HAT
      //
      // Am 29.07.2026 auf zwei echten Telefonen: beide tragen die Adresse des
      // anderen ein, beide sind online, beide starten neu — und auf keinem
      // erscheint eine eingehende Anfrage. Auf beiden steht fuer immer
      // "Request sent, waiting for confirmation".
      //
      // Der Grund: eine Kontaktanfrage ist eine verschluesselte Nutzlast und
      // braucht eine Sitzung, also das Buendel der Gegenseite vom Relay. War
      // das gerade nicht zu haben, scheiterte sie — und `addContact` warf sie
      // mit `unawaited` ab. Der Fehler verschwand darin, und weil eine
      // Steuernutzlast keine eigene Nachricht ist, kam sie in keine
      // Warteschlange. Kein zweiter Versuch, kein Hinweis.
      //
      // Fuer NACHRICHTEN gab es den Nachversand laengst (der Fall darueber).
      // Fuer die Anfrage, mit der ueberhaupt alles anfaengt, nicht.
      await beideBereit();
      await alice.core.disconnect();

      await alice.core.addContact(bob.core.myId);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(bob.kontaktEreignisse, isEmpty,
          reason: 'ohne Verbindung kann sie nicht angekommen sein — sonst '
              'prueft der Test darunter nichts');

      await alice.core.connect();
      expect(await Nutzer.warteBis(() => bob.kontaktEreignisse.isNotEmpty),
          isTrue,
          reason: 'die Anfrage wurde nie wiederholt: Bob erfaehrt nie, dass '
              'ihn jemand hinzufuegen will');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('beide Seiten sehen dieselbe Pruefnummer', () async {
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(() => bob.kontaktEreignisse.isNotEmpty);
      await bob.core.acceptRequest(alice.core.myId);
      await Nutzer.warteBis(() => alice.kontaktEreignisse.isNotEmpty);
      await alice.core.sendMessage(bob.core.myId, 'damit es eine Sitzung gibt');
      await Nutzer.warteBis(() => bob.eingang.isNotEmpty);

      final a = await alice.core.getSafetyNumber(bob.core.myId);
      final b = await bob.core.getSafetyNumber(alice.core.myId);

      expect(a.digits, hasLength(60));
      expect(a.digits, b.digits,
          reason: 'unterschiedliche Nummern machen den Vergleich am Telefon '
              'sinnlos');
      expect(a.groups, hasLength(12));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('eine abgelehnte Anfrage verschwindet auf beiden Seiten', () async {
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(() => bob.kontaktEreignisse.isNotEmpty);

      await bob.core.declineRequest(alice.core.myId);
      expect(await bob.core.getContacts(), isEmpty);
      expect(
          await Nutzer.warteBis(() => alice.kontaktEreignisse
              .any((e) => e.type == ContactEventType.requestDeclined)),
          isTrue);
      expect(await alice.core.getContacts(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    bool hat(Nutzer n, ContactEventType art) =>
        n.kontaktEreignisse.any((e) => e.type == art);

    Future<ContactState> zustand(Nutzer bei, Nutzer von) async =>
        (await bei.core.getContacts())
            .singleWhere((k) => k.id == von.core.myId)
            .state;

    test('GEGENSEITIG HINZUGEFUEGT, die Anfragen kreuzen sich: beide werden '
        'Kontakte', () async {
      // DER FALL BEIM TREFFEN: beide scannen den Code des anderen. Jede
      // Anfrage traf dabei auf einen Kontakt, der beim Empfaenger schon als
      // "ausstehend" stand — und wurde als Wiederholung verworfen: keine
      // Karte, kein Zustandswechsel. Beide sahen fuer immer "Anfrage
      // gesendet", mit Internet genauso wie ohne. Dasselbe Bild wie am
      // 29.07.2026 (siehe "EINE KONTAKTANFRAGE IM FUNKLOCH"), nur mit einer
      // Ursache, die der Nachversand nicht beheben konnte.
      //
      // Beide offline, damit sich die Anfragen wirklich kreuzen und nicht
      // eine vor dem zweiten Hinzufuegen ankommt — den Fall gibt es darunter.
      await beideBereit();
      await alice.core.disconnect();
      await bob.core.disconnect();
      await alice.core.addContact(bob.core.myId);
      await bob.core.addContact(alice.core.myId);
      await alice.core.connect();
      await bob.core.connect();

      final gemeldet = await Nutzer.warteBis(() =>
          hat(alice, ContactEventType.requestAccepted) &&
          hat(bob, ContactEventType.requestAccepted));
      expect(await zustand(alice, bob), ContactState.active,
          reason: 'beide wollten den Kontakt, und beide warten fuer immer');
      expect(await zustand(bob, alice), ContactState.active);
      expect(gemeldet, isTrue,
          reason: 'die Oberflaeche erfaehrt nichts davon');
      expect(hat(alice, ContactEventType.incomingRequest), isFalse,
          reason: 'wer selbst angefragt hat, muss nichts mehr annehmen');
      expect(hat(bob, ContactEventType.incomingRequest), isFalse);

      // Und es laeuft in beide Richtungen — die Sitzungen sind dabei von
      // beiden Seiten zugleich entstanden, und genau das soll hier mit
      // geprueft sein.
      await alice.core.sendMessage(bob.core.myId, 'hin');
      await bob.core.sendMessage(alice.core.myId, 'her');
      expect(
          await Nutzer.warteBis(
              () => bob.eingang.isNotEmpty && alice.eingang.isNotEmpty),
          isTrue,
          reason: 'die gekreuzten Sitzungen tragen keine Nachricht');
      expect(bob.eingang.single.text, 'hin');
      expect(alice.eingang.single.text, 'her');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('WER EINE ANFRAGE HAT UND SELBST HINZUFUEGT, nimmt damit an',
        () async {
      // Dieselbe Absicht, andere Reihenfolge: Alices Anfrage ist schon da,
      // Bob scannt ihren Code, statt die Karte anzutippen. `addContact` gab
      // den vorhandenen Kontakt zurueck und tat sonst nichts — der
      // Hinzufuegen-Bildschirm sagte "Anfrage gesendet", gesendet war nichts.
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(
          () => hat(bob, ContactEventType.incomingRequest));

      final k = await bob.core.addContact(alice.core.myId);
      expect(k.state, ContactState.active,
          reason: 'Bob will den Kontakt — die Anfrage dazu liegt schon da');
      expect(
          await Nutzer.warteBis(
              () => hat(alice, ContactEventType.requestAccepted)),
          isTrue,
          reason: 'Alice erfaehrt nie, dass Bob sie auch will');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EINE ZUSAGE IM FUNKLOCH GEHT SPAETER RAUS', () async {
      // Das Gegenstueck zur Kontaktanfrage im Funkloch. Die Zusage ging
      // einmal hinaus oder nie: gescheitert, war sie weg, und Alice stand
      // fuer immer auf "ausstehend", waehrend Bob schon schreiben konnte.
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(
          () => hat(bob, ContactEventType.incomingRequest));

      await bob.core.disconnect();
      await bob.core.acceptRequest(alice.core.myId);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hat(alice, ContactEventType.requestAccepted), isFalse,
          reason: 'ohne Verbindung kann sie nicht angekommen sein — sonst '
              'prueft der Test darunter nichts');

      await bob.core.connect();
      expect(
          await Nutzer.warteBis(
              () => hat(alice, ContactEventType.requestAccepted)),
          isTrue,
          reason: 'die Zusage wurde nie nachgeschickt');
      expect(await zustand(alice, bob), ContactState.active);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('WER SCHON ZUGESAGT HAT, sagt auf eine wiederholte Anfrage noch '
        'einmal zu', () async {
      // FUER DIE, DIE ES SCHON ERWISCHT HAT. Eine Zusage, die vor diesem
      // Stand verloren ging, liegt in keinem Ausgang. Alice schickt ihre
      // Anfrage aber bei jedem Verbinden erneut — und die traf bei Bob auf
      // einen aktiven Kontakt und wurde verworfen. Ab jetzt ist sie genau
      // das Zeichen, dass die Zusage fehlt.
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(
          () => hat(bob, ContactEventType.incomingRequest));

      // Der Stand, den die alte Fassung hinterliess: Bob hat angenommen,
      // hinausgegangen ist nichts.
      final beiBob = (await bob.core.getContacts()).single;
      bob.core.ablageFuerTest
          .speichereKontakt(beiBob.copyWith(state: ContactState.active));

      await alice.core.disconnect();
      await alice.core.connect();
      expect(
          await Nutzer.warteBis(
              () => hat(alice, ContactEventType.requestAccepted)),
          isTrue,
          reason: 'Alice fragt bei jedem Verbinden, und Bob schweigt');
      expect(await zustand(alice, bob), ContactState.active);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EINE ABSAGE IM FUNKLOCH GEHT SPAETER RAUS', () async {
      await beideBereit();
      await alice.core.addContact(bob.core.myId);
      await Nutzer.warteBis(
          () => hat(bob, ContactEventType.incomingRequest));

      await bob.core.disconnect();
      await bob.core.declineRequest(alice.core.myId);
      expect(await bob.core.getContacts(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hat(alice, ContactEventType.requestDeclined), isFalse);

      await bob.core.connect();
      expect(
          await Nutzer.warteBis(
              () => hat(alice, ContactEventType.requestDeclined)),
          isTrue,
          reason: 'die Absage wurde nie nachgeschickt — Alice fragte bei '
              'jedem Verbinden weiter, und Bob bekam jedes Mal eine neue Karte');
      expect(await alice.core.getContacts(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('Alles loeschen', () {
    test('loescht Identitaet, Schluessel UND Nachrichten wirklich', () async {
      // Der Knopf in der Oberflaeche hat bis zum 25.07.2026 nur Anzeigewerte
      // zurueckgesetzt. Dieser Test haelt fest, dass er jetzt loescht.
      final a = nutzer('alice');
      final b = nutzer('bob');
      addTearDown(a.aufraeumen);
      addTearDown(b.aufraeumen);
      await a.starten();
      await b.starten();
      await a.core.createIdentity();
      await b.core.createIdentity();
      await a.core.connect();
      await b.core.connect();

      await a.core.addContact(b.core.myId);
      await Nutzer.warteBis(() => b.kontaktEreignisse.isNotEmpty);
      await b.core.acceptRequest(a.core.myId);
      await Nutzer.warteBis(() => a.kontaktEreignisse.isNotEmpty);
      await a.core.sendMessage(b.core.myId, 'etwas zum Loeschen');
      await Nutzer.warteBis(() => b.eingang.isNotEmpty);

      expect(File(a.pfad).existsSync(), isTrue);
      expect(await a.tresor.read(), isNotNull);

      await a.core.wipeEverything();

      expect(await a.tresor.read(), isNull,
          reason: 'die Entropie muss weg sein — sie ist der Schluessel zu allem');
      expect(File(a.pfad).existsSync(), isFalse,
          reason: 'die Datenbankdatei muss weg sein');
      expect(a.core.hasIdentity, isFalse);
      expect(await a.core.initialize(), isFalse,
          reason: 'nach dem Loeschen muss die App wieder ins Onboarding');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('danach laesst sich eine NEUE Identitaet anlegen', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      final alt = (await a.core.createIdentity(), a.core.myId).$2;

      await a.core.wipeEverything();
      await a.core.createIdentity();

      expect(a.core.myId, isNot(alt),
          reason: 'die neue Identitaet darf nicht die alte sein');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('mit den zwoelf Woertern kommt die Identitaet zurueck', () async {
      // Das ist die einzige Ausnahme von "unwiderruflich" — und der Grund,
      // warum die Phrase beim Anlegen gezeigt werden MUSS.
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      final woerter = await a.core.createIdentity();
      final adresse = a.core.myId;

      await a.core.wipeEverything();
      expect(await a.core.initialize(), isFalse);

      expect(await a.core.restoreIdentity(woerter), adresse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('Was abgelehnt werden muss', () {
    test('ohne Identitaet gibt es keine Adresse', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      expect(() => a.core.myId, throwsA(isA<NotInitializedException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('eine unsinnige Adresse wird abgelehnt', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();

      expect(a.core.isValidAddress('zu kurz'), isFalse);
      await expectLater(a.core.addContact('zu kurz'),
          throwsA(isA<InvalidAddressException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('die eigene Adresse laesst sich nicht hinzufuegen', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();
      await expectLater(a.core.addContact(a.core.myId),
          throwsA(isA<InvalidAddressException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('eine zu lange Nachricht wird abgelehnt', () async {
      final a = nutzer('alice');
      final b = nutzer('bob');
      addTearDown(a.aufraeumen);
      addTearDown(b.aufraeumen);
      await a.starten();
      await b.starten();
      await a.core.createIdentity();
      await b.core.createIdentity();
      await a.core.connect();

      await a.core.addContact(b.core.myId);
      await expectLater(
          a.core.sendMessage(b.core.myId, 'x' * (kMaxTextBytes + 1)),
          throwsA(isA<MessageTooLargeException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('eine unbekannte Unterhaltung wird abgelehnt', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();
      await expectLater(a.core.getMessages('b' * 56),
          throwsA(isA<UnknownContactException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('ein unerreichbarer Relay wirft NICHT, sondern meldet den Zustand',
        () async {
      // Vertragsregel. Wuerde connect() werfen, muesste jede Stelle der
      // Oberflaeche einen try/catch tragen, mit dem sie nichts anfangen kann.
      final a = Nutzer('alice', '${tmp.path}/offline_${n++}.db',
          Uri.parse('http://127.0.0.1:1'));
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();

      await a.core.connect();
      expect(a.core.connectionState, ConnectionState.error);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
