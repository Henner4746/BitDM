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

class Home extends StatefulWidget {
  const Home({super.key, required this.state});

  final AppState state;

  @override
  State<Home> createState() => _HomeState();
}

/// Die drei Reiter der unteren Leiste, in ihrer Reihenfolge.
///
/// Steht hier und nicht nur in buildNav, weil das Wischen dieselbe
/// Reihenfolge braucht. Zwei Listen waeren zwei Gelegenheiten, sie
/// auseinanderlaufen zu lassen.
const List<String> reiter = ['chats', 'id', 'set'];

class _HomeState extends State<Home> with WidgetsBindingObserver, TickerProviderStateMixin {
  // setState IST @protected. Die Bildschirme und Bausteine stehen als
  // `extension on _HomeState` in home/*.dart (part); jeder Aufruf von dort
  // gaebe die Warnung invalid_use_of_protected_member, und die CI bricht bei
  // Warnungen ab. Dieser Override tut nichts anderes als State.setState.
  @override
  void setState(VoidCallback fn) => super.setState(fn);

  String screen = 'onboard';
  String? chat;
  bool sheet = false, panic = false, wiped = false, copied = false;
  /// Was das letzte "Anfrage senden" bewirkt hat; null, solange es nichts zu
  /// sagen gibt. Bis 15.10.2026 ein bool, und "wahr" hiess immer "Anfrage
  /// gesendet" — siehe [Hinzugefuegt].
  Hinzugefuegt? reqErgebnis;

  /// Die Bildlaufsteuerung der offenen Unterhaltung.
  final _chatScroll = ScrollController();

  /// Woran [_haltUnten] erkennt, dass sich etwas geaendert hat. Ohne dieses
  /// Gedaechtnis wuerde bei JEDEM Neubauen gescrollt — und neu gebaut wird
  /// auch beim Tippen, beim Eintreffen eines Lesehakens, beim Wechsel der
  /// Verbindungsanzeige.
  String? _scrollChat;
  int _scrollAnzahl = 0;

  /// Ob der Nutzer gerade selbst etwas abgeschickt hat.
  ///
  /// GEMESSEN, NICHT ERSCHLOSSEN. Erst stand hier "ist die letzte Nachricht
  /// von mir" — das faellt um, sobald das Gegenueber schnell antwortet: dann
  /// ist die letzte Nachricht die Antwort, und das eigene Senden zaehlte
  /// ploetzlich als fremdes Eintreffen. Beim Testen sprang die Zaehlung um
  /// zwei statt um eins, und daran war es zu sehen.
  bool _selbstGeschrieben = false;

  AppState get st => widget.state;

  /// Die Pruefnummer der offenen Unterhaltung. Wird beim Oeffnen des
  /// Verschluesselungs-Blatts geladen — sie zu berechnen kostet 5200 Runden
  /// SHA-512 und lohnt nicht auf Vorrat.
  SafetyNumber? pruefnummer;
  String? pruefnummerFehler;

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

  /// Ob der Schutz fuer den Woerter-Bildschirm gerade angemeldet ist.
  bool _phraseGeschuetzt = false;

  /// Was beim letzten Horchen galt — um den WECHSEL zu erkennen, nicht den
  /// Zustand.
  bool _warGesperrt = false;
  bool _hatteIdentitaet = false;

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

  /// Das Thema, VON dem gerade gewechselt wird, oder null.
  Thema? _vonThema;
  // In initState angelegt, NICHT faul: ein `late final` mit Initialisierer
  // entstuende sonst erst in dispose() — und wollte dort einen Ticker von
  // einem Baum, den es nicht mehr gibt.
  late final AnimationController _wechsel;
  Timer? _wanderTakt;
  String? _gemeldetesThema;
  int? _gemeldetesWandern;

  /// Wann eine eintreffende Nachricht sich zu entschluesseln begann.
  final Map<String, DateTime> _entschluesseltSeit = {};

  void _wechselTakt() {
    if (!mounted) return;
    // Die Schrift wechselt in der Mitte, wenn der Schleier am dichtesten ist.
    if (_wechsel.value >= 0.5 && !identical(anzeigeThema.value, _thema)) {
      anzeigeThema.value = _thema;
    }
    setState(() {});
  }

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

  /// Welche Zeile im Zugriffs-Bildschirm gerade arbeitet.
  ///
  /// Ohne diese Anzeige sieht ein Antippen aus wie ein Antippen ins Leere —
  /// und genau so wurde es am 25.07.2026 gemeldet.
  String? laeuftZeile;

