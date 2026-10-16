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
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

const _phrase = [
  'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'abandon',
  'abandon', 'abandon', 'abandon', 'abandon', 'abandon', 'about',
];

void main() {
  setUpAll(signalBereit);

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

    test('libsignal behaelt unseren geklammerten Schluessel unveraendert',
        () async {
      // Wir uebergeben bereits geklammert (_clampX25519). Was libsignal als
      // privaten Schluessel fuehrt, muss Byte fuer Byte derselbe sein — sonst
      // waere offen, mit welchem Schluessel signiert wird.
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity = SignalIdentityBridge.fromDerived(
        derived,
        registrationId: 1,
      );
      expect(identity.keyPair.privateKey, derived.identityPrivateKey);
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

      final serialized = identity.keyPair.publicKey;
      expect(serialized.length, 33,
          reason: 'libsignal stellt das Typ-Byte voran');
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
      final serialized = identity.keyPair.publicKey;
      expect(() => BitdmAddress.encode(serialized),
          throwsA(isA<InvalidAddressFormatException>()));

      final abgeschnitten =
          BitdmAddress.encode(Uint8List.fromList(serialized.sublist(0, 32)));
      expect(abgeschnitten, isNot(richtig),
          reason: 'genau dieser stille Fehler soll hier dokumentiert sein');
    });

    test('PrivateKey.deserialize kopiert — die Dart-Liste bleibt, wie sie ist',
        () {
      // Gemessen, nicht vermutet: flutter_rust_bridge kopiert die Bytes nach
      // Rust, und genullt wird dort nur die Rust-Kopie ("The input bytes are
      // securely zeroized" bezieht sich auf sie). Die Liste des Aufrufers
      // bleibt unveraendert. Die Bruecke uebergibt trotzdem eine eigene Kopie,
      // damit das bei einer kuenftigen Anbindung nicht anders ausgeht.
      final eingabe = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final vorher = Uint8List.fromList(eingabe);
      PrivateKey.deserialize(bytes: eingabe);
      expect(eingabe, vorher);
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

      final fremd = identity.publicKey;
      expect(SignalIdentityBridge.addressOf(fremd), derived.address);
    });

    test('Rundlauf ueber die Serialisierung bleibt stabil', () async {
      // Der Server reicht Schluessel als Bytes durch; nach dem Wiedereinlesen
      // muss dieselbe Adresse herauskommen.
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final identity =
          SignalIdentityBridge.fromDerived(derived, registrationId: 1);

      final bytes = identity.keyPair.publicKey;
      final wieder = PublicKey.deserialize(bytes: bytes);
      expect(SignalIdentityBridge.addressOf(wieder), derived.address);
    });

    test('publicKeyOfAddress ist die Umkehrung von addressOf', () async {
      final derived = await KeyDerivation.fromMnemonic(_phrase);
      final schluessel =
          SignalIdentityBridge.publicKeyOfAddress(derived.address);
      expect(SignalIdentityBridge.addressOf(schluessel), derived.address);
    });

    test('ein fremder Schluesseltyp wird nicht still zur Adresse', () {
      // Ein Kyber-Schluessel hat Typ 0x08 und 1569 Bytes. rawPublicKeyOf muss
      // werfen statt irgendetwas zu kodieren.
      final kyber = KyberKeyPair.generate().getPublicKey().serialize();
      expect(() => SignalIdentityBridge.rawPublicKeyOfSerialized(kyber),
          throwsStateError);
    });
  });

  group('registrationId', () {
    test('ist NICHT aus dem Seed abgeleitet', () async {
      // Bei einer Wiederherstellung soll bewusst eine neue entstehen; zwei
      // Geraete derselben Adresse fuehren verschiedene.
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
