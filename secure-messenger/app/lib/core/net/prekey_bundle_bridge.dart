// prekey_bundle_bridge.dart — zwischen Relay-Format und libsignal.
//
// Hier und nur hier wird umgerechnet. Der Grund fuer eine eigene Datei ist der
// Stolperstein mit den Schluessellaengen: libsignal serialisiert oeffentliche
// Schluessel MIT vorangestelltem Typ-Byte (0x05 fuer Curve25519, 0x08 fuer
// Kyber-1024), die Adresse und die Signaturpruefung des Servers brauchen fuer
// die Identitaet aber die rohen 32 Bytes. Waere das ueber mehrere Dateien
// verteilt, wuerde die Verwechslung irgendwann passieren — und sie faellt nicht
// sofort auf, sondern erst als Sitzungsaufbau, der still scheitert.

import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

import '../crypto/address.dart';
import '../crypto/signal_errors.dart';
import '../crypto/signal_identity.dart';
import 'relay_protocol.dart';

/// Das Geraet der Gegenstelle hat keine Kyber-Prekeys beim Relay.
///
/// Das heisst: dort laeuft noch eine App vor 2.0.0. Die offizielle libsignal
/// baut ohne Kyber keine Sitzung auf (PQXDH ist Pflicht), und zurueck auf die
/// alte Bibliothek gibt es bewusst keinen Weg (docs/LIBSIGNAL-UMSTIEG.md:
/// keine Wahl, kein Downgrade). Die Oberflaeche sagt dem Nutzer, dass die
/// Gegenstelle aktualisieren muss.
class GegenstelleOhneKyberException implements Exception {
  final String adresse;
  final int geraet;
  const GegenstelleOhneKyberException(this.adresse, this.geraet);
  @override
  String toString() =>
      'GegenstelleOhneKyberException: $adresse Geraet $geraet hat keine '
      'Kyber-Prekeys (alte App)';
}

class PreKeyBundleBridge {
  /// Baut aus dem eigenen Zustand das Bundle, das der Relay speichert.
  ///
  /// [oneTimePreKeys] und [oneTimeKyberPreKeys] duerfen leer sein — dann kann
  /// eine Gegenstelle zwar noch eine Sitzung aufbauen, aber ohne die
  /// zusaetzliche Absicherung durch Einmalschluessel. [lastResortKyber] ist
  /// Pflicht: ohne Kyber gibt es keine Sitzung.
  static RelayPreKeyBundle toRelay({
    required SignalIdentity identity,
    required SignedPreKeyRecord signedPreKey,
    required KyberPreKeyRecord lastResortKyber,
    required List<PreKeyRecord> oneTimePreKeys,
    List<KyberPreKeyRecord> oneTimeKyberPreKeys = const [],
    int? deviceId,
  }) {
    return RelayPreKeyBundle(
      userId: identity.address,
      deviceId: deviceId,
      // ROH, 32 Bytes: der Server rechnet die Adresse daraus nach und prueft
      // damit die Signatur. Mit der 33-Byte-Form waere beides falsch.
      identityKey: base64.encode(identity.rawPublicKey),
      registrationId: identity.registrationId,
      signedPreKeyId: signedPreKey.id(),
      // SERIALISIERT, 33 Bytes: fuer den Server ein undurchsichtiger Block,
      // den die Gegenstelle so wieder an libsignal gibt.
      signedPreKey: base64.encode(signedPreKey.publicKey()),
      signedPreKeySignature: base64.encode(signedPreKey.signature()),
      oneTimePreKeys: [
        for (final k in oneTimePreKeys)
          RelayOneTimePreKey(
            keyId: k.id(),
            publicKey: base64.encode(k.publicKey()),
          ),
      ],
      kyberPreKeyId: lastResortKyber.id(),
      kyberPreKey: base64.encode(lastResortKyber.getPublicKey().serialize()),
      kyberPreKeySignature: base64.encode(lastResortKyber.signature()),
      oneTimeKyberPreKeys: [
        for (final k in oneTimeKyberPreKeys)
          RelayKyberPreKey(
            keyId: k.id(),
            publicKey: base64.encode(k.getPublicKey().serialize()),
            signature: base64.encode(k.signature()),
          ),
      ],
    );
  }

  /// Macht aus der Antwort des Relays ein Bundle, mit dem libsignal eine
  /// Sitzung aufbauen kann.
  ///
  /// [deviceId] sagt, MIT WELCHEM GERAET der Adresse die Sitzung entsteht.
  /// Eine Adresse kann bis zu fuenf Geraete haben, und je Geraetepaar MUSS
  /// eine eigene Sitzung entstehen. Eine geteilte Sitzung waere stiller
  /// Nachrichtenverlust — eine Signal-Sitzung ist eine Hashkette, und jedes
  /// Entschluesseln wirft den benutzten Kettenschluessel weg.
  ///
  /// Wirft [GegenstelleOhneKyberException], wenn das Geraet keine
  /// Kyber-Prekeys hat, und [FremdeIdentitaet], wenn der Schluessel nicht die
  /// Adresse `userId` ergibt.
  ///
  /// DIESE PRUEFUNG IST DER RIEGEL GEGEN EINEN FEINDLICHEN RELAY. libsignal
  /// prueft beim Sitzungsaufbau zwar die Signaturen der Prekeys — aber gegen
  /// den Identitaetsschluessel IM BUENDEL. Ein Relay, der ein Buendel mit
  /// eigenem Schluessel unter einer fremden Adresse ausliefert, baut sonst eine
  /// Sitzung, die er selbst mitlesen kann. `isTrustedIdentity` faengt das
  /// nicht, die Anbindung ruft es nie auf (signal_errors.dart
  /// `FremdeIdentitaet`). Der Aufrufer prueft zusaetzlich, dass `userId` die
  /// angefragte Adresse ist.
  static PreKeyBundle fromRelay(RelayBundleResponse antwort,
      {int deviceId = 1}) {
    final identityRaw = base64.decode(antwort.identityKey);
    if (identityRaw.length != 32) {
      throw FormatException(
          'Identitaetsschluessel hat ${identityRaw.length} statt 32 Bytes');
    }
    if (BitdmAddress.encode(identityRaw) !=
        BitdmAddress.normalize(antwort.userId)) {
      throw FremdeIdentitaet(antwort.userId);
    }
    final kyberId = antwort.kyberPreKeyId;
    final kyber = antwort.kyberPreKey;
    final kyberSig = antwort.kyberPreKeySignature;
    if (kyberId == null || kyber == null || kyberSig == null) {
      throw GegenstelleOhneKyberException(antwort.userId, deviceId);
    }

    final otk = antwort.oneTimePreKey;
    return PreKeyBundle(
      registrationId: antwort.registrationId,
      deviceId: deviceId,
      preKeyId: otk?.keyId,
      preKeyPublic:
          otk == null ? null : Uint8List.fromList(base64.decode(otk.publicKey)),
      signedPreKeyId: antwort.signedPreKeyId,
      signedPreKeyPublic: base64.decode(antwort.signedPreKey),
      signedPreKeySignature: base64.decode(antwort.signedPreKeySignature),
      // Der IdentitaetsSCHLUESSEL will die 33-Byte-Form. Das Typ-Byte wird
      // hier wieder vorangestellt — die Umkehrung von rawPublicKeyOf().
      identityKey: [SignalIdentityBridge.curve25519Typ, ...identityRaw],
      kyberPreKeyId: kyberId,
      kyberPreKeyPublic: base64.decode(kyber),
      kyberPreKeySignature: base64.decode(kyberSig),
    );
  }
}
