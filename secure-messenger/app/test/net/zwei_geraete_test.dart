// zwei_geraete_test.dart — DER BEWEIS.
//
// Henriks Anforderung, woertlich: zwei Geraete mit DENSELBEN zwoelf Woertern
// haben dieselbe Identitaet und dieselben Kontakte und bekommen AB DEM KOPPELN
// beide neue Nachrichten. Kein Uebertrag alter Verlaeufe, keine
// Kopplungsmaske, kein Hauptgeraet.
//
// Hier laeuft nichts Nachgebautes: echter Kern, echte verschluesselte
// Datenbank je Geraet, echter relay_server.py als eigener Prozess. Der Grund
// steht in relay_end_to_end_test.dart — ein Server-Test gegen einen
// Client-Nachbau und ein Client-Test gegen einen Server-Nachbau koennen beide
// gruen sein, waehrend nichts zusammenpasst.
//
// ═════════════════════════════════════════ WARUM GERADE DIESE SECHS FAELLE
//
// Es ist die Liste dessen, was still kaputtgehen kann. Jeder Fall hat einen
// Fehlermodus ohne Fehlermeldung:
//
//  1) Verdraengung — bis zum 30.07.2026 warf sich das zweite Geraet mit
//     denselben Woertern beim Anmelden das erste hinaus (Code 4409), und
//     keines der beiden merkte etwas.
//  2) Fanout — kommt die Nachricht nur bei einem Geraet an, sieht der Nutzer
//     auf dem anderen einfach nichts. Es gibt keine Meldung "hier fehlt was".
//  3) Spiegel und Doppelversand — beides unsichtbar: was ich selbst
//     geschrieben habe, fehlt auf dem Tablet, oder die Gegenstelle bekommt es
//     zweimal.
//  4) Verlaufsuebertrag — Henriks Entscheidung. Ein Test dagegen verhindert,
//     dass es spaeter jemand "repariert".
//  5) Obergrenze — ohne sie kostet eine Nutzernachricht beliebig viele
//     Verschluesselungen und Warteschlangenzeilen.
//  6) Besitznachweis — die einzige Tuer. Faellt sie, haengt sich ein Fremder
//     als weiteres Geraet an eine fremde Adresse und liest ab da alles mit,
//     ohne dass irgendwo etwas auffaellt (Spezifikation §6).
//
// ═══════════════════════════════════════════════════ MUTATIONSPROBE 30.07.2026
//
// Jeder Fall wurde einzeln gegen eine zurueckgedrehte Behebung laufen
// gelassen. Was dabei rot wurde, steht daneben — wer eine dieser Zeilen
// spaeter nicht mehr reproduzieren kann, hat einen Test vor sich, der nichts
// mehr prueft.
//
//  1  real_messenger_core.dart `_ermittleGeraetId` -> immer `_setzeGeraetId(1)`
//     ROT: handy connectionState war `disconnected` statt `online`
//          ("das ERSTE Geraet wurde stumm hinausgeworfen")
//  2  `_sendePayload`: `for (final g in ziele)` -> `ziele.take(1)`
//     ROT: "handy=[Eine Nachricht an beide.] tablet=[]"
//  3  `_sendePayload`: Spiegelversand abgeschaltet
//     ROT: Fall 3 "tablet=[]" UND Fall 4 "ab der Kopplung MUSS das Tablet
//          alles Neue sehen" — die zweite Haelfte belegt, dass Fall 4 nicht
//          bloss deshalb gruen ist, weil das Tablet ueberhaupt nichts bekommt
//  5  relay_server.py: Geraete-Deckel abgeschaltet
//     ROT: das dritte Geraet ging `online` statt in `error`
//  6  relay_server.py: beide `verify_signature`-Pruefungen abgeschaltet
//     ROT: /register antwortete 200 statt 403; /ws meldete `ok: true`
//
// EIN FALL HAT KEINE MUTATION, und das muss dastehen: Fall 4 bewacht eine
// ABWESENHEIT (kein Verlaufsuebertrag). Es gibt keine Behebung, die man
// zurueckdrehen koennte — die Behebung ist, dass nie jemand etwas gebaut hat.
// Ein solcher Test kann nur dadurch wertlos werden, dass sein Gegenstand gar
// nicht lebt; deshalb prueft er in derselben Zusicherungsfolge auch, dass das
// Neue ankommt, und genau diese Haelfte faellt unter Mutation 3.
//
// Mutation 5 wurde einmal FALSCH gewaehlt (`raise` -> `pass`): dahinter steht
// `totes[0]`, das war dann ein TypeError, die Registrierung scheiterte
// weiterhin und der Test blieb gruen. Eine Mutation, die den Fehler nur
// verschiebt, statt die Regel abzuschalten, beweist nichts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

