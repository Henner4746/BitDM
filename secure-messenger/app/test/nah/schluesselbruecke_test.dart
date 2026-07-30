// schluesselbruecke_test.dart — rechnen beide Bibliotheken dasselbe?
//
// DIE FRAGE, AN DER DER GANZE NAHEBEREICH HAENGT
//
// Das Leuchtfeuer braucht ein gemeinsames Geheimnis aus X25519. Es gibt im
// Projekt aber ZWEI Wege dorthin:
//
//   libsignal    `Curve.calculateAgreement(fremderOeffentlicher, eigenerPrivater)`
//                — das ist der Schluessel, den die App ohnehin hat.
//   cryptography `X25519().sharedSecretKey(...)`
//                — das benutzt leuchtfeuer.dart.
//
// Beide sind X25519 nach RFC 7748 und muessen dieselben 32 Byte liefern.
// "Muessen" ist hier aber genau die Sorte Annahme, die dieses Projekt schon
// zweimal Tage gekostet hat: die 33-gegen-32-Byte-Falle bei libsignal
// (ein vorangestelltes Typbyte) und `Ecdh.p256`, das UnimplementedError wirft.
//
// Waeren die Ergebnisse verschieden, wuerde nichts abstuerzen und nichts
// scheitern. Zwei Telefone wuerden nur nie voneinander Notiz nehmen — der
// unangenehmste denkbare Fehler, weil er wie "Bluetooth ist halt unzuverlaessig"
// aussieht.

import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Eine Identitaet, genau so gebaut wie in der App.
///
/// Nicht mit `Curve.generateKeyPair()` abgekuerzt: der Weg ueber die Phrase
/// ist der einzige, den die App wirklich geht, und ein Test, der einen
/// anderen nimmt, prueft einen Schluessel, den es nie gibt.
Future<SignalIdentity> neueIdentitaet() async {
  final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
  return SignalIdentityBridge.fromDerived(keys,
      registrationId: SignalIdentityBridge.newRegistrationId());
}

/// Der Weg ueber libsignal, wie ihn der Kern gehen wuerde.
Uint8List ueberLibsignal(SignalIdentity eigene, Uint8List fremderOeffentlicher) {
  // DJB_TYPE davor: libsignal fuehrt oeffentliche Schluessel mit einem
  // Typbyte. `BitdmAddress.decode` liefert die 32 nackten Bytes, und
  // `Curve.decodePoint` erwartet 33 — genau die Falle aus dem Dateikopf von
  // signal_identity.dart.
  final mitTyp = Uint8List(33)
    ..[0] = 5 // Curve.djbType
    ..setRange(1, 33, fremderOeffentlicher);
  final fremd = Curve.decodePoint(mitTyp, 0);
  return Uint8List.fromList(
      Curve.calculateAgreement(fremd, eigene.keyPair.getPrivateKey()));
}

/// Der Weg ueber das cryptography-Paket, wie ihn leuchtfeuer.dart geht.
Future<Uint8List> ueberCryptography(
    Uint8List eigenerPrivater, Uint8List fremderOeffentlicher) async {
  final paar = await X25519().newKeyPairFromSeed(eigenerPrivater);
  return Leuchtfeuer.gemeinsamesGeheimnis(
      eigenerSchluessel: paar, fremderOeffentlicher: fremderOeffentlicher);
}

void main() {
  test('BEIDE WEGE LIEFERN DASSELBE GEHEIMNIS', () async {
    final anna = await neueIdentitaet();
    final bert = await neueIdentitaet();

    final annaPub = BitdmAddress.decode(anna.address);
    final bertPub = BitdmAddress.decode(bert.address);

    final ueberSignal = ueberLibsignal(anna, bertPub);
    final ueberPaket = await ueberCryptography(
        Uint8List.fromList(anna.keyPair.getPrivateKey().serialize()), bertPub);

    expect(ueberSignal, ueberPaket,
        reason: 'sonst rechnen die beiden Seiten verschiedene Leuchtfeuer und '
            'zwei Telefone sehen einander nie — ohne dass irgendwo ein Fehler '
            'auftaucht');
    expect(ueberSignal.length, 32);

    // Und die Gegenrichtung: was Bert rechnet, muss dasselbe sein.
    final andersherum = ueberLibsignal(bert, annaPub);
    expect(andersherum, ueberSignal,
        reason: 'ein gemeinsames Geheimnis ist gemeinsam oder keines');
  });

  test('die Adresse traegt wirklich den Identitaetsschluessel', () async {
    // Der Entwurf des Nahbereichs steht darauf: aus einer Adresse allein
    // laesst sich der oeffentliche Schluessel gewinnen, ohne Server.
    final wer = await neueIdentitaet();
    expect(BitdmAddress.decode(wer.address), wer.rawPublicKey);
  });

  test('ein fremder Schluessel ergibt ein ANDERES Geheimnis', () async {
    // Die Gegenprobe. Ohne sie koennte der erste Test auch dann bestehen,
    // wenn beide Wege dieselbe Konstante zurueckgaeben.
    final anna = await neueIdentitaet();
    final bert = await neueIdentitaet();
    final fremd = await neueIdentitaet();

    final mitBert = ueberLibsignal(anna, BitdmAddress.decode(bert.address));
    final mitFremd = ueberLibsignal(anna, BitdmAddress.decode(fremd.address));
    expect(mitBert, isNot(mitFremd));
  });
}
