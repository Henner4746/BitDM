// anhang_knopf_test.dart — "Datei anhaengen" je Plattform: der Punkt geht,
// oder er ist sichtbar abgeschaltet und sagt, warum.
//
// DER ANLASS (17.10.2026). Am PC stand der Menuepunkt da und tat auf Druck
// nichts. Die Dateiwahl lief ueber den Kanal bitdm/dateien, den es nur unter
// Android gab; `Dateien.waehlen` fing die MissingPluginException und gab still
// null zurueck. Ein Kritiker von aussen hat es bemaengelt, die eigene Webseite
// raeumte es ein. Seitdem gibt es den Kanal auch in den Startprogrammen fuer
// Windows und Linux (windows/runner/datei_kanal.cpp, linux/runner/
// datei_kanal.cc).
//
// WAS HIER GEPRUEFT WIRD UND WAS NICHT. Ob am echten Windows ein Dialog
// aufgeht, kann ein Widget-Test nicht sagen — das tut
// integration_test/datei_kanal_windows_test.dart. Hier geht es um die Weiche:
//   * auf android, windows und linux erreicht der Druck den Kanal ('waehlen');
//   * im Browser und auf Plattformen ohne Kanal ist der Punkt grau, tut
//     nichts, und darunter steht der Grund.
// `kIsWeb` ist eine Konstante des Uebersetzers und im Widget-Test nicht
// setzbar. Der Browser kommt deshalb ueber `SystemDateiWahl(imBrowser: true)` —
// dieselbe Klasse, die die App benutzt, nur mit umgelegtem Schalter.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/dateien.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/foundation.dart';
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

const _mitKanal = [
  TargetPlatform.android,
  TargetPlatform.windows,
  TargetPlatform.linux,
];
const _ohneKanal = [
  TargetPlatform.macOS,
  TargetPlatform.iOS,
  TargetPlatform.fuchsia,
];

