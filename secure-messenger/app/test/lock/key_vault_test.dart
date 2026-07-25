// key_vault_test.dart — die App-Sperre.
//
// Geprueft wird nicht, ob sich ein Fach oeffnen laesst — das waere leicht und
// sagt wenig. Geprueft wird, was NICHT gehen darf: ein Fach mit dem falschen
// Schluessel oeffnen, an der Datei drehen, ein Fach durch ein anderes ersetzen,
// oder das letzte Fach entfernen und damit alles unerreichbar machen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Die 16 Bytes, aus denen bei BitDM alles entsteht.
final geheimnis = Uint8List.fromList(List.generate(16, (i) => i * 11 % 256));

Uint8List kek(int f) => Uint8List.fromList(List.filled(32, f));

const zeit = 1753400000;

/// Stellt einen Faktor nach, der seinen Schluessel NIE herausgibt — so wie der
/// Schluesselspeicher von Android. Er beweist, dass die Schnittstelle auch
/// diese Bauart traegt, obwohl sich das auf dem Rechner nicht echt pruefen
/// laesst.
class FakeKeystoreFactor implements UnlockFactor {
  FakeKeystoreFactor({this.entsperrt = true});

  /// Ob der gesicherte Bereich gerade arbeiten wuerde — steht fuer "der
  /// Fingerabdruck lag vor".
  bool entsperrt;

  final Uint8List _niemalsHerausgegeben = kek(0x5A);

  @override
  UnlockFactorKind get kind => UnlockFactorKind.biometric;

  @override
  String get label => 'Fingerabdruck';

  @override
  Future<KeySlot> createSlot(Uint8List secret, {required int createdAt}) {
    if (!entsperrt) throw const UnlockFailedException();
    return KeyVault.sealSlot(
      secret: secret,
      kek: _niemalsHerausgegeben,
      kind: kind,
      label: label,
      createdAt: createdAt,
    );
  }

  @override
  Future<Uint8List> unlock(KeySlot slot) {
    if (!entsperrt) throw const UnlockFailedException();
    return KeyVault.openSlot(slot, _niemalsHerausgegeben);
  }
}

