// zurueck_test.dart — die Zurueck-Geste geht zurueck, nicht raus.
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// BitDM wechselt den Bildschirm ueber eine Variable (`screen` in _HomeState),
// nicht ueber den Navigator. Fuer Android heisst das: der Routenstapel ist
// leer, egal wie tief man in der App steht. Die Zurueck-Geste findet nichts
// zum Schliessen und beendet die App — aus einer Unterhaltung
// herauszuwischen schloss BitDM.
//
// Das ist genau die Sorte Fehler, die kein Test der Logik findet: jede
// einzelne Funktion tut das Richtige, es ruft sie nur niemand. Deshalb geht
// dieser Test ueber `handlePopRoute` — denselben Weg, den Android nimmt.

import 'dart:typed_data';

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

  /// Baut die App und tippt sich durchs Onboarding bis zur Chatliste.
  ///
  /// `runAsync` um den Start: `testWidgets` laeuft in kuenstlicher Zeit, in
  /// der Timer nur beim Pumpen feuern — ein `await` auf etwas dahinter wird
  /// nie fertig. Feste Pumpschritte statt pumpAndSettle, weil diese App
  /// dauerhaft animiert und es den erwarteten Stillstand nie gibt.
  Future<void> bisZurListe(WidgetTester tester) async {
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
    // DAS ONBOARDING ENDET AUF "MEINE ID", NICHT AUF DER LISTE (main.dart,
    // secureScreen: beide Knoepfe rufen go('id')). Ohne diesen Schritt
    // pruefte der Test von dort aus und sagte etwas anderes, als er
    // behauptet.
    await tester.tap(find.text('CHATS'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Genau das, was Android beim Zurueckwischen tut.
  Future<void> wischeZurueck(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    // ZWEIMAL LANG PUMPEN. Der Wechsel ist animiert: der alte Bildschirm
    // gleitet hinaus und steht solange noch im Baum. Nach 400 ms war er noch
    // da, und der Test meldete "es ging nichts zurueck", obwohl es ging.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Ob die App die Geste gerade durchlaesst — `true` heisst: sie wird sich
  /// beenden. Direkt am Widget abgelesen und nicht aus dem Verhalten
  /// erschlossen, denn "die App hat sich beendet" laesst sich im Test nicht
  /// beobachten.
  bool darfSchliessen(WidgetTester tester) {
    final f = find.byKey(const Key('zurueckWaechter'));
    expect(f, findsOneWidget, reason: 'der Waechter ist gar nicht im Baum');
    return (tester.widget(f) as PopScope).canPop;
  }

  testWidgets('AUS DEN EINSTELLUNGEN GEHT ES ZURUECK ZUR LISTE', (tester) async {
    await bisZurListe(tester);
    await tester.tap(find.text('SETTINGS'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('SETTINGS'), findsWidgets);
    expect(darfSchliessen(tester), isFalse,
        reason: 'DAS IST DER GANZE FEHLER: hier durchzulassen heisst, dass '
            'die Zurueck-Geste die App beendet statt zurueckzugehen');

    await wischeZurueck(tester);

    expect(find.text('Follow new messages'), findsNothing,
        reason: 'die Einstellungen stehen immer noch da — es ging nichts '
            'zurueck');
    expect(darfSchliessen(tester), isTrue,
        reason: 'wir sind wieder an der Wurzel, also darf die naechste Geste '
            'hinausfuehren');
  });

  testWidgets('auf der Liste selbst darf sie die App beenden', (tester) async {
    // Die Gegenprobe, und sie ist keine Formsache: eine App, die die Geste
    // IMMER abfaengt, laesst sich nicht mehr verlassen. Das waere schlimmer
    // als der Fehler, der hier behoben wird.
    await bisZurListe(tester);
    expect(darfSchliessen(tester), isTrue,
        reason: 'von der Wurzel aus muss die Geste hinausfuehren duerfen');
  });

  testWidgets('und aus der Unterhaltung zurueck zur Liste', (tester) async {
    await bisZurListe(tester);

    // DIE UNTERHALTUNG UEBER IHRE ADRESSE OEFFNEN, nicht ueber "den ersten
    // GestureDetector".
    //
    // Erst hiess es hier `find.byType(GestureDetector).first` mit einer
    // Ausweichklausel: falls danach keine Unterhaltung offen ist, wird der
    // Fall uebersprungen. Die Mutationsprobe hat gezeigt, wozu das fuehrt —
    // der erste GestureDetector ist ein Element der Kopfzeile, es ging nie
    // eine Unterhaltung auf, der Fall uebersprang sich selbst und galt als
    // bestanden. Er ueberlebte BEIDE Mutationen, weil er nichts geprueft hat.
    //
    // Kontakte der Attrappe haben keinen Namen; sie stehen mit ihrer Adresse
    // da. Nachgesehen statt geraten — die Liste zeigt nicht die volle Adresse
    // aus data.dart, sondern `shortId(adresseFormatiert(...))`: ein
    // vorangestelltes BITD, dann das Ende. Aus c1 wird 'BITD...2L-X'.
    //
    // Der Schwanz ist der eindeutige Teil; der Kopf ist bei jedem Kontakt
    // gleich. Und NICHT die erste Zeile nehmen: ganz oben steht eine
    // unbeantwortete Anfrage mit ANNEHMEN/ABLEHNEN, die gar keine
    // Unterhaltung oeffnet.
    final zeile = find
        .byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').contains('2L-X'))
        .first;
    expect(zeile, findsOneWidget,
        reason: 'die Chatliste zeigt die Unterhaltung gar nicht');
    await tester.tap(zeile, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));

    expect(darfSchliessen(tester), isFalse,
        reason: 'in der Unterhaltung darf die Geste nicht hinausfuehren — '
            'genau das war der gemeldete Fehler');

    await wischeZurueck(tester);
    expect(darfSchliessen(tester), isTrue,
        reason: 'aus der Unterhaltung muss die Geste zur Liste fuehren, nicht '
            'aus der App heraus');
  });

}
