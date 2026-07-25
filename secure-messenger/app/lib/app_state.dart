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
import 'core/fenster.dart';
import 'core/fido/client_pin.dart';
import 'core/fido/ctap.dart';
import 'core/fido/stick_zugang.dart';
import 'core/lock/hardware_key_factor.dart';
import 'core/lock/key_vault.dart';
import 'core/lock/keystore_factor.dart';
import 'core/lock/unlock_factor.dart';
import 'core/lock/vault_store.dart';
import 'core/messenger_core.dart';

class AppState extends ChangeNotifier {
  AppState(this.core, {this.tresor, this.stickZugang});

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
      faktoren = (await tresor?.faecher())?.slots ?? const [];
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

  /// Entsperrt mit dem Schluesselspeicher des Geraets — Fingerabdruck,
  /// Gesicht, PIN oder Muster, je nachdem, was eingerichtet ist.
  ///
  /// Die App fragt nichts davon selbst ab und bekommt es nie zu sehen. Sie
  /// versucht nur, den Fachschluessel zu lesen; die Abfrage zeigt das System.
  Future<bool> entsperreMitGeraet() =>
      _entsperreMit(KeystoreFactor(ablage: GeraeteAblage.mitAnmeldung()));

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
    await t.entsperreMit(faktor);
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

  /// Nimmt den Schluesselspeicher des Geraets als Faktor auf.
  ///
  /// Wirft [LockUnavailableException], wenn das Telefon gar keine
  /// Bildschirmsperre hat — dann gibt es nichts, woran sich etwas binden
  /// liesse.
  Future<void> fuegeGeraetHinzu() async {
    await _fuegeHinzu(KeystoreFactor(ablage: GeraeteAblage.mitAnmeldung()));
  }

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
    try {
      await t.fuegeHinzu(faktor);
    } finally {
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
    await t.entferne(
      slotId,
      faktor: slot?.kind == UnlockFactorKind.biometric
          ? KeystoreFactor(ablage: GeraeteAblage.mitAnmeldung())
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
      _ungelesen = 0;
      unawaited(Benachrichtigungen.instanz.raeumeAuf());
      unawaited(raeumeAbgelaufeneWeg());
      _fehlversuche = 0;
      if (verbindung != ConnectionState.online) unawaited(_versucheVerbindung());
    } else {
      _wiederverbindung?.cancel();
      _wiederverbindung = null;
    }
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
