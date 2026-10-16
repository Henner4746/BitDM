// signal_bibliothek_test.dart — die Angriffe aus dem Audit vom 16.10.2026,
// gefahren gegen Signals offizielle libsignal.
//
// Bis 1.9.x pruefte diese Datei Korrekturen an der eigenen Kopie der
// Dart-Nachbildung (libsignal_protocol_dart 0.8.2). Seit 2.0.0 laeuft die
// offizielle Rust-Bibliothek (Paket `libsignal` 8.0.0, libsignal 0.105); die
// Kopie ist weg. Die ANGRIFFE bleiben dieselben, und sie laufen hier gegen
// die neue Bibliothek — ueber BitdmSignalStore, nicht ueber die
// In-Memory-Speicher des Pakets. Denn die Haelfte der Abwehr liegt jetzt im
// Speicher: die Liste der Last-Resort-Nutzungen (LS-1), der Verbrauch der
// Kyber-Einmalschluessel und die Nachrechnung der Adresse.
//
// GEMESSEN (16.10.2026): libsignal 0.105 schreibt in das erste Byte einer
// Erstnachricht 0x44 — oben die Nachrichtenfassung 4 (PQXDH), unten die
// aktuelle Fassung 4. Die alte Bibliothek schrieb 0x33. Der erste Test haelt
// das fest; aendert es eine kuenftige Fassung, faellt es dort auf.
//
// Wo geprueft wird, DASS etwas wirft, wird der geworfene Wert eingesammelt
// und AUSSERHALB des try geprueft — aus demselben Grund wie in
// test/store/session_exchange_test.dart: ein fail() im try-Block faengt sich
// selbst wieder ein, und der Test bliebe gerade dann gruen, wenn nichts
// geworfen wurde.
//
// Einige Tests loesen absichtlich einen Wurf in einem Speicher-Rueckruf aus.
// Die Anbindung macht daraus eine Rust-Panic; die Konsole zeigt dann
// "thread 'tokio-rt-worker' panicked". Das ist erwartet.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_errors.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

/// Eine Gegenstelle mit eigener Identitaet, eigenem BitdmSignalStore und
/// einem signierten EC-Prekey samt Last-Resort-Kyber-Schluessel — so, wie
/// jede Installation von 2.0.0 sie beim Relay anmeldet.
class Seite {
  Seite._(this.identity, this.store, this.spk, this.letzteRettung);

  final SignalIdentity identity;
  final BitdmSignalStore store;
  final SignedPreKeyRecord spk;
  final KyberPreKeyRecord letzteRettung;
  var _naechsteId = 100;

  String get name => identity.address;
  ProtocolAddress get addr => adr(name);

  static Future<Seite> neu() async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final spk = neuerSpk(id.keyPair, 1);
    await store.storeSignedPreKey(1, spk);
    final letzte = neuerKyber(id.keyPair, 1);
    await store.storeLastResortKyberPreKey(1, letzte);
    // Als waere es festgeschrieben: ab hier zeigt der Merkzettel nur, was
    // ein Test ausloest.
    store.markClean();
    return Seite._(id, store, spk, letzte);
  }

  /// Was ein Relay als Buendel ausliefern wuerde.
  ///
  /// [ec]: mit EC-Einmalschluessel. [kyberEinmal]: mit Kyber-Einmalschluessel
  /// statt des Last-Resort-Schluessels. Ob einer dabei ist, bestimmt der
  /// Relay — die Abwehr darf sich nicht darauf verlassen.
  Future<PreKeyBundle> buendel({bool ec = false, bool kyberEinmal = false}) async {
    PreKeyRecord? otk;
    if (ec) {
      otk = neuerPreKey(_naechsteId++);
      await store.storePreKey(otk.id(), otk);
    }
    var kyber = letzteRettung;
    if (kyberEinmal) {
      kyber = neuerKyber(identity.keyPair, _naechsteId++);
      await store.storeKyberPreKey(kyber.id(), kyber);
    }
    return buendelAus(otk: otk, kyber: kyber);
  }

  /// Ein Buendel aus Einzelteilen — fuer die Faelschungen.
  PreKeyBundle buendelAus({
    PreKeyRecord? otk,
    required KyberPreKeyRecord kyber,
    List<int>? kyberOeffentlich,
    List<int>? kyberSignatur,
  }) =>
      PreKeyBundle(
        registrationId: identity.registrationId,
        deviceId: 1,
        preKeyId: otk?.id(),
        preKeyPublic: otk?.publicKey(),
        signedPreKeyId: spk.id(),
        signedPreKeyPublic: spk.publicKey(),
        signedPreKeySignature: spk.signature(),
        identityKey: identity.keyPair.publicKey,
        kyberPreKeyId: kyber.id(),
        kyberPreKeyPublic: kyberOeffentlich ?? kyber.getPublicKey().serialize(),
        kyberPreKeySignature: kyberSignatur ?? kyber.signature(),
      );
}

/// Eine Nachricht auf dem Draht: Art und Bytes, wie der Relay sie sieht.
class Draht {
  Draht(this.art, this.bytes);

  final CiphertextMessageType art;
  final Uint8List bytes;

  Draht kopie() => Draht(art, Uint8List.fromList(bytes));

