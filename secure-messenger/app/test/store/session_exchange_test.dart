// session_exchange_test.dart — der erste echte Nachrichtenaustausch.
//
// Alles bisher Gebaute trifft hier aufeinander: Seed-Phrase, Adressableitung,
// die Bruecke zu libsignal und die vier Speicher. Zwei Teilnehmer bauen per
// X3DH eine Sitzung auf und schreiben sich mit Double Ratchet.
//
// Fuer X3DH und den Double Ratchet gibt es KEINE offiziellen Testvektoren wie
// bei BIP39. Deshalb pruefen diese Tests EIGENSCHAFTEN, die gelten muessen:
// Forward Secrecy, Ablehnung wiederholter Nachrichten, Zustellung ausserhalb
// der Reihenfolge, Verhalten ohne One-Time-Prekey. Fehlt eine davon, ist das
// Sicherheitsversprechen des Produkts nicht eingeloest — auch wenn Nachrichten
// scheinbar ankommen.
//
// Wo geprueft wird, DASS etwas wirft, steht `fail()` nie im try-Block. Der
// nackte `catch (e)` danach faengt die von fail() geworfene TestFailure
// naemlich wieder ein; classify() ordnet sie keiner bekannten Klasse zu und
// gibt unreadable zurueck, was weder isSilent noch shouldRebuildSession
// setzt. Die folgenden Erwartungen gehen also durch, und der Test bleibt
// gerade dann gruen, wenn gar nichts geworfen wurde — im Angriffsfall.
// Nachgemessen: mit einer Fassung von _empfangen, die den Klartext einfach
// zurueckgab, meldeten beide betroffenen Tests weiter "All tests passed".
// Deshalb wird der geworfene Wert eingesammelt und AUSSERHALB des try
// geprueft. Nackt gefangen wird trotzdem, denn libsignal wirft auch
// AssertionError (siehe signal_errors.dart).

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_errors.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Ein Teilnehmer mit eigener Identitaet, eigenem Speicher und eigenen Prekeys.
class Teilnehmer {
  final SignalIdentity identity;
  final BitdmSignalStore store;
  final SignalProtocolAddress address;
  final List<PreKeyRecord> preKeys;
  final SignedPreKeyRecord signedPreKey;

  Teilnehmer._(this.identity, this.store, this.address, this.preKeys,
      this.signedPreKey);

  static Future<Teilnehmer> neu({int otkAnzahl = 5}) async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final identity = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: identity);

    final preKeys = generatePreKeys(1, otkAnzahl);
    for (final pk in preKeys) {
      await store.storePreKey(pk.id, pk);
    }
    final spk = generateSignedPreKey(identity.keyPair, 1);
    await store.storeSignedPreKey(spk.id, spk);

    return Teilnehmer._(identity, store,
        SignalProtocolAddress(identity.address, 1), preKeys, spk);
  }

  /// Was der Relay als Prekey-Bundle ausliefern wuerde.
  PreKeyBundle bundle({bool mitOtk = true, int otkIndex = 0}) => PreKeyBundle(
        identity.registrationId,
        1,
        mitOtk ? preKeys[otkIndex].id : null,
        mitOtk ? preKeys[otkIndex].getKeyPair().publicKey : null,
        signedPreKey.id,
        signedPreKey.getKeyPair().publicKey,
        signedPreKey.signature,
        identity.keyPair.getPublicKey(),
      );
}

Uint8List _txt(String s) => Uint8List.fromList(utf8.encode(s));
String _str(Uint8List b) => utf8.decode(b);

/// Verschluesselt fuer die Gegenstelle.
Future<CiphertextMessage> _senden(
    Teilnehmer von, Teilnehmer an, String text) async {
  final cipher = SessionCipher.fromStore(von.store, an.address);
  return cipher.encrypt(_txt(text));
}

/// Entschluesselt, egal ob Erst- oder Folgenachricht.
Future<String> _empfangen(
    Teilnehmer bei, Teilnehmer von, CiphertextMessage msg) async {
  final cipher = SessionCipher.fromStore(bei.store, von.address);
  final klar = msg.getType() == CiphertextMessage.prekeyType
      ? await cipher.decrypt(PreKeySignalMessage(msg.serialize()))
      : await cipher.decryptFromSignal(SignalMessage.fromSerialized(msg.serialize()));
  return _str(klar);
}

