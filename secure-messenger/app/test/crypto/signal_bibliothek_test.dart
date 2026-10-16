// signal_bibliothek_test.dart — die Korrekturen am eigenen Stand der
// Signal-Bibliothek (third_party/libsignal_protocol_dart).
//
// Diese Tests pruefen NICHT BitDM-Code, sondern die Bibliothek darunter. Sie
// gehoeren trotzdem hierher: der gepatchte Stand liegt im Repo, und ohne
// Tests faellt beim naechsten Fassungswechsel niemandem auf, wenn eine der
// Korrekturen verlorengeht. Jeder Test war gegen die unveraenderte 0.8.2 rot
// (Abgleich in third_party/libsignal_protocol_dart/BITDM-AENDERUNGEN.md).
//
// Benutzt werden die mitgelieferten In-Memory-Speicher der Bibliothek. Sie
// deserialisieren bei jedem loadSession frisch, genau wie BitdmSignalStore
// (signal_store.dart). Deshalb sind die Ergebnisse auf BitDM uebertragbar.
//
// Wo geprueft wird, DASS etwas wirft, wird der geworfene Wert eingesammelt
// und AUSSERHALB des try geprueft — aus demselben Grund wie in
// test/store/session_exchange_test.dart: ein fail() im try-Block faengt sich
// selbst wieder ein, und der Test bliebe gerade dann gruen, wenn nichts
// geworfen wurde.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
// ignore: implementation_imports
import 'package:libsignal_protocol_dart/src/invalid_message_exception.dart';
// ignore: implementation_imports
import 'package:libsignal_protocol_dart/src/state/whisper_text_protocol.pb.dart'
    as wp;

/// Der In-Memory-Speicher der Bibliothek, der mitschreibt, welche
/// Identitaeten gespeichert wurden.
///
/// Gebraucht fuer FZ-1: `getIdentity` des Speichers wirft bei einer
/// unbekannten Adresse (`trustedKeys[address]!`), taugt also nicht zum
/// Nachsehen. Die Mitschrift beantwortet die Frage direkt.
class MitschnittStore extends InMemorySignalProtocolStore {
  MitschnittStore(super.identityKeyPair, super.registrationId);

  final gespeichert = <String>[];

  @override
  Future<bool> saveIdentity(
      SignalProtocolAddress address, IdentityKey? identityKey) {
    gespeichert.add(address.getName());
    return super.saveIdentity(address, identityKey);
  }
}

/// Eine Gegenstelle mit eigener Identitaet, eigenem Speicher, eigenen Keys.
class Seite {
  Seite(this.name);

  final String name;
  late IdentityKeyPair identity;
  late MitschnittStore store;
  late SignedPreKeyRecord spk;

  SignalProtocolAddress get addr => SignalProtocolAddress(name, 1);

  Future<void> start() async {
    identity = generateIdentityKeyPair();
    store = MitschnittStore(identity, generateRegistrationId(false));
    spk = generateSignedPreKey(identity, 1);
    await store.storeSignedPreKey(spk.id, spk);
  }

  /// Was ein Relay als Buendel ausliefern wuerde.
  Future<PreKeyBundle> buendel({int? otpkId}) async {
    PreKeyRecord? pk;
    if (otpkId != null) {
      pk = generatePreKeys(otpkId, 1).first;
      await store.storePreKey(pk.id, pk);
    }
    return PreKeyBundle(
      await store.getLocalRegistrationId(),
      1,
      pk?.id,
      pk?.getKeyPair().publicKey,
      spk.id,
      spk.getKeyPair().publicKey,
      spk.signature,
      identity.getPublicKey(),
    );
  }
}

/// Eine Nachricht auf dem Draht: Art und Bytes, wie der Relay sie sieht.
class Draht {
  Draht(this.art, this.bytes);

  final int art;
  final Uint8List bytes;

  Draht kopie() => Draht(art, Uint8List.fromList(bytes));
}

