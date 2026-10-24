// home.dart — der Hauptbildschirm: Home, sein Zustand (_HomeState) mit
// Lebenszyklus, Sperren und Aufraeumen, und die Bedienbar-Huelle.
//
// Aus main.dart herausgeloest, Zeichen fuer Zeichen (docs/MAIN-DART-AUFTEILUNG.md).
// Die Bildschirme und Bausteine von _HomeState stehen spaeter als Teile
// (part) in home/*.dart.

import 'dart:async';
import 'dart:io' show File;
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../core/messenger_core.dart';
import '../core/real_messenger_core.dart';
import '../core/app_lock.dart';
import '../core/fido/client_pin.dart';
import '../core/fido/ctap.dart';
import '../core/fido/stick_zugang.dart';
import '../core/lock/hardware_key_factor.dart';
import '../core/lock/unlock_factor.dart';
import '../core/lock/geraete_fach.dart';
import '../core/lock/key_vault.dart';
import '../core/lock/vault_store.dart';
import '../core/browser/browser_zugang.dart';
import '../core/sprache.dart';
import '../core/benachrichtigungen.dart';
import '../bewegung.dart';
import '../masse.dart';
import '../core/crypto/wordlist_english.dart';
import '../core/crypto/address.dart';
import '../core/empfang.dart';
import '../core/fenster.dart';
import '../core/fern_codewort.dart';
import '../core/push.dart';
import '../core/qr_bild.dart';
import '../core/verbindungstest.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data.dart';
import '../geraete_seite.dart';
import '../formatierung.dart';
import '../core/crypto/teilgeheimnis.dart';
import '../schluesselbild.dart';
import '../themen.dart';
import '../painters.dart';
import '../fido_probe_screen.dart';
import '../qr_scan_screen.dart';
import 'app_thema.dart';
import 'einbrennschutz.dart';

part 'home/bedienbar.dart';
part 'home/rahmen.dart';
part 'home/thema.dart';
part 'home/bausteine.dart';
part 'home/sperre.dart';
part 'home/zugriff.dart';
part 'home/notfall.dart';
part 'home/identitaet.dart';
part 'home/wiederherstellung.dart';
part 'home/verschluesselung.dart';
part 'home/chatliste.dart';
part 'home/kontakt_neu.dart';
part 'home/gruppen.dart';
part 'home/unterhaltung.dart';
part 'home/nachricht.dart';
part 'home/befehle.dart';
part 'home/anhaenge.dart';
part 'home/einstellungen.dart';
part 'home/nahbereich.dart';
part 'home/tastatur.dart';
part 'home/navigation.dart';

class Home extends StatefulWidget {
  const Home({super.key, required this.state});

  final AppState state;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Felder des Kerns: Bildschirm, Lebenszyklus, Zustand (home.dart)

  /// Ob der Schutz fuer den Woerter-Bildschirm gerade angemeldet ist.
  bool _phraseGeschuetzt = false;

  /// Was beim letzten Horchen galt — um den WECHSEL zu erkennen, nicht den
  /// Zustand.
  bool _warGesperrt = false;

  bool _hatteIdentitaet = false;

  // ── Felder von home/tastatur.dart

  /// Faengt den Tastaturfokus ein, wenn ihn sonst niemand hat.
  ///
  /// WARUM DAS NOETIG IST. Tastenereignisse laufen vom fokussierten Knoten nach
  /// OBEN. Hat in der App nichts den Fokus, liegt er auf dem FocusScope der
  /// Route — und das ist ueber [_mitTasten]. Escape und Eingabe kamen dort nie
  /// an, solange niemand vorher geklickt oder getabbt hatte, also genau in dem
  /// Moment, in dem man sie zuerst probiert.
  ///
  /// `skipTraversal`, damit Tab nicht auf diesem unsichtbaren Knoten anfaengt,
  /// sondern beim ersten echten Bedienelement.
  final _tastenFokus =
      FocusNode(debugLabel: 'Tastenfang', skipTraversal: true);

  /// Fuer welchen Bildschirm [_sorgeFuerFokus] den Fokus schon gesetzt hat.
  String? _zuletztFokussiert;

  // ── Felder von home/navigation.dart