  final draftCtl = TextEditingController();

  /// Worauf die naechste Nachricht antwortet, oder welche gerade bearbeitet
  /// wird. Hoechstens eines von beiden: eine Bearbeitung antwortet nicht neu.
  Message? _antwortZiel;
  Message? _bearbeitungsZiel;

  /// Zeigt die Chatliste das Archiv statt der gewoehnlichen Unterhaltungen?
  bool _zeigeArchiv = false;
  final suchCtl = TextEditingController();
  final addCtl = TextEditingController();
  final codeCtl = TextEditingController();
  final stickPinCtl = TextEditingController();
  final pwCtl = TextEditingController();
  final pwCtl2 = TextEditingController();
  final phraseCtl = TextEditingController();

  /// Nur fuer den sichtbaren Fokusrahmen der beiden mehrzeiligen Felder.
  ///
  /// Beide liegen in einem Container, der den Rahmen zeichnet und vom Feld
  /// darin nichts weiss. Ohne diese Knoten sah man auf einem leeren Feld
  /// nicht, dass es am Zug ist — mit Tab-Bedienung ist das der Unterschied
  /// zwischen bedienbar und nicht.
  final _phraseFokus = FocusNode();
  final _addFokus = FocusNode();

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
    // main.dart:425-429). `removeListener` auf einen nicht angemeldeten Horcher
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

  /// Die Frist als Text — jetzt aus der ECHTEN Einstellung, nicht aus einer
  /// Anzeigevariablen.
  String ephLabel() => fristText(st.einstellungen.messageLifetime);

  String nowHm() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  // ---- actions ----
  void go(String s) {
    // Die Richtung mitfuehren, damit ein Tippen auf die Leiste genauso
    // aussieht wie ein Wischen dorthin. Sonst kaeme der Bildschirm beim Tippen
    // immer von rechts, auch wenn man nach links gegangen ist.
    // BEIM VERLASSEN DER UNTERHALTUNG DAS GEDAECHTNIS LOESCHEN.
    //
    // Sonst gilt das erneute Oeffnen DERSELBEN Unterhaltung nicht als Wechsel,
    // und sie geht dort auf, wo man sie verlassen hat — beim Testen war das
    // ganz oben, bei der aeltesten Nachricht.
    if (screen == 'chat' && s != 'chat') _scrollChat = null;
    final von = reiter.indexOf(screen);
    final nach = reiter.indexOf(s);
    if (von >= 0 && nach >= 0 && von != nach) _richtung = nach > von ? 1 : -1;
    setState(() { screen = s; sheet = false; panic = false; });
    // JEDES MAL neu fragen, nicht einmal beim Start. Bluetooth laesst sich
    // ausserhalb der App umschalten; eine gemerkte Antwort waere spaetestens
    // beim zweiten Hinsehen falsch, und der Nutzer saehe "Bluetooth ist aus",
    // waehrend es laengst an ist.
    if (s == 'set') unawaited(st.pruefeFunk());
  }

  /// Seit wann aufgenommen wird, oder null.
  DateTime? _aufnahmeSeit;
  Timer? _aufnahmeTakt;

  /// Ob die laufende Aufnahme als Einmal-Ansicht hinausgeht (Schalter "1×").
  bool _spracheEinmal = false;

  /// Ob die Schreibzeile beim letzten Tastendruck mit "/" begann.
  bool _warBefehl = false;

  /// Welche der angehefteten Nachrichten die Leiste gerade zeigt.
  int _angeheftetStelle = 0;

  String _filter = 'alle';

  /// Zeichnet den Balken nach, solange eine Fernloeschung laeuft — einmal je
  /// Minute, in der letzten Minute jede Sekunde. Ohne Wecker stand "10 Min."
  /// bis zur Loeschung da.
  Timer? _fernAnzeigeTakt;

