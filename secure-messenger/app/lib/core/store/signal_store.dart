// signal_store.dart — die vier Speicher, die libsignal verlangt.
//
// ENTWURFSENTSCHEIDUNG: dieser Speicher schreibt NIE selbst in die Datenbank.
// Er arbeitet ausschliesslich im Arbeitsspeicher und merkt sich, was sich
// geaendert hat. Das Wegschreiben uebernimmt eine Schicht darueber, in genau
// EINER Transaktion.
//
// Der Grund liegt im Ablauf des Double Ratchet. Beim Entschluesseln einer
// einzigen Nachricht ruft libsignal mehrere Speicher nacheinander:
// Sitzung laden, Identitaet pruefen, Prekey lesen, Prekey loeschen, Sitzung
// zurueckschreiben. Wuerde jeder dieser Schritte einzeln committen, hinterliesse
// ein Absturz dazwischen einen halb fortgeschriebenen Zustand: der Prekey ist
// verbraucht, die Sitzung aber noch die alte. Die Gegenstelle glaubt dann an
// eine Sitzung, die auf diesem Geraet nicht existiert — und beide koennen sich
// nicht mehr erreichen, ohne dass ein Fehler gemeldet wurde.
//
// Alles oder nichts ist hier also keine Feinheit, sondern die Bedingung dafuer,
// dass eine Unterhaltung einen Absturz ueberlebt.

import 'dart:collection';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/address.dart';
import '../crypto/signal_identity.dart';

/// Welcher der vier Speicher sich geaendert hat — die Schicht darueber braucht
/// das, um gezielt zu schreiben statt alles.
enum StoreSection { identity, preKey, signedPreKey, session }

/// Zustand aller vier Speicher im Arbeitsspeicher.
///
/// Bewusst eine eigene Klasse und nicht vier lose Maps: die Transaktion oben
/// braucht einen einzigen Gegenstand, den sie festschreiben kann.
class SignalStoreState {
  final Map<String, Uint8List> identities;      // Adresse -> serialisierter IdentityKey
  final Map<int, Uint8List> preKeys;            // id -> serialisierter PreKeyRecord
  final Map<int, Uint8List> signedPreKeys;      // id -> serialisierter SignedPreKeyRecord
  final Map<String, Uint8List> sessions;        // Adresse -> serialisiertes SessionRecord

  SignalStoreState({
    Map<String, Uint8List>? identities,
    Map<int, Uint8List>? preKeys,
    Map<int, Uint8List>? signedPreKeys,
    Map<String, Uint8List>? sessions,
  })  : identities = identities ?? HashMap(),
        preKeys = preKeys ?? HashMap(),
        signedPreKeys = signedPreKeys ?? HashMap(),
        sessions = sessions ?? HashMap();

  SignalStoreState copy() => SignalStoreState(
        identities: HashMap.of(identities),
        preKeys: HashMap.of(preKeys),
        signedPreKeys: HashMap.of(signedPreKeys),
        sessions: HashMap.of(sessions),
      );
}

/// Wird geworfen, wenn ein Identitaetsschluessel nicht zu seiner Adresse passt.
///
/// Bei BitDM ist das ein Widerspruch in sich, kein Vertrauensproblem: die
/// Adresse WIRD aus dem Schluessel gebildet.
class AddressKeyMismatchException implements Exception {
  final String address;
  const AddressKeyMismatchException(this.address);
  @override
  String toString() =>
      'AddressKeyMismatchException: Schluessel passt nicht zur Adresse $address';
}

class BitdmSignalStore implements SignalProtocolStore {
  /// [state] ist der aus der Datenbank geladene Zustand. Ohne Angabe startet
  /// der Speicher leer — das ist der Fall bei einer frisch erzeugten Identitaet.
  BitdmSignalStore({
    required SignalIdentity identity,
    SignalStoreState? state,
  })  : _identity = identity,
        _state = state ?? SignalStoreState();

  // Der Analyzer schlaegt hier `required this._identity` vor. Das waere
  // schlechter: der benannte Parameter hiesse dann `_identity`, und Aufrufer
  // muessten einen Unterstrich schreiben. Die Zuweisung bleibt bewusst
  // ausgeschrieben.
  // ignore_for_file: prefer_initializing_formals