  /// In welche Richtung zuletzt gewechselt wurde. Steuert, von welcher Seite
  /// der neue Bildschirm hereinkommt.
  int _richtung = 1;

  // ── Felder von home/thema.dart

  /// Das Thema, VON dem gerade gewechselt wird, oder null.
  Thema? _vonThema;

  // In initState angelegt, NICHT faul: ein `late final` mit Initialisierer
  // entstuende sonst erst in dispose() — und wollte dort einen Ticker von
  // einem Baum, den es nicht mehr gibt.
  late final AnimationController _wechsel;

  Timer? _wanderTakt;

  String? _gemeldetesThema;

  /// Ob die naechste Themenaenderung aus einer Wahl in den Einstellungen
  /// kommt. Nur dann wird uebergeblendet; beim Start und nach dem Entsperren
  /// gilt das gespeicherte Thema sofort (siehe [_uebernimmEinstellungen]).
  bool _themaGewaehlt = false;

  int? _gemeldetesWandern;

  // ── Felder von home/zugriff.dart

  /// Welche Zeile im Zugriffs-Bildschirm gerade arbeitet.
  ///
  /// Ohne diese Anzeige sieht ein Antippen aus wie ein Antippen ins Leere —
  /// und genau so wurde es am 25.07.2026 gemeldet.
  String? laeuftZeile;

  // ── Felder von home/notfall.dart

  final codeCtl = TextEditingController();

  /// Zeichnet den Balken nach, solange eine Fernloeschung laeuft — einmal je
  /// Minute, in der letzten Minute jede Sekunde. Ohne Wecker stand "10 Min."
  /// bis zur Loeschung da.
  Timer? _fernAnzeigeTakt;

  // ── Felder von home/verschluesselung.dart

  /// Die Pruefnummer der offenen Unterhaltung. Wird beim Oeffnen des
  /// Verschluesselungs-Blatts geladen — sie zu berechnen kostet 5200 Runden
  /// SHA-512 und lohnt nicht auf Vorrat.
  SafetyNumber? pruefnummer;

  String? pruefnummerFehler;

  // ── Felder von home/unterhaltung.dart

  /// Die Bildlaufsteuerung der offenen Unterhaltung.
  final _chatScroll = ScrollController();

  int _scrollAnzahl = 0;

  /// Ob die Schreibzeile beim letzten Tastendruck mit "/" begann.
  bool _warBefehl = false;

  /// Welche der angehefteten Nachrichten die Leiste gerade zeigt.
  int _angeheftetStelle = 0;

  // ── Felder von home/nachricht.dart

  /// Wann eine eintreffende Nachricht sich zu entschluesseln begann.
  final Map<String, DateTime> _entschluesseltSeit = {};

  // ── Felder von home/anhaenge.dart

  Timer? _aufnahmeTakt;

  // ── Felder, die mehrere Teile benutzen

  String screen = 'onboard';

  String? chat;

  bool sheet = false, panic = false, wiped = false, copied = false;

  /// Was das letzte "Anfrage senden" bewirkt hat; null, solange es nichts zu
  /// sagen gibt. Bis 15.10.2026 ein bool, und "wahr" hiess immer "Anfrage
  /// gesendet" — siehe [Hinzugefuegt].
  Hinzugefuegt? reqErgebnis;

  /// Woran [_haltUnten] erkennt, dass sich etwas geaendert hat. Ohne dieses
  /// Gedaechtnis wuerde bei JEDEM Neubauen gescrollt — und neu gebaut wird
  /// auch beim Tippen, beim Eintreffen eines Lesehakens, beim Wechsel der
  /// Verbindungsanzeige.
  String? _scrollChat;

  /// Ob der Nutzer gerade selbst etwas abgeschickt hat.
  ///
  /// GEMESSEN, NICHT ERSCHLOSSEN. Erst stand hier "ist die letzte Nachricht
  /// von mir" — das faellt um, sobald das Gegenueber schnell antwortet: dann
  /// ist die letzte Nachricht die Antwort, und das eigene Senden zaehlte
  /// ploetzlich als fremdes Eintreffen. Beim Testen sprang die Zaehlung um
  /// zwei statt um eins, und daran war es zu sehen.
  bool _selbstGeschrieben = false;

