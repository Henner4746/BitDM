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
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'core/anhang/anhang_empfang.dart';
import 'core/anhang/anhang_versand.dart';
import 'core/anhang/lager_client.dart';
import 'core/app_lock.dart';
import 'core/benachrichtigungen.dart';
import 'core/dateien.dart';
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
import 'core/net/relay_client.dart' show RelayException;
import 'core/push.dart';
import 'core/messenger_core.dart';
import 'core/nah/funk.dart';
import 'core/real_messenger_core.dart';
import 'core/verbindungstest.dart';

class AppState extends ChangeNotifier {
  AppState(this.core,
      {this.tresor,
      this.stickZugang,
      this.ablagen,
      this.dateien = const SystemDateiWahl()});

  /// Woher eine Datei kommt und wohin eine geht.
  ///
  /// Hereinreichbar, damit der Anhang-Weg OHNE Menschen pruefbar ist: der
  /// Auswahldialog gehoert Android, nicht BitDM. Siehe core/dateien.dart.
  final DateiWahl dateien;

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
      // Ohne Fachdatei gilt die Werkseinstellung: alle 15 Minuten. Wer sie
      // ausschaltet, schreibt eine Datei mit 0 — die bleibt dann auch 0.
      empfangsTakt = EmpfangsTakt.vonMinuten(
          v?.empfangsTaktMinuten ?? KeyVault.empfangsTaktAbWerk);
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
  /// Entfernt einen Kontakt samt Verlauf.
  ///
  /// ES GAB DAFUER KEINEN WEG IN DER OBERFLAECHE. `removeContact` steht seit
  /// jeher im Kern, gerufen hat es niemand — wer eine falsche Adresse
  /// eintippte, wurde sie nie wieder los. Bei 56 Zeichen ist das kein
  /// Randfall.
  Future<void> entferneKontakt(String id) async {
    await core.removeContact(id);
    kontakte.removeWhere((k) => k.id == id);
    verlaeufe.remove(id);
    notifyListeners();
  }

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

  /// Die Anbindung an den Verteiler auf dem Telefon.
  ///
  /// Ersetzbar, weil der Verteiler eine ANDERE App auf demselben Telefon ist —
  /// nachbauen laesst er sich nicht, und ohne Ersatz bliebe der Fall
  /// "Verteiler weigert sich" ungeprueft. Genau der ist der haeufigste.
  PushAnbindung? push;

  /// Der zuletzt vom Verteiler genannte Endpunkt.
  String? pushEndpunkt;

  Future<void> setzeEmpfangsTakt(EmpfangsTakt takt) async {
    final vorher = empfangsTakt;

    // ERST DAS, WAS FEHLSCHLAGEN KANN. Waere die Einstellung schon
    // gespeichert, wenn sich der Verteiler weigert, stuende in der App
    // "Anstoss" — und es liefe nichts. Ein Zustand, den der Nutzer nicht von
    // einem echten unterscheiden kann und der erst auffaellt, wenn tagelang
    // keine Nachricht kommt.
    if (takt.angestossen && !vorher.angestossen) {
      await _startePush();
    }

    final t = tresor;
    if (t != null) await t.setzeEmpfangsTakt(takt.minuten);
    empfangsTakt = takt;
    if (!takt.an) await _beendeHintergrundempfang();

    // Beim Wegwechseln erst danach abmelden: waere es davor, und das
    // Speichern schluege fehl, waere der Verteiler weg und die Einstellung
    // stuende weiter auf Anstoss.
    if (vorher.angestossen && !takt.angestossen) {
      await _beendePush();
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
    // Kein Wiederverbinden gegen den Willen des Nutzers. Ohne diese Zeile
    // versuchte der Zeitgeber im Hintergrund weiter, sich zu verbinden — der
    // Kern lehnte jedes Mal ab, aber es waere ein Wecker, der alle paar
    // Sekunden gegen eine verschlossene Tuer laeuft.
    if (einstellungen.nurNahbereich) return;

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
      ..add(core.messageStatusUpdates.listen(_uebernehmeStatus))
      ..add(core.anhangAenderungen.listen((a) {
        anhaenge.putIfAbsent(a.chatId, () => {})[a.messageId] = a;
        // Ist er da, ist der Fortschritt erledigt und soll weg — sonst
        // stuende unter der fertigen Datei noch ein Balken.
        if (a.zustand != AnhangZustand.laedt) fortschritt.remove(a.messageId);
        notifyListeners();
      }))
      ..add(core.anhangFortschritt.listen((f) {
        fortschritt[f.messageId] = f;
        // OHNE DROSSEL waere das mehrmals je Sekunde ein kompletter Neubau
        // des Bildschirms — bei einer 3-GB-Datei minutenlang. Gezeichnet wird
        // hoechstens alle 100 ms; die Zahl selbst ist immer die aktuelle.
        final jetzt = DateTime.now();
        if (_letzterBalken == null ||
            jetzt.difference(_letzterBalken!).inMilliseconds >= 100 ||
            f.fertigeBytes >= f.gesamtBytes) {
          _letzterBalken = jetzt;
          notifyListeners();
        }
      }));
  }

  DateTime? _letzterBalken;

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
    // In EINEM Zug fuer die ganze Unterhaltung. Je Nachricht zu fragen hiesse
    // bei fuenfzig Anhaengen fuenfzig Abfragen beim Zeichnen einer Liste.
    anhaenge[id] = await core.getAnhaenge(id);
    notifyListeners();
    unawaited(core.markRead(id));
  }

