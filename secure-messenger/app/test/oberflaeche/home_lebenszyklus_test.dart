// home_lebenszyklus_test.dart — Charakterisierungstests fuer Lebenszyklus,
// Sperren und Aufraeumen von Home.
//
// WOFUER: Die Aufteilung von main.dart (docs/MAIN-DART-AUFTEILUNG.md) soll
// nichts am Verhalten aendern. Die vorhandenen Oberflaechentests decken die
// Bildschirme ab, aber keiner schickte der Oberflaeche einen echten
// Lebenszyklus-Wechsel, und keiner pruefte, was nach dem Abbau von Home am
// AppState haengen bleibt. Genau das ist der Teil, auf den eine Durchsicht
// von aussen am 16.10.2026 zeigte (Sperrzustand, Hintergrundwechsel,
// sensible Anzeigen in einer 8 540-Zeilen-Datei). Diese Tests laufen auf dem
// Stand VOR und NACH der Aufteilung gruen; das ist der Beleg.
//
// Plan-Nummern C1, C3, C5, C7 (C2 Aufnahme, C4 Zurueck-Geste, C6 Loeschen
// sind teils durch sprachnachricht_test, zurueck_test und fernloeschung_ui_test
// abgedeckt und hier nicht nachgebaut).

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fido/fake_stick.dart';

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

void main() {
  late Directory verzeichnis;
  late FakeMessengerCore kern;
  late AppState st;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), (c) async => true);
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-lebenszyklus');
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
      stickZugang: (_) async => FakeStick(),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  Future<void> starte(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Der Lebenszyklus haengt am Binding und ueberdauert den einzelnen Test.
    addTearDown(() =>
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.runAsync(() => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await warte(tester);
  }

  Future<void> lebenszyklus(WidgetTester tester, List<AppLifecycleState> folge) async {
    for (final z in folge) {
      tester.binding.handleAppLifecycleStateChanged(z);
      await warte(tester);
    }
  }

  testWidgets('C1 VERDECKEN SPERRT, EIN SYSTEMDIALOG NICHT', (tester) async {
    await starte(tester);
    await tester.runAsync(() => st.fuegePasswortHinzu(echtes));
    await warte(tester);
    expect(st.gesperrt, isFalse);

    // Ein Fingerabdruck- oder USB-Dialog legt sich ueber die App: nur
    // `inactive`, dann wieder `resumed`. Die App bleibt offen — sonst liesse
    // sich bei Sperrfrist null nie ein Faktor einrichten.
    await lebenszyklus(tester, [AppLifecycleState.inactive, AppLifecycleState.resumed]);
    expect(st.gesperrt, isFalse, reason: 'ein Systemdialog (inactive) sperrte die App');

    // Wirklich weggelegt: in echter Reihenfolge hin und zurueck.
    await lebenszyklus(tester, [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    expect(st.gesperrt, isTrue, reason: 'nach dem Weglegen blieb die App offen');
    expect(find.text('LOCKED'), findsOneWidget);
  });

  testWidgets('C3 SPERREN RAEUMT AUCH DIE EIGENEN FELDER AUF', (tester) async {
    await starte(tester);
    await tester.runAsync(() => st.fuegePasswortHinzu(echtes));
    await warte(tester);

    final suche = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Search messages');
    expect(suche, findsOneWidget);
    await tester.enterText(suche, 'geheimer Suchbegriff');
    await warte(tester);
    expect(find.text('geheimer Suchbegriff'), findsOneWidget);

    await tester.runAsync(() => st.sperreWieder());
    await warte(tester);
    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.text('geheimer Suchbegriff'), findsNothing,
        reason: 'der Suchbegriff stand hinter dem Sperrbildschirm weiter im Baum');

    expect(await tester.runAsync(() => st.entsperreMitPasswort(echtes)), isTrue);
    await warte(tester);
    expect(st.gesperrt, isFalse);
    expect(find.text('geheimer Suchbegriff'), findsNothing,
        reason: 'nach dem Entsperren stand der alte Suchbegriff wieder da');
  });

  testWidgets('C5 NACH DEM ABBAU HAENGT HOME NICHT MEHR AM ZUSTAND', (tester) async {
    await starte(tester);
    // ignore: invalid_use_of_protected_member
    expect(st.hasListeners, isTrue, reason: 'Home hoert nicht auf den Zustand');
    expect(st.frageOhneBereinigung, isNotNull,
        reason: 'Home hat die Metadaten-Frage nicht angemeldet');

    await tester.pumpWidget(const SizedBox());
    await warte(tester);
    // ignore: invalid_use_of_protected_member
    expect(st.hasListeners, isFalse,
        reason: 'Home hing nach dem Abbau noch als Zuhoerer am Zustand');
    expect(st.frageOhneBereinigung, isNull,
        reason: 'die Metadaten-Frage zeigte nach dem Abbau auf ein totes Home');
  });

  testWidgets('C7 SPRACHWECHSEL ERREICHT DIE BENACHRICHTIGUNGSTEXTE', (tester) async {
    await starte(tester);
    expect(st.einNeuText, 'New message');

    // Von aussen (gespeicherte Einstellung, etwa nach einem Neustart).
    await tester.runAsync(
        () => st.setzeEinstellungen(st.einstellungen.copyWith(sprache: 'de')));
    await warte(tester);
    expect(st.einNeuText, 'Neue Nachricht');

    // Und ueber den Schalter in den Einstellungen.
    await tester.tap(find.text('EINSTELLUNGEN'));
    await warte(tester);
    await tester.ensureVisible(find.text('English'));
    await tester.tap(find.text('English'));
    await warte(tester);
    expect(st.einNeuText, 'New message');
  });
}