void main() {
  group('Sitzungsaufbau und erste Nachricht', () {
    test('Alice schreibt Bob, ohne dass Bob online war', () async {
      // Genau der Fall, fuer den es Prekey-Bundles gibt.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();

      final builder = SessionBuilder.fromSignalStore(alice.store, bob.address);
      await builder.processPreKeyBundle(bob.bundle());

      final msg = await _senden(alice, bob, 'Hallo Bob, das hier liest keiner mit.');
      expect(msg.getType(), CiphertextMessage.prekeyType,
          reason: 'die erste Nachricht traegt den Sitzungsaufbau');

      expect(await _empfangen(bob, alice, msg),
          'Hallo Bob, das hier liest keiner mit.');
    });

    test('Bob antwortet, danach laeuft es in beide Richtungen', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());

      await _empfangen(bob, alice, await _senden(alice, bob, 'eins'));
      expect(await _empfangen(alice, bob, await _senden(bob, alice, 'zwei')),
          'zwei');
      expect(await _empfangen(bob, alice, await _senden(alice, bob, 'drei')),
          'drei');
      expect(await _empfangen(alice, bob, await _senden(bob, alice, 'vier')),
          'vier');
    });

    test('der verbrauchte One-Time-Prekey ist danach weg', () async {
      // Er darf sich nicht wiederverwenden lassen — sonst waere der
      // Sitzungsaufbau nicht mehr einmalig.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final vorher = bob.store.preKeyCount;

      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'x'));

      expect(bob.store.preKeyCount, vorher - 1);
      expect(await bob.store.containsPreKey(bob.preKeys[0].id), isFalse);
    });

    test('funktioniert auch OHNE One-Time-Prekey', () async {
      // Der Relay liefert keinen mehr, wenn der Vorrat leer ist. X3DH ist dann
      // etwas schwaecher, muss aber funktionieren — sonst waere ein leerer
      // Vorrat gleichbedeutend mit Unerreichbarkeit, und genau das waere das
      // Ziel eines Prekey-Drain-Angriffs.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();

      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle(mitOtk: false));

      expect(await _empfangen(bob, alice, await _senden(alice, bob, 'ohne otk')),
          'ohne otk');
    });
  });

  group('Eigenschaften, die gelten MUESSEN', () {
    test('Forward Secrecy: jede Nachricht bekommt einen eigenen Schluessel',
        () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'start'));

      // Derselbe Klartext, mehrfach gesendet, muss jedes Mal anders aussehen.
      final chiffren = <String>{};
      for (var i = 0; i < 6; i++) {
        final m = await _senden(alice, bob, 'immer derselbe Text');
        chiffren.add(base64.encode(m.serialize()));
        await _empfangen(bob, alice, m);
      }
      expect(chiffren.length, 6,
          reason: 'gleicher Chiffretext zweimal hiesse: gleicher Schluessel');
    });

    test('dieselbe Nachricht zweimal wird beim zweiten Mal abgelehnt', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'erste'));

      final zweite = await _senden(alice, bob, 'nur einmal bitte');
      expect(await _empfangen(bob, alice, zweite), 'nur einmal bitte');

      // Ein Angreifer, der eine mitgeschnittene Nachricht erneut einspielt,
      // darf sie nicht ein zweites Mal zugestellt bekommen.
      Object? geworfen;
      try {
        await _empfangen(bob, alice, zweite);
      } catch (e) {
        geworfen = e;
      }
      expect(geworfen, isNotNull,
          reason: 'die Wiederholung haette abgelehnt werden muessen');
      expect(classify(geworfen!), SignalFailure.duplicate);
    });

    test('Nachrichten ausserhalb der Reihenfolge kommen trotzdem an', () async {
      // Passiert im Normalbetrieb: beim Reconnect liefert der Relay die
      // Warteschlange, waehrend gleichzeitig neue Nachrichten live eintreffen.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'start'));

      final m1 = await _senden(alice, bob, 'eins');
      final m2 = await _senden(alice, bob, 'zwei');
      final m3 = await _senden(alice, bob, 'drei');

      // Verdreht zustellen.
      expect(await _empfangen(bob, alice, m3), 'drei');
      expect(await _empfangen(bob, alice, m1), 'eins');
      expect(await _empfangen(bob, alice, m2), 'zwei');
    });

    test('eine veraenderte Nachricht wird abgelehnt', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'start'));

      // BOB MUSS ANTWORTEN, sonst prueft dieser Test nichts.
      //
      // Solange Alice von Bob noch nichts empfangen hat, bleibt sie im
      // Aufbau und schickt weiter PreKey-Nachrichten. `SignalMessage
      // .fromSerialized` scheitert daran schon beim PARSEN — der Test warf
      // also zuverlaessig, aber aus dem falschen Grund, und blieb auch dann
      // gruen, wenn man das Bitkippen ganz wegliess. Gefunden von einem
      // Widerlegungsagenten am 27.07.2026, nachdem die Reparatur des
      // try/catch-Musters bereits als erledigt galt.
      await _empfangen(alice, bob, await _senden(bob, alice, 'zurueck'));

      final echt = await _senden(alice, bob, 'unveraendert');
      expect(echt.getType(), CiphertextMessage.whisperType,
          reason: 'DIESE ZEILE HAELT DEN TEST AUFRECHT: bei einer '
              'PreKey-Nachricht wuerde unten schon das Parsen scheitern, und '
              'die Verfaelschung waere nie geprueft worden');

      final bytes = Uint8List.fromList(echt.serialize());
      bytes[bytes.length - 5] ^= 0x01; // ein Bit im Chiffretext kippen

      Object? geworfen;
      try {
        final cipher = SessionCipher.fromStore(bob.store, alice.address);
        await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
      } catch (e) {
        geworfen = e;
      }

      // Diese Erwartung traegt den Test: geht die Verfaelschung glatt durch,
      // faellt sie hier auf und nicht erst dem Nutzer.
      expect(geworfen, isNotNull,
          reason: 'die Verfaelschung haette auffallen muessen');
      // Wichtig ist NICHT, dass es badMac ist, sondern dass es keinen
      // Neuaufbau ausloest.
      expect(classify(geworfen!).shouldRebuildSession, isFalse,
          reason: 'sonst koennte ein Angreifer Sitzungen zuruecksetzen');
    });

    test('ein Dritter kann nicht mitlesen', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final mallory = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());

      final msg = await _senden(alice, bob, 'geheim');
      Object? geworfen;
      try {
        await _empfangen(mallory, alice, msg);
      } catch (e) {
        geworfen = e;
      }

      expect(geworfen, isNotNull,
          reason: 'Mallory darf das nicht entschluesseln koennen');
      // Und der Fehlschlag darf nicht als Normalfall durchgewinkt werden:
      // isSilent hiesse, die Nachricht wird kommentarlos verworfen.
      expect(classify(geworfen!).isSilent, isFalse);
    });
  });

  group('Der Speicher wird richtig benutzt', () {
    test('libsignal hat waehrend des Austauschs geschrieben', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());

      bob.store.markClean();
      await _empfangen(bob, alice, await _senden(alice, bob, 'x'));

      // Beim Empfang einer Erstnachricht aendern sich Sitzung UND Prekeys —
      // genau deshalb muessen beide in EINER Transaktion weggeschrieben werden.
      expect(bob.store.dirtySections, contains(StoreSection.session));
      expect(bob.store.dirtySections, contains(StoreSection.preKey));
      expect(bob.store.dirtySections, contains(StoreSection.identity));
    });

    test('eine Sitzung ueberlebt das Wiederherstellen des Zustands', () async {
      // So verhaelt es sich spaeter beim App-Neustart: der Zustand kommt aus
      // der Datenbank, die Unterhaltung muss weiterlaufen.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await SessionBuilder.fromSignalStore(alice.store, bob.address)
          .processPreKeyBundle(bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'vor dem Neustart'));

      // Bobs Speicher neu aufbauen, nur aus dem gesicherten Zustand.
      final bobNeu = Teilnehmer._(
        bob.identity,
        BitdmSignalStore(identity: bob.identity, state: bob.store.state.copy()),
        bob.address,
        bob.preKeys,
        bob.signedPreKey,
      );

      expect(
          await _empfangen(bobNeu, alice, await _senden(alice, bob, 'danach')),
          'danach');
    });
  });
}
