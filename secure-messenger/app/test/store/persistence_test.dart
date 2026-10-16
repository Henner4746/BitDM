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
//
// Seit 2.0.0 gehoeren die Kyber-Prekeys und die Liste der Last-Resort-
// Nutzungen dazu. Ueberlebt diese Liste den Neustart nicht, laesst sich eine
// alte Erstnachricht nach jedem Neustart erneut einspielen (LS-1).

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

/// Ein Teilnehmer, dessen Zustand tatsaechlich auf der Platte liegt.
///
/// [neustart] macht genau das, was Android macht: alles schliessen und aus der
/// Datei neu aufbauen. Nichts wird aus dem alten Speicher uebernommen.
class Geraet {
  Geraet._(this.derived, this.dbPfad, this.db, this.repo, this.store,
      this.preKeys, this.signedPreKey, this.letzteRettung, this.kyberEinmal);

  final DerivedKeys derived;
  final String dbPfad;
  EncryptedDatabase db;
  SignalStoreRepository repo;
  BitdmSignalStore store;
  List<PreKeyRecord> preKeys;
  SignedPreKeyRecord signedPreKey;
  KyberPreKeyRecord letzteRettung;
  List<KyberPreKeyRecord> kyberEinmal;

  ProtocolAddress get address => adr(store.identity.address);

  static Future<Geraet> neu(String pfad,
      {int otkAnzahl = 5, int kyberAnzahl = 2}) async {
    final derived = await KeyDerivation.fromMnemonic(Bip39.generate());
    final db = EncryptedDatabase.open(pfad, derived.databaseKey);
    final repo = SignalStoreRepository(db);
    final store = repo.openStore(derived);
    final paar = store.identity.keyPair;

    final preKeys = [for (var id = 1; id <= otkAnzahl; id++) neuerPreKey(id)];
    for (final pk in preKeys) {
      await store.storePreKey(pk.id(), pk);
    }
    final spk = neuerSpk(paar, 1);
    await store.storeSignedPreKey(spk.id(), spk);
    final letzte = neuerKyber(paar, 1);
    await store.storeLastResortKyberPreKey(1, letzte);
    final kyber = [
      for (var i = 0; i < kyberAnzahl; i++) neuerKyber(paar, 100 + i)
    ];
    for (final k in kyber) {
      await store.storeKyberPreKey(k.id(), k);
    }
    repo.commit(store);

    return Geraet._(
        derived, pfad, db, repo, store, preKeys, spk, letzte, kyber);
  }

  /// App beenden und neu starten.
  Future<void> neustart() async {
    db.close();
    db = EncryptedDatabase.open(dbPfad, derived.databaseKey);
    repo = SignalStoreRepository(db);
    store = repo.openStore(derived);
    // Prekeys kommen jetzt aus der Datenbank, nicht mehr aus dem alten Speicher.
    signedPreKey = (await store.loadSignedPreKey(signedPreKey.id()))!;
  }

  void schliessen() => db.close();

  /// [kyberIndex] null: der Last-Resort-Kyber-Schluessel.
  PreKeyBundle bundle({bool mitOtk = true, int otkIndex = 0, int? kyberIndex = 0}) =>
      _buendel(store.identity, signedPreKey,
          kyberIndex == null ? letzteRettung : kyberEinmal[kyberIndex],
          otk: mitOtk ? preKeys[otkIndex] : null);
}

PreKeyBundle _buendel(SignalIdentity id, SignedPreKeyRecord spk,
        KyberPreKeyRecord kyber, {PreKeyRecord? otk}) =>
    PreKeyBundle(
      registrationId: id.registrationId,
      deviceId: 1,
      preKeyId: otk?.id(),
      preKeyPublic: otk?.publicKey(),
      signedPreKeyId: spk.id(),
      signedPreKeyPublic: spk.publicKey(),
      signedPreKeySignature: spk.signature(),
      identityKey: id.keyPair.publicKey,
      kyberPreKeyId: kyber.id(),
      kyberPreKeyPublic: kyber.getPublicKey().serialize(),
      kyberPreKeySignature: kyber.signature(),
    );

