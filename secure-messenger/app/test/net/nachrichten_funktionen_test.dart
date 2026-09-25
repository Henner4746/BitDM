// nachrichten_funktionen_test.dart — Antworten, Reaktionen, Bearbeiten und
// "fuer alle loeschen" Ende zu Ende: zwei echte Kerne, echter Relay, echtes
// libsignal.
//
// Die Regeln selbst (wer darf was, wie lange) stehen in
// test/store/nachrichten_regeln_test.dart. Hier geht es darum, dass sie auf
// der ANDEREN Seite ankommen — und dass nichts verloren geht, wenn gerade
// keine Verbindung besteht.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

/// Alice und Bob bis zum aktiven Kontakt bringen.
Future<void> _befreunde(Nutzer alice, Nutzer bob) async {
  await alice.core.connect();
  await bob.core.connect();
  await alice.core.addContact(bob.core.myId, displayName: 'Bob');
  expect(
      await Nutzer.warteBis(() => bob.kontaktEreignisse
          .any((e) => e.type == ContactEventType.incomingRequest)),
      isTrue,
      reason: 'Bob bekam keine Kontaktanfrage');
  await bob.core.acceptRequest(alice.core.myId);
  expect(
      await Nutzer.warteBis(() => alice.kontaktEreignisse
          .any((e) => e.type == ContactEventType.requestAccepted)),
      isTrue,
      reason: 'Alice sah die Annahme nicht');
}

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_funktionen'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull,
        reason: 'relay_server.py liess sich nicht starten. '
            'py -3 -m pip install -r secure-messenger/server/requirements.txt');
  });

  /// Zwei befreundete Nutzer, und Alice hat Bob schon eine Nachricht
  /// geschickt, die bei ihm liegt.
  Future<({Nutzer alice, Nutzer bob, Message erste})> paar() async {
    final alice = Nutzer('alice', '${tmp.path}/alice_${n++}.db', relay!.uri);
    final bob = Nutzer('bob', '${tmp.path}/bob_${n++}.db', relay!.uri);
    addTearDown(alice.aufraeumen);
    addTearDown(bob.aufraeumen);
    await alice.starten();
    await bob.starten();
    await alice.core.createIdentity();
    await bob.core.createIdentity();
    await _befreunde(alice, bob);

    final erste = await alice.core.sendMessage(bob.core.myId, 'Treffen um acht?');
    expect(await Nutzer.warteBis(() => bob.eingang.any((m) => m.id == erste.id)),
        isTrue,
        reason: 'die erste Nachricht kam nicht an');
    return (alice: alice, bob: bob, erste: erste);
  }

  Future<Message?> beiBob(Nutzer bob, String von, String id) async =>
      (await bob.core.getMessages(von)).where((m) => m.id == id).firstOrNull;

  test('EINE ANTWORT KOMMT MIT IHREM BEZUG AN', () async {
    final (:alice, :bob, :erste) = await paar();
    final antwort = await bob.core
        .sendMessage(alice.core.myId, 'Ja, passt', antwortAuf: erste.id);
    expect(antwort.antwortAuf, erste.id);
    expect(
        await Nutzer.warteBis(() => alice.eingang.any((m) => m.id == antwort.id)),
        isTrue);
    final angekommen = alice.eingang.firstWhere((m) => m.id == antwort.id);
    expect(angekommen.antwortAuf, erste.id,
        reason: 'der Bezug ging unterwegs verloren');
    // Und er ueberlebt das Speichern: aus der Datenbank gelesen, nicht nur
    // aus dem Strom.
    final gespeichert = (await alice.core.getMessages(bob.core.myId))
        .firstWhere((m) => m.id == antwort.id);
    expect(gespeichert.antwortAuf, erste.id);
  });

  test('EINE REAKTION ERSCHEINT DRUEBEN, WIRD ERSETZT UND ZURUECKGENOMMEN',
      () async {
    final (:alice, :bob, :erste) = await paar();
    final geaendert = <String>[];
    final abo = alice.core.verlaufGeaendert.listen(geaendert.add);
    addTearDown(abo.cancel);

    Future<Reaktionen?> beiAlice() async =>
        (await alice.core.getReaktionen(bob.core.myId))[erste.id];

    await bob.core.reagiere(alice.core.myId, erste.id, '👍');
    expect(
        await Nutzer.warteBis(() => geaendert.contains(bob.core.myId)), isTrue,
        reason: 'Alice bekam keine Meldung');
    expect(await beiAlice(), {bob.core.myId: '👍'});

    // `warteBis` braucht eine synchrone Pruefung, die Reaktionen liegen aber
    // hinter einem Future. Deshalb wird hier auf die Meldungen gezaehlt.
    await bob.core.reagiere(alice.core.myId, erste.id, '❤️');
    expect(await Nutzer.warteBis(() => geaendert.length >= 2), isTrue);
    expect(await beiAlice(), {bob.core.myId: '❤️'});

    await bob.core.reagiere(alice.core.myId, erste.id, null);
    expect(await Nutzer.warteBis(() => geaendert.length >= 3), isTrue);
    expect(await beiAlice(), isNull);
  });

  test('BEARBEITEN KOMMT AN — UND NUR DER AUTOR KANN ES', () async {
    final (:alice, :bob, :erste) = await paar();
    final geaendert = <String>[];
    final abo = bob.core.verlaufGeaendert.listen(geaendert.add);
    addTearDown(abo.cancel);

    final neu =
        await alice.core.bearbeite(bob.core.myId, erste.id, 'Treffen um neun?');
    expect(neu.text, 'Treffen um neun?');
    expect(neu.bearbeitet, isTrue);

    expect(
        await Nutzer.warteBis(() => geaendert.contains(alice.core.myId)), isTrue);
    final drueben = await beiBob(bob, alice.core.myId, erste.id);
    expect(drueben!.text, 'Treffen um neun?');
    expect(drueben.bearbeitet, isTrue);

    // Bob versucht, Alices Satz zu aendern: sein eigener Kern laesst es
    // schon nicht zu. (Dass auch ein veraenderter Client auf Alices Seite
    // abprallt, prueft nachrichten_regeln_test.)
    await expectLater(
        bob.core.bearbeite(alice.core.myId, erste.id, 'Treffen nie'),
        throwsA(isA<BearbeitungNichtMoeglichException>()));
  });

  test('FUER ALLE LOESCHEN LAESST DRUEBEN EINE LEERSTELLE', () async {
    final (:alice, :bob, :erste) = await paar();
    final geaendert = <String>[];
    final abo = bob.core.verlaufGeaendert.listen(geaendert.add);
    addTearDown(abo.cancel);

    await alice.core.widerrufe(bob.core.myId, erste.id);
    final hier = (await alice.core.getMessages(bob.core.myId))
        .firstWhere((m) => m.id == erste.id);
    expect(hier.widerrufen, isTrue);
    expect(hier.text, isEmpty);

    expect(
        await Nutzer.warteBis(() => geaendert.contains(alice.core.myId)), isTrue);
    final drueben = await beiBob(bob, alice.core.myId, erste.id);
    expect(drueben!.widerrufen, isTrue);
    expect(drueben.text, isEmpty);

    // Und fremde Nachrichten lassen sich nicht fuer alle loeschen.
    await expectLater(bob.core.widerrufe(alice.core.myId, erste.id),
        throwsA(isA<BearbeitungNichtMoeglichException>()));
  });

  test('ANGEHEFTET SIEHT ES AUCH DIE GEGENSEITE — UND GELOEST AUCH', () async {
    final (:alice, :bob, :erste) = await paar();
    final geaendert = <String>[];
    final abo = bob.core.verlaufGeaendert.listen(geaendert.add);
    addTearDown(abo.cancel);

    await alice.core.hefteAn(bob.core.myId, erste.id, true);
    expect(await Nutzer.warteBis(() => geaendert.isNotEmpty), isTrue);
    expect((await beiBob(bob, alice.core.myId, erste.id))!.angeheftetAm,
        isNotNull);

    await bob.core.hefteAn(alice.core.myId, erste.id, false);
    final beiAlice = <String>[];
    final abo2 = alice.core.verlaufGeaendert.listen(beiAlice.add);
    addTearDown(abo2.cancel);
    expect(await Nutzer.warteBis(() => beiAlice.isNotEmpty), isTrue);
    final hier = (await alice.core.getMessages(bob.core.myId))
        .firstWhere((m) => m.id == erste.id);
    expect(hier.angeheftetAm, isNull);
  });

  test('EINE GEPLANTE NACHRICHT GEHT ERST ZUR ZEIT HINAUS', () async {
    final (:alice, :bob, erste: _) = await paar();
    final um = DateTime.now().add(const Duration(seconds: 3));
    final m = await alice.core.sendMessage(bob.core.myId, 'spaeter', um: um);
    expect(m.geplantFuer, isNotNull);
    // EIN WIEDERVERBINDEN VOR DER ZEIT. Es stoesst den Nachversand an, und
    // genau der darf sie jetzt NICHT mitnehmen. Ohne diese zwei Zeilen fragte
    // in diesem Fenster niemand nach unversandten Nachrichten, und der Test
    // bliebe gruen, auch wenn die Sperre fehlte (Mutationsprobe 25.09.2026).
    await alice.core.disconnect();
    await alice.core.connect();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(bob.eingang.any((x) => x.id == m.id), isFalse,
        reason: 'sie ging vor ihrer Zeit hinaus');
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == m.id)),
        isTrue,
        reason: 'sie ging zu ihrer Zeit nicht hinaus');
    // Einsortiert zur geplanten Zeit, nicht zur Zeit des Tippens.
    final drueben = bob.eingang.firstWhere((x) => x.id == m.id);
    expect(drueben.timestamp.difference(um.toUtc()).inSeconds.abs(), lessThan(2));
  });

  test('UND SIE UEBERSTEHT EINEN NEUSTART DAZWISCHEN', () async {
    final (:alice, :bob, erste: _) = await paar();
    final m = await alice.core.sendMessage(bob.core.myId, 'trotzdem',
        um: DateTime.now().add(const Duration(seconds: 2)));
    await alice.neustart();
    await alice.core.connect();
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == m.id)),
        isTrue,
        reason: 'nach dem Neustart war der Wecker weg');
  });

  test('EINE UMFRAGE KOMMT AN, UND DIE STIMME DER GEGENSEITE AUCH', () async {
    final (:alice, :bob, erste: _) = await paar();
    final u = await alice.core.sendeUmfrage(
        bob.core.myId, const Umfrage('Wann?', ['Heute', 'Morgen']));
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == u.id)),
        isTrue);
    final drueben = bob.eingang.firstWhere((x) => x.id == u.id);
    expect(drueben.kind, MessageKind.umfrage);
    expect(Umfrage.lies(drueben.text)!.optionen, ['Heute', 'Morgen']);

    final geaendert = <String>[];
    final abo = alice.core.verlaufGeaendert.listen(geaendert.add);
    addTearDown(abo.cancel);
    await bob.core.stimme(alice.core.myId, u.id, [1]);
    expect(await Nutzer.warteBis(() => geaendert.isNotEmpty), isTrue);
    expect((await alice.core.getStimmen(bob.core.myId))[u.id],
        {bob.core.myId: [1]});

    // Und eine Stimme, die nicht passt, nimmt schon der eigene Kern nicht an.
    await expectLater(bob.core.stimme(alice.core.myId, u.id, [0, 1]),
        throwsA(isA<BearbeitungNichtMoeglichException>()));
  });

  test('FUER MICH LOESCHEN BLEIBT HIER', () async {
    final (:alice, :bob, :erste) = await paar();
    await bob.core.loescheFuerMich(alice.core.myId, erste.id);
    expect(await beiBob(bob, alice.core.myId, erste.id), isNull);
    // Bei Alice steht sie noch — sie hat davon nichts erfahren.
    expect(
        (await alice.core.getMessages(bob.core.myId)).any((m) => m.id == erste.id),
        isTrue);
  });

  test('OHNE VERBINDUNG GESETZT, BEIM NAECHSTEN VERBINDEN ZUGESTELLT', () async {
    // Der Grund fuer den Ausgang: vorher gab es keinen Platz, an dem eine
    // Reaktion ohne Verbindung haette warten koennen.
    final (:alice, :bob, :erste) = await paar();
    final geaendert = <String>[];
    final abo = alice.core.verlaufGeaendert.listen(geaendert.add);
    addTearDown(abo.cancel);

    await bob.core.disconnect();
    await bob.core.reagiere(alice.core.myId, erste.id, '🙏');
    // Lokal ist sie sofort da ...
    expect((await bob.core.getReaktionen(alice.core.myId))[erste.id],
        {bob.core.myId: '🙏'});

    // ... und ueberlebt sogar einen Neustart, bevor sie hinausgeht.
    await bob.neustart();
    await bob.core.connect();
    expect(
        await Nutzer.warteBis(() => geaendert.contains(bob.core.myId)), isTrue,
        reason: 'die Reaktion blieb im Ausgang liegen');
    expect((await alice.core.getReaktionen(bob.core.myId))[erste.id],
        {bob.core.myId: '🙏'});
  });

  test('DIE SUCHE FINDET, WAS IN DER UNTERHALTUNG STEHT', () async {
    final (:alice, :bob, :erste) = await paar();
    expect((await bob.core.suche('ACHT')).map((m) => m.id), [erste.id]);
    expect(await bob.core.suche('neun'), isEmpty);
  });

  test('DIE FRIST DER UNTERHALTUNG REIST MIT UND LOESCHT DRUEBEN', () async {
    final (:alice, :bob, erste: _) = await paar();
    await alice.core.setzeChatFrist(bob.core.myId, const Duration(seconds: 1));
    final m = await alice.core.sendMessage(bob.core.myId, 'gleich weg');
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == m.id)),
        isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await bob.core.purgeExpiredMessages();
    expect((await bob.core.getMessages(alice.core.myId)).any((x) => x.id == m.id),
        isFalse,
        reason: 'die Frist dieser Unterhaltung kam nicht mit');
  });

  test('"HIER NIE" SCHLAEGT DIE GRUNDEINSTELLUNG', () async {
    final (:alice, :bob, erste: _) = await paar();
    await alice.core.setPreferences((await alice.core.getPreferences())
        .copyWith(messageLifetime: const Duration(seconds: 1)));
    await alice.core.setzeChatFrist(bob.core.myId, Duration.zero);
    final m = await alice.core.sendMessage(bob.core.myId, 'bleibt');
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == m.id)),
        isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await bob.core.purgeExpiredMessages();
    await alice.core.purgeExpiredMessages();
    expect((await bob.core.getMessages(alice.core.myId)).any((x) => x.id == m.id),
        isTrue);
    expect((await alice.core.getMessages(bob.core.myId)).any((x) => x.id == m.id),
        isTrue);
  });

  test('ANHEFTEN, ARCHIVIEREN, STUMM BLEIBEN NACH EINEM NEUSTART', () async {
    final (:alice, :bob, erste: _) = await paar();
    await bob.core.setzeOrdnung(alice.core.myId, angeheftet: true, stumm: true);
    await bob.neustart();
    final k = (await bob.core.getContacts())
        .firstWhere((c) => c.id == alice.core.myId);
    expect(k.angeheftet, isTrue);
    expect(k.stumm, isTrue);
    expect(k.archiviert, isFalse);
  });
}