  /// Die Sprache: gewaehlt (in den Einstellungen gespeichert) oder die des
  /// Systems. Bis 25.09.2026 stand hier fest 'en', und nichts davon ueberlebte
  /// einen Neustart — wer Deutsch wollte, stellte es jedes Mal neu ein.
  String lang =
      WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'de' ? 'de' : 'en';

  // ═════════════════════════════════════════════════════════════ Themen
  //
  // Siehe lib/themen.dart. Hier liegt nur, welches gerade gilt und wie weit
  // ein Wechsel ist.

  List<Thema> _themen = bauThemen();

  late Thema _thema = _themen.first;

  String? enroll;

  /// Was beim Sperren zuletzt schiefging, im Klartext fuer den Nutzer.
  String? lockFehler;

  /// Was bei der Wiederherstellung schiefging, im Klartext.
  String? restoreFehler;

  /// Wie der Stick angeschlossen ist. Einstecken ist der Standard: der Kontakt
  /// kann dabei nicht abreissen, und beim Anlegen sind zwei Beruehrungen
  /// noetig — bei NFC ist das die haeufigste Fehlerquelle.
  StickWeg stickWeg = StickWeg.usb;

  /// Woran gerade gearbeitet wird. Null heisst: nichts laeuft.
  String? stickSchritt;

  final draftCtl = TextEditingController();

  /// Worauf die naechste Nachricht antwortet, oder welche gerade bearbeitet
  /// wird. Hoechstens eines von beiden: eine Bearbeitung antwortet nicht neu.
  Message? _antwortZiel;

  Message? _bearbeitungsZiel;

  /// Zeigt die Chatliste das Archiv statt der gewoehnlichen Unterhaltungen?
  bool _zeigeArchiv = false;

  final suchCtl = TextEditingController();

  final addCtl = TextEditingController();

  /// Nur fuer den sichtbaren Fokusrahmen der beiden mehrzeiligen Felder.
  ///
  /// Beide liegen in einem Container, der den Rahmen zeichnet und vom Feld
  /// darin nichts weiss. Ohne diese Knoten sah man auf einem leeren Feld
  /// nicht, dass es am Zug ist — mit Tab-Bedienung ist das der Unterschied
  /// zwischen bedienbar und nicht.
  final _phraseFokus = FocusNode();

  final _addFokus = FocusNode();

  /// Seit wann aufgenommen wird, oder null.
  DateTime? _aufnahmeSeit;

  /// Ob die laufende Aufnahme als Einmal-Ansicht hinausgeht (Schalter "1×").
  bool _spracheEinmal = false;

  String _filter = 'alle';

  // setState IST @protected. Die Bildschirme und Bausteine stehen als
  // `extension on _HomeState` in home/*.dart (part); jeder Aufruf von dort
  // gaebe die Warnung invalid_use_of_protected_member, und die CI bricht bei
  // Warnungen ab. Dieser Override tut nichts anderes als State.setState.
  @override
  void setState(VoidCallback fn) => super.setState(fn);

  AppState get st => widget.state;

  @override
  void initState() {
    super.initState();
    // Der Kern verbindet nur nach, solange die App sichtbar ist. Im
    // Hintergrund weiterzuprobieren waere der schnellste Weg, den Akku zu
    // leeren; das gehoert an den Vordergrunddienst, den es noch nicht gibt.
    WidgetsBinding.instance.addObserver(this);
    _wechsel = AnimationController(vsync: this)
      ..addListener(_wechselTakt)
      ..addStatusListener((z) {
        if (z == AnimationStatus.completed && mounted) {
          setState(() => _vonThema = null);
          anzeigeThema.value = _thema;
        }
      });
    st.addListener(_aktualisiere);
    st.frageOhneBereinigung = _frageMetadaten;
    // Material You: die Akzentfarbe des Systems faerbt die Material-Themen.
    unawaited(SystemFarbe.akzent().then((farbe) {
      if (farbe == null || !mounted) return;
      setState(() {
        _themen = bauThemen(systemAkzent: Color(farbe));
        _thema = _themen.firstWhere((t) => t.id == _thema.id, orElse: () => _thema);
      });
      if (_vonThema == null) anzeigeThema.value = _thema;
    }));
    // Ob es einen Mikrofonknopf gibt, entscheidet die Plattform — einmal
    // gefragt, beim Start.
    unawaited(st.pruefeSprache());
    // Der Rahmen der beiden mehrzeiligen Felder haengt am Fokus, also muss ein
    // Fokuswechsel neu zeichnen lassen.
    //
    // NUR IM FENSTER, und das ist keine Vorsicht, sondern der Punkt: auf dem
    // Telefon tippt man IMMER ins Feld, um zu schreiben. Dort waere jeder
    // Fokuswechsel ein setState des ganzen _HomeState — Einbrennschutz-Transform
    // und kompletter Neubau — fuer eine Rahmenfarbe, die dort niemand bestellt
    // hat. Die Farbe selbst haengt an derselben Weiche (wiederherstellenScreen
    // und addScreen), damit Android Pixel fuer Pixel bleibt, wie es war.
    if (_imFenster) {
      _phraseFokus.addListener(_aktualisiere);
      _addFokus.addListener(_aktualisiere);
      FocusManager.instance.addListener(_fokusNachfassen);
    }
    _setzeMeldetexte();
    _starte();
  }

