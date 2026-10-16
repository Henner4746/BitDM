// signal_store.dart — die fuenf Speicher, die libsignal verlangt.
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
// DER VERTRAG DER ANBINDUNG (libsignal 8.0.0, stores/session_store.dart) lässt
// genau das zu: Schreibvorgaenge muessen dauerhaft sein, "or ... part of a
// transaction you commit durably before the ciphertext is sent / the plaintext
// is acted upon". Die Transaktion darueber MUSS also vor dem Senden bzw. vor
// dem Verarbeiten des Klartexts committen. Darauf achtet real_messenger_core.
//
// SEIT 2.0.0 (Signals offizielle libsignal statt der Dart-Nachbildung) kommt
// ein fuenfter Speicher dazu: Kyber-Prekeys fuer PQXDH. Siehe den Abschnitt
// KyberPreKeyStore unten — er hat eine Eigenheit, die die Sicherheit betrifft.

import 'dart:collection';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

import '../crypto/address.dart';
import '../crypto/signal_identity.dart';

/// Welcher der Speicher sich geaendert hat — die Schicht darueber braucht das,
/// um gezielt zu schreiben statt alles.
enum StoreSection {
  identity,
  preKey,
  signedPreKey,
  kyberPreKey,
  kyberBenutzt,
  session,
}

/// Was seit dem letzten Festschreiben angefasst wurde — nicht nur WELCHER
/// Speicher, sondern WELCHE Eintraege.
///
/// Der Unterschied ist keine Feinheit. Wuerde beim Empfang einer Nachricht der
/// ganze Sitzungsbereich neu geschrieben, waeren das bei 100 Kontakten rund
/// 100 Datensaetze fuer eine einzige geaenderte Sitzung — bei jeder Nachricht,
/// auf dem Flash-Speicher eines Telefons. Mit den einzelnen Schluesseln wird
/// genau eine Zeile angefasst.
///
/// Ein aufgefuehrter Schluessel bedeutet "hat sich geaendert", nicht
/// "existiert". Ob geschrieben oder geloescht werden muss, ergibt sich beim
/// Festschreiben daraus, ob er im Zustand noch vorkommt. Damit sind Anlegen und
/// Loeschen derselbe Fall.
class StoreDelta {
  final Set<String> identities = <String>{};
  final Set<int> preKeys = <int>{};
  final Set<int> signedPreKeys = <int>{};
  final Set<int> kyberPreKeys = <int>{};
  final Set<String> kyberBenutzt = <String>{};
  final Set<String> sessions = <String>{};

  bool get isEmpty =>
      identities.isEmpty &&
      preKeys.isEmpty &&
      signedPreKeys.isEmpty &&
      kyberPreKeys.isEmpty &&
      kyberBenutzt.isEmpty &&
      sessions.isEmpty;

  bool get isNotEmpty => !isEmpty;

  Set<StoreSection> get sections => {
        if (identities.isNotEmpty) StoreSection.identity,
        if (preKeys.isNotEmpty) StoreSection.preKey,
        if (signedPreKeys.isNotEmpty) StoreSection.signedPreKey,
        if (kyberPreKeys.isNotEmpty) StoreSection.kyberPreKey,
        if (kyberBenutzt.isNotEmpty) StoreSection.kyberBenutzt,
        if (sessions.isNotEmpty) StoreSection.session,
      };

  void clear() {
    identities.clear();
    preKeys.clear();
    signedPreKeys.clear();
    kyberPreKeys.clear();
    kyberBenutzt.clear();
    sessions.clear();
  }
}

/// Ein gespeicherter Kyber-Prekey samt seiner Art.
///
/// DIE ART STEHT NICHT IM RECORD. libsignal unterscheidet Einmal- und
/// Last-Resort-Schluessel nicht; das muss der Speicher selbst wissen, vom
/// Erzeugen an (stores/kyber_pre_key_store.dart der Anbindung).
class KyberEintrag {
  /// Serialisierter `KyberPreKeyRecord`.
  final Uint8List record;

  /// `true`: der Last-Resort-Schluessel, der weiter ausgegeben wird, wenn die
  /// Einmalschluessel aufgebraucht sind. `false`: ein Einmalschluessel.
  final bool letzteRettung;

  const KyberEintrag(this.record, {required this.letzteRettung});
}

