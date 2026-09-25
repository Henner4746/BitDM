// themen_test.dart — Themen, ihr langsamer Wechsel, und der Entschluesselungs-
// Effekt an eintreffenden Nachrichten.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:bitdm/themen.dart';
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
  group('die Themen selbst', () {
    final alle = bauThemen();

    test('jede Kennung nur einmal, Material ist dabei', () {
      final ids = alle.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids, containsAll(['nocturne', 'papier', 'material', 'materialHell']));
    });

    test('das Wandern zieht nur durch dunkle Themen', () {
      final kreis = wanderKreis(alle);
      expect(kreis, isNotEmpty);
      expect(kreis.every((t) => t.dunkel), isTrue,
          reason: 'nachts von allein auf Papierweiss waere ein Blendangriff');
    });

    test('Material nimmt die Akzentfarbe des Systems', () {
      final ohne = alle.firstWhere((t) => t.id == 'material');
      final mit = bauThemen(systemAkzent: const Color(0xFF00897B))
          .firstWhere((t) => t.id == 'material');
      expect(mit.pal.accent, isNot(ohne.pal.accent));
      expect(ohne.monoSchrift, isNull, reason: 'Material setzt die Schrift des Systems');
    });

    test('Pal.lerp trifft beide Enden', () {
      final a = alle[0].pal, b = alle[5].pal;
      expect(Pal.lerp(a, b, 0).bg, a.bg);
      expect(Pal.lerp(a, b, 1).bg, b.bg);
      expect(Pal.lerp(a, b, 0.5).bg, isNot(anyOf(a.bg, b.bg)));
    });
  });

  group('in der App', () {
    late AppState st;

    setUp(() {
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

    Future<void> warte(WidgetTester tester, [int ms = 400]) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
        await tester.pump(Duration(milliseconds: ms ~/ 2));
      }
    }

    Future<void> bisZurListe(WidgetTester tester) async {
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

    Color hintergrund(WidgetTester tester) =>
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;

    testWidgets('EIN THEMA WAEHLEN: ERST DER SCHLEIER, DANN DIE NEUEN FARBEN',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await bisZurListe(tester);
      final phosphor = bauThemen().firstWhere((t) => t.id == 'phosphor');
      expect(hintergrund(tester), isNot(phosphor.pal.bg));

      await tester.tap(find.text('SETTINGS'));
      await warte(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('thema-phosphor')));
      await tester.tap(find.byKey(const ValueKey('thema-phosphor')));
      await warte(tester, 200);
      expect(st.einstellungen.thema, 'phosphor', reason: 'die Wahl wurde nicht gespeichert');

      // Mitten im Wechsel: der Schleier liegt ueber allem, die Farbe ist
      // weder die alte noch die neue.
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.byType(ChiffreSchleier), findsOneWidget, reason: 'kein Schleier');
      expect(hintergrund(tester), isNot(phosphor.pal.bg), reason: 'kein langsamer Wechsel');

      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byType(ChiffreSchleier), findsNothing, reason: 'der Schleier bleibt liegen');
      expect(hintergrund(tester), phosphor.pal.bg);
      expect(anzeigeThema.value.id, 'phosphor', reason: 'Dialoge behielten das alte Thema');
      anzeigeThema.value = bauThemen().first;
    });

    testWidgets('DIE SPRACHE WIRD GESPEICHERT', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await bisZurListe(tester);
      await tester.tap(find.text('SETTINGS'));
      await warte(tester);
      await tester.tap(find.text('Deutsch'));
      await warte(tester);
      expect(st.einstellungen.sprache, 'de');
      expect(find.text('EINSTELLUNGEN'), findsWidgets);
    });

    testWidgets('EINE EINTREFFENDE NACHRICHT ENTSCHLUESSELT SICH SICHTBAR',
        (tester) async {
      await bisZurListe(tester);
      await tester.tap(
          find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('2L-X')).first,
          warnIfMissed: false);
      await warte(tester, 600);
      await tester.enterText(find.byType(TextField).last, 'Hallo');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      // Der Entwurfskern antwortet nach 1,1 s (Testzeit) mit "Understood.".
      await warte(tester, 700);
      expect(find.text('Understood.'), findsNothing,
          reason: 'die Antwort stand sofort im Klartext da');
      expect(find.byType(EntschluesselnderText), findsOneWidget);

      // Der Effekt laeuft auf der echten Uhr: er muss auch einen Neuaufbau der
      // Liste ueberstehen, und dafuer haelt die Oberflaeche den Startzeitpunkt.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Understood.'), findsOneWidget,
          reason: 'nach dem Effekt steht der Klartext nicht da');
    });
  });
}
