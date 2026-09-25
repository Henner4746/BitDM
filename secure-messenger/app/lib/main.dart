import 'dart:async';
// Nur fuer File in der Weiche unten. dart:io uebersetzt fuer Web mit — die
// Stellen, die dort nicht gehen, werfen erst beim Aufruf (io_patch.dart).
import 'dart:io' show File;

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'core/messenger_core.dart';
import 'core/nah/funk.dart';
import 'core/real_messenger_core.dart';
import 'core/app_lock.dart';
import 'core/fido/client_pin.dart';
import 'core/fido/ctap.dart';
import 'core/fido/stick_zugang.dart';
import 'core/lock/hardware_key_factor.dart';
import 'core/lock/unlock_factor.dart';
import 'core/lock/geraete_fach.dart';
import 'core/lock/key_vault.dart';
import 'core/lock/vault_store.dart';
import 'core/secret_store.dart';
import 'core/sprache.dart';
import 'core/benachrichtigungen.dart';
import 'bewegung.dart';
import 'masse.dart';
import 'core/crypto/wordlist_english.dart';
import 'core/crypto/address.dart';
import 'core/empfang.dart';
import 'core/fenster.dart';
import 'core/push.dart';
import 'core/qr_bild.dart';
import 'core/verbindungstest.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';
import 'formatierung.dart';
import 'core/crypto/teilgeheimnis.dart';
import 'schluesselbild.dart';
import 'themen.dart';
import 'painters.dart';
import 'fido_probe_screen.dart';
import 'qr_scan_screen.dart';

/// Wohin sich die App verbindet.
///
/// Ueberschreibbar beim Bauen:
///   flutter build apk --dart-define=BITDM_RELAY=https://relay.example.org
///
/// Der Relay darf NIE hinter einem Proxy wie Cloudflare stehen — der saehe
/// sonst zu jeder Verbindung, wer wann mit wem spricht. Genau die Angabe, die
/// diese App vermeiden soll.
const String relayBasis = String.fromEnvironment(
  'BITDM_RELAY',
  defaultValue: 'https://relay.bitdm.net',
);

/// Wo die Anhaenge liegen, wenn es nicht aus dem Relay folgt.
///
/// Leer heisst: aus dem Relay ableiten (relay.X -> dateien.X), wie in jeder
/// Freigabe. Gebraucht wird es fuer den Emulatorlauf gegen den eigenen
/// Rechner: dort laufen Relay (8080) und Lager (8099) unter derselben Adresse
/// auf zwei Ports, und aus 10.0.2.2:8080 laesst sich 8099 nicht erraten.
///   flutter build apk --dart-define=BITDM_RELAY=http://10.0.2.2:8080
///                     --dart-define=BITDM_LAGER=http://10.0.2.2:8099
const String lagerBasis = String.fromEnvironment('BITDM_LAGER');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ein Verzeichnis, das dem Betriebssystem gehoert und nicht in Sicherungen
  // oder in den Dateimanager wandert.
  //
  // IM BROWSER GIBT ES DAS NICHT, und der Versuch war bis zum 30.07.2026 der
  // Grund, warum die Web-Fassung nur eine weisse Seite war. path_provider hat
  // keine Web-Umsetzung — path_provider_web steht nicht in pubspec.lock —, und
  // in Chrome kam an dieser Zeile wortwoertlich:
  //   MissingPluginException(No implementation found for method
  //   getApplicationSupportDirectory on channel plugins.flutter.io/path_provider)
  // Gemessen war zu dem Zeitpunkt: <flutter-view> stand da, aber 0 <canvas>,
  // kein <flt-scene-host>, `indexedDB.databases()` leer und sqlite3mc.wasm nie
  // angefragt — main() starb vor dem ersten Bildaufbau.
  //
  // Der leere Weg ist im Browser kein Notbehelf, sondern das Richtige: der
  // Datenbankpfad ist dort nur ein NAME im virtuellen Dateisystem von
  // package:sqlite3 (siehe Kopf von core/store/sqlite_zugang_web.dart — das
  // VFS liegt in IndexedDB, nicht auf einer Platte).
  final String ablageWeg =
      kIsWeb ? '' : (await getApplicationSupportDirectory()).path;

  // Solange kein Faktor eingerichtet ist, liegt die Entropie im
  // Schluesselspeicher des Geraets und die App oeffnet ohne Rueckfrage. Mit
  // dem ersten Faktor wandert sie in ein Schluesselfach und ist ohne ihn nicht
  // mehr zu haben — auch nicht mit Root, auch nicht mit der Datei in der Hand.
  final tresor = VaultSecretStore(
    // File() direkt und NICHT vaultDateiIn() im Browser: das setzt den Pfad mit
    // `Platform.pathSeparator` zusammen (vault_store.dart:301), und der ist auf
    // Web ein UnsupportedError("Platform._pathSeparator") — nachgelesen am
    // 30.07.2026 in dart-sdk/lib/_internal/js_runtime/lib/io_patch.dart:242.
    // Der reine Name wirft nicht; erst LESEN oder SCHREIBEN wuerde es (dieselbe
    // Datei, Zeile 115: File._exists). Der Browser kommt also so weit wie ohne
    // Fachdatei, nicht weiter.
    datei: kIsWeb ? File(vaultDateiname) : vaultDateiIn(ablageWeg),
    basis: DeviceSecretStore(),
    jetzt: () => DateTime.now().millisecondsSinceEpoch,
  );

  final core = RealMessengerCore(
    secretStore: tresor,
    databasePath: kIsWeb ? 'bitdm.db' : '$ablageWeg/bitdm.db',
    relayUri: Uri.parse(relayBasis),
    lagerUri: lagerBasis.isEmpty ? null : Uri.parse(lagerBasis),
  );

  // Benachrichtigungen vorbereiten. Die ERLAUBNIS wird bewusst nicht hier
  // abgefragt: eine App, die vor dem ersten Bildschirm danach fragt, bekommt
  // meistens ein Nein. Gefragt wird, wenn die erste Unterhaltung zustande
  // kommt — dann ist klar, wofuer.
  await Benachrichtigungen.instanz.starte();

  final zustand = AppState(
    core,
    tresor: tresor,
    stickZugang: (weg) => stickOeffner(weg)(),
    // Die Fachschluessel liegen neben der Fachdatei, verschluesselt mit
    // einem Schluessel aus dem gesicherten Bereich des Geraets.
    //
    // Im Browser bleibt der Weg leer und dieser Rueckruf ungenutzt: er gilt nur
    // fuer Geraetesperre und Biometrie, und [_faktorGehtHier] laesst dort nur
    // 'pw' durch — beide Faktoren sind an [_nurAufAndroid] gebunden.
    ablagen: (art) => GeraeteFach(
      art == UnlockFactorKind.deviceCredential
          ? GeraeteArt.geraetesperre
          : GeraeteArt.biometrie,
      verzeichnis: ablageWeg,
    ),
  )
    ..empfangsDienst = EmpfangsDienst()
    // Die Bluetooth-Strecke. Hier angehaengt und nicht im Konstruktor
    // verlangt, weil sie in Tests fehlt: `flutter test` hat keine
    // Plattformkanaele, und ein Pflichtfeld haette jeden Zustandstest an
    // Bluetooth gebunden.
    //
    // IM BROWSER GAR NICHT: `horcheAuf()` legt sich auf den EventChannel
    // bitdm/nahfunk_ereignisse, und den gibt es dort nicht. Gemessen am
    // 30.07.2026 in Chrome, wortwoertlich in der Konsole bei jedem Start:
    // "MissingPluginException(No implementation found for method listen on
    // channel bitdm/nahfunk_ereignisse)". Toedlich war das nicht — der Wurf
    // kommt aus einem unbeobachteten Future und die App baute trotzdem auf —,
    // aber nachbaubar ist Nahfunk im Browser eben auch nicht: Web Bluetooth
    // kennt kein Werben und kein Lauschen. `funk` bleibt also null, und alle
    // Aufrufer pruefen darauf (app_state.dart:1129, 1145, 1169).
    ..funk = kIsWeb ? null : (Nahfunk()..horcheAuf());

  // Die Rueckrufe des Verteilers MUESSEN bei jedem Start stehen, nicht erst
  // wenn der Nutzer etwas einstellt: ein Anstoss kann kommen, bevor er die App
  // ueberhaupt angefasst hat.
  zustand.push = PushAnbindung(
    beiEndpunkt: (e) => unawaited(zustand.nimmPushEndpunkt(e)),
    beiAnstoss: () => unawaited(zustand.beiAnstoss()),
    beiAbmeldung: () => unawaited(zustand.setzeEmpfangsTakt(EmpfangsTakt.aus)),
  );
  if (zustand.empfangsTakt.angestossen) {
    unawaited(zustand.push!.starte());
  }

  runApp(BitApp(state: zustand));
}

class BitApp extends StatelessWidget {
  const BitApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Thema>(
      valueListenable: anzeigeThema,
      builder: (_, thema, _) => MaterialApp(
        title: 'BitDM',
        debugShowCheckedModeBanner: false,
        theme: bitThema(thema.pal,
            dunkel: thema.dunkel, mono: thema.monoSchrift, text: thema.textSchrift),
        home: Home(state: state),
      ),
    );
  }
}

/// Das Thema fuer Flutters eigene Teile — Home schreibt, [BitApp] liest.
///
/// Das Thema muss UEBER dem Navigator haengen: Dialoge und Blaetter sind
/// eigene Routen, und `showDialog(context: context)` aus Home heraus sieht nur
/// die Themen oberhalb von Home.
final ValueNotifier<Thema> anzeigeThema = ValueNotifier(bauThemen().first);

/// Das Thema fuer alles, was Flutter selbst zeichnet: Dialoge, Blaetter,
/// Textknoepfe, Eingabefelder, Kaestchen.
///
/// BIS 25.09.2026 GAB ES KEINES. Die App zeichnet ihre Bildschirme selbst
/// und merkte es deshalb nicht — aber jeder AlertDialog kam in Roboto mit
/// Material-Lila daher, mitten in einer Monoschrift-Oberflaeche (im
/// Emulatorlauf an "Neue Gruppe" aufgefallen).
ThemeData bitThema(Pal p,
    {bool dunkel = true, String? mono = 'Chivo Mono', String? text}) {
  TextStyle m(double groesse, {FontWeight dicke = FontWeight.w400, Color? farbe, double? abstand}) =>
      TextStyle(
        fontFamily: mono,
        fontVariations: [FontVariation('wght', dicke.value.toDouble())],
        fontSize: groesse,
        fontWeight: dicke,
        color: farbe,
        letterSpacing: abstand,
      );
  final schema = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: dunkel ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: p.accLight,
    onPrimary: p.onAcc,
    surface: p.surf,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    outline: p.line,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    colorScheme: schema,
    // fontFamily NUR, WENN DAS THEMA ES WILL: es findet sich in jedem Text
    // ohne eigene Schrift wieder, auch im Nachrichtentext der Blasen. Der ist
    // normalerweise in der Schrift des Systems gesetzt, weil sie sich in
    // Saetzen besser liest — nur die Terminal-Themen setzen ihn mono.
    fontFamily: text,
    scaffoldBackgroundColor: p.bg,
    dialogTheme: DialogThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
      titleTextStyle: m(15, dicke: FontWeight.w600, farbe: p.ink),
      contentTextStyle: m(13, farbe: p.muted),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accLight,
        textStyle: m(12, dicke: FontWeight.w600, abstand: 0.8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      // Derselbe Griff wie am eigenen Blatt ([sheetCard]): 36 x 3 in p.line.
      showDragHandle: true,
      dragHandleColor: p.line,
      dragHandleSize: const Size(36, 3),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: m(13, farbe: p.dim),
      labelStyle: m(13, farbe: p.muted),
      counterStyle: m(10, farbe: p.dim),
      // KEIN enabledBorder/focusedBorder: die schlagen ein `border:
      // InputBorder.none` am Feld und zogen eine Linie in die Schreibzeile.
      // Die Farben der Unterstreichung im Dialog kommen aus dem Schema.
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accLight,
      selectionColor: p.accent.withValues(alpha: 0.35),
      selectionHandleColor: p.accLight,
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: p.muted, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      fillColor: WidgetStateProperty.resolveWith(
          (z) => z.contains(WidgetState.selected) ? p.accLight : Colors.transparent),
      checkColor: WidgetStatePropertyAll(p.onAcc),
    ),
    // "Spaeter senden" fragt Tag und Uhrzeit mit Flutters eigenen Waehlern —
    // ohne diese beiden Eintraege kamen sie hell und in Roboto.
    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: p.surf,
      headerForegroundColor: p.ink,
      headerHeadlineStyle: m(26, dicke: FontWeight.w500, farbe: p.ink),
      headerHelpStyle: m(11, dicke: FontWeight.w600, farbe: p.dim, abstand: 1.2),
      weekdayStyle: m(12, farbe: p.dim),
      dayStyle: m(13),
      yearStyle: m(13),
      dividerColor: p.line,
      todayBorder: BorderSide(color: p.accLight),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
      cancelButtonStyle: TextButton.styleFrom(foregroundColor: p.muted),
      confirmButtonStyle: TextButton.styleFrom(foregroundColor: p.accLight),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: p.surf,
      helpTextStyle: m(11, dicke: FontWeight.w600, farbe: p.dim, abstand: 1.2),
      hourMinuteColor: p.surf2,
      hourMinuteTextColor: p.ink,
      hourMinuteTextStyle: m(40, dicke: FontWeight.w500),
      dayPeriodTextStyle: m(12, dicke: FontWeight.w600),
      dayPeriodBorderSide: BorderSide(color: p.line),
      dialBackgroundColor: p.surf2,
      dialTextStyle: m(13),
      entryModeIconColor: p.muted,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
      cancelButtonStyle: TextButton.styleFrom(foregroundColor: p.muted),
      confirmButtonStyle: TextButton.styleFrom(foregroundColor: p.accLight),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surf2,
      contentTextStyle: m(12.5, farbe: p.ink),
    ),
  );
}


/// Verschiebt den Inhalt langsam um wenige Pixel — gegen Einbrennen auf OLED.
///
/// WOGEGEN GENAU
///
/// Auf einem OLED altert jedes Leuchtelement einzeln. Was tagelang an
/// derselben Stelle in derselben Farbe steht, bleibt als Schatten sichtbar,
/// auch wenn laengst etwas anderes dort ist. BitDM hat davon mehr als die
/// meisten Apps: die Reiterleiste steht immer unten, die Kopfzeile immer oben,
/// und der QR-Bildschirm wird bewusst liegengelassen, waehrend jemand ihn
/// abscannt.
///
/// ZWEI PIXEL GENUEGEN, und das ist der ganze Trick: die Alterung verteilt
/// sich auf mehrere Elemente, sobald das Bild nicht exakt stehenbleibt. Mehr
/// waere sichtbar und damit stoerend — hier soll niemand etwas bemerken.
///
/// KEIN DAUERLAUF. Es waere naheliegend, das zu animieren; das hiesse aber,
/// die Bildwiederholung nie zur Ruhe kommen zu lassen und dafuer Akku zu
/// verbrennen. Stattdessen ein Schritt alle 40 Sekunden — fuer die Alterung
/// ist das schnell genug, fuer den Akku unsichtbar.
///
/// Die Schrittfolge ist absichtlich KEIN Kreis mit gerader Laenge: sechs
/// Stellungen, deren Summe null ist, aber deren Reihenfolge das Bild nicht in
/// zwei Haelften teilt. Ein Hin und Her zwischen zwei Punkten waere nur die
/// halbe Wirkung.
class Einbrennschutz extends StatefulWidget {
  const Einbrennschutz({super.key, required this.child});

  final Widget child;

  @override
  State<Einbrennschutz> createState() => _EinbrennschutzState();
}

class _EinbrennschutzState extends State<Einbrennschutz> {
  static const _stellungen = <Offset>[
    Offset(0, 0),
    Offset(1, -1),
    Offset(2, 0),
    Offset(1, 1),
    Offset(-1, 1),
    Offset(-1, -1),
  ];

  int _wo = 0;
  Timer? _takt;

  @override
  void initState() {
    super.initState();
    _takt = Timer.periodic(const Duration(seconds: 40), (_) {
      if (!mounted) return;
      setState(() => _wo = (_wo + 1) % _stellungen.length);
    });
  }

  @override
  void dispose() {
    _takt?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Transform.translate UND NICHT Padding: das hier verschiebt beim Zeichnen
    // und loest kein neues Layout aus. Ein Padding, das sich alle 40 Sekunden
    // aendert, liesse den ganzen Baum neu rechnen — fuer zwei Pixel.
    return Transform.translate(
      offset: _stellungen[_wo],
      child: widget.child,
    );
  }
}

/// Was Leertaste und Eingabetaste auf einem FOKUSSIERTEN Bedienelement
/// ausloesen sollen.
///
/// UEBER DIE INTENTS UND NICHT UEBER TASTEN. Die Zuordnung Taste → Absicht
/// haengt schon in `WidgetsApp` ueber der ganzen App; hier wird nur gesagt, was
/// die Absicht bewirkt. Wer stattdessen selbst auf die Eingabetaste hoert,
/// nimmt sie dem fokussierten Bedienelement weg — genau der Fehler, der am
/// 30.07.2026 auf 'onboard' eine neue Identitaet anlegte, obwohl der Verweis
/// "Ich habe schon 12 Woerter" den Fokus hatte.
///
/// BEIDE ABSICHTEN SIND NOETIG: im Browser bildet WidgetsApp die Eingabetaste
/// auf [ButtonActivateIntent] ab, nicht auf [ActivateIntent]
/// (flutter/lib/src/widgets/app.dart:1317, nachgesehen am 30.07.2026) — mit nur
/// einer der beiden waere im Web allein die Leertaste ein Druck.
Map<Type, Action<Intent>> _aktivierung(VoidCallback tun) => {
      ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
        tun();
        return null;
      }),
      ButtonActivateIntent:
          CallbackAction<ButtonActivateIntent>(onInvoke: (_) {
        tun();
        return null;
      }),
    };

/// Macht ein Bedienelement im Fenster zeigerbar, ueberfahrbar und fokussierbar.
///
/// WARUM ES DAS BRAUCHT. Am 30.07.2026 kam MouseRegion in ganz lib/ nicht ein
/// einziges Mal vor: der Zeiger blieb ueber jedem Knopf ein Pfeil, ueber
/// Textknoepfen sogar ein Text-Cursor, und mit Tab war kein Knopf der App
/// erreichbar. Am Schreibtisch ist der Zeiger das erste, woran man erkennt,
/// dass etwas ein Knopf ist — bleibt er ein Pfeil, sucht man weiter.
///
/// DER TIPP BLEIBT DRINNEN. Diese Huelle bringt KEIN eigenes GestureDetector
/// mit; das Antippen behandelt weiter der Baustein, um den sie liegt
/// (`outlineBtn`, `Masse.trefferflaeche`, die freien GestureDetector). Zwei
/// Erkenner um dieselbe Flaeche waeren zwei Wege zu derselben Wirkung — und
/// einer davon wuerde irgendwann anders reagieren als der andere.
///
/// AUF ANDROID FAELLT SIE WEG, nicht "wirkt nicht": bei `imFenster == false`
/// gibt sie den Baum unveraendert zurueck. Damit bleibt dort jedes Pixel und
/// jeder Test, wie er war — im Widget-Test meldet Flutter android.
class _Bedienbar extends StatefulWidget {
  const _Bedienbar({
    required this.imFenster,
    required this.bau,
    this.onTap,
  });

  final bool imFenster;

  /// Null heisst: gerade nicht bedienbar. Dann bleibt der Standardzeiger, und
  /// die Huelle nimmt keinen Fokus — eine Hand ueber etwas, das nicht geht,
  /// verspricht etwas, was nicht kommt.
  final VoidCallback? onTap;

  final Widget Function(bool ueberfahren, bool fokus) bau;

  @override
  State<_Bedienbar> createState() => _BedienbarState();
}

class _BedienbarState extends State<_Bedienbar> {
  bool _ueber = false, _fokus = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.imFenster) return widget.bau(false, false);
    final an = widget.onTap != null;
    return FocusableActionDetector(
      enabled: an,
      mouseCursor: an ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (v) => setState(() => _ueber = v),
      onShowFocusHighlight: (v) => setState(() => _fokus = v),
      actions: _aktivierung(() => widget.onTap?.call()),
      child: widget.bau(_ueber && an, _fokus),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key, required this.state});

  final AppState state;

  @override
  State<Home> createState() => _HomeState();
}

/// Die Zeilen im Zugriffs-Bildschirm, in dieser Reihenfolge.
///
/// ALLE VIER SIND ECHT. Vorher standen hier zwei weitere, die nichts
/// einrichteten und nur erklaerten, warum es sie nicht gibt — Passkey und
/// Zwei-Faktor-Code. Sie sind raus: eine Liste, in der die Haelfte der
/// Eintraege nichts tut, laesst den Nutzer bei jedem der anderen zweifeln,
/// ob der wohl auch nur so tut.
const List<String> zugriffsZeilen = ['bio', 'devpin', 'hw', 'pw'];

/// Welche Faktorart hinter welcher Zeile steckt.
///
/// DIESE ZUORDNUNG WAR DER FEHLER, DER AM 25.07.2026 GEMELDET WURDE: vorher
/// wurde alles ausser 'hw' auf die Biometrie abgebildet. Ein Druck auf
/// "Passkey" fand damit das Fingerabdruck-Fach und ENTFERNTE es — mit einer
/// Zeile, die davon nichts sagte.
///
/// Steht auf oberster Ebene, damit ein Test sie sehen kann. Eine Zuordnung,
/// bei der zwei Zeilen auf dieselbe Art zeigen, ist genau der Fehler von
/// damals — und ohne Test faellt er erst am Geraet auf.
const Map<String, UnlockFactorKind> zeilenArt = {
  'bio': UnlockFactorKind.biometric,
  'devpin': UnlockFactorKind.deviceCredential,
  'hw': UnlockFactorKind.hardwareKey,
  'pw': UnlockFactorKind.passphrase,
};

class _HomeState extends State<Home> with WidgetsBindingObserver, TickerProviderStateMixin {
  String screen = 'onboard';
  String? chat;
  bool reqSent = false, sheet = false, panic = false, wiped = false, copied = false;

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

