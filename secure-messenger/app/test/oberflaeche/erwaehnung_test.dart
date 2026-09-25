// erwaehnung_test.dart — "@XLLW…S7JD" in Gruppen: erkennen und vorschlagen.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState st;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  Message nachricht(String chat, String text, {bool mein = false}) => Message(
      id: 'n1', chatId: chat, senderId: 'x', text: text, isMine: mein,
      timestamp: DateTime.now().toUtc());

  test('erkennt die eigene Erwaehnung nur in Gruppen und nur fremd', () async {
    await st.boot();
    await st.identitaetAnlegen();
    final kontakt = st.aktiveKontakte.first.id;
    final gid = await st.legeGruppeAn('Wanderung', [kontakt]);
    final ich = AppState.erwaehnungVon(st.meineAdresse);

    expect(st.erwaehntMich(nachricht(gid, 'Kommst du, $ich?')), isTrue);
    expect(st.erwaehntMich(nachricht(gid, 'Kommt jemand?')), isFalse);
    expect(st.erwaehntMich(nachricht(kontakt, 'Kommst du, $ich?')), isFalse,
        reason: 'im Einzelchat ist jede Nachricht ohnehin an mich');
    expect(st.erwaehntMich(nachricht(gid, 'Ich schrieb $ich', mein: true)), isFalse);
  });

  testWidgets('"@" IN DER GRUPPE SCHLAEGT DIE MITGLIEDER VOR', (tester) async {
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CREATE IDENTITY'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('SKIP FOR NOW'));
    await tester.pump(const Duration(milliseconds: 400));
    final kontakt = st.aktiveKontakte.first.id;
    final gid = (await tester.runAsync(() => st.legeGruppeAn('Wanderung', [kontakt])))!;
    await tester.tap(find.text('CHATS'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Wanderung'));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(st.offeneUnterhaltung, gid);

    final vorschlag = find.byKey(ValueKey('erwaehne-${AppState.erwaehnungVon(kontakt)}'));
    await tester.enterText(find.byType(TextField).last, 'Hallo @');
    await tester.pump();
    expect(vorschlag, findsOneWidget, reason: 'kein Vorschlag nach "@"');
    await tester.tap(vorschlag);
    await tester.pump();
    final feld = tester.widget<TextField>(find.byType(TextField).last);
    expect(feld.controller!.text, 'Hallo ${AppState.erwaehnungVon(kontakt)} ');
  });
}
