// persistence_test.dart — ueberlebt eine Unterhaltung den App-Neustart?
//
// session_exchange_test.dart hat gezeigt, dass zwei Teilnehmer verschluesselt
// miteinander reden koennen. Dort lag aber alles im Arbeitsspeicher; ein
// Neustart haette die Sitzung mitgenommen.
//
// Hier laufen dieselben Ablaeufe gegen ECHTE verschluesselte Datenbanken, die
// zwischendurch vollstaendig geschlossen und wieder geoeffnet werden. Das ist
// der Alltag auf einem Telefon: Android beendet die App, der Nutzer oeffnet sie
// Stunden spaeter wieder, und die Unterhaltung muss weiterlaufen.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Ein Teilnehmer, dessen Zustand tatsaechlich auf der Platte liegt.
///
/// [neustart] macht genau das, was Android macht: alles schliessen und aus der
/// Datei neu aufbauen. Nichts wird aus dem alten Speicher uebernommen.
class Geraet {
  Geraet._(this.derived, this.dbPfad, this.db, this.repo, this.store,
      this.preKeys, this.signedPreKey);

  final DerivedKeys derived;
  final String dbPfad;
  EncryptedDatabase db;
  SignalStoreRepository repo;
  BitdmSignalStore store;
  List<PreKeyRecord> preKeys;
  SignedPreKeyRecord signedPreKey;

  SignalProtocolAddress get address => SignalProtocolAddress(store.identity.address, 1);

  static Future<Geraet> neu(String pfad, {int otkAnzahl = 5}) async {
    final derived = await KeyDerivation.fromMnemonic(Bip39.generate());
    final db = EncryptedDatabase.open(pfad, derived.databaseKey);
    final repo = SignalStoreRepository(db);
    final store = repo.openStore(derived);

    final preKeys = generatePreKeys(1, otkAnzahl);
    for (final pk in preKeys) {
      await store.storePreKey(pk.id, pk);
    }
    final spk = generateSignedPreKey(store.identity.keyPair, 1);
    await store.storeSignedPreKey(spk.id, spk);
    repo.commit(store);

    return Geraet._(derived, pfad, db, repo, store, preKeys, spk);
  }

  /// App beenden und neu starten.
  Future<void> neustart() async {
    db.close();
    db = EncryptedDatabase.open(dbPfad, derived.databaseKey);
    repo = SignalStoreRepository(db);
    store = repo.openStore(derived);
    // Prekeys kommen jetzt aus der Datenbank, nicht mehr aus dem alten Speicher.
    signedPreKey = await store.loadSignedPreKey(signedPreKey.id);
  }

  void schliessen() => db.close();

  PreKeyBundle bundle({bool mitOtk = true, int otkIndex = 0}) => PreKeyBundle(
        store.identity.registrationId,
        1,
        mitOtk ? preKeys[otkIndex].id : null,
        mitOtk ? preKeys[otkIndex].getKeyPair().publicKey : null,
        signedPreKey.id,
        signedPreKey.getKeyPair().publicKey,
        signedPreKey.signature,
        store.identity.keyPair.getPublicKey(),
      );
}

Uint8List _txt(String s) => Uint8List.fromList(utf8.encode(s));

Future<CiphertextMessage> _senden(Geraet von, Geraet an, String text) async {
  final msg =
      await SessionCipher.fromStore(von.store, an.address).encrypt(_txt(text));
  von.repo.commit(von.store);
  return msg;
}

Future<String> _empfangen(Geraet bei, Geraet von, CiphertextMessage msg) async {
  final cipher = SessionCipher.fromStore(bei.store, von.address);
  final klar = msg.getType() == CiphertextMessage.prekeyType
      ? await cipher.decrypt(PreKeySignalMessage(msg.serialize()))
      : await cipher
          .decryptFromSignal(SignalMessage.fromSerialized(msg.serialize()));
  bei.repo.commit(bei.store);
  return utf8.decode(klar);
}