Future<void> _baue(Geraet von, Geraet an, PreKeyBundle b) async {
  await bauerVon(von.store).processPreKeyBundle(an.address, b);
  von.repo.commit(von.store);
}

Future<CiphertextMessage> _senden(Geraet von, Geraet an, String t) async {
  final msg = await chiffreVon(von.store).encrypt(an.address, text(t));
  von.repo.commit(von.store);
  return msg;
}

Future<String> _empfangen(Geraet bei, Geraet von, CiphertextMessage msg,
    {int geraet = 1}) async {
  final klar = await chiffreVon(bei.store)
      .decrypt(adr(von.store.identity.address, geraet), msg);
  bei.repo.commit(bei.store);
  return utf8.decode(klar);
}

int _zahl(EncryptedDatabase db, String sql, [List<Object?> p = const []]) =>
    db.raw.select(sql, p).first['c'] as int;

void main() {
  late Directory tmp;
  var n = 0;
  setUpAll(signalBereit);
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

    await _baue(alice, bob, bob.bundle());

    expect(await _empfangen(bob, alice, await _senden(alice, bob, 'erste')),
        'erste');
    expect(await _empfangen(alice, bob, await _senden(bob, alice, 'zweite')),
        'zweite');

    // Damit dieser Test aus dem richtigen Grund besteht: die Sitzungen muessen
    // JETZT in der Datei stehen. Stuende hier 0, liefe der Rest des Tests auf
    // frisch aufgebaute Sitzungen hinaus und bewiese nichts.
    for (final g in [alice, bob]) {
      expect(_zahl(g.db, 'SELECT count(*) c FROM sessions'), 1);
    }

    // Beide Apps werden beendet und neu gestartet.
    await alice.neustart();
    await bob.neustart();
    for (final g in [alice, bob]) {
      expect(g.store.state.sessions, isNotEmpty,
          reason: 'die Sitzung kam nicht aus der Datei zurueck');
    }

    // Die Unterhaltung laeuft weiter — mit dem Ratchet-Stand von vorher.
    expect(
        await _empfangen(
            bob, alice, await _senden(alice, bob, 'nach dem Neustart')),
        'nach dem Neustart');
    expect(
        await _empfangen(alice, bob, await _senden(bob, alice, 'auch zurueck')),
        'auch zurueck');
  });

  test('der verbrauchte EC-Prekey ist nach dem Neustart wirklich weg',
      () async {
    // Ohne Persistenz waere er nach dem Neustart wieder da — und eine
    // wiederholt eingespielte Erstnachricht liesse sich erneut entschluesseln.
    final alice = await Geraet.neu(pfad('alice'));
    final bob = await Geraet.neu(pfad('bob'));
    addTearDown(alice.schliessen);
    addTearDown(bob.schliessen);

    final otkId = bob.preKeys[0].id();
    expect(_zahl(bob.db, 'SELECT count(*) c FROM pre_keys WHERE id = ?', [otkId]),
        1);

    await _baue(alice, bob, bob.bundle());
    await _empfangen(bob, alice, await _senden(alice, bob, 'hallo'));

    expect(_zahl(bob.db, 'SELECT count(*) c FROM pre_keys WHERE id = ?', [otkId]),
        0,
        reason: 'der verbrauchte Prekey steht noch in der Datenbank');

    await bob.neustart();
    expect(await bob.store.containsPreKey(otkId), isFalse,
        reason: 'nach dem Neustart waere er wieder da — und eine wiederholt '
            'eingespielte Erstnachricht erneut entschluesselbar');
  });

  test('der verbrauchte Kyber-Einmalschluessel ist nach dem Neustart weg, '
      'der Last-Resort-Schluessel bleibt', () async {
    final alice = await Geraet.neu(pfad('alice'));
    final bob = await Geraet.neu(pfad('bob'));
    addTearDown(alice.schliessen);
    addTearDown(bob.schliessen);
    final kyberId = bob.kyberEinmal[0].id();

    await _baue(alice, bob, bob.bundle(mitOtk: false));
    await _empfangen(bob, alice, await _senden(alice, bob, 'hallo'));

    expect(
        _zahl(bob.db, 'SELECT count(*) c FROM kyber_pre_keys WHERE id = ?',
            [kyberId]),
        0,
        reason: 'markKyberPreKeyUsed hat ihn verbraucht, das Loeschen muss '
            'in der Datei ankommen');

    await bob.neustart();
    expect(await bob.store.containsKyberPreKey(kyberId), isFalse);
    expect(bob.store.letzteRettungId, bob.letzteRettung.id());
    expect(bob.store.kyberEinmalCount, bob.kyberEinmal.length - 1);
  });

  test('Kyber-Eintraege und Tripel ueberstehen Festschreiben und Neuladen',
      () async {
    final bob = await Geraet.neu(pfad('bob'), otkAnzahl: 0, kyberAnzahl: 2);
    addTearDown(bob.schliessen);
    final basis = PrivateKey.generate().getPublicKey();
    await bob.store.markKyberPreKeyUsed(1, 1, basis);
    bob.repo.commit(bob.store);

    // In der Datei: die Art steht neben dem Record, denn der Record selbst
    // sagt nicht, ob es ein Einmal- oder der Last-Resort-Schluessel ist.
    final zeilen = {
      for (final r in bob.db.raw
          .select('SELECT id, letzte_rettung FROM kyber_pre_keys'))
        r['id'] as int: r['letzte_rettung'] as int
    };
    expect(zeilen, {1: 1, 100: 0, 101: 0});
    expect(_zahl(bob.db, 'SELECT count(*) c FROM kyber_benutzt'), 1);

    final vorher = {
      for (final e in bob.store.state.kyberPreKeys.entries)
        e.key: [if (e.value.letzteRettung) 1 else 0, ...e.value.record]
    };
    final tripelVorher = {...bob.store.state.kyberBenutzt};

    await bob.neustart();

    expect({
      for (final e in bob.store.state.kyberPreKeys.entries)
        e.key: [if (e.value.letzteRettung) 1 else 0, ...e.value.record]
    }, vorher, reason: 'Records und Art muessen byte-gleich zurueckkommen');
    expect(bob.store.state.kyberBenutzt, tripelVorher);
    expect(bob.store.isDirty, isFalse);

    // Der eigentliche Zweck: auch nach dem Neustart faellt dieselbe Nutzung
    // als Wiederholung auf.
    await bob.store.markKyberPreKeyUsed(1, 1, basis);
    expect(bob.store.kyberWiederholungen, 1);

    // Und das Abraeumen kommt ebenso in der Datei an.
    await bob.store.removeKyberPreKey(1);
    bob.repo.commit(bob.store);
    expect(_zahl(bob.db, 'SELECT count(*) c FROM kyber_benutzt'), 0);
    expect(
        _zahl(bob.db, 'SELECT count(*) c FROM kyber_pre_keys WHERE id = 1'), 0);
    await bob.neustart();
    expect(bob.store.state.kyberBenutzt, isEmpty);
    expect(bob.store.letzteRettungId, isNull);
  });

  test('eine erneut eingespielte Erstnachricht faellt auch nach dem Neustart '
      'auf', () async {
    // Der Ablauf von LS-1 ueber die Datei: Erstnachricht ueber den
    // Last-Resort-Kyber, App neu gestartet, dieselbe Nachricht noch einmal —
    // vom Relay einem anderen Geraet zugeschrieben, damit libsignal keine
    // passende Sitzung findet und neu aufbaut.
    final alice = await Geraet.neu(pfad('alice'));
    final bob = await Geraet.neu(pfad('bob'));
    addTearDown(alice.schliessen);
    addTearDown(bob.schliessen);

    await _baue(alice, bob, bob.bundle(mitOtk: false, kyberIndex: null));
    final erst = await _senden(alice, bob, 'nur einmal');
    expect(await _empfangen(bob, alice, erst), 'nur einmal');

    await bob.neustart();
    final vorher = bob.store.kyberWiederholungen;
    await chiffreVon(bob.store)
        .decrypt(adr(alice.store.identity.address, 2), erst);
    expect(bob.store.kyberWiederholungen, vorher + 1,
        reason: 'die Liste der Last-Resort-Nutzungen kam nicht aus der Datei '
            'zurueck — die Wiederholung bliebe unbemerkt');
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
    // Die Gegenstellen brauchen keine eigene Datei, nur ein Buendel.
    for (var i = 0; i < 40; i++) {
      final k = await KeyDerivation.fromMnemonic(Bip39.generate());
      final fremd = SignalIdentityBridge.fromDerived(k, registrationId: 1);
      await bauerVon(alice.store).processPreKeyBundle(
          adr(fremd.address),
          _buendel(fremd, neuerSpk(fremd.keyPair, 1),
              neuerKyber(fremd.keyPair, 1)));
    }
    alice.repo.commit(alice.store);
    expect(_zahl(alice.db, 'SELECT count(*) c FROM sessions'), 40);

    // Ab hier jeden Schreibzugriff auf `sessions` mitzaehlen.
    alice.db.raw.execute('CREATE TEMP TABLE zaehler (x INTEGER)');
    for (final ereignis in ['INSERT', 'UPDATE']) {
      alice.db.raw.execute('''
        CREATE TEMP TRIGGER t_$ereignis AFTER $ereignis ON sessions
        BEGIN INSERT INTO zaehler VALUES (1); END
      ''');
    }

    await bauerVon(alice.store).processPreKeyBundle(bob.address, bob.bundle());
    await _senden(alice, bob, 'eine einzige Nachricht');

    final geschrieben = _zahl(alice.db, 'SELECT count(*) c FROM zaehler');
    expect(geschrieben, 1,
        reason: 'fuer eine Nachricht an einen Kontakt wurden $geschrieben '
            'Sitzungszeilen geschrieben statt einer');
  });

  test('nach einer gescheiterten Transaktion wird beim naechsten Mal '
      'alles nachgeholt', () async {
    final alice = await Geraet.neu(pfad('alice'));
    addTearDown(alice.schliessen);

    await alice.store
        .storeSignedPreKey(77, neuerSpk(alice.store.identity.keyPair, 77));
    await alice.store.storeLastResortKyberPreKey(
        78, neuerKyber(alice.store.identity.keyPair, 78));
    expect(alice.store.isDirty, isTrue);

    // Schreiben scheitert — hier durch einen veralteten Stand.
    alice.db.raw.execute("UPDATE meta SET value = '4242' WHERE key = 'generation'");
    expect(() => alice.repo.commit(alice.store),
        throwsA(isA<StaleStateException>()));

    // Der Merkzettel darf NICHT geleert sein, sonst waere die Aenderung still
    // verloren.
    expect(alice.store.isDirty, isTrue);
    expect(alice.store.delta.signedPreKeys, contains(77));
    expect(alice.store.delta.kyberPreKeys, contains(78));

    // Stand wieder geradeziehen, dann klappt es.
    alice.db.raw.execute(
        "UPDATE meta SET value = '${alice.db.generation}' WHERE key = 'generation'");
    alice.repo.commit(alice.store);
    expect(alice.store.isDirty, isFalse);
    expect(_zahl(alice.db, 'SELECT count(*) c FROM signed_pre_keys WHERE id = 77'),
        1);
    expect(
        _zahl(alice.db,
            'SELECT count(*) c FROM kyber_pre_keys WHERE id = 78 AND letzte_rettung = 1'),
        1);
  });

  test('geloeschte Eintraege verschwinden auch aus der Datei', () async {
    final alice = await Geraet.neu(pfad('alice'), otkAnzahl: 10);
    addTearDown(alice.schliessen);
    expect(_zahl(alice.db, 'SELECT count(*) c FROM pre_keys'), 10);

    await alice.store.removePreKey(3);
    await alice.store.removePreKey(7);
    await alice.store.removeKyberPreKey(100);
    alice.repo.commit(alice.store);

    final uebrig = alice.db.raw
        .select('SELECT id FROM pre_keys ORDER BY id')
        .map((r) => r['id'] as int)
        .toList();
    expect(uebrig, [1, 2, 4, 5, 6, 8, 9, 10]);
    final kyber = alice.db.raw
        .select('SELECT id FROM kyber_pre_keys ORDER BY id')
        .map((r) => r['id'] as int)
        .toList();
    expect(kyber, [1, 101]);
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
    // Zufall von 1..16380: eine Gleichheit ist moeglich (p = 1/16380), aber
    // zu selten, um den Test aufzuweichen.
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
