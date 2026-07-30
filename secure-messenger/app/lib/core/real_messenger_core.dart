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
import 'net/payload.dart';
import 'net/prekey_bundle_bridge.dart';
import 'net/relay_protocol.dart';
import 'net/relay_client.dart';
import 'secret_store.dart';
import 'store/chat_repository.dart';
import 'store/encrypted_database.dart';
import 'store/signal_store.dart';
import 'store/signal_store_repository.dart';
import 'store/sqlite_zugang.dart';
import 'verbindungstest.dart';

class RealMessengerCore implements MessengerCore {
  RealMessengerCore({
    required this.secretStore,
    required this.databasePath,
    required this.relayUri,
    Uri? lagerUri,
    RelayClient Function(Uri, SignalIdentity)? relayFactory,
    Nahbereich Function()? nahFactory,
  })  : lagerUri = lagerUri ?? lagerAdresse(relayUri),
        _relayFactory = relayFactory ??
            ((uri, id) => RelayClient(baseUri: uri, identity: id)),
        _nahFactory = nahFactory ?? (() => Nahbereich(funk: Nahfunk()));

  final SecretStore secretStore;
  final String databasePath;
  final Uri relayUri;

  /// Wo die grossen Anhaenge liegen.
  ///
  /// Wird aus [relayUri] abgeleitet, wenn nichts dasteht — aber NIE aus dem,
  /// was der Relay in seiner Antwort mitschickt. Sonst koennte ein
  /// uebernommener Relay die Uploads auf einen fremden Rechner umlenken.
  final Uri lagerUri;
  final RelayClient Function(Uri, SignalIdentity) _relayFactory;

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

  var _conn = ConnectionState.disconnected;

  AppPreferences _prefs = const AppPreferences();
  var _hatIdentitaet = false;

  final _connCtl = StreamController<ConnectionState>.broadcast();
  final _incoming = StreamController<Message>.broadcast();
  final _status = StreamController<MessageStatusUpdate>.broadcast();
  final _contacts = StreamController<ContactEvent>.broadcast();
  final _anhangStand = StreamController<AnhangFortschritt>.broadcast();
  final _anhangWechsel = StreamController<AnhangEintrag>.broadcast();
  final _zufall = Random.secure();

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

    _prefs = _chats!.ladeEinstellungen();
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
    final relay = _relayFactory(relayUri, store.identity);
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
      await _meldeAnWennNoetig(relay);
      if (ueberholt()) return _gibAuf(relay);

      _relayAbo = relay.events.listen(_verarbeiteRelayEreignis);
      await relay.connect();
      if (ueberholt()) return _gibAuf(relay);

