// hardware_key_factor_test.dart — die ganze Kette gegen einen nachgebauten
// Stick.
//
// Hier laufen zum ersten Mal alle Teile zusammen: kanonisches CBOR, der
// Schluesselaustausch, die PIN, die hmac-secret-Erweiterung und das
// Schluesselfach. Die Gegenseite (test/fido/fake_stick.dart) ist nach der
// Spezifikation gebaut und nicht nach dem, was der Client tut — sie rechnet
// ECDH, AES und HMAC unabhaengig nach und lehnt ab, wenn etwas nicht passt.
//
// Was ein echter Titan zusaetzlich beitraegt, ist nur das, was sich nicht
// nachbauen laesst: seine eigene Auslegung von Randfaellen und die Beruehrung.

import 'dart:typed_data';

import 'package:bitdm/core/fido/client_pin.dart';
import 'package:bitdm/core/fido/ctap.dart';
import 'package:bitdm/core/lock/hardware_key_factor.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_stick.dart';

Uint8List geheimnis() => Uint8List.fromList(List.generate(16, (i) => i * 3));

/// Baut einen Faktor, der immer denselben Stick vorfindet.
HardwareKeyFactor faktor(FakeStick stick, {String? pin = '123456'}) =>
    HardwareKeyFactor(oeffne: () async => stick, pin: pin);

