// signal_hilfe.dart — was Tests mit der offiziellen libsignal immer wieder
// brauchen.
//
// Seit 2.0.0 laeuft BitDM ueber Signals offizielle libsignal (Rust, Paket
// `libsignal`). Die Dart-Nachbildung hatte freie Hilfsfunktionen wie
// `generateSignedPreKey` und `generatePreKeys`; die offizielle Bibliothek
// erzeugt Records aus Schluesseln. Damit nicht jeder Test das selbst
// zusammensteckt — und dabei die Signatur eines Kyber-Prekeys ueber die
// falschen Bytes rechnet —, steht es hier einmal.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:libsignal/libsignal.dart';

/// Laedt die native Bibliothek. In `setUpAll` jeder Datei, die libsignal
/// anfasst, ohne den Kern zu oeffnen. Ein zweiter Aufruf tut nichts.
Future<void> signalBereit() => LibSignal.init();

/// Zeitstempel fuer frisch erzeugte Records.
BigInt get jetztMs => BigInt.from(DateTime.now().millisecondsSinceEpoch);

/// Ein signierter EC-Prekey, signiert mit [identitaet].
SignedPreKeyRecord neuerSpk(IdentityKeyPair identitaet, int id, {BigInt? zeit}) {
  final privat = PrivateKey.generate();
  final oeffentlich = privat.getPublicKey();
  return SignedPreKeyRecord(
    id: id,
    timestamp: zeit ?? jetztMs,
    publicKey: oeffentlich,
    privateKey: privat,
    signature: identitaet.sign(message: oeffentlich.serialize()),
  );
}

/// Ein EC-Einmalschluessel.
PreKeyRecord neuerPreKey(int id) {
  final privat = PrivateKey.generate();
  return PreKeyRecord(id: id, publicKey: privat.getPublicKey(), privateKey: privat);
}

/// Ein Kyber-Prekey, signiert ueber die vollen 1569 Bytes mit Typ-Byte.
KyberPreKeyRecord neuerKyber(IdentityKeyPair identitaet, int id, {BigInt? zeit}) {
  final kp = KyberKeyPair.generate();
  return KyberPreKeyRecord.create(
    id: id,
    timestamp: zeit ?? jetztMs,
    keyPair: kp,
    signature: identitaet.sign(message: kp.getPublicKey().serialize()),
  );
}

/// Kurzform fuer eine libsignal-Adresse.
ProtocolAddress adr(String name, [int geraet = 1]) =>
    ProtocolAddress(name: name, deviceId: geraet);

/// Ver- und Entschluesseln ueber einen [BitdmSignalStore], der alle fuenf
/// Rollen spielt — so wie real_messenger_core `_chiffre`.
SessionCipher chiffreVon(BitdmSignalStore store, {int geraet = 1}) =>
    SessionCipher(
      localAddress: adr(store.identity.address, geraet),
      sessionStore: store,
      identityKeyStore: store,
      preKeyStore: store,
      signedPreKeyStore: store,
      kyberPreKeyStore: store,
    );

/// Sitzungsaufbau ueber einen [BitdmSignalStore].
SessionBuilder bauerVon(BitdmSignalStore store, {int geraet = 1}) =>
    SessionBuilder(
      localAddress: adr(store.identity.address, geraet),
      sessionStore: store,
      identityKeyStore: store,
    );

