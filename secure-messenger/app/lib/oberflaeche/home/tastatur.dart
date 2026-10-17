// tastatur.dart — Tastenfang, Fokus, Strg+Eingabe, Hauptknopf.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Tastatur on _HomeState {
  /// Legt Eingabetaste und Escape auf die Abfolgen — nur im Fenster.
  ///
  /// WARUM UEBER DEN VORHANDENEN WEGEN UND NICHT DANEBEN: Escape ruft
  /// [_gehZurueck], also genau die Logik, die schon hinter der Zurueck-Geste
  /// und den ‹-Knoepfen steht. Eine zweite Ordnung der Zurueck-Ziele waere die
  /// naechste Stelle, an der beide auseinanderlaufen. Auf 'phrase' und
  /// 'creating' gibt [_zurueckZiel] absichtlich null zurueck — dort tut Escape
  /// dann auch nichts, und das ist richtig: die zwoelf Woerter stehen nur
  /// einmal da.
  ///
  /// Die Eingabetaste liegt auf dem Hauptknopf — aber nur, solange sie kein
  /// naeherer Knoten vorher abfaengt. Zwei tun das, und beide gehoeren zu
  /// Flutter, nicht hierher:
  ///
  ///   * JEDES BEDIENELEMENT bringt fuer [ActivateIntent] seine eigene Handlung
  ///     mit ([_Bedienbar] setzt sie ueber [_aktivierung]). Die Handlung wird
  ///     von unten nach oben gesucht, also findet sie zuerst die des Knopfes.
  ///   * EIN FOKUSSIERTES TEXTFELD faengt die blanke Eingabe- UND Leertaste ab,
  ///     bevor daraus ueberhaupt eine Absicht wird: `DefaultTextEditingShortcuts`
  ///     haengt UNTER dem `Shortcuts` von WidgetsApp, sieht die Taste also
  ///     zuerst, und bildet beide auf `DoNothingAndStopPropagationTextIntent`
  ///     ab. Das gilt fuer ALLE VIER Plattformen hinter [_imFenster], und zwar
  ///     ueber DREI verschiedene Wege — einzeln nachgesehen am 30.07.2026 in
  ///     flutter/lib/src/widgets/default_text_editing_shortcuts.dart
  ///     (flutter-Baum C:\flutter, Stand 058e0af2):
  ///
  ///     - WINDOWS und LINUX nehmen das Paar aus `_clipboardShortcuts` (294;
  ///       Leertaste 328, Eingabetaste 329, mit dem Kommentar "these keys should
  ///       go to the IME when a field is focused"). Eingestreut wird es in
  ///       `_windowsShortcuts` (779, Streuung 781) und `_linuxShortcuts` (546,
  ///       Streuung 548). `_androidShortcuts` (345, Streuung 347) fuehrt es
  ///       ebenfalls — dort greift [_imFenster] aber gar nicht, die Zeile stand
  ///       hier vorher zu Unrecht als Beleg.
  ///     - MACOS nimmt `_clipboardShortcuts` NICHT. `_macShortcuts` (590)
  ///       traegt dasselbe Paar als eigene Eintraege (Leertaste 753,
  ///       Eingabetaste 754), mit demselben Intent und demselben Kommentar.
  ///       Ausgewaehlt wird das Buendel in `_shortcuts` (961-970). Oben drauf
  ///       haengt auf macOS ausserdem `_macDisablingTextShortcuts` (897) noch
  ///       naeher am Feld; darin liegt das Paar ueber
  ///       `_commonDisablingTextShortcuts` (863; Leertaste 893, Eingabetaste
  ///       894) ein drittes Mal.
  ///     - IM WEB kommt `_webDisablingTextShortcuts` (828) als zweites,
  ///       naeheres `Shortcuts` dazu (`_getDisablingShortcut` 972-988, gebaut in
  ///       1005-1020). Es streut ebenfalls `_commonDisablingTextShortcuts` und
  ///       riegelt Leer- und Eingabetaste damit unabhaengig davon, welche
  ///       Plattform der Browser meldet.
  ///
  ///     `EditableText` antwortet auf diesen Intent mit
  ///     `DoNothingAction(consumesKey: false)` (editable_text.dart:5597): die
  ///     Taste gilt als NICHT verbraucht und erreicht die Textschicht als
  ///     Umbruch bzw. Leerzeichen. Deshalb steht in [_mitStrgEingabe] auch keine
  ///     Gegenmassnahme — sie waere eine zweite Ordnung ohne Wirkung.
  ///
  ///     WAS DAVON GEMESSEN IST: windows und macOS laufen beide im Fenster-Fall
  ///     "IM PHRASENFELD UND IM ADRESSFELD BLEIBEN EINGABE UND LEERTASTE BEIM
  ///     TEXT" (fenster_abfolge_test.dart, Schleife ueber die Plattformen).
  ///     linux teilt sich `_clipboardShortcuts` mit windows, wird also von
  ///     derselben Fundstelle getragen. NICHT GEMESSEN ist das WEB: `kIsWeb` ist
  ///     eine Konstante des Uebersetzers, im Widget-Test laesst sie sich nicht
  ///     setzen — dafuer steht hier nur die Fundstelle, kein Messwert.
  ///
  /// Der Tastenfang selbst bringt keine Handlung mit. Hat er den Fokus, laeuft
  /// die Suche an ihm vorbei und findet die Karte hier.
  ///
  /// DAS WAR DER GEFAEHRLICHSTE FEHLER DES 30.07.2026 und er ist es wert,
  /// aufgeschrieben zu werden: die Bindung hing zuerst als blanke Eingabetaste
  /// in `CallbackShortcuts`. Tastenereignisse laufen vom fokussierten Knoten
  /// nach OBEN, und dieses CallbackShortcuts lag naeher am Knopf als das
  /// `Shortcuts` von WidgetsApp — es sah die Taste also zuerst und meldete sie
  /// als behandelt (shortcuts.dart, `_applyKeyEventBinding`: `accepts` wahr →
  /// handled, ganz egal, was der Rueckruf tut — ein Wachposten im Rueckruf
  /// haette die Taste also trotzdem verbraucht, und der naheliegende Vorschlag
  /// `if (primaryFocus != _tastenFokus) return;` haette den Fehler nur
  /// versteckt). FOLGE: auf 'onboard' legte Tab auf "Ich habe schon 12 Woerter"
  /// plus Eingabe eine NEUE IDENTITAET an. Die Leertaste ging richtig, weil sie
  /// nicht gebunden war — die beiden Tasten liefen auseinander.
  ///
  /// Deshalb liegt die Eingabetaste jetzt als [_aktivierung] AM Fang und nicht
  /// als Taste darueber: WidgetsApp macht aus der Taste ein `ActivateIntent`,
  /// und dessen Handlung wird von unten nach oben gesucht. Hat ein Knopf den
  /// Fokus, findet die Suche zuerst SEINE Handlung; hat der Fang den Fokus,
  /// findet sie diese hier. Festgenagelt in
  /// test/oberflaeche/fenster_abfolge_test.dart.
  ///
  /// Escape bleibt in `CallbackShortcuts`, und zwar bewusst: es soll auch dann
  /// zurueckfuehren, wenn ein Textfeld oder ein Knopf den Fokus hat. Es haengt
  /// aber UNTER dem FocusScope der Route — liegt der Fokus dort, kommt Escape
  /// nicht an. Dagegen stehen [_sorgeFuerFokus] und [_fokusNachfassen].
  Widget _mitTasten(Widget kind) {
    if (!_imFenster) return kind;
    _sorgeFuerFokus();
    final haupt = _hauptKnopf();
    // Der Fang MUSS unter den Tasten und unter den Handlungen haengen: geprueft
    // und gesucht wird nur, was UEBER dem fokussierten Knoten liegt.
    //
    // DIE BAUMFORM BLEIBT UEBER ALLE ZUSTAENDE GLEICH. Vorher hing der
    // Actions-Knoten nur ein, wenn es einen Hauptknopf gab — an derselben
    // Stelle stand damit einmal Actions und einmal Focus. `Widget.canUpdate`
    // vergleicht runtimeType, ist dann falsch, und Flutter aktualisiert den
    // Teilbaum nicht, sondern wirft ihn weg und baut ihn neu
    // (framework.dart, `updateChild`: deactivateChild + inflateWidget). Jedes
    // State-Objekt der ganzen App waere neu, samt der Ueberfahr- und
    // Fokusmarken in [_BedienbarState] — allein weil eine Ueberlagerung
    // aufgeht. Ohne Hauptknopf steht deshalb eine LEERE Karte drin: dann sucht
    // [ActivateIntent] einfach weiter nach oben, genau wie ohne den Knoten.
    //
    // Sonst aendert hier nichts seine Form: der Zweig oben haengt an
    // [_imFenster], und das ist die Plattform, keine Regung des Zustands.
    Widget baum = Focus(focusNode: _tastenFokus, child: kind);
    baum = Actions(
      actions: haupt == null
          ? const <Type, Action<Intent>>{}
          : _aktivierung(haupt),
      child: baum,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _gehZurueck,
      },
      child: baum,
    );
  }

  /// Legt den Tastaturfokus dorthin, wo er hingehoert — einmal je Bild.
  ///
  /// EINE STELLE STATT `autofocus` AN DEN FELDERN. Zwei Knoten mit `autofocus`
  /// in derselben Fokusgruppe sind ein Wettlauf: Flutter wendet nur den ersten
  /// an, sobald die Gruppe ein fokussiertes Kind hat, wird der zweite
  /// verworfen. Der Tastenfang haette damit den Feldern den Fokus weggenommen.
  ///
  /// Genommen wird der Fokus nur, wenn ihn NICHTS hat: `primaryFocus` ist dann
  /// der FocusScope der Route. Wer selbst geklickt oder getabbt hat, behaelt
  /// ihn — auch ein offener Dialog, dessen Feld selbst `autofocus` traegt.
  void _sorgeFuerFokus() {
    // EINMAL JE BILDSCHIRM, nicht je Aufbau. [_mitTasten] laeuft im build, und
    // gebaut wird bei jeder Regung des AppState und bei jedem Fokuswechsel —
    // jeder Aufruf haengte bisher einen weiteren addPostFrameCallback an.
    //
    // Die Marke haengt am Bildschirm und nicht an [go]: 'creating', 'phrase'
    // und der ‹-Knopf auf 'restore' setzen `screen` direkt per setState, die
    // gingen bei einem Aufruf in go() leer aus.
    if (_zuletztFokussiert == screen) return;
    _zuletztFokussiert = screen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // "Frei" heisst: es hat niemand ECHTES den Fokus. Der Tastenfang selbst
      // zaehlt dazu — sonst haette er den Feldern beim Bildschirmwechsel den
      // Fokus weggenommen und behalten (am 30.07.2026 genau so gemessen: auf
      // 'restore' stand der Fokus auf dem Fang, nicht im Phrasenfeld).
      final jetzt = FocusManager.instance.primaryFocus;
      final frei =
          jetzt == null || jetzt is FocusScopeNode || jetzt == _tastenFokus;
      if (!frei) return;
      // Wo genau ein Bildschirm nur ein Feld hat, gehoert der Fokus dorthin —
      // sonst muesste man erst mit der Maus hineinklicken, um zu tippen.
      switch (screen) {
        case 'restore':
          _phraseFokus.requestFocus();
        case 'add':
          _addFokus.requestFocus();
        default:
          _tastenFokus.requestFocus();
      }
    });
  }

  /// Legt Strg+Eingabe auf [tun], solange [kind] den Fokus hat — nur im Fenster.
  ///
  /// Fuer mehrzeilige Felder: dort ist die Eingabetaste der Zeilenumbruch und
  /// darf es bleiben. Auf dem Telefon gibt es keine Strg-Taste, dort faellt die
  /// Huelle weg statt wirkungslos dazwischenzuliegen.
  ///
  /// UND HIER STEHT NICHTS, DAS DIE BLANKE EINGABETASTE ABWEHRT — geprueft und
  /// nicht angenommen. Die Handlungskarte aus [_mitTasten] liegt ueber dem
  /// ganzen Baum, ein Textfeld braeuchte also eigentlich einen Riegel. Es hat
  /// schon einen, und der gehoert zu Flutter: `DefaultTextEditingShortcuts`
  /// haengt naeher am Feld als das `Shortcuts` von WidgetsApp und bildet die
  /// blanke Eingabe- und Leertaste auf
  /// `DoNothingAndStopPropagationTextIntent` ab, bevor daraus [ActivateIntent]
  /// wird — Begruendung, Fundstellen und Zahlen stehen bei [_mitTasten].
  ///
  /// GEMESSEN am 30.07.2026 im Fenster-Zweig: mit einem
  /// `Actions(ActivateIntent: DoNothingAction(consumesKey: false))` um das Feld
  /// UND ohne es laufen dieselben Faelle gruen (fenster_abfolge_test.dart, "IM
  /// PHRASENFELD BLEIBEN EINGABE UND LEERTASTE BEIM TEXT"). Ein Riegel, der
  /// nichts verriegelt, ist nicht drin: er saehe wie eine Notwendigkeit aus und
  /// naehme dem naechsten Leser die Begruendung, die oben steht.
  Widget _mitStrgEingabe(VoidCallback tun, Widget kind) => !_imFenster
      ? kind
      : CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true): tun,
            const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
                tun,
          },
          child: kind,
        );

  /// Der eine offensichtliche Weiter-Knopf des aktuellen Bildschirms.
  ///
  /// Ein switch an derselben Stelle wie die Bildschirmwahl und keine neue
  /// Abstraktion: wer hier einen Bildschirm vergisst, sieht das an der Liste.
  /// Null heisst "kein eindeutiger Hauptknopf" — dann tut die Eingabetaste
  /// nichts, und das ist besser als eine Taste, die auf einem Bildschirm etwas
  /// anderes tut als auf dem daneben.
  VoidCallback? _hauptKnopf() {
    if (!st.bereit || st.gesperrt) return null;
    // Solange eine Ueberlagerung offen ist, gehoert die Taste ihr.
    if (enroll != null || panic || sheet) return null;
    return switch (screen) {
      'onboard' => doCreate,
      'phrase' => () {
          st.phraseBestaetigt();
          go('secure');
        },
      'secure' => () => go('id'),
      'restore' => _stelleWieder,
      'add' => sendReq,
      'test' => st.testLaeuft ? null : () => st.verbindungPruefen(),
      _ => null,
    };
  }
}