Future<Draht> sende(Seite von, Seite an, String text) async {
  final ct = await SessionCipher.fromStore(von.store, an.addr)
      .encrypt(Uint8List.fromList(utf8.encode(text)));
  return Draht(ct.getType(), Uint8List.fromList(ct.serialize()));
}

/// Wie Envelope.decrypt in BitDM: Kopie der Bytes, dann je nach Art lesen.
Future<String> empfange(Seite bei, Seite von, Draht d) async {
  final cipher = SessionCipher.fromStore(bei.store, von.addr);
  final bytes = Uint8List.fromList(d.bytes);
  final klar = d.art == CiphertextMessage.prekeyType
      ? await cipher.decrypt(PreKeySignalMessage(bytes))
      : await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
  return utf8.decode(klar);
}

/// Sammelt, was [f] wirft — oder null, wenn es durchlief.
Future<Object?> wasFliegt(Future<void> Function() f) async {
  try {
    await f();
    return null;
  } catch (e) {
    return e;
  }
}

/// Wie [wasFliegt], meldet aber zusaetzlich, was als UNBEHANDELTER Fehler in
/// der Zone landet. Genau das ist der Kern von FZ-1: der Aufrufer bekommt
/// seine Ausnahme, und dieselbe Ausnahme fliegt ein zweites Mal an der
/// Fehlerbehandlung des Programms vorbei.
Future<(Object?, List<String>)> wasFliegtUndVerwaist(
    Future<void> Function() f) async {
  final verwaist = <String>[];
  final fertig = Completer<Object?>();
  runZonedGuarded(() async {
    fertig.complete(await wasFliegt(f));
  }, (e, _) {
    verwaist.add(e.runtimeType.toString());
  });
  final gefangen = await fertig.future;
  // Ein verwaistes Future meldet seinen Fehler erst im naechsten Microtask-
  // Durchlauf. Ohne diese Pause waere die Liste immer leer.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return (gefangen, verwaist);
}

Uint8List serialisiere(SessionRecord r) => Uint8List.fromList(r.serialize());

