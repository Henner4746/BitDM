// vault_store_test.dart — der Uebergang zwischen "ungesperrt" und "gesperrt".
//
// Der rechnerische Teil der Faecher ist anderswo geprueft. Hier geht es um die
// Stelle, an der wirklich etwas verloren gehen kann: die Entropie wandert aus
// dem Schluesselspeicher in ein Fach und wieder zurueck. Geht dabei etwas
// schief, ist die Identitaet weg — und mit ihr alles, was auf diesem Telefon
// liegt.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/app_lock.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Der Schluesselspeicher des Geraets, im Speicher nachgebaut.
class FakeBasis implements SecretStore {
  Uint8List? inhalt;

  @override
  Future<Uint8List?> read() async => inhalt;

  @override
  Future<void> write(Uint8List e) async => inhalt = e;

  @override
  Future<void> delete() async => inhalt = null;
}

/// Der gesicherte Bereich, im Speicher nachgebaut.
class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};

  /// Ob die Anmeldung gerade fehlschlaegt — der abgebrochene Fingerabdruck.
  bool verweigert = false;

  @override
  Future<String?> lies(String k) async {
    if (verweigert) throw Exception('Anmeldung abgebrochen');
    return daten[k];
  }

  @override
  Future<void> schreibe(String k, String v) async {
    if (verweigert) throw Exception('Anmeldung abgebrochen');
    daten[k] = v;
  }

  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

Uint8List entropie([int start = 0]) =>
    Uint8List.fromList(List.generate(16, (i) => start + i));

