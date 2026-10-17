// geraeteabmeldung_test.dart — DER FALL DER AUFGABE, gegen den echten Relay.
//
// "Telefon verloren, mit den zwoelf Woertern auf dem neuen wiederhergestellt"
// — bis 2.0.0 blieb das alte Geraet Teil der Identitaet und bekam weiter jede
// Nachricht (docs/GERAETEABMELDUNG.md). Hier laeuft nichts Nachgebautes:
// echter Kern, echte verschluesselte Datenbank je Geraet, echter
// relay_server.py als eigener Prozess.
//
// ═══════════════════════════════════════════════ WAS GEZEIGT WIRD, IN FOLGE
//
//  1) Ein zweites Geraet mit denselben Woertern kommt NICHT still dazu: es
//     steht nicht in der Liste, meldet sich nicht an und bekommt nichts —
//     bis das erste den Beitritt per Code bestaetigt.
//  2) Abmelden wirkt sofort: das Tablet ist draussen, die Woerter sind von ihm
//     entfernt, Annas naechste Nachricht geht nur noch ans Telefon, und beim
//     Relay liegt nichts mehr fuer das Tablet.
//  3) Das abgemeldete Geraet kommt nicht zurueck — weder durch Neustart noch
//     mit den Woertern: es bekommt seinen Verlauf wieder (verschluesselt
//     liegen geblieben), aber keine einzige neue Nachricht.
//  4) Telefon verloren, kein anderes Geraet: zuruecksetzen. Das alte faellt
//     heraus, das neue empfaengt — und das ist laut, das alte merkt es.

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/geraete_koppeln.dart';
import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  // EIN GROSSER EIMER FUER DIE HERKUNFTSBREMSE. Alle Faelle teilen sich einen
  // Relay und eine Herkunft (127.0.0.1); jede Anmeldung und jede Fassung der
  // Liste kostet 5 Marken, und nach drei Faellen war der Eimer leer (429 im
  // vierten). Die Bremse prueft test_relay.py; hier geht es um die Abmeldung.
  setUpAll(() async => relay = await Relay.starten(umgebung: {
        'BITDM_RATE_BURST': '5000',
        'BITDM_RATE_REFILL': '500',
      }));
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_abmeldung'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Nutzer nutzer(String name) =>
      Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);

  /// Welche Geraete der Relay unter [adresse] fuehrt — direkt gefragt.
  Future<List<int>> geraeteAmRelay(String adresse) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(relay!.uri.replace(
          path: '/prekey/$adresse', queryParameters: {'nur_geraete': '1'}));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return const [];
      final roh = (jsonDecode(text) as Map)['geraete'] as List;
      return [for (final g in roh) (g as Map)['device_id']! as int]..sort();
    } finally {
      client.close();
    }
  }

  int zeilenFuer(String adresse, int geraet) {
    final db = sqlite3.open('${relay!.datenverzeichnis.path}/relay.db');
    try {
      return db.select(
          'SELECT COUNT(*) AS n FROM queue '
          'WHERE recipient = ? AND recipient_device = ?',
          [adresse, geraet]).first['n'] as int;
    } finally {
      db.close();
    }
  }

  group('Geraeteabmeldung gegen den echten Relay', () {
    late Nutzer anna, handy, tablet;
    late List<String> woerter;
    late String bob;

    setUp(() {
      if (relay == null) {
        markTestSkipped('relay_server.py liess sich nicht starten');
      }
    });

    /// Anna, Bobs Telefon und Bobs Tablet — das Tablet ordentlich gekoppelt.
    Future<void> aufbau() async {
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
      bob = handy.core.myId;
      await handy.core.connect();
      expect(handy.core.geraeteStand, ListenStand.mitglied,
          reason: 'das erste Geraet legt die Liste mit sich allein an');

      await anna.core.addContact(bob, displayName: 'Bob');
      expect(await Nutzer.warteBis(() => handy.kontaktEreignisse.isNotEmpty), isTrue);
      await handy.core.acceptRequest(anna.core.myId);
      expect(
          await Nutzer.warteBis(() => anna.kontaktEreignisse
              .any((e) => e.type == ContactEventType.requestAccepted)),
          isTrue);

      await tablet.starten();
      expect(await tablet.core.restoreIdentity(woerter), bob);
      await tablet.core.connect();
    }

    Future<String> annaSchreibt(String text) async {
      final m = await anna.core.sendMessage(bob, text);
      return m.id;
    }

    test(
        '1) DIESELBEN WOERTER ALLEIN REICHEN NICHT MEHR — erst die Bestaetigung',
        () async {
      await aufbau();

      // Das Tablet hat die Woerter, steht aber nicht in der Liste.
      expect(tablet.core.geraeteStand, ListenStand.beitrittNoetig);
      expect(tablet.core.connectionState, isNot(ConnectionState.online));
      expect(await geraeteAmRelay(bob), [handy.core.geraetId],
          reason: 'es hat sich gar nicht erst angemeldet');

      final vorher = await annaSchreibt('noch nicht gekoppelt');
      expect(await Nutzer.warteBis(() => handy.eingang.any((m) => m.id == vorher)),
          isTrue);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(tablet.eingang, isEmpty,
          reason: 'ein Geraet mit den Woertern liest NICHT still mit');

      // Ein falscher Code hilft nicht.
      await handy.core.starteHinzufuegen();
      await tablet.core.trittBei('AAAA-BBBB-CCCC-DDDD');
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(tablet.core.geraeteStand, ListenStand.wartetAufBestaetigung,
          reason: 'die Anfrage passt zu keinem Code, das Handy laesst sie nicht zu');
      tablet.core.brichBeitrittAb();
      handy.core.beendeHinzufuegen();

      await koppele(handy, tablet);
      expect(await geraeteAmRelay(bob),
          [handy.core.geraetId, tablet.core.geraetId]..sort());

      // Ab jetzt bekommt es alles Neue.
      await handy.core.disconnect();
      await handy.core.connect();
      anna.core.ablageFuerTest.setzeGeraeteGeprueft(bob, 0);
      final nachher = await annaSchreibt('jetzt gekoppelt');
      expect(
          await Nutzer.warteBis(() =>
              handy.eingang.any((m) => m.id == nachher) &&
              tablet.eingang.any((m) => m.id == nachher)),
          isTrue,
          reason: 'handy=${handy.eingang.map((m) => m.text)} '
              'tablet=${tablet.eingang.map((m) => m.text)}');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '2+3) ABGEMELDET IST ABGEMELDET — und kommt auf keinem Weg zurueck',
        () async {
      await aufbau();
      await koppele(handy, tablet);
      final tabletKennung = tablet.core.geraetId;
      anna.core.ablageFuerTest.setzeGeraeteGeprueft(bob, 0);
      final vorher = await annaSchreibt('vor der Abmeldung');
      expect(await Nutzer.warteBis(() => tablet.eingang.any((m) => m.id == vorher)),
          isTrue);

      // Das Tablet geht verloren. Bob meldet es am Telefon ab.
      await handy.core.meldeGeraetAb(tabletKennung);

      expect(
          await Nutzer.warteBis(
              () => tablet.core.geraeteStand == ListenStand.abgemeldet),
          isTrue,
          reason: 'das Tablet hat seine Abmeldung nicht bemerkt '
              '(Stand ${tablet.core.geraeteStand})');
      expect(await tablet.tresor.read(), isNull,
          reason: 'die zwoelf Woerter sind vom abgemeldeten Geraet entfernt');
      expect(tablet.core.hasIdentity, isFalse);
      expect(File(tablet.pfad).existsSync(), isTrue,
          reason: 'die Datenbank bleibt — verschluesselt, nur mit den Woertern '
              'wieder zu oeffnen');
      expect(await geraeteAmRelay(bob), [handy.core.geraetId]);

      // Annas naechste Nachricht: nur noch ans Telefon, und beim Relay liegt
      // nichts fuer das Tablet.
      anna.core.ablageFuerTest.setzeGeraeteGeprueft(bob, 0);
      final nachher = await annaSchreibt('nach der Abmeldung');
      expect(await Nutzer.warteBis(() => handy.eingang.any((m) => m.id == nachher)),
          isTrue);
      expect(
          await Nutzer.warteBis(() => anna.statusEreignisse.any((u) =>
              u.messageId == nachher && u.status == MessageStatus.sent)),
          isTrue,
          reason: 'Annas Nachricht bleibt nicht am abgemeldeten Geraet haengen');
      expect(zeilenFuer(bob, tabletKennung), 0);

      // ── 3a) Neustart: ohne die Woerter gibt es keine Identitaet mehr.
      final neustart = RealMessengerCore(
        secretStore: tablet.tresor,
        databasePath: tablet.pfad,
        relayUri: relay!.uri,
      );
      expect(await neustart.initialize(), isFalse,
          reason: 'ein abgemeldetes Geraet steht nach dem Neustart ohne '
              'Identitaet da — es kann sich nicht von selbst wieder anmelden');
      await neustart.dispose();

      // ── 3b) Wer die Woerter hat (der Dieb, der sie im Telefon fand), gibt
      // sie dort wieder ein: der Verlauf ist wieder da — neue Post nicht.
      final dieb = Nutzer('dieb', tablet.pfad, relay!.uri);
      addTearDown(dieb.aufraeumen);
      await dieb.starten();
      expect(await dieb.core.restoreIdentity(woerter), bob);
      final alt = await dieb.core.getMessages(anna.core.myId);
      expect(alt.map((m) => m.id), contains(vorher),
          reason: 'der Verlauf lag verschluesselt da und geht mit den Woertern auf');
      await dieb.core.connect();
      expect(dieb.core.geraeteStand, ListenStand.beitrittNoetig,
          reason: 'es steht nicht in der Liste und kommt nicht hinein');
      expect(dieb.core.connectionState, isNot(ConnectionState.online));

      anna.core.ablageFuerTest.setzeGeraeteGeprueft(bob, 0);
      final spaeter = await annaSchreibt('nach dem Rueckkehrversuch');
      expect(await Nutzer.warteBis(() => handy.eingang.any((m) => m.id == spaeter)),
          isTrue);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(dieb.eingang.where((m) => m.id == spaeter), isEmpty,
          reason: 'DER PUNKT: mit den Woertern allein liest es nicht mehr mit');
      expect(await geraeteAmRelay(bob), [handy.core.geraetId]);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '2b) ABGEMELDET, WAEHREND ES AUS WAR — es merkt es beim naechsten Start',
        () async {
      // DER EIGENTLICHE FALL "TELEFON IN DER SCHUBLADE": es ist nicht
      // verbunden, waehrend Bob es abmeldet. Beim naechsten Verbinden darf es
      // sich nicht anmelden, sondern muss die Liste lesen und gehen.
      await aufbau();
      await koppele(handy, tablet);
      final tabletKennung = tablet.core.geraetId;
      await tablet.core.disconnect();

      await handy.core.meldeGeraetAb(tabletKennung);
      expect(await geraeteAmRelay(bob), [handy.core.geraetId]);
      expect(tablet.core.geraeteStand, ListenStand.mitglied,
          reason: 'es war aus und weiss noch nichts');

      await tablet.core.connect();
      expect(tablet.core.geraeteStand, ListenStand.abgemeldet);
      expect(await tablet.tresor.read(), isNull);
      expect(await geraeteAmRelay(bob), [handy.core.geraetId],
          reason: 'es hat sich nicht wieder angemeldet');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '4) TELEFON VERLOREN, KEIN ANDERES GERAET: zuruecksetzen — laut',
        () async {
      await aufbau();
      await koppele(handy, tablet);

      final ersatz = nutzer('bob-ersatz');
      addTearDown(ersatz.aufraeumen);
      await ersatz.starten();
      expect(await ersatz.core.restoreIdentity(woerter), bob);
      await ersatz.core.connect();
      expect(ersatz.core.geraeteStand, ListenStand.beitrittNoetig);

      await ersatz.core.setzeZurueck();
      expect(
          await Nutzer.warteBis(() =>
              ersatz.core.geraeteStand == ListenStand.mitglied &&
              ersatz.core.connectionState == ConnectionState.online),
          isTrue);

      // LAUT: beide alten Geraete merken es sofort.
      expect(
          await Nutzer.warteBis(() =>
              handy.core.geraeteStand == ListenStand.abgemeldet &&
              tablet.core.geraeteStand == ListenStand.abgemeldet),
          isTrue,
          reason: 'handy=${handy.core.geraeteStand} tablet=${tablet.core.geraeteStand}');
      expect(await geraeteAmRelay(bob), [ersatz.core.geraetId]);

      // Anna erreicht das neue Telefon.
      anna.core.ablageFuerTest.setzeGeraeteGeprueft(bob, 0);
      final m = await annaSchreibt('an das Ersatztelefon');
      await anna.core.disconnect();
      await anna.core.connect();
      expect(await Nutzer.warteBis(() => ersatz.eingang.any((x) => x.id == m)),
          isTrue,
          reason: 'ersatz=${ersatz.eingang.map((x) => x.text)}');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

// Damit `InMemorySecretStore` im Typ steht, den `Nutzer.tresor` liefert.
// ignore: unused_element
SecretStore _typ(Nutzer n) => n.tresor;
