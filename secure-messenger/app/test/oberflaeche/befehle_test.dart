// befehle_test.dart — die Befehle der Schreibzeile: /timer, /theme, /shrug.
//
// Nur bekannte Befehle werden abgefangen; alles andere mit "/" am Anfang
// ist eine gewoehnliche Nachricht.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FunkAttrappe implements Nahfunk {
  @override
  Future<Funkzustand> zustand() async => const Funkzustand(
      zuAlt: false, vorhanden: true, an: true, rechte: true, jeWerbung: 20);
  @override
  Future<Rechtelage> fordereRechte() async => Rechtelage.erteilt;
  @override
  Future<void> oeffneEinstellungen() async {}
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

void main() {
  late AppState st;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore())..funk = FunkAttrappe();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  /// Laesst Kern und Animationen durchlaufen. MEHRERE Frames, nicht einer:
  /// ein Blatt, das sich schliesst, ist erst im Frame NACH dem Ende seiner
  /// Animation aus dem Baum — mit einem einzigen `pump` staende es noch da,
  /// und jede Suche faende seinen Inhalt doppelt. `pumpAndSettle` geht nicht,
  /// weil der Einbrennschutz einen Dauerwecker hat.
  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  Future<void> inDieUnterhaltung(WidgetTester tester) async {
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
        find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').contains('2L-X')).first,
        warnIfMissed: false);
    await warte(tester, 600);
  }

  Future<void> tippe(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
  }

  Future<void> sende(WidgetTester tester, String text) async {
    await tippe(tester, text);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await warte(tester);
  }

  testWidgets('"/" ZEIGT DIE BEFEHLE, "/ti" NUR NOCH /timer', (tester) async {
    await inDieUnterhaltung(tester);
    await tippe(tester, '/');
    expect(find.byKey(const ValueKey('befehl-timer')), findsOneWidget);
    expect(find.byKey(const ValueKey('befehl-shrug')), findsOneWidget);
    await tippe(tester, '/ti');
    expect(find.byKey(const ValueKey('befehl-timer')), findsOneWidget);
    expect(find.byKey(const ValueKey('befehl-shrug')), findsNothing);
    await tippe(tester, 'hallo');
    expect(find.byKey(const ValueKey('befehl-timer')), findsNothing);
    await warte(tester, 2400);
  });

  testWidgets('/timer 1h SETZT DIE FRIST UND SCHICKT NICHTS', (tester) async {
    await inDieUnterhaltung(tester);
    final cid = st.verlaeufe.keys.first;
    final vorher = st.verlaufVon(cid).length;
    await sende(tester, '/timer 1h');
    expect(st.fristFuer(cid), const Duration(hours: 1));
    expect(st.verlaufVon(cid).length, vorher, reason: 'der Befehl ging als Nachricht hinaus');
    await sende(tester, '/timer off');
    expect(st.fristFuer(cid), isNull, reason: '"off" schaltet fuer diesen Chat ab');
    await warte(tester, 2400);
  });

  testWidgets('/theme aurora WECHSELT DAS THEMA', (tester) async {
    await inDieUnterhaltung(tester);
    await sende(tester, '/theme aurora');
    expect(st.einstellungen.thema, 'aurora');
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await warte(tester, 2400);
  });

  testWidgets('/shrug SCHICKT DAS SCHULTERZUCKEN, UNBEKANNTES GEHT ALS TEXT', (tester) async {
    await inDieUnterhaltung(tester);
    final cid = st.verlaeufe.keys.first;
    await sende(tester, '/shrug na gut');
    expect(st.verlaufVon(cid).where((m) => m.isMine).last.text, r'na gut ¯\_(ツ)_/¯');
    await sende(tester, '/s war ironisch');
    expect(st.verlaufVon(cid).where((m) => m.isMine).last.text, '/s war ironisch');
    await warte(tester, 2400);
  });

  testWidgets('"/ shrug hi" NIMMT DEN REST NACH DEM WORT, NICHT NACH EINER FESTEN STELLE',
      (tester) async {
    // Vorher schnitt `substring(1 + 5)` mitten ins Wort: aus "/ shrug hi"
    // wurde "g hi ¯\_(ツ)_/¯".
    await inDieUnterhaltung(tester);
    final cid = st.verlaeufe.keys.first;
    await sende(tester, '/ shrug hi');
    expect(st.verlaufVon(cid).where((m) => m.isMine).last.text, r'hi ¯\_(ツ)_/¯');
    await warte(tester, 2400);
  });
}
