// signal_store_test.dart — prueft die fuenf Speicher.
//
// Drei Sorten Tests stehen hier nebeneinander:
//
//  1. VERTRAGSTREUE. libsignal ruft diese Methoden ueber die Anbindung selbst
//     auf und verlaesst sich auf ihr genaues Verhalten — etwa darauf, dass
//     loadSession fuer eine unbekannte Adresse null liefert. Weicht der
//     Speicher hier ab, bricht der Sitzungsaufbau an einer Stelle, die weit
//     entfernt aussieht.
//
//  2. DIE ABWEICHUNG VON DER REFERENZ. BitDM prueft Identitaeten nicht ueber
//     Vertrauen, sondern rechnet nach. Das ist der Kern des Sicherheits-
//     versprechens und wird entsprechend hart geprueft.
//
//  3. DER KYBER-SPEICHER (seit 2.0.0). Der Record sagt nicht, ob ein Kyber-
//     Prekey ein Einmal- oder der Last-Resort-Schluessel ist; das muss der
//     Speicher wissen. Und die Liste der Last-Resort-Nutzungen ist der Schutz,
//     den LS-1 im Audit vom 16.10.2026 vermisste.

import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

/// Erzeugt eine Identitaet samt zugehoeriger libsignal-Adresse.
Future<({SignalIdentity identity, ProtocolAddress addr})> _wer() async {
  final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
  final id = SignalIdentityBridge.fromDerived(keys,
      registrationId: SignalIdentityBridge.newRegistrationId());
  return (identity: id, addr: adr(id.address));
}

/// Ein echtes SessionRecord, serialisiert.
///
/// Die offizielle Bibliothek kennt kein leeres `SessionRecord()` mehr wie die
/// Dart-Nachbildung; ein Record entsteht nur aus einem Sitzungsaufbau. Fuer
/// die Vertragstests reicht EIN echter, der dann beliebig oft eingelesen wird.
Future<Uint8List> _echteSitzung() async {
  final a = await _wer();
  final b = await _wer();
  final sa = BitdmSignalStore(identity: a.identity);
  final sb = BitdmSignalStore(identity: b.identity);
  final paar = b.identity.keyPair;
  final spk = neuerSpk(paar, 1);
  await sb.storeSignedPreKey(1, spk);
  final kyber = neuerKyber(paar, 1);
  await sb.storeLastResortKyberPreKey(1, kyber);
  await bauerVon(sa).processPreKeyBundle(
    b.addr,
    PreKeyBundle(
      registrationId: b.identity.registrationId,
      deviceId: 1,
      signedPreKeyId: 1,
      signedPreKeyPublic: spk.publicKey(),
      signedPreKeySignature: spk.signature(),
      identityKey: paar.publicKey,
      kyberPreKeyId: 1,
      kyberPreKeyPublic: kyber.getPublicKey().serialize(),
      kyberPreKeySignature: kyber.signature(),
    ),
  );
  return sa.state.sessions.values.single;
}

/// Ein Basisschluessel, wie er in einer Erstnachricht steht.
PublicKey _basis() => PrivateKey.generate().getPublicKey();

/// Was ein Zustand enthaelt — als einfache Werte, damit zwei Staende sich
/// vergleichen lassen, ohne dass Identitaet der Objekte mitspielt.
Map<String, Object> _abbild(SignalStoreState s) => {
      'identities': {
        for (final e in s.identities.entries) e.key: e.value.toList()
      },
      'preKeys': {for (final e in s.preKeys.entries) e.key: e.value.toList()},
      'signedPreKeys': {
        for (final e in s.signedPreKeys.entries) e.key: e.value.toList()
      },
      'kyberPreKeys': {
        for (final e in s.kyberPreKeys.entries)
          e.key: [e.value.letzteRettung, ...e.value.record]
      },
      'kyberBenutzt': {...s.kyberBenutzt},
      'sessions': {for (final e in s.sessions.entries) e.key: e.value.toList()},
    };

Map<String, Object> _merkzettel(StoreDelta d) => {
      'identities': {...d.identities},
      'preKeys': {...d.preKeys},
      'signedPreKeys': {...d.signedPreKeys},
      'kyberPreKeys': {...d.kyberPreKeys},
      'kyberBenutzt': {...d.kyberBenutzt},
      'sessions': {...d.sessions},
    };

