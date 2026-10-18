// nachweis_beim_hinzufuegen_test.dart — ein neuer Faktor ist ein neuer Ausweis.
//
// DIE LUECKE (Sicherheitspruefung vom 18.10.2026): nur das ENTFERNEN eines
// Faktors verlangte eine frische Anmeldung, das Hinzufuegen nicht. Wer das
// entsperrte Telefon einen Moment in der Hand hatte, legte ein eigenes
// App-Passwort an und wies sich danach damit aus — fuer die zwoelf Woerter,
// die Sperrfrist "nie", die Fernloeschung, die Teilgeheimnisse.
//
// Geprueft wird beides: dass das Hinzufuegen ohne Nachweis scheitert, UND dass
// ein Faktor aus der laufenden Sitzung kein Nachweis ist. Das zweite haelt,
// falls das erste je wieder ein Loch bekommt.

import 'dart:async';
import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/app_lock.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i + 3));
  @override
  Future<Uint8List?> read() async => inhalt;
  @override
  Future<void> write(Uint8List e) async => inhalt = e;
  @override
  Future<void> delete() async => inhalt = null;
}

/// Der gesicherte Bereich. [halt] laesst das Schreiben warten — so laesst
/// sich mitten im Anlegen sperren.
class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};
  Completer<void>? halt;

  @override
  Future<String?> lies(String k) async => daten[k];
  @override
  Future<void> schreibe(String k, String v) async {
    final h = halt;
    if (h != null) await h.future;
    daten[k] = v;
  }

  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

const echtes = 'Kupfer-Regen-Turm-Zaun-9042';
const fremdes = 'Moewe-Anker-Salz-Kran-7715';

PassphraseFactor pw(String p) => PassphraseFactor(p, geraeteGebunden: false);

