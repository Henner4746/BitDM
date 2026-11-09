// geheime_ablage_test.dart — wann die Zwischenablage nach dem Kopieren der
// zwoelf Woerter wieder leer wird, und wer sie leert.
//
// Die Zwischenablage ist hier eine Attrappe hinter SystemChannels.platform
// (dorthin schicken Clipboard.setData/getData), die Gegenstelle "bitdm/ablage"
// eine hinter ihrem Kanal. Die Zeit ist die Testzeit von testWidgets: eine
// Minute vergeht mit einem pump.

import 'package:bitdm/core/geheime_ablage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _kanal = MethodChannel('bitdm/ablage');

void main() {
  /// Was in der Attrappe der Zwischenablage steht.
  String? ablage;

  /// Was Flutter selbst hineingeschrieben hat (Clipboard.setData).
  final perFlutter = <String?>[];

  /// Was bei der Gegenstelle ankam.
  final aufrufe = <MethodCall>[];

  TestDefaultBinaryMessenger bote() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Haengt eine Gegenstelle an "bitdm/ablage". Ohne Aufruf gibt es keine —
  /// wie im Browser.
  ///
  /// "KEINE" HEISST HIER EINE ATTRAPPE, DIE MissingPluginException WIRFT, und
  /// nicht ein Kanal ohne Attrappe. Ohne sie ginge der Aufruf an die echte
  /// Maschine, deren Antwort ausserhalb der Testzeit ankommt — der Fall hing
  /// dann fuer immer (beim ersten Lauf am 09.11.2026 so gesehen).
  void gegenstelle(Object? Function(MethodCall) antwort) {
    bote().setMockMethodCallHandler(_kanal, (c) async {
      aufrufe.add(c);
      return antwort(c);
    });
  }

  setUp(() {
    ablage = null;
    perFlutter.clear();
    aufrufe.clear();
    gegenstelle((c) => throw MissingPluginException());
    bote().setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') {
        final text = (c.arguments as Map)['text'] as String?;
        perFlutter.add(text);
        ablage = text;
        return null;
      }
      if (c.method == 'Clipboard.getData') {
        return ablage == null ? null : <String, dynamic>{'text': ablage};
      }
      return null;
    });
  });

  tearDown(() {
    GeheimeAblage.vergiss();
    bote().setMockMethodCallHandler(SystemChannels.platform, null);
    bote().setMockMethodCallHandler(_kanal, null);
  });

  group('ohne Gegenstelle (Browser, Test)', () {
    testWidgets('kopiert ueber Flutter und leert nach 60 s', (tester) async {
      expect(await GeheimeAblage.kopiere('eins zwei drei'), isTrue);
      expect(ablage, 'eins zwei drei');

      await tester.pump(const Duration(seconds: 59));
      expect(ablage, 'eins zwei drei', reason: 'vor der Frist geleert');

      await tester.pump(const Duration(seconds: 2));
      expect(ablage, '', reason: 'nach der Frist stand noch alles da');
      expect(GeheimeAblage.wartet, isFalse);
    });

    testWidgets('was inzwischen selbst kopiert wurde, bleibt', (tester) async {
      await GeheimeAblage.kopiere('eins zwei drei');
      ablage = 'eine Adresse';

      await tester.pump(const Duration(seconds: 61));
      expect(ablage, 'eine Adresse',
          reason: 'die Frist hat fremden Inhalt geloescht');
    });

    testWidgets('die Frist laesst sich kuerzen (Teilgeheimnisse: 30 s)',
        (tester) async {
      await GeheimeAblage.kopiere('teil', frist: const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 31));
      expect(ablage, '');
    });

    testWidgets('ein zweites Kopieren beobachtet nur noch das zweite',
        (tester) async {
      await GeheimeAblage.kopiere('erstes');
      await tester.pump(const Duration(seconds: 40));
      await GeheimeAblage.kopiere('zweites');

      // Nach 61 s seit dem ERSTEN darf noch nichts passiert sein.
      await tester.pump(const Duration(seconds: 21));
      expect(ablage, 'zweites');
      await tester.pump(const Duration(seconds: 40));
      expect(ablage, '');
    });

    testWidgets('raeumeJetzt leert sofort, aber nur das Eigene',
        (tester) async {
      await GeheimeAblage.kopiere('eins zwei drei');
      await GeheimeAblage.raeumeJetzt();
      expect(ablage, '');
      expect(GeheimeAblage.wartet, isFalse);

      await GeheimeAblage.kopiere('eins zwei drei');
      ablage = 'fremd';
      await GeheimeAblage.raeumeJetzt();
      expect(ablage, 'fremd');
    });
  });

  /// Ein Fall auf [plattform]. Die Weiche wird IM Fall zurueckgesetzt und
  /// nicht in tearDown: flutter_test prueft vorher, ob sie stehen blieb
  /// (siehe fenster_abfolge_test.dart).
  void auf(TargetPlatform plattform, String name,
      Future<void> Function(WidgetTester) koerper) {
    testWidgets('$name — ${plattform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = plattform;
      try {
        await koerper(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('Android', () {
    // Im Widget-Test meldet Flutter ohnehin android; hier steht es trotzdem,
    // damit der Fall nicht still an einer Vorgabe des Testrahmens haengt.
    auf(TargetPlatform.android,
        'die Gegenstelle kopiert UND raeumt selbst — kein Dart-Wecker',
        (tester) async {
      gegenstelle((c) => true);
      expect(await GeheimeAblage.kopiere('eins zwei drei'), isTrue);

      expect(aufrufe.single.method, 'kopiere');
      expect(aufrufe.single.arguments,
          {'text': 'eins zwei drei', 'sekunden': 60});
      expect(perFlutter, isEmpty,
          reason: 'zusaetzlich ueber Flutter kopiert — ohne Sensibel-Merkmal');

      // Die Frist laeuft in GeheimeAblage.kt. Dart darf danach nichts tun:
      // im Hintergrund laese es null und koennte nichts entscheiden.
      await tester.pump(const Duration(seconds: 61));
      expect(aufrufe, hasLength(1));
      expect(perFlutter, isEmpty);

      await GeheimeAblage.raeumeJetzt();
      expect(aufrufe.last.method, 'raeume');
    });

    auf(TargetPlatform.android,
        'scheitert die Gegenstelle, kopiert Flutter und Dart raeumt',
        (tester) async {
      gegenstelle((c) => throw PlatformException(code: 'kaputt'));
      expect(await GeheimeAblage.kopiere('eins zwei drei'), isTrue);
      expect(ablage, 'eins zwei drei');

      await tester.pump(const Duration(seconds: 61));
      expect(ablage, '');
    });
  });

  group('am Rechner (Windows, Linux)', () {
    for (final plattform in [TargetPlatform.windows, TargetPlatform.linux]) {
      auf(plattform,
          'die Gegenstelle kopiert, Dart vergleicht und laesst sie leeren',
          (tester) async {
        gegenstelle((c) {
          switch (c.method) {
            case 'kopiere':
              ablage = (c.arguments as Map)['text'] as String;
              return true;
            case 'leere':
              ablage = null;
              return true;
          }
          return null;
        });
        await GeheimeAblage.kopiere('eins zwei drei');
        expect(ablage, 'eins zwei drei');

        await tester.pump(const Duration(seconds: 61));
        expect(aufrufe.map((c) => c.method), ['kopiere', 'leere']);
        expect(ablage, isNull);
        // Clipboard.setData('') legte auf Windows einen leeren Eintrag in den
        // Verlauf — die Gegenstelle leert die Ablage ganz.
        expect(perFlutter, isEmpty);
      });
    }

    auf(TargetPlatform.linux, 'kennt die Gegenstelle "leere" nicht, leert Flutter',
        (tester) async {
      gegenstelle((c) {
        if (c.method == 'kopiere') {
          ablage = (c.arguments as Map)['text'] as String;
          return true;
        }
        return false;
      });
      await GeheimeAblage.kopiere('eins zwei drei');
      await tester.pump(const Duration(seconds: 61));
      expect(perFlutter, ['']);
      expect(ablage, '');
    });

    auf(TargetPlatform.windows, 'fremder Inhalt bleibt auch hier',
        (tester) async {
      gegenstelle((c) {
        if (c.method == 'kopiere') {
          ablage = (c.arguments as Map)['text'] as String;
        }
        return true;
      });
      await GeheimeAblage.kopiere('eins zwei drei');
      ablage = 'fremd';
      await tester.pump(const Duration(seconds: 61));
      expect(aufrufe.map((c) => c.method), ['kopiere']);
      expect(ablage, 'fremd');
    });
  });
}
