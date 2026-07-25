// signal_store_test.dart — prueft die vier Speicher.
//
// Zwei Sorten Tests stehen hier nebeneinander:
//
//  1. VERTRAGSTREUE. libsignal ruft diese Methoden selbst auf und verlaesst
//     sich auf ihr genaues Verhalten — etwa darauf, dass loadSession fuer eine
//     unbekannte Adresse ein leeres Record liefert statt null. Weicht der
//     Speicher hier ab, bricht der Sitzungsaufbau an einer Stelle, die weit
//     entfernt aussieht.
//
//  2. DIE ABWEICHUNG VON DER REFERENZ. BitDM prueft Identitaeten nicht ueber
//     Vertrauen, sondern rechnet nach. Das ist der Kern des Sicherheits-
//     versprechens und wird entsprechend hart geprueft.

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Erzeugt eine Identitaet samt zugehoeriger libsignal-Adresse.
Future<({SignalIdentity identity, SignalProtocolAddress addr})> _wer() async {
  final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
  final id = SignalIdentityBridge.fromDerived(keys,
      registrationId: SignalIdentityBridge.newRegistrationId());
  return (identity: id, addr: SignalProtocolAddress(id.address, 1));
}

void main() {
  late SignalIdentity ich;
  late BitdmSignalStore store;

  setUp(() async {
    final k = await KeyDerivation.fromMnemonic(Bip39.generate());
    ich = SignalIdentityBridge.fromDerived(k, registrationId: 4242);
    store = BitdmSignalStore(identity: ich);
  });

  group('Eigene Identitaet', () {
    test('liefert das eigene Schluesselpaar', () async {
      final kp = await store.getIdentityKeyPair();
      expect(SignalIdentityBridge.rawPublicKeyOf(kp.getPublicKey()),
          ich.rawPublicKey);
    });

    test('liefert die Installationskennung', () async {
      expect(await store.getLocalRegistrationId(), 4242);
    });
  });

  group('Identitaeten werden NACHGERECHNET, nicht geglaubt', () {
    test('passender Schluessel wird angenommen', () async {
      final gegen = await _wer();
      expect(
          await store.isTrustedIdentity(gegen.addr,
              gegen.identity.keyPair.getPublicKey(), Direction.receiving),
          isTrue);
    });

    test('fremder Schluessel zu einer Adresse wird abgelehnt — auch beim '
        'ALLERERSTEN Kontakt', () async {
      // Das ist der entscheidende Unterschied zur Referenz. Dort waere dieser
      // Schluessel angenommen worden, weil zu der Adresse noch nichts
      // gespeichert ist ("dem ersten glauben"). Ein boesartiger Server koennte
      // damit beim Prekey-Bundle einen fremden Schluessel unterschieben.
      final opfer = await _wer();
      final angreifer = await _wer();

      expect(
          await store.isTrustedIdentity(opfer.addr,
              angreifer.identity.keyPair.getPublicKey(), Direction.receiving),
          isFalse,
          reason: 'Schluessel gehoert nicht zu dieser Adresse');
    });

    test('null-Schluessel wird abgelehnt', () async {
      final gegen = await _wer();
      expect(
          await store.isTrustedIdentity(
              gegen.addr, null, Direction.sending),
          isFalse);
    });

    test('speichern eines fremden Schluessels wirft, statt still abzulehnen',
        () async {
      // Ein Aufrufer, der den Rueckgabewert ignoriert, wuerde sonst mit einem
      // Schluessel weiterarbeiten, den wir gerade als falsch erkannt haben.
      final opfer = await _wer();
      final angreifer = await _wer();
      expect(
          () => store.saveIdentity(
              opfer.addr, angreifer.identity.keyPair.getPublicKey()),
          throwsA(isA<AddressKeyMismatchException>()));
    });

    test('gilt fuer viele zufaellige Paare', () async {
      for (var i = 0; i < 8; i++) {
        final a = await _wer();
        final b = await _wer();
        expect(await store.isTrustedIdentity(
                a.addr, a.identity.keyPair.getPublicKey(), Direction.receiving),
            isTrue);
        expect(await store.isTrustedIdentity(
                a.addr, b.identity.keyPair.getPublicKey(), Direction.receiving),
            isFalse);
      }
    });

    test('formatierte Adresse wird ebenso akzeptiert', () async {
      // Die UI zeigt Adressen in 14 Gruppen a 4. Wird so eine Schreibweise
      // durchgereicht, darf die Pruefung nicht daran scheitern.
      final gegen = await _wer();
      final formatiert = SignalProtocolAddress(
          BitdmAddress.format(gegen.identity.address), 1);
      expect(
          await store.isTrustedIdentity(formatiert,
              gegen.identity.keyPair.getPublicKey(), Direction.receiving),
          isTrue);
    });
  });

  group('saveIdentity meldet Aenderungen', () {
    test('erstes Speichern meldet true, zweites false', () async {
      final gegen = await _wer();
      final key = gegen.identity.keyPair.getPublicKey();
      expect(await store.saveIdentity(gegen.addr, key), isTrue);
      expect(await store.saveIdentity(gegen.addr, key), isFalse,
          reason: 'unveraendert');
    });

    test('gespeicherte Identitaet ist wieder abrufbar', () async {
      final gegen = await _wer();
      expect(await store.getIdentity(gegen.addr), isNull);
      await store.saveIdentity(gegen.addr, gegen.identity.keyPair.getPublicKey());
      final zurueck = await store.getIdentity(gegen.addr);
      expect(zurueck, isNotNull);
      expect(SignalIdentityBridge.rawPublicKeyOf(zurueck!),
          gegen.identity.rawPublicKey);
    });
  });

  group('Sitzungen — Vertragstreue gegenueber libsignal', () {
    test('unbekannte Adresse liefert ein LEERES Record, nicht null', () async {
      // libsignal verlaesst sich darauf: ein leeres Record heisst "noch keine
      // Sitzung", und der Aufbau schreibt hinein. Ein null hier wuerde den
      // Sitzungsaufbau mit einer Nullreferenz beenden.
      final gegen = await _wer();
      final rec = await store.loadSession(gegen.addr);
      expect(rec, isNotNull);
      expect(rec.isFresh(), isTrue);
      expect(await store.containsSession(gegen.addr), isFalse);
    });

    test('gespeicherte Sitzung kommt unveraendert zurueck', () async {
      final gegen = await _wer();
      final rec = SessionRecord();
      await store.storeSession(gegen.addr, rec);
      expect(await store.containsSession(gegen.addr), isTrue);
      final zurueck = await store.loadSession(gegen.addr);
      expect(zurueck.serialize(), rec.serialize());
    });

    test('deleteSession trifft nur die eine Adresse', () async {
      final a = await _wer();
      final b = await _wer();
      await store.storeSession(a.addr, SessionRecord());
      await store.storeSession(b.addr, SessionRecord());
      await store.deleteSession(a.addr);
      expect(await store.containsSession(a.addr), isFalse);
      expect(await store.containsSession(b.addr), isTrue);
    });

    test('deleteAllSessions trifft alle Geraete EINER Adresse', () async {
      final a = await _wer();
      final b = await _wer();
      for (final d in [1, 2, 3]) {
        await store.storeSession(SignalProtocolAddress(a.identity.address, d),
            SessionRecord());
      }
      await store.storeSession(b.addr, SessionRecord());

      await store.deleteAllSessions(a.identity.address);
      for (final d in [1, 2, 3]) {
        expect(
            await store.containsSession(
                SignalProtocolAddress(a.identity.address, d)),
            isFalse);
      }
      expect(await store.containsSession(b.addr), isTrue,
          reason: 'fremde Adresse darf nicht mitgeloescht werden');
    });

    test('getSubDeviceSessions laesst Geraet 1 aus', () async {
      final a = await _wer();
      for (final d in [1, 2, 5]) {
        await store.storeSession(
            SignalProtocolAddress(a.identity.address, d), SessionRecord());
      }
      final sub = await store.getSubDeviceSessions(a.identity.address);
      expect(sub..sort(), [2, 5]);
    });
  });

  group('Prekeys', () {
    test('unbekannte Nummer wirft InvalidKeyIdException', () async {
      // NORMALFALL, kein Ausnahmefall: eine doppelt zugestellte Erstnachricht
      // verweist auf einen Prekey, der beim ersten Mal verbraucht wurde.
      expect(() => store.loadPreKey(999),
          throwsA(isA<InvalidKeyIdException>()));
      expect(() => store.loadSignedPreKey(999),
          throwsA(isA<InvalidKeyIdException>()));
    });

    test('speichern, lesen, zaehlen, entfernen', () async {
      final keys = generatePreKeys(1, 5);
      for (final k in keys) {
        await store.storePreKey(k.id, k);
      }
      expect(store.preKeyCount, 5);
      expect(await store.containsPreKey(1), isTrue);
      expect((await store.loadPreKey(1)).id, 1);

      await store.removePreKey(1);
      expect(await store.containsPreKey(1), isFalse);
      expect(store.preKeyCount, 4);
    });

    test('signierte Prekeys lassen sich sammeln', () async {
      final kp = await store.getIdentityKeyPair();
      for (var i = 1; i <= 3; i++) {
        await store.storeSignedPreKey(
            i, generateSignedPreKey(kp, i));
      }
      expect((await store.loadSignedPreKeys()).length, 3);
    });
  });

  group('Veraenderungen werden vermerkt', () {
    // Die Schicht darueber schreibt in EINER Transaktion weg und muss dafuer
    // wissen, was sich ueberhaupt geaendert hat.
    test('frischer Speicher ist sauber', () {
      expect(store.isDirty, isFalse);
      expect(store.dirtySections, isEmpty);
    });

    test('nur Lesen macht nicht schmutzig', () async {
      final gegen = await _wer();
      await store.loadSession(gegen.addr);
      await store.containsPreKey(1);
      await store.getIdentity(gegen.addr);
      await store.getIdentityKeyPair();
      expect(store.isDirty, isFalse);
    });

    test('jeder Bereich meldet sich einzeln', () async {
      final gegen = await _wer();
      await store.saveIdentity(gegen.addr, gegen.identity.keyPair.getPublicKey());
      expect(store.dirtySections, {StoreSection.identity});

      await store.storeSession(gegen.addr, SessionRecord());
      expect(store.dirtySections,
          {StoreSection.identity, StoreSection.session});

      store.markClean();
      expect(store.isDirty, isFalse);
    });

    test('erfolgloses Entfernen macht nicht schmutzig', () async {
      await store.removePreKey(12345);
      await store.removeSignedPreKey(12345);
      expect(store.isDirty, isFalse,
          reason: 'es gab nichts zu entfernen, also nichts zu schreiben');
    });

    test('unveraendertes Speichern derselben Identitaet meldet sich nicht',
        () async {
      final gegen = await _wer();
      final key = gegen.identity.keyPair.getPublicKey();
      await store.saveIdentity(gegen.addr, key);
      store.markClean();
      await store.saveIdentity(gegen.addr, key);
      expect(store.isDirty, isFalse);
    });
  });

  group('Zustand laesst sich uebergeben und wiederherstellen', () {
    test('ein Speicher kann auf vorhandenem Zustand aufsetzen', () async {
      final gegen = await _wer();
      await store.saveIdentity(gegen.addr, gegen.identity.keyPair.getPublicKey());
      await store.storeSession(gegen.addr, SessionRecord());

      // So wird es spaeter aus der Datenbank kommen.
      final neuer =
          BitdmSignalStore(identity: ich, state: store.state.copy());

      expect(await neuer.containsSession(gegen.addr), isTrue);
      expect(await neuer.getIdentity(gegen.addr), isNotNull);
      expect(neuer.isDirty, isFalse,
          reason: 'geladener Zustand ist noch nicht veraendert');
    });

    test('copy() entkoppelt wirklich', () async {
      final gegen = await _wer();
      final kopie = store.state.copy();
      await store.storeSession(gegen.addr, SessionRecord());
      expect(kopie.sessions, isEmpty,
          reason: 'die Kopie darf spaetere Aenderungen nicht sehen');
    });
  });
}
