// fenster_abfolge_test.dart — der Schreibtisch-Zweig, mit der Tastatur bedient.
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// Am 30.07.2026 kam in ganz test/ weder `TargetPlatform` noch der
// Fenster-Zweig vor: im Widget-Test meldet Flutter android, also lief die
// gesamte Desktop-Weiche (`_imFenster`) in keinem einzigen der damals 807
// gruenen Tests. Die belegten, dass ANDROID nicht kaputt ist — ueber den
// Schreibtisch sagten sie nichts.
//
// Genau dort sass der gefaehrlichste Fehler: die blanke Eingabetaste hing als
// `CallbackShortcuts` UEBER dem Baum und lag damit naeher am fokussierten
// Knopf als das `Shortcuts` von WidgetsApp. Sie verbrauchte die Taste, bevor
// der Knopf sie sah — auf 'onboard' legte Tab auf "Ich habe schon 12 Woerter"
// plus Eingabe eine NEUE IDENTITAET an. Mit diesem Test faellt das sofort auf.
//
// `debugDefaultTargetPlatformOverride` ist der einzige Weg dorthin: die Weiche
// haengt an der Plattform und nicht an der Fenstergroesse (siehe `_imFenster`
// in main.dart, samt Begruendung).
//
// UND SIE STEHT NICHT FEST AUF WINDOWS. Bis zum 30.07.2026 tat sie das, damit
// liefen alle Faelle auf einer der VIER Plattformen hinter `_imFenster`. Die
// Faelle, bei denen die Plattform etwas aendert, laufen jetzt ueber
// [aufBeidenFenstern] auch auf macOS — welche das sind und warum die anderen
// nicht, steht dort. Das Web bleibt aussen vor: `kIsWeb` ist eine Konstante des
// Uebersetzers und im Widget-Test nicht setzbar.

