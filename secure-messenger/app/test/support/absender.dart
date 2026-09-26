// absender.dart — eine Gegenstelle mit eigenem libsignal-Speicher, und die
// Relay-Attrappe, die mitschreibt, was bestaetigt wurde.
//
// Stand bis 26.09.2026 in test/net/protokoll_befunde_test.dart; hier, weil
// auch test/net/fern_codewort_test.dart Umschlaege einer echten Gegenstelle
// einwerfen muss — zwei Kopien derselben Gegenstelle liefen sonst
// auseinander.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'relay_attrappe.dart';

/// Die Attrappe, die ausserdem mitschreibt, was bestaetigt wurde.
class ZaehlRelay extends RelayAttrappe {
  ZaehlRelay(super.identity, super.lage);
  final bestaetigt = <int>[];
  @override
  void bestaetigeEmpfang(int q) => bestaetigt.add(q);
}

/// Eine Gegenstelle mit eigenem libsignal-Speicher.
class Absender {
  Absender._(this.store, this._spk, this._otk);

  final BitdmSignalStore store;
  final SignedPreKeyRecord _spk;
  final PreKeyRecord _otk;

  String get adresse => store.identity.address;

  static Future<Absender> neu() async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final spk = generateSignedPreKey(id.keyPair, 1);
    await store.storeSignedPreKey(spk.id, spk);
    final otk = generatePreKeys(500, 1).first;
    await store.storePreKey(otk.id, otk);
    return Absender._(store, spk, otk);
  }

  /// Wie der Relay das Buendel dieser Gegenstelle ausliefert.
  Map<String, Object?> karte() => {
        'user_id': adresse,
        'identity_key': base64.encode(store.identity.rawPublicKey),
        'registration_id': store.identity.registrationId,
        'signed_prekey_id': _spk.id,
        'signed_prekey': base64.encode(_spk.getKeyPair().publicKey.serialize()),
        'signed_prekey_sig': base64.encode(_spk.signature),
        'one_time_prekey': {
          'key_id': _otk.id,
          'public_key': base64.encode(_otk.getKeyPair().publicKey.serialize()),
        },
      };

  /// Rohe Nutzlast-Bytes an Geraet 1 von [an] — auch solche, die
  /// [Payload.toBytes] nie erzeugen wuerde.
  Future<Uint8List> rohAn(
      String an, RelayBundleResponse buendel, Uint8List klar) async {
    final ziel = SignalProtocolAddress(an, 1);
    if (!await store.containsSession(ziel)) {
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(buendel));
    }
    final ct = await SessionCipher.fromStore(store, ziel).encrypt(klar);
    return Envelope.of(ct).toBytes();
  }

  Future<Uint8List> an(String an, RelayBundleResponse buendel, Payload p) =>
      rohAn(an, buendel, p.toBytes());
}