  // ══════════════════════════════════════════════════════════════════ Anhaenge

  /// chatId → messageId → Eintrag.
  final Map<String, Map<String, AnhangEintrag>> anhaenge = {};

  /// Was gerade laeuft, nach Nachrichtenkennung. Leer, sobald es fertig ist.
  final Map<String, AnhangFortschritt> fortschritt = {};

  AnhangEintrag? anhangZu(String chatId, String messageId) =>
      anhaenge[chatId]?[messageId];

  /// Schickt eine Datei.
  ///
  /// Laeuft bei drei Gigabyte minutenlang. Der Verlauf bekommt die Nachricht
  /// erst, wenn alles oben ist — bis dahin traegt [fortschritt] den Stand
  /// unter [schwebendeKennung].
  Future<void> anhangSenden(String chatId, File datei,
      {String? name, int? groesse}) async {
    if (schwebendeKennung != null) {
      // EINER NACH DEM ANDEREN. Zwei gleichzeitige Uploads teilen sich die
      // Leitung, verdoppeln den Speicherbedarf und machen den Fortschritt
      // unlesbar. Der Nutzer merkt davon nur, dass der Knopf wartet.
      letzterFehler = 'anhangLaeuft';
      notifyListeners();
      return;
    }
    schwebendeKennung = '${DateTime.now().microsecondsSinceEpoch}';
    schwebenderName = name ?? datei.uri.pathSegments.last;
    schwebenderChat = chatId;
    notifyListeners();
    try {
      final m = await core.sendeAnhang(chatId, datei,
          name: name, groesse: groesse);
      verlaeufe.putIfAbsent(chatId, () => []).add(m);
      anhaenge[chatId] = await core.getAnhaenge(chatId);
    } on AnhangZuGross catch (e) {
      letzterFehler = 'anhangZuGross:${e.groesse}:${e.grenze}';
    } on LagerVoll {
      letzterFehler = 'lagerVoll';
    } catch (e) {
      letzterFehler = _anhangFehler(e);
      _merkeTechnisch(e);
    } finally {
      fortschritt.remove(schwebendeKennung);
      schwebendeKennung = null;
      schwebenderName = null;
      schwebenderChat = null;
      notifyListeners();
    }
  }

  /// Holt einen angekuendigten Anhang.
  Future<void> anhangHolen(String chatId, String messageId) async {
    try {
      await core.holeAnhang(chatId, messageId);
    } on LagerLeer {
      // Kein Fehler zum Anzeigen: der Zustand steht jetzt auf "weg", und die
      // Blase sagt es selbst. Eine zweite Meldung darueber waere Laerm.
    } catch (e) {
      letzterFehler = _anhangFehler(e);
      _merkeTechnisch(e);
    } finally {
      anhaenge[chatId] = await core.getAnhaenge(chatId);
      notifyListeners();
    }
  }

  /// Waehrend eines Versands: die Ersatzkennung, unter der der Fortschritt
  /// laeuft, bevor es die Nachricht gibt.
  ///
  /// Die Nachricht entsteht erst, wenn ALLES oben ist — bei drei Gigabyte also
  /// nach Minuten. Ohne diese drei Felder saehe der Nutzer waehrenddessen eine
  /// unveraenderte Unterhaltung und wuesste nicht, ob ueberhaupt etwas
  /// passiert.
  String? schwebendeKennung;
  String? schwebenderName;
  String? schwebenderChat;