bool gleich(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Eine gefaelschte SignalMessage mit fremdem Ratchet-Schluessel.
///
/// Sie kommt bis zur MAC-Pruefung: die Bibliothek legt vorher einen neuen
/// Wurzelschluessel, eine neue Sendekette und uebersprungene Schluessel an.
/// Genau diese Vorarbeit darf den echten Zustand nicht anfassen (LS-2).
Uint8List gefaelschteNachricht({int counter = 0}) {
  final fremd = Curve.generateKeyPair();
  final m = wp.SignalMessage.create()
    ..ratchetKey = fremd.publicKey.serialize()
    ..counter = counter
    ..previousCounter = 0
    ..ciphertext = List<int>.filled(32, 7);
  return Uint8List.fromList(
      [0x33, ...m.writeToBuffer(), ...List<int>.filled(8, 0)]);
}

/// Der Ausgangspunkt fuer LS-2, ohne Angreifer und ohne LS-1.
///
/// Alice baut eine Sitzung, schickt eine Nachricht, die unterwegs liegen
/// bleibt, und baut danach eine zweite Sitzung auf (bei BitDM der Fall nach
/// einer Wiederherstellung oder wenn beide Seiten gleichzeitig eroeffnen).
/// Wird die liegengebliebene Nachricht dann zugestellt, scheitert Bobs
/// aktuelle Sitzung, und die archivierte entschluesselt sie — der Rueckfall
/// aufs Archiv, bei dem 0.8.2 den Zustand verbiegt.
class Rueckfall {
  Rueckfall(this.alice, this.bob, this.liegengeblieben, this.vorDemRueckfall);

  final Seite alice;
  final Seite bob;

  /// Die Nachricht aus der ersten Sitzung, die spaeter zugestellt wird.
  final Draht liegengeblieben;

  /// Bobs Record, serialisiert, unmittelbar vor der Zustellung.
  final Uint8List vorDemRueckfall;

  static Future<Rueckfall> aufbauen() async {
    final alice = Seite('alice');
    final bob = Seite('bob');
    await alice.start();
    await bob.start();

    // Erste Sitzung, ein paar Nachrichten hin und her.
    await SessionBuilder.fromSignalStore(alice.store, bob.addr)
        .processPreKeyBundle(await bob.buendel(otpkId: 7));
    await empfange(bob, alice, await sende(alice, bob, 'a1'));
    await empfange(alice, bob, await sende(bob, alice, 'b1'));

    // Diese bleibt unterwegs liegen.
    final liegengeblieben = await sende(alice, bob, 'a2: kommt spaeter an');

    // Alice baut eine zweite Sitzung auf und schreibt darueber.
    await SessionBuilder.fromSignalStore(alice.store, bob.addr)
        .processPreKeyBundle(await bob.buendel(otpkId: 8));
    await empfange(bob, alice, await sende(alice, bob, 'a3: neue Sitzung'));

    final vorher = serialisiere(await bob.store.loadSession(alice.addr));
    return Rueckfall(alice, bob, liegengeblieben, vorher);
  }
}

void main() {
  group('LS-1: Versionsbyte der Erstnachricht', () {
    test('Erstnachricht mit erhoehtem Versionsbyte wird abgelehnt', () async {
      // Das obere Nibble des ersten Bytes deckt kein MAC. Nimmt die
      // Bibliothek es ungeprueft an, findet die Duplikaterkennung die
      // laufende Sitzung nicht mehr und baut sie neu auf — die echte wird
      // dabei archiviert, und Bobs Antworten kann Alice nicht mehr lesen.
      final alice = Seite('alice');
      final bob = Seite('bob');
      await alice.start();
      await bob.start();

      // Ohne Einmal-Prekey: ob einer dabei ist, bestimmt der Relay.
      await SessionBuilder.fromSignalStore(alice.store, bob.addr)
          .processPreKeyBundle(await bob.buendel());
      final erst = await sende(alice, bob, 'a1: Hallo Bob');
      expect(await empfange(bob, alice, erst), 'a1: Hallo Bob');
      await empfange(alice, bob, await sende(bob, alice, 'b1'));

      final vorher = serialisiere(await bob.store.loadSession(alice.addr));

      final verbogen = erst.kopie()..bytes[0] = 0x43;
      final fehler = await wasFliegt(() => empfange(bob, alice, verbogen));

      expect(fehler, isA<InvalidMessageException>(),
          reason: 'eine unbekannte Protokollfassung muss abgelehnt werden, '
              'nicht als neue Sitzung durchgehen');
      expect(gleich(serialisiere(await bob.store.loadSession(alice.addr)),
              vorher),
          isTrue,
          reason: 'die laufende Sitzung darf dabei unangetastet bleiben');
    });

    test('Erstnachricht mit altem Versionsbyte wird abgelehnt', () async {
      final alice = Seite('alice');
      final bob = Seite('bob');
      await alice.start();
      await bob.start();
      await SessionBuilder.fromSignalStore(alice.store, bob.addr)
          .processPreKeyBundle(await bob.buendel());
      final erst = await sende(alice, bob, 'a1');

      final alt = erst.kopie()..bytes[0] = 0x23; // Fassung 2
      final fehler = await wasFliegt(() => empfange(bob, alice, alt));

      expect(fehler, isA<InvalidMessageException>());
    });

    test('die unveraenderte Erstnachricht laeuft weiter durch', () async {
      // Gegenprobe: die Pruefung darf den Normalfall nicht treffen.
      final alice = Seite('alice');
      final bob = Seite('bob');
      await alice.start();
      await bob.start();
      await SessionBuilder.fromSignalStore(alice.store, bob.addr)
          .processPreKeyBundle(await bob.buendel(otpkId: 7));
      final erst = await sende(alice, bob, 'a1');

      expect(await empfange(bob, alice, erst), 'a1');
      expect(await empfange(alice, bob, await sende(bob, alice, 'b1')), 'b1');
    });
  });

  group('LS-2: Fehlversuche duerfen den Sitzungszustand nicht verbiegen', () {
    test('die Arbeitskopie eines Zustands haengt nicht am Original', () async {
      // Das ist die Ursache. Java und Rust kopieren den Zustand, bevor sie
      // einen Entschluesselungsversuch machen, und uebernehmen nur den
      // erfolgreichen. 0.8.2 kopierte nur die Huelle und teilte das
      // Protobuf-Objekt — ein Fehlversuch verbog damit den echten Zustand.
      final alice = Seite('alice');
      final bob = Seite('bob');
      await alice.start();
      await bob.start();
      await SessionBuilder.fromSignalStore(alice.store, bob.addr)
          .processPreKeyBundle(await bob.buendel(otpkId: 7));
      await empfange(bob, alice, await sende(alice, bob, 'a1'));

      final original = (await bob.store.loadSession(alice.addr)).sessionState;
      final vorher = Uint8List.fromList(original.serialize());

      final kopie = SessionState.fromSessionState(original)
        ..previousCounter = 4711
        ..aliceBaseKey = Uint8List.fromList(List<int>.filled(33, 9));

      expect(gleich(original.serialize(), vorher), isTrue,
          reason: 'Aenderungen an der Kopie duerfen das Original nicht '
              'erreichen');
      expect(kopie.previousCounter, 4711,
          reason: 'und die Kopie muss fuer sich veraenderbar bleiben');
    });

    test('ein gescheiterter Versuch veraendert den gespeicherten Zustand '
        'nicht', () async {
      final alice = Seite('alice');
      final bob = Seite('bob');
      await alice.start();
      await bob.start();
      await SessionBuilder.fromSignalStore(alice.store, bob.addr)
          .processPreKeyBundle(await bob.buendel(otpkId: 7));
      await empfange(bob, alice, await sende(alice, bob, 'a1'));
      final vorher = serialisiere(await bob.store.loadSession(alice.addr));

      final fehler = await wasFliegt(() async {
        await SessionCipher.fromStore(bob.store, alice.addr)
            .decryptFromSignal(
                SignalMessage.fromSerialized(gefaelschteNachricht()));
      });

      expect(fehler, isA<InvalidMessageException>());
      expect(
          gleich(serialisiere(await bob.store.loadSession(alice.addr)), vorher),
          isTrue);

      // Und die echte naechste Nachricht muss danach weiter ankommen.
      expect(await empfange(bob, alice, await sende(alice, bob, 'a2')), 'a2');
    });

    test('nach dem Rueckfall aufs Archiv bleibt kein verbogener Zustand '
        'und keine Doppelkopie liegen', () async {
      final f = await Rueckfall.aufbauen();
      final archivVorher =
          SessionRecord.fromSerialized(f.vorDemRueckfall)
              .previousSessionStates
              .length;

      expect(await empfange(f.bob, f.alice, f.liegengeblieben),
          'a2: kommt spaeter an',
          reason: 'der Rueckfall aufs Archiv muss weiter funktionieren');

      final record = await f.bob.store.loadSession(f.alice.addr);

      // Der befoerderte Zustand muss aus dem Archiv GELOEST sein. Bleibt er
      // stehen, liegt dort eine Fassung mit noch unverbrauchten
      // Nachrichtenschluesseln — und die entschluesselt denselben Umschlag
      // spaeter ein zweites Mal, sobald die aktive Sitzung ihn nicht mehr
      // als Duplikat erkennt.
      expect(record.previousSessionStates.length, archivVorher,
          reason: 'einer raus, einer rein: das Archiv darf nicht wachsen');

      final aktuell = record.sessionState.serialize();
      for (final archiviert in record.previousSessionStates) {
        expect(gleich(archiviert.serialize(), aktuell), isFalse,
            reason: 'eine bytegleiche Momentaufnahme der aktiven Sitzung im '
                'Archiv macht spaetere Nachrichten wieder entschluesselbar');
      }

      // Der Zustand, an dem der Versuch scheiterte, muss unveraendert im
      // Archiv stehen — nicht mit neuem Wurzelschluessel und Scheinkette.
      final vorher = SessionRecord.fromSerialized(f.vorDemRueckfall);
      final vorherAktuell = vorher.sessionState.serialize();
      final gefunden = record.previousSessionStates
          .any((s) => gleich(s.serialize(), vorherAktuell));
      expect(gefunden, isTrue,
          reason: 'der gescheiterte Zustand wird archiviert, wie er war');
    });

    test('eine laengst zugestellte Nachricht laesst sich spaeter nicht '
        'erneut einspielen', () async {
      final f = await Rueckfall.aufbauen();
      expect(await empfange(f.bob, f.alice, f.liegengeblieben),
          'a2: kommt spaeter an');

      // Sechs Runden, damit die passende Empfangskette in der aktiven
      // Sitzung verdraengt wird (die Bibliothek haelt fuenf).
      for (var i = 1; i <= 6; i++) {
        expect(await empfange(f.bob, f.alice, await sende(f.alice, f.bob, 'd$i')),
            'd$i');
        expect(await empfange(f.alice, f.bob, await sende(f.bob, f.alice, 'e$i')),
            'e$i');
      }

      final fehler = await wasFliegt(
          () => empfange(f.bob, f.alice, f.liegengeblieben.kopie()));
      expect(fehler, isNotNull,
          reason: 'die Double-Ratchet-Schicht muss Wiederholungen abweisen; '
              'BitDM verlaesst sich darauf bei Steuernachrichten');
    });

    test('ein wiederholter Umschlag laesst die Sitzung nicht zurueckspringen '
        'und keinen Schluessel doppelt benutzen', () async {
      final f = await Rueckfall.aufbauen();
      expect(await empfange(f.bob, f.alice, f.liegengeblieben),
          'a2: kommt spaeter an');

      // Jede Nachricht, die Bob sendet, wird mitgeschrieben: gleicher
      // Ratchet-Schluessel und gleicher Zaehler bedeuten gleicher
      // Nachrichtenschluessel und gleiches IV.
      final gesehen = <String>{};
      Future<void> bobSendet(String text) async {
        final d = await sende(f.bob, f.alice, text);
        final m = SignalMessage.fromSerialized(Uint8List.fromList(d.bytes));
        final kennung =
            '${base64.encode(m.getSenderRatchetKey().serialize())}@'
            '${m.getCounter()}';
        expect(gesehen.add(kennung), isTrue,
            reason: 'Schluessel und IV duerfen sich nicht wiederholen');
      }

      await bobSendet('c1: gleicher Anfang');
      for (var i = 1; i <= 6; i++) {
        await empfange(f.bob, f.alice, await sende(f.alice, f.bob, 'd$i'));
        await bobSendet('e$i');
      }

      final aktuellVorher =
          (await f.bob.store.loadSession(f.alice.addr)).sessionState.serialize();
      await wasFliegt(
          () => empfange(f.bob, f.alice, f.liegengeblieben.kopie()));
      final aktuellNachher =
          (await f.bob.store.loadSession(f.alice.addr)).sessionState.serialize();

      expect(gleich(aktuellNachher, aktuellVorher), isTrue,
          reason: 'ein wiederholter alter Umschlag darf die aktive Sitzung '
              'nicht auf einen alten Stand befoerdern');
      await bobSendet('f1: gleicher Anfang');
    });
  });

  group('FZ-1: kein verwaister Fehler beim Sitzungsaufbau', () {
    test('unbekannte Nummer des signierten Prekeys', () async {
      final bob = Seite('bob');
      final mallory = Seite('mallory');
      await bob.start();
      await mallory.start();

      final echt = await bob.buendel();
      final falsch = PreKeyBundle(echt.getRegistrationId(), 1, null, null, 99,
          echt.getSignedPreKey(), echt.getSignedPreKeySignature(),
          echt.getIdentityKey());
      await SessionBuilder.fromSignalStore(mallory.store, bob.addr)
          .processPreKeyBundle(falsch);
      final erst = await sende(mallory, bob, 'hallo');

      final (gefangen, verwaist) = await wasFliegtUndVerwaist(
          () => empfange(bob, mallory, erst));

      expect(gefangen, isA<InvalidKeyIdException>(),
          reason: 'der Aufrufer muss den Fehler bekommen');
      expect(verwaist, isEmpty,
          reason: 'und er darf nicht zusaetzlich an der Fehlerbehandlung des '
              'Programms vorbei in die Zone fliegen');
    });

    test('verbrauchter Einmal-Prekey', () async {
      final alice = Seite('alice');
      final bob = Seite('bob');
      await alice.start();
      await bob.start();
      await SessionBuilder.fromSignalStore(alice.store, bob.addr)
          .processPreKeyBundle(await bob.buendel(otpkId: 7));
      final erst = await sende(alice, bob, 'a1');
      await empfange(bob, alice, erst);

      // Erneut zugestellt, mit verbogenem Versionsbyte: ohne die Pruefung aus
      // LS-1 lief hier InvalidKeyIdException zusaetzlich in die Zone.
      final verbogen = erst.kopie()..bytes[0] = 0x43;
      final (gefangen, verwaist) = await wasFliegtUndVerwaist(
          () => empfange(bob, alice, verbogen));

      expect(gefangen, isNotNull);
      expect(verwaist, isEmpty);
    });

    test('die Identitaet wird erst nach erfolgreichem Aufbau gespeichert',
        () async {
      final bob = Seite('bob');
      final mallory = Seite('mallory');
      await bob.start();
      await mallory.start();

      final echt = await bob.buendel();
      final falsch = PreKeyBundle(echt.getRegistrationId(), 1, null, null, 99,
          echt.getSignedPreKey(), echt.getSignedPreKeySignature(),
          echt.getIdentityKey());
      await SessionBuilder.fromSignalStore(mallory.store, bob.addr)
          .processPreKeyBundle(falsch);
      final erst = await sende(mallory, bob, 'hallo');

      await wasFliegt(() => empfange(bob, mallory, erst));

      expect(bob.store.gespeichert, isEmpty,
          reason: 'ein Fremder darf sich mit einer kaputten Erstnachricht '
              'keinen Identitaetseintrag anlegen');
    });
  });

  group('FZ-2: kaputte Nachrichten melden InvalidMessageException', () {
    test('leere Bytes', () {
      expect(() => PreKeySignalMessage(Uint8List(0)),
          throwsA(isA<InvalidMessageException>()));
    });

    test('Erstnachricht mit kaputtem Protobuf', () {
      expect(() => PreKeySignalMessage(Uint8List.fromList([0x33, 0xff, 0xff])),
          throwsA(isA<InvalidMessageException>()));
    });

    test('Erstnachricht mit aufgeblasener Protobuf-Laenge', () {
      // Feld 1 (registrationId) als Laengenangabe 0x7f, aber nichts dahinter.
      expect(() => PreKeySignalMessage(Uint8List.fromList([0x33, 0x0a, 0x7f])),
          throwsA(isA<InvalidMessageException>()));
    });

    test('zu kurze Folgenachricht', () {
      expect(() => SignalMessage.fromSerialized(Uint8List(3)),
          throwsA(isA<InvalidMessageException>()));
    });

    test('Folgenachricht mit kaputtem Protobuf', () {
      expect(
          () => SignalMessage.fromSerialized(
              Uint8List.fromList([0x33, 0x0a, 0x7f, ...List<int>.filled(8, 0)])),
          throwsA(isA<InvalidMessageException>()));
    });
  });
}
