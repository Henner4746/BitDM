// fern_codewort_test.dart — das Codewort, das eine Fernloeschung anstoesst.
//
// Zwei Haelften. Oben das Codewort selbst: Normalisieren, Mindestlaenge,
// gespeichert wird nur ein Hash. Unten der echte Kern mit echten Umschlaegen
// von Gegenstellen (RelayAttrappe, wie in protokoll_befunde_test.dart): ein
// Vertrauter mit dem Wort zaehlt wie eine Loeschanfrage und hinterlaesst
// KEINE Spur im Verlauf; jeder andere schreibt eine gewoehnliche Nachricht.

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/core/fern_codewort.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/absender.dart';
import '../support/relay_attrappe.dart';

const wort = 'Rote Katze im Schnee';

void main() {
  group('Das Codewort selbst', () {
    test('Gross/klein, Rand und doppelte Leerzeichen zaehlen nicht', () {
      final c = FernCodewort.aus(wort);
      expect(c.passt('rote katze im schnee'), isTrue);
      expect(c.passt('  ROTE   Katze\tim\nSchnee  '), isTrue);
      expect(c.passt('Rote Katze im Schnee!'), isFalse);
      expect(c.passt('Rote Katze'), isFalse);
      expect(FernCodewort.normalisiere('  A  b\tC '), 'a b c');
    });

    test('Umlaute: klein geschrieben wie gross', () {
      final c = FernCodewort.aus('ÄRGER ÜBER ÖL');
      expect(c.passt('ärger über öl'), isTrue);
    });

    test('mindestens sechs Zeichen nach dem Normalisieren', () {
      expect(FernCodewort.taugt('abcde'), isFalse);
      expect(FernCodewort.taugt('   abcde   '), isFalse);
      expect(FernCodewort.taugt('ab  cd'), isFalse, reason: 'wird zu "ab cd", fuenf Zeichen');
      expect(FernCodewort.taugt('abcdef'), isTrue);
      expect(() => FernCodewort.aus('kurz'), throwsArgumentError);
    });

    test('gespeichert wird nur Salz und Hash — und jedes Mal ein anderes Salz', () {
      final a = FernCodewort.aus(wort);
      final b = FernCodewort.aus(wort);
      final j = a.alsJson();
      expect(j.toLowerCase(), isNot(contains('katze')));
      final karte = jsonDecode(j) as Map;
      expect(karte.keys.toSet(), {'v', 's', 'h'});
      expect(base64.decode(karte['s'] as String), hasLength(16));
      expect(base64.decode(karte['h'] as String), hasLength(32));
      expect(a.alsJson(), isNot(b.alsJson()), reason: 'gleiches Wort, gleicher Hash');
      final zurueck = FernCodewort.ausJson(j)!;
      expect(zurueck.passt(wort), isTrue);
      expect(FernCodewort.ausJson('kaputt'), isNull);
      expect(FernCodewort.ausJson(null), isNull);
    });
  });

  group('Am echten Kern', () {
    late Directory ordner;
    late Relaylage lage;
    late RealMessengerCore kern;
    late List<String> woerter;
    late ZaehlRelay relay;
    final buendelJe = <String, RelayBundleResponse>{};
    final eingang = <Message>[];

    Future<bool> warteBis(bool Function() fertig,
        {Duration frist = const Duration(seconds: 5)}) async {
      final ende = DateTime.now().add(frist);
      while (!fertig() && DateTime.now().isBefore(ende)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return fertig();
    }

    setUp(() async {
      buendelJe.clear();
      eingang.clear();
      ordner = await Directory.systemTemp.createTemp('bitdm-codewort');
      lage = Relaylage();
      kern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
        relayFactory: (uri, id) => relay = ZaehlRelay(id, lage),
      );
      kern.quittungsVerzug = () => Duration.zero;
      await kern.initialize();
      woerter = await kern.createIdentity();
      await kern.connect();
      kern.incomingMessages.listen(eingang.add);
    });

    tearDown(() async {
      await kern.dispose();
      try {
        await ordner.delete(recursive: true);
      } catch (_) {}
    });

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

    Future<void> wirfEin(Absender a, Payload p, {int? q}) async {
      final b = buendelJe[a.adresse] ??= await buendel();
      relay.herein(RelayMessage(
          from: a.adresse,
          ciphertext: await a.an(kern.myId, b, p),
          at: DateTime.now().toUtc(),
          q: q));
    }

    void kontakt(Absender a) => kern.ablageFuerTest.speichereKontakt(Contact(
        id: a.adresse,
        addedAt: DateTime.now().toUtc(),
        state: ContactState.active));

    DateTime jetzt() => DateTime.now().toUtc();

    Future<void> vertraue(List<Absender> wem, {int k = 2}) =>
        kern.setzeFernloeschung(Fernloeschung(
            an: true, schwelle: k, vertraute: [for (final a in wem) a.adresse]));

    bool quittiertAn(Absender a) =>
        lage.gesendet.any((g) => g.an == a.adresse);

    test('IN DER DATENBANK STEHT NUR DER HASH', () async {
      await kern.setzeFernCodewort(wort);
      expect(await kern.hatFernCodewort(), isTrue);
      final roh = kern.datenbankFuerTest.meta('fern_codewort')!;
      expect(roh.toLowerCase(), isNot(contains('katze')));
      expect(kern.ablageFuerTest.fernCodewort()!.passt('rote katze im schnee'), isTrue);

      await expectLater(kern.setzeFernCodewort('kurz'), throwsArgumentError);
      expect(await kern.hatFernCodewort(), isTrue, reason: 'ein zu kurzes Wort nahm das alte weg');

      await kern.setzeFernCodewort(null);
      expect(await kern.hatFernCodewort(), isFalse);
      expect(kern.datenbankFuerTest.meta('fern_codewort'), isNull);
    });

    test('EIN VERTRAUTER MIT DEM WORT: ZAEHLT, STEHT NICHT IM VERLAUF, WIRD QUITTIERT',
        () async {
      final a = await Absender.neu();
      final b = await Absender.neu();
      kontakt(a);
      kontakt(b);
      await vertraue([a, b]);
      await kern.setzeFernCodewort(wort);

      await wirfEin(a, Payload.text('cw-1', '  rote KATZE im schnee ', jetzt()), q: 61);
      expect(await warteBis(() => relay.bestaetigt.contains(61)), isTrue);
      expect((await kern.getFernloeschung()).anfragen.keys, [a.adresse]);
      expect(kern.ablageFuerTest.verlauf(a.adresse), isEmpty,
          reason: 'das Codewort stand im Verlauf — wer das Telefon hat, liest es');
      expect(eingang, isEmpty, reason: 'das Codewort ging an die Oberflaeche (Benachrichtigung)');
      expect(await warteBis(() => quittiertAn(a)), isTrue,
          reason: 'der Absender bekam keine zwei Haken');
      expect((await kern.getFernloeschung()).faellig, isNull,
          reason: 'eine einzige Bitte loeste schon aus');
    });

    test('ZWEI VERSCHIEDENE VERTRAUTE: DIE LOESCHUNG IST GEPLANT', () async {
      final a = await Absender.neu();
      final b = await Absender.neu();
      kontakt(a);
      kontakt(b);
      await vertraue([a, b]);
      await kern.setzeFernCodewort(wort);
      final ausgeloest = <Fernloeschung>[];
      final abo = kern.fernloeschungAusgeloest.listen(ausgeloest.add);
      addTearDown(abo.cancel);

      // Derselbe zweimal reicht nicht.
      await wirfEin(a, Payload.text('cw-a1', wort, jetzt()), q: 71);
      await wirfEin(a, Payload.text('cw-a2', wort, jetzt()), q: 72);
      expect(await warteBis(() => relay.bestaetigt.contains(72)), isTrue);
      expect(ausgeloest, isEmpty);

      // Der zweite Vertraute mit /wipe (die alte Art) — beides zaehlt zusammen.
      await wirfEin(b, Payload.control(PayloadKind.loeschanfrage, 'l-b', jetzt()), q: 73);
      expect(await warteBis(() => ausgeloest.isNotEmpty), isTrue,
          reason: 'zwei Vertraute, und nichts geschah');
      final f = await kern.getFernloeschung();
      expect(f.faellig, isNotNull);
      expect(f.anfragen.keys.toSet(), {a.adresse, b.adresse});
    });

    test('BEIDE MIT DEM CODEWORT: AUCH DAS LOEST AUS', () async {
      final a = await Absender.neu();
      final b = await Absender.neu();
      kontakt(a);
      kontakt(b);
      await vertraue([a, b]);
      await kern.setzeFernCodewort(wort);
      await wirfEin(a, Payload.text('cw-a', wort, jetzt()), q: 81);
      await wirfEin(b, Payload.text('cw-b', wort.toUpperCase(), jetzt()), q: 82);
      expect(await warteBis(() => relay.bestaetigt.contains(82)), isTrue);
      expect(await warteBis(() => relay.bestaetigt.contains(81)), isTrue);
      expect((await kern.getFernloeschung()).faellig, isNotNull);
      expect(kern.ablageFuerTest.verlauf(a.adresse), isEmpty);
      expect(kern.ablageFuerTest.verlauf(b.adresse), isEmpty);
    });

    test('EIN NICHT-VERTRAUTER MIT DEMSELBEN TEXT: EINE GANZ NORMALE NACHRICHT', () async {
      final a = await Absender.neu();
      final b = await Absender.neu();
      final fremd = await Absender.neu();
      kontakt(a);
      kontakt(b);
      kontakt(fremd);
      await vertraue([a, b]);
      await kern.setzeFernCodewort(wort);

      await wirfEin(fremd, Payload.text('cw-f', wort, jetzt()), q: 91);
      expect(await warteBis(() => relay.bestaetigt.contains(91)), isTrue);
      expect(kern.ablageFuerTest.verlauf(fremd.adresse).map((m) => m.text), [wort]);
      expect(eingang.map((m) => m.id), ['cw-f']);
      expect((await kern.getFernloeschung()).anfragen, isEmpty);
    });

    test('OHNE EINGESCHALTETEN SCHUTZ IST ES EINE NACHRICHT', () async {
      final a = await Absender.neu();
      kontakt(a);
      await kern.setzeFernloeschung(Fernloeschung(schwelle: 2, vertraute: [a.adresse]));
      await kern.setzeFernCodewort(wort);
      await wirfEin(a, Payload.text('cw-aus', wort, jetzt()), q: 95);
      expect(await warteBis(() => relay.bestaetigt.contains(95)), isTrue);
      expect(kern.ablageFuerTest.verlauf(a.adresse).map((m) => m.text), [wort]);
    });

    test('EINE ALTE NACHRICHT MIT DEM WORT ZAEHLT NICHT (24-STUNDEN-FENSTER)', () async {
      final a = await Absender.neu();
      kontakt(a);
      await vertraue([a]);
      await kern.setzeFernCodewort(wort);
      await wirfEin(
          a, Payload.text('cw-alt', wort, jetzt().subtract(const Duration(days: 2))),
          q: 97);
      expect(await warteBis(() => relay.bestaetigt.contains(97)), isTrue);
      expect((await kern.getFernloeschung()).anfragen, isEmpty);
      // Verschluckt wird sie trotzdem — das Wort soll nie sichtbar werden.
      expect(kern.ablageFuerTest.verlauf(a.adresse), isEmpty);
    });

    test('EIN ANDERER TEXT VOM VERTRAUTEN BLEIBT EINE NACHRICHT', () async {
      final a = await Absender.neu();
      kontakt(a);
      await vertraue([a]);
      await kern.setzeFernCodewort(wort);
      await wirfEin(a, Payload.text('n-1', 'Wie geht es dir?', jetzt()), q: 99);
      expect(await warteBis(() => relay.bestaetigt.contains(99)), isTrue);
      expect(kern.ablageFuerTest.verlauf(a.adresse).map((m) => m.text), ['Wie geht es dir?']);
      expect((await kern.getFernloeschung()).anfragen, isEmpty);
    });
  });
}