  /// Der laufende Verbindungstest: was bisher geprueft wurde.
  ///
  /// Waechst waehrend des Laufs, damit der Nutzer sieht, dass etwas passiert —
  /// bei einer Zeitgrenze von zwoelf Sekunden je Schritt waere ein Bildschirm,
  /// der eine halbe Minute nichts tut, nicht von einem haengengebliebenen zu
  /// unterscheiden.
  final List<Schritt> testSchritte = [];
  bool testLaeuft = false;

  Future<void> verbindungPruefen() async {
    if (testLaeuft) return;
    testLaeuft = true;
    testSchritte.clear();
    notifyListeners();

    final k = core;
    if (k is! RealMessengerCore) {
      testLaeuft = false;
      notifyListeners();
      return;
    }
    try {
      await Verbindungstest(k.testUmgebung).lauf(beiSchritt: (s) {
        testSchritte.add(s);
        notifyListeners();
      });
    } finally {
      testLaeuft = false;
      notifyListeners();
    }
  }

  /// Was zuletzt technisch schiefging — unuebersetzt, zum Weitergeben.
  ///
  /// WARUM DAS GEBRAUCHT WIRD: die uebersetzten Meldungen fassen sehr
  /// verschiedene Ursachen zu einem Satz zusammen. "That did not go through"
  /// steht sowohl fuer einen Verbindungsabbruch als auch fuer einen Fehler
  /// beim Lesen der Datei. Der Nutzer soll den einen Satz sehen; wer den
  /// Fehler beheben will, braucht den Rest. Er steht im Verbindungstest.
  ///
  /// NUR DIE ART UND DIE MELDUNG, keine Kennungen, keine Adressen, keine
  /// Dateinamen: der Bildschirm wird abfotografiert und weitergeschickt.
  String? letzteTechnischeMeldung;

  void _merkeTechnisch(Object e) {
    final art = e.runtimeType.toString();
    var text = e.toString();
    if (text.startsWith('$art: ')) text = text.substring(art.length + 2);
    if (text.length > 160) text = '${text.substring(0, 160)}…';
    letzteTechnischeMeldung = '$art — $text';
  }

  /// Bringt einen Fehler in eine Form, die die Oberflaeche uebersetzen kann.
  ///
  /// Die Meldung der Ausnahme selbst NICHT durchreichen: sie ist auf Englisch,
  /// technisch, und im Fall des Lagers traegt sie eine Kennung — also etwas,
  /// das in keiner Bildschirmaufnahme stehen soll.
  static String _anhangFehler(Object e) {
    if (e is NurNahbereichException) return 'nurNahbereich';
    final t = e.toString();
    if (t.contains('Tagesmenge')) return 'tagesmenge';
    if (e is AnhangKaputt) return 'anhangKaputt';
    if (e is LagerException || e is RelayException) return 'anhangNetz';
    return 'anhangFehler';
  }

  Future<void> senden(String id, String text) async {
    final sauber = text.trim();
    if (sauber.isEmpty) return;
    try {
      final m = await core.sendMessage(id, sauber);
      // NICHT `.add(...)` AUF DIE LISTE DES KERNS.
      //
      // Was in `verlaeufe` liegt, kommt aus `core.history(...)` — und ob das
      // eine wachsende Liste ist, entscheidet der Kern, nicht diese Stelle.
      // Gibt er eine unveraendlerliche zurueck (was ein Kern durchaus tun
      // darf, und die Attrappe tut es), scheitert das Anhaengen mit einem
      // Fehler, der weder gefangen noch angezeigt wird: die Nachricht ist
      // gesendet, aber der Verlauf zeigt sie nicht.
      //
      // Eine neue Liste zu bauen kostet bei Chatlaengen nichts und macht die
      // Annahme ueberfluessig.
      verlaeufe[id] = [...?verlaeufe[id], m];
      notifyListeners();
    } on MessageTooLargeException {
      letzterFehler = 'zuLang';
      notifyListeners();
    }
  }

  /// Setzt eine Meldung, die die Oberflaeche uebersetzen kann.
  ///
  /// Nimmt einen SCHLUESSEL und keinen fertigen Satz: die Sprache waehlt die
  /// Oberflaeche, und ein hier zusammengebauter deutscher Text stuende auch
  /// in der englischen Fassung.
  void setzeFehler(String schluessel) {
    letzterFehler = schluessel;
    notifyListeners();
  }