  final SignalIdentity _identity;
  final SignalStoreState _state;
  final Set<StoreSection> _dirty = <StoreSection>{};

  /// Welche Bereiche seit dem letzten Festschreiben veraendert wurden.
  Set<StoreSection> get dirtySections => Set.unmodifiable(_dirty);

  /// Ob ueberhaupt etwas zu schreiben waere.
  bool get isDirty => _dirty.isNotEmpty;

  /// Der aktuelle Zustand — fuer die Schicht, die ihn festschreibt.
  SignalStoreState get state => _state;

  /// Nach erfolgreichem Festschreiben aufzurufen.
  void markClean() => _dirty.clear();

  void _touch(StoreSection s) => _dirty.add(s);

  // ══════════════════════════════════════════════ IdentityKeyStore

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identity.keyPair;

  @override
  Future<int> getLocalRegistrationId() async => _identity.registrationId;

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final bytes = _state.identities[address.getName()];
    return bytes == null ? null : IdentityKey.fromBytes(bytes, 0);
  }

  /// Prueft, ob dieser Schluessel fuer diese Adresse gelten darf.
  ///
  /// HIER WEICHT BITDM BEWUSST VON DER REFERENZ AB.
  ///
  /// libsignals Beispielspeicher vertraut dem ersten Schluessel, den es zu
  /// einer Adresse sieht, und danach nur noch demselben. Das ist der uebliche
  /// Ansatz, wenn eine Adresse eine Telefonnummer ist: man kann nicht
  /// nachrechnen, welcher Schluessel dazugehoert, also glaubt man dem ersten.
  ///
  /// Bei BitDM ist das anders. Die Adresse IST der oeffentliche Schluessel,
  /// lesbar kodiert. Ob ein Schluessel zu einer Adresse gehoert, ist deshalb
  /// keine Vertrauensfrage, sondern eine Rechenaufgabe — und die loesen wir.
  ///
  /// Der Unterschied ist praktisch: Ein boesartiger Server, der beim
  /// Prekey-Bundle einen fremden Schluessel unterschiebt, kaeme bei einer
  /// Vertrauensregel durch, solange das Opfer die Gegenstelle noch nie
  /// kontaktiert hat. Hier faellt er auf — beim allerersten Kontakt, ohne dass
  /// jemand eine Sicherheitsnummer vergleichen muesste.
  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    return _keyMatchesAddress(address.getName(), identityKey);
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;

    final name = address.getName();
    if (!_keyMatchesAddress(name, identityKey)) {
      // Nicht bloss ablehnen, sondern werfen. Ein Aufrufer, der das Ergebnis
      // ignoriert, wuerde sonst mit einem Schluessel weiterarbeiten, den wir
      // gerade als falsch erkannt haben.
      throw AddressKeyMismatchException(name);
    }

    final serialized = identityKey.serialize();
    final existing = _state.identities[name];
    if (existing != null && _bytesEqual(existing, serialized)) {
      return false; // unveraendert
    }
    _state.identities[name] = serialized;
    _touch(StoreSection.identity);
    return true; // neu oder geaendert
  }

  /// Rechnet nach, ob der Schluessel die Adresse ergibt.
  ///
  /// Nutzt bewusst die rohen 32 Bytes, nicht serialize() — letzteres traegt
  /// libsignals Typ-Byte 0x05 voran und ergaebe eine andere Adresse. Siehe
  /// signal_identity.dart.
  bool _keyMatchesAddress(String address, IdentityKey key) {
    try {
      final erwartet = BitdmAddress.encode(
        SignalIdentityBridge.rawPublicKeyOf(key),
      );
      return BitdmAddress.normalize(address) == erwartet;
    } catch (_) {
      // Unbrauchbarer Schluessel oder unbrauchbare Adresse: nicht vertrauen.
      return false;
    }
  }

  // ══════════════════════════════════════════════════ PreKeyStore

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final bytes = _state.preKeys[preKeyId];
    if (bytes == null) {
      // Die Referenz wirft hier ebenfalls. Der Fall ist NORMAL: eine doppelt
      // zugestellte Erstnachricht verweist auf einen Prekey, der beim ersten
      // Mal verbraucht wurde.
      throw InvalidKeyIdException('kein Prekey mit der Nummer $preKeyId');
    }
    return PreKeyRecord.fromBuffer(bytes);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    _state.preKeys[preKeyId] = record.serialize();
    _touch(StoreSection.preKey);
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      _state.preKeys.containsKey(preKeyId);

  @override
  Future<void> removePreKey(int preKeyId) async {
    if (_state.preKeys.remove(preKeyId) != null) {
      _touch(StoreSection.preKey);
    }
  }

  /// Wie viele One-Time-Prekeys noch vorraetig sind.
  ///
  /// Der Relay meldet zwar `prekeys_low`, aber darauf allein sollte sich der
  /// Client nicht verlassen — er soll auch ohne Zuruf nachfuellen koennen.
  int get preKeyCount => _state.preKeys.length;

  // ═══════════════════════════════════════════ SignedPreKeyStore

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final bytes = _state.signedPreKeys[signedPreKeyId];
    if (bytes == null) {
      throw InvalidKeyIdException(
          'kein signierter Prekey mit der Nummer $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(bytes);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async => _state
      .signedPreKeys.values
      .map(SignedPreKeyRecord.fromSerialized)
      .toList();

  @override
  Future<void> storeSignedPreKey(
      int signedPreKeyId, SignedPreKeyRecord record) async {
    _state.signedPreKeys[signedPreKeyId] = record.serialize();
    _touch(StoreSection.signedPreKey);
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      _state.signedPreKeys.containsKey(signedPreKeyId);

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    if (_state.signedPreKeys.remove(signedPreKeyId) != null) {
      _touch(StoreSection.signedPreKey);
    }
  }

  // ═════════════════════════════════════════════════ SessionStore

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final bytes = _state.sessions[address.toString()];
    // Bei unbekannter Adresse ein FRISCHES Record, nicht null und keine
    // Ausnahme — genau wie die Referenz. libsignal verlaesst sich darauf:
    // ein leeres Record bedeutet "noch keine Sitzung", und der Sitzungsaufbau
    // schreibt hinein.
    if (bytes == null) return SessionRecord();
    return SessionRecord.fromSerialized(bytes);
  }

  @override
  Future<void> storeSession(
      SignalProtocolAddress address, SessionRecord record) async {
    _state.sessions[address.toString()] = record.serialize();
    _touch(StoreSection.session);
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      _state.sessions.containsKey(address.toString());

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    if (_state.sessions.remove(address.toString()) != null) {
      _touch(StoreSection.session);
    }
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final treffer =
        _state.sessions.keys.where((k) => _nameOf(k) == name).toList();
    for (final k in treffer) {
      _state.sessions.remove(k);
    }
    if (treffer.isNotEmpty) _touch(StoreSection.session);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    // Geraet 1 ist das Hauptgeraet und zaehlt nicht als Zweitgeraet — so
    // macht es auch die Referenz. Bei BitDM v1 ist die Liste immer leer, weil
    // es nur ein Geraet je Identitaet gibt; die Methode gehoert trotzdem zur
    // Schnittstelle.
    return _state.sessions.keys
        .where((k) => _nameOf(k) == name)
        .map(_deviceOf)
        .whereType<int>()
        .where((d) => d != 1)
        .toList();
  }

  // SignalProtocolAddress.toString() liefert "name:geraeteId" — nachgelesen in
  // signal_protocol_address.dart, nicht geraten. Eine BitDM-Adresse besteht
  // nur aus Base32-Zeichen und kann keinen Doppelpunkt enthalten, das
  // Trennzeichen ist also eindeutig.
  //
  // Beide Funktionen geben bei unerwartetem Aufbau lieber nichts zurueck, als
  // zu werfen: diese Schluessel kommen aus der Datenbank, und ein einzelner
  // beschaedigter Eintrag darf nicht die ganze Abfrage zum Absturz bringen.
  static String? _nameOf(String key) {
    final i = key.lastIndexOf(':');
    return i <= 0 ? null : key.substring(0, i);
  }

  static int? _deviceOf(String key) {
    final i = key.lastIndexOf(':');
    return i < 0 ? null : int.tryParse(key.substring(i + 1));
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
