// app_state.dart — die Bruecke zwischen Oberflaeche und Kern.
//
// Die Oberflaeche hielt ihre Daten bisher in lokalen Variablen mit
// Beispieltexten. Diese Datei ersetzt sie durch das, was wirklich in der
// verschluesselten Datenbank steht — ohne dass an einer einzigen
// Gestaltungsentscheidung etwas geaendert werden muesste.
//
// Sie ist bewusst duenn. Sie haelt keinen eigenen Zustand, den der Kern nicht
// auch haette; sie merkt sich nur, was gerade angezeigt wird, und meldet
// Aenderungen. Alles, was mit Krypto, Netz oder Speichern zu tun hat, liegt im
// Kern und wird dort geprueft.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'core/app_lock.dart';
import 'core/benachrichtigungen.dart';
import 'core/empfang.dart';
import 'core/fenster.dart';
import 'core/fido/client_pin.dart';
import 'core/fido/ctap.dart';
import 'core/fido/stick_zugang.dart';
import 'core/lock/geraete_fach.dart';
import 'core/lock/hardware_key_factor.dart';
import 'core/lock/key_vault.dart';
import 'core/lock/keystore_factor.dart';
import 'core/lock/unlock_factor.dart';
import 'core/lock/vault_store.dart';
import 'core/push.dart';
import 'core/messenger_core.dart';

class AppState extends ChangeNotifier {
  AppState(this.core, {this.tresor, this.stickZugang, this.ablagen});

  /// Woher der gesicherte Bereich des Geraets kommt, je Faktorart.
  ///
  /// Hereinreichbar, weil diese Faktoren sonst die EINZIGEN waeren, die
  /// ungeprueft bleiben — und auf sie faellt am Ende alles zurueck.
  ///
  /// GETRENNT JE ART, und das ist nicht Ordnungsliebe: die beiden Ablagen
  /// muessen verschiedene Namensraeume haben, sonst teilen sie sich den
  /// Schluessel im gesicherten Bereich. Siehe keystore_factor.dart.
  final SchluesselAblage Function(UnlockFactorKind)? ablagen;

  final _ablagenSpeicher = <UnlockFactorKind, SchluesselAblage>{};

  /// Erst beim Gebrauch gebaut: schon das Anlegen verlangt eine
  /// Bildschirmsperre, und beim Start gibt es die vielleicht noch nicht.
  SchluesselAblage ablageFuer(UnlockFactorKind art) {
    final vorhanden = _ablagenSpeicher[art];
    if (vorhanden != null) return vorhanden;
    final bauer = ablagen;
    if (bauer == null) {
      throw const LockUnavailableException(
          'Der Schluesselspeicher wurde nicht angebunden');
    }
    return _ablagenSpeicher[art] = bauer(art);
  }

  /// Was das Geraet ueber diese Anmeldeart sagt — BEVOR etwas passiert.
  ///
  /// Ohne diese Frage tippt der Nutzer und wartet dann auf einen Dialog, der
  /// nie kommt. Mit ihr steht vorher da, was fehlt: kein Fingerabdruck
  /// hinterlegt, keine Bildschirmsperre eingerichtet, keine Hardware.
  Future<GeraeteStand> geraetestand(UnlockFactorKind art) async {
    final ablage = ablageFuer(art);
    if (ablage is GeraeteFach) return ablage.verfuegbar();
    return const GeraeteStand(true, null);
  }

  KeystoreFactor _keystoreFaktor(UnlockFactorKind art) => KeystoreFactor(
        ablage: ablageFuer(art),
        kind: art,
        label: art == UnlockFactorKind.deviceCredential
            ? 'Geraetesperre'
            : 'Fingerabdruck',
      );

  /// Null in Tests — dort gibt es keinen Schluesselspeicher des Geraets.
  final VaultSecretStore? tresor;

  /// Wie ein Sicherheitsschluessel erreicht wird — per NFC oder per Kabel.
  ///
  /// Hereingereicht statt fest verdrahtet, damit der Zustand ohne Geraet
  /// pruefbar bleibt: die Plattformaufrufe fuer NFC und USB laufen in
  /// `flutter test` nicht.
  final Future<CtapTransport> Function(StickWeg)? stickZugang;

  final MessengerCore core;

  /// Ob [boot] durch ist. Vorher zeigt die App nichts an.
  bool bereit = false;

  bool hatIdentitaet = false;
  String meineAdresse = '';
  ConnectionState verbindung = ConnectionState.disconnected;

  List<Contact> kontakte = const [];

  /// Verlaeufe, nur fuer die Unterhaltungen, die schon geoeffnet wurden.
  /// Alles auf einmal zu laden waere bei vielen Kontakten Arbeit fuer nichts.
  final Map<String, List<Message>> verlaeufe = {};

