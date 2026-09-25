// vertrauen_test.dart — Wiederherstellen aus den Teilen von Vertrauenskontakten.
//
// Die Teile kommen aus teilgeheimnis.dart; hier geht es darum, dass man sie
// in das Feld der zwoelf Woerter einfuegen kann und danach dieselbe
// Wiederherstellung laeuft wie mit getippten Woertern.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/crypto/teilgeheimnis.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState st;
  const woerter = 'legal winner thank year wave sausage worth useful legal winner thank yellow';

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

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  Future<void> zumWiederherstellen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byWidgetPredicate((w) =>
        w is Text && (w.data ?? '').toLowerCase().contains('12 words')).first);
    await warte(tester);
  }

  testWidgets('DREI VON FUENF TEILEN STELLEN DIE IDENTITAET WIEDER HER', (tester) async {
    final teile = teileWoerter(woerter.split(' '), schwelle: 3, anzahl: 5);
    await zumWiederherstellen(tester);
    await tester.enterText(find.byType(TextField).first,
        [teile[4], teile[0], teile[2]].map((t) => t.alsText()).join('\n'));
    await tester.tap(find.byWidgetPredicate((w) =>
        w is Text && (w.data ?? '').toUpperCase() == 'RESTORE').last);
    await warte(tester, 1600);
    expect(st.hatIdentitaet, isTrue, reason: 'die Teile fuehrten nicht zur Identitaet');
    expect(await tester.runAsync(() => st.phraseAusEinstellungen()), woerter.split(' '));
  });

  testWidgets('ZU WENIGE TEILE: EINE KLARE MELDUNG, KEINE IDENTITAET', (tester) async {
    final teile = teileWoerter(woerter.split(' '), schwelle: 3, anzahl: 5);
    await zumWiederherstellen(tester);
    await tester.enterText(find.byType(TextField).first,
        [teile[1], teile[3]].map((t) => t.alsText()).join('\n'));
    await tester.tap(find.byWidgetPredicate((w) =>
        w is Text && (w.data ?? '').toUpperCase() == 'RESTORE').last);
    await warte(tester);
    expect(st.hatIdentitaet, isFalse);
    expect(find.textContaining('do not fit together'), findsOneWidget);
  });
}