  String _uhr(int minuten) =>
      '${(minuten ~/ 60).toString().padLeft(2, '0')}:${(minuten % 60).toString().padLeft(2, '0')}';

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
        child: Stack(fit: StackFit.expand, children: [
          _imFenster ? geruest : Einbrennschutz(child: geruest),
          // IMMER ALS ZWEITES KIND, nur eben leer: kaeme der Stack erst mit
          // dem Schleier dazu, baute Flutter den ganzen Baum darunter neu auf,
          // und Eingabefelder und Bildlauf verloeren ihren Stand.
          if (_vonThema != null)
            ChiffreSchleier(
              fortschritt: _wechsel.value,
              farbe: p.accLight,
              hauch: p.bg,
              chiffre: _thema.chiffre,
              titel: _thema.nameIn(lang).toUpperCase(),
              schrift: _thema.monoSchrift,
            ),
        ]),
      )),
    );
  }

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

  /// Wohin die Zurueck-Geste als Naechstes fuehrt — oder null, wenn es hier
  /// nichts mehr zu schliessen gibt und die App sich beenden darf.
  ///
  /// Getrennt von [_gehZurueck], weil `PopScope.canPop` die Antwort BEIM BAUEN
  /// braucht, das Handeln aber erst danach kommt. Eine Methode, die beides
  /// taete, muesste beim Bauen schon etwas veraendern.
  ///
  /// Die Rueckgabe ist entweder ein Bildschirmcode oder eine der '#'-Marken
  /// fuer die Ueberlagerungen — die haben keinen eigenen Bildschirm, muessen
  /// aber zuerst weg.
  String? _zurueckZiel() {
    // Ueberlagerungen zuerst, in der Reihenfolge, in der sie uebereinander
    // liegen: was oben liegt, geht zuerst.
    if (enroll != null) return '#enroll';
    if (panic && screen == 'set') return '#panic';
    if (sheet && screen == 'chat') return '#sheet';

    // Gesperrt: die Geste darf die Sperre nicht umgehen. Sie beendet die App,
    // und das ist richtig so — die Identitaet bleibt verschlossen.
    if (st.gesperrt) return null;

    return switch (screen) {
      // Unterbildschirme, zurueck zu ihrem Ausgangspunkt. Dieselben Ziele wie
      // die ‹-Knoepfe in den jeweiligen Kopfzeilen.
      'chat' || 'add' => 'chats',
      'test' || 'nahHilfe' => 'set',
      'secure' => 'id',
      'restore' => 'onboard',

      // Die Reiter: zurueck heisst zum ersten Reiter, wie ueberall unter
      // Android.
      'id' || 'set' => 'chats',

      // 'chats' ist die Wurzel, 'onboard' der Anfang — dort beendet die Geste
      // die App. 'creating' und 'phrase' ebenfalls, und zwar mit Absicht: die
      // Wiederherstellungswoerter stehen nur einmal da. Ein Zurueck mitten
      // hinein waere ein Weg, sie zu verlieren.
      _ => null,
    };
  }

  void _gehZurueck() {
    final ziel = _zurueckZiel();
    if (ziel == null) return;
    switch (ziel) {
      case '#enroll':
        setState(() { enroll = null; stickSchritt = null; });
      case '#panic':
        setState(() => panic = false);
      case '#sheet':
        setState(() => sheet = false);
      case 'onboard':
        setState(() { screen = 'onboard'; restoreFehler = null; });
      default:
        go(ziel);
    }
  }

  /// In welche Richtung zuletzt gewechselt wurde. Steuert, von welcher Seite
  /// der neue Bildschirm hereinkommt.
  int _richtung = 1;

  /// Wechselt zum Nachbarreiter, wenn es einen gibt.
  ///
  /// NUR VON DEN DREI REITERN AUS. Aus einem Chat oder dem Hinzufuegen-
  /// Bildschirm heraus zu wischen waere ein Weg, den niemand sucht und den
  /// jeder versehentlich findet — dort wischt man, um zu scrollen.
  void _wischeZuReiter(int schritte) {
    final jetzt = reiter.indexOf(screen);
    if (jetzt < 0) return;
    final ziel = jetzt + schritte;
    if (ziel < 0 || ziel >= reiter.length) return;
    setState(() {
      _richtung = schritte;
      screen = reiter[ziel];
      sheet = false;
      panic = false;
    });
  }

  Widget buildScreen() {
    if (!st.bereit) {
      return st.schluesselspeicherZu
          ? schluesselspeicherScreen()
          : const SizedBox.shrink();
    }
    // Die Sperre kommt VOR allem anderen. Es gibt eine Identitaet, der
    // gesicherte Bereich des Geraets ruecke sie nur noch nicht heraus.
    if (st.gesperrt) return gesperrtScreen();

    final inhalt = switch (screen) {
      'creating' => arbeitetScreen(),
      'phrase' => phraseScreen(),
      'secure' => secureScreen(),
      'id' => idScreen(),
      'add' => addScreen(),
      'restore' => wiederherstellenScreen(),
      'test' => testScreen(),
      'nahHilfe' => nahHilfeScreen(),
      'chats' => chatsScreen(),
      'chat' => chatScreen(),
      'set' => settingsScreen(),
      _ => onboardScreen(),
    };

    // Nur auf den drei Reitern gewischt und ueberblendet. Anderswo waere
    // beides falsch: der Chat scrollt, und ein Wechsel dorthin ist kein
    // Nachbarschaftswechsel, sondern ein Sprung.
    if (!reiter.contains(screen)) return inhalt;

    return GestureDetector(
      // Nur waagerecht. Ohne diese Beschraenkung faengt die Geste jedes
      // Scrollen ab.
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        // Unter 200 Pixeln je Sekunde ist es kein Wischen, sondern ein
        // verrutschter Finger.
        if (v < -200) {
          _wischeZuReiter(1);
        } else if (v > 200) {
          _wischeZuReiter(-1);
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (kind, animation) {
          // Der neue Bildschirm kommt von der Seite herein, in die gewischt
          // wurde. Kaeme er immer von rechts, fuehlte sich das
          // Zurueckwischen falsch an — man sieht die Bewegung und erwartet
          // sie in der eigenen Richtung.
          final hinein = Tween<Offset>(
            begin: Offset(0.06 * _richtung, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: hinein, child: kind),
          );
        },
        // Der Schluessel sagt dem Wechsler, DASS sich etwas geaendert hat.
        // Ohne ihn haelt er zwei verschiedene Bildschirme fuer denselben und
        // blendet nichts ueber.
        child: KeyedSubtree(key: ValueKey(screen), child: inhalt),
      ),
    );
  }

  /// Die Zeilen samt Fehlerkasten.
  ///
  /// DER KASTEN IST DER PUNKT: bis zum 25.07.2026 wurden Fehler beim
  /// Einrichten zwar gesetzt, aber auf diesem Bildschirm nie angezeigt. Wer
  /// tippte, sah nichts — weder Dialog noch Grund.
  List<Widget> zugriffsBlock({required bool statusMode}) => [
        for (final k in zugriffsZeilen.where(_faktorGehtHier)) ...[
          methodRow(k, statusMode: statusMode),
          const SizedBox(height: 3),
        ],
        if (lockFehler != null) ...[
          const SizedBox(height: 6),
          _hinweisKasten(lockFehler!),
        ],
      ];

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

  // ---- NAV ----
  Widget buildNav() {
    final active = screen == 'chat' ? 'chats' : screen;
    final items = [
      ['chats', t('navChats')],
      ['id', t('navId')],
      ['set', t('navSet')],
    ];
    return Container(
      decoration: BoxDecoration(color: p.navbg, border: Border(top: BorderSide(color: p.lineSoft))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          for (final it in items)
            Expanded(
              child: GestureDetector(
                onTap: () => go(it[0]),
                child: Container(
                  padding: const EdgeInsets.only(top: 11, bottom: 15),
                  // Der Balken und die Schriftfarbe wandern mit. Ein Sprung
                  // sagt "es ist etwas anderes", eine Bewegung sagt "du bist
                  // dorthin gegangen" — und genau das ist beim Wischen die
                  // Frage.
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: active == it[0] ? p.accent : Colors.transparent, width: 2))),
                  alignment: Alignment.center,
                  child: AnimatedDefaultTextStyle(
                    duration: Bewegung.klein,
                    curve: Curves.easeOut,
                    style: mono(size: 10.5, weight: FontWeight.w500, color: active == it[0] ? p.ink : p.dim, spacing: 1.2),
                    child: Text(it[1].toUpperCase()),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  // ---- DEV JUMP ----
  void showDevJump() {
    final labels = jumpLabels[lang]!;
    const codes = ['onboard', 'secure', 'id', 'add', 'chats', 'chat', 'set'];
    showModalBottomSheet(
      context: context,
      backgroundColor: p.surf,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SCREENS · DEV JUMP', style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1.6)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (int i = 0; i < codes.length; i++)
              GestureDetector(
                onTap: () { Navigator.pop(ctx); setState(() { screen = codes[i]; chat ??= c1; sheet = false; panic = false; }); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: screen == codes[i] ? p.accent : p.line)),
                  child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: screen == codes[i] ? p.accLight : p.muted)),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
