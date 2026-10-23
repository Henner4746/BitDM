// geraeteliste_verschwiegen_test.dart — ein Relay, der eine Abmeldung
// verschweigt (docs/GERAETEABMELDUNG.md §12).
//
// Stufe 2 (geraeteliste_stufe2_test.dart) haelt einen Relay auf, der eine
// AELTERE Fassung wieder einspielt. Hier luegt er geschickter: er nimmt
// Fassung 2 (Tablet abgemeldet) an und liefert weiter Fassung 1 aus — und
// trennt das Tablet nicht. Dagegen stehen die Listenstempel Ende-zu-Ende, die
// Liste als eigene Nachricht (Art 20), die Warnung beim Besitzer und die
// Bindung jeder Sitzung an den Geraeteschluessel.
//
// GEGEN DIE ATTRAPPE: der echte relay_server.py luegt nicht. Die Gegenstellen
// sind echt — eigene libsignal-Speicher je Geraet, eigene
// Geraeteschluessel —, damit jeder Umschlag wirklich ver- und entschluesselt
// wird und kein Test an einer Abkuerzung vorbei gruen wird.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/crypto/sitzungsdatensatz.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/absender.dart';
import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

/// Eine Adresse mit mehreren Geraeten — jedes mit eigenem Speicher, eigenem
/// Geraeteschluessel und eigenen Prekeys.
class Gegenstelle {
  Gegenstelle._(this.identitaet);

  final SignalIdentity identitaet;
  final speicher = <int, BitdmSignalStore>{};
  final schluessel = <int, PrivateKey>{};
  final _karten = <int, Map<String, Object?>>{};

  String get adresse => identitaet.address;

  /// [identitaet]: fuer weitere Geraete der EIGENEN Adresse des Kerns.
  static Future<Gegenstelle> mit(List<int> geraete,
      {SignalIdentity? identitaet}) async {
    await signalBereit();
    final id = identitaet ??
        SignalIdentityBridge.fromDerived(
            await KeyDerivation.fromMnemonic(Bip39.generate()),
            registrationId: SignalIdentityBridge.newRegistrationId());
    final x = Gegenstelle._(id);
    var n = 40;
    for (final g in geraete) {
      n++;
      final s = BitdmSignalStore(identity: id);
      x.speicher[g] = s;
      x.schluessel[g] = PrivateKey.generate();
      x._karten[g] =
          await legePrekeysAb(s, spkId: n, kyberId: n * 10, preKeyId: n * 100);
    }
    return x;
  }

  GeraeteEintrag eintrag(int g) =>
      GeraeteEintrag(g, rohOeffentlich(schluessel[g]!), '');

  /// Eine Fassung, unterschrieben vom Geraet [von].
  Geraeteliste fassung(int epoche, List<int> geraete, {required int von}) =>
      Geraeteliste.unterschreibe(
        identitaet: identitaet,
        geraeteschluessel: schluessel[von]!,
        epoche: epoche,
        geraete: [for (final g in geraete) eintrag(g)],
        unterzeichner: von,
      );

  /// Was der Relay unter Kennung [kennung] ausliefert: die Prekeys von
  /// [prekeysVon] (sonst die eigenen) und die Signatur am signierten Prekey,
  /// ausgestellt vom Schluessel [sigVon] auf [kennung] — oder keine.
  /// [sig] ersetzt die Signatur ganz — fuer eine, die der Relay von einem
  /// anderen Buendel herueberkopiert.
  Map<String, Object?> geraetekarte(int kennung,
      {int? prekeysVon, int? sigVon, bool mitSig = true, String? sig}) {
    final k = _karten[prekeysVon ?? kennung]!;
    return {
      'device_id': kennung,
      ...k,
      if (mitSig)
        'spk_geraete_sig': sig ??
            base64.encode(schluessel[sigVon ?? prekeysVon ?? kennung]!.sign(
                message: spkNachricht(adresse, kennung,
                    k['signed_prekey_id']! as int, k['signed_prekey']! as String))),
    };
  }

  /// Die Antwort auf `/prekey/<adresse>`.
  Map<String, Object?> karte(List<Map<String, Object?>> geraete,
          {Geraeteliste? liste}) =>
      {
        'user_id': adresse,
        'identity_key': base64.encode(identitaet.rawPublicKey),
        ...geraete.first,
        'geraete': geraete,
        if (liste != null) 'geraeteliste': liste.alsJson(),
      };