void main() {
  late Directory verzeichnis;
  late FakeBasis basis;
  late FakeAblage ablage;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-nachweis-neu');
    basis = FakeBasis();
    ablage = FakeAblage();
  });

  tearDown(() {
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  VaultSecretStore tresor() => VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path), basis: basis, jetzt: () => 1000);

  KeystoreFactor finger([FakeAblage? a]) => KeystoreFactor(ablage: a ?? ablage);

  KeyVault aufPlatte() => KeyVault.fromJsonString(
      vaultDateiIn(verzeichnis.path).readAsStringSync());

  /// Wie nach einem Neustart: der Fingerabdruck ist eingerichtet, und der
  /// Tresor wurde mit ihm geoeffnet — die Lage, in der jemand das entsperrte
  /// Telefon in die Hand bekommt.
  Future<VaultSecretStore> mitFingerGeoeffnet() async {
    await tresor().fuegeHinzu(finger());
    final t = tresor();
    await t.entsperreMit(finger());
    return t;
  }

  group('Tresor: Hinzufuegen ohne Nachweis schlaegt fehl', () {
    test('DER ANGRIFF: ein eigenes Passwort neben dem Fingerabdruck', () async {
      final t = await mitFingerGeoeffnet();
      final vorher = aufPlatte().toJsonString();

      await expectLater(t.fuegeHinzu(pw(fremdes)),
          throwsA(isA<NachweisNoetigException>()));

      expect(aufPlatte().toJsonString(), vorher,
          reason: 'die Fachdatei darf sich nicht veraendert haben');
      await expectLater(t.weiseNach(pw(fremdes)),
          throwsA(isA<UnlockFailedException>()),
          reason: 'es gibt kein Fach, das dieses Passwort oeffnet');
    });

    test('auch kein zweiter Fingerabdruck, kein Stick, kein Panik-Fach',
        () async {
      final t = await mitFingerGeoeffnet();
      final zweite = FakeAblage();
      await expectLater(t.fuegeHinzu(finger(zweite)),
          throwsA(isA<NachweisNoetigException>()));
      expect(zweite.daten, isEmpty,
          reason: 'ohne Nachweis wird gar nicht erst angelegt');
      await expectLater(t.fuegePanikHinzu(pw(fremdes)),
          throwsA(isA<NachweisNoetigException>()));
      expect(aufPlatte().slots, hasLength(1));
    });

    test('mit Nachweis geht es — einmal', () async {
      final t = await mitFingerGeoeffnet();
      final n = await t.weiseNach(finger());
      await t.fuegeHinzu(pw(echtes), nachweis: n);
      expect((await t.faecher())!.slots, hasLength(2));

      await expectLater(t.fuegeHinzu(finger(FakeAblage()), nachweis: n),
          throwsA(isA<NachweisNoetigException>()),
          reason: 'ein Nachweis gilt fuer genau eine Aenderung');
    });

    test('ein zu schwaches Passwort verbraucht den Nachweis nicht', () async {
      // Sonst kostete jeder Tippfehler beim neuen Passwort einen weiteren
      // Fingerabdruck — der Nachweis wird erst eingeloest, wenn das Fach steht.
      final t = await mitFingerGeoeffnet();
      final n = await t.weiseNach(finger());
      await expectLater(t.fuegeHinzu(pw('1234'), nachweis: n),
          throwsA(isA<WeakPassphraseException>()));
      await t.fuegeHinzu(pw(echtes), nachweis: n);
      expect((await t.faecher())!.slots, hasLength(2));
    });

    test('ein verfallener Nachweis gilt nicht', () async {
      var uhr = 1000;
      await tresor().fuegeHinzu(finger());
      final t = VaultSecretStore(
          datei: vaultDateiIn(verzeichnis.path), basis: basis, jetzt: () => uhr);
      await t.entsperreMit(finger());
      final n = await t.weiseNach(finger());
      uhr += VaultSecretStore.nachweisGueltigkeit.inMilliseconds + 1;
      await expectLater(t.fuegeHinzu(pw(echtes), nachweis: n),
          throwsA(isA<NachweisNoetigException>()));
    });

    test('bei zugem Tresor: gar nicht', () async {
      await tresor().fuegeHinzu(finger());
      await expectLater(
          tresor().fuegeHinzu(pw(echtes)), throwsA(isA<LockedException>()));
    });

    test('WIRD MITTEN IM ANLEGEN GESPERRT, wird das neue Fach verworfen',
        () async {
      // Das Anlegen dauert: Argon2id, zwei Stick-Beruehrungen, ein
      // Systemdialog. Sperrt die App dazwischen (etwa im Hintergrund), darf
      // danach kein Fach stehen, das mit der alten Erlaubnis entstand — und
      // der Tresor darf nicht still wieder aufgehen.
      final t = await mitFingerGeoeffnet();
      final n = await t.weiseNach(finger());
      final langsam = FakeAblage()..halt = Completer<void>();
      final anlegen = t.fuegeHinzu(finger(langsam), nachweis: n);
      await Future<void>.delayed(Duration.zero);

      t.sperre();
      langsam.halt!.complete();

      await expectLater(anlegen, throwsA(isA<NachweisNoetigException>()));
      expect(t.istOffen, isFalse);
      expect(aufPlatte().slots, hasLength(1));
      expect(langsam.daten, isEmpty,
          reason: 'der Fachschluessel im Geraet gehoert zu keinem Fach mehr');
    });

    test('DER ERSTE Faktor braucht keinen Nachweis — es gibt nichts, womit',
        () async {
      final t = tresor();
      await t.fuegeHinzu(pw(echtes));
      expect(t.istOffen, isTrue);
      expect(await t.hatFaecher(), isTrue);
    });
  });

  group('Tresor: ein Faktor aus dieser Sitzung ist kein Nachweis', () {
    test('das gerade angelegte Passwort oeffnet weiseNach nicht', () async {
      final t = await mitFingerGeoeffnet();
      final neu = await t.fuegeHinzu(pw(echtes),
          nachweis: await t.weiseNach(finger()));

      expect(t.taugtAlsNachweis(neu.id), isFalse);
      await expectLater(t.weiseNach(pw(echtes)),
          throwsA(isA<UnlockFailedException>()));
      // Der alte Faktor gilt weiter.
      expect(await t.weiseNach(finger()), isA<FrischerNachweis>());
    });

    test('auch nicht mit der Kennung des Fachs', () async {
      final t = await mitFingerGeoeffnet();
      final neu = await t.fuegeHinzu(pw(echtes),
          nachweis: await t.weiseNach(finger()));
      await expectLater(t.weiseNach(pw(echtes), slotId: neu.id),
          throwsA(isA<UnlockFailedException>()));
    });

    test('nach dem naechsten Entsperren zaehlt es wie jedes andere', () async {
      final t = await mitFingerGeoeffnet();
      final neu = await t.fuegeHinzu(pw(echtes),
          nachweis: await t.weiseNach(finger()));
      t.sperre();
      await t.entsperreMit(finger());

      expect(t.taugtAlsNachweis(neu.id), isTrue);
      expect(await t.weiseNach(pw(echtes)), isA<FrischerNachweis>());
    });

    test('DIE ERSTE SPERRE: ihr Faktor ist der Ausweis', () async {
      // Die Sperre entsteht erst in dieser Sitzung. Es gibt kein aelteres Fach,
      // und vorher war die App offen — ein Ausweis war gar nicht zu verlangen.
      // Ohne diese Ausnahme liesse sich direkt nach dem Einrichten kein
      // zweiter Faktor anlegen und kein Wort zeigen, bis die App einmal zu war.
      final t = tresor();
      final erster = await t.fuegeHinzu(pw(echtes));
      expect(t.taugtAlsNachweis(erster.id), isTrue);
      final n = await t.weiseNach(pw(echtes));
      await t.fuegeHinzu(finger(), nachweis: n);
      expect((await t.faecher())!.slots, hasLength(2));
    });

    test('auch nach dem Entfernen der letzten Sperre', () async {
      // Letzten Faktor raus, App ungesperrt — der naechste ist wieder eine
      // ERSTE Sperre und damit der Ausweis.
      final t = await mitFingerGeoeffnet();
      await t.entferne(aufPlatte().slots.single.id,
          faktor: finger(), nachweis: await t.weiseNach(finger()));
      final neu = await t.fuegeHinzu(pw(echtes));
      expect(t.taugtAlsNachweis(neu.id), isTrue);
      expect(await t.weiseNach(pw(echtes)), isA<FrischerNachweis>());
    });
  });

  group('AppState', () {
    late VaultSecretStore t;
    late AppState st;

    setUp(() async {
      // Fingerabdruck aus einer frueheren Sitzung, heute damit entsperrt.
      await tresor().fuegeHinzu(finger());
      t = tresor();
      st = AppState(FakeMessengerCore()..simulateExistingIdentity = true,
          tresor: t, ablagen: (_) => ablage);
      await st.boot();
      // Die Attrappe des Kerns kennt keine Sperre und startet offen — der
      // Tresor ist es nicht. Also so, wie es auf dem Geraet aussieht:
      // gesperrt, dann mit dem Fingerabdruck geoeffnet.
      await st.sperreWieder();
      expect(st.gesperrt, isTrue);
      expect(await st.entsperreMitBiometrie(), isTrue);
      expect(t.istOffen, isTrue);
    });

    tearDown(() => st.dispose());

    test('DER ANGRIFF ueber die App: kein eigenes Passwort ohne Fingerabdruck',
        () async {
      await expectLater(st.fuegePasswortHinzu(fremdes),
          throwsA(isA<NachweisNoetigException>()));
      expect(st.hatFaktor(UnlockFactorKind.passphrase), isFalse);
      expect(await st.bestaetigeMitPasswort(fremdes), isFalse,
          reason: 'damit liesse sich dann die frische Anmeldung bestehen');
    });

    test('nach frischBestaetigt geht es, und der Beleg ist danach weg',
        () async {
      expect(await st.bestaetigeMitBiometrie(), isTrue);
      await st.fuegePasswortHinzu(echtes);
      expect(st.hatFaktor(UnlockFactorKind.passphrase), isTrue);

      await expectLater(st.fuegeGeraetePinHinzu(),
          throwsA(isA<NachweisNoetigException>()));
    });

    test('ein frisch angelegter Faktor besteht frischBestaetigt nicht',
        () async {
      expect(await st.bestaetigeMitBiometrie(), isTrue);
      await st.fuegePasswortHinzu(echtes);

      expect(st.kannNachweisen(UnlockFactorKind.passphrase), isFalse,
          reason: 'die Oberflaeche soll ihn gar nicht erst anbieten');
      expect(st.kannNachweisen(UnlockFactorKind.biometric), isTrue);
      expect(await st.bestaetigeMitPasswort(echtes), isFalse);

      // Nach dem naechsten Entsperren schon.
      await st.sperreWieder();
      expect(await st.entsperreMitBiometrie(), isTrue);
      expect(st.kannNachweisen(UnlockFactorKind.passphrase), isTrue);
      expect(await st.bestaetigeMitPasswort(echtes), isTrue);
    });

    test('Panik-Wort: ohne Nachweis abgelehnt — und kein Passwort-Orakel',
        () async {
      expect(await st.bestaetigeMitBiometrie(), isTrue);
      await st.fuegePasswortHinzu(echtes);

      // Ohne Nachweis darf nicht einmal herauskommen, ob ein Wort das echte
      // Passwort ist (PanikGleichException) — sonst liesse es sich mit dem
      // entsperrten Telefon durchprobieren.
      await expectLater(st.setzePanikPasswort(echtes),
          throwsA(isA<NachweisNoetigException>()));
      await expectLater(st.setzePanikPasswort(fremdes),
          throwsA(isA<NachweisNoetigException>()));
      expect(st.hatPanikPasswort, isFalse);

      expect(await st.bestaetigeMitBiometrie(), isTrue);
      await st.setzePanikPasswort(fremdes);
      expect(st.hatPanikPasswort, isTrue);
    });
  });
}
