// libsignal_bridge_test.dart — nagelt die Uebergabe unseres abgeleiteten
// Schluessels an libsignal fest.
//
// Das ist die riskanteste Stelle des ganzen Krypto-Kerns: Hier treffen unsere
// eigene Ableitung und eine fremde Bibliothek aufeinander, und beide koennten
// unterschiedliche Annahmen ueber Clamping und Byte-Format haben. Ein Fehler
// wirft hier keine Ausnahme — er erzeugt still eine andere Adresse, und das
// faellt erst auf, wenn zwei Geraete sich nicht finden.
//
// Deshalb wird hier nicht nur der richtige Weg geprueft, sondern auch
// nachgewiesen, dass der falsche tatsaechlich schiefgeht.

import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _phrase = [
  'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
  'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'about',
];

void main() {
  group('Unsere Ableitung und libsignal kommen zum selben Ergebnis', () {
    test('gleicher oeffentlicher Schluessel, Byte fuer Byte', () async {
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity = SignalIdentityBridge.fromDerived(
        derived,
        registrationId: SignalIdentityBridge.newRegistrationId(),
      );

      // Links: unsere X25519-Ableitung. Rechts: libsignals eigene Rechnung
      // aus demselben Privatschluessel. Weichen sie ab, waere die Identitaet
      // davon abhaengig, welcher Code sie gerade berechnet.
      expect(identity.rawPublicKey, derived.identityPublicKey);
    });

    test('gleiche BitDM-Adresse', () async {
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity = SignalIdentityBridge.fromDerived(
        derived,
        registrationId: SignalIdentityBridge.newRegistrationId(),
      );
      expect(identity.address, derived.address);
    });

    test('libsignal clamped genauso wie wir', () async {
      // Curve.generateKeyPairFromPrivate wendet &=248, &=127, |=64 an — genau
      // unser _clampX25519. Weil wir bereits geclamped uebergeben, darf sich
      // nichts mehr aendern.
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity = SignalIdentityBridge.fromDerived(
        derived,
        registrationId: 1,
      );
      final privFromSignal =
          (identity.keyPair.getPrivateKey() as DjbECPrivateKey).serialize();
      expect(privFromSignal, derived.identityPrivateKey);
    });

    test('gilt fuer beliebige Phrasen, nicht nur die eine', () async {
      for (var i = 0; i < 10; i++) {
        final words = Bip39.generate();
        final derived = await KeyDerivation.fromMnemonic(words);
        final identity =
            SignalIdentityBridge.fromDerived(derived, registrationId: 1);
        expect(identity.address, derived.address,
            reason: 'Abweichung bei ${words.take(3).join(" ")}…');
      }
    });
  });

  group('Die Fallen, gegen die diese Bruecke existiert', () {
    test('serialize() liefert 33 Bytes mit Typ-Byte 0x05, nicht 32', () async {
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity =
          SignalIdentityBridge.fromDerived(derived, registrationId: 1);

      final serialized = identity.keyPair.getPublicKey().serialize();
      expect(serialized.length, 33,
          reason: 'libsignal stellt Curve.djbType voran');
      expect(serialized.first, 0x05);
      expect(serialized.sublist(1), derived.identityPublicKey);
    });

    test('serialize() an die Adressberechnung zu geben, ergibt eine ANDERE '
        'Adresse — deshalb gibt es rawPublicKeyOf()', () async {
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity =
          SignalIdentityBridge.fromDerived(derived, registrationId: 1);

      final richtig = BitdmAddress.encode(identity.rawPublicKey);

      // Der naheliegende Fehler: serialize() nehmen. Es sind 33 Bytes, unsere
      // Kodierung verlangt aber 32 — sie wirft. Wuerde jemand stattdessen die
      // ersten 32 Bytes abschneiden, entstuende klaglos eine falsche Adresse.
      final serialized = identity.keyPair.getPublicKey().serialize();
      expect(() => BitdmAddress.encode(serialized),
          throwsA(isA<InvalidAddressFormatException>()));

      final abgeschnitten =
          BitdmAddress.encode(Uint8List.fromList(serialized.sublist(0, 32)));
      expect(abgeschnitten, isNot(richtig),
          reason: 'genau dieser stille Fehler soll hier dokumentiert sein');
    });

    test('generateKeyPairFromPrivate veraendert seine Eingabe', () {
      // Deshalb uebergibt die Bruecke eine Kopie. Ohne das haette der Aufrufer
      // danach womoeglich veraenderte Schluesselbytes in der Hand.
      final ungeclampt = Uint8List.fromList(List<int>.filled(32, 0xFF));
      final vorher = Uint8List.fromList(ungeclampt);
      Curve.generateKeyPairFromPrivate(ungeclampt);
      expect(ungeclampt, isNot(equals(vorher)),
          reason: 'libsignal clamped an Ort und Stelle');
    });

    test('die Bruecke selbst laesst den Ausgangsschluessel unangetastet',
        () async {
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final vorher = Uint8List.fromList(derived.identityPrivateKey);
      SignalIdentityBridge.fromDerived(derived, registrationId: 1);
      expect(derived.identityPrivateKey, vorher);
    });
  });

  group('Fremde Identitaeten', () {
    test('Adresse einer Gegenstelle laesst sich aus ihrem IdentityKey bilden',
        () async {
      // So kommt es spaeter aus einem Prekey-Bundle vom Server.
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity =
          SignalIdentityBridge.fromDerived(derived, registrationId: 1);

      final fremd = identity.keyPair.getPublicKey();
      expect(SignalIdentityBridge.addressOf(fremd), derived.address);
    });

    test('Rundlauf ueber die Serialisierung bleibt stabil', () async {
      // Der Server reicht Schluessel als Bytes durch; nach dem Wiedereinlesen
      // muss dieselbe Adresse herauskommen.
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity =
          SignalIdentityBridge.fromDerived(derived, registrationId: 1);

      final bytes = identity.keyPair.getPublicKey().serialize();
      final wieder = IdentityKey.fromBytes(bytes, 0);
      expect(SignalIdentityBridge.addressOf(wieder), derived.address);
    });
  });

  group('registrationId', () {
    test('ist NICHT aus dem Seed abgeleitet', () async {
      // Bei einer Wiederherstellung soll bewusst eine neue entstehen, damit
      // Gegenstellen die alten Sitzungen verwerfen.
      final a = SignalIdentityBridge.newRegistrationId();
      final b = SignalIdentityBridge.newRegistrationId();
      final c = SignalIdentityBridge.newRegistrationId();
      expect({a, b, c}.length, greaterThan(1));
    });

    test('liegt im von libsignal erwarteten Bereich', () {
      for (var i = 0; i < 50; i++) {
        final id = SignalIdentityBridge.newRegistrationId();
        expect(id, greaterThan(0));
        expect(id, lessThanOrEqualTo(16380));
      }
    });
  });
}