  /// Die zwoelf Woerter — NUR direkt nach dem Anlegen einer Identitaet und
  /// solange der Nutzer sie noch nicht bestaetigt hat. Danach werden sie hier
  /// vergessen; wer sie spaeter sehen will, holt sie ueber
  /// [phraseAusEinstellungen] neu aus dem Schluesselspeicher.
  List<String>? frischePhrase;

  /// Was zuletzt schiefging, in einer Form, die man anzeigen kann.
  String? letzterFehler;

  /// Ob die App gerade auf eine Anmeldung wartet.
  ///
  /// Nicht dasselbe wie "noch nicht geladen": hier gibt es eine Identitaet,
  /// der gesicherte Bereich des Geraets ruecke sie nur noch nicht heraus.
  bool gesperrt = false;

  /// Die eingerichteten Faktoren, so wie sie in der Fachdatei stehen.
  ///
  /// Leer heisst: keine Sperre. Die App oeffnet dann ohne Rueckfrage, und die
  /// Entropie liegt im Schluesselspeicher des Geraets.
  List<KeySlot> faktoren = const [];

  final _abos = <StreamSubscription<Object?>>[];
  final _zufall = Random();

  Future<void> boot() async {
    await _ladeFaktoren();
    try {
      hatIdentitaet = await core.initialize();
      gesperrt = false;
    } on LockedException {
      // Es GIBT eine Identitaet, sie liegt nur in einem Fach, das noch
      // niemand geoeffnet hat. Das ist kein Fehler, sondern der Zweck.
      hatIdentitaet = true;
      gesperrt = true;
      bereit = true;
      notifyListeners();
      return;
    }
    if (hatIdentitaet) await _nachIdentitaet();
    bereit = true;
    notifyListeners();
  }

  Future<void> _ladeFaktoren() async {
    try {
      final v = await tresor?.faecher();
      faktoren = v?.slots ?? const [];
      empfangsTakt = EmpfangsTakt.vonMinuten(v?.empfangsTaktMinuten ?? 0);
      _nieSperren = (v?.sperrfristSekunden ?? 0) < 0;
      sperrfrist = _nieSperren ? Duration.zero : (v?.sperrfrist ?? Duration.zero);
    } catch (e) {
      // Eine unlesbare Fachdatei darf die App nicht am Starten hindern — sonst
      // kaeme man nicht einmal mehr an den Knopf, mit dem sich alles loeschen
      // laesst.
      letzterFehler = '$e';
      faktoren = const [];
    }
  }

  /// Ob es ueberhaupt einen Faktor dieser Art gibt.
  bool hatFaktor(UnlockFactorKind art) =>
      faktoren.any((s) => s.kind == art);

  // ═══════════════════════════════════════════════════════════════ Entsperren

  /// Entsperrt mit dem Fingerabdruck oder dem Gesicht.
  ///
  /// Die App fragt nichts davon selbst ab und bekommt es nie zu sehen. Sie
  /// versucht nur, den Fachschluessel zu lesen; die Abfrage zeigt das System.
  Future<bool> entsperreMitBiometrie() =>
      _entsperreMit(_keystoreFaktor(UnlockFactorKind.biometric));

  /// Entsperrt mit der Sperre des Geraets — PIN, Muster oder Passwort.
  Future<bool> entsperreMitGeraetePin() =>
      _entsperreMit(_keystoreFaktor(UnlockFactorKind.deviceCredential));

  /// Entsperrt mit dem App-Passwort.
  ///
  /// [geraeteGebunden] ist hier false: dieses Fach haengt an nichts als dem
  /// Passwort. Wer die Fachdatei kopiert, kann in Ruhe auf eigener Hardware
  /// probieren — deshalb verlangt der Faktor beim Anlegen ein starkes
  /// Passwort und rechnet mit Argon2id.
  Future<bool> entsperreMitPasswort(String passwort) => _entsperreMit(
      PassphraseFactor(passwort, geraeteGebunden: false, label: 'Passwort'));

  /// Entsperrt mit einem Sicherheitsschluessel.
  ///
  /// [pin] ist die PIN DES STICKS. Null, solange sie nicht bekannt ist — der
  /// Faktor meldet dann [StickPinNoetigException], und die Oberflaeche fragt
  /// nach.
  Future<bool> entsperreMitStick({String? pin, StickWeg weg = StickWeg.usb}) =>
      _entsperreMit(HardwareKeyFactor(oeffne: _wegZum(weg), pin: pin));