void main() {
  group('Ein Fach', () {
    test('laesst sich mit demselben Schluessel wieder oeffnen', () async {
      final slot = await KeyVault.sealSlot(
        secret: geheimnis,
        kek: kek(1),
        kind: UnlockFactorKind.hardwareKey,
        label: 'Stick',
        createdAt: zeit,
      );
      expect(await KeyVault.openSlot(slot, kek(1)), geheimnis);
    });

    test('bleibt mit einem anderen Schluessel zu', () async {
      final slot = await KeyVault.sealSlot(
        secret: geheimnis,
        kek: kek(1),
        kind: UnlockFactorKind.hardwareKey,
        label: 'Stick',
        createdAt: zeit,
      );
      expect(() => KeyVault.openSlot(slot, kek(2)),
          throwsA(isA<UnlockFailedException>()));
    });

    test('faellt auf, wenn ein Byte gekippt wurde', () async {
      final slot = await KeyVault.sealSlot(
        secret: geheimnis,
        kek: kek(1),
        kind: UnlockFactorKind.hardwareKey,
        label: 'Stick',
        createdAt: zeit,
      );
      final kaputt = Uint8List.fromList(slot.cipherText);
      kaputt[0] ^= 1;
      final manipuliert = KeySlot(
        id: slot.id,
        kind: slot.kind,
        label: slot.label,
        createdAt: slot.createdAt,
        nonce: slot.nonce,
        cipherText: kaputt,
        mac: slot.mac,
      );
      expect(() => KeyVault.openSlot(manipuliert, kek(1)),
          throwsA(isA<UnlockFailedException>()));
    });
  });

  group('Die mitverschluesselten Angaben binden das Fach', () {
    late KeySlot slot;

    setUp(() async {
      slot = await KeyVault.sealSlot(
        secret: geheimnis,
        kek: kek(1),
        kind: UnlockFactorKind.passphrase,
        label: 'Passwort',
        kdf: Argon2Params.owasp(salt: Uint8List.fromList(List.filled(16, 3))),
        createdAt: zeit,
      );
    });

    test('eine abgeschwaechte Ableitung macht das Fach unlesbar', () async {
      // Der eigentliche Angriff: jemand setzt in der Datei den Speicherbedarf
      // von Argon2id herunter, damit sich Passwoerter billiger durchprobieren
      // lassen. Weil die Einstellungen mitverschluesselt sind, geht das Fach
      // danach gar nicht mehr auf.
      final geschwaecht = KeySlot(
        id: slot.id,
        kind: slot.kind,
        label: slot.label,
        createdAt: slot.createdAt,
        kdf: Argon2Params(
            memory: 8, iterations: 1, parallelism: 1, salt: slot.kdf!.salt),
        nonce: slot.nonce,
        cipherText: slot.cipherText,
        mac: slot.mac,
      );
      expect(() => KeyVault.openSlot(geschwaecht, kek(1)),
          throwsA(isA<UnlockFailedException>()));
    });

    test('eine geaenderte Faktorart macht das Fach unlesbar', () async {
      final umettikettiert = KeySlot(
        id: slot.id,
        kind: UnlockFactorKind.biometric,
        label: slot.label,
        createdAt: slot.createdAt,
        kdf: slot.kdf,
        nonce: slot.nonce,
        cipherText: slot.cipherText,
        mac: slot.mac,
      );
      expect(() => KeyVault.openSlot(umettikettiert, kek(1)),
          throwsA(isA<UnlockFailedException>()));
    });

    test('eine geaenderte Kennung macht das Fach unlesbar', () async {
      final verschoben = KeySlot(
        id: 'fremd',
        kind: slot.kind,
        label: slot.label,
        createdAt: slot.createdAt,
        kdf: slot.kdf,
        nonce: slot.nonce,
        cipherText: slot.cipherText,
        mac: slot.mac,
      );
      expect(() => KeyVault.openSlot(verschoben, kek(1)),
          throwsA(isA<UnlockFailedException>()));
    });

    test('umbenennen ist dagegen erlaubt', () async {
      // Absicht: der Name ist nicht mitverschluesselt. Wer ein Fach umbenennt,
      // greift nichts an — und ein Fach, das nach dem Umbenennen zu bleibt,
      // waere eine Falle fuer den Nutzer.
      expect(await KeyVault.openSlot(slot.mitLabel('anders'), kek(1)),
          geheimnis);
    });
  });

  group('Mehrere Faecher', () {
    test('jedes oeffnet dasselbe Geheimnis, unabhaengig voneinander', () async {
      var vault = KeyVault(slots: [
        await KeyVault.sealSlot(
            secret: geheimnis,
            kek: kek(1),
            kind: UnlockFactorKind.biometric,
            label: 'Finger',
            createdAt: zeit),
      ]);
      vault = vault.mitSlot(await KeyVault.sealSlot(
          secret: geheimnis,
          kek: kek(2),
          kind: UnlockFactorKind.hardwareKey,
          label: 'Stick',
          createdAt: zeit));

      expect(await KeyVault.openSlot(vault.slots[0], kek(1)), geheimnis);
      expect(await KeyVault.openSlot(vault.slots[1], kek(2)), geheimnis);
      // Und ueber Kreuz geht nichts.
      expect(() => KeyVault.openSlot(vault.slots[0], kek(2)),
          throwsA(isA<UnlockFailedException>()));
    });

    test('ein Fach entfernen laesst die anderen unberuehrt', () async {
      final a = await KeyVault.sealSlot(
          secret: geheimnis,
          kek: kek(1),
          kind: UnlockFactorKind.biometric,
          label: 'Finger',
          createdAt: zeit);
      final b = await KeyVault.sealSlot(
          secret: geheimnis,
          kek: kek(2),
          kind: UnlockFactorKind.hardwareKey,
          label: 'Stick',
          createdAt: zeit);
      final vault = KeyVault(slots: [a, b]).ohneSlot(a.id);

      expect(vault.slots, hasLength(1));
      expect(await KeyVault.openSlot(vault.slots.single, kek(2)), geheimnis);
    });

    test('das LETZTE Fach laesst sich nicht entfernen', () async {
      // Sonst bliebe eine Datenbank zurueck, deren Schluessel niemand mehr hat.
      final a = await KeyVault.sealSlot(
          secret: geheimnis,
          kek: kek(1),
          kind: UnlockFactorKind.biometric,
          label: 'Finger',
          createdAt: zeit);
      expect(() => KeyVault(slots: [a]).ohneSlot(a.id), throwsStateError);
    });
  });

  group('Die Datei auf der Platte', () {
    test('enthaelt das Geheimnis nicht im Klartext', () async {
      // Dieselbe Pruefung wie bei der Datenbank: nicht ueber die Schnittstelle
      // fragen, sondern in die Datei sehen.
      final vault = KeyVault(slots: [
        await KeyVault.sealSlot(
            secret: geheimnis,
            kek: kek(1),
            kind: UnlockFactorKind.biometric,
            label: 'Finger',
            createdAt: zeit),
      ]);
      final text = vault.toJsonString();
      expect(text.contains(base64.encode(geheimnis)), isFalse);
      for (final b in [
        geheimnis.sublist(0, 8),
        geheimnis.sublist(8),
      ]) {
        expect(text.contains(base64.encode(b)), isFalse);
      }
    });

    test('ueberlebt Schreiben und Lesen', () async {
      final vault = KeyVault(slots: [
        await KeyVault.sealSlot(
            secret: geheimnis,
            kek: kek(1),
            kind: UnlockFactorKind.passphrase,
            label: 'Passwort',
            kdf: Argon2Params.owasp(),
            createdAt: zeit),
      ]);
      final zurueck = KeyVault.fromJsonString(vault.toJsonString());
      expect(zurueck.slots, hasLength(1));
      expect(await KeyVault.openSlot(zurueck.slots.single, kek(1)), geheimnis);
      expect(zurueck.slots.single.kdf!.memory, 19456);
    });

    test('Faecher aus einer NEUEREN App-Fassung werden abgelehnt', () {
      expect(() => KeyVault.fromJsonString('{"version": 99, "slots": []}'),
          throwsA(isA<VaultFormatException>()));
    });

    test('Schrott wird abgelehnt statt zu ueberraschen', () {
      for (final s in ['', 'kein json', '[]', '{}', '{"version": 1}']) {
        expect(() => KeyVault.fromJsonString(s),
            throwsA(isA<VaultFormatException>()),
            reason: 'bei Eingabe "$s"');
      }
    });
  });

  group('Passwort als Faktor', () {
    test('das richtige Passwort oeffnet, ein anderes nicht', () async {
      final f = PassphraseFactor('korrekt-pferd-batterie-heftklammer',
          geraeteGebunden: false);
      final slot = await f.createSlot(geheimnis, createdAt: zeit);

      expect(await f.unlock(slot), geheimnis);
      expect(
          () => PassphraseFactor('korrekt-pferd-batterie-heftklammeR',
                  geraeteGebunden: false)
              .unlock(slot),
          throwsA(isA<UnlockFailedException>()));
    });

    test('jedes Fach bekommt sein eigenes Salz', () async {
      final f = PassphraseFactor('korrekt-pferd-batterie-heftklammer',
          geraeteGebunden: false);
      final a = await f.createSlot(geheimnis, createdAt: zeit);
      final b = await f.createSlot(geheimnis, createdAt: zeit);
      expect(a.kdf!.salt, isNot(b.kdf!.salt));
      expect(a.cipherText, isNot(b.cipherText),
          reason: 'gleiches Passwort und gleiches Geheimnis duerfen nicht '
              'denselben Chiffretext ergeben');
    });

    test('ohne Geraetebindung wird eine PIN abgelehnt', () async {
      // Der wichtigste Test dieser Gruppe. Auf dem Rechner kann jemand mit der
      // Datei so viele Versuche machen, wie er will — eine sechsstellige PIN
      // sind dann eine Million Versuche, und Argon2id macht daraus Stunden,
      // nicht Jahre.
      expect(
          () => PassphraseFactor('123456', geraeteGebunden: false)
              .createSlot(geheimnis, createdAt: zeit),
          throwsA(isA<WeakPassphraseException>()));
    });

    test('MIT Geraetebindung ist eine PIN in Ordnung', () async {
      // Dann zaehlt der gesicherte Bereich des Geraets die Versuche mit, und
      // ausserhalb des Geraets laesst sich gar nichts probieren.
      final f = PassphraseFactor('123456', geraeteGebunden: true);
      final slot = await f.createSlot(geheimnis, createdAt: zeit);
      expect(await f.unlock(slot), geheimnis);
    });

    test('die Staerkeschaetzung liegt in der richtigen Groessenordnung', () {
      expect(PassphraseFactor.schaetzeBits(''), 0);
      expect(PassphraseFactor.schaetzeBits('1234'), lessThan(15));
      expect(PassphraseFactor.schaetzeBits('123456'), lessThan(21));
      expect(PassphraseFactor.schaetzeBits('korrekt-pferd-batterie'),
          greaterThan(60));
    });
  });

  group('Ein Faktor, der seinen Schluessel nie herausgibt', () {
    test('funktioniert ueber dieselbe Schnittstelle', () async {
      // Beweist, dass die Schnittstelle bei "Fach anlegen/oeffnen" sitzt und
      // nicht bei "Schluessel liefern" — sonst liesse sich der
      // Schluesselspeicher von Android gar nicht anbinden.
      final f = FakeKeystoreFactor();
      final slot = await f.createSlot(geheimnis, createdAt: zeit);
      expect(await f.unlock(slot), geheimnis);
    });

    test('verweigert die Arbeit, solange der Faktor nicht vorlag', () async {
      final f = FakeKeystoreFactor();
      final slot = await f.createSlot(geheimnis, createdAt: zeit);
      f.entsperrt = false;
      expect(() => f.unlock(slot), throwsA(isA<UnlockFailedException>()));
    });
  });

  test('ein Fachschluessel mit falscher Laenge wird abgelehnt', () async {
    expect(
        () => KeyVault.sealSlot(
            secret: geheimnis,
            kek: Uint8List(16),
            kind: UnlockFactorKind.biometric,
            label: 'x',
            createdAt: zeit),
        throwsArgumentError);
  });
}
