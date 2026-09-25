// real_messenger_core.dart — der echte Kern hinter dem eingefrorenen Vertrag.
//
// Bisher lief die Oberflaeche gegen FakeMessengerCore. Diese Datei setzt
// dieselbe Schnittstelle mit echter Krypto, echter Datenbank und echtem Relay
// um. Die Oberflaeche merkt vom Wechsel nichts ausser dass es funktioniert.
//
// WAS HIER ZUSAMMENKOMMT
//   secret_store.dart   16 Bytes Entropie -> Seed -> alle Schluessel
//   encrypted_database  verschluesselte Datei mit Sitzungen und Nachrichten
//   signal_store        die vier Speicher, die libsignal verlangt
//   relay_client        Anmeldung, WebSocket, Umschlaege
//   payload.dart        was INNERHALB der Verschluesselung steht
//
// GRUNDREGEL DES VERTRAGS: Netzwerkprobleme werden NICHT geworfen. Sie
// erscheinen als Zustandswechsel auf connectionStateChanges und als
// MessageStatus.failed. Geworfen wird nur bei Bedienfehlern und schlechten
// Eingaben. Wer das umdreht, zwingt jede Stelle der Oberflaeche in einen
// try/catch, den sie nicht sinnvoll behandeln kann.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:meta/meta.dart';

import 'anhang/anhang_empfang.dart';
import 'anhang/anhang_versand.dart';
import 'anhang/lager_client.dart';
import 'anhang/rezept.dart';
import 'crypto/address.dart';
import 'crypto/bip39.dart';
import 'crypto/key_derivation.dart';
import 'crypto/signal_errors.dart';
import 'crypto/signal_identity.dart';
import 'messenger_core.dart';
import 'nah/funk.dart';
import 'nah/leuchtfeuer.dart';
import 'nah/nahbereich.dart';
import 'nah/wegwahl.dart';
import 'net/envelope.dart';
import 'net/netzweg.dart';
import 'net/payload.dart';
import 'net/prekey_bundle_bridge.dart';
import 'net/relay_protocol.dart';
import 'net/relay_client.dart';
import 'secret_store.dart';
import 'store/chat_repository.dart';
import 'store/encrypted_database.dart';
import 'store/signal_store.dart';
import 'store/sicherung.dart';
import 'store/signal_store_repository.dart';
import 'store/sqlite_zugang.dart';
import 'verbindungstest.dart';

class RealMessengerCore implements MessengerCore {
  RealMessengerCore({
    required this.secretStore,
    required this.databasePath,
    required this.relayUri,
    this.relayUriTor,
    Uri? lagerUri,
    RelayClient Function(Uri, SignalIdentity)? relayFactory,
    Nahbereich Function()? nahFactory,
  }) : lagerUri = lagerUri ?? lagerAdresse(relayUri),
       // Der Analyzer schlaegt `this._relayFactory` vor. Das hiesse, der
       // benannte Parameter hiesse `_relayFactory`, und jeder Aufrufer
       // muesste einen Unterstrich schreiben — bei einem Parameter, den
       // ausschliesslich Tests setzen, waere das eine Aenderung an fremden
       // Dateien fuer nichts.
       // ignore: prefer_initializing_formals
       _relayFactory = relayFactory,
       _nahFactory = nahFactory ?? (() => Nahbereich(funk: Nahfunk()));

  final SecretStore secretStore;
  final String databasePath;
  final Uri relayUri;

  /// Derselbe Relay als Onion-Dienst — benutzt, wenn "Tor" an ist. Dann
  /// verlaesst die Verbindung das Tor-Netz gar nicht erst, und es gibt keinen
  /// Ausgangsknoten, der sie sieht. Fuer Anmeldevermerk und Zwischenlager
  /// gilt weiter [relayUri]: es ist derselbe Server unter zweiter Adresse,
  /// kein neuer — sonst meldete sich die App dort neu an und verwarf dabei
  /// alle Einmal-Prekeys (siehe relay_wechsel_test.dart).
  final Uri? relayUriTor;

  Uri get _relayWeg => (_prefs.tor && relayUriTor != null) ? relayUriTor! : relayUri;

  /// Wo die grossen Anhaenge liegen.
  ///
  /// Wird aus [relayUri] abgeleitet, wenn nichts dasteht — aber NIE aus dem,
  /// was der Relay in seiner Antwort mitschickt. Sonst koennte ein
  /// uebernommener Relay die Uploads auf einen fremden Rechner umlenken.
  final Uri lagerUri;

  /// Woher der Relay-Client kommt — null heisst "der echte".
  ///
  /// FRUEHER STAND HIER EIN STANDARDWERT IM INITIALISIERER, und der ging
  /// nicht mehr: der echte Client bekommt seine Geraetekennung beim Bauen
  /// mit, und die steht erst fest, wenn die Datenbank offen ist. Im
  /// Initialisierer gibt es weder `this` noch die Kennung. Deshalb wird der
  /// Standardfall erst in [_neuerRelay] gebaut — eine hereingereichte Fabrik
  /// (die Tests) merkt davon nichts und bekommt weiter genau ihre zwei
  /// Argumente.
  final RelayClient Function(Uri, SignalIdentity)? _relayFactory;

  /// Woher der Nahbereich kommt — hereingereicht wie [_relayFactory].
  ///
  /// ZWEI GRUENDE, und der erste ist der wichtigere: ohne diesen Haken laesst
  /// sich der ganze Anschluss nur mit zwei Telefonen pruefen. Mit ihm reicht
  /// ein Nahbereich ueber einer Funk-Attrappe, und die Wegwahl, der Eingang und
  /// das Zeichen an der Nachricht sind am Schreibtisch zu messen.
  ///
  /// Der zweite: eine Fabrik statt eines fertigen Objekts, damit fuer jemanden,
  /// der Bluetooth nie einschaltet, auch nichts Bluetooth-Foermiges entsteht.
  final Nahbereich Function() _nahFactory;

  /// Wie viele One-Time-Prekeys vorgehalten werden.
  ///
  /// Jeder erlaubt genau einen Sitzungsaufbau mit der zusaetzlichen
  /// Absicherung. Sind sie alle, funktioniert X3DH weiter, nur etwas
  /// schwaecher — deshalb ist ein leerer Vorrat kein Notfall, aber es soll
  /// nicht dauernd vorkommen.
  static const int preKeyVorrat = 100;
  static const int preKeyUntergrenze = 20;

  /// Wie lange die Geraeteliste eines Kontakts ohne Nachfrage gilt.
  ///
  /// GESETZT, NICHT GEMESSEN — Spezifikation §12.2 sagt das ausdruecklich, und
  /// deshalb steht der Wert als Konstante hier und nicht als 6 mitten im Code.
  ///
  /// Zu kurz kostet Anfragen: ein `?nur_geraete=1` je Kontakt und Fenster sind
  /// 4 am Tag, bei 50 Kontakten 200 gegen den IP-Eimer des Relays (120 Stoss,
  /// 2/s Nachschub) — `py -c "print(200/2/60)"` -> 1.67 Minuten Nachschub, also
  /// unkritisch. Zu lang laesst ein neu aufgesetztes Geraet der Gegenstelle
  /// lange stumm: es bekommt nichts, bis es selbst einmal schreibt.
  static const Duration geraeteFenster = Duration(hours: 6);

  /// Wie lange nach einem GESCHEITERTEN Auffrischen gewartet wird.
  ///
  /// Der Ausgleich zwischen zwei Fehlern: ohne Vermerk kostete jede einzelne
  /// Nutzlast zwei /prekey-Abrufe gegen denselben IP-Eimer, mit vollem Vermerk
  /// bliebe ein neu gemeldetes Geraet sechs Stunden unbeliefert.
  static const Duration geraeteWiederholung = Duration(minutes: 5);

  /// Wie viele Geraete einer Adresse der Client hoechstens beliefert.
  ///
  /// DIESELBE ZAHL WIE `GERAETE_MAX` IM RELAY (relay_server.py, Vorgabe 5,
  /// Spezifikation §6) — und sie muss AUCH HIER stehen. Eine Grenze
  /// durchzusetzen ist Sache dessen, der ihr nicht traut: ein feindlicher
  /// Relay liefert auf `/prekey` beliebig viele Geraetezeilen, und der Client
  /// baut zu jeder eine Sitzung und verschluesselt jede Nachricht dagegen.
  ///
  /// Aufsteigend nach `device_id` geschnitten, weil der Relay so ausliefert
  /// (§3.3) und weil Geraet 1 dadurch nie herausfaellt.
  ///
  /// Setzt der Betreiber seinen Relay hoeher, sehen aeltere Clients die
  /// zusaetzlichen Geraete nicht — das ist die richtige Richtung des
  /// Irrtums: zu wenige Kopien sind ein sichtbarer Ausfall, zu viele ein
  /// stiller Ressourcenschaden.
  static const int geraeteMax = 5;

  /// Der Fehlergrund des Relays, wenn ein Zielgeraet nicht (mehr) existiert.
  ///
  /// Als Konstante, weil daran eine Entscheidung haengt (Sitzung wegwerfen)
  /// und ein Tippfehler sie stillschweigend abschaltete.
  static const String zielgeraetUnbekannt = 'Zielgeraet unbekannt';

  EncryptedDatabase? _db;

  /// NUR FUER TESTS: die offene Datenbank.
  ///
  /// Damit ein Test einen Zustand herstellen kann, den es im Betrieb nur bei
  /// einer Installation aus einer aelteren Fassung gibt — etwa einen
  /// fehlenden Anmelde-Vermerk.
  @visibleForTesting
  EncryptedDatabase get datenbankFuerTest => _db!;

  /// Die Ablage, um einen Zustand herzustellen, den der Kern selbst noch
  /// nicht erzeugt — etwa eine Nachricht mit `ueberNaehe`, solange die
  /// Wegwahl noch nicht am Nachrichtenweg haengt.
  @visibleForTesting
  ChatRepository get ablageFuerTest => _chats!;

  SignalStoreRepository? _signalRepo;
  ChatRepository? _chats;
  BitdmSignalStore? _store;
  RelayClient? _relay;
  StreamSubscription<RelayEvent>? _relayAbo;

  Nahbereich? _nah;
  StreamSubscription<NahUmschlag>? _nahAbo;
  StreamSubscription<NahSonderpost>? _nahPostAbo;
  StreamSubscription<String>? _nahDaAbo;

  /// Das X25519-Geheimnis je Kontakt, einmal gerechnet.
  ///
  /// Es haengt an zwei Identitaeten, und die aendern sich nicht. Es bei jedem
  /// Aufsetzen neu zu rechnen hiesse, bei vierzig Kontakten vierzig
  /// Kurvenmultiplikationen zu machen, nur weil jemand einen Kontakt
  /// hinzugefuegt hat.
  final _nahGeheimnisse = <String, Uint8List>{};

  /// Die Warteschlange fuer das Auf- und Abbauen des Nahbereichs.
  ///
  /// Zwei Aenderungen kurz hintereinander — Kontakt hinzufuegen, gleich darauf
  /// Anwesenheit umschalten — wuerden sonst ineinanderlaufen: `starte` haelt
  /// zuerst an und baut dann ueber mehrere Wartepunkte auf, und der zweite
  /// Durchlauf raeumte dem ersten die Abonnements unter den Fuessen weg.
  Future<void> _nahLauf = Future<void>.value();

  /// Die Kontaktliste, mit der der Funk gerade laeuft.
  ///
  /// Der Vergleichspunkt in [_setzeNaheAuf]. Er steht HIER und nicht bei den
  /// Aufrufern, weil sonst jeder von ihnen selbst wissen muesste, ob seine
  /// Aenderung den Nahbereich ueberhaupt angeht — und der Empfangsweg weiss es
  /// nicht: dort steht erst nach dem Schreiben fest, ob ein Kontakt
  /// dazugekommen ist.
  ///
  /// null heisst "der Funk laeuft nicht", nicht "keine Kontakte". Der
  /// Unterschied entscheidet, ob nach dem Aufschliessen wieder angefangen
  /// wird; deshalb geht jedes Anhalten ueber [_haltNahe].
  String? _nahStand;

  /// Der Nachversand laeuft nacheinander, nie zweimal gleichzeitig.
  ///
  /// Tauchen zwei Kontakte im selben Augenblick auf, laesen zwei Laeufe
  /// dieselbe Liste — beide sehen dieselbe Nachricht auf "sending" stehen, und
  /// beide schicken sie. Dieselbe Kette wie bei [_nahLauf]: der zweite Lauf
  /// faengt an, wenn der erste durch ist, und findet dann nur noch, was
  /// wirklich liegengeblieben ist.
  Future<void> _nachversandLauf = Future<void>.value();

  /// Die Kennung DIESES Geraets an dieser Adresse. Null = noch nicht ermittelt.
  ///
  /// Sie haengt am [databasePath] und ist damit je Installation eine eigene —
  /// genau wie `registration_id`. NICHT aus dem Seed abgeleitet: abgeleitet
  /// waeren beide Geraete gleich, und das ist genau der Fehler, den das ganze
  /// Vorhaben behandelt.
  int? _geraetId;

  /// Wie viele Geraete diese Adresse beim Relay hat — null, solange niemand
  /// gefragt hat.
  ///
  /// Fuer den Identitaetsbildschirm. Es gibt KEINEN Widerruf: wer die zwoelf
  /// Woerter hat, bekommt von jedem Absender eine eigene Kopie jeder
  /// Nachricht, und abmelden laesst sich ein Geraet nicht (Spezifikation §6).
  /// Diese Zahl ist die einzige Stelle, an der ein unsichtbarer Mitleser
  /// sichtbar wird — deshalb ist ihre Anzeige verpflichtend und nicht Kuer.
  int? _geraeteZahl;

  int? get geraeteZahl => _geraeteZahl;

  /// Der Relay hat DIESES Geraet endgueltig abgewiesen — die Adresse hat schon
  /// [geraeteMax] Geraete (HTTP 507, Spezifikation §6).
  ///
  /// KEIN NETZFEHLER, UND DESHALB EINE EIGENE ZAHL. Der Relay hat 507 statt
  /// 429 gerade deswegen gewaehlt: "das ist keine Bremse, die nachgibt". Ohne
  /// diese Angabe sieht die App wie ein Funkloch aus — dauerhaft "keine
  /// Verbindung" — und der Wiederverbindungszeitgeber laeuft bis in alle
  /// Ewigkeit gegen eine Antwort, die sich nie aendert.
  bool _abgewiesen = false;

  bool get abgewiesen => _abgewiesen;

  var _conn = ConnectionState.disconnected;

  AppPreferences _prefs = const AppPreferences();
  var _hatIdentitaet = false;

  final _connCtl = StreamController<ConnectionState>.broadcast();
  final _incoming = StreamController<Message>.broadcast();
  final _status = StreamController<MessageStatusUpdate>.broadcast();
  final _contacts = StreamController<ContactEvent>.broadcast();
  final _anhangStand = StreamController<AnhangFortschritt>.broadcast();
  final _anhangWechsel = StreamController<AnhangEintrag>.broadcast();
  final _verlaufWechsel = StreamController<String>.broadcast();
  final _tippen = StreamController<TippMeldung>.broadcast();
  final _gruppenWechsel = StreamController<String>.broadcast();
  final _zufall = Random.secure();

  /// Wie lange eine Quittung wartet, bevor sie hinausgeht.
  ///
  /// ZUFAELLIG VERZOEGERT. Eine Zustellquittung, die im selben Augenblick
  /// zurueckgeht, in dem die Nachricht ankam, verbindet fuer den Relay
  /// Absender und Empfaenger ueber die Zeit — selbst dann, wenn er den
  /// Absender gar nicht kennt (Martiny u. a., "Improving Signal's Sealed
  /// Sender", NDSS 2021: genau so liessen sich Gespraechspartner zuordnen).
  /// 0,3 bis 2,5 Sekunden verwischen das, ohne dass ein Mensch auf seinen
  /// Haken wartet. Fuer Tests austauschbar.
  late Duration Function() quittungsVerzug =
      () => Duration(milliseconds: 300 + _zufall.nextInt(2200));

  LagerClient? _lagerClient;

  // ══════════════════════════════════════════════════════════════ Identitaet

  @override
  bool get isInitialized => _store != null;

  @override
  bool get hasIdentity => _hatIdentitaet;

  @override
  String get myId {
    final s = _store;
    if (s == null) throw const NotInitializedException();
    return s.identity.address;
  }

  @override
  Future<bool> initialize() async {
    if (_store != null) return true;
    final entropie = await secretStore.read();
    _hatIdentitaet = entropie != null;
    if (entropie == null) return false;
    await _oeffne(entropie);
    return true;
  }

  @override
  Future<List<String>> createIdentity() async {
    if (_store != null || await secretStore.read() != null) {
      throw StateError('es gibt bereits eine Identitaet');
    }
    final woerter = Bip39.generate();
    final entropie = Bip39.mnemonicToEntropy(woerter);
    await secretStore.write(entropie);
    _hatIdentitaet = true;
    await _oeffne(entropie);
    return woerter;
  }

  @override
  Future<String> restoreIdentity(List<String> words) async {
    if (_store != null || await secretStore.read() != null) {
      throw StateError('es gibt bereits eine Identitaet');
    }
    if (!Bip39.validate(words)) throw const InvalidRecoveryPhraseException();
    final entropie = Bip39.mnemonicToEntropy(words);
    await secretStore.write(entropie);
    _hatIdentitaet = true;
    await _oeffne(entropie);
    return myId;
  }

  @override
  bool isValidRecoveryPhrase(List<String> words) => Bip39.validate(words);

  @override
  Future<List<String>> getRecoveryPhrase() async {
    final entropie = await secretStore.read();
    if (entropie == null) throw const NotInitializedException();
    return Bip39.entropyToMnemonic(entropie);
  }

  @override
  bool isValidAddress(String address) => BitdmAddress.isValid(address);

