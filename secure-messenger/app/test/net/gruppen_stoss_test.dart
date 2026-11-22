// gruppen_stoss_test.dart — viele Nachrichten schnell hintereinander in eine
// Gruppe, gegen einen echten Relay mit enger Bremse (QA-Bericht vom
// 18.11.2026, "Burst Message Loss in Large Groups").
//
// Die Tester schickten in einer Gruppe mit 20 Mitgliedern 15 Nachrichten
// rasch hintereinander. Der Relay bremst je Absender (relay_server.py
// `MSG_CAPACITY` 180 Rahmen, `MSG_REFILL_PER_SEC` 6), und eine
// Gruppennachricht kostet einen Rahmen je Mitgliedsgeraet. Was an der Bremse
// liegenblieb, stand auf der Uhr, bis der Absender neu verband — manchmal
// zweimal, weil jeder Nachversand wieder an ALLE ging.
//
// Nachgestellt mit vier Mitgliedern und einer Bremse von 12 Rahmen Stoss und
// 3 je Sekunde: dasselbe Verhaeltnis, ohne zwanzig Kerne.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten(umgebung: {
        'BITDM_MSG_BURST': '12',
        'BITDM_MSG_REFILL': '3',
      }));
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_stoss'));
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

  Future<void> befreunde(Nutzer a, Nutzer b) async {
    await a.core.addContact(b.core.myId);
    expect(
        await Nutzer.warteBis(() => b.kontaktEreignisse.any((e) =>
            e.type == ContactEventType.incomingRequest &&
            e.contactId == a.core.myId)),
        isTrue);
    await b.core.acceptRequest(a.core.myId);
    expect(
        await Nutzer.warteBis(() => a.kontaktEreignisse.any((e) =>
            e.type == ContactEventType.requestAccepted &&
            e.contactId == b.core.myId)),
        isTrue);
  }

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull);
  });

  test('ZEHN NACHRICHTEN AUF EINMAL: JEDES MITGLIED BEKOMMT ALLE, OHNE NEUVERBINDEN',
      () async {
    final anna = await nutzer('anna');
    final andere = [
      for (final name in ['bob', 'carl', 'dora']) await nutzer(name),
    ];
    for (final u in andere) {
      await befreunde(anna, u);
    }
    final g = await anna.core
        .legeGruppeAn('Stoss', [for (final u in andere) u.core.myId]);
    for (final u in andere) {
      final ende = DateTime.now().add(const Duration(seconds: 20));
      while (!(await u.core.getGruppen()).any((x) => x.id == g.id) &&
          DateTime.now().isBefore(ende)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    // Die Bremse hat sich vom Aufbau erholt: Annas Eimer ist wieder voll.
    await Future<void>.delayed(const Duration(seconds: 5));

    // 10 Nachrichten x 3 Mitglieder = 30 Rahmen gegen einen Eimer von 12.
    final ids = <String>[];
    for (var i = 1; i <= 10; i++) {
      ids.add((await anna.core.sendMessage(g.id, 'Nachricht $i')).id);
    }

    for (final u in andere) {
      expect(
          await Nutzer.warteBis(
              () => ids.every((id) => u.eingang.any((m) => m.id == id)),
              frist: const Duration(seconds: 90)),
          isTrue,
          reason: '${u.name} bekam nur '
              '${ids.where((id) => u.eingang.any((m) => m.id == id)).length} '
              'von ${ids.length}');
    }
    // Und bei Anna kommt jede auf zwei Haken — die Quittungen laufen bei den
    // Mitgliedern durch dieselbe Bremse.
    expect(
        await Nutzer.warteBis(
            () => ids.every((id) => anna.statusEreignisse.any(
                (s) => s.messageId == id && s.status == MessageStatus.delivered)),
            frist: const Duration(seconds: 90)),
        isTrue,
        reason: 'nicht jede Nachricht kam auf zwei Haken');
    for (final u in andere) {
      final verlauf = await u.core.getMessages(g.id);
      expect(verlauf.where((m) => ids.contains(m.id)), hasLength(ids.length),
          reason: '${u.name}: jede genau einmal');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
