// vier_faktoren_test.dart — die vier Wege in die App, jeder fuer sich.
//
// DREI FEHLER, DIE HIER ABGEFANGEN WERDEN, WAREN AM 25.07.2026 ECHT:
//
//   1. Ein Druck auf "Passkey" entfernte das Fingerabdruck-Fach. Die Zeilen
//      der Oberflaeche waren nicht sauber auf Faktorarten abgebildet — alles
//      ausser dem Stick landete auf der Biometrie.
//   2. Fingerabdruck und Geraetesperre teilten sich denselben Platz im
//      gesicherten Bereich. Das eine zu entfernen nahm dem anderen den
//      Schluessel mit.
//   3. Die Biometrie ging an, ohne je nach einem Finger zu fragen — die
//      Ablage ohne Anmeldezwang schrieb die Daten auf einen Schluessel um,
//      der keine verlangt.
//
// Der dritte laesst sich hier nur zur Haelfte pruefen: ob Android wirklich
// abfragt, zeigt erst das Geraet. Pruefbar ist die Ursache — dass jede Ablage
// ihren eigenen Namensraum hat und keine der anderen dazwischenfunkt.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/geraete_fach.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i + 7));
  @override
  Future<Uint8List?> read() async => inhalt;
  @override
  Future<void> write(Uint8List e) async => inhalt = e;
  @override
  Future<void> delete() async => inhalt = null;
}

/// Ein gesicherter Bereich, der sich merkt, WER ihn benutzt hat.
class FakeAblage implements SchluesselAblage {
  FakeAblage(this.name);
  final String name;
  final Map<String, String> daten = {};

