// signal_identity.dart — die Bruecke zwischen unserer Schluesselableitung und
// libsignal.
//
// BitDM erzeugt den Identitaetsschluessel NICHT von libsignal, sondern leitet
// ihn aus der BIP39-Seed-Phrase ab (key_derivation.dart). Nur so ergibt
// dieselbe Wortfolge auf einem neuen Geraet wieder dieselbe Identitaet.
// Dieser Schluessel muss libsignal untergeschoben werden — und genau dabei
// lauern zwei Fallen, die keinen Fehler werfen, sondern still eine falsche
// Adresse erzeugen:
//
// FALLE 1 — Das Typ-Byte.
//   IdentityKey.serialize() liefert 33 Bytes: ein vorangestelltes 0x05
//   (Curve.djbType) plus die 32 echten Schluesselbytes. Unsere Adresse wird
//   aber ueber die ROHEN 32 Bytes gebildet. Wer serialize() an
//   BitdmAddress.encode gibt, bekommt eine voellig andere Adresse — ohne
//   Fehlermeldung. Aufgefallen waere das erst, wenn zwei Geraete sich nicht
//   mehr finden.
//   -> Richtig ist ECPublicKey.publicKey, nicht serialize().
//
// FALLE 2 — Die Mutation.
//   Curve.generateKeyPairFromPrivate veraendert die uebergebene Liste an Ort
//   und Stelle (private[0] &= 248 usw.). Wer seinen eigenen Schluessel
//   hineinreicht, haelt danach womoeglich veraenderte Bytes in der Hand.
//   -> Wir uebergeben grundsaetzlich eine Kopie.
//
// Beide Punkte sind in test/crypto/libsignal_bridge_test.dart festgenagelt,
// inklusive des Nachweises, dass der falsche Weg tatsaechlich eine andere
// Adresse ergibt.

import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'address.dart';
import 'key_derivation.dart';

/// Die libsignal-Sicht auf eine aus dem Seed abgeleitete Identitaet.
class SignalIdentity {
  /// Schluesselpaar in der Form, die libsignal erwartet.
  final IdentityKeyPair keyPair;

  /// Fortlaufende Kennung dieser Installation.
  ///
  /// libsignal verlangt sie je Geraet. Sie ist NICHT aus dem Seed abgeleitet:
  /// bei einer Wiederherstellung soll bewusst eine neue entstehen, damit die
  /// Gegenstellen die alten Sitzungen verwerfen ("letzte Wiederherstellung
  /// gewinnt", siehe PLAN.md §2).
  final int registrationId;

  const SignalIdentity({required this.keyPair, required this.registrationId});

  /// Die rohen 32 Bytes des oeffentlichen Schluessels — ohne Typ-Byte.
  Uint8List get rawPublicKey =>
      SignalIdentityBridge.rawPublicKeyOf(keyPair.getPublicKey());

  /// Die BitDM-Adresse dieser Identitaet.
  String get address => BitdmAddress.encode(rawPublicKey);

  @override
  String toString() => 'SignalIdentity($address)';
}

class SignalIdentityBridge {
  SignalIdentityBridge._();

  /// Baut aus den abgeleiteten Schluesseln ein libsignal-Schluesselpaar.
  ///
  /// [registrationId] wird bei der Erstanlage und bei jeder Wiederherstellung
  /// neu erzeugt; sie darf nicht aus dem Seed stammen.
  static SignalIdentity fromDerived(
    DerivedKeys derived, {
    required int registrationId,
  }) {
    // Kopie: generateKeyPairFromPrivate veraendert die Liste an Ort und Stelle.
    final privateCopy = Uint8List.fromList(derived.identityPrivateKey);
    final pair = Curve.generateKeyPairFromPrivate(privateCopy);

    final identity = IdentityKeyPair(
      IdentityKey(pair.publicKey),
      pair.privateKey,
    );

    return SignalIdentity(keyPair: identity, registrationId: registrationId);
  }

  /// Erzeugt eine neue Kennung fuer diese Installation. Bereich 1..16380.
  ///
  /// `generateRegistrationId` ist in libsignal eine freie Funktion, keine
  /// Klassenmethode. Der Parameter `extendedRange` bleibt false: der grosse
  /// Bereich ist fuer Installationen mit sehr vielen Geraeten gedacht, BitDM
  /// hat eines je Identitaet.
  static int newRegistrationId() => generateRegistrationId(false);

  /// Rohe 32 Bytes aus einem libsignal-Identitaetsschluessel.
  ///
  /// Bewusst als benannte Funktion statt als beilaeufiger Feldzugriff, damit an
  /// der Aufrufstelle sichtbar ist, dass hier NICHT serialize() gemeint ist.
  static Uint8List rawPublicKeyOf(IdentityKey key) {
    final pub = key.publicKey;
    if (pub is! DjbECPublicKey) {
      // libsignal kennt derzeit nur diesen Typ. Faellt das je anders aus,
      // soll es hier auffallen und nicht still eine falsche Adresse geben.
      throw StateError('unerwarteter Schluesseltyp: ${pub.runtimeType}');
    }
    return Uint8List.fromList(pub.publicKey);
  }

  /// Adresse einer fremden Identitaet, z. B. aus einem Prekey-Bundle.
  static String addressOf(IdentityKey key) =>
      BitdmAddress.encode(rawPublicKeyOf(key));
}