  /// Eine Kopie mit [wert] an Stelle [i].
  Draht mit(int i, int wert) => kopie()..bytes[i] = wert;

  CiphertextMessage nachricht() =>
      CiphertextMessage(type: art, ciphertext: Uint8List.fromList(bytes));
}

Future<void> baue(Seite von, Seite an, PreKeyBundle b) =>
    bauerVon(von.store).processPreKeyBundle(an.addr, b);

Future<Draht> sende(Seite von, Seite an, String t) async {
  final ct = await chiffreVon(von.store).encrypt(an.addr, text(t));
  return Draht(ct.type, Uint8List.fromList(ct.ciphertext));
}

/// Nur libsignal, ohne die Pruefung des Kerns.
Future<String> empfange(Seite bei, Seite von, Draht d, {int geraet = 1}) async =>
    utf8.decode(await chiffreVon(bei.store)
        .decrypt(adr(von.name, geraet), d.nachricht()));

/// DER WEG DES KERNS (real_messenger_core `_nimmUmschlagJetzt`), auf das
/// Wesentliche gekuerzt: vor einer Erstnachricht den Stand festhalten,
/// entschluesseln, den Zaehler der Last-Resort-Nutzungen vergleichen, bei
/// einer Wiederholung den Stand zurueckspielen und verwerfen.
Future<String> kernEmpfang(Seite bei, Seite von, Draht d,
    {int geraet = 1}) async {
  final store = bei.store;
  final wiederholungenVorher = store.kyberWiederholungen;
  final vorher =
      d.art == CiphertextMessageType.preKey ? store.schnappschuss() : null;
  final klar = await chiffreVon(store)
      .decrypt(adr(von.name, geraet), d.nachricht());
  if (store.kyberWiederholungen != wiederholungenVorher) {
    if (vorher != null) store.stelleWiederHer(vorher);
    throw const ErneutEingespielt();
  }
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

/// Der ganze Zustand eines Speichers als einfache Werte.
Map<String, Object> abbild(BitdmSignalStore s) {
  final z = s.state;
  return {
    'sessions': {for (final e in z.sessions.entries) e.key: e.value.toList()},
    'identities': {
      for (final e in z.identities.entries) e.key: e.value.toList()
    },
    'preKeys': {for (final e in z.preKeys.entries) e.key: e.value.toList()},
    'signedPreKeys': {
      for (final e in z.signedPreKeys.entries) e.key: e.value.toList()
    },
    'kyberPreKeys': {
      for (final e in z.kyberPreKeys.entries)
        e.key: [if (e.value.letzteRettung) 1 else 0, ...e.value.record]
    },
    'kyberBenutzt': {...z.kyberBenutzt},
  };
}

/// Nur die Sitzungen — das, wonach LS-2 fragt.
Map<String, List<int>> sitzungen(BitdmSignalStore s) =>
    {for (final e in s.state.sessions.entries) e.key: e.value.toList()};

Map<String, Object> merkzettel(StoreDelta d) => {
      'identities': {...d.identities},
      'preKeys': {...d.preKeys},
      'signedPreKeys': {...d.signedPreKeys},
      'kyberPreKeys': {...d.kyberPreKeys},
      'kyberBenutzt': {...d.kyberBenutzt},
      'sessions': {...d.sessions},
    };

/// Wo [teil] in [ganz] beginnt.
int finde(List<int> ganz, List<int> teil) {
  for (var i = 0; i + teil.length <= ganz.length; i++) {
    var gleich = true;
    for (var j = 0; j < teil.length && gleich; j++) {
      gleich = ganz[i + j] == teil[j];
    }
    if (gleich) return i;
  }
  throw StateError('Teil nicht gefunden');
}

/// Alice baut ueber ein Buendel OHNE Einmalschluessel eine Sitzung zu Bob,
/// Bob empfaengt die Erstnachricht. Mit [antwort] schreibt Bob zurueck und
/// Alice empfaengt — dann laeuft die Sitzung in beide Richtungen.
///
/// Ohne Einmalschluessel ist der haerteste Fall: Gegen eine Wiederholung
/// schuetzt dann nichts, was verbraucht wird, sondern nur, was gemerkt wird.
Future<(Seite, Seite, Draht)> laufendeSitzung({bool antwort = true}) async {
  final alice = await Seite.neu();
  final bob = await Seite.neu();
  await baue(alice, bob, await bob.buendel());
  final erst = await sende(alice, bob, 'a1: Hallo Bob');
  expect(await empfange(bob, alice, erst), 'a1: Hallo Bob');
  if (antwort) {
    expect(await empfange(alice, bob, await sende(bob, alice, 'b1')), 'b1');
  }
  return (alice, bob, erst);
}

void main() {
  setUpAll(signalBereit);

  group('Die Fassung auf dem Draht', () {
    test('libsignal 0.105 schreibt 0x44 in die Erstnachricht', () async {
      // Nachrichtenfassung 4 (PQXDH) im oberen Halbbyte, aktuelle Fassung 4
      // im unteren. Die Tests zu LS-1 unten bauen auf diesem Wert auf.
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      await baue(alice, bob, await bob.buendel());
      final erst = await sende(alice, bob, 'x');

      expect(erst.art, CiphertextMessageType.preKey);
      expect(erst.bytes[0], 0x44);
      final m = PreKeySignalMessage.deserialize(data: erst.bytes);
      expect(m.messageVersion(), 4);
      expect(m.kyberPreKeyId(), bob.letzteRettung.id(),
          reason: 'ohne Kyber gaebe es keine Fassung 4');
      expect(m.message().serialize()[0], 0x44,
          reason: 'die eingebettete Folgenachricht traegt dasselbe Byte');

      await empfange(bob, alice, erst);
      final folge = await sende(bob, alice, 'y');
      expect(folge.art, CiphertextMessageType.signal);
      expect(folge.bytes[0], 0x44);
    });
  });

  group('LS-1: Versionsbyte der Erstnachricht', () {
    // Das erste Byte deckt kein MAC. In der Dart-Nachbildung fand die
    // Duplikaterkennung mit verbogenem Byte die laufende Sitzung nicht mehr
    // und baute sie aus der alten Erstnachricht neu auf — die echte wurde
    // archiviert, und Bobs Antworten konnte Alice nicht mehr lesen.
    //
    // Die offizielle Bibliothek liest nur das obere Halbbyte: 3 heisst
    // "X3DH, nicht mehr unterstuetzt", ab 5 "unbekannte Fassung", das untere
    // Halbbyte wird nicht ausgewertet. Mit oberem Halbbyte 4 findet sie die
    // laufende Sitzung also weiter und meldet ein Duplikat.
    const varianten = [
      0x43, 0x45, 0x40, 0x4f, // unteres Halbbyte
      0x34, 0x33, 0x24, 0x14, 0x04, // aelter
      0x54, 0x64, 0xf4, 0xff, // neuer
    ];

    Future<void> pruefe(Seite alice, Seite bob, Draht erst) async {
      final vorher = abbild(bob.store);
      final merkVorher = merkzettel(bob.store.delta);
      final zaehlerVorher = bob.store.kyberWiederholungen;

      for (final v in varianten) {
        final fehler =
            await wasFliegt(() => kernEmpfang(bob, alice, erst.mit(0, v)));

        final hex = '0x${v.toRadixString(16)}';
        expect(fehler, isNotNull,
            reason: '$hex: die Erstnachricht darf nicht noch einmal '
                'angenommen werden');
        expect(classify(fehler!).shouldRebuildSession, isFalse,
            reason: '$hex: ein verbogenes Byte darf keinen Neuaufbau ausloesen');
        expect(abbild(bob.store), vorher,
            reason: '$hex: die laufende Sitzung muss unangetastet bleiben');
        expect(merkzettel(bob.store.delta), merkVorher,
            reason: '$hex: und nichts davon darf zum Festschreiben anstehen');
      }
      expect(bob.store.kyberWiederholungen, zaehlerVorher,
          reason: 'libsignal hat keine der Varianten als neue Sitzung '
              'aufgebaut — die Abwehr liegt schon in der Bibliothek');
    }

    test('verbogenes Versionsbyte bei laufender Sitzung: abgelehnt, Sitzung '
        'unveraendert', () async {
      final (alice, bob, erst) = await laufendeSitzung();
      bob.store.markClean();

      await pruefe(alice, bob, erst);

      // Und die Unterhaltung laeuft in beide Richtungen weiter.
      expect(await empfange(alice, bob, await sende(bob, alice, 'b2')), 'b2');
      expect(await empfange(bob, alice, await sende(alice, bob, 'a2')), 'a2');
    });

    test('dasselbe, bevor Bob geantwortet hat', () async {
      // Alice schickt dann weiter Erstnachrichten; Bobs Sitzung steht nur
      // aus der einen.
      final (alice, bob, erst) = await laufendeSitzung(antwort: false);
      bob.store.markClean();
      await pruefe(alice, bob, erst);
      expect(await empfange(bob, alice, await sende(alice, bob, 'a2')), 'a2');
    });

    test('dasselbe mit Einmalschluesseln im Buendel', () async {
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      await baue(alice, bob, await bob.buendel(ec: true, kyberEinmal: true));
      final erst = await sende(alice, bob, 'a1');
      await empfange(bob, alice, erst);
      bob.store.markClean();
      await pruefe(alice, bob, erst);
    });

    test('was die Bibliothek je Halbbyte meldet', () async {
      // Festgehalten, damit ein Fassungswechsel, der das aendert, auffaellt.
      final (alice, bob, erst) = await laufendeSitzung();
      Future<LibSignalErrorCode?> code(int v) async {
        final f = await wasFliegt(() => empfange(bob, alice, erst.mit(0, v)));
        return f is LibSignalException ? f.code : null;
      }

      expect(await code(0x43), LibSignalErrorCode.duplicatedMessage);
      expect(await code(0x4f), LibSignalErrorCode.duplicatedMessage);
      expect(await code(0x34), LibSignalErrorCode.invalidMessage);
      expect(await code(0x54), LibSignalErrorCode.unknownCiphertextVersion);
    });

    test('eine Erstnachricht der Fassung 3 (X3DH ohne Kyber) wird auch ohne '
        'laufende Sitzung abgelehnt — kein Zurueckstufen', () async {
      // Ein Relay, der das Byte auf 0x33 setzt, darf Bob nicht in eine
      // Sitzung ohne Post-Quanten-Teil zwingen.
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      await baue(alice, bob, await bob.buendel());
      final erst = await sende(alice, bob, 'a1');
      final vorher = abbild(bob.store);

      final fehler =
          await wasFliegt(() => kernEmpfang(bob, alice, erst.mit(0, 0x33)));

      expect(fehler, isA<LibSignalException>());
      expect(abbild(bob.store), vorher);
      // Gegenprobe: die unveraenderte Erstnachricht laeuft durch.
      expect(await kernEmpfang(bob, alice, erst), 'a1');
    });
  });

  group('LS-2: Fehlversuche duerfen den Sitzungszustand nicht veraendern', () {
    // In der Dart-Nachbildung verbog ein gescheiterter Versuch den echten
    // Zustand, weil die Arbeitskopie am Original hing. Die offizielle
    // Bibliothek rechnet auf einer Kopie und gibt ueber storeSession nur den
    // ERFOLGREICHEN Stand zurueck. Hier wird das am Speicher nachgemessen.

    test('ein verfaelschter MAC aendert die gespeicherte Sitzung nicht',
        () async {
      final (alice, bob, _) = await laufendeSitzung();
      final echt = await sende(alice, bob, 'a2');
      expect(echt.art, CiphertextMessageType.signal,
          reason: 'sonst traefe das Bitkippen den Aufbau, nicht die Folge');
      final kaputt = echt.mit(echt.bytes.length - 1, echt.bytes.last ^ 0x01);
      final vorher = sitzungen(bob.store);
      bob.store.markClean();

      final fehler = await wasFliegt(() => empfange(bob, alice, kaputt));

      expect(fehler, isA<LibSignalException>());
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.invalidMessage);
      expect(sitzungen(bob.store), vorher,
          reason: 'store.state.sessions muss byte-gleich bleiben');
      expect(bob.store.isDirty, isFalse,
          reason: 'libsignal darf nach einem Fehlschlag nichts schreiben');

      // Und die echte Nachricht kommt danach weiter an.
      expect(await empfange(bob, alice, echt), 'a2');
    });

    test('eine Folgenachricht mit fremdem Ratchet-Schluessel aendert nichts',
        () async {
      // Der teure Fall: libsignal leitet vor der MAC-Pruefung aus dem fremden
      // Schluessel eine neue Wurzel und Empfangskette ab. Genau diese
      // Vorarbeit verbog in 0.8.2 den echten Zustand.
      final (alice, bob, _) = await laufendeSitzung();
      final echt = await sende(alice, bob, 'a2');
      final ratchet =
          SignalMessage.deserialize(data: echt.bytes).senderRatchetKey();
      final stelle = finde(echt.bytes, ratchet);
      final fremd = PrivateKey.generate().getPublicKey().serialize();
      final gefaelscht = echt.kopie();
      gefaelscht.bytes.setRange(stelle, stelle + fremd.length, fremd);
      final vorher = sitzungen(bob.store);
      bob.store.markClean();

      final fehler = await wasFliegt(() => empfange(bob, alice, gefaelscht));

      expect(fehler, isA<LibSignalException>());
      expect(sitzungen(bob.store), vorher);
      expect(bob.store.isDirty, isFalse);
      expect(await empfange(bob, alice, echt), 'a2');
    });

    test('eine Erstnachricht mit verfaelschtem MAC legt keine Sitzung an und '
        'verbraucht keinen Einmalschluessel', () async {
      // Bob kennt Alice noch nicht. libsignal baut die neue Sitzung im
      // Arbeitsspeicher auf, scheitert dann am MAC der eingebetteten
      // Nachricht — und darf dabei weder die Sitzung ablegen noch einen
      // Einmalschluessel verbrauchen. Sonst koennte jeder mit kaputten
      // Erstnachrichten Bobs Vorrat leerraeumen.
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      await baue(alice, bob, await bob.buendel(ec: true, kyberEinmal: true));
      final erst = await sende(alice, bob, 'a1');
      final innen =
          PreKeySignalMessage.deserialize(data: erst.bytes).message().serialize();
      final macEnde = finde(erst.bytes, innen) + innen.length - 1;
      final kaputt = erst.mit(macEnde, erst.bytes[macEnde] ^ 0x01);
      final vorher = abbild(bob.store);
      bob.store.markClean();

      final fehler = await wasFliegt(() => kernEmpfang(bob, alice, kaputt));

      expect(fehler, isA<LibSignalException>());
      expect(abbild(bob.store), vorher);
      expect(bob.store.isDirty, isFalse);
      expect(await kernEmpfang(bob, alice, erst), 'a1',
          reason: 'die echte Erstnachricht muss danach weiter durchgehen');
    });

    test('eine liegengebliebene Nachricht aus der alten Sitzung kommt an, '
        'ihre Wiederholung danach nicht mehr', () async {
      // Der Rueckfall aufs Archiv: Alice baut eine zweite Sitzung auf (bei
      // BitDM nach einer Wiederherstellung oder wenn beide gleichzeitig
      // eroeffnen), eine Nachricht aus der ersten kommt erst danach an.
      final (alice, bob, _) = await laufendeSitzung();
      final liegt = await sende(alice, bob, 'a2: kommt spaeter an');
      await baue(alice, bob, await bob.buendel());
      expect(await empfange(bob, alice, await sende(alice, bob, 'a3')), 'a3');

      expect(await empfange(bob, alice, liegt), 'a2: kommt spaeter an',
          reason: 'der Rueckfall aufs Archiv muss funktionieren');

      final vorher = sitzungen(bob.store);
      final fehler = await wasFliegt(() => empfange(bob, alice, liegt));
      expect(fehler, isNotNull);
      expect(classify(fehler!), SignalFailure.duplicate);
      expect(sitzungen(bob.store), vorher);
    });

    test('ein wiederholter alter Umschlag laesst die Sitzung nicht '
        'zurueckspringen und keinen Schluessel doppelt benutzen', () async {
      final (alice, bob, _) = await laufendeSitzung();
      final alt = await sende(alice, bob, 'a2');
      await empfange(bob, alice, alt);

      // Jede Nachricht, die Bob sendet, wird mitgeschrieben: gleicher
      // Ratchet-Schluessel und gleicher Zaehler bedeuten gleicher
      // Nachrichtenschluessel und gleiches IV.
      final gesehen = <String>{};
      Future<void> bobSendet(String t) async {
        final d = await sende(bob, alice, t);
        final m = SignalMessage.deserialize(data: d.bytes);
        expect(gesehen.add('${base64.encode(m.senderRatchetKey())}@${m.counter()}'),
            isTrue,
            reason: 'Schluessel und IV duerfen sich nicht wiederholen');
        await empfange(alice, bob, d);
      }

      // Sechs Runden: mehr, als libsignal Empfangsketten haelt (fuenf).
      for (var i = 1; i <= 6; i++) {
        await empfange(bob, alice, await sende(alice, bob, 'd$i'));
        await bobSendet('e$i');
      }

      final vorher = sitzungen(bob.store);
      final fehler = await wasFliegt(() => empfange(bob, alice, alt.kopie()));
      expect(fehler, isNotNull,
          reason: 'die Double-Ratchet-Schicht muss Wiederholungen abweisen; '
              'BitDM verlaesst sich darauf bei Steuernachrichten');
      expect(sitzungen(bob.store), vorher,
          reason: 'ein wiederholter alter Umschlag darf die Sitzung nicht '
              'auf einen alten Stand befoerdern');
      await bobSendet('f1');
    });
  });

  group('Wiederholung gegen den Last-Resort-Kyber-Schluessel', () {
    // Ohne Einmalschluessel ist eine Erstnachricht nur ueber das Tripel
    // (kyberId, spkId, Basisschluessel) als Wiederholung erkennbar. Die
    // Anbindung meldet es erst NACH dem Entschluesseln (markKyberPreKeyUsed
    // darf nicht werfen); BitDM zaehlt in kyberWiederholungen, und der Kern
    // verwirft (kernEmpfang oben).

    test('direkt danach: libsignal erkennt das Duplikat selbst', () async {
      final (alice, bob, erst) = await laufendeSitzung(antwort: false);
      final vorher = abbild(bob.store);

      final fehler = await wasFliegt(() => kernEmpfang(bob, alice, erst));

      expect(fehler, isA<LibSignalException>());
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.duplicatedMessage);
      expect(classify(fehler).isSilent, isTrue);
      expect(bob.store.kyberWiederholungen, 0);
      expect(abbild(bob.store), vorher);
    });

    test('nachdem die Sitzung weitergelaufen ist: Duplikat oder Zaehler — '
        'in jedem Fall verworfen, Zustand wie vorher', () async {
      final (alice, bob, erst) = await laufendeSitzung();
      for (var i = 0; i < 3; i++) {
        await empfange(bob, alice, await sende(alice, bob, 'x$i'));
        await empfange(alice, bob, await sende(bob, alice, 'y$i'));
      }
      final vorher = abbild(bob.store);
      final merkVorher = merkzettel(bob.store.delta);
      final zaehler = bob.store.kyberWiederholungen;

      final fehler = await wasFliegt(() => kernEmpfang(bob, alice, erst));

      expect(fehler, isNotNull);
      final libsignalSahEs = fehler is LibSignalException &&
          fehler.code == LibSignalErrorCode.duplicatedMessage;
      final speicherSahEs = bob.store.kyberWiederholungen > zaehler;
      expect(libsignalSahEs || speicherSahEs, isTrue,
          reason: 'erwartet: duplicatedMessage oder ein Anstieg von '
              'kyberWiederholungen, war: $fehler');
      expect(classify(fehler!), SignalFailure.duplicate);
      expect(abbild(bob.store), vorher);
      expect(merkzettel(bob.store.delta), merkVorher);
      expect(await empfange(alice, bob, await sende(bob, alice, 'y9')), 'y9');
    });

    test('einem anderen Geraet zugeschrieben baut libsignal NEU auf — erst '
        'der Speicher bemerkt es', () async {
      // Der Relay bestimmt, von welchem Geraet eine Nachricht kommt. Fuer
      // "Alice, Geraet 2" hat Bob keine Sitzung, also findet libsignal kein
      // Duplikat und entschluesselt. Das zeigt, warum der Kern den Zaehler
      // pruefen MUSS: ohne ihn ginge die Wiederholung hier durch.
      final (alice, bob, erst) = await laufendeSitzung(antwort: false);

      final klar = await empfange(bob, alice, erst, geraet: 2);

      expect(klar, 'a1: Hallo Bob', reason: 'libsignal allein nimmt sie an');
      expect(bob.store.kyberWiederholungen, 1,
          reason: 'aber das Tripel ist bekannt');
      expect(await bob.store.containsSession(adr(alice.name, 2)), isTrue,
          reason: 'und eine eingeschleuste Sitzung steht schon im Speicher');
    });

    test('der Weg des Kerns verwirft sie und stellt den Stand exakt her',
        () async {
      final (alice, bob, erst) = await laufendeSitzung();
      await bob.store.storePreKey(9, neuerPreKey(9)); // offen, nicht fest
      final vorher = abbild(bob.store);
      final merkVorher = merkzettel(bob.store.delta);

      final fehler =
          await wasFliegt(() => kernEmpfang(bob, alice, erst, geraet: 2));

      expect(fehler, isA<ErneutEingespielt>());
      expect(classify(fehler!), SignalFailure.duplicate);
      expect(bob.store.kyberWiederholungen, 1);
      expect(abbild(bob.store), vorher,
          reason: 'keine Sitzung fuer Geraet 2, nichts verbraucht');
      expect(merkzettel(bob.store.delta), merkVorher,
          reason: 'der Fehlerpfad schreibt den Merkzettel fest — darauf darf '
              'die eingeschleuste Sitzung nicht stehen');
      expect(await bob.store.containsSession(adr(alice.name, 2)), isFalse);
      expect(await empfange(alice, bob, await sende(bob, alice, 'b2')), 'b2');
    });

    test('nach Verlust der Sitzung: ebenso verworfen', () async {
      // Etwa nach Schema 15 oder wenn Bob die Sitzung geloescht hat. Dann
      // gibt es nichts, woran libsignal ein Duplikat erkennen koennte.
      final (alice, bob, erst) = await laufendeSitzung();
      await bob.store.deleteSession(alice.addr);
      final vorher = abbild(bob.store);

      final fehler = await wasFliegt(() => kernEmpfang(bob, alice, erst));

      expect(fehler, isA<ErneutEingespielt>());
      expect(abbild(bob.store), vorher);
    });

    test('Gegenprobe: der Weg des Kerns laesst die echte Erstnachricht durch',
        () async {
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      await baue(alice, bob, await bob.buendel());
      final erst = await sende(alice, bob, 'echt');

      expect(await kernEmpfang(bob, alice, erst), 'echt');
      expect(bob.store.kyberWiederholungen, 0);
      expect(bob.store.state.kyberBenutzt, hasLength(1));
      expect(await bob.store.containsSession(alice.addr), isTrue);
    });
  });

  group('Kyber-Einmalschluessel lassen sich nur einmal verwenden', () {
    test('dieselbe Erstnachricht unter anderem Geraet: Schluessel fehlt',
        () async {
      // Anders als beim Last-Resort-Schluessel ist hier nichts zu zaehlen:
      // der Schluessel ist weg, libsignal kann gar nicht erst rechnen.
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      await baue(alice, bob, await bob.buendel(kyberEinmal: true));
      final erst = await sende(alice, bob, 'a1');
      await empfange(bob, alice, erst);
      expect(bob.store.kyberEinmalCount, 0);
      final vorher = abbild(bob.store);

      final fehler =
          await wasFliegt(() => kernEmpfang(bob, alice, erst, geraet: 2));

      expect(fehler, isA<LibSignalException>());
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.invalidKeyIdentifier);
      expect(classify(fehler), SignalFailure.missingKey);
      expect(abbild(bob.store), vorher);
    });

    test('ein zweiter Absender mit demselben Einmalschluessel scheitert',
        () async {
      // Ein Relay, der denselben Kyber-Einmalschluessel zweimal ausgibt —
      // aus Versehen oder mit Absicht. Die zweite Sitzung darf nicht
      // entstehen, sonst teilten sich zwei Sitzungen ein Kyber-Geheimnis.
      final alice = await Seite.neu();
      final carol = await Seite.neu();
      final bob = await Seite.neu();
      final b = await bob.buendel(kyberEinmal: true);
      await baue(alice, bob, b);
      await baue(carol, bob, b);

      expect(await empfange(bob, alice, await sende(alice, bob, 'a')), 'a');
      final vorher = abbild(bob.store);
      final fehler = await wasFliegt(
          () async => empfange(bob, carol, await sende(carol, bob, 'c')));

      expect(fehler, isA<LibSignalException>());
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.invalidKeyIdentifier);
      expect(abbild(bob.store), vorher);
    });
  });

  group('Ein Buendel mit falscher Kyber-Signatur wird abgelehnt', () {
    // Die Kyber-Signatur ist das, was ein Relay daran hindert, einen eigenen
    // Kyber-Schluessel unterzuschieben und damit den Post-Quanten-Teil
    // auszuhebeln.

    Future<void> pruefe(Seite alice, Seite bob, PreKeyBundle Function() b) async {
      final fehler = await wasFliegt(() => baue(alice, bob, b()));
      expect(fehler, isA<LibSignalException>());
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.invalidSignature);
      expect(alice.store.state.sessions, isEmpty);
      expect(alice.store.state.identities, isEmpty);
      expect(alice.store.isDirty, isFalse);
    }

    test('ein gekipptes Bit in der Signatur', () async {
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      final sig = Uint8List.fromList(bob.letzteRettung.signature());
      sig[10] ^= 0x01;
      await pruefe(alice, bob,
          () => bob.buendelAus(kyber: bob.letzteRettung, kyberSignatur: sig));
    });

    test('ein fremder Kyber-Schluessel unter der echten Signatur', () async {
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      final fremd = KyberKeyPair.generate().getPublicKey().serialize();
      await pruefe(
          alice,
          bob,
          () => bob.buendelAus(
              kyber: bob.letzteRettung, kyberOeffentlich: fremd));
    });

    test('ein Kyber-Schluessel, signiert von einer anderen Identitaet',
        () async {
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      final mallory = await Seite.neu();
      final unterschoben = neuerKyber(mallory.identity.keyPair, 1);
      await pruefe(alice, bob, () => bob.buendelAus(kyber: unterschoben));
    });
  });

  group('BEFUND 16.10.2026: eine fremde Identitaet im Buendel', () {
    // DER BEFUND: Die Anbindung ruft isTrustedIdentity NIE auf, und beim
    // Sitzungsaufbau ruft sie storeSession VOR saveIdentity
    // (rust/src/api/session_builder.rs). Solange BitDMs Speicher fuer eine
    // unbekannte Adresse `getIdentity == null` lieferte, wirkte die
    // Nachrechnung der Adresse nur ueber einen Wurf in saveIdentity — zu spaet:
    // die Sitzung mit Mallorys Schluesseln stand schon im Speicher, und
    // Mallory las mit (so am 16.10.2026 gemessen).
    //
    // DIE BEHEBUNG IM SPEICHER: getIdentity liefert IMMER den Schluessel der
    // Adresse. libsignal prueft dann selbst gegen ihn und lehnt einen fremden
    // mit `untrustedIdentity` ab, BEVOR eine Sitzung entsteht. Davor stehen im
    // Kern zusaetzlich die Riegel (FremdeIdentitaet) und der Schnappschuss —
    // am echten Kern belegt in test/net/fremde_identitaet_test.dart.

    test('processPreKeyBundle lehnt Mallorys Buendel unter Doras Adresse ab — '
        'ohne Sitzung, ohne Panic', () async {
      final alice = await Seite.neu();
      final dora = await Seite.neu();
      final mallory = await Seite.neu();
      // Der Relay liefert Mallorys Buendel als das von Dora aus.
      final gefaelscht = await mallory.buendel();

      final fehler = await wasFliegt(() => baue(alice, dora, gefaelscht));

      expect(fehler, isA<LibSignalException>(),
          reason: 'libsignal selbst lehnt ab, sauber und ohne Panic im '
              'Rust-Faden');
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.untrustedIdentity);
      expect(await alice.store.containsSession(dora.addr), isFalse,
          reason: 'DER BEFUND KEHRT ZURUECK: eine Sitzung mit Mallorys '
              'Schluesseln steht unter Doras Adresse im Speicher');
      expect(alice.store.delta.sessions, isEmpty);
      expect(alice.store.state.identities[dora.name], isNull,
          reason: 'Mallorys Schluessel wurde unter Doras Adresse abgelegt');
    });

    test('Gegenmittel: die Adresse VOR dem Aufbau nachrechnen', () async {
      final dora = await Seite.neu();
      final mallory = await Seite.neu();
      final gefaelscht = await mallory.buendel();
      final echt = await dora.buendel();

      String adresseVon(PreKeyBundle b) => SignalIdentityBridge.addressOf(
          PublicKey.deserialize(bytes: b.identityKey()));

      expect(adresseVon(gefaelscht), isNot(dora.name));
      expect(adresseVon(echt), dora.name);
    });

    test('Gegenmittel: Schnappschuss vor dem Aufbau, bei jedem Fehler '
        'zurueck', () async {
      final alice = await Seite.neu();
      final dora = await Seite.neu();
      final mallory = await Seite.neu();
      final gefaelscht = await mallory.buendel();
      final vorher = abbild(alice.store);
      final s = alice.store.schnappschuss();

      final fehler = await wasFliegt(() => baue(alice, dora, gefaelscht));
      if (fehler != null) alice.store.stelleWiederHer(s);

      expect(fehler, isNotNull);
      expect(abbild(alice.store), vorher);
      expect(alice.store.isDirty, isFalse);
    });

    test('beim Empfang bleibt nichts zurueck', () async {
      // Auf Bibliotheksebene meldet libsignal `untrustedIdentity` (der
      // Speicher liefert Alices Schluessel aus ihrer Adresse, die Nachricht
      // traegt Mallorys). Im Kern kommt es gar nicht so weit: die Vorpruefung
      // in `_nimmUmschlagJetzt` wirft vorher FremdeIdentitaet, und die gilt als
      // unlesbar — damit der Relay keine Kontaktanfragen erzeugen kann
      // (test/net/fremde_identitaet_test.dart).
      final alice = await Seite.neu();
      final bob = await Seite.neu();
      final mallory = await Seite.neu();
      await baue(mallory, bob, await bob.buendel(ec: true, kyberEinmal: true));
      final alsAlice = await sende(mallory, bob, 'ich bin Alice');
      final vorher = abbild(bob.store);

      final fehler = await wasFliegt(() => kernEmpfang(bob, alice, alsAlice));

      expect(fehler, isNotNull);
      expect(classify(fehler!), SignalFailure.untrusted);
      expect(abbild(bob.store), vorher);
    });
  });

  group('FZ-2: kaputte Bytes werfen LibSignalException, nie einen Absturz', () {
    test('Bekannte Formen von Muell', () async {
      final (alice, bob, _) = await laufendeSitzung();
      final vorher = abbild(bob.store);
      final muell = <List<int>>[
        [], // leer
        [0x44], // nur das Versionsbyte
        [0x44, 0xff, 0xff], // kaputtes Protobuf
        [0x44, 0x0a, 0x7f], // Laengenangabe 0x7f, nichts dahinter
        [0x33, 0x0a, 0x7f], // alte Fassung, ebenso kaputt
        [0x44, ...List<int>.filled(8, 0)], // nur ein "MAC"
        List<int>.filled(40, 0x41),
        List<int>.filled(4000, 0xff),
      ];
      for (final roh in muell) {
        for (final art in [
          CiphertextMessageType.preKey,
          CiphertextMessageType.signal,
        ]) {
          final fehler = await wasFliegt(() =>
              kernEmpfang(bob, alice, Draht(art, Uint8List.fromList(roh))));
          final was = '$art, ${roh.length} Byte';
          expect(fehler, isA<LibSignalException>(), reason: was);
          expect(classify(fehler!), SignalFailure.unreadable, reason: was);
        }
      }
      expect(abbild(bob.store), vorher);
    });

    test('Zufallsbytes', () async {
      final (alice, bob, _) = await laufendeSitzung();
      final vorher = abbild(bob.store);
      final zufall = Random(20261016); // fest, damit ein Fund nachstellbar ist
      for (var i = 0; i < 200; i++) {
        final roh = Uint8List.fromList(List<int>.generate(
            zufall.nextInt(300), (_) => zufall.nextInt(256)));
        final art = i.isEven
            ? CiphertextMessageType.preKey
            : CiphertextMessageType.signal;
        final fehler =
            await wasFliegt(() => kernEmpfang(bob, alice, Draht(art, roh)));
        expect(fehler, isA<LibSignalException>(), reason: 'Lauf $i');
        expect(classify(fehler!).shouldRebuildSession, isFalse,
            reason: 'Lauf $i');
      }
      expect(abbild(bob.store), vorher);
    });

    test('jedes siebte Byte einer Erstnachricht gekippt', () async {
      // Echte Struktur, ein Fehler an einer Stelle: das trifft der Reihe
      // nach Versionsbyte, Prekey-Nummern, Basisschluessel, Identitaet,
      // eingebettete Nachricht und Kyber-Chiffretext.
      final (alice, bob, erst) = await laufendeSitzung();
      final vorher = abbild(bob.store);
      for (var i = 0; i < erst.bytes.length; i += 7) {
        final fehler = await wasFliegt(
            () => kernEmpfang(bob, alice, erst.mit(i, erst.bytes[i] ^ 0x01)));
        expect(fehler, isNotNull, reason: 'Stelle $i ging durch');
        expect(fehler, anyOf(isA<LibSignalException>(), isA<ErneutEingespielt>()),
            reason: 'Stelle $i');
        expect(classify(fehler!).shouldRebuildSession, isFalse,
            reason: 'Stelle $i');
      }
      expect(abbild(bob.store), vorher);
      expect(bob.store.kyberWiederholungen, 0);
    });

    test('ein gekipptes Bit in der Identitaet meldet untrustedIdentity — vor '
        'jeder Authentisierung', () async {
      // Festgehalten, weil es fuer den Empfangspfad zaehlt: die Identitaet
      // einer Erstnachricht wird mit der gespeicherten verglichen, BEVOR
      // irgendetwas daran geprueft ist. `untrusted` kann also jeder erzeugen,
      // der Bytes auf dem Weg veraendert — es beweist keinen
      // Schluesselwechsel (siehe LibSignalErrorCode.untrustedIdentity).
      final (alice, bob, erst) = await laufendeSitzung();
      final identitaet =
          PreKeySignalMessage.deserialize(data: erst.bytes).identityKey();
      final letztes = finde(erst.bytes, identitaet) + identitaet.length - 1;
      final vorher = abbild(bob.store);

      final fehler = await wasFliegt(() =>
          kernEmpfang(bob, alice, erst.mit(letztes, erst.bytes[letztes] ^ 1)));

      expect(fehler, isA<LibSignalException>());
      expect((fehler! as LibSignalException).code,
          LibSignalErrorCode.untrustedIdentity);
      expect(abbild(bob.store), vorher);
    });
  });
}
