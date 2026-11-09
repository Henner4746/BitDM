// woerter_kopieren_test.dart — der Knopf "Kopieren" unter den zwoelf Woertern,
// nach dem Anlegen ('phrase') und in den Einstellungen.
//
// Die Woerter sind die des Entwurfskerns (FakeMessengerCore, der
// BIP39-Testvektor "abandon … about"); kein echtes Geheimnis.
//
// Was die Zwischenablage DANACH tut (Frist, nur Eigenes leeren, Android raeumt
// selbst), prueft test/core/geheime_ablage_test.dart. Hier geht es darum, dass
// der Knopf da ist, das Richtige weitergibt, den Hinweis zeigt und am
// Screenshot-Schutz nichts aendert.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/geheime_ablage.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _woerter = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  late FakeMessengerCore kern;
  late AppState st;

  /// Was bei "bitdm/ablage" ankam.
  final aufrufe = <MethodCall>[];

  /// Die Attrappe der Zwischenablage — gebraucht im Fenster-Zweig, wo Dart
  /// nach der Frist nachsieht. Ohne sie ginge die Frage an die echte Maschine,
  /// und deren Antwort kaeme ausserhalb der Testzeit an.
  String? ablage;

  /// Was die Oberflaeche zuletzt an den Screenshot-Kanal geschickt hat.
  final schutz = <bool>[];

  TestDefaultBinaryMessenger bote() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    aufrufe.clear();
    schutz.clear();
    ablage = null;
    bote().setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') {
        ablage = (c.arguments as Map)['text'] as String?;
      } else if (c.method == 'Clipboard.getData') {
        return ablage == null ? null : <String, dynamic>{'text': ablage};
      }
      return null;
    });
    bote().setMockMethodCallHandler(const MethodChannel('bitdm/fenster'),
        (c) async {
      if (c.method == 'setzeScreenshotSperre') {
        schutz.add((c.arguments as Map)['an'] as bool);
      }
      return true;
    });
    bote().setMockMethodCallHandler(const MethodChannel('bitdm/ablage'),
        (c) async {
      aufrufe.add(c);
      // Wie die Gegenstellen: "kopiere" legt den Text ab, "leere" raeumt.
      if (c.method == 'kopiere') ablage = (c.arguments as Map)['text'] as String;
      if (c.method == 'leere') ablage = null;
      return true;
    });
    kern = FakeMessengerCore();
    st = AppState(kern);
  });

  tearDown(() {
    GeheimeAblage.vergiss();
    bote().setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    bote().setMockMethodCallHandler(const MethodChannel('bitdm/ablage'), null);
    bote().setMockMethodCallHandler(SystemChannels.platform, null);
    st.dispose();
  });

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  Future<void> starte(WidgetTester tester) async {
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// onboard → 'phrase'.
  Future<void> bisZuDenWoertern(WidgetTester tester) async {
    await starte(tester);
    await tester.tap(find.text('CREATE IDENTITY'));
    await warte(tester, 600);
    expect(find.text('YOUR 12 WORDS'), findsOneWidget);
  }

  final knopf = find.byKey(const ValueKey('woerter-kopieren'));
  final hinweis = find.byKey(const ValueKey('woerter-kopiert'));

  /// Was der Hinweis unter dem Knopf sagt.
  String hinweisText(WidgetTester tester) =>
      tester.widget<Text>(hinweis).data ?? '';

  testWidgets('NACH DEM ANLEGEN: Kopieren gibt die zwoelf Woerter weiter und '
      'sagt, wann sie verschwinden', (tester) async {
    await bisZuDenWoertern(tester);
    expect(knopf, findsOneWidget, reason: 'kein Kopierknopf unter den Woertern');
    expect(find.descendant(of: knopf, matching: find.text('COPY')),
        findsOneWidget);
    expect(hinweis, findsNothing, reason: 'Hinweis vor dem Kopieren');

    await tester.tap(knopf);
    await warte(tester);

    expect(aufrufe, hasLength(1));
    expect(aufrufe.single.method, 'kopiere');
    expect(aufrufe.single.arguments,
        {'text': _woerter, 'sekunden': GeheimeAblage.frist.inSeconds});
    expect(st.frischePhrase!.join(' '), _woerter);

    expect(hinweis, findsOneWidget, reason: 'kein Hinweis nach dem Kopieren');
    expect(hinweisText(tester), contains('60 s'));
    expect(hinweisText(tester), contains('chats or cloud notes'));

    // DER SCREENSHOT-SCHUTZ BLEIBT: 'phrase' erzwingt ihn, und das Kopieren
    // aendert daran nichts.
    expect(schutz.last, isTrue);

    // Der Weg weiter ist derselbe wie vorher.
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await warte(tester);
    expect(find.text('SKIP FOR NOW'), findsOneWidget);
  });

  testWidgets('IM FENSTER: Knopf und Hinweis stehen bei den Woertern, und '
      '"I WROTE THEM DOWN" bleibt im Bild', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await bisZuDenWoertern(tester);

      await tester.tap(knopf);
      await warte(tester);
      expect(aufrufe.single.arguments, containsPair('text', _woerter));
      expect(hinweis, findsOneWidget);

      // Unter den Woertern, nicht irgendwo am Rand: der Knopf liegt zwischen
      // dem letzten Wort und dem Hauptknopf.
      final wortUnten = tester.getBottomLeft(find.text('about')).dy;
      final knopfOben = tester.getTopLeft(knopf).dy;
      final weiter = tester.getTopLeft(find.text('I WROTE THEM DOWN')).dy;
      expect(knopfOben, greaterThan(wortUnten));
      expect(weiter, greaterThan(tester.getBottomLeft(hinweis).dy));
      expect(weiter, lessThan(1000), reason: 'Hauptknopf unter den Fensterrand gerutscht');

      // Am Rechner sieht Dart nach der Frist nach und laesst die Gegenstelle
      // leeren.
      expect(ablage, _woerter);
      await tester.pump(const Duration(seconds: 61));
      expect(GeheimeAblage.wartet, isFalse);
      expect(aufrufe.map((c) => c.method), ['kopiere', 'leere']);
      expect(ablage, isNull);

      await tester.tap(find.text('I WROTE THEM DOWN'));
      await warte(tester);
      expect(find.text('SKIP FOR NOW'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('IN DEN EINSTELLUNGEN: Kopieren im Dialog, Hinweis im Dialog, '
      'Schliessen unveraendert', (tester) async {
    kern.simulateExistingIdentity = true;
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await starte(tester);
    // Wie in sperre_oberflaeche_test: in den Einstellungen AUS, damit sich
    // zeigt, dass der Dialog den Schutz erzwingt und das Kopieren ihn nicht
    // stehen laesst.
    await tester.runAsync(() => st.setzeEinstellungen(
        st.einstellungen.copyWith(blockScreenshots: false)));
    await tester.tap(find.text('SETTINGS'));
    await warte(tester);
    expect(schutz.last, isFalse);

    Future<void> oeffne() async {
      await tester.ensureVisible(find.byKey(const ValueKey('woerter-zeigen')));
      await tester.tap(find.byKey(const ValueKey('woerter-zeigen')));
      await warte(tester);
      expect(find.byKey(const ValueKey('woerter-dialog')), findsOneWidget);
    }

    await oeffne();
    final imDialog = find.descendant(
        of: find.byKey(const ValueKey('woerter-dialog')), matching: knopf);
    expect(imDialog, findsOneWidget, reason: 'kein Kopierknopf im Dialog');
    expect(schutz.last, isTrue);

    await tester.tap(imDialog);
    await warte(tester);
    expect(aufrufe.single.method, 'kopiere');
    expect(aufrufe.single.arguments,
        {'text': _woerter, 'sekunden': GeheimeAblage.frist.inSeconds});
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('woerter-dialog')), matching: hinweis),
        findsOneWidget,
        reason: 'der Hinweis muss IM Dialog stehen, nicht hinter dessen '
            'Abdunklung');
    expect(schutz.last, isTrue, reason: 'Kopieren hat den Schutz geloest');

    // Der Schliessen-Knopf ist weiterhin der einzige TextButton im Dialog —
    // sperre_oberflaeche_test findet ihn genau so.
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('woerter-dialog')),
        matching: find.byType(TextButton)));
    await warte(tester);
    expect(find.byKey(const ValueKey('woerter-dialog')), findsNothing);
    expect(schutz.last, isFalse);

    // Neu geoeffnet: ohne den alten Hinweis.
    await oeffne();
    expect(hinweis, findsNothing);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('woerter-dialog')),
        matching: find.byType(TextButton)));
    await warte(tester);
  });

  testWidgets('IDENTITAET GELOESCHT: die Woerter gehen aus der Zwischenablage',
      (tester) async {
    await bisZuDenWoertern(tester);
    await tester.tap(knopf);
    await warte(tester);
    expect(GeheimeAblage.wartet, isTrue);

    await tester.runAsync(() => st.allesLoeschen());
    await warte(tester);

    expect(st.hatIdentitaet, isFalse);
    expect(aufrufe.last.method, 'raeume',
        reason: 'nach dem Loeschen standen die Woerter weiter in der Ablage');
    expect(GeheimeAblage.wartet, isFalse);
    // Der Wiederverbindungs-Wecker des Kerns, den das Loeschen anstoesst.
    await tester.pump(const Duration(seconds: 2));
  });
}
