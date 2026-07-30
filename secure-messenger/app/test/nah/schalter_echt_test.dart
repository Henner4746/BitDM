// schalter_echt_test.dart — derselbe Schalter, aber gegen den ECHTEN Kern.
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// Am 28.07.2026 liess sich "Bluetooth benutzen" auf zwei echten Telefonen
// nicht einschalten. Der Schalter sprang kommentarlos zurueck, und im
// Verbindungstest fehlte die Nahbereich-Zeile ganz — sie erscheint nur, wenn
// `naheAn` wahr ist, und das wurde es nie.
//
// Gesucht habe ich den Fehler danach im KERN: in setPreferences, in der
// Warteschlange des Nahbereichs, in der Fehlerbehandlung. Alles falsch, und
// die Mutationsprobe hat es gezeigt — die Tests, die ich dort schrieb,
// ueberlebten jede Mutation, weil es an dieser Stelle nichts zu brechen gab.
//
// Was fehlte, war ein Test AUF DER ANDEREN SEITE: nicht "tut der Kern das
// Richtige, wenn man ihn ruft", sondern "wird er ueberhaupt gerufen". Zwischen
// dem Finger und dem Kern liegen ein GestureDetector, ein Zustandsobjekt und
// eine asynchrone Kette — und keine einzige Zeile davon war geprueft.
//
// DIESE FASSUNG NIMMT DEN ECHTEN KERN.
//
// Der Zwilling daneben (schalter_widget_test.dart) laeuft gegen
// FakeMessengerCore und ist gruen — der Schalter TUT dort, was er soll. Auf
// zwei echten Telefonen tut er es nicht. Der Unterschied muss also in etwas
// liegen, das die Attrappe nicht nachstellt.
//
// Genau dort setzt dieser Test an: dieselbe Oberflaeche, derselbe Tipp, aber
// RealMessengerCore mit echter Datenbank dahinter — also der Weg
// setPreferences -> _richteNaheEin -> _setzeNaheAuf, den die Attrappe
// ueberspringt.
//
// Bleibt er gruen, liegt es an noch etwas anderem (dem echten Nahfunk ueber
// den Plattformkanal). Wird er rot, ist der Fehler eingekreist.
//
// ══════════════════════════════════════════════════════════════ UNFERTIG
//
// Er laeuft noch nicht: alle vier Faelle enden in "did not complete". Zwei
// Erklaerungen sind schon ausgeschlossen — es ist NICHT die Navigation (die
// Reihenfolge Aufbauen/Identitaet ist unten richtig herum) und NICHT die
// Dauer-Animation (feste Pumpschritte statt pumpAndSettle aendern nichts).
//
// Was bleibt: der Start der App wartet auf Plattformkanaele, die hier niemand
// beantwortet.  ist nachgestellt, aber beim Aufbauen kommen
// mehrere dazu — Empfang, Benachrichtigungen, Push. Ein einziger
// unbeantworteter genuegt, und der Aufbau kehrt nie zurueck.
//
// NAECHSTER SCHRITT: die uebrigen Kanaele mitnachstellen (die Namen stehen in
// core/empfang.dart, core/benachrichtigungen.dart, core/push.dart) — oder den
// Einstellungsbildschirm einzeln bauen statt der ganzen App. Das zweite ist
// weniger wert: gerade der Weg vom Finger durch die App ist ja das
// Ungepruefte.

import 'package:bitdm/app_state.dart';
import 'dart:io';

import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/main.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ein Funk, der alles kann — damit dieser Test den SCHALTER misst und nicht
/// die Bluetooth-Lage.
class FunkAttrappe implements Nahfunk {
  int rechteAbfragen = 0;
  Rechtelage lage = Rechtelage.erteilt;
  Funkzustand zustandWert = const Funkzustand(
      zuAlt: false, vorhanden: true, an: true, rechte: true, jeWerbung: 40);

  @override
  Future<Funkzustand> zustand() async => zustandWert;

  @override
  Future<Rechtelage> fordereRechte() async {
    rechteAbfragen++;
    return lage;
  }

  @override
  Future<void> oeffneEinstellungen() async {}

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

/// Der Schluesselspeicher des Geraets gibt es im Test nicht.
class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

void main() {
  late AppState st;
  late FunkAttrappe funk;
  late Directory ordner;
  var schonWeg = false;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    funk = FunkAttrappe();
    ordner = await Directory.systemTemp.createTemp('bitdm-schalter-echt');
    st = AppState(RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      // Ein Nahbereich ueber der Funk-Attrappe: der Kern geht seinen echten
      // Weg, nur die Bluetooth-Kante ist nachgestellt.
      nahFactory: () => Nahbereich(funk: funk),
    ))
      ..funk = funk;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    if (!schonWeg) st.dispose();
    try {
      ordner.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Baut die App und geht in die Einstellungen.
  ///
  /// FESTE PUMPSCHRITTE STATT pumpAndSettle. Diese App animiert dauerhaft —
  /// der Verbindungspunkt pulsiert, Nachrichten gleiten herein. pumpAndSettle
  /// wartet auf einen Stillstand, den es hier nie gibt, und laeuft dann in
  /// seine Zeitgrenze statt in eine Aussage.
  Future<void> zuDenEinstellungen(WidgetTester tester) async {
    // `runAsync` UM ALLES, WAS ECHTE ZEIT BRAUCHT.
    //
    // `testWidgets` laeuft in einer kuenstlichen Zeit: Timer feuern nur beim
    // Pumpen, und ein `await` auf etwas, das hinter einem Timer haengt, wird
    // dort NIE fertig. `AppState.boot()` tut genau das — nachgemessen mit
    // einer Probe, die nichts weiter tat als booten: sie lief in die
    // Zeitgrenze, ohne dass ein einziges Widget im Spiel war.
    //
    // Diese Zeile ist der ganze Unterschied zwischen "der Test haengt" und
    // "der Test misst".
    await tester.runAsync(() async {
      await st.boot();
    });
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));

