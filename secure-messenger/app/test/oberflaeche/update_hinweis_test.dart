// update_hinweis_test.dart — die ruhige Karte "neue Fassung verfuegbar".
//
// Die Auskunft kommt nur vom Relay (Feld `neueste` in auth_result); hier
// nennt sie die Attrappe des Kerns. Geprueft wird: die Karte erscheint nur
// fuer eine NEUERE Fassung, "Spaeter" nimmt sie fuer genau diese weg und
// merkt sich das, eine noch neuere zeigt sie wieder.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState st;
  late FakeMessengerCore kern;
  const karte = ValueKey('update-hinweis');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), (_) async => true);
    kern = FakeMessengerCore();
    st = AppState(kern)
      ..eigeneFassung = '1.8.3'
      ..updateBenachrichtigen = false;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  Future<void> bisZurListe(WidgetTester tester) async {
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CREATE IDENTITY'));
    await warte(tester, 600);
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('SKIP FOR NOW'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CHATS'));
    await warte(tester);
  }

  testWidgets('OHNE AUSKUNFT VOM RELAY: KEINE KARTE', (tester) async {
    await bisZurListe(tester);
    expect(find.byKey(karte), findsNothing);
  });

  testWidgets('EINE NEUERE FASSUNG: KARTE MIT TEXT, "SPAETER" NIMMT SIE WEG UND MERKT ES SICH',
      (tester) async {
    await bisZurListe(tester);
    kern.simuliereNeuesteFassung('1.10.0');
    await warte(tester);
    expect(find.byKey(karte), findsOneWidget, reason: '1.10.0 ist neuer als 1.8.3');
    expect(find.text("BitDM 1.10.0 is available. You can update, but you don't have to."),
        findsOneWidget);
    expect(find.text('TO THE WEBSITE'), findsOneWidget);
    expect(st.einstellungen.fassungGemeldet, '1.10.0',
        reason: 'die einmalige Benachrichtigung wird je Fassung gemerkt');

    await tester.tap(find.text('LATER'));
    await warte(tester);
    expect(find.byKey(karte), findsNothing);
    expect((await kern.getPreferences()).fassungSpaeter, '1.10.0',
        reason: '"Spaeter" wurde nicht gespeichert — nach dem Neustart kaeme die Karte wieder');

    // Dieselbe Fassung noch einmal (neue Anmeldung): bleibt weg.
    kern.simuliereNeuesteFassung('1.10.0');
    await warte(tester);
    expect(find.byKey(karte), findsNothing);

    // Eine noch neuere: wieder da.
    kern.simuliereNeuesteFassung('1.11.0');
    await warte(tester);
    expect(find.byKey(karte), findsOneWidget);
  });

  testWidgets('GLEICHE ODER AELTERE FASSUNG: KEINE KARTE', (tester) async {
    await bisZurListe(tester);
    kern.simuliereNeuesteFassung('1.8.3');
    await warte(tester);
    expect(find.byKey(karte), findsNothing);
    kern.simuliereNeuesteFassung('1.7.9');
    await warte(tester);
    expect(find.byKey(karte), findsNothing);
    expect(st.einstellungen.fassungGemeldet, isNull);
  });

  test('"SPAETER" UEBERLEBT EINEN NEUSTART (gespeichert in den Einstellungen)', () async {
    kern.simulateExistingIdentity = true;
    await st.boot();
    kern.simuliereNeuesteFassung('2.0.0');
    await Future<void>.delayed(Duration.zero);
    expect(st.updateHinweis, '2.0.0');
    await st.updateSpaeter();
    expect(st.updateHinweis, isNull);

    final neu = AppState(kern)..eigeneFassung = '1.8.3'..updateBenachrichtigen = false;
    addTearDown(neu.dispose);
    await neu.boot();
    expect(kern.neuesteFassung, '2.0.0');
    expect(neu.neuesteFassung, '2.0.0', reason: 'was der Relay schon sagte, ging verloren');
    expect(neu.updateHinweis, isNull, reason: 'nach dem Neustart kam die Karte wieder');
  });
}
