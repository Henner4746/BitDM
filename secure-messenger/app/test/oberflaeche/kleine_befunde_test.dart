// kleine_befunde_test.dart — leichte Befunde aus dem QA-Bericht vom
// 18.11.2026 (Linux-Desktop), die sich ohne Netz pruefen lassen.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Tor am Rechner', () {
    test('DER TEXT NENNT KEIN ORBOT — DAS GIBT ES NUR AUF ANDROID', () {
      for (final sprache in ['de', 'en']) {
        for (final k in ['torSub', 'pruefTor']) {
          expect(textFuer(sprache, k, telefon: false), isNot(contains('Orbot')),
              reason: '$sprache/$k');
          expect(textFuer(sprache, k, telefon: true), contains('Orbot'),
              reason: 'auf Android bleibt Orbot richtig');
        }
      }
    });
  });

  group('Gruppe voll', () {
    late AppState st;
    setUp(() async {
      st = AppState(FakeMessengerCore());
      await st.boot();
      await st.identitaetAnlegen();
    });
    tearDown(() => st.dispose());

    test('DAS 21. MITGLIED WIRD NICHT STILL ABGEWIESEN', () async {
      final zwei = st.kontakte.take(2).map((k) => k.id).toList();
      final gid = await st.legeGruppeAn('Voll', zwei);
      final fremde = [
        for (var i = 0; i < 18; i++) 'bitdmVOLL${'$i'.padLeft(2, '0')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
      ];
      await st.fuegeZuGruppeHinzu(gid, fremde);
      expect(st.letzterFehler, 'gruppeVoll',
          reason: 'drei plus achtzehn sind 21 — und niemand sagte etwas');
      expect(st.gruppeZu(gid)!.mitglieder, hasLength(3));
    });
  });

  group('Eingabezeile', () {
    late AppState st;
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bitdm_zeile');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), (_) async => true);
      st = AppState(FakeMessengerCore());
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
      st.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> warte(WidgetTester tester, [int ms = 400]) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(Duration(milliseconds: ms ~/ 2));
      }
    }

    testWidgets('UMSCHALT+EINGABE MACHT EINE NEUE ZEILE, UND SIE KOMMT MIT',
        (tester) async {
      await tester.runAsync(() async => st.boot());
      await tester.pumpWidget(BitApp(state: st));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('CREATE IDENTITY'));
      await tester.pump(const Duration(milliseconds: 600));
      await warte(tester, 600);
      await tester.tap(find.text('I WROTE THEM DOWN'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('SKIP FOR NOW'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('CHATS'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
          find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('2L-X')).first,
          warnIfMissed: false);
      await warte(tester, 600);

      final feld = find.byWidgetPredicate(
          (w) => w is TextField && w.textInputAction == TextInputAction.send);
      expect(feld, findsOneWidget, reason: 'keine Eingabezeile');
      expect(tester.widget<TextField>(feld).maxLines, greaterThan(1),
          reason: 'einzeilig: Umbrueche verschwinden');

      await tester.enterText(feld, 'erste Zeile');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      final ctl = tester.widget<TextField>(feld).controller!;
      expect(ctl.text, 'erste Zeile\n',
          reason: 'Umschalt+Eingabe schickte ab statt umzubrechen');
      ctl.value = const TextEditingValue(
          text: 'erste Zeile\nzweite Zeile',
          selection: TextSelection.collapsed(offset: 24));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await warte(tester);

      final verlauf = st.verlaufVon(st.verlaeufe.keys.first);
      expect(verlauf.any((m) => m.text == 'erste Zeile\nzweite Zeile'), isTrue,
          reason: 'der Umbruch ging verloren: ${verlauf.map((m) => m.text).toList()}');
      // Der Entwurfskern stellt nach 1,1 s "zu" — ablaufen lassen.
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
