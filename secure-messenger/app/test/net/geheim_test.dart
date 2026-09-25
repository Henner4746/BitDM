// geheim_test.dart — Teile der zwoelf Woerter bleiben nicht im eigenen Verlauf.
//
// Seit 25.09.2026: `sendMessage(..., geheim: true)`. Beim Empfaenger kommt der
// Text wie immer an; beim Absender steht er nur so lange, bis die Quittung
// da ist (der Nachversand braucht ihn), danach ist er geschwaerzt. Bis dahin
// lagen alle verschickten Teile im Klartext im Verlauf — die frische
// Anmeldung vor "Teile erzeugen" war mit einem Blick dorthin umgangen.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_geheim'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  test('EIN GEHEIMER TEXT KOMMT AN UND IST DANACH BEIM ABSENDER GESCHWAERZT', () async {
    if (relay == null) return;
    final alice = Nutzer('alice', '${tmp.path}/alice.db', relay!.uri);
    final bob = Nutzer('bob', '${tmp.path}/bob.db', relay!.uri);
    addTearDown(alice.aufraeumen);
    addTearDown(bob.aufraeumen);
    await alice.starten();
    await bob.starten();
    await alice.core.createIdentity();
    await bob.core.createIdentity();
    await alice.core.connect();
    await bob.core.connect();
    await alice.core.addContact(bob.core.myId, displayName: 'Bob');
    expect(
        await Nutzer.warteBis(() => bob.kontaktEreignisse
            .any((e) => e.type == ContactEventType.incomingRequest)),
        isTrue);
    await bob.core.acceptRequest(alice.core.myId);
    expect(
        await Nutzer.warteBis(() => alice.kontaktEreignisse
            .any((e) => e.type == ContactEventType.requestAccepted)),
        isTrue);

    const teil = 'BITDM-TEIL-2-2-1-ABCDEFGH';
    final m = await alice.core.sendMessage(bob.core.myId, teil, geheim: true);

    expect(await Nutzer.warteBis(() => bob.eingang.any((e) => e.id == m.id)), isTrue,
        reason: 'der Teil kam nicht an');
    expect(bob.eingang.firstWhere((e) => e.id == m.id).text, teil,
        reason: 'beim Empfaenger muss der volle Text stehen');

    Future<String?> beiAlice() async =>
        (await alice.core.getMessages(bob.core.myId))
            .where((e) => e.id == m.id)
            .firstOrNull
            ?.text;
    var zuletzt = await beiAlice();
    for (var i = 0; i < 60 && zuletzt == teil; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      zuletzt = await beiAlice();
    }
    expect(zuletzt, isNotNull, reason: 'die Nachricht selbst bleibt stehen');
    expect(zuletzt, isNot(contains('BITDM-TEIL')),
        reason: 'nach der Quittung darf der Teil nicht mehr im eigenen Verlauf stehen');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('OHNE "geheim" BLEIBT DER TEXT STEHEN (Gegenprobe)', () async {
    if (relay == null) return;
    final alice = Nutzer('alice', '${tmp.path}/alice2.db', relay!.uri);
    final bob = Nutzer('bob', '${tmp.path}/bob2.db', relay!.uri);
    addTearDown(alice.aufraeumen);
    addTearDown(bob.aufraeumen);
    await alice.starten();
    await bob.starten();
    await alice.core.createIdentity();
    await bob.core.createIdentity();
    await alice.core.connect();
    await bob.core.connect();
    await alice.core.addContact(bob.core.myId, displayName: 'Bob');
    expect(
        await Nutzer.warteBis(() => bob.kontaktEreignisse
            .any((e) => e.type == ContactEventType.incomingRequest)),
        isTrue);
    await bob.core.acceptRequest(alice.core.myId);
    expect(
        await Nutzer.warteBis(() => alice.kontaktEreignisse
            .any((e) => e.type == ContactEventType.requestAccepted)),
        isTrue);

    final m = await alice.core.sendMessage(bob.core.myId, 'ganz normal');
    expect(await Nutzer.warteBis(() => bob.eingang.any((e) => e.id == m.id)), isTrue);
    // Zeit fuer eine Quittung lassen, damit die Gegenprobe etwas beweist.
    await Future<void>.delayed(const Duration(seconds: 4));
    final dort = (await alice.core.getMessages(bob.core.myId)).firstWhere((e) => e.id == m.id);
    expect(dort.text, 'ganz normal');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