  /// Ein Umschlag von Geraet [g] an [an]:[anGeraet]. Ohne Sitzung wird sie
  /// aus [buendel] gebaut. Solange libsignal PreKey-Nachrichten schickt, kommt
  /// der Sitzungsnachweis dazu — ausgestellt mit [nachweisMit] (sonst dem
  /// eigenen Schluessel) auf [nachweisAls] (sonst die eigene Kennung).
  Future<Uint8List> schreibe(int g, String an, int anGeraet, Payload p,
      {RelayBundleResponse? buendel,
      bool nachweis = true,
      PrivateKey? nachweisMit,
      int? nachweisAls}) async {
    final s = speicher[g]!;
    final ziel = adr(an, anGeraet);
    if (!await s.containsSession(ziel)) {
      await bauerVon(s, geraet: g).processPreKeyBundle(
          ziel, PreKeyBundleBridge.fromRelay(buendel!, deviceId: anGeraet));
    }
    var nutz = p;
    final basis =
        offenerBasisschluessel((await s.loadSession(ziel))!.serialize());
    if (basis != null && nachweis) {
      nutz = p.gestempelt(
        listenEpoche: p.listenEpoche,
        listenHash: p.listenHash,
        kenntEpoche: p.kenntEpoche,
        sitzungsNachweis: base64.encode((nachweisMit ?? schluessel[g]!).sign(
            message: sitzungsNachricht(
          absender: adresse,
          absenderGeraet: nachweisAls ?? g,
          empfaenger: an,
          empfaengerGeraet: anGeraet,
          basisschluessel: basis,
        ))),
      );
    }
    final ct = await chiffreVon(s, geraet: g).encrypt(ziel, nutz.toBytes());
    return Envelope.of(ct).toBytes();
  }

  Future<Payload> lies(int g, Uint8List umschlag, String von, int vonGeraet) async {
    final klar = await Envelope.fromBytes(umschlag)
        .decrypt(chiffreVon(speicher[g]!, geraet: g), adr(von, vonGeraet));
    return Payload.fromBytes(klar);
  }
}

