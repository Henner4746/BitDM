// fern_codewort_anmeldung_test.dart — das Fernloesch-Codewort setzen,
// aendern und entfernen geht nur mit dem Beleg einer FRISCHEN Anmeldung.
//
// Echter Tresor und echtes Argon2id wie in panik_passwort_test.dart; der Kern
// ist die Attrappe (was das Codewort beim Empfang tut, prueft
// test/net/fern_codewort_test.dart am echten Kern).

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
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
const wort = 'Leuchtturm am Hafen';

void main() {
  late Directory verzeichnis;
  late FakeMessengerCore kern;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-codewort-anmeldung');
    kern = FakeMessengerCore()..simulateExistingIdentity = true;
    final ablage = FakeAblage();
    st = AppState(
      kern,
      tresor: VaultSecretStore(
        datei: vaultDateiIn(verzeichnis.path),
        basis: FakeBasis(),
        jetzt: () => 1000,
      ),
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

  test('OHNE SPERRE GEHT ES OHNE BELEG — es gibt nichts, womit man sich ausweisen koennte',
      () async {
    await st.setzeFernCodewort(wort);
    expect(st.fernCodewortGesetzt, isTrue);
    expect(await kern.hatFernCodewort(), isTrue);
  });

  test('MIT SPERRE: OHNE FRISCHE ANMELDUNG WIRD NICHTS GESETZT', () async {
    await st.fuegePasswortHinzu(echtes);
    await expectLater(st.setzeFernCodewort(wort), throwsA(isA<NachweisNoetigException>()));
    expect(await kern.hatFernCodewort(), isFalse,
        reason: 'wer das offene Telefon hat, setzte ein eigenes Codewort');
    expect(st.fernCodewortGesetzt, isFalse);
  });

  test('EIN FALSCHES PASSWORT IST KEIN BELEG', () async {
    await st.fuegePasswortHinzu(echtes);
    expect(await st.bestaetigeMitPasswort('Falsch-Falsch-Falsch-0000'), isFalse);
    await expectLater(st.setzeFernCodewort(wort), throwsA(isA<NachweisNoetigException>()));
    expect(await kern.hatFernCodewort(), isFalse);
  });

  test('MIT FRISCHER ANMELDUNG: EINMAL — der Beleg ist danach verbraucht', () async {
    await st.fuegePasswortHinzu(echtes);
    expect(await st.bestaetigeMitPasswort(echtes), isTrue);
    await st.setzeFernCodewort(wort);
    expect(await kern.hatFernCodewort(), isTrue);
    expect(kern.codewortFuerTest!.passt('leuchtturm AM hafen'), isTrue);

    // Aendern mit demselben Beleg geht nicht mehr.
    await expectLater(st.setzeFernCodewort('Anderes Wort hier'),
        throwsA(isA<NachweisNoetigException>()));
    expect(kern.codewortFuerTest!.passt(wort), isTrue, reason: 'das Wort wurde ohne Beleg ersetzt');

    // Entfernen verlangt ebenfalls einen frischen.
    await expectLater(st.setzeFernCodewort(null), throwsA(isA<NachweisNoetigException>()));
    expect(await kern.hatFernCodewort(), isTrue);
    expect(await st.bestaetigeMitPasswort(echtes), isTrue);
    await st.setzeFernCodewort(null);
    expect(await kern.hatFernCodewort(), isFalse);
    expect(st.fernCodewortGesetzt, isFalse);
  });

  test('EIN ZU KURZES WORT VERBRAUCHT DEN BELEG NICHT', () async {
    await st.fuegePasswortHinzu(echtes);
    expect(await st.bestaetigeMitPasswort(echtes), isTrue);
    await expectLater(st.setzeFernCodewort('kurz'), throwsArgumentError);
    await st.setzeFernCodewort(wort);
    expect(await kern.hatFernCodewort(), isTrue);
  });
}