void main() {
  late Directory tmp;
  var n = 0;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_persist'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });
  String pfad(String name) => '${tmp.path}/${name}_${n++}.db';

  test('eine Unterhaltung ueberlebt den Neustart BEIDER Geraete', () async {
    final alice = await Geraet.neu(pfad('alice'));
    final bob = await Geraet.neu(pfad('bob'));
    addTearDown(alice.schliessen);
    addTearDown(bob.schliessen);

    await SessionBuilder.fromSignalStore(alice.store, bob.address)
        .processPreKeyBundle(bob.bundle());
    alice.repo.commit(alice.store);

    expect(await _empfangen(bob, alice, await _senden(alice, bob, 'erste')),
        'erste');
    expect(await _empfangen(alice, bob, await _senden(bob, alice, 'zweite')),
        'zweite');

    // Damit dieser Test aus dem richtigen Grund besteht: die Sitzungen muessen
    // JETZT in der Datei stehen. Stuende hier 0, liefe der Rest des Tests auf
    // frisch aufgebaute Sitzungen hinaus und bewiese nichts.
    for (final g in [alice, bob]) {
      expect(g.db.raw.select('SELECT count(*) c FROM sessions').first['c'], 1);
    }

    // Beide Apps werden beendet und neu gestartet.
    await alice.neustart();
    await bob.neustart();
    for (final g in [alice, bob]) {
      expect(g.store.state.sessions, isNotEmpty,
          reason: 'die Sitzung kam nicht aus der Datei zurueck');
    }

    // Die Unterhaltung laeuft weiter — mit dem Ratchet-Stand von vorher.
    expect(await _empfangen(bob, alice, await _senden(alice, bob, 'nach dem Neustart')),
        'nach dem Neustart');
    expect(await _empfangen(alice, bob, await _senden(bob, alice, 'auch zurueck')),
        'auch zurueck');
  });

  test('der verbrauchte Prekey ist nach dem Neustart wirklich weg', () async {
    // Ohne Persistenz waere er nach dem Neustart wieder da — und eine
    // wiederholt eingespielte Erstnachricht liesse sich erneut entschluesseln.
    final alice = await Geraet.neu(pfad('alice'));
    final bob = await Geraet.neu(pfad('bob'));
    addTearDown(alice.schliessen);
    addTearDown(bob.schliessen);

    final otkId = bob.preKeys[0].id;
    expect(bob.db.raw.select('SELECT id FROM pre_keys WHERE id = ?', [otkId]),
        isNotEmpty);

    await SessionBuilder.fromSignalStore(alice.store, bob.address)
        .processPreKeyBundle(bob.bundle());
    final erste = await _senden(alice, bob, 'hallo');
    await _empfangen(bob, alice, erste);

    expect(bob.db.raw.select('SELECT id FROM pre_keys WHERE id = ?', [otkId]),
        isEmpty,
        reason: 'der verbrauchte Prekey steht noch in der Datenbank');

    await bob.neustart();
    expect(await bob.store.containsPreKey(otkId), isFalse,
        reason: 'nach dem Neustart waere er wieder da — und eine wiederholt '
            'eingespielte Erstnachricht erneut entschluesselbar');
  });

  test('nur die eine betroffene Zeile wird geschrieben', () async {
    // Der Grund, warum der Merkzettel EINZELNE Schluessel fuehrt und nicht nur
    // Bereiche. Wuerde beim Empfang einer Nachricht der ganze Sitzungsbereich
    // neu geschrieben, waeren das bei vielen Kontakten entsprechend viele
    // Zeilen — bei jeder einzelnen Nachricht, auf dem Flash eines Telefons.
    final alice = await Geraet.neu(pfad('alice'));
    final bob = await Geraet.neu(pfad('bob'));
    addTearDown(alice.schliessen);
    addTearDown(bob.schliessen);

    // 40 weitere Sitzungen, wie sie ein Nutzer mit vielen Kontakten haette.
    for (var i = 0; i < 40; i++) {
      final fremd = await Geraet.neu(pfad('fremd$i'), otkAnzahl: 1);
      await SessionBuilder.fromSignalStore(alice.store, fremd.address)
          .processPreKeyBundle(fremd.bundle());
      fremd.schliessen();
    }
    alice.repo.commit(alice.store);
    expect(alice.db.raw.select('SELECT count(*) c FROM sessions').first['c'], 40);

    // Ab hier jeden Schreibzugriff auf `sessions` mitzaehlen.
    alice.db.raw.execute('CREATE TEMP TABLE zaehler (x INTEGER)');
    for (final ereignis in ['INSERT', 'UPDATE']) {
      alice.db.raw.execute('''
        CREATE TEMP TRIGGER t_$ereignis AFTER $ereignis ON sessions
        BEGIN INSERT INTO zaehler VALUES (1); END
      ''');
    }

    await SessionBuilder.fromSignalStore(alice.store, bob.address)
        .processPreKeyBundle(bob.bundle());
    await _senden(alice, bob, 'eine einzige Nachricht');

    final geschrieben =
        alice.db.raw.select('SELECT count(*) c FROM zaehler').first['c'];
    expect(geschrieben, 1,
        reason: 'fuer eine Nachricht an einen Kontakt wurden $geschrieben '
            'Sitzungszeilen geschrieben statt einer');
  });

  test('nach einer gescheiterten Transaktion wird beim naechsten Mal '
      'alles nachgeholt', () async {
    final alice = await Geraet.neu(pfad('alice'));
    addTearDown(alice.schliessen);

    final spk = generateSignedPreKey(alice.store.identity.keyPair, 77);
    await alice.store.storeSignedPreKey(77, spk);
    expect(alice.store.isDirty, isTrue);

    // Schreiben scheitert — hier durch einen veralteten Stand.
    alice.db.raw.execute("UPDATE meta SET value = '4242' WHERE key = 'generation'");
    expect(() => alice.repo.commit(alice.store),
        throwsA(isA<StaleStateException>()));

    // Der Merkzettel darf NICHT geleert sein, sonst waere die Aenderung still
    // verloren.
    expect(alice.store.isDirty, isTrue);
    expect(alice.store.delta.signedPreKeys, contains(77));

    // Stand wieder geradeziehen, dann klappt es.
    alice.db.raw
        .execute("UPDATE meta SET value = '${alice.db.generation}' WHERE key = 'generation'");
    alice.repo.commit(alice.store);
    expect(alice.store.isDirty, isFalse);
    expect(alice.db.raw.select('SELECT id FROM signed_pre_keys WHERE id = 77'),
        isNotEmpty);
  });

  test('geloeschte Eintraege verschwinden auch aus der Datei', () async {
    final alice = await Geraet.neu(pfad('alice'), otkAnzahl: 10);
    addTearDown(alice.schliessen);
    expect(alice.db.raw.select('SELECT count(*) c FROM pre_keys').first['c'], 10);

    await alice.store.removePreKey(3);
    await alice.store.removePreKey(7);
    alice.repo.commit(alice.store);

    final uebrig = alice.db.raw
        .select('SELECT id FROM pre_keys ORDER BY id')
        .map((r) => r['id'] as int)
        .toList();
    expect(uebrig, [1, 2, 4, 5, 6, 8, 9, 10]);
  });

  test('ohne Aenderung wird gar nicht erst geschrieben', () async {
    final alice = await Geraet.neu(pfad('alice'));
    addTearDown(alice.schliessen);
    final stand = alice.db.generation;
    alice.repo.commit(alice.store);
    expect(alice.db.generation, stand,
        reason: 'eine leere Transaktion kostet trotzdem ein fsync');
  });

  test('die Registrierungsnummer bleibt ueber Neustarts hinweg dieselbe',
      () async {
    // Sie steht im Prekey-Bundle. Wuerde sie sich bei jedem Start aendern,
    // saehe jede Gegenstelle staendig ein neu aufgesetztes Geraet.
    final alice = await Geraet.neu(pfad('alice'));
    addTearDown(alice.schliessen);
    final vorher = alice.store.identity.registrationId;
    await alice.neustart();
    expect(alice.store.identity.registrationId, vorher);
  });

  test('dieselbe Seed-Phrase ergibt auf einem zweiten Geraet dieselbe Adresse, '
      'aber eine andere Registrierungsnummer', () async {
    final derived = await KeyDerivation.fromMnemonic(Bip39.generate());

    final a = EncryptedDatabase.open(pfad('a'), derived.databaseKey);
    final storeA = SignalStoreRepository(a).openStore(derived);
    final b = EncryptedDatabase.open(pfad('b'), derived.databaseKey);
    final storeB = SignalStoreRepository(b).openStore(derived);
    addTearDown(a.close);
    addTearDown(b.close);

    expect(storeB.identity.address, storeA.identity.address,
        reason: 'die Identitaet haengt an der Seed-Phrase');
    expect(storeB.identity.registrationId,
        isNot(storeA.identity.registrationId),
        reason: 'die Nummer bezeichnet ein GERAET, nicht eine Identitaet');
  });

  test('die Datenbank eines anderen Nutzers laesst sich nicht oeffnen',
      () async {
    final alice = await Geraet.neu(pfad('alice'));
    final pfadA = alice.dbPfad;
    alice.schliessen();

    final fremd = await KeyDerivation.fromMnemonic(Bip39.generate());
    expect(() => EncryptedDatabase.open(pfadA, fremd.databaseKey),
        throwsA(isA<DatabaseUnlockException>()));
  });
}
