// fake_messenger_core.dart
//
// In-memory reference implementation of MessengerCore. NO crypto, NO network.
// This is the BEHAVIOURAL SPEC: RealMessengerCore must look like this from the
// UI's point of view (same call order, same streams, same timing feel).
//
// Person A develops the UI against this. Person B mirrors these behaviours.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'messenger_core.dart'; // re-exports models.dart + errors.dart

class FakeMessengerCore implements MessengerCore {
  // Demo addresses (placeholders). Real address ENCODING is Person B's call —
  // see DECISIONS.md ("Adressierungsmodell").
  static const _me = 'bitdmDEMOme2f7k9x3q4tvb8hrsj3nc5wdy6zfmq2lx';
  static const _c1 = 'bitdmDEMOalice7qp2m9x4tvb8hrsj3nc5wdy6zfmq2lx';
  static const _c2 = 'bitdmDEMObob4rb9nkm3jwd7xlp2qcv8hfy5ztb8vqd';
  static const _c3 = 'bitdmDEMOcarol9hc4lpm8xkv2wrt6ndb3jqy7fszm4kp';

  String _myId = '';
  bool _init = false;
  ConnectionState _conn = ConnectionState.disconnected;

  final _contacts = <String, Contact>{};
  final _msgs = <String, List<Message>>{};
  int _seq = 0;

  final _incoming = StreamController<Message>.broadcast();
  final _status = StreamController<MessageStatusUpdate>.broadcast();
  final _connCtl = StreamController<ConnectionState>.broadcast();
  final _contactCtl = StreamController<ContactEvent>.broadcast();
  final _anhangStandCtl = StreamController<AnhangFortschritt>.broadcast();
  final _anhangWechselCtl = StreamController<AnhangEintrag>.broadcast();

  /// chatId -> messageId -> Eintrag
  final _anhaenge = <String, Map<String, AnhangEintrag>>{};

  DateTime get _now => DateTime.now().toUtc();
  String _nextId() => 'm${_seq++}-${_now.microsecondsSinceEpoch}';

  @override
  bool get isInitialized => _init;

  @override
  String get myId {
    if (!_init) throw const NotInitializedException();
    return _myId;
  }

  @override
  bool get hasIdentity => _hasIdentity;

  /// Set this before [initialize] to simulate a returning user (identity
  /// already on the device) instead of a first launch.
  bool simulateExistingIdentity = false;

  bool _hasIdentity = false;
  List<String> _phrase = const [];

