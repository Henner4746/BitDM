// fernloeschung_ui_test.dart — Countdown, Abbrechen, und das Loeschen selbst.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState st;
  late FakeMessengerCore kern;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), (_) async => true);
    kern = FakeMessengerCore();
    st = AppState(kern);
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

  Future<void> bisZurListeMitSchutz(WidgetTester tester) async {
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
    final vertraute = st.aktiveKontakte.map((k) => k.id).take(2).toList();
    expect(vertraute, hasLength(2));
    await tester.runAsync(() => st.setzeFernloeschung(
        Fernloeschung(an: true, schwelle: 2, vertraute: vertraute)));
    for (final v in vertraute) {
      kern.simuliereLoeschanfrage(v);
    }
    await warte(tester);
  }

  testWidgets('DER COUNTDOWN STEHT UEBER DER LISTE UND LAESST SICH ABBRECHEN', (tester) async {
    await bisZurListeMitSchutz(tester);
    expect(find.byKey(const ValueKey('fern-banner')), findsOneWidget, reason: 'kein Countdown zu sehen');
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('fern-banner')),
        matching: find.byWidgetPredicate((w) => w is Text && (w.data ?? '').toUpperCase() == 'CANCEL')));
    await warte(tester);
    expect(find.byKey(const ValueKey('fern-banner')), findsNothing);
    expect(st.fernloeschung.faellig, isNull);
    expect(st.hatIdentitaet, isTrue);
  });

  testWidgets('NACH ZEHN MINUTEN IST ALLES WEG', (tester) async {
    await bisZurListeMitSchutz(tester);
    await tester.pump(const Duration(minutes: 11));
    await warte(tester, 800);
    expect(st.hatIdentitaet, isFalse, reason: 'die Fernloeschung lief nicht');
    expect(find.text('CREATE IDENTITY'), findsOneWidget, reason: 'der Bildschirm blieb bei den Chats');
  });
}