  @override
  Future<String?> lies(String k) async => daten[k];
  @override
  Future<void> schreibe(String k, String v) async => daten[k] = v;
  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

const String starkesPasswort = 'Kupfer-Regen-Turm-Zaun-9042';

void main() {
  late Directory verzeichnis;
  late VaultSecretStore tresor;
  late FakeAblage bioAblage;
  late FakeAblage pinAblage;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-vier');
    bioAblage = FakeAblage('biometrie');
    pinAblage = FakeAblage('geraetepin');
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: FakeBasis(),
      jetzt: () => 1000,
    );
    st = AppState(
      FakeMessengerCore()..simulateExistingIdentity = true,
      tresor: tresor,
      ablagen: (art) =>
          art == UnlockFactorKind.deviceCredential ? pinAblage : bioAblage,
    );
    await st.boot();
  });

  tearDown(() {
    st.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Jeder Faktor fuer sich', () {
    test('Fingerabdruck: einrichten und wieder oeffnen', () async {
      await st.fuegeBiometrieHinzu();
      expect(st.hatFaktor(UnlockFactorKind.biometric), isTrue);

      await st.sperreWieder();
      expect(await st.entsperreMitBiometrie(), isTrue);
      expect(st.gesperrt, isFalse);
    });

    test('Geraetesperre: einrichten und wieder oeffnen', () async {
      await st.fuegeGeraetePinHinzu();
      expect(st.hatFaktor(UnlockFactorKind.deviceCredential), isTrue);

      await st.sperreWieder();
      expect(await st.entsperreMitGeraetePin(), isTrue);
      expect(st.gesperrt, isFalse);
    });

    test('App-Passwort: einrichten und wieder oeffnen', () async {
      await st.fuegePasswortHinzu(starkesPasswort);
      expect(st.hatFaktor(UnlockFactorKind.passphrase), isTrue);

      await st.sperreWieder();
      expect(await st.entsperreMitPasswort(starkesPasswort), isTrue);
      expect(st.gesperrt, isFalse);
    });

    test('alle drei nebeneinander, jeder oeffnet allein', () async {
      await st.fuegeBiometrieHinzu();
      await st.fuegeGeraetePinHinzu();
      await st.fuegePasswortHinzu(starkesPasswort);
      expect(st.faktoren, hasLength(3));

      for (final oeffne in [
        st.entsperreMitBiometrie,
        st.entsperreMitGeraetePin,
        () => st.entsperreMitPasswort(starkesPasswort),
      ]) {
        await st.sperreWieder();
        expect(await oeffne(), isTrue);
      }
    });
  });

  group('DER GEMELDETE FEHLER: ein Faktor loescht den anderen', () {
    test('die Geraetesperre einzurichten laesst den Fingerabdruck stehen',
        () async {
      await st.fuegeBiometrieHinzu();
      final bioSlot = st.faktoren.single.id;

      await st.fuegeGeraetePinHinzu();

      expect(st.faktoren, hasLength(2),
          reason: 'am 25.07.2026 war es hier eins: die Oberflaeche bildete '
              'alles ausser dem Stick auf die Biometrie ab, und das Anlegen '
              'des zweiten Faktors entfernte den ersten');
      expect(st.faktoren.any((s) => s.id == bioSlot), isTrue);
    });

    test('die Geraetesperre zu entfernen laesst den Fingerabdruck stehen',
        () async {
      await st.fuegeBiometrieHinzu();
      await st.fuegeGeraetePinHinzu();
      final pinSlot = st.faktoren
          .firstWhere((s) => s.kind == UnlockFactorKind.deviceCredential);

      await st.entferneFaktor(pinSlot.id);

      expect(st.hatFaktor(UnlockFactorKind.biometric), isTrue);
      expect(st.hatFaktor(UnlockFactorKind.deviceCredential), isFalse);

      await st.sperreWieder();
      expect(await st.entsperreMitBiometrie(), isTrue,
          reason: 'der Fingerabdruck muss weiter oeffnen — sein Fachschluessel '
              'liegt in einer ANDEREN Ablage und darf nicht mitgeloescht '
              'werden');
    });

    test('die beiden Ablagen sind wirklich getrennt', () async {
      // DIE URSACHE des dritten Fehlers: teilen sich beide denselben Platz im
      // gesicherten Bereich, schreibt die eine der anderen den Schluessel um —
      // und die Anmeldung faellt still weg.
      await st.fuegeBiometrieHinzu();
      await st.fuegeGeraetePinHinzu();

      expect(bioAblage.daten, hasLength(1));
      expect(pinAblage.daten, hasLength(1));
      expect(bioAblage.daten.keys.first, isNot(pinAblage.daten.keys.first),
          reason: 'gleiche Kennung hiesse: dasselbe Fach, zweimal gezaehlt');
    });

    test('jede Zeile der Oberflaeche zeigt auf eine EIGENE Faktorart', () {
      // GENAU HIER SASS DER FEHLER. Zeigen zwei Zeilen auf dieselbe Art, dann
      // entfernt die eine das Fach der anderen — und die Zeile, die man
      // gedrueckt hat, sagt davon nichts.
      final arten = zeilenArt.values.toList();
      expect(arten.toSet(), hasLength(arten.length),
          reason: 'zwei Zeilen auf derselben Faktorart: ein Druck auf die eine '
              'entfernt das Fach der anderen');
    });

    test('jede echte Zeile steht auch in der Liste', () {
      for (final schluessel in zeilenArt.keys) {
        expect(zugriffsZeilen, contains(schluessel),
            reason: 'ein Faktor, den es gibt, den aber niemand sieht');
      }
    });

    test('die beiden Arten sind auch im Geraet verschieden', () {
      // Jede Art bekommt einen eigenen Schluessel im gesicherten Bereich
      // (SchluesselfachKanal.kt leitet den Alias aus dieser Kennung ab).
      // Waeren sie gleich, waere es EIN Faktor mit zwei Namen — und das
      // Entfernen des einen naehme dem anderen den Schluessel mit.
      expect(GeraeteArt.biometrie.kennung,
          isNot(GeraeteArt.geraetesperre.kennung));
      expect(GeraeteArt.values.map((a) => a.kennung).toSet(),
          hasLength(GeraeteArt.values.length));
    });
  });

  group('Was schiefgehen darf', () {
    test('ein zu schwaches Passwort wird abgelehnt, mit Zahlen', () async {
      // Dieses Fach haengt an nichts als dem Passwort. "1234" waere in
      // Sekunden durchprobiert, und die App wuerde trotzdem einen Haken
      // zeigen.
      await expectLater(
          st.fuegePasswortHinzu('1234'),
          throwsA(isA<WeakPassphraseException>()
              .having((e) => e.verlangteBits, 'verlangte Bits', 60)));
      expect(st.faktoren, isEmpty);
    });

    test('das falsche Passwort oeffnet nicht — und sagt nicht, warum',
        () async {
      await st.fuegePasswortHinzu(starkesPasswort);
      await st.sperreWieder();

      await expectLater(st.entsperreMitPasswort('Kupfer-Regen-Turm-Zaun-9043'),
          throwsA(isA<UnlockFailedException>()),
          reason: 'ABSICHTLICH ohne Grund: ein Fehler, der zwischen falschem '
              'Passwort und beschaedigtem Fach unterscheidet, ist ein Hinweis '
              'fuer jeden, der durchprobiert');
      expect(st.gesperrt, isTrue);
    });

    test('der falsche Faktor an der falschen Zeile oeffnet nicht', () async {
      await st.fuegeBiometrieHinzu();
      await st.sperreWieder();

      await expectLater(
          st.entsperreMitGeraetePin(), throwsA(isA<UnlockFailedException>()),
          reason: 'es gibt kein Fach dieser Art — das muss auffallen, statt '
              'still das falsche zu oeffnen');
    });

    test('der letzte Faktor laesst sich entfernen und die App bleibt offen',
        () async {
      await st.fuegePasswortHinzu(starkesPasswort);
      final slot = st.faktoren.single.id;

      await st.entferneFaktor(slot);

      expect(st.faktoren, isEmpty);
      expect(st.gesperrt, isFalse,
          reason: 'ohne Faktor gaebe es keinen Weg wieder hinein — sich dann '
              'auszusperren waere eine Falle');
    });
  });
}
