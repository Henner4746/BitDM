// signal_identity.dart — die Bruecke zwischen unserer Schluesselableitung und
// libsignal.
//
// BitDM erzeugt den Identitaetsschluessel NICHT von libsignal, sondern leitet
// ihn aus der BIP39-Seed-Phrase ab (key_derivation.dart). Nur so ergibt
// dieselbe Wortfolge auf einem neuen Geraet wieder dieselbe Identitaet.
// Dieser Schluessel muss libsignal untergeschoben werden — und dabei lauert
// eine Falle, die keinen Fehler wirft, sondern still eine falsche Adresse
// erzeugt:
//
// DAS TYP-BYTE.
//   PublicKey.serialize() (und IdentityKeyPair.publicKey) liefern 33 Bytes:
//   ein vorangestelltes 0x05 (Curve25519) plus die 32 echten Schluesselbytes.
//   Unsere Adresse wird aber ueber die ROHEN 32 Bytes gebildet. Wer die 33
//   Bytes an BitdmAddress.encode gibt, bekommt eine voellig andere Adresse —
//   ohne Fehlermeldung.
//   -> Richtig ist [SignalIdentityBridge.rawPublicKeyOf], die das Typ-Byte
//      PRUEFT und abschneidet.
//
// SEIT 2.0.0 IST DAS SIGNALS OFFIZIELLE libsignal (Rust) statt der
// Dart-Nachbildung libsignal_protocol_dart. Am 16.10.2026 nachgewiesen
// (docs/LIBSIGNAL-UMSTIEG.md, Abschnitt Machbarkeit): derselbe geklammerte
// Schluessel aus key_derivation.dart ergibt in beiden Bibliotheken
// byte-gleich dieselbe Adresse. Bestehende Adressen bleiben also gueltig.
// Die Falle "generateKeyPairFromPrivate veraendert die Eingabe" der alten
// Bibliothek gibt es nicht mehr: PrivateKey.deserialize kopiert die Bytes nach
// Rust und nullt nur dort (gemessen, libsignal_bridge_test). Es geht trotzdem
// eine Kopie hinein, damit eine kuenftige Anbindung das nicht aendern kann.
//
// Festgenagelt in test/crypto/libsignal_bridge_test.dart.

import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

import 'address.dart';
import 'key_derivation.dart';

/// Die libsignal-Sicht auf eine aus dem Seed abgeleitete Identitaet.
class SignalIdentity {
  /// Schluesselpaar in der Form, die libsignal erwartet.
  final IdentityKeyPair keyPair;

  /// Fortlaufende Kennung dieser Installation. libsignal verlangt sie.
  ///
  /// SIE BEWIRKT NICHTS DARUEBER HINAUS. Zwei Geraete derselben Adresse
  /// fuehren verschiedene Nummern; ob am anderen Ende wirklich der Richtige
  /// sitzt, entscheidet die Nachrechnung der Adresse aus dem Schluessel
  /// (signal_store `_keyMatchesAddress`), nicht diese Zahl.
  ///
  /// Sie ist NICHT aus dem Seed abgeleitet: zwei Geraete sollen verschiedene
  /// fuehren, so wie es libsignal vorsieht.
  final int registrationId;

  const SignalIdentity({required this.keyPair, required this.registrationId});

  /// Die rohen 32 Bytes des oeffentlichen Schluessels — ohne Typ-Byte.
  Uint8List get rawPublicKey =>
      SignalIdentityBridge.rawPublicKeyOfSerialized(keyPair.publicKey);

  /// Der oeffentliche Schluessel als libsignal-Objekt.
  PublicKey get publicKey => PublicKey.deserialize(bytes: keyPair.publicKey);

  /// Die BitDM-Adresse dieser Identitaet.
  String get address => BitdmAddress.encode(rawPublicKey);

  @override
  String toString() => 'SignalIdentity($address)';
}

class SignalIdentityBridge {
  SignalIdentityBridge._();

  /// Das Typ-Byte von libsignal fuer Curve25519-Schluessel.
  static const int curve25519Typ = 0x05;

  /// Baut aus den abgeleiteten Schluesseln ein libsignal-Schluesselpaar.
  ///
  /// [registrationId] wird bei der Erstanlage und bei jeder Wiederherstellung
  /// neu erzeugt; sie darf nicht aus dem Seed stammen.
  static SignalIdentity fromDerived(
    DerivedKeys derived, {
    required int registrationId,
  }) {
    // Kopie: siehe Dateikopf.
    final privat =
        PrivateKey.deserialize(bytes: Uint8List.fromList(derived.identityPrivateKey));
    final paar =
        IdentityKeyPair.fromKeys(privateKey: privat, publicKey: privat.getPublicKey());
    final identitaet =
        SignalIdentity(keyPair: paar, registrationId: registrationId);

    // GEGENPROBE: Die Adresse, die libsignal aus dem privaten Schluessel
    // rechnet, muss die sein, die key_derivation.dart unabhaengig davon
    // gerechnet hat. Weicht sie ab, haette dieses Geraet still eine andere
    // Identitaet als die zwoelf Woerter versprechen — das darf nie
    // unbemerkt passieren.
    if (identitaet.address != derived.address) {
      throw StateError('libsignal rechnet aus demselben Schluessel eine '
          'andere Adresse');
    }
    return identitaet;
  }

  /// Erzeugt eine neue Kennung fuer diese Installation. Bereich 1..16380.
  ///
  /// Derselbe Bereich wie libsignals `generateRegistrationId(false)`; die
  /// offizielle Anbindung bringt keine solche Funktion mit.
  static int newRegistrationId() => Random.secure().nextInt(16380) + 1;

  /// Rohe 32 Bytes aus einem libsignal-Schluessel.
  ///
  /// Bewusst als benannte Funktion statt als beilaeufiger Feldzugriff, damit an
  /// der Aufrufstelle sichtbar ist, dass hier NICHT serialize() gemeint ist.
  static Uint8List rawPublicKeyOf(PublicKey key) =>
      rawPublicKeyOfSerialized(key.serialize());

  /// Rohe 32 Bytes aus der 33-Byte-Form mit Typ-Byte.
  ///
  /// Wirft bei jedem anderen Aufbau. libsignal kennt fuer Identitaeten derzeit
  /// nur Curve25519; faellt das je anders aus, soll es hier auffallen und
  /// nicht still eine falsche Adresse geben.
  static Uint8List rawPublicKeyOfSerialized(List<int> serialisiert) {
    if (serialisiert.length != 33 || serialisiert[0] != curve25519Typ) {
      throw StateError('unerwarteter Schluesselaufbau: '
          '${serialisiert.length} Byte, Typ ${serialisiert.isEmpty ? '-' : serialisiert[0]}');
    }
    return Uint8List.fromList(serialisiert.sublist(1));
  }

  /// Adresse einer fremden Identitaet, z. B. aus einem Prekey-Bundle.
  static String addressOf(PublicKey key) =>
      BitdmAddress.encode(rawPublicKeyOf(key));

  /// libsignal-Schluessel aus einer BitDM-Adresse.
  ///
  /// Die Adresse traegt die rohen 32 Bytes; libsignal will sie mit Typ-Byte.
  static PublicKey publicKeyOfAddress(String address) => PublicKey.deserialize(
      bytes: [curve25519Typ, ...BitdmAddress.decode(address)]);
}
