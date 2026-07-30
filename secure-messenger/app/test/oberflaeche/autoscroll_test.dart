// autoscroll_test.dart — folgt die Unterhaltung dem, was dazukommt?
//
// ZWEI DINGE, DIE NICHT DASSELBE SIND
//
// BEIM OEFFNEN ans Ende zu springen ist kein Merkmal, sondern eine
// Selbstverstaendlichkeit. Die Liste hatte bisher gar keine Steuerung und
// begann oben — wer eine laengere Unterhaltung oeffnete, landete bei der
// aeltesten Nachricht und musste sich nach unten arbeiten. Das gilt
// unabhaengig vom Schalter.
//
// BEI EINER NEUEN NACHRICHT zu folgen ist dagegen Geschmackssache, und dafuer
// gibt es den Schalter. Steht er auf aus, bleibt die Ansicht stehen.
//
// Ein Test, der nur das erste prueft, waere gruen, auch wenn der Schalter
// nichts tut. Deshalb stehen hier beide Richtungen.

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
      zuAlt: false, vorhanden: true, an: true, rechte: true, jeWerbung: 40);
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

  /// Baut die App, geht durchs Onboarding und oeffnet die Unterhaltung.
  Future<void> inDieUnterhaltung(WidgetTester tester) async {
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CREATE IDENTITY'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('SKIP FOR NOW'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CHATS'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
        find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('2L-X')).first,
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Die Bildlaufsteuerung der Nachrichtenliste.
  ScrollController liste(WidgetTester tester) {
    final c = tester.widget<ListView>(find.byType(ListView).first).controller;
    expect(c, isNotNull, reason: 'die Nachrichtenliste hat keine Steuerung');
    return c!;
  }

  /// Schreibt eine Nachricht und schickt sie ab — ueber das Eingabefeld, also
  /// so, wie ein Mensch es tut.
  Future<void> schreibe(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // DREI PUMPSCHRITTE, UND DER DRITTE IST DER WICHTIGE.
    //
    // Der erste bringt die Nachricht in die Liste, der zweite loest den
    // Rueckruf nach dem Bau aus — DORT beginnt der Bildlauf. Ohne einen
    // dritten wird die begonnene Bewegung nie weitergerechnet, und der Test
    // liest den Stand von davor.
    //
    // Nachgemessen: die Ausgabe endete mit "animiere nach 1382.5", waehrend
    // die Pruefung 0.0 sah. Es lag nicht am Programm.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Fuellt die Unterhaltung, bis sie ueberlaeuft — vorher gibt es nichts zu
  /// scrollen, und jeder Vergleich waere 0 gegen 0.
  Future<void> fuelle(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await schreibe(tester, 'Nachricht $i');
    }
  }

  testWidgets('BEIM OEFFNEN STEHT DIE NEUESTE NACHRICHT DA', (tester) async {
    await inDieUnterhaltung(tester);
    await fuelle(tester);
    expect(liste(tester).position.maxScrollExtent, greaterThan(0),
        reason: 'die Unterhaltung laeuft gar nicht ueber — der Test misst '
            'nichts');

    // Zurueck zur Liste und wieder hinein: das ist der Weg, auf dem die alte
    // Fassung oben landete.
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(
        find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('2L-X')).first,
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));

    final c = liste(tester);
    expect(c.offset, closeTo(c.position.maxScrollExtent, 1),
        reason: 'die Unterhaltung geht bei der aeltesten Nachricht auf');
  });

  testWidgets('MIT DEM SCHALTER FOLGT SIE EINER NEUEN NACHRICHT',
      (tester) async {
    await inDieUnterhaltung(tester);
    await fuelle(tester);
    expect(st.einstellungen.autoScroll, isTrue, reason: 'ab Werk an');

    // Nach oben wegscrollen, damit ein Nachfuehren ueberhaupt sichtbar waere.
    liste(tester).jumpTo(0);
    await tester.pump(const Duration(milliseconds: 200));

    await schreibe(tester, 'die neueste');

    // NICHT AUF DEN PIXEL GENAU. Das Gegenueber der Attrappe antwortet sofort;
    // waehrend der Bildlauf laeuft, waechst die Liste also weiter, und das
    // Ziel von eben ist nicht mehr das Ende. Gemessen wurde 1442 bei einem
    // Ende von 1557 — nachgefuehrt hat sie, nur eine Nachrichtenhoehe hinter
    // dem inzwischen neuen Ende.
    //
    // Die Aussage ist "sie ist mitgegangen", und der Vergleichswert dafuer
    // ist die 0, auf der sie ohne Nachfuehren stuende.
    final c = liste(tester);
    expect(c.offset, greaterThan(c.position.maxScrollExtent - 200),
        reason: 'wer selbst schreibt, will sehen, was er geschrieben hat');
  });

  testWidgets('OHNE DEN SCHALTER BLEIBT SIE STEHEN', (tester) async {
    await inDieUnterhaltung(tester);
    await fuelle(tester);

    await st.setzeEinstellungen(
        st.einstellungen.copyWith(autoScroll: false));
    await tester.pump(const Duration(milliseconds: 200));

    liste(tester).jumpTo(0);
    await tester.pump(const Duration(milliseconds: 200));

    await schreibe(tester, 'noch eine');

    // Die Gegenprobe zum Fall darueber. Ohne sie waere der Test auch dann
    // gruen, wenn der Schalter gar nichts bewirkt.
    expect(liste(tester).offset, closeTo(0, 1),
        reason: 'der Schalter steht auf aus, die Ansicht ist trotzdem '
            'gesprungen');
  });
}