      _setzeVerbindung(ConnectionState.online);
      _stosseNachversandAn();
      _wiederholeKontaktanfragen();
    } catch (_) {
      // Vertragsregel: Netzwerkprobleme werden nicht geworfen.
      //
      // Aber nur den EIGENEN Versuch abraeumen: wer inzwischen ueberholt
      // wurde, wuerde sonst den Zustand eines fremden, laufenden Versuchs auf
      // "Fehler" setzen.
      if (ueberholt()) return _gibAuf(relay);
      await _raeumeVerbindungAb();
      _setzeVerbindung(ConnectionState.error);
    }
  }

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

  Future<void> _meldeAn(RelayClient relay) async {
    final store = _store!;
    final spk = await store.loadSignedPreKey(store.state.signedPreKeys.keys.first);
    final otk = <PreKeyRecord>[];
    for (final id in store.state.preKeys.keys) {
      otk.add(await store.loadPreKey(id));
    }
    await relay.register(PreKeyBundleBridge.toRelay(
      identity: store.identity,
      signedPreKey: spk,
      oneTimePreKeys: otk,
    ));
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

  Future<void> _setzeNaheAuf() async {
    final store = _store;
    if (store == null || !_prefs.naheAn) {
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
          if (k.zeigtAnwesenheit)
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
    if (nah == null) return;

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

  Future<void> _verarbeiteNaheEingang(NahUmschlag u) => _nimmUmschlag(
        von: u.von,
        umschlag: u.umschlag,
        ueberNaehe: true,
        nachweisFuer: null,
      );

  Future<void> _nimmUmschlag({
    required String von,
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
      final klar = await huelle.decrypt(
          SessionCipher.fromStore(store, SignalProtocolAddress(von, 1)));
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
        _quittiere(von, payload.refs, MessageStatus.delivered);
      case PayloadKind.readReceipt:
        _quittiere(von, payload.refs, MessageStatus.read);
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

  void _legeEingangAb(String von, Payload p, bool ueberNaehe) {
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
      isMine: false,
      timestamp: p.sentAt,
      status: MessageStatus.delivered,
      ueberNaehe: ueberNaehe,
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
    );
    final eintrag = AnhangEintrag(
      messageId: p.messageId,
      chatId: von,
      senderId: von,
      name: name,
      groesse: rezept.gesamtGroesse,
      zustand: AnhangZustand.angekuendigt,
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

  void _meldeAnfrage(String von) => _contacts.add(ContactEvent(
      type: ContactEventType.incomingRequest,
      contactId: von,
      at: DateTime.now().toUtc()));

  Future<void> _sendeQuittung(String an, String messageId) async {
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
    _fordereKontakt(contactId);
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
  Future<Message> sendMessage(String contactId, String text) async {
    _fordereKontakt(contactId);
    final bytes = utf8.encode(text).length;
    if (bytes > kMaxTextBytes) {
      throw MessageTooLargeException(bytes, kMaxTextBytes);
    }

    final nachricht = Message(
      id: _neueId(),
      chatId: contactId,
      senderId: myId,
      text: text,
      isMine: true,
      timestamp: DateTime.now().toUtc(),
      status: MessageStatus.sending,
    );
    // ERST speichern, DANN senden. Stuerzt die App zwischen beidem ab, steht
    // die Nachricht als unversandt in der Datenbank und wird beim naechsten
    // Verbinden wiederholt. Umgekehrt waere sie beim Empfaenger und hier
    // verschwunden.
    _chats!.speichereEigene(nachricht, lebensdauer: _prefs.messageLifetime);

    unawaited(_versucheZuSenden(
        contactId,
        Payload.text(nachricht.id, text, nachricht.timestamp,
            lebensdauer: _prefs.messageLifetime),
        eigeneNachricht: nachricht.id));

    return nachricht;
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
    _fordereKontakt(contactId);
    return _chats!.anhaenge(contactId);
  }

  @override
  Future<Message> sendeAnhang(String contactId, File datei,
      {String? name, int? groesse}) async {
    _fordereKontakt(contactId);

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
    final eintrag = AnhangEintrag(
      messageId: id,
      chatId: contactId,
      senderId: myId,
      name: angezeigt,
      groesse: wirklicheGroesse,
      zustand: AnhangZustand.da,
      pfad: datei.path,
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

    _chats!.speichereEigene(nachricht,
        lebensdauer: _prefs.messageLifetime,
        anhang: eintrag,
        rezept: rezept.alsText());

    unawaited(_versucheZuSenden(
        contactId,
        Payload.anhang(id, rezept.alsText(), nachricht.timestamp,
            lebensdauer: _prefs.messageLifetime),
        eigeneNachricht: id));

    return nachricht;
  }

  @override
  Future<AnhangEintrag> holeAnhang(String contactId, String messageId) async {
    _fordereKontakt(contactId);
    final chats = _chats!;
    final eintrag = chats.anhang(contactId, contactId, messageId);
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

    final text = chats.rezeptText(contactId, contactId, messageId);
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
    _prefs = prefs;
    _chats!.speichereEinstellungen(prefs);

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
    _fordereKontakt(contactId);

    // Der Schalter steuert jetzt wirklich etwas. Vorher wurde IMMER
    // quittiert, egal was in den Einstellungen stand.
    //
    // Aus heisst: die Gegenstelle sieht "zugestellt", aber nie "gelesen" —
    // und kann nicht unterscheiden, ob es abgeschaltet ist oder nur noch
    // niemand hingesehen hat. Genau darum geht es.
    if (!_prefs.readReceipts) return;

    final ungelesen = _db!.raw.select(
        'SELECT id FROM messages WHERE chat_id=? AND is_mine=0 ORDER BY seq DESC LIMIT 1',
        [contactId]);
    if (ungelesen.isEmpty) return;
    unawaited(_versucheZuSenden(
        contactId,
        Payload.control(
            PayloadKind.readReceipt, _neueId(), DateTime.now().toUtc(),
            refs: [ungelesen.first['id'] as String])));
  }

  /// Verschickt und meldet Fehler ueber den Status, nicht als Ausnahme.
  Future<void> _versucheZuSenden(String an, Payload p,
      {String? eigeneNachricht,
      bool schonBeimRelay = false,
      bool schonInDerNaehe = false}) async {
    try {
      final bescheid =
          await _sendePayload(an, p,
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
  Future<Wegbescheid> _sendePayload(String an, Payload p,
      {bool schonBeimRelay = false, bool schonInDerNaehe = false}) async {
    final store = _store;
    if (store == null) throw const NotInitializedException();
    final ziel = SignalProtocolAddress(an, 1);

    if (!await store.containsSession(ziel)) {
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
      final antwort = await relay.fetchBundle(an);
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(antwort));
    }

    final ct = await SessionCipher.fromStore(store, ziel).encrypt(p.toBytes());
    _signalRepo!.commit(store);

    return Wegwahl(
      relay: _RelayAusgang(_relay),
      naehe: _nah ?? const _KeinAusgang(),
      nurNahbereich: _prefs.nurNahbereich,
    ).schicke(an, Envelope.of(ct).toBytes(),
        schonBeimRelay: schonBeimRelay, schonInDerNaehe: schonInDerNaehe);
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
      m.kind == MessageKind.anhang
          ? Payload.anhang(m.id, m.text, m.timestamp, lebensdauer: frist)
          : Payload.text(m.id, m.text, m.timestamp, lebensdauer: frist);

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
          m.chatId, nachversand(m, _prefs.messageLifetime),
          eigeneNachricht: m.id,
          schonBeimRelay: m.schonBeimRelay,
          schonInDerNaehe: m.schonInDerNaehe);
    }
  }

  // ══════════════════════════════════════════════════════════════ Pruefnummer

  @override
  Future<SafetyNumber> getSafetyNumber(String contactId) async {
    _fordereKontakt(contactId);
    final store = _store!;
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
  const _RelayAusgang(this._relay);

  final RelayClient? _relay;

  @override
  bool get bereit => _relay?.isConnected ?? false;

  @override
  Future<void> schicke(String an, Uint8List umschlag) =>
      _relay!.send(an, umschlag);
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
  HttpClient httpClient() => HttpClient();

  /// EIN EIGENER CLIENT je Lauf und nicht der des Kerns: der Test wirft ihn
  /// am Ende weg, und ein laufender Anhang-Versand soll davon nichts merken.
  @override
  LagerClient lagerClient() => LagerClient(basis: _k.lagerUri);
}
