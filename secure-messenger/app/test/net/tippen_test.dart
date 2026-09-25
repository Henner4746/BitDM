// tippen_test.dart — "tippt gerade", fluechtig ueber den echten Relay.
//
// Die drei Zusagen, die hier geprueft werden:
//
// 1. Es kommt an, wenn beide Seiten die Anzeige anhaben.
// 2. Ist die Gegenseite nicht verbunden, bleibt NICHTS beim Relay liegen —
//    keine Zeile in der Warteschlange, also auch kein Anstoss.
// 3. Die verworfene Meldung hat den Ratchet trotzdem weitergerueckt; die
//    naechste ECHTE Nachricht muss sich ueber diese Luecke hinweg
//    entschluesseln lassen. Das ist der Fall, der still Nachrichten kosten
//    wuerde, wenn er nicht hielte.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_tippen'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  int offeneZeilen(String empfaenger) {
    final db = sqlite.sqlite3.open('${relay!.datenverzeichnis.path}/relay.db');
    try {
      return db.select('SELECT COUNT(*) AS n FROM queue WHERE recipient = ?',
          [empfaenger]).first['n'] as int;
    } finally {
      db.close();
    }
  }

  Future<({Nutzer alice, Nutzer bob, List<TippMeldung> beiBob})> paar(
      {bool bobZeigt = true}) async {
    final alice = Nutzer('alice', '${tmp.path}/alice_${n++}.db', relay!.uri);
    final bob = Nutzer('bob', '${tmp.path}/bob_${n++}.db', relay!.uri);
    addTearDown(alice.aufraeumen);
    addTearDown(bob.aufraeumen);
    await alice.starten();
    await bob.starten();
    await alice.core.createIdentity();
    await bob.core.createIdentity();
    await alice.core.setPreferences(
        (await alice.core.getPreferences()).copyWith(tippAnzeige: true));
    await bob.core.setPreferences(
        (await bob.core.getPreferences()).copyWith(tippAnzeige: bobZeigt));

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

    final beiBob = <TippMeldung>[];
    final abo = bob.core.tippen.listen(beiBob.add);
    addTearDown(abo.cancel);
    return (alice: alice, bob: bob, beiBob: beiBob);
  }

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull);
  });

  test('KOMMT AN, WENN BEIDE ES ANHABEN — UND BLEIBT NICHT LIEGEN', () async {
    final (:alice, :bob, :beiBob) = await paar();
    await alice.core.meldeTippen(bob.core.myId, true);
    expect(await Nutzer.warteBis(() => beiBob.isNotEmpty), isTrue,
        reason: 'Bob sah nicht, dass Alice tippt');
    expect(beiBob.last.chatId, alice.core.myId);
    expect(beiBob.last.tippt, isTrue);

    await alice.core.meldeTippen(bob.core.myId, false);
    expect(await Nutzer.warteBis(() => beiBob.length >= 2), isTrue);
    expect(beiBob.last.tippt, isFalse);
    expect(offeneZeilen(bob.core.myId), 0,
        reason: 'eine fluechtige Meldung stand in der Warteschlange');
  });

  test('BOB NICHT DA: NICHTS IN DER WARTESCHLANGE, UND DIE LUECKE SCHADET NICHT',
      () async {
    final (:alice, :bob, :beiBob) = await paar();
    await bob.core.disconnect();
    for (var i = 0; i < 5; i++) {
      await alice.core.meldeTippen(bob.core.myId, i.isEven);
    }
    expect(offeneZeilen(bob.core.myId), 0,
        reason: 'der Relay hat fluechtige Rahmen gepuffert — dann weckte '
            'jeder davon das Telefon');

    // Fuenf Kettenschluessel sind jetzt verbraucht, ohne dass Bob sie je sah.
    final m = await alice.core.sendMessage(bob.core.myId, 'nach der Luecke');
    await bob.core.connect();
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == m.id)),
        isTrue,
        reason: 'die echte Nachricht liess sich ueber die Luecke hinweg nicht '
            'entschluesseln');
    expect(beiBob, isEmpty, reason: 'eine alte Tipp-Meldung kam doch noch an');
  });

  test('WER DIE ANZEIGE AUS HAT, SIEHT NICHTS', () async {
    final (:alice, :bob, :beiBob) = await paar(bobZeigt: false);
    await alice.core.meldeTippen(bob.core.myId, true);
    // Eine echte Nachricht hinterher: wenn sie da ist, ist die Tipp-Meldung
    // davor laengst verarbeitet — oder eben verworfen.
    final m = await alice.core.sendMessage(bob.core.myId, 'hallo');
    expect(await Nutzer.warteBis(() => bob.eingang.any((x) => x.id == m.id)),
        isTrue);
    expect(beiBob, isEmpty);
  });
}
