// auto_sperre_test.dart — schliesst die App sich von selbst wieder ab?
//
// DER FEHLER, DEN DAS ABFAENGT: eine Sperre, die nur beim Kaltstart greift.
// Wer die App einmal geoeffnet hat, legt das Telefon weg, jemand anders nimmt
// es auf — und die App steht offen da, weil Android sie nicht abgeraeumt hat.
// Genau so war es bis zum 25.07.2026.
//
// Geprueft wird beides: dass nach der Frist wirklich zugeht, UND dass eine
// kurze Abwesenheit nicht sperrt. Der zweite Teil ist nicht Bequemlichkeit:
// eine Sperre, die bei jedem Blick in eine andere App zuschlaegt, wird
// abgeschaltet — und dann schuetzt sie gar nichts mehr.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i));
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

void main() {
  late Directory verzeichnis;
  late VaultSecretStore tresor;
  late FakeAblage ablage;
  late FakeMessengerCore core;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Der Screenshot-Schutz geht ueber einen Plattform-Kanal, den es hier
    // nicht gibt. Nur abfangen, nicht nachbauen — geprueft wird die Sperre.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-autosperre');
    ablage = FakeAblage();
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: FakeBasis(),
      jetzt: () => 1000,
    );
    core = FakeMessengerCore()..simulateExistingIdentity = true;
    st = AppState(core, tresor: tresor, geraeteAblage: ablage);
    await st.boot();
  });

  tearDown(() {
    st.dispose();
    core.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> richteEin() async {
    await st.fuegeGeraetHinzu();
    expect(st.faktoren, hasLength(1));
  }

  group('Ohne eingerichteten Faktor', () {
    test('bleibt die App offen — es gibt nichts zu sperren', () async {
      st.vordergrund(false);
      st.vordergrund(true);
      expect(st.gesperrt, isFalse);

      await st.sperreWieder();
      expect(st.gesperrt, isFalse,
          reason: 'ohne Faktor waere Zusperren eine Falle: es gaebe keinen '
              'Weg wieder hinein');
    });
  });

  group('Mit einem Faktor', () {
    test('DER FALL: weggelegt und wieder aufgenommen — die App ist zu',
        () async {
      await richteEin();
      expect(st.gesperrt, isFalse);

      await st.sperreWieder();

      expect(st.gesperrt, isTrue);
      expect(core.isInitialized, isFalse,
          reason: 'die Datenbank muss WIRKLICH zu sein — ein Bildschirm '
              'davor liesse die Schluessel im Speicher');
      expect(tresor.istOffen, isFalse);
    });

    test('die Verlaeufe im Speicher werden mit weggeraeumt', () async {
      await richteEin();
      st.verlaeufe['irgendwer'] = const [];
      st.kontakte = const [];

      await st.sperreWieder();

      expect(st.verlaeufe, isEmpty,
          reason: 'die Verlaeufe stehen hier im KLARTEXT — sie kamen '
              'entschluesselt aus der Datenbank. Die Datenbank zu schliessen '
              'und den Text daneben liegen zu lassen waere halbe Arbeit');
      expect(st.meineAdresse, isEmpty);
    });

    test('eine kurze Abwesenheit sperrt NICHT', () async {
      // Adresse in eine andere App kopieren, Benachrichtigung wegwischen, den
      // Stick per NFC bedienen — alles unter einer Minute. Wer hier sperrt,
      // erzieht den Nutzer dazu, die Sperre abzuschalten.
      await richteEin();
      st.vordergrund(false);
      st.vordergrund(true);
      expect(st.gesperrt, isFalse);
      expect(core.isInitialized, isTrue);
    });

    test('nach dem Zusperren geht die App mit dem Faktor wieder auf', () async {
      await richteEin();
      await st.sperreWieder();
      expect(st.gesperrt, isTrue);

      final ok = await st.entsperreMitGeraet();

      expect(ok, isTrue);
      expect(st.gesperrt, isFalse);
      expect(core.isInitialized, isTrue);
    });

    test('die Frist steht auf einer Minute', () {
      // Festgehalten, weil beide Richtungen schaden: sofort erzieht zum
      // Abschalten, gar nicht laesst den Schluessel tagelang im Speicher.
      expect(AppState.sperrfrist, const Duration(minutes: 1));
    });
  });
}