import 'package:bitdm/app_state.dart';
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
    // DER GURT ZUM HOSENTRAEGER. Zurueckgesetzt wird die Weiche schon im
    // `finally` von [imFenster] — und dort MUSS sie es auch, denn
    // flutter_test prueft nach jedem Fall, ob eine foundation-Variable stehen
    // geblieben ist (binding.dart:1995, `_verifyInvariants`), und diese
    // Pruefung laeuft VOR tearDown. Hier steht sie trotzdem: wer die Weiche
    // kuenftig anderswo von Hand setzt, laesst sie damit nicht fuer die
    // naechste Testdatei stehen.
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  /// Ein Testfall, der im FENSTER-Zweig laeuft.
  ///
  /// DAS IST DER GANZE ZWECK DIESER DATEI: ohne die Weiche laeuft alles darunter
  /// im Telefon-Zweig und prueft nichts von dem, was hier gemeint ist. Sie
  /// haengt an der Plattform und nicht an der Fenstergroesse (siehe
  /// `_imFenster` in main.dart).
  ///
  /// [plattform] ist windows, wo die Plattform nichts zur Sache tut — sonst
  /// waeren aus sieben Faellen einundzwanzig geworden, fuer drei Belege.
  void imFenster(String name, Future<void> Function(WidgetTester) koerper,
      {TargetPlatform plattform = TargetPlatform.windows}) {
    testWidgets(
        plattform == TargetPlatform.windows
            ? name
            : '$name — auf ${plattform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = plattform;
      try {
        await koerper(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  /// Ein Fall, bei dem die PLATTFORM den Unterschied macht — windows UND macOS.
  ///
  /// WELCHE FAELLE DAS SIND, und warum nicht alle: `_imFenster` deckt vier
  /// Plattformen ab (main.dart:564-568, kIsWeb + windows + linux + macOS).
  /// Plattformabhaengig ist daran nur, was aus einer TASTE wird — und das
  /// entscheiden zwei verschiedene Buendel:
  ///
  ///   * `WidgetsApp.defaultShortcuts` (app.dart:1390-1405) gibt fuer
  ///     windows/linux `_defaultShortcuts` (1263) und fuer macOS/iOS
  ///     `_defaultAppleOsShortcuts` (1344) zurueck — zwei getrennte Karten.
  ///     Am 30.07.2026 nachgezaehlt: fuer die Aktivierung sind sie GLEICH
  ///     (enter 1265/1346, numpadEnter 1266/1347, space 1267/1348, alle drei auf
  ///     `ActivateIntent`); macOS hat nur `gameButtonA` und `select` (1268-1269)
  ///     nicht. Dass sie gleich SIND, ist genau der Grund, es zu pruefen: es
  ///     steht nirgends geschrieben, dass es so bleibt.
  ///   * `DefaultTextEditingShortcuts` haengt auf macOS ein zweites,
  ///     naeheres `Shortcuts` ueber den Baum
  ///     (`_macDisablingTextShortcuts`, default_text_editing_shortcuts.dart:897)
  ///     und riegelt die blanke Leer- und Eingabetaste dort ein weiteres Mal.
  ///     Auf windows/linux gibt es diese zweite Lage nicht
  ///     (`_getDisablingShortcut` gibt fuer sie null, 989-994). Der Weg zur
  ///     Aktivierung ist damit auf macOS ein anderer, das Ergebnis muss dasselbe
  ///     sein — hier gemessen.
  ///
  /// NICHT plattformabhaengig und deshalb nur auf windows: die Baumform
  /// (`Widget.canUpdate` kennt keine Plattform), die Breitenrechnung des Gitters
  /// (Zahlen aus dem Layout) und der ESCAPE-Fall (die Bindung dafuer ist unsere
  /// eigene in `CallbackShortcuts`, und `defaultShortcuts` legt Escape auf
  /// beiden Karten auf `DismissIntent`, app.dart:1272 und 1351).
  ///
  /// UND DAS WEB LAEUFT HIER GAR NICHT MIT: `kIsWeb` ist eine Konstante des
  /// Uebersetzers, kein Schalter — im Widget-Test laesst es sich nicht setzen.
  /// Der vierte Zweig von `_imFenster` bleibt damit ungemessen; was fuer ihn
  /// gilt, steht als Fundstelle an `_mitTasten` in main.dart.
  void aufBeidenFenstern(
      String name, Future<void> Function(WidgetTester) koerper) {
    for (final pl in const [TargetPlatform.windows, TargetPlatform.macOS]) {
      imFenster(name, koerper, plattform: pl);
    }
  }

  /// Ein Fenster, wie es auf einem Schreibtisch steht.
  ///
  /// 1600x1000 ist nicht beliebig: ab 900 px greift die Zwei-Spalten-Anordnung,
  /// und die rechte Spalte ist dort auf 720 begrenzt. Genau in ihr
  /// stand die alte Breitenrechnung falsch — mit der Fensterbreite ergab sie
  /// (1600-50)/2 = 775 px je Kaestchen, also mehr als die 676 px Innenbreite.
  void fensterGroesse(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Baut die App bis zum ersten Bildschirm ('onboard').
  ///
  /// `runAsync` um den Start und feste Pumpschritte statt `pumpAndSettle`:
  /// diese App animiert dauerhaft, den erwarteten Stillstand gibt es nie.
  Future<void> starte(WidgetTester tester) async {
    fensterGroesse(tester);
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Der Fokusknoten, in dem [wo] steckt.
  FocusNode knotenVon(WidgetTester tester, Finder wo) =>
      Focus.of(tester.element(wo));

  /// Tabbt, bis [wo] den Fokus hat — und sagt, nach dem wievielten Tab.
  ///
  /// UEBER TAB UND NICHT UEBER `requestFocus`: geprueft werden soll der Weg,
  /// den ein Mensch nimmt. Ein von Hand gesetzter Fokus haette auch dann
  /// funktioniert, wenn die Tab-Reihenfolge das Ziel nie erreicht.
  Future<int> tabbeBisZu(WidgetTester tester, Finder wo) async {
    for (var i = 1; i <= 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump(const Duration(milliseconds: 100));
      if (knotenVon(tester, wo).hasPrimaryFocus) return i;
    }
    fail('die Tab-Reihenfolge erreicht dieses Bedienelement gar nicht');
  }

  /// Wie viele Bedienelemente des Bildschirms Tab ueberhaupt anlaufen kann.
  ///
  /// `_Bedienbar` baut fuer jedes einen [FocusableActionDetector] und schaltet
  /// ihn bei `onTap == null` auf `enabled: false` — dann nimmt er keinen Fokus.
  /// Gezaehlt statt hingeschrieben, damit die Zahl mit dem Bildschirm wandert.
  int bedienelemente(WidgetTester tester) => find
      .byWidgetPredicate((w) => w is FocusableActionDetector && w.enabled)
      .evaluate()
      .length;

  /// onboard → 'secure': Identitaet anlegen und die Woerter bestaetigen.
  ///
  /// `runAsync` mitten drin, weil `doCreate` echte Arbeit im Kern auslaesst und
  /// der Bildschirm 'creating' erst danach weiterspringt.
  Future<void> bisSecure(WidgetTester tester) async {
    await tester.tap(find.text('CREATE IDENTITY'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// weiter bis 'id', ohne einen Zugriffsfaktor einzurichten.
  Future<void> bisId(WidgetTester tester) async {
    await bisSecure(tester);
    await tester.tap(find.text('SKIP FOR NOW'));
    await tester.pump(const Duration(milliseconds: 600));
  }

  aufBeidenFenstern('EINGABE DRUECKT DEN FOKUSSIERTEN VERWEIS, nicht den '
      'Hauptknopf', (tester) async {
    await starte(tester);
    final verweis = find.text('I ALREADY HAVE 12 WORDS');
    expect(find.text('CREATE IDENTITY'), findsOneWidget,
        reason: 'wir stehen nicht auf dem Anfangsbildschirm');
    expect(verweis, findsOneWidget);

    // Die Tab-Reihenfolge auf 'onboard': der Tastenfang ist `skipTraversal`,
    // es geht also beim ersten echten Bedienelement los. Der Verweis ist das
    // letzte Element des Bildschirms und in wenigen Tabs erreicht.
    //
    // DIE OBERGRENZE KOMMT AUS DEM BAUM. Hier stand `lessThanOrEqualTo(8)`, und
    // das konnte nie zuschlagen: [tabbeBisZu] laeuft nur bis 8 und ruft danach
    // `fail` — ein Rueckgabewert ueber 8 gibt es nicht. Verglichen wird jetzt
    // mit der GEZAEHLTEN Zahl der anlaufbaren Bedienelemente; mehr Tabs als es
    // Elemente gibt kann der Weg zum letzten nicht brauchen. Am 30.07.2026 sind
    // das auf 'onboard' zwei (Hauptknopf und Verweis), und der Verweis liegt auf
    // dem zweiten Tab — die Grenze sitzt also stramm und wuerde rot, sobald der
    // Verweis hinter ein neues Element rutscht.
    final tabs = await tabbeBisZu(tester, verweis);
    expect(tabs, lessThanOrEqualTo(bedienelemente(tester)));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 600));

    // DAS IST DER BEHOBENE FEHLER: hier stand vorher der Bildschirm "wird
    // angelegt" und danach die zwoelf Woerter — die Eingabetaste hatte den
    // Hauptknopf gedrueckt und eine echte Identitaet erzeugt.
    expect(st.hatIdentitaet, isFalse,
        reason: 'die Eingabetaste hat doCreate ausgeloest statt den '
            'fokussierten Verweis — genau der Fehler vom 30.07.2026');
    expect(find.text('RESTORE IDENTITY'), findsOneWidget,
        reason: 'der fokussierte Verweis hat nicht zur Wiederherstellung '
            'gefuehrt');
    expect(find.text('YOUR 12 WORDS'), findsNothing);
  });

  aufBeidenFenstern('und die Leertaste tut dort dasselbe', (tester) async {
    // DIE GEGENPROBE ZUM AUSEINANDERLAUFEN. Die Leertaste ging schon vorher
    // richtig, weil sie nie gebunden war — dass beide Tasten jetzt dasselbe
    // tun, ist der Beweis, dass die Eingabetaste ueber denselben Weg laeuft
    // (ActivateIntent) statt daneben.
    await starte(tester);
    final verweis = find.text('I ALREADY HAVE 12 WORDS');
    await tabbeBisZu(tester, verweis);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 600));

    expect(st.hatIdentitaet, isFalse);
    expect(find.text('RESTORE IDENTITY'), findsOneWidget);
  });

  aufBeidenFenstern(
      'ohne Fokus auf einem Bedienelement bleibt Eingabe der Hauptknopf',
      (tester) async {
    // DIE ZWEITE GEGENPROBE, und sie ist die wichtigere: den Fehler von oben
    // koennte man auch beheben, indem man die Eingabetaste ganz abschaltet.
    // Dann waere die Abfolge im Fenster wieder nur mit der Maus zu bedienen.
    await starte(tester);
    expect(find.text('CREATE IDENTITY'), findsOneWidget);

    // Nichts angetabbt: der Fokus liegt auf dem Tastenfang, den
    // `_sorgeFuerFokus` beim Bildschirmwechsel dorthin gelegt hat.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 600));

    // Bis der Verbindungsversuch der Attrappe ausgelaufen ist (900 ms in
    // fake_messenger_core.dart:150) — ein Timer, der den Test ueberlebt, gilt
    // flutter_test als Fehler.
    await tester.pump(const Duration(milliseconds: 1000));

    expect(find.text('CREATE IDENTITY'), findsNothing,
        reason: 'die Eingabetaste hat den Hauptknopf nicht gedrueckt — im '
            'Fenster waere die Abfolge damit nur noch mit der Maus bedienbar');
    expect(st.hatIdentitaet, isTrue);
  });

  // BEIDE MEHRZEILIGEN FELDER, nicht nur eins. `_mitStrgEingabe` liegt um zwei
  // Felder: das Phrasenfeld auf 'restore' (_phraseFokus, maxLines 4) und das
  // Adressfeld auf 'add' (_addFokus, maxLines 3). Bis zum 30.07.2026 war nur das
  // erste festgenagelt — der Riegel ist derselbe, der Beleg war es nicht.
  //
  // Der Weg zum Adressfeld ist der laengere, weil 'add' eine Identitaet braucht.
  // Der Text, an dem man sieht, dass die Abkuerzung lief, ist je Feld ein
  // anderer: 'alpha beta gamma' sind drei Woerter (Klage von `_stelleWieder`)
  // und, ohne Leerzeichen und Bindestriche gelesen, keine gueltige Adresse
  // (Klage von `sendReq` ueber `letzterFehler == 'adresseUngueltig'`).
  final felder = <(String, Future<void> Function(WidgetTester), String, String)>[
    (
      'PHRASENFELD',
      (WidgetTester tester) async {
        await tester.tap(find.text('I ALREADY HAVE 12 WORDS'));
        await tester.pump(const Duration(milliseconds: 400));
      },
      'RESTORE IDENTITY',
      'That is 3 words, it needs 12.',
    ),
    (
      'ADRESSFELD',
      (WidgetTester tester) async {
        await bisId(tester);
        await tester.tap(find.text('+'));
        await tester.pump(const Duration(milliseconds: 600));
      },
      'ADD CONTACT',
      'That is not a valid BitDM ID. Check for typos — the ID carries a '
          'checksum.',
    ),
  ];

  for (final (name, hin, titel, geklagt) in felder) {
    aufBeidenFenstern('IM $name BLEIBEN EINGABE UND LEERTASTE BEIM TEXT',
        (tester) async {
      // DIE KEHRSEITE DER DREI FAELLE OBEN. Die Handlung fuer ActivateIntent
      // liegt ueber dem GANZEN Baum, ein Textfeld liegt also auch darunter — und
      // `EditableText` bringt fuer diese Absicht keine eigene Handlung mit. Beim
      // Gegenlesen am 30.07.2026 war das der Verdacht, im Feld loese die blanke
      // Eingabe den Hauptknopf aus statt einen Umbruch zu setzen.
      //
      // GEMESSEN TUT SIE ES NICHT, und der Grund gehoert festgehalten:
      // `DefaultTextEditingShortcuts` haengt naeher am Feld als das `Shortcuts`
      // von WidgetsApp und bildet die blanke Eingabe- UND Leertaste vorher auf
      // `DoNothingAndStopPropagationTextIntent` ab — auf windows und linux aus
      // `_clipboardShortcuts` (default_text_editing_shortcuts.dart:328-329), auf
      // macOS aus `_macShortcuts` selbst (753-754) plus
      // `_macDisablingTextShortcuts` (897). Alle Fundstellen stehen bei
      // `_mitTasten` in main.dart. Zu ActivateIntent wird die Taste im Feld also
      // gar nicht — auf beiden hier gelaufenen Plattformen.
      //
      // Dieser Fall haelt genau das fest. Er ist kein Selbstlaeufer: haengt die
      // Eingabetaste wieder als blanke Taste in einem `CallbackShortcuts` ueber
      // dem Baum — der gefaehrlichste Fehler des 30.07.2026 —, dann liegt SIE
      // naeher am Feld als Flutters Riegel, und dieser Fall wird rot. So
      // nachgestellt und gesehen, fuer BEIDE Felder.
      await starte(tester);
      await hin(tester);
      expect(find.text(titel), findsOneWidget,
          reason: 'wir stehen nicht auf dem Bildschirm mit dem $name');

      final feld = find.byType(TextField);
      expect(feld, findsOneWidget,
          reason: 'auf diesem Bildschirm gibt es genau ein Textfeld');
      await tester.enterText(feld, 'alpha beta gamma');
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<TextField>(feld).focusNode?.hasPrimaryFocus, isTrue,
          reason: 'ohne Fokus IM FELD prueft dieser Fall nichts');

      // NICHT `tester.sendKeyEvent`: gemessen wird, ob die Taste VERBRAUCHT
      // wird. Nur eine unverbrauchte Taste erreicht die Textschicht, die den
      // Umbruch bzw. das Leerzeichen setzt — im Widget-Test gibt es diese
      // Schicht nicht (Zeichen kommen hier ueber `enterText`), der Verbrauch ist
      // also das einzige, was sich hier ehrlich messen laesst.
      Future<bool> taste(LogicalKeyboardKey k) async {
        final verbraucht = await simulateKeyDownEvent(k);
        await simulateKeyUpEvent(k);
        await tester.pump(const Duration(milliseconds: 400));
        return verbraucht;
      }

      expect(await taste(LogicalKeyboardKey.enter), isFalse,
          reason: 'die Eingabetaste wurde im Feld verbraucht — dann kommt dort '
              'nie ein Zeilenumbruch an');
      expect(find.text(geklagt), findsNothing,
          reason: 'die blanke Eingabetaste hat den Hauptknopf ausgeloest');

      expect(await taste(LogicalKeyboardKey.space), isFalse,
          reason: 'die Leertaste wurde im Feld verbraucht — dann laesst sich '
              'das Feld nicht mit durch Leerzeichen getrennten Gruppen fuellen');
      expect(find.text(geklagt), findsNothing,
          reason: 'die Leertaste hat den Hauptknopf ausgeloest');

      // UND DIE ABKUERZUNG MUSS BLEIBEN. Sonst waere der billigste "Fix" hier,
      // dem Feld jede Aktivierung zu nehmen — dann waere der Bildschirm ohne
      // Maus nicht abzuschliessen.
      await simulateKeyDownEvent(LogicalKeyboardKey.control);
      await simulateKeyDownEvent(LogicalKeyboardKey.enter);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      await simulateKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(geklagt), findsOneWidget,
          reason: 'Strg+Eingabe hat nichts ausgeloest — die Abkuerzung aus '
              '_mitStrgEingabe ist verlorengegangen');
    });
  }

  imFenster('DIE BAUMFORM BLEIBT, WENN DER HAUPTKNOPF WEGFAELLT',
      (tester) async {
    // `_mitTasten` haengte den Actions-Knoten nur ein, wenn es einen
    // Hauptknopf gab. An derselben Stelle stand damit einmal Actions und einmal
    // Focus — `Widget.canUpdate` ist dann falsch, und Flutter wirft den ganzen
    // Teilbaum weg statt ihn zu aktualisieren. Jedes Element darunter ist
    // danach ein neues, samt State: Ueberfahr- und Fokusmarken fallen zurueck.
    //
    // Auf 'secure' laesst sich das ohne Bildschirmwechsel ausloesen: der
    // Hauptknopf ist dort `go('id')`, und sobald die Einrichtungs-Ueberlagerung
    // aufgeht, gibt [_hauptKnopf] null zurueck.
    await starte(tester);
    await bisSecure(tester);

    final titel = find.text('SECURE THIS DEVICE');
    expect(titel, findsOneWidget, reason: 'wir stehen nicht auf "Secure this '
        'device"');
    final vorher = tester.element(titel);

    // Die Zugriffszeile IST das Bedienelement; 'NOT SET UP' ist ihr rechter
    // Text. Im Fenster ueberlebt auf 'secure' nur die Passwort-Zeile, es gibt
    // also genau eine.
    await tester.tap(find.text('NOT SET UP'));
    await tester.pump(const Duration(milliseconds: 400));
    // Die Passwort-Einrichtung bringt zwei Felder mit, 'secure' selbst keins.
    expect(find.byType(TextField), findsNWidgets(2),
        reason: 'die Ueberlagerung ist nicht aufgegangen, der Hauptknopf ist '
            'also gar nicht weggefallen');
    expect(tester.element(titel), same(vorher),
        reason: 'der Teilbaum wurde neu aufgebaut, statt aktualisiert zu '
            'werden — die Baumform in _mitTasten haengt wieder am Zustand');
  });

  imFenster('ESCAPE LEBT AUCH NACH EINEM FOKUSVERLUST', (tester) async {
    // Escape haengt in einem `CallbackShortcuts` UNTER dem FocusScope der
    // Route. Tastenereignisse laufen vom fokussierten Knoten nach oben — liegt
    // der Fokus beim Scope, ist die Bindung darunter und wird nie gefragt.
    //
    // `_sorgeFuerFokus` fuellt diese Luecke, aber nur EINMAL JE BILDSCHIRM.
    // Verliert der Fokus danach seinen Knoten (ein Bedienelement verschwindet,
    // oder sein onTap wird null), fiel er auf den Scope zurueck und Escape war
    // tot — bis zum naechsten Bildschirmwechsel. Genau den Fall stellt
    // `unfocus()` hier nach.
    await starte(tester);
    await tester.tap(find.text('I ALREADY HAVE 12 WORDS'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('RESTORE IDENTITY'), findsOneWidget);

    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump(const Duration(milliseconds: 100));
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()),
        reason: 'der Fokus ist beim FocusScope der Route liegengeblieben — '
            'Escape findet seine Bindung dort nicht mehr');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('CREATE IDENTITY'), findsOneWidget,
        reason: 'Escape hat nicht zurueckgefuehrt');
  });

  imFenster('DIE ADRESSE STEHT ZU ZWEI JE ZEILE', (tester) async {
    await starte(tester);
    await bisId(tester);

    expect(find.text('MY ID'), findsWidgets,
        reason: 'wir stehen nicht auf "Meine ID"');

    // Das Gitter der Vierergruppen ist auf diesem Bildschirm das einzige Wrap.
    // Nachgezaehlt am 30.07.2026: main.dart hat fuenf Wrap. Dieses hier steht in
    // `_zweiSpaltenGitter` (und wird nur von 'phrase' und 'id' benutzt), die
    // anderen vier auf 'restore' bei den einzeln geprueften Woertern, im Bogen
    // bei der Pruefnummer, in `_schritt` der Push-Hilfe und im Sprungbogen des
    // Entwicklermodus. Auf 'test' und im Nahbereich steht KEINS — das stand hier
    // vorher und war falsch.
    final gitter = find.byType(Wrap);
    expect(gitter, findsOneWidget);
    final kaesten = find.descendant(of: gitter, matching: find.byType(SizedBox));
    expect(kaesten.evaluate().length, greaterThanOrEqualTo(4),
        reason: 'die Adresse wird gar nicht in Gruppen gezeigt');

    // 676 px ist die Innenbreite der rechten Schreibtischspalte (720 minus 44
    // px Rand) — hier gemessen und nicht angenommen, denn genau diese Zahl
    // begruendet den Kommentar an `_zweiSpaltenGitter`.
    expect(tester.getSize(gitter).width, 676.0);

    final erste = tester.getRect(kaesten.at(0));
    final zweite = tester.getRect(kaesten.at(1));
    final dritte = tester.getRect(kaesten.at(2));

    expect(zweite.top, erste.top,
        reason: 'DAS IST DER BEHOBENE FEHLER: die zweite Gruppe steht unter '
            'der ersten statt daneben — mit der Fensterbreite gerechnet war '
            'jedes Kaestchen 775 px breit und wurde auf 676 geklemmt');
    expect(zweite.left, greaterThan(erste.right));
    expect(dritte.top, greaterThan(erste.top),
        reason: 'zwei je Zeile heisst: die dritte Gruppe faengt eine neue an');
    expect(erste.width, lessThan(676.0 / 2),
        reason: 'ein Kaestchen ist breiter als die halbe Spalte, zwei je Zeile '
            'gehen damit nie auf');
  });
}