  /// Startet den Zustand und waehlt danach den ersten Bildschirm — beim
  /// Oeffnen und ueber "Erneut versuchen", wenn der Schluesselspeicher zu war
  /// (AppState.schluesselspeicherZu).
  void _starte() {
    st.boot().then((_) {
      if (!mounted) return;
      // Wer schon eine Identitaet hat, sieht das Onboarding nicht wieder.
      setState(() => screen = st.hatIdentitaet ? 'chats' : 'onboard');
    });
  }

  void _aktualisiere() {
    if (!mounted) return;
    // GERADE ZUGESPERRT ODER GELOESCHT: alles, was UEBER dem Bildschirm liegt,
    // muss mit. Der Sperrbildschirm ersetzt nur den Inhalt von Home — ein
    // offener Dialog, ein Blatt, das Einmal-Bild oder die Teile der zwoelf
    // Woerter lagen bis hierher als eigene Route DARUEBER und blieben
    // sichtbar und bedienbar.
    final gesperrtJetzt = st.gesperrt;
    final identitaetJetzt = st.hatIdentitaet;
    final gesperrtWorden = gesperrtJetzt && !_warGesperrt;
    final geloeschtWorden = st.bereit && !identitaetJetzt && _hatteIdentitaet;
    _warGesperrt = gesperrtJetzt;
    _hatteIdentitaet = identitaetJetzt;
    if (gesperrtWorden || geloeschtWorden) _raeumeOberflaecheAuf();
    if (geloeschtWorden) {
      // Filter und Suche der alten Identitaet gehoeren nicht zur neuen.
      _filter = 'alle';
      _zeigeArchiv = false;
    }
    // DIE IDENTITAET IST WEG — etwa durch eine Fernloeschung, die ablief,
    // waehrend die Chatliste offen war. Dann gehoert der Bildschirm zum
    // Anfang, nicht zu Unterhaltungen, die es nicht mehr gibt.
    if (st.bereit && !st.hatIdentitaet && !st.gesperrt &&
        const {'chats', 'chat', 'id', 'set'}.contains(screen)) {
      screen = 'onboard';
      chat = null;
    }
    _planeFernAnzeige();
    _uebernimmEinstellungen();
    setState(() {});
  }

  // ── Felder mit Geheimnissen: _raeumeOberflaecheAuf (gleich darunter) leert
  //    sie beim Sperren und Loeschen.

  final stickPinCtl = TextEditingController();

  final pwCtl = TextEditingController();

  final pwCtl2 = TextEditingController();

  final phraseCtl = TextEditingController();