/// Zustand aller Speicher im Arbeitsspeicher.
///
/// Bewusst eine eigene Klasse und nicht lose Maps: die Transaktion oben
/// braucht einen einzigen Gegenstand, den sie festschreiben kann.
class SignalStoreState {
  final Map<String, Uint8List> identities;      // Adresse -> serialisierter PublicKey (33 Byte)
  final Map<int, Uint8List> preKeys;            // id -> serialisierter PreKeyRecord
  final Map<int, Uint8List> signedPreKeys;      // id -> serialisierter SignedPreKeyRecord
  final Map<int, KyberEintrag> kyberPreKeys;    // id -> Record + Art
  final Set<String> kyberBenutzt;               // "kyberId:spkId:basisHex" der Last-Resort-Nutzungen
  final Map<String, Uint8List> sessions;        // "adresse:geraet" -> serialisiertes SessionRecord

  SignalStoreState({
    Map<String, Uint8List>? identities,
    Map<int, Uint8List>? preKeys,
    Map<int, Uint8List>? signedPreKeys,
    Map<int, KyberEintrag>? kyberPreKeys,
    Set<String>? kyberBenutzt,
    Map<String, Uint8List>? sessions,
  })  : identities = identities ?? HashMap(),
        preKeys = preKeys ?? HashMap(),
        signedPreKeys = signedPreKeys ?? HashMap(),
        kyberPreKeys = kyberPreKeys ?? HashMap(),
        kyberBenutzt = kyberBenutzt ?? HashSet(),
        sessions = sessions ?? HashMap();