  /// Der Weg zum Stick, oder ein klarer Fehler statt eines Absturzes.
  StickOeffner _wegZum(StickWeg weg) {
    final zugang = stickZugang;
    if (zugang == null) {
      throw const LockUnavailableException('kein Weg zum Stick');
    }
    return () => zugang(weg);
  }

  Future<bool> _entsperreMit(UnlockFactor faktor) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    _amFaktor = true;
    try {
      await t.entsperreMit(faktor);
    } finally {
      _amFaktor = false;
    }
    return _nachDemOeffnen();
  }

  /// Zweiter Anlauf, ohne einen Faktor zu wechseln.
  Future<bool> entsperren() async {
    if (tresor != null && !(tresor!.istOffen)) {
      // Ohne offenen Tresor gaebe es nichts zu holen. Welcher Faktor es sein
      // soll, entscheidet die Oberflaeche.
      return false;
    }
    return _nachDemOeffnen();
  }

  Future<bool> _nachDemOeffnen() async {
    try {
      hatIdentitaet = await core.initialize();
      gesperrt = false;
      _weggelegtUm = null;
      if (hatIdentitaet) await _nachIdentitaet();
      notifyListeners();
      return true;
    } on LockedException {
      gesperrt = true;
      notifyListeners();
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════ Faktoren pflegen

  /// Nimmt den Fingerabdruck als Faktor auf.
  ///
  /// Wirft [LockUnavailableException], wenn das Telefon gar keine
  /// Bildschirmsperre hat — dann gibt es nichts, woran sich etwas binden
  /// liesse.
  Future<void> fuegeBiometrieHinzu() =>
      _fuegeHinzu(_keystoreFaktor(UnlockFactorKind.biometric));

  /// Nimmt die Sperre des Geraets als Faktor auf.
  Future<void> fuegeGeraetePinHinzu() =>
      _fuegeHinzu(_keystoreFaktor(UnlockFactorKind.deviceCredential));

  /// Nimmt ein App-Passwort als Faktor auf.
  ///
  /// Wirft [WeakPassphraseException], wenn das Passwort zu wenig hergibt. Das
  /// ist keine Schikane: dieses Fach haengt an nichts als dem Passwort, und
  /// wer die Fachdatei kopiert, probiert auf eigener Hardware, so lange er
  /// will. Argon2id verteuert jeden Versuch, aber gegen eine vierstellige PIN
  /// reicht das nicht.
  Future<void> fuegePasswortHinzu(String passwort) => _fuegeHinzu(
      PassphraseFactor(passwort, geraeteGebunden: false, label: 'Passwort'));

  /// Nimmt einen Sicherheitsschluessel als Faktor auf.
  ///
  /// Verlangt ZWEI Beruehrungen: einmal, um den Zugang anzulegen, einmal, um
  /// das Geheimnis dazu zu holen. Das ist kein Fehler — anders geht es nicht.
  Future<void> fuegeStickHinzu(
      {String? pin, String? name, StickWeg weg = StickWeg.usb}) async {
    await _fuegeHinzu(HardwareKeyFactor(
      oeffne: _wegZum(weg),
      pin: pin,
      label: (name == null || name.trim().isEmpty)
          ? 'Sicherheitsschluessel'
          : name.trim(),
    ));
  }

  Future<void> _fuegeHinzu(UnlockFactor faktor) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    _amFaktor = true;
    try {
      await t.fuegeHinzu(faktor);
    } finally {
      _amFaktor = false;
      // Auch nach einem Fehlschlag neu einlesen: beim Stick kann der Zugang
      // schon angelegt sein, wenn erst das Holen des Geheimnisses scheitert.
      await _ladeFaktoren();
      notifyListeners();
    }
  }

  /// Entfernt einen Faktor.
  ///
  /// Beim LETZTEN ist die App danach wieder ungesperrt, und die Entropie liegt
  /// wieder im Schluesselspeicher. Das ist Absicht: eine App, die sich nach
  /// dem Entfernen des letzten Faktors gar nicht mehr oeffnen liesse, waere
  /// eine Falle.
  Future<void> entferneFaktor(String slotId) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    final slot = faktoren.where((s) => s.id == slotId).firstOrNull;
    // Beim Schluesselspeicher-Fach muss der Fachschluessel im gesicherten
    // Bereich mit weg. Beim Stick und beim Passwort gibt es nichts
    // aufzuraeumen: der Stick behaelt seinen Zugang, und das Passwort steht
    // nirgends.
    final art = slot?.kind;
    await t.entferne(
      slotId,
      faktor: (art == UnlockFactorKind.biometric ||
              art == UnlockFactorKind.deviceCredential)
          ? _keystoreFaktor(art!)
          : null,
    );
    await _ladeFaktoren();
    notifyListeners();
  }

  /// Wie viele Fehlversuche der Stick noch zulaesst.
  ///
  /// Zum Anzeigen, BEVOR jemand die PIN raet: nach acht Fehlversuchen sperrt
  /// sich der Stick endgueltig, und alle Zugaenge darauf sind verloren.
  Future<int?> stickVersuche({StickWeg weg = StickWeg.usb}) async {
    if (stickZugang == null) return null;
    final transport = await _wegZum(weg)();
    await transport.verbinde();
    try {
      return await ClientPin(Ctap2(transport)).verbleibendeVersuche();
    } finally {
      try {
        await transport.trenne();
      } catch (_) {}
    }
  }

  /// Traegt den Anstoss-Endpunkt erneut ein, sobald die Verbindung steht.
  ///
  /// NOETIG, WEIL DER RELAY IHN VERLIEREN KANN: bei einem Serverumzug oder
  /// einem Zuruecksetzen der Datenbank stuende dort nichts mehr, und die App
  /// wuerde nie wieder angestossen — ohne dass irgendwo ein Fehler erschiene.
  void _traegePushEndpunktEin() {
    final e = pushEndpunkt;
    if (e == null || !empfangsTakt.angestossen) return;
    unawaited(core.setPushEndpoint(e));
  }

  Future<void> _nachIdentitaet() async {
    meineAdresse = core.myId;
    await _ladeEinstellungen();
    await raeumeAbgelaufeneWeg();
    kontakte = await core.getContacts();
    _hoereZu();
    // Nicht abwarten: der Kern wirft bei Netzproblemen nicht, er meldet den
    // Zustand. Die Oberflaeche soll sofort da sein, auch im Funkloch.
    unawaited(core.connect());
  }

  // ═══════════════════════════════════════════════════════ Wiederverbinden
  //
  // BEWUSST NUR IM VORDERGRUND. Solange die App sichtbar ist, wartet ein
  // Mensch auf seine Nachricht — da lohnt jeder Versuch. Im Hintergrund
  // weiterzuprobieren waere dagegen der schnellste Weg, den Akku zu leeren,
  // und gehoert an den Vordergrunddienst, den es noch nicht gibt.
  //
  // Ohne das hier faellt die App beim ersten Funkloch stumm und kommt nie
  // zurueck: RelayClient meldet den Abbruch und ueberlaesst die Entscheidung
  // ausdruecklich dieser Schicht.

  Timer? _wiederverbindung;
  int _fehlversuche = 0;
  bool _imVordergrund = true;

  /// Wie viele Nachrichten seit dem letzten Hinsehen gekommen sind.
  int _ungelesen = 0;

  /// Die Texte kommen von aussen: der Kern kennt die Sprache des Nutzers
  /// nicht, und Uebersetzungen gehoeren nicht in eine Datei, die auch ohne
  /// Oberflaeche laufen soll.
  String einNeuText = 'Neue Nachricht';
  String Function(int) mehrereNeuText = (n) => '$n neue Nachrichten';

  /// Groesster Abstand zwischen zwei Versuchen.
  ///
  /// 30 Sekunden und nicht mehr: wer die App offen hat, soll nicht minutenlang
  /// auf eine Verbindung warten, die laengst wieder da waere.
  static const Duration maxAbstand = Duration(seconds: 30);

  /// Wird von der Oberflaeche gemeldet, wenn die App in den Vorder- oder
  /// Hintergrund geht.
  void vordergrund(bool sichtbar) {
    if (_imVordergrund == sichtbar) return;
    _imVordergrund = sichtbar;
    if (sichtbar) {
      unawaited(_beendeHintergrundempfang());
      if (_sollWiederSperren()) {
        unawaited(sperreWieder());
        return;
      }
      _ungelesen = 0;
      unawaited(Benachrichtigungen.instanz.raeumeAuf());
      unawaited(raeumeAbgelaufeneWeg());
      _fehlversuche = 0;
      if (verbindung != ConnectionState.online) unawaited(_versucheVerbindung());
    } else {
      _weggelegtUm = DateTime.now();
      _wiederverbindung?.cancel();
      _wiederverbindung = null;
      unawaited(_starteHintergrundempfang());
    }
  }

  // ═══════════════════════════════════════════════════ Empfang im Hintergrund

  /// Der Vordergrunddienst. Null in Tests.
  EmpfangsDienst? empfangsDienst;

  /// Wie oft im Hintergrund nachgesehen wird.
  ///
  /// Steht in der Fachdatei neben der Sperrfrist und NICHT in den
  /// Einstellungen: die liegen in der verschluesselten Datenbank, und die ist
  /// beim Sperren zu.
  EmpfangsTakt empfangsTakt = EmpfangsTakt.aus;

  /// Texte fuer die dauerhafte Benachrichtigung. Der Kern kennt keine Sprache.
  String empfangTitelText = 'BitDM';
  String empfangLaeuftText = 'Empfangsbereit';

  Timer? _empfangsTimer;

  /// Ob der Hintergrundempfang gerade ueberhaupt etwas ausrichten KANN.
  ///
  /// Bei eingeschalteter Sperre und abgelaufener Frist ist die Entropie weg —
  /// und ohne sie gibt es keinen Identitaetsschluessel, ohne den der Relay
  /// nicht einmal die Frage beantwortet, ob etwas anliegt.
  bool get empfangMoeglich =>
      empfangsTakt.an && hatIdentitaet && !gesperrt && !_sperrtGleich;

  /// Ob die App beim naechsten Weglegen sofort zusperrt.
  bool get _sperrtGleich =>
      faktoren.isNotEmpty && !_nieSperren && sperrfrist == Duration.zero;

  /// Die Anbindung an den Verteiler auf dem Telefon. Null in Tests.
  PushAnbindung? push;

  /// Der zuletzt vom Verteiler genannte Endpunkt.
  String? pushEndpunkt;

  Future<void> setzeEmpfangsTakt(EmpfangsTakt takt) async {
    final vorher = empfangsTakt;
    final t = tresor;
    if (t != null) await t.setzeEmpfangsTakt(takt.minuten);
    empfangsTakt = takt;
    if (!takt.an) await _beendeHintergrundempfang();

    // BEIM WECHSEL AUFRAEUMEN, und zwar in dieser Reihenfolge: erst abmelden,
    // dann anmelden. Andersherum koennte der Verteiler den frischen Endpunkt
    // gleich wieder wegwerfen.
    if (vorher.angestossen && !takt.angestossen) {
      await _beendePush();
    }
    if (takt.angestossen && !vorher.angestossen) {
      await _startePush();
    }
    notifyListeners();
  }

  /// Meldet BitDM beim Verteiler an. Der Endpunkt kommt spaeter ueber den
  /// Rueckruf, nicht von hier.
  Future<void> _startePush({String? verteiler}) async {
    final p = push;
    if (p == null) throw const PushException(PushHindernis.keinVerteiler);
    await p.melde(verteilerName: verteiler);
  }

  Future<void> _beendePush() async {
    pushEndpunkt = null;
    // ERST beim Relay loeschen, DANN beim Verteiler abmelden. Andersherum
    // bliebe ein Endpunkt eingetragen, an den niemand mehr horcht — der Relay
    // klopfte dann ins Leere und wuesste es nicht.
    try {
      await core.setPushEndpoint(null);
    } catch (_) {
      // Nicht verbunden. Der Endpunkt bleibt eingetragen, bis die App das
      // naechste Mal online ist; angestossen wird dann ins Leere, was nichts
      // kaputtmacht.
    }
    await push?.melde_ab();
  }

  /// Der Verteiler nennt einen Endpunkt — beim Einrichten und immer dann, wenn
  /// er ihn von sich aus wechselt.
  ///
  /// DASS ER WECHSELN KANN, ist der Grund, warum das ein Rueckruf ist: ntfy
  /// vergibt nach einer Neuinstallation ein neues Thema. Wer den alten
  /// Endpunkt beim Relay stehen laesst, wird nie wieder angestossen und merkt
  /// es nicht.
  Future<void> nimmPushEndpunkt(String endpunkt) async {
    if (!PushAnbindung.eigenerServer(endpunkt)) {
      // Ein fremder Server wuerde vom Relay ohnehin abgelehnt. Hier faellt es
      // frueher auf, und die Meldung kann sagen, WARUM.
      letzterFehler = 'Push-Endpunkt auf fremdem Server: $endpunkt';
      notifyListeners();
      return;
    }
    pushEndpunkt = endpunkt;
    await core.setPushEndpoint(endpunkt);
    notifyListeners();
  }

  /// Ein Anstoss ist angekommen: verbinden, abholen, wieder trennen.
  ///
  /// Was NICHT im Anstoss steht: Absender, Inhalt, Anzahl. Er sagt nur, dass
  /// etwas anliegt.
  Future<void> beiAnstoss() async {
    if (!empfangMoeglich) return;
    await core.connect();
    // Der Relay leert seine Warteschlange gleich nach der Anmeldung. Kurz
    // offen lassen, damit das durchlaeuft.
    await Future<void>.delayed(const Duration(seconds: 20));
    if (!_imVordergrund) await core.disconnect();
  }

  Future<void> _starteHintergrundempfang() async {
    if (!empfangMoeglich) return;

    // BEIM ANSTOSSEN LAEUFT NICHTS. Das ist der ganze Vorteil: kein Dienst,
    // keine dauerhafte Benachrichtigung, kein Akkuverbrauch. Der Verteiler auf
    // dem Telefon haelt die Verbindung, und die weckt BitDM, wenn etwas
    // anliegt.
    if (empfangsTakt.angestossen) return;

    final dienst = empfangsDienst;
    if (dienst == null) return;

    await dienst.starte(titel: empfangTitelText, text: empfangLaeuftText);

    if (empfangsTakt.dauerhaft) {
      // Die bestehende Verbindung bleibt einfach offen. Der Kern verbindet
      // von sich aus nach, wenn sie abreisst — dieselbe Logik wie im
      // Vordergrund, statt einer zweiten daneben.
      if (verbindung != ConnectionState.online) {
        unawaited(core.connect());
      }
      return;
    }

    // Im Takt: verbinden, abholen, wieder trennen. Eine offene Verbindung
    // kostet dauerhaft Funk; ein kurzer Griff alle 15 Minuten deutlich
    // weniger.
    await core.disconnect();
    _empfangsTimer?.cancel();
    _empfangsTimer = Timer.periodic(empfangsTakt.abstand, (_) async {
      if (!empfangMoeglich) {
        await _beendeHintergrundempfang();
        return;
      }
      await core.connect();
      // Kurz offen lassen, damit der Relay seine Warteschlange leeren kann.
      // Er schickt alles Wartende gleich nach der Anmeldung.
      await Future<void>.delayed(const Duration(seconds: 20));
      if (!_imVordergrund) await core.disconnect();
    });
  }

  Future<void> _beendeHintergrundempfang() async {
    _empfangsTimer?.cancel();
    _empfangsTimer = null;
    final dienst = empfangsDienst;
    if (dienst != null && dienst.laeuft) await dienst.stoppe();
  }

  // ═══════════════════════════════════════════════════════ Von selbst zusperren

  /// Wann die App zuletzt weggelegt wurde. Null heisst: sie war nicht weg.
  DateTime? _weggelegtUm;

  /// Wie lange die App zu bleiben darf, ohne wieder zu verriegeln.
  ///
  /// STANDARD IST SOFORT. Wer eine Sperre einrichtet, will gefragt werden —
  /// und nicht manchmal. Laenger geht auch, aber das muss man wollen und
  /// einstellen; siehe [setzeSperrfrist].
  ///
  /// Die Zahl steht in der Fachdatei, nicht in den Einstellungen: die liegen
  /// in der verschluesselten Datenbank, und die ist beim Sperren zu — die
  /// Frist waere dann genau in dem Moment nicht lesbar, in dem sie gebraucht
  /// wird.
  Duration sperrfrist = Duration.zero;

  /// Die Auswahl, die die Oberflaeche anbietet. -1 heisst: gar nicht sperren.
  static const List<int> sperrfristAuswahl = [0, 60, 300, -1];

  /// Ob gerade ein Faktor bedient wird.
  ///
  /// WICHTIG BEI "SOFORT": das Freigeben eines USB-Sticks zeigt Android als
  /// eigenen Dialog, und die App geht dabei in den Hintergrund. Wuerde sie
  /// dann zusperren, liesse sich ein Stick nie einrichten — man kaeme immer
  /// nur bis zur Freigabe.
  bool _amFaktor = false;

  Future<void> setzeSperrfrist(int sekunden) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    await t.setzeSperrfrist(sekunden < 0 ? -1 : sekunden);
    sperrfrist = sekunden < 0 ? Duration.zero : Duration(seconds: sekunden);
    _nieSperren = sekunden < 0;
    notifyListeners();
  }

  bool _nieSperren = false;

  /// Die Frist als Zahl, wie die Oberflaeche sie anzeigt. -1 heisst nie.
  int get sperrfristAlsZahl => _nieSperren ? -1 : sperrfrist.inSeconds;

  bool _sollWiederSperren() {
    if (faktoren.isEmpty) return false; // ohne Faktor gibt es nichts zu sperren
    if (gesperrt || _nieSperren || _amFaktor) return false;
    final weg = _weggelegtUm;
    if (weg == null) return false;
    return DateTime.now().difference(weg) >= sperrfrist;
  }

  /// Verriegelt wieder: Datenbank zu, Schluessel aus dem Speicher.
  ///
  /// Nicht bloss ein Bildschirm davor. Ein Vorhang liesse die Datenbank offen
  /// und die Schluessel im Arbeitsspeicher — wer den Prozess lesen kann, kaeme
  /// daran vorbei.
  Future<void> sperreWieder() async {
    if (faktoren.isEmpty) return;
    _weggelegtUm = null;
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    for (final a in _abos) {
      unawaited(a.cancel());
    }
    _abos.clear();

    tresor?.sperre();
    await core.lock();

    // Auch das, was die Oberflaeche schon geholt hat, muss weg. Die Verlaeufe
    // stehen hier IM KLARTEXT — sie kamen ja entschluesselt aus der Datenbank.
    // Die Datenbank zu schliessen und den Text daneben liegen zu lassen waere
    // halbe Arbeit.
    verlaeufe.clear();
    kontakte = const [];
    meineAdresse = '';
    frischePhrase = null;

    gesperrt = true;
    notifyListeners();
  }

  Future<void> _versucheVerbindung() async {
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    if (!hatIdentitaet || !_imVordergrund) return;
    await core.connect();
  }

  void _planeWiederverbindung() {
    if (!_imVordergrund || _wiederverbindung != null) return;

    // Verdoppeln mit Zufallsanteil. Der Zufall ist nicht Zierrat: ohne ihn
    // kaemen nach einem Ausfall des Relays alle Clients gleichzeitig zurueck
    // und legten ihn erneut lahm.
    final stufe = _fehlversuche.clamp(0, 5);
    final basis = Duration(seconds: 1 << stufe);
    final gedeckelt = basis > maxAbstand ? maxAbstand : basis;
    final streuung = Duration(
        milliseconds: _zufall.nextInt(gedeckelt.inMilliseconds ~/ 2 + 1));
    _fehlversuche++;

    _wiederverbindung = Timer(gedeckelt + streuung, () {
      _wiederverbindung = null;
      unawaited(_versucheVerbindung());
    });
  }

  void _hoereZu() {
    if (_abos.isNotEmpty) return;
    _abos
      ..add(core.connectionStateChanges.listen((s) {
        verbindung = s;
        if (s == ConnectionState.online) {
          _fehlversuche = 0;
          _wiederverbindung?.cancel();
          _wiederverbindung = null;
          _traegePushEndpunktEin();
        } else if (s == ConnectionState.disconnected ||
            s == ConnectionState.error) {
          _planeWiederverbindung();
        }
        notifyListeners();
      }))
      ..add(core.incomingMessages.listen((m) {
        verlaeufe.putIfAbsent(m.chatId, () => []).add(m);
        // Nur melden, wenn niemand hinsieht. Eine Benachrichtigung fuer eine
        // Nachricht, die gerade auf dem Bildschirm erscheint, waere Laerm.
        if (!_imVordergrund) {
          _ungelesen++;
          unawaited(Benachrichtigungen.instanz.zeigeNeueNachricht(
              anzahl: _ungelesen,
              text: _ungelesen == 1 ? einNeuText : mehrereNeuText(_ungelesen)));
        }
        unawaited(_ladeKontakteNeu());
      }))
      ..add(core.contactEvents.listen((_) => unawaited(_ladeKontakteNeu())))
      ..add(core.messageStatusUpdates.listen(_uebernehmeStatus));
  }

  void _uebernehmeStatus(MessageStatusUpdate u) {
    final liste = verlaeufe[u.chatId];
    if (liste == null) return;
    final i = liste.indexWhere((m) => m.id == u.messageId);
    if (i < 0) return;
    liste[i] = liste[i].copyWith(status: u.status);
    notifyListeners();
  }

  Future<void> _ladeKontakteNeu() async {
    kontakte = await core.getContacts();
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════════════ Identitaet

  /// Legt eine Identitaet an und haelt die zwoelf Woerter zum Anzeigen bereit.
  Future<void> identitaetAnlegen() async {
    frischePhrase = await core.createIdentity();
    hatIdentitaet = true;
    await _nachIdentitaet();
    notifyListeners();
  }

  Future<bool> identitaetWiederherstellen(List<String> woerter) async {
    if (!core.isValidRecoveryPhrase(woerter)) {
      letzterFehler = 'phraseUngueltig';
      notifyListeners();
      return false;
    }
    try {
      await core.restoreIdentity(woerter);
      hatIdentitaet = true;
      await _nachIdentitaet();
      notifyListeners();
      return true;
    } on MessengerException {
      letzterFehler = 'phraseUngueltig';
      notifyListeners();
      return false;
    }
  }

  /// Der Nutzer hat bestaetigt, dass er die Woerter notiert hat.
  void phraseBestaetigt() {
    frischePhrase = null;
    notifyListeners();
  }

  Future<List<String>> phraseAusEinstellungen() => core.getRecoveryPhrase();

  // ═════════════════════════════════════════════════════════════════ Kontakte

  List<Contact> get aktiveKontakte =>
      kontakte.where((c) => c.state == ContactState.active).toList();

  List<Contact> get offeneAnfragen => kontakte
      .where((c) => c.state == ContactState.incomingPending)
      .toList();

  List<Contact> get eigeneAnfragen => kontakte
      .where((c) => c.state == ContactState.outgoingPending)
      .toList();

  bool adresseGueltig(String a) => core.isValidAddress(a);

  /// Gibt true zurueck, wenn die Anfrage rausging.
  Future<bool> kontaktHinzufuegen(String adresse) async {
    try {
      await core.addContact(adresse);
      await _ladeKontakteNeu();
      return true;
    } on InvalidAddressException {
      letzterFehler = 'adresseUngueltig';
      notifyListeners();
      return false;
    }
  }

  Future<void> anfrageAnnehmen(String id) async {
    await core.acceptRequest(id);
    await _ladeKontakteNeu();
  }

  Future<void> anfrageAblehnen(String id) async {
    await core.declineRequest(id);
    verlaeufe.remove(id);
    await _ladeKontakteNeu();
  }

  // ══════════════════════════════════════════════════════════════ Nachrichten

  List<Message> verlaufVon(String id) => verlaeufe[id] ?? const [];

  Future<void> unterhaltungOeffnen(String id) async {
    verlaeufe[id] = await core.getMessages(id);
    notifyListeners();
    unawaited(core.markRead(id));
  }

  Future<void> senden(String id, String text) async {
    final sauber = text.trim();
    if (sauber.isEmpty) return;
    try {
      final m = await core.sendMessage(id, sauber);
      verlaeufe.putIfAbsent(id, () => []).add(m);
      notifyListeners();
    } on MessageTooLargeException {
      letzterFehler = 'zuLang';
      notifyListeners();
    }
  }

  Future<SafetyNumber> pruefnummer(String id) => core.getSafetyNumber(id);

  // ══════════════════════════════════════════════════════════ Einstellungen

  AppPreferences einstellungen = const AppPreferences();

  Future<void> _ladeEinstellungen() async {
    einstellungen = await core.getPreferences();
    // Die Sperre wird beim Start in MainActivity.onCreate gesetzt, bevor
    // ueberhaupt gezeichnet wird. Hier wird sie nur an die gespeicherte
    // Einstellung angeglichen — moeglicherweise also geloest.
    await Fenster.screenshotSperre(einstellungen.blockScreenshots);
    notifyListeners();
  }

  Future<void> setzeEinstellungen(AppPreferences neu) async {
    await core.setPreferences(neu);
    einstellungen = neu;
    await Fenster.screenshotSperre(neu.blockScreenshots);
    notifyListeners();
  }

  /// Raeumt Abgelaufenes weg und meldet, ob sich etwas geaendert hat.
  ///
  /// Wird beim Start und bei jedem Zurueckkommen in den Vordergrund gerufen —
  /// sonst saehe der Nutzer nach dem Aufwachen noch Nachrichten, die laengst
  /// haetten verschwinden sollen.
  Future<void> raeumeAbgelaufeneWeg() async {
    if (!hatIdentitaet) return;
    final weg = await core.purgeExpiredMessages();
    if (weg == 0) return;
    // Betroffene Verlaeufe neu laden statt zu raten, welche es traf.
    for (final id in verlaeufe.keys.toList()) {
      verlaeufe[id] = await core.getMessages(id);
    }
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════ Loeschen

  /// Loescht alles. Unwiderruflich, ausser man hat die zwoelf Woerter.
  ///
  /// Bis zum 25.07.2026 hat der Knopf in der Oberflaeche nur Anzeigewerte
  /// zurueckgesetzt. Solange die App ein Entwurf war, fiel das nicht auf;
  /// sobald echte Nachrichten dahinterliegen, ist ein Knopf, der "alles
  /// geloescht" sagt und es nicht tut, schlimmer als gar keiner.
  Future<void> allesLoeschen() async {
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    _fehlversuche = 0;

    await core.wipeEverything();

    hatIdentitaet = false;
    meineAdresse = '';
    kontakte = const [];
    verlaeufe.clear();
    frischePhrase = null;
    letzterFehler = null;
    verbindung = ConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    for (final a in _abos) {
      unawaited(a.cancel());
    }
    _abos.clear();
    unawaited(core.dispose());
    super.dispose();
  }
}

/// Formatiert eine 56-stellige Adresse in Vierergruppen — dieselbe
/// Darstellung, die der Entwurf schon benutzt hat.
String adresseFormatiert(String a) {
  final sb = StringBuffer();
  for (var i = 0; i < a.length; i += 4) {
    if (i > 0) sb.write('-');
    sb.write(a.substring(i, i + 4 > a.length ? a.length : i + 4).toUpperCase());
  }
  return sb.toString();
}
