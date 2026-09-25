// sprachnachricht_test.dart — Mikrofonknopf, Aufnahme, Versand, Abspielknopf.
//
// Der Kanal zu SprachKanal.kt ist nachgebildet: aufnehmen kann ein Testlauf
// nicht, und der Kanal selbst ist zehn Zeilen MediaRecorder. Geprueft wird,
// was BitDM gehoert: dass der Knopf nur erscheint, wo es den Kanal gibt, dass
// Aufnehmen und Schicken in der richtigen Reihenfolge laufen, und dass die
// Aufnahme als Sprachnachricht im Verlauf steht.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/sprache.dart';
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
  late Directory tmp;
  final aufrufe = <String>[];
  const kanal = MethodChannel('bitdm/sprache');

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bitdm_sprache');
    aufrufe.clear();
    final bote = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    bote.setMockMethodCallHandler(
        const MethodChannel('bitdm/fenster'), (_) async => true);
    bote.setMockMethodCallHandler(kanal, (c) async {
      aufrufe.add(c.method);
      switch (c.method) {
        case 'verfuegbar':
          return true;
        case 'rechte':
          return 'ja';
        case 'starte':
          return true;
        case 'stoppe':
          final f = File('${tmp.path}/aufnahme.m4a')..writeAsBytesSync(List.filled(2048, 1));
          return {'pfad': f.path, 'ms': 3000};
      }
      return null;
    });
    st = AppState(FakeMessengerCore())..funk = FunkAttrappe();
  });

  tearDown(() {
    final bote = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    bote.setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    bote.setMockMethodCallHandler(kanal, null);
    st.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  testWidgets('AUFNEHMEN, SCHICKEN, UND ES STEHT ALS SPRACHNACHRICHT DA',
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
    await tester.tap(find.text('CHATS'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
        find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('2L-X')).first,
        warnIfMissed: false);
    await warte(tester, 600);

    expect(st.spracheMoeglich, isTrue);
    expect(find.text('🎤'), findsOneWidget, reason: 'kein Mikrofonknopf');

    await tester.tap(find.text('🎤'));
    await warte(tester);
    expect(aufrufe, containsAllInOrder(['rechte', 'starte']),
        reason: 'erst fragen, dann aufnehmen');
    expect(find.textContaining('■'), findsOneWidget, reason: 'keine laufende Aufnahme zu sehen');

    await tester.tap(find.textContaining('■'));
    // Der Versand wechselt zwischen echter Datei-Ein/Ausgabe (Laenge lesen)
    // und kuenstlicher Testzeit (die Fortschrittsschritte des Entwurfskerns).
    // Beides braucht seine eigenen Runden.
    for (var i = 0; i < 6; i++) {
      await warte(tester, 400);
    }
    expect(aufrufe.last, 'stoppe');

    final verlauf = st.verlaufVon(st.verlaeufe.keys.first);
    expect(verlauf.any((m) => sprachName.hasMatch(m.text)), isTrue,
        reason: 'die Aufnahme steht nicht als Sprachnachricht im Verlauf — '
            'Fehler=${st.letzterFehler}, schwebend=${st.schwebendeKennung}, '
            'verlauf=${verlauf.map((m) => m.text).toList()}');
    expect(
        find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').toUpperCase().contains('PLAY')),
        findsOneWidget,
        reason: 'kein Abspielknopf');
  });

  testWidgets('OHNE KANAL (RECHNER, BROWSER) GIBT ES KEINEN KNOPF', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kanal, null);
    await tester.runAsync(() async => st.pruefeSprache());
    expect(st.spracheMoeglich, isFalse);
  });
}
