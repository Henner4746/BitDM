// sitzungsdatensatz_test.dart — liest der Kern den Basisschluessel richtig?
//
// Der Sitzungsnachweis (docs/GERAETEABMELDUNG.md §12.5 b) haengt daran, dass
// `offenerBasisschluessel` aus libsignals Datensatz genau den Schluessel holt,
// den die naechste PreKey-Nachricht traegt — und dass er verschwindet, sobald
// die Gegenstelle geantwortet hat. Geprueft gegen echte libsignal-Nachrichten,
// nicht gegen eine zweite Annahme ueber die Feldnummern.

import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/crypto/sitzungsdatensatz.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

Future<BitdmSignalStore> _speicher() async {
  final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
  final id = SignalIdentityBridge.fromDerived(keys,
      registrationId: SignalIdentityBridge.newRegistrationId());
  return BitdmSignalStore(identity: id);
}

Future<PreKeyBundle> _buendel(BitdmSignalStore s) async {
  final spk = neuerSpk(s.identity.keyPair, 1);
  await s.storeSignedPreKey(1, spk);
  final kyber = neuerKyber(s.identity.keyPair, 1);
  await s.storeLastResortKyberPreKey(1, kyber);
  final otk = neuerPreKey(7);
  await s.storePreKey(7, otk);
  return PreKeyBundle(
    registrationId: s.identity.registrationId,
    deviceId: 1,
    preKeyId: 7,
    preKeyPublic: otk.publicKey(),
    signedPreKeyId: 1,
    signedPreKeyPublic: spk.publicKey(),
    signedPreKeySignature: spk.signature(),
    identityKey: s.identity.keyPair.publicKey,
    kyberPreKeyId: 1,
    kyberPreKeyPublic: kyber.getPublicKey().serialize(),
    kyberPreKeySignature: kyber.signature(),
  );
}

void main() {
  setUpAll(signalBereit);

  test('der Basisschluessel im Datensatz ist der der PreKey-Nachricht — und '
      'faellt mit der ersten Antwort weg', () async {
    final anna = await _speicher();
    final bob = await _speicher();
    final zuBob = adr(bob.identity.address);
    final zuAnna = adr(anna.identity.address);
    await bauerVon(anna).processPreKeyBundle(zuBob, await _buendel(bob));

    final vorher = offenerBasisschluessel((await anna.loadSession(zuBob))!.serialize());
    expect(vorher, isNotNull);
    expect(vorher!.length, 33, reason: 'mit Typbyte 0x05, wie baseKey()');

    // Zwei Nachrichten vor der Antwort: beide PreKey, beide mit demselben
    // Basisschluessel — und der steht vorher schon im Datensatz.
    for (var i = 0; i < 2; i++) {
      final ct = await chiffreVon(anna).encrypt(zuBob, text('hallo $i'));
      expect(ct.type, CiphertextMessageType.preKey);
      final erst = PreKeySignalMessage.deserialize(data: ct.ciphertext);
      expect(gleich(erst.baseKey(), vorher), isTrue);
      await chiffreVon(bob).decrypt(
          zuAnna, CiphertextMessage(type: ct.type, ciphertext: ct.ciphertext));
    }

    final antwort = await chiffreVon(bob).encrypt(zuAnna, text('hallo zurueck'));
    await chiffreVon(anna).decrypt(zuBob,
        CiphertextMessage(type: antwort.type, ciphertext: antwort.ciphertext));
    expect(offenerBasisschluessel((await anna.loadSession(zuBob))!.serialize()),
        isNull,
        reason: 'nach der Antwort schickt libsignal keine PreKey-Nachricht mehr');
    final danach = await chiffreVon(anna).encrypt(zuBob, text('weiter'));
    expect(danach.type, isNot(CiphertextMessageType.preKey));

    // Beim Empfaenger hat die Sitzung nie einen offenen Basisschluessel.
    expect(offenerBasisschluessel((await bob.loadSession(zuAnna))!.serialize()),
        isNull);
  });

  test('Unsinn ergibt null, keinen Wurf', () {
    expect(offenerBasisschluessel(const []), isNull);
    expect(offenerBasisschluessel(Uint8List.fromList([0x0a, 0x7f, 1, 2])), isNull);
    expect(offenerBasisschluessel(Uint8List.fromList([0xff, 0xff, 0xff])), isNull);
    expect(offenerBasisschluessel(Uint8List.fromList(List.filled(40, 0x80))), isNull);
  });
}
