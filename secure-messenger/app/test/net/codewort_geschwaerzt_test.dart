// codewort_geschwaerzt_test.dart — das Fernloesch-Codewort bleibt nicht im
// Verlauf des Vertrauten stehen (Sicherheitsbewertung vom 23.11.2026, SEC-M8).
//
// Der Vertraute tippt das Codewort als gewoehnliche Nachricht; die Gegenstelle
// verschluckt es und zaehlt es als Loeschanfrage. Bis 23.11.2026 stand es
// danach im Klartext im Verlauf des Vertrauten. Jetzt bittet die Quittung ums
// Schwaerzen — derselbe Weg wie bei den Teilgeheimnissen der Sicherung.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

const wort = 'Rote Katze im Schnee';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_codewort'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Future<Nutzer> nutzer(String name) async {
    final u = Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);
    addTearDown(u.aufraeumen);
    await u.starten();
    await u.core.createIdentity();
    await u.core.connect();
    return u;
  }

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull);
  });

  test('DAS CODEWORT WIRD BEIM VERTRAUTEN GESCHWAERZT, ANDERES BLEIBT', () async {
    final anna = await nutzer('anna');
    final bob = await nutzer('bob');
    await anna.core.addContact(bob.core.myId);
    expect(
        await Nutzer.warteBis(() => bob.kontaktEreignisse
            .any((e) => e.type == ContactEventType.incomingRequest)),
        isTrue);
    await bob.core.acceptRequest(anna.core.myId);
    expect(
        await Nutzer.warteBis(() => anna.kontaktEreignisse
            .any((e) => e.type == ContactEventType.requestAccepted)),
        isTrue);

    await anna.core.setzeFernCodewort(wort);
    await anna.core.setzeFernloeschung(
        Fernloeschung(an: true, schwelle: 2, vertraute: [bob.core.myId]));

    final gewoehnlich = await bob.core.sendMessage(anna.core.myId, 'Bis morgen');
    final code = await bob.core.sendMessage(anna.core.myId, wort);

    Future<String?> textBeiBob(String id) async => (await bob.core
            .getMessages(anna.core.myId))
        .where((m) => m.id == id)
        .map((m) => m.text)
        .firstOrNull;

    final ende = DateTime.now().add(const Duration(seconds: 20));
    while (await textBeiBob(code.id) == wort && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await textBeiBob(code.id), isNot(wort),
        reason: 'das Codewort stand weiter im Klartext im Verlauf des Vertrauten');
    expect(await textBeiBob(code.id), '••••••');

    // Bei Anna zaehlte es als Anfrage und kam nicht in den Verlauf.
    expect((await anna.core.getFernloeschung()).anfragen.keys, [bob.core.myId]);
    expect((await anna.core.getMessages(bob.core.myId)).any((m) => m.text == wort),
        isFalse);

    // Die gewoehnliche Nachricht bleibt lesbar.
    expect(
        await Nutzer.warteBis(
            () => anna.eingang.any((m) => m.id == gewoehnlich.id)),
        isTrue);
    expect(await textBeiBob(gewoehnlich.id), 'Bis morgen');
  });
}
