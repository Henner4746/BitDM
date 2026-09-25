// chatliste_ordnung_test.dart — Anheften, Archivieren, Stummschalten und die
// Suche in der Chatliste, von der Oberflaeche aus.

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

  /// Die Zeile des Demo-Kontakts, dessen Adresse auf "2L-X" endet.
  Finder zeile() => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains('2L-X'));

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  Future<void> zurListe(WidgetTester tester) async {
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
    await warte(tester);
  }

  Future<void> menuePunkt(WidgetTester tester, String punkt) async {
    await tester.longPress(zeile().first);
    await warte(tester);
    await tester.tap(textEgalWie(punkt).last);
    await warte(tester);
  }

  testWidgets('ANHEFTEN UND STUMMSCHALTEN ZEIGEN SICH AN DER ZEILE', (tester) async {
    await zurListe(tester);
    await menuePunkt(tester, 'Pin');
    expect(find.textContaining('📌'), findsOneWidget);
    await menuePunkt(tester, 'Mute');
    expect(find.textContaining('🔕'), findsOneWidget);
    // Und zurueck.
    await menuePunkt(tester, 'Unpin');
    expect(find.textContaining('📌'), findsNothing);
  });

  testWidgets('ARCHIVIEREN NIMMT DIE ZEILE HERAUS, DAS ARCHIV HOLT SIE ZURUECK',
      (tester) async {
    await zurListe(tester);
    expect(zeile(), findsWidgets);
    await menuePunkt(tester, 'Archive');
    expect(zeile(), findsNothing, reason: 'die archivierte Zeile steht noch da');
    expect(textEgalWie('ARCHIVED (1)'), findsOneWidget);

    await tester.tap(textEgalWie('ARCHIVED (1)'));
    await warte(tester);
    expect(zeile(), findsWidgets, reason: 'im Archiv fehlt sie');
    await menuePunkt(tester, 'Unarchive');
    await tester.tap(textEgalWie('Back to chats'));
    await warte(tester);
    expect(zeile(), findsWidgets);
    expect(textEgalWie('ARCHIVED'), findsNothing);
  });

  testWidgets('EINE GRUPPE ANLEGEN, SCHREIBEN, AUSTRETEN', (tester) async {
    await zurListe(tester);
    await tester.tap(textEgalWie('+ New group'));
    await warte(tester);
    final dialog = find.byType(AlertDialog);
    await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextField)), 'Wanderung');
    await tester.tap(find.descendant(of: dialog, matching: find.byType(Checkbox)).first);
    await warte(tester);
    await tester.tap(find.descendant(of: dialog, matching: find.byType(TextButton)).last);
    await warte(tester, 600);

    expect(find.text('Wanderung'), findsWidgets, reason: 'der Gruppenchat ist nicht offen');
    expect(st.gruppen, hasLength(1));
    final gid = st.gruppen.single.id;

    await tester.enterText(find.byType(TextField).last, 'Samstag um neun?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await warte(tester);
    expect(st.verlaufVon(gid).map((m) => m.text), contains('Samstag um neun?'));

    // Kopf antippen -> Gruppenblatt -> austreten.
    await tester.tap(find.text('Wanderung').first, warnIfMissed: false);
    await warte(tester);
    expect(textEgalWie('ADMIN'), findsOneWidget, reason: 'kein Gruppenblatt');
    await tester.tap(textEgalWie('Leave group'));
    await warte(tester);
    expect(textEgalWie('no longer a member'), findsOneWidget,
        reason: 'nach dem Austritt steht noch die Eingabezeile da');
  });

  testWidgets('DIE SUCHE FINDET EINEN SATZ UND OEFFNET SEINE UNTERHALTUNG',
      (tester) async {
    await zurListe(tester);
    await tester.enterText(find.byType(TextField).first, 'FILE');
    await warte(tester);
    expect(find.text('Did you get the file?'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'gibt es nicht');
    await warte(tester);
    expect(textEgalWie('Nothing found'), findsOneWidget);
  });
}
