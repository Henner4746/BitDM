// identity_lifecycle_test.dart — nagelt den Ablauf rund um die Identitaet fest.
//
// Geprueft wird gegen FakeMessengerCore, weil der Fake die Verhaltensreferenz
// ist: RealMessengerCore muss sich aus Sicht der UI genauso verhalten. Was hier
// steht, ist damit gleichzeitig die Abnahmebedingung fuer die echte
// Implementierung.
//
// Der wichtigste Punkt: initialize() darf NIEMALS von sich aus eine Identitaet
// anlegen. Taete es das, haette ein Nutzer, der wiederherstellen will, bereits
// eine andere Identitaet, bevor er die Wahl ueberhaupt zu sehen bekommt.

import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Erster Start (noch keine Identitaet)', () {
    late FakeMessengerCore core;
    setUp(() => core = FakeMessengerCore());
    tearDown(() => core.dispose());

    test('initialize() meldet "keine Identitaet" und legt keine an', () async {
      expect(await core.initialize(), isFalse);
      expect(core.hasIdentity, isFalse);
      expect(core.isInitialized, isFalse);
    });

    test('myId ist vor einer Identitaet nicht abrufbar', () async {
      await core.initialize();
      expect(() => core.myId, throwsA(isA<NotInitializedException>()));
    });

    test('createIdentity() liefert 12 Woerter und macht die App nutzbar',
        () async {
      await core.initialize();
      final phrase = await core.createIdentity();

      expect(phrase.length, kRecoveryPhraseWords);
      expect(core.hasIdentity, isTrue);
      expect(core.isInitialized, isTrue);
      expect(core.myId, isNotEmpty);
    });

    test('die zurueckgegebene Phrase ist spaeter wieder abrufbar', () async {
      // Fuer "Wiederherstellungsphrase anzeigen" in den Einstellungen.
      await core.initialize();
      final phrase = await core.createIdentity();
      expect(await core.getRecoveryPhrase(), phrase);
    });

    test('zweimal createIdentity() ist ein Programmierfehler', () async {
      await core.initialize();
      await core.createIdentity();
      expect(core.createIdentity, throwsA(isA<StateError>()));
    });
  });

  group('Wiederherstellung', () {
    late FakeMessengerCore core;
    setUp(() => core = FakeMessengerCore());
    tearDown(() => core.dispose());

    const good = [
      'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
      'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'about',
    ];

    test('gueltige Phrase stellt eine Identitaet her', () async {
      await core.initialize();
      final id = await core.restoreIdentity(good);
      expect(id, isNotEmpty);
      expect(core.hasIdentity, isTrue);
      expect(core.myId, id);
    });

    test('zu kurze Phrase wird abgelehnt', () async {
      await core.initialize();
      expect(core.isValidRecoveryPhrase(good.sublist(0, 11)), isFalse);
      expect(() => core.restoreIdentity(good.sublist(0, 11)),
          throwsA(isA<InvalidRecoveryPhraseException>()));
    });

    test('Wiederherstellung ueber eine bestehende Identitaet ist ein Fehler',
        () async {
      // Sonst koennte ein Fehlgriff in der UI stillschweigend die vorhandene
      // Identitaet ersetzen — und damit alle Kontakte unerreichbar machen.
      await core.initialize();
      await core.createIdentity();
      expect(() => core.restoreIdentity(good), throwsA(isA<StateError>()));
    });

    test('isValidRecoveryPhrase prueft ohne Nebenwirkung', () async {
      await core.initialize();
      core.isValidRecoveryPhrase(good);
      expect(core.hasIdentity, isFalse, reason: 'darf nichts anlegen');
    });
  });

  group('Spaeterer Start (Identitaet liegt bereits vor)', () {
    late FakeMessengerCore core;
    setUp(() => core = FakeMessengerCore()..simulateExistingIdentity = true);
    tearDown(() => core.dispose());

    test('initialize() laedt die Identitaet und meldet true', () async {
      expect(await core.initialize(), isTrue);
      expect(core.hasIdentity, isTrue);
      expect(core.isInitialized, isTrue);
      expect(core.myId, isNotEmpty);
    });

    test('das Onboarding wird uebersprungen', () async {
      await core.initialize();
      // Genau daran erkennt die UI, dass sie direkt in die Chatliste darf.
      expect(core.createIdentity, throwsA(isA<StateError>()));
    });

    test('Phrase ist abrufbar', () async {
      await core.initialize();
      expect((await core.getRecoveryPhrase()).length, kRecoveryPhraseWords);
    });
  });

  group('Fehlerklasse', () {
    test('enthaelt die Phrase nicht in der Meldung', () {
      // Ausnahmetexte landen in Logs und Absturzberichten. Diese Phrase IST
      // die Identitaet des Nutzers — sie darf dort niemals auftauchen.
      const e = InvalidRecoveryPhraseException();
      expect(e.toString().toLowerCase(), isNot(contains('abandon')));
    });
  });
}
