// geraet_texte_test.dart — am Rechner und im Browser "Geraet", nicht "Telefon".
//
// Gemeldet vom ersten echten Linux-Lauf (17.10.2026): der Sperrbildschirm
// sagte "The identity on this phone is sealed", die zwoelf Woerter "if this
// phone is lost", die Startseite "Lost or replaced your phone?" — auf einem
// Rechner. Die Ersetzungen stehen in data.dart (geraetErsetzungen); hier wird
// geprueft, dass sie greifen, dass Android unberuehrt bleibt und dass kein
// neuer Text das Telefon erwaehnt, ohne dass jemand entschieden hat, ob man
// ihn am Rechner sieht.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/app_lock.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Texte, die NUR in der Android-App zu sehen sind und dort zu Recht vom
/// Telefon sprechen. Wer hier einen Schluessel eintraegt, sagt damit: am
/// Rechner und im Browser erscheint dieser Text nicht.
const _nurAndroid = {
  // Sicherheitsschluessel, Geraetesperre, Fingerabdruck: nur Android
  // (_faktorGehtHier und _nurAufAndroid in main.dart).
  'stickPinHint',
  'lockNoScreenLockBody',
  'fidoHold',
  'devpinSub',
  // Anstoss ueber UnifiedPush: ein Android-Plugin, die Stufe '-2' gibt es
  // am Rechner nicht.
  'pushGuideIntro',
  // Eine Nachricht, die ueber Funk kam — Funk gibt es nur auf Android.
  'viaNearbyWhat',
};

/// Der ganze Nahbereich (Schluessel 'near…'): `nahbereichBlock` und die
/// Anleitung `nahHilfeScreen` stehen in den Einstellungen hinter
/// `if (_nurAufAndroid)` (main.dart). Kommt der Nahbereich auf den Rechner,
/// muss diese Ausnahme weg.
bool _nurAndroidText(String k) => _nurAndroid.contains(k) || k.startsWith('near');

/// Ob [text] vom Telefon als Geraet spricht. "phone number" und
/// "Telefonnummer" sind etwas anderes.
bool _sagtTelefon(String sprache, String text) => sprache == 'en'
    ? RegExp(r'\bphones?\b(?! numbers?)', caseSensitive: false).hasMatch(text)
    : RegExp(r'Telefon(?!nummer)').hasMatch(text);

/// Ein Kern, der eine Identitaet hat, die hinter einem Faktor liegt.
class _GesperrterKern extends FakeMessengerCore {
  @override
  Future<bool> initialize() async => throw const LockedException();
}

void main() {
  group('Ersetzungen', () {
    test('beide Sprachen ersetzen dieselben Texte', () {
      expect(geraetErsetzungen['de']!.keys.toSet(),
          geraetErsetzungen['en']!.keys.toSet());
    });

    test('jede Ersetzung trifft — sonst hat jemand den Text oben geaendert', () {
      for (final MapEntry(key: sprache, value: texte) in geraetErsetzungen.entries) {
        for (final MapEntry(key: k, value: paare) in texte.entries) {
          final basis = strings[sprache]![k];
          expect(basis, isNotNull, reason: '$sprache/$k gibt es nicht');
          for (final (alt, _) in paare) {
            expect(basis, contains(alt),
                reason: '$sprache/$k: "$alt" steht nicht mehr im Text');
          }
        }
      }
    });

    test('am Rechner spricht kein ersetzter Text mehr vom Telefon', () {
      for (final sprache in strings.keys) {
        for (final k in geraetErsetzungen[sprache]!.keys) {
          final text = textFuer(sprache, k, telefon: false);
          expect(_sagtTelefon(sprache, text), isFalse, reason: '$sprache/$k: $text');
          expect(text, isNot(strings[sprache]![k]), reason: '$sprache/$k blieb gleich');
        }
      }
    });

    test('auf Android bleibt jeder Text, wie er war', () {
      for (final sprache in strings.keys) {
        for (final k in strings[sprache]!.keys) {
          expect(textFuer(sprache, k, telefon: true), strings[sprache]![k]);
        }
      }
    });

    test('jeder Text, der vom Telefon spricht, ist ersetzt oder nur auf Android zu sehen', () {
      final offen = <String>[];
      for (final sprache in strings.keys) {
        for (final MapEntry(key: k, value: text) in strings[sprache]!.entries) {
          if (!_sagtTelefon(sprache, text)) continue;
          if (_nurAndroidText(k)) continue;
          if (geraetErsetzungen[sprache]!.containsKey(k)) continue;
          offen.add('$sprache/$k');
        }
      }
      expect(offen, isEmpty,
          reason: 'Diese Texte sagen "phone"/"Telefon". Entweder in '
              'geraetErsetzungen (data.dart) eintragen oder, wenn sie nur '
              'auf Android erscheinen, hier in _nurAndroid.');
    });

    test('die Liste der Android-Texte enthaelt nichts, was es nicht gibt', () {
      for (final k in _nurAndroid) {
        expect(strings['en']!.containsKey(k), isTrue, reason: k);
      }
    });
  });

  group('auf dem Bildschirm', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('bitdm/fenster'), (_) async => true);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    });

    Future<void> warte(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<AppState> starte(WidgetTester tester, FakeMessengerCore kern) async {
      final st = AppState(kern);
      addTearDown(st.dispose);
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => st.boot());
      await tester.pumpWidget(BitApp(state: st));
      await warte(tester);
      return st;
    }

    final en = strings['en']!;

    for (final plattform in const [TargetPlatform.linux, TargetPlatform.windows]) {
      testWidgets('Startseite auf ${plattform.name}: "your device"', (tester) async {
        debugDefaultTargetPlatformOverride = plattform;
        await starte(tester, FakeMessengerCore());
        expect(find.text(textFuer('en', 'restoreLinkSub', telefon: false)), findsOneWidget);
        expect(find.text(en['restoreLinkSub']!), findsNothing);
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('Sperrbildschirm auf ${plattform.name}: "on this device"', (tester) async {
        debugDefaultTargetPlatformOverride = plattform;
        final st = await starte(tester, _GesperrterKern());
        expect(st.gesperrt, isTrue);
        expect(find.text(textFuer('en', 'lockedSub', telefon: false)), findsOneWidget);
        expect(find.text(en['lockedSub']!), findsNothing);
        // Ohne Fachdatei gibt es keinen Faktor — dann steht auch dieser da.
        expect(find.text(textFuer('en', 'lockedNoFactor', telefon: false)), findsOneWidget);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('Startseite auf Android: weiter "your phone"', (tester) async {
      await starte(tester, FakeMessengerCore());
      expect(find.text(en['restoreLinkSub']!), findsOneWidget);
    });

    testWidgets('Sperrbildschirm auf Android: weiter "on this phone"', (tester) async {
      await starte(tester, _GesperrterKern());
      expect(find.text(en['lockedSub']!), findsOneWidget);
    });
  });
}
