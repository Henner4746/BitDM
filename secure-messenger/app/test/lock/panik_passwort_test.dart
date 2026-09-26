// panik_passwort_test.dart — das Passwort, das statt zu oeffnen loescht.
//
// Echter Tresor, echte Fachdatei, echtes Argon2id. Nur der Kern ist die
// Attrappe: was "alles loeschen" im echten Kern bedeutet, pruefen dessen
// eigene Tests (wipeEverything); hier geht es darum, WANN es ausgeloest wird
// und wann auf keinen Fall.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
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

class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};
  @override
  Future<String?> lies(String k) async => daten[k];
  @override
  Future<void> schreibe(String k, String v) async => daten[k] = v;
  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

const echtes = 'Kupfer-Regen-Turm-Zaun-9042';
const panik = 'Moewe-Anker-Salz-Kran-7715';

void main() {
  late Directory verzeichnis;
  late VaultSecretStore tresor;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-panik');
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: FakeBasis(),
      jetzt: () => 1000,
    );
    final ablage = FakeAblage();
    st = AppState(
      FakeMessengerCore()..simulateExistingIdentity = true,
      tresor: tresor,
      ablagen: (_) => ablage,
    );
    await st.boot();
  });

  tearDown(() {
    st.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('DAS PANIK-PASSWORT LOESCHT, DAS ECHTE OEFFNET', () async {
    await st.fuegePasswortHinzu(echtes);
    await st.setzePanikPasswort(panik);
    expect(st.hatPanikPasswort, isTrue);

    await st.sperreWieder();
    expect(await st.entsperreMitPasswort(echtes), isTrue);
    expect(st.hatIdentitaet, isTrue);

    await st.sperreWieder();
    expect(await st.entsperreMitPasswort(panik), isFalse);
    expect(st.hatIdentitaet, isFalse, reason: 'die Identitaet ist noch da');
    expect(st.gesperrt, isFalse,
        reason: 'danach soll die App aussehen wie frisch installiert, '
            'nicht wie gesperrt');
    expect(vaultDateiIn(verzeichnis.path).existsSync(), isFalse,
        reason: 'die Fachdatei liegt noch');
  });

  test('EGAL, IN WELCHER REIHENFOLGE DIE FAECHER STEHEN', () async {
    // Erst das Panik-Fach, dann das echte: die Schleife ueber die Faecher
    // probiert das Panik-Fach mit dem ECHTEN Passwort zuerst — das darf
    // weder loeschen noch das Oeffnen verhindern.
    await st.fuegePasswortHinzu(echtes);
    await st.setzePanikPasswort(panik);
    final v = (await tresor.faecher())!;
    final umgedreht = KeyVault(slots: v.slots.reversed.toList());
    await vaultDateiIn(verzeichnis.path).writeAsString(umgedreht.toJsonString());
    final frisch = VaultSecretStore(
        datei: vaultDateiIn(verzeichnis.path), basis: FakeBasis(), jetzt: () => 1);
    expect((await frisch.faecher())!.slots.first.id, st.einstellungen.panikFach);

    expect(await frisch.entsperreMit(PassphraseFactor(echtes, geraeteGebunden: false)),
        hasLength(16));
    frisch.sperre();
    await expectLater(
        frisch.entsperreMit(PassphraseFactor(panik, geraeteGebunden: false)),
        throwsA(isA<PanikAusgeloestException>()));
  });

  test('VON AUSSEN SIEHT DAS PANIK-FACH AUS WIE EIN PASSWORT-FACH', () async {
    await st.fuegePasswortHinzu(echtes);
    await st.setzePanikPasswort(panik);
    final slots = (await tresor.faecher())!.slots;
    expect(slots, hasLength(2));
    final a = slots[0].toJson()..remove('id')..remove('createdAt');
    final b = slots[1].toJson()..remove('id')..remove('createdAt');
    expect(a.keys.toSet(), b.keys.toSet());
    expect(a['kind'], b['kind']);
    expect(a['label'], b['label'], reason: 'die Beschriftung verraet es');
    expect((a['cipherText'] as String).length, (b['cipherText'] as String).length,
        reason: 'die Laenge verraet es');
    // Und die Einstellungen zeigen es nicht als zweites Passwort.
    expect(st.sichtbareFaktoren, hasLength(1));
  });

  test('DAS ECHTE PASSWORT KANN NICHT ZUM PANIK-PASSWORT WERDEN', () async {
    await st.fuegePasswortHinzu(echtes);
    await expectLater(st.setzePanikPasswort(echtes),
        throwsA(isA<PanikGleichException>()));
    expect(st.hatPanikPasswort, isFalse);
  });

  test('OHNE SPERRE GIBT ES KEIN PANIK-PASSWORT', () async {
    await expectLater(st.setzePanikPasswort(panik), throwsA(isA<StateError>()));
  });

  test('DER LETZTE ECHTE FAKTOR NIMMT DAS PANIK-FACH MIT', () async {
    await st.fuegePasswortHinzu(echtes);
    await st.setzePanikPasswort(panik);
    // Den letzten Faktor nimmt der Tresor nur mit frischem Nachweis heraus
    // (die Oberflaeche holt ihn ueber frischBestaetigt).
    expect(await st.bestaetigeMitPasswort(echtes), isTrue);
    await st.entferneFaktor(st.sichtbareFaktoren.single.id);
    expect(st.faktoren, isEmpty,
        reason: 'uebrig blieb eine Sperre, deren einziger Schluessel loescht');
    expect(st.hatPanikPasswort, isFalse);
    expect(st.hatIdentitaet, isTrue);
  });

  group('Panik-Wort oder -Satz (seit 26.09.2026)', () {
    const satz = 'rote Katze im Schnee';

    test('EIN SATZ MIT LEERZEICHEN LOESCHT — genau so getippt wie eingerichtet', () async {
      await st.fuegePasswortHinzu(echtes);
      await st.setzePanikPasswort(satz);
      await st.sperreWieder();
      // Ohne das Leerzeichen, anders geschrieben: nichts passiert.
      await expectLater(st.entsperreMitPasswort('roteKatzeimSchnee'),
          throwsA(isA<UnlockFailedException>()));
      await expectLater(st.entsperreMitPasswort('Rote Katze im Schnee'),
          throwsA(isA<UnlockFailedException>()),
          reason: 'keine Normalisierung — jedes Zeichen zaehlt');
      expect(st.hatIdentitaet, isTrue);
      expect(await st.entsperreMitPasswort(satz), isFalse);
      expect(st.hatIdentitaet, isFalse, reason: 'der Satz mit Leerzeichen loeschte nicht');
    });

    test('KURZ IST ERLAUBT — ab vier Zeichen, ohne Staerkeprobe', () async {
      await st.fuegePasswortHinzu(echtes);
      await expectLater(
          st.setzePanikPasswort('abc'),
          throwsA(isA<PanikWortUngueltigException>()
              .having((e) => e.grund, 'grund', PanikWortFehler.zuKurz)));
      await expectLater(st.setzePanikPasswort('  abc  '),
          throwsA(isA<PanikWortUngueltigException>()));
      await st.setzePanikPasswort('Kiwi');
      expect(st.hatPanikPasswort, isTrue);
    });

    test('LEERZEICHEN AM RAND WERDEN ABGELEHNT, NICHT STILL ENTFERNT', () async {
      await st.fuegePasswortHinzu(echtes);
      await expectLater(
          st.setzePanikPasswort(' $satz'),
          throwsA(isA<PanikWortUngueltigException>()
              .having((e) => e.grund, 'grund', PanikWortFehler.randLeer)));
      await expectLater(st.setzePanikPasswort('$satz '),
          throwsA(isA<PanikWortUngueltigException>()));
      expect(st.hatPanikPasswort, isFalse);
    });

    test('NUR FINGERABDRUCK + PANIK-WORT: DER SPERRBILDSCHIRM BIETET EIN PASSWORTFELD', () async {
      await st.fuegeBiometrieHinzu();
      expect(st.sperreBietetPasswort, isFalse,
          reason: 'ohne Passwort-Fach gibt es auch kein Feld');
      await st.setzePanikPasswort(satz);
      expect(st.hatFaktor(UnlockFactorKind.passphrase), isFalse,
          reason: 'die Einstellungen zeigten das Panik-Wort als Passwort');

      // Nach dem Sperren stehen die Einstellungen noch im Speicher — genau da
      // fehlte das Feld bis 26.09.2026.
      await st.sperreWieder();
      expect(st.sperreBietetPasswort, isTrue,
          reason: 'kein Passwortfeld — das Panik-Wort liess sich nirgends eingeben');

      // Und nach einem Kaltstart ebenso (neuer Tresor, neue AppState).
      final kalt = AppState(FakeMessengerCore()..simulateExistingIdentity = true,
          tresor: VaultSecretStore(
              datei: vaultDateiIn(verzeichnis.path), basis: FakeBasis(), jetzt: () => 1000),
          ablagen: (_) => FakeAblage());
      addTearDown(kalt.dispose);
      await kalt.boot();
      // Die Attrappe des Kerns kennt keine Sperre; es zaehlt, was der verschlossene
      // Tresor zeigt: Panik-Fach und Platzhalter, beide als Passwort-Fach.
      expect(kalt.faktoren.where((s) => s.kind == UnlockFactorKind.passphrase),
          hasLength(2));
      expect(kalt.sperreBietetPasswort, isTrue);

      expect(await st.entsperreMitPasswort(satz), isFalse);
      expect(st.hatIdentitaet, isFalse);
    });
  });

  test('EIN NEUES PANIK-PASSWORT ERSETZT DAS ALTE', () async {
    await st.fuegePasswortHinzu(echtes);
    await st.setzePanikPasswort(panik);
    await st.setzePanikPasswort('Birke-Nebel-Sand-Horn-3381');
    expect(st.faktoren, hasLength(2), reason: 'das alte Panik-Fach blieb stehen');
    await st.sperreWieder();
    // Das alte loest nichts mehr aus — es oeffnet schlicht nicht.
    await expectLater(st.entsperreMitPasswort(panik),
        throwsA(isA<UnlockFailedException>()));
    expect(st.hatIdentitaet, isTrue);
  });
}
