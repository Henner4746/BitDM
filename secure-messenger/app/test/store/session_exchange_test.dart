// session_exchange_test.dart — der erste echte Nachrichtenaustausch.
//
// Alles bisher Gebaute trifft hier aufeinander: Seed-Phrase, Adressableitung,
// die Bruecke zu libsignal und die fuenf Speicher. Zwei Teilnehmer bauen per
// PQXDH eine Sitzung auf und schreiben sich mit Double Ratchet.
//
// Seit 2.0.0 ist das Signals offizielle libsignal (Rust, Paket `libsignal`),
// nicht mehr die Dart-Nachbildung. PQXDH heisst: jedes Buendel traegt einen
// Kyber-Prekey, ohne geht es nicht (docs/LIBSIGNAL-UMSTIEG.md).
//
// Fuer PQXDH und den Double Ratchet gibt es KEINE offiziellen Testvektoren
// wie bei BIP39. Deshalb pruefen diese Tests EIGENSCHAFTEN, die gelten
// muessen: Forward Secrecy, Ablehnung wiederholter Nachrichten, Zustellung
// ausserhalb der Reihenfolge, Verhalten ohne Einmalschluessel. Fehlt eine
// davon, ist das Sicherheitsversprechen des Produkts nicht eingeloest — auch
// wenn Nachrichten scheinbar ankommen.
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
// geprueft. Nackt gefangen wird trotzdem, denn die Anbindung wirft auch
// PanicException (siehe signal_errors.dart).

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_errors.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

/// Ein Teilnehmer mit eigener Identitaet, eigenem Speicher und eigenen Prekeys.
class Teilnehmer {
  final SignalIdentity identity;
  final BitdmSignalStore store;
  final ProtocolAddress address;
  final List<PreKeyRecord> preKeys;
  final SignedPreKeyRecord signedPreKey;
  final KyberPreKeyRecord letzteRettung;
  final List<KyberPreKeyRecord> kyberEinmal;

  Teilnehmer._(this.identity, this.store, this.address, this.preKeys,
      this.signedPreKey, this.letzteRettung, this.kyberEinmal);

  static Future<Teilnehmer> neu({int otkAnzahl = 5, int kyberAnzahl = 5}) async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final identity = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: identity);

    final preKeys = [for (var id = 1; id <= otkAnzahl; id++) neuerPreKey(id)];
    for (final pk in preKeys) {
      await store.storePreKey(pk.id(), pk);
    }
    final spk = neuerSpk(identity.keyPair, 1);
    await store.storeSignedPreKey(spk.id(), spk);
    final letzte = neuerKyber(identity.keyPair, 1);
    await store.storeLastResortKyberPreKey(1, letzte);
    final kyber = [
      for (var i = 0; i < kyberAnzahl; i++) neuerKyber(identity.keyPair, 100 + i)
    ];
    for (final k in kyber) {
      await store.storeKyberPreKey(k.id(), k);
    }

    return Teilnehmer._(identity, store, adr(identity.address), preKeys, spk,
        letzte, kyber);
  }

  /// Was der Relay als Prekey-Bundle ausliefern wuerde.
  ///
  /// [kyberIndex] null: der Last-Resort-Kyber-Schluessel — so liefert der
  /// Relay, wenn die Kyber-Einmalschluessel aufgebraucht sind.
  PreKeyBundle bundle({bool mitOtk = true, int otkIndex = 0, int? kyberIndex = 0}) {
    final kyber = kyberIndex == null ? letzteRettung : kyberEinmal[kyberIndex];
    return PreKeyBundle(
      registrationId: identity.registrationId,
      deviceId: 1,
      preKeyId: mitOtk ? preKeys[otkIndex].id() : null,
      preKeyPublic: mitOtk ? preKeys[otkIndex].publicKey() : null,
      signedPreKeyId: signedPreKey.id(),
      signedPreKeyPublic: signedPreKey.publicKey(),
      signedPreKeySignature: signedPreKey.signature(),
      identityKey: identity.keyPair.publicKey,
      kyberPreKeyId: kyber.id(),
      kyberPreKeyPublic: kyber.getPublicKey().serialize(),
      kyberPreKeySignature: kyber.signature(),
    );
  }
}

String _str(Uint8List b) => utf8.decode(b);

/// Sitzung von [von] zu [an] aus [an]s Buendel.
Future<void> _baue(Teilnehmer von, Teilnehmer an, PreKeyBundle b) =>
    bauerVon(von.store).processPreKeyBundle(an.address, b);

