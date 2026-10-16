// absender.dart — eine Gegenstelle mit eigenem libsignal-Speicher, und die
// Relay-Attrappe, die mitschreibt, was bestaetigt wurde.
//
// Stand bis 26.09.2026 in test/net/protokoll_befunde_test.dart; hier, weil
// auch test/net/fern_codewort_test.dart Umschlaege einer echten Gegenstelle
// einwerfen muss — zwei Kopien derselben Gegenstelle liefen sonst
// auseinander.
//
// Seit 2.0.0 ueber die offizielle libsignal (signal_hilfe.dart).

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

import 'relay_attrappe.dart';
import 'signal_hilfe.dart';

/// Die Attrappe, die ausserdem mitschreibt, was bestaetigt wurde.
class ZaehlRelay extends RelayAttrappe {
  ZaehlRelay(super.identity, super.lage);
  final bestaetigt = <int>[];
  @override
  void bestaetigeEmpfang(int q) => bestaetigt.add(q);
}

/// Eine Gegenstelle mit eigenem libsignal-Speicher.
class Absender {
  Absender._(this.store, this._geraetekarte);

  final BitdmSignalStore store;
  final Map<String, Object?> _geraetekarte;

  String get adresse => store.identity.address;

  static Future<Absender> neu() async {
    await signalBereit();
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final karte = await legePrekeysAb(store);
    return Absender._(store, karte);
  }

  /// Wie der Relay das Buendel dieser Gegenstelle ausliefert.
  Map<String, Object?> karte() => {
        'user_id': adresse,
        'identity_key': base64.encode(store.identity.rawPublicKey),
        ..._geraetekarte,
      };

  /// Rohe Nutzlast-Bytes an Geraet 1 von [an] — auch solche, die
  /// [Payload.toBytes] nie erzeugen wuerde.
  Future<Uint8List> rohAn(
      String an, RelayBundleResponse buendel, Uint8List klar) async {
    final ziel = adr(an);
    if (!await store.containsSession(ziel)) {
      await bauerVon(store)
          .processPreKeyBundle(ziel, PreKeyBundleBridge.fromRelay(buendel));
    }
    final ct = await chiffreVon(store).encrypt(ziel, klar);
    return Envelope.of(ct).toBytes();
  }

  Future<Uint8List> an(String an, RelayBundleResponse buendel, Payload p) =>
      rohAn(an, buendel, p.toBytes());
}
