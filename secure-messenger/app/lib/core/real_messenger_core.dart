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
import 'net/envelope.dart';
import 'net/payload.dart';
import 'net/prekey_bundle_bridge.dart';
import 'net/relay_client.dart';
import 'secret_store.dart';
import 'store/chat_repository.dart';
import 'store/encrypted_database.dart';
import 'store/signal_store.dart';
import 'store/signal_store_repository.dart';

class RealMessengerCore implements MessengerCore {
  RealMessengerCore({
    required this.secretStore,
    required this.databasePath,
    required this.relayUri,
    Uri? lagerUri,
    RelayClient Function(Uri, SignalIdentity)? relayFactory,
  })  : lagerUri = lagerUri ?? lagerAdresse(relayUri),
        _relayFactory = relayFactory ??
            ((uri, id) => RelayClient(baseUri: uri, identity: id));

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

  /// Wie viele One-Time-Prekeys vorgehalten werden.
  ///
  /// Jeder erlaubt genau einen Sitzungsaufbau mit der zusaetzlichen
  /// Absicherung. Sind sie alle, funktioniert X3DH weiter, nur etwas
  /// schwaecher — deshalb ist ein leerer Vorrat kein Notfall, aber es soll
  /// nicht dauernd vorkommen.
  static const int preKeyVorrat = 100;
  static const int preKeyUntergrenze = 20;

  EncryptedDatabase? _db;
  SignalStoreRepository? _signalRepo;
  ChatRepository? _chats;
  BitdmSignalStore? _store;
  RelayClient? _relay;
  StreamSubscription<RelayEvent>? _relayAbo;

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
    if (_conn == ConnectionState.online ||
        _conn == ConnectionState.connecting) {
      return;
    }

    _setzeVerbindung(ConnectionState.connecting);
    final relay = _relayFactory(relayUri, store.identity);
    _relay = relay;

    try {
      await _meldeAnWennNoetig(relay);
      _relayAbo = relay.events.listen(_verarbeiteRelayEreignis);
      await relay.connect();
      _setzeVerbindung(ConnectionState.online);
      unawaited(_sendeUnversandtes());
    } catch (_) {
      // Vertragsregel: Netzwerkprobleme werden nicht geworfen.
      await _raeumeVerbindungAb();
      _setzeVerbindung(ConnectionState.error);
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
    if (gemeldet != null && int.tryParse(gemeldet) == store.preKeyCount) {
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
    _db!.transaction((raw) => raw.execute(
        'INSERT INTO meta (key, value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['relay_prekey_count', '${store.preKeyCount}']));
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

  // ═════════════════════════════════════════════════════════════════ Eingang

  Future<void> _verarbeiteEingang(RelayMessage roh) async {
    final store = _store!;
    final chats = _chats!;

    final Payload payload;
    try {
      final umschlag = Envelope.fromBytes(roh.ciphertext);
      final klar = await umschlag.decrypt(
          SessionCipher.fromStore(store, SignalProtocolAddress(roh.from, 1)));
      payload = Payload.fromBytes(klar);
    } catch (fehler) {
      _behandleEingangsfehler(fehler, roh.from);
      return;
    }

    switch (payload.kind) {
      case PayloadKind.text:
      case PayloadKind.contactRequest:
        _legeEingangAb(roh.from, payload);
      case PayloadKind.anhang:
        _legeAnhangAb(roh.from, payload);
      case PayloadKind.contactAccept:
        _bestaetigeKontakt(roh.from);
      case PayloadKind.contactDecline:
        _lehnteAb(roh.from);
      case PayloadKind.deliveryReceipt:
        _quittiere(roh.from, payload.refs, MessageStatus.delivered);
      case PayloadKind.readReceipt:
        _quittiere(roh.from, payload.refs, MessageStatus.read);
    }

    // Steuernachrichten legen nichts in den Verlauf, veraendern aber trotzdem
    // den Ratchet. Ohne diese Zeile bliebe der Fortschritt im Arbeitsspeicher.
    chats.speichereNurSitzung(store);
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

  void _legeEingangAb(String von, Payload p) {
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
  void _legeAnhangAb(String von, Payload p) {
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
    if (_conn != ConnectionState.online) return;
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
    final relay = _relay;
    if (relay == null || !relay.isConnected) {
      throw const RelayException('nicht verbunden');
    }

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

    final text = chats.rezeptText(contactId, contactId, messageId);
    if (text == null) throw StateError('keine Anleitung zu $messageId');
    final rezept = Rezept.ausText(text);

    _setzeAnhang(eintrag, AnhangZustand.laedt);

    // In den Anhangordner und NICHT in den allgemeinen Downloads-Ordner: was
    // hier liegt, gehoert zu einer Unterhaltung und verschwindet mit ihr.
    final ordner = Directory('${File(databasePath).parent.path}/anhaenge');
    await ordner.create(recursive: true);
    final ziel = File('${ordner.path}/${messageId}_${eintrag.name}');

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
  Future<void> setPreferences(AppPreferences prefs) async {
    if (_chats == null) throw const NotInitializedException();
    _prefs = prefs;
    _chats!.speichereEinstellungen(prefs);
    // Eine geaenderte Lebensdauer wirkt NUR auf Neues. Bestehende Nachrichten
    // behalten ihren Verfall — sonst wuerde Ausschalten Geglaubt-Geloeschtes
    // wieder auftauchen lassen und Einschalten stillschweigend Verlauf
    // vernichten.
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
      {String? eigeneNachricht}) async {
    try {
      await _sendePayload(an, p);
      if (eigeneNachricht != null) {
        _chats!.setzeStatus(an, myId, eigeneNachricht, MessageStatus.sent);
        _status.add(MessageStatusUpdate(
            messageId: eigeneNachricht,
            chatId: an,
            status: MessageStatus.sent,
            at: DateTime.now().toUtc()));
      }
    } catch (_) {
      if (eigeneNachricht != null) {
        // BEWUSST NICHT auf failed setzen: `sending` ist der Zustand, den
        // _sendeUnversandtes wieder aufgreift. Wer hier failed schriebe,
        // muesste den Nutzer bitten, von Hand zu wiederholen — obwohl die App
        // es beim naechsten Verbinden selbst kann.
        _status.add(MessageStatusUpdate(
            messageId: eigeneNachricht,
            chatId: an,
            status: MessageStatus.sending,
            at: DateTime.now().toUtc()));
      }
    }
  }

  Future<void> _sendePayload(String an, Payload p) async {
    final relay = _relay;
    if (relay == null) throw const NotInitializedException();
    final store = _store!;
    final ziel = SignalProtocolAddress(an, 1);

    if (!await store.containsSession(ziel)) {
      final antwort = await relay.fetchBundle(an);
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(antwort));
    }

    final ct = await SessionCipher.fromStore(store, ziel).encrypt(p.toBytes());
    _signalRepo!.commit(store);
    await relay.send(an, Envelope.of(ct).toBytes());
  }

  /// Holt nach, was beim letzten Mal nicht rausging.
  Future<void> _sendeUnversandtes() async {
    final offen = _chats!.unversandt();
    for (final m in offen) {
      if (_conn != ConnectionState.online) return;
      await _versucheZuSenden(
          m.chatId, Payload.text(m.id, m.text, m.timestamp),
          eigeneNachricht: m.id);
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

    _db?.close();
    _db = null;
    _store = null;
    _chats = null;
    _signalRepo = null;

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