/// Legt in [store] einen vollstaendigen Prekey-Satz ab und gibt die Karte
/// zurueck, die der Relay fuer dieses Geraet ausliefern wuerde.
///
/// [mitEinmal]: ob ein EC-Einmalschluessel und ein Kyber-Einmalschluessel
/// dabei sind (sonst nur der signierte und der Last-Resort-Kyber).
Future<Map<String, Object?>> legePrekeysAb(
  BitdmSignalStore store, {
  int spkId = 1,
  int kyberId = 1,
  int preKeyId = 500,
  bool mitEinmal = true,
}) async {
  final paar = store.identity.keyPair;
  final spk = neuerSpk(paar, spkId);
  await store.storeSignedPreKey(spkId, spk);
  final kyberLetzte = neuerKyber(paar, kyberId);
  await store.storeLastResortKyberPreKey(kyberId, kyberLetzte);
  PreKeyRecord? otk;
  KyberPreKeyRecord? kyberEinmal;
  if (mitEinmal) {
    otk = neuerPreKey(preKeyId);
    await store.storePreKey(preKeyId, otk);
    kyberEinmal = neuerKyber(paar, kyberId + 1);
    await store.storeKyberPreKey(kyberId + 1, kyberEinmal);
  }
  final kyber = kyberEinmal ?? kyberLetzte;
  return {
    'registration_id': store.identity.registrationId,
    'signed_prekey_id': spkId,
    'signed_prekey': base64.encode(spk.publicKey()),
    'signed_prekey_sig': base64.encode(spk.signature()),
    'one_time_prekey': otk == null
        ? null
        : {'key_id': otk.id(), 'public_key': base64.encode(otk.publicKey())},
    'kyber_prekey_id': kyber.id(),
    'kyber_prekey': base64.encode(kyber.getPublicKey().serialize()),
    'kyber_prekey_sig': base64.encode(kyber.signature()),
  };
}

/// Die rohen 32 Bytes der Identitaet als base64 — so steht sie beim Relay.
String identitaetB64(BitdmSignalStore store) =>
    base64.encode(store.identity.rawPublicKey);

/// Bytes vergleichen.
bool gleich(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Ein Uint8List aus Text.
Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

/// Das Buendel, das der Relay fuer [store] ausliefern wuerde — gebaut aus dem,
/// was der Speicher eines laufenden Kerns schon hat.
///
/// Nimmt den NEUESTEN signierten Prekey, einen EC-Einmalschluessel und einen
/// Kyber-Einmalschluessel, falls vorhanden, sonst den Last-Resort-Kyber.
/// Genau wie der Relay es tut (relay_server.py `/prekey`).
///
/// [nr]: der wievielte Einmalschluessel. Der echte Relay gibt JEDEN
/// Einmalschluessel nur einmal aus; ein Test, der zwei Gegenstellen dasselbe
/// Buendel gibt, baut einen Fall, den es nicht gibt — die zweite Erstnachricht
/// verweist dann auf einen verbrauchten Schluessel. Bis 1.9.x fiel das nicht
/// auf, weil die Erstnachricht meist schon verarbeitet war, bevor die zweite
/// Gegenstelle ihr Buendel las; mit der offiziellen libsignal (Rust, ueber
/// FFI) dauert das Entschluesseln laenger, und der Wettlauf wird sichtbar.
Future<RelayBundleResponse> buendelAusSpeicher(BitdmSignalStore store,
    {int nr = 0}) async {
  final spkId = store.state.signedPreKeys.keys.reduce((a, b) => a > b ? a : b);
  final spk = (await store.loadSignedPreKey(spkId))!;
  final otkIds = store.state.preKeys.keys.toList()..sort();
  final otk = otkIds.length <= nr ? null : await store.loadPreKey(otkIds[nr]);
  final kyberEinmal = store.state.kyberPreKeys.entries
      .where((e) => !e.value.letzteRettung)
      .map((e) => e.key)
      .toList()
    ..sort();
  final kyberId =
      kyberEinmal.length > nr ? kyberEinmal[nr] : store.letzteRettungId!;
  final kyber = (await store.loadKyberPreKey(kyberId))!;
  return RelayBundleResponse(
    userId: store.identity.address,
    identityKey: base64.encode(store.identity.rawPublicKey),
    registrationId: store.identity.registrationId,
    signedPreKeyId: spk.id(),
    signedPreKey: base64.encode(spk.publicKey()),
    signedPreKeySignature: base64.encode(spk.signature()),
    oneTimePreKey: otk == null
        ? null
        : RelayOneTimePreKey(
            keyId: otk.id(), publicKey: base64.encode(otk.publicKey())),
    kyberPreKeyId: kyber.id(),
    kyberPreKey: base64.encode(kyber.getPublicKey().serialize()),
    kyberPreKeySignature: base64.encode(kyber.signature()),
  );
}
