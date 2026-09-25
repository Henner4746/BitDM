// schalter_ansage_test.dart — sagt ein Schalter, ob er an ist?
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// Die Schalter der Einstellungen sind reine Grafik: eine Farbe und eine
// Ausrichtung. Wer sie sieht, weiss sofort, ob sie an sind. Wer sie vorlesen
// laesst, hoerte am 29.07.2026 nur die Beschriftung — weder den Zustand noch
// ueberhaupt, dass es ein Schalter ist.
//
// Betroffen waren ALLE fuenf: Bildschirmschutz, Lesebestaetigungen, Bluetooth,
// "nur in der Naehe" und "neuen Nachrichten folgen". Fuer einen blinden Nutzer
// war damit keine einzige Einstellung der App ablesbar. Umlegen ginge —
// feststellen, wohin, nicht.
//
// Aufgefallen ist es beim Durchgehen der taeglichen Ablaeufe auf dem Emulator,
// nicht durch einen Test: die Tests pruefen, was ein Schalter TUT, und keiner
// pruefte, was er SAGT.

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

  Future<void> inDieEinstellungen(WidgetTester tester) async {
    // KEIN ensureSemantics() — es wird nicht gebraucht, seit hier am Widget
    // abgelesen wird, und sein Griff muss sonst von Hand freigegeben werden.
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
    await tester.tap(find.text('SETTINGS'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Was die Schalterzeile ueber ihren Zustand ERKLAERT.
  ///
  /// AM WIDGET ABGELESEN UND NICHT AM GERENDERTEN KNOTEN. Der Versuch ueber
  /// `tester.getSemantics` schlug fehl, weil die Knoten der Zeile
  /// ineinander verschmelzen und der zurueckgegebene der Elternknoten ist —
  /// der Zustand steckt dann drin, ist aber an dieser Stelle nicht mehr
  /// abzulesen.
  ///
  /// WAS DIESER TEST DAMIT ZEIGT und was nicht: er zeigt, dass die App den
  /// Zustand ANGIBT. Dass Android ihn daraufhin auch vorliest, ist Flutters
  /// Sache und nicht meine — geprueft wird die Ebene, fuer die dieser Code
  /// verantwortlich ist.
  bool? zustandVon(WidgetTester tester, String text) {
    final mitZustand = find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.toggled != null),
    );
    if (mitZustand.evaluate().isEmpty) return null;
    return tester.widget<Semantics>(mitZustand.first).properties.toggled;
  }

  testWidgets('EIN SCHALTER SAGT, DASS ER EINER IST — UND WIE ER STEHT',
      (tester) async {
    await inDieEinstellungen(tester);

    final z = zustandVon(tester, 'Follow new messages');
    expect(z, isNotNull,
        reason: 'die Vorlesefunktion haelt das fuer einen gewoehnlichen Text — '
            'dass man ihn umlegen kann, erfaehrt niemand');
    expect(z, isTrue,
        reason: '"neuen Nachrichten folgen" ist ab Werk an, die Ansage sagt aus');
  });

  testWidgets('und die Ansage folgt dem Umlegen', (tester) async {
    // Die Gegenprobe. Ein Merkmal, das immer denselben Wert meldet, ist
    // schlimmer als keines: es klingt nach einer Auskunft und ist keine.
    await inDieEinstellungen(tester);
    expect(zustandVon(tester, 'Follow new messages'), isTrue);

    // Seit der Themenwahl sind die Einstellungen laenger — der Schalter kann
    // unter dem sichtbaren Rand liegen.
    await tester.ensureVisible(find.text('Follow new messages'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Follow new messages'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(zustandVon(tester, 'Follow new messages'), isFalse,
        reason: 'umgelegt, und die Ansage sagt weiterhin "an"');
  });

  testWidgets('auch die Schalter der Sicherheit sagen ihren Stand',
      (tester) async {
    // Nicht nur der eine, den ich gerade gebaut habe: die Luecke war in
    // toggleRow und damit ueberall.
    await inDieEinstellungen(tester);
    for (final text in const ['Screenshot protection', 'Read receipts']) {
      expect(zustandVon(tester, text), isNotNull,
          reason: '"$text" wird nicht als Schalter angesagt');
    }
  });
  testWidgets('DIE ZUGRIFFS-ZEILEN SAGEN, DASS SIE KNOEPFE SIND', (tester) async {
    // Die ganze Zeile ist das Bedienelement; ein eigenes "SET UP" gibt es
    // nicht. Vorgelesen wurde deshalb nur eine Aneinanderreihung von Texten,
    // ohne dass erkennbar war, dass man sie antippen kann.
    await inDieEinstellungen(tester);

    for (final text in const ['Biometrics', 'Device lock', 'App password']) {
      final alsKnopf = find.ancestor(
        of: find.text(text),
        matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.button == true),
      );
      expect(alsKnopf, findsWidgets,
          reason: '"$text" wird nicht als Knopf angesagt — man hoert die '
              'Beschriftung und erfaehrt nicht, dass man sie antippen kann');
    }
  });
}
