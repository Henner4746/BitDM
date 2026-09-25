// nachricht_menue_test.dart — das Menue an einer Nachricht, von der
// Oberflaeche aus: Reaktion, Antworten, Bearbeiten, fuer alle loeschen.
//
// Gegen den Entwurfskern (FakeMessengerCore), der dieselben Regeln kennt wie
// der echte. Ob die Aenderungen auf der Gegenseite ankommen, prueft
// test/net/nachrichten_funktionen_test.dart; hier geht es darum, dass man
// sie ueberhaupt ausloesen kann und dass die Blase zeigt, was passiert ist.

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

  Finder textEgalWie(String teil) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').toUpperCase().contains(teil.toUpperCase()));

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

  Future<void> menueAn(WidgetTester tester, String blasentext) async {
    await tester.longPress(find.text(blasentext).last);
    await warte(tester);
  }

  testWidgets('EINE REAKTION: ANTIPPEN SETZT, NOCHMAL ANTIPPEN NIMMT ZURUECK',
      (tester) async {
    await inDieUnterhaltung(tester);
    await menueAn(tester, 'Did you get the file?');
    expect(find.text('👍'), findsOneWidget, reason: 'keine Reaktionsleiste im Menue');

    await tester.tap(find.text('👍'));
    await warte(tester);
    expect(find.text('👍'), findsOneWidget,
        reason: 'unter der Blase steht keine Reaktion');

    // Die eigene Reaktion unter der Blase antippen nimmt sie zurueck.
    await tester.tap(find.text('👍'));
    await warte(tester);
    expect(find.text('👍'), findsNothing);
  });

  testWidgets('ANTWORTEN: DIE LEISTE ERSCHEINT, DIE BLASE ZITIERT', (tester) async {
    await inDieUnterhaltung(tester);
    await menueAn(tester, 'Did you get the file?');
    await tester.tap(textEgalWie('Reply'));
    await warte(tester);
    expect(textEgalWie('Reply to'), findsOneWidget, reason: 'keine Antwortleiste');

    await tester.enterText(find.byType(TextField).last, 'Ja, gerade eben');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await warte(tester);

    expect(textEgalWie('Reply to'), findsNothing,
        reason: 'die Leiste bleibt nach dem Senden stehen');
    final neu = st.verlaufVon(st.verlaeufe.keys.first).last;
    expect(neu.text, 'Ja, gerade eben');
    expect(neu.antwortAuf, isNotNull, reason: 'der Bezug ging nicht mit');
    await warte(tester, 2400); // die Antwort des Entwurfskerns abwarten
    // Das Zitat steht jetzt zweimal da: in der Originalblase und im Zitat.
    expect(find.text('Did you get the file?'), findsNWidgets(2));
  });

  testWidgets('BEARBEITEN: DER TEXT WANDERT INS FELD, DIE BLASE SAGT "EDITED"',
      (tester) async {
    await inDieUnterhaltung(tester);
    await tester.enterText(find.byType(TextField).last, 'Treffen um acht');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await warte(tester);

    await menueAn(tester, 'Treffen um acht');
    await tester.tap(textEgalWie('Edit'));
    await warte(tester);
    final feld = tester.widget<TextField>(find.byType(TextField).last);
    expect(feld.controller!.text, 'Treffen um acht');

    await tester.enterText(find.byType(TextField).last, 'Treffen um neun');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await warte(tester);
    expect(find.text('Treffen um neun'), findsOneWidget);
    expect(find.text('Treffen um acht'), findsNothing);
    expect(find.text('edited'), findsOneWidget);
    await warte(tester, 2400); // die Antwort des Entwurfskerns abwarten
  });

  testWidgets('EINE UMFRAGE ANLEGEN UND ABSTIMMEN', (tester) async {
    await inDieUnterhaltung(tester);
    await tester.tap(find.text('+').last);
    await warte(tester);
    await tester.tap(textEgalWie('New poll'));
    await warte(tester);
    final felder = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(felder.at(0), 'Pizza oder Pasta?');
    await tester.enterText(felder.at(1), 'Pizza');
    await tester.enterText(felder.at(2), 'Pasta');
    // Der letzte Knopf im Dialog ist 'Send'.
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextButton)).last);
    await warte(tester);

    expect(find.text('Pizza oder Pasta?'), findsOneWidget,
        reason: 'die Umfrage steht nicht im Verlauf');
    expect(find.text('○'), findsNWidgets(2));
    await tester.tap(find.text('Pasta'));
    await warte(tester);
    expect(find.text('◉'), findsOneWidget, reason: 'die eigene Wahl ist nicht markiert');
  });

  testWidgets('FREMDE NACHRICHTEN BIETEN WEDER BEARBEITEN NOCH FUER ALLE LOESCHEN',
      (tester) async {
    await inDieUnterhaltung(tester);
    await menueAn(tester, 'Did you get the file?');
    expect(textEgalWie('Edit'), findsNothing);
    expect(textEgalWie('Delete for everyone'), findsNothing);
    expect(textEgalWie('Delete for me'), findsOneWidget);
  });

  testWidgets('FUER ALLE LOESCHEN: MIT RUECKFRAGE, DANACH EINE LEERSTELLE',
      (tester) async {
    await inDieUnterhaltung(tester);
    await tester.enterText(find.byType(TextField).last, 'Tippfehler');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await warte(tester);

    await menueAn(tester, 'Tippfehler');
    await tester.tap(textEgalWie('Delete for everyone'));
    await warte(tester);
    expect(textEgalWie('Delete for everyone?'), findsOneWidget,
        reason: 'ohne Rueckfrage waere ein Fehltipp endgueltig');
    await tester.tap(find.widgetWithText(TextButton, 'Delete for everyone'));
    await warte(tester);

    expect(find.text('Tippfehler'), findsNothing);
    expect(find.text('You deleted this message'), findsOneWidget);
    await warte(tester, 2400); // die Antwort des Entwurfskerns abwarten
  });
}