  /// Vergisst die letzte Fehlermeldung.
  ///
  /// Damit eine Meldung verschwindet, sobald der Nutzer etwas dagegen tut —
  /// eine, die stehen bleibt, waehrend man sie schon behoben hat, verwirrt
  /// mehr als sie hilft.
  void vergissFehler() {
    if (letzterFehler == null) return;
    letzterFehler = null;
    notifyListeners();
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

  // ══════════════════════════════════════════════════════════ In der Naehe

  /// Null in Tests und ueberall dort, wo es kein Bluetooth gibt.
  ///
  /// Nachtraeglich gesetzt statt im Konstruktor verlangt: `flutter test` hat
  /// keine Plattformkanaele, und ein Pflichtfeld haette jeden Zustandstest an
  /// Bluetooth gebunden.
  Nahfunk? funk;

  /// Was das Geraet ueber Bluetooth sagt. Null, solange nicht gefragt wurde.
  ///
  /// Wird bei jedem Oeffnen der Einstellungen neu geholt: Bluetooth laesst
  /// sich ausserhalb der App umschalten, und eine gemerkte Antwort waere
  /// spaetestens beim zweiten Hinsehen falsch.
  Funkzustand? funkzustand;

  /// Ob Android die Rechteabfrage dauerhaft dichtgemacht hat.
  ///
  /// Getrennt vom Zustand, weil es sich nur durch eine ABFRAGE herausfinden
  /// laesst — `checkSelfPermission` sagt bloss "fehlt", nicht "fehlt und wird
  /// nie wieder gefragt". Die Oberflaeche muss den Unterschied kennen, sonst
  /// bietet sie einen Knopf an, bei dem sichtbar nichts passiert.
  bool rechteEndgueltigWeg = false;

  Future<void> pruefeFunk() async {
    final f = funk;
    if (f == null) return;
    try {
      funkzustand = await f.zustand();
    } on FunkFehler {
      funkzustand = null;
    }
    notifyListeners();
  }

  /// Fragt die Bluetooth-Rechte ab und aktualisiert den Zustand.
  ///
  /// Gibt zurueck, ob es jetzt geht — der Aufrufer schaltet nur dann den
  /// Schalter um. Einen Schalter umzulegen, dessen Voraussetzung fehlt, waere
  /// eine Einstellung ohne Wirkung.
  Future<bool> erlaubeFunk() async {
    final f = funk;
    if (f == null) return false;
    try {
      final lage = await f.fordereRechte();
      rechteEndgueltigWeg = lage == Rechtelage.dauerhaftAbgelehnt;
      await pruefeFunk();
      return lage == Rechtelage.erteilt;
    } on FunkFehler {
      return false;
    }
  }

  /// Ob dieser Kontakt einen sieht — und man ihn.
  Future<void> setzeAnwesenheit(String kontaktId, bool zeigen) async {
    await core.setContactPresence(kontaktId, zeigen);
    // Die Liste selbst neu holen statt den einen Eintrag zu ersetzen: sonst
    // stehen hier zwei Wahrheiten, und beim naechsten Nachladen gewinnt die
    // aus der Datenbank ohnehin.
    kontakte = await core.getContacts();
    notifyListeners();
  }

  Future<void> oeffneSystemeinstellungen() async {
    try {
      await funk?.oeffneEinstellungen();
    } on FunkFehler {
      // Kein Grund, irgendetwas anzuhalten: es gibt Geraete ohne diesen
      // Bildschirm, und der Nutzer findet ihn dann von Hand.
    }
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
/// Ein Beispiel im GENAU SELBEN Format, in dem die App Adressen zeigt und
/// kopiert.
///
/// Es stand hier als fester Text "B3XK-7QMD-2FTV-…" — mit Strichen, waehrend
/// die Zwischenablage die rohe Adresse ohne Striche lieferte. Wer kopierte und
/// einfuegte, sah etwas anderes als das Beispiel und hielt die eingefuegte
/// Adresse fuer falsch. Jetzt kommt es durch dieselbe Funktion wie alles
/// andere und kann nicht mehr auseinanderlaufen.
final String beispielAdresse =
    '${adresseFormatiert('b3xk7qmd2ftv9sln4hrw6jyc8pzb5nkq7wdm3xrv')}…';

String adresseFormatiert(String a) {
  final sb = StringBuffer();
  for (var i = 0; i < a.length; i += 4) {
    if (i > 0) sb.write('-');
    sb.write(a.substring(i, i + 4 > a.length ? a.length : i + 4).toUpperCase());
  }
  return sb.toString();
}