/// Die Obergrenze, mit der dieser Relay laeuft.
///
/// ZWEI STATT DER AUSGELIEFERTEN FUENF (relay_server.py:186). Die Grenze
/// wirklich zu erreichen kostet sonst sechs vollstaendige Clients — sechs
/// Datenbanken, sechs Identitaeten, sechs Anmeldungen fuer eine Zahl, die der
/// Betreiber ohnehin per Umgebungsvariable setzt. Geprueft wird der
/// MECHANISMUS, nicht die Zahl.
const int geraeteMax = 2;

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten(
        umgebung: {'BITDM_GERAETE_MAX': '$geraeteMax'},
      ));
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_zwei'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Nutzer nutzer(String name) =>
      Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);

  /// Wartet, bis [wer] seine eigenen [wieviele] Geraete wirklich kennt.
  ///
  /// ═══════════════════════════ WARUM DAS HIER STEHEN MUSS UND KEIN LUXUS IST
  ///
  /// `connect()` stoesst die Auffrischung der eigenen Geraete mit `unawaited`
  /// an (real_messenger_core.dart:465) — sie laeuft noch, wenn `connect()`
  /// laengst zurueckgekehrt ist. Wer unmittelbar danach schreibt, spiegelt an
  /// eine leere Geraeteliste, und der Spiegel kommt NIE: er wird nicht
  /// nachgeholt, weil die Nachricht auf `sent` steht und der Nachversand nur
  /// `sending` einsammelt.
  ///
  /// Im Betrieb ist das belanglos — zwischen App-Start und der ersten
  /// getippten Nachricht liegen Sekunden. In einem Test liegen dort
  /// Mikrosekunden, und ohne diese Wartestelle entscheidet der Zufall, ob
  /// Fall 3 und Fall 4 gruen sind. Beim ersten Lauf hat Fall 3 gewonnen und
  /// Fall 4 verloren; das ist genau die Sorte Flackern, die spaeter jemand
  /// als "Test ist halt manchmal rot" abtut.
  Future<void> kenntEigeneGeraete(Nutzer wer, int wieviele) async {
    expect(await Nutzer.warteBis(() => wer.core.geraeteZahl == wieviele), isTrue,
        reason: '${wer.name} hat seine eigenen Geraete nicht gefunden');
    // `geraeteZahl` steht, BEVOR die Sitzungen dazu gebaut sind
    // (`_frischeEigeneGeraeteAuf` merkt sich die Zahl und holt danach erst das
    // Buendel). Dazwischen liegen ein HTTP-Abruf gegen 127.0.0.1 und ein
    // X3DH je Geraet — Millisekunden. Eine Sekunde ist zwei Groessenordnungen
    // darueber und trotzdem kein Grund, den ganzen Lauf zu bremsen: diese
    // Stelle wird dreimal erreicht.
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  /// Welche Geraete der Relay unter [adresse] fuehrt.
  ///
  /// DIREKT BEIM RELAY NACHGESEHEN und nicht ueber den Kern gefragt: der Kern
  /// merkt sich die Zahl vom letzten Verbinden, und genau die koennte veraltet
  /// sein. Der Weg ist derselbe, den die App geht (`?nur_geraete=1`,
  /// Spezifikation §3.3), nur ohne Zwischenschicht.
  Future<List<int>> geraeteAmRelay(String adresse) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(relay!.uri
          .replace(path: '/prekey/$adresse', queryParameters: {'nur_geraete': '1'}));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(text) as Map<String, Object?>;
      final roh = j['geraete'];
      if (roh is! List) return const [];
      return [for (final g in roh) (g as Map)['device_id']! as int]..sort();
    } finally {
      client.close();
    }
  }

  test('Relay laeuft — sonst sagen die folgenden Tests nichts aus', () {
    expect(relay, isNotNull,
        reason: 'relay_server.py liess sich nicht starten. '
            'py -3 -m pip install -r secure-messenger/server/requirements.txt');
  });

  group('Zwei Geraete, dieselben zwoelf Woerter', () {
    late Nutzer anna;
    late Nutzer handy;
    late Nutzer tablet;
    late String bobsAdresse;
    late List<String> woerter;

    /// Anna und Bob mit zwei Geraeten, alle drei online.
    Future<void> alleDreiBereit() async {
      anna = nutzer('anna');
      handy = nutzer('bob-handy');
      tablet = nutzer('bob-tablet');
      addTearDown(anna.aufraeumen);
      addTearDown(handy.aufraeumen);
      addTearDown(tablet.aufraeumen);

      await anna.starten();
      await anna.core.createIdentity();
      await anna.core.connect();

      await handy.starten();
      woerter = await handy.core.createIdentity();
      bobsAdresse = handy.core.myId;
      await handy.core.connect();

      // DASSELBE, WAS HENRIK TUT: zwoelf Woerter auf dem zweiten Geraet
      // eintippen. Kein Kopplungsschritt, kein QR-Code, kein Hauptgeraet.
      await tablet.starten();
      expect(await tablet.core.restoreIdentity(woerter), bobsAdresse,
          reason: 'dieselben Woerter muessen dieselbe Adresse ergeben — '
              'sonst ist es gar keine Kopplung');
      await tablet.core.connect();

      // DAS HANDY MUSS NOCH EINMAL VERBINDEN. Als es sich anmeldete, gab es
      // das Tablet noch nicht; die eigenen Geraete lernt der Kern bei JEDEM
      // connect() (Spezifikation §4), also beim naechsten App-Start. Genau
      // das wird hier nachgestellt.
      await handy.core.disconnect();
      await handy.core.connect();
      await kenntEigeneGeraete(handy, 2);
    }

    /// Anna und Bob sind Kontakte.
    ///
    /// HIER WIRD BEWUSST NUR AUF DAS HANDY GEWARTET, obwohl Annas
    /// Kontaktanfrage schon ein Fanout ist und beide Geraete erreicht. Der
    /// Grund kam aus der Mutationsprobe: schaltet man den Fanout ab, scheitert
    /// sonst DIESER Aufbau — und der Fall, der "beide entschluesseln die
    /// Nachricht" heisst, kommt gar nicht mehr dazu, das zu pruefen. Ein Test,
    /// der an fremder Stelle stirbt, belegt seine eigene Aussage nicht.
    Future<void> annaUndBobBefreundet() async {
      await anna.core.addContact(bobsAdresse, displayName: 'Bob');
      expect(await Nutzer.warteBis(() => handy.kontaktEreignisse.isNotEmpty),
          isTrue,
          reason: 'Annas Kontaktanfrage kam nicht an');
      await handy.core.acceptRequest(anna.core.myId);
      expect(
          await Nutzer.warteBis(() => anna.kontaktEreignisse
              .any((e) => e.type == ContactEventType.requestAccepted)),
          isTrue,
          reason: 'Anna hat die Annahme nicht mitbekommen');
    }

    // ═══════════════════════════════════════════════════════════════ Fall 1
    test('BEIDE GERAETE BLEIBEN ANGEMELDET — keines verdraengt das andere',
        () async {
      // DER KERN DES BEFUNDS. Vorher hielt der Relay eine Buendelzeile je
      // ADRESSE und eine WebSocket je ADRESSE: das zweite Geraet schrieb dem
      // ersten das Buendel weg, loeschte dabei seine Einmalschluessel und
      // trennte seine Verbindung mit Code 4409 — stumm, ohne Meldung, auf
      // beiden Seiten.
      //
      // EIGENER AUFBAU STATT `alleDreiBereit`, und zwar mit Absicht: der
      // gemeinsame Aufbau wartet darauf, dass das Handy sein Tablet kennt,
      // und diese Wartestelle wuerde bei einer kaputten Geraetekennung als
      // ERSTE scheitern. Der Test waere dann zwar rot, aber nicht an seiner
      // eigenen Aussage — und ein Test, der an fremder Stelle stirbt, sagt
      // ueber die Verdraengung nichts. Genau so ist es in der Mutationsprobe
      // aufgefallen.
      handy = nutzer('bob-handy');
      tablet = nutzer('bob-tablet');
      addTearDown(handy.aufraeumen);
      addTearDown(tablet.aufraeumen);

      await handy.starten();
      woerter = await handy.core.createIdentity();
      bobsAdresse = handy.core.myId;
      await handy.core.connect();

      await tablet.starten();
      expect(await tablet.core.restoreIdentity(woerter), bobsAdresse,
          reason: 'dieselben Woerter muessen dieselbe Adresse ergeben — '
              'sonst ist es gar keine Kopplung');
      await tablet.core.connect();

      expect(handy.core.connectionState, ConnectionState.online);
      expect(tablet.core.connectionState, ConnectionState.online,
          reason: 'das zweite Geraet muss sich anmelden koennen');

      // NICHT NUR IM SELBEN AUGENBLICK. Die Verdraengung war ein Ereignis auf
      // der Leitung; wer sofort nachsieht, sieht sie nicht. Deshalb ein
      // Moment Ruhe und dann noch einmal.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(handy.core.connectionState, ConnectionState.online,
          reason: 'das ERSTE Geraet wurde stumm hinausgeworfen');
      expect(tablet.core.connectionState, ConnectionState.online);

      // Und der Relay fuehrt sie wirklich als zwei Zeilen, nicht als eine.
      final geraete = await geraeteAmRelay(bobsAdresse);
      expect(geraete, hasLength(2),
          reason: 'eine Zeile je (Adresse, Geraet), Spezifikation §3.5');
      expect(geraete.first, 1,
          reason: 'das erste Geraet einer Adresse ist fest 1 — sonst koennen '
              'Clients ohne die Erweiterung diese Adresse nie erreichen (§1)');
    }, timeout: const Timeout(Duration(minutes: 3)));

    // ═══════════════════════════════════════════════════════════════ Fall 2
    test('EINE NACHRICHT VON AUSSEN, BEIDE GERAETE ENTSCHLUESSELN SIE',
        () async {
      // DER DURCHSTICH. Anna schickt EINMAL an eine Adresse; ihr Client
      // verschluesselt je Empfaengergeraet einzeln (eine Sitzung je
      // Geraetepaar, §10), der Relay legt je Geraet eine Zeile an, und beide
      // Geraete lesen den Klartext.
      await alleDreiBereit();
      await annaUndBobBefreundet();

      await anna.core.sendMessage(bobsAdresse, 'Eine Nachricht an beide.');

      expect(
          await Nutzer.warteBis(() =>
              handy.eingang.any((m) => m.text == 'Eine Nachricht an beide.') &&
              tablet.eingang.any((m) => m.text == 'Eine Nachricht an beide.')),
          isTrue,
          reason: 'beide Geraete muessen dieselbe Nachricht entschluesseln — '
              'handy=${handy.eingang.map((m) => m.text).toList()} '
              'tablet=${tablet.eingang.map((m) => m.text).toList()}');

      for (final g in [handy, tablet]) {
        final verlauf = await g.core.getMessages(anna.core.myId);
        expect(verlauf.where((m) => m.text == 'Eine Nachricht an beide.'),
            hasLength(1),
            reason: '${g.name}: genau einmal im Verlauf, nicht doppelt');
        expect(verlauf.single.isMine, isFalse);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    // ═══════════════════════════════════════════════════════════════ Fall 3
    test('WAS DAS HANDY SCHREIBT, STEHT AUF DEM TABLET — und bei Anna EINMAL',
        () async {
      // Der Spiegel (§5). Zwei Dinge in einem Test, weil sie zusammen die
      // Falle bilden: ohne Spiegel fehlt die eigene Nachricht auf dem zweiten
      // Geraet, und ein Spiegel, der versehentlich an die Gegenstelle geht,
      // laesst sie dort zweimal erscheinen.
      await alleDreiBereit();
      await annaUndBobBefreundet();

      await handy.core.sendMessage(anna.core.myId, 'Vom Handy geschrieben.');

      expect(
          await Nutzer.warteBis(() =>
              anna.eingang.any((m) => m.text == 'Vom Handy geschrieben.')),
          isTrue,
          reason: 'Anna hat die Nachricht gar nicht bekommen');

      expect(
          await Nutzer.warteBis(() => tablet.eingang
              .any((m) => m.text == 'Vom Handy geschrieben.')),
          isTrue,
          reason: 'das Tablet sieht nicht, was das Handy geschrieben hat — '
              'tablet=${tablet.eingang.map((m) => m.text).toList()}');

      final aufDemTablet = await tablet.core.getMessages(anna.core.myId);
      expect(aufDemTablet.map((m) => m.text), ['Vom Handy geschrieben.']);
      expect(aufDemTablet.single.isMine, isTrue,
          reason: 'auf dem Tablet ist es MEINE Nachricht, nicht Annas');
      expect(aufDemTablet.single.chatId, anna.core.myId,
          reason: 'sie gehoert in den Chat mit Anna, nicht in einen mit mir '
              'selbst');

      // GENAU EINMAL BEI ANNA. Kurz Zeit lassen — ein zweiter Umschlag waere
      // laengst da.
      await Future<void>.delayed(const Duration(seconds: 2));
      final beiAnna = await anna.core.getMessages(bobsAdresse);
      expect(beiAnna.where((m) => m.text == 'Vom Handy geschrieben.'),
          hasLength(1),
          reason: 'die Gegenstelle darf die Nachricht genau einmal bekommen, '
              'nicht je Geraet des Absenders eine');
    }, timeout: const Timeout(Duration(minutes: 3)));

    // ═══════════════════════════════════════════════ Notiz an mich (Signal)
    test('EINE NOTIZ AUF DEM HANDY STEHT AUF DEM TABLET — UND NIRGENDS SONST',
        () async {
      await alleDreiBereit();
      await annaUndBobBefreundet();

      final notizen = await handy.core.oeffneNotizen();
      expect(notizen, bobsAdresse);
      final m = await handy.core.sendMessage(notizen, 'Milch, Brot, Akku');

      expect(
          await Nutzer.warteBis(
              () => tablet.eingang.any((x) => x.text == 'Milch, Brot, Akku')),
          isTrue,
          reason: 'die Notiz kam auf dem Tablet nicht an');
      final aufDemTablet =
          tablet.eingang.firstWhere((x) => x.text == 'Milch, Brot, Akku');
      expect(aufDemTablet.chatId, bobsAdresse,
          reason: 'auf dem Tablet gehoert sie in die Notizen');
      expect(aufDemTablet.isMine, isTrue);

      // Auf dem Handy ist sie "gesendet" — nicht fuer immer "unterwegs".
      expect(
          await Nutzer.warteBis(() => handy.statusEreignisse.any((u) =>
              u.messageId == m.id && u.status == MessageStatus.sent)),
          isTrue);

      // Und Anna bekommt davon nichts.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(anna.eingang.any((x) => x.text == 'Milch, Brot, Akku'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));

    // ═══════════════════════════════════════════════════════════════ Fall 4
    test('DER VERLAUF VOR DEM KOPPELN WANDERT NICHT MIT — das Neue schon',
        () async {
      // HENRIKS ENTSCHEIDUNG, festgehalten (§9). Dieser Test bewacht eine
      // ABWESENHEIT, und eine Abwesenheit ist ohne Gegenprobe wertlos: waere
      // das Tablet einfach kaputt, waere der Verlauf auch leer. Deshalb
      // prueft derselbe Test BEIDE Haelften — nichts von vorher, alles ab
      // jetzt.
      anna = nutzer('anna');
      handy = nutzer('bob-handy');
      addTearDown(anna.aufraeumen);
      addTearDown(handy.aufraeumen);

      await anna.starten();
      await anna.core.createIdentity();
      await anna.core.connect();
      await handy.starten();
      woerter = await handy.core.createIdentity();
      bobsAdresse = handy.core.myId;
      await handy.core.connect();

      await anna.core.addContact(bobsAdresse);
      expect(await Nutzer.warteBis(() => handy.kontaktEreignisse.isNotEmpty),
          isTrue);
      await handy.core.acceptRequest(anna.core.myId);
      expect(await Nutzer.warteBis(() => anna.kontaktEreignisse.isNotEmpty),
          isTrue);

      // ZWEI NACHRICHTEN, BEVOR ES DAS TABLET GIBT.
      await handy.core.sendMessage(anna.core.myId, 'vor der Kopplung, von mir');
      expect(await Nutzer.warteBis(() => anna.eingang.isNotEmpty), isTrue);
      await anna.core.sendMessage(bobsAdresse, 'vor der Kopplung, von Anna');
      expect(await Nutzer.warteBis(() => handy.eingang.isNotEmpty), isTrue);

      // Jetzt erst das zweite Geraet.
      tablet = nutzer('bob-tablet');
      addTearDown(tablet.aufraeumen);
      await tablet.starten();
      await tablet.core.restoreIdentity(woerter);
      await tablet.core.connect();
      await handy.core.disconnect();
      await handy.core.connect();
      await kenntEigeneGeraete(handy, 2);

      expect(await tablet.core.getContacts(), isEmpty,
          reason: 'ein frisch gekoppeltes Geraet faengt mit einer leeren '
              'Unterhaltungsliste an (§9)');
      await expectLater(tablet.core.getMessages(anna.core.myId),
          throwsA(isA<UnknownContactException>()),
          reason: 'es gibt keinen Chat mit Anna, weil nichts uebertragen wird');

      // UND AB JETZT ALLES: dieselbe Nachricht wie in Fall 3, nur dass hier
      // bewiesen wird, dass der leere Verlauf oben nicht daran lag, dass das
      // Tablet gar nichts bekommt.
      await handy.core.sendMessage(anna.core.myId, 'nach der Kopplung');
      expect(
          await Nutzer.warteBis(() =>
              tablet.eingang.any((m) => m.text == 'nach der Kopplung')),
          isTrue,
          reason: 'ab der Kopplung MUSS das Tablet alles Neue sehen');

      expect((await tablet.core.getMessages(anna.core.myId)).map((m) => m.text),
          ['nach der Kopplung'],
          reason: 'genau das Neue und nichts von vorher');
    }, timeout: const Timeout(Duration(minutes: 3)));

    // ═══════════════════════════════════════════════════════════════ Fall 5
    test('DAS GERAET UEBER DER OBERGRENZE WIRD ABGEWIESEN', () async {
      // §6. Jedes weitere Geraet kostet dem Absender eine Verschluesselung und
      // dem Relay eine Warteschlangenzeile; ohne Deckel waere eine
      // Nutzernachricht beliebig teuer.
      await alleDreiBereit();
      expect(await geraeteAmRelay(bobsAdresse), hasLength(geraeteMax));

      final zuviel = nutzer('bob-laptop');
      addTearDown(zuviel.aufraeumen);
      await zuviel.starten();
      await zuviel.core.restoreIdentity(woerter);

      // KEIN WURF. Vertragsregel des Kerns: Netzprobleme werden gemeldet,
      // nicht geworfen (real_core_test.dart "ein unerreichbarer Relay wirft
      // NICHT"). Die Absage kommt als 507 und landet damit im Fehlerzustand.
      await zuviel.core.connect();
      expect(zuviel.core.connectionState, ConnectionState.error,
          reason: 'das Geraet ueber der Grenze darf nicht online gehen');

      expect(await geraeteAmRelay(bobsAdresse), hasLength(geraeteMax),
          reason: 'der Abgewiesene darf keine Zeile hinterlassen — und schon '
              'gar nicht ein lebendes Geraet verdraengen (§6)');
      expect(handy.core.connectionState, ConnectionState.online,
          reason: 'die bestehenden Geraete bleiben unberuehrt');
      expect(tablet.core.connectionState, ConnectionState.online);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // ═════════════════════════════════════════════════════════════════ Fall 6
  group('Der Besitznachweis', () {
    /// Ein Angreifer ohne die zwoelf Woerter. Er kennt die Adresse — sie ist
    /// oeffentlich — und damit auch den oeffentlichen Identitaetsschluessel,
    /// denn die Adresse IST dieser Schluessel. Was er nicht hat, ist der
    /// private Teil.
    late ECKeyPair fremderSchluessel;

    setUp(() => fremderSchluessel = Curve.generateKeyPair());

    test('EIN FREMDER KANN SICH NICHT ALS WEITERES GERAET ANMELDEN', () async {
      // DIE GEFAEHRLICHSTE STELLE DES GANZEN VORHABENS. Gelingt das, bekommt
      // der Fremde ab sofort von JEDEM Absender eine eigene Kopie jeder
      // Nachricht — und es gibt keinen Widerruf (§6, §12.5). Es faellt auch
      // nirgends auf: eine Adresse mit zwei Geraeten sieht aus wie Henriks.
      final bob = nutzer('bob');
      addTearDown(bob.aufraeumen);
      await bob.starten();
      await bob.core.createIdentity();
      await bob.core.connect();
      final adresse = bob.core.myId;

      // Der Angreifer setzt Bobs ECHTEN Identitaetsschluessel ein — er steht
      // in der Adresse und ist damit kein Geheimnis. Die Pruefung
      // `encode_id(identity_key) == user_id` (relay_server.py:1076) haelt
      // also. Was ihn aufhaelt, ist einzig die Signatur.
      final bundle = RelayPreKeyBundle(
        userId: adresse,
        identityKey: base64.encode(BitdmAddress.decode(adresse)),
        registrationId: 4242,
        deviceId: 4711,
        signedPreKeyId: 1,
        signedPreKey: base64.encode(Uint8List(33)),
        signedPreKeySignature: base64.encode(Uint8List(64)),
      );

      final client = HttpClient();
      addTearDown(client.close);

      Future<HttpClientResponse> post(String pfad, Object rumpf) async {
        final req = await client.postUrl(relay!.uri.replace(path: pfad));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(rumpf));
        return req.close();
      }

      final chal = await post('/register/challenge',
          {'user_id': adresse, 'device_id': 4711});
      final nonce = base64.decode(
          (jsonDecode(await chal.transform(utf8.decoder).join())
              as Map)['nonce']! as String);

      final antwort = await post('/register', {
        'bundle': bundle.toJson(),
        'signature': base64.encode(Curve.calculateSignature(
            fremderSchluessel.privateKey,
            bundle.registrationChallenge(Uint8List.fromList(nonce)))),
      });
      await antwort.drain<void>();

      expect(antwort.statusCode, 403,
          reason: 'ohne den privaten Identitaetsschluessel darf sich niemand '
              'als Geraet dieser Adresse eintragen');
      expect(await geraeteAmRelay(adresse), [1],
          reason: 'der Versuch darf keine Geraetezeile hinterlassen');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EIN FREMDER KANN SICH NICHT AUF EIN BESTEHENDES GERAET SETZEN',
        () async {
      // Die zweite Tuer. Selbst wenn er sich nicht eintragen kann, duerfte er
      // sich nicht auf die WebSocket eines schon eingetragenen Geraets
      // setzen — dort liegt die Post.
      final bob = nutzer('bob');
      addTearDown(bob.aufraeumen);
      await bob.starten();
      await bob.core.createIdentity();
      await bob.core.connect();
      final adresse = bob.core.myId;

      final ws = await WebSocket.connect(relay!.uri
          .replace(scheme: 'ws', path: '/ws', queryParameters: {
            'user_id': adresse,
            'device_id': '1',
          })
          .toString());

      // AUF DAS SCHLIESSEN GEWARTET UND NICHT AUF `auth_result`. Der Relay
      // schickt erst die Absage und schliesst dann; wer beim `auth_result`
      // weiterlaeuft, liest `closeCode` bevor es einen gibt und bekommt null.
      // Genau so ist dieser Test beim ersten Lauf gescheitert — an sich
      // selbst, nicht am Server.
      bool? angenommen;
      final geschlossen = Completer<void>();
      ws.listen((roh) {
        final m = jsonDecode(roh as String) as Map<String, Object?>;
        if (m['type'] == 'challenge') {
          // Signiert mit dem FREMDEN Schluessel. Etwas anderes hat er nicht.
          ws.add(jsonEncode({
            'signature': base64.encode(Curve.calculateSignature(
                fremderSchluessel.privateKey,
                Uint8List.fromList(base64.decode(m['nonce']! as String)))),
          }));
        } else if (m['type'] == 'auth_result') {
          angenommen = m['ok'] == true;
        }
      }, onDone: () {
        if (!geschlossen.isCompleted) geschlossen.complete();
      });

      // `onTimeout` schluckt die Frist mit Absicht: bleibt die Verbindung
      // offen, ist genau DAS der Befund, und er gehoert in die Zusicherung
      // darunter. Ohne das endete der Test mit "TimeoutException", und wer
      // ihn spaeter rot sieht, wuesste nicht, dass gerade ein Fremder
      // hereingelassen wurde.
      await geschlossen.future
          .timeout(const Duration(seconds: 20), onTimeout: () {});
      expect(angenommen, isFalse,
          reason: 'die Anmeldung mit einem fremden Schluessel muss scheitern — '
              'angenommen=$angenommen (null = der Relay hat gar nicht '
              'geantwortet und die Verbindung offen gelassen)');
      expect(ws.closeCode, 4403,
          reason: 'und zwar mit dem Code fuer "Signatur ungueltig", damit man '
              'es im Betrieb von einem Netzfehler unterscheiden kann');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
