// protokoll_befunde_test.dart — die Protokollbefunde vom 25.09.2026, am
// echten Kern gemessen.
//
// Jeder Fall hier braucht einen Umschlag, den eine GEGENSTELLE so geschickt
// hat: eine Nutzlast, die nicht so aussieht, wie sie soll; eine Kennung, die
// schon mir gehoert; eine Wiederholung; einen Gruppenstand in der falschen
// Reihenfolge. Deshalb hat jeder Absender hier einen eigenen libsignal-
// Speicher und verschluesselt echt — nachgebaut ist nur der Transport
// (RelayAttrappe), damit sich jeder Umschlag gezielt einwerfen laesst.
//
// Die Befundnummern (H4, L1, ...) stehen am jeweiligen Fall.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../support/relay_attrappe.dart';

/// Die Attrappe, die ausserdem mitschreibt, was bestaetigt wurde.
class ZaehlRelay extends RelayAttrappe {
  ZaehlRelay(super.identity, super.lage);
  final bestaetigt = <int>[];
  @override
  void bestaetigeEmpfang(int q) => bestaetigt.add(q);
}

/// Eine Gegenstelle mit eigenem libsignal-Speicher.
class Absender {
  Absender._(this.store, this._spk, this._otk);

  final BitdmSignalStore store;
  final SignedPreKeyRecord _spk;
  final PreKeyRecord _otk;

  String get adresse => store.identity.address;

  static Future<Absender> neu() async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final spk = generateSignedPreKey(id.keyPair, 1);
    await store.storeSignedPreKey(spk.id, spk);
    final otk = generatePreKeys(500, 1).first;
    await store.storePreKey(otk.id, otk);
    return Absender._(store, spk, otk);
  }

  /// Wie der Relay das Buendel dieser Gegenstelle ausliefert.
  Map<String, Object?> karte() => {
        'user_id': adresse,
        'identity_key': base64.encode(store.identity.rawPublicKey),
        'registration_id': store.identity.registrationId,
        'signed_prekey_id': _spk.id,
        'signed_prekey': base64.encode(_spk.getKeyPair().publicKey.serialize()),
        'signed_prekey_sig': base64.encode(_spk.signature),
        'one_time_prekey': {
          'key_id': _otk.id,
          'public_key': base64.encode(_otk.getKeyPair().publicKey.serialize()),
        },
      };

  /// Rohe Nutzlast-Bytes an Geraet 1 von [an] — auch solche, die
  /// [Payload.toBytes] nie erzeugen wuerde.
  Future<Uint8List> rohAn(
      String an, RelayBundleResponse buendel, Uint8List klar) async {
    final ziel = SignalProtocolAddress(an, 1);
    if (!await store.containsSession(ziel)) {
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(buendel));
    }
    final ct = await SessionCipher.fromStore(store, ziel).encrypt(klar);
    return Envelope.of(ct).toBytes();
  }

  Future<Uint8List> an(String an, RelayBundleResponse buendel, Payload p) =>
      rohAn(an, buendel, p.toBytes());
}