  /// Haelt die Unterhaltung am unteren Ende.
  ///
  /// Wird beim Bauen des Chatbildschirms gerufen und tut in zwei Faellen
  /// etwas — die sich absichtlich unterschiedlich verhalten:
  ///
  ///   BEIM OEFFNEN springt sie immer ans Ende, ohne Ruecksicht auf den
  ///   Schalter. Eine Unterhaltung, die bei der aeltesten Nachricht aufgeht,
  ///   ist kein Merkmal, das man abschalten koennen muss. (Genau das tat sie
  ///   bisher: die Liste hatte keine Steuerung und begann oben.)
  ///
  ///   BEI EINER NEUEN NACHRICHT nur, wenn [AppPreferences.autoScroll] an ist
  ///   — und selbst dann nicht, wenn der Leser gerade weiter oben steht. Wer
  ///   Alteres liest, soll nicht mitten im Satz weggerissen werden. Eigene
  ///   Nachrichten nehmen ihn trotzdem mit: wer schreibt, will sehen, was er
  ///   geschrieben hat.
  void _haltUnten(String cid, int anzahl) {
    final gewechselt = cid != _scrollChat;
    final eigene = _selbstGeschrieben;
    if (!gewechselt && anzahl == _scrollAnzahl) return;
    _scrollChat = cid;
    _scrollAnzahl = anzahl;
    _selbstGeschrieben = false;
    if (!gewechselt && !st.einstellungen.autoScroll) return;

    // NACH dem Bau, nicht waehrend: vorher steht die Hoehe der Liste noch
    // nicht fest, und maxScrollExtent waere der Wert von gestern.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScroll.hasClients) return;
      final unten = _chatScroll.position.maxScrollExtent;
      if (gewechselt) {
        _chatScroll.jumpTo(unten);
        return;
      }
      // Etwa eine Nachrichtenhoehe Spielraum: wer so nah am Ende steht, hat
      // die Liste nicht verlassen, sondern nur einen Rest Schwung uebrig.
      if (!eigene && unten - _chatScroll.offset > 140) return;
      _chatScroll.animateTo(unten,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    });
  }

  /// Die Pruefnummer der offenen Unterhaltung. Wird beim Oeffnen des
  /// Verschluesselungs-Blatts geladen — sie zu berechnen kostet 5200 Runden
  /// SHA-512 und lohnt nicht auf Vorrat.
  SafetyNumber? pruefnummer;
  String? pruefnummerFehler;

  Future<void> _ladePruefnummer(String id) async {
    setState(() { pruefnummer = null; pruefnummerFehler = null; });
    try {
      final n = await st.pruefnummer(id);
      if (mounted) setState(() => pruefnummer = n);
    } on MessengerException {
      // Es gibt noch keine Sitzung — erst muss eine Nachricht geflossen sein.
      if (mounted) setState(() => pruefnummerFehler = "verifyNoSession");
    }
  }

  /// Adressen der Unterhaltungen, die in der Liste erscheinen.
  List<String> get contacts => st.aktiveKontakte.map((c) => c.id).toList();

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
    st.boot().then((_) {
      if (!mounted) return;
      // Wer schon eine Identitaet hat, sieht das Onboarding nicht wieder.
      setState(() => screen = st.hatIdentitaet ? 'chats' : 'onboard');
    });
  }

  void _aktualisiere() {
    if (!mounted) return;
    _uebernimmEinstellungen();
    setState(() {});
  }

  /// Reicht die uebersetzten Texte fuer Benachrichtigungen durch. Der Kern
  /// kennt die Sprache nicht und soll sie auch nicht kennen.
  void _setzeMeldetexte() {
    st.einNeuText = t('notifOne');
    st.empfangTitelText = t('bgNotifTitle');
    st.empfangLaeuftText = t('bgNotifText');
    st.mehrereNeuText = (n) => t('notifMany').replaceFirst('{n}', '');
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

  /// Das Thema, dessen Schriften und Kennungsfarben gerade gelten: bis zur
  /// Mitte eines Wechsels das alte, danach das neue.
  Thema get _schriftThema =>
      (_vonThema != null && _wechsel.value < 0.5) ? _vonThema! : _thema;

  /// Wechselt langsam zu [neu]. Mitten in einem Wechsel geht es vom
  /// Zwischenstand aus weiter, nicht mit einem Sprung zurueck.
  void wechsleThema(Thema neu, {Duration dauer = const Duration(milliseconds: 2800)}) {
    if (neu.id == _thema.id && _vonThema == null) return;
    final ohneBewegung = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (ohneBewegung) {
      _wechsel.stop();
      setState(() {
        _vonThema = null;
        _thema = neu;
      });
      anzeigeThema.value = neu;
      return;
    }
    final von = _vonThema == null
        ? _thema
        : Thema(
            id: '_zwischen',
            name: const {'en': ''},
            pal: p,
            avatar: avp,
            dunkel: _schriftThema.dunkel,
            anzeigeSchrift: _schriftThema.anzeigeSchrift,
            monoSchrift: _schriftThema.monoSchrift,
            textSchrift: _schriftThema.textSchrift,
          );
    setState(() {
      _vonThema = von;
      _thema = neu;
    });
    _wechsel.duration = dauer;
    _wechsel.forward(from: 0);
  }

  /// Das Wandern: alle paar Minuten gleitet das Thema von allein zum
  /// naechsten dunklen weiter — langsamer als ein gewaehlter Wechsel.
  void _planeWandern(int minuten) {
    _wanderTakt?.cancel();
    _wanderTakt = null;
    if (minuten <= 0) return;
    _wanderTakt = Timer.periodic(Duration(minutes: minuten), (_) {
      if (!mounted) return;
      final kreis = wanderKreis(_themen);
      final i = kreis.indexWhere((t) => t.id == _thema.id);
      wechsleThema(kreis[(i + 1) % kreis.length], dauer: const Duration(seconds: 7));
    });
  }

  /// Uebernimmt, was in den Einstellungen steht — beim Start (nach dem
  /// Entsperren gleitet die App in das gespeicherte Thema) und nach jeder
  /// Aenderung.
  void _uebernimmEinstellungen() {
    final e = st.einstellungen;
    if (e.thema != _gemeldetesThema) {
      _gemeldetesThema = e.thema;
      final ziel = _themen.firstWhere((t) => t.id == e.thema, orElse: () => _themen.first);
      if (ziel.id != _thema.id) wechsleThema(ziel, dauer: const Duration(milliseconds: 3200));
    }
    if (e.themaWandern != _gemeldetesWandern) {
      _gemeldetesWandern = e.themaWandern;
      _planeWandern(e.themaWandern);
    }
    final sprache = e.sprache;
    if (sprache != null && sprache != lang) {
      lang = sprache;
      _setzeMeldetexte();
    }
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

  Pal get p => _vonThema == null
      ? _thema.pal
      : Pal.lerp(_vonThema!.pal, _thema.pal, Curves.easeInOut.transform(_wechsel.value));

  /// Breiteste Darstellung des Inhalts. Darueber wird der Rest Rand.
  ///
  /// Ein Desktop-Fenster ist leicht 1400 Pixel breit. Ein Eingabefeld dieser
  /// Breite ist keins mehr, und eine Textzeile, die man von einem Bildrand zum
  /// anderen lesen muss, liest niemand. Diese App ist fuer eine Hand
  /// entworfen — in einem grossen Fenster bleibt sie das.
  ///
  /// Genau das stand als Absicht schon in der README ("am Desktop im
  /// Handy-Rahmen, am Handy im Vollbild"), war aber nie gebaut. Am 30.07.2026
  /// im ersten Windows-Bau nachgemessen: das Feld auf dem Anmeldebildschirm
  /// war 1430 Pixel breit.
  ///
  static const _telefonbreite = 460.0;

  /// Laeuft die App in einem FENSTER, dessen Groesse jemand zieht?
  ///
  /// AN DER PLATTFORM UND NICHT AN DER BREITE, und das war ein Fehler, den ich
  /// erst gemessen habe. Zuerst hiess die Regel "ab 460 Pixel begrenzen". Die
  /// trifft aber auch den 800x600-Bildschirm der Widget-Tests: der Inhalt
  /// wurde dort schmaler und damit hoeher, und 16 Tests fielen mit
  /// "RenderFlex overflowed by 22 pixels on the bottom" — 791 statt 807 gruen,
  /// am 30.07.2026.
  ///
  /// Auf einem echten Telefon passiert das nicht, weil ein Telefon hoch ist.
  /// 800x600 ist weder Telefon noch Desktop, und eine Regel, die daran
  /// haengenblieb, war am falschen Merkmal aufgehaengt.
  ///
  /// So laesst sie Android vollstaendig unberuehrt, Tests eingeschlossen, und
  /// sagt genauer, was gemeint ist: der Rahmen ist fuer Fenster da, nicht fuer
  /// breite Telefone. Das Web ist mitgezaehlt — dort greift zusaetzlich die
  /// Breitenpruefung, ein Telefonbrowser bleibt also im Vollbild.
  static bool get _imFenster =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// Breite der Spalte in einem Fenster.
  ///
  /// 460 war die Telefonbreite und im Fenster zu schmal: die Abfolgen —
  /// Anmeldung, Phrase, Wiederherstellen — standen als duenner Streifen in
  /// einer leeren Flaeche. 560 nimmt der Zeile die Enge, ohne sie so lang zu
  /// machen, dass das Auge am Zeilenende den Anfang verliert.
  static const _fensterspalte = 560.0;

  /// Begrenzt [kind] auf [_telefonbreite], sobald mehr Platz da ist.
  ///
  /// Bewusst NUR um den Inhalt und nicht um das Scaffold: dessen Hintergrund
  /// soll das Fenster weiter ausfuellen. Die Ueberlagerungen daneben im Stack
  /// (Anmeldung, Bogen, Notfall) bleiben ebenfalls voll — sie bringen eigene
  /// Verdunkelung mit, und die muss bis an den Fensterrand reichen.
  Widget _aufTelefonbreite(Widget kind) => !_imFenster
      ? kind
      : LayoutBuilder(
          builder: (_, con) => con.maxWidth <= _telefonbreite
              ? kind
              : Center(
                  child: Container(
                    width: _fensterspalte,
                    // SEITENLINIEN, KEIN KASTEN. Ohne sie schwebt der Text im
                    // Fenster und sieht aus wie ein Fehler im Layout; mit einem
                    // ganzen Rahmen sieht er aus wie ein Dialog, der auf eine
                    // Antwort wartet. Zwei Linien sagen "hier ist die Spalte"
                    // und sonst nichts.
                    decoration: BoxDecoration(
                      border: Border.symmetric(
                        vertical: BorderSide(color: p.lineSoft),
                      ),
                    ),
                    child: kind,
                  ),
                ),
        );

  // ── Abfolgen im Fenster ─────────────────────────────────────────────────
  //
  // Die Bildschirme, die Schritt fuer Schritt durch etwas fuehren, sind fuer
  // eine Hand entworfen: senkrecht zentriert, Knoepfe ueber die ganze Breite,
  // Schrift fuer 30 cm Abstand. Am Schreibtisch sitzt man doppelt so weit weg,
  // das Fenster ist hoeher als jeder Inhalt, und ein Knopf ueber die ganze
  // Spalte ist kein Knopf mehr, sondern ein Banner. Henrik hat das am
  // 30.07.2026 an einem 984x1040 grossen Fenster beanstandet.

  /// Genau die Bildschirme, die eine Abfolge sind — und keinen weiteren.
  ///
  /// Die vier Schreibtisch-Bildschirme ('chats', 'chat', 'id', 'set') stehen
  /// bewusst NICHT hier: die haben ihr eigenes Geruest und sind fertig. Der
  /// Sperrbildschirm auch nicht, der ist ein eigener Fall.
  static const _abfolgeSchirme = {
    'onboard', 'creating', 'phrase', 'secure', 'restore', 'test', 'nahHilfe',
    'add',
  };

  bool get _abfolgeImFenster =>
      _imFenster && _abfolgeSchirme.contains(screen);

  /// Um diesen Faktor waechst die Schrift der Abfolgen im Fenster.
  ///
  /// EIN FAKTOR AN EINER STELLE statt vierzig geaenderter Zahlen: die
  /// Proportionen des Entwurfs bleiben damit erhalten, und die naechste
  /// Aenderung muss nicht vierzig Stellen finden. Er greift in [_font], also
  /// ueberall, wo diese App Text setzt.
  ///
  /// 1.15 ist gemessen, nicht geraten: die kleinste Schrift der Abfolgen ist
  /// `label6` mit 10 pt, und 10 pt sind auf 60 cm Abstand an der Grenze. 11.5
  /// liest sich dort wie 10 pt in der Hand; mehr liess die Zeilen in der
  /// Spalte umbrechen, die vorher in eine Zeile passten (30.07.2026, 984 px
  /// Fenster, 24-Zoll-Schirm).
  ///
  /// Die 36-pt-Ueberschrift auf 'onboard' waechst NICHT mit — sie ist dort
  /// gegengerechnet kleiner gesetzt, siehe [onboardScreen].
  static const _schriftFaktor = 1.15;

  /// Hoechstbreite eines Knopfes im Fenster.
  ///
  /// In der 560er Spalte bleiben 516 px Innenbreite. Ein Knopf darueber ist
  /// ein Banner — er sieht aus wie eine Kopfzeile mit Rahmen. 320 ist an den
  /// laengsten Knopfbeschriftungen gemessen ('CREATE IDENTITY',
  /// 'WIEDERHERSTELLEN', 'ANFRAGE SENDEN' bei 13 pt mal 1.15): sie passen
  /// ohne Umbruch hinein, und der Knopf sieht noch wie einer aus (30.07.2026).
  static const _knopfBreiteMax = 320.0;

  /// Begrenzt einen Knopf im Fenster und schlaegt ihn links an.
  ///
  /// LINKS UND NICHT MITTIG, weil aller Text dieser Bildschirme links
  /// anschlaegt (`CrossAxisAlignment.start`). Ein mittiger Knopf unter linkem
  /// Text sieht aus wie ein Knopf, der zu einem anderen Abschnitt gehoert.
  Widget _knopfBreite(Widget knopf) => !_imFenster
      ? knopf
      : Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _knopfBreiteMax),
            child: knopf,
          ),
        );

  /// Ein Gitter mit ZWEI Kaesten je Zeile, gerechnet aus dem Platz, den es HIER
  /// gibt — nicht aus der Fensterbreite.
  ///
  /// EIN BAUSTEIN FUER BEIDE STELLEN: die zwoelf Woerter auf 'phrase' und die
  /// vierzehn Vierergruppen der Adresse auf 'id'. Vorher stand in beiden
  /// `MediaQuery.of(context).size.width`, und behoben wurde nur die erste — die
  /// zweite fiel dem Gegenlesen am 30.07.2026 auf. Mit einer Stelle kann das
  /// nicht mehr passieren.
  ///
  /// WAS DIE FENSTERBREITE FALSCH MACHT: die Spalte, in der diese Bildschirme
  /// stehen, ist begrenzt — die Abfolgen auf [_fensterspalte] (560 minus zwei
  /// Seitenlinien minus 44 px Rand = 514 px innen), die rechte
  /// Schreibtischspalte auf 720 (676 px innen, im Test nachgemessen). Die alte
  /// Rechnung `(Fensterbreite - 44 - 6) / 2` ergab bei 984 px Fenster 467 px je
  /// Kasten: in 514 px passte davon nur EINER je Zeile. Ab 1078 px Fenster
  /// (bzw. 1402 px bei 676 px Innenbreite) ist der Kasten sogar breiter als der
  /// Platz — RenderWrap klemmt ihn dann auf die Spaltenbreite, also wieder
  /// einer je Zeile. Beides fiel genau die Lesehilfe zusammen, deren Zweck das
  /// Vergleichen ist.
  ///
  /// `con.maxWidth` ist der Platz INNERHALB des Randes, die 44 sind darin also
  /// schon abgezogen — auf Android kommt dasselbe heraus wie vorher.
  Widget _zweiSpaltenGitter(int anzahl, Widget Function(int i) bau) =>
      LayoutBuilder(
        builder: (_, con) => Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < anzahl; i++)
            SizedBox(width: (con.maxWidth - 6) / 2, child: bau(i)),
        ]),
      );

  // ── Schreibtisch ────────────────────────────────────────────────────────
  //
  // WARUM UEBERHAUPT EIN ZWEITES GERUEST. Zuerst habe ich die Telefon-
  // Oberflaeche nur auf 460 Pixel begrenzt und mittig gestellt. Das behob den
  // 1430 Pixel breiten Eingabekasten, sah aber aus wie eine Telefon-App in
  // einem zu grossen Fenster — ein schmaler Streifen mit viel Leere daneben.
  // Henrik hat das am 30.07.2026 genau so beanstandet, und er hatte recht: das
  // war ein Kompromiss, keine Desktop-App.
  //
  // NEU IST NUR DIE ANORDNUNG. Die Bildschirme selbst bleiben, wie sie sind —
  // `chatsScreen()` links, der Rest rechts. Kein zweiter Satz Oberflaeche, der
  // getrennt gepflegt werden muesste, und kein zweiter Ort, an dem ein Fehler
  // behoben werden muss.

  /// Ab dieser Fensterbreite lohnen zwei Spalten.
  ///
  /// Darunter ist die Telefonanordnung die bessere: 300 Pixel Liste plus einen
  /// brauchbaren Unterhaltungsbereich gehen sich unter 900 nicht aus, und ein
  /// gequetschtes Nebeneinander liest schlechter als ein klares Nacheinander.
  static const _zweiSpaltenAb = 900.0;

  /// Nur diese Bildschirme haben zwei Spalten. Die Einrichtung nicht.
  ///
  /// Anmeldung, Wiederherstellen und die Phrase sind Abfolgen — Schritt fuer
  /// Schritt, ein Gedanke je Bild. Die gehoeren auch auf dem Desktop in eine
  /// Spalte, sonst steht rechts eine leere Flaeche und fragt, was man dort
  /// verpasst hat.
  static const _schreibtischSchirme = {'chats', 'chat', 'id', 'set'};

  bool get _zweiSpalten =>
      _imFenster && MediaQuery.sizeOf(context).width >= _zweiSpaltenAb;

  bool get _amSchreibtisch =>
      _zweiSpalten &&
      st.bereit &&
      !st.gesperrt &&
      _schreibtischSchirme.contains(screen);

  /// Liste links, Inhalt rechts.
  Widget schreibtischGeruest() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: Column(children: [
              Expanded(child: chatsScreen()),
              buildNav(),
            ]),
          ),
          Container(width: 1, color: p.lineSoft),
          Expanded(child: _rechteSpalte()),
        ],
      );

  /// Was rechts steht, haengt am gewaehlten Bildschirm.
  ///
  /// 'chats' heisst hier NICHT "die Liste nochmal", sondern "es ist nichts
  /// ausgewaehlt" — links steht sie ja schon.
  Widget _rechteSpalte() {
    final inhalt = switch (screen) {
      'chat' => chatScreen(),
      'id' => idScreen(),
      'set' => settingsScreen(),
      _ => _nichtsGewaehlt(),
    };
    // Auch rechts nicht unbegrenzt: eine Textzeile ueber 1200 Pixel liest
    // niemand, und die Einstellungen sind fuer eine Spalte entworfen.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: inhalt,
      ),
    );
  }

  Widget _nichtsGewaehlt() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            t('noChats'),
            textAlign: TextAlign.center,
            style: mono(size: 12, color: p.dim, height: 1.6),
          ),
        ),
      );
  List<Color> get avp => _schriftThema.avatar;
  String t(String k) => strings[lang]![k] ?? k;

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
    _chatScroll.dispose();
    draftCtl.dispose();
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

  // ---- fonts (bundled locally; the app never fetches them at runtime) ----
  //
  // Both families are variable fonts with a `wght` axis, so a single file
  // covers every weight the UI uses (w300 … w900). `fontWeight` alone does not
  // drive that axis reliably, so the axis is set explicitly via fontVariations
  // and `fontWeight` is kept for Flutter's own fallback/metrics handling.
  TextStyle _font(String? family, double size, FontWeight weight, Color? color, double? spacing, double height) {
    // DIE EINE STELLE, an der die Schrift der Abfolgen im Fenster waechst —
    // siehe [_schriftFaktor]. Der Faktor haengt am Bildschirm und nicht nur an
    // der Plattform: die vier fertigen Schreibtisch-Bildschirme sind
    // ausgemessen, wie sie sind, und sollen sich nicht verschieben.
    if (_abfolgeImFenster) size *= _schriftFaktor;
    return TextStyle(
      fontFamily: family,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: spacing,
      height: height,
    );
  }
  TextStyle doto({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.2}) =>
      _font(_schriftThema.anzeigeSchrift, size, weight, color, spacing, height);
  TextStyle mono({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.4}) =>
      _font(_schriftThema.monoSchrift, size, weight, color, spacing, height);

  // ---- helpers ----
  /// Uhrzeit einer Nachricht, bei aelteren zusaetzlich der Tag.
  String zeitVon(DateTime utc) {
    final l = utc.toLocal();
    final heute = DateTime.now();
    final hm = '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
    if (l.year == heute.year && l.month == heute.month && l.day == heute.day) {
      return hm;
    }
    return '${l.day.toString().padLeft(2, '0')}.'
        '${l.month.toString().padLeft(2, '0')}. $hm';
  }

  /// Die Frist als Text — jetzt aus der ECHTEN Einstellung, nicht aus einer
  /// Anzeigevariablen.
  String ephLabel() => fristText(st.einstellungen.messageLifetime);

  String fristText(Duration? d) {
    if (d == null) return t("off");
    if (d.inHours <= 1) return t("h1");
    if (d.inHours <= 24) return t("h24");
    return t("d7");
  }

  /// Fristen, die die Oberflaeche anbietet. null = aus.
  static const Map<String, Duration?> _fristen = {
    "off": null,
    "1h": Duration(hours: 1),
    "24h": Duration(hours: 24),
    "7d": Duration(days: 7),
  };

  String get _fristSchluessel {
    final d = st.einstellungen.messageLifetime;
    if (d == null) return "off";
    if (d.inHours <= 1) return "1h";
    if (d.inHours <= 24) return "24h";
    return "7d";
  }

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

  /// Legt eine echte Identitaet an und zeigt danach die zwoelf Woerter.
  ///
  /// Der Entwurf sprang von hier direkt zu den Anmeldeverfahren. Das ging
  /// nicht: die Phrase ist der EINZIGE Weg zurueck, wenn das Telefon weg ist,
  /// und wer sie nie zu sehen bekommt, verliert seine Identitaet beim ersten
  /// kaputten Bildschirm. Deshalb liegt jetzt ein Schritt dazwischen.
  Future<void> doCreate() async {
    setState(() { screen = 'creating'; wiped = false; });
    await st.identitaetAnlegen();
    if (!mounted) return;
    setState(() => screen = 'phrase');
  }

  Future<void> send() async {
    final d = draftCtl.text.trim();
    if (d.isEmpty || chat == null) return;
    if (d.startsWith('/') && _bearbeitungsZiel == null && await _fuehreBefehlAus(d)) {
      draftCtl.clear();
      if (mounted) setState(() {});
      return;
    }
    _vergissPlanFehler();
    draftCtl.clear();
    final bearbeitet = _bearbeitungsZiel;
    final antwort = _antwortZiel;
    setState(() {
      _bearbeitungsZiel = null;
      _antwortZiel = null;
    });
    if (bearbeitet != null) {
      await st.bearbeite(chat!, bearbeitet.id, d);
      return;
    }
    // VOR dem Senden setzen, nicht danach: `senden` meldet die Aenderung
    // selbst, der Neubau laeuft also noch waehrend dieses `await`. Danach
    // waere die Marke zu spaet.
    _selbstGeschrieben = true;
    await st.senden(chat!, d, antwortAuf: antwort?.id);
  }

  /// Fragt nach Tag und Uhrzeit und plant die Nachricht im Eingabefeld.
  /// "Die Zeit ist schon vorbei" gilt fuer EINEN Versuch. Stehen blieb sie
  /// sonst auch dann noch, als der naechste Versuch laengst geplant war
  /// (Emulatorlauf 25.09.2026).
  void _vergissPlanFehler() {
    if (st.letzterFehler == 'geplantVorbei') st.vergissFehler();
  }

  Future<void> _planeSenden() async {
    final d = draftCtl.text.trim();
    if (d.isEmpty || chat == null || _bearbeitungsZiel != null) return;
    _vergissPlanFehler();
    final jetzt = DateTime.now();
    final tag = await showDatePicker(
        context: context,
        initialDate: jetzt,
        firstDate: jetzt,
        lastDate: jetzt.add(const Duration(days: 365)),
        helpText: t('scheduleTitle'));
    if (tag == null || !mounted) return;
    final zeit = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(jetzt.add(const Duration(hours: 1))));
    if (zeit == null) return;
    final um = DateTime(tag.year, tag.month, tag.day, zeit.hour, zeit.minute);
    if (!um.isAfter(DateTime.now())) {
      st.setzeFehler('geplantVorbei');
      return;
    }
    final antwort = _antwortZiel;
    draftCtl.clear();
    setState(() => _antwortZiel = null);
    await st.senden(chat!, d, antwortAuf: antwort?.id, um: um);
  }

  /// Seit wann aufgenommen wird, oder null.
  DateTime? _aufnahmeSeit;
  Timer? _aufnahmeTakt;

  String _aufnahmeDauer() {
    final d = DateTime.now().difference(_aufnahmeSeit ?? DateTime.now());
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _starteAufnahme(String cid) async {
    final recht = await Sprache.rechte();
    if (recht != 'ja') {
      st.setzeFehler(recht == 'dauerhaft' ? 'mikrofonDauerhaft' : 'mikrofonNein');
      return;
    }
    if (!await Sprache.starte()) {
      st.setzeFehler('aufnahmeFehler');
      return;
    }
    setState(() => _aufnahmeSeit = DateTime.now());
    // Die Anzeige der Dauer zaehlt sichtbar mit — sonst weiss niemand, ob
    // das Mikrofon wirklich laeuft.
    _aufnahmeTakt = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  Future<void> _schickeAufnahme(String cid) async {
    _aufnahmeTakt?.cancel();
    setState(() => _aufnahmeSeit = null);
    final a = await Sprache.stoppe();
    if (a == null) return; // zu kurz — nichts aufgenommen
    // AUCH EINE SPRACHNACHRICHT IST "SELBST GESCHRIEBEN" — siehe
    // [_haltUnten]. Ohne das galt sie als fremde, und weil ihre Blase hoeher
    // ist als der Spielraum von 140 Punkten, blieb die Liste stehen: die
    // eigene Sprachnachricht war abgeschickt und unsichtbar (Emulatorlauf
    // 25.09.2026). Dasselbe fuer Umfrage und Anhang.
    _selbstGeschrieben = true;
    await st.sendeSprachnachricht(cid, a);
  }

  Future<void> _verwirfAufnahme() async {
    _aufnahmeTakt?.cancel();
    setState(() => _aufnahmeSeit = null);
    await Sprache.verwirf();
  }

  /// Ein kurzer Auszug einer Nachricht — fuer Zitat, Antwortleiste und Liste.
  String auszug(Message m) {
    if (m.widerrufen) return t('deletedMsg');
    if (m.kind == MessageKind.anhang && sprachName.hasMatch(m.text)) {
      return t('voice');
    }
    if (m.kind == MessageKind.anhang) return '${t('attachment')}: ${m.text}';
    if (m.kind == MessageKind.umfrage) {
      return '${t('poll')}: ${Umfrage.lies(m.text)?.frage ?? ''}';
    }
    return Formatierung.schlicht(m.text);
  }

  // ═══════════════════════════════════════════════ Befehle der Schreibzeile
  //
  // "/timer 1h", "/verify", "/poll", "/theme aurora", "/shrug". Wie in einem
  // Terminal — und nur die bekannten: alles andere mit "/" am Anfang geht als
  // gewoehnliche Nachricht hinaus, wer "/s" schreibt, meint Ironie.

  static const _befehle = ['timer', 'verify', 'poll', 'theme', 'shrug'];

  /// Ob die Schreibzeile beim letzten Tastendruck mit "/" begann.
  bool _warBefehl = false;

  List<String> _passendeBefehle() {
    final text = draftCtl.text;
    if (!text.startsWith('/') || text.contains('\n')) return const [];
    final wort = text.substring(1).split(' ').first.toLowerCase();
    // Steht der Befehl schon vollstaendig da und ein Argument dahinter, ist die
    // Leiste nur noch im Weg — ausser beim Thema, dort zeigt sie die Namen.
    if (text.contains(' ') && wort != 'theme' && wort != 'timer') return const [];
    return _befehle.where((b) => b.startsWith(wort)).toList();
  }

  /// Die Vorschlaege ueber der Schreibzeile, sobald sie mit "/" beginnt.
  Widget befehlsLeiste() {
    final passend = _passendeBefehle();
    if (passend.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
          color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final b in passend)
          InkWell(
            key: ValueKey('befehl-$b'),
            onTap: () {
              draftCtl.text = '/$b ';
              draftCtl.selection = TextSelection.collapsed(offset: draftCtl.text.length);
              setState(() {});
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              child: Row(children: [
                Text('/$b', style: mono(size: 12.5, weight: FontWeight.w600, color: p.accLight)),
                const SizedBox(width: 10),
                Expanded(child: Text(
                    b == 'theme'
                        ? _themen.map((th) => th.id.toLowerCase()).join(' · ')
                        : t('cmd_$b'),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: mono(size: 10.5, color: p.dim, height: 1.4))),
              ]),
            ),
          ),
      ]),
    );
  }

  /// Fuehrt einen Befehl aus. false = kein bekannter Befehl, der Text geht
  /// als Nachricht hinaus.
  Future<bool> _fuehreBefehlAus(String eingabe) async {
    final cid = chat;
    if (cid == null) return false;
    final teile = eingabe.substring(1).trim().split(RegExp(r'\s+'));
    final befehl = teile.first.toLowerCase();
    final arg = teile.length > 1 ? teile[1].toLowerCase() : '';
    switch (befehl) {
      case 'timer':
        const fristen = <String, Duration?>{
          '1h': Duration(hours: 1),
          '24h': Duration(hours: 24),
          '1d': Duration(hours: 24),
          '7d': Duration(days: 7),
          '1w': Duration(days: 7),
          // Duration.zero ist "aus fuer diesen Chat", null "wie in den
          // Einstellungen" — dieselben Werte wie im Verschluesselungsblatt.
          'off': Duration.zero,
          'aus': Duration.zero,
          'std': null,
        };
        if (!fristen.containsKey(arg)) {
          _hinweis(t('cmdTimerBad'));
          return true;
        }
        await st.setzeChatFrist(cid, fristen[arg]);
        _hinweis('${t('selfDestruct')}: ${fristText(st.fristFuer(cid))}');
        return true;
      case 'verify':
        if (st.gruppeZu(cid) != null || st.istNotizen(cid)) {
          _hinweis(t('cmdVerifyNone'));
          return true;
        }
        setState(() => sheet = true);
        unawaited(_ladePruefnummer(cid));
        return true;
      case 'poll':
        unawaited(_legeUmfrageAn(cid));
        return true;
      case 'theme':
        final ziel = _themen.where((th) =>
            th.id.toLowerCase() == arg ||
            th.name.values.any((n) => n.toLowerCase().replaceAll(' ', '') == arg));
        if (ziel.isEmpty) {
          _hinweis(t('cmdThemeBad'));
          return true;
        }
        await st.setzeEinstellungen(st.einstellungen.copyWith(thema: ziel.first.id));
        return true;
      case 'shrug':
        final rest = eingabe.substring(1 + befehl.length).trim();
        await st.senden(cid, rest.isEmpty ? r'¯\_(ツ)_/¯' : '$rest ' r'¯\_(ツ)_/¯');
        return true;
    }
    return false;
  }

  /// Eine kurze Rueckmeldung am unteren Rand.
  void _hinweis(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  /// Die Zeile, die zeigt, worauf die naechste Nachricht antwortet oder dass
  /// gerade bearbeitet wird. Das Kreuz bricht ab.
  Widget eingabeBezug() {
    final ziel = _bearbeitungsZiel ?? _antwortZiel;
    if (ziel == null) return const SizedBox.shrink();
    final bearbeitung = _bearbeitungsZiel != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
          color: p.surf2,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: p.accent, width: 3))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((bearbeitung ? t('editing') : t('replyTo')).toUpperCase(),
                style: mono(size: 9.5, weight: FontWeight.w600, color: p.accLight, spacing: 1)),
            const SizedBox(height: 2),
            Text(auszug(ziel), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: mono(size: 12, color: p.muted)),
          ]),
        ),
        Semantics(
          button: true,
          label: t('cancel'),
          child: Masse.trefferflaeche(
            onTap: () => setState(() {
              if (bearbeitung) draftCtl.clear();
              _antwortZiel = null;
              _bearbeitungsZiel = null;
            }),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text('×', style: TextStyle(color: p.muted, fontSize: 16, height: 1)),
            ),
          ),
        ),
      ]),
    );
  }

  void plusMenue(String cid) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      // HOEHER ALS DIE VORGABE, WENN NOETIG. Ohne das darf ein Blatt nur
      // 9/16 des Bildschirms hoch sein, und das Nachrichtenmenue lief im
      // Querformat unten ueber (Widget-Test, 600 px Hoehe: 18 px zu viel).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) {
        Widget eintrag(String text, VoidCallback tun) => InkWell(
              onTap: () {
                Navigator.pop(ctx);
                tun();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(text, style: mono(size: 13.5, color: p.ink)),
              ),
            );
        return SafeArea(
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            eintrag(t('attach'), () => anhangWaehlen(cid)),
            eintrag(t('pollNew'), () => _legeUmfrageAn(cid)),
            const SizedBox(height: 6),
          ])),
        );
      },
    );
  }

  Future<void> _legeUmfrageAn(String cid) async {
    final frage = TextEditingController();
    final optionen = [TextEditingController(), TextEditingController()];
    var mehrfach = false;
    String? fehler;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('pollNew'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: frage, maxLength: Umfrage.maxFrage, enableIMEPersonalizedLearning: false,
                  style: mono(size: 13, color: p.ink),
                  decoration: InputDecoration(hintText: t('pollQuestion'), counterText: '', hintStyle: mono(size: 13, color: p.dim))),
              for (var i = 0; i < optionen.length; i++)
                TextField(controller: optionen[i], maxLength: Umfrage.maxOption, enableIMEPersonalizedLearning: false,
                    style: mono(size: 13, color: p.ink),
                    decoration: InputDecoration(hintText: '${t('pollOption')} ${i + 1}', counterText: '', hintStyle: mono(size: 13, color: p.dim))),
              if (optionen.length < Umfrage.maxOptionen)
                TextButton(
                  onPressed: () => neu(() => optionen.add(TextEditingController())),
                  child: Text('+ ${t('pollOption')}'),
                ),
              Row(children: [
                Checkbox(value: mehrfach, onChanged: (v) => neu(() => mehrfach = v ?? false)),
                Expanded(child: Text(t('pollMulti'), style: mono(size: 12, color: p.muted))),
              ]),
              if (fehler != null)
                Text(fehler!, style: mono(size: 11.5, color: p.tintInk)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                final antworten = [
                  for (final o in optionen)
                    if (o.text.trim().isNotEmpty) o.text.trim(),
                ];
                final u = Umfrage(frage.text.trim(), antworten, mehrfach: mehrfach);
                if (Umfrage.lies(u.alsText()) == null) {
                  neu(() => fehler = t('pollInvalid'));
                  return;
                }
                Navigator.pop(ctx);
                _selbstGeschrieben = true;
                await st.sendeUmfrage(cid, u);
              },
              child: Text(t('send')),
            ),
          ],
        ),
      ),
    );
    _entsorgeNachDemSchliessen([frage, ...optionen]);
  }

  /// Eine Umfrage in der Blase: Frage, und je Antwort Anzahl und Balken.
  /// Antippen waehlt oder nimmt die Wahl zurueck.
  Widget umfrageInhalt(String cid, Message m) {
    final u = Umfrage.lies(m.text);
    if (u == null) return const SizedBox.shrink();
    final stimmen = st.stimmenZu(cid, m.id);
    final meine = stimmen[st.meineAdresse] ?? const <int>[];
    final zaehler = List<int>.filled(u.optionen.length, 0);
    for (final a in stimmen.values) {
      for (final i in a) {
        if (i >= 0 && i < zaehler.length) zaehler[i]++;
      }
    }
    final gesamt = stimmen.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(u.frage, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: p.ink, height: 1.4)),
      const SizedBox(height: 2),
      Text(u.mehrfach ? t('pollMulti') : t('pollSingle'), style: mono(size: 9.5, color: p.dim)),
      const SizedBox(height: 6),
      for (var i = 0; i < u.optionen.length; i++)
        Semantics(
          button: true,
          selected: meine.contains(i),
          label: '${u.optionen[i]}, ${zaehler[i]}',
          child: GestureDetector(
            // DIE GANZE ZEILE, nicht nur Text und Kreis. Ohne `opaque` traf
            // nur, was gemalt ist — ein Tipp auf den Balken oder den
            // Zwischenraum ging ins Leere (Emulatorlauf 25.09.2026: die
            // Mitte der Zeile zaehlte nicht).
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final neu = meine.contains(i)
                  ? (List.of(meine)..remove(i))
                  : (u.mehrfach ? [...meine, i] : [i]);
              st.stimme(cid, m.id, neu);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  wahlZeichen(meine.contains(i), u.mehrfach,
                      ValueKey('wahl-${m.id}-$i-${meine.contains(i) ? 'an' : 'aus'}')),
                  const SizedBox(width: 8),
                  Expanded(child: Text(u.optionen[i], style: TextStyle(fontSize: 13, color: p.ink))),
                  Text('${zaehler[i]}', style: mono(size: 11, color: p.muted)),
                ]),
                const SizedBox(height: 3),
                // Ohne Prozentzeile: die Zahl steht rechts schon da.
                fortschrittsBalken(gesamt == 0 ? 0 : zaehler[i] / gesamt, mitZahl: false),
              ]),
            ),
          ),
        ),
    ]);
  }

  /// Welche der angehefteten Nachrichten die Leiste gerade zeigt.
  int _angeheftetStelle = 0;

  /// Die Leiste unter der Kopfzeile: die angeheftete Nachricht, bei mehreren
  /// schaltet Antippen zur naechsten weiter.
  Widget angeheftetLeiste(String cid) {
    final liste = st.angeheftete(cid);
    if (liste.isEmpty) return const SizedBox.shrink();
    final i = _angeheftetStelle % liste.length;
    return Semantics(
      button: liste.length > 1,
      label: t('pinnedTitle'),
      child: GestureDetector(
        onTap: liste.length > 1 ? () => setState(() => _angeheftetStelle++) : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(17, 7, 17, 7),
          decoration: BoxDecoration(
              color: p.surf2, border: Border(bottom: BorderSide(color: p.lineSoft))),
          child: Row(children: [
            marke(t('pinnedTag')),
            const SizedBox(width: 8),
            Expanded(
              child: Text(auszug(liste[i]), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: mono(size: 12, color: p.muted)),
            ),
            if (liste.length > 1)
              Text('${i + 1}/${liste.length}', style: mono(size: 10.5, color: p.dim)),
          ]),
        ),
      ),
    );
  }

  /// Eine kleine Rahmen-Marke in Monoschrift — derselbe Aufbau wie die
  /// Marke "VIA NEARBY" an einer Nachricht.
  ///
  /// STATT FARB-EMOJIS. Die App zeichnet ihre Zeichen als Text in ihrer
  /// eigenen Schrift (‹, +, ✓✓, ◷); ein buntes 📌 oder 🔕 aus dem
  /// Emoji-Satz des Telefons faellt darin heraus und sieht auf jedem
  /// Hersteller anders aus.
  Widget marke(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: p.tintLine)),
        child: Text(text.toUpperCase(),
            style: mono(size: 8, weight: FontWeight.w600, color: p.accLight, spacing: 0.9)),
      );

  /// Die Wahl-Markierung einer Umfrage-Antwort: gezeichnet, nicht als
  /// Unicode-Zeichen — Kreis fuer Einzelwahl, Kaestchen fuer Mehrfachwahl.
  Widget wahlZeichen(bool gewaehlt, bool mehrfach, Key key) => Container(
        key: key,
        width: 14,
        height: 14,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: mehrfach ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: mehrfach ? BorderRadius.circular(3) : null,
          border: Border.all(color: p.accLight, width: 1.4),
        ),
        child: gewaehlt
            ? Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: p.accLight,
                  shape: mehrfach ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: mehrfach ? BorderRadius.circular(1.5) : null,
                ),
              )
            : null,
      );

  /// Die sechs Reaktionen, die Signal zuerst anbietet.
  static const schnellReaktionen = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  /// Das Menue an einer Nachricht: Reaktionen oben, Aktionen darunter.
  void nachrichtMenue(String cid, Message m) {
    final meine = st.reaktionenZu(cid, m.id)[st.meineAdresse];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      // HOEHER ALS DIE VORGABE, WENN NOETIG. Ohne das darf ein Blatt nur
      // 9/16 des Bildschirms hoch sein, und das Nachrichtenmenue lief im
      // Querformat unten ueber (Widget-Test, 600 px Hoehe: 18 px zu viel).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) {
        Widget eintrag(String text, VoidCallback tun, {bool warnend = false}) =>
            InkWell(
              onTap: () {
                Navigator.pop(ctx);
                tun();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(text,
                    style: mono(size: 13.5, color: warnend ? p.tintInk : p.ink)),
              ),
            );
        return SafeArea(
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            if (!m.widerrufen)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  for (final z in schnellReaktionen)
                    Semantics(
                      button: true,
                      selected: meine == z,
                      label: z,
                      child: GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          // Dieselbe noch einmal nimmt sie zurueck — wie bei Signal.
                          st.reagiere(cid, m.id, meine == z ? null : z);
                        },
                        child: Container(
                          width: 44, height: 44, alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: meine == z ? p.tint : null,
                              shape: BoxShape.circle,
                              border: meine == z ? Border.all(color: p.tintLine) : null),
                          child: Text(z, style: const TextStyle(fontSize: 22)),
                        ),
                      ),
                    ),
                ]),
              ),
            Container(height: 1, color: p.lineSoft),
            if (!m.widerrufen)
              eintrag(t('reply'), () {
                setState(() {
                  _bearbeitungsZiel = null;
                  _antwortZiel = m;
                });
              }),
            if (!m.widerrufen)
              eintrag(m.angeheftetAm == null ? t('pinMsg') : t('unpinMsg'),
                  () => st.hefteAn(cid, m.id, m.angeheftetAm == null)),
            if (!m.widerrufen)
              eintrag(m.sternAm == null ? t('star') : t('unstar'),
                  () => st.setzeStern(cid, m.id, m.sternAm == null)),
            if (!m.widerrufen && m.kind == MessageKind.text)
              eintrag(t('copyMsg'), () {
                Clipboard.setData(ClipboardData(text: m.text));
              }),
            if (AppState.bearbeitbar(m))
              eintrag(t('edit'), () {
                setState(() {
                  _antwortZiel = null;
                  _bearbeitungsZiel = m;
                  draftCtl.text = m.text;
                });
              }),
            if (AppState.widerrufbar(m))
              eintrag(t('deleteAll'), () => _bestaetigeWiderruf(cid, m), warnend: true),
            eintrag(t('deleteMe'), () => st.loescheFuerMich(cid, m.id), warnend: true),
            const SizedBox(height: 6),
          ])),
        );
      },
    );
  }

  Future<void> _bestaetigeWiderruf(String cid, Message m) async {
    final ja = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        title: Text(t('deleteAllAsk'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
        content: Text(t('deleteAllBody'), style: mono(size: 12.5, color: p.muted, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('deleteAll'))),
        ],
      ),
    );
    if (ja == true) await st.widerrufe(cid, m.id);
  }

  /// Das Menue an einer Unterhaltung in der Liste.
  void unterhaltungMenue(String id) {
    final kontakt = st.kontakte.where((c) => c.id == id).firstOrNull;
    final gruppe = st.gruppeZu(id);
    if (kontakt == null && gruppe == null) return;
    final k = (
      angeheftet: kontakt?.angeheftet ?? gruppe!.angeheftet,
      archiviert: kontakt?.archiviert ?? gruppe!.archiviert,
      stumm: kontakt?.stumm ?? gruppe!.stumm,
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      // HOEHER ALS DIE VORGABE, WENN NOETIG. Ohne das darf ein Blatt nur
      // 9/16 des Bildschirms hoch sein, und das Nachrichtenmenue lief im
      // Querformat unten ueber (Widget-Test, 600 px Hoehe: 18 px zu viel).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) {
        Widget eintrag(String text, VoidCallback tun) => InkWell(
              onTap: () {
                Navigator.pop(ctx);
                tun();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(text, style: mono(size: 13.5, color: p.ink)),
              ),
            );
        return SafeArea(
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            eintrag(k.angeheftet ? t('unpin') : t('pin'),
                () => st.setzeOrdnung(id, angeheftet: !k.angeheftet)),
            eintrag(k.archiviert ? t('unarchive') : t('archive'),
                () => st.setzeOrdnung(id, archiviert: !k.archiviert)),
            eintrag(k.stumm ? t('unmute') : t('mute'),
                () => st.setzeOrdnung(id, stumm: !k.stumm)),
            const SizedBox(height: 6),
          ])),
        );
      },
    );
  }

  /// Die Unterhaltungen, die die Liste gerade zeigt: angeheftete zuerst, und
  /// entweder das Archiv oder alles andere.
  List<Gruppe> get sichtbareGruppen {
    final hier = st.gruppen.where((g) => g.archiviert == _zeigeArchiv);
    return [...hier.where((g) => g.angeheftet), ...hier.where((g) => !g.angeheftet)];
  }

  Widget gruppenZeile(Gruppe g) {
    final list = st.verlaufVon(g.id);
    final letzte = list.isEmpty ? null : list.last;
    final marken = [if (g.angeheftet) t('pinnedTag'), if (g.stumm) t('mutedTag')];
    final zeit = letzte == null ? '' : zeitVon(letzte.timestamp);
    return InkWell(
      onTap: () => oeffneChat(g.id),
      onLongPress: () => unterhaltungMenue(g.id),
      onSecondaryTap: () => unterhaltungMenue(g.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
            child: Text('${g.mitglieder.length}', style: doto(size: 15, weight: FontWeight.w600, color: p.tintInk)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: doto(size: 15, weight: FontWeight.w600, color: g.aktiv ? p.ink : p.dim, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(letzte == null ? (g.aktiv ? t('groupNew') : t('groupLeft')) : auszug(letzte),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(zeit, style: mono(size: 10.5, color: p.dim)),
            if ((screen == 'chat' && chat == g.id ? 0 : st.ungelesenIn(g.id)) > 0) ...[
              const SizedBox(height: 5),
              ungelesenMarke(st.ungelesenIn(g.id)),
            ],
            if (marken.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final mk in marken) Padding(padding: const EdgeInsets.only(left: 4), child: marke(mk)),
              ]),
            ],
          ]),
        ]),
      ),
    );
  }

  Future<void> _legeGruppeAnDialog() async {
    final name = TextEditingController();
    final gewaehlt = <String>{};
    String? fehler;
    final kandidaten = st.aktiveKontakte.where((k) => !st.istNotizen(k.id)).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('groupCreate'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(controller: name, maxLength: Gruppe.maxName, enableIMEPersonalizedLearning: false,
                    style: mono(size: 13, color: p.ink),
                    decoration: InputDecoration(hintText: t('groupName'), counterText: '', hintStyle: mono(size: 13, color: p.dim))),
                const SizedBox(height: 6),
                if (kandidaten.isEmpty)
                  Text(t('groupNoContacts'), style: mono(size: 12, color: p.muted)),
                for (final k in kandidaten)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: gewaehlt.contains(k.id),
                    onChanged: (v) => neu(() => v == true ? gewaehlt.add(k.id) : gewaehlt.remove(k.id)),
                    title: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 12, color: p.ink)),
                  ),
                if (fehler != null) Text(fehler!, style: mono(size: 11.5, color: p.tintInk)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || gewaehlt.isEmpty ||
                    gewaehlt.length + 1 > Gruppe.maxMitglieder) {
                  neu(() => fehler = t('groupInvalid'));
                  return;
                }
                Navigator.pop(ctx);
                final id = await st.legeGruppeAn(name.text, gewaehlt.toList());
                if (mounted) oeffneChat(id);
              },
              child: Text(t('actCreate')),
            ),
          ],
        ),
      ),
    );
    _entsorgeNachDemSchliessen([name]);
  }

  /// Das Blatt einer Gruppe: Mitglieder, und fuer den Admin Hinzufuegen,
  /// Entfernen, Umbenennen. Austreten fuer alle.
  void gruppenBlatt(String gid) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, neu) {
        final g = st.gruppeZu(gid);
        if (g == null) return const SizedBox.shrink();
        final admin = g.admin == st.meineAdresse && g.aktiv;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                h2(g.name, size: 20),
                const SizedBox(height: 4),
                Text('${g.mitglieder.length} / ${Gruppe.maxMitglieder} ${t('groupMembers')}',
                    style: mono(size: 11, color: p.dim)),
                const SizedBox(height: 10),
                for (final m in g.mitglieder)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Identicon(m, 24, avp, 6),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            st.istNotizen(m) ? t('groupYou') : shortId(adresseFormatiert(m)),
                            style: mono(size: 12, color: p.ink)),
                      ),
                      if (m == g.admin) Text(t('groupAdmin'), style: mono(size: 10, color: p.accLight)),
                      if (admin && m != st.meineAdresse)
                        IconButton(
                          tooltip: t('groupRemove'),
                          onPressed: () async {
                            await st.entferneAusGruppe(gid, m);
                            neu(() {});
                          },
                          icon: Text('×', style: TextStyle(color: p.muted, fontSize: 16)),
                        ),
                    ]),
                  ),
                const SizedBox(height: 10),
                if (admin) ...[
                  outlineBtn(t('groupAdd'), () async {
                    Navigator.pop(ctx);
                    await _fuegeMitgliederHinzuDialog(gid);
                  }, padding: const EdgeInsets.all(10)),
                  const SizedBox(height: 6),
                  outlineBtn(t('groupRename'), () async {
                    Navigator.pop(ctx);
                    await _benenneGruppeDialog(gid);
                  }, accent: false, padding: const EdgeInsets.all(10)),
                  const SizedBox(height: 6),
                ],
                if (g.aktiv)
                  outlineBtn(t('groupLeave'), () async {
                    Navigator.pop(ctx);
                    await st.verlasseGruppe(gid);
                  }, accent: false, padding: const EdgeInsets.all(10)),
              ]),
            ),
          ),
        );
      }),
    );
  }

  Future<void> _fuegeMitgliederHinzuDialog(String gid) async {
    final g = st.gruppeZu(gid);
    if (g == null) return;
    final gewaehlt = <String>{};
    final kandidaten = st.aktiveKontakte
        .where((k) => !st.istNotizen(k.id) && !g.mitglieder.contains(k.id))
        .toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('groupAdd'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (kandidaten.isEmpty)
                  Text(t('groupNoContacts'), style: mono(size: 12, color: p.muted)),
                for (final k in kandidaten)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: gewaehlt.contains(k.id),
                    onChanged: (v) => neu(() => v == true ? gewaehlt.add(k.id) : gewaehlt.remove(k.id)),
                    title: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 12, color: p.ink)),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (gewaehlt.isNotEmpty) await st.fuegeZuGruppeHinzu(gid, gewaehlt.toList());
              },
              child: Text(t('add')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _benenneGruppeDialog(String gid) async {
    final name = TextEditingController(text: st.gruppeZu(gid)?.name ?? '');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        title: Text(t('groupRename'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
        content: TextField(controller: name, maxLength: Gruppe.maxName, enableIMEPersonalizedLearning: false,
            style: mono(size: 13, color: p.ink)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (name.text.trim().isNotEmpty) await st.benenneGruppe(gid, name.text);
            },
            child: Text(t('actSave')),
          ),
        ],
      ),
    );
    _entsorgeNachDemSchliessen([name]);
  }

  // ═══════════════════════════════════════════════════════ Filter der Liste
  //
  // Alle · Ungelesen · Gruppen · ★. Nur eine Sicht, nichts wird verschoben —
  // und "ungelesen" folgt derselben Regel wie der Punkt an der Zeile, damit
  // Filter und Punkt sich nie widersprechen.

  String _filter = 'alle';

  bool _passt(String id, bool gruppe) => switch (_filter) {
        'gruppen' => gruppe,
        'ungelesen' => st.ungelesenIn(id) > 0,
        _ => true,
      };

  /// Fragt nach k von n, zerlegt die Woerter und zeigt die Teile.
  Future<void> _erzeugeTeile() async {
    var wahl = '3/5';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          title: Text(t('trustTitle')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('trustHow'), style: mono(size: 12, color: p.muted, height: 1.5)),
            const SizedBox(height: 12),
            segmented(['2/3', '3/5', '4/7'], ['2 / 3', '3 / 5', '4 / 7'], wahl, (v) => neu(() => wahl = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('actCreate'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final k = int.parse(wahl.split('/')[0]);
    final n = int.parse(wahl.split('/')[1]);
    final List<Teil> teile;
    try {
      teile = teileWoerter(await st.phraseAusEinstellungen(), schwelle: k, anzahl: n);
    } catch (e) {
      _hinweis('$e');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('trustSheetTitle').replaceFirst('{k}', '$k').replaceFirst('{n}', '$n'),
                style: mono(size: 14, weight: FontWeight.w600, color: p.ink, height: 1.4)),
            const SizedBox(height: 6),
            Text(t('trustWarn').replaceFirst('{k}', '$k'),
                style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
            const SizedBox(height: 12),
            for (var i = 0; i < teile.length; i++)
              Container(
                key: ValueKey('teil-$i'),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${t('trustPart')} ${i + 1} / $n',
                      style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1)),
                  const SizedBox(height: 4),
                  SelectableText(teile[i].alsText(), style: mono(size: 11, color: p.ink, height: 1.5)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: outlineBtn(t('copy'), () {
                      Clipboard.setData(ClipboardData(text: teile[i].alsText()));
                      _hinweis(t('copied'));
                    }, padding: const EdgeInsets.all(8))),
                    const SizedBox(width: 8),
                    Expanded(child: outlineBtn(t('trustSend'), () => _sendeTeil(teile[i]),
                        accent: false, padding: const EdgeInsets.all(8))),
                  ]),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  /// Schickt einen Teil verschluesselt an einen Kontakt.
  Future<void> _sendeTeil(Teil teil) async {
    final kandidaten = st.aktiveKontakte.where((k) => !st.istNotizen(k.id)).toList();
    if (kandidaten.isEmpty) {
      _hinweis(t('trustNoContacts'));
      return;
    }
    final ziel = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t('trustSend')),
        children: [
          for (final k in kandidaten)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, k.id),
              child: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 13, color: p.ink)),
            ),
        ],
      ),
    );
    if (ziel == null) return;
    await st.senden(ziel, '${t('trustMsg')}\n\n${teil.alsText()}');
    _hinweis(t('trustSent'));
  }

  String _uhr(int minuten) =>
      '${(minuten ~/ 60).toString().padLeft(2, '0')}:${(minuten % 60).toString().padLeft(2, '0')}';

  Future<void> _waehleRuhe(bool anfang) async {
    final jetzt = anfang ? st.einstellungen.ruheVon : st.einstellungen.ruheBis;
    final zeit = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: jetzt ~/ 60, minute: jetzt % 60),
        helpText: anfang ? t('quietFrom') : t('quietTo'));
    if (zeit == null) return;
    final m = zeit.hour * 60 + zeit.minute;
    await st.setzeEinstellungen(anfang
        ? st.einstellungen.copyWith(ruheVon: m)
        : st.einstellungen.copyWith(ruheBis: m));
  }

  /// Die Zahl der ungelesenen Nachrichten als Pille — leer, wenn keine.
  Widget ungelesenMarke(int zahl) => zahl <= 0
      ? const SizedBox(height: 16)
      : Container(
          key: const ValueKey('ungelesen-zahl'),
          constraints: const BoxConstraints(minWidth: 18),
          height: 18,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(99)),
          child: Text(zahl > 99 ? '99+' : '$zahl',
              style: mono(size: 9.5, weight: FontWeight.w700, color: p.onAcc, height: 1)),
        );

  Widget filterLeiste() {
    const filter = ['alle', 'ungelesen', 'gruppen', 'stern'];
    final namen = {
      'alle': t('filterAll'),
      'ungelesen': t('filterUnread'),
      'gruppen': t('filterGroups'),
      'stern': '★',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 4, 17, 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final f in filter)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                button: true,
                selected: _filter == f,
                label: f == 'stern' ? t('filterStarred') : namen[f],
                excludeSemantics: true,
                child: GestureDetector(
                  key: ValueKey('filter-$f'),
                  onTap: () {
                    setState(() => _filter = f);
                    if (f == 'stern') unawaited(st.ladeSterne());
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: _filter == f ? p.tint : Colors.transparent,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: _filter == f ? p.tintLine : p.line),
                    ),
                    child: Text(namen[f]!.toUpperCase(),
                        style: mono(size: 9.5, weight: FontWeight.w600, spacing: 0.9,
                            color: _filter == f ? p.tintInk : p.muted)),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  List<Contact> get sichtbareKontakte {
    final hier = st.aktiveKontakte.where((c) => c.archiviert == _zeigeArchiv);
    return [...hier.where((c) => c.angeheftet), ...hier.where((c) => !c.angeheftet)];
  }

  /// Suchfeld und Treffer. Ohne Suchtext steht hier nur das Feld.
  Widget suchFeld() => Container(
        margin: const EdgeInsets.fromLTRB(17, 8, 17, 4),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: TextField(
          controller: suchCtl,
          enableIMEPersonalizedLearning: false,
          onChanged: st.suche,
          style: mono(size: 13, color: p.ink),
          cursorColor: p.accent,
          decoration: InputDecoration.collapsed(
              hintText: t('search'), hintStyle: mono(size: 13, color: p.dim)),
        ),
      );

  /// Nachrichten als Trefferzeilen — fuer die Suche und fuer die Sterne.
  Widget suchTreffer({List<Message>? liste, String? leer}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if ((liste ?? st.suchTreffer).isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
            child: Text(leer ?? t('noResults'), style: mono(size: 12, color: p.dim, height: 1.5)),
          ),
        for (final m in liste ?? st.suchTreffer)
          InkWell(
            onTap: () {
              suchCtl.clear();
              st.suche('');
              oeffneChat(m.chatId);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              child: Row(children: [
                // WIE IN DER CHATLISTE: eine Gruppe mit Namen und Mitgliederzahl,
                // die Notizen als Notizen. Vorher stand hier fuer jede
                // Unterhaltung die rohe Kennung, bei Gruppen also "G-XL…" statt
                // des Namens — und der Text roh, mit Sternchen und dem Spoiler
                // im Klartext (Emulatorlauf 25.09.2026).
                if (st.gruppeZu(m.chatId) case final g?)
                  Container(
                    width: 32, height: 32, alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                    child: Text('${g.mitglieder.length}', style: doto(size: 13, weight: FontWeight.w600, color: p.tintInk)),
                  )
                else
                  Identicon(m.chatId, 32, avp, 8),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        st.gruppeZu(m.chatId)?.name ??
                            (st.istNotizen(m.chatId) ? t('notes') : shortId(adresseFormatiert(m.chatId))),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: doto(size: 13, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                    const SizedBox(height: 2),
                    Text(auszug(m), maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: mono(size: 12, color: p.muted)),
                  ]),
                ),
                const SizedBox(width: 8),
                Text(zeitVon(m.timestamp), style: mono(size: 10.5, color: p.dim)),
              ]),
            ),
          ),
      ]);

  /// Richtet einen Faktor ein oder entfernt ihn.
  ///
  /// Bis zum 25.07.2026 stand hier eine Attrappe: eine Einrichtungs-Animation,
  /// danach ein Haken, dahinter nichts. Jetzt liegt darunter ein
  /// Schluesselfach — die Entropie ist ohne den Faktor wirklich nicht mehr zu
  /// haben, auch nicht mit Root, auch nicht mit der Datei in der Hand.
  Future<void> methodAct(String key) async {
    final art = zeilenArt[key];
    if (art == null || laeuftZeile != null) return;

    final vorhanden = st.sichtbareFaktoren.where((s) => s.kind == art).toList();
    if (vorhanden.isNotEmpty) {
      await _entferneFaktor(key, vorhanden.first.id);
      return;
    }

    switch (art) {
      case UnlockFactorKind.hardwareKey:
        await _richteStickEin();
      case UnlockFactorKind.passphrase:
        await _richtePasswortEin();
      case UnlockFactorKind.biometric:
        await _richteKeystoreEin(key, art, st.fuegeBiometrieHinzu);
      case UnlockFactorKind.deviceCredential:
        await _richteKeystoreEin(key, art, st.fuegeGeraetePinHinzu);
    }
  }

  /// Richtet ein Fach im gesicherten Bereich des Geraets ein.
  ///
  /// BIS ZUM 25.07.2026 PASSIERTE HIER BEIM ANTIPPEN SICHTBAR NICHTS. Zwei
  /// Gruende kamen zusammen: der Anmeldedialog erschien nicht (dazu
  /// SchluesselfachKanal.kt), und wenn doch ein Fehler kam, landete er in
  /// einer Variablen, die dieser Bildschirm gar nicht anzeigte.
  ///
  /// Deshalb jetzt drei Dinge: vorher fragen, ob es ueberhaupt gehen KANN;
  /// waehrenddessen zeigen, dass etwas laeuft; und jeden Fehler sichtbar
  /// machen.
  Future<void> _richteKeystoreEin(
      String zeile, UnlockFactorKind art, Future<void> Function() anlegen) async {
    setState(() {
      lockFehler = null;
      laeuftZeile = zeile;
    });
    try {
      // Erst fragen, dann tippen lassen. Ohne diese Frage wartet der Nutzer
      // auf einen Dialog, den das Geraet gar nicht zeigen kann.
      final stand = await st.geraetestand(art);
      if (!stand.ok) {
        if (mounted) {
          setState(() => lockFehler = stand.grund ?? t('lockNoScreenLockBody'));
        }
        return;
      }
      await anlegen();
    } on AnmeldungFehlgeschlagen catch (e) {
      // Ein Abbruch ist keine Panne, sondern eine Entscheidung — dafuer keine
      // rote Meldung.
      if (mounted && !e.abgebrochen) setState(() => lockFehler = e.grund);
    } on GeraetKannNicht catch (e) {
      if (mounted) setState(() => lockFehler = e.grund);
    } on LockUnavailableException catch (e) {
      if (mounted) setState(() => lockFehler = e.grund);
    } on UnlockFailedException {
      if (mounted) setState(() => lockFehler = t('unlockFailed'));
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    } finally {
      if (mounted) setState(() => laeuftZeile = null);
    }
  }

  /// Stellt um, wie oft im Hintergrund nach Nachrichten gesehen wird.
  Future<void> _setzeEmpfangsTakt(int minuten) async {
    setState(() => lockFehler = null);
    try {
      await st.setzeEmpfangsTakt(EmpfangsTakt.vonMinuten(minuten));
    } on PushException catch (e) {
      // KEIN VERTEILER: statt einer Fehlermeldung die Anleitung. Der Nutzer
      // hat nichts falsch gemacht — ihm fehlt eine App, und er kann nicht
      // wissen welche.
      if (!mounted) return;
      if (e.grund == PushHindernis.keinVerteiler) {
        // Zurueckstellen: eine Stufe, die nicht laeuft, darf nicht als
        // ausgewaehlt dastehen.
        await st.setzeEmpfangsTakt(EmpfangsTakt.aus);
        if (mounted) setState(() => enroll = 'pushHilfe');
      } else {
        setState(() => lockFehler = t('pushFailed'));
      }
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Was die gewaehlte Einstellung praktisch bedeutet.
  ///
  /// Steht als Fliesstext unter der Auswahl, weil die Unterschiede nicht
  /// selbsterklaerend sind: "alle 15 Minuten" klingt haeufiger als es sich
  /// anfuehlt, und "staendig" klingt teurer als es ist.
  String _empfangErklaerung() => switch (st.empfangsTakt) {
        EmpfangsTakt.aus => t('bgOffNote'),
        EmpfangsTakt.staendig => t('bgLiveNote'),
        EmpfangsTakt.viertelstunde => t('bg15Note'),
        EmpfangsTakt.stunde => t('bg60Note'),
        EmpfangsTakt.vierStunden => t('bg240Note'),
        EmpfangsTakt.push => t('bgPushNote'),
      };

  /// Stellt um, wann die App sich von selbst wieder abschliesst.
  Future<void> _setzeSperrfrist(int sekunden) async {
    try {
      await st.setzeSperrfrist(sekunden);
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Nimmt einen Faktor wieder heraus.
  ///
  /// Verlangt einen offenen Tresor. Sonst waere die Sperre einen Fingertipp
  /// weit — jemand mit dem entsperrten Telefon koennte sie einfach abschalten.
  Future<void> _entferneFaktor(String zeile, String slotId) async {
    setState(() {
      lockFehler = null;
      laeuftZeile = zeile;
    });
    try {
      await st.entferneFaktor(slotId);
    } on StateError catch (e) {
      // Das letzte Fach: dahinter steckt kein Fehler, sondern die Regel, dass
      // immer ein Weg hinein bleiben muss.
      if (mounted) setState(() => lockFehler = e.message);
    } on AnmeldungFehlgeschlagen catch (e) {
      if (mounted && !e.abgebrochen) setState(() => lockFehler = e.grund);
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    } finally {
      if (mounted) setState(() => laeuftZeile = null);
    }
  }

  /// Oeffnet das Blatt, auf dem ein App-Passwort eingerichtet wird.
  Future<void> _richtePasswortEin() async {
    pwCtl.clear();
    pwCtl2.clear();
    setState(() {
      enroll = 'pw';
      lockFehler = null;
    });
  }

  /// Legt das Passwort-Fach an.
  Future<void> _passwortAnlegen() async {
    final pw = pwCtl.text;
    if (pw != pwCtl2.text) {
      setState(() => lockFehler = t('pwMismatch'));
      return;
    }
    setState(() => lockFehler = null);
    try {
      await st.fuegePasswortHinzu(pw);
      pwCtl.clear();
      pwCtl2.clear();
      if (mounted) setState(() => enroll = null);
    } on WeakPassphraseException catch (e) {
      // Die Zahl mitzugeben ist der Unterschied zwischen "zu schwach" und
      // "zu schwach, und zwar um so viel".
      if (mounted) {
        setState(() => lockFehler = t('pwWeak')
            .replaceFirst('{ist}', '${e.geschaetzteBits}')
            .replaceFirst('{soll}', '${e.verlangteBits}'));
      }
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Oeffnet das Blatt, auf dem der Stick eingerichtet wird.
  Future<void> _richteStickEin() async {
    stickPinCtl.clear();
    setState(() {
      enroll = 'hw';
      lockFehler = null;
      stickSchritt = null;
    });
  }

  /// Legt den Zugang auf dem Stick an und verschliesst die Identitaet damit.
  Future<void> _stickAnlegen() async {
    setState(() {
      stickSchritt = t('stickWorking');
      lockFehler = null;
    });
    try {
      await st.fuegeStickHinzu(
        weg: stickWeg,
        pin: stickPinCtl.text.isEmpty ? null : stickPinCtl.text,
      );
      stickPinCtl.clear();
      if (mounted) setState(() { enroll = null; stickSchritt = null; });
    } catch (e) {
      if (mounted) {
        setState(() { lockFehler = _stickMeldung(e); stickSchritt = null; });
      }
    }
  }

  /// Uebersetzt einen Fehler in etwas, mit dem der Nutzer etwas anfangen kann.
  ///
  /// BEIM STICK IST DAS WICHTIGER ALS SONST: er zaehlt Fehlversuche selbst mit
  /// und sperrt sich nach acht endgueltig. Eine Meldung im Stil von "Fehler
  /// 0x31" laesst den Nutzer weiterraten, bis der Stick unbrauchbar ist.
  String _stickMeldung(Object e) => switch (e) {
        PinFalschException(:final verbleibend) => verbleibend == null
            ? t('stickPinWrong')
            : t('stickPinWrongLeft').replaceFirst('{n}', '$verbleibend'),
        StickPinNoetigException() => t('stickPinNeeded'),
        StickUngeeignetException(:final grund) => grund,
        KeinStickException(:final grund) => grund,
        CtapException(:final bedeutung) => bedeutung,
        _ => '$e',
      };

  /// Die eigene Adresse, wie der Entwurf sie zeigt: Vierergruppen mit
  /// Bindestrichen. Solange noch keine Identitaet da ist, bleibt es leer.
  String get meineAdresseAnzeige =>
      st.meineAdresse.isEmpty ? '' : adresseFormatiert(st.meineAdresse);

  void copyId() {
    if (st.meineAdresse.isEmpty) return;
    // MIT Bindestrichen, genau wie die App sie ueberall zeigt.
    //
    // Bis zum 25.07.2026 ging die rohe Adresse in die Zwischenablage. Das war
    // gut gemeint — sie sollte anderswo ohne Nacharbeit funktionieren — hatte
    // aber eine Folge, die einen Tester gekostet hat: das Beispiel im
    // Eingabefeld zeigte Striche, das Eingefuegte hatte keine, und es sah aus,
    // als waere beim Kopieren etwas schiefgegangen.
    //
    // Die Striche schaden nirgends: jedes Eingabefeld dieser App entfernt sie
    // wieder, und ueber 56 Zeichen hinweg machen sie den Unterschied zwischen
    // lesbar und nicht lesbar. Im QR-Code steht weiterhin die rohe Adresse —
    // dort zaehlt Dichte, nicht Lesbarkeit.
    Clipboard.setData(ClipboardData(text: adresseFormatiert(st.meineAdresse)));
    setState(() => copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () { if (mounted) setState(() => copied = false); });
  }

  /// Liest eine Adresse per Kamera ein.
  ///
  /// Der sicherste Weg, eine Adresse auszutauschen: ein QR-Code im
  /// persoenlichen Gespraech geht durch keinen Kanal, den jemand veraendern
  /// koennte. Bei 56 Zeichen ist Abtippen ausserdem fehleranfaellig.
  Future<void> _scanneQr() async {
    final adresse = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          titel: t('scan'),
          hinweis: t('scanHint'),
          keineKamera: t('scanNoCamera'),
          abbrechen: t('cancel'),
          // BEIDE STELLEN MUESSEN NORMALISIEREN, und beide auf dieselbe Art.
          //
          // Hier stand `RegExp(r'[s-]')` — eine Zeichenklasse aus 's' und '-',
          // nicht "Leerraum oder Strich". Aus jeder gescannten Adresse fiel
          // damit der Buchstabe s heraus, und Adressen sind Base32 in
          // Kleinbuchstaben: s kommt in fast jeder vor. Die Pruefsumme
          // scheiterte, der Leser nahm den Code NIE an und suchte weiter. Von
          // aussen sah es aus, als koenne die App keine QR-Codes lesen.
          //
          // Unten in dieser Methode war derselbe Fehler schon behoben — hier
          // oben nicht, und HIER faellt die Entscheidung. Deshalb steht jetzt
          // an beiden Stellen dieselbe Funktion statt einer zweiten
          // handgeschriebenen Fassung davon.
          istGueltig: (s) => st.adresseGueltig(BitdmAddress.normalize(s)),
        ),
      ),
    );
    if (adresse == null || !mounted) return;
    setState(() => addCtl.text = adresseFormatiert(BitdmAddress.normalize(adresse)));
  }

  Future<void> sendReq() async {
    final eingabe = addCtl.text.replaceAll(RegExp(r'[\s\-]'), '');
    if (eingabe.isEmpty) return;
    final ok = await st.kontaktHinzufuegen(eingabe);
    if (!mounted) return;
    setState(() => reqSent = ok);
  }

  Future<void> acceptReq(String id) async {
    await Benachrichtigungen.instanz.frageErlaubnis();
    await st.anfrageAnnehmen(id);
    if (!mounted) return;
    await st.unterhaltungOeffnen(id);
    if (!mounted) return;
    setState(() { screen = 'chat'; chat = id; });
  }

  Future<void> oeffneChat(String id) async {
    setState(() { screen = 'chat'; chat = id; sheet = false; });
    await st.unterhaltungOeffnen(id);
  }

  /// Loescht Identitaet, Schluessel und alle Nachrichten — wirklich.
  ///
  /// Bis zum 25.07.2026 setzte diese Funktion nur Anzeigewerte zurueck. Bei
  /// einem Entwurf war das folgenlos; jetzt liegen echte Nachrichten und eine
  /// echte Identitaet dahinter, und ein Knopf, der "alles geloescht" behauptet
  /// und es nicht tut, waere in dieser App der schlimmste denkbare Fehler.
  Future<void> doWipe() async {
    setState(() { panic = false; screen = 'creating'; });
    await st.allesLoeschen();
    if (!mounted) return;
    setState(() {
      final l = lang;
      screen = 'onboard'; chat = null; reqSent = false; sheet = false;
      wiped = true; copied = false;
      enroll = null;
      lang = l;
      draftCtl.clear(); addCtl.clear(); codeCtl.clear();
    });
  }

  // ---- small UI atoms ----
  Widget h2(String s, {double size = 26}) =>
      Text(s.toUpperCase(), style: doto(size: size, weight: FontWeight.w700, color: p.ink, spacing: 0.4, height: 1.1));

  Widget label6(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s.toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.8)),
      );

  /// [onTap] darf null sein: dann ist der Knopf sichtbar, aber nicht bedienbar
  /// — und behaelt den Standardzeiger, statt eine Hand zu zeigen, die nichts
  /// verspricht. [fuellung] und [rahmen] sind fuer die Faelle, in denen ein
  /// Knopf einen Hintergrund traegt (der Start des Verbindungstests) — dort
  /// gehoeren Fuellung und Rahmen zusammen, `accent` allein trifft es nicht.
  Widget outlineBtn(String labelTxt, VoidCallback? onTap,
      {bool accent = true, double fontSize = 12, EdgeInsets? padding, FontWeight weight = FontWeight.w600, Color? textColor, Color? fuellung, Color? rahmen}) {
    // RUECKMELDUNG OHNE LAYOUT: nur Rahmenfarbe und Fuellung wechseln, nie
    // Rahmenbreite oder Abstand. Ein Fokusring aussen herum haette jeden Knopf
    // im Fenster um 3 px verschoben — auch auf den vier fertigen
    // Schreibtisch-Bildschirmen, die outlineBtn mitbenutzen.
    //
    // p.accHover lag seit dem Entwurf in beiden Paletten und wurde nirgends
    // benutzt (data.dart:58/80, nachgesehen am 30.07.2026). Die Entscheidung
    // war also getroffen, nur nie angeschlossen.
    return _Bedienbar(
      imFenster: _imFenster,
      onTap: onTap,
      bau: (ueber, fokus) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: padding ?? const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fokus ? p.wash : fuellung,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: ueber || fokus
                    ? p.accHover
                    : (rahmen ?? (accent ? p.accent : p.line))),
          ),
          child: Text(labelTxt.toUpperCase(),
              style: mono(size: fontSize, weight: weight, color: textColor ?? (accent ? p.ink : p.muted), spacing: fontSize * 0.12)),
        ),
      ),
    );
  }

  /// Ein kleiner runder Knopf. SICHTBAR 30 dp, ANTIPPBAR 48.
  ///
  /// Die beiden Masse gehoeren nicht zusammen: 30 dp sieht richtig aus, 48 dp
  /// trifft man. Wer den Knopf auf 48 aufblaest, damit er sich treffen laesst,
  /// bekommt eine Oberflaeche aus lauter Klotzen; wer ihn bei 30 laesst, wird
  /// danebengetippt — nicht von ungeschickten Leuten, sondern von allen, nur
  /// unterschiedlich oft.
  Widget iconBtn(String glyph, VoidCallback onTap, {Color? color, double fontSize = 15}) =>
      _Bedienbar(
        imFenster: _imFenster,
        onTap: onTap,
        bau: (ueber, fokus) => Masse.trefferflaeche(
          onTap: onTap,
          child: Container(
            width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: fokus ? p.wash : null,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: ueber || fokus ? p.accHover : p.line)),
            child: Text(glyph, style: TextStyle(color: ueber ? p.accHover : (color ?? p.muted), fontSize: fontSize, height: 1)),
          ),
        ),
      );

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

  /// Die drei Reiter der unteren Leiste, in ihrer Reihenfolge.
  ///
  /// Steht hier und nicht nur in buildNav, weil das Wischen dieselbe
  /// Reihenfolge braucht. Zwei Listen waeren zwei Gelegenheiten, sie
  /// auseinanderlaufen zu lassen.
  static const List<String> reiter = ['chats', 'id', 'set'];

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
    if (!st.bereit) return const SizedBox.shrink();
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

  // ---- ONBOARD ----
  Widget onboardScreen() {
    return LayoutBuilder(builder: (ctx, con) {
      // IM FENSTER OBEN ANSCHLAGEN. Der Inhalt ist etwa 700 px hoch; in dem
      // 984x1040 grossen Fenster vom 30.07.2026 blieben durch die Zentrierung
      // oben und unten je ueber 160 px tote Flaeche, die die Seitenlinien der
      // Spalte als fast leeren Kasten mitzeichneten.
      //
      // Damit fallen ConstrainedBox und IntrinsicHeight im Fenster weg: sie
      // sind nur fuer die Zentrierung auf niedrigen Telefonen da, und
      // IntrinsicHeight kostet bei jedem Aufbau einen zweiten Layout-Durchgang
      // ueber den ganzen Teilbaum.
      final Widget inhalt = Padding(
              // 40 px Kopfabstand im Fenster, gemessen an 1040 px Fensterhoehe:
              // weniger klebte das Zeichen an der Fensterkante, mehr fing an,
              // wieder wie Zentrierung auszusehen. Die 22 sind der Rand der
              // Abfolgen (Masse.rand).
              padding: EdgeInsets.fromLTRB(22, _imFenster ? 40 : 22, 22, 22),
              child: Column(
                mainAxisAlignment: _imFenster
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46, height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                    child: Text('B', style: doto(size: 22, weight: FontWeight.w900, color: p.accLight)),
                  ),
                  const SizedBox(height: 16),
                  // DIE UEBERSCHRIFT WAECHST NICHT MIT. [_schriftFaktor] ist
                  // fuer Lesetext gedacht; 36 mal 1.15 waeren 41 pt und
                  // brachen "SECURE MESSAGING" in der 560er Spalte um. 28 mal
                  // 1.15 sind 32 pt — im Fenster also bewusst KLEINER als auf
                  // dem Telefon, wo die Ueberschrift den ganzen Bildschirm
                  // traegt (30.07.2026).
                  Text('${t('h1a')}\n${t('h1b')}', style: doto(size: _imFenster ? 28 : 36, weight: FontWeight.w800, color: p.ink, height: 1.05, spacing: 0.4)),
                  const SizedBox(height: 10),
                  Text(t('intro'), style: mono(size: 13.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
                  const SizedBox(height: 16),
                  bullet(t('b1')), bullet(t('b2')), bullet(t('b3')),
                  if (wiped) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                      child: Text(t('wiped'), style: mono(size: 12, color: p.tintInk)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _knopfBreite(outlineBtn(t('create'), doCreate, padding: const EdgeInsets.all(15), fontSize: 13)),
                  const SizedBox(height: 8),
                  Text(t('createNote'), style: mono(size: 11, color: p.dim)),

                  // DER WEG ZURUECK. Er fehlte bis zum 25.07.2026 ganz —
                  // waehrend der Bildschirm mit den zwoelf Woertern sagte,
                  // sie seien "der einzige Weg zurueck, wenn dieses Telefon
                  // verloren ist". Wer sie brav aufgeschrieben hatte, stand
                  // auf einem neuen Telefon vor einer App, die sie nirgends
                  // annahm.
                  //
                  // Leiser gesetzt als das Anlegen: die meisten kommen hier
                  // zum ersten Mal an. Aber sichtbar, denn wer ihn braucht,
                  // braucht ihn dringend.
                  const SizedBox(height: 22),
                  Container(height: 1, color: p.lineSoft),
                  const SizedBox(height: 18),
                  // EIN VERWEIS MUSS SICH WIE EINER VERHALTEN. Bisher war das
                  // ein Text in Akzentfarbe, ueber dem der Zeiger ein
                  // Text-Cursor blieb — am Schreibtisch das Zeichen fuer "hier
                  // ist nichts". Und das ist der Weg, den nach einem
                  // Geraeteverlust jemand dringend braucht.
                  //
                  // Unterstrichen wird nur beim Ueberfahren und im Fokus:
                  // dauerhaft unterstrichen saehe er auf dem Telefon anders aus
                  // als heute, und dort ist er unstrittig.
                  _restoreVerweis(),
                  const SizedBox(height: 6),
                  Text(t('restoreLinkSub'), style: mono(size: 11, color: p.dim, height: 1.5)),
                ],
              ),
      );

      return SingleChildScrollView(
        child: _imFenster
            ? inhalt
            : ConstrainedBox(
                constraints: BoxConstraints(minHeight: con.maxHeight),
                child: IntrinsicHeight(child: inhalt),
              ),
      );
    });
  }

  /// Der Weg zur Wiederherstellung auf 'onboard'.
  Widget _restoreVerweis() {
    void hin() {
      phraseCtl.clear();
      setState(() { screen = 'restore'; restoreFehler = null; });
    }

    return _Bedienbar(
      imFenster: _imFenster,
      onTap: hin,
      bau: (ueber, fokus) => GestureDetector(
        onTap: hin,
        child: Text(
          t('restoreLink').toUpperCase(),
          style: mono(
            size: 11,
            weight: FontWeight.w600,
            color: ueber || fokus ? p.accHover : p.accLight,
            spacing: 1.2,
          ).copyWith(
            decoration:
                ueber || fokus ? TextDecoration.underline : TextDecoration.none,
            decorationColor: p.accHover,
          ),
        ),
      ),
    );
  }

  Widget bullet(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('—', style: TextStyle(color: p.accent, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(child: Text(s, style: mono(size: 12, color: p.dim))),
        ]),
      );

  /// Wartet darauf, dass ein Faktor das Fach oeffnet.
  ///
  /// Angeboten wird nur, was auch eingerichtet ist. Ein Knopf fuer einen
  /// Faktor, den es nicht gibt, waere hier besonders bitter: der Nutzer haelt
  /// einen Stick an das Telefon und wartet auf etwas, das nie kommt.
  ///
  /// Fingerabdruck und PIN fragt die App NICHT selbst ab und bekommt sie nie
  /// zu sehen — sie versucht nur, den Fachschluessel zu lesen, und die Abfrage
  /// zeigt das System.
  Widget gesperrtScreen() {
    final bio = st.hatFaktor(UnlockFactorKind.biometric);
    final pin = st.hatFaktor(UnlockFactorKind.deviceCredential);
    final stick = st.hatFaktor(UnlockFactorKind.hardwareKey);
    final pw = st.hatFaktor(UnlockFactorKind.passphrase);

    // Der erste Knopf traegt die Betonung. Welcher das ist, haengt davon ab,
    // was eingerichtet ist — ein blasser einziger Knopf saehe aus, als waere
    // er nicht gemeint.
    var ersterHervorgehoben = true;
    Widget knopf(String text, VoidCallback tun) {
      final hervor = ersterHervorgehoben;
      ersterHervorgehoben = false;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: outlineBtn(text, tun,
            accent: hervor,
            padding: const EdgeInsets.all(13),
            weight: hervor ? FontWeight.w500 : FontWeight.w400),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          h2(t("locked")),
          const SizedBox(height: 8),
          Text(t("lockedSub"),
              style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
          const SizedBox(height: 22),

          if (lockFehler != null) ...[
            _hinweisKasten(lockFehler!),
            const SizedBox(height: 14),
          ],

          if (bio) knopf(t('unlockBio'), _entsperreMitBiometrie),
          if (pin) knopf(t('unlockDevPin'), _entsperreMitGeraetePin),
          if (pw) knopf(t('unlockPw'), _fragePasswort),
          if (stick) ...[
            knopf(t('unlockStick'), _entsperreMitStick),
            Row(children: [
              Expanded(child: _wegKnopf(StickWeg.usb, t('stickUsb'))),
              const SizedBox(width: 8),
              Expanded(child: _wegKnopf(StickWeg.nfc, t('stickNfc'))),
            ]),
          ],
          if (!bio && !pin && !stick && !pw)
            // Kann nur passieren, wenn die Fachdatei kaputt ist. Ohne diesen
            // Hinweis stuende der Nutzer vor einem Bildschirm ohne Knopf.
            Text(t('lockedNoFactor'),
                style: mono(size: 12, color: p.dim, height: 1.6)),
        ],
      ),
    );
  }

  Future<void> _entsperreMitBiometrie() =>
      _versucheEntsperren(st.entsperreMitBiometrie);

  Future<void> _entsperreMitGeraetePin() =>
      _versucheEntsperren(st.entsperreMitGeraetePin);

  /// Fragt das App-Passwort ab und versucht damit zu oeffnen.
  Future<void> _fragePasswort() async {
    pwCtl.clear();
    final ok = await _frageGeheimnis(
        titel: t('unlockPw'), ctl: pwCtl, hinweis: t('pwUnlockHint'));
    if (ok != true || !mounted) return;
    final eingabe = pwCtl.text;
    pwCtl.clear();
    await _versucheEntsperren(() => st.entsperreMitPasswort(eingabe));
  }

  Future<void> _versucheEntsperren(Future<bool> Function() tun) async {
    setState(() => lockFehler = null);
    try {
      final ok = await tun();
      if (!ok && mounted) setState(() => lockFehler = t('unlockFailed'));
    } on UnlockFailedException {
      // ABSICHTLICH OHNE GRUND: falsches Passwort, abgebrochene Anmeldung und
      // beschaedigtes Fach sollen von aussen gleich aussehen. Ein Fehler, der
      // sie unterscheidet, ist ein Hinweis fuer jeden, der Passwoerter
      // durchprobiert. Beim Stick ist es umgekehrt — siehe _stickMeldung.
      if (mounted) setState(() => lockFehler = t('unlockFailed'));
    } catch (e) {
      if (mounted) setState(() => lockFehler = _stickMeldung(e));
    }
  }

  /// Entsperrt mit dem Stick, und fragt nach der PIN, wenn er eine verlangt.
  Future<void> _entsperreMitStick() async {
    setState(() => lockFehler = null);
    try {
      await st.entsperreMitStick(
          weg: stickWeg,
          pin: stickPinCtl.text.isEmpty ? null : stickPinCtl.text);
    } on StickPinNoetigException {
      if (mounted) await _fragePin();
    } catch (e) {
      if (mounted) setState(() => lockFehler = _stickMeldung(e));
    }
  }

  /// Fragt ein Geheimnis ab, ohne es irgendwo abzulegen.
  Future<bool?> _frageGeheimnis({
    required String titel,
    required TextEditingController ctl,
    required String hinweis,
    bool nurZahlen = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: p.line)),
        title: Text(titel, style: doto(size: 17, color: p.ink)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctl,
            obscureText: true,
            autofocus: true,
            keyboardType: nurZahlen ? TextInputType.number : null,
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
            style: mono(size: 15, color: p.ink, spacing: 2),
            decoration: InputDecoration(
              hintText: '••••••',
              hintStyle: mono(size: 15, color: p.dim, spacing: 2),
            ),
          ),
          const SizedBox(height: 10),
          Text(hinweis, style: mono(size: 11, color: p.dim, height: 1.5)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('cancel'), style: mono(size: 12, color: p.dim))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child:
                  Text(t('unlock'), style: mono(size: 12, color: p.accLight))),
        ],
      ),
    );
  }

  /// Fragt die PIN DES STICKS ab — nicht die des Telefons.
  ///
  /// Sie verlaesst das Telefon nie im Klartext: uebertragen werden die ersten
  /// 16 Byte ihres SHA-256, und auch die nur verschluesselt.
  Future<void> _fragePin() async {
    stickPinCtl.clear();
    final ok = await _frageGeheimnis(
        titel: t('stickPinLabel'),
        ctl: stickPinCtl,
        hinweis: t('stickPinHint'),
        nurZahlen: true);
    if (ok != true || !mounted) return;
    await _entsperreMitStick();
  }

  // ---- WIEDERHERSTELLEN ----
  //
  // DIESEN BILDSCHIRM GAB ES BIS ZUM 25.07.2026 NICHT — waehrend der
  // Bildschirm mit den zwoelf Woertern sagte, sie seien "der einzige Weg
  // zurueck, wenn dieses Telefon verloren, kaputt oder geloescht ist".
  //
  // Der Kern konnte es die ganze Zeit (restoreIdentity), AppState auch
  // (identitaetWiederherstellen), die Pruefung ebenfalls. Nur der Weg dorthin
  // fehlte. Wer sein Telefon verlor und die Woerter brav aufgeschrieben hatte,
  // stand auf dem neuen vor einer App, die sie nirgends annahm.
  //
  // WARUM JEDES WORT EINZELN GEPRUEFT WIRD
  // "Phrase ungueltig" hilft bei zwoelf Woertern niemandem — man weiss nicht,
  // welches. Hier wird jedes Wort gegen die Liste gehalten und das falsche
  // hervorgehoben. Bei etwas, das ueber den Verlust der Identitaet
  // entscheidet, ist das kein Feinschliff.

  /// Die eingegebenen Woerter, klein und ohne Leerraum.
  List<String> get _phraseWoerter => phraseCtl.text
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Welche davon nicht in der BIP39-Liste stehen.
  Set<int> get _unbekannteWoerter {
    final aus = <int>{};
    final woerter = _phraseWoerter;
    for (var i = 0; i < woerter.length; i++) {
      if (!bip39EnglishWordlist.contains(woerter[i])) aus.add(i);
    }
    return aus;
  }

  Future<void> _stelleWieder() async {
    var woerter = _phraseWoerter;
    setState(() => restoreFehler = null);

    // TEILE VON VERTRAUENSKONTAKTEN statt der Woerter: stehen sie im Feld,
    // werden daraus die zwoelf Woerter, und danach geht es genau so weiter,
    // als haette jemand sie getippt — mit derselben Pruefsumme am Ende.
    if (phraseCtl.text.toUpperCase().contains('BITDM-TEIL')) {
      try {
        final teile = phraseCtl.text
            .split(RegExp(r'(?=BITDM-TEIL)', caseSensitive: false))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map(Teil.ausText)
            .toList();
        woerter = woerterAusTeilen(teile);
      } catch (e) {
        setState(() => restoreFehler = '${t('restorePartsBad')} $e');
        return;
      }
      setState(() => screen = 'creating');
      final ok = await st.identitaetWiederherstellen(woerter);
      if (!mounted) return;
      if (ok) {
        phraseCtl.clear();
        setState(() => screen = 'chats');
      } else {
        setState(() {
          screen = 'restore';
          restoreFehler = t('restoreChecksum');
        });
      }
      return;
    }

    if (woerter.length != kRecoveryPhraseWords) {
      setState(() => restoreFehler = t('restoreCount')
          .replaceFirst('{n}', '${woerter.length}')
          .replaceFirst('{soll}', '$kRecoveryPhraseWords'));
      return;
    }
    if (_unbekannteWoerter.isNotEmpty) {
      setState(() => restoreFehler = t('restoreUnknownWord'));
      return;
    }

    setState(() => screen = 'creating');
    final ok = await st.identitaetWiederherstellen(woerter);
    if (!mounted) return;
    if (ok) {
      phraseCtl.clear();
      setState(() => screen = 'chats');
    } else {
      // Die Woerter stehen alle in der Liste, aber die Pruefsumme stimmt
      // nicht: es sind die richtigen Woerter in der falschen Reihenfolge,
      // oder eines ist ein anderes aus derselben Liste. Das muss anders
      // klingen als "ein Wort kenne ich nicht".
      setState(() {
        screen = 'restore';
        restoreFehler = t('restoreChecksum');
      });
    }
  }

  Widget wiederherstellenScreen() {
    final woerter = _phraseWoerter;
    final unbekannt = _unbekannteWoerter;
    final vollstaendig = woerter.length == kRecoveryPhraseWords;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // EINE GLYPHE FUER ALLE ZURUECK-KNOEPFE, auf jeder Plattform. Dieser
          // hier war der einzige mit '<', 'add', 'test' und 'nahHilfe' hatten
          // schon '‹' — und die beiden sehen deutlich verschieden aus. Das ist
          // eine Vereinheitlichung und keine Desktop-Sache: sie aendert das
          // Zeichen auch auf dem Telefon, und das ist gewollt (30.07.2026).
          // Nicht auf `go` umgestellt — hier muss zusaetzlich `restoreFehler`
          // weg.
          iconBtn('‹', () => setState(() { screen = 'onboard'; restoreFehler = null; })),
          const SizedBox(width: 11),
          Expanded(child: h2(t('restoreTitle'), size: 24)),
        ]),
        const SizedBox(height: 12),
        Text(t('restoreIntro'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 6),
        Text(t('restoreParts'),
            style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 16),

        // DER RAHMEN ZEIGT DEN FOKUS — IM FENSTER. Der Kasten zeichnet den
        // Rahmen, das Feld darin weiss nichts davon; beim Hineinklicken oder
        // Hineintabben aenderte sich bisher nichts Sichtbares, und auf einem
        // leeren Feld war damit nicht zu erkennen, dass es am Zug ist. Auf dem
        // Telefon bleibt er still: dort ist Tippen ins Feld der Normalfall, der
        // Rahmen wuerde bei jeder Benutzung wechseln, und jeder Wechsel kostet
        // einen Neubau des ganzen _HomeState (siehe initState).
        //
        // DEN FOKUS BEIM OEFFNEN bekommt dieses Feld im Fenster von
        // [_sorgeFuerFokus] — nicht ueber `autofocus`, siehe die Begruendung
        // dort. Auf dem Telefon geschieht das absichtlich nicht: dort wuerde
        // die Tastatur ungefragt aufklappen und den halben Bildschirm nehmen.
        // STRG+EINGABE STELLT WIEDER HER, Eingabe allein nicht: das Feld hat
        // vier Zeilen, dort ist die Eingabetaste der Zeilenumbruch. Strg+
        // Eingabe ist am Schreibtisch die uebliche Abkuerzung fuer "fertig" in
        // einem mehrzeiligen Feld — ohne sie war der wichtigste Bildschirm der
        // App ohne Maus nicht zu bedienen.
        _mitStrgEingabe(
          _stelleWieder,
          Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _imFenster && _phraseFokus.hasFocus
                      ? p.accent
                      : p.line)),
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: phraseCtl,
            focusNode: _phraseFokus,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            onChanged: (_) => setState(() => restoreFehler = null),
            style: mono(size: 14, color: p.ink, height: 1.6),
            cursorColor: p.accent,
            decoration: InputDecoration.collapsed(
                hintText: t('restoreHint'),
                hintStyle: mono(size: 13, color: p.dim, height: 1.6)),
          ),
        ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          smallBtn(t('paste'), () async {
            final d = await Clipboard.getData(Clipboard.kTextPlain);
            final txt = d?.text?.trim();
            if (txt == null || txt.isEmpty || !mounted) return;
            setState(() { phraseCtl.text = txt; restoreFehler = null; });
          }),
          const Spacer(),
          Text('${woerter.length} / $kRecoveryPhraseWords',
              style: mono(
                  size: 11,
                  weight: FontWeight.w600,
                  color: vollstaendig && unbekannt.isEmpty ? p.accLight : p.dim)),
        ]),
        const SizedBox(height: 14),

        // Die Woerter einzeln, damit sichtbar wird, WELCHES nicht stimmt.
        if (woerter.isNotEmpty)
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < woerter.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                    color: unbekannt.contains(i) ? p.tint : p.surf,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: unbekannt.contains(i) ? p.accent : p.line)),
                child: Text('${i + 1} ${woerter[i]}',
                    style: mono(
                        size: 11.5,
                        color: unbekannt.contains(i) ? p.tintInk : p.muted)),
              ),
          ]),

        if (restoreFehler != null) ...[
          const SizedBox(height: 14),
          _hinweisKasten(restoreFehler!),
        ],

        const SizedBox(height: 18),
        _knopfBreite(outlineBtn(t('restoreDo'), _stelleWieder,
            padding: const EdgeInsets.all(14), fontSize: 13)),
        const SizedBox(height: 14),

        // WAS DIE WIEDERHERSTELLUNG NICHT ZURUECKBRINGT. Das gehoert VOR die
        // Handlung, nicht danach: wer hier erwartet, seine Unterhaltungen
        // wiederzusehen, wird sonst zweimal enttaeuscht.
        Text(t('restoreNote'), style: mono(size: 11, color: p.dim, height: 1.55)),
      ]),
    );
  }

  // ---- WIRD ANGELEGT ----
  //
  // EIN DREHENDER RING GEHOERT DAZU. Vorher war das eine einzige graue Zeile
  // in der Mitte — in einem 984x1040 grossen Fenster ein winziger Schriftzug
  // in einer leeren Flaeche, nicht zu unterscheiden von einer haengenden App.
  // Der Bildschirm steht beim Anlegen, beim Wiederherstellen und beim
  // Loeschen, und das Wiederherstellen dauert wegen PBKDF2 merkbar laenger als
  // die versprochene Sekunde.
  //
  // KEIN BALKEN UND KEINE PROZENTE: die Dauer ist nicht bekannt. Dieselben
  // Masse wie der Ring in `methodRow` (strokeWidth 1.6, p.accLight), damit es
  // nicht nach einem zweiten Entwurf aussieht.
  //
  // NUR IM FENSTER, und diesmal nicht nur wegen Android: ein Ring dreht sich
  // endlos, und `pumpAndSettle` wartet auf das Ende einer Animation. Im
  // Widget-Test meldet Flutter android — dort bleibt dieser Bildschirm die
  // eine Zeile, und kein Test wartet auf etwas, das nie aufhoert.
  Widget arbeitetScreen() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_imFenster) ...[
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: p.accLight),
            ),
            const SizedBox(height: 16),
          ],
          Text(t('creating').toUpperCase(),
              style: mono(size: 12, color: p.dim, spacing: 1.8)),
        ]),
      );

  // ---- WIEDERHERSTELLUNGSPHRASE ----
  //
  // Diesen Bildschirm gab es im Entwurf nicht. Er ist trotzdem nicht optional:
  // die zwoelf Woerter sind der einzige Weg zurueck, wenn das Telefon
  // verloren, kaputt oder geloescht ist. Es gibt keinen Server, bei dem man
  // sich ausweisen und die Identitaet zurueckholen koennte — wer sie nicht
  // notiert hat, ist weg.
  //
  // Gestaltet mit denselben Bausteinen wie der Rest, damit sich nichts
  // Fremdes anfuehlt.
  Widget phraseScreen() {
    final woerter = st.frischePhrase ?? const <String>[];

    // ZWEI SPALTEN AUS DEM PLATZ DER SPALTE, nicht aus der Fensterbreite —
    // Begruendung und Zahlen stehen an [_zweiSpaltenGitter].
    final Widget gitter = _zweiSpaltenGitter(
      woerter.length,
      (i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          SizedBox(
            width: 20,
            child: Text('${i + 1}', style: mono(size: 10, color: p.dim)),
          ),
          Expanded(
            child: Text(woerter[i],
                style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
          ),
        ]),
      ),
    );

    final Widget inhalt = Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('phraseTitle')),
        const SizedBox(height: 6),
        Text(t('phraseSub'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        // IM FENSTER KEIN Expanded. Es frisst dort die ganze Resthoehe, und
        // Warnkasten und Knopf klebten am unteren Fensterrand — weit weg von
        // den Woertern, auf die sie sich beziehen. Stattdessen scrollt der
        // ganze Bildschirm (wie 'restore' und 'test'); das faengt gleich den
        // zweiten Fall mit ab: zieht man das Fenster niedriger als etwa 350 px,
        // lief der Inhalt vorher in den gelb-schwarzen Ueberlaufbalken.
        if (_imFenster) gitter else Expanded(child: SingleChildScrollView(child: gitter)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.tint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.tintLine),
          ),
          child: Text(t('phraseWarn'), style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
        ),
        const SizedBox(height: 12),
        _knopfBreite(outlineBtn(t('phraseDone'), () {
          st.phraseBestaetigt();
          go('secure');
        }, padding: const EdgeInsets.all(13))),
      ]),
    );

    return _imFenster ? SingleChildScrollView(child: inhalt) : inhalt;
  }

  // ---- SECURE ----
  /// Oeffnet den Faehigkeitstest fuer einen Sicherheitsschluessel.
  Future<void> _pruefeStick() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => FidoProbeScreen(
        titel: t('fidoProbe'),
        anhalten: t('fidoHold'),
        keinNfc: t('fidoNoNfc'),
        schliessen: t('close'),
      ),
    ));
  }

  Widget secureScreen() {
    // DER SPACER WAR DER AUFFAELLIGSTE EINZELNE GRUND, warum die Abfolgen im
    // Fenster nicht wie eine Desktop-App aussahen: auf dem Desktop bleibt von
    // den vier Zugriffszeilen nur eine uebrig (siehe `_faktorGehtHier` — nur
    // 'pw' hat dort eine Gegenseite), der Bildschirm hat also etwa 260 px
    // Inhalt, und in einem 1040 px hohen Fenster klebten darunter nach ueber
    // 600 px Leere zwei Knoepfe am Boden (30.07.2026).
    //
    // 24 px ist der Abstand zwischen zwei Gruppen (Masse.gruppe ist 22, hier
    // eine Stufe mehr, weil darunter die Handlung folgt).
    //
    // ZWEI KNOEPFE NEBENEINANDER, ABER NICHT MEHR GEDEHNT: die beiden Expanded
    // machten aus ihnen zwei 254 px breite Halbbanner. Im Fenster nehmen sie
    // ihre Textbreite und stehen links, wie alles andere auf diesem Bildschirm.
    final Widget knoepfe = _imFenster
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            outlineBtn(t('secureSkip'), () => go('id'),
                accent: false,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                weight: FontWeight.w400),
            const SizedBox(width: 8),
            outlineBtn(t('secureDone'), () => go('id'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 13)),
          ])
        : Row(children: [
            Expanded(child: outlineBtn(t('secureSkip'), () => go('id'), accent: false, padding: const EdgeInsets.all(13), weight: FontWeight.w400)),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('secureDone'), () => go('id'), padding: const EdgeInsets.all(13))),
          ]);

    final Widget inhalt = Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('secureTitle')),
        const SizedBox(height: 6),
        Text(t('secureSub'), style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        ...zugriffsBlock(statusMode: true),
        const SizedBox(height: 4),
        Text(t('secureFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
        if (_imFenster) const SizedBox(height: 24) else const Spacer(),
        _imFenster
            ? Align(alignment: Alignment.centerLeft, child: knoepfe)
            : knoepfe,
      ]),
    );

    // Scrollbar im Fenster, sobald der Spacer weg ist — sonst ueberlaeuft der
    // Bildschirm, wenn jemand das Fenster niedriger zieht als seinen Inhalt.
    // Spacer und Scrollview gehen nicht zusammen, deshalb geht beides nur
    // gemeinsam.
    return _imFenster ? SingleChildScrollView(child: inhalt) : inhalt;
  }

  Widget methodRow(String key, {bool statusMode = true}) {
    final art = zeilenArt[key];
    final on = art != null && st.hatFaktor(art);
    final laeuft = laeuftZeile == key;
    // Ein anderer Faktor arbeitet gerade. Zwei Anmeldedialoge gleichzeitig
    // gehen nicht, und der zweite bliebe stumm haengen.
    final blockiert = laeuftZeile != null && !laeuft;

    final mark = laeuft ? '·' : (on ? '✓' : '·');
    final right = laeuft
        ? t('waiting')
        : statusMode
            ? (on ? t('on2') : t('offMethod'))
            : (on ? t('remove') : t('add'));

    // ALS KNOPF ANSAGEN, UND OB ER GERADE GEHT.
    //
    // Die ganze Zeile ist das Bedienelement; ein eigenes "SET UP" gibt es
    // nicht. Vorgelesen wurde deshalb nur eine Aneinanderreihung von Texten —
    // "Geraetesperre, Die PIN dieses Telefons, Einrichten" —, ohne dass
    // erkennbar war, dass man sie antippen kann.
    //
    // `enabled` traegt die zweite Haelfte: waehrend ein anderer Faktor
    // arbeitet, ist die Zeile gesperrt. Sichtbar ist das an der Transparenz.
    // Wer sie nicht sieht, tippte bisher ins Leere und bekam keine Auskunft,
    // warum nichts geschieht.
    //
    // Aufgefallen am 29.07.2026: beim Durchgehen der Ablaeufe traf mein
    // eigener Tipp die Zeile nicht, weil sie kein eigener Knoten war.
    // AM ZEIGER WAR VON ALLEM NICHTS ZU SEHEN. Auf 'secure' ist diese Zeile im
    // Fenster die EINZIGE (nur 'pw' ueberlebt `_faktorGehtHier`), also der
    // einzige Weg zu einem App-Passwort — und sie sah aus wie eine
    // Statuszeile. `blockiert` behaelt den Standardzeiger: eine Hand ueber
    // etwas, das gerade nicht geht, verspricht etwas, was nicht kommt.
    return Semantics(
      button: true,
      enabled: !blockiert,
      container: true,
      child: Opacity(
      opacity: blockiert ? 0.4 : 1,
      child: _Bedienbar(
        imFenster: _imFenster,
        onTap: blockiert ? null : () => methodAct(key),
        bau: (ueber, fokus) => GestureDetector(
        onTap: blockiert ? null : () => methodAct(key),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              color: ueber || fokus ? p.surf : p.surf2,
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Container(
              width: 26, height: 26, alignment: Alignment.center,
              decoration: BoxDecoration(color: on ? p.tint : p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: on || laeuft ? p.accent : p.line)),
              child: laeuft
                  // Sichtbar, dass etwas laeuft. Fehlte das, sah ein Antippen
                  // waehrend der Anmeldung aus wie ein Antippen ins Leere.
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.6, color: p.accLight))
                  : Text(mark, style: doto(size: 12, weight: FontWeight.w600, color: on ? p.accLight : p.dim)),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t(key), style: TextStyle(fontSize: 13.5, color: p.ink)),
                Text(t('${key}Sub'), style: mono(size: 11, color: p.dim, height: 1.35)),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: on ? p.tint : Colors.transparent, borderRadius: BorderRadius.circular(4), border: Border.all(color: on ? p.tintLine : p.line)),
              child: Text(right.toUpperCase(), style: mono(size: 10, weight: FontWeight.w500, color: on ? p.tintInk : p.dim, spacing: 1.2)),
            ),
          ]),
        ),
      ),
      ),
    ),
    );
  }

  /// Kann dieser Faktor auf DIESEM Geraet ueberhaupt etwas einrichten?
  ///
  /// Drei der vier haengen an Android: Biometrie und Geraetesperre am
  /// Schluesselfach (`bitdm/schluesselfach`), der Sicherheitsschluessel an
  /// USB-HID und NFC. Auf Windows gibt es diese Kanaele nicht — ein Druck
  /// darauf endet in einer MissingPluginException. Nur das App-Passwort ist
  /// reines Dart und laeuft ueberall.
  ///
  /// DAS IST DERSELBE FEHLER, DER SCHON UEBER `zugriffsZeilen` STEHT: eine
  /// Liste, in der die Haelfte der Eintraege nichts tut, laesst den Nutzer bei
  /// jedem der anderen zweifeln. Am 30.07.2026 bot der erste Windows-Bau vier
  /// Faktoren an, von denen drei nicht funktionieren konnten — und einer sagte
  /// "the PIN, pattern or password of this phone" auf einem PC.
  ///
  /// Im Test meldet Flutter Android, dort bleiben also alle vier sichtbar.
  bool _faktorGehtHier(String k) => k == 'pw' || _nurAufAndroid;

  /// Laeuft die App dort, wo die Kotlin-Kanaele ueberhaupt existieren?
  ///
  /// Drei Dinge in dieser App stecken vollstaendig in Kotlin und haben auf
  /// keiner anderen Plattform eine Gegenseite:
  ///
  ///   * `bitdm/schluesselfach` — Biometrie und Geraetesperre
  ///   * `bitdm/usb_hid` und NFC — der Sicherheitsschluessel
  ///   * `bitdm/nahfunk` — der ganze Nahbereich
  ///
  /// Dazu UnifiedPush, ein Android-Plugin. Ein Aufruf ohne Gegenseite endet in
  /// einer MissingPluginException — sichtbar als Bedienelement, das auf Tippen
  /// mit einem Fehler antwortet statt mit einer Wirkung.
  ///
  /// `kIsWeb` MUSS mitgeprueft werden: im Browser auf einem Android-Telefon
  /// meldet `defaultTargetPlatform` android, Kanaele gibt es dort aber keine.
  ///
  /// Im Widget-Test meldet Flutter android, dort bleibt also alles sichtbar
  /// und keiner der vorhandenen Tests aendert sein Verhalten.
  static bool get _nurAufAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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

  // ---- MY ID ----
  Widget idScreen() {
    // OHNE IDENTITAET GIBT ES NICHTS ZU ZEIGEN. Vorher stand hier ein QR-Code
    // aus einer leeren Zeichenkette und darunter leere Kaestchen — eine Seite,
    // die aussah, als waere sie kaputt. Erreichbar ist dieser Zustand ueber
    // die Reiter, bevor eine Identitaet angelegt wurde.
    if (st.meineAdresse.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            Masse.rand, Masse.block, Masse.rand, Masse.rand),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          h2(t('myId')),
          const SizedBox(height: Masse.block),
          _hinweisKasten(t('myIdEmpty'), warnend: false),
        ]),
      );
    }

    final bloecke = meineAdresseAnzeige.split('-');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('myId')),
        const SizedBox(height: 4),
        Text(t('myIdSub'), style: mono(size: 12, color: p.dim)),
        const SizedBox(height: 16),
        // HELLE KARTE, DUNKLE MODULE — auch im dunklen Thema.
        //
        // Ein QR-Code ist nach Norm dunkel auf hell. Umgekehrt lesen ihn viele
        // Kameras nicht; ZXing kehrt nicht von sich aus um. Der Code hier soll
        // aber von JEDER App gelesen werden koennen, nicht nur von BitDM.
        // Deshalb bricht diese eine Flaeche mit dem dunklen Thema.
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: const Color(0xFFF2F2F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.line)),
            child: QrBild(
              st.meineAdresse,
              vordergrund: const Color(0xFF0B0B10),
              hintergrund: const Color(0xFFF2F2F2),
              kante: 220,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // EINE BESCHRIFTUNG FUER DIE GANZE ADRESSE, nicht vierzehn.
        //
        // Die Vierergruppen sind eine Lesehilfe fuer die AUGEN — sie machen
        // aus 56 Zeichen etwas, das man abtippen und vergleichen kann. Fuer
        // einen Screenreader sind sie das Gegenteil: vierzehn
        // zusammenhanglose Haeppchen, zwischen denen er jedes Mal neu
        // ansetzt. `excludeSemantics` blendet sie deshalb aus und legt EINEN
        // Text darueber.
        //
        // Aufgefallen ist es an einer anderen Ecke: die Adresse liess sich auf
        // dem Galaxy S10 nicht aus dem Bedienungsbaum lesen (auf dem S25
        // schon), und damit war ein Zwei-Telefon-Test nicht zu fahren. Der
        // Grund war derselbe wie beim Screenreader — die Gruppen sind
        // vierzehn beilaeufige Textknoten und keine Angabe. Ein Testkniff
        // haette mein Problem geloest und das der Nutzer stehen gelassen.
        //
        // DIESELBE BREITENRECHNUNG WIE AUF 'phrase', und das ist der Punkt:
        // hier stand bis zum 30.07.2026 noch die Fensterbreite. Ab 1402 px
        // Fenster fielen die vierzehn Vierergruppen zu vierzehn spaltenbreiten
        // Zeilen zusammen — auf dem Bildschirm, dessen Zweck das Vergleichen
        // der Adresse ist. Zahlen und Herleitung an [_zweiSpaltenGitter].
        Semantics(
          label: adresseFormatiert(st.meineAdresse),
          excludeSemantics: true,
          child: _zweiSpaltenGitter(
            bloecke.length,
            (i) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                  color: p.surf2, borderRadius: BorderRadius.circular(4)),
              child: Text(bloecke[i],
                  style: doto(
                      size: 16,
                      weight: FontWeight.w600,
                      color: p.ink,
                      spacing: 1.4)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Das Schluesselbild: wer die Adresse weitergibt, kann das Bild gleich
        // mit vergleichen lassen — schneller als 56 Zeichen.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SchluesselbildAnsicht(schluessel: st.meineAdresse, farbe: p.accLight, leer: p.line, punkt: 9),
          const SizedBox(width: 14),
          Expanded(child: Text(t('keyArtSelf'), style: mono(size: 11, color: p.dim, height: 1.5))),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: outlineBtn(copied ? t('copied') : t('copy'), copyId, padding: const EdgeInsets.all(11))),
          const SizedBox(width: 8),
          Expanded(child: outlineBtn(t('share'), () async {
            // Geteilt wird die Adresse MIT Strichen — genau das, was der
            // Empfaenger dann in sein Eingabefeld einfuegt und dort auch als
            // Beispiel stehen sieht.
            final ok = await FremdeApp.teile(
                adresseFormatiert(st.meineAdresse),
                titel: t('share'));
            if (!ok && mounted) setState(() => lockFehler = t('shareFailed'));
          }, accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
        ]),
        const SizedBox(height: 16),

        // WIE VIELE GERAETE AUF DIESER IDENTITAET SITZEN.
        //
        // Verpflichtend und keine Kuer. Wer die zwoelf Woerter hat, kann
        // vollstaendig als man selbst auftreten — das war schon immer so.
        // Seit dem Mehrgeraetebetrieb bekommt er zusaetzlich von JEDEM
        // Absender eine eigene Kopie jeder Nachricht, ohne dass irgendwo
        // etwas auffiele. Und es gibt keinen Widerruf: ein Geraet abzumelden
        // ist unmoeglich, weil kein Geraet mehr Recht auf die Adresse hat als
        // ein anderes; die einzige Abhilfe ist eine neue Identitaet.
        //
        // Diese Zeile macht aus einem unsichtbaren Mitleser eine sichtbare
        // Zahl, die nicht stimmt. KEINE VERWALTUNGSMASKE — es gaebe nichts zu
        // verwalten, und ein Knopf "abmelden", der nichts abmeldet, waere
        // schlimmer als keine Zahl.
        //
        // Nichts steht da, solange niemand gefragt hat (kein Relay erreicht,
        // nur in der Naehe): eine erfundene 1 waere genau die Halbwahrheit,
        // gegen die diese Zeile gebaut ist.
        if (st.geraeteZahl != null) ...[
          _hinweisKasten(
            st.geraeteZahl! <= 1
                ? t('geraeteEins')
                : t('geraeteViele').replaceFirst('{n}', '${st.geraeteZahl}'),
            warnend: st.geraeteZahl! > 1,
          ),
          const SizedBox(height: 16),
        ],

        Text(t('idNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  // ---- ADD ----
  Widget addScreen() {
    final Widget inhalt = Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('chats')),
          const SizedBox(width: 11),
          // FEHLERBEHEBUNG, AUCH FUER ANDROID: ohne Expanded laeuft eine
          // laengere Uebersetzung aus der Row heraus ("Kontakt hinzufügen" auf
          // einem schmalen Telefon). Dass 'restore', 'test' und 'nahHilfe' das
          // Expanded schon hatten, macht es hier nicht zur Angleichung — es war
          // an dieser Stelle schlicht kaputt.
          Expanded(child: h2(t('addTitle'), size: 20)),
        ]),
        const SizedBox(height: 16),
        Text(t('idLabel').toUpperCase(), style: mono(size: 10.5, color: p.dim, spacing: 1.6)),
        const SizedBox(height: 6),
        // Strg+Eingabe schickt die Anfrage; Begruendung siehe 'restore'. Der
        // Rahmen zeigt den Fokus, damit man das leere Feld am Zug erkennt.
        _mitStrgEingabe(
          sendReq,
          Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _imFenster && _addFokus.hasFocus ? p.accent : p.line)),
          padding: const EdgeInsets.all(11),
          child: TextField(
            controller: addCtl,
            focusNode: _addFokus,
            maxLines: 3,
            style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 1.4, height: 1.7),
            cursorColor: p.accent,
            decoration: InputDecoration.collapsed(hintText: beispielAdresse, hintStyle: doto(size: 15, weight: FontWeight.w600, color: p.dim, spacing: 1.4, height: 1.7)),
          ),
        ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          smallBtn(t('paste'), () async {
            final d = await Clipboard.getData(Clipboard.kTextPlain);
            final txt = d?.text?.trim();
            if (txt == null || txt.isEmpty || !mounted) return;
            setState(() => addCtl.text = txt);
          }),
          // KEIN QR-SCANNER AUSSERHALB VON ANDROID. pubspec.lock bringt nur
          // camera_android_camerax, camera_avfoundation und camera_web mit —
          // auf Windows und Linux wirft `availableCameras()` eine
          // MissingPluginException, und `_starte()` in qr_scan_screen.dart
          // faengt nur CameraException. Der Druck landete also auf einer Seite
          // mit Fehlerbild statt auf einem Scanner. Im Web gibt es camera_web,
          // dort ist aber `startImageStream` nicht umgesetzt — dasselbe Ende.
          //
          // Dieselbe Begruendung wie bei den Anmeldefaktoren (`_faktorGehtHier`):
          // ein Bedienelement, das auf Tippen mit einem Fehler antwortet, laesst
          // am Rest der App zweifeln. Im Widget-Test meldet Flutter android,
          // dort bleibt der Knopf sichtbar.
          if (_nurAufAndroid) const SizedBox(width: 8),
          if (_nurAufAndroid) smallBtn(t('scan'), _scanneQr),
        ]),
        const SizedBox(height: 16),
        _knopfBreite(outlineBtn(t('sendReq'), sendReq, padding: const EdgeInsets.all(13))),
        if (reqSent) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(4)),
                  child: Text(t('pending').toUpperCase(), style: mono(size: 10, weight: FontWeight.w500, color: p.tintInk, spacing: 1.2)),
                ),
                const SizedBox(width: 8),
                Text(
                    shortId(adresseFormatiert(
                        addCtl.text.replaceAll(RegExp(r'[\s\-]'), ''))),
                    style: doto(size: 13, weight: FontWeight.w600, color: p.muted, spacing: 0.8)),
              ]),
              const SizedBox(height: 6),
              Text(t('reqSentNote'), style: mono(size: 12, color: p.muted, height: 1.4)),
            ]),
          ),
        ],
        if (st.letzterFehler == 'adresseUngueltig') ...[
          const SizedBox(height: 12),
          Text(t('badAddress'), style: mono(size: 11.5, color: p.accLight, height: 1.5)),
        ],
        // Wie auf 'secure': im Fenster schob der Spacer die 11-pt-Fussnote an
        // den unteren Fensterrand, mit mehreren hundert Pixeln Leere darueber.
        // Und weil Spacer und Scrollview nicht zusammengehen, war der
        // Bildschirm gleichzeitig nicht scrollbar — mit eingeblendetem
        // reqSent-Kasten lief er in einem niedrigen Fenster ueber.
        if (_imFenster) const SizedBox(height: 22) else const Spacer(),
        Text(t('addFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );

    return _imFenster ? SingleChildScrollView(child: inhalt) : inhalt;
  }

  Widget smallBtn(String labelTxt, VoidCallback onTap) => _Bedienbar(
        imFenster: _imFenster,
        onTap: onTap,
        bau: (ueber, fokus) => Masse.trefferflaeche(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
                color: fokus ? p.wash : null,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: ueber || fokus ? p.accHover : p.line)),
            child: Text(labelTxt.toUpperCase(),
                style: mono(
                    size: 11,
                    weight: FontWeight.w400,
                    color: ueber ? p.accHover : p.muted,
                    spacing: 1.2)),
          ),
        ),
      );

  // ---- CHATS ----
  /// Zeigt, ob die App mit dem Relay verbunden ist.
  ///
  /// DAS FEHLTE BISHER GANZ. Wer eine Nachricht schickte und nichts
  /// zurueckbekam, konnte nicht unterscheiden zwischen "kein Netz" und "der
  /// andere antwortet nicht" — zwei Lagen, die voellig verschiedenes Handeln
  /// verlangen.
  ///
  /// Der Punkt atmet, solange verbunden wird, und steht still, sobald es
  /// steht. Ein Punkt, der dauernd blinkt, macht nervoes; einer, der sich nie
  /// ruehrt, sagt nichts.
  Widget verbindungsPunkt() {
    final (farbe, text, aktiv) = switch (st.verbindung) {
      ConnectionState.online => (p.accLight, t('connOnline'), false),
      ConnectionState.connecting => (p.muted, t('connConnecting'), true),
      // ABGEWIESEN IST NICHT "KEIN NETZ". Der Relay hat mit 507 gesagt, dass
      // diese Adresse schon genug Geraete hat (§6) — daran aendert Warten
      // nichts, und die App versucht es auch nicht mehr. Wer hier "keine
      // Verbindung" liest, sucht den Fehler bei seinem WLAN.
      ConnectionState.error => (
          p.dim,
          st.abgewiesen ? t('connGeraeteVoll') : t('connError'),
          false
        ),
      ConnectionState.disconnected => (p.dim, t('connOffline'), false),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AtmenderPunkt(farbe: farbe, aktiv: aktiv, groesse: 7),
      const SizedBox(width: 6),
      // Kuerzen statt ueberlaufen, wenn die Kopfzeile eng wird (siehe dort):
      // ein abgeschnittenes "KEINE VERBIND…" sagt noch etwas, ein gelb
      // gestreifter Balken nichts.
      Flexible(
        child: AnimatedDefaultTextStyle(
          duration: Bewegung.klein,
          style: mono(size: 10, weight: FontWeight.w500, color: farbe, spacing: 1.1),
          child: Text(text.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ]);
  }

  /// Was das '+' in der Kopfzeile tut. Als Methode, weil [_Bedienbar] die
  /// Handlung zweimal braucht — fuer den Zeiger und fuer den Tipp.
  void _zumHinzufuegen() =>
      setState(() { screen = 'add'; addCtl.clear(); reqSent = false; });

  Widget chatsScreen() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 11, 22, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          // FLEXIBEL, WEIL DIE LINKE SPALTE ENG IST. Im Schreibtisch-Geruest
          // steht diese Kopfzeile in 300 px minus 44 px Rand = 256 px, und
          // darin liegen 'CHATS', der Punkt, sein Text und das '+'. Der neue
          // Fenster-Test hat den Ueberlauf am 30.07.2026 gemeldet: 31 px zu
          // viel (mit der Testschrift, die breiter baut als Doto — auf dem
          // Geraet passt es, aber mit einem langen Text wie "keine
          // Verbindung" nur knapp). Flexible aendert nichts, solange es
          // passt, und laesst den Text kuerzen statt ueberzulaufen.
          Flexible(
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              h2(t('chats')),
              const SizedBox(width: 10),
              Flexible(child: verbindungsPunkt()),
            ]),
          ),
          _Bedienbar(
            imFenster: _imFenster,
            onTap: _zumHinzufuegen,
            bau: (ueber, fokus) => GestureDetector(
              onTap: _zumHinzufuegen,
              child: Container(
                width: 32, height: 32, alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: fokus ? p.wash : null,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: ueber || fokus ? p.accHover : p.accent)),
                // EIGENE BESCHRIFTUNG FUER DIE VORLESEFUNKTION.
                //
                // Ohne sie liest ein Screenreader die ganze Kopfzeile als einen
                // Block vor: "CHATS OFFLINE +". Das Pluszeichen ist der einzige
                // Weg, jemanden hinzuzufuegen, und es hatte keinen Namen.
                child: Semantics(
                  label: t('addContact'),
                  button: true,
                  child: Text('+', style: TextStyle(color: p.accLight, fontSize: 18, height: 1)),
                ),
              ),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      suchFeld(),
      if (st.suchText.trim().isEmpty && !_zeigeArchiv) filterLeiste(),
      Expanded(
        child: st.suchText.trim().isNotEmpty
            ? ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [suchTreffer()])
            : _filter == 'stern'
            ? ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
                suchTreffer(liste: st.sterne, leer: t('starEmpty')),
              ])
            : ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
          if (_zeigeArchiv)
            InkWell(
              onTap: () => setState(() => _zeigeArchiv = false),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                child: Text('‹ ${t('backToChats')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          if (!_zeigeArchiv) ...[
          for (final k in st.offeneAnfragen) pendingCard(k),
          // Ausgehende Anfragen erscheinen ebenfalls. Vorher waren sie
          // unsichtbar: wer jemanden hinzugefuegt hatte, sah danach eine leere
          // Liste und musste annehmen, es habe nicht funktioniert.
          for (final k in st.eigeneAnfragen) wartendeAnfrage(k),
          ],
          // ANGEHEFTET HEISST GANZ OBEN — ueber beide Arten hinweg. Vorher
          // standen erst alle Gruppen, dann alle Kontakte, und ein angehefteter
          // Kontakt blieb unter jeder Gruppe (Emulatorlauf 25.09.2026).
          for (final g in sichtbareGruppen.where((g) => g.angeheftet && _passt(g.id, true))) gruppenZeile(g),
          for (final k in sichtbareKontakte.where((k) => k.angeheftet && _passt(k.id, false))) contactRow(k.id),
          for (final g in sichtbareGruppen.where((g) => !g.angeheftet && _passt(g.id, true))) gruppenZeile(g),
          for (final k in sichtbareKontakte.where((k) => !k.angeheftet && _passt(k.id, false))) contactRow(k.id),
          if (!_zeigeArchiv && !st.kontakte.any((k) => st.istNotizen(k.id)) && st.meineAdresse.isNotEmpty)
            InkWell(
              onTap: () async {
                final id = await st.notizenOeffnen();
                if (mounted) oeffneChat(id);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: Text('+ ${t('notes')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          // Das Archiv ist ein Eintrag am Ende der Liste, wie bei Signal —
          // und nur, wenn es etwas enthaelt.
          if (!_zeigeArchiv && st.meineAdresse.isNotEmpty)
            InkWell(
              onTap: _legeGruppeAnDialog,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: Text('+ ${t('groupCreate')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          if (!_zeigeArchiv &&
              (st.aktiveKontakte.any((c) => c.archiviert) || st.gruppen.any((g) => g.archiviert)))
            InkWell(
              onTap: () => setState(() => _zeigeArchiv = true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: Text(
                    '${t('archived').toUpperCase()} (${st.aktiveKontakte.where((c) => c.archiviert).length + st.gruppen.where((g) => g.archiviert).length})',
                    style: mono(size: 11, color: p.muted, spacing: 1.2)),
              ),
            ),
          if (contacts.isEmpty && st.offeneAnfragen.isEmpty && st.eigeneAnfragen.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
              child: Text(t('noChats'), style: mono(size: 12, color: p.dim, height: 1.6)),
            ),
          Padding(padding: const EdgeInsets.fromLTRB(22, 16, 22, 16), child: Text(t('noNames'), style: mono(size: 11, color: p.dim, height: 1.5))),
        ]),
      ),
    ]);
  }

  /// Eine Anfrage, die WIR gestellt haben und die noch offen ist.
  ///
  /// Bewusst nicht antippbar: es gibt noch keine Sitzung, und ein Chat, in dem
  /// man nicht schreiben kann, waere verwirrender als gar keiner.
  Widget wartendeAnfrage(Contact k) => Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Opacity(opacity: 0.45, child: Identicon(k.id, 40, avp, 8)),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(shortId(adresseFormatiert(k.id)),
                  style: doto(size: 15, weight: FontWeight.w600, color: p.muted, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(t('waitingForAccept'), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.line)),
            child: Text(t('pending').toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.2)),
          ),
        ]),
      );

  Widget pendingCard(Contact k) => Container(
        margin: const EdgeInsets.fromLTRB(17, 8, 17, 11),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(shortId(adresseFormatiert(k.id)), style: doto(size: 13, weight: FontWeight.w600, color: p.tintInk, spacing: 0.8)),
          const SizedBox(height: 6),
          Text(t('wantsChat'), style: mono(size: 11.5, color: p.muted)),
          const SizedBox(height: 8),
          // Annehmen und Ablehnen stehen IN der Chatliste und sind echte
          // Knoepfe — also auch durch [_Bedienbar]. Nicht auf `smallBtn`
          // umgestellt: dessen Masse sind andere, und das waere eine
          // Layout-Aenderung am Telefon fuer nichts.
          Row(children: [
            _Bedienbar(
              imFenster: _imFenster,
              onTap: () => acceptReq(k.id),
              bau: (ueber, fokus) => GestureDetector(
                onTap: () => acceptReq(k.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(color: fokus ? p.wash : null, borderRadius: BorderRadius.circular(4), border: Border.all(color: ueber || fokus ? p.accHover : p.accent)),
                  child: Text(t('accept').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _Bedienbar(
              imFenster: _imFenster,
              onTap: () => st.anfrageAblehnen(k.id),
              bau: (ueber, fokus) => GestureDetector(
                onTap: () => st.anfrageAblehnen(k.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(color: fokus ? p.wash : null, borderRadius: BorderRadius.circular(4), border: Border.all(color: ueber || fokus ? p.accHover : p.line)),
                  child: Text(t('decline').toUpperCase(), style: mono(size: 11, color: p.muted, spacing: 1.2)),
                ),
              ),
            ),
          ]),
        ]),
      );

  Widget contactRow(String id) {
    final list = st.verlaufVon(id);
    final letzte = list.isEmpty ? null : list.last;
    final last = letzte == null ? t('newContact') : auszug(letzte);
    final k = st.kontakte.where((c) => c.id == id).firstOrNull;
    final marken = [
      if (k?.angeheftet ?? false) t('pinnedTag'),
      if (k?.stumm ?? false) t('mutedTag'),
    ];
    final time = letzte == null ? '' : zeitVon(letzte.timestamp);
    // Ungelesen: die letzte Nachricht kam von der Gegenstelle und diese
    // Unterhaltung ist gerade nicht offen.
    // DIE ECHTE ZAHL statt "die letzte Nachricht ist fremd": die alte Regel
    // liess den Punkt stehen, bis man selbst antwortete, und blendete ihn fuer
    // die zuletzt geoeffnete Unterhaltung aus, auch nachdem man sie verlassen
    // hatte.
    final zahl = (screen == 'chat' && chat == id) ? 0 : st.ungelesenIn(id);
    // Die Zeilen der Chatliste sind die am haeufigsten angetippten der App und
    // waren im Fenster die letzten ohne Zeiger, Ueberfahren und Tab. Die
    // Fuellung ist die Rueckmeldung: die Zeile hat keinen Rahmen, den man
    // faerben koennte, und ein neuer haette sie um 1 px verschoben.
    return _Bedienbar(
      imFenster: _imFenster,
      onTap: () => oeffneChat(id),
      bau: (ueber, fokus) => GestureDetector(
      onTap: () => oeffneChat(id),
      // Langdruck am Telefon, Rechtsklick am Rechner — dasselbe Menue.
      onLongPress: () => unterhaltungMenue(id),
      onSecondaryTap: () => unterhaltungMenue(id),
      child: Container(
        color: ueber || fokus ? p.wash : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Identicon(id, 40, avp, 8),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(st.istNotizen(id) ? t('notes') : shortId(adresseFormatiert(id)), style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(last, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(time, style: mono(size: 10.5, color: p.dim)),
            const SizedBox(height: 6),
            if (marken.isNotEmpty) ...[
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final mk in marken) Padding(padding: const EdgeInsets.only(left: 4), child: marke(mk)),
              ]),
              const SizedBox(height: 4),
            ],
            ungelesenMarke(zahl),
          ]),
        ]),
      ),
      ),
    );
  }

  // ---- CHAT ----
  Widget chatScreen() {
    final cid = chat ?? c1;
    final hints = <String>[];
    if (st.einstellungen.blockScreenshots) hints.add(t("hintShot"));
    hints.add(t("hintEnc"));
    // ZUERST in der Zeile, weil es das Wichtigste ist: was hier geschrieben
    // wird, geht gerade nirgendwo hin. Wer das nicht sieht, haelt eine
    // liegengebliebene Nachricht fuer zugestellt.
    if (st.einstellungen.nurNahbereich) hints.insert(0, t("nearOnlyWaiting"));
    if (st.fristFuer(cid) != null) {
      hints.add(t("hintEph") + fristText(st.fristFuer(cid)));
    }
    final list = st.verlaufVon(cid);
    _haltUnten(cid, list.length);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(17, 8, 17, 8),
        child: Row(children: [
          // KEIN ZURUECK BEI ZWEI SPALTEN. Die Liste steht dann links und ist
          // nie verlassen worden — ein Pfeil, der "zurueck zur Liste" heisst,
          // zeigt dort auf etwas, das schon sichtbar ist.
          if (!_zweiSpalten) ...[
            iconBtn('‹', () => go('chats')),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: GestureDetector(
              // Die Notizen haben kein Gegenueber — keine Pruefnummer, kein
              // Kontakt zum Entfernen. Das Blatt waere leer oder falsch.
              onTap: Gruppe.istGruppenId(cid)
                  ? () => gruppenBlatt(cid)
                  : st.istNotizen(cid) ? null : () { setState(() => sheet = true); _ladePruefnummer(cid); },
              child: Row(children: [
                Identicon(cid, 32, avp, 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // DIESELBE SCHREIBWEISE WIE UEBERALL SONST.
                    //
                    // Hier stand `shortId(cid)` — die ROHE Kennung, ohne
                    // `adresseFormatiert`. Die Liste zeigte dieselbe Adresse
                    // als "BITD...2L-X", diese Kopfzeile als "bitd...q2lx":
                    // andere Gruppierung, andere Schreibweise, dasselbe
                    // Gegenueber. Wer zwei Geraete vergleichen will — und
                    // genau das tut man bei einer Adresse, die der Schluessel
                    // IST —, muss die beiden erst ineinander umrechnen.
                    Text(st.gruppeZu(cid)?.name ?? (st.istNotizen(cid) ? t('notes') : shortId(adresseFormatiert(cid))), maxLines: 1, overflow: TextOverflow.ellipsis, style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                    // "TIPPT ..." an der Stelle der Unterzeile, nicht als
                    // eigene Zeile: sonst sprang die ganze Unterhaltung um eine
                    // Zeile, jedes Mal, wenn die Gegenseite zu tippen anfaengt.
                    Text(st.tipptGerade(cid) ? t('typing').toUpperCase() : t('encDetails').toUpperCase(),
                        style: mono(size: 10, color: st.tipptGerade(cid) ? p.accLight : p.dim, spacing: 1)),
                  ]),
                ),
              ]),
            ),
          ),
          if (!st.istNotizen(cid)) GestureDetector(
            onTap: Gruppe.istGruppenId(cid)
                ? () => gruppenBlatt(cid)
                : () { setState(() => sheet = true); _ladePruefnummer(cid); },
            child: Container(
              width: 30, height: 30, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              child: Text('i', style: TextStyle(color: p.accLight, fontSize: 12)),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      angeheftetLeiste(cid),
      Expanded(
        child: ListView(
          controller: _chatScroll,
          padding: const EdgeInsets.all(17),
          children: [
            Center(child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(hints.join(' · '), textAlign: TextAlign.center, style: mono(size: 10.5, color: p.dim, height: 1.5)))),
            for (int i = 0; i < list.length; i++)
              // Nur die LETZTE Nachricht bewegt sich. Wuerde die ganze Liste
              // beim Oeffnen hereingleiten, waere das eine Vorfuehrung, keine
              // Auskunft — und beim Scrollen zurueck wuerde alles noch einmal
              // tanzen.
              if (i == list.length - 1)
                Hereingleiten(
                  key: ValueKey(list[i].id),
                  vonRechts: list[i].isMine,
                  child: msgBubble(cid, list[i], i),
                )
              else
                msgBubble(cid, list[i], i),
            // Ganz unten, weil es die neueste "Nachricht" ist — auch wenn es
            // noch keine gibt.
            if (st.schwebenderChat == cid) schwebenderAnhang(),
          ],
        ),
      ),
      // WAS NICHT RAUSGING, MUSS DASTEHEN. "zuLang" wurde bisher gesetzt und
      // nirgends gezeigt: die Nachricht verschwand aus dem Eingabefeld und kam
      // nie an, ohne dass irgendwo etwas stand.
      befehlsLeiste(),
      eingabeBezug(),
      if (chatFehlerText() != null)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: p.tint,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.tintLine)),
          child: Text(chatFehlerText()!,
              style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
        ),
      if (Gruppe.istGruppenId(cid) && !(st.gruppeZu(cid)?.aktiv ?? false))
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(17, 14, 17, 18),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: p.lineSoft))),
          child: SafeArea(
            top: false,
            child: Text(t('groupNotMember'), textAlign: TextAlign.center,
                style: mono(size: 12, color: p.dim)),
          ),
        )
      else
      Container(
        padding: const EdgeInsets.fromLTRB(17, 11, 17, 16),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: p.lineSoft))),
        // DER ABSTAND GEHOERT NACH INNEN, nicht um das Container herum: so
        // laeuft die Trennlinie und der Hintergrund bis an den Rand durch, und
        // nur der Inhalt bleibt ueber der Systemleiste. Genauso macht es die
        // Reiterleiste in buildNav().
        //
        // Bei offener Tastatur ist padding.bottom von sich aus 0 — Flutter
        // zieht die Tastaturhoehe ab. Es entsteht also kein doppelter Abstand.
        child: SafeArea(
          top: false,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // DIESER KNOPF WAR EIN BILD. Bis zum 26.07.2026 stand hier ein
          // Container ohne GestureDetector: er sah aus wie ein Knopf, liess
          // sich druecken und tat nichts. Jetzt haengt die Dateiauswahl daran.
          //
          // Waehrend ein Versand laeuft, ist er stumm — einer nach dem
          // anderen. Dass er das ist, sieht man ihm an (p.dim statt p.muted),
          // statt dass ein Tippen ins Leere geht.
          Masse.trefferflaeche(
            // DATEI ODER UMFRAGE. Ein Menue statt zweier Knoepfe: die
            // Eingabezeile ist am Telefon schon voll.
            onTap: st.schwebendeKennung == null ? () => plusMenue(cid) : null,
            child: Container(
              width: 36, height: 36, alignment: Alignment.center,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: st.schwebendeKennung == null ? p.line : p.lineSoft)),
              child: Text('+',
                  style: TextStyle(
                      color: st.schwebendeKennung == null ? p.muted : p.dim,
                      fontSize: 16,
                      height: 1)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 2),
              child: TextField(
                controller: draftCtl,
                // INKOGNITO-TASTATUR, wie bei Signal und Threema — hier immer:
                // die Tastatur soll aus verschluesselten Unterhaltungen keine
                // Woerter lernen und sie spaeter anderswo vorschlagen. Das
                // Woerterbuch der Tastatur ist eine Kopie, die niemand
                // verschluesselt.
                enableIMEPersonalizedLearning: false,
                onChanged: (text) {
                  if (st.letzterFehler == 'zuLang') st.vergissFehler();
                  // Ein Befehl ist kein Tippen fuer die Gegenseite: wer
                  // "/timer" schreibt, schreibt niemandem.
                  st.eingabeGeaendert(cid, text.startsWith('/') ? '' : text);
                  // Neu zeichnen, solange ein Befehl dasteht — und EINMAL
                  // danach, damit die Leiste auch wieder verschwindet.
                  final befehl = text.startsWith('/');
                  if (befehl || _warBefehl) setState(() {});
                  _warBefehl = befehl;
                },
                style: mono(size: 13.5, color: p.ink),
                cursorColor: p.accent,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => send(),
                decoration: InputDecoration.collapsed(hintText: t('message'), hintStyle: mono(size: 13.5, color: p.dim)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // SPRACHNACHRICHT: nur, wo es den Kanal gibt (Android). Einmal
          // tippen nimmt auf, noch einmal tippen schickt; das Kreuz daneben
          // verwirft. Kein "gedrueckt halten": das verlangt eine ruhige Hand,
          // und ein verrutschter Daumen schickte eine halbe Nachricht.
          if (st.spracheMoeglich && _bearbeitungsZiel == null) ...[
            if (_aufnahmeSeit != null) ...[
              Semantics(
                button: true,
                label: t('voiceDiscard'),
                child: GestureDetector(
                  onTap: _verwirfAufnahme,
                  child: Container(
                    width: 36, height: 36, alignment: Alignment.center,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
                    child: Text('×', style: TextStyle(color: p.muted, fontSize: 16, height: 1)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Semantics(
              button: true,
              label: _aufnahmeSeit == null ? t('voice') : t('voiceSend'),
              child: GestureDetector(
                onTap: () => _aufnahmeSeit == null ? _starteAufnahme(cid) : _schickeAufnahme(cid),
                child: Container(
                  key: ValueKey(_aufnahmeSeit == null ? 'mikro-bereit' : 'mikro-laeuft'),
                  height: 36, alignment: Alignment.center,
                  constraints: const BoxConstraints(minWidth: 36),
                  padding: EdgeInsets.symmetric(horizontal: _aufnahmeSeit == null ? 0 : 10),
                  decoration: BoxDecoration(
                      color: _aufnahmeSeit == null ? null : p.tint,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _aufnahmeSeit == null ? p.line : p.tintLine)),
                  // GEZEICHNET, NICHT GESETZT: Punkt = aufnehmen, Quadrat =
                  // anhalten, wie an jedem Rekorder. Als Textzeichen (● ■)
                  // hing ihre Groesse an der Schrift — das ● war in Chivo Mono
                  // ein Stecknadelkopf neben dem vollen "+" (Emulatorlauf
                  // 25.09.2026).
                  child: _aufnahmeSeit == null
                      ? Container(
                          width: 11, height: 11,
                          decoration: BoxDecoration(color: p.muted, shape: BoxShape.circle))
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                              width: 9, height: 9,
                              decoration: BoxDecoration(
                                  color: p.tintInk, borderRadius: BorderRadius.circular(1.5))),
                          const SizedBox(width: 8),
                          Text(_aufnahmeDauer(), style: mono(size: 12, color: p.tintInk)),
                        ]),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: send,
            // LANGER DRUCK PLANT, wie bei Signal. Rechtsklick am Rechner.
            onLongPress: _planeSenden,
            onSecondaryTap: _planeSenden,
            child: Container(
              height: 36, alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.accent)),
              child: Text(t('send').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
            ),
          ),
          ]),
        ),
      ),
    ]);
  }

  /// Datei aussuchen und schicken.
  ///
  /// Der Zugang wird IMMER freigegeben, auch wenn das Senden scheitert —
  /// sonst bleibt eine Dateikennung offen, und davon hat ein Prozess nur eine
  /// begrenzte Zahl. Nach ein paar abgebrochenen Versuchen ginge gar nichts
  /// mehr, und niemand wuesste warum.
  Future<void> anhangWaehlen(String cid) async {
    final gewaehlt = await st.dateien.waehlen();
    if (gewaehlt == null) return;
    _selbstGeschrieben = true;
    try {
      await st.anhangSenden(cid, gewaehlt.datei,
          name: gewaehlt.name, groesse: gewaehlt.groesse);
    } finally {
      await st.dateien.gibFrei(gewaehlt.zettel);
    }
  }

  Future<void> oeffneAnhang(AnhangEintrag a) async {
    final pfad = a.pfad;
    if (pfad == null) return;
    final ging = await st.dateien.oeffne(pfad, name: a.name);
    if (!ging && mounted) {
      // Keine App auf dem Geraet kann diese Art Datei oeffnen. Das ist keine
      // Panne, sondern eine Auskunft — und sie gehoert dorthin, wo der Nutzer
      // gerade hinsieht.
      st.setzeFehler('anhangKeineApp');
    }
  }

  /// Was ueber der Eingabezeile steht, wenn etwas schiefging.
  ///
  /// AN EINER STELLE STATT AN FUENF. Vorher hing hier nur 'zuLang'; jede neue
  /// Fehlerart haette eine weitere if-Zeile im Aufbau gebraucht, und die
  /// erste, die jemand vergisst, verschwindet spurlos. Genau so war 'zuLang'
  /// selbst einmal gesetzt und nirgends gezeigt.
  String? chatFehlerText() {
    final f = st.letzterFehler;
    if (f == null) return null;
    if (f == 'zuLang') return t('tooLong');
    if (f == 'nichtMehrMoeglich') return t('notPossible');
    if (f == 'geplantVorbei') return t('schedulePast');
    if (f == 'mikrofonNein') return t('micDenied');
    if (f == 'mikrofonDauerhaft') return t('micDeniedForever');
    if (f == 'aufnahmeFehler') return t('micFailed');
    if (f == 'lagerVoll') return t('attachFull');
    if (f == 'tagesmenge') return t('attachQuota');
    if (f == 'anhangKaputt') return t('attachBroken');
    if (f == 'anhangNetz' || f == 'anhangFehler') return t('attachNet');
    if (f == 'anhangLaeuft') return t('attachBusy');
    if (f == 'anhangKeineApp') return t('attachNoApp');
    if (f == 'nurNahbereich') return t('nearOnlyNoAttach');
    if (f.startsWith('anhangZuGross:')) return t('attachTooBig');
    // WAS HIER NICHT AUFGEZAEHLT IST, WIRD TROTZDEM GEZEIGT.
    //
    // Vorher stand hier `return null` — jeder Fehler ohne eigenen Satz
    // verschwand also spurlos. Das ist die schlechteste aller Auskuenfte: der
    // Nutzer sieht, dass nichts ankommt, und die App schweigt dazu.
    //
    // Ein unuebersetzter technischer Text ist haesslich, aber er laesst sich
    // abfotografieren und weitergeben. Genau das brauchte ich am 29.07.2026
    // und hatte es nicht.
    return f;
  }

  Widget msgBubble(String cid, Message m, int i) {
    final me = m.isMine;
    final time = zeitVon(m.timestamp);
    // Sprachnachrichten gibt es in Fassung 1 noch nicht — der Entwurf zeigte
    // sie, der Kern kennt nur Text. Lieber nichts anzeigen, als etwas
    // vorzutaeuschen — die Darstellung dafuer steht in der Versionsgeschichte
    // und kommt zurueck, sobald es Sprachnachrichten wirklich gibt.
    final bub = BoxDecoration(
      color: me ? p.tint : p.surf,
      borderRadius: me
          ? const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(2))
          : const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(2), bottomRight: Radius.circular(8)),
      border: me ? Border.all(color: p.tintLine) : null,
    );
    final reaktionen = st.reaktionenZu(cid, m.id);
    final bezug = st.bezugVon(m);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: me ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
        Flexible(
          child: GestureDetector(
          // Langdruck am Telefon, Rechtsklick am Rechner — dasselbe Menue.
          onLongPress: () => nachrichtMenue(cid, m),
          onSecondaryTap: () => nachrichtMenue(cid, m),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 252),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: bub,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              // DAS ZITAT KOMMT AUS DEM EIGENEN VERLAUF, nicht aus der
              // Nachricht. Steht die Bezugsnachricht hier nicht (mehr), sagt
              // die Blase das — statt etwas zu zeigen, das der Absender
              // behauptet.
              // IN EINER GRUPPE: wer es geschrieben hat. Ohne das waeren alle
              // fremden Blasen gleich, und niemand wuesste, wer was sagt.
              if (!me && Gruppe.istGruppenId(cid))
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(shortId(adresseFormatiert(m.senderId)),
                        style: mono(size: 9.5, weight: FontWeight.w600, color: p.accLight)),
                  ),
                ),
              if (m.antwortAuf != null && !m.widerrufen)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  decoration: BoxDecoration(
                      color: p.surf2,
                      borderRadius: BorderRadius.circular(4),
                      border: Border(left: BorderSide(color: p.accent, width: 2))),
                  child: Text(bezug == null ? t('replyGone') : auszug(bezug),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: mono(size: 11, color: p.muted, height: 1.4)),
                ),
              if (m.widerrufen)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(me ? t('deletedMine') : t('deletedMsg'),
                      style: TextStyle(fontSize: 13, color: p.dim, fontStyle: FontStyle.italic, height: 1.4)),
                )
              else if (m.kind == MessageKind.anhang)
                anhangInhalt(cid, m)
              else if (m.kind == MessageKind.umfrage)
                umfrageInhalt(cid, m)
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: entschluesselt(
                      m,
                      TextStyle(fontSize: 13.5, color: p.ink, height: 1.4),
                      FormatierterText(m.text,
                          stil: TextStyle(fontSize: 13.5, color: p.ink, height: 1.4),
                          festStil: mono(size: 12.5, color: p.ink, height: 1.4),
                          verdeckt: p.muted)),
                ),
              const SizedBox(height: 3),
              Row(mainAxisSize: MainAxisSize.min, children: [
                // DAS EINZIGE, WAS DIE NAEHE SICHTBAR MACHT.
                //
                // Hier steht, wie diese Nachricht gegangen IST — nicht, wo
                // jemand gerade IST. Der Unterschied ist der Grund, warum es
                // an keiner Stelle dieser App eine Anwesenheitsanzeige gibt:
                // ein Punkt am Kontakt waere bequem und verriete jedes Mal,
                // wer neben wem sitzt.
                //
                // Ein Wort statt eines Zeichens. Ein Funkwellen-Glyph waere
                // kuerzer und muesste doch erklaert werden — und ob ihn eine
                // Schrift ueberhaupt hat, weiss man erst auf dem Geraet.
                if (m.ueberNaehe) ...[
                  Semantics(
                    button: true,
                    label: t('viaNearbyTitle'),
                    child: GestureDetector(
                      onTap: _erklaereNaehe,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 4),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: p.tintLine)),
                        child: Text(t('viaNearby').toUpperCase(),
                            style: mono(
                                size: 8,
                                weight: FontWeight.w600,
                                color: p.accLight,
                                spacing: 0.9)),
                      ),
                    ),
                  ),
                ],
                if (m.sternAm != null && !m.widerrufen) ...[
                  Text('★', key: ValueKey('stern-${m.id}'),
                      style: TextStyle(fontSize: 10, color: p.accLight, height: 1)),
                  const SizedBox(width: 5),
                ],
                if (m.bearbeitet && !m.widerrufen) ...[
                  Text(t('edited'), style: mono(size: 9.5, color: p.dim)),
                  const SizedBox(width: 5),
                ],
                // GEPLANT: statt der Uhrzeit und der Uhr der Zeitpunkt, zu
                // dem sie hinausgeht — sonst sahe sie aus wie eine, die
                // haengt.
                if (m.geplantFuer != null && m.status == MessageStatus.sending)
                  Text('${t('scheduledFor')} ${zeitVon(m.geplantFuer!)}',
                      style: mono(size: 9.5, color: p.accLight))
                else
                Text(time, style: mono(size: 9.5, color: p.dim)),
                if (me && !(m.geplantFuer != null && m.status == MessageStatus.sending)) ...[
                  const SizedBox(width: 5),
                  // Ein Haken je erreichter Stufe: abgeschickt, zugestellt,
                  // gelesen. Solange sie noch beim Absender liegt, eine Uhr.
                  Text(
                    switch (m.status) {
                      MessageStatus.sending => '◷',
                      MessageStatus.sent => '✓',
                      MessageStatus.delivered => '✓✓',
                      MessageStatus.read => '✓✓',
                      MessageStatus.failed => '!',
                    },
                    style: mono(
                        size: 9.5,
                        color: m.status == MessageStatus.read
                            ? p.accLight
                            : p.dim),
                  ),
                ],
              ]),
            ]),
          ),
          ),
        ),
      ]),
      if (reaktionen.isNotEmpty) reaktionsLeiste(cid, m, reaktionen),
      ]),
    );
  }

  /// Die Reaktionen unter einer Blase: je Zeichen eines, mit Anzahl.
  /// Die eigene ist hervorgehoben; antippen nimmt sie zurueck.
  Widget reaktionsLeiste(String cid, Message m, Reaktionen r) {
    final zaehler = <String, int>{};
    for (final z in r.values) {
      zaehler[z] = (zaehler[z] ?? 0) + 1;
    }
    final meine = r[st.meineAdresse];
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(spacing: 4, children: [
        for (final e in zaehler.entries)
          Semantics(
            button: e.key == meine,
            label: '${e.key} ${e.value}',
            // Sonst liest die Vorleseschrift die Reaktion zweimal: einmal
            // aus diesem Etikett, einmal aus dem Text darunter.
            excludeSemantics: true,
            child: GestureDetector(
              onTap: e.key == meine ? () => st.reagiere(cid, m.id, null) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: e.key == meine ? p.tint : p.surf,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: e.key == meine ? p.tintLine : p.line)),
                child: Text(e.value > 1 ? '${e.key} ${e.value}' : e.key,
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════ Anhaenge
  //
  // Eine Anhang-Blase zeigt IMMER dasselbe oben — Kaestchen, Name, Groesse —
  // und darunter das, was gerade zu tun ist. Die Reihenfolge bleibt also
  // gleich, waehrend sich der Zustand aendert; nur der untere Teil wechselt.
  // Ein Aufbau, der bei jedem Zustand anders aussieht, laesst eine Liste
  // unruhig wirken, obwohl sich nur eine Zeile bewegt hat.

  /// Die Dateiendung in einem Kaestchen, hoechstens vier Zeichen.
  ///
  /// KEIN SYMBOLZEICHEN. Die App zeichnet ihre Symbole als Text (‹, +, ✓✓),
  /// und Doto hat nicht jedes Zeichen — ein fehlendes waere ein leeres
  /// Rechteck. Die Endung gibt es immer, sie ist in jeder Schrift vorhanden,
  /// und sie sagt mehr als ein allgemeines Dateisymbol.
  Widget endungsKaestchen(String name) {
    final punkt = name.lastIndexOf('.');
    var endung = punkt > 0 && punkt < name.length - 1
        ? name.substring(punkt + 1).toUpperCase()
        : '···';
    if (endung.length > 4) endung = endung.substring(0, 4);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.line),
      ),
      child: Text(endung,
          maxLines: 1,
          style: mono(
              size: endung.length > 3 ? 7.5 : 9,
              color: p.muted,
              spacing: 0.5)),
    );
  }

  /// Aus Bytes eine Zahl, die man vorlesen kann.
  ///
  /// Tausenderschritte und nicht 1024er: die Zahl steht neben einem
  /// Dateinamen, nicht in einem Speichermonitor, und "1,2 GB" ist das, was
  /// auch auf der Rechnung des Mobilfunkanbieters steht.
  static String groesseText(int bytes) {
    if (bytes < 1000) return '$bytes B';
    if (bytes < 1000 * 1000) return '${(bytes / 1000).toStringAsFixed(0)} KB';
    if (bytes < 1000 * 1000 * 1000) {
      return '${(bytes / 1000000).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
  }

  /// Ein Balken. Duenn, ohne Rahmen, ohne Rundung an den Enden — er soll den
  /// Blick nicht auf sich ziehen, sondern nur sagen, dass es vorangeht.
  Widget fortschrittsBalken(double anteil, {bool mitZahl = true}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
                color: p.line, borderRadius: BorderRadius.circular(2)),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: anteil.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                    color: p.accent, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
          if (mitZahl) ...[
            const SizedBox(height: 4),
            Text('${(anteil * 100).clamp(0, 100).toStringAsFixed(0)} %',
                style: mono(size: 9.5, color: p.dim)),
          ],
        ],
      );

  /// Der Knopf unter einer Anhang-Blase. Schmaler als outlineBtn, damit er in
  /// eine Blase passt, ohne sie zu sprengen.
  Widget anhangKnopf(String text, VoidCallback? tun, {bool betont = false}) =>
      Masse.trefferflaeche(
        onTap: tun,
        child: Container(
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: betont ? p.accent : p.line),
          ),
          child: Text(text.toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w600,
                  color: tun == null ? p.dim : p.ink,
                  spacing: 1.1)),
        ),
      );

  /// Der Kopf jeder Anhang-Blase: Kaestchen, Name, Groesse.
  Widget anhangKopf(String name, int groesse, {String? statt}) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          endungsKaestchen(name),
          const SizedBox(width: Masse.nah),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Der Name kommt von der Gegenstelle. Er ist beim Speichern
                // schon gesaeubert worden; hier wird er nur noch gekuerzt,
                // damit ein 200 Zeichen langer Name die Blase nicht sprengt.
                Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mono(size: 12, color: p.ink, height: 1.35)),
                const SizedBox(height: 2),
                Text(statt ?? groesseText(groesse),
                    style: mono(size: 9.5, color: p.dim)),
              ],
            ),
          ),
        ],
      );

  Widget anhangInhalt(String cid, Message m) {
    final a = st.anhangZu(cid, m.id);
    if (a == null) {
      // Die Nachricht sagt "Anhang", der Eintrag fehlt. Sollte es nicht
      // geben — beides wird in derselben Transaktion geschrieben. Falls doch,
      // lieber der Name als eine leere Blase.
      return Align(
          alignment: Alignment.centerLeft,
          child: anhangKopf(m.text, 0, statt: '—'));
    }

    final f = st.fortschritt[m.id];
    final laeuft = a.zustand == AnhangZustand.laedt ||
        (m.isMine && m.status == MessageStatus.sending);

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          anhangKopf(a.name, a.groesse),
          if (laeuft) ...[
            const SizedBox(height: Masse.innen),
            SizedBox(width: 200, child: fortschrittsBalken(f?.anteil ?? 0)),
          ] else ...[
            const SizedBox(height: Masse.nah),
            switch (a.zustand) {
              // Beim eigenen Anhang liegt die Datei ohnehin hier. Ein Knopf
              // "holen" waere Unsinn, ein Knopf "oeffnen" ist es nicht.
              AnhangZustand.da => Row(mainAxisSize: MainAxisSize.min, children: [
                  if (sprachName.hasMatch(a.name))
                    anhangKnopf(t('voicePlay'), () async {
                      // Erst der eigene Spieler, sonst die App des Systems.
                      if (a.pfad == null || !await Sprache.spiele(a.pfad!)) {
                        await oeffneAnhang(a);
                      }
                    }, betont: true)
                  else
                  anhangKnopf(t('attachOpen'), () => oeffneAnhang(a)),
                  const SizedBox(width: Masse.nah),
                  Flexible(
                      child: Text(t('attachHere'),
                          style: mono(size: 9.5, color: p.dim))),
                ]),
              AnhangZustand.angekuendigt => anhangKnopf(
                  t('attachGet'), () => st.anhangHolen(cid, m.id),
                  betont: true),
              AnhangZustand.gescheitert => anhangKnopf(
                  t('attachAgain'), () => st.anhangHolen(cid, m.id)),
              // KEIN KNOPF. Nach vierzehn Tagen ist der Block weg, und wer
              // ihn geholt hat, hat ihn selbst weggeworfen. "Nochmal
              // versuchen" waere hier eine Luege — deshalb steht stattdessen
              // da, warum.
              AnhangZustand.weg => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t('attachGone'),
                        style: mono(size: 10.5, color: p.muted)),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: 200,
                      child: Text(t('attachGoneWhy'),
                          style: mono(size: 9.5, color: p.dim, height: 1.45)),
                    ),
                  ],
                ),
              AnhangZustand.laedt => const SizedBox.shrink(),
            },
          ],
        ],
      ),
    );
  }

  /// Die Blase, die es noch nicht gibt.
  ///
  /// Ein Versand entsteht erst als Nachricht, wenn ALLES oben ist — bei drei
  /// Gigabyte also nach Minuten. Bis dahin stuende die Unterhaltung
  /// unveraendert da, und niemand wuesste, ob etwas passiert.
  Widget schwebenderAnhang() {
    final f = st.fortschritt[st.schwebendeKennung];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 252),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: p.tint,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(2)),
              border: Border.all(color: p.tintLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                anhangKopf(st.schwebenderName ?? '…',
                    f?.gesamtBytes ?? 0,
                    statt: f == null ? t('attachSend') : null),
                const SizedBox(height: Masse.innen),
                SizedBox(width: 200, child: fortschrittsBalken(f?.anteil ?? 0)),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  // ---- SETTINGS ----
  Widget settingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 11, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('settings')),
        const SizedBox(height: 17),
        label6(t('general')),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('language'), t('languageSub')),
          const SizedBox(height: 8),
          segmented(['en', 'de'], ['English', 'Deutsch'], lang, (v) {
            setState(() { lang = v; _setzeMeldetexte(); });
            // Gespeichert — bis 25.09.2026 vergass die App die Sprache bei
            // jedem Neustart.
            st.setzeEinstellungen(st.einstellungen.copyWith(sprache: v));
          }),
        ])),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('appearance'), t('appearanceSub')),
          const SizedBox(height: 10),
          themenWahl(),
          const SizedBox(height: 14),
          settingHead(t('themeDrift'), t('themeDriftSub')),
          const SizedBox(height: 8),
          segmented(['0', '1', '10', '60'], [t('off'), '1 min', '10 min', '1 h'],
              '${st.einstellungen.themaWandern}',
              (v) => st.setzeEinstellungen(
                  st.einstellungen.copyWith(themaWandern: int.parse(v)))),
        ])),
        const SizedBox(height: 3),
        toggleRow(t('quietHours'), t('quietHoursSub'), st.einstellungen.ruheAn,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(ruheAn: !st.einstellungen.ruheAn))),
        if (st.einstellungen.ruheAn)
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 6, 11, 4),
            child: Row(children: [
              Expanded(child: outlineBtn('${t('quietFrom')} ${_uhr(st.einstellungen.ruheVon)}',
                  () => _waehleRuhe(true), padding: const EdgeInsets.all(10))),
              const SizedBox(width: 8),
              Expanded(child: outlineBtn('${t('quietTo')} ${_uhr(st.einstellungen.ruheBis)}',
                  () => _waehleRuhe(false), padding: const EdgeInsets.all(10))),
            ]),
          ),
        const SizedBox(height: 3),
        toggleRow(t('decryptFx'), t('decryptFxSub'), st.einstellungen.entschluesseln,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                entschluesseln: !st.einstellungen.entschluesseln))),
        const SizedBox(height: 3),
        // Steht bei "Allgemein" und nicht bei "Sicherheit": das ist eine
        // Frage der Bequemlichkeit, nicht des Schutzes. Die beiden nicht zu
        // vermischen ist der Grund, warum die Abschnitte ueberhaupt getrennt
        // sind.
        toggleRow(t('autoScroll'), t('autoScrollSub'), st.einstellungen.autoScroll,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                autoScroll: !st.einstellungen.autoScroll))),
        const SizedBox(height: 22),
        label6(t('access')),
        ...zugriffsBlock(statusMode: false),
        Padding(padding: const EdgeInsets.fromLTRB(11, 3, 11, 0), child: Text(t('minOne'), style: mono(size: 10.5, color: p.dim))),

        // Die Frist erscheint erst, wenn es etwas zu sperren gibt. Ohne
        // Faktor waere sie eine Einstellung ohne Wirkung.
        if (st.faktoren.isNotEmpty) ...[
          const SizedBox(height: 3),
          settingCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                settingHead(t('lockDelay'), t('lockDelaySub')),
                const SizedBox(height: 8),
                segmented(
                  const ['0', '60', '300', '-1'],
                  [t('delayNow'), t('delay1m'), t('delay5m'), t('delayNever')],
                  '${st.sperrfristAlsZahl}',
                  (v) => _setzeSperrfrist(int.parse(v)),
                ),
              ])),
        ],

        const SizedBox(height: 22),
        label6(t('receiving')),
        settingCard(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('bgReceive'), t('bgReceiveSub')),
          const SizedBox(height: 8),
          // OHNE PUSH AUF DEM DESKTOP. '-2' ist der Push-Takt, und der laeuft
          // ueber UnifiedPush — ein Android-Plugin. Auf Windows waehlbar zu
          // sein, aber beim Umschalten zu scheitern, ist schlechter als nicht
          // angeboten zu werden. Die Verbindung bleibt dort ohnehin offen, ein
          // Weckdienst von aussen wird also nicht gebraucht.
          segmented(
            _nurAufAndroid
                ? const ['0', '-2', '-1', '15', '60']
                : const ['0', '-1', '15', '60'],
            _nurAufAndroid
                ? [t('bgOff'), t('bgPush'), t('bgLive'), t('bg15'), t('bg60')]
                : [t('bgOff'), t('bgLive'), t('bg15'), t('bg60')],
            '${st.empfangsTakt.minuten}',
            (v) => _setzeEmpfangsTakt(int.parse(v)),
          ),
          const SizedBox(height: 10),
          Text(_empfangErklaerung(),
              style: mono(size: 11, color: p.dim, height: 1.55)),

          // Die Anleitung bleibt erreichbar, auch wenn Push schon laeuft:
          // ntfy kann nach einer Neuinstallation wieder auf seinem eigenen
          // Server stehen, und dann geht es ohne erkennbaren Grund nicht mehr.
          if (st.empfangsTakt.angestossen) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => setState(() => enroll = 'pushHilfe'),
              child: Text(t('pushGuideLink').toUpperCase(),
                  style: mono(
                      size: 10,
                      weight: FontWeight.w600,
                      color: p.accLight,
                      spacing: 1.2)),
            ),
          ],

          // DER WIDERSPRUCH, DEN DER NUTZER KENNEN MUSS: eine Sperre, die
          // sofort zugeht, macht Hintergrundempfang unmoeglich. Nicht aus
          // Bequemlichkeit — der Relay verlangt eine Unterschrift mit dem
          // Identitaetsschluessel, und der liegt hinter der Sperre.
          if (st.empfangsTakt.an && !st.empfangMoeglich) ...[
            const SizedBox(height: 10),
            _hinweisKasten(t('bgConflict'), warnend: false),
          ],
        ])),

        // IN DER NAEHE steht VOR der Sicherheit, weil es ein Weg ist und
        // keine Einschraenkung. Die Einschraenkung "nur in der Naehe" ist
        // mitgewandert — sie gehoert zu dem Weg, den sie erzwingt, nicht zu
        // Bildschirmfotos und Lesebestaetigungen.
        // NUR WO ES FUNK GIBT. Der Nahbereich haengt vollstaendig am
        // Kotlin-Kanal `bitdm/nahfunk`; auf Windows gibt es ihn nicht, und zwei
        // Schalter, die nichts schalten, sind schlimmer als keine.
        if (_nurAufAndroid) ...[
          const SizedBox(height: 22),
          nahbereichBlock(),
        ],

        const SizedBox(height: 22),
        label6(t('security')),
        toggleRow(t("screenshot"), t("screenshotSub"), st.einstellungen.blockScreenshots,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                blockScreenshots: !st.einstellungen.blockScreenshots))),
        const SizedBox(height: 3),
        toggleRow(t("readReceipts"), t("readReceiptsSub"), st.einstellungen.readReceipts,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                readReceipts: !st.einstellungen.readReceipts))),
        const SizedBox(height: 3),
        // VERTRAUENSKONTAKTE: die zwoelf Woerter in Teile zerlegt (Shamir,
        // core/crypto/teilgeheimnis.dart). Einige zusammen stellen die
        // Identitaet wieder her, einer allein verraet nichts.
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('trustTitle'), t('trustSub')),
          const SizedBox(height: 8),
          outlineBtn(t('trustCreate'), _erzeugeTeile, padding: const EdgeInsets.all(9)),
        ])),
        const SizedBox(height: 3),
        // SICHERUNG: Kontakte und Verlauf als verschluesselte Datei, die nur
        // mit den zwoelf Woertern aufgeht. Zwei Knoepfe, weil es zwei Wege
        // sind, und die Erklaerung darunter sagt, was NICHT darin ist.
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('backup'), t('backupSub')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: outlineBtn(t('backupCreate'), () async {
              final wo = await st.sichere();
              if (wo != null && mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text('${t('backupSaved')} $wo')));
              }
            }, padding: const EdgeInsets.all(9))),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('backupRestore'), () async {
              final n = await st.spieleSicherungEin();
              if (n != null && mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text('${t('backupRestored')} $n')));
              }
            }, accent: false, padding: const EdgeInsets.all(9))),
          ]),
          if (st.letzterFehler == 'sicherungPasstNicht') ...[
            const SizedBox(height: 6),
            Text(t('backupWrong'), style: mono(size: 11.5, color: p.tintInk, height: 1.4)),
          ],
        ])),
        const SizedBox(height: 3),
        // DAS PANIK-PASSWORT. Nur, wenn es eine Sperre gibt — ohne Sperre
        // fragt die App nach nichts, und ein Panik-Passwort haette keinen
        // Ort, an dem man es eingeben koennte.
        if (st.sichtbareFaktoren.isNotEmpty) ...[
          toggleRow(t('panicPw'), t('panicPwSub'), st.hatPanikPasswort,
              () => st.hatPanikPasswort
                  ? st.entfernePanikPasswort()
                  : _richtePanikPasswortEin()),
          const SizedBox(height: 3),
        ],
        toggleRow(t("typingSetting"), t("typingSettingSub"), st.einstellungen.tippAnzeige,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                tippAnzeige: !st.einstellungen.tippAnzeige))),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('selfDestruct'), t('selfDestructSub')),
          const SizedBox(height: 8),
          segmented(["off", "1h", "24h", "7d"], [t("off"), t("h1"), t("h24"), t("d7")],
              _fristSchluessel,
              (v) => st.setzeEinstellungen(st.einstellungen.copyWith(
                  messageLifetime: _fristen[v], loescheLebensdauer: _fristen[v] == null))),
        ])),
        // Der Verbindungstest steht bei der Sicherheit und nicht ganz unten:
        // wer hier landet, sucht meist einen Fehler und soll ihn finden,
        // bevor er die Notfallknoepfe erreicht.
        const SizedBox(height: 3),
        settingCard(
            onTap: () {
              go('test');
              st.verbindungPruefen();
            },
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('connTestRow'),
                          style: TextStyle(fontSize: 13.5, color: p.ink)),
                      Text(t('connTestRowSub'),
                          style: mono(size: 11, color: p.dim)),
                    ]),
              ),
              Text('›', style: TextStyle(fontSize: 18, color: p.dim)),
            ])),

        const SizedBox(height: 22),
        label6(t('identity')),
        settingCard(
          onTap: () => go('id'),
          child: Row(children: [
            // Expanded: auf Deutsch ist die Beschriftung laenger, und die Zeile
            // lief bei 420 Punkten Breite um 38 ueber (Widget-Test 25.09.2026).
            Expanded(child: Text(t('myIdQr'), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: p.ink))),
            const SizedBox(width: 8),
            Text(shortId(meineAdresseAnzeige), style: doto(size: 12.5, weight: FontWeight.w600, color: p.dim, spacing: 0.8)),
          ]),
        ),
        const SizedBox(height: 3),
        // DAS SCHLUESSELBILD. Hier stand bis 25.09.2026 ein erfundener
        // "Fingerabdruck" ('b7d2 4e10 9af3') — derselbe Fehler, den die
        // Pruefnummer im Verschluesselungsblatt schon hinter sich hatte: er sah
        // nach Sicherheit aus und war keine. Das Bild entsteht aus der eigenen
        // Adresse, und die Kontakte sehen fuer diesen Schluessel dasselbe.
        settingCard(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SchluesselbildAnsicht(schluessel: st.meineAdresse, farbe: p.accLight, leer: p.line, punkt: 7),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('keyArt'), style: TextStyle(fontSize: 13.5, color: p.ink)),
            const SizedBox(height: 3),
            Text(t('keyArtSelf'), style: mono(size: 10.5, color: p.dim, height: 1.45)),
          ])),
        ])),
        const SizedBox(height: 22),
        label6(t('emergency')),
        // Die Notfallzeile ist keine settingCard (eigene Warnfarben), braucht
        // die Huelle aber genauso: sie ist die folgenreichste Zeile der App.
        _Bedienbar(
          imFenster: _imFenster,
          onTap: () => setState(() => panic = true),
          bau: (ueber, fokus) => GestureDetector(
            onTap: () => setState(() => panic = true),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: ueber || fokus ? p.accHover : p.tintLine)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('panic'), style: TextStyle(fontSize: 13.5, color: p.tintInk)),
                Text(t('panicSub'), style: mono(size: 11, color: p.muted, height: 1.4)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  /// Eine Karte in den Einstellungen. Mit [onTap] ist sie eine ANTIPPBARE
  /// Zeile — und dann im Fenster auch zeigerbar, ueberfahrbar und tabbar.
  ///
  /// HIER UND NICHT AN JEDER ZEILE: 'set' hat die meisten antippbaren Zeilen der
  /// App, und die liefen alle als blanke GestureDetector um diese Karte. Ein
  /// [_Bedienbar] je Aufrufstelle waere derselbe Fehler in sechs Ausfuehrungen —
  /// die siebte Zeile haette ihn wieder. Ohne [onTap] bleibt die Karte reine
  /// Anzeige (die Fingerabdruck-Zeile), und dort gehoert kein Zeigerwechsel hin.
  Widget settingCard({required Widget child, VoidCallback? onTap}) {
    Widget karte(bool ueber, bool fokus) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          // RUECKMELDUNG OHNE LAYOUT, wie bei `outlineBtn`: nur die Fuellung
          // wechselt, kein Rahmen — ein Rahmen haette den Inhalt jeder Zeile
          // beim Ueberfahren um 1 px eingerueckt. `p.wash` liegt UEBER der
          // Flaeche und ersetzt sie nicht (er ist durchscheinend, 0x24/0x1F in
          // data.dart), sonst waere die Karte beim Ueberfahren verschwunden.
          decoration: BoxDecoration(
              color: ueber || fokus
                  ? Color.alphaBlend(p.wash, p.surf2)
                  : p.surf2,
              borderRadius: BorderRadius.circular(8)),
          child: child,
        );
    if (onTap == null) return karte(false, false);
    return _Bedienbar(
      imFenster: _imFenster,
      onTap: onTap,
      bau: (ueber, fokus) =>
          GestureDetector(onTap: onTap, child: karte(ueber, fokus)),
    );
  }

  Widget settingHead(String title, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13.5, color: p.ink)),
        Text(sub, style: mono(size: 11, color: p.dim)),
      ]);

  Widget segmented(List<String> keys, List<String> labels, String cur, ValueChanged<String> onPick) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        for (int i = 0; i < keys.length; i++)
          Expanded(
            child: _Bedienbar(
              imFenster: _imFenster,
              onTap: () => onPick(keys[i]),
              bau: (ueber, fokus) => GestureDetector(
                onTap: () => onPick(keys[i]),
                child: Container(
                  margin: EdgeInsets.only(right: i < keys.length - 1 ? 3 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: cur == keys[i]
                          ? p.tint
                          : (ueber || fokus ? p.wash : Colors.transparent),
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: cur == keys[i] ? p.tintInk : p.muted)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  /// Die Themen als Kacheln: jede zeigt ihre eigenen Farben und Schrift, nicht
  /// die des gerade gueltigen Themas — sonst saehe man nicht, wohin man geht.
  Widget themenWahl() {
    final gewaehlt = st.einstellungen.thema;
    return LayoutBuilder(builder: (context, platz) {
      final breite = ((platz.maxWidth - 16) / 3).floorToDouble();
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final th in _themen)
          Semantics(
            button: true,
            selected: th.id == gewaehlt,
            label: th.nameIn(lang),
            excludeSemantics: true,
            child: GestureDetector(
              key: ValueKey('thema-${th.id}'),
              onTap: () => st.setzeEinstellungen(st.einstellungen.copyWith(thema: th.id)),
              child: Container(
                width: breite,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: th.pal.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: th.id == gewaehlt ? p.accLight : th.pal.line,
                      width: th.id == gewaehlt ? 2 : 1),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Eine Mini-Blase und ein Akzentstrich: genug, um das Thema
                  // zu erkennen, ohne eine ganze Vorschau zu zeichnen.
                  Row(children: [
                    Container(width: 14, height: 14,
                        decoration: BoxDecoration(color: th.pal.accent, borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 5),
                    Expanded(child: Container(height: 8,
                        decoration: BoxDecoration(color: th.pal.surf, borderRadius: BorderRadius.circular(3)))),
                  ]),
                  const SizedBox(height: 5),
                  Container(height: 3, width: breite * 0.45,
                      decoration: BoxDecoration(color: th.pal.accLight, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 7),
                  Text(th.nameIn(lang),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: th.monoSchrift, fontSize: 10.5,
                          fontWeight: FontWeight.w600, color: th.pal.ink)),
                ]),
              ),
            ),
          ),
      ]);
    });
  }

  /// Laesst eine eintreffende Textnachricht sich sichtbar entschluesseln —
  /// einmal, wenn ihre Blase zum ersten Mal erscheint. Danach [fertig].
  Widget entschluesselt(Message m, TextStyle stil, Widget fertig) {
    if (m.isMine || !st.einstellungen.entschluesseln) return fertig;
    var seit = _entschluesseltSeit[m.id];
    if (seit == null) {
      if (!st.frischeNachrichten.remove(m.id)) return fertig;
      seit = _entschluesseltSeit[m.id] = DateTime.now();
    }
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return fertig;
    if (DateTime.now().difference(seit) >= EntschluesselnderText.dauerFuer(m.text)) {
      return fertig;
    }
    return EntschluesselnderText(
      key: ValueKey('entschluesseln-${m.id}'),
      // Der Salat entsteht aus dem SCHLICHTEN Text: sonst stuende ein Spoiler
      // waehrend des Effekts fuer einen Augenblick im Klartext da.
      text: Formatierung.schlicht(m.text),
      stil: stil,
      seit: seit,
      chiffre: _thema.chiffre,
      fertig: fertig,
    );
  }

  /// Eine Zeile mit Schalter.
  ///
  /// DER ZUSTAND MUSS ANGESAGT WERDEN, und er wurde es nicht.
  ///
  /// Der Schalter ist reine Grafik: eine Farbe und eine Ausrichtung. Wer ihn
  /// sieht, weiss sofort, ob er an ist. Wer ihn vorlesen laesst, hoerte
  /// bisher nur "Neuen Nachrichten folgen. Springt zur neuesten Nachricht." —
  /// weder den Zustand noch ueberhaupt, dass es ein Schalter ist. Damit war
  /// jede Einstellung der App fuer einen blinden Nutzer unlesbar: umlegen
  /// ginge, feststellen wohin nicht.
  ///
  /// Aufgefallen am 29.07.2026 beim Durchgehen der taeglichen Ablaeufe auf
  /// dem Emulator — betroffen waren ALLE fuenf Schalter der Einstellungen.
  ///
  /// `toggled` setzt in Android die Merkmale "checkable" und "checked"; die
  /// Vorlesefunktion sagt dann von sich aus "an" oder "aus" dazu. `container`
  /// haelt den Knoten beisammen — sonst verschmilzt der Zustand mit der
  /// Nachbarzeile und haengt an beiden.
  Widget toggleRow(String title, String sub, bool on, VoidCallback onTap) =>
      Semantics(
        toggled: on,
        container: true,
        child: settingCard(
          onTap: onTap,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 13.5, color: p.ink)),
                Text(sub, style: mono(size: 11, color: p.dim)),
              ]),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 40, height: 22, padding: const EdgeInsets.all(2),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(color: on ? p.tint : p.surf, borderRadius: BorderRadius.circular(99), border: Border.all(color: on ? p.accent : p.line)),
              child: Container(width: 16, height: 16, decoration: BoxDecoration(color: on ? p.accLight : p.muted, shape: BoxShape.circle)),
            ),
          ]),
        ),
      );


  // ══════════════════════════════════════════════════════════ In der Naehe

  /// Der Funk und die Einschraenkung — in dieser Reihenfolge, in EINEM
  /// Abschnitt.
  ///
  /// WARUM ZUSAMMEN. Vorher gab es nur "nur in der Naehe", und der sass bei
  /// der Sicherheit. Das war richtig, solange es den Funk nicht gab: der
  /// Schalter verbot einen Server und baute keinen Weg. Jetzt gibt es beides,
  /// und getrennt waere es irrefuehrend — wer nur die Einschraenkung sieht,
  /// legt sie um und wundert sich, dass nichts mehr ankommt.
  ///
  /// Die Reihenfolge ist die Aussage: erst der WEG, dann das VERBOT.
  Widget nahbereichBlock() {
    final z = st.funkzustand;
    final prefs = st.einstellungen;

    // NUR EIN HINDERNIS, das erste, das zutrifft. Vier Zeilen untereinander
    // waeren eine Fehlerliste; gebraucht wird der naechste Schritt.
    //
    // Die Reihenfolge ist nicht beliebig: die fehlende Berechtigung steht vor
    // dem ausgeschalteten Bluetooth, weil sie sich mit einem Tipp in der App
    // erledigen laesst und das andere einen Weg in die Systemleiste braucht.
    String? hindernis;
    Widget? ausweg;
    if (z != null && !z.geht) {
      if (z.zuAlt) {
        hindernis = t('nearbyTooOld');
      } else if (!z.vorhanden || !z.erweitert) {
        // Beides heisst fuer den Nutzer dasselbe: dieses Telefon kann es
        // nicht. Ob die Hardware ganz fehlt oder nur die erweiterte Werbung,
        // aendert nichts daran, was er tun kann — naemlich nichts.
        hindernis = t('nearbyNoHardware');
      } else if (!z.rechte) {
        // Der Knopf aus den Anleitungen, links eingerueckt wie die Zeile
        // darueber. `Masse.trefferflaeche` sorgt darin fuer eine Flaeche, die
        // man auch mit dem Daumen trifft — deshalb kein eigener Knopf hier.
        Widget links(Widget w) => Align(
            alignment: Alignment.centerLeft,
            child: Padding(
                padding: const EdgeInsets.only(left: 11), child: w));
        if (st.rechteEndgueltigWeg) {
          hindernis = t('nearbyBlocked');
          ausweg = links(_kleinerKnopf(
              t('nearbyOpenSettings'), st.oeffneSystemeinstellungen));
        } else {
          hindernis = t('nearbyNoPerm');
          ausweg = links(_kleinerKnopf(t('nearbyAllow'), _fordereFunkRechte));
        }
      } else if (!z.an) {
        hindernis = t('nearbyBtOff');
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      label6(t('nearby')),
      toggleRow(t('nearbyUse'), t('nearbyUseSub'), prefs.naheAn, _schalteFunkUm),

      if (hindernis != null) ...[
        const SizedBox(height: 3),
        _hinweisKasten(hindernis, warnend: false),
        if (ausweg != null) ...[
          const SizedBox(height: 6),
          ausweg,
        ],
      ],

      // Was es KOSTET, und zwar erst wenn es an ist. Vorher waere es eine
      // Warnung vor etwas, das niemand vorhat.
      // Der Abstand ist hier die Aussage: eng an den Schalter darueber, weit
      // weg vom naechsten Feld. Mit gleichem Abstand nach beiden Seiten las
      // sich der Satz wie eine Anmerkung zu "nur in der Naehe" — also zu dem
      // Schalter, um den es dabei gerade nicht geht.
      if (prefs.naheAn && (z?.geht ?? false)) ...[
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Text(t('nearbyCost'),
              style: mono(size: 11, color: p.dim, height: 1.5)),
        ),
        const SizedBox(height: 13),
      ] else
        const SizedBox(height: 3),

      toggleRow(t('nearOnly'), t('nearOnlySub'), prefs.nurNahbereich,
          () => st.setzeEinstellungen(
              prefs.copyWith(nurNahbereich: !prefs.nurNahbereich))),

      // WIEDER DA, seit die Wegwahl am Nachrichtenweg haengt.
      //
      // Der Hinweis lag eine Weile still, weil er falscher Rat war: der Funk
      // fand zwar Kontakte, trug aber keine Nachrichten, und Bluetooth
      // einzuschalten aenderte an der Zustellung nichts. Jetzt aendert es
      // alles — mit "nur in der Naehe" allein geht ueberhaupt nichts hinaus.
      //
      // NUR WENN "NUR IN DER NAEHE" AN IST UND DER FUNK AUS. Sonst waere es
      // eine Werbung fuer eine Einstellung, um die gerade niemand gebeten
      // hat; hier ist es der fehlende zweite Schalter zu einer Entscheidung,
      // die der Nutzer schon getroffen hat.
      if (prefs.nurNahbereich && !prefs.naheAn) ...[
        const SizedBox(height: 3),
        _hinweisKasten(t('nearbyNeedsBoth')),
      ],

      // DER KASTEN GEHOERT UNTER SEINEN SCHALTER, nicht unter den Link. Er
      // stand vorher darunter, und dazwischen las sich "Wie das funktioniert"
      // wie eine Ueberschrift zu einer Warnung, zu der es nicht gehoert.
      if (prefs.nurNahbereich) ...[
        const SizedBox(height: 3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Masse.innen),
          decoration: BoxDecoration(
              color: p.tint,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.tintLine)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('nearOnlyNow').toUpperCase(),
                style: mono(
                    size: 10,
                    weight: FontWeight.w600,
                    color: p.tintInk,
                    spacing: 1.1)),
            const SizedBox(height: Masse.eng),
            // ZWEI FASSUNGEN, je nachdem ob der Funk an ist. Mit nur einer
            // stuende "Bluetooth ist noch nicht gebaut" direkt unter einem
            // eingeschalteten Bluetooth-Schalter. Jeder Satz fuer sich waere
            // wahr, zusammen saehe es nach einem Fehler aus — und der Nutzer
            // wuesste nicht, welchem von beiden er glauben soll.
            Text(prefs.naheAn ? t('nearOnlyWarnRadio') : t('nearOnlyWarn'),
                style: mono(size: 11.5, color: p.tintInk, height: 1.55)),
          ]),
        ),
      ],

      // Die Anleitung ist IMMER erreichbar, nicht erst wenn etwas an ist.
      // Wer wissen will, was ihn erwartet, soll nachlesen koennen, BEVOR er
      // etwas umlegt.
      const SizedBox(height: 3),
      GestureDetector(
        onTap: () => go('nahHilfe'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 2, 11, 6),
          child: Text(t('nearGuideLink').toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w600,
                  color: p.accLight,
                  spacing: 1.2)),
        ),
      ),
    ]);
  }

  Future<void> _fordereFunkRechte() async {
    await st.erlaubeFunk();
    if (mounted) setState(() {});
  }

  /// Beim EINSCHALTEN erst fragen, dann umlegen.
  ///
  /// Ein Schalter, der auf "an" steht, waehrend die Berechtigung fehlt, waere
  /// eine Einstellung ohne Wirkung — und der Nutzer haette keinen Anlass,
  /// weiter zu suchen. Ausschalten geht dagegen immer sofort.
  /// Entfernt den Kontakt der offenen Unterhaltung — nach Rueckfrage.
  ///
  /// MIT RUECKFRAGE, weil es den ganzen Verlauf mitnimmt und sich nicht
  /// zurueckholen laesst. Der Knopf steht bewusst ohne Betonung da: er ist
  /// noetig, aber nichts, wozu die Oberflaeche einladen sollte.
  Future<void> _entferneOffenenKontakt() async {
    final id = chat;
    if (id == null) return;
    final sicher = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        title: Text(t('removeContact'),
            style: mono(size: 15, weight: FontWeight.w500, color: p.ink)),
        content: Text(t('removeAsk'),
            style: mono(size: 12.5, color: p.muted, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('cancel'), style: mono(size: 12.5, color: p.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('removeDo'),
                style: mono(size: 12.5, weight: FontWeight.w500, color: p.accLight)),
          ),
        ],
      ),
    );
    if (sicher != true || !mounted) return;
    await st.entferneKontakt(id);
    if (!mounted) return;
    // ZURUECK ZUR LISTE, denn die Unterhaltung, die hier offen war, gibt es
    // nicht mehr. Stehenzubleiben zeigte einen leeren Chat zu einem Kontakt,
    // den es nicht mehr gibt.
    setState(() {
      sheet = false;
      chat = null;
    });
    go('chats');
  }

  Future<void> _schalteFunkUm() async {
    final prefs = st.einstellungen;
    if (prefs.naheAn) {
      await st.setzeEinstellungen(prefs.copyWith(naheAn: false));
      return;
    }
    await st.pruefeFunk();
    final z = st.funkzustand;
    if (z != null && !z.geht && !z.rechte && !z.zuAlt && z.vorhanden) {
      final ok = await st.erlaubeFunk();
      if (!ok) {
        if (mounted) setState(() {});
        return;
      }
    }
    await st.setzeEinstellungen(st.einstellungen.copyWith(naheAn: true));
    if (mounted) setState(() {});
  }

  /// Was das Zeichen an einer Nachricht bedeutet.
  void _erklaereNaehe() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 26),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 36,
                    height: 3,
                    decoration: BoxDecoration(
                        color: p.line,
                        borderRadius: BorderRadius.circular(99))),
              ),
              const SizedBox(height: 14),
              h2(t('viaNearbyTitle'), size: 18),
              const SizedBox(height: 10),
              Text(t('viaNearbyWhat'),
                  style: mono(size: 12.5, color: p.muted, height: 1.55)),
            ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════ Verbindungstest

  /// Sagt, WO die Kette reisst — statt "versuch es nochmal".
  ///
  /// Der Bildschirm ist bewusst nuechtern: eine Zeile je Glied, ein Zeichen
  /// davor, die Dauer dahinter, und beim ersten, das nicht haelt, der
  /// technische Grund. Wer ihn abfotografiert und weiterschickt, hat alles
  /// beisammen, was jemand zum Beheben braucht.
  Widget testScreen() {
    Color farbe(Befund b) => switch (b) {
          Befund.gut => p.accLight,
          Befund.schlecht => p.accent,
          Befund.hinweis => p.accLight,
          Befund.uebersprungen => p.dim,
        };
    String zeichen(Befund b) => switch (b) {
          Befund.gut => 'OK',
          Befund.schlecht => '!',
          Befund.hinweis => '·',
          Befund.uebersprungen => '–',
        };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('set')),
          const SizedBox(width: 11),
          Expanded(child: h2(t('connTest'), size: 20)),
        ]),
        const SizedBox(height: 6),
        Text(t('connTestSub'), style: mono(size: 12, color: p.dim, height: 1.5)),
        const SizedBox(height: 16),

        for (final sch in st.testSchritte)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
                color: p.surf2, borderRadius: BorderRadius.circular(8)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(
                  width: 28,
                  child: Text(zeichen(sch.befund),
                      style: mono(
                          size: 11,
                          weight: FontWeight.w600,
                          color: farbe(sch.befund))),
                ),
                Expanded(
                  child: Text(t(sch.schluessel),
                      style: TextStyle(fontSize: 13.5, color: p.ink)),
                ),
                if (sch.dauer != null)
                  Text('${sch.dauer!.inMilliseconds} ms',
                      style: mono(size: 10.5, color: p.dim)),
              ]),
              // DER GRUND STEHT DABEI, nicht in einem Protokoll, das niemand
              // findet. Unuebersetzt: er soll weitergegeben werden koennen,
              // und eine uebersetzte Fehlermeldung ist beim Suchen wertlos.
              if (sch.detail != null)
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 6),
                  child: SelectableText(sch.detail!,
                      style: mono(size: 11, color: p.muted, height: 1.5)),
                ),
              if (sch.befund == Befund.hinweis &&
                  sch.schluessel == 'pruefNahbereich')
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 6),
                  child: Text(t('pruefNahbereichWas'),
                      style: mono(size: 11, color: p.muted, height: 1.5)),
                ),
            ]),
          ),

        if (st.testLaeuft)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child:
                Text(t('connTestRunning'), style: mono(size: 11.5, color: p.dim)),
          ),

        const SizedBox(height: 12),
        // AUF outlineBtn UMGESTELLT. Vorher war das ein eigener
        // GestureDetector mit `width: double.infinity` — ein 516 px breites
        // Banner ohne Zeigerwechsel, ohne Ueberfahr-Zustand und ohne Fokus,
        // und waehrend `testLaeuft` war `onTap` null, wobei der Kasten weiter
        // wie ein Knopf aussah. Ueber den Baustein greift beides jetzt von
        // selbst; die Sonderfarben liegen in `fuellung`, `accent` und
        // `textColor`.
        _knopfBreite(outlineBtn(
          st.testSchritte.isEmpty ? t('connTestStart') : t('connTestAgain'),
          st.testLaeuft ? null : () => st.verbindungPruefen(),
          fuellung: st.testLaeuft ? p.surf2 : p.tint,
          rahmen: st.testLaeuft ? p.line : p.tintLine,
          textColor: st.testLaeuft ? p.dim : p.tintInk,
          fontSize: 11,
          padding: const EdgeInsets.symmetric(vertical: 12),
        )),

        // WAS ZULETZT SCHIEFGING, auch wenn der Test gerade gruen ist. Ein
        // Fehler, der nur manchmal auftritt, waere sonst nicht zu fassen: bis
        // der Nutzer den Test oeffnet, ist die Lage wieder in Ordnung.
        if (st.letzteTechnischeMeldung != null) ...[
          const SizedBox(height: 22),
          label6(t('connLast')),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: p.surf2, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(st.letzteTechnischeMeldung!,
                style: mono(size: 11, color: p.muted, height: 1.5)),
          ),
        ],
      ]),
    );
  }

  // ══════════════════════════════════════════════════ Anleitung zur Naehe

  /// Schritt fuer Schritt, was "nur in der Naehe" verlangt und was es leistet.
  ///
  /// EHRLICH AN DER STELLE, AN DER ES WEHTUT: die Zustellung ueber Funk ist
  /// noch nicht gebaut. Das steht hier nicht im Kleingedruckten, sondern in
  /// einem eigenen Kasten ganz oben — wer die Schritte befolgt und dann
  /// vergeblich wartet, verliert das Vertrauen in alles andere mit.
  ///
  /// NUR UNTER ANDROID ERREICHBAR. Der einzige Weg hierher ist `go('nahHilfe')`
  /// in `nahbereichBlock()`, und der ganze Block steht in den Einstellungen
  /// hinter `if (_nurAufAndroid)`. Auf Windows, Linux und im Web kann diesen
  /// Bildschirm niemand oeffnen — beim Desktop-Feinschliff am 30.07.2026 ist er
  /// deshalb bewusst ungeschliffen geblieben (er hat dieselben Maengel wie
  /// 'test' hatte, aber niemand sieht sie). Wenn der Nahbereich fuer den
  /// Desktop kommt, faellt er zusammen mit `nahbereichBlock` wieder an.
  Widget nahHilfeScreen() {
    Widget schritt(int nr, String titel, String text) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
              color: p.surf2, borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 26,
              child: Text('$nr',
                  style: doto(
                      size: 15, weight: FontWeight.w600, color: p.accLight)),
            ),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titel, style: TextStyle(fontSize: 13.5, color: p.ink)),
                    const SizedBox(height: 3),
                    Text(text,
                        style: mono(size: 11.5, color: p.muted, height: 1.55)),
                  ]),
            ),
          ]),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('set')),
          const SizedBox(width: 11),
          Expanded(child: h2(t('nearGuide'), size: 20)),
        ]),
        const SizedBox(height: 12),
        _hinweisKasten(t('nearGuideNotYet')),
        const SizedBox(height: 18),
        label6(t('nearGuideWhat')),
        Text(t('nearGuideWhatBody'),
            style: mono(size: 12, color: p.muted, height: 1.6)),
        const SizedBox(height: 18),
        label6(t('nearGuideSteps')),
        schritt(1, t('nearStep1'), t('nearStep1Body')),
        schritt(2, t('nearStep2'), t('nearStep2Body')),
        schritt(3, t('nearStep3'), t('nearStep3Body')),
        schritt(4, t('nearStep4'), t('nearStep4Body')),
        schritt(5, t('nearStep5'), t('nearStep5Body')),
        const SizedBox(height: 18),
        label6(t('nearGuideBack')),
        Text(t('nearGuideBackBody'),
            style: mono(size: 12, color: p.muted, height: 1.6)),
        const SizedBox(height: 18),
        label6(t('nearGuideLimits')),
        Text(t('nearGuideLimitsBody'),
            style: mono(size: 12, color: p.muted, height: 1.6)),
      ]),
    );
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

  // ---- OVERLAYS ----
  Widget scrim(Widget child, {Alignment align = Alignment.bottomCenter, VoidCallback? onTapOutside}) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onTapOutside,
        child: Container(
          color: p.scrim,
          alignment: align,
          child: GestureDetector(onTap: () {}, child: child),
        ),
      ),
    );
  }

  /// Ein Blatt, das von unten hereinkommt.
  ///
  /// SCROLLBAR UND IN DER HOEHE BEGRENZT, seit dem 25.07.2026: die Anleitung
  /// zum Anstoss-Verteiler ist laenger als der Bildschirm. Vorher lief sie
  /// unten heraus — der Schliessen-Knopf lag ausserhalb, und weil die Karte
  /// den ganzen Bildschirm fuellte, gab es auch daneben nichts mehr zum
  /// Antippen. Das Blatt liess sich schlicht nicht mehr schliessen.
  ///
  /// 85 Prozent, damit oben ein Streifen frei bleibt: dort tippt man hin, um
  /// abzubrechen, und ohne ihn faende man diesen Weg nicht.
  Widget sheetCard({required List<Widget> children}) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: p.surf, borderRadius: const BorderRadius.vertical(top: Radius.circular(14)), border: Border.all(color: p.line)),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                22, 22, 22, 22 + MediaQuery.of(context).padding.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ),
      );

  Widget encSheet() {
    return scrim(
      onTapOutside: () => setState(() => sheet = false),
      sheetCard(children: [
        Center(child: Container(width: 36, height: 3, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('encryption'), size: 20),
        const SizedBox(height: 11),
        kvRow(t('protocol'), 'Double-Ratchet, X25519'),
        kvRow(t('selfDestruct'), fristText(st.fristFuer(chat ?? c1))),
        // JE UNTERHALTUNG, wie bei Signal. "Standard" folgt den
        // Einstellungen; alles andere gilt nur hier — und nur fuer das, was
        // man selbst schreibt.
        segmented(
          ['std', 'off', '1h', '24h', '7d'],
          [t('chatFristStd'), t('off'), t('h1'), t('h24'), t('d7')],
          _chatFristSchluessel(chat ?? c1),
          (v) => st.setzeChatFrist(chat ?? c1,
              v == 'std' ? null : (_fristen[v] ?? Duration.zero)),
        ),
        const SizedBox(height: 8),
        kvRow(t('readReceipts'), st.einstellungen.readReceipts ? t('on') : t('off')),
        const SizedBox(height: 11),

        // Die echte Pruefnummer. Hier stand vorher ein erfundener Wert
        // ('a3f9 21bd 77c4') — er sah nach Sicherheit aus und war keine.
        //
        // Beide Seiten sehen dieselben 60 Ziffern. Stimmen sie ueberein, sitzt
        // wirklich der Erwartete am anderen Ende und niemand dazwischen. Das
        // ist der einzige Weg, den ein Nutzer selbst gehen kann.
        label6(t('safetyNumber')),
        if (pruefnummerFehler != null)
          Text(t(pruefnummerFehler!), style: mono(size: 11.5, color: p.dim, height: 1.5))
        else if (pruefnummer == null)
          Text('…', style: mono(size: 13, color: p.dim))
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final g in pruefnummer!.groups)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
                child: Text(g, style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
              ),
          ]),

        const SizedBox(height: 14),
        label6(t('keyArt')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SchluesselbildAnsicht(schluessel: chat ?? c1, farbe: p.accLight, leer: p.line, punkt: 8),
          const SizedBox(width: 12),
          Expanded(child: Text(t('keyArtPeer'), style: mono(size: 10.5, color: p.dim, height: 1.45))),
        ]),

        const SizedBox(height: 8),
        Container(height: 1, color: p.lineSoft),
        const SizedBox(height: 8),
        Text(t('verifyNote'), style: mono(size: 11, color: p.dim, height: 1.5)),

        // ANWESENHEIT JE KONTAKT.
        //
        // Sie steht hier und nicht in den Einstellungen, weil sie zu EINEM
        // Kontakt gehoert — und weil dies der einzige Ort ist, an dem man
        // ohnehin ueber diesen einen nachdenkt.
        //
        // NUR wenn der Funk ueberhaupt an ist: ein Schalter fuer eine
        // Anwesenheit, die niemand aussendet, waere eine Einstellung ohne
        // Wirkung — und der Nutzer wuesste nicht, warum sie nichts tut.
        if (st.einstellungen.naheAn) ...[
          const SizedBox(height: 11),
          Container(height: 1, color: p.lineSoft),
          const SizedBox(height: 11),
          label6(t('nearby')),
          toggleRow(
            t('presence'),
            t('presenceSub'),
            _zeigtAnwesenheit(chat ?? c1),
            () => _legeAnwesenheitUm(chat ?? c1),
          ),
        ],

        const SizedBox(height: 11),
        // ENTFERNEN GEHOERT HIERHER, und es fehlte ganz.
        //
        // `removeContact` steht seit jeher im Kern; gerufen hat es niemand.
        // Wer eine falsche Adresse eintippte — 56 Zeichen, kein Randfall —,
        // wurde sie nie wieder los. Am 29.07.2026 blieb auf einem Testgeraet
        // ein toter Kontakt stehen, den nichts mehr entfernen konnte.
        //
        // In diesem Blatt und nicht in der Liste: hier steht schon alles
        // andere ueber die Gegenstelle, und ein Wisch-zum-Loeschen in der
        // Chatliste waere die Sorte Geste, die man versehentlich macht.
        outlineBtn(t('removeContact'), _entferneOffenenKontakt,
            accent: false, padding: const EdgeInsets.all(11)),
        const SizedBox(height: 6),
        outlineBtn(t('close'), () => setState(() => sheet = false), padding: const EdgeInsets.all(11)),
      ]),
    );
  }

  Future<void> _richtePanikPasswortEin() async {
    final eins = TextEditingController();
    final zwei = TextEditingController();
    String? fehler;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('panicPw'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('panicPwBody'), style: mono(size: 12, color: p.muted, height: 1.5)),
            const SizedBox(height: 10),
            TextField(controller: eins, obscureText: true, autocorrect: false, enableSuggestions: false,
                style: mono(size: 13, color: p.ink),
                decoration: InputDecoration(hintText: t('pw'), hintStyle: mono(size: 13, color: p.dim))),
            TextField(controller: zwei, obscureText: true, autocorrect: false, enableSuggestions: false,
                style: mono(size: 13, color: p.ink),
                decoration: InputDecoration(hintText: t('pwAgain'), hintStyle: mono(size: 13, color: p.dim))),
            if (fehler != null) ...[
              const SizedBox(height: 8),
              Text(fehler!, style: mono(size: 11.5, color: p.tintInk, height: 1.4)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                if (eins.text != zwei.text) {
                  neu(() => fehler = t('pwMismatch'));
                  return;
                }
                try {
                  await st.setzePanikPasswort(eins.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                } on WeakPassphraseException {
                  neu(() => fehler = t('pwWeak'));
                } on PanikGleichException {
                  neu(() => fehler = t('panicPwSame'));
                }
              },
              child: Text(t('actSave')),
            ),
          ],
        ),
      ),
    );
    // Das Passwort nicht laenger als noetig im Speicher stehen lassen.
    eins.clear();
    zwei.clear();
    _entsorgeNachDemSchliessen([eins, zwei]);
  }

  /// Entsorgt Eingabefelder eines Dialogs ERST NACH seiner Schliess-Animation.
  ///
  /// `showDialog` kehrt zurueck, sobald `pop` gerufen ist — der Dialog
  /// zeichnet sich danach aber noch einmal, waehrend er ausblendet, und
  /// greift dabei auf seine Felder zu. Sofort entsorgt, warf das "A
  /// TextEditingController was used after being disposed" (Widget-Test
  /// 25.09.2026). Die Ausblendung eines Dialogs dauert 150 ms; eine halbe
  /// Sekunde laesst reichlich Luft.
  void _entsorgeNachDemSchliessen(List<TextEditingController> felder) {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      for (final f in felder) {
        f.dispose();
      }
    });
  }

  String _chatFristSchluessel(String id) {
    final s = st.kontakte.where((k) => k.id == id).firstOrNull?.fristSekunden;
    if (s == null) return 'std';
    if (s == 0) return 'off';
    if (s <= 3600) return '1h';
    if (s <= 86400) return '24h';
    return '7d';
  }

  /// Ob dieser Kontakt uns sieht. Unbekannt heisst ja — so steht es im
  /// Datenmodell, und ein "nein" hier waere eine stille Abweichung davon.
  bool _zeigtAnwesenheit(String id) =>
      st.kontakte
          .where((k) => k.id == id)
          .map((k) => k.zeigtAnwesenheit)
          .firstOrNull ??
      true;

  Future<void> _legeAnwesenheitUm(String id) async {
    try {
      await st.setzeAnwesenheit(id, !_zeigtAnwesenheit(id));
    } on MessengerException {
      // Ein Kontakt, den es nicht mehr gibt. Kein Grund, das Blatt
      // wegzuwerfen — es schliesst sich gleich ohnehin.
    }
    if (mounted) setState(() {});
  }

  Widget kvRow(String k, String v, {bool mono2 = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k, style: mono(size: 12, color: p.muted))),
          const SizedBox(width: 16),
          Text(v, style: mono2 ? doto(size: 12, weight: FontWeight.w600, color: p.ink, spacing: 0.8) : TextStyle(fontSize: 12, color: p.ink)),
        ]),
      );

  Widget panicModal() {
    return scrim(
      align: Alignment.center,
      Container(
        margin: const EdgeInsets.all(22),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          h2(t('panicTitle'), size: 20),
          const SizedBox(height: 11),
          Text(t('panicBody'), style: mono(size: 12.5, color: p.muted, height: 1.5)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: outlineBtn(t('cancel'), () => setState(() => panic = false), accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('delete'), doWipe, padding: const EdgeInsets.all(11), textColor: p.tintInk)),
          ]),
        ]),
      ),
    );
  }

  /// Die Blaetter, die ueber dem Zugriffs-Bildschirm liegen.
  Widget enrollModal() {
    final en = enroll!;
    if (en == 'keineSperre') {
      return scrim(
        onTapOutside: () => setState(() => enroll = null),
        sheetCard(children: [
          const SizedBox(height: 8),
          h2(t('lockNoScreenLock'), size: 18),
          const SizedBox(height: 11),
          Text(t('lockNoScreenLockBody'), style: mono(size: 12.5, color: p.muted, height: 1.6)),
          const SizedBox(height: 14),
          outlineBtn(t('close'), () => setState(() => enroll = null), padding: const EdgeInsets.all(11)),
        ]),
      );
    }
    if (en == 'hw') return stickModal();
    if (en == 'pw') return passwortModal();
    if (en == 'pushHilfe') return pushHilfeModal();

    // Alles andere ist ein Fehler im Programm, kein Zustand des Nutzers.
    // Frueher standen hier Passkey und Zwei-Faktor-Code; die Zeilen sind weg.
    return const SizedBox.shrink();
  }

  /// Ein Textfeld im Stil der App, fuer Geheimnisse.
  Widget _geheimFeld(TextEditingController ctl, String hinweis,
      {bool aktiv = true, bool nurZahlen = false, bool autofokus = false}) {
    return Container(
      decoration: BoxDecoration(
          color: p.surf2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.line)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: ctl,
        enabled: aktiv,
        obscureText: true,
        autofocus: autofokus,
        keyboardType: nurZahlen ? TextInputType.number : null,
        style: mono(size: 14, color: p.ink, spacing: 2),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hinweis,
          hintStyle: mono(size: 13, color: p.dim),
        ),
      ),
    );
  }

  /// Ein Kasten fuer etwas, das der Nutzer wissen muss.
  ///
  /// ZWEI BEDEUTUNGEN, ZWEI AUSSEHEN. Bis zum 25.07.2026 sah beides gleich
  /// aus: "dein Fingerabdruck wurde nicht erkannt" und "so richtest du ntfy
  /// ein" hatten dieselbe Farbe. Wer eine Oberflaeche schnell ueberfliegt —
  /// und das tut jeder — liest Farbe vor Text. Zwei Dinge in derselben Farbe
  /// sind fuer ihn dasselbe Ding.
  ///
  /// Der Akzent bleibt dem vorbehalten, was schiefging oder Aufmerksamkeit
  /// braucht. Ruhige Hinweise bekommen die gewoehnliche Umrandung — sie
  /// stehen da, ohne zu rufen.
  Widget _hinweisKasten(String text, {bool warnend = true}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Masse.innen),
        decoration: BoxDecoration(
            color: warnend ? p.tint : p.surf2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: warnend ? p.tintLine : p.line)),
        child: Text(text,
            style: mono(
                size: 11.5,
                color: warnend ? p.tintInk : p.muted,
                height: 1.5)),
      );

  /// Eine nummerierte Zeile in einer Anleitung.
  Widget _schritt(int nummer, String titel, String text,
      {List<Widget> knoepfe = const []}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: p.tint,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.tintLine)),
          child: Text('$nummer',
              style: mono(size: 10.5, weight: FontWeight.w600, color: p.tintInk)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titel, style: TextStyle(fontSize: 13.5, color: p.ink)),
            const SizedBox(height: 3),
            Text(text, style: mono(size: 11.5, color: p.muted, height: 1.5)),
            if (knoepfe.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: knoepfe),
            ],
          ]),
        ),
      ]),
    );
  }

  /// Ein kleiner Knopf innerhalb einer Anleitung.
  Widget _kleinerKnopf(String text, VoidCallback tun) => Masse.trefferflaeche(
        onTap: tun,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
              color: p.surf,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.line)),
          child: Text(text.toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w500,
                  color: p.accLight,
                  spacing: 1.1)),
        ),
      );

  Future<void> _oeffneLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Die Anleitung fuer den Anstoss-Verteiler.
  ///
  /// WARUM DAS EINE EIGENE SEITE BRAUCHT: der Nutzer muss in einer ANDEREN App
  /// eine Einstellung finden, und zwar VOR dem Einschalten hier. Wer das in
  /// einen Satz packt, schickt ihn suchen. Die Menuepunkte stehen deshalb
  /// woertlich da, in der Reihenfolge, in der sie vorkommen.
  ///
  /// DIE REIHENFOLGE IST NICHT KOSMETISCH: ntfy baut die Anstoss-Adresse beim
  /// Anmelden aus dem eingestellten Standardserver. Wer erst hier einschaltet,
  /// bekommt eine Adresse auf ntfy.sh — und BitDM lehnt sie ab, weil der Relay
  /// nur den eigenen Push-Server annimmt.
  Widget pushHilfeModal() {
    return scrim(
      onTapOutside: () => setState(() => enroll = null),
      sheetCard(children: [
        Center(
            child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                    color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('pushGuideTitle'), size: 20),
        const SizedBox(height: 8),
        Text(t('pushGuideIntro'),
            style: mono(size: 12, color: p.muted, height: 1.55)),
        const SizedBox(height: 16),

        _schritt(1, t('pushStep1'), t('pushStep1Sub'), knoepfe: [
          _kleinerKnopf('F-Droid',
              () => _oeffneLink('https://f-droid.org/packages/io.heckel.ntfy/')),
          _kleinerKnopf('Play Store',
              () => _oeffneLink('https://play.google.com/store/apps/details?id=io.heckel.ntfy')),
        ]),

        _schritt(2, t('pushStep2'), t('pushStep2Sub'), knoepfe: [
          _kleinerKnopf(t('copy'), () {
            Clipboard.setData(const ClipboardData(text: pushBasis));
            setState(() => copied = true);
            Future.delayed(const Duration(milliseconds: 1400), () {
              if (mounted) setState(() => copied = false);
            });
          }),
          _kleinerKnopf(t('pushOpenNtfy'), () async {
            final da = await FremdeApp.oeffne(FremdeApp.ntfy);
            if (!da && mounted) {
              setState(() => lockFehler = t('pushNoNtfy'));
            }
          }),
        ]),

        // Die Adresse zum Abtippen, falls das Kopieren nicht ankommt.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          margin: const EdgeInsets.only(left: 32, bottom: 14),
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.line)),
          child: Text(copied ? t('copied') : pushBasis,
              style: mono(size: 12, color: copied ? p.accLight : p.ink)),
        ),

        _schritt(3, t('pushStep3'), t('pushStep3Sub')),
        _schritt(4, t('pushStep4'), t('pushStep4Sub')),

        _hinweisKasten(t('pushOrderWarning'), warnend: false),
        const SizedBox(height: 14),

        outlineBtn(t('close'), () => setState(() => enroll = null),
            padding: const EdgeInsets.all(11)),
      ]),
    );
  }

  /// Das App-Passwort wird eingerichtet.
  ///
  /// Dieses Fach haengt an NICHTS ausser dem Passwort — kein gesicherter
  /// Bereich, kein Stick. Wer die Fachdatei kopiert, probiert auf eigener
  /// Hardware, so lange er will. Deshalb steht die Anforderung hier deutlich
  /// da und wird nicht erst beim Absenden nachgereicht.
  Widget passwortModal() {
    return scrim(
      onTapOutside: () => setState(() => enroll = null),
      sheetCard(children: [
        Center(
            child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                    color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('enrollPw'), size: 20),
        const SizedBox(height: 10),
        Text(t('pwIntro'), style: mono(size: 12.5, color: p.muted, height: 1.6)),
        const SizedBox(height: 14),
        _geheimFeld(pwCtl, t('pwHint'), autofokus: true),
        const SizedBox(height: 8),
        _geheimFeld(pwCtl2, t('pwAgain')),
        const SizedBox(height: 12),
        if (lockFehler != null) ...[
          _hinweisKasten(lockFehler!),
          const SizedBox(height: 12),
        ],
        Row(children: [
          Expanded(
              child: outlineBtn(t('cancel'), () => setState(() => enroll = null),
                  accent: false,
                  padding: const EdgeInsets.all(11),
                  weight: FontWeight.w400)),
          const SizedBox(width: 8),
          Expanded(
              child: outlineBtn(t('add'), _passwortAnlegen,
                  padding: const EdgeInsets.all(11))),
        ]),
        const SizedBox(height: 10),
        Text(t('pwLostNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  /// Der Stick wird eingerichtet.
  ///
  /// Zwei Dinge stehen hier bewusst DRAUF und nicht im Kleingedruckten:
  /// dass es ZWEI Beruehrungen braucht (sonst haelt man die zweite
  /// Aufforderung fuer einen Fehler), und was passiert, wenn der Stick
  /// verloren geht.
  Widget stickModal() {
    final laeuft = stickSchritt != null;
    return scrim(
      onTapOutside: laeuft ? () {} : () => setState(() => enroll = null),
      sheetCard(children: [
        Center(
            child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                    color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('enrollHw'), size: 20),
        const SizedBox(height: 10),
        Text(t('stickIntro'), style: mono(size: 12.5, color: p.muted, height: 1.6)),
        const SizedBox(height: 14),

        // Der Weg zum Stick.
        Row(children: [
          Expanded(child: _wegKnopf(StickWeg.usb, t('stickUsb'))),
          const SizedBox(width: 8),
          Expanded(child: _wegKnopf(StickWeg.nfc, t('stickNfc'))),
        ]),
        const SizedBox(height: 14),

        Text(t('stickPinLabel').toUpperCase(),
            style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1.4)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.line)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: stickPinCtl,
            enabled: !laeuft,
            obscureText: true,
            keyboardType: TextInputType.number,
            style: mono(size: 14, color: p.ink, spacing: 2),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: '••••••',
              hintStyle: mono(size: 14, color: p.dim, spacing: 2),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(t('stickPinHint'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 14),

        if (lockFehler != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: p.tint,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.tintLine)),
            child: Text(lockFehler!,
                style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
          ),
          const SizedBox(height: 12),
        ],

        if (laeuft) ...[
          Text(stickSchritt!,
              style: mono(size: 12.5, color: p.accLight, height: 1.5)),
          const SizedBox(height: 12),
        ],

        Row(children: [
          Expanded(
              child: outlineBtn(t('cancel'),
                  laeuft ? () {} : () => setState(() => enroll = null),
                  accent: false,
                  padding: const EdgeInsets.all(11),
                  weight: FontWeight.w400)),
          const SizedBox(width: 8),
          Expanded(
              child: outlineBtn(laeuft ? t('waiting') : t('add'),
                  laeuft ? () {} : _stickAnlegen,
                  padding: const EdgeInsets.all(11))),
        ]),
        const SizedBox(height: 10),
        Text(t('stickLostNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 10),
        // Ob ein Stick hmac-secret ueberhaupt kann, steht in keiner
        // Produktbeschreibung — die Erweiterung ist optional, und Hersteller
        // werben nicht damit. Deshalb der Weg, ihn vorher selbst zu fragen.
        GestureDetector(
          onTap: laeuft ? null : _pruefeStick,
          child: Text(t('fidoProbe').toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w600,
                  color: p.accLight,
                  spacing: 1.3)),
        ),
      ]),
    );
  }

  Widget _wegKnopf(StickWeg weg, String beschriftung) {
    final an = stickWeg == weg;
    return GestureDetector(
      onTap: stickSchritt != null ? null : () => setState(() => stickWeg = weg),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: an ? p.tint : p.surf2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: an ? p.tintLine : p.line)),
        child: Text(beschriftung.toUpperCase(),
            style: mono(
                size: 11,
                weight: FontWeight.w500,
                color: an ? p.tintInk : p.dim,
                spacing: 1.2)),
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
