// prekey_bundle_bridge.dart — zwischen Relay-Format und libsignal.
//
// Hier und nur hier wird umgerechnet. Der Grund fuer eine eigene Datei ist der
// Stolperstein mit den Schluessellaengen: libsignal serialisiert oeffentliche
// Schluessel MIT vorangestelltem Typ-Byte 0x05 (33 Bytes), die Adresse und die
// Signaturpruefung des Servers brauchen aber die rohen 32. Waere das ueber
// mehrere Dateien verteilt, wuerde die Verwechslung irgendwann passieren — und
// sie faellt nicht sofort auf, sondern erst als Sitzungsaufbau, der still
// scheitert.

import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/signal_identity.dart';
import 'relay_protocol.dart';

class PreKeyBundleBridge {
  /// Baut aus dem eigenen Zustand das Bundle, das der Relay speichert.
  ///
  /// [oneTimePreKeys] duerfen leer sein — dann kann eine Gegenstelle zwar noch
  /// eine Sitzung aufbauen, aber ohne die zusaetzliche Absicherung durch einen
  /// Einmalschluessel.
  static RelayPreKeyBundle toRelay({
    required SignalIdentity identity,
    required SignedPreKeyRecord signedPreKey,
    required List<PreKeyRecord> oneTimePreKeys,
  }) {
    return RelayPreKeyBundle(
      userId: identity.address,
      // ROH, 32 Bytes: der Server rechnet die Adresse daraus nach und prueft
      // damit die Signatur. Mit serialize() waeren es 33 und beides schlaegt
      // fehl.
      identityKey: base64.encode(
          SignalIdentityBridge.rawPublicKeyOf(identity.keyPair.getPublicKey())),
      registrationId: identity.registrationId,
      signedPreKeyId: signedPreKey.id,
      // SERIALISIERT, 33 Bytes: fuer den Server ein undurchsichtiger Block,
      // den die Gegenstelle mit Curve.decodePoint wieder einliest.
      signedPreKey:
          base64.encode(signedPreKey.getKeyPair().publicKey.serialize()),
      signedPreKeySignature: base64.encode(signedPreKey.signature),
      oneTimePreKeys: [
        for (final k in oneTimePreKeys)
          RelayOneTimePreKey(
            keyId: k.id,
            publicKey: base64.encode(k.getKeyPair().publicKey.serialize()),
          ),
      ],
    );
  }

  /// Macht aus der Antwort des Relays ein Bundle, mit dem libsignal eine
  /// Sitzung aufbauen kann.
  ///
  /// [deviceId] ist bei BitDM immer 1 — eine Identitaet, ein Geraet.
  static PreKeyBundle fromRelay(RelayBundleResponse antwort,
      {int deviceId = 1}) {
    final identityRaw = base64.decode(antwort.identityKey);
    if (identityRaw.length != 32) {
      throw FormatException(
          'Identitaetsschluessel hat ${identityRaw.length} statt 32 Bytes');
    }

    final otk = antwort.oneTimePreKey;
    return PreKeyBundle(
      antwort.registrationId,
      deviceId,
      otk?.keyId,
      otk == null
          ? null
          : Curve.decodePoint(
              Uint8List.fromList(base64.decode(otk.publicKey)), 0),
      antwort.signedPreKeyId,
      Curve.decodePoint(
          Uint8List.fromList(base64.decode(antwort.signedPreKey)), 0),
      Uint8List.fromList(base64.decode(antwort.signedPreKeySignature)),
      // Der IdentitaetsSCHLUESSEL will die 33-Byte-Form. Das Typ-Byte wird
      // hier wieder vorangestellt — die Umkehrung von rawPublicKeyOf().
      IdentityKey.fromBytes(
          Uint8List.fromList([0x05, ...identityRaw]), 0),
    );
  }
}
