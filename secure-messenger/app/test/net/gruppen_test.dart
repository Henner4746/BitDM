// gruppen_test.dart — Gruppen Ende zu Ende: drei echte Kerne, echter Relay.
//
// Anna legt die Gruppe an und ist Admin. Bob und Carl sind Annas Kontakte,
// aber NICHT miteinander befreundet — der Fall, an dem sich zeigt, ob der
// Fanout auch an Mitglieder geht, mit denen man nie eine Sitzung hatte.

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_gruppen'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Future<Nutzer> nutzer(String name) async {
    final u = Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);
    addTearDown(u.aufraeumen);
    await u.starten();
    await u.core.createIdentity();
    await u.core.connect();
    return u;
  }

  Future<void> befreunde(Nutzer a, Nutzer b) async {
    await a.core.addContact(b.core.myId);
    expect(
        await Nutzer.warteBis(() => b.kontaktEreignisse.any((e) =>
            e.type == ContactEventType.incomingRequest &&
            e.contactId == a.core.myId)),
        isTrue);
    await b.core.acceptRequest(a.core.myId);
    expect(
        await Nutzer.warteBis(() => a.kontaktEreignisse.any((e) =>
            e.type == ContactEventType.requestAccepted &&
            e.contactId == b.core.myId)),
        isTrue);
  }

  Future<bool> kennt(Nutzer u, String gid) async =>
      (await u.core.getGruppen()).any((g) => g.id == gid && g.aktiv);

  /// Wartet, bis [u] die Gruppe kennt — `warteBis` ist synchron, die Abfrage
  /// nicht; deshalb ueber den Strom der Gruppenaenderungen.
  Future<void> wartetAufGruppe(Nutzer u, String gid) async {
    final ende = DateTime.now().add(const Duration(seconds: 20));
    while (!await kennt(u, gid) && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await kennt(u, gid), isTrue, reason: '${u.name} kennt die Gruppe nicht');
  }

  Future<({Nutzer anna, Nutzer bob, Nutzer carl, String gid})> gruppe() async {
    final anna = await nutzer('anna');
    final bob = await nutzer('bob');
    final carl = await nutzer('carl');
    await befreunde(anna, bob);
    await befreunde(anna, carl);
    final g = await anna.core
        .legeGruppeAn('Wanderung', [bob.core.myId, carl.core.myId]);
    await wartetAufGruppe(bob, g.id);
    await wartetAufGruppe(carl, g.id);
    return (anna: anna, bob: bob, carl: carl, gid: g.id);
  }

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull);
  });

  test('DIE GRUPPE ENTSTEHT BEI ALLEN, UND EINE NACHRICHT ERREICHT ALLE',
      () async {
    final (:anna, :bob, :carl, :gid) = await gruppe();
    final beiCarl = (await carl.core.getGruppen()).single;
    expect(beiCarl.name, 'Wanderung');
    expect(beiCarl.admin, anna.core.myId);
    expect(beiCarl.mitglieder.toSet(),
        {anna.core.myId, bob.core.myId, carl.core.myId});

    // Bob schreibt — auch an Carl, mit dem er nie eine Sitzung hatte.
    final m = await bob.core.sendMessage(gid, 'Samstag um neun am Parkplatz');
    expect(await Nutzer.warteBis(() => anna.eingang.any((x) => x.id == m.id)),
        isTrue, reason: 'Anna bekam die Gruppennachricht nicht');
    expect(await Nutzer.warteBis(() => carl.eingang.any((x) => x.id == m.id)),
        isTrue, reason: 'Carl bekam die Gruppennachricht nicht');
    final angekommen = carl.eingang.firstWhere((x) => x.id == m.id);
    expect(angekommen.chatId, gid, reason: 'sie gehoert in die Gruppe');
    expect(angekommen.senderId, bob.core.myId);

    // Und KEIN Kontakt "Bob" bei Carl — eine Gruppennachricht ist keine
    // Kontaktanfrage.
    expect((await carl.core.getContacts()).any((k) => k.id == bob.core.myId),
        isFalse);
  });

  test('REAKTIONEN, BEARBEITEN UND ANHEFTEN GEHEN AUCH IN DER GRUPPE',
      () async {
    final (:anna, :bob, :carl, :gid) = await gruppe();
    final m = await bob.core.sendMessage(gid, 'Wer bringt Brot?');
    expect(await Nutzer.warteBis(() => carl.eingang.any((x) => x.id == m.id)),
        isTrue);
    expect(await Nutzer.warteBis(() => anna.eingang.any((x) => x.id == m.id)),
        isTrue);

    final beiAnna = <String>[];
    final abo = anna.core.verlaufGeaendert.listen(beiAnna.add);
    addTearDown(abo.cancel);
    await carl.core.reagiere(gid, m.id, '🙋');
    expect(await Nutzer.warteBis(() => beiAnna.contains(gid)), isTrue);
    expect((await anna.core.getReaktionen(gid))[m.id], {carl.core.myId: '🙋'});

    await bob.core.bearbeite(gid, m.id, 'Wer bringt Brot und Kaese?');
    expect(await Nutzer.warteBis(() => beiAnna.length >= 2), isTrue);
    final neu = (await anna.core.getMessages(gid)).firstWhere((x) => x.id == m.id);
    expect(neu.text, 'Wer bringt Brot und Kaese?');

    // Carl darf Bobs Satz nicht aendern — schon sein eigener Kern sagt nein.
    await expectLater(carl.core.bearbeite(gid, m.id, 'niemand'),
        throwsA(isA<BearbeitungNichtMoeglichException>()));
  });

  test('WER ENTFERNT WURDE, SCHREIBT NICHT MEHR HINEIN', () async {
    final (:anna, :bob, :carl, :gid) = await gruppe();
    // DIE REIHENFOLGE IST DER GANZE TEST. Anna ist offline, waehrend sie
    // Carl entfernt: der neue Stand liegt in IHREM Ausgang, Carl erfaehrt
    // nichts und schreibt ahnungslos weiter. Seine Nachricht wartet beim
    // Relay auf Anna. Kommt Anna zurueck, muss IHRE Mitgliederliste sie
    // verwerfen — Carls Glaube, noch dazuzugehoeren, zaehlt nicht.
    //
    // Die erste Fassung liess Carl offline gehen; dann erfuhr er beim
    // Wiederverbinden von der Entfernung, BEVOR sein Nachversand lief, schickte
    // gar nichts, und der Test blieb gruen, auch ohne die Pruefung beim
    // Empfaenger (Mutationsprobe 25.09.2026).
    await anna.core.disconnect();
    await anna.core.entferneAusGruppe(gid, carl.core.myId);
    final m = await carl.core.sendMessage(gid, 'bin ich noch drin?');
    expect(
        await Nutzer.warteBis(() => carl.statusEreignisse.any(
            (u) => u.messageId == m.id && u.status == MessageStatus.sent)),
        isTrue,
        reason: 'Carls Nachricht ging gar nicht erst hinaus — dann prueft der '
            'Rest nichts');
    await anna.core.connect();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(anna.eingang.any((x) => x.id == m.id), isFalse,
        reason: 'Anna nahm eine Nachricht von einem Entfernten an');
    expect(await kennt(carl, gid), isFalse,
        reason: 'Carl hat nicht erfahren, dass er entfernt wurde');
    // Bob hat den neuen Stand auch.
    final beiBob = (await bob.core.getGruppen()).single;
    expect(beiBob.mitglieder.contains(carl.core.myId), isFalse);
  });

  test('IN EINE GRUPPE STECKT EINEN NUR, WER KONTAKT IST', () async {
    // Carl hat Bob entfernt; Bob hat Carl noch in seiner Liste und steckt ihn
    // in eine Gruppe. Bei Carl darf sie nicht ankommen.
    //
    // WAS DIESER TEST NICHT BEWEIST, gemessen per Mutationsprobe am
    // 25.09.2026: er bleibt auch gruen, wenn man die Kontaktpruefung in
    // `_nimmGruppenStand` entfernt. Beim Entfernen des Kontakts loescht Carl
    // auch die Sitzung, und Bobs Einladung laesst sich schon gar nicht mehr
    // entschluesseln. Die Kontaktpruefung schuetzt gegen einen VERAENDERTEN
    // Client, der ohne alte Sitzung frisch einlaedt — ein Fall, den der
    // echte Kern nie erzeugt und der sich ueber seine Schnittstelle deshalb
    // nicht herstellen laesst.
    final bob = await nutzer('bob');
    final carl = await nutzer('carl');
    final dora = await nutzer('dora');
    await befreunde(bob, carl);
    await befreunde(bob, dora);
    await carl.core.removeContact(bob.core.myId);
    final g = await bob.core.legeGruppeAn('Werbung', [carl.core.myId, dora.core.myId]);
    await wartetAufGruppe(dora, g.id); // bei Dora kommt sie an ...
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await kennt(carl, g.id), isFalse, reason: '... bei Carl nicht');
  });

  test('GEHT DER ADMIN, RUECKT DER NAECHSTE NACH — UND KANN VERWALTEN',
      () async {
    final (:anna, :bob, :carl, :gid) = await gruppe();
    await anna.core.verlasseGruppe(gid);
    Future<String?> adminBei(Nutzer u) async =>
        (await u.core.getGruppen()).single.admin;
    final ende = DateTime.now().add(const Duration(seconds: 20));
    while ((await adminBei(bob) != bob.core.myId ||
            await adminBei(carl) != bob.core.myId) &&
        DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await adminBei(bob), bob.core.myId,
        reason: 'Bob steht nach Anna in der Liste');
    expect(await adminBei(carl), bob.core.myId,
        reason: 'Carl muss denselben Nachfolger ausrechnen');

    // Und Bob kann wirklich verwalten: seine Umbenennung nimmt Carl an.
    await bob.core.benenneGruppe(gid, 'Wanderung ohne Anna');
    final ende2 = DateTime.now().add(const Duration(seconds: 20));
    while ((await carl.core.getGruppen()).single.name != 'Wanderung ohne Anna' &&
        DateTime.now().isBefore(ende2)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect((await carl.core.getGruppen()).single.name, 'Wanderung ohne Anna');
  });

  test('AUSTRETEN: DIE ANDEREN WISSEN ES, DER VERLAUF BLEIBT', () async {
    final (:anna, :bob, carl: _, :gid) = await gruppe();
    final vorher = await bob.core.sendMessage(gid, 'Ich bin dann mal weg');
    expect(await Nutzer.warteBis(() => anna.eingang.any((x) => x.id == vorher.id)),
        isTrue);
    await bob.core.verlasseGruppe(gid);
    final ende = DateTime.now().add(const Duration(seconds: 20));
    while ((await anna.core.getGruppen()).single.mitglieder.contains(bob.core.myId) &&
        DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect((await anna.core.getGruppen()).single.mitglieder,
        isNot(contains(bob.core.myId)));
    expect(await kennt(bob, gid), isFalse);
    expect((await bob.core.getMessages(gid)).any((x) => x.id == vorher.id),
        isTrue, reason: 'der Verlauf ist nach dem Austritt weg');
  });
}