/// Verschluesselt fuer die Gegenstelle.
Future<CiphertextMessage> _senden(Teilnehmer von, Teilnehmer an, String t) =>
    chiffreVon(von.store).encrypt(an.address, text(t));

/// Entschluesselt, egal ob Erst- oder Folgenachricht — die Art steht in der
/// Nachricht selbst, wie im Umschlag von BitDM.
Future<String> _empfangen(
        Teilnehmer bei, Teilnehmer von, CiphertextMessage msg) async =>
    _str(await chiffreVon(bei.store).decrypt(von.address, msg));

/// Sammelt, was [f] wirft — oder null, wenn es durchlief.
Future<Object?> _wasFliegt(Future<void> Function() f) async {
  try {
    await f();
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  setUpAll(signalBereit);

  group('Sitzungsaufbau und erste Nachricht', () {
    test('Alice schreibt Bob, ohne dass Bob online war', () async {
      // Genau der Fall, fuer den es Prekey-Bundles gibt.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();

      await _baue(alice, bob, bob.bundle());

      final msg =
          await _senden(alice, bob, 'Hallo Bob, das hier liest keiner mit.');
      expect(msg.type, CiphertextMessageType.preKey,
          reason: 'die erste Nachricht traegt den Sitzungsaufbau');
      expect(msg.type.value, 3,
          reason: 'dieselbe Typnummer wie in BitDMs Umschlag');

      expect(await _empfangen(bob, alice, msg),
          'Hallo Bob, das hier liest keiner mit.');
    });

    test('Bob antwortet, danach laeuft es in beide Richtungen', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());

      await _empfangen(bob, alice, await _senden(alice, bob, 'eins'));
      final zwei = await _senden(bob, alice, 'zwei');
      expect(zwei.type, CiphertextMessageType.signal,
          reason: 'Bob hat die Sitzung schon, er braucht keinen Aufbau');
      expect(await _empfangen(alice, bob, zwei), 'zwei');
      expect(await _empfangen(bob, alice, await _senden(alice, bob, 'drei')),
          'drei');
      expect(await _empfangen(alice, bob, await _senden(bob, alice, 'vier')),
          'vier');
    });

    test('der verbrauchte EC-Einmalschluessel ist danach weg', () async {
      // Er darf sich nicht wiederverwenden lassen — sonst waere der
      // Sitzungsaufbau nicht mehr einmalig.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final vorher = bob.store.preKeyCount;

      await _baue(alice, bob, bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'x'));

      expect(bob.store.preKeyCount, vorher - 1);
      expect(await bob.store.containsPreKey(bob.preKeys[0].id()), isFalse);
    });

    test('der verbrauchte Kyber-Einmalschluessel ist danach weg, der '
        'Last-Resort-Schluessel bleibt', () async {
      // Dasselbe fuer den Post-Quanten-Teil. Bliebe der Kyber-Einmal-
      // schluessel liegen, haette ein spaeterer Diebstahl des Geraets noch
      // etwas, womit sich der Sitzungsaufbau nachrechnen liesse.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final vorher = bob.store.kyberEinmalCount;
      final benutzt = bob.kyberEinmal[2].id();

      await _baue(alice, bob, bob.bundle(kyberIndex: 2));
      await _empfangen(bob, alice, await _senden(alice, bob, 'x'));

      expect(bob.store.kyberEinmalCount, vorher - 1);
      expect(await bob.store.containsKyberPreKey(benutzt), isFalse);
      expect(bob.store.letzteRettungId, bob.letzteRettung.id());
      expect(bob.store.state.kyberBenutzt, isEmpty,
          reason: 'ein Einmalschluessel wird verbraucht, nicht vermerkt');
    });

    test('funktioniert auch OHNE Einmalschluessel — EC und Kyber', () async {
      // Der Relay liefert keine mehr, wenn der Vorrat leer ist. PQXDH ist dann
      // etwas schwaecher, muss aber funktionieren — sonst waere ein leerer
      // Vorrat gleichbedeutend mit Unerreichbarkeit, und genau das waere das
      // Ziel eines Prekey-Drain-Angriffs.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();

      await _baue(alice, bob, bob.bundle(mitOtk: false, kyberIndex: null));

      expect(await _empfangen(bob, alice, await _senden(alice, bob, 'ohne otk')),
          'ohne otk');
      // Der Last-Resort-Schluessel bleibt, und die Nutzung ist vermerkt: an
      // genau diesem Eintrag faellt eine erneut eingespielte Erstnachricht
      // auf (signal_bibliothek_test.dart).
      expect(bob.store.letzteRettungId, bob.letzteRettung.id());
      expect(bob.store.state.kyberBenutzt, hasLength(1));
      expect(bob.store.kyberWiederholungen, 0);
    });

    test('der Last-Resort-Schluessel traegt auch einen zweiten Absender',
        () async {
      // Er ist zum Wiederverwenden da. Nur DIESELBE Erstnachricht darf nicht
      // zweimal durchgehen — eine neue Vereinbarung schon.
      final alice = await Teilnehmer.neu();
      final carol = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final b = bob.bundle(mitOtk: false, kyberIndex: null);

      await _baue(alice, bob, b);
      await _baue(carol, bob, b);
      expect(await _empfangen(bob, alice, await _senden(alice, bob, 'a')), 'a');
      expect(await _empfangen(bob, carol, await _senden(carol, bob, 'c')), 'c');
      expect(bob.store.state.kyberBenutzt, hasLength(2));
      expect(bob.store.kyberWiederholungen, 0);
    });
  });

  group('Eigenschaften, die gelten MUESSEN', () {
    test('Forward Secrecy: jede Nachricht bekommt einen eigenen Schluessel',
        () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'start'));

      // Derselbe Klartext, mehrfach gesendet, muss jedes Mal anders aussehen.
      final chiffren = <String>{};
      for (var i = 0; i < 6; i++) {
        final m = await _senden(alice, bob, 'immer derselbe Text');
        chiffren.add(base64.encode(m.ciphertext));
        await _empfangen(bob, alice, m);
      }
      expect(chiffren.length, 6,
          reason: 'gleicher Chiffretext zweimal hiesse: gleicher Schluessel');
    });

    test('dieselbe Nachricht zweimal wird beim zweiten Mal abgelehnt', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'erste'));

      final zweite = await _senden(alice, bob, 'nur einmal bitte');
      expect(await _empfangen(bob, alice, zweite), 'nur einmal bitte');

      // Ein Angreifer, der eine mitgeschnittene Nachricht erneut einspielt,
      // darf sie nicht ein zweites Mal zugestellt bekommen.
      final geworfen = await _wasFliegt(() => _empfangen(bob, alice, zweite));
      expect(geworfen, isNotNull,
          reason: 'die Wiederholung haette abgelehnt werden muessen');
      expect(classify(geworfen!), SignalFailure.duplicate);
    });

    test('Nachrichten ausserhalb der Reihenfolge kommen trotzdem an', () async {
      // Passiert im Normalbetrieb: beim Reconnect liefert der Relay die
      // Warteschlange, waehrend gleichzeitig neue Nachrichten live eintreffen.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());
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
      await _baue(alice, bob, bob.bundle());
      await _empfangen(bob, alice, await _senden(alice, bob, 'start'));

      // BOB MUSS ANTWORTEN, sonst prueft dieser Test nichts.
      //
      // Solange Alice von Bob noch nichts empfangen hat, bleibt sie im
      // Aufbau und schickt weiter PreKey-Nachrichten. Ein gekipptes Bit traefe
      // dann den Aufbauteil statt der Folgenachricht. Gefunden von einem
      // Widerlegungsagenten am 27.07.2026, nachdem die Reparatur des
      // try/catch-Musters bereits als erledigt galt.
      await _empfangen(alice, bob, await _senden(bob, alice, 'zurueck'));

      final echt = await _senden(alice, bob, 'unveraendert');
      expect(echt.type, CiphertextMessageType.signal,
          reason: 'DIESE ZEILE HAELT DEN TEST AUFRECHT: bei einer '
              'PreKey-Nachricht traefe das Bitkippen unten den Aufbau, und '
              'die Verfaelschung der Folgenachricht waere nie geprueft worden');

      final bytes = Uint8List.fromList(echt.ciphertext);
      bytes[bytes.length - 5] ^= 0x01; // ein Bit in der Pruefsumme kippen

      final geworfen = await _wasFliegt(() => _empfangen(bob, alice,
          CiphertextMessage(type: echt.type, ciphertext: bytes)));

      // Diese Erwartung traegt den Test: geht die Verfaelschung glatt durch,
      // faellt sie hier auf und nicht erst dem Nutzer.
      expect(geworfen, isNotNull,
          reason: 'die Verfaelschung haette auffallen muessen');
      // Wichtig ist NICHT der genaue Code, sondern dass es keinen Neuaufbau
      // ausloest.
      expect(classify(geworfen!).shouldRebuildSession, isFalse,
          reason: 'sonst koennte ein Angreifer Sitzungen zuruecksetzen');
      // Und die echte Nachricht kommt danach weiter an.
      expect(await _empfangen(bob, alice, echt), 'unveraendert');
    });

    test('ein Dritter kann nicht mitlesen', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final mallory = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());

      final msg = await _senden(alice, bob, 'geheim');
      final geworfen =
          await _wasFliegt(() => _empfangen(mallory, alice, msg));

      expect(geworfen, isNotNull,
          reason: 'Mallory darf das nicht entschluesseln koennen');
      // Und der Fehlschlag darf nicht als Normalfall durchgewinkt werden:
      // isSilent hiesse, die Nachricht wird kommentarlos verworfen.
      expect(classify(geworfen!).isSilent, isFalse);
    });

    test('eine Erstnachricht unter fremder Adresse wird abgewiesen, ohne '
        'Spuren', () async {
      // Mallory schreibt Bob und gibt sich als Alice aus — der Relay setzt
      // den Absender, und der kann luegen. Die Adresse IST der Schluessel:
      // saveIdentity rechnet nach und wirft. Weil die Anbindung einen Wurf
      // aus einem Speicher-Rueckruf nicht als Fehler kennt, kommt er als
      // PanicException an (siehe signal_errors.dart) — die Konsole zeigt dazu
      // eine Rust-Panic. Beim Entschluesseln steht saveIdentity VOR allen
      // anderen Schreibvorgaengen, also bleibt nichts zurueck.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      final mallory = await Teilnehmer.neu();
      await _baue(mallory, bob, bob.bundle());
      final msg = await _senden(mallory, bob, 'ich bin Alice');
      final prekeysVorher = bob.store.preKeyCount;
      final kyberVorher = bob.store.kyberEinmalCount;

      final geworfen = await _wasFliegt(() => _empfangen(bob, alice, msg));

      expect(geworfen, isNotNull,
          reason: 'ein fremder Schluessel unter Alices Adresse');
      expect(classify(geworfen!).isSilent, isFalse);
      expect(classify(geworfen).shouldRebuildSession, isFalse);
      expect(bob.store.state.sessions, isEmpty,
          reason: 'keine Sitzung mit "Alice", die Mallory gehoert');
      expect(bob.store.state.identities, isEmpty);
      expect(bob.store.preKeyCount, prekeysVorher,
          reason: 'ein abgewiesener Aufbau verbraucht keinen Einmalschluessel');
      expect(bob.store.kyberEinmalCount, kyberVorher);
    });
  });

  group('Der Speicher wird richtig benutzt', () {
    test('libsignal hat waehrend des Austauschs geschrieben', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());

      bob.store.markClean();
      await _empfangen(bob, alice, await _senden(alice, bob, 'x'));

      // Beim Empfang einer Erstnachricht aendern sich Sitzung, Identitaet und
      // beide Einmalschluessel — genau deshalb muessen alle in EINER
      // Transaktion weggeschrieben werden.
      expect(bob.store.dirtySections, {
        StoreSection.session,
        StoreSection.preKey,
        StoreSection.identity,
        StoreSection.kyberPreKey,
      });
    });

    test('ueber den Last-Resort-Schluessel wird das Tripel vermerkt', () async {
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle(mitOtk: false, kyberIndex: null));

      bob.store.markClean();
      await _empfangen(bob, alice, await _senden(alice, bob, 'x'));

      expect(bob.store.dirtySections, {
        StoreSection.session,
        StoreSection.identity,
        StoreSection.kyberBenutzt,
      });
    });

    test('eine Sitzung ueberlebt das Wiederherstellen des Zustands', () async {
      // So verhaelt es sich spaeter beim App-Neustart: der Zustand kommt aus
      // der Datenbank, die Unterhaltung muss weiterlaufen.
      final alice = await Teilnehmer.neu();
      final bob = await Teilnehmer.neu();
      await _baue(alice, bob, bob.bundle());
      await _empfangen(
          bob, alice, await _senden(alice, bob, 'vor dem Neustart'));

      // Bobs Speicher neu aufbauen, nur aus dem gesicherten Zustand.
      final bobNeu = Teilnehmer._(
        bob.identity,
        BitdmSignalStore(identity: bob.identity, state: bob.store.state.copy()),
        bob.address,
        bob.preKeys,
        bob.signedPreKey,
        bob.letzteRettung,
        bob.kyberEinmal,
      );

      expect(
          await _empfangen(bobNeu, alice, await _senden(alice, bob, 'danach')),
          'danach');
    });
  });
}
