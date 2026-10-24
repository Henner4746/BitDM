// sicherung_test.dart — Verlauf sichern, Telefon verlieren, mit den zwoelf
// Woertern zurueckholen und die Sicherung einspielen.
//
// Echte Kerne, echter Relay. Der Fall, auf den es ankommt, ist der letzte
// Schritt: nach dem Einspielen muss Alice wieder SCHREIBEN koennen. Eine
// Sicherung, die alte Sitzungen mitbraechte, wuerde genau hier still
// Nachrichten kosten — deshalb bringt sie keine mit.

// DIE FRIST FUER JEDEN TEST DIESER DATEI, der keine eigene hat. Sie bauen
// echte Kerne auf und reden ueber einen Relay; auf dem Windows-Runner der CI
// brauchten solche Tests bis zu 35 s, voreingestellt sind 30 (CI-Laeufe bis
// 24.10.2026). Dieselben 3 Minuten wie bei den Tests, die eine eigene haben.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
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

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_sicherung'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Nutzer nutzer(String name) {
    final u = Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);
    addTearDown(u.aufraeumen);
    return u;
  }

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull);
  });

  test('SICHERN, TELEFON WEG, WIEDERHERSTELLEN, EINSPIELEN, WEITERSCHREIBEN',
      () async {
    final alice = nutzer('alice');
    final bob = nutzer('bob');
    await alice.starten();
    await bob.starten();
    await alice.core.createIdentity();
    await bob.core.createIdentity();
    await alice.core.connect();
    await bob.core.connect();
    await alice.core.addContact(bob.core.myId);
    expect(
        await Nutzer.warteBis(() => bob.kontaktEreignisse
            .any((e) => e.type == ContactEventType.incomingRequest)),
        isTrue);
    await bob.core.acceptRequest(alice.core.myId);
    expect(
        await Nutzer.warteBis(() => alice.kontaktEreignisse
            .any((e) => e.type == ContactEventType.requestAccepted)),
        isTrue);

    final vonAlice =
        await alice.core.sendMessage(bob.core.myId, 'Geheimnis Nummer eins');
    expect(await Nutzer.warteBis(() => bob.eingang.any((m) => m.id == vonAlice.id)),
        isTrue);
    final vonBob = await bob.core.sendMessage(alice.core.myId, 'Antwort zwei');
    expect(await Nutzer.warteBis(() => alice.eingang.any((m) => m.id == vonBob.id)),
        isTrue);
    await bob.core.reagiere(alice.core.myId, vonAlice.id, '👍');
    // SIE MUSS BEI ALICE SEIN, BEVOR SIE SICHERT — unten wird sie in der
    // Sicherung erwartet. Bis 24.10.2026 stand hier eine Pause von 500 ms.
    expect(
        await Nutzer.warteBis(() async =>
            (await alice.core.getReaktionen(bob.core.myId))[vonAlice.id] !=
            null),
        isTrue,
        reason: 'Bobs Reaktion kam bei Alice nie an');

    final woerter = await alice.core.getRecoveryPhrase();
    final sicherung = await alice.core.erstelleSicherung();

    // KEIN KLARTEXT IN DER DATEI — weder ein Satz noch eine Adresse.
    final alsText = latin1.decode(sicherung, allowInvalid: true);
    expect(alsText.contains('Geheimnis'), isFalse);
    expect(alsText.contains(bob.core.myId), isFalse);

    // Bob kann sie nicht oeffnen: andere zwoelf Woerter.
    await expectLater(bob.core.spieleSicherungEin(sicherung),
        throwsA(isA<SicherungPasstNichtException>()));

    // Alices Telefon ist weg. Ein neues, dieselben Woerter.
    await alice.core.disconnect();
    final neu = nutzer('alice_neu');
    await neu.starten();
    expect(await neu.core.restoreIdentity(woerter), alice.core.myId);
    await neu.core.connect();
    // SEIT DER GERAETEABMELDUNG (docs/GERAETEABMELDUNG.md) steht das neue
    // Telefon nicht von selbst in der Geraeteliste — die Woerter allein
    // reichen nicht mehr. Das alte ist weg, also bleibt der Weg, den ein
    // Mensch hier nimmt: "Alle anderen Geraete abmelden".
    expect(neu.core.geraeteStand, ListenStand.beitrittNoetig);
    await neu.core.setzeZurueck();
    expect(
        await Nutzer.warteBis(
            () => neu.core.connectionState == ConnectionState.online),
        isTrue);

    final hinzu = await neu.core.spieleSicherungEin(sicherung);
    expect(hinzu, 2, reason: 'beide Nachrichten sollten zurueck sein');
    final verlauf = await neu.core.getMessages(bob.core.myId);
    expect(verlauf.map((m) => m.text),
        containsAll(['Geheimnis Nummer eins', 'Antwort zwei']));
    expect((await neu.core.getReaktionen(bob.core.myId))[vonAlice.id],
        {bob.core.myId: '👍'});

    // Zweimal einspielen legt nichts doppelt an.
    expect(await neu.core.spieleSicherungEin(sicherung), 0);

    // UND SIE KANN WEITERSCHREIBEN — mit einer frischen Sitzung.
    final danach = await neu.core.sendMessage(bob.core.myId, 'wieder da');
    // 45 statt 20 Sekunden: das neue Geraet baut hier erst eine frische
    // Sitzung auf, und unter Last (voller Testlauf, CI) dauerte das einmal
    // laenger als 20 Sekunden.
    expect(
        await Nutzer.warteBis(() => bob.eingang.any((m) => m.id == danach.id),
            frist: const Duration(seconds: 45)),
        isTrue,
        reason: 'nach dem Einspielen ging keine Nachricht mehr durch');
  });
}
