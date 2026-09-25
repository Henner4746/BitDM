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
    await st.entferneFaktor(st.sichtbareFaktoren.single.id);
    expect(st.faktoren, isEmpty,
        reason: 'uebrig blieb eine Sperre, deren einziger Schluessel loescht');
    expect(st.hatPanikPasswort, isFalse);
    expect(st.hatIdentitaet, isTrue);
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