void main() {
  late Directory verzeichnis;
  late FakeBasis basis;
  late FakeAblage ablage;
  late VaultSecretStore tresor;

  setUp(() {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-tresor');
    basis = FakeBasis()..inhalt = entropie();
    ablage = FakeAblage();
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: basis,
      jetzt: () => 1000,
    );
  });

  tearDown(() {
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  KeystoreFactor finger([String label = 'Fingerabdruck']) =>
      KeystoreFactor(ablage: ablage, label: label);

  group('Ohne ein einziges Fach bleibt alles wie bisher', () {
    test('gelesen wird aus dem Schluesselspeicher', () async {
      expect(await tresor.read(), entropie());
      expect(await tresor.hatFaecher(), isFalse);
    });

    test('geschrieben wird in den Schluesselspeicher', () async {
      await tresor.write(entropie(50));
      expect(basis.inhalt, entropie(50));
    });

    test('ohne Identitaet kommt null, kein Fehler', () async {
      basis.inhalt = null;
      expect(await tresor.read(), isNull);
    });
  });

  group('Der erste Faktor', () {
    test('DER Uebergang: die Entropie verlaesst den Schluesselspeicher',
        () async {
      // WENN DIESER TEST FEHLT, ist der Hardware-Stick wertlos: die Entropie
      // laege weiterhin im Schluesselspeicher und waere ohne ihn zu haben.
      await tresor.fuegeHinzu(finger());

      expect(basis.inhalt, isNull,
          reason: 'sonst gibt es die Entropie an zwei Stellen, und die '
              'schwaechere entscheidet');
      expect(await tresor.hatFaecher(), isTrue);
    });

    test('die Fachdatei liegt da, wo sie hingehoert', () async {
      await tresor.fuegeHinzu(finger());
      final datei = vaultDateiIn(verzeichnis.path);
      expect(datei.existsSync(), isTrue);
      final gelesen = KeyVault.fromJsonString(datei.readAsStringSync());
      expect(gelesen.slots, hasLength(1));
      expect(gelesen.slots.single.kind, UnlockFactorKind.biometric);
    });

    test('die Entropie steht NICHT im Klartext in der Datei', () async {
      await tresor.fuegeHinzu(finger());
      final text = vaultDateiIn(verzeichnis.path).readAsStringSync();
      expect(text.contains(base64.encode(entropie())), isFalse);
    });

    test('bleibt danach offen — der Nutzer soll sich nicht sofort neu anmelden',
        () async {
      await tresor.fuegeHinzu(finger());
      expect(tresor.istOffen, isTrue);
      expect(await tresor.read(), entropie());
    });
  });

  group('Nach einem Neustart', () {
    /// Baut denselben Tresor noch einmal — wie beim naechsten App-Start.
    VaultSecretStore neuStart() => VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 2000,
        );

    test('ist zu, und read() sagt das statt zu raten', () async {
      await tresor.fuegeHinzu(finger());
      final frisch = neuStart();

      expect(frisch.istOffen, isFalse);
      await expectLater(frisch.read(), throwsA(isA<LockedException>()));
    });

    test('geht mit dem Faktor wieder auf', () async {
      await tresor.fuegeHinzu(finger());
      final frisch = neuStart();

      expect(await frisch.entsperreMit(finger()), entropie());
      expect(await frisch.read(), entropie());
    });

    test('eine abgebrochene Anmeldung sperrt nicht aus', () async {
      await tresor.fuegeHinzu(finger());
      final frisch = neuStart();

      ablage.verweigert = true;
      await expectLater(frisch.entsperreMit(finger()),
          throwsA(isA<UnlockFailedException>()));

      ablage.verweigert = false;
      expect(await frisch.entsperreMit(finger()), entropie());
    });
  });

  group('Mehrere Faktoren', () {
    test('jeder oeffnet fuer sich — kein Faktor braucht einen anderen',
        () async {
      await tresor.fuegeHinzu(finger('Fingerabdruck'));
      await tresor.fuegeHinzu(
          PassphraseFactor('ein ziemlich langes Passwort mit Zahlen 12345',
              geraeteGebunden: false));

      final frisch = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 3000);
      expect(await frisch.entsperreMit(finger()), entropie());

      final noch = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 3000);
      expect(
          await noch.entsperreMit(PassphraseFactor(
              'ein ziemlich langes Passwort mit Zahlen 12345',
              geraeteGebunden: false)),
          entropie());
    });

    test('ein falsches Passwort verraet nicht, dass es das falsche war',
        () async {
      await tresor.fuegeHinzu(
          PassphraseFactor('ein ziemlich langes Passwort mit Zahlen 12345',
              geraeteGebunden: false));
      final frisch = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 3000);

      await expectLater(
          frisch.entsperreMit(PassphraseFactor(
              'ein anderes ziemlich langes Passwort 67890',
              geraeteGebunden: false)),
          throwsA(isA<UnlockFailedException>()));
    });

    test('zwei Sticks derselben Sorte: der Reihe nach probieren', () async {
      // Ein Ersatzstick ist der ganze Sinn mehrerer Faecher gleicher Art. Wer
      // hier nur das erste Fach probiert, sperrt den Nutzer mit dem zweiten
      // Stick aus.
      await tresor.fuegeHinzu(finger('erster'));
      final zweiteAblage = FakeAblage();
      await tresor.fuegeHinzu(
          KeystoreFactor(ablage: zweiteAblage, label: 'zweiter'));

      final frisch = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 3000);
      expect(
          await frisch
              .entsperreMit(KeystoreFactor(ablage: zweiteAblage)),
          entropie(),
          reason: 'das passende Fach ist das ZWEITE — das erste muss '
              'uebersprungen werden');
    });
  });

  group('Faktor entfernen', () {
    test('der letzte gibt die Entropie zurueck', () async {
      await tresor.fuegeHinzu(finger());
      final slot = (await tresor.faecher())!.slots.single;

      await tresor.entferne(slot.id, faktor: finger());

      expect(basis.inhalt, entropie(), reason: 'sonst ist die Identitaet weg');
      expect(await tresor.hatFaecher(), isFalse);
    });

    test('die Datei bleibt liegen — die Einstellungen stehen darin', () async {
      // In der Fachdatei steht mehr als Faecher: Sperrfrist und
      // Empfangstakt. Sie beim Entfernen des letzten Faktors mitzuloeschen
      // hiesse, dem Nutzer still zwei Einstellungen zurueckzusetzen, weil er
      // etwas ganz anderes getan hat.
      await tresor.fuegeHinzu(finger());
      await tresor.setzeEmpfangsTakt(60);
      final slot = (await tresor.faecher())!.slots.single;

      await tresor.entferne(slot.id, faktor: finger());

      expect(vaultDateiIn(verzeichnis.path).existsSync(), isTrue);
      final danach = KeyVault.fromJsonString(
          vaultDateiIn(verzeichnis.path).readAsStringSync());
      expect(danach.slots, isEmpty);
      expect(danach.empfangsTaktMinuten, 60);
    });

    test('der Fachschluessel im gesicherten Bereich wird mit aufgeraeumt',
        () async {
      await tresor.fuegeHinzu(finger());
      final slot = (await tresor.faecher())!.slots.single;
      expect(ablage.daten, isNotEmpty);

      await tresor.entferne(slot.id, faktor: finger());
      expect(ablage.daten, isEmpty,
          reason: 'ein Rest, der zu nichts mehr gehoert — beim '
              'Panik-Loeschen ist "fast alles weg" nichts wert');
    });

    test('ein nicht-letzter laesst die anderen unberuehrt', () async {
      await tresor.fuegeHinzu(finger('erster'));
      final zweiteAblage = FakeAblage();
      await tresor
          .fuegeHinzu(KeystoreFactor(ablage: zweiteAblage, label: 'zweiter'));
      final ersterSlot = (await tresor.faecher())!.slots.first;

      await tresor.entferne(ersterSlot.id, faktor: finger());

      final frisch = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 3000);
      expect(await frisch.hatFaecher(), isTrue);
      expect(
          await frisch.entsperreMit(KeystoreFactor(ablage: zweiteAblage)),
          entropie());
    });

    test('bei zugem Tresor geht es NICHT — sonst waere die Sperre ein Tipp weit',
        () async {
      await tresor.fuegeHinzu(finger());
      final slot = (await tresor.faecher())!.slots.single;

      final frisch = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path),
          basis: basis,
          jetzt: () => 3000);
      await expectLater(frisch.entferne(slot.id),
          throwsA(isA<LockedException>()));
      expect(vaultDateiIn(verzeichnis.path).existsSync(), isTrue);
    });
  });

  group('Wenn etwas schiefgeht', () {
    test('eine halbe Fachdatei wird gemeldet, nicht ueberschrieben', () async {
      vaultDateiIn(verzeichnis.path).writeAsStringSync('{"version": 1, "slo');
      await expectLater(tresor.faecher(), throwsA(isA<VaultFormatException>()));
    });

    test('Faecher aus einer neueren App-Fassung werden nicht geraten', () async {
      vaultDateiIn(verzeichnis.path)
          .writeAsStringSync('{"version": 99, "slots": []}');
      await expectLater(tresor.faecher(), throwsA(isA<VaultFormatException>()));
    });

    test('neue Entropie bei bestehenden Faechern wird abgelehnt', () async {
      await tresor.fuegeHinzu(finger());
      await expectLater(
          tresor.write(entropie(99)), throwsA(isA<StateError>()));
    });

    test('Panik-Loeschen raeumt BEIDES weg', () async {
      await tresor.fuegeHinzu(finger());
      await tresor.delete();

      expect(vaultDateiIn(verzeichnis.path).existsSync(), isFalse);
      expect(basis.inhalt, isNull);
      expect(tresor.istOffen, isFalse);
    });

    test('ohne Identitaet gibt es nichts zu verschliessen', () async {
      basis.inhalt = null;
      await expectLater(
          tresor.fuegeHinzu(finger()), throwsA(isA<StateError>()));
    });
  });
}