void main() {
  group('Einrichten und wieder oeffnen', () {
    test('DER Durchgang: Fach anlegen, Fach oeffnen, dasselbe heraus',
        () async {
      // Wenn dieser Test gruen ist, funktioniert die Stick-Sperre. Wenn er rot
      // ist, sagt der Stick spaeter nur "Ungueltiger Parameter".
      final stick = FakeStick();
      final f = faktor(stick);

      final slot = await f.createSlot(geheimnis(), createdAt: 1);
      expect(slot.kind, UnlockFactorKind.hardwareKey);
      expect(slot.handle, isNotNull,
          reason: 'ohne Zugangskennung liesse sich das Fach nie wieder oeffnen');

      final zurueck = await faktor(stick).unlock(slot);
      expect(zurueck, geheimnis());
    });

    test('zwei Beruehrungen beim Einrichten, eine beim Oeffnen', () async {
      // Nicht kosmetisch: das Geheimnis gibt es nur ueber getAssertion, und
      // getAssertion braucht einen Zugang, den es vorher nicht gab. Wer das
      // nicht weiss, haelt die zweite Aufforderung fuer einen Fehler.
      final stick = FakeStick();
      final slot = await faktor(stick).createSlot(geheimnis(), createdAt: 1);
      expect(stick.beruehrungen, 2);

      await faktor(stick).unlock(slot);
      expect(stick.beruehrungen, 3);
    });

    test('nach dem Arbeiten wird die Verbindung wieder getrennt', () async {
      final stick = FakeStick();
      await faktor(stick).createSlot(geheimnis(), createdAt: 1);
      expect(stick.getrennt, isTrue,
          reason: 'ein offener NFC- oder USB-Kanal blockiert den naechsten '
              'Versuch');
    });

    test('auch nach einem Fehlschlag wird getrennt', () async {
      final stick = FakeStick();
      await expectLater(
          faktor(stick, pin: 'falsch').createSlot(geheimnis(), createdAt: 1),
          throwsA(isA<PinFalschException>()));
      expect(stick.getrennt, isTrue);
    });
  });

  group('Ein anderer Stick oeffnet das Fach nicht', () {
    test('derselbe Zugang, aber ein fremder Stick — kein Zutritt', () async {
      final echter = FakeStick();
      final slot = await faktor(echter).createSlot(geheimnis(), createdAt: 1);

      // Ein zweiter Stick, der die Kennung sogar kennt, aber einen anderen
      // internen Schluessel hat. Genau das ist der Fall "jemand hat meinen
      // Stick nachgemacht".
      final fremder = FakeStick();
      fremder.zugaenge[
              echter.zugaenge.keys.first] =
          Uint8List.fromList(List.filled(32, 0xEE));

      await expectLater(faktor(fremder).unlock(slot),
          throwsA(isA<UnlockFailedException>()));
    });

    test('ein Stick ohne diesen Zugang meldet das klar', () async {
      final echter = FakeStick();
      final slot = await faktor(echter).createSlot(geheimnis(), createdAt: 1);

      await expectLater(
          faktor(FakeStick()).unlock(slot),
          throwsA(isA<CtapException>()
              .having((e) => e.status, 'status', 0x36)));
    });
  });

  group('Was der Nutzer erfahren muss', () {
    test('falsche PIN wird als solche gemeldet, nicht verschwiegen', () async {
      // ABSICHTLICH ANDERS ALS BEIM PASSWORT-FACH: der Stick zaehlt selbst mit
      // und sperrt sich nach acht Fehlversuchen endgueltig. Wer nicht erfaehrt,
      // dass die PIN falsch war, verbrennt die Versuche ahnungslos.
      final stick = FakeStick();
      final slot = await faktor(stick).createSlot(geheimnis(), createdAt: 1);

      await expectLater(
          faktor(stick, pin: '000000').unlock(slot),
          throwsA(isA<PinFalschException>()
              .having((e) => e.verbleibend, 'verbleibende Versuche', 7)));
    });

    test('ein Stick ohne hmac-secret wird abgelehnt, bevor etwas passiert',
        () async {
      final stick = FakeStick(kannHmacSecret: false);
      await expectLater(faktor(stick).createSlot(geheimnis(), createdAt: 1),
          throwsA(isA<StickUngeeignetException>()));
      expect(stick.beruehrungen, 0,
          reason: 'der Nutzer soll nicht erst beruehren und dann erfahren, '
              'dass sein Stick nicht taugt');
    });

    test('ein Stick mit PIN, aber ohne bekannte PIN, fragt danach', () async {
      final stick = FakeStick();
      await expectLater(
          faktor(stick, pin: null).createSlot(geheimnis(), createdAt: 1),
          throwsA(isA<StickPinNoetigException>()));
    });

    test('ein Fach ohne Zugangskennung meldet den Grund', () async {
      final kaputt = KeySlot(
        id: 'x',
        kind: UnlockFactorKind.hardwareKey,
        label: 'Stick',
        createdAt: 0,
        nonce: Uint8List(12),
        cipherText: Uint8List(16),
        mac: Uint8List(16),
      );
      await expectLater(faktor(FakeStick()).unlock(kaputt),
          throwsA(isA<VaultFormatException>()));
    });
  });

  group('Ein Stick ganz ohne PIN', () {
    test('funktioniert genauso — der Schluesselaustausch bleibt', () async {
      // Auch ohne PIN laufen die Salze verschluesselt. Wer den
      // Schluesselaustausch nur als Beiwerk der PIN sieht, laesst ihn hier weg
      // und bekommt vom Stick eine Ablehnung ohne Hinweis.
      final stick = FakeStick(hatPin: false);
      final f = HardwareKeyFactor(oeffne: () async => stick);

      final slot = await f.createSlot(geheimnis(), createdAt: 1);
      final zurueck =
          await HardwareKeyFactor(oeffne: () async => stick).unlock(slot);
      expect(zurueck, geheimnis());
    });

    test('eine PIN, die der Stick nicht kennt, stoert nicht', () async {
      final stick = FakeStick(hatPin: false);
      final slot = await faktor(stick).createSlot(geheimnis(), createdAt: 1);
      expect(await faktor(stick).unlock(slot), geheimnis());
    });
  });

  group('Die Zugangskennung haengt in den Zusatzdaten', () {
    test('eine ausgetauschte Kennung macht das Fach unbrauchbar', () async {
      // Ohne diese Bindung koennte jemand die Kennung in der Fachdatei durch
      // die eines Zugangs ersetzen, den er selbst angelegt hat. Das Fach
      // liesse sich damit zwar immer noch nicht oeffnen — aber der Fehler
      // saehe aus wie ein defekter Stick, statt wie ein Angriff.
      final stick = FakeStick();
      final slot = await faktor(stick).createSlot(geheimnis(), createdAt: 1);

      final vertauscht = KeySlot(
        id: slot.id,
        kind: slot.kind,
        label: slot.label,
        createdAt: slot.createdAt,
        handle: Uint8List.fromList(List.filled(32, 1)),
        nonce: slot.nonce,
        cipherText: slot.cipherText,
        mac: slot.mac,
      );
      expect(vertauscht.aad, isNot(slot.aad));
    });

    test('sie ueberlebt den Weg durch die Datei', () async {
      final stick = FakeStick();
      final slot = await faktor(stick).createSlot(geheimnis(), createdAt: 1);
      final vault = KeyVault(slots: [slot]);

      final zurueck = KeyVault.fromJsonString(vault.toJsonString());
      expect(zurueck.slots.single.handle, slot.handle);
      expect(await faktor(stick).unlock(zurueck.slots.single), geheimnis());
    });
  });
}