  /// Datenbank oeffnen, Speicher aufbauen, Prekeys sicherstellen.
  Future<void> _oeffne(Uint8List entropie) async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.entropyToMnemonic(entropie));
    // Im Browser laedt das das WASM-Modul; auf der VM ist der Rumpf leer
    // (sqlite_zugang_native.dart:21), Android sieht davon also nichts. Es muss
    // hier stehen und nicht in EncryptedDatabase.open, weil open() synchron ist.
    await sqliteVorbereiten();
    final db = EncryptedDatabase.open(databasePath, keys.databaseKey);
    final signalRepo = SignalStoreRepository(db);
    final store = signalRepo.openStore(keys);

    _db = db;
    _signalRepo = signalRepo;
    _store = store;
    _chats = ChatRepository(db, signalRepo);

    // DIE GERAETEKENNUNG, SOWEIT SIE SCHON FESTSTEHT.
    //
    // Bei einer BESTEHENDEN Installation steht sie noch nicht in `meta`, wohl
    // aber `relay_angemeldet_bei` — und dann ist sie 1, ohne den Relay zu
    // fragen (Spezifikation §1/§8). Das ist die Bedingung dafuer, dass beim
    // Update keine einzige Unterhaltung verlorengeht: alle bestehenden
    // Sitzungen sind mit "adresse:1" geschluesselt, alle Gegenstellen bleiben
    // Geraet 1, es aendert sich an keiner Sitzung etwas.
    //
    // Bei einer FRISCHEN Installation bleibt sie null und wird beim ersten
    // Verbinden ermittelt ([_ermittleGeraetId]) — dort und nicht hier, weil
    // dafuer der Relay gefragt werden muss.
    final gemerkt = int.tryParse(db.meta('device_id') ?? '');
    if (gemerkt != null) {
      _geraetId = gemerkt;
    } else if (db.meta('relay_angemeldet_bei') != null) {
      _setzeGeraetId(1);
    }

    _prefs = _chats!.ladeEinstellungen();
    _setzeNetzweg();
    _planeGeplante();
    // Was waehrend der App-Pause abgelaufen ist, verschwindet beim Start —
    // nicht erst, wenn jemand die Unterhaltung oeffnet und es noch sieht.
    _chats!.loescheAbgelaufene();

    _fuelleVorratAuf();

    // STAND DER SCHALTER SCHON AUF AN, faengt der Funk hier an — nicht erst,
    // wenn jemand die Einstellungen oeffnet und ihn noch einmal umlegt. Eine
    // Ausfallsicherung, die man nach jedem Start von Hand scharf machen muss,
    // ist keine.
    await _richteNaheEin();
  }

  /// Legt fehlende Prekeys an. Tut nichts, wenn genug da sind.
  bool _fuelleVorratAuf() {
    final store = _store!;
    var veraendert = false;

    if (store.state.signedPreKeys.isEmpty) {
      final spk = generateSignedPreKey(store.identity.keyPair, 1);
      store.storeSignedPreKey(spk.id, spk);
      veraendert = true;
    }

    if (store.preKeyCount < preKeyUntergrenze) {
      // Bei den Nummern dort weitermachen, wo sie aufgehoert haben. Wuerde
      // wieder bei 1 begonnen, kaeme eine Nummer doppelt vor — und eine
      // Gegenstelle mit einem alten Bundle bekaeme einen Schluessel, der
      // inzwischen einem anderen gehoert.
      final hoechste = store.state.preKeys.keys.fold<int>(0, max);
      for (final pk in generatePreKeys(hoechste + 1, preKeyVorrat)) {
        store.storePreKey(pk.id, pk);
      }
      veraendert = true;
    }

    if (veraendert) _signalRepo!.commit(store);
    return veraendert;
  }

  // ══════════════════════════════════════════════════════════════ Verbindung

  @override
  ConnectionState get connectionState => _conn;

  @override
  Stream<ConnectionState> get connectionStateChanges => _connCtl.stream;

  void _setzeVerbindung(ConnectionState s) {
    if (_conn == s) return;
    _conn = s;
    if (!_connCtl.isClosed) _connCtl.add(s);
  }

  @override
  Future<void> connect() async {
    final store = _store;
    if (store == null) throw const NotInitializedException();

    // NUR IN DER NAEHE: hier ist Schluss, und zwar VOR dem ersten Byte.
    //
    // Nicht "verbinden und dann nichts senden" — dann staende die Adresse
    // schon in der Verbindungsliste des Relays, und beim Anmelden waere eine
    // Signatur ueber die Leitung gegangen. Der Schalter verspricht, dass
    // NICHTS an einen Server geht; das laesst sich nur einhalten, indem man
    // gar nicht erst anfaengt.
    //
    // Die Verbindung bleibt auf "getrennt" und nicht auf "Fehler": es ist
    // kein Fehler, sondern eine Entscheidung des Nutzers.
    if (_prefs.nurNahbereich) {
      await _raeumeVerbindungAb();
      _setzeVerbindung(ConnectionState.disconnected);
      return;
    }

    if (_conn == ConnectionState.online ||
        _conn == ConnectionState.connecting) {
      return;
    }

    _setzeVerbindung(ConnectionState.connecting);
    // JEDER AUSDRUECKLICHE VERSUCH BEKOMMT EIN FRISCHES URTEIL. Wer die App in
    // den Vordergrund holt, nachdem er ein anderes Geraet aufgegeben hat, soll
    // nicht an einem alten 507 haengenbleiben.
    _abgewiesen = false;
    final relay = _neuerRelay(store.identity);
    _relay = relay;

    // DER LAUFZETTEL, und warum es ihn braucht.
    //
    // Zwischen hier und dem Ende dieser Methode liegen drei Wartepunkte: die
    // Anmeldung, das Oeffnen der WebSocket, das Nonce. Waehrend die App dort
    // wartet, kann alles Moegliche passieren — der Nutzer legt "nur in der
    // Naehe" um, disconnect() laeuft durch, _relay wird null und der Zustand
    // steht auf "getrennt".
    //
    // Der Ablauf hier weiss davon nichts. Er kommt aus dem Wartepunkt zurueck
    // und macht weiter: oeffnet die Verbindung, signiert das Nonce, setzt den
    // Zustand auf "online". Genau das, was der Schalter ausschliesst — die
    // Pruefung darauf liegt oben und ist laengst vorbei. Zurueck bleibt eine
    // angemeldete Verbindung, die niemand mehr kennt und die niemand mehr
    // schliessen kann.
    //
    // Deshalb nach JEDEM Wartepunkt: bin ich noch der, der verbinden soll?
    // Ein einziger Vergleich reicht: JEDES Abraeumen und jeder neue Versuch
    // setzt _relay um — auf null oder auf ein anderes Objekt. Ein zweiter
    // Zaehler stand hier zuerst daneben; ein Mutationstest zeigte, dass ihn
    // wegzunehmen keinen einzigen Test rot macht. Was nichts kann, kommt weg.
    //
    // `identical` und nicht `==`: es geht um dieses eine Objekt.
    bool ueberholt() => !identical(_relay, relay);

    try {
      // ERST DIE EIGENE KENNUNG, DANN ALLES ANDERE. Sie geht in den
      // Besitznachweis der Anmeldung ein und in die Signatur der WebSocket —
      // beides passiert gleich, und beides waere mit der falschen Kennung
      // nicht bloss falsch, sondern abgewiesen.
      await _ermittleGeraetId(relay);
      if (ueberholt()) return _gibAuf(relay);
      if (geraetId != 1) relay.geraeteKennung = geraetId;

      await _meldeAnWennNoetig(relay);
      if (ueberholt()) return _gibAuf(relay);

      _relayAbo = relay.events.listen(_verarbeiteRelayEreignis);
      await relay.connect();
      if (ueberholt()) return _gibAuf(relay);

      _setzeVerbindung(ConnectionState.online);
      _planeGeraeusch();
      // DIE EIGENEN GERAETE NACH JEDEM VERBINDEN, nicht nach dem
      // Sechs-Stunden-Fenster wie bei Kontakten (Spezifikation §4). Das ist
      // Henriks Kernszenario: das zweite Telefon soll sehen, was das erste
      // schreibt — und zwar ab dem naechsten App-Start und nicht erst in
      // sechs Stunden. Der Aufruf kostet keinen Einmalschluessel.
      //
      // UND DER NACHVERSAND ERST DANACH. `_stosseNachversandAn` haengt sich an
      // ein bereits erfuelltes Future, sein `.then` ist also eine Mikrotask und
      // laeuft VOR jedem Netzereignis — vor dem ersten HTTPS-Umlauf hier
      // drueber. Was aus der Funkstille auf `sending` liegt, ginge dann hinaus,
      // waehrend `_bekannteGeraete(store, myId)` noch leer ist: kein Spiegel,
      // und weil die Nachricht danach auf `sent` steht, holt ihn auch nie
      // jemand nach. Genau die Nachrichten, die beim Koppeln warteten, fehlten
      // auf dem Zweitgeraet dauerhaft.
      unawaited(_frischeEigeneGeraeteAuf().whenComplete(_stosseNachversandAn));
      _wiederholeKontaktanfragen();
    } catch (fehler) {
      // Vertragsregel: Netzwerkprobleme werden nicht geworfen.
      //
      // Aber nur den EIGENEN Versuch abraeumen: wer inzwischen ueberholt
      // wurde, wuerde sonst den Zustand eines fremden, laufenden Versuchs auf
      // "Fehler" setzen.
      if (ueberholt()) return _gibAuf(relay);
      // VOR dem Zustandswechsel: an ihm haengt der Wiederverbindungszeitgeber
      // (app_state `_planeWiederverbindung`), und der liest [abgewiesen].
      _abgewiesen = fehler is RelayException && fehler.statusCode == 507;
      await _raeumeVerbindungAb();
      _setzeVerbindung(ConnectionState.error);
    }
  }

  /// Der Relay-Client fuer diese Verbindung.
  ///
  /// Die hereingereichte Fabrik hat Vorrang und bekommt genau ihre zwei
  /// Argumente; nur der echte Client bekommt die Geraetekennung mit — und
  /// auch nur, wenn es nicht die 1 ist (siehe RelayClient `geraeteKennung`).
  RelayClient _neuerRelay(SignalIdentity identitaet) =>
      _relayFactory?.call(_relayWeg, identitaet) ??
      RelayClient(
        baseUri: _relayWeg,
        identity: identitaet,
        geraeteKennung: geraetId == 1 ? null : geraetId,
      );

  /// Ein ueberholter Verbindungsversuch raeumt SICH auf und sonst nichts.
  ///
  /// Ohne den Verweis auf genau dieses Objekt wuerde er die inzwischen
  /// aufgebaute Verbindung eines spaeteren Versuchs mit wegwerfen. Und ohne
  /// jede Zustandsaenderung, weil der Zustand nicht mehr ihm gehoert.
  ///
  /// EHRLICH DAZU: das `dispose` hier ist heute ein zweites Netz und deckt
  /// keinen erreichbaren Fall ab. Jeder Weg, der einen Versuch ueberholt,
  /// laeuft ueber _raeumeVerbindungAb, und das entsorgt den alten Relay schon.
  /// Ein Mutationstest zeigt das: nimmt man diese Zeile weg, wird kein Test
  /// rot. Sie bleibt trotzdem — wer spaeter einen Weg baut, der _relay
  /// umsetzt, OHNE abzuraeumen, laesst sonst eine angemeldete Verbindung
  /// stehen, und das faellt erst im Betrieb auf. Ein Netz, das man begruenden
  /// kann, ist kein toter Code.
  Future<void> _gibAuf(RelayClient relay) async {
    try {
      await relay.dispose();
    } catch (_) {
      // Ein Versuch, den ohnehin niemand mehr braucht.
    }
  }

  Future<void> _meldeAnWennNoetig(RelayClient relay) async {
    final store = _store!;
    final db = _db!;
    // Neu anmelden, wenn wir es noch nie getan haben oder der Vorrat beim
    // Server nicht mehr zu unserem passt. Die Anmeldung ersetzt beim Relay
    // ALLE One-Time-Prekeys durch die uebergebenen — sie ist damit zugleich
    // das Nachfuellen.
    final gemeldet = db.meta('relay_prekey_count');

    // WO wir angemeldet sind, nicht nur DASS.
    //
    // Ohne die zweite Zeile galt der Vermerk fuer JEDEN Server. Am 26.07.2026
    // im Emulator beobachtet: nach einem Wechsel der Relay-Adresse hielt sich
    // die App fuer angemeldet, kam beim neuen Server als Unbekannte an, und
    // der schloss die Verbindung sofort wieder — ohne Fehler, ohne Meldung,
    // ohne dass irgendetwas darauf hinwies.
    //
    // FEHLT DER EINTRAG, ist es dieser Relay. Das ist keine Vermutung: bis
    // dahin kannte die App nur einen einzigen. Andernfalls meldete sich mit
    // dem naechsten Update jede bestehende Installation noch einmal an — und
    // jede Gegenstelle mit einem schon geholten Buendel liefe ins Leere.
    final wo = db.meta('relay_angemeldet_bei');
    if (gemeldet != null &&
        int.tryParse(gemeldet) == store.preKeyCount &&
        (wo == null || wo == relayUri.toString())) {
      return;
    }
    await _meldeAn(relay);
  }

  /// Welches Geraet dieser Adresse wir sind. Ohne Ermittlung: 1.
  ///
  /// Der Rueckfall auf 1 ist kein Notbehelf, sondern die Regel aus §3 der
  /// Spezifikation: eine fehlende Kennung IST Geraet 1. Wer nie verbindet
  /// ("nur in der Naehe"), fragt den Relay nie und ist damit dauerhaft
  /// Geraet 1 — richtig so, denn ohne Relay gibt es auch kein zweites.
  int get geraetId => _geraetId ?? 1;

  void _setzeGeraetId(int n) {
    _geraetId = n;
    // WER KEINE 1 IST, FUNKT NICHT MEHR. Der Funk kann schon laufen — er wird
    // in `_oeffne` scharf gemacht, lange bevor der Relay nach der Kennung
    // gefragt ist. Siehe [_darfFunken].
    if (n != 1) unawaited(_richteNaheEin());
    _db!.transaction(
      (raw) => raw.execute(
        'INSERT INTO meta (key, value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['device_id', '$n'],
      ),
    );
  }

  /// Ermittelt die eigene Geraetekennung — genau einmal je Installation.
  ///
  /// ═══════════ WARUM DAS ERSTE GERAET IMMER 1 IST UND NICHT AUCH ZUFALL
  ///
  /// Ein Client, der die Erweiterung nicht kennt, schickt kein Zielgeraet; der
  /// Relay setzt dann 1 ein. Waere die einzige Kennung einer frischen
  /// Installation eine Zufallszahl, koennten alte Clients diese Adresse NIE
  /// erreichen ("Zielgeraet unbekannt"). Mit dieser Regel ist das erste Geraet
  /// jeder Adresse immer 1, und die Rueckwaertsverträglichkeit haelt dauerhaft
  /// und nicht nur bis zur ersten Neuinstallation.
  ///
  /// Kennt der Relay die Frage nicht (null), wird es ebenfalls 1: dann gibt es
  /// dort ohnehin nur eine Zeile je Adresse.
  ///
  /// ═══════════ EIN TRANSPORTFEHLER IST KEINE ANTWORT UND WIRD NICHT GEBRANNT
  ///
  /// [_setzeGeraetId] schreibt in `meta`, und `:582` fragt danach nie wieder.
  /// Wer aus einer Zeitueberschreitung, einem 429 oder einem 502 die 1 macht,
  /// hat sie FUER IMMER gemacht — auf einem Zweitgeraet heissen dann beide
  /// Geraete 1, sie ueberschreiben sich beim Relay die Zeile, loeschen sich
  /// die Einmalschluessel und rasten bei jeder Gegenstelle dieselbe Sitzung
  /// weiter. Genau der stille, dauerhafte Verlust aus §10.
  ///
  /// Spezifikation §1 laesst die 1 nur bei LEERER Liste oder 404 zu. Alles
  /// andere fliegt weiter: `connect()` faengt es, endet in
  /// ConnectionState.error, und beim naechsten Versuch wird erneut gefragt.
  /// Vertagen ist heilbar, Brennen nicht.
  Future<void> _ermittleGeraetId(RelayClient relay) async {
    if (_geraetId != null) return;
    List<int>? liste;
    try {
      liste = await relay.geraeteliste(myId);
    } on RelayException catch (e) {
      // 404 heisst "diese Adresse hat noch kein Geraet" — der Normalfall bei
      // einer Erstanlage. Nur das gilt als Antwort.
      if (e.statusCode != 404) rethrow;
      liste = null;
    }
    _merkeGeraeteZahl(liste);
    _setzeGeraetId(liste == null || liste.isEmpty ? 1 : _neueGeraetId());
  }

  /// Eine Zufallskennung aus 2 .. 2^31−1.
  ///
  /// `Random.secure()` und nicht der gewoehnliche Zufall: die Kennung landet
  /// oeffentlich beim Relay, und eine vorhersagbare liesse einen Fremden
  /// gezielt die Zeile eines Geraets belegen, das sich gerade erst anmeldet.
  ///
  /// Kollisionen sind nur INNERHALB einer Adresse moeglich. Bei fuenf Geraeten
  /// sind vier Kennungen zufaellig, Geburtstagsschranke
  /// `py -c "d=5;print((d-1)*(d-2)/2/2**31)"` -> 2.79e-09, also eins in rund
  /// 358 Millionen.
  int _neueGeraetId() => 2 + _zufall.nextInt(0x7FFFFFFF - 1);

  void _merkeGeraeteZahl(List<int>? liste) {
    if (liste != null) _geraeteZahl = liste.length;
  }

  Future<void> _meldeAn(RelayClient relay) async {
    final store = _store!;
    final spk = await store.loadSignedPreKey(store.state.signedPreKeys.keys.first);
    final otk = <PreKeyRecord>[];
    for (final id in store.state.preKeys.keys) {
      otk.add(await store.loadPreKey(id));
    }
    await relay.register(
      PreKeyBundleBridge.toRelay(
        identity: store.identity,
        signedPreKey: spk,
        oneTimePreKeys: otk,
        // GERAET 1 SCHICKT NICHTS MIT. Damit sind die signierten Bytes Zeichen
        // fuer Zeichen die von vor der Umstellung — siehe RelayClient
        // `geraeteKennung`.
        deviceId: geraetId == 1 ? null : geraetId,
      ),
    );
    _db!.transaction((raw) {
      void setze(String k, String v) => raw.execute(
          'INSERT INTO meta (key, value) VALUES (?,?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [k, v]);
      setze('relay_prekey_count', '${store.preKeyCount}');
      setze('relay_angemeldet_bei', relayUri.toString());
    });
  }

  /// Wartet, bis der Relay steht — hoechstens [dauer].
  ///
  /// Baut die Verbindung selbst auf, wenn keine da ist. Wirft erst, wenn es
  /// wirklich nicht geht; dann ist es ein echter Netzfehler und kein
  /// Wettlauf.
  Future<RelayClient> _wartAufVerbindung(
      {Duration dauer = const Duration(seconds: 15)}) async {
    final r = _relay;
    if (r != null && r.isConnected) return r;

    // NICHT NUR WARTEN, SONDERN AUCH ANSTOSSEN: wer aus der Dateiauswahl
    // zurueckkommt, hat vielleicht schon einen Wiederaufbau laufen — dann
    // kehrt connect() sofort zurueck, weil es den Zustand kennt.
    unawaited(connect());

    final ende = DateTime.now().add(dauer);
    while (DateTime.now().isBefore(ende)) {
      final jetzt = _relay;
      if (jetzt != null && jetzt.isConnected) return jetzt;
      if (_conn == ConnectionState.error) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const RelayException('nicht verbunden');
  }

  /// Was der Verbindungstest braucht, um die Kette nachzugehen.
  ///
  /// Der Kern gibt seine Innereien NICHT heraus — er reicht eine kleine
  /// Ansicht darauf. So kann der Test denselben Relay und dasselbe Lager
  /// benutzen wie der Betrieb, ohne dass irgendwo eine zweite Wahrheit
  /// darueber entsteht, welcher Server gerade gilt.
  TestUmgebung get testUmgebung => _KernUmgebung(this);

  /// NUR FUER WERKZEUGE: der offene Relay.
  ///
  /// Damit tool/dicke_datei.dart den Anhang-Versand mit denselben Teilen
  /// fahren kann wie der Betrieb, statt sie nachzubauen und dabei
  /// moeglicherweise am Fehler vorbei.
  @visibleForTesting
  RelayClient get relayFuerTest {
    final r = _relay;
    if (r == null) throw const RelayException('nicht verbunden');
    return r;
  }

  /// NUR FUER WERKZEUGE: eine Marke ueber die offene Verbindung holen.
  ///
  /// Damit tool/lager_durchstich.dart genau den Weg gehen kann, den die App
  /// geht — ohne den ganzen Anhang-Versand nachzubauen und dabei
  /// moeglicherweise am Fehler vorbei.
  @visibleForTesting
  Future<BlobMarke> markeFuerTest(String kennung, int groesse) {
    final r = _relay;
    if (r == null) throw const RelayException('nicht verbunden');
    return r.holeMarke(kennung, groesse);
  }

  @override
  Future<void> disconnect() async {
    _geraeuschTakt?.cancel();
    await _raeumeVerbindungAb();
    _setzeVerbindung(ConnectionState.disconnected);
  }

  Future<void> _raeumeVerbindungAb() async {
    await _relayAbo?.cancel();
    _relayAbo = null;
    final r = _relay;
    _relay = null;
    await r?.dispose();
  }

  void _verarbeiteRelayEreignis(RelayEvent e) {
    switch (e) {
      case RelayMessage():
        unawaited(_verarbeiteEingang(e));
      case RelayPreKeysLow():
        unawaited(_fuelleNachUndMelde());
      case RelayDisconnected():
        _setzeVerbindung(ConnectionState.disconnected);
      case RelayProtocolError():
        // Nicht toedlich. Die Verbindung steht weiter.
        break;
    }
  }

  Future<void> _fuelleNachUndMelde() async {
    final relay = _relay;
    if (relay == null) return;
    _fuelleVorratAuf();
    try {
      await _meldeAn(relay);
    } catch (_) {
      // Beim naechsten Verbinden erneut. Kein Grund, die Sitzung abzubrechen.
    }
  }

  // ═══════════════════════════════════════════════════════════════ Nahbereich

  /// Baut den Nahbereich neu auf — oder haelt ihn an.
  ///
  /// Aufzurufen, wann immer sich etwas aendert, wovon er abhaengt: der
  /// Schalter, die Kontaktliste, die Anwesenheit eines Kontakts. Er wird dabei
  /// wirklich neu aufgesetzt und nicht nachgebessert; das kostet, wer gerade
  /// in Reichweite ist, und das ist der Preis dafuer, dass es genau EINEN Weg
  /// gibt, auf dem dieser Zustand entsteht.
  ///
  /// Weil das Aufsetzen teuer ist, darf der Aufruf billig sein: [_setzeNaheAuf]
  /// sieht nach, ob sich an der Kontaktliste ueberhaupt etwas geaendert hat.
  /// Erst dadurch laesst sich diese Zeile auch dorthin stellen, wo man nicht
  /// vorher weiss, ob sie noetig ist — auf den Empfangsweg.
  Future<void> _richteNaheEin() =>
      _nahLauf = _nahLauf.then((_) => _setzeNaheAuf());

  /// Haelt den Funk an und vergisst, wofuer er lief.
  ///
  /// Beides gehoert zusammen: bliebe der Stand stehen, hielte der Kern nach
  /// einem Aufschliessen die Kontaktliste fuer schon eingerichtet und liesse
  /// den Funk aus.
  Future<void> _haltNahe() async {
    _nahStand = null;
    await _nah?.halt();
  }

  /// Ob dieses Geraet ueberhaupt funken darf.
  ///
  /// NUR GERAET 1, UND ZWAR AUF BEIDEN SEITEN DES FUNKS. Der Umschlag des
  /// Nahbereichs fuehrt heute nur [Fassung][Art][Chiffretext] (envelope.dart)
  /// — es gibt kein Feld fuer das Absendergeraet. Deshalb schreibt
  /// [_verarbeiteNaheEingang] jedem Funkeingang fest "Geraet 1" auf, und
  /// [_schickeBuendelUeberFunk] antwortet mit einer Karte ohne `device_id`,
  /// die die Gegenseite ebenfalls als Geraet 1 ablegt.
  ///
  /// Funkte ein Zweitgeraet mit, landete SEIN Schluesselmaterial bei der
  /// Gegenstelle unter "adresse:1" — und weil [_bauSitzungen] eine bestehende
  /// Sitzung nie ersetzt, blieb es dort fuer immer. Alles, was die Gegenstelle
  /// danach an Geraet 1 schickt, ist fuer Geraet 1 unlesbar; der Ratchet wird
  /// beim Fehlschlag trotzdem festgeschrieben. Stiller, dauerhafter Verlust,
  /// derselbe wie in §10.
  ///
  /// Fuer jeden Nutzer mit EINEM Geraet aendert das nichts: dessen Kennung ist
  /// 1 (§1), und wer nie verbindet ("nur in der Naehe") bleibt es dauerhaft.
  /// ponytail: Funk nur fuer Geraet 1. Geraetefaehig zu werden heisst, den
  /// Umschlag um ein Absenderfeld zu erweitern — Protokollaenderung.
  bool get _darfFunken => geraetId == 1;

  Future<void> _setzeNaheAuf() async {
    final store = _store;
    if (store == null || !_prefs.naheAn || !_darfFunken) {
      // Auch beim Sperren und beim Loeschen: ohne Schluessel kaeme keine
      // eingehende Nachricht mehr durch, und weiterzufunken hiesse, die eigene
      // Anwesenheit fuer nichts in die Gegend zu rufen.
      await _haltNahe();
      return;
    }

    final kontakte = _nahKontakte();
    // NUR WAS WIRKLICH EINGEHT, nicht "irgendetwas an einem Kontakt ist
    // anders": der Nahbereich sieht die Adressen und die daraus abgeleiteten
    // Geheimnisse. Ein geaenderter Anzeigename oder ein gesetztes Haekchen
    // "geprueft" aendern am Funk nichts — darauf neu aufzusetzen kostete
    // jeden, der gerade in Reichweite ist.
    //
    // SORTIERT, UND NICHT IN DER REIHENFOLGE DER ABLAGE: `alleKontakte` ordnet
    // nach dem Zeitpunkt des Hinzufuegens, und zwei Kontakte aus derselben
    // Millisekunde koennen zwischen zwei Abfragen die Plaetze tauschen. Das
    // waere ein Neuaufbau ohne jede Aenderung — verglichen wird, WER dabei
    // ist, nicht in welcher Reihenfolge.
    final stand = (kontakte.map((k) => k.adresse).toList()..sort()).join('\n');
    if (_nahStand == stand) return;

    final nah = _nah ??= _nahFactory();
    // EINMAL abonnieren und nicht bei jedem Aufsetzen: der Strom des
    // Nahbereichs ueberlebt sein `halt`, ein zweites Abonnement machte aus
    // jeder ankommenden Nachricht zwei.
    _nahAbo ??= nah.eingang.listen((u) => unawaited(_verarbeiteNaheEingang(u)));
    // DAS SCHLUESSELBUENDEL UEBER FUNK.
    //
    // Ohne das hier bleibt die ERSTE Nachricht an einen neuen Kontakt mit
    // "nur in der Naehe" fuer immer liegen: eine Sitzung braucht das Buendel
    // der Gegenseite, und das holte die App bisher ausschliesslich vom Relay.
    // Ein Messenger, der ohne Internet arbeiten soll, kam damit ohne Internet
    // nie ins Gespraech.
    _nahPostAbo ??=
        nah.sonderpost.listen((p) => unawaited(_verarbeiteSonderpost(p)));
    // DAS GEGENSTUECK ZU connect(): dort stoesst die stehende Verbindung den
    // Nachversand an, hier tut es ein Kontakt, der wieder in Reichweite kommt.
    // Ohne diese Zeile gibt es mit "nur in der Naehe" ueberhaupt keinen
    // Nachversand — es gibt dort ja kein Verbinden.
    _nahDaAbo ??= nah.neuInReichweite.listen((_) => _stosseNachversandAn());

    try {
      await nah.starte(
        kontakte: kontakte,
        eigenerOeffentlicher: store.identity.rawPublicKey,
      );

      // NACH DEM WARTEPUNKT NOCH EINMAL PRUEFEN — sonst funkt ein gesperrtes
      // Telefon weiter.
      //
      // `starte` dauert: Leuchtfeuer rechnen, werben, suchen, Postfach
      // oeffnen. Waehrenddessen kann der Nutzer sperren. `lock()` ruft
      // `_haltNahe()` DIREKT und nicht ueber `_nahLauf` — es soll ja gerade
      // nicht hinter einem laufenden Aufbau warten. Beides zusammen heisst:
      // das Anhalten passiert MITTEN im Aufbauen, und der Aufbau schaltet
      // danach alles wieder ein.
      //
      // Gemessen am 27.07.2026 von einem Widerlegungsagenten: nach `lock()`
      // stand `suchtGerade` weiter auf true. Ein gesperrtes Geraet, das seine
      // Anwesenheit weiter in die Gegend ruft — genau das, was der Naheteil
      // sonst ueberall vermeidet.
      //
      // Kein Laufzettel noetig: die Bedingung, die hier gilt, ist dieselbe
      // wie oben. Wer sie danach nicht mehr erfuellt, hat umgelegt.
      if (_store == null || !_prefs.naheAn) {
        await _haltNahe();
        return;
      }
      // NUR EIN NICHTLEERER STAND GILT ALS EINGERICHTET.
      //
      // Bei leerer Kontaktliste kehrt `nah.starte` um, ohne etwas zu senden.
      // Wer das trotzdem vermerkte, sperrte sich selbst aus: der Vergleich
      // `_nahStand == stand` oben griffe beim naechsten Anlass nicht mehr,
      // und der Funk bliebe fuer immer aus — genau der Zustand, in dem ein
      // Telefon am 27.07. stundenlang stumm war, obwohl der Schalter an war.
      _nahStand = stand.isEmpty ? null : stand;
    } catch (_) {
      // Dieselbe Vertragsregel wie beim Relay: kein Bluetooth ist ein Zustand,
      // keine Ausnahme. Die Naehe ist die Ausfallsicherung — faellt sie aus,
      // bleibt der Hauptweg, und die App laeuft weiter.
      //
      // UND KEIN STAND: ein misslungener Aufbau darf nicht als eingerichtet
      // gelten, sonst versuchte es der naechste Anlass gar nicht mehr.
      _nahStand = null;
    }
  }

  /// Wie viele Kontakte zuletzt am Funk teilgenommen haben.
  ///
  /// Aus `_nahStand` gelesen und nicht neu gezaehlt: gefragt ist, womit der
  /// Funk WIRKLICH laeuft, nicht was die Datenbank gerade hergibt. Weichen
  /// die beiden voneinander ab, ist genau das der Fehler, den der
  /// Verbindungstest zeigen soll.
  int get _nahKontakteZahl {
    final st = _nahStand;
    if (st == null || st.isEmpty) return 0;
    return st.split('\n').length;
  }

  /// Die Kontakte, die am Nahbereich teilnehmen.
  ///
  /// WER `zeigtAnwesenheit` AUSGESCHALTET HAT, IST GAR NICHT DABEI — weder
  /// wird fuer ihn ein Leuchtfeuer ausgesendet noch eines von ihm erwartet.
  /// Nur das eine von beiden hiesse: ihn nicht mehr finden, ihm aber weiter
  /// zeigen, wo man ist.
  List<NahKontakt> _nahKontakte() => [
        for (final k in _chats!.alleKontakte())
          // Die Notizen sind kein Gegenueber, nach dem man suchen koennte.
          if (k.zeigtAnwesenheit && k.id != myId)
            NahKontakt(
              adresse: k.id,
              identitaet: BitdmAddress.decode(k.id),
              geheimnis: _nahGeheimnis(k.id),
            ),
      ];

  /// Das gemeinsame Geheimnis mit einem Kontakt, aus seiner ADRESSE.
  ///
  /// Kein Server dafuer: die Adresse IST der oeffentliche Identitaetsschluessel
  /// (siehe address.dart), und X25519 braucht sonst nur den eigenen privaten.
  /// Ein Nahbereich, der erst beim Relay nachfragen muesste, waere kein
  /// Nahbereich.
  ///
  /// Gerechnet wird ueber libsignal und nicht ueber das cryptography-Paket, weil
  /// der eigene private Schluessel in libsignals Form vorliegt. Dass beide Wege
  /// dieselben 32 Byte liefern, ist gemessen — test/nah/schluesselbruecke_test.
  Uint8List _nahGeheimnis(String adresse) =>
      _nahGeheimnisse.putIfAbsent(adresse, () {
        // DAS TYPBYTE IST PFLICHT. `BitdmAddress.decode` liefert 32 nackte
        // Bytes, `Curve.decodePoint` verlangt 33 mit vorangestelltem DJB_TYPE.
        // Ohne es die bekannte 33-gegen-32-Falle aus signal_identity.dart.
        final mitTyp = Uint8List(33)
          ..[0] = 5
          ..setRange(1, 33, BitdmAddress.decode(adresse));
        return Uint8List.fromList(Curve.calculateAgreement(
            Curve.decodePoint(mitTyp, 0),
            _store!.identity.keyPair.getPrivateKey()));
      });

  /// NUR FUER TESTS: wartet, bis das Auf- und Abbauen durch ist.
  ///
  /// Die Kontaktwege stossen es an, ohne darauf zu warten — die Oberflaeche
  /// soll nicht auf dem Funk stehen. Ein Test, der danach nachsieht, braucht
  /// trotzdem einen Punkt, an dem er weiss, dass es fertig ist.
  @visibleForTesting
  Future<void> get nahRuhtFuerTest => _nahLauf;

  /// NUR FUER TESTS: der Nahbereich, so wie der Kern ihn benutzt.
  @visibleForTesting
  Nahbereich? get nahFuerTest => _nah;

  // ═════════════════════════════════════════════════════════════════ Eingang

  /// Ein Umschlag vom Relay.
  ///
  /// [RelayMessage.q] ist die Kennung der Zeile in der Warteschlange — nur der
  /// Relay hat eine, und nur bei ihm wird am Ende bestaetigt.
  Future<void> _verarbeiteEingang(RelayMessage roh) => _nimmUmschlag(
    von: roh.from,
    vonGeraet: roh.vonGeraet,
    umschlag: roh.ciphertext,
    ueberNaehe: false,
    nachweisFuer: roh.q,
  );

  /// Ein Umschlag ueber die Naehe.
  ///
  /// DERSELBE WEG WIE OBEN, und das ist der ganze Punkt: die Entschluesselung,
  /// der Umgang mit einem unbekannten Absender, das Ablegen im Verlauf und die
  /// Behandlung eines Fehlschlags stehen genau einmal da. Ein zweites Mal
  /// geschrieben waeren es zwei Fassungen, von denen die eine irgendwann
  /// nachzieht und die andere nicht.
  ///
  /// Was NICHT gleich ist: es gibt keine Zeile beim Relay, also auch nichts zu
  /// bestaetigen. Deshalb `nachweisFuer: null` — nicht als Sonderfall im
  /// Verarbeiten, sondern als das, was es ist: ein fehlender Nachweis.
  /// Beantwortet eine Buendel-Anfrage und verwertet eine Buendel-Antwort.
  ///
  /// NUR VON ERKANNTEN KONTAKTEN. Die Zuordnung kommt aus der Marke und damit
  /// aus demselben X25519-Geheimnis wie die Erkennung — wer nicht in der
  /// Kontaktliste steht, taucht hier gar nicht erst auf. Ohne das koennte
  /// jeder in Reichweite Buendel einsammeln und den Vorrat leeren.
  Future<void> _verarbeiteSonderpost(NahSonderpost post) async {
    final store = _store;
    if (store == null) return;
    try {
      switch (post.typ) {
        case Nahtyp.buendelAnfrage:
          await _schickeBuendelUeberFunk(post.von);
        case Nahtyp.buendelAntwort:
          await _nimmBuendelUeberFunk(post.von, post.nutzlast);
        default:
          // Ein Typ aus einer neueren Fassung. Nichts tun ist richtig:
          // abstuerzen waere schlimmer, und raten gibt es hier nicht.
          break;
      }
    } catch (e) {
      // ignore: avoid_print
      print('BitDM-Nah: Sonderpost von ' + post.von +
          ' (Typ ' + post.typ.toString() + ') gescheitert: ' + e.toString());
    }
  }

  /// Wann zuletzt ein Buendel an wen ging. Gegen das Leerfragen des Vorrats.
  final Map<String, DateTime> _buendelZuletzt = {};

  /// Wie oft dieselbe Gegenstelle ein Buendel bekommen darf.
  ///
  /// EIN EINMALSCHLUESSEL JE ANFRAGE, und der ist danach weg — das ist
  /// richtig so, aber es macht die Anfrage zu etwas, das Arbeit und Vorrat
  /// kostet. Ohne Grenze koennte jedes Geraet in Reichweite den Vorrat leeren,
  /// einfach indem es fragt. Danach bekaeme jeder neue Kontakt nur noch ein
  /// Buendel OHNE Einmalschluessel: eine Sitzung geht dann zwar noch, aber die
  /// zusaetzliche Absicherung fehlt — und niemand saehe, warum.
  ///
  /// Eine Minute ist reichlich fuer den echten Fall (man fragt einmal und baut
  /// die Sitzung auf) und eng genug, dass Leerfragen nichts bringt.
  /// KEIN `const`, DAMIT DER TEST IHN VERKUERZEN KANN. Eine Grenze, die sich
  /// nur mit echtem Warten pruefen laesst, wird nicht geprueft — und eine
  /// Sicherung ohne Test ist eine Vermutung.
  Duration buendelAbstand = const Duration(minutes: 1);

  /// Baut das eigene Buendel und schickt es ueber die Naehe.
  Future<void> _schickeBuendelUeberFunk(String an) async {
    final store = _store!;
    final nah = _nah;
    // DIE ZWEITE HAELFTE VON [_darfFunken], und sie muss hier noch einmal
    // stehen: die Karte unten hat kein `device_id`-Feld, die Gegenseite legt
    // sie also unter "adresse:1" ab. Antwortete ein Zweitgeraet, vergiftete
    // sein Schluesselmaterial dort dauerhaft die Sitzung zu Geraet 1.
    if (nah == null || !_darfFunken) return;

    final zuletzt = _buendelZuletzt[an];
    final jetzt = DateTime.now().toUtc();
    if (zuletzt != null && jetzt.difference(zuletzt) < buendelAbstand) {
      // STILL ABLEHNEN, nicht mit einer Fehlermeldung antworten: wer hier
      // fragt, ist ein erkannter Kontakt, und eine Antwort waere entweder
      // nutzlos oder eine Einladung, es weiter zu versuchen.
      return;
    }
    _buendelZuletzt[an] = jetzt;

    final spk = await store.loadSignedPreKey(store.state.signedPreKeys.keys.first);
    // GENAU EINEN EINMALSCHLUESSEL, UND ER IST DANACH VERBRAUCHT.
    //
    // Beim Relay bekommt jeder Abruf einen frischen; ueber Funk muss dieselbe
    // Regel gelten, sonst bauen zwei Gegenstellen ihre Sitzung auf demselben
    // auf — und dann ist er fuer beide keine zusaetzliche Absicherung mehr.
    final ids = store.state.preKeys.keys.toList()..sort();
    final einer = ids.isEmpty ? null : await store.loadPreKey(ids.first);

    final b = PreKeyBundleBridge.toRelay(
      identity: store.identity,
      signedPreKey: spk,
      oneTimePreKeys: einer == null ? const [] : [einer],
    );
    // Die Form von RelayBundleResponse, nicht die von RelayPreKeyBundle: die
    // Gegenseite liest es mit `RelayBundleResponse.fromJson`, und dort heisst
    // es EIN Schluessel statt einer Liste.
    final karte = <String, Object?>{
      'user_id': b.userId,
      'identity_key': b.identityKey,
      'registration_id': b.registrationId,
      'signed_prekey_id': b.signedPreKeyId,
      'signed_prekey': b.signedPreKey,
      'signed_prekey_sig': b.signedPreKeySignature,
      'one_time_prekey':
          b.oneTimePreKeys.isEmpty ? null : b.oneTimePreKeys.first.toJson(),
    };
    await nah.schickeSonder(an, Nahtyp.buendelAntwort,
        Uint8List.fromList(utf8.encode(jsonEncode(karte))));

    if (einer != null) {
      await store.removePreKey(einer.id);
      _fuelleVorratAuf();
    }
  }

  /// Baut aus einem ueber Funk gekommenen Buendel eine Sitzung.
  ///
  /// IMMER GERAET 1, und das bleibt so. Der Nahbereich schluesselt
  /// ausschliesslich ueber die Kontaktliste (siehe [_nahKontakte]); dort steht
  /// eine ADRESSE, kein Geraet, und das eigene Zweitgeraet ist dort gar kein
  /// Kontakt. Dazu kommt: in Reichweite liegen selten beide Geraete der
  /// Gegenstelle.
  /// ponytail: Nahbereich kennt nur Geraet 1. Ausbau erst, wenn jemand
  /// wirklich zwei Geraete nebeneinander betreibt.
  Future<void> _nimmBuendelUeberFunk(String von, Uint8List roh) async {
    final store = _store!;
    final ziel = SignalProtocolAddress(von, 1);
    if (await store.containsSession(ziel)) return;

    final j = (jsonDecode(utf8.decode(roh)) as Map).cast<String, Object?>();
    final antwort = RelayBundleResponse.fromJson(j);
    // DIE ADRESSE MUSS ZUM ABSENDER PASSEN. Die Marke sagt, WER geschickt hat;
    // das Buendel behauptet, WEM es gehoert. Stimmen die nicht ueberein,
    // baute man eine Sitzung mit einer fremden Identitaet auf.
    if (antwort.userId != von) {
      throw StateError('Buendel von $von gehoert zu ${antwort.userId}');
    }
    await SessionBuilder.fromSignalStore(store, ziel)
        .processPreKeyBundle(PreKeyBundleBridge.fromRelay(antwort));
    // Und sofort nachholen, was darauf gewartet hat.
    _stosseNachversandAn();
  }

  /// Ueber die Naehe kommt immer Geraet 1 — siehe [_schickeBuendelUeberFunk]:
  /// der Funk schluesselt ueber die Kontaktliste, und dort steht eine Adresse,
  /// kein Geraet.
  Future<void> _verarbeiteNaheEingang(NahUmschlag u) => _nimmUmschlag(
    von: u.von,
    vonGeraet: 1,
    umschlag: u.umschlag,
    ueberNaehe: true,
    nachweisFuer: null,
  );

  Future<void> _nimmUmschlag({
    required String von,
    required int vonGeraet,
    required Uint8List umschlag,
    required bool ueberNaehe,
    required int? nachweisFuer,
  }) async {
    final store = _store;
    final chats = _chats;
    // Ein Umschlag, der eintrifft, waehrend gerade gesperrt oder geloescht
    // wird. Ohne diese Zeile waere es ein Absturz aus einem `!` heraus, in
    // einem unawaited-Ablauf, den niemand faengt.
    if (store == null || chats == null) return;

    final Payload payload;
    try {
      final huelle = Envelope.fromBytes(umschlag);
      // DIE SITZUNG DES GERAETEPAARS, nicht "die Sitzung mit dieser Adresse".
      // Gegen die falsche zu probieren waere kein Fehlversuch, den man
      // wiederholen koennte: `_behandleEingangsfehler` schreibt den
      // Ratchet-Fortschritt auch beim Fehlschlag fest, und danach ist genau
      // diese Nachricht dauerhaft unentschluesselbar.
      final klar = await huelle.decrypt(
        SessionCipher.fromStore(store, SignalProtocolAddress(von, vonGeraet)),
      );
      payload = Payload.fromBytes(klar);
    } catch (fehler) {
      _behandleEingangsfehler(fehler, von);
      // AUCH HIER bestaetigen. _behandleEingangsfehler schreibt den
      // Sitzungsfortschritt fest; ab da laesst sich dieser Umschlag nie
      // wieder entschluesseln, und ihn 14 Tage lang bei jedem Verbinden
      // erneut zu schicken hilft niemandem. Wirft das Schreiben selbst,
      // kommt diese Zeile nicht dran — dann bleibt die Zeile beim Relay
      // liegen, und das ist richtig so.
      _bestaetigeEmpfang(nachweisFuer);
      return;
    }

    // ═══════════════════════════ VOM EIGENEN ZWEITGERAET ODER VON JEMANDEM?
    //
    // `von == myId` GENUEGT, UND ES IST GERECHNET STATT BEHAUPTET. Diese Bytes
    // sind nur entschluesselbar, wenn sie ueber eine Sitzung mit unserem
    // EIGENEN Identitaetsschluessel liefen, und `isTrustedIdentity` rechnet
    // die Adresse aus dem Schluessel nach (signal_store `_keyMatchesAddress`).
    // Ein Fremder kann `from` beliebig behaupten — entschluesselbar macht er
    // es damit nicht. Die Behauptung IN der Nutzlast wird nie gefragt.
    //
    // ALLES ANDERE VON DER EIGENEN ADRESSE WIRD VERWORFEN, und das ist die
    // erste der drei Stolperfallen: eine Kontaktanfrage von einem selbst darf
    // niemals in der Anfragenliste auftauchen. Ohne diesen Zweig liefe sie
    // durch `_legeEingangAb` und legte einen Kontakt "ich" an.
    // GRUPPENPOST ZUERST, auch von der eigenen Adresse: das eigene Zweitgeraet
    // bekommt eigene Gruppennachrichten und Gruppenstaende auf demselben Weg
    // wie alle anderen Mitglieder. Wer schreiben darf, entscheidet die
    // Mitgliederliste in [_nimmGruppe], nicht diese Weiche.
    if (payload.kind == PayloadKind.gruppe) {
      _nimmGruppe(von, payload, ueberNaehe, store);
    } else if (payload.kind == PayloadKind.gruppenStand) {
      _nimmGruppenStand(von, payload, store);
    } else if (payload.kind == PayloadKind.gruppenAustritt) {
      _nimmAustritt(von, payload, store);
    } else if (von == myId) {
      _nimmSpiegel(payload);
    } else {
      switch (payload.kind) {
        case PayloadKind.text:
        case PayloadKind.contactRequest:
          _legeEingangAb(von, payload, ueberNaehe);
        case PayloadKind.anhang:
          _legeAnhangAb(von, payload, ueberNaehe);
        case PayloadKind.contactAccept:
          _bestaetigeKontakt(von);
        case PayloadKind.contactDecline:
          _lehnteAb(von);
        case PayloadKind.deliveryReceipt:
          if (payload.gruppe != null) {
            _quittiereGruppe(von, payload.gruppe!, payload.refs);
          } else {
            _quittiere(von, payload.refs, MessageStatus.delivered);
          }
        case PayloadKind.readReceipt:
          _quittiere(von, payload.refs, MessageStatus.read);
        // Der Chat IST der Absender, und der Autor auch: eine Gegenstelle
        // kann nur in der Unterhaltung mit sich selbst reagieren, und nur
        // ihre eigenen Saetze aendern oder zuruecknehmen.
        case PayloadKind.reaktion:
          _nimmReaktion(von, von, payload, store);
        case PayloadKind.bearbeitung:
          _nimmBearbeitung(von, von, payload, store);
        case PayloadKind.widerruf:
          _nimmWiderruf(von, von, payload, store);
        case PayloadKind.tippt:
          _nimmTippen(von, payload);
        case PayloadKind.anheften:
          _nimmAnheften(von, payload, store);
        case PayloadKind.umfrage:
          // Erst pruefen, dann ablegen: eine Umfrage, die keine ist, kaeme
          // sonst als Blase ohne Inhalt in den Verlauf.
          if (Umfrage.lies(payload.text) != null) {
            _legeEingangAb(von, payload, ueberNaehe, art: MessageKind.umfrage);
          }
        case PayloadKind.stimme:
          _nimmStimme(von, von, payload, store);
        case PayloadKind.gruppe:
        case PayloadKind.gruppenStand:
        case PayloadKind.gruppenAustritt:
          // Schon oben verteilt; hier nur, damit die Aufzaehlung vollstaendig
          // bleibt und eine kuenftige Art den Uebersetzer stolpern laesst.
          break;
        case PayloadKind.loeschanfrage:
          _nimmLoeschanfrage(von);
        case PayloadKind.spiegel:
          // Ein Spiegel von einer FREMDEN Adresse ergibt keinen Sinn: er
          // gehoert in einen Chat, ueber den der Absender nichts zu sagen
          // hat. Still verwerfen, wie jede Art, mit der hier nichts anzufangen
          // ist.
          break;
      }
    }

    // Steuernachrichten legen nichts in den Verlauf, veraendern aber trotzdem
    // den Ratchet. Ohne diese Zeile bliebe der Fortschritt im Arbeitsspeicher.
    chats.speichereNurSitzung(store);

    // HIER KANN EIN KONTAKT ENTSTANDEN ODER VERSCHWUNDEN SEIN, und das geht
    // den Nahbereich an: die erste Nachricht von jemand Unbekanntem legt ihn
    // an, eine Absage nimmt ihn weg.
    //
    // Ohne diese Zeile kannte der Nahbereich ausgerechnet den zuletzt
    // hinzugekommenen Kontakt nicht — den, neben dem man am ehesten steht. Bob
    // fuegt Anna hinzu und findet sie; Annas App legt Bob auf dem Empfangsweg
    // an, sendet kein Leuchtfeuer fuer ihn und erkennt seines nicht. Weil das
    // Verfahren in beide Richtungen laeuft, findet dann auch Bob sie nicht
    // mehr. Die ganze Schicht tat fuer dieses Paar stillschweigend nichts.
    //
    // EINE STELLE UND NICHT VIER: jeder Zweig oben, der einen Kontakt
    // anfassen kann, kommt hier vorbei — auch ein kuenftiger. Dass daraus
    // nicht bei jeder eingehenden Nachricht ein Neuaufbau wird, entscheidet
    // _setzeNaheAuf: es vergleicht die Kontaktliste mit der, mit der der Funk
    // laeuft. Ein Neuaufbau je Nachricht hielte den Funk staendig an und
    // wieder an, und wer in Reichweite ist, waere nach jeder Nachricht wieder
    // unbekannt.
    unawaited(_richteNaheEin());

    _bestaetigeEmpfang(nachweisFuer);
  }

  /// Sagt dem Relay, dass dieser Umschlag dauerhaft liegt.
  ///
  /// ERST NACH DEM SCHREIBEN. Der Relay loescht daraufhin seine Zeile; ein
  /// Nachweis davor haette den Verlust nur von der Leitung in die App
  /// verschoben. Der dauerhafte Punkt ist chat_repository —
  /// speichereEmpfangen / speichereEmpfangenMitKontakt /
  /// speichereNurSitzung sind synchrones sqlite3 in einer Transaktion, nach
  /// deren Rueckkehr steht die Zeile auf der Platte.
  ///
  /// Ueber das AKTUELLE _relay und nicht ueber das, das die Nachricht
  /// gebracht hat: sollte inzwischen neu verbunden worden sein, gehoert die
  /// Verbindung derselben Adresse, und der Relay loescht ohnehin nur Zeilen
  /// mit passendem Empfaenger. Nach einem Identitaetswechsel verpufft der
  /// Nachweis wirkungslos.
  void _bestaetigeEmpfang(int? q) {
    // Ohne Kennung gibt es nichts zu bestaetigen: live zugestellt, ueber die
    // Naehe gekommen, oder ein Relay, der den Nachweis nicht kennt.
    if (q == null) return;
    _relay?.bestaetigeEmpfang(q);
  }

  void _behandleEingangsfehler(Object fehler, String von) {
    final art = classify(fehler);
    // Der Ratchet kann trotz Fehlschlag weitergerueckt sein — was da ist, wird
    // festgeschrieben.
    _chats!.speichereNurSitzung(_store!);

    if (art.needsUserAttention) {
      _contacts.add(ContactEvent(
          type: ContactEventType.incomingRequest,
          contactId: von,
          at: DateTime.now().toUtc()));
    }
    // Alles Uebrige wird verworfen. Eine Nachricht, die sich nicht
    // entschluesseln laesst, ist entweder doppelt, veraltet oder nicht von der
    // Gegenstelle — in keinem Fall etwas, das der Nutzer sehen sollte.
  }

  void _legeEingangAb(String von, Payload p, bool ueberNaehe,
      {MessageKind art = MessageKind.text}) {
    final chats = _chats!;
    final store = _store!;

    // Eine Nachricht von jemandem, den es lokal nicht gibt, macht daraus eine
    // eingehende Anfrage. Der Nutzer soll sehen koennen, WAS jemand geschrieben
    // hat, bevor er ueber den Kontakt entscheidet — eine Anfrage ohne jeden
    // Anhaltspunkt waere schlechter zu beurteilen.
    final bekannt = chats.kontakt(von);
    final neuerKontakt = bekannt == null
        ? Contact(
            id: von,
            addedAt: DateTime.now().toUtc(),
            state: ContactState.incomingPending)
        : null;

    // Eine reine Kontaktanfrage traegt keinen Text. Sie darf NICHTS in den
    // Verlauf legen — sonst begaenne jede Unterhaltung mit einer leeren Blase.
    if (p.text.isEmpty) {
      if (neuerKontakt != null) {
        chats.speichereKontaktUndSitzung(neuerKontakt, store);
        _meldeAnfrage(von);
      } else {
        chats.speichereNurSitzung(store);
      }
      return;
    }

    final nachricht = Message(
      id: p.messageId,
      chatId: von,
      senderId: von,
      text: p.text,
      kind: art,
      isMine: false,
      timestamp: p.sentAt,
      status: MessageStatus.delivered,
      ueberNaehe: ueberNaehe,
      antwortAuf: p.antwortAuf,
    );

    // Die Lebensdauer kommt vom ABSENDER: er hat entschieden, wie lange seine
    // Nachricht leben soll, und das gilt auf beiden Geraeten. Eine eigene
    // Einstellung hier draufzurechnen wuerde seine Entscheidung stillschweigend
    // uebergehen.
    final ttl = p.ttlSeconds == null ? null : Duration(seconds: p.ttlSeconds!);
    final neu = neuerKontakt == null
        ? chats.speichereEmpfangen(nachricht, store, lebensdauer: ttl)
        : chats.speichereEmpfangenMitKontakt(nachricht, neuerKontakt, store,
            lebensdauer: ttl);

    if (neuerKontakt != null && neu) _meldeAnfrage(von);

    // Doppelt zugestellte Nachrichten nicht noch einmal melden.
    if (neu) {
      _incoming.add(nachricht);
      unawaited(_sendeQuittung(von, p.messageId));
    }
  }

  /// Ein angekuendigter Anhang.
  ///
  /// GEHOLT WIRD HIER NICHTS. Die Datei kann drei Gigabyte gross sein; sie
  /// ungefragt zu holen, waere ein Griff in fremdes Datenvolumen — und bei
  /// jemandem, der noch gar kein Kontakt ist, waere es schlimmer als das. In
  /// den Verlauf kommt der Name, die Groesse und die Anleitung; das Holen
  /// stoesst die Oberflaeche an ([holeAnhang]).
  void _legeAnhangAb(String von, Payload p, bool ueberNaehe) {
    final chats = _chats!;
    final store = _store!;

    final Rezept rezept;
    try {
      rezept = Rezept.ausText(p.text);
    } on RezeptFormatException {
      // Eine unlesbare Anleitung ist kein Grund abzustuerzen und auch keiner,
      // dem Nutzer etwas anzuzeigen: er kann nichts damit anfangen. Der
      // Ratchet-Fortschritt muss trotzdem festgeschrieben werden.
      chats.speichereNurSitzung(store);
      return;
    }

    final bekannt = chats.kontakt(von);
    final neuerKontakt = bekannt == null
        ? Contact(
            id: von,
            addedAt: DateTime.now().toUtc(),
            state: ContactState.incomingPending)
        : null;

    // DER NAME KOMMT VON DRAUSSEN und wird gesaeubert, BEVOR er gespeichert
    // wird — nicht erst beim Anlegen der Datei. Sonst stuende er ungeprueft in
    // der Datenbank und jede kuenftige Stelle, die ihn benutzt, muesste selbst
    // daran denken.
    final name = AnhangEmpfang.sichererName(rezept.name);

    final nachricht = Message(
      id: p.messageId,
      chatId: von,
      senderId: von,
      text: name,
      kind: MessageKind.anhang,
      isMine: false,
      timestamp: p.sentAt,
      status: MessageStatus.delivered,
      // Die ANKUENDIGUNG kam ueber die Naehe; die Datei selbst kommt trotzdem
      // aus dem Zwischenlager. Das Zeichen sagt, wie die Nachricht gegangen
      // ist, und das ist hier die Ankuendigung.
      ueberNaehe: ueberNaehe,
      antwortAuf: p.antwortAuf,
    );
    final eintrag = AnhangEintrag(
      messageId: p.messageId,
      chatId: von,
      senderId: von,
      name: name,
      groesse: rezept.gesamtGroesse,
      zustand: AnhangZustand.angekuendigt,
      einmal: rezept.einmal,
    );

    final ttl = p.ttlSeconds == null ? null : Duration(seconds: p.ttlSeconds!);
    final neu = neuerKontakt == null
        ? chats.speichereEmpfangen(nachricht, store,
            lebensdauer: ttl, anhang: eintrag, rezept: p.text)
        : chats.speichereEmpfangenMitKontakt(nachricht, neuerKontakt, store,
            lebensdauer: ttl, anhang: eintrag, rezept: p.text);

    if (neuerKontakt != null && neu) _meldeAnfrage(von);
    if (neu) {
      _incoming.add(nachricht);
      _anhangWechsel.add(eintrag);
      unawaited(_sendeQuittung(von, p.messageId));
    }
  }

  /// Was ein anderes Geraet DERSELBEN Identitaet gerade verschickt hat.
  ///
  /// ═══════════════════════════════════ WARUM DAS NICHT UEBER `_legeEingangAb`
  /// GEHT
  ///
  /// `_legeEingangAb` legt hart `chatId: von, senderId: von, isMine: false`
  /// fest. Fuer einen Spiegel ist jedes dieser drei Felder falsch: der Chat
  /// ist die Gegenstelle (`c`), der Absender bin ich, und die Nachricht ist
  /// meine. Sie dort einzuflechten hiesse, drei Sonderfaelle in eine Funktion
  /// zu legen, die den Normalfall traegt.
  ///
  /// KEINE QUITTUNG UND KEINE ANFRAGE. Das ist die zweite und dritte
  /// Stolperfalle: eine Empfangsbestaetigung an mich selbst waere eine
  /// Nachricht, die das andere Geraet nicht zuordnen kann, und ein Kontakt
  /// "ich" waere in der Liste nicht mehr loszuwerden. Deshalb wird hier
  /// nichts zurueckgeschickt.
  ///
  /// ENTDOPPELT WIRD NICHT HIER, sondern vom eindeutigen Index auf
  /// messages(chat_id, sender_id, id) zusammen mit `INSERT OR IGNORE`. Noetig
  /// ist das, weil der Nachversand dieselbe Nutzlast erneut schickt und damit
  /// erneut spiegelt.
  /// Was in den Notizen zwischen eigenen Geraeten reist: neue Notizen und
  /// alles, was auf eine vorhandene zeigt. Nichts, was einen Kontakt anlegt.
  static const _notizArten = {
    PayloadKind.text,
    PayloadKind.anhang,
    PayloadKind.bearbeitung,
    PayloadKind.widerruf,
    PayloadKind.reaktion,
    PayloadKind.anheften,
  };

  void _nimmSpiegel(Payload aussen) {
    if (aussen.kind != PayloadKind.spiegel) return;
    final chats = _chats!;
    final store = _store!;

    // Ein Spiegel, dessen Ziel-Chat die eigene Adresse ist, ergaebe eine
    // Unterhaltung mit sich selbst. `Payload.fromBytes` hat die Adresse schon
    // auf Form und Pruefsumme geprueft; das hier ist die inhaltliche Absage.
    final chat = aussen.chatId;
    if (chat == null) return;

    final Payload p;
    try {
      p = aussen.innere;
    } on PayloadFormatException {
      // Eine aeltere oder fehlerhafte Fassung derselben App. Verwerfen ist
      // richtig — der Ratchet-Fortschritt wird vom Aufrufer festgeschrieben.
      return;
    }

    // DIE UNTERHALTUNG MIT SICH SELBST GIBT ES NUR ALS NOTIZEN: Text und
    // Anhang, sonst nichts. Eine gespiegelte Kontaktanfrage "an mich" legte
    // sonst einen Kontakt "ich" im Wartezustand an, den niemand annehmen kann.
    if (chat == myId && !_notizArten.contains(p.kind)) {
      return;
    }

    // KEIN LOESCHEN AUS EINEM SPIEGEL. Gegenstueck zu [_spiegelfaehig]: wir
    // schicken diese Art nicht mehr, und wir handeln auch nicht mehr auf sie.
    // Beides gehoert zusammen — ein Spiegel, der VOR dieser Aenderung entstand,
    // liegt beim Relay und laesst sich jederzeit wieder einwerfen.
    if (p.kind == PayloadKind.contactDecline) return;

    // WAS AUF EINE NACHRICHT ZEIGT, LEGT KEINEN KONTAKT AN. Eine Reaktion,
    // eine Bearbeitung oder ein Widerruf ohne vorhandene Nachricht tut hier
    // nichts — genau wie beim fremden Absender. Der Autor ist ICH: so greift
    // die Regel "nur der Absender bearbeitet" auch zwischen eigenen Geraeten.
    switch (p.kind) {
      case PayloadKind.reaktion:
        _nimmReaktion(chat, myId, p, store);
        return;
      case PayloadKind.bearbeitung:
        _nimmBearbeitung(chat, myId, p, store);
        return;
      case PayloadKind.widerruf:
        _nimmWiderruf(chat, myId, p, store);
        return;
      case PayloadKind.anheften:
        _nimmAnheften(chat, p, store);
        return;
      case PayloadKind.stimme:
        _nimmStimme(chat, myId, p, store);
        return;
      default:
        break;
    }

    final bekannt = chats.kontakt(chat);
    final zustand = p.kind == PayloadKind.contactRequest
        ? ContactState.outgoingPending
        : ContactState.active;
    // ANZEIGENAME UND "VERIFIZIERT" REISEN NICHT MIT (Spezifikation §9). Ein
    // bestehender Kontakt behaelt beides; ein neu entstandener hat es nicht.
    final kontakt = bekannt == null
        ? Contact(id: chat, addedAt: DateTime.now().toUtc(), state: zustand)
        : (bekannt.state == ContactState.active
              ? null
              : bekannt.copyWith(state: zustand));

    // Steuernachrichten legen nichts in den Verlauf.
    if (p.kind != PayloadKind.text &&
        p.kind != PayloadKind.anhang &&
        p.kind != PayloadKind.umfrage) {
      if (kontakt != null) chats.speichereKontaktUndSitzung(kontakt, store);
      return;
    }
    if (p.kind == PayloadKind.umfrage && Umfrage.lies(p.text) == null) return;

    final anhang = p.kind == PayloadKind.anhang;
    final Rezept? rezept;
    if (anhang) {
      try {
        rezept = Rezept.ausText(p.text);
      } on RezeptFormatException {
        return;
      }
    } else {
      rezept = null;
    }
    final name = anhang ? AnhangEmpfang.sichererName(rezept!.name) : p.text;

    final nachricht = Message(
      id: p.messageId,
      chatId: chat,
      senderId: myId,
      text: name,
      kind: anhang
          ? MessageKind.anhang
          : (p.kind == PayloadKind.umfrage
              ? MessageKind.umfrage
              : MessageKind.text),
      isMine: true,
      timestamp: p.sentAt,
      // SENT UND NICHT SENDING. `unversandt()` holt alles, was auf `sending`
      // steht, und schickte es erneut — dieses Geraet wuerde eine Nachricht
      // wiederholen, die es selbst nie verfasst hat. Weiter als "gesendet"
      // kommt der Spiegel nicht: Quittungen werden bewusst nicht gespiegelt,
      // Haken- und Lesezustand bleiben deshalb je Geraet.
      status: MessageStatus.sent,
      antwortAuf: p.antwortAuf,
    );
    // `zustand` und `pfad` sind ORTSGEBUNDEN: die Datei liegt auf dem anderen
    // Geraet. Hier entsteht nur der Eintrag, und der bleibt "angekuendigt".
    final eintrag = anhang
        ? AnhangEintrag(
            messageId: p.messageId,
            chatId: chat,
            senderId: myId,
            name: name,
            groesse: rezept!.gesamtGroesse,
            zustand: AnhangZustand.angekuendigt,
          )
        : null;

    final ttl = p.ttlSeconds == null ? null : Duration(seconds: p.ttlSeconds!);
    final neu = kontakt == null
        ? chats.speichereEmpfangen(
            nachricht,
            store,
            lebensdauer: ttl,
            anhang: eintrag,
            rezept: eintrag == null ? null : p.text,
          )
        : chats.speichereEmpfangenMitKontakt(
            nachricht,
            kontakt,
            store,
            lebensdauer: ttl,
            anhang: eintrag,
            rezept: eintrag == null ? null : p.text,
          );

    if (neu) {
      _incoming.add(nachricht);
      if (eintrag != null) _anhangWechsel.add(eintrag);
    }
  }

  /// Wie alt eine Tipp-Meldung hoechstens sein darf. Der Relay puffert sie
  /// nicht, aber ein alter Relay oder ein Weg ueber die Naehe koennte sie
  /// doch verspaetet abliefern — und dann waere sie falsch.
  static const Duration tippFrische = Duration(seconds: 30);

  void _nimmTippen(String von, Payload p) {
    if (!_prefs.tippAnzeige) return;
    if (_chats?.kontakt(von)?.state != ContactState.active) return;
    if (DateTime.now().toUtc().difference(p.sentAt) > tippFrische) return;
    _tippen.add(TippMeldung(von, p.text == '1'));
  }

  void _nimmStimme(
      String chat, String von, Payload p, BitdmSignalStore store) {
    final auswahl = p.auswahl;
    if (auswahl == null) return;
    if (_chats!.setzeStimme(chat, p.refs.single, von, auswahl, p.sentAt,
        store: store)) {
      _verlaufWechsel.add(chat);
    }
  }

  void _nimmAnheften(String chat, Payload p, BitdmSignalStore store) {
    if (_chats!.hefteAn(chat, p.refs.single, p.text == '1', p.sentAt,
        store: store)) {
      _verlaufWechsel.add(chat);
    }
  }

  // ═══════════════════════════════════════════════════════ Gruppen: Eingang

  bool _istGruppe(String id) => Gruppe.istGruppenId(id);

  /// Eine Nachricht in einer Gruppe. Angenommen wird sie NUR von einem
  /// Mitglied laut der EIGENEN Liste — eine Behauptung des Absenders zaehlt
  /// nicht, und wer entfernt wurde, schreibt nicht mehr hinein.
  void _nimmGruppe(
      String von, Payload huelle, bool ueberNaehe, BitdmSignalStore store) {
    final gid = huelle.gruppe!;
    final g = _chats!.gruppe(gid);
    if (g == null || !g.aktiv || !g.mitglieder.contains(von)) return;
    final Payload p;
    try {
      p = huelle.innere;
    } on PayloadFormatException {
      return;
    }
    switch (p.kind) {
      case PayloadKind.text:
      case PayloadKind.umfrage:
      case PayloadKind.anhang:
        _legeGruppenNachrichtAb(gid, von, p, ueberNaehe, store);
      // Dieselben Regeln wie im Einzelchat, mit der Gruppe als Chat und dem
      // Absender als Autor: niemand bearbeitet oder loescht fremde Saetze.
      case PayloadKind.reaktion:
        _nimmReaktion(gid, von, p, store);
      case PayloadKind.bearbeitung:
        _nimmBearbeitung(gid, von, p, store);
      case PayloadKind.widerruf:
        _nimmWiderruf(gid, von, p, store);
      case PayloadKind.stimme:
        _nimmStimme(gid, von, p, store);
      case PayloadKind.anheften:
        _nimmAnheften(gid, p, store);
      default:
        // Quittungen, Tippen, Kontaktanfragen und verschachtelte Huellen
        // haben in einer Gruppe nichts verloren.
        break;
    }
  }

  void _legeGruppenNachrichtAb(String gid, String von, Payload p,
      bool ueberNaehe, BitdmSignalStore store) {
    final chats = _chats!;
    var text = p.text;
    final MessageKind art;
    AnhangEintrag? eintrag;
    switch (p.kind) {
      case PayloadKind.text:
        if (text.isEmpty) return;
        art = MessageKind.text;
      case PayloadKind.umfrage:
        if (Umfrage.lies(text) == null) return;
        art = MessageKind.umfrage;
      case PayloadKind.anhang:
        final Rezept rezept;
        try {
          rezept = Rezept.ausText(text);
        } on RezeptFormatException {
          return;
        }
        art = MessageKind.anhang;
        text = AnhangEmpfang.sichererName(rezept.name);
        eintrag = AnhangEintrag(
          messageId: p.messageId,
          chatId: gid,
          senderId: von,
          name: text,
          groesse: rezept.gesamtGroesse,
          zustand: AnhangZustand.angekuendigt,
          einmal: rezept.einmal,
        );
      default:
        return;
    }
    final nachricht = Message(
      id: p.messageId,
      chatId: gid,
      senderId: von,
      text: text,
      kind: art,
      isMine: von == myId,
      timestamp: p.sentAt,
      status: von == myId ? MessageStatus.sent : MessageStatus.delivered,
      ueberNaehe: ueberNaehe,
      antwortAuf: p.antwortAuf,
    );
    final ttl = p.ttlSeconds == null ? null : Duration(seconds: p.ttlSeconds!);
    final neu = chats.speichereEmpfangen(nachricht, store,
        lebensdauer: ttl, anhang: eintrag, rezept: eintrag == null ? null : p.text);
    if (neu) {
      _incoming.add(nachricht);
      if (eintrag != null) _anhangWechsel.add(eintrag);
      // DER AUTOR ERFAEHRT, DASS SIE DA IST — direkt, nicht an die ganze
      // Gruppe. Vorher gab es in Gruppen gar keine Quittung, und jede
      // Nachricht stand fuer immer auf einem Haken.
      if (von != myId) unawaited(_sendeGruppenQuittung(von, gid, p.messageId));
    }
  }

  Future<void> _sendeGruppenQuittung(String an, String gid, String messageId) async {
    await Future<void>.delayed(quittungsVerzug());
    if (_conn != ConnectionState.online && !(_nah?.bereit ?? false)) return;
    try {
      await _sendePayload(
          an,
          Payload(
              kind: PayloadKind.deliveryReceipt,
              messageId: _neueId(),
              sentAt: DateTime.now().toUtc(),
              refs: [messageId],
              gruppe: gid));
    } catch (_) {
      // Eine verlorene Quittung kostet einen Haken, sonst nichts.
    }
  }

  /// Eine Zustellquittung aus einer Gruppe: je Mitglied merken, und wenn alle
  /// da sind, zwei Haken — so wie bei Signal.
  void _quittiereGruppe(String von, String gid, List<String> refs) {
    final chats = _chats!;
    final g = chats.gruppe(gid);
    if (g == null || !g.mitglieder.contains(von)) return;
    for (final ref in refs) {
      final haben = chats.merkeGruppenQuittung(gid, ref, von, myId);
      if (haben == null) continue;
      final alle = g.mitglieder.where((m) => m != myId).toSet();
      if (alle.difference(haben).isEmpty) {
        chats.setzeStatus(gid, myId, ref, MessageStatus.delivered);
        _status.add(MessageStatusUpdate(
            messageId: ref, chatId: gid, status: MessageStatus.delivered, at: DateTime.now().toUtc()));
      }
    }
  }

  final _fernloeschung = StreamController<Fernloeschung>.broadcast();

  @override
  Stream<Fernloeschung> get fernloeschungAusgeloest => _fernloeschung.stream;

  @override
  Future<Fernloeschung> getFernloeschung() async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.fernloeschung();
  }

  @override
  Future<void> setzeFernloeschung(Fernloeschung f) async {
    if (_chats == null) throw const NotInitializedException();
    // Die Schwelle nie unter zwei — einer allein darf nie loeschen koennen.
    final k = f.schwelle < 2 ? 2 : f.schwelle;
    _chats!.speichereFernloeschung(f.copyWith(schwelle: k));
  }

  @override
  Future<void> sendeLoeschanfrage(String contactId) async {
    _fordereChat(contactId);
    await _sendeSteuerung(
        contactId, Payload.control(PayloadKind.loeschanfrage, _neueId(), DateTime.now().toUtc()));
  }

  void _nimmLoeschanfrage(String von) {
    final chats = _chats!;
    final vorher = chats.fernloeschung();
    final nachher = vorher.nimmAnfrage(von, DateTime.now().toUtc());
    if (identical(vorher, nachher)) return;
    chats.speichereFernloeschung(nachher);
    if (vorher.faellig == null && nachher.faellig != null) {
      _fernloeschung.add(nachher);
    }
  }

  @override
  Future<Set<String>> zugestelltAn(String gruppe, String messageId) async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.zugestelltAn(gruppe, messageId);
  }

  /// Der Stand einer Gruppe, verkuendet vom Admin.
  ///
  /// EINE NEUE GRUPPE NUR VON EINEM KONTAKT. Sonst koennte jeder, der eine
  /// Adresse kennt, sie in beliebig viele Gruppen stecken — Werbung ohne
  /// Kontaktanfrage. Die eigene Adresse zaehlt als Kontakt: das Zweitgeraet
  /// uebernimmt Gruppen, die das erste angelegt hat.
  void _nimmGruppenStand(String von, Payload p, BitdmSignalStore store) {
    final chats = _chats!;
    final stand =
        Gruppe.lies(p.gruppe!, p.text, adresseTaugt: BitdmAddress.isValid);
    if (stand == null || stand.admin != von) return;
    final alt = chats.gruppe(stand.id);
    if (alt == null) {
      if (!stand.mitglieder.contains(myId)) return;
      if (von != myId && chats.kontakt(von)?.state != ContactState.active) {
        return;
      }
      chats.speichereGruppe(stand, store: store);
    } else {
      if (alt.admin != von || stand.version <= alt.version) return;
      chats.speichereGruppe(
          alt.copyWith(
            name: stand.name,
            mitglieder: stand.mitglieder,
            version: stand.version,
            aktiv: stand.mitglieder.contains(myId),
          ),
          store: store);
    }
    _gruppenWechsel.add(stand.id);
  }

  /// Jemand tritt aus. Das darf jeder nur fuer sich selbst — [von] ist
  /// gerechnet, nicht behauptet.
  void _nimmAustritt(String von, Payload p, BitdmSignalStore store) {
    final chats = _chats!;
    final g = chats.gruppe(p.gruppe!);
    if (g == null || !g.mitglieder.contains(von)) return;
    final rest = [...g.mitglieder]..remove(von);
    chats.speichereGruppe(
        g.copyWith(
          mitglieder: rest,
          // Ging der Admin, rueckt der Naechste nach — auf allen Geraeten
          // derselbe, siehe Gruppe.nachfolger.
          admin: von == g.admin ? Gruppe.nachfolger(g.mitglieder, von) : null,
          // Das eigene Zweitgeraet ist ausgetreten: dann dieses auch.
          aktiv: von == myId ? false : g.aktiv,
        ),
        store: store);
    _gruppenWechsel.add(g.id);
  }

  /// Eine Reaktion von [von] in der Unterhaltung [chat].
  void _nimmReaktion(
      String chat, String von, Payload p, BitdmSignalStore store) {
    if (_chats!.setzeReaktion(chat, p.refs.single, von, p.text, p.sentAt,
        store: store)) {
      _verlaufWechsel.add(chat);
    }
  }

  /// Neuer Text von [autor] fuer seine eigene Nachricht in [chat]. Die Regeln
  /// (nur eigene, Frist, Anzahl, Reihenfolge) stehen in
  /// ChatRepository.bearbeite — in der Abfrage, nicht davor.
  void _nimmBearbeitung(
      String chat, String autor, Payload p, BitdmSignalStore store) {
    // Dieselbe Grenze wie beim Absenden. Eine laengere Bearbeitung koennte
    // nur ein veraenderter Client schicken; sie haette nie eine Nachricht
    // werden duerfen und wird auch keine.
    if (utf8.encode(p.text).length > kMaxTextBytes) return;
    if (_chats!.bearbeite(chat, autor, p.refs.single, p.text, p.sentAt,
        hoechstens: kMaxBearbeitungen,
        frist: kBearbeitungsFrist,
        store: store)) {
      _verlaufWechsel.add(chat);
    }
  }

  /// "Fuer alle loeschen" von [autor] fuer seine eigene Nachricht in [chat].
  void _nimmWiderruf(
      String chat, String autor, Payload p, BitdmSignalStore store) {
    final weg = _chats!.widerrufe(chat, autor, p.refs.single, p.sentAt,
        frist: kWiderrufsFrist, store: store);
    if (weg == null) return;
    // Die Datei muss mit weg — eine "geloeschte" Nachricht, deren Anhang
    // weiter im Speicher liegt, waere dieselbe gebrochene Zusage wie bei der
    // Verfallsfrist.
    unawaited(_loescheDateien(weg.dateien));
    _verlaufWechsel.add(chat);
  }

  void _meldeAnfrage(String von) => _contacts.add(
    ContactEvent(
      type: ContactEventType.incomingRequest,
      contactId: von,
      at: DateTime.now().toUtc()));

  Future<void> _sendeQuittung(String an, String messageId) async {
    await Future<void>.delayed(quittungsVerzug());
    // ODER DIE NAEHE. Ohne den zweiten Teil bekaeme eine Nachricht, die ueber
    // Bluetooth hereinkam, nie ein Haekchen — obwohl der Rueckweg offensteht,
    // derselbe, auf dem sie gekommen ist.
    if (_conn != ConnectionState.online && !(_nah?.bereit ?? false)) return;
    try {
      await _sendePayload(
          an,
          Payload.control(PayloadKind.deliveryReceipt, _neueId(),
              DateTime.now().toUtc(),
              refs: [messageId]));
    } catch (_) {
      // Eine verlorene Quittung ist kein Fehler, der jemanden interessiert.
    }
  }

  void _bestaetigeKontakt(String von) {
    final chats = _chats!;
    final k = chats.kontakt(von);
    if (k == null || k.state == ContactState.active) return;
    chats.speichereKontakt(k.copyWith(state: ContactState.active));
    _contacts.add(ContactEvent(
        type: ContactEventType.requestAccepted,
        contactId: von,
        at: DateTime.now().toUtc()));
  }

  void _lehnteAb(String von) {
    _chats!.entferneKontakt(von);
    _contacts.add(ContactEvent(
        type: ContactEventType.requestDeclined,
        contactId: von,
        at: DateTime.now().toUtc()));
  }

  void _quittiere(String von, List<String> refs, MessageStatus status) {
    final chats = _chats!;
    for (final ref in refs) {
      final seq = chats.seqVon(von, ref, myId);
      if (seq == null) continue;
      if (status == MessageStatus.read) {
        chats.markiereGelesenBis(von, myId, seq);
      } else {
        chats.setzeStatus(von, myId, ref, status);
      }
      _status.add(MessageStatusUpdate(
          messageId: ref,
          chatId: von,
          status: status,
          at: DateTime.now().toUtc()));
    }
  }

  // ════════════════════════════════════════════════════════════════ Kontakte

  @override
  Future<List<Contact>> getContacts() async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.alleKontakte();
  }

  /// Schickt Kontaktanfragen nach, die beim ersten Mal nicht rausgingen.
  ///
  /// WARUM ES DAS BRAUCHT — und das war ein echter Ausfall, gemessen am
  /// 29.07.2026 auf zwei Telefonen:
  ///
  /// Eine Kontaktanfrage ist eine verschluesselte Nutzlast wie jede andere.
  /// Sie braucht also eine Signal-Sitzung, und die braucht das Buendel der
  /// Gegenseite vom Relay. Ist davon irgendetwas gerade nicht da — kein Netz,
  /// Relay im Neustart, die Gegenseite noch nicht angemeldet —, scheitert sie.
  ///
  /// Und dann war sie WEG. `addContact` warf sie mit `unawaited` ab, der
  /// Fehler verschwand darin, und weil eine Steuernutzlast keine eigene
  /// Nachricht ist, kam sie in keine Warteschlange. Kein zweiter Versuch, kein
  /// Hinweis — auf beiden Geraeten stand fuer immer "Request sent, waiting for
  /// confirmation", waehrend die Gegenseite nie etwas erfahren hatte.
  ///
  /// Der Nachversand fuer Nachrichten gibt es laengst; hier ist sein
  /// Gegenstueck. Ausgeloest beim Verbinden, denn genau dann ist der Grund
  /// weggefallen, an dem es beim ersten Mal lag.
  void _wiederholeKontaktanfragen() {
    final chats = _chats;
    if (chats == null) return;
    for (final k in chats.alleKontakte()) {
      if (k.state != ContactState.outgoingPending) continue;
      unawaited(_versucheZuSenden(
          k.id,
          Payload.control(
              PayloadKind.contactRequest, _neueId(), DateTime.now().toUtc())));
    }
  }

  @override
  Future<Contact> addContact(String address, {String? displayName}) async {
    if (_chats == null) throw const NotInitializedException();
    final adresse = BitdmAddress.normalize(address);
    if (!BitdmAddress.isValid(adresse)) {
      throw InvalidAddressException(address);
    }
    if (adresse == myId) {
      throw InvalidAddressException('$address (das ist die eigene Adresse)');
    }

    final vorhanden = _chats!.kontakt(adresse);
    if (vorhanden != null) return vorhanden;

    final kontakt = Contact(
      id: adresse,
      displayName: displayName,
      addedAt: DateTime.now().toUtc(),
      state: ContactState.outgoingPending,
    );
    _chats!.speichereKontakt(kontakt);
    // Er soll sich sofort finden lassen und nicht erst nach einem Neustart.
    // NICHT abgewartet: das Anlegen eines Kontakts darf nicht am Funk haengen.
    unawaited(_richteNaheEin());

    unawaited(_versucheZuSenden(adresse,
        Payload.control(PayloadKind.contactRequest, _neueId(),
            DateTime.now().toUtc())));
    return kontakt;
  }

  @override
  Future<void> acceptRequest(String contactId) async {
    final k = _fordereKontakt(contactId);
    _chats!.speichereKontakt(k.copyWith(state: ContactState.active));
    unawaited(_versucheZuSenden(contactId,
        Payload.control(PayloadKind.contactAccept, _neueId(),
            DateTime.now().toUtc())));
  }

  @override
  Future<void> declineRequest(String contactId) async {
    _fordereKontakt(contactId);
    unawaited(_versucheZuSenden(contactId,
        Payload.control(PayloadKind.contactDecline, _neueId(),
            DateTime.now().toUtc())));
    _chats!.entferneKontakt(contactId);
    // DASSELBE AUFRAEUMEN WIE IN removeContact, und aus demselben Grund.
    //
    // Eine Absage ist eine Entfernung — nur eine, die man nie bestaetigt hat.
    // Ohne diese zwei Zeilen liefe das Leuchtfeuer fuer jemanden weiter, den
    // man gerade weggeschickt hat: er saehe weiterhin, wann man im selben
    // Raum ist. Von allen Kontakten ist das der, bei dem es am wenigsten
    // hingehoert.
    //
    // Gefunden am 27.07.2026 von einem Widerlegungsagenten, nachdem die fuenf
    // beauftragten Befunde schon behoben waren.
    _nahGeheimnisse.remove(contactId);
    await _richteNaheEin();
  }

  @override
  Future<void> removeContact(String contactId) async {
    _fordereKontakt(contactId);
    final weg = _chats!.entferneKontakt(contactId);
    // Die Anhaenge dieser Unterhaltung mit. Sonst laege der Verlauf zwar nicht
    // mehr da, die Dateien aber schon — bei einem entfernten Kontakt das
    // Gegenteil dessen, was jemand damit bezweckt.
    await _loescheDateien(weg.dateien);
    // Die Sitzung mit abraeumen: bliebe sie stehen, liessen sich Nachrichten
    // dieser Gegenstelle weiterhin entschluesseln.
    await _store!.deleteAllSessions(contactId);
    _signalRepo!.commit(_store!);
    // Sein Geheimnis mit, sonst leuchtete der Kern fuer einen Kontakt weiter,
    // den es nicht mehr gibt — und ein entfernter Kontakt saehe, wo man ist.
    _nahGeheimnisse.remove(contactId);
    await _richteNaheEin();
  }

  @override
  Stream<ContactEvent> get contactEvents => _contacts.stream;

  /// Wie [_fordereKontakt], nimmt aber auch eine Gruppe. Fuer alle
  /// Nachrichten-Methoden, die in Einzel- und Gruppenchats gleich gehen.
  void _fordereChat(String id) {
    if (_istGruppe(id)) {
      if (_chats == null) throw const NotInitializedException();
      if (_chats!.gruppe(id) == null) throw UnknownContactException(id);
      return;
    }
    _fordereKontakt(id);
  }

  Contact _fordereKontakt(String id) {
    if (_chats == null) throw const NotInitializedException();
    final k = _chats!.kontakt(id);
    if (k == null) throw UnknownContactException(id);
    return k;
  }

  // ═════════════════════════════════════════════════════════════ Nachrichten

  @override
  Future<List<Message>> getMessages(String contactId,
      {int limit = 50, DateTime? before}) async {
    _fordereChat(contactId);
    int? beforeSeq;
    if (before != null) {
      final r = _db!.raw.select(
          'SELECT MIN(seq) s FROM messages WHERE chat_id=? AND sent_at >= ?',
          [contactId, before.toUtc().millisecondsSinceEpoch]);
      beforeSeq = r.isEmpty ? null : r.first['s'] as int?;
    }
    return _chats!.verlauf(contactId, limit: limit, beforeSeq: beforeSeq);
  }

  @override
  Future<Message> sendMessage(String contactId, String text,
      {String? antwortAuf, DateTime? um}) async {
    _fordereChat(contactId);
    final bytes = utf8.encode(text).length;
    if (bytes > kMaxTextBytes) {
      throw MessageTooLargeException(bytes, kMaxTextBytes);
    }
    final geplant = um != null && um.isAfter(DateTime.now());

    final nachricht = Message(
      id: _neueId(),
      chatId: contactId,
      senderId: myId,
      text: text,
      isMine: true,
      // Geplant heisst: verfasst "um" — sonst stuende sie bei der
      // Gegenstelle zwischen Nachrichten, die Stunden vor ihr kamen.
      timestamp: geplant ? um.toUtc() : DateTime.now().toUtc(),
      status: MessageStatus.sending,
      antwortAuf: antwortAuf,
      geplantFuer: geplant ? um.toUtc() : null,
    );
    // ERST speichern, DANN senden. Stuerzt die App zwischen beidem ab, steht
    // die Nachricht als unversandt in der Datenbank und wird beim naechsten
    // Verbinden wiederholt. Umgekehrt waere sie beim Empfaenger und hier
    // verschwunden.
    final frist = _fristFuer(contactId);
    _chats!.speichereEigene(nachricht, lebensdauer: frist);

    if (geplant) {
      _planeGeplante();
      return nachricht;
    }

    unawaited(_versucheZuSenden(
        contactId,
        Payload.text(nachricht.id, text, nachricht.timestamp,
            lebensdauer: frist, antwortAuf: antwortAuf),
        eigeneNachricht: nachricht.id));

    return nachricht;
  }

  @override
  Stream<String> get verlaufGeaendert => _verlaufWechsel.stream;

  Timer? _geplantWecker;

  /// Stellt den Wecker auf die naechste geplante Nachricht.
  ///
  /// EIN WECKER FUER ALLE, gestellt auf die fruehste. Klingelt er, schickt
  /// der gewoehnliche Nachversand, was faellig ist, und der Wecker wird auf
  /// die naechste gestellt. Ist die App zu dieser Zeit zu, holt das naechste
  /// Verbinden sie nach — derselbe Weg wie fuer jede liegengebliebene
  /// Nachricht.
  void _planeGeplante() {
    _geplantWecker?.cancel();
    final naechste = _chats?.naechsteGeplante();
    if (naechste == null) return;
    var warte = naechste.difference(DateTime.now().toUtc());
    if (warte.isNegative) warte = Duration.zero;
    _geplantWecker = Timer(warte + const Duration(milliseconds: 50), () {
      _stosseNachversandAn();
      _nachversandLauf.whenComplete(_planeGeplante);
    });
  }

  // ══════════════════════════════ Reaktionen, Bearbeiten, Loeschen, Suche

  @override
  Future<void> reagiere(
      String contactId, String messageId, String? zeichen) async {
    _fordereChat(contactId);
    final z = zeichen ?? '';
    if (utf8.encode(z).length > Payload.reaktionMaxBytes ||
        z.contains(RegExp(r'[\s\x00-\x1F]'))) {
      throw ArgumentError.value(zeichen, 'zeichen', 'keine taugliche Reaktion');
    }
    final jetzt = DateTime.now().toUtc();
    if (!_chats!.setzeReaktion(contactId, messageId, myId, z, jetzt)) {
      throw const BearbeitungNichtMoeglichException('keine solche Nachricht');
    }
    _verlaufWechsel.add(contactId);
    unawaited(_sendeSteuerung(
        contactId, Payload.reaktion(_neueId(), messageId, z, jetzt)));
  }

  @override
  Future<Map<String, Reaktionen>> getReaktionen(String contactId) async {
    _fordereChat(contactId);
    return _chats!.reaktionen(contactId);
  }

  @override
  Future<Message> bearbeite(
      String contactId, String messageId, String neuerText) async {
    _fordereChat(contactId);
    final bytes = utf8.encode(neuerText).length;
    if (bytes > kMaxTextBytes) {
      throw MessageTooLargeException(bytes, kMaxTextBytes);
    }
    if (neuerText.trim().isEmpty) {
      throw const BearbeitungNichtMoeglichException('leerer Text');
    }
    final jetzt = DateTime.now().toUtc();
    // DIESELBE ABFRAGE WIE BEIM EMPFAENGER. Was hier durchgeht, geht dort
    // durch — solange beide Uhren dieselbe sind, und das ist hier die eigene
    // auf beiden Seiten der Rechnung.
    final ging = _chats!.bearbeite(contactId, myId, messageId, neuerText, jetzt,
        hoechstens: kMaxBearbeitungen, frist: kBearbeitungsFrist);
    if (!ging) {
      throw const BearbeitungNichtMoeglichException('nicht bearbeitbar');
    }
    _verlaufWechsel.add(contactId);
    unawaited(_sendeSteuerung(contactId,
        Payload.bearbeitung(_neueId(), messageId, neuerText, jetzt)));
    return _chats!.nachricht(contactId, myId, messageId)!;
  }

  @override
  Future<void> widerrufe(String contactId, String messageId) async {
    _fordereChat(contactId);
    final jetzt = DateTime.now().toUtc();
    final weg = _chats!.widerrufe(contactId, myId, messageId, jetzt,
        frist: kWiderrufsFrist);
    if (weg == null) {
      throw const BearbeitungNichtMoeglichException('nicht widerrufbar');
    }
    unawaited(_loescheDateien(weg.dateien));
    _verlaufWechsel.add(contactId);
    unawaited(_sendeSteuerung(
        contactId, Payload.widerruf(_neueId(), messageId, jetzt)));
  }

  @override
  Future<Message> sendeUmfrage(String contactId, Umfrage umfrage,
      {String? antwortAuf}) async {
    _fordereChat(contactId);
    final text = umfrage.alsText();
    if (Umfrage.lies(text) == null) {
      throw ArgumentError.value(umfrage.frage, 'umfrage', 'taugt nicht');
    }
    final bytes = utf8.encode(text).length;
    if (bytes > kMaxTextBytes) {
      throw MessageTooLargeException(bytes, kMaxTextBytes);
    }
    final nachricht = Message(
      id: _neueId(),
      chatId: contactId,
      senderId: myId,
      text: text,
      kind: MessageKind.umfrage,
      isMine: true,
      timestamp: DateTime.now().toUtc(),
      status: MessageStatus.sending,
      antwortAuf: antwortAuf,
    );
    final frist = _fristFuer(contactId);
    _chats!.speichereEigene(nachricht, lebensdauer: frist);
    unawaited(_versucheZuSenden(
        contactId,
        Payload.umfrage(nachricht.id, text, nachricht.timestamp,
            lebensdauer: frist, antwortAuf: antwortAuf),
        eigeneNachricht: nachricht.id));
    return nachricht;
  }

  @override
  Future<void> stimme(
      String contactId, String umfrageId, List<int> auswahl) async {
    _fordereChat(contactId);
    final jetzt = DateTime.now().toUtc();
    if (!_chats!.setzeStimme(contactId, umfrageId, myId, auswahl, jetzt)) {
      throw const BearbeitungNichtMoeglichException('keine taugliche Stimme');
    }
    _verlaufWechsel.add(contactId);
    unawaited(_sendeSteuerung(
        contactId, Payload.stimme(_neueId(), umfrageId, auswahl, jetzt)));
  }

  @override
  Future<Map<String, Stimmen>> getStimmen(String contactId) async {
    _fordereChat(contactId);
    return _chats!.stimmen(contactId);
  }

  @override
  Future<void> hefteAn(String contactId, String messageId, bool an) async {
    _fordereChat(contactId);
    final jetzt = DateTime.now().toUtc();
    if (!_chats!.hefteAn(contactId, messageId, an, jetzt)) {
      throw const BearbeitungNichtMoeglichException('keine solche Nachricht');
    }
    _verlaufWechsel.add(contactId);
    unawaited(_sendeSteuerung(
        contactId, Payload.anheften(_neueId(), messageId, an, jetzt)));
  }

  @override
  Future<void> setzeStern(String contactId, String messageId, bool an) async {
    _fordereChat(contactId);
    if (!_chats!.setzeStern(contactId, messageId, an)) {
      throw const BearbeitungNichtMoeglichException('keine solche Nachricht');
    }
    // KEIN _sendeSteuerung: ein Stern ist eine Notiz fuer sich selbst.
    _verlaufWechsel.add(contactId);
  }

  @override
  Future<List<Verteiler>> getVerteiler() async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.verteiler();
  }

  @override
  Future<void> speichereVerteiler(List<Verteiler> liste) async {
    if (_chats == null) throw const NotInitializedException();
    _chats!.speichereVerteiler(liste);
  }

  @override
  Future<void> verbraucheEinmal(String contactId, String messageId) async {
    _fordereChat(contactId);
    final pfad = _chats!.verbraucheAnhang(contactId, messageId);
    if (pfad != null) await _loescheDateien([pfad]);
    _verlaufWechsel.add(contactId);
  }

  @override
  Future<Map<String, int>> ungelesenJeChat() async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.ungelesenJeChat();
  }

  @override
  Future<List<Message>> sterne() async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.sterne();
  }

  @override
  Future<void> loescheFuerMich(String contactId, String messageId) async {
    _fordereChat(contactId);
    final chats = _chats!;
    // BEIDE MOEGLICHEN ABSENDER. Die Kennung ist nur je Absender eindeutig;
    // welche von beiden gemeint ist, weiss die Oberflaeche, aber hier kommt
    // nur die Kennung an. Beide zu loeschen ist fuer ein oertliches Loeschen
    // harmlos — schlimmstenfalls faellt eine Nachricht weg, deren Kennung die
    // Gegenstelle absichtlich gleich gewaehlt hat.
    final weg = chats.loescheNachrichtJeder(contactId, messageId);
    unawaited(_loescheDateien(weg.dateien));
    _verlaufWechsel.add(contactId);
  }

  @override
  Future<List<Message>> suche(String text,
      {String? contactId, int limit = 100}) async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.suche(text, chatId: contactId, limit: limit);
  }

  @override
  Future<Uint8List> erstelleSicherung({bool mitDateien = false}) async {
    final chats = _chats;
    final entropie = await secretStore.read();
    if (chats == null || entropie == null) {
      throw const NotInitializedException();
    }
    final inhalt = chats.sicherungsInhalt();
    if (mitDateien) {
      // DIE DATEIEN SELBST — bis zur Grenze. Vorher standen nur die
      // Anleitungen darin, und die gehen nach 14 Tagen ins Leere.
      final dateien = <Map<String, Object?>>[];
      for (final a in chats.anhaengeFuerSicherung(Sicherung.dateienGrenze)) {
        final f = File(a.pfad!);
        if (!await f.exists()) continue;
        dateien.add({
          'chat_id': a.chatId,
          'sender_id': a.senderId,
          'message_id': a.messageId,
          'name': a.name,
          'daten': base64.encode(await f.readAsBytes()),
        });
      }
      inhalt['dateien'] = dateien;
    }
    return Sicherung.verpacke(inhalt, await Sicherung.schluessel(entropie));
  }

  @override
  Future<int> spieleSicherungEin(Uint8List daten) async {
    final chats = _chats;
    final entropie = await secretStore.read();
    if (chats == null || entropie == null) {
      throw const NotInitializedException();
    }
    final inhalt =
        await Sicherung.entpacke(daten, await Sicherung.schluessel(entropie));
    final neu = chats.spieleSicherungEin(inhalt);
    // Mitgesicherte Dateien zurueck in den Anhangordner — nur dort, wo der
    // Anhang hier noch nicht liegt.
    final dateien = inhalt['dateien'];
    if (dateien is List && dateien.isNotEmpty) {
      final ordner = Directory('${File(databasePath).parent.path}/anhaenge');
      await ordner.create(recursive: true);
      for (final d in dateien.whereType<Map>()) {
        try {
          final chat = d['chat_id'] as String;
          final absender = d['sender_id'] as String;
          final id = d['message_id'] as String;
          final vorhanden = chats.anhang(chat, absender, id);
          if (vorhanden == null || vorhanden.zustand == AnhangZustand.da || vorhanden.einmal) {
            continue;
          }
          final ziel = File('${ordner.path}/${AnhangEmpfang.sichererName(id)}_'
              '${AnhangEmpfang.sichererName(d['name'] as String)}');
          await ziel.writeAsBytes(base64.decode(d['daten'] as String), flush: true);
          chats.setzeAnhangZustand(chat, absender, id, AnhangZustand.da, pfad: ziel.path);
        } catch (_) {
          // Eine unlesbare Datei ist kein Grund, den Rest nicht einzuspielen.
        }
      }
    }
    // Neue Kontakte heissen neue Leuchtfeuer — derselbe Grund wie beim
    // Empfang (`_richteNaheEin` in _nimmUmschlag).
    unawaited(_richteNaheEin());
    return neu;
  }

  // ═════════════════════════════════════════════════════ Gruppen: Versand

  /// Schickt [p] eingepackt an jedes Mitglied und an die eigenen anderen
  /// Geraete.
  ///
  /// LIEGT, SOLANGE EINES LIEGT — und nur dann. `liegt` heisst "gerade kein
  /// Weg"; der Nachversand schickt dann an ALLE noch einmal, und wer sie
  /// schon hat, verwirft die Wiederholung am eindeutigen Index. Ein Mitglied,
  /// dessen Versand mit einem Fehler scheitert (Adresse beim Relay
  /// unbekannt), haelt die Nachricht NICHT fuer immer auf: sonst blockierte
  /// ein einziges geloeschtes Konto jede Nachricht der ganzen Gruppe.
  Future<Wegbescheid> _sendeAnGruppe(String gid, Payload p) async {
    final g = _chats?.gruppe(gid);
    final store = _store;
    if (g == null || store == null) {
      return const Wegbescheid(Weg.liegt, 'keine solche Gruppe');
    }
    if (!g.aktiv) return const Wegbescheid(Weg.relay, 'nicht mehr Mitglied');
    final huelle = Payload.inGruppe(gid, p);
    var liegt = false;
    var draussen = false;
    for (final m in g.mitglieder) {
      if (m == myId) continue;
      try {
        final b = await _sendePayload(m, huelle, spiegeln: false);
        if (b.weg == Weg.liegt) {
          liegt = true;
        } else {
          draussen = true;
        }
      } catch (_) {
        // Siehe oben: ein Fehler ist kein "liegt".
      }
    }
    if (_bekannteGeraete(store, myId).isNotEmpty) {
      try {
        await _sendePayload(myId, huelle, spiegeln: false);
      } catch (_) {}
    }
    if (liegt) return const Wegbescheid(Weg.liegt, 'ein Mitglied liegt');
    return Wegbescheid(Weg.relay, draussen ? 'an alle' : 'an niemanden erreichbar');
  }

  /// Verkuendet den Stand an alle Mitglieder (und an [auchAn], etwa an
  /// gerade Entfernte, damit sie es erfahren) — ueber den Ausgang, also auch
  /// ohne Verbindung zuverlaessig.
  void _verkuendeStand(Gruppe g, {List<String> auchAn = const []}) {
    final jetzt = DateTime.now().toUtc();
    final an = {...g.mitglieder, ...auchAn}..remove(myId);
    for (final m in an) {
      unawaited(_sendeSteuerung(
          m, Payload.gruppenStand(_neueId(), g.id, g.standText(), jetzt)));
    }
    // Das eigene Zweitgeraet: direkt, nicht ueber den Ausgang (der kennt die
    // eigene Adresse nur als Notizen und schickt dorthin nichts).
    final store = _store;
    if (store != null && _bekannteGeraete(store, myId).isNotEmpty) {
      unawaited(_sendePayload(
              myId, Payload.gruppenStand(_neueId(), g.id, g.standText(), jetzt),
              spiegeln: false)
          .catchError((Object _) => const Wegbescheid(Weg.liegt, '')));
    }
  }

  Gruppe _fordereGruppe(String id, {bool nurAdmin = false}) {
    final g = _chats?.gruppe(id);
    if (g == null) throw UnknownContactException(id);
    if (nurAdmin && g.admin != myId) {
      throw const BearbeitungNichtMoeglichException('nur der Admin');
    }
    if (!g.aktiv) {
      throw const BearbeitungNichtMoeglichException('nicht mehr Mitglied');
    }
    return g;
  }

  List<String> _pruefeNeue(List<String> neue, List<String> schon) {
    final aus = <String>[];
    for (final a in neue) {
      final k = _chats!.kontakt(a);
      if (a == myId || k == null || k.state != ContactState.active) {
        throw ArgumentError.value(a, 'mitglied', 'kein aktiver Kontakt');
      }
      if (!schon.contains(a) && !aus.contains(a)) aus.add(a);
    }
    return aus;
  }

  @override
  Stream<String> get gruppenGeaendert => _gruppenWechsel.stream;

  @override
  Future<List<Gruppe>> getGruppen() async {
    if (_chats == null) throw const NotInitializedException();
    return _chats!.alleGruppen();
  }

  @override
  Future<Gruppe> legeGruppeAn(String name, List<String> mitglieder) async {
    if (_chats == null) throw const NotInitializedException();
    final n = name.trim();
    if (n.isEmpty || n.length > Gruppe.maxName) {
      throw ArgumentError.value(name, 'name', 'leer oder zu lang');
    }
    final neue = _pruefeNeue(mitglieder, const []);
    if (neue.isEmpty || neue.length + 1 > Gruppe.maxMitglieder) {
      throw ArgumentError.value(
          mitglieder.length, 'mitglieder', '1 bis ${Gruppe.maxMitglieder - 1}');
    }
    final roh = Uint8List(16);
    for (var i = 0; i < roh.length; i++) {
      roh[i] = _zufall.nextInt(256);
    }
    final id = 'g-${base64Url.encode(roh).replaceAll('=', '')}';
    final g = Gruppe(id: id, name: n, admin: myId, mitglieder: [myId, ...neue]);
    _chats!.speichereGruppe(g);
    _verkuendeStand(g);
    _gruppenWechsel.add(id);
    return g;
  }

  @override
  Future<void> fuegeZuGruppeHinzu(String gruppeId, List<String> neue) async {
    final g = _fordereGruppe(gruppeId, nurAdmin: true);
    final dazu = _pruefeNeue(neue, g.mitglieder);
    if (dazu.isEmpty) return;
    if (g.mitglieder.length + dazu.length > Gruppe.maxMitglieder) {
      throw ArgumentError.value(dazu.length, 'neue', 'zu viele Mitglieder');
    }
    final neu =
        g.copyWith(mitglieder: [...g.mitglieder, ...dazu], version: g.version + 1);
    _chats!.speichereGruppe(neu);
    _verkuendeStand(neu);
    _gruppenWechsel.add(gruppeId);
  }

  @override
  Future<void> entferneAusGruppe(String gruppeId, String mitglied) async {
    final g = _fordereGruppe(gruppeId, nurAdmin: true);
    if (mitglied == myId || !g.mitglieder.contains(mitglied)) return;
    final neu = g.copyWith(
        mitglieder: [...g.mitglieder]..remove(mitglied), version: g.version + 1);
    _chats!.speichereGruppe(neu);
    // Der Entfernte bekommt den neuen Stand auch — sonst schriebe er weiter in
    // eine Gruppe, die ihn laengst verworfen hat, und wunderte sich.
    _verkuendeStand(neu, auchAn: [mitglied]);
    _gruppenWechsel.add(gruppeId);
  }

  @override
  Future<void> benenneGruppe(String gruppeId, String name) async {
    final g = _fordereGruppe(gruppeId, nurAdmin: true);
    final n = name.trim();
    if (n.isEmpty || n.length > Gruppe.maxName) {
      throw ArgumentError.value(name, 'name', 'leer oder zu lang');
    }
    final neu = g.copyWith(name: n, version: g.version + 1);
    _chats!.speichereGruppe(neu);
    _verkuendeStand(neu);
    _gruppenWechsel.add(gruppeId);
  }

  @override
  Future<void> verlasseGruppe(String gruppeId) async {
    final g = _fordereGruppe(gruppeId);
    final jetzt = DateTime.now().toUtc();
    for (final m in g.mitglieder) {
      if (m == myId) continue;
      unawaited(_sendeSteuerung(
          m, Payload.gruppenAustritt(_neueId(), gruppeId, jetzt)));
    }
    final store = _store;
    if (store != null && _bekannteGeraete(store, myId).isNotEmpty) {
      unawaited(_sendePayload(
              myId, Payload.gruppenAustritt(_neueId(), gruppeId, jetzt),
              spiegeln: false)
          .catchError((Object _) => const Wegbescheid(Weg.liegt, '')));
    }
    _chats!.speichereGruppe(g.copyWith(
        aktiv: false,
        admin: g.admin == myId ? Gruppe.nachfolger(g.mitglieder, myId) : null,
        mitglieder: [...g.mitglieder]..remove(myId)));
    _gruppenWechsel.add(gruppeId);
  }

  /// Die Frist, die fuer eine neue eigene Nachricht in [chat] gilt.
  ///
  /// EINE STELLE fuer Text, Anhang und Nachversand. Drei Stellen, die je
  /// selbst nachsehen, waeren drei Gelegenheiten, die Ausnahme zu vergessen
  /// — und eine vergessene Ausnahme hiesse hier: eine Nachricht, die bleibt,
  /// obwohl der Nutzer "loescht sich" eingestellt hat.
  Duration? _fristFuer(String chat) {
    final eigen = _istGruppe(chat)
        ? _chats?.gruppe(chat)?.fristSekunden
        : _chats?.kontakt(chat)?.fristSekunden;
    if (eigen == null) return _prefs.messageLifetime;
    return eigen == 0 ? null : Duration(seconds: eigen);
  }

  @override
  Stream<TippMeldung> get tippen => _tippen.stream;

  @override
  Future<void> meldeTippen(String contactId, bool tippt) async {
    final relay = _relay;
    final store = _store;
    if (!_prefs.tippAnzeige || _prefs.nurNahbereich) return;
    if (contactId == myId || _istGruppe(contactId)) return;
    if (relay == null || store == null || !relay.isConnected) return;
    if (!relay.kannFluechtig) return;
    if (_chats?.kontakt(contactId)?.state != ContactState.active) return;
    // NUR BESTEHENDE SITZUNGEN. Kein Buendelabruf und kein Auffrischen der
    // Geraeteliste: beides ginge an den Server, fuer eine Meldung, die in
    // drei Sekunden nichts mehr bedeutet.
    final ziele = _bekannteGeraete(store, contactId);
    if (ziele.isEmpty) return;
    final klar =
        Payload.tippt(_neueId(), tippt, DateTime.now().toUtc()).toBytes();
    try {
      for (final g in ziele) {
        final ct = await SessionCipher.fromStore(
                store, SignalProtocolAddress(contactId, g))
            .encrypt(klar);
        try {
          // Dieselbe Weiche wie in _RelayAusgang: Geraet 1 ohne `to_device`.
          await relay.sendeFluechtig(
              contactId, g == 1 ? null : g, Envelope.of(ct).toBytes());
        } catch (_) {
          // Verloren ist hier nichts, was jemand vermisst.
        }
      }
    } finally {
      // Der Ratchet ist weitergerueckt, auch fuer eine verworfene Meldung —
      // das muss auf die Platte, sonst verschluesselte die naechste
      // Nachricht mit einem schon benutzten Schluessel.
      _signalRepo!.commit(store);
    }
  }

  @override
  Future<String> oeffneNotizen() async {
    final chats = _chats;
    if (chats == null) throw const NotInitializedException();
    if (chats.kontakt(myId) == null) {
      chats.speichereKontakt(
          Contact(id: myId, addedAt: DateTime.now().toUtc()));
    }
    return myId;
  }

  /// Spiegelt eine Notiz an die eigenen anderen Geraete — NUR Text und
  /// Anhang. Kein Buendelabruf, aus demselben Grund wie in
  /// [_spiegleAnEigeneGeraete].
  Future<void> _spiegleNotiz(BitdmSignalStore store, Payload p) async {
    if (!_notizArten.contains(p.kind)) return;
    if (_bekannteGeraete(store, myId).isEmpty) return;
    try {
      await _sendePayload(myId, Payload.spiegel(myId, p), spiegeln: false);
    } catch (_) {
      // Eine Notiz, die das Tablet nicht erreicht, bleibt hier trotzdem.
    }
  }

  @override
  Future<void> setzeChatFrist(String contactId, Duration? frist) async {
    if (_istGruppe(contactId)) {
      final g = _chats?.gruppe(contactId);
      if (g == null) throw UnknownContactException(contactId);
      _chats!.speichereGruppe(g.copyWith(fristSekunden: frist?.inSeconds));
      _gruppenWechsel.add(contactId);
      return;
    }
    final k = _fordereKontakt(contactId);
    _chats!.speichereKontakt(k.copyWith(fristSekunden: frist?.inSeconds));
  }

  @override
  Future<void> setzeOrdnung(String contactId,
      {bool? angeheftet, bool? archiviert, bool? stumm}) async {
    if (_istGruppe(contactId)) {
      final g = _chats?.gruppe(contactId);
      if (g == null) throw UnknownContactException(contactId);
      _chats!.speichereGruppe(g.copyWith(
          angeheftet: angeheftet, archiviert: archiviert, stumm: stumm));
      _gruppenWechsel.add(contactId);
      return;
    }
    final k = _fordereKontakt(contactId);
    _chats!.speichereKontakt(k.copyWith(
        angeheftet: angeheftet, archiviert: archiviert, stumm: stumm));
  }

  /// Schickt eine Steuernachricht, die nicht verloren gehen darf.
  ///
  /// ERST IN DEN AUSGANG, DANN SENDEN — dieselbe Reihenfolge wie bei einer
  /// Textnachricht. Stuerzt die App dazwischen ab, holt der Nachversand sie.
  /// Alle drei Arten sind wiederholbar (eine Reaktion ersetzt sich selbst,
  /// eine Bearbeitung mit demselben Zeitstempel wird nicht zweimal
  /// uebernommen, ein Widerruf trifft kein zweites Mal), deshalb schadet es
  /// nicht, wenn sie bei einem mehrdeutigen Fehlschlag doppelt hinausgeht.
  Future<void> _sendeSteuerung(String an, Payload p) async {
    final chats = _chats;
    if (chats == null) return;
    // IN DEN NOTIZEN gibt es kein Gegenueber — aber die eigenen anderen
    // Geraete. Bis 25.09.2026 blieben Bearbeiten, Loeschen, Reaktion und
    // Anheften in den Notizen auf dem Geraet, auf dem sie passierten; jetzt
    // gehen sie als Spiegel mit, genau wie neue Notizen.
    if (an == myId) {
      final store = _store;
      if (store != null) await _spiegleNotiz(store, p);
      return;
    }
    final seq = chats.legeInAusgang(an, p.toBytes());
    await _versucheAusgang(seq, an, p);
  }

  Future<void> _versucheAusgang(int seq, String an, Payload p) async {
    try {
      final bescheid = _istGruppe(an)
          ? await _sendeAnGruppe(an, p)
          : await _sendePayload(an, p);
      if (bescheid.weg == Weg.liegt) return;
      _chats?.trageAusDemAusgang(seq);
    } catch (_) {
      // Bleibt im Ausgang; der naechste Nachversand versucht es wieder.
    }
  }

  @override
  Stream<Message> get incomingMessages => _incoming.stream;

  @override
  Stream<MessageStatusUpdate> get messageStatusUpdates => _status.stream;

  // ══════════════════════════════════════════════════════════════ Anhaenge

  @override
  Stream<AnhangFortschritt> get anhangFortschritt => _anhangStand.stream;

  @override
  Stream<AnhangEintrag> get anhangAenderungen => _anhangWechsel.stream;

  @override
  Future<Map<String, AnhangEintrag>> getAnhaenge(String contactId) async {
    _fordereChat(contactId);
    return _chats!.anhaenge(contactId);
  }

  @override
  Future<Message> sendeAnhang(String contactId, File datei,
      {String? name, int? groesse, bool einmal = false}) async {
    _fordereChat(contactId);

    // EIN ANHANG BRAUCHT DEN SERVER, und zwar zweimal: der Relay stellt die
    // Marke aus, das Lager nimmt die Stuecke. Beides faellt weg, wenn nur
    // ueber die Naehe gehen soll. Das ist kein Netzfehler, sondern eine Folge
    // der Einstellung — und die Oberflaeche muss etwas anderes dazu sagen als
    // "versuch es noch einmal".
    if (_prefs.nurNahbereich) {
      throw const NurNahbereichException();
    }

    // AUF DIE VERBINDUNG WARTEN, statt sofort abzubrechen.
    //
    // AM 26.07.2026 IM EMULATOR NACHGESTELLT: Anhaenge scheiterten mit
    // "RelayException — nicht verbunden", waehrend der Verbindungstest
    // unmittelbar daneben alles gruen meldete, den Weg ins Zwischenlager
    // eingeschlossen.
    //
    // Die Ursache ist die Dateiauswahl selbst. Sie gehoert Android und legt
    // sich VOR die App; BitDM zaehlt als weggelegt, trennt die Verbindung und
    // schaltet auf Hintergrundempfang. Kommt der Nutzer mit seiner Datei
    // zurueck, laeuft der Wiederaufbau noch — er dauert rund eine Sekunde,
    // ein Netzweg hin und zurueck. Der Versand griff genau in dieser Luecke
    // zu. Wer eine Datei auswaehlte, sorgte damit selbst dafuer, dass sie
    // nicht abgeschickt werden konnte.
    //
    // Deshalb wird hier gewartet und notfalls neu verbunden. Eine Nachricht
    // geht nicht verloren, nur weil die Leitung eine Sekunde lang stand.
    final relay = await _wartAufVerbindung();

    final id = _neueId();
    final angezeigt =
        AnhangEmpfang.sichererName(name ?? datei.uri.pathSegments.last);
    final wirklicheGroesse = groesse ?? await datei.length();

    // ERST in den Verlauf, DANN hochladen. Bei drei Gigabyte laeuft das
    // minutenlang; ohne Eintrag saehe der Nutzer waehrenddessen eine leere
    // Unterhaltung und wuesste nicht, ob ueberhaupt etwas passiert.
    //
    // Der Anhang steht dabei sofort auf "da" mit dem Pfad der QUELLDATEI: sie
    // liegt ja wirklich hier. Was noch laeuft, ist das Verschicken, und das
    // steht im Status der Nachricht — nicht zweimal an zwei Stellen.
    final nachricht = Message(
      id: id,
      chatId: contactId,
      senderId: myId,
      text: angezeigt,
      kind: MessageKind.anhang,
      isMine: true,
      timestamp: DateTime.now().toUtc(),
      status: MessageStatus.sending,
    );
    // EINE EIGENE KOPIE im Anhangordner — sonst zeigte "Oeffnen" beim eigenen
    // Anhang ins Leere: der Dateiwaehler reicht /proc/self/fd/<nr> herein,
    // und die Kennung ist nach dem Versand wieder zu (bis 25.09.2026 so).
    // Nur bis 50 MB, damit ein grosser Versand nicht den Platz verdoppelt,
    // und nie bei einer Einmal-Ansicht: die soll auch hier nicht liegen.
    String? eigenerPfad;
    if (!einmal && wirklicheGroesse <= 50 * 1024 * 1024) {
      try {
        final ordner = Directory('${File(databasePath).parent.path}/anhaenge');
        await ordner.create(recursive: true);
        final kopie = File('${ordner.path}/${AnhangEmpfang.sichererName(id)}_$angezeigt');
        await datei.copy(kopie.path);
        eigenerPfad = kopie.path;
      } catch (_) {
        eigenerPfad = null;
      }
    }
    final eintrag = AnhangEintrag(
      messageId: id,
      chatId: contactId,
      senderId: myId,
      name: angezeigt,
      groesse: wirklicheGroesse,
      zustand: AnhangZustand.da,
      pfad: eigenerPfad,
      einmal: einmal,
    );

    final versand = AnhangVersand(relay: relay, lager: _lager());
    final Rezept rezept;
    try {
      rezept = await versand.schicke(datei,
          name: angezeigt, groesse: wirklicheGroesse,
          fortschritt: (s) => _anhangStand.add(AnhangFortschritt(
                messageId: id,
                chatId: contactId,
                fertigeBytes: s.fertigeBytes,
                gesamtBytes: s.gesamtBytes,
              )));
    } catch (_) {
      // NICHTS IN DEN VERLAUF, wenn das Hochladen scheitert. Eine Nachricht
      // "Datei" ohne Datei dahinter waere beim Empfaenger nicht einzuloesen —
      // und hier eine, die aussieht, als waere sie unterwegs.
      rethrow;
    }

    final frist = _fristFuer(contactId);
    final anleitung = einmal ? rezept.alsEinmal() : rezept;
    _chats!.speichereEigene(nachricht,
        lebensdauer: frist,
        anhang: eintrag,
        rezept: anleitung.alsText());

    unawaited(_versucheZuSenden(
        contactId,
        Payload.anhang(id, anleitung.alsText(), nachricht.timestamp,
            lebensdauer: frist),
        eigeneNachricht: id));

    return nachricht;
  }

  @override
  Future<AnhangEintrag> holeAnhang(String contactId, String messageId) async {
    _fordereChat(contactId);
    final chats = _chats!;
    // UEBER DIE NACHRICHTENKENNUNG, NICHT UEBER DEN ABSENDER.
    //
    // `anhaenge(chatId)` ist genau die Karte, aus der die Oberflaeche den Knopf
    // zeichnet — und sie fragt nicht nach dem Absender. Hier stand `anhang(
    // contactId, contactId, ...)`, also fest die Adresse der Gegenstelle als
    // Absender. Ein GESPIEGELTER Anhang traegt aber `sender_id = myId`
    // (`_nimmSpiegel`): auf dem Zweitgeraet fand der Nachschlag nichts, der
    // Knopf blieb trotzdem stehen und warf bei jedem Tippen — obwohl die
    // vollstaendige Anleitung in derselben Zeile liegt.
    final eintrag = chats.anhaenge(contactId)[messageId];
    if (eintrag == null) {
      throw StateError('kein Anhang zu $messageId');
    }
    if (eintrag.zustand == AnhangZustand.da) return eintrag;

    // DERSELBE SCHALTER WIE BEIM VERSCHICKEN, und aus demselben Grund: die
    // Stuecke liegen im Zwischenlager, und das ist ein Server. Dass die
    // Ankuendigung ueber die Naehe hereinkam, aendert daran nichts — geholt
    // wird jetzt, und der Schalter gilt jetzt.
    //
    // ERST NACH DER ABKUERZUNG DARUEBER. Was schon auf dem Geraet liegt,
    // herauszugeben fasst nichts an; ein Schalter, der eine laengst geladene
    // Datei nicht mehr oeffnen liesse, verspraeche nichts, sondern naehme nur
    // etwas weg.
    if (_prefs.nurNahbereich) {
      throw const NurNahbereichException();
    }

    // DERSELBE ABSENDER WIE OBEN — er steht am Eintrag, und alle spaeteren
    // Zustandsschreiben ([_setzeAnhang]) nehmen ihn ebenfalls von dort.
    final text = chats.rezeptText(contactId, eintrag.senderId, messageId);
    if (text == null) throw StateError('keine Anleitung zu $messageId');
    final rezept = Rezept.ausText(text);

    _setzeAnhang(eintrag, AnhangZustand.laedt);

    // In den Anhangordner und NICHT in den allgemeinen Downloads-Ordner: was
    // hier liegt, gehoert zu einer Unterhaltung und verschwindet mit ihr.
    final ordner = Directory('${File(databasePath).parent.path}/anhaenge');
    await ordner.create(recursive: true);
    // BEIDE TEILE GESAEUBERT, obwohl payload.dart die Kennung schon prueft.
    // Der Name wurde beim Ablegen gesaeubert, die Kennung beim Empfang — aber
    // hier laufen sie zu einem PFAD zusammen, und ein Pfad ist die Stelle, an
    // der ein Fehler nicht wehtut, sondern ausbricht. Wer diese Zeile spaeter
    // mit einer Kennung aus einer anderen Quelle bedient, soll nicht darauf
    // angewiesen sein, dass zwei Dateien weiter oben jemand mitgedacht hat.
    final sicherId = AnhangEmpfang.sichererName(messageId);
    final ziel = File('${ordner.path}/${sicherId}_${eintrag.name}');

    try {
      final fertig = await AnhangEmpfang(lager: _lager()).hole(
        rezept,
        ziel,
        fortschritt: (s) => _anhangStand.add(AnhangFortschritt(
              messageId: messageId,
              chatId: contactId,
              fertigeBytes: s.fertigeBytes,
              gesamtBytes: s.gesamtBytes,
            )),
      );
      return _setzeAnhang(eintrag, AnhangZustand.da, pfad: fertig.path);
    } on LagerLeer {
      // EIGENER ZUSTAND und nicht "gescheitert": nach vierzehn Tagen ist der
      // Block weg, und wer ihn schon geholt hat, hat ihn selbst weggeworfen.
      // "Noch einmal versuchen" waere hier eine Luege.
      _setzeAnhang(eintrag, AnhangZustand.weg);
      rethrow;
    } catch (_) {
      _setzeAnhang(eintrag, AnhangZustand.gescheitert);
      rethrow;
    }
  }

  AnhangEintrag _setzeAnhang(AnhangEintrag e, AnhangZustand z, {String? pfad}) {
    _chats!.setzeAnhangZustand(e.chatId, e.senderId, e.messageId, z, pfad: pfad);
    final neu = e.copyWith(zustand: z, pfad: pfad);
    _anhangWechsel.add(neu);
    return neu;
  }

  LagerClient _lager() => _lagerClient ??= LagerClient(basis: lagerUri);

  Timer? _geraeuschTakt;

  /// Der naechste Tarnrahmen — in einem zufaelligen Abstand mit einem Mittel
  /// von 45 Sekunden (Exponentialverteilung: ohne erkennbaren Takt), solange
  /// verbunden und eingeschaltet.
  void _planeGeraeusch() {
    _geraeuschTakt?.cancel();
    _geraeuschTakt = null;
    if (!_prefs.tarnverkehr || _conn != ConnectionState.online) return;
    final u = 1 - _zufall.nextDouble();
    final ms = (-log(u) * 45000).clamp(4000, 180000).round();
    _geraeuschTakt = Timer(Duration(milliseconds: ms), () {
      if (_conn != ConnectionState.online) return;
      _relay?.sendeGeraeusch();
      _planeGeraeusch();
    });
  }

  /// Stellt den Weg aller Verbindungen nach der Einstellung "Tor".
  void _setzeNetzweg() {
    Netzweg.proxy = _prefs.tor ? SocksZiel('127.0.0.1', _prefs.torPort) : null;
    // Der Lager-Client haelt seinen HttpClient; er muss neu entstehen.
    _lagerClient = null;
  }

  /// relay.bitdm.net → dateien.bitdm.net, 127.0.0.1:8099 → 127.0.0.1:8099.
  ///
  /// Der zweite Fall ist der Testfall: dort laeuft beides auf demselben
  /// Rechner. In der Freigabe steht der Name ausdruecklich in der
  /// Einstellung — geraten wird nur, wenn nichts dasteht.
  static Uri lagerAdresse(Uri relay) {
    final host = relay.host;
    if (host.startsWith('relay.')) {
      return relay.replace(host: 'dateien.${host.substring(6)}');
    }
    return relay;
  }

  // ══════════════════════════════════════════════════════════ Einstellungen

  @override
  Future<AppPreferences> getPreferences() async {
    if (_chats == null) throw const NotInitializedException();
    return _prefs;
  }

  @override
  Future<void> setContactPresence(String contactId, bool zeigen) async {
    // `_fordereKontakt` wirft UnknownContactException und prueft zugleich, ob
    // ueberhaupt schon initialisiert wurde — derselbe Weg wie ueberall sonst
    // in dieser Datei.
    final kontakt = _fordereKontakt(contactId);
    if (kontakt.zeigtAnwesenheit == zeigen) return;
    _chats!.speichereKontakt(kontakt.copyWith(zeigtAnwesenheit: zeigen));

    // SOFORT WIRKSAM, nicht beim naechsten Start. Wer die Anwesenheit
    // abschaltet, will nicht mehr gesehen werden — und ein Leuchtfeuer, das
    // danach noch eine Viertelstunde weiterlaeuft, waere genau das, was er
    // gerade abgestellt hat.
    await _richteNaheEin();

    // KEIN ContactEvent. Der Strom traegt Anfragen, Zusagen, Absagen und
    // Entfernungen — Dinge, die von der GEGENSTELLE kommen. Eine eigene
    // Einstellung dort einzuwerfen hiesse, jeder Zuhoerer muesste kuenftig
    // unterscheiden, ob gerade jemand geantwortet hat oder ob man selbst
    // einen Schalter umgelegt hat. Die Oberflaeche weiss es ohnehin: sie hat
    // den Schalter umgelegt.
  }

  @override
  Future<void> setPreferences(AppPreferences prefs) async {
    if (_chats == null) throw const NotInitializedException();
    final vorher = _prefs.nurNahbereich;
    final vorherFunk = _prefs.naheAn;
    final vorherTor = (_prefs.tor, _prefs.torPort);
    _prefs = prefs;
    _chats!.speichereEinstellungen(prefs);
    _planeGeraeusch();

    // TOR SOFORT: die offene Verbindung laeuft noch auf dem alten Weg. Neu
    // verbinden, damit ab jetzt nichts mehr an Tor vorbei geht.
    if ((prefs.tor, prefs.torPort) != vorherTor) {
      _setzeNetzweg();
      if (!prefs.nurNahbereich) {
        await disconnect();
        await connect();
      }
    }

    // Nur beim WECHSEL. Ohne den Vergleich riefe jedes Speichern der
    // Einstellungen — auch das der Lesebestaetigungen — ein vollstaendiges
    // Neuaufsetzen hervor, und wer gerade in Reichweite ist, waere danach
    // wieder unbekannt.
    //
    // UND `await`, NICHT `unawaited`. Am 28.07.2026 habe ich das umgestellt,
    // weil eine Einstellung nicht an ihrer Folge haengen sollte — der Gedanke
    // stimmt, der Anlass war erfunden. Der Fehler, den es beheben sollte, gab
    // es nicht (`_setzeNaheAuf` faengt selbst ab), die Mutationsprobe zeigte
    // es, und der Umbau nahm dem Test "NIEMALS EIN SERVER" seine Wirkung: der
    // haelt den Kern genau hier fest, um zu messen, dass kein Buendel geholt
    // wird, WAEHREND ein Relay noch antworten wuerde.
    if (prefs.naheAn != vorherFunk) await _richteNaheEin();
    // Eine geaenderte Lebensdauer wirkt NUR auf Neues. Bestehende Nachrichten
    // behalten ihren Verfall — sonst wuerde Ausschalten Geglaubt-Geloeschtes
    // wieder auftauchen lassen und Einschalten stillschweigend Verlauf
    // vernichten.

    // SOFORT, NICHT BEIM NAECHSTEN START. Wer den Schalter umlegt, erwartet,
    // dass ab jetzt nichts mehr rausgeht — nicht ab dem naechsten Mal, wenn
    // er die App oeffnet. Eine offene Verbindung stehen zu lassen waere genau
    // die Sorte Halbwahrheit, gegen die dieser Schalter gebaut ist.
    if (prefs.nurNahbereich && !vorher) {
      await disconnect();
    } else if (!prefs.nurNahbereich && vorher) {
      await connect();
    }
  }

  @override
  Future<int> purgeExpiredMessages() async {
    if (_chats == null) return 0;
    final weg = _chats!.loescheAbgelaufene();
    await _loescheDateien(weg.dateien);
    return weg.nachrichten;
  }

  /// Loescht die lokalen Dateien verschwundener Anhaenge.
  ///
  /// OHNE DAS WAERE DIE VERFALLSFRIST EINE HALBWAHRHEIT: die Nachricht
  /// verschwaende aus der Unterhaltung, und die zwei Gigabyte laegen weiter im
  /// Speicher des Telefons. Wer glaubt, seine Nachrichten verschwinden,
  /// schreibt Dinge, die er sonst nicht schriebe.
  ///
  /// Fehler werden verschluckt: die Zeile in der Datenbank ist schon weg, und
  /// ein Datei-Fehler darf den Aufraeumlauf nicht anhalten.
  static Future<void> _loescheDateien(List<String> pfade) async {
    for (final p in pfade) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // absichtlich still
      }
    }
  }

  /// Wann die naechste Nachricht verfaellt — fuer einen Wecker statt Pollen.
  DateTime? get naechsterVerfall => _chats?.naechsterVerfall();

  @override
  Future<void> markRead(String contactId) async {
    _fordereChat(contactId);
    // ZUERST DIE EIGENE ZAHL, unabhaengig vom Schalter darunter: ob die
    // Gegenseite eine Lesebestaetigung bekommt, ist eine andere Frage als die,
    // ob hier noch ein Zaehler stehen soll.
    _chats?.merkeGelesen(contactId);

    // Der Schalter steuert jetzt wirklich etwas. Vorher wurde IMMER
    // quittiert, egal was in den Einstellungen stand.
    //
    // Aus heisst: die Gegenstelle sieht "zugestellt", aber nie "gelesen" —
    // und kann nicht unterscheiden, ob es abgeschaltet ist oder nur noch
    // niemand hingesehen hat. Genau darum geht es.
    if (!_prefs.readReceipts || contactId == myId || _istGruppe(contactId)) {
      return;
    }

    final ungelesen = _db!.raw.select(
        'SELECT id FROM messages WHERE chat_id=? AND is_mine=0 ORDER BY seq DESC LIMIT 1',
        [contactId]);
    if (ungelesen.isEmpty) return;
    final ref = ungelesen.first['id'] as String;
    // Verzoegert wie die Zustellquittung — siehe [quittungsVerzug]. Beim
    // Lesen verraet der Zeitpunkt, wann jemand die App offen hat.
    unawaited(Future<void>.delayed(quittungsVerzug()).then((_) async {
      if (_chats == null) return;
      await _versucheZuSenden(
          contactId,
          Payload.control(PayloadKind.readReceipt, _neueId(), DateTime.now().toUtc(),
              refs: [ref]));
    }));
  }

  /// Verschickt und meldet Fehler ueber den Status, nicht als Ausnahme.
  Future<void> _versucheZuSenden(String an, Payload p,
      {String? eigeneNachricht,
      bool schonBeimRelay = false,
      bool schonInDerNaehe = false}) async {
    // NOTIZEN: es gibt keinen Empfaenger. "Gesendet" heisst hier "gespeichert",
    // und hinaus geht nur ein Spiegel an die eigenen anderen Geraete. Ohne
    // diesen Zweig schickte der Kern die Notiz roh an die eigenen Geraete —
    // die verwerfen alles von der eigenen Adresse, was kein Spiegel ist —, und
    // die Nachricht stuende fuer immer auf "sending".
    if (an == myId) {
      final store = _store;
      if (eigeneNachricht != null) {
        _chats?.setzeStatus(an, myId, eigeneNachricht, MessageStatus.sent);
        _status.add(MessageStatusUpdate(
            messageId: eigeneNachricht,
            chatId: an,
            status: MessageStatus.sent,
            at: DateTime.now().toUtc()));
      }
      if (store != null) await _spiegleNotiz(store, p);
      return;
    }
    try {
      final bescheid = _istGruppe(an)
          ? await _sendeAnGruppe(an, p)
          : await _sendePayload(an, p,
              schonBeimRelay: schonBeimRelay,
              schonInDerNaehe: schonInDerNaehe);
      if (bescheid.weg == Weg.liegt) {
        // DER VERMERK GEHOERT AUF DIE PLATTE, BEVOR IRGENDETWAS ANDERES
        // PASSIERT. Er ist das Einzige, was Regel 2 ueber diesen Versuch
        // hinaus traegt: die Wegwahl lebt nur einen Versand lang, der naechste
        // Anlauf baut eine frische und waehlte ohne ihn wieder frei.
        //
        // Nur bei einer liegengebliebenen: bei einer, die draussen ist, liest
        // ihn nie jemand — `unversandt()` sieht nur, was auf "sending" steht.
        if (eigeneNachricht != null && bescheid.beimRelay && !schonBeimRelay) {
          _chats?.merkeBeimRelay(an, myId, eigeneNachricht);
        }
        // Und dasselbe fuer den anderen Weg. Symmetrisch, weil beide Wege
        // mehrdeutig scheitern koennen — die Naehe genauso wie der Relay: das
        // letzte Haeppchen kann bestaetigt drueben liegen, waehrend hier die
        // Verbindung schon weg ist.
        if (eigeneNachricht != null && bescheid.inDerNaehe && !schonInDerNaehe) {
          _chats?.merkeInDerNaehe(an, myId, eigeneNachricht);
        }
        _bleibtLiegen(an, eigeneNachricht);
        return;
      }
      if (eigeneNachricht != null) {
        // DAS ZEICHEN ENTSTEHT HIER und nirgends sonst: erst jetzt steht fest,
        // welchen Weg genau diese Nachricht genommen hat. Beim Anlegen war es
        // noch offen, und die Wegwahl kennt die Nachricht nicht.
        _chats!.setzeStatus(an, myId, eigeneNachricht, MessageStatus.sent,
            ueberNaehe: bescheid.weg == Weg.naehe);
        _status.add(MessageStatusUpdate(
            messageId: eigeneNachricht,
            chatId: an,
            status: MessageStatus.sent,
            at: DateTime.now().toUtc()));
      }
    } catch (_) {
      _bleibtLiegen(an, eigeneNachricht);
    }
  }

  /// Nichts ging raus — die Nachricht bleibt liegen.
  ///
  /// BEWUSST NICHT auf failed setzen: `sending` ist der Zustand, den
  /// _sendeUnversandtes wieder aufgreift. Wer hier failed schriebe, muesste den
  /// Nutzer bitten, von Hand zu wiederholen — obwohl die App es beim naechsten
  /// Verbinden selbst kann. Das ist Regel 4 aus wegwahl.dart, und sie gilt
  /// gleich, ob die Wegwahl `liegt` gesagt hat oder unterwegs etwas geworfen
  /// hat.
  void _bleibtLiegen(String an, String? eigeneNachricht) {
    if (eigeneNachricht == null) return;
    _status.add(MessageStatusUpdate(
        messageId: eigeneNachricht,
        chatId: an,
        status: MessageStatus.sending,
        at: DateTime.now().toUtc()));
  }

  /// Verschluesselt und gibt die Nachricht der Wegwahl.
  ///
  /// ═══════════════ WARUM DAS BUENDEL VOR DER WEGWAHL GEHOLT WIRD, UND MUSS
  ///
  /// Verschluesseln geht nur mit einer Sitzung, und die erste Sitzung mit
  /// jemandem entsteht aus seinem Prekey-Buendel. Das Buendel liegt beim
  /// Relay. Beides zusammen heisst: die Reihenfolge ist nicht frei waehlbar —
  /// erst Sitzung, dann Chiffretext, dann die Frage, worueber er hinausgeht.
  /// Der Weg kann also nicht entscheiden, ob ein Buendel geholt wird; das
  /// Buendel ist da schon geholt.
  ///
  /// DIE FALLE DABEI: mit "nur in der Naehe" ginge fuer die allererste
  /// Nachricht an einen neuen Kontakt trotzdem eine Anfrage an den Server —
  /// hinter dem Ruecken eines Schalters, der genau das ausschliesst.
  ///
  /// DIE LOESUNG IST DIE ZEILE UNTEN, und sie ist eine Absage, keine
  /// Umgehung: gibt es keine Sitzung und darf kein Server gefragt werden,
  /// bleibt die Nachricht liegen. Nicht "gescheitert" — sie geht hinaus,
  /// sobald der Schalter wieder aus ist. Ein Schluesselaustausch ueber die
  /// Naehe waere der ehrliche Ausweg; den gibt es noch nicht, und ihn hier
  /// vorzutaeuschen waere schlimmer als die Wartezeit.
  ///
  /// Wer schon einmal miteinander geschrieben hat, merkt davon nichts: die
  /// Sitzung steht, und ab da braucht kein Weg mehr einen Server.
  ///
  /// ═══════════════════════════ UND WARUM ES HIER EINE SCHLEIFE GEWORDEN IST
  ///
  /// Eine Signal-Sitzung ist eine Hashkette: jedes `encrypt` rueckt die
  /// Sendekette weiter, jedes `decrypt` wirft den benutzten Kettenschluessel
  /// weg. Zwei Geraete, die dieselbe Sitzung weiterrasten, senden zwei
  /// verschiedene Klartexte mit DEMSELBEN Zaehler — die Gegenstelle
  /// entschluesselt einen davon und kann den anderen nie wieder ableiten.
  /// Zusammenfuehren gibt es nicht; eine Hashkette hat genau eine gueltige
  /// Zukunft.
  ///
  /// Daraus folgt zwingend: eine Sitzung je GERAETEPAAR, und der Absender
  /// verschluesselt an JEDES Empfaengergeraet einzeln. Nicht als Vorsicht,
  /// sondern weil die Alternative stiller, dauerhafter Nachrichtenverlust ist.
  ///
  /// GENAU EINE STELLE, und das ist der Grund, warum sie hier steht und nicht
  /// in `sendMessage`: alle Versandwege laufen hier durch — Text, Anhang,
  /// Lesequittung, Empfangsquittung, Kontaktzusage und -absage. Deshalb liegt
  /// auch der Spiegel an die eigenen Geraete hier.
  Future<Wegbescheid> _sendePayload(
    String an,
    Payload p, {
    bool schonBeimRelay = false,
    bool schonInDerNaehe = false,
    bool spiegeln = true,
  }) async {
    final store = _store;
    if (store == null) throw const NotInitializedException();

    var ziele = _bekannteGeraete(store, an);

    if (ziele.isEmpty) {
      if (_prefs.nurNahbereich) {
        // ERST FRAGEN, DANN LIEGENLASSEN.
        //
        // Ohne Sitzung kann hier nichts verschluesselt werden, und das
        // Buendel dafuer kam bisher nur vom Relay — mit "nur in der Naehe"
        // also nie. Die Nachricht blieb fuer immer stehen, und der Nutzer sah
        // nur, dass nichts passiert.
        //
        // Jetzt geht eine Anfrage ueber den Funk hinaus. Sie kostet 7 Byte,
        // und wenn die Gegenseite in Reichweite ist, kommt das Buendel
        // zurueck; `_nimmBuendelUeberFunk` stoesst dann den Nachversand an
        // und dieselbe Nachricht geht beim naechsten Anlauf raus.
        //
        // NICHT WARTEN, sondern liegenlassen und wiederkommen: warten hiesse,
        // die Oberflaeche an eine Gegenstelle zu haengen, die vielleicht
        // gerade weggeht.
        final nahJetzt = _nah;
        if (nahJetzt != null && nahJetzt.inReichweite.contains(an)) {
          unawaited(nahJetzt
              .schickeSonder(an, Nahtyp.buendelAnfrage, Uint8List(0))
              .catchError((Object _) {}));
        }
        return const Wegbescheid(
            Weg.liegt,
            'nur in der Naehe, und mit diesem Kontakt gibt es noch keine '
            'Sitzung — das erste Buendel kaeme vom Server');
      }
      final relay = _relay;
      if (relay == null) throw const NotInitializedException();
      // DAS VOLLE BUENDEL BRINGT ALLE GERAETE AUF EINMAL, jedes mit eigenem
      // Einmalschluessel. Ein Abruf je Geraet waere derselbe Weg mehrmals.
      ziele = await _bauSitzungen(store, an, await relay.fetchBundle(an));
      _chats?.setzeGeraeteGeprueft(
        an,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      if (ziele.isEmpty) {
        // Die Adresse hat kein Geraet ausser unserem eigenen — bei der
        // eigenen Adresse der Normalfall, solange nur ein Telefon laeuft.
        return const Wegbescheid(
          Weg.liegt,
          'diese Adresse hat kein anderes Geraet',
        );
      }
    } else if (an != myId && !_prefs.nurNahbereich && _geraeteFaellig(an)) {
      // AUFFRISCHEN, ABER NIE AUF KOSTEN DES VERSANDS: schlaegt es fehl, geht
      // die Nachricht an die bekannten Geraete hinaus. Die eigene Adresse ist
      // ausgenommen — die frischt `connect()` auf, nicht das Fenster.
      ziele = await _frischeGeraeteAuf(store, an, ziele);
    }

    // EINMAL VERPACKT UND MEHRFACH VERSCHLUESSELT. `toBytes` fuellt auf 256er-
    // Bloecke auf und ist damit nicht umsonst; das Ergebnis ist fuer alle
    // Geraete dasselbe, nur die Verschluesselung unterscheidet sich.
    final klartext = p.toBytes();

    var ueberRelay = false;
    var ueberNaehe = false;
    // Hat AUCH NUR EIN Zielgeraet nichts bekommen? Siehe die Verdichtung unten.
    var einesLiegt = false;
    var beimRelay = schonBeimRelay;
    var inDerNaehe = schonInDerNaehe;
    final gruende = <String>[];

    try {
      for (final g in ziele) {
        final ziel = SignalProtocolAddress(an, g);
        final ct = await SessionCipher.fromStore(store, ziel).encrypt(klartext);
        final bescheid =
            await Wegwahl(
              relay: _RelayAusgang(_relay, g),
              // DER NAHBEREICH BLEIBT GERAET 1 — und zwar auf beiden Seiten,
              // siehe [_darfFunken]. Der Funkumschlag traegt kein
              // Absendergeraet, jede Funkzustellung landet bei der Gegenstelle
              // unter "adresse:1".
              naehe: g == 1
                  ? (_nah ?? const _KeinAusgang())
                  : const _KeinAusgang(),
              nurNahbereich: _prefs.nurNahbereich,
            ).schicke(
              an,
              Envelope.of(ct).toBytes(),
              schonBeimRelay: schonBeimRelay,
              // NUR FUER GERAET 1, weil nur es je ueber die Naehe erreichbar
              // war. `schonInDerNaehe` sperrt in der Wegwahl den RELAY —
              // gaebe man es allen Zielen mit, koennte eine Funkzustellung an
              // Geraet 1 die Nachricht fuer ALLE anderen Geraete dauerhaft
              // blockieren: sie bliebe liegen und faende nie wieder einen Weg.
              schonInDerNaehe: g == 1 && schonInDerNaehe,
            );

        // BEIDE MERKZETTEL WERDEN VER-ODERT. Sie schuetzen vor doppeltem Versand
        // ueber den jeweils anderen Weg und muessen im Zweifel `true` sein: hat
        // auch nur EIN Geraet den Umschlag moeglicherweise ueber den Relay
        // bekommen, darf die Wiederholung nicht ueber die Naehe gehen.
        beimRelay = beimRelay || bescheid.beimRelay;
        inDerNaehe = inDerNaehe || bescheid.inDerNaehe;
        ueberRelay = ueberRelay || bescheid.weg == Weg.relay;
        ueberNaehe = ueberNaehe || bescheid.weg == Weg.naehe;
        einesLiegt = einesLiegt || bescheid.weg == Weg.liegt;
        gruende.add('$g ${bescheid.grund}');

        // DER RELAY KENNT DIESES GERAET NICHT MEHR. Die Sitzung dazu ist damit
        // wertlos — sie stehen zu lassen hiesse, bei jeder weiteren Nachricht
        // erneut dagegen zu verschluesseln und erneut abgewiesen zu werden.
        if (bescheid.grund.contains(zielgeraetUnbekannt)) {
          await store.deleteSession(ziel);
          _chats?.setzeGeraeteGeprueft(an, 0);
        }
      }
    } finally {
      // EINMAL FESTSCHREIBEN, NACH DER SCHLEIFE. Fuenf Geraete bedeuten fuenf
      // fortgerueckte Sendeketten; sie einzeln zu schreiben waeren fuenf
      // Transaktionen fuer einen Vorgang, der als Ganzes gilt.
      //
      // UND IM `finally`, NICHT DAHINTER. Wirft die Verschluesselung fuer das
      // dritte Geraet, sind die ersten beiden Umschlaege schon draussen —
      // ihre Sendeketten sind weitergerueckt, und ohne dieses Festschreiben
      // faenge der naechste Anlauf mit veralteten Ketten an. Die Gegenstelle
      // saehe dann zwei Nachrichten mit demselben Zaehler und koennte die
      // zweite nie entschluesseln.
      _signalRepo!.commit(store);
    }

    // DRAUSSEN ERST, WENN JEDES ZIELGERAET ANGENOMMEN HAT.
    //
    // Hier stand "sobald EIN Geraet angenommen hat", begruendet mit "sonst
    // bliebe eine Nachricht stehen, nur weil das Tablet der Gegenstelle seit
    // Wochen aus ist". Das traegt nicht: ein abgeschaltetes Geraet erzeugt
    // beim Relay eine Warteschlangenzeile und ein `ack`, also KEIN `liegt`
    // (relay_server.py, Zustellung an einen nicht verbundenen Empfaenger).
    // `liegt` bedeutet immer einen echten Fehlschlag — Absage des Relays,
    // Abriss mitten im Fanout, abgelaufener Ack, kein Weg offen.
    //
    // Und ein Fehlschlag je Geraet war bisher unsichtbar: der Gesamtbescheid
    // wurde `relay`, `_versucheZuSenden` setzte MessageStatus.sent, und
    // `unversandt()` sieht nur `sending`. Das uebersprungene Geraet bekam die
    // Nachricht NIE, ohne Fehler und ohne Spur — genau der Verlust, gegen den
    // §10 den ganzen Entwurf begruendet.
    //
    // Der Preis ist eine Wiederholung an Geraete, die schon haben: die faengt
    // beim Empfaenger der eindeutige Index auf messages(chat_id, sender_id, id)
    // zusammen mit `INSERT OR IGNORE` ab (encrypted_database.dart,
    // chat_repository `_schreibeNachricht`). Eine Dublette, die niemand sieht,
    // ist billiger als eine Nachricht, die niemand bekommt.
    //
    // Der Relay hat Vorrang vor der Naehe: das Zeichen "kein Server war
    // beteiligt" darf nur dran, wenn wirklich keiner beteiligt war.
    final weg = einesLiegt
        ? Weg.liegt
        : ueberRelay
        ? Weg.relay
        : ueberNaehe
        ? Weg.naehe
        : Weg.liegt;
    final ergebnis = Wegbescheid(
      weg,
      gruende.join('; '),
      beimRelay: beimRelay,
      inDerNaehe: inDerNaehe,
    );

    if (spiegeln && weg != Weg.liegt) {
      await _spiegleAnEigeneGeraete(store, an, p);
    }
    return ergebnis;
  }

  /// Schickt eine Kopie dessen, was gerade hinausging, an die EIGENEN Geraete.
  ///
  /// ERST NACH DEM ORIGINAL, und nur wenn das Original draussen ist: sonst
  /// zeigte Geraet B eine Nachricht als versandt, die nie hinausging. Beim
  /// Nachversand geht beides zusammen hinaus, und der eindeutige Index auf
  /// messages(chat_id, sender_id, id) faengt die Wiederholung ab.
  ///
  /// NIE UEBER `sendMessage`: das ruft `_fordereKontakt(myId)`, und die eigene
  /// Adresse steht nicht in der Kontaktliste — es gaebe eine
  /// UnknownContactException fuer jede eigene Nachricht.
  ///
  /// FEHLER WERDEN GESCHLUCKT. Ein misslungener Spiegel darf die Nachricht,
  /// die schon bei der Gegenstelle liegt, nicht als liegengeblieben markieren.
  Future<void> _spiegleAnEigeneGeraete(
    BitdmSignalStore store,
    String an,
    Payload p,
  ) async {
    if (!_spiegelfaehig(p.kind) || an == myId) return;
    // NUR AN SCHON BEKANNTE EIGENE GERAETE. Gaebe es hier einen Buendelabruf,
    // kostete jede einzelne Nachricht einen EIGENEN Einmalschluessel — auch
    // bei jemandem, der nur ein Telefon hat und nie eines dazustellen wird.
    // Die eigenen Geraete lernt `connect()` kennen, und das kostet keinen.
    if (_bekannteGeraete(store, myId).isEmpty) return;
    try {
      await _sendePayload(myId, Payload.spiegel(an, p), spiegeln: false);
    } catch (_) {
      // Beim naechsten Nachversand noch einmal.
    }
  }

  /// Welche Arten gespiegelt werden.
  ///
  /// QUITTUNGEN NICHT: sie verdoppelten das Sendevolumen fuer eine
  /// Information, die das zweite Geraet selbst erzeugt, und ihr Empfaenger ist
  /// die Gegenstelle, nicht ich. Die Folge ist eine Grenze und kein Fehler:
  /// Haken- und Lesezustand sind je Geraet.
  ///
  /// UND `contactDecline` NICHT — abweichend von Spezifikation §5.2.
  ///
  /// HIER STAND EINE FALSCHE BEGRUENDUNG, korrigiert am 01.08.2026: sie
  /// behauptete die Kette `_nimmSpiegel` -> `_lehnteAb` ->
  /// `chat_repository.entferneKontakt`, also DELETE FROM anhaenge, messages,
  /// contacts. DIESE KETTE GIBT ES NICHT. `_nimmSpiegel` ruft `_lehnteAb`
  /// nirgends auf; der einzige Aufruf haengt am Zweig fuer FREMDE Absender in
  /// `_nimmUmschlag`. Wer die Schwere einer Regel falsch aufschreibt, laesst
  /// den naechsten entweder in Panik das Falsche bauen oder die Regel achselzuckend
  /// wieder herausnehmen.
  ///
  /// WAS WIRKLICH PASSIERT, wenn eine Absage gespiegelt wird: sie faellt in
  /// `_nimmSpiegel` in den Zweig darunter, und der setzt fuer alles, was keine
  /// Kontaktanfrage ist, `ContactState.active`. Ein eingeworfener alter
  /// Absage-Spiegel LEGT also einen Kontakt AN oder macht einen abgelehnten
  /// wieder aktiv — das Gegenteil dessen, was er bedeutet.
  ///
  /// Das ist kein Datenverlust, aber es ist eine Aussage ueber den Willen des
  /// Nutzers, die ein Dritter setzen kann: wer eine Adresse abgelehnt hat, darf
  /// sie nicht dadurch zurueckbekommen, dass jemand einen alten Umschlag
  /// aufhebt. Deshalb bleibt die Art ungespiegelt, UND `_nimmSpiegel` handelt
  /// nicht auf sie (fruehes return dort) — die zweite Haelfte ist die
  /// wichtigere, weil Spiegel aus der Zeit davor beim Relay liegen.
  static bool _spiegelfaehig(PayloadKind k) => switch (k) {
    PayloadKind.text ||
    PayloadKind.anhang ||
    PayloadKind.contactRequest ||
    PayloadKind.contactAccept ||
    // Was ich auf einem Geraet an einer Nachricht aendere, soll auf dem
    // anderen genauso aussehen — sonst stuende dort der alte Text neben der
    // neuen Fassung, die die Gegenstelle sieht.
    PayloadKind.reaktion ||
    PayloadKind.bearbeitung ||
    PayloadKind.widerruf ||
    PayloadKind.anheften ||
    PayloadKind.umfrage ||
    PayloadKind.stimme => true,
    PayloadKind.contactDecline ||
    PayloadKind.deliveryReceipt ||
    PayloadKind.readReceipt ||
    // Dass ich auf dem Telefon tippe, geht mein Tablet nichts an.
    PayloadKind.tippt ||
    // Gruppenpost erreicht das eigene Zweitgeraet schon als Mitglied
    // (_sendeAnGruppe schickt sie ausdruecklich auch dorthin) — ein Spiegel
    // obendrauf kaeme doppelt.
    PayloadKind.gruppe ||
    PayloadKind.gruppenStand ||
    PayloadKind.gruppenAustritt ||
    // Eine Loeschanfrage gilt EINEM Geraet des Besitzers; gespiegelt zaehlte
    // sie auf dessen anderen Geraeten ein zweites Mal.
    PayloadKind.loeschanfrage ||
    PayloadKind.spiegel => false,
  };

  /// Die Geraete, an die verschluesselt werden kann — aus dem Sitzungsspeicher.
  ///
  /// DIE EIGENE KENNUNG FAELLT HERAUS. `/prekey/<eigene Adresse>` enthaelt auch
  /// die eigene Geraetezeile; an sich selbst zu verschluesseln waere eine
  /// Sitzung mit dem eigenen Identitaetsschluessel auf beiden Seiten und
  /// erzeugte auf diesem Geraet eine Kopie jeder eigenen Nachricht.
  List<int> _bekannteGeraete(BitdmSignalStore store, String an) {
    final g = store.geraeteVon(an);
    if (an == myId) g.remove(geraetId);
    return g;
  }

  bool _geraeteFaellig(String an) {
    final zuletzt = _chats?.geraeteGeprueft(an) ?? 0;
    return DateTime.now().toUtc().millisecondsSinceEpoch - zuletzt >=
        geraeteFenster.inMilliseconds;
  }

  /// Baut fuer jedes Geraet der Antwort eine Sitzung und gibt ihre Kennungen.
  ///
  /// Eine schon bestehende Sitzung wird NICHT ersetzt: ein neuer Aufbau
  /// archiviert den alten Zustand (libsignal 0.8.2
  /// `session_builder.dart:139`), aber die Sendekette begaenne von vorn, und
  /// die Gegenstelle muesste den Wechsel erst mitbekommen. Fuer ein Geraet,
  /// mit dem wir schon reden, waere das Arbeit gegen den laufenden Betrieb.
  ///
  /// MEHR ALS EINE ZAHL WIRD BEI DER EIGENEN ADRESSE GEPRUEFT — siehe
  /// [_istEigenesBuendel]. Ein feindlicher Relay kann sonst ein Geraet
  /// erfinden und ihm UNSER EIGENES Schluesselmaterial unterschieben.
  Future<List<int>> _bauSitzungen(
    BitdmSignalStore store,
    String an,
    RelayBundleResponse antwort,
  ) async {
    final ziele = <int>[];
    // GEDECKELT, siehe [geraeteMax]. `alleGeraete` kommt vom Relay und ist
    // damit fremde Eingabe wie jede andere.
    final alle = antwort.alleGeraete;
    for (final b in alle.length <= geraeteMax
        ? alle
        : (alle.toList()..sort((x, y) => x.deviceId.compareTo(y.deviceId)))
            .take(geraeteMax)) {
      if (an == myId && b.deviceId == geraetId) continue;
      if (an == myId && await _istEigenesBuendel(store, b)) continue;
      final ziel = SignalProtocolAddress(an, b.deviceId);
      if (!await store.containsSession(ziel)) {
        await SessionBuilder.fromSignalStore(store, ziel).processPreKeyBundle(
          PreKeyBundleBridge.fromRelay(b, deviceId: b.deviceId),
        );
      }
      ziele.add(b.deviceId);
    }
    ziele.sort();
    return ziele;
  }

  /// Traegt dieses angebliche EIGENE Geraet unser eigenes Schluesselmaterial?
  ///
  /// ═══════════════════════════════ DER RIEGEL GEGEN DIE REFLEXION (§12.1)
  ///
  /// Bis hierher prueft der Sitzungsaufbau bei der eigenen Adresse nur eine
  /// ZAHL: `b.deviceId != geraetId`. Ein feindlicher Relay behauptet also
  /// einfach ein Geraet 7 und legt dort UNSER EIGENES signiertes Prekey-Paar
  /// hinein, kopiert aus unserer echten Zeile. Alles Weitere haelt: die
  /// Signatur des Prekeys ist echt (wir haben sie selbst erzeugt), und
  /// `isTrustedIdentity` rechnet die Adresse aus dem Schluessel nach — bei der
  /// EIGENEN Adresse passt der eigene Schluessel per Konstruktion.
  ///
  /// Danach steht eine Sitzung mit uns selbst. Sie ist der Einstieg: sie macht
  /// [_bekannteGeraete] fuer die eigene Adresse nichtleer, damit spiegelt jede
  /// Nachricht an dieses Phantom, und der Relay kann diese Spiegel spaeter
  /// beliebig oft zurueckwerfen — wir entschluesseln unsere eigenen Bytes, weil
  /// DH symmetrisch ist und der Identitaetsschluessel auf beiden Seiten
  /// derselbe.
  ///
  /// EIN FREMDES Buendel kann der Relay dafuer nicht nehmen: die Signatur des
  /// signierten Prekeys muesste gegen unseren Identitaetsschluessel aufgehen,
  /// und dessen privaten Teil hat er nicht. Uebrig bleibt genau unser eigener
  /// signierter Prekey — und den erkennen wir hier an seinen rohen Bytes.
  /// Legitim ist das nie: jede Installation wuerfelt ihren eigenen
  /// (libsignal `key_helper.dart` `generateSignedPreKey` -> `generateKeyPair`).
  Future<bool> _istEigenesBuendel(
      BitdmSignalStore store, RelayBundleResponse b) async {
    // ALLE EIGENEN, nicht nur der mit passender Nummer: die Nummer kommt vom
    // Relay und ist damit frei waehlbar, die Bytes sind es nicht.
    for (final id in store.state.signedPreKeys.keys) {
      final eigen = await store.loadSignedPreKey(id);
      if (base64.encode(eigen.getKeyPair().publicKey.serialize()) ==
          b.signedPreKey) {
        return true;
      }
    }
    return false;
  }

  /// Sieht nach, ob bei [an] Geraete dazugekommen sind. Best effort.
  ///
  /// ZUERST DIE BILLIGE FRAGE: `?nur_geraete=1` zieht keinen
  /// Einmalschluessel. Nur wenn dabei eine unbekannte Kennung auftaucht, wird
  /// das volle Buendel geholt — und das bringt dann gleich alle Geraete mit.
  Future<List<int>> _frischeGeraeteAuf(
    BitdmSignalStore store,
    String an,
    List<int> bekannt,
  ) async {
    final relay = _relay;
    if (relay == null || !relay.isConnected) return bekannt;
    final jetzt = DateTime.now().toUtc().millisecondsSinceEpoch;
    try {
      final liste = await relay.geraeteliste(an);
      // Ein Relay ohne die Erweiterung: es bleibt beim heutigen Verhalten,
      // und zwar OHNE Vermerk — sonst gaelte die Liste sechs Stunden lang als
      // geprueft, obwohl niemand geprueft hat.
      if (liste == null) return bekannt;
      if (liste.toSet().difference(bekannt.toSet()).isEmpty) {
        _chats?.setzeGeraeteGeprueft(an, jetzt);
        return bekannt;
      }
      // DER STEMPEL GEHOERT HINTER DEN SITZUNGSAUFBAU, nicht davor.
      //
      // Die Liste sagt nur, DASS ein Geraet dazugekommen ist; beliefern kann
      // man es erst, wenn seine Sitzung steht. Der zweite Abruf zieht ein
      // weiteres Token aus demselben IP-Eimer des Relays und kann mit 429
      // scheitern, ebenso durch ein Netzloch zwischen den beiden GETs.
      // Stempelte man vorher, gaelte die Frage sechs Stunden als beantwortet,
      // obwohl die Antwort ungenutzt verfiel — das neue Geraet der
      // Gegenstelle bliebe bis zu zwoelf statt der zugesagten sechs Stunden
      // unbeliefert (Spezifikation §4).
      final neu = await _bauSitzungen(store, an, await relay.fetchBundle(an));
      _chats?.setzeGeraeteGeprueft(an, jetzt);
      return neu.isEmpty ? bekannt : neu;
    } catch (_) {
      // KEIN VOLLER STEMPEL, ABER AUCH KEIN "SOFORT WIEDER": ohne jeden
      // Vermerk kostete ein dauerhaft scheiternder Abruf ZWEI /prekey-GETs je
      // gesendeter Nutzlast, Quittungen eingeschlossen. Der Stempel wird so
      // weit zurueckdatiert, dass [_geraeteFaellig] in
      // [geraeteWiederholung] wieder wahr wird.
      _chats?.setzeGeraeteGeprueft(
        an,
        jetzt - geraeteFenster.inMilliseconds + geraeteWiederholung.inMilliseconds,
      );
      return bekannt;
    }
  }

  /// Die eigenen anderen Geraete kennenlernen — nach jedem Verbinden.
  ///
  /// OHNE DAS GIBT ES KEINEN SPIEGEL: [_spiegleAnEigeneGeraete] holt bewusst
  /// kein Buendel, weil das jede einzelne Nachricht einen eigenen
  /// Einmalschluessel kosten wuerde. Die Sitzungen zu den eigenen Geraeten
  /// entstehen deshalb genau hier, einmal je Verbindung.
  Future<void> _frischeEigeneGeraeteAuf() async {
    final store = _store;
    final relay = _relay;
    if (store == null || relay == null) return;
    try {
      final liste = await relay.geraeteliste(myId);
      if (liste == null) return;
      _merkeGeraeteZahl(liste);
      final fremd = liste.where((g) => g != geraetId).toSet();
      if (fremd.difference(_bekannteGeraete(store, myId).toSet()).isEmpty) {
        return;
      }
      await _bauSitzungen(store, myId, await relay.fetchBundle(myId));
      _signalRepo!.commit(store);
      // Der Nachversand haengt am `whenComplete` in `connect()` — er laeuft in
      // JEDEM Ausgang dieser Methode, auch wenn sie hier oben umkehrt.
    } catch (_) {
      // Beim naechsten Verbinden erneut. Ein Spiegel ist eine Bequemlichkeit,
      // kein Zustellweg.
    }
  }

  /// Was beim Nachversand wirklich hinausgeht.
  ///
  /// ZWEI FEHLER SASSEN HIER, beide unsichtbar bis beim Empfaenger — gefunden
  /// von einem Suchagenten am 26.07.2026, nachdem sie monatelang niemandem
  /// aufgefallen waren.
  ///
  /// ERSTENS DIE ART. Es stand `Payload.text` fuer ALLES. Ein Anhang, der
  /// beim ersten Versuch liegengeblieben war, ging beim Nachversand als
  /// gewoehnliche Textnachricht hinaus: der Empfaenger bekam die Anleitung
  /// als sichtbaren Text in die Unterhaltung geschrieben statt eine Datei
  /// angeboten — und die Anleitung enthaelt die Kennungen und Schluessel
  /// aller Stuecke.
  ///
  /// ZWEITENS DIE FRIST. Ohne `lebensdauer` heisst "kein Verfall". Eine
  /// Nachricht mit eingestellter Frist, die nachversandt wurde, blieb beim
  /// Empfaenger FUER IMMER stehen, waehrend sie beim Absender verschwand.
  /// Genau die Sorte Halbwahrheit, gegen die die Frist gebaut ist.
  ///
  /// ALS EIGENE FUNKTION, weil eine Regel, die man nicht aufrufen kann, auch
  /// nicht geprueft werden kann: der erste Anlauf der Behebung stand mitten in
  /// der Schleife, und ein Mutationstest zeigte, dass kein einziger Test rot
  /// wurde, als man sie wieder zurueckdrehte.
  @visibleForTesting
  static Payload nachversand(Message m, Duration? frist) =>
      switch (m.kind) {
        MessageKind.anhang => Payload.anhang(m.id, m.text, m.timestamp,
            lebensdauer: frist, antwortAuf: m.antwortAuf),
        MessageKind.umfrage => Payload.umfrage(m.id, m.text, m.timestamp,
            lebensdauer: frist, antwortAuf: m.antwortAuf),
        MessageKind.text => Payload.text(m.id, m.text, m.timestamp,
            lebensdauer: frist, antwortAuf: m.antwortAuf),
      };

  /// Stellt einen Nachversand in die Reihe. Siehe [_nachversandLauf].
  ///
  /// ZWEI ANLAESSE, EIN WEG: die Verbindung steht wieder, oder jemand ist
  /// wieder in Reichweite. Beide muenden hier, damit sie sich nicht
  /// ueberholen — sonst laesen zwei Laeufe dieselbe Liste und schickten
  /// dieselbe Nachricht zweimal.
  void _stosseNachversandAn() {
    _nachversandLauf = _nachversandLauf
        .then((_) => _sendeUnversandtes())
        // Sonst bliebe die Kette vergiftet: jeder spaetere Nachversand haengte
        // sich an eine Zukunft, die schon mit einem Fehler abgeschlossen ist,
        // und liefe nie.
        .catchError((Object _) {});
  }

  /// Ob ueberhaupt noch ein Weg offen ist.
  ///
  /// Grob mit Absicht: welchen Weg eine EINZELNE Nachricht nimmt, entscheidet
  /// die Wegwahl. Hier geht es nur darum, eine Liste nicht gegen zwei
  /// geschlossene Tueren durchzuarbeiten.
  bool get _einWegOffen =>
      (_conn == ConnectionState.online && !_prefs.nurNahbereich) ||
      (_nah?.bereit ?? false);

  /// Holt nach, was beim letzten Mal nicht rausging.
  Future<void> _sendeUnversandtes() async {
    final chats = _chats;
    // Gesperrt oder geloescht, waehrend der Lauf in der Reihe stand.
    if (chats == null) return;

    for (final m in chats.unversandt()) {
      // NICHT MEHR NUR "IST DER RELAY ONLINE".
      //
      // Der Abbruch soll verhindern, dass der Rest der Liste gegen eine tote
      // Leitung laeuft. Mit "nur in der Naehe" ist die Leitung IMMER tot, und
      // die Schleife kehrte um, bevor sie das erste Mal etwas versucht hatte —
      // ausgerechnet in dem Modus, in dem die Naehe der einzige Weg ist. Eine
      // Nachricht blieb dort fuer immer auf "sending", auch wenn der
      // Empfaenger wieder danebenstand; von Hand nachhelfen konnte niemand,
      // MessageStatus.failed wird nirgends gesetzt.
      if (!_einWegOffen) return;

      // Die Entscheidung, WAS nachgeschickt wird, steht in [nachversand].
      // Womit es NICHT mehr gehen darf, steht an der Nachricht.
      await _versucheZuSenden(
          m.chatId, nachversand(m, _fristFuer(m.chatId)),
          eigeneNachricht: m.id,
          schonBeimRelay: m.schonBeimRelay,
          schonInDerNaehe: m.schonInDerNaehe);
    }

    // DER AUSGANG NACH DEN NACHRICHTEN, nicht davor: eine Reaktion oder
    // Bearbeitung kann sich auf eine Nachricht beziehen, die selbst noch
    // gerade nachgeschickt wird. Vor ihr angekommen, faende der Empfaenger
    // nichts, worauf sie zeigt, und verwuerfe sie.
    for (final a in chats.ausgang()) {
      if (!_einWegOffen) return;
      final Payload p;
      try {
        p = Payload.fromBytes(a.nutzlast);
      } on PayloadFormatException {
        // Von einer aelteren Fassung dieser App geschrieben und nicht mehr
        // lesbar. Liegenlassen hiesse, es bei jedem Verbinden erneut zu
        // versuchen — fuer immer.
        chats.trageAusDemAusgang(a.seq);
        continue;
      }
      await _versucheAusgang(a.seq, a.chatId, p);
    }
  }

  // ══════════════════════════════════════════════════════════════ Pruefnummer

  @override
  Future<SafetyNumber> getSafetyNumber(String contactId) async {
    _fordereKontakt(contactId);
    final store = _store!;
    // DIE 1 BLEIBT, UND SIE IST HIER KEINE GERAETEANGABE. `getIdentity` liest
    // `_state.identities[address.getName()]` (signal_store.dart) — die
    // Geraetenummer wird verworfen, dasselbe gilt fuer `isTrustedIdentity` und
    // `saveIdentity`. Identitaeten liegen je ADRESSE, Sitzungen je
    // GERAETEPAAR, und genau diese Aufteilung ist fuer Mehrgeraete die
    // richtige: die Pruefnummer haengt am Identitaetsschluessel und aendert
    // sich nicht, wenn die Gegenstelle ein zweites Telefon dazustellt.
    final fremd = await store.getIdentity(SignalProtocolAddress(contactId, 1));
    if (fremd == null) {
      throw UnknownContactException(
          '$contactId (noch keine Sitzung — erst eine Nachricht austauschen)');
    }

    final eigen = SignalIdentityBridge.rawPublicKeyOf(
        store.identity.keyPair.getPublicKey());
    final andere = SignalIdentityBridge.rawPublicKeyOf(fremd);

    final a = _fingerabdruck(eigen, myId);
    final b = _fingerabdruck(andere, contactId);
    // Sortiert, damit beide Seiten dieselbe Nummer sehen — sonst waere der
    // Vergleich am Telefon sinnlos.
    final digits = (a.compareTo(b) <= 0) ? '$a$b' : '$b$a';

    return SafetyNumber(
      contactId: contactId,
      digits: digits,
      qrPayload: base64.encode([...eigen, ...andere]),
    );
  }

  /// Signals Verfahren: 5200-mal SHA-512 ueber Schluessel und Adresse.
  ///
  /// Die vielen Durchgaenge sind kein Zierrat. Ohne sie koennte jemand
  /// Schluessel durchprobieren, bis einer eine Pruefnummer ergibt, die der
  /// echten aehnlich genug sieht, um beim Vorlesen durchzugehen. Mit 5200
  /// Durchgaengen kostet jeder Versuch so viel, dass sich das nicht lohnt.
  static const int _fingerabdruckRunden = 5200;

  static String _fingerabdruck(Uint8List schluessel, String adresse) {
    const sha = DartSha512();
    // Fassung 0, dann Schluessel, dann Adresse — wie in Signals
    // NumericFingerprintGenerator.
    final anhang = <int>[
      ...[0x00, 0x00],
      ...schluessel,
      ...utf8.encode(adresse),
    ];
    var h = Uint8List.fromList(sha.hashSync(anhang).bytes);
    for (var i = 1; i < _fingerabdruckRunden; i++) {
      h = Uint8List.fromList(sha.hashSync([...h, ...schluessel]).bytes);
    }

    final sb = StringBuffer();
    for (var i = 0; i < 30; i += 5) {
      var n = 0;
      for (var j = 0; j < 5; j++) {
        n = (n << 8) | h[i + j];
      }
      sb.write((n % 100000).toString().padLeft(5, '0'));
    }
    return sb.toString();
  }

  @override
  Future<void> setVerified(String contactId, bool verified) async {
    final k = _fordereKontakt(contactId);
    _chats!.speichereKontakt(k.copyWith(verified: verified));
  }

  // ═════════════════════════════════════════════════════════════ Lebenszyklus

  String _neueId() {
    final b = List.generate(16, (_) => _zufall.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }

  /// Loescht Identitaet, Schluessel und Nachrichten — unwiderruflich.
  ///
  /// DIE REIHENFOLGE IST WICHTIG. Zuerst die Entropie aus dem
  /// Schluesselspeicher, DANN die Datenbankdateien. Bricht es dazwischen ab
  /// (Akku leer, App abgeschossen), ist die Datenbank bereits unlesbar, weil
  /// ihr Schluessel aus genau dieser Entropie stammt. Andersherum bliebe im
  /// schlimmsten Fall eine loeschbare Datenbank mit noch vorhandenem
  /// Schluessel zurueck — also genau das, was hier verhindert werden soll.
  ///
  /// Dass die Bytes auf dem Flash-Speicher womoeglich noch physisch vorhanden
  /// sind, spielt deshalb keine Rolle: ohne den Schluessel sind sie Rauschen.
  @override
  Future<void> wipeEverything() async {
    await _raeumeVerbindungAb();
    await _haltNahe();
    // Die Geheimnisse sind aus der Identitaet gerechnet, die gleich faellt.
    // Sie stehenzulassen hiesse, nach dem Loeschen im Arbeitsspeicher noch
    // Werte zu haben, mit denen sich Kontakte wiedererkennen liessen.
    _nahGeheimnisse.clear();

    _db?.close();
    _db = null;
    _store = null;
    _chats = null;
    _signalRepo = null;

    // DIE ENTSCHLUESSELTEN ANHAENGE ZUERST, und zwar BEVOR die Entropie faellt.
    //
    // Fuer die Datenbankdateien gilt "ohne Schluessel sind sie Rauschen" —
    // fuer diese hier gilt das GERADE NICHT. Ein heruntergeladener Anhang
    // liegt im Klartext; er haengt an keinem Schluessel, den man wegnehmen
    // koennte. Und weil mit der Datenbank auch die Spalte `pfad` verschwindet,
    // findet ihn hinterher kein Aufraeumlauf mehr — er laege dort fuer immer.
    //
    // Die Oberflaeche verspricht "Identitaet, Kontakte und Nachrichten sofort
    // und unwiderruflich loeschen". Der Anhang IST der Inhalt der Nachricht.
    try {
      final anhaenge =
          Directory('${File(databasePath).parent.path}/anhaenge');
      if (anhaenge.existsSync()) anhaenge.deleteSync(recursive: true);
    } on FileSystemException {
      // Weiter loeschen. Eine Datei, die sich nicht entfernen laesst, darf den
      // Rest nicht aufhalten — der Rest ist wichtiger.
    }

    await secretStore.delete();

    for (final endung in ['', '-wal', '-shm']) {
      final f = File('$databasePath$endung');
      try {
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException {
        // Die Datei bleibt vielleicht liegen — ohne Schluessel ist sie
        // wertlos. Kein Grund, den Loeschvorgang deswegen abzubrechen.
      }
    }

    _hatIdentitaet = false;
    _setzeVerbindung(ConnectionState.disconnected);
  }

  /// Hinterlegt beim Relay, wohin angestossen werden soll.
  ///
  /// Ohne Verbindung passiert NICHTS und es fliegt kein Fehler: ein Anstoss
  /// beschleunigt die Zustellung, er ist nie Voraussetzung dafuer. Wer hier
  /// wuerfe, machte den Verbindungsaufbau von etwas abhaengig, das auch
  /// fehlschlagen darf.
  @override
  Future<void> setPushEndpoint(String? endpoint) async {
    try {
      _relay?.setzePushEndpunkt(endpoint);
    } catch (_) {
      // Nicht verbunden. Beim naechsten Verbinden traegt die Oberflaeche ihn
      // erneut ein.
    }
  }

  /// Schliesst wieder ab, ohne etwas zu loeschen.
  ///
  /// Wichtig ist, WAS hier passiert: die Datenbankdatei wird geschlossen und
  /// die abgeleiteten Schluessel fallen aus dem Speicher. Eine Sperre, die nur
  /// den Bildschirm verdeckt, waere wertlos — die Datenbank laege weiter offen,
  /// und wer den Prozess lesen kann, kaeme daran vorbei.
  ///
  /// Die Verbindung zum Relay geht dabei mit. Das ist gewollt: solange die
  /// App zu ist, gibt es niemanden, der eine ankommende Nachricht
  /// entschluesseln koennte, und ein offener Draht waere nur ein Signal nach
  /// aussen, dass dieses Geraet gerade laeuft.
  @override
  Future<void> lock() async {
    await _raeumeVerbindungAb();
    // Der Funk geht mit, aus demselben Grund wie die Verbindung: solange die
    // App zu ist, koennte niemand eine ankommende Nachricht entschluesseln,
    // und ein weiterlaufendes Leuchtfeuer waere nur ein Signal nach aussen,
    // dass dieses Geraet gerade da ist.
    await _haltNahe();
    _db?.close();
    _db = null;
    _store = null;
    _chats = null;
    _signalRepo = null;
    // _hatIdentitaet bleibt stehen: es GIBT eine Identitaet, sie ist nur
    // gerade nicht zu haben. Die Oberflaeche unterscheidet daran den
    // Sperrbildschirm vom Onboarding.
    _setzeVerbindung(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    _geraeuschTakt?.cancel();
    await _raeumeVerbindungAb();
    await _nahAbo?.cancel();
    _nahAbo = null;
    await _nahPostAbo?.cancel();
    _nahPostAbo = null;
    await _nahDaAbo?.cancel();
    _nahDaAbo = null;
    await _nah?.dispose();
    _nah = null;
    _nahStand = null;
    _db?.close();
    _db = null;
    _store = null;
    _chats = null;
    _signalRepo = null;
    await _connCtl.close();
    await _incoming.close();
    await _status.close();
    await _contacts.close();
    _geplantWecker?.cancel();
    await _verlaufWechsel.close();
    await _tippen.close();
    await _gruppenWechsel.close();
  }
}


/// Der Relay als Ausgang fuer die Wegwahl — eine duenne Huelle, sonst nichts.
///
/// [bereit] ist die einzige Aussage, die hier wirklich getroffen wird, und sie
/// entscheidet, ob Regel 2 aus wegwahl.dart ueberhaupt greift: nur ein
/// begonnener Versuch kann doppelt zustellen. Deshalb steht hier
/// `isConnected` und nicht bloss "es gibt ein Objekt" — nach einem
/// Leitungsabriss bleibt der Client stehen, und wer ihn dann fuer benutzbar
/// hielte, verboete der Naehe fuer immer das Einspringen. Genau das, wofuer
/// sie gebaut ist.
class _RelayAusgang implements Ausgang {
  const _RelayAusgang(this._relay, this._geraet);

  final RelayClient? _relay;

  /// An welches Geraet der Adresse dieser Umschlag geht.
  final int _geraet;

  @override
  bool get bereit => _relay?.isConnected ?? false;

  @override
  Future<void> schicke(String an, Uint8List umschlag) => _geraet == 1
      // GERAET 1 GEHT UEBER DEN HEUTIGEN WEG, ohne `to_device` im Rahmen —
      // siehe RelayClient `geraeteKennung`. Das ist nicht nur
      // Rueckwaertsverträglichkeit: es ist auch der einzige Weg, der in den
      // Attrappen der bestehenden Tests existiert.
      ? _relay!.send(an, umschlag)
      : _relay!.sendeAnGeraet(an, _geraet, umschlag);
}

/// Kein Weg. Fuer die Naehe, solange sie nicht laeuft.
///
/// Lieber das als ein `null` in der Wegwahl: sie haette dann zwei Faelle zu
/// unterscheiden, wo es in Wirklichkeit nur einen gibt — dieser Weg ist nicht
/// benutzbar.
class _KeinAusgang implements Ausgang {
  const _KeinAusgang();

  @override
  bool get bereit => false;

  @override
  Future<void> schicke(String an, Uint8List umschlag) =>
      throw StateError('dieser Weg ist nie bereit');
}

/// Die Ansicht auf den Kern, die der Verbindungstest bekommt.
class _KernUmgebung implements TestUmgebung {
  _KernUmgebung(this._k);

  final RealMessengerCore _k;

  @override
  Uri get relay => _k.relayUri;
  @override
  Uri get lager => _k.lagerUri;
  @override
  String? get eigeneAdresse => _k.isInitialized ? _k.myId : null;
  @override
  RelayClient? get relayClient => _k._relay;
  @override
  bool get nurNahbereich => _k._prefs.nurNahbereich;

  @override
  bool get naheAn => _k._prefs.naheAn;

  /// LAEUFT er, nicht: soll er laufen.
  ///
  /// FRUEHER STAND HIER `_nahStand != null`, UND DAS WAR FALSCH. Ein leerer
  /// Stand ist nicht null: wird der Nahbereich mit leerer Kontaktliste
  /// aufgesetzt, kehrt sein `starte` sofort um (richtig so — eine Werbung aus
  /// reinen Fuellbytes waere Funkverkehr fuer nichts), und `_setzeNaheAuf`
  /// vermerkte trotzdem einen Stand. Die Diagnose meldete daraufhin "laeuft",
  /// waehrend nachweislich keine einzige Werbung auf Sendung ging.
  ///
  /// Am 27.07.2026 auf einem echten Geraet genau so beobachtet — und der
  /// Bildschirm, der den Fehler haette zeigen sollen, war es, der ihn
  /// verdeckt hat.
  ///
  /// Gefragt wird jetzt den, der es weiss: den Nahbereich selbst.
  @override
  bool get naheLaeuft => _k._nah?.laeuft == true;

  @override
  int get naheKontakte => _k._nah == null ? 0 : _k._nahKontakteZahl;

  @override
  int get naheInReichweite => _k._nah?.inReichweite.length ?? 0;

  @override
  HttpClient httpClient() => Netzweg.httpClient();

  /// EIN EIGENER CLIENT je Lauf und nicht der des Kerns: der Test wirft ihn
  /// am Ende weg, und ein laufender Anhang-Versand soll davon nichts merken.
  @override
  LagerClient lagerClient() => LagerClient(basis: _k.lagerUri);
}