DateTime jetzt() => DateTime.now().toUtc();

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;
  late List<Message> angekommen;
  late List<ContactEvent> ereignisse;
  final abos = <StreamSubscription<Object?>>[];
  final karten = <String, Map<String, Object?> Function()>{};
  final gelesen = <int>{};
  var q = 1000;
  var kernBuendelNr = 0;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 10)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return fertig();
  }

  setUp(() async {
    await signalBereit();
    RealMessengerCore.geraeteNachweisPflicht = false;
    ordner = await Directory.systemTemp.createTemp('bitdm-verschwiegen');
    karten.clear();
    gelesen.clear();
    lage = Relaylage()
      ..liste = []
      ..kenntListen = true
      ..buendel = (wen) => karten[wen]?.call() ?? <String, Object?>{};
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}k.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = ZaehlRelay(id, lage);
        lage.gebaut.add(r);
        return r;
      },
    );
    kern.quittungsVerzug = () => Duration.zero;
    angekommen = [];
    ereignisse = [];
    abos
      ..add(kern.incomingMessages.listen(angekommen.add))
      ..add(kern.contactEvents.listen(ereignisse.add));
    await kern.initialize();
    woerter = await kern.createIdentity();
    await kern.connect();
    lage.listeJe[kern.myId] = [kern.geraetId];
    expect(kern.geraeteStand, ListenStand.mitglied);
  });

  tearDown(() async {
    RealMessengerCore.geraeteNachweisPflicht = false;
    for (final a in abos) {
      await a.cancel();
    }
    abos.clear();
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  ZaehlRelay relay() => lage.gebaut.last as ZaehlRelay;

  Future<SignalIdentity> ich() async => SignalIdentityBridge.fromDerived(
      await KeyDerivation.fromMnemonic(woerter),
      registrationId: 1);

  PrivateKey meinGeraeteschluessel() => PrivateKey.deserialize(
      bytes: base64.decode(kern.datenbankFuerTest.meta('geraeteschluessel')!));

  Geraeteliste eigeneListe() =>
      Geraeteliste.pruefe(lage.listen[kern.myId], adresse: kern.myId);

  /// Ein frisches Buendel des Kerns — jedes mit eigenem Einmalschluessel,
  /// wie beim echten Relay.
  Future<RelayBundleResponse> kernBuendel() async => buendelAusSpeicher(
      SignalStoreRepository(kern.datenbankFuerTest)
          .openStore(await KeyDerivation.fromMnemonic(woerter)),
      nr: kernBuendelNr++);

  List<String> sitzungen() => kern.datenbankFuerTest.raw
      .select('SELECT address FROM sessions')
      .map((r) => r['address']! as String)
      .toList();

  Set<int> geraeteAn(String adresse, int ab) => {
        for (final s in lage.gesendet.skip(ab))
          if (s.an == adresse) s.geraet,
      };

  /// Alles, was der Kern an [x]:[g] geschickt hat und noch nicht gelesen
  /// wurde — entschluesselt, in der Reihenfolge des Versands.
  Future<List<({Payload p, Envelope huelle})>> post(Gegenstelle x, int g) async {
    final aus = <({Payload p, Envelope huelle})>[];
    for (var i = 0; i < lage.gesendet.length; i++) {
      final s = lage.gesendet[i];
      if (s.an != x.adresse || s.geraet != g || gelesen.contains(i)) continue;
      gelesen.add(i);
      aus.add((
        p: await x.lies(g, s.umschlag, kern.myId, kern.geraetId),
        huelle: Envelope.fromBytes(s.umschlag),
      ));
    }
    return aus;
  }

  Future<List<Payload>> texte(Gegenstelle x, int g) async => [
        for (final e in await post(x, g))
          if (e.p.kind == PayloadKind.text) e.p,
      ];

  /// Ein Umschlag kommt vom Relay herein, beschriftet mit [alsGeraet].
  /// Rueckgabe: die Kennung des Empfangsnachweises.
  int herein(Gegenstelle x, int alsGeraet, Uint8List umschlag) {
    final n = q++;
    relay().herein(RelayMessage(
        from: x.adresse,
        vonGeraet: alsGeraet,
        ciphertext: umschlag,
        at: jetzt(),
        q: n));
    return n;
  }

  void alsKontakt(Gegenstelle x) =>
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: x.adresse, addedAt: jetzt(), state: ContactState.active));

  /// [x] ist Kontakt, der Relay bietet [geraete] an (mit der Liste, die
  /// [liste] gerade liefert), der Kern schreibt einmal an alle, und die
  /// Geraete in [lesen] lesen es — danach haben beide Seiten Sitzungen.
  Future<void> verbinde(Gegenstelle x, List<int> geraete,
      {Geraeteliste? Function()? liste, List<int>? lesen}) async {
    lage.listeJe[x.adresse] = geraete;
    karten[x.adresse] = () {
      final l = liste?.call();
      if (l != null) lage.listen[x.adresse] = l.alsJson();
      return x.karte([for (final g in geraete) x.geraetekarte(g)], liste: l);
    };
    karten[x.adresse]!();
    alsKontakt(x);
    final ab = lage.gesendet.length;
    await kern.sendMessage(x.adresse, 'hallo');
    final erwartet = {
      for (final g in geraete)
        if (liste?.call()?.kennungen.contains(g) ?? true) g,
    };
    expect(await warteBis(() => geraeteAn(x.adresse, ab).containsAll(erwartet)),
        isTrue,
        reason: 'der erste Versand erreicht die gelisteten Geraete');
    for (final g in lesen ?? const <int>[]) {
      expect((await texte(x, g)).map((p) => p.text), contains('hallo'));
    }
  }

  // ═══════════════════════════════════════════ Teil 1: Stempel und Art 20

  test(
      'VERSCHLUCKTE VERTEILUNG: der Stempel der naechsten Nachricht macht die '
      'Liste veraltet — an das Tablet geht nichts mehr, von ihm kommt nichts '
      'mehr an', () async {
    final x = await Gegenstelle.mit([1, 7]);
    final eins = x.fassung(1, [1, 7], von: 1);
    final zwei = x.fassung(2, [1], von: 1);
    // Der Relay hat Fassung 2 angenommen, liefert aber weiter Fassung 1 aus —
    // mit beiden Geraeten — und trennt das Tablet nicht.
    await verbinde(x, [1, 7], liste: () => eins, lesen: [1, 7]);

    // Geraet 1 schreibt mit dem Stempel von Fassung 2. Die Liste selbst (die
    // Verteilung) hat der Relay verschluckt.
    herein(
        x,
        1,
        await x.schreibe(
            1,
            kern.myId,
            kern.geraetId,
            Payload.text('m-1', 'nach der Abmeldung', jetzt()).gestempelt(
                listenEpoche: 2, listenHash: zwei.kurzHash, kenntEpoche: 1)));
    expect(await warteBis(() => angekommen.any((m) => m.id == 'm-1')), isTrue,
        reason: 'wer die neue Fassung nennt, spricht weiter fuer die Adresse');
    expect(kern.datenbankFuerTest.meta('geraeteliste_ank:${x.adresse}'),
        isNotNull,
        reason: 'die Ankuendigung steht in meta und ueberlebt einen Neustart');

    // Der Kern hat beim Relay nachgefragt — und wieder Fassung 1 bekommen.
    // Trotzdem: an das Tablet geht nichts.
    var ab = lage.gesendet.length;
    await kern.sendMessage(x.adresse, 'nachher');
    expect(await warteBis(() => geraeteAn(x.adresse, ab).isNotEmpty), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(geraeteAn(x.adresse, ab), {1},
        reason: 'Geraet 7 hat Fassung 2 nicht gestempelt');
    expect(sitzungen(), contains('${x.adresse}:7'),
        reason: 'die Liste selbst fehlt noch — die Sitzung bleibt, sie wird '
            'nur nicht benutzt');

    // Das Tablet schreibt — mit Fassung 1, und ganz ohne Stempel.
    // Entschluesselt, verworfen, aber quittiert.
    herein(
        x,
        7,
        await x.schreibe(
            7,
            kern.myId,
            kern.geraetId,
            Payload.text('t-1', 'vom Tablet', jetzt()).gestempelt(
                listenEpoche: 1, listenHash: eins.kurzHash, kenntEpoche: 1)));
    final ohne = herein(x, 7,
        await x.schreibe(7, kern.myId, kern.geraetId,
            Payload.text('t-2', 'vom Tablet, ohne Stempel', jetzt())));
    expect(await warteBis(() => relay().bestaetigt.contains(ohne)), isTrue,
        reason: 'quittiert, sonst kaeme derselbe Umschlag bei jedem Verbinden');
    // GEGENPROBE in derselben Reihenfolge: Geraet 1 kommt weiter durch.
    herein(
        x,
        1,
        await x.schreibe(
            1,
            kern.myId,
            kern.geraetId,
            Payload.text('m-2', 'noch einmal', jetzt()).gestempelt(
                listenEpoche: 2, listenHash: zwei.kurzHash, kenntEpoche: 1)));
    expect(await warteBis(() => angekommen.any((m) => m.id == 'm-2')), isTrue);
    expect(angekommen.where((m) => m.id.startsWith('t-')), isEmpty,
        reason: 'das abgemeldete Tablet spricht nicht mehr als Besitzer');

    // Die Liste kommt doch noch an (Art 20 ueber Geraet 1): die Ankuendigung
    // ist erfuellt, und die Sitzung zum Tablet geht.
    herein(
        x,
        1,
        await x.schreibe(
            1,
            kern.myId,
            kern.geraetId,
            Payload.geraeteliste('l-2', zwei.alsJson(), jetzt()).gestempelt(
                listenEpoche: 2, listenHash: zwei.kurzHash, kenntEpoche: 1)));
    expect(
        await warteBis(() => !sitzungen().contains('${x.adresse}:7')), isTrue);
    expect(kern.datenbankFuerTest.meta('geraeteliste_ank:${x.adresse}'), isNull);
    expect(angekommen.where((m) => m.id == 'l-2'), isEmpty,
        reason: 'die Liste erscheint nie im Verlauf');
    ab = lage.gesendet.length;
    await kern.sendMessage(x.adresse, 'mit Liste');
    expect(await warteBis(() => geraeteAn(x.adresse, ab).isNotEmpty), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(geraeteAn(x.adresse, ab), {1});
  });

  test(
      'ZWEI FASSUNGEN DERSELBEN EPOCHE: Hinweis im Chat, es bleibt bei der '
      'ersten — aus der Liste und aus dem Stempel', () async {
    // Ueber die Liste (Art 20).
    final x = await Gegenstelle.mit([1, 3, 7]);
    await verbinde(x, [1, 7],
        liste: () => x.fassung(1, [1, 7], von: 1), lesen: [1]);
    final zweiA = x.fassung(2, [1], von: 1);
    final zweiB = x.fassung(2, [1, 3, 7], von: 1);
    herein(x, 1,
        await x.schreibe(1, kern.myId, kern.geraetId,
            Payload.geraeteliste('a', zweiA.alsJson(), jetzt())));
    expect(
        await warteBis(() => !sitzungen().contains('${x.adresse}:7')), isTrue);
    expect(kern.geraetelisteWiderspruch(x.adresse), isFalse);
    herein(x, 1,
        await x.schreibe(1, kern.myId, kern.geraetId,
            Payload.geraeteliste('b', zweiB.alsJson(), jetzt())));
    expect(await warteBis(() => kern.geraetelisteWiderspruch(x.adresse)), isTrue);
    expect(
        ereignisse.where((e) =>
            e.type == ContactEventType.deviceListConflict &&
            e.contactId == x.adresse),
        hasLength(1));
    expect(sitzungen(), isNot(contains('${x.adresse}:7')),
        reason: 'es bleibt bei der zuerst gesehenen Fassung');

    // Ueber den Stempel: Y kennt der Kern in Fassung 2 (A), ein Stempel
    // nennt Fassung 2 mit anderem Hash.
    final y = await Gegenstelle.mit([1, 7]);
    final y2a = y.fassung(2, [1], von: 1);
    final y2b = y.fassung(2, [1, 7], von: 1);
    await verbinde(y, [1, 7], liste: () => y2a, lesen: [1]);
    expect(kern.geraetelisteWiderspruch(y.adresse), isFalse);
    herein(
        y,
        1,
        await y.schreibe(
            1,
            kern.myId,
            kern.geraetId,
            Payload.text('y-1', 'mit anderem Hash', jetzt()).gestempelt(
                listenEpoche: 2, listenHash: y2b.kurzHash, kenntEpoche: 1)));
    expect(await warteBis(() => kern.geraetelisteWiderspruch(y.adresse)), isTrue);
  });

  test(
      'JEDE NUTZLAST TRAEGT DIE STEMPEL, JEDE PREKEY-NACHRICHT DEN '
      'SITZUNGSNACHWEIS — bis die Gegenstelle antwortet', () async {
    final x = await Gegenstelle.mit([1]);
    await verbinde(x, [1]);
    await kern.sendMessage(x.adresse, 'zwei');
    expect(
        await warteBis(
            () => lage.gesendet.where((s) => s.an == x.adresse).length >= 2),
        isTrue);
    final eigene = eigeneListe();
    final vorher = await post(x, 1);
    expect(vorher.map((e) => e.p.text), containsAll(['hallo', 'zwei']));
    for (final e in vorher) {
      expect(e.p.listenEpoche, eigene.epoche);
      expect(e.p.listenHash, eigene.kurzHash);
      expect(e.p.kenntEpoche, 0, reason: 'von X kennt der Kern keine Liste');
      expect(e.huelle.startetSitzung, isTrue);
      final basis =
          PreKeySignalMessage.deserialize(data: e.huelle.ciphertext).baseKey();
      expect(
          signaturGilt(
              rohOeffentlich(meinGeraeteschluessel()),
              sitzungsNachricht(
                absender: kern.myId,
                absenderGeraet: kern.geraetId,
                empfaenger: x.adresse,
                empfaengerGeraet: 1,
                basisschluessel: basis,
              ),
              base64.decode(e.p.sitzungsNachweis!)),
          isTrue,
          reason: 'der Nachweis gilt fuer genau diese Sitzung');
    }

    // X antwortet (kennt die Liste des Kerns). Ab jetzt keine
    // PreKey-Nachricht und kein Nachweis mehr, die Stempel bleiben.
    herein(
        x,
        1,
        await x.schreibe(
            1,
            kern.myId,
            kern.geraetId,
            Payload.text('a-1', 'Antwort', jetzt()).gestempelt(
                kenntEpoche: eigene.epoche)));
    expect(await warteBis(() => angekommen.any((m) => m.id == 'a-1')), isTrue);
    final ab = lage.gesendet.length;
    await kern.sendMessage(x.adresse, 'drei');
    expect(await warteBis(() => geraeteAn(x.adresse, ab).isNotEmpty), isTrue);
    final drei = (await post(x, 1)).where((e) => e.p.text == 'drei').single;
    expect(drei.huelle.startetSitzung, isFalse);
    expect(drei.p.sitzungsNachweis, isNull);
    expect(drei.p.listenEpoche, eigene.epoche);
  });

  test(
      'HEILEN: wer mit einer aelteren Epoche schreibt, bekommt die Liste '
      'nachgeschickt — hoechstens einmal in zehn Minuten', () async {
    final x = await Gegenstelle.mit([1]);
    await verbinde(x, [1], lesen: [1]);
    final eigene = eigeneListe();

    Future<void> antworte(String id, int ke) async {
      herein(
          x,
          1,
          await x.schreibe(1, kern.myId, kern.geraetId,
              Payload.text(id, 'Antwort', jetzt()).gestempelt(kenntEpoche: ke)));
      expect(await warteBis(() => angekommen.any((m) => m.id == id)), isTrue);
      // Das Nachschicken laeuft nebenher.
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    Future<List<Payload>> listen() async => [
          for (final e in await post(x, 1))
            if (e.p.kind == PayloadKind.geraeteliste) e.p,
        ];

    await antworte('a-1', eigene.epoche);
    expect(await listen(), isEmpty,
        reason: 'GEGENPROBE: wer die Epoche kennt, bekommt nichts');

    await antworte('a-2', 0);
    final l = await listen();
    expect(l, hasLength(1), reason: 'die verschluckte Verteilung kommt nach');
    expect(
        Geraeteliste.pruefe(l.single.geraetelisteRoh, adresse: kern.myId).roh,
        eigene.roh);

    await antworte('a-3', 0);
    expect(await listen(), isEmpty, reason: 'nicht bei jeder Nachricht');
  });

  test(
      'ABMELDEN VERTEILT: an Kontakte, an die eigenen Geraete — und einmal an '
      'das abgemeldete', () async {
    // Ein zweites eigenes Geraet (5) mit eigenem Speicher und Schluessel.
    final ich5 = await Gegenstelle.mit([5], identitaet: await ich());
    final zwei = Geraeteliste.unterschreibe(
      identitaet: await ich(),
      geraeteschluessel: meinGeraeteschluessel(),
      epoche: 2,
      geraete: [...eigeneListe().geraete, ich5.eintrag(5)],
      unterzeichner: kern.geraetId,
    );
    lage.listen[kern.myId] = zwei.alsJson();
    lage.listeJe[kern.myId] = [kern.geraetId, 5];
    karten[kern.myId] = () => ich5.karte([ich5.geraetekarte(5)]);
    relay().herein(const RelayGeraetelisteNeu(2));
    expect(await warteBis(() => sitzungen().contains('${kern.myId}:5')), isTrue,
        reason: 'mit gueltiger Prekey-Signatur entsteht die Sitzung');

    final x = await Gegenstelle.mit([1]);
    await verbinde(x, [1], lesen: [1]);

    final ab = lage.gesendet.length;
    await kern.meldeGeraetAb(5);
    final drei = eigeneListe();
    expect(drei.epoche, 3);
    expect(drei.kennungen, {kern.geraetId});

    Future<List<Geraeteliste>> listenBei(Gegenstelle wer, int g) async => [
          for (final e in await post(wer, g))
            if (e.p.kind == PayloadKind.geraeteliste)
              Geraeteliste.pruefe(e.p.geraetelisteRoh, adresse: kern.myId),
        ];

    expect(
        await warteBis(() =>
            geraeteAn(x.adresse, ab).isNotEmpty &&
            geraeteAn(kern.myId, ab).contains(5)),
        isTrue);
    expect((await listenBei(x, 1)).map((l) => l.roh), [drei.roh],
        reason: 'der Kontakt erfaehrt es Ende-zu-Ende');
    expect((await listenBei(ich5, 5)).map((l) => l.roh), [drei.roh],
        reason: 'der Abschied: das abgemeldete Geraet bekommt die Fassung, '
            'die es entfernt');
  });

  test(
      'DAS ABGEMELDETE GERAET ENTFERNT SEINE WOERTER, auch wenn der Relay es '
      'nie trennt', () async {
    // Der Kern ist hier das Tablet. Das Telefon (Geraet 5) meldet es ab, der
    // Relay liefert weiter Fassung 2 und laesst das Tablet herein.
    final telefon = await Gegenstelle.mit([5], identitaet: await ich());
    final zwei = Geraeteliste.unterschreibe(
      identitaet: await ich(),
      geraeteschluessel: meinGeraeteschluessel(),
      epoche: 2,
      geraete: [...eigeneListe().geraete, telefon.eintrag(5)],
      unterzeichner: kern.geraetId,
    );
    lage.listen[kern.myId] = zwei.alsJson();
    lage.listeJe[kern.myId] = [kern.geraetId, 5];
    karten[kern.myId] = () => telefon.karte([telefon.geraetekarte(5)]);
    relay().herein(const RelayGeraetelisteNeu(2));
    expect(await warteBis(() => sitzungen().contains('${kern.myId}:5')), isTrue);

    final adresse = kern.myId;
    final drei = telefon.fassung(3, [5], von: 5);
    herein(
        telefon,
        5,
        await telefon.schreibe(5, kern.myId, kern.geraetId,
            Payload.geraeteliste('ab', drei.alsJson(), jetzt()),
            buendel: await kernBuendel()));
    expect(
        await warteBis(() => kern.geraeteStand == ListenStand.abgemeldet), isTrue);
    expect(kern.hasIdentity, isFalse,
        reason: 'die zwoelf Woerter sind von diesem Geraet entfernt');
    expect(lage.listen[adresse], zwei.alsJson(),
        reason: 'und das, obwohl der Relay weiter Fassung 2 ausliefert');
  });

  // ═════════════════════════════════════════ Teil 2: Warnung beim Besitzer

  test(
      'DER BESITZER SIEHT, WENN DER RELAY SEINE AENDERUNG NICHT AUSLIEFERT',
      () async {
    final zwei = Geraeteliste.unterschreibe(
      identitaet: await ich(),
      geraeteschluessel: meinGeraeteschluessel(),
      epoche: 2,
      geraete: [
        ...eigeneListe().geraete,
        GeraeteEintrag(5, rohOeffentlich(PrivateKey.generate()), ''),
        GeraeteEintrag(6, rohOeffentlich(PrivateKey.generate()), ''),
      ],
      unterzeichner: kern.geraetId,
    );
    lage.listen[kern.myId] = zwei.alsJson();
    relay().herein(const RelayGeraetelisteNeu(2));
    expect(await warteBis(() => kern.eigeneGeraete.length == 3), isTrue);

    // Ehrlich: keine Warnung.
    await kern.meldeGeraetAb(5);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(kern.relayVerschweigtListe, isNull);

    // Der Relay nimmt Fassung 4 an und liefert weiter Fassung 3 aus.
    lage.verschweigtListen = true;
    await kern.meldeGeraetAb(6);
    expect(await warteBis(() => kern.relayVerschweigtListe == 4), isTrue);
    expect(kern.eigeneGeraete.map((g) => g.id), [kern.geraetId],
        reason: 'die eigene Anzeige folgt der eigenen Fassung');

    // Liefert er sie spaeter doch, faellt die Warnung beim naechsten Verbinden.
    lage.listen[kern.myId] = lage.verschwiegen[kern.myId]!;
    await kern.disconnect();
    await kern.connect();
    expect(await warteBis(() => kern.relayVerschweigtListe == null), isTrue);
  });

  // ═════════════════════════ Teil 3: Sitzungen gehoeren zum Geraeteschluessel

  test(
      'DAS BUENDEL DES TABLETS UNTER DER KENNUNG DES LAPTOPS WIRD NICHT '
      'ANGENOMMEN', () async {
    // Fassung: 1 und 3 (der Laptop). Das Tablet (7) ist abgemeldet, hat aber
    // die Woerter — und unterschreibt sein Buendel mit SEINEM Schluessel.
    Future<Set<int>> aufbau(Map<String, Object?> Function(Gegenstelle) laptop) async {
      final x = await Gegenstelle.mit([1, 3, 7]);
      final l = x.fassung(1, [1, 3], von: 1);
      lage.listen[x.adresse] = l.alsJson();
      lage.listeJe[x.adresse] = [1, 3];
      karten[x.adresse] =
          () => x.karte([x.geraetekarte(1), laptop(x)], liste: l);
      alsKontakt(x);
      final ab = lage.gesendet.length;
      await kern.sendMessage(x.adresse, 'hallo');
      expect(await warteBis(() => geraeteAn(x.adresse, ab).contains(1)), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return {
        for (final s in sitzungen())
          if (s.startsWith('${x.adresse}:')) int.parse(s.split(':').last),
      };
    }

    expect(await aufbau((x) => x.geraetekarte(3, prekeysVon: 7)), {1},
        reason: 'unterschrieben vom Schluessel des Tablets, nicht des Laptops');
    expect(
        await aufbau((x) => x.geraetekarte(3,
            prekeysVon: 7, sig: x.geraetekarte(3)['spk_geraete_sig']! as String)),
        {1},
        reason: 'die echte Signatur des Laptops gilt fuer SEINEN Prekey, nicht '
            'fuer den des Tablets');
    expect(await aufbau((x) => x.geraetekarte(3)), {1, 3},
        reason: 'GEGENPROBE: das echte Buendel des Laptops');

    // UEBERGANG (§12.5): eine FEHLENDE Signatur geht noch durch, Fassungen vor
    // 2.0.1 signieren nichts. Mit der Pflicht nicht mehr.
    expect(await aufbau((x) => x.geraetekarte(3, prekeysVon: 7, mitSig: false)),
        {1, 3});
    RealMessengerCore.geraeteNachweisPflicht = true;
    expect(await aufbau((x) => x.geraetekarte(3, prekeysVon: 7, mitSig: false)),
        {1});
  });

  test(
      'DIE ERSTNACHRICHT DES TABLETS UNTER DER KENNUNG DES LAPTOPS verdraengt '
      'die echte Sitzung nicht', () async {
    final x = await Gegenstelle.mit([1, 3, 7]);
    await verbinde(x, [1, 3],
        liste: () => x.fassung(1, [1, 3], von: 1), lesen: [3]);
    herein(x, 3,
        await x.schreibe(3, kern.myId, kern.geraetId,
            Payload.text('echt-1', 'vom Laptop', jetzt())));
    expect(await warteBis(() => angekommen.any((m) => m.id == 'echt-1')), isTrue);

    // Das Tablet baut eine frische Sitzung zum Kern und unterschreibt — wie
    // seine unveraenderte App — mit seinem Schluessel auf seine Kennung. Der
    // Relay beschriftet den Umschlag mit "Geraet 3".
    final t1 = herein(
        x,
        3,
        await x.schreibe(7, kern.myId, kern.geraetId,
            Payload.text('tablet-1', 'als Laptop', jetzt()),
            buendel: await kernBuendel()));
    expect(await warteBis(() => relay().bestaetigt.contains(t1)), isTrue);
    // Und eines, das die Kennung des Laptops in den Nachweis schreibt — mit
    // dem falschen Schluessel. (Dieselbe, noch unbestaetigte Sitzung: wieder
    // eine PreKey-Nachricht.)
    final t2 = herein(
        x,
        3,
        await x.schreibe(7, kern.myId, kern.geraetId,
            Payload.text('tablet-2', 'als Laptop', jetzt()),
            nachweisAls: 3));
    expect(await warteBis(() => relay().bestaetigt.contains(t2)), isTrue);
    expect(angekommen.where((m) => m.id.startsWith('tablet')), isEmpty);

    // DIE ANTWORT "AN DEN LAPTOP" LIEST DER LAPTOP. Haette die Sitzung des
    // Tablets die echte verdraengt, liefe sie darueber — dann laese sie das
    // Tablet, und der Laptop koennte sie nicht entschluesseln. SOFORT und
    // nicht erst nach der naechsten Nachricht des Laptops: die holte in
    // libsignal den alten Sitzungszustand wieder nach vorn und verdeckte die
    // Uebernahme (Mutationsprobe vom 18.10.2026).
    final abAntwort = lage.gesendet.length;
    await kern.sendMessage(x.adresse, 'antwort');
    expect(
        await warteBis(() => geraeteAn(x.adresse, abAntwort).contains(3)), isTrue);
    expect((await texte(x, 3)).map((p) => p.text), contains('antwort'));

    // Und die echte Sitzung traegt weiter.
    herein(x, 3,
        await x.schreibe(3, kern.myId, kern.geraetId,
            Payload.text('echt-2', 'wieder vom Laptop', jetzt())));
    expect(await warteBis(() => angekommen.any((m) => m.id == 'echt-2')), isTrue,
        reason: 'die echte Sitzung zum Laptop ist nicht verdraengt');

    // GEGENPROBE: Geraet 1 baut selbst eine Sitzung auf — mit gueltigem
    // Nachweis kommt es an. Ohne Nachweis nur im Uebergang.
    RealMessengerCore.geraeteNachweisPflicht = true;
    final b = await kernBuendel();
    final ohne = herein(
        x,
        1,
        await x.schreibe(1, kern.myId, kern.geraetId,
            Payload.text('eins-ohne', 'ohne Nachweis', jetzt()),
            buendel: b, nachweis: false));
    expect(await warteBis(() => relay().bestaetigt.contains(ohne)), isTrue);
    expect(angekommen.where((m) => m.id == 'eins-ohne'), isEmpty,
        reason: 'mit Pflicht kein Sitzungsaufbau ohne Nachweis');
    herein(x, 1,
        await x.schreibe(1, kern.myId, kern.geraetId,
            Payload.text('eins-mit', 'mit Nachweis', jetzt())));
    expect(
        await warteBis(() => angekommen.any((m) => m.id == 'eins-mit')), isTrue);
  });

  test(
      '"ZIELGERAET UNBEKANNT" LAESST DIE SITZUNG STEHEN, wenn das Geraet in der '
      'signierten Liste steht — ohne Liste wie bisher', () async {
    final x = await Gegenstelle.mit([1, 7]);
    await verbinde(x, [1, 7], liste: () => x.fassung(1, [1, 7], von: 1));

    // Der Relay verleugnet Geraet 7.
    lage.unbekannteGeraete = {7};
    lage.listeJe[x.adresse] = [1];
    final vorZwei = lage.versucht.length;
    await kern.sendMessage(x.adresse, 'zwei');
    expect(
        await warteBis(() => lage.versucht
            .skip(vorZwei)
            .any((v) => v.an == x.adresse && v.geraet == 7)),
        isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sitzungen(), contains('${x.adresse}:7'),
        reason: 'sonst baute der naechste Versand sie aus einem Buendel neu, '
            'das der Relay waehlt');
    final ab = lage.versucht.length;
    final abGesendet = lage.gesendet.length;
    await kern.sendMessage(x.adresse, 'drei');
    expect(await warteBis(() => geraeteAn(x.adresse, abGesendet).isNotEmpty),
        isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect({
      for (final v in lage.versucht.skip(ab))
        if (v.an == x.adresse) v.geraet,
    }, {1}, reason: 'bis zur naechsten Auffrischung uebersprungen');

    // GEGENPROBE ohne Liste: die Sitzung faellt.
    final y = await Gegenstelle.mit([1, 7]);
    lage.unbekannteGeraete = {};
    await verbinde(y, [1, 7]);
    lage.unbekannteGeraete = {7};
    lage.listeJe[y.adresse] = [1];
    await kern.sendMessage(y.adresse, 'zwei');
    expect(
        await warteBis(() => !sitzungen().contains('${y.adresse}:7')), isTrue);
  });
}
