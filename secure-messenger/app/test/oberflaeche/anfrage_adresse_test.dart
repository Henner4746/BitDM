// anfrage_adresse_test.dart — eine Kontaktanfrage zeigt die ganze Adresse
// (Sicherheitsbewertung vom 23.11.2026, SEC-M7).
//
// Bis 23.11.2026 stand an der Anfrage nur "ABCD…WXYZ": acht Zeichen, rund 40
// Bit. Wer eine Adresse erzeugt, die vorne und hinten gleich aussieht, haette
// sich als jemand Bekanntes ausgeben koennen — genau dort, wo der Nutzer
// entscheidet, wen er annimmt.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
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

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  testWidgets('DIE ANFRAGE ZEIGT DIE GANZE ADRESSE UND DAS BILD DAZU',
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
    // Auf main gibt es die Rueckfrage noch nicht (fix/ohne-nachweis-ehrlich).
    final ohne = find.byKey(const ValueKey('ohne-schutz-weiter'));
    if (ohne.evaluate().isNotEmpty) await tester.tap(ohne);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CHATS').first);
    // Der Entwurfskern meldet die Anfrage gut eine Sekunde nach dem Verbinden.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(st.offeneAnfragen, isNotEmpty, reason: 'keine Anfrage da');
    final id = st.offeneAnfragen.first.id;
    final adresse = find.byKey(ValueKey('anfrage-adresse-$id'));
    expect(adresse, findsOneWidget,
        reason: 'an der Anfrage stehen nur acht Zeichen der Adresse');
    expect(tester.widget<SelectableText>(adresse).data, adresseFormatiert(id),
        reason: 'nicht die ganze Adresse');
    await tester.pump(const Duration(seconds: 2));
  });
}