  /// Schliesst alles, was ueber dem Bildschirm liegt, und vergisst, was
  /// eingetippt oder angezeigt war — beim Sperren und beim Loeschen.
  void _raeumeOberflaecheAuf() {
    try {
      Navigator.maybeOf(context)?.popUntil((r) => r.isFirst);
    } catch (_) {
      // Mitten in einem anderen Navigatorschritt: dann eben ein Bild spaeter.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.maybeOf(context)?.popUntil((r) => r.isFirst);
      });
    }
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    sheet = false;
    panic = false;
    enroll = null;
    stickSchritt = null;
    laeuftZeile = null;
    pruefnummer = null;
    pruefnummerFehler = null;
    _antwortZiel = null;
    _bearbeitungsZiel = null;
    suchCtl.clear();
    stickPinCtl.clear();
    pwCtl.clear();
    pwCtl2.clear();
    // DAS MIKROFON LAEUFT NICHT HINTER DER SPERRE WEITER.
    if (_aufnahmeSeit != null) unawaited(_verwirfAufnahme());
  }

  /// Reicht die uebersetzten Texte fuer Benachrichtigungen durch. Der Kern
  /// kennt die Sprache nicht und soll sie auch nicht kennen.
  void _setzeMeldetexte() {
    st.fernWarnText = t('wipeNotify');
    st.updateMeldeText = (v) => t('updateNotif').replaceFirst('{neu}', v);
    st.einNeuText = t('notifOne');
    st.empfangTitelText = t('bgNotifTitle');
    st.empfangLaeuftText = t('bgNotifText');
    // MIT der Zahl — hier stand '' als Ersatz, und die Meldung hiess
    // " new messages".
    st.mehrereNeuText = (n) => t('notifMany').replaceFirst('{n}', '$n');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState zustand) {
    // WICHTIG: `inactive` zaehlt NICHT als weggelegt.
    //
    // Android meldet `inactive`, sobald irgendetwas ueber der App liegt — der
    // Fingerabdruck-Dialog, die Freigabe fuer einen USB-Stick, ein
    // Anrufhinweis. Bei einer Sperrfrist von null wuerde die App sich dann
    // ausgerechnet waehrend der eigenen Anmeldung zusperren, und kein Faktor
    // liesse sich je einrichten.
    //
    // Wirklich weg ist sie erst bei `paused` (Startbildschirm, App-Uebersicht,
    // andere App) und `hidden`.
    switch (zustand) {
      case AppLifecycleState.resumed:
        st.vordergrund(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // EINE LAUFENDE AUFNAHME GEHT WEG. Sonst nahm das Mikrofon weiter auf,
        // waehrend die App laengst verdeckt war.
        if (_aufnahmeSeit != null) unawaited(_verwirfAufnahme());
        st.vordergrund(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _wechselTakt() {
    if (!mounted) return;
    // Die Schrift wechselt in der Mitte, wenn der Schleier am dichtesten ist.
    if (_wechsel.value >= 0.5 && !identical(anzeigeThema.value, _thema)) {
      anzeigeThema.value = _thema;
    }
    setState(() {});
  }

  /// Am Rechner und im Browser "Geraet" statt "Telefon" — siehe
  /// [geraetErsetzungen] in data.dart.
  String t(String k) => textFuer(lang, k);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _aufnahmeTakt?.cancel();
    _wanderTakt?.cancel();
    _wechsel.dispose();
    // OHNE `if (_imFenster)` und VOR `_tastenFokus.dispose()`: die Weiche haengt
    // an `defaultTargetPlatform`, und im Test setzt der Fenster-Fall sie zurueck,
    // BEVOR flutter_test den Baum abbaut — mit der Bedingung waere der Horcher
    // hier haengengeblieben und haette auf einen abgeraeumten State gezeigt.
    //
    // AUF ANDROID LAEUFT DIESE ZEILE ALSO INS LEERE, und das ist Absicht:
    // angemeldet wird der Horcher nur unter `if (_imFenster)` (initState,
    // home.dart). `removeListener` auf einen nicht angemeldeten Horcher
    // ist ein Nichts — `ChangeNotifier.removeListener` laeuft die Liste ab und
    // tut nichts, wenn er nicht drinsteht, ohne assert und ohne Wurf
    // (change_notifier.dart:339-363; `FocusManager` mischt ChangeNotifier ein
    // und ueberschreibt die Methode nicht, focus_manager.dart:1636. Nachgesehen
    // am 30.07.2026). Steht hier ohne Weiche, damit nicht bei jedem Gegenlesen
    // dieselbe Frage neu aufkommt.
    FocusManager.instance.removeListener(_fokusNachfassen);
    st.removeListener(_aktualisiere);
    if (st.frageOhneBereinigung == _frageMetadaten) st.frageOhneBereinigung = null;
    _chatScroll.dispose();
    _fernAnzeigeTakt?.cancel();
    draftCtl.dispose();
    suchCtl.dispose();
    addCtl.dispose();
    codeCtl.dispose();
    stickPinCtl.dispose();
    pwCtl.dispose();
    pwCtl2.dispose();
    phraseCtl.dispose();
    _phraseFokus.dispose();
    _addFokus.dispose();
    _tastenFokus.dispose();
    super.dispose();
  }

  // ---- build ----
  @override
  Widget build(BuildContext context) {
    // Bei gesperrter App KEINE Leiste. Sie tat zwar nichts, aber sie sah
    // bedienbar aus — und eine Oberflaeche, die auf Tippen nicht reagiert,
    // laesst den Nutzer an der App zweifeln statt an seinem Finger.
    //
    // Auch "noch nicht bereit" gehoert dazu: waehrend boot() laeuft, steht
    // hinter der Leiste noch nichts.
    final showNav = st.bereit && !st.gesperrt && reiter.contains(screen);

    // WER UNTEN EINE EIGENE LEISTE HAT, bringt seinen Abstand selbst mit —
    // die Reiterleiste und die Schreibzeile im Chat tun das, weil ihr
    // Hintergrund bis unter die Systemleiste durchlaufen soll. Alle anderen
    // Bildschirme bekommen ihn hier.
    //
    // OHNE DAS lag jeder unten angeschlagene Knopf IN den Systemtasten. Am
    // 26.07.2026 auf einem S10 gesehen und im Emulator nachgestellt: bei
    // 1080x2280 mit drei Tasten ragte "I WROTE THEM DOWN" 68 Pixel in die
    // Leiste. Ein Tipp darauf loeste HOME aus statt des Knopfes — die
    // Testautomatik ist genau daran aus der App geflogen, bevor ein Mensch es
    // gemeldet hat.
    //
    // Auf dem Emulator mit Wischgesten fiel es nicht auf: dort ist die Leiste
    // 72 statt 126 Pixel hoch, und der Knopf ragte nur 6 Pixel hinein.
    final eigeneLeiste = showNav || screen == 'chat';

    // ZURUECKWISCHEN GEHT ZURUECK, NICHT RAUS.
    //
    // Diese App wechselt den Bildschirm ueber eine Variable (`screen`), nicht
    // ueber den Navigator. Fuer Android heisst das: der Stapel ist leer, egal
    // wie tief man in der App steht — und die Zurueck-Geste beendet sie. Aus
    // einer Unterhaltung herauszuwischen schloss BitDM.
    //
    // `canPop: false` faengt die Geste ab, solange es hier drin noch etwas zu
    // schliessen gibt; erst auf der Chatliste (und im Onboarding) darf sie
    // durch. Die Ziele sind dieselben wie bei den ‹-Knoepfen — zwei Wege,
    // eine Ordnung.
    // Fuer den Zaehler: eine Nachricht in die gerade offene Unterhaltung gilt
    // sofort als gelesen (AppState.offeneUnterhaltung).
    st.offeneUnterhaltung = screen == 'chat' ? chat : null;

    // DIE ZWOELF WOERTER NACH DEM ANLEGEN: Screenshot-Schutz, solange sie
    // dastehen — gleich, was in den Einstellungen steht (die gelten fuer die
    // Unterhaltungen). Am Bildschirmwechsel gemessen und nicht an jedem Weg
    // dorthin: 'phrase' wird an mehreren Stellen direkt gesetzt.
    final phraseSichtbar = st.bereit && !st.gesperrt && screen == 'phrase';
    if (phraseSichtbar != _phraseGeschuetzt) {
      _phraseGeschuetzt = phraseSichtbar;
      unawaited(st.geheimnisSichtbar(phraseSichtbar));
    }

    final Widget geruest = Scaffold(
      backgroundColor: p.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            if (_amSchreibtisch)
              SafeArea(top: false, child: schreibtischGeruest())
            else
              _aufTelefonbreite(Column(
                children: [
                  Expanded(
                    child: SafeArea(
                      top: false,
                      bottom: !eigeneLeiste,
                      child: buildScreen(),
                    ),
                  ),
                  if (showNav) buildNav(),
                ],
              )),
            if (enroll != null) enrollModal(),
            if (sheet && screen == 'chat') encSheet(),
            if (panic && screen == 'set') panicModal(),
          ],
        ),
      ),
      // Der Sprungknopf war ein Entwicklerwerkzeug aus der Entwurfsphase: er
      // liess zwischen allen Bildschirmen springen, unabhaengig davon, ob der
      // Weg dorthin sinnvoll war. In einer ausgelieferten App ist er zweierlei
      // Fehler — er liegt ueber dem Inhalt, und er umgeht den Ablauf.
      //
      // kDebugMode wird beim Bauen einer Release-Fassung zu einer Konstanten
      // false, der ganze Zweig faellt also aus dem Programm heraus. Beim
      // Entwickeln bleibt er.
      floatingActionButton:
          (!kDebugMode || sheet || panic || enroll != null)
              ? null
              : FloatingActionButton.small(
                  backgroundColor: p.surf,
                  foregroundColor: p.accLight,
                  shape: const CircleBorder(),
                  onPressed: showDevJump,
                  child: const Text('≡', style: TextStyle(fontSize: 20, height: 1)),
                ),
    );

    // KEIN EINBRENNSCHUTZ IM FENSTER. Er ist fuer ein OLED-Telefon gebaut
    // (Begruendung ab Zeile 132) — an einem Schreibtischschirm gibt es den
    // Grund nicht, dafuer eine neue Nebenwirkung: alle 40 Sekunden wandert
    // jedes Ziel unter dem Mauszeiger um bis zu 2 px weg, und die neuen
    // Ueberfahr-Zustaende flackern dabei. Im Fenster faellt damit auch der
    // 40-Sekunden-Rebuild des ganzen Baums weg.
    return PopScope(
      // Der Schluessel ist fuer den Test da, und das ist kein Selbstzweck:
      // ueber den Typ ist dieses Widget nicht sicher zu finden (der
      // Typparameter wird abgeleitet, und das Geruest der App bringt eigene
      // PopScopes mit). Ohne ihn wuerde der Test irgendeines pruefen.
      key: const Key('zurueckWaechter'),
      canPop: _zurueckZiel() == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _gehZurueck();
      },
      child: _mitTasten(AnnotatedRegion<SystemUiOverlayStyle>(
        // Die Symbole der Statusleiste passend zum Thema — sonst stehen sie
        // auf einem dunklen Thema schwarz auf fast schwarz.
        value: _schriftThema.dunkel ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        // Der Stack bleibt, auch mit einem Kind: hier lag bis 24.10.2026 der
        // Chiffreschleier eines Themenwechsels (siehe [wechsleThema]), und
        // eine andere Baumform liesse Eingabefelder und Bildlauf ihren Stand
        // verlieren, sobald wieder etwas darueber liegt.
        child: Stack(fit: StackFit.expand, children: [
          _imFenster ? geruest : Einbrennschutz(child: geruest),
        ]),
      )),
    );
  }

  /// Faengt den Fokus wieder ein, wenn er seinen Knoten VERLIERT.
  ///
  /// [_sorgeFuerFokus] setzt ihn einmal je Bildschirm. Danach kann er ohne
  /// Bildschirmwechsel heimatlos werden, und es bleiben zwei Wege dorthin
  /// (der dritte, "der Teilbaum wird neu aufgebaut", ist mit der immer gleichen
  /// Baumform in [_mitTasten] weg — festgenagelt in fenster_abfolge_test.dart,
  /// "DIE BAUMFORM BLEIBT, WENN DER HAUPTKNOPF WEGFAELLT"):
  ///
  ///   * ein Bedienelement verschwindet — sein FocusNode wird abgeraeumt;
  ///   * sein `onTap` wird null, dann setzt [_Bedienbar] den
  ///     [FocusableActionDetector] auf `enabled: false`, und dessen FocusNode
  ///     gibt den Fokus ab, sobald `canRequestFocus` faellt
  ///     (focus_manager.dart:541-551, `unfocus` mit
  ///     `UnfocusDisposition.previouslyFocusedChild`; gibt es kein solches
  ///     Kind, landet der Fokus beim Scope).
  ///
  /// Danach liegt der Fokus beim FocusScope der Route, also UEBER [_mitTasten],
  /// und Escape kommt dort nicht mehr an — bis zum naechsten
  /// Bildschirmwechsel. Dieselbe Ursache wie beim Tastenfang selbst, nur
  /// spaeter.
  ///
  /// UEBER DEN FOCUSMANAGER UND NICHT UEBER JEDEN AUFBAU. Der Fokuswechsel ist
  /// ein Ereignis, das es schon gibt; eine Pruefung im build waere dieselbe
  /// Frage bei jeder Regung des AppState UND sie kaeme zu frueh: aufgegeben
  /// wird der Fokus erst, wenn der Teilbaum abgebaut ist, also nach dem build,
  /// das ihn abbaut.
  ///
  /// NUR IN DER EIGENEN ROUTE. Ein Dialog bringt seinen eigenen FocusScope mit
  /// ([_frageGeheimnis], der Entwicklersprung); dessen Fokus gehoert ihm, und
  /// ihn zurueckzuholen machte den Dialog unbedienbar. Verglichen wird deshalb
  /// mit genau dem Scope, in dem der Tastenfang haengt — haengt der gar nicht
  /// im Baum, ist er null, und dann ist hier nichts zu tun.
  /// UND ES BLEIBT BEI EINEM RUECKRUF JE FOKUSVERLUST — gemessen, nicht
  /// geschlossen. Diese Methode laeuft NICHT im build, sondern in einem
  /// Microtask (`FocusManager._markNeedsUpdate` →
  /// `scheduleMicrotask(applyFocusChangesIfNeeded)`, focus_manager.dart:1931;
  /// das `notifyListeners` darin nur bei echter Aenderung, Zeile 1999-2001).
  /// [_sorgeFuerFokus] haengt seine Arbeit aber an einen
  /// `addPostFrameCallback` — zwischen Microtask und Frame liegt also Platz fuer
  /// weitere Fokuswechsel. Am 30.07.2026 mit einem Zaehler im Rueckruf gezaehlt,
  /// im Fenster-Zweig auf 'restore':
  ///
  ///   * ein einzelner Fokusverlust (`unfocus()`, wie im ESCAPE-Fall):
  ///     1 Rueckruf.
  ///   * drei Fokusverluste OHNE Frame dazwischen (nur `tester.idle()`, damit
  ///     die Microtasks laufen): 0 Rueckrufe vor dem Frame, 3 danach — also
  ///     drei, die alle im SELBEN Frame laufen.
  ///   * dieselben drei Verluste MIT einem Frame dazwischen: 3, einer je Frame.
  ///
  /// Immer genau einer je Verlust, nie mehr. Der Grund steckt in der Reihenfolge
  /// hier: die Marke wird geloest und von [_sorgeFuerFokus] noch im SELBEN
  /// synchronen Aufruf wieder gesetzt, ein build kann dazwischen keinen zweiten
  /// Rueckruf anhaengen. Und laufen doch mehrere im selben Frame, tun sie
  /// dasselbe: `screen` kann sich innerhalb eines Frames nicht aendern, also
  /// greifen alle nach demselben Knoten, und `requestFocus` auf den schon
  /// vorgemerkten ist ein Nichts. Deshalb steht hier keine zweite Marke.
  void _fokusNachfassen() {
    final eigener = _tastenFokus.enclosingScope;
    if (eigener == null || FocusManager.instance.primaryFocus != eigener) return;
    // Die Marke loesen, sonst haelt [_sorgeFuerFokus] den Bildschirm fuer schon
    // versorgt. Eine Endlosschleife wird das nicht: der naechste Aufruf kommt
    // erst beim naechsten FOKUSWECHSEL, und nach dem gelungenen Griff ist
    // `primaryFocus` nicht mehr der Scope.
    _zuletztFokussiert = null;
    _sorgeFuerFokus();
  }

  /// Fragt, ob ein Bild oder Video hinausgehen soll, obwohl seine Metadaten
  /// (Ort, Kamera, Zeit) nicht entfernt werden konnten.
  Future<bool> _frageMetadaten(String grund) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('meta-frage'),
        title: Text(t('metaAskTitle')),
        content: Text(grund == 'metaZuGross' ? t('metaTooBig') : t('metaFailed'),
            style: mono(size: 12, color: p.muted, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('sendAnyway'))),
        ],
      ),
    );
    return ok == true;
  }
}
