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
    st = AppState(core, tresor: tresor, ablagen: (_) => ablage);
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
    await st.fuegeBiometrieHinzu();
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

  // GEMELDET AM 26.09.2026: Anhang waehlen, Dateiwahl von Android oeffnet
  // sich, Datei ausgesucht — zurueck in der App die Anmeldung, und danach ein
  // Fehler. Bei Sperrfrist "sofort" sperrte die EIGENE Dateiwahl die App,
  // und der Versand lief in die geschlossene Datenbank.
  group('Die eigene Dateiwahl', () {
    test('SPERRT BEI "SOFORT" NICHT, solange sie laeuft und kurz danach', () async {
      await richteEin();
      final ergebnis = await st.imSystemDialog(() async {
        st.vordergrund(false); // Android legt den Waehler vor die App
        return 'datei';
      });
      st.vordergrund(true); // onResume kommt NACH dem Ergebnis
      await Future<void>.delayed(Duration.zero);
      expect(ergebnis, 'datei');
      expect(st.gesperrt, isFalse,
          reason: 'die selbst geoeffnete Dateiwahl darf nicht zusperren');
      expect(core.isInitialized, isTrue);
    });

    test('ABER NICHT GRENZENLOS: ueber der Obergrenze sperrt es doch', () async {
      await richteEin();
      st.systemDialogHoechstens = Duration.zero;
      await st.imSystemDialog(() async => st.vordergrund(false));
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(st.gesperrt, isTrue,
          reason: 'wer den Waehler offen liegen laesst, muss an die Sperre');
    });

    test('OHNE DATEIWAHL bleibt "sofort" sofort', () async {
      await richteEin();
      await st.imSystemDialog(() async => 'nichts');
      // Drei Sekunden Nachlauf sind um — hier kuenstlich: ein zweites
      // Weglegen lange nach dem Dialog darf nicht mehr darunter fallen.
      st.systemDialogHoechstens = Duration.zero;
      st.vordergrund(false);
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(st.gesperrt, isTrue);
    });

    test('WAR DOCH GESPERRT, WARTET DER VERSAND AUFS ENTSPERREN', () async {
      await richteEin();
      await st.sperreWieder();
      expect(st.gesperrt, isTrue);
      var offen = false;
      final warten = st.wartBisOffen().then((v) => offen = v);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(offen, isFalse, reason: 'vor dem Entsperren darf nichts hinaus');
      await st.entsperreMitBiometrie();
      await warten;
      expect(offen, isTrue);
      expect(core.isInitialized, isTrue);
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

    test('ab Werk sperrt schon eine kurze Abwesenheit', () async {
      // DAS WAR DIE MELDUNG vom 25.07.2026: App zu, App auf, einfach drin.
      // Vorher stand die Frist fest auf einer Minute.
      await richteEin();
      st.vordergrund(false);
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(st.gesperrt, isTrue);
    });

    test('mit eingestellter Frist bleibt eine kurze Abwesenheit folgenlos',
        () async {
      // Adresse in eine andere App kopieren, Benachrichtigung wegwischen —
      // wer das jedes Mal mit einer Anmeldung bezahlt, schaltet die Sperre ab.
      await richteEin();
      await st.setzeSperrfrist(60);
      st.vordergrund(false);
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(st.gesperrt, isFalse);
      expect(core.isInitialized, isTrue);
    });

    test('"nie" sperrt nicht von selbst', () async {
      await richteEin();
      await st.setzeSperrfrist(-1);
      st.vordergrund(false);
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(st.gesperrt, isFalse);
    });

    test('nach dem Zusperren geht die App mit dem Faktor wieder auf', () async {
      await richteEin();
      await st.sperreWieder();
      expect(st.gesperrt, isTrue);

      final ok = await st.entsperreMitBiometrie();

      expect(ok, isTrue);
      expect(st.gesperrt, isFalse);
      expect(core.isInitialized, isTrue);
    });

    test('die Frist steht ab Werk auf SOFORT', () {
      // Wer eine Sperre einrichtet, will gefragt werden — und nicht manchmal.
      // Laenger geht, muss aber eingestellt werden.
      expect(st.sperrfrist, Duration.zero);
    });

    test('eine eingestellte Frist ueberlebt den Neustart', () async {
      await richteEin();
      await st.setzeSperrfrist(300);

      final frisch = AppState(FakeMessengerCore()..simulateExistingIdentity = true,
          tresor: VaultSecretStore(
              datei: vaultDateiIn(verzeichnis.path),
              basis: FakeBasis(),
              jetzt: () => 2000),
          ablagen: (_) => ablage);
      await frisch.boot();

      expect(frisch.sperrfrist, const Duration(seconds: 300));
      frisch.dispose();
    });
  });
}