/// Eine Nutzlast von Hand, mit Auffuellung — fuer Inhalte, die kein
/// ordentlicher Client baut.
Uint8List handNutzlast(int art, Map<String, Object?> json) {
  final inhalt = [art, ...utf8.encode(jsonEncode(json)), 0x80];
  final fehlend = (256 - inhalt.length % 256) % 256;
  return Uint8List.fromList([...inhalt, ...List.filled(fehlend, 0)]);
}

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;
  late ZaehlRelay relay;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 5)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return fertig();
  }

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-befunde');
    lage = Relaylage();
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = ZaehlRelay(id, lage);
        lage.gebaut.add(r);
        return relay = r;
      },
    );
    kern.quittungsVerzug = () => Duration.zero;
    await kern.initialize();
    woerter = await kern.createIdentity();
    await kern.connect();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  /// Das eigene Buendel des Kerns, frisch aus der Datei — nach jedem
  /// verbrauchten Einmalschluessel ein anderes.
  Future<RelayBundleResponse> buendel() async {
    final store = SignalStoreRepository(kern.datenbankFuerTest)
        .openStore(await KeyDerivation.fromMnemonic(woerter));
    final spk =
        await store.loadSignedPreKey(store.state.signedPreKeys.keys.first);
    final otk = await store.loadPreKey(store.state.preKeys.keys.first);
    return RelayBundleResponse(
      userId: store.identity.address,
      identityKey: base64.encode(store.identity.rawPublicKey),
      registrationId: store.identity.registrationId,
      signedPreKeyId: spk.id,
      signedPreKey: base64.encode(spk.getKeyPair().publicKey.serialize()),
      signedPreKeySignature: base64.encode(spk.signature),
      oneTimePreKey: RelayOneTimePreKey(
        keyId: otk.id,
        publicKey: base64.encode(otk.getKeyPair().publicKey.serialize()),
      ),
    );
  }

  final buendelJe = <String, RelayBundleResponse>{};

  /// Schickt [p] von [a] an den Kern, wie der Relay es zustellen wuerde.
  Future<void> wirfEin(Absender a, Payload p, {int? q}) async {
    final b = buendelJe[a.adresse] ??= await buendel();
    relay.herein(RelayMessage(
        from: a.adresse,
        ciphertext: await a.an(kern.myId, b, p),
        at: DateTime.now().toUtc(),
        q: q));
  }

  void kontakt(Absender a, {ContactState zustand = ContactState.active}) =>
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: a.adresse, addedAt: DateTime.now().toUtc(), state: zustand));

  DateTime jetzt() => DateTime.now().toUtc();

  // ═══════════════════════════════════════════════════════════════════ L1
  group('L1: eine kaputte Nutzlast haelt den Empfang nicht auf', () {
    test('EIN STUECK, DAS KEIN OBJEKT IST: bestaetigt, Sitzung gespeichert',
        () async {
      // Rezept.ausText warf hier einen TypeError, an _legeAnhangAb vorbei:
      // kein Nachweis, kein gespeicherter Ratchet, dieselbe Zeile bei jedem
      // Verbinden.
      final a = await Absender.neu();
      kontakt(a);
      await wirfEin(
          a,
          Payload.anhang('kaputt-1', '{"v":1,"n":"x","g":1,"p":"","st":[1]}',
              jetzt()),
          q: 41);
      expect(await warteBis(() => relay.bestaetigt.contains(41)), isTrue,
          reason: 'der Umschlag blieb unbestaetigt liegen');

      // Die Sitzung lebt: die naechste Nachricht derselben Gegenstelle kommt an.
      final da = kern.incomingMessages.first;
      await wirfEin(a, Payload.text('danach-1', 'geht noch', jetzt()), q: 42);
      expect((await da.timeout(const Duration(seconds: 5))).text, 'geht noch');
    });

    test('EINE INNERE NUTZLAST MIT "r" OHNE LISTE (Gruppe): bestaetigt',
        () async {
      final a = await Absender.neu();
      kontakt(a);
      const gid = 'g-AAAAAAAAAAAAAAAAAAAAAA';
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid, name: 'G', admin: a.adresse, mitglieder: [a.adresse, kern.myId]));
      final innen = handNutzlast(PayloadKind.reaktion.code, {
        'id': 'r-1',
        't': jetzt().millisecondsSinceEpoch,
        'x': ':)',
        'r': 5,
      });
      await wirfEin(
          a,
          Payload(
              kind: PayloadKind.gruppe,
              messageId: 'huelle-1',
              sentAt: jetzt(),
              gruppe: gid,
              text: base64.encode(innen)),
          q: 43);
      expect(await warteBis(() => relay.bestaetigt.contains(43)), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════ L4
  test('L4: EIN "from" IN ANDERER SCHREIBWEISE WIRD VERWORFEN (und bestaetigt)',
      () async {
    final a = await Absender.neu();
    final b = await buendel();
    relay.herein(RelayMessage(
        from: a.adresse.toUpperCase(),
        ciphertext: await a.an(kern.myId, b, Payload.text('x-1', 'hi', jetzt())),
        at: jetzt(),
        q: 44));
    expect(await warteBis(() => relay.bestaetigt.contains(44)), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await kern.getContacts(), isEmpty,
        reason: 'es entstand ein Kontakt unter einer zweiten Schreibweise');
  });

  // ═══════════════════════════════════════════════════════════════════ M1
  test('M1: EINE KENNUNG, DIE SCHON MIR GEHOERT, WIRD NICHT ANGENOMMEN',
      () async {
    final a = await Absender.neu();
    kontakt(a);
    kern.ablageFuerTest.speichereEigene(Message(
        id: 'meine-1',
        chatId: a.adresse,
        senderId: kern.myId,
        text: 'von mir',
        isMine: true,
        timestamp: jetzt(),
        status: MessageStatus.sent));
    await wirfEin(a, Payload.text('meine-1', 'untergeschoben', jetzt()), q: 45);
    expect(await warteBis(() => relay.bestaetigt.contains(45)), isTrue,
        reason: 'verworfen heisst nicht: liegengelassen');
    final verlauf = await kern.getMessages(a.adresse);
    expect(verlauf.map((m) => m.text), ['von mir']);
  });

  // ═══════════════════════════════════════════════════════════════════ L3
  group('L3: Quittungen', () {
    test('EINE WIEDERHOLUNG WIRD NOCH EINMAL QUITTIERT', () async {
      final a = await Absender.neu();
      kontakt(a);
      await wirfEin(a, Payload.text('d-1', 'zweimal', jetzt()));
      expect(
          await warteBis(
              () => lage.gesendet.where((g) => g.an == a.adresse).length == 1),
          isTrue,
          reason: 'die erste Quittung fehlt');
      await wirfEin(a, Payload.text('d-1', 'zweimal', jetzt()));
      expect(
          await warteBis(
              () => lage.gesendet.where((g) => g.an == a.adresse).length == 2),
          isTrue,
          reason: 'auf die Wiederholung kam keine Quittung — der Absender '
              'schickte sie sonst bei jedem Verbinden erneut');
      expect((await kern.getMessages(a.adresse)), hasLength(1));
    });

    test('OHNE LEITUNG WARTET DIE QUITTUNG IM AUSGANG', () async {
      final a = await Absender.neu();
      kontakt(a);
      kern.quittungsVerzug = () => const Duration(milliseconds: 200);
      await wirfEin(a, Payload.text('q-1', 'hallo', jetzt()));
      expect(await warteBis(() => kern.ablageFuerTest.verlauf(a.adresse).isNotEmpty),
          isTrue);
      relay.verbunden = false; // die Leitung bricht vor der Quittung ab
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lage.gesendet.where((g) => g.an == a.adresse), isEmpty);
      expect(kern.ablageFuerTest.ausgang(), hasLength(1),
          reason: 'bis 25.09.2026 war sie hier einfach weg');

      await kern.disconnect();
      await kern.connect();
      expect(
          await warteBis(
              () => lage.gesendet.where((g) => g.an == a.adresse).isNotEmpty),
          isTrue,
          reason: 'der Nachversand holt die Quittung nach');
      expect(await warteBis(() => kern.ablageFuerTest.ausgang().isEmpty), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════ L7
  test('L7: VIELE UMSCHLAEGE DERSELBEN GEGENSTELLE AUF EINMAL — alle lesbar',
      () async {
    final a = await Absender.neu();
    kontakt(a);
    final b = buendelJe[a.adresse] ??= await buendel();
    // Erst alle verschluesseln, dann in einem Zug einwerfen.
    final umschlaege = [
      for (var i = 0; i < 6; i++)
        await a.an(kern.myId, b, Payload.text('s-$i', 'nr $i', jetzt())),
    ];
    for (final u in umschlaege) {
      relay.herein(RelayMessage(from: a.adresse, ciphertext: u, at: jetzt()));
    }
    expect(
        await warteBis(
            () => kern.ablageFuerTest.verlauf(a.adresse).length == 6),
        isTrue,
        reason: 'gleichzeitig entschluesselt, und der Ratchet verlor Schritte');
  });

  // ══════════════════════════════════════════════════════════════ C4 + C5
  group('Fernloeschung (C4, C5)', () {
    Future<void> vertraue(List<Absender> wem) => kern.setzeFernloeschung(
        Fernloeschung(
            an: true, schwelle: 2, vertraute: [for (final a in wem) a.adresse]));

    test('C4: WER ENTFERNT WIRD, VERLIERT SEIN LOESCHRECHT', () async {
      final a = await Absender.neu();
      kontakt(a);
      await vertraue([a]);
      await kern.removeContact(a.adresse);
      expect((await kern.getFernloeschung()).vertraute, isEmpty);
    });

    test('C4: NUR EIN AKTIVER KONTAKT ZAEHLT', () async {
      final a = await Absender.neu();
      kontakt(a, zustand: ContactState.incomingPending);
      await vertraue([a]);
      await wirfEin(a,
          Payload.control(PayloadKind.loeschanfrage, 'l-1', jetzt()), q: 46);
      expect(await warteBis(() => relay.bestaetigt.contains(46)), isTrue);
      expect((await kern.getFernloeschung()).anfragen, isEmpty);

      // Gegenprobe: aktiv zaehlt.
      kontakt(a);
      await wirfEin(a,
          Payload.control(PayloadKind.loeschanfrage, 'l-2', jetzt()), q: 47);
      expect(await warteBis(() => relay.bestaetigt.contains(47)), isTrue);
      expect((await kern.getFernloeschung()).anfragen.keys, [a.adresse]);
    });

    test('C5: EINE ALTE ANFRAGE ZAEHLT NICHT, AUCH WENN SIE JETZT ANKOMMT',
        () async {
      final a = await Absender.neu();
      kontakt(a);
      await vertraue([a]);
      await wirfEin(
          a,
          Payload.control(PayloadKind.loeschanfrage, 'l-3',
              jetzt().subtract(const Duration(days: 3))),
          q: 48);
      expect(await warteBis(() => relay.bestaetigt.contains(48)), isTrue);
      expect((await kern.getFernloeschung()).anfragen, isEmpty,
          reason: 'drei Tage beim Relay, und sie galt als frisch');
    });
  });

  // ═══════════════════════════════════════════════════════════════════ M3
  group('M3: Gruppen finden zusammen', () {
    const gid = 'g-BBBBBBBBBBBBBBBBBBBBBB';

    Future<void> standVon(Absender a, Gruppe g, {int? q}) => wirfEin(
        a, Payload.gruppenStand('st-${g.version}', gid, g.standText(), jetzt()),
        q: q);

    test('(a) WER SELBST GING, WIRD VON EINEM ALTEN STAND NICHT ZURUECKGEHOLT',
        () async {
      final admin = await Absender.neu();
      final b = await Absender.neu();
      kontakt(admin);
      final g = Gruppe(
          id: gid,
          name: 'G',
          admin: admin.adresse,
          mitglieder: [admin.adresse, kern.myId, b.adresse]);
      kern.ablageFuerTest.speichereGruppe(g);
      await kern.verlasseGruppe(gid);

      // Der Admin kennt den Austritt noch nicht und benennt um.
      await standVon(admin, g.copyWith(name: 'Neu', version: 2), q: 49);
      expect(await warteBis(() => relay.bestaetigt.contains(49)), isTrue);
      final jetztG = (await kern.getGruppen()).single;
      expect(jetztG.aktiv, isFalse,
          reason: 'bis 25.09.2026 machte der veraltete Stand mich wieder aktiv');
      expect(jetztG.verlassen, isTrue);
    });

    test('(b) DER NACHFOLGER WIRD ANGENOMMEN, BEVOR DER AUSTRITT DA IST',
        () async {
      final admin = await Absender.neu();
      final nachfolger = await Absender.neu();
      kontakt(admin);
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: admin.adresse,
          mitglieder: [admin.adresse, nachfolger.adresse, kern.myId]));
      // Ein fremdes Mitglied, das NICHT Nachfolger ist, darf das nicht.
      await standVon(
          nachfolger,
          Gruppe(
              id: gid,
              name: 'G',
              admin: nachfolger.adresse,
              mitglieder: [nachfolger.adresse, kern.myId],
              version: 2),
          q: 50);
      expect(await warteBis(() => relay.bestaetigt.contains(50)), isTrue);
      final g = (await kern.getGruppen()).single;
      expect(g.admin, nachfolger.adresse,
          reason: 'die erste Aenderung des neuen Admins ging verloren');
      expect(g.version, 2);
      expect(g.mitglieder, [nachfolger.adresse, kern.myId]);
    });

    test('(b) aber nur, wenn er GENAU den alten Admin herausnimmt', () async {
      final admin = await Absender.neu();
      final nachfolger = await Absender.neu();
      final dritter = await Absender.neu();
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: admin.adresse,
          mitglieder: [admin.adresse, nachfolger.adresse, kern.myId]));
      await standVon(
          nachfolger,
          Gruppe(
              id: gid,
              name: 'G',
              admin: nachfolger.adresse,
              mitglieder: [nachfolger.adresse, kern.myId, dritter.adresse],
              version: 2),
          q: 51);
      expect(await warteBis(() => relay.bestaetigt.contains(51)), isTrue);
      expect((await kern.getGruppen()).single.admin, admin.adresse);
    });

    test('EIN ADMIN VERKUENDET NACH EINEM AUSTRITT DEN NEUEN STAND', () async {
      final a = await Absender.neu();
      final b = await Absender.neu();
      lage.buendel = (wen) => wen == b.adresse ? b.karte() : const {};
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: kern.myId,
          mitglieder: [kern.myId, a.adresse, b.adresse]));
      await wirfEin(a, Payload.gruppenAustritt('aus-1', gid, jetzt()), q: 52);
      expect(await warteBis(() => relay.bestaetigt.contains(52)), isTrue);
      final g = (await kern.getGruppen()).single;
      expect(g.mitglieder, [kern.myId, b.adresse]);
      expect(g.version, 2, reason: 'eine Fassung hoeher, damit es ueberall greift');
      expect(
          await warteBis(() => lage.gesendet.any((x) => x.an == b.adresse)),
          isTrue,
          reason: 'B haengt sonst an einer Liste, die es nicht mehr gibt');
    });

    test('ALS NACHFOLGER UEBERNEHME UND VERKUENDE ICH', () async {
      final admin = await Absender.neu();
      final b = await Absender.neu();
      lage.buendel = (wen) => wen == b.adresse ? b.karte() : const {};
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: admin.adresse,
          mitglieder: [admin.adresse, kern.myId, b.adresse]));
      await wirfEin(admin, Payload.gruppenAustritt('aus-2', gid, jetzt()), q: 53);
      expect(await warteBis(() => relay.bestaetigt.contains(53)), isTrue);
      final g = (await kern.getGruppen()).single;
      expect(g.admin, kern.myId);
      expect(g.version, 2);
      expect(
          await warteBis(() => lage.gesendet.any((x) => x.an == b.adresse)),
          isTrue);
    });

    test('EIN SPRUNG ANS ENDE DER ZAHLEN WIRD ABGEWIESEN', () async {
      final admin = await Absender.neu();
      final g = Gruppe(
          id: gid,
          name: 'G',
          admin: admin.adresse,
          mitglieder: [admin.adresse, kern.myId]);
      kern.ablageFuerTest.speichereGruppe(g);
      await standVon(admin, g.copyWith(name: 'Weit', version: 1 << 30), q: 54);
      expect(await warteBis(() => relay.bestaetigt.contains(54)), isTrue);
      expect((await kern.getGruppen()).single.version, 1);
    });
  });

  // ══════════════════════════════════════════════════════════════ H4 + L2
  group('Gruppenversand (H4, L2)', () {
    const gid = 'g-CCCCCCCCCCCCCCCCCCCCCC';

    Future<MessageStatus> statusNach(String id) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return kern.ablageFuerTest.nachricht(gid, kern.myId, id)!.status;
    }

    test('H4: EIN BREMSENDER RELAY (429) BEI EINEM MITGLIED HEISST "LIEGT"',
        () async {
      final a = await Absender.neu();
      final b = await Absender.neu();
      lage.buendel = (wen) {
        if (wen == b.adresse) {
          throw const RelayException('zu viele Anfragen', statusCode: 429);
        }
        return wen == a.adresse ? a.karte() : const {};
      };
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: kern.myId,
          mitglieder: [kern.myId, a.adresse, b.adresse]));
      final m = await kern.sendMessage(gid, 'an alle');
      expect(await statusNach(m.id), MessageStatus.sending,
          reason: 'bis 25.09.2026 stand sie hier auf "gesendet" — und B '
              'bekam sie nie');
    });

    test('H4: NUR EIN UNBEKANNTES KONTO (404) WIRD UEBERSPRUNGEN', () async {
      final a = await Absender.neu();
      final weg = await Absender.neu();
      lage.buendel = (wen) => wen == a.adresse ? a.karte() : const {};
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: kern.myId,
          mitglieder: [kern.myId, a.adresse, weg.adresse]));
      final m = await kern.sendMessage(gid, 'an alle');
      expect(await statusNach(m.id), MessageStatus.sent);
    });

    test('L2: IN EINER GRUPPE OHNE MICH WIRD NICHTS "GESENDET"', () async {
      kern.ablageFuerTest.speichereGruppe(Gruppe(
          id: gid,
          name: 'G',
          admin: 'x',
          mitglieder: const ['x', 'y'],
          aktiv: false));
      final m = await kern.sendMessage(gid, 'ins Leere');
      expect(await statusNach(m.id), MessageStatus.failed,
          reason: 'bis 25.09.2026 kam hier "gesendet" heraus');
    });
  });
}
