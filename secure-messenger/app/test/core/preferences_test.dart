// preferences_test.dart — die drei Einstellungen, die bis zum 25.07.2026
// gelogen haben.
//
// Die Oberflaeche bot an: "Nachrichten verschwinden nach 24 Stunden",
// "Screenshots blockieren" und "Lesebestaetigungen aus". Keine davon tat
// irgendetwas — es waren drei Variablen in main.dart. Ein Versprechen, das die
// Software nicht haelt, ist schlimmer als eine fehlende Funktion: jemand
// schreibt etwas, das er sonst nicht schriebe.
//
// Diese Tests halten fest, dass die Schalter jetzt wirken.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/relay_process.dart';
import '../support/nutzer.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_prefs'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows
    }
  });

  Nutzer nutzer(String name) =>
      Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);

  group('Einstellungen ueberleben', () {
    test('gespeicherte Werte kommen nach dem Neustart zurueck', () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();

      await a.core.setPreferences(const AppPreferences(
        readReceipts: false,
        messageLifetime: Duration(hours: 24),
        blockScreenshots: false,
      ));

      await a.neustart();
      final p = await a.core.getPreferences();
      expect(p.readReceipts, isFalse);
      expect(p.messageLifetime, const Duration(hours: 24));
      expect(p.blockScreenshots, isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('ohne Zutun sind Lesebestaetigungen an und nichts verfaellt',
        () async {
      final a = nutzer('alice');
      addTearDown(a.aufraeumen);
      await a.starten();
      await a.core.createIdentity();

      final p = await a.core.getPreferences();
      expect(p.readReceipts, isTrue);
      expect(p.messageLifetime, isNull,
          reason: 'nichts darf ungefragt verschwinden');
      expect(p.blockScreenshots, isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('Verschwinden nach einer Frist', () {
    test('eine abgelaufene Nachricht ist weg — auf BEIDEN Geraeten', () async {
      // Der eigentliche Punkt. Eine nur oertliche Loeschung waere eine
      // Halbwahrheit: beim anderen laege die Nachricht weiter.
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

      // Eine Sekunde Lebensdauer, damit der Test nicht 24 Stunden dauert.
      await a.core.setPreferences(
          const AppPreferences(messageLifetime: Duration(seconds: 1)));

      await a.core.sendMessage(b.core.myId, 'das hier ist gleich weg');
      expect(await Nutzer.warteBis(() => b.eingang.isNotEmpty), isTrue);

      // Beide haben sie.
      expect(await a.core.getMessages(b.core.myId), hasLength(1));
      expect(await b.core.getMessages(a.core.myId), hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 1400));

      expect(await a.core.purgeExpiredMessages(), 1);
      expect(await b.core.purgeExpiredMessages(), 1,
          reason: 'BOB muss auch loeschen — die Frist reist in der '
              'verschluesselten Nutzlast mit');

      expect(await a.core.getMessages(b.core.myId), isEmpty);
      expect(await b.core.getMessages(a.core.myId), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('ohne Frist verschwindet nichts', () async {
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

      await a.core.sendMessage(b.core.myId, 'das bleibt');
      await Nutzer.warteBis(() => b.eingang.isNotEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await a.core.purgeExpiredMessages(), 0);
      expect(await b.core.purgeExpiredMessages(), 0);
      expect(await a.core.getMessages(b.core.myId), hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('eine bereits gespeicherte Nachricht behaelt ihre Frist', () async {
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

      await a.core.setPreferences(
          const AppPreferences(messageLifetime: Duration(seconds: 1)));
      await a.core.sendMessage(b.core.myId, 'befristet');
      await Nutzer.warteBis(() => b.eingang.isNotEmpty);

      // Frist abschalten — die bestehende Nachricht bleibt trotzdem befristet.
      await a.core.setPreferences(const AppPreferences());
      await Future<void>.delayed(const Duration(milliseconds: 1400));

      expect(await a.core.purgeExpiredMessages(), 1,
          reason: 'die Nachricht wurde mit Frist gespeichert und behaelt sie');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('Lesebestaetigungen', () {
    test('ausgeschaltet wird keine gesendet', () async {
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

      // BOB schaltet sie aus.
      await b.core.setPreferences(const AppPreferences(readReceipts: false));

      await a.core.sendMessage(b.core.myId, 'hallo');
      expect(await Nutzer.warteBis(() => b.eingang.isNotEmpty), isTrue);
      // Zustellbestaetigung kommt weiterhin — die ist nicht abschaltbar und
      // verraet auch nichts ueber das Verhalten des Nutzers.
      expect(
          await Nutzer.warteBis(() => a.statusEreignisse
              .any((s) => s.status == MessageStatus.delivered)),
          isTrue);

      a.statusEreignisse.clear();
      await b.core.markRead(a.core.myId);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(a.statusEreignisse.where((s) => s.status == MessageStatus.read),
          isEmpty,
          reason: 'mit ausgeschalteter Bestaetigung darf Alice nie "gelesen" '
              'sehen');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('eingeschaltet kommt sie an', () async {
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

      await a.core.sendMessage(b.core.myId, 'hallo');
      await Nutzer.warteBis(() => b.eingang.isNotEmpty);

      await b.core.markRead(a.core.myId);
      expect(
          await Nutzer.warteBis(() => a.statusEreignisse
              .any((s) => s.status == MessageStatus.read)),
          isTrue,
          reason: 'ohne Abschalten muss "gelesen" ankommen');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