  @override
  Future<bool> initialize() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _hasIdentity = simulateExistingIdentity;
    if (_hasIdentity) {
      _phrase = _demoPhrase;
      _adoptIdentity();
    }
    return _hasIdentity;
  }

  @override
  Future<List<String>> createIdentity() async {
    if (_hasIdentity) {
      throw StateError('identity already exists — call initialize() first');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _phrase = _demoPhrase;
    _hasIdentity = true;
    _adoptIdentity();
    return List.unmodifiable(_phrase);
  }

  @override
  Future<String> restoreIdentity(List<String> words) async {
    if (_hasIdentity) {
      throw StateError('identity already exists — call initialize() first');
    }
    if (!isValidRecoveryPhrase(words)) {
      throw const InvalidRecoveryPhraseException();
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _phrase = List.of(words);
    _hasIdentity = true;
    _adoptIdentity();
    return _myId;
  }

  @override
  bool isValidRecoveryPhrase(List<String> words) {
    // The fake has no wordlist and no checksum — it only mimics the SHAPE of
    // the check so the UI can wire up live validation. The real core verifies
    // against the BIP39 wordlist and checksum.
    return words.length == kRecoveryPhraseWords &&
        words.every((w) => RegExp(r'^[a-z]{3,8}$').hasMatch(w));
  }

  @override
  Future<List<String>> getRecoveryPhrase() async {
    if (!_init) throw const NotInitializedException();
    return List.unmodifiable(_phrase);
  }

  /// Demo phrase — a real BIP39 phrase so the UI can be laid out against
  /// realistic word lengths. Never used for anything but display.
  static const _demoPhrase = [
    'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
    'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'about',
  ];

  /// Populates the demo state once an identity exists, whichever way it came.
  void _adoptIdentity() {
    _myId = _me;
    final t = _now;
    _contacts[_c1] = Contact(id: _c1, addedAt: t);
    _contacts[_c2] = Contact(id: _c2, addedAt: t);
    _msgs[_c1] = [
      Message(id: _nextId(), chatId: _c1, senderId: _c1, text: 'Did you get the file?', isMine: false, timestamp: t, status: MessageStatus.delivered),
      Message(id: _nextId(), chatId: _c1, senderId: _me, text: 'Yes, everything arrived.', isMine: true, timestamp: t, status: MessageStatus.read),
    ];
    _msgs[_c2] = [];
    _init = true;
  }

  @override
  bool isValidAddress(String address) {
    final a = address.trim().replaceAll(RegExp(r'[\s-]'), '');
    return a.length >= 24 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(a);
  }

  @override
  Future<void> connect() async {
    if (!_init) throw const NotInitializedException();
    _setConn(ConnectionState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _setConn(ConnectionState.online);
    // simulate an inbound contact request shortly after connecting
    Timer(const Duration(milliseconds: 900), () {
      if (_contactCtl.isClosed) return;
      _contacts[_c3] = Contact(id: _c3, addedAt: _now, state: ContactState.incomingPending);
      _contactCtl.add(ContactEvent(type: ContactEventType.incomingRequest, contactId: _c3, at: _now));
    });
  }

  void _setConn(ConnectionState c) {
    _conn = c;
    if (!_connCtl.isClosed) _connCtl.add(c);
  }

  @override
  Future<void> disconnect() async => _setConn(ConnectionState.disconnected);

  @override
  ConnectionState get connectionState => _conn;

  @override
  Stream<ConnectionState> get connectionStateChanges => _connCtl.stream;

  @override
  Future<List<Contact>> getContacts() async =>
      _contacts.values.toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  @override
  Future<Contact> addContact(String address, {String? displayName}) async {
    if (!_init) throw const NotInitializedException();
    if (!isValidAddress(address)) throw InvalidAddressException(address);
    final id = address.trim();
    final c = Contact(id: id, addedAt: _now, displayName: displayName, state: ContactState.outgoingPending);
    _contacts[id] = c;
    _msgs.putIfAbsent(id, () => []);
    // simulate the peer accepting after a moment
    Timer(const Duration(milliseconds: 1200), () {
      if (_contactCtl.isClosed || !_contacts.containsKey(id)) return;
      _contacts[id] = _contacts[id]!.copyWith(state: ContactState.active);
      _contactCtl.add(ContactEvent(type: ContactEventType.requestAccepted, contactId: id, at: _now));
    });
    return c;
  }

  @override
  Future<void> acceptRequest(String contactId) async {
    final c = _contacts[contactId];
    if (c == null) throw UnknownContactException(contactId);
    _contacts[contactId] = c.copyWith(state: ContactState.active);
    _msgs.putIfAbsent(contactId, () => []);
    _contactCtl.add(ContactEvent(type: ContactEventType.requestAccepted, contactId: contactId, at: _now));
  }

  @override
  Future<void> declineRequest(String contactId) async {
    _contacts.remove(contactId);
    _contactCtl.add(ContactEvent(type: ContactEventType.requestDeclined, contactId: contactId, at: _now));
  }

  @override
  Future<void> removeContact(String contactId) async {
    _contacts.remove(contactId);
    _msgs.remove(contactId);
    _contactCtl.add(ContactEvent(type: ContactEventType.removed, contactId: contactId, at: _now));
  }

  @override
  Stream<ContactEvent> get contactEvents => _contactCtl.stream;

  @override
  Future<List<Message>> getMessages(String contactId, {int limit = 50, DateTime? before}) async {
    if (!_contacts.containsKey(contactId)) throw UnknownContactException(contactId);
    final all = _msgs[contactId] ?? const <Message>[];
    return List<Message>.unmodifiable(all.length > limit ? all.sublist(all.length - limit) : all);
  }

  @override
  Future<Message> sendMessage(String contactId, String text) async {
    if (!_init) throw const NotInitializedException();
    if (!_contacts.containsKey(contactId)) throw UnknownContactException(contactId);
    final bytes = utf8.encode(text).length;
    if (bytes > kMaxTextBytes) throw MessageTooLargeException(bytes, kMaxTextBytes);
    final msg = Message(id: _nextId(), chatId: contactId, senderId: _myId, text: text, isMine: true, timestamp: _now, status: MessageStatus.sending);
    _msgs.putIfAbsent(contactId, () => []).add(msg);
    Timer(const Duration(milliseconds: 250), () => _emitStatus(contactId, msg.id, MessageStatus.sent));
    Timer(const Duration(milliseconds: 700), () => _emitStatus(contactId, msg.id, MessageStatus.delivered));
    // fake inbound auto-reply so the UI sees incomingMessages
    Timer(const Duration(milliseconds: 1100), () {
      if (_incoming.isClosed) return;
      final reply = Message(id: _nextId(), chatId: contactId, senderId: contactId, text: 'Understood.', isMine: false, timestamp: _now, status: MessageStatus.delivered);
      _msgs.putIfAbsent(contactId, () => []).add(reply);
      _incoming.add(reply);
    });
    return msg;
  }

  // ──────────────────────────────────────────────────────────── Anhaenge
  //
  // Der Entwurfskern legt hier NICHTS an und laedt NICHTS hoch — es gibt
  // weder Netz noch Lager. Was er nachbildet, ist das ZEITVERHALTEN: dass
  // Fortschritt in Schritten kommt und ein Zustandswechsel gemeldet wird.
  // Genau daran haengt die Oberflaeche.

  @override
  Stream<AnhangFortschritt> get anhangFortschritt => _anhangStandCtl.stream;

  @override
  Stream<AnhangEintrag> get anhangAenderungen => _anhangWechselCtl.stream;

  @override
  Future<Map<String, AnhangEintrag>> getAnhaenge(String contactId) async {
    if (!_init) throw const NotInitializedException();
    return Map.unmodifiable(_anhaenge[contactId] ?? const {});
  }

  @override
  Future<Message> sendeAnhang(String contactId, File datei,
      {String? name, int? groesse}) async {
    if (!_init) throw const NotInitializedException();
    if (!_contacts.containsKey(contactId)) {
      throw UnknownContactException(contactId);
    }
    final gr = groesse ?? await datei.length();
    final id = _nextId();
    final angezeigt = name ?? datei.uri.pathSegments.last;

    // In Schritten melden, nicht in einem Sprung. Ein Fortschrittsbalken, der
    // von 0 auf 100 springt, sieht in der Entwicklung richtig aus und auf dem
    // Geraet kaputt.
    for (var i = 1; i <= 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (_anhangStandCtl.isClosed) break;
      _anhangStandCtl.add(AnhangFortschritt(
          messageId: id,
          chatId: contactId,
          fertigeBytes: gr * i ~/ 5,
          gesamtBytes: gr));
    }

    final msg = Message(
        id: id,
        chatId: contactId,
        senderId: _myId,
        text: angezeigt,
        kind: MessageKind.anhang,
        isMine: true,
        timestamp: _now,
        status: MessageStatus.sending);
    _msgs.putIfAbsent(contactId, () => []).add(msg);
    _anhaenge.putIfAbsent(contactId, () => {})[id] = AnhangEintrag(
        messageId: id,
        chatId: contactId,
        senderId: _myId,
        name: angezeigt,
        groesse: gr,
        zustand: AnhangZustand.da,
        pfad: datei.path);
    Timer(const Duration(milliseconds: 250),
        () => _emitStatus(contactId, id, MessageStatus.sent));
    return msg;
  }

  @override
  Future<AnhangEintrag> holeAnhang(String contactId, String messageId) async {
    if (!_init) throw const NotInitializedException();
    final e = _anhaenge[contactId]?[messageId];
    if (e == null) throw StateError('kein Anhang zu $messageId');
    if (e.zustand == AnhangZustand.da) return e;

    _setzeAnhang(e.copyWith(zustand: AnhangZustand.laedt));
    for (var i = 1; i <= 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (_anhangStandCtl.isClosed) break;
      _anhangStandCtl.add(AnhangFortschritt(
          messageId: messageId,
          chatId: contactId,
          fertigeBytes: e.groesse * i ~/ 5,
          gesamtBytes: e.groesse));
    }
    return _setzeAnhang(
        e.copyWith(zustand: AnhangZustand.da, pfad: '/erfunden/${e.name}'));
  }

  AnhangEintrag _setzeAnhang(AnhangEintrag e) {
    _anhaenge.putIfAbsent(e.chatId, () => {})[e.messageId] = e;
    if (!_anhangWechselCtl.isClosed) _anhangWechselCtl.add(e);
    return e;
  }

  void _emitStatus(String chatId, String messageId, MessageStatus s) {
    if (_status.isClosed) return;
    final list = _msgs[chatId];
    if (list != null) {
      final i = list.indexWhere((m) => m.id == messageId);
      if (i >= 0) list[i] = list[i].copyWith(status: s);
    }
    _status.add(MessageStatusUpdate(messageId: messageId, chatId: chatId, status: s, at: _now));
  }

  @override
  Stream<Message> get incomingMessages => _incoming.stream;

  @override
  Stream<MessageStatusUpdate> get messageStatusUpdates => _status.stream;

  @override
  Future<void> markRead(String contactId) async {
    if (!_contacts.containsKey(contactId)) throw UnknownContactException(contactId);
    // no-op in the fake; RealMessengerCore would send a read receipt to the peer.
  }

  @override
  Future<SafetyNumber> getSafetyNumber(String contactId) async {
    if (!_contacts.containsKey(contactId)) throw UnknownContactException(contactId);
    // Deterministic 60-digit number from both ids. NOT cryptographic — demo only.
    final seed = ([_myId, contactId]..sort()).join('|');
    final sb = StringBuffer();
    var h = 0x811c9dc5;
    for (var i = 0; sb.length < 60; i++) {
      for (final code in utf8.encode('$seed$i')) {
        h = ((h ^ code) * 0x01000193) & 0xFFFFFFFF;
      }
      sb.write((h % 100000).toString().padLeft(5, '0'));
    }
    return SafetyNumber(contactId: contactId, digits: sb.toString().substring(0, 60), qrPayload: 'bitdm-sn:$seed');
  }

  @override
  Future<void> setVerified(String contactId, bool verified) async {
    final c = _contacts[contactId];
    if (c == null) throw UnknownContactException(contactId);
    _contacts[contactId] = c.copyWith(verified: verified);
  }

  AppPreferences _prefs = const AppPreferences();

  @override
  Future<AppPreferences> getPreferences() async => _prefs;

  @override
  Future<void> setPreferences(AppPreferences prefs) async => _prefs = prefs;

  @override
  Future<void> setContactPresence(String contactId, bool zeigen) async {
    final k = _contacts[contactId];
    if (k == null) throw UnknownContactException(contactId);
    _contacts[contactId] = k.copyWith(zeigtAnwesenheit: zeigen);
  }

  @override
  Future<int> purgeExpiredMessages() async => 0;

  @override
  Future<void> wipeEverything() async {
    _msgs.clear();
    _contacts.clear();
    _myId = '';
    _init = false;
    _hasIdentity = false;
    simulateExistingIdentity = false;
    _setConn(ConnectionState.disconnected);
  }

  /// Schliesst wieder ab, ohne etwas zu loeschen.
  ///
  /// Zuletzt hinterlegter Anstoss-Endpunkt. Im Entwurf gibt es keinen Relay,
  /// dem sich etwas sagen liesse — gemerkt wird er trotzdem, damit Tests
  /// nachsehen koennen, ob die Oberflaeche ihn ueberhaupt weiterreicht.
  String? pushEndpunkt;

  @override
  Future<void> setPushEndpoint(String? endpoint) async {
    pushEndpunkt = endpoint;
  }

  /// Im Entwurf gibt es keine Datenbank und keine Schluessel; nachgestellt
  /// wird nur der Zustand, auf den es der Oberflaeche ankommt: nicht mehr
  /// bereit, aber es GIBT eine Identitaet.
  @override
  Future<void> lock() async {
    _init = false;
    _setConn(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _incoming.close();
    await _status.close();
    await _connCtl.close();
    await _contactCtl.close();
    await _anhangStandCtl.close();
    await _anhangWechselCtl.close();
  }
}