void main() {
  late SignalIdentity ich;
  late BitdmSignalStore store;
  late Uint8List sitzungsBytes;

  /// Ein frisch eingelesenes Record — jedes Mal ein eigenes Objekt.
  SessionRecord sitzung() =>
      SessionRecord.deserialize(bytes: Uint8List.fromList(sitzungsBytes));

  setUpAll(() async {
    await signalBereit();
    sitzungsBytes = await _echteSitzung();
  });

  setUp(() async {
    final k = await KeyDerivation.fromMnemonic(Bip39.generate());
    ich = SignalIdentityBridge.fromDerived(k, registrationId: 4242);
    store = BitdmSignalStore(identity: ich);
  });

  group('Eigene Identitaet', () {
    test('liefert das eigene Schluesselpaar', () async {
      final kp = await store.getIdentityKeyPair();
      expect(SignalIdentityBridge.rawPublicKeyOfSerialized(kp.publicKey),
          ich.rawPublicKey);
    });

    test('liefert die Installationskennung', () async {
      expect(await store.getLocalRegistrationId(), 4242);
    });
  });

  group('Identitaeten werden NACHGERECHNET, nicht geglaubt', () {
    // DIE ANBINDUNG (libsignal 8.0.0) RUFT isTrustedIdentity NICHT SELBST AUF.
    // Sie gibt libsignal den gespeicherten Schluessel aus getIdentity mit und
    // laesst dann saveIdentity schreiben. Die Nachrechnung wirkt im Ablauf
    // deshalb ueber saveIdentity (unten: es wirft). isTrustedIdentity bleibt
    // Teil der Schnittstelle und dieselbe Rechnung — wer es fragt, muss die
    // richtige Antwort bekommen.
    test('passender Schluessel wird angenommen', () async {
      final gegen = await _wer();
      expect(
          await store.isTrustedIdentity(
              gegen.addr, gegen.identity.publicKey, Direction.receiving),
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
          await store.isTrustedIdentity(
              opfer.addr, angreifer.identity.publicKey, Direction.receiving),
          isFalse,
          reason: 'Schluessel gehoert nicht zu dieser Adresse');
    });

    // ENTFALLEN: "null-Schluessel wird abgelehnt". Die Schnittstelle der
    // offiziellen Anbindung nimmt einen PublicKey, kein PublicKey?; ein null
    // kann gar nicht mehr ankommen.

    test('ein fremder Schluessel wird NICHT abgelegt — und es fliegt nichts',
        () async {
      // BIS 16.10.2026 WARF saveIdentity hier. Das ist ein Rueckruf aus
      // libsignal; ein Wurf wird dort zur Panic im Rust-Faden, und im Browser
      // kehrt der Aufruf danach nie zurueck (signal_store.dart). Abgewehrt
      // wird der fremde Schluessel jetzt VOR libsignal (signal_errors.dart
      // `FremdeIdentitaet`) und von libsignal selbst ueber getIdentity (siehe
      // unten). saveIdentity lehnt nur noch still ab.
      final opfer = await _wer();
      final angreifer = await _wer();
      expect(await store.saveIdentity(opfer.addr, angreifer.identity.publicKey),
          isFalse);
      expect(store.isDirty, isFalse,
          reason: 'es darf nichts davon im Speicher haengen bleiben');
      expect(store.state.identities[opfer.identity.address], isNull);
    });

    test('getIdentity liefert IMMER den Schluessel der Adresse — auch ohne '
        'gespeicherten', () async {
      // Die Adresse IST der Schluessel. Liefert der Speicher ihn fuer jede
      // Adresse, prueft libsignal selbst gegen genau diesen und lehnt einen
      // fremden mit `untrustedIdentity` ab, BEVOR eine Sitzung entsteht.
      final gegen = await _wer();
      final zurueck = await store.getIdentity(gegen.addr);
      expect(zurueck, isNotNull);
      expect(SignalIdentityBridge.rawPublicKeyOf(zurueck!),
          gegen.identity.rawPublicKey);
      expect(await store.getIdentity(adr('keine-bitdm-adresse')), isNull,
          reason: 'eine Adresse, die keine ist, ergibt keinen Schluessel');
    });

    test('gilt fuer viele zufaellige Paare', () async {
      for (var i = 0; i < 8; i++) {
        final a = await _wer();
        final b = await _wer();
        expect(
            await store.isTrustedIdentity(
                a.addr, a.identity.publicKey, Direction.receiving),
            isTrue);
        expect(
            await store.isTrustedIdentity(
                a.addr, b.identity.publicKey, Direction.sending),
            isFalse);
      }
    });

    test('formatierte Adresse wird ebenso akzeptiert', () async {
      // Die UI zeigt Adressen in 14 Gruppen a 4. Wird so eine Schreibweise
      // durchgereicht, darf die Pruefung nicht daran scheitern.
      final gegen = await _wer();
      final formatiert = adr(BitdmAddress.format(gegen.identity.address));
      expect(
          await store.isTrustedIdentity(
              formatiert, gegen.identity.publicKey, Direction.receiving),
          isTrue);
    });
  });

  group('saveIdentity meldet Aenderungen', () {
    test('erstes Speichern meldet true, zweites false', () async {
      final gegen = await _wer();
      final key = gegen.identity.publicKey;
      expect(await store.saveIdentity(gegen.addr, key), isTrue);
      expect(await store.saveIdentity(gegen.addr, key), isFalse,
          reason: 'unveraendert');
    });

    test('gespeicherte Identitaet ist wieder abrufbar — fuer jedes Geraet',
        () async {
      // Identitaeten liegen je ADRESSE, nicht je Geraet: ein zweites Telefon
      // derselben Adresse hat denselben Schluessel.
      final gegen = await _wer();
      expect(store.state.identities[gegen.identity.address], isNull);
      await store.saveIdentity(gegen.addr, gegen.identity.publicKey);
      expect(store.state.identities[gegen.identity.address], isNotNull);
      for (final geraet in [1, 2]) {
        final zurueck =
            await store.getIdentity(adr(gegen.identity.address, geraet));
        expect(zurueck, isNotNull);
        expect(SignalIdentityBridge.rawPublicKeyOf(zurueck!),
            gegen.identity.rawPublicKey);
      }
    });
  });

  group('Sitzungen — Vertragstreue gegenueber libsignal', () {
    test('unbekannte Adresse liefert null', () async {
      // ERSETZT "liefert ein LEERES Record": Die Dart-Nachbildung verlangte
      // ein leeres Record, die offizielle Anbindung verlangt null ("Returns
      // null if no session exists", stores/session_store.dart). Ein leeres
      // Record gibt es dort gar nicht mehr.
      final gegen = await _wer();
      expect(await store.loadSession(gegen.addr), isNull);
      expect(await store.containsSession(gegen.addr), isFalse);
    });

    test('gespeicherte Sitzung kommt unveraendert zurueck', () async {
      final gegen = await _wer();
      final rec = sitzung();
      await store.storeSession(gegen.addr, rec);
      expect(await store.containsSession(gegen.addr), isTrue);
      final zurueck = await store.loadSession(gegen.addr);
      expect(zurueck!.serialize(), rec.serialize());
    });

    test('deleteSession trifft nur die eine Adresse', () async {
      final a = await _wer();
      final b = await _wer();
      await store.storeSession(a.addr, sitzung());
      await store.storeSession(b.addr, sitzung());
      await store.deleteSession(a.addr);
      expect(await store.containsSession(a.addr), isFalse);
      expect(await store.containsSession(b.addr), isTrue);
    });

    test('deleteAllSessions trifft alle Geraete EINER Adresse', () async {
      final a = await _wer();
      final b = await _wer();
      for (final d in [1, 2, 3]) {
        await store.storeSession(adr(a.identity.address, d), sitzung());
      }
      await store.storeSession(b.addr, sitzung());

      await store.deleteAllSessions(a.identity.address);
      for (final d in [1, 2, 3]) {
        expect(await store.containsSession(adr(a.identity.address, d)),
            isFalse);
      }
      expect(await store.containsSession(b.addr), isTrue,
          reason: 'fremde Adresse darf nicht mitgeloescht werden');
    });

    test('getSubDeviceSessions laesst Geraet 1 aus, geraeteVon nicht',
        () async {
      final a = await _wer();
      for (final d in [5, 1, 2]) {
        await store.storeSession(adr(a.identity.address, d), sitzung());
      }
      final sub = await store.getSubDeviceSessions(a.identity.address);
      expect(sub..sort(), [2, 5]);
      expect(store.geraeteVon(a.identity.address), [1, 2, 5]);
    });

    test('der Sitzungsschluessel ist "adresse:geraet" wie bis 1.9.x', () async {
      // Das Format steht in jeder bestehenden Datenbank. Aendert es sich,
      // findet die App nach dem Update keine Zeile mehr wieder.
      final a = await _wer();
      await store.storeSession(adr(a.identity.address, 3), sitzung());
      expect(store.state.sessions.keys, ['${a.identity.address}:3']);
    });
  });

  group('Prekeys', () {
    test('unbekannte Nummer liefert null', () async {
      // ERSETZT "wirft InvalidKeyIdException": Die offizielle Anbindung will
      // null und macht daraus selbst `invalidKeyIdentifier`. NORMALFALL, kein
      // Ausnahmefall: eine doppelt zugestellte Erstnachricht verweist auf
      // einen Prekey, der beim ersten Mal verbraucht wurde.
      expect(await store.loadPreKey(999), isNull);
      expect(await store.loadSignedPreKey(999), isNull);
      expect(await store.loadKyberPreKey(999), isNull);
    });

    test('speichern, lesen, zaehlen, entfernen', () async {
      for (var id = 1; id <= 5; id++) {
        await store.storePreKey(id, neuerPreKey(id));
      }
      expect(store.preKeyCount, 5);
      expect(await store.containsPreKey(1), isTrue);
      expect((await store.loadPreKey(1))!.id(), 1);
      expect((await store.getAllPreKeyIds())..sort(), [1, 2, 3, 4, 5]);

      await store.removePreKey(1);
      expect(await store.containsPreKey(1), isFalse);
      expect(store.preKeyCount, 4);
    });

    test('signierte Prekeys lassen sich sammeln', () async {
      final kp = await store.getIdentityKeyPair();
      for (var i = 1; i <= 3; i++) {
        await store.storeSignedPreKey(i, neuerSpk(kp, i));
      }
      expect((await store.getAllSignedPreKeyIds())..sort(), [1, 2, 3]);
      expect((await store.loadSignedPreKey(2))!.id(), 2);
      await store.removeSignedPreKey(2);
      expect(await store.containsSignedPreKey(2), isFalse);
    });
  });

  group('Kyber-Prekeys: zwei Arten, und der Record sagt nicht, welche', () {
    test('ein Einmalschluessel wird bei markKyberPreKeyUsed verbraucht',
        () async {
      // Bleibt er nach der Markierung lesbar, schuetzt die Markierung nichts:
      // eine zweite Sitzung mit demselben Schluessel ginge durch.
      await store.storeKyberPreKey(7, neuerKyber(ich.keyPair, 7));
      expect(store.kyberEinmalCount, 1);
      store.markClean();

      await store.markKyberPreKeyUsed(7, 1, _basis());

      expect(await store.containsKyberPreKey(7), isFalse);
      expect(await store.loadKyberPreKey(7), isNull,
          reason: 'ein verbrauchter Einmalschluessel darf nie wieder '
              'ausgegeben werden');
      expect(store.kyberEinmalCount, 0);
      expect(store.state.kyberBenutzt, isEmpty,
          reason: 'fuer Einmalschluessel braucht es keine Tripel');
      expect(store.kyberWiederholungen, 0);
      expect(store.delta.kyberPreKeys, {7},
          reason: 'das Loeschen muss mit festgeschrieben werden');
    });

    test('der Last-Resort-Schluessel bleibt und merkt sich das Tripel',
        () async {
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      store.markClean();
      final basis = _basis();

      await store.markKyberPreKeyUsed(1, 3, basis);

      expect(await store.loadKyberPreKey(1), isNotNull,
          reason: 'der Last-Resort-Schluessel wird weiter ausgegeben');
      expect(store.letzteRettungId, 1);
      final tripel = BitdmSignalStore.kyberTripel(1, 3, basis.serialize());
      expect(store.state.kyberBenutzt, {tripel});
      expect(store.delta.kyberBenutzt, {tripel});
      expect(store.delta.kyberPreKeys, isEmpty,
          reason: 'der Schluessel selbst hat sich nicht geaendert');
      expect(store.kyberWiederholungen, 0, reason: 'erste Nutzung');
    });

    test('dasselbe Tripel zweimal erhoeht kyberWiederholungen', () async {
      // GENAU DAS ist die erneut eingespielte Erstnachricht. Der Speicher darf
      // hier nicht werfen (Panic im Rust-Thread); der Empfangspfad liest den
      // Zaehler und verwirft.
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      final basis = _basis();
      await store.markKyberPreKeyUsed(1, 3, basis);
      store.markClean();

      await expectLater(store.markKyberPreKeyUsed(1, 3, basis), completes);
      expect(store.kyberWiederholungen, 1);
      expect(store.isDirty, isFalse,
          reason: 'eine Wiederholung bringt nichts Neues zum Festschreiben');

      await store.markKyberPreKeyUsed(1, 3, basis);
      expect(store.kyberWiederholungen, 2, reason: 'jede Wiederholung zaehlt');
    });

    test('ein anderes Tripel ist keine Wiederholung', () async {
      // Anderer Absender (anderer Basisschluessel) oder derselbe Kyber-
      // Schluessel mit einem anderen signierten Prekey: das sind neue
      // Vereinbarungen, die durchgehen muessen — sonst waere der
      // Last-Resort-Schluessel nach dem ersten Kontakt unbrauchbar.
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      final basis = _basis();
      await store.markKyberPreKeyUsed(1, 3, basis);
      await store.markKyberPreKeyUsed(1, 3, _basis());
      await store.markKyberPreKeyUsed(1, 4, basis);
      expect(store.kyberWiederholungen, 0);
      expect(store.state.kyberBenutzt, hasLength(3));
    });

    test('unbekannte Nummer: still, ohne Wurf, ohne Eintrag', () async {
      await expectLater(store.markKyberPreKeyUsed(999, 1, _basis()), completes);
      expect(store.isDirty, isFalse);
      expect(store.kyberWiederholungen, 0);
    });

    test('removeKyberPreKey raeumt die Tripel des Schluessels ab — und nur '
        'die', () async {
      // 1 und 12: das Tripel beginnt mit "kyberId:". Ein Praefix ohne
      // Trennzeichen raeumte bei 1 auch die von 12 mit ab.
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      await store.storeLastResortKyberPreKey(12, neuerKyber(ich.keyPair, 12));
      final basis = _basis();
      await store.markKyberPreKeyUsed(1, 3, basis);
      await store.markKyberPreKeyUsed(1, 3, _basis());
      await store.markKyberPreKeyUsed(12, 3, basis);
      final von12 = BitdmSignalStore.kyberTripel(12, 3, basis.serialize());
      final von1 = {...store.state.kyberBenutzt}..remove(von12);
      store.markClean();

      await store.removeKyberPreKey(1);

      expect(await store.containsKyberPreKey(1), isFalse);
      expect(store.state.kyberBenutzt, {von12});
      expect(store.delta.kyberBenutzt, von1,
          reason: 'das Loeschen der Tripel muss mit festgeschrieben werden');
      expect(store.delta.kyberPreKeys, {1});

      // Ohne den Schluessel gibt es nichts mehr zu entschluesseln, also auch
      // nichts mehr zu zaehlen.
      await store.markKyberPreKeyUsed(1, 3, basis);
      expect(store.kyberWiederholungen, 0);
    });

    test('letzteRettungId und kyberEinmalCount unterscheiden die Arten',
        () async {
      expect(store.letzteRettungId, isNull);
      await store.storeLastResortKyberPreKey(3, neuerKyber(ich.keyPair, 3));
      await store.storeLastResortKyberPreKey(5, neuerKyber(ich.keyPair, 5));
      await store.storeKyberPreKey(10, neuerKyber(ich.keyPair, 10));
      await store.storeKyberPreKey(11, neuerKyber(ich.keyPair, 11));

      expect(store.letzteRettungId, 5,
          reason: 'waehrend einer Erneuerung gilt die hoechste Nummer');
      expect(store.kyberEinmalCount, 2);
      expect((await store.getAllKyberPreKeyIds())..sort(), [3, 5, 10, 11]);
      expect(store.state.kyberPreKeys[3]!.letzteRettung, isTrue);
      expect(store.state.kyberPreKeys[10]!.letzteRettung, isFalse);
    });

    test('ein Kyber-Record kommt byte-gleich zurueck', () async {
      final k = neuerKyber(ich.keyPair, 9);
      await store.storeKyberPreKey(9, k);
      final zurueck = await store.loadKyberPreKey(9);
      expect(zurueck!.serialize(), k.serialize());
      expect(zurueck.signature(), k.signature());
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
      await store.loadKyberPreKey(1);
      await store.getIdentity(gegen.addr);
      await store.getIdentityKeyPair();
      expect(store.isDirty, isFalse);
    });

    test('jeder Bereich meldet sich einzeln', () async {
      final gegen = await _wer();
      await store.saveIdentity(gegen.addr, gegen.identity.publicKey);
      expect(store.dirtySections, {StoreSection.identity});

      await store.storeSession(gegen.addr, sitzung());
      expect(store.dirtySections,
          {StoreSection.identity, StoreSection.session});

      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      expect(store.dirtySections, contains(StoreSection.kyberPreKey));

      store.markClean();
      await store.markKyberPreKeyUsed(1, 1, _basis());
      expect(store.dirtySections, {StoreSection.kyberBenutzt});

      store.markClean();
      expect(store.isDirty, isFalse);
    });

    test('erfolgloses Entfernen macht nicht schmutzig', () async {
      await store.removePreKey(12345);
      await store.removeSignedPreKey(12345);
      await store.removeKyberPreKey(12345);
      await store.deleteSession(adr((await _wer()).identity.address));
      expect(store.isDirty, isFalse,
          reason: 'es gab nichts zu entfernen, also nichts zu schreiben');
    });

    test('unveraendertes Speichern derselben Identitaet meldet sich nicht',
        () async {
      final gegen = await _wer();
      final key = gegen.identity.publicKey;
      await store.saveIdentity(gegen.addr, key);
      store.markClean();
      await store.saveIdentity(gegen.addr, key);
      expect(store.isDirty, isFalse);
    });
  });

  group('Zustand laesst sich uebergeben und wiederherstellen', () {
    test('ein Speicher kann auf vorhandenem Zustand aufsetzen', () async {
      final gegen = await _wer();
      await store.saveIdentity(gegen.addr, gegen.identity.publicKey);
      await store.storeSession(gegen.addr, sitzung());
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      await store.markKyberPreKeyUsed(1, 1, _basis());

      // So wird es spaeter aus der Datenbank kommen.
      final neuer = BitdmSignalStore(identity: ich, state: store.state.copy());

      expect(await neuer.containsSession(gegen.addr), isTrue);
      expect(await neuer.getIdentity(gegen.addr), isNotNull);
      expect(neuer.letzteRettungId, 1);
      expect(neuer.state.kyberBenutzt, store.state.kyberBenutzt);
      expect(neuer.isDirty, isFalse,
          reason: 'geladener Zustand ist noch nicht veraendert');
    });

    test('copy() entkoppelt wirklich', () async {
      final gegen = await _wer();
      final kopie = store.state.copy();
      await store.storeSession(gegen.addr, sitzung());
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      await store.markKyberPreKeyUsed(1, 1, _basis());
      expect(kopie.sessions, isEmpty,
          reason: 'die Kopie darf spaetere Aenderungen nicht sehen');
      expect(kopie.kyberPreKeys, isEmpty);
      expect(kopie.kyberBenutzt, isEmpty);
    });
  });

  group('schnappschuss und stelleWiederHer', () {
    // Der Empfangspfad haelt vor jeder Erstnachricht den Stand fest. Faellt
    // nach dem Entschluesseln auf, dass sie erneut eingespielt war, stellt er
    // ihn wieder her (real_messenger_core `_nimmUmschlagJetzt`). Bleibt dabei
    // auch nur ein Eintrag stehen — oder fehlt einer im Merkzettel —, schreibt
    // der Fehlerpfad eine eingeschleuste Sitzung fest oder verliert eine echte
    // Aenderung.

    /// Ein Speicher mit Inhalt in jedem Bereich und einem halb vollen
    /// Merkzettel: ein Teil ist schon festgeschrieben, ein Teil nicht.
    Future<ProtocolAddress> fuelle() async {
      final gegen = await _wer();
      await store.saveIdentity(gegen.addr, gegen.identity.publicKey);
      await store.storeSession(gegen.addr, sitzung());
      await store.storePreKey(1, neuerPreKey(1));
      await store.storeSignedPreKey(1, neuerSpk(ich.keyPair, 1));
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      await store.storeKyberPreKey(2, neuerKyber(ich.keyPair, 2));
      await store.markKyberPreKeyUsed(1, 1, _basis());
      store.markClean();
      // Noch offen zum Zeitpunkt des Schnappschusses:
      await store.storePreKey(3, neuerPreKey(3));
      await store.markKyberPreKeyUsed(1, 1, _basis());
      return gegen.addr;
    }

    /// Alles, was libsignal bei einer eingeschleusten Erstnachricht anfassen
    /// kann, und etwas mehr.
    Future<void> verbiege(ProtocolAddress gegen) async {
      final dritter = await _wer();
      await store.saveIdentity(dritter.addr, dritter.identity.publicKey);
      await store.storeSession(adr(gegen.name(), 2), sitzung());
      await store.deleteSession(gegen);
      await store.removePreKey(1);
      await store.removePreKey(3);
      await store.storeSignedPreKey(9, neuerSpk(ich.keyPair, 9));
      await store.markKyberPreKeyUsed(2, 1, _basis()); // Einmal: verbraucht
      await store.markKyberPreKeyUsed(1, 1, _basis()); // neues Tripel
      await store.storeKyberPreKey(4, neuerKyber(ich.keyPair, 4));
    }

    test('stellen Zustand und Merkzettel exakt her', () async {
      final gegen = await fuelle();
      final zustandVorher = _abbild(store.state);
      final merkVorher = _merkzettel(store.delta);
      expect(merkVorher['preKeys'], isNotEmpty,
          reason: 'ohne offenen Merkzettel prueft der Test die Haelfte nicht');

      final s = store.schnappschuss();
      await verbiege(gegen);
      expect(_abbild(store.state), isNot(zustandVorher),
          reason: 'sonst prueft der Test nichts');

      store.stelleWiederHer(s);

      expect(_abbild(store.state), zustandVorher);
      expect(_merkzettel(store.delta), merkVorher,
          reason: 'was vorher offen war, muss offen bleiben — und nichts von '
              'dem Verbogenen darf zum Festschreiben vorgemerkt sein');
    });

    test('der Schnappschuss sieht spaetere Aenderungen nicht und traegt '
        'mehrfach', () async {
      final gegen = await fuelle();
      final zustandVorher = _abbild(store.state);
      final s = store.schnappschuss();

      await verbiege(gegen);
      store.stelleWiederHer(s);
      // Nach dem Zuruecksetzen weiterarbeiten darf den Schnappschuss nicht
      // veraendern — sonst haengen Speicher und Schnappschuss aneinander.
      await verbiege(gegen);
      store.stelleWiederHer(s);

      expect(_abbild(store.state), zustandVorher);
    });

    test('kyberWiederholungen faellt beim Zuruecksetzen nicht zurueck',
        () async {
      // Der Zaehler "steigt nie wieder ab" (signal_store.dart). Fiele er mit
      // dem Schnappschuss zurueck, saehe ein zweiter Vergleich im selben
      // Ablauf eine Wiederholung nicht mehr.
      await store.storeLastResortKyberPreKey(1, neuerKyber(ich.keyPair, 1));
      final basis = _basis();
      await store.markKyberPreKeyUsed(1, 1, basis);
      final s = store.schnappschuss();
      await store.markKyberPreKeyUsed(1, 1, basis);
      expect(store.kyberWiederholungen, 1);
      store.stelleWiederHer(s);
      expect(store.kyberWiederholungen, 1);
    });
  });
}