    // ERST BAUEN, DANN DIE IDENTITAET — nicht umgekehrt.
    //
    // Der Bildschirm wechselt von "onboard" auf "chats" nur, wenn AppState
    // eine Aenderung MELDET (main.dart, ). Wer die Identitaet
    // vor dem Aufbauen anlegt, hoert diese Meldung nicht mehr: die App bleibt
    // im Onboarding, und der Test scheitert an "SETTINGS nicht gefunden" —
    // an der Navigation also, nicht an dem, was er messen soll.
    // DURCHS ONBOARDING TIPPEN statt die Identitaet daneben anzulegen.
    //
    // `Home` startet fest auf "onboard" (main.dart) und wechselt erst, wenn
    // AppState eine Aenderung meldet. Wer die Identitaet an der Oberflaeche
    // vorbei anlegt, sitzt danach immer noch im Onboarding — nachgemessen:
    // `hatIdentitaet=true`, auf dem Bildschirm steht "No name.".
    //
    // Der Weg ueber den Knopf ist ohnehin der ehrlichere: er ist der, den ein
    // Mensch geht, und er prueft ihn gleich mit.
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

  /// Beendet die App NOCH IM TESTKOERPER.
  ///
  /// Der echte Kern erreicht das Relay hier nie (127.0.0.1:1) und plant nach
  /// jedem Fehlschlag den naechsten Versuch (app_state.dart,
  /// _planeWiederverbindung) — ein Timer, der beim Testende noch laeuft.
  /// `testWidgets` bricht darauf ab ("Pending timers"), und zwar BEVOR
  /// tearDown drankommt; das Aufraeumen dort ist also zu spaet.
  ///
  /// Das ist ein Befund ueber den Test, nicht ueber das Programm: auf dem
  /// Geraet SOLL es ja wieder versucht werden.
  Future<void> schluss(WidgetTester tester) async {
    st.dispose();
    schonWeg = true;
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Scrollt den Schalter ins Bild und tippt ihn.
  ///
  /// Ueber `ensureVisible` und nicht ueber feste Koordinaten: die Liste ist
  /// lang, und ein Tipp ins Leere saehe genauso aus wie ein Schalter, der
  /// nicht funktioniert — was hier ja gerade die Frage ist.
  Future<void> tippeSchalter(WidgetTester tester) async {
    final schalter = find.text('Use Bluetooth');
    expect(schalter, findsOneWidget,
        reason: 'der Schalter ist gar nicht auf dem Bildschirm');
    await tester.ensureVisible(schalter);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(schalter);
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('EIN TIPP AUF DEN SCHALTER SCHALTET IHN EIN', (tester) async {
    await zuDenEinstellungen(tester);
    expect(st.einstellungen.naheAn, isFalse, reason: 'ab Werk aus');

    await tippeSchalter(tester);

    expect(st.einstellungen.naheAn, isTrue,
        reason: 'DAS IST DIE GANZE FRAGE: kommt der Tipp bis zur Einstellung? '
            'Am 28.07. kam er es auf zwei echten Geraeten nicht, und kein '
            'Test hat es gemerkt');

    await schluss(tester);
  });

  testWidgets('und ein zweiter Tipp wieder aus', (tester) async {
    // Die Gegenprobe. Ein Schalter, der nur in eine Richtung geht, ist kein
    // Schalter — und ein Test, der nur das Einschalten prueft, faende das nie.
    await zuDenEinstellungen(tester);
    await tippeSchalter(tester);
    expect(st.einstellungen.naheAn, isTrue);

    await tippeSchalter(tester);
    expect(st.einstellungen.naheAn, isFalse);

    await schluss(tester);
  });

  testWidgets('OHNE BERECHTIGUNG BLEIBT ER AUS', (tester) async {
    // Der Fall, fuer den die Rechteabfrage gebaut ist: ein Schalter auf "an",
    // waehrend die Berechtigung fehlt, waere eine Einstellung ohne Wirkung.
    funk.zustandWert = const Funkzustand(
        zuAlt: false, vorhanden: true, an: true, rechte: false, jeWerbung: 40);
    funk.lage = Rechtelage.abgelehnt;

    await zuDenEinstellungen(tester);
    await tippeSchalter(tester);

    expect(funk.rechteAbfragen, greaterThan(0),
        reason: 'es wurde gar nicht erst gefragt');
    expect(st.einstellungen.naheAn, isFalse,
        reason: 'ohne Berechtigung darf er nicht auf an springen');

    await schluss(tester);
  });

  testWidgets('wird sie erteilt, geht er an', (tester) async {
    // Und die Gegenrichtung dazu — sonst bestuende der Test oben auch dann,
    // wenn der Schalter GRUNDSAETZLICH nichts tut.
    funk.zustandWert = const Funkzustand(
        zuAlt: false, vorhanden: true, an: true, rechte: false, jeWerbung: 40);
    funk.lage = Rechtelage.erteilt;

    await zuDenEinstellungen(tester);
    await tippeSchalter(tester);

    expect(funk.rechteAbfragen, greaterThan(0));
    expect(st.einstellungen.naheAn, isTrue);

    await schluss(tester);
  });
}