void main() {
  group('Die Weiche', () {
    test('mit Kanal: android, windows, linux', () {
      for (final pl in _mitKanal) {
        expect(Dateien.auswahlFehltAuf(pl, imBrowser: false), isNull,
            reason: pl.name);
      }
    });

    test('ohne Startprogramm, also ohne Kanal: abgeschaltet mit Grund', () {
      for (final pl in _ohneKanal) {
        expect(Dateien.auswahlFehltAuf(pl, imBrowser: false), 'anhangKeinDialog',
            reason: pl.name);
      }
    });

    test('IM BROWSER IMMER AUS — auch wenn die Plattform android meldet', () {
      // Im Browser auf einem Android-Telefon ist defaultTargetPlatform
      // android. Kanaele gibt es dort trotzdem keine.
      for (final pl in TargetPlatform.values) {
        expect(Dateien.auswahlFehltAuf(pl, imBrowser: true), 'anhangWeb',
            reason: pl.name);
      }
    });

    test('jede Plattform ist eingeteilt', () {
      // Kommt eine neue TargetPlatform dazu, soll das hier auffallen und
      // nicht still in "abgeschaltet" landen.
      expect({..._mitKanal, ..._ohneKanal}, TargetPlatform.values.toSet());
    });

    test('SystemDateiWahl folgt der Plattform, auf der die App laeuft', () {
      try {
        for (final pl in TargetPlatform.values) {
          debugDefaultTargetPlatformOverride = pl;
          expect(const SystemDateiWahl(imBrowser: false).auswahlFehlt,
              _mitKanal.contains(pl) ? isNull : 'anhangKeinDialog',
              reason: pl.name);
          expect(const SystemDateiWahl(imBrowser: true).auswahlFehlt,
              'anhangWeb', reason: pl.name);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Am PC gehen aktive Inhalte als Text auf', () {
    // Dieselbe Liste wie AKTIVE_ENDUNGEN in DateiKanal.kt.
    test('HTML, SVG, Skripte — gleich wie geschrieben', () {
      for (final n in [
        'rechnung.html', 'RECHNUNG.HTM', 'bild.svg', 'a.svgz', 'x.xhtml',
        'seite.mht', 'seite.mhtml', 'lauf.js', 'daten.xml', 'app.hta',
        'teil.shtml',
      ]) {
        expect(Dateien.aktiverInhalt(n), isTrue, reason: n);
      }
    });

    test('alles andere geht an das Programm, das das System vorsieht', () {
      for (final n in [
        'foto.jpg', 'brief.pdf', 'html', 'datei.', 'ohne_endung',
        r'C:\Users\a.html\datei', 'x.html.txt',
      ]) {
        expect(Dateien.aktiverInhalt(n), isFalse, reason: n);
      }
    });
  });

  group('Im Plus-Menue', () {
    late AppState st;
    late List<String> aufrufe;
    // Erst im Test abgerufen: beim Aufbau der Gruppe gibt es die Bindung
    // noch nicht.
    TestDefaultBinaryMessenger bote() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      aufrufe = [];
      bote().setMockMethodCallHandler(
          const MethodChannel('bitdm/fenster'), (_) async => true);
      // Antwortet wie ein abgebrochener Dialog. Es zaehlt nur, OB er gefragt
      // wird — vorher kam auf dem PC gar nichts an.
      bote().setMockMethodCallHandler(const MethodChannel('bitdm/dateien'),
          (aufruf) async {
        aufrufe.add(aufruf.method);
        return null;
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      bote().setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
      bote().setMockMethodCallHandler(const MethodChannel('bitdm/dateien'), null);
      st.dispose();
    });

    Finder textEgalWie(String teil) => find.byWidgetPredicate((w) =>
        w is Text && (w.data ?? '').toUpperCase().contains(teil.toUpperCase()));

    Future<void> warte(WidgetTester tester, [int ms = 400]) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
        await tester.pump(Duration(milliseconds: ms ~/ 2));
      }
    }

    /// Bis ins Plus-Menue der ersten Unterhaltung des Entwurfskerns.
    ///
    /// Auf dem Schreibtisch in einem Fenster wie dort (1600x1000, wie
    /// fenster_abfolge_test.dart): in 800x600 laege "I WROTE THEM DOWN" im
    /// Fenster-Zweig ausserhalb des Bildes, und der Tipp ginge daneben.
    Future<void> insPlusMenue(WidgetTester tester) async {
      if (defaultTargetPlatform != TargetPlatform.android) {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
      }
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
      // Auf dem Schreibtisch steht "CHATS" zweimal: als Ueberschrift und in
      // der Leiste. Der Eintrag in der Leiste ist der letzte.
      await tester.tap(find.text('CHATS').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
          find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').contains('2L-X')).first,
          warnIfMissed: false);
      await warte(tester, 600);
      await tester.tap(find.text('+').last);
      await warte(tester);
    }

    InkWell eintrag(WidgetTester tester, String text) => tester.widget<InkWell>(
        find.ancestor(of: textEgalWie(text), matching: find.byType(InkWell)).first);

    for (final pl in _mitKanal) {
      testWidgets('${pl.name}: DER DRUCK ERREICHT DIE DATEIAUSWAHL',
          (tester) async {
        debugDefaultTargetPlatformOverride = pl;
        try {
          st = AppState(FakeMessengerCore())..funk = FunkAttrappe();
          await insPlusMenue(tester);

          expect(find.byKey(const ValueKey('anhang-grund')), findsNothing,
              reason: 'hier geht es — dann gehoert auch kein Grund darunter');
          expect(eintrag(tester, 'Attach file').onTap, isNotNull);
          expect(eintrag(tester, 'Photo, view once').onTap, isNotNull);

          await tester.tap(textEgalWie('Attach file'));
          await warte(tester);
          expect(aufrufe, ['waehlen'],
              reason: 'der Druck kam nicht beim Kanal bitdm/dateien an');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('IM BROWSER: GRAU, OHNE WIRKUNG, UND DER GRUND STEHT DARUNTER',
        (tester) async {
      st = AppState(FakeMessengerCore(),
          dateien: const SystemDateiWahl(imBrowser: true))
        ..funk = FunkAttrappe();
      await insPlusMenue(tester);

      expect(eintrag(tester, 'Attach file').onTap, isNull);
      expect(eintrag(tester, 'Photo, view once').onTap, isNull);
      expect(find.byKey(const ValueKey('anhang-grund')), findsOneWidget);
      expect(textEgalWie('Files do not work in the browser'), findsOneWidget);

      await tester.tap(textEgalWie('Attach file'), warnIfMissed: false);
      await warte(tester);
      expect(aufrufe, isEmpty);
      // Das Blatt bleibt offen: der Grund ist weiter zu lesen.
      expect(textEgalWie('Files do not work in the browser'), findsOneWidget);
      // Was dort geht, bleibt bedienbar.
      expect(eintrag(tester, 'New poll').onTap, isNotNull);
    });

    testWidgets('OHNE KANAL (macOS): GRAU MIT EIGENEM GRUND', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        st = AppState(FakeMessengerCore())..funk = FunkAttrappe();
        await insPlusMenue(tester);

        expect(eintrag(tester, 'Attach file').onTap, isNull);
        expect(textEgalWie('no file picker on this system'), findsOneWidget);
        expect(textEgalWie('in the browser'), findsNothing,
            reason: 'macOS ist kein Browser — der Grund muss stimmen');
        await tester.tap(textEgalWie('Attach file'), warnIfMissed: false);
        await warte(tester);
        expect(aufrufe, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