  SignalStoreState copy() => SignalStoreState(
        identities: HashMap.of(identities),
        preKeys: HashMap.of(preKeys),
        signedPreKeys: HashMap.of(signedPreKeys),
        kyberPreKeys: HashMap.of(kyberPreKeys),
        kyberBenutzt: HashSet.of(kyberBenutzt),
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

/// Ein festgehaltener Stand von [BitdmSignalStore] (siehe
/// [BitdmSignalStore.schnappschuss]).
class SignalStoreSchnappschuss {
  SignalStoreSchnappschuss._(this._state, StoreDelta d)
      : _identities = {...d.identities},
        _preKeys = {...d.preKeys},
        _signedPreKeys = {...d.signedPreKeys},
        _kyberPreKeys = {...d.kyberPreKeys},
        _kyberBenutzt = {...d.kyberBenutzt},
        _sessions = {...d.sessions};

  final SignalStoreState _state;
  final Set<String> _identities;
  final Set<int> _preKeys;
  final Set<int> _signedPreKeys;
  final Set<int> _kyberPreKeys;
  final Set<String> _kyberBenutzt;
  final Set<String> _sessions;
}

class BitdmSignalStore
    implements
        IdentityKeyStore,
        PreKeyStore,
        SignedPreKeyStore,
        KyberPreKeyStore,
        SessionStore {
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
  final StoreDelta _delta = StoreDelta();

  /// Welche Bereiche seit dem letzten Festschreiben veraendert wurden.
  Set<StoreSection> get dirtySections => _delta.sections;

  /// Welche EINZELNEN Eintraege veraendert wurden.
  StoreDelta get delta => _delta;

  /// Ob ueberhaupt etwas zu schreiben waere.
  bool get isDirty => _delta.isNotEmpty;

  /// Der aktuelle Zustand — fuer die Schicht, die ihn festschreibt.
  SignalStoreState get state => _state;

  /// Die eigene Identitaet. Sie kommt aus der Seed-Phrase und aendert sich nie.
  SignalIdentity get identity => _identity;

  /// Nach erfolgreichem Festschreiben aufzurufen.
  ///
  /// Ausdruecklich getrennt vom Schreiben selbst: schlaegt die Transaktion
  /// fehl, bleibt der Merkzettel stehen und der naechste Versuch schreibt
  /// wieder alles Offene. Wuerde hier zu frueh geleert, gingen die Aenderungen
  /// still verloren.
  void markClean() => _delta.clear();

  /// Haelt den ganzen Zustand samt Merkzettel fest — vor einer Erstnachricht.
  ///
  /// WOFUER: Eine erneut eingespielte Erstnachricht gegen den
  /// Last-Resort-Kyber-Prekey faellt erst NACH dem Entschluesseln auf
  /// ([kyberWiederholungen]). Bis dahin kann libsignal schon eine neue Sitzung
  /// daraus angelegt und gespeichert haben. Der Empfangspfad stellt in dem Fall
  /// mit [stelleWiederHer] den Stand von vorher her — sonst schriebe der
  /// Fehlerpfad die eingeschleuste Sitzung fest, und die naechste eigene
  /// Nachricht ginge ueber eine Sitzung, die die Gegenstelle nicht hat.
  ///
  /// Kostet nur Kopien der Maps, nicht der Bytes (die Werte werden nie an Ort
  /// und Stelle veraendert, nur ersetzt).
  SignalStoreSchnappschuss schnappschuss() =>
      SignalStoreSchnappschuss._(_state.copy(), _delta);

  /// Setzt Zustand und Merkzettel auf [s] zurueck.
  void stelleWiederHer(SignalStoreSchnappschuss s) {
    void tausche<K, V>(Map<K, V> ziel, Map<K, V> quelle) => ziel
      ..clear()
      ..addAll(quelle);
    tausche(_state.identities, s._state.identities);
    tausche(_state.preKeys, s._state.preKeys);
    tausche(_state.signedPreKeys, s._state.signedPreKeys);
    tausche(_state.kyberPreKeys, s._state.kyberPreKeys);
    tausche(_state.sessions, s._state.sessions);
    _state.kyberBenutzt
      ..clear()
      ..addAll(s._state.kyberBenutzt);
    _delta.clear();
    _delta.identities.addAll(s._identities);
    _delta.preKeys.addAll(s._preKeys);
    _delta.signedPreKeys.addAll(s._signedPreKeys);
    _delta.kyberPreKeys.addAll(s._kyberPreKeys);
    _delta.kyberBenutzt.addAll(s._kyberBenutzt);
    _delta.sessions.addAll(s._sessions);
  }

  // ══════════════════════════════════════════════ IdentityKeyStore

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identity.keyPair;

  @override
  Future<int> getLocalRegistrationId() async => _identity.registrationId;

  /// Der Identitaetsschluessel zu [address] — auch fuer eine Adresse, die
  /// dieser Speicher noch nie gesehen hat.
  ///
  /// DIE ADRESSE IST DER SCHLUESSEL. Was libsignal hier sonst als
  /// "zuerst gesehener Schluessel" fuehrt (trust on first use), steht bei
  /// BitDM schon in der Adresse. Liefert der Speicher ihn immer, prueft
  /// libsignal bei jedem Sitzungsaufbau und jeder Erstnachricht selbst gegen
  /// genau diesen Schluessel und lehnt einen anderen sauber mit
  /// `untrustedIdentity` ab — OHNE vorher eine Sitzung abzulegen.
  ///
  /// Bis zu dieser Aenderung (16.10.2026) gab es fuer eine unbekannte Adresse
  /// null, und die einzige Pruefung war ein Wurf in [saveIdentity] — aus
  /// einem Rueckruf heraus, also als Panic im Rust-Faden, NACHDEM die Anbindung
  /// die Sitzung schon abgelegt hatte (signal_errors.dart `FremdeIdentitaet`).
  /// Im Browser kehrt ein asynchroner Aufruf nach einer Panic laut Paket nie
  /// zurueck.
  ///
  /// Null nur bei einer Adresse, die keine BitDM-Adresse ist.
  @override
  Future<PublicKey?> getIdentity(ProtocolAddress address) async {
    final bytes = _state.identities[address.name()];
    if (bytes != null) return PublicKey.deserialize(bytes: bytes);
    try {
      return SignalIdentityBridge.publicKeyOfAddress(address.name());
    } catch (_) {
      return null;
    }
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
  ///
  /// ACHTUNG, SEIT 2.0.0: die Anbindung der offiziellen libsignal ruft diese
  /// Methode NIE auf (Befund vom 16.10.2026). Sie bleibt fuer die
  /// Schnittstelle und fuer Tests; der eigentliche Riegel steht VOR libsignal
  /// (signal_errors.dart `FremdeIdentitaet`). [saveIdentity] wirft weiter als
  /// letzte Linie.
  @override
  Future<bool> isTrustedIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
    Direction direction,
  ) async =>
      _keyMatchesAddress(address.name(), identityKey);

  @override
  Future<bool> saveIdentity(ProtocolAddress address, PublicKey identityKey) async {
    final name = address.name();
    if (!_keyMatchesAddress(name, identityKey)) {
      // NICHT WERFEN, nur nicht ablegen. Bis 16.10.2026 stand hier ein Wurf —
      // das ist ein Rueckruf aus libsignal, ein Wurf wird dort zur Panic im
      // Rust-Faden, und im Browser kehrt der Aufruf danach nie zurueck.
      // Erreichbar ist der Fall ohnehin nicht mehr: [getIdentity] liefert
      // immer den Schluessel der Adresse, und libsignal lehnt einen anderen
      // vorher selbst ab. Davor stehen ausserdem die Riegel
      // (signal_errors.dart `FremdeIdentitaet`).
      return false;
    }

    final serialized = identityKey.serialize();
    final existing = _state.identities[name];
    if (existing != null && _bytesEqual(existing, serialized)) {
      return false; // unveraendert
    }
    _state.identities[name] = serialized;
    _delta.identities.add(name);
    return true; // neu oder geaendert
  }

  /// Rechnet nach, ob der Schluessel die Adresse ergibt.
  ///
  /// Nutzt bewusst die rohen 32 Bytes, nicht serialize() — letzteres traegt
  /// libsignals Typ-Byte 0x05 voran und ergaebe eine andere Adresse. Siehe
  /// signal_identity.dart.
  bool _keyMatchesAddress(String address, PublicKey key) {
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

  /// `null` bei unbekannter Nummer. Der Fall ist NORMAL: eine doppelt
  /// zugestellte Erstnachricht verweist auf einen Prekey, der beim ersten Mal
  /// verbraucht wurde. libsignal macht daraus `invalidKeyIdentifier`.
  @override
  Future<PreKeyRecord?> loadPreKey(int preKeyId) async {
    final bytes = _state.preKeys[preKeyId];
    return bytes == null ? null : PreKeyRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    _state.preKeys[preKeyId] = record.serialize();
    _delta.preKeys.add(preKeyId);
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      _state.preKeys.containsKey(preKeyId);

  @override
  Future<void> removePreKey(int preKeyId) async {
    if (_state.preKeys.remove(preKeyId) != null) {
      _delta.preKeys.add(preKeyId);
    }
  }

  @override
  Future<List<int>> getAllPreKeyIds() async => _state.preKeys.keys.toList();

  /// Wie viele One-Time-Prekeys noch vorraetig sind.
  ///
  /// Der Relay meldet zwar `prekeys_low`, aber darauf allein sollte sich der
  /// Client nicht verlassen — er soll auch ohne Zuruf nachfuellen koennen.
  int get preKeyCount => _state.preKeys.length;

  // ═══════════════════════════════════════════ SignedPreKeyStore

  @override
  Future<SignedPreKeyRecord?> loadSignedPreKey(int signedPreKeyId) async {
    final bytes = _state.signedPreKeys[signedPreKeyId];
    return bytes == null ? null : SignedPreKeyRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storeSignedPreKey(
      int signedPreKeyId, SignedPreKeyRecord record) async {
    _state.signedPreKeys[signedPreKeyId] = record.serialize();
    _delta.signedPreKeys.add(signedPreKeyId);
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      _state.signedPreKeys.containsKey(signedPreKeyId);

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    if (_state.signedPreKeys.remove(signedPreKeyId) != null) {
      _delta.signedPreKeys.add(signedPreKeyId);
    }
  }

  @override
  Future<List<int>> getAllSignedPreKeyIds() async =>
      _state.signedPreKeys.keys.toList();

  // ═════════════════════════════════════════════ KyberPreKeyStore
  //
  // ZWEI ARTEN, UND DER RECORD SAGT NICHT, WELCHE.
  //
  // Einmalschluessel: einer je neuer Sitzung, danach verbraucht. Der
  // Last-Resort-Schluessel: wird weiter ausgegeben, wenn die Einmalschluessel
  // alle sind. Fuer ihn gilt eine Besonderheit, die die Sicherheit betrifft:
  //
  // EINE ERSTNACHRICHT GEGEN DEN LAST-RESORT-SCHLUESSEL LIESSE SICH ERNEUT
  // EINSPIELEN, wenn niemand sich merkt, dass sie schon da war. Genau das war
  // LS-1 im Audit vom 16.10.2026 (dort in der Dart-Nachbildung). libsignal
  // ruft dafuer [markKyberPreKeyUsed] mit (kyberId, signedPreKeyId, baseKey);
  // dasselbe Tripel zweimal heisst: dieselbe Erstnachricht zweimal.
  //
  // DIE ERKENNUNG KOMMT ERST NACH DEM ENTSCHLUESSELN. Die Anbindung sagt
  // ausdruecklich: dieser Rueckruf darf nicht werfen (sonst Panic im
  // Rust-Thread), und libsignal hat den Klartext da schon erzeugt. Deshalb
  // zaehlt der Speicher Wiederholungen in [kyberWiederholungen], und der
  // Empfangspfad vergleicht den Zaehler vor und nach dem Entschluesseln und
  // VERWIRFT die Nachricht bei einer Wiederholung.

  @override
  Future<KyberPreKeyRecord?> loadKyberPreKey(int kyberPreKeyId) async {
    final e = _state.kyberPreKeys[kyberPreKeyId];
    return e == null ? null : KyberPreKeyRecord.deserialize(bytes: e.record);
  }

  /// Legt einen EINMAL-Schluessel ab. Fuer den Last-Resort-Schluessel gibt es
  /// [storeLastResortKyberPreKey] — die Art muss beim Ablegen feststehen.
  @override
  Future<void> storeKyberPreKey(
      int kyberPreKeyId, KyberPreKeyRecord record) async {
    _state.kyberPreKeys[kyberPreKeyId] =
        KyberEintrag(record.serialize(), letzteRettung: false);
    _delta.kyberPreKeys.add(kyberPreKeyId);
  }

  /// Legt den LAST-RESORT-Schluessel ab.
  Future<void> storeLastResortKyberPreKey(
      int kyberPreKeyId, KyberPreKeyRecord record) async {
    _state.kyberPreKeys[kyberPreKeyId] =
        KyberEintrag(record.serialize(), letzteRettung: true);
    _delta.kyberPreKeys.add(kyberPreKeyId);
  }

  @override
  Future<bool> containsKyberPreKey(int kyberPreKeyId) async =>
      _state.kyberPreKeys.containsKey(kyberPreKeyId);

  /// Wie oft eine bereits gesehene Last-Resort-Nutzung erneut kam.
  ///
  /// Steigt nie wieder ab. Der Empfangspfad liest ihn vor und nach dem
  /// Entschluesseln; ein Anstieg heisst "erneut eingespielt — verwerfen".
  int get kyberWiederholungen => _kyberWiederholungen;
  int _kyberWiederholungen = 0;

  @override
  Future<void> markKyberPreKeyUsed(
    int kyberPreKeyId,
    int signedPreKeyId,
    PublicKey baseKey,
  ) async {
    // NIE WERFEN — siehe Abschnittskopf. Auch nicht bei Unbekanntem.
    final e = _state.kyberPreKeys[kyberPreKeyId];
    if (e == null) return;
    if (!e.letzteRettung) {
      // Einmalschluessel: verbrauchen. Danach liefert loadKyberPreKey null,
      // eine zweite Sitzung damit ist ausgeschlossen.
      _state.kyberPreKeys.remove(kyberPreKeyId);
      _delta.kyberPreKeys.add(kyberPreKeyId);
      return;
    }
    final tripel = kyberTripel(kyberPreKeyId, signedPreKeyId, baseKey.serialize());
    if (!_state.kyberBenutzt.add(tripel)) {
      _kyberWiederholungen++;
      return;
    }
    _delta.kyberBenutzt.add(tripel);
  }

  /// Schluessel fuer die Liste der Last-Resort-Nutzungen.
  static String kyberTripel(int kyberId, int spkId, List<int> basis) =>
      '$kyberId:$spkId:${basis.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  @override
  Future<void> removeKyberPreKey(int kyberPreKeyId) async {
    if (_state.kyberPreKeys.remove(kyberPreKeyId) != null) {
      _delta.kyberPreKeys.add(kyberPreKeyId);
    }
    // Die gemerkten Nutzungen eines entfernten Last-Resort-Schluessels
    // braucht niemand mehr: ohne den Schluessel laesst sich eine alte
    // Erstnachricht ohnehin nicht mehr entschluesseln.
    final weg = _state.kyberBenutzt
        .where((t) => t.startsWith('$kyberPreKeyId:'))
        .toList();
    for (final t in weg) {
      _state.kyberBenutzt.remove(t);
      _delta.kyberBenutzt.add(t);
    }
  }

  @override
  Future<List<int>> getAllKyberPreKeyIds() async =>
      _state.kyberPreKeys.keys.toList();

  /// Wie viele Kyber-EINMAL-Schluessel noch vorraetig sind.
  int get kyberEinmalCount =>
      _state.kyberPreKeys.values.where((e) => !e.letzteRettung).length;

  /// Die Nummer des aktuellen Last-Resort-Schluessels, oder null.
  ///
  /// Gibt es mehrere (waehrend einer Erneuerung), gilt die hoechste Nummer.
  int? get letzteRettungId {
    final ids = _state.kyberPreKeys.entries
        .where((e) => e.value.letzteRettung)
        .map((e) => e.key)
        .toList()
      ..sort();
    return ids.isEmpty ? null : ids.last;
  }

  // ═════════════════════════════════════════════════ SessionStore

  /// Schluessel einer Sitzung: "adresse:geraet". Dasselbe Format wie bis 1.9.x
  /// (`SignalProtocolAddress.toString()`). Eine BitDM-Adresse besteht nur aus
  /// Base32-Zeichen und kann keinen Doppelpunkt enthalten, das Trennzeichen
  /// ist also eindeutig.
  static String sitzungsSchluessel(ProtocolAddress a) =>
      '${a.name()}:${a.deviceId()}';

  @override
  Future<SessionRecord?> loadSession(ProtocolAddress address) async {
    final bytes = _state.sessions[sitzungsSchluessel(address)];
    return bytes == null ? null : SessionRecord.deserialize(bytes: bytes);
  }

  @override
  Future<void> storeSession(ProtocolAddress address, SessionRecord record) async {
    final k = sitzungsSchluessel(address);
    _state.sessions[k] = record.serialize();
    _delta.sessions.add(k);
  }

  @override
  Future<bool> containsSession(ProtocolAddress address) async =>
      _state.sessions.containsKey(sitzungsSchluessel(address));

  @override
  Future<void> deleteSession(ProtocolAddress address) async {
    final k = sitzungsSchluessel(address);
    if (_state.sessions.remove(k) != null) {
      _delta.sessions.add(k);
    }
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final treffer =
        _state.sessions.keys.where((k) => _nameOf(k) == name).toList();
    for (final k in treffer) {
      _state.sessions.remove(k);
      _delta.sessions.add(k);
    }
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    // Geraet 1 ist das Hauptgeraet und zaehlt nicht als Zweitgeraet — so
    // macht es auch die Referenz. Eine Adresse kann bis zu fuenf Geraete
    // haben (Spezifikation §6). Wer alle braucht — und das tut das Fanout —
    // nimmt [geraeteVon]; diese Methode hier gehoert libsignals
    // Schnittstelle und behaelt deren Bedeutung.
    return geraeteVon(name).where((d) => d != 1).toList();
  }

  /// ALLE Geraete, mit denen zu [name] eine Sitzung besteht — aufsteigend.
  ///
  /// DAS IST DIE GERAETELISTE, UND ES BRAUCHT KEINE ZWEITE.
  ///
  /// Sitzungen sind ohnehin je Geraetepaar geschluesselt ("adresse:geraetId",
  /// siehe [storeSession]), das Schema haelt sie einzeln
  /// (encrypted_database.dart `sessions.address TEXT PRIMARY KEY`), und der
  /// Schluessel wird hier schon zerlegt. Eine eigene Tabelle "bekannte
  /// Geraete" waere ein zweiter Ort fuer dieselbe Wahrheit — und der eine, der
  /// dann irgendwann nicht mehr stimmt.
  ///
  /// "Bekanntes Geraet" heisst damit genau: "Geraet, an das wir verschluesseln
  /// koennen". Etwas anderes hilft dem Versand ohnehin nicht.
  List<int> geraeteVon(String name) => _state.sessions.keys
      .where((k) => _nameOf(k) == name)
      .map(_deviceOf)
      .whereType<int>()
      .toList()
    ..sort();

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
