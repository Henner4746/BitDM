import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'core/messenger_core.dart';
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
import 'core/benachrichtigungen.dart';
import 'bewegung.dart';
import 'masse.dart';
import 'core/crypto/wordlist_english.dart';
import 'core/crypto/address.dart';
import 'core/empfang.dart';
import 'core/fenster.dart';
import 'core/push.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ein Verzeichnis, das dem Betriebssystem gehoert und nicht in Sicherungen
  // oder in den Dateimanager wandert.
  final verzeichnis = await getApplicationSupportDirectory();

  // Solange kein Faktor eingerichtet ist, liegt die Entropie im
  // Schluesselspeicher des Geraets und die App oeffnet ohne Rueckfrage. Mit
  // dem ersten Faktor wandert sie in ein Schluesselfach und ist ohne ihn nicht
  // mehr zu haben — auch nicht mit Root, auch nicht mit der Datei in der Hand.
  final tresor = VaultSecretStore(
    datei: vaultDateiIn(verzeichnis.path),
    basis: DeviceSecretStore(),
    jetzt: () => DateTime.now().millisecondsSinceEpoch,
  );

  final core = RealMessengerCore(
    secretStore: tresor,
    databasePath: '${verzeichnis.path}/bitdm.db',
    relayUri: Uri.parse(relayBasis),
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
    ablagen: (art) => GeraeteFach(
      art == UnlockFactorKind.deviceCredential
          ? GeraeteArt.geraetesperre
          : GeraeteArt.biometrie,
      verzeichnis: verzeichnis.path,
    ),
  )..empfangsDienst = EmpfangsDienst();

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
    return MaterialApp(
      title: 'BitDM',
      debugShowCheckedModeBanner: false,
      home: Home(state: state),
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

class _HomeState extends State<Home> with WidgetsBindingObserver {
  String screen = 'onboard';
  String? chat;
  bool reqSent = false, sheet = false, panic = false, wiped = false, copied = false;

  AppState get st => widget.state;

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
    st.addListener(_aktualisiere);
    _setzeMeldetexte();
    st.boot().then((_) {
      if (!mounted) return;
      // Wer schon eine Identitaet hat, sieht das Onboarding nicht wieder.
      setState(() => screen = st.hatIdentitaet ? 'chats' : 'onboard');
    });
  }

  void _aktualisiere() {
    if (mounted) setState(() {});
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

  String lang = 'en', mode = 'dark';
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
  final addCtl = TextEditingController();
  final codeCtl = TextEditingController();
  final stickPinCtl = TextEditingController();
  final pwCtl = TextEditingController();
  final pwCtl2 = TextEditingController();
  final phraseCtl = TextEditingController();

  Pal get p => mode == 'dark' ? palDark : palLight;
  List<Color> get avp => mode == 'dark' ? avPalDark : avPalLight;
  String t(String k) => strings[lang]![k] ?? k;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    st.removeListener(_aktualisiere);
    draftCtl.dispose();
    addCtl.dispose();
    codeCtl.dispose();
    stickPinCtl.dispose();
    pwCtl.dispose();
    pwCtl2.dispose();
    phraseCtl.dispose();
    super.dispose();
  }

  // ---- fonts (bundled locally; the app never fetches them at runtime) ----
  //
  // Both families are variable fonts with a `wght` axis, so a single file
  // covers every weight the UI uses (w300 … w900). `fontWeight` alone does not
  // drive that axis reliably, so the axis is set explicitly via fontVariations
  // and `fontWeight` is kept for Flutter's own fallback/metrics handling.
  TextStyle _font(String family, double size, FontWeight weight, Color? color, double? spacing, double height) {
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
      _font('Doto', size, weight, color, spacing, height);
  TextStyle mono({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.4}) =>
      _font('Chivo Mono', size, weight, color, spacing, height);

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
  String ephLabel() {
    final d = st.einstellungen.messageLifetime;
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
    final von = reiter.indexOf(screen);
    final nach = reiter.indexOf(s);
    if (von >= 0 && nach >= 0 && von != nach) _richtung = nach > von ? 1 : -1;
    setState(() { screen = s; sheet = false; panic = false; });
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
    draftCtl.clear();
    await st.senden(chat!, d);
  }

  /// Richtet einen Faktor ein oder entfernt ihn.
  ///
  /// Bis zum 25.07.2026 stand hier eine Attrappe: eine Einrichtungs-Animation,
  /// danach ein Haken, dahinter nichts. Jetzt liegt darunter ein
  /// Schluesselfach — die Entropie ist ohne den Faktor wirklich nicht mehr zu
  /// haben, auch nicht mit Root, auch nicht mit der Datei in der Hand.
  Future<void> methodAct(String key) async {
    final art = zeilenArt[key];
    if (art == null || laeuftZeile != null) return;

    final vorhanden = st.faktoren.where((s) => s.kind == art).toList();
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
          istGueltig: (s) =>
              st.adresseGueltig(s.replaceAll(RegExp(r'[s-]'), '')),
        ),
      ),
    );
    if (adresse == null || !mounted) return;
    // ACHTUNG, HIER STAND EIN ECHTER FEHLER: RegExp(r'[s-]') ist eine
    // Zeichenklasse aus 's' und '-', nicht "Leerraum oder Strich". Aus jeder
    // gescannten Adresse fiel damit der Buchstabe s heraus — und Adressen sind
    // Base32 in Kleinbuchstaben, s kommt in fast jeder vor. Das Ergebnis
    // scheiterte an der Pruefsumme, und es sah aus, als taugte der QR-Code
    // nicht.
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
      final l = lang, m = mode;
      screen = 'onboard'; chat = null; reqSent = false; sheet = false;
      wiped = true; copied = false;
      enroll = null;
      lang = l; mode = m;
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

  Widget outlineBtn(String labelTxt, VoidCallback onTap,
      {bool accent = true, double fontSize = 12, EdgeInsets? padding, FontWeight weight = FontWeight.w600, Color? textColor}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: padding ?? const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent ? p.accent : p.line),
        ),
        child: Text(labelTxt.toUpperCase(),
            style: mono(size: fontSize, weight: weight, color: textColor ?? (accent ? p.ink : p.muted), spacing: fontSize * 0.12)),
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
      Masse.trefferflaeche(
        onTap: onTap,
        child: Container(
          width: 30, height: 30, alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
          child: Text(glyph, style: TextStyle(color: color ?? p.muted, fontSize: fontSize, height: 1)),
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
    return Scaffold(
      backgroundColor: p.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(child: buildScreen()),
                if (showNav) buildNav(),
              ],
            ),
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
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: con.maxHeight),
          child: IntrinsicHeight(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46, height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                    child: Text('B', style: doto(size: 22, weight: FontWeight.w900, color: p.accLight)),
                  ),
                  const SizedBox(height: 16),
                  Text('${t('h1a')}\n${t('h1b')}', style: doto(size: 36, weight: FontWeight.w800, color: p.ink, height: 1.05, spacing: 0.4)),
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
                  outlineBtn(t('create'), doCreate, padding: const EdgeInsets.all(15), fontSize: 13),
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
                  GestureDetector(
                    onTap: () {
                      phraseCtl.clear();
                      setState(() { screen = 'restore'; restoreFehler = null; });
                    },
                    child: Text(t('restoreLink').toUpperCase(),
                        style: mono(size: 11, weight: FontWeight.w600, color: p.accLight, spacing: 1.2)),
                  ),
                  const SizedBox(height: 6),
                  Text(t('restoreLinkSub'), style: mono(size: 11, color: p.dim, height: 1.5)),
                ],
              ),
            ),
          ),
        ),
      );
    });
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
    final woerter = _phraseWoerter;
    setState(() => restoreFehler = null);

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
          iconBtn('<', () => setState(() { screen = 'onboard'; restoreFehler = null; })),
          const SizedBox(width: 11),
          Expanded(child: h2(t('restoreTitle'), size: 24)),
        ]),
        const SizedBox(height: 12),
        Text(t('restoreIntro'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),

        Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.line)),
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: phraseCtl,
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
        outlineBtn(t('restoreDo'), _stelleWieder,
            padding: const EdgeInsets.all(14), fontSize: 13),
        const SizedBox(height: 14),

        // WAS DIE WIEDERHERSTELLUNG NICHT ZURUECKBRINGT. Das gehoert VOR die
        // Handlung, nicht danach: wer hier erwartet, seine Unterhaltungen
        // wiederzusehen, wird sonst zweimal enttaeuscht.
        Text(t('restoreNote'), style: mono(size: 11, color: p.dim, height: 1.55)),
      ]),
    );
  }

  // ---- WIRD ANGELEGT ----
  Widget arbeitetScreen() => Center(
        child: Text(t('creating').toUpperCase(),
            style: mono(size: 12, color: p.dim, spacing: 1.8)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('phraseTitle')),
        const SizedBox(height: 6),
        Text(t('phraseSub'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (var i = 0; i < woerter.length; i++)
                SizedBox(
                  width: (MediaQuery.of(context).size.width - 44 - 6) / 2,
                  child: Container(
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
                ),
            ]),
          ),
        ),
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
        outlineBtn(t('phraseDone'), () {
          st.phraseBestaetigt();
          go('secure');
        }, padding: const EdgeInsets.all(13)),
      ]),
    );
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('secureTitle')),
        const SizedBox(height: 6),
        Text(t('secureSub'), style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        ...zugriffsBlock(statusMode: true),
        const SizedBox(height: 4),
        Text(t('secureFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const Spacer(),
        Row(children: [
          Expanded(child: outlineBtn(t('secureSkip'), () => go('id'), accent: false, padding: const EdgeInsets.all(13), weight: FontWeight.w400)),
          const SizedBox(width: 8),
          Expanded(child: outlineBtn(t('secureDone'), () => go('id'), padding: const EdgeInsets.all(13))),
        ]),
      ]),
    );
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

    return Opacity(
      opacity: blockiert ? 0.4 : 1,
      child: GestureDetector(
        onTap: blockiert ? null : () => methodAct(key),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8)),
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
    );
  }

  /// Die vier Zeilen samt Fehlerkasten.
  ///
  /// DER KASTEN IST DER PUNKT: bis zum 25.07.2026 wurden Fehler beim
  /// Einrichten zwar gesetzt, aber auf diesem Bildschirm nie angezeigt. Wer
  /// tippte, sah nichts — weder Dialog noch Grund.
  List<Widget> zugriffsBlock({required bool statusMode}) => [
        for (final k in zugriffsZeilen) ...[
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

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('myId')),
        const SizedBox(height: 4),
        Text(t('myIdSub'), style: mono(size: 12, color: p.dim)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
          child: QrView(st.meineAdresse, p.ink, p.surf),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final blk in meineAdresseAnzeige.split('-'))
            SizedBox(
              width: (MediaQuery.of(context).size.width - 44 - 6) / 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
                child: Text(blk, style: doto(size: 16, weight: FontWeight.w600, color: p.ink, spacing: 1.4)),
              ),
            ),
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
        Text(t('idNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  // ---- ADD ----
  Widget addScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('chats')),
          const SizedBox(width: 11),
          h2(t('addTitle'), size: 20),
        ]),
        const SizedBox(height: 16),
        Text(t('idLabel').toUpperCase(), style: mono(size: 10.5, color: p.dim, spacing: 1.6)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
          padding: const EdgeInsets.all(11),
          child: TextField(
            controller: addCtl,
            maxLines: 3,
            style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 1.4, height: 1.7),
            cursorColor: p.accent,
            decoration: InputDecoration.collapsed(hintText: beispielAdresse, hintStyle: doto(size: 15, weight: FontWeight.w600, color: p.dim, spacing: 1.4, height: 1.7)),
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
          const SizedBox(width: 8),
          smallBtn(t('scan'), _scanneQr),
        ]),
        const SizedBox(height: 16),
        outlineBtn(t('sendReq'), sendReq, padding: const EdgeInsets.all(13)),
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
        const Spacer(),
        Text(t('addFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  Widget smallBtn(String labelTxt, VoidCallback onTap) => Masse.trefferflaeche(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.line)),
          child: Text(labelTxt.toUpperCase(), style: mono(size: 11, weight: FontWeight.w400, color: p.muted, spacing: 1.2)),
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
      ConnectionState.error => (p.dim, t('connError'), false),
      ConnectionState.disconnected => (p.dim, t('connOffline'), false),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AtmenderPunkt(farbe: farbe, aktiv: aktiv, groesse: 7),
      const SizedBox(width: 6),
      AnimatedDefaultTextStyle(
        duration: Bewegung.klein,
        style: mono(size: 10, weight: FontWeight.w500, color: farbe, spacing: 1.1),
        child: Text(text.toUpperCase()),
      ),
    ]);
  }

  Widget chatsScreen() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 11, 22, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            h2(t('chats')),
            const SizedBox(width: 10),
            verbindungsPunkt(),
          ]),
          GestureDetector(
            onTap: () => setState(() { screen = 'add'; addCtl.clear(); reqSent = false; }),
            child: Container(
              width: 32, height: 32, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.accent)),
              child: Text('+', style: TextStyle(color: p.accLight, fontSize: 18, height: 1)),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
          for (final k in st.offeneAnfragen) pendingCard(k),
          // Ausgehende Anfragen erscheinen ebenfalls. Vorher waren sie
          // unsichtbar: wer jemanden hinzugefuegt hatte, sah danach eine leere
          // Liste und musste annehmen, es habe nicht funktioniert.
          for (final k in st.eigeneAnfragen) wartendeAnfrage(k),
          for (final id in contacts) contactRow(id),
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
          Row(children: [
            GestureDetector(
              onTap: () => acceptReq(k.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.accent)),
                child: Text(t('accept').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => st.anfrageAblehnen(k.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.line)),
                child: Text(t('decline').toUpperCase(), style: mono(size: 11, color: p.muted, spacing: 1.2)),
              ),
            ),
          ]),
        ]),
      );

  Widget contactRow(String id) {
    final list = st.verlaufVon(id);
    final letzte = list.isEmpty ? null : list.last;
    final last = letzte?.text ?? t('newContact');
    final time = letzte == null ? '' : zeitVon(letzte.timestamp);
    // Ungelesen: die letzte Nachricht kam von der Gegenstelle und diese
    // Unterhaltung ist gerade nicht offen.
    final unread = letzte != null && !letzte.isMine && chat != id;
    return GestureDetector(
      onTap: () => oeffneChat(id),
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Identicon(id, 40, avp, 8),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(shortId(adresseFormatiert(id)), style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(last, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(time, style: mono(size: 10.5, color: p.dim)),
            const SizedBox(height: 6),
            Container(width: 8, height: 8, decoration: BoxDecoration(color: unread ? p.accent : Colors.transparent, shape: BoxShape.circle)),
          ]),
        ]),
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
    if (st.einstellungen.messageLifetime != null) {
      hints.add(t("hintEph") + ephLabel());
    }
    final list = st.verlaufVon(cid);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(17, 8, 17, 8),
        child: Row(children: [
          iconBtn('‹', () => go('chats')),
          const SizedBox(width: 11),
          Expanded(
            child: GestureDetector(
              onTap: () { setState(() => sheet = true); _ladePruefnummer(cid); },
              child: Row(children: [
                Identicon(cid, 32, avp, 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(shortId(cid), maxLines: 1, overflow: TextOverflow.ellipsis, style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                    Text(t('encDetails').toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1)),
                  ]),
                ),
              ]),
            ),
          ),
          GestureDetector(
            onTap: () { setState(() => sheet = true); _ladePruefnummer(cid); },
            child: Container(
              width: 30, height: 30, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              child: Text('i', style: TextStyle(color: p.accLight, fontSize: 12)),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      Expanded(
        child: ListView(
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
      Container(
        padding: const EdgeInsets.fromLTRB(17, 11, 17, 16),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: p.lineSoft))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // DIESER KNOPF WAR EIN BILD. Bis zum 26.07.2026 stand hier ein
          // Container ohne GestureDetector: er sah aus wie ein Knopf, liess
          // sich druecken und tat nichts. Jetzt haengt die Dateiauswahl daran.
          //
          // Waehrend ein Versand laeuft, ist er stumm — einer nach dem
          // anderen. Dass er das ist, sieht man ihm an (p.dim statt p.muted),
          // statt dass ein Tippen ins Leere geht.
          Masse.trefferflaeche(
            onTap: st.schwebendeKennung == null ? () => anhangWaehlen(cid) : null,
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
                onChanged: (_) {
                  if (st.letzterFehler == 'zuLang') st.vergissFehler();
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
          GestureDetector(
            onTap: send,
            child: Container(
              height: 36, alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.accent)),
              child: Text(t('send').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
            ),
          ),
        ]),
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
    if (f == 'lagerVoll') return t('attachFull');
    if (f == 'tagesmenge') return t('attachQuota');
    if (f == 'anhangKaputt') return t('attachBroken');
    if (f == 'anhangNetz' || f == 'anhangFehler') return t('attachNet');
    if (f == 'anhangLaeuft') return t('attachBusy');
    if (f == 'anhangKeineApp') return t('attachNoApp');
    if (f == 'nurNahbereich') return t('nearOnlyNoAttach');
    if (f.startsWith('anhangZuGross:')) return t('attachTooBig');
    return null;
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 252),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: bub,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              if (m.kind == MessageKind.anhang)
                anhangInhalt(cid, m)
              else
                Align(alignment: Alignment.centerLeft, child: Text(m.text, style: TextStyle(fontSize: 13.5, color: p.ink, height: 1.4))),
              const SizedBox(height: 3),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(time, style: mono(size: 9.5, color: p.dim)),
                if (me) ...[
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
  Widget fortschrittsBalken(double anteil) => Column(
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
          const SizedBox(height: 4),
          Text('${(anteil * 100).clamp(0, 100).toStringAsFixed(0)} %',
              style: mono(size: 9.5, color: p.dim)),
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
          segmented(['en', 'de'], ['English', 'Deutsch'], lang,
            (v) => setState(() { lang = v; _setzeMeldetexte(); })),
        ])),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('appearance'), t('appearanceSub')),
          const SizedBox(height: 8),
          segmented(['dark', 'light'], [t('dark'), t('light')], mode, (v) => setState(() => mode = v)),
        ])),
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
          segmented(
            const ['0', '-2', '-1', '15', '60'],
            [t('bgOff'), t('bgPush'), t('bgLive'), t('bg15'), t('bg60')],
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

        // NUR IN DER NAEHE.
        //
        // Der Schalter steht hier bei der Sicherheit und nicht bei der
        // Verbindung, weil das der Grund ist, aus dem man ihn umlegt: er
        // sorgt dafuer, dass die App KEINEN Server anspricht. Was er heute
        // noch NICHT kann — Nachrichten ueber die Naehe zustellen —, steht
        // ausdruecklich darunter, sobald er an ist. Ein Schalter, der
        // stillschweigend nichts zustellt, waere schlimmer als keiner.
        toggleRow(t("nearOnly"), t("nearOnlySub"), st.einstellungen.nurNahbereich,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                nurNahbereich: !st.einstellungen.nurNahbereich))),
        if (st.einstellungen.nurNahbereich) ...[
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
                  style: mono(size: 10, weight: FontWeight.w600, color: p.tintInk, spacing: 1.1)),
              const SizedBox(height: Masse.eng),
              Text(t('nearOnlyWarn'),
                  style: mono(size: 11.5, color: p.tintInk, height: 1.55)),
            ]),
          ),
        ],
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('selfDestruct'), t('selfDestructSub')),
          const SizedBox(height: 8),
          segmented(["off", "1h", "24h", "7d"], [t("off"), t("h1"), t("h24"), t("d7")],
              _fristSchluessel,
              (v) => st.setzeEinstellungen(st.einstellungen.copyWith(
                  messageLifetime: _fristen[v], loescheLebensdauer: _fristen[v] == null))),
        ])),
        const SizedBox(height: 22),
        label6(t('identity')),
        GestureDetector(
          onTap: () => go('id'),
          child: settingCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(t('myIdQr'), style: TextStyle(fontSize: 13.5, color: p.ink)),
            Text(shortId(meineAdresseAnzeige), style: doto(size: 12.5, weight: FontWeight.w600, color: p.dim, spacing: 0.8)),
          ])),
        ),
        const SizedBox(height: 3),
        settingCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(t('fingerprint'), style: TextStyle(fontSize: 13.5, color: p.ink)),
          Text('b7d2 4e10 9af3', style: doto(size: 12.5, weight: FontWeight.w600, color: p.dim, spacing: 0.8)),
        ])),
        const SizedBox(height: 22),
        label6(t('emergency')),
        GestureDetector(
          onTap: () => setState(() => panic = true),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('panic'), style: TextStyle(fontSize: 13.5, color: p.tintInk)),
              Text(t('panicSub'), style: mono(size: 11, color: p.muted, height: 1.4)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget settingCard({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8)),
        child: child,
      );

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
            child: GestureDetector(
              onTap: () => onPick(keys[i]),
              child: Container(
                margin: EdgeInsets.only(right: i < keys.length - 1 ? 3 : 0),
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: cur == keys[i] ? p.tint : Colors.transparent, borderRadius: BorderRadius.circular(4)),
                child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: cur == keys[i] ? p.tintInk : p.muted)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget toggleRow(String title, String sub, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: settingCard(
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
        kvRow(t('selfDestruct'), ephLabel()),
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

        const SizedBox(height: 8),
        Container(height: 1, color: p.lineSoft),
        const SizedBox(height: 8),
        Text(t('verifyNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 11),
        outlineBtn(t('close'), () => setState(() => sheet = false), padding: const EdgeInsets.all(11)),
      ]),
    );
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
