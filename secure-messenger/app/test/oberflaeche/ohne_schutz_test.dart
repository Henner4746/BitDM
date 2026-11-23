// ohne_schutz_test.dart — weiter ohne App-Passwort nur nach Rueckfrage
// (Sicherheitsbewertung vom 23.11.2026, SEC-H1).
//
// Ohne Faktor liegt die Identitaet im Schluesselbund, und BitDM oeffnet ohne
// Frage. Bis 22.11.2026 fuehrten "Spaeter", "Weiter", die Eingabetaste und
// Zurueck kommentarlos daran vorbei, und der Text darueber sprach von "bevor
// die App entsperrt".

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState st;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  Future<void> bisSecure(WidgetTester tester) async {
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CREATE IDENTITY'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('SECURE THIS DEVICE'), findsOneWidget);
  }

  final frage = find.text('Continue without protection?');

  testWidgets('SPAETER OHNE FAKTOR: ERST DIE RUECKFRAGE, "ZURUECK" BLEIBT STEHEN',
      (tester) async {
    await bisSecure(tester);
    await tester.tap(find.text('SKIP FOR NOW'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(frage, findsOneWidget, reason: 'ohne Faktor ging es kommentarlos weiter');

    await tester.tap(find.byKey(const ValueKey('schutz-zurueck')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(frage, findsNothing);
    expect(find.text('SECURE THIS DEVICE'), findsOneWidget,
        reason: '"Zurueck" darf nicht weitergehen');

    // "Weiter" ohne Faktor ist dasselbe wie "Spaeter".
    await tester.tap(find.text('CONTINUE'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(frage, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ohne-schutz-weiter')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('SECURE THIS DEVICE'), findsNothing,
        reason: 'nach der Bestaetigung geht es weiter');
  });

  testWidgets('AUCH DIE ZURUECK-GESTE FRAGT', (tester) async {
    await bisSecure(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 600));
    expect(frage, findsOneWidget,
        reason: 'Zurueck fuehrte ohne Rueckfrage an der Absicherung vorbei');
    await tester.tap(find.byKey(const ValueKey('schutz-zurueck')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('SECURE THIS DEVICE'), findsOneWidget);
  });

  test('DIE TEXTE VERSPRECHEN KEINEN SCHUTZ, DEN ES NICHT GIBT', () {
    for (final sprache in ['de', 'en']) {
      final s = strings[sprache]!;
      expect(s['secureSub'], isNot(contains('before the app unlocks')));
      expect(s['secureSub'], isNot(contains('bevor die App entsperrt')));
      // Den letzten Faktor kann man entfernen (vault_store.dart) — "bleibt
      // erforderlich" stimmte nicht.
      expect(s['minOne'], isNot(contains('required')));
      expect(s['minOne'], isNot(contains('erforderlich')));
    }
  });
}
