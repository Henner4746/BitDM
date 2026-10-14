// nahbereich_anleitung_test.dart — sagt die Anleitung "nur in der Naehe" das,
// was der Kern tut?
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// Bis 15.10.2026 stand ganz oben in der Anleitung "DIE ZUSTELLUNG UEBER FUNK
// IST NOCH NICHT GEBAUT" — zweieinhalb Monate, nachdem sie am 29.07.2026
// zwischen zwei Telefonen bewiesen war. Schritt 4 verlangte die Ortung, die das
// Manifest mit Absicht nie anfordert. Kein Test hat die Anleitung je geoeffnet;
// aufgefallen ist es beim Schreiben der Ratgeberseiten fuer die Webseite.
//
// Was die Schritte inhaltlich behaupten, haengt am Kern und ist dort
// festgehalten (nahweg_test, "EIN NEUER KONTAKT ENTSTEHT NICHT UEBER FUNK").
// Hier steht, dass die Anleitung sich oeffnen laesst, den richtigen Kasten
// zeigt und in beiden Sprachen vollstaendig ist.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
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

  /// Ueber die Einstellungen in die Anleitung — derselbe Weg wie am Telefon.
  ///
  /// Der Block "In der Naehe" steht nur unter Android; flutter_test meldet
  /// ab Werk Android als Plattform, deshalb ist er hier zu sehen.
  Future<void> inDieAnleitung(WidgetTester tester) async {
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

    final link = find.text(strings['en']!['nearGuideLink']!.toUpperCase());
    await tester.ensureVisible(link);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(link);
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('OBEN STEHT, WAS FUNK WIRKLICH KANN — nicht "nicht gebaut"',
      (tester) async {
    await inDieAnleitung(tester);

    // h2() schreibt gross.
    expect(find.text(strings['en']!['nearGuide']!.toUpperCase()), findsOneWidget,
        reason: 'die Anleitung ist gar nicht aufgegangen');
    expect(find.text(strings['en']!['nearGuideKurz']!), findsOneWidget,
        reason: 'der Kasten ganz oben fehlt');
    expect(find.textContaining('NOT BUILT'), findsNothing,
        reason: 'die Zustellung ueber Funk ist seit dem 29.07.2026 gebaut');
  });

  testWidgets('alle fuenf Schritte stehen da, in ihrer Reihenfolge',
      (tester) async {
    await inDieAnleitung(tester);

    // Die Reihenfolge ist Teil der Aussage: "vorher Kontakte werden" steht
    // VOR dem Einschalten, denn danach geht die Anfrage nicht mehr hinaus.
    var oben = double.negativeInfinity;
    for (var i = 1; i <= 5; i++) {
      final titel = find.text(strings['en']!['nearStep$i']!);
      expect(titel, findsOneWidget, reason: 'Schritt $i fehlt');
      final y = tester.getTopLeft(titel).dy;
      expect(y, greaterThan(oben), reason: 'Schritt $i steht vor Schritt ${i - 1}');
      oben = y;
    }
  });

  test('JEDER TEXT DES NAHBEREICHS STEHT IN BEIDEN SPRACHEN', () {
    // t() faellt auf den nackten Schluessel zurueck. Fehlt eine Uebersetzung,
    // steht in der deutschen Anleitung "nearStep4Body" — kein Absturz, kein
    // Test rot, nur ein Satz, den niemand lesen kann.
    Set<String> nah(String sprache) =>
        strings[sprache]!.keys.where((k) => k.startsWith('near')).toSet();
    expect(nah('de').difference(nah('en')), isEmpty);
    expect(nah('en').difference(nah('de')), isEmpty);
    expect(nah('en'), contains('nearGuideKurz'));
  });
}
