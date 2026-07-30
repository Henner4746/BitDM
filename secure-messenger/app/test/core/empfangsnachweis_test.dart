// empfangsnachweis_test.dart — WANN der Nachweis hinausgeht.
//
// Der Relay loescht eine Warteschlangenzeile erst, wenn der Empfaenger
// gemeldet hat, dass sie dauerhaft bei ihm liegt. Damit steht und faellt alles
// mit einer einzigen Frage: geht diese Meldung ERST nach dem Schreiben hinaus?
// Geht sie frueher, ist der Verlust nicht behoben, sondern von der Leitung in
// die App verschoben — und zwar unsichtbar, weil jeder andere Test dabei gruen
// bleibt.
//
// Deshalb prueft die erste Gruppe hier nicht das Ergebnis, sondern die
// REIHENFOLGE: im Augenblick des Nachweises wird der Verlauf befragt, und die
// Nachricht muss darin schon stehen.
//
// Die zweite Gruppe kommt ohne Netz aus. Sie deckt die beiden Faelle ab, die
// keine entschluesselbare Nachricht brauchen: den unlesbaren Umschlag und den
// live zugestellten ohne Kennung.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../support/nutzer.dart';
import '../support/relay_process.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _inhalt;
  @override
  Future<Uint8List?> read() async => _inhalt;
  @override
  Future<void> write(Uint8List e) async => _inhalt = e;
  @override
  Future<void> delete() async => _inhalt = null;
}

/// Ein echter RelayClient mit einem Fenster an genau einer Stelle.
///
/// GEERBT UND NICHT NACHGEBAUT: fuer die Reihenfolgefrage muss alles andere
/// echt bleiben — echtes X3DH, echter Ratchet, echte Warteschlange. Ein
/// Doppelgaenger koennte die Frage gar nicht stellen, weil er keine
/// entschluesselbare Nachricht liefern kann.
class NachweisSpitzel extends RelayClient {
  NachweisSpitzel({
    required super.baseUri,
    required super.identity,
    this.beiNachweis,
    this.stumm = false,
  });

  /// Laeuft SYNCHRON im Augenblick des Nachweises, vor dem Absenden.
  final void Function(int q)? beiNachweis;

  /// Haelt den Nachweis zurueck — stellt eine App nach, die abstuerzt, bevor
  /// sie ihn losschicken kann. Der Relay stellt die Nachricht dann noch einmal
  /// zu, und genau das soll pruefbar sein.
  final bool stumm;

  final bestaetigt = <int>[];

  @override
  void bestaetigeEmpfang(int q) {
    bestaetigt.add(q);
    beiNachweis?.call(q);
    if (!stumm) super.bestaetigeEmpfang(q);
  }
}

/// Ein Relay, der nichts kann ausser Ereignisse einwerfen und mitschreiben,
/// was bestaetigt wurde.
class NachweisDoppel implements RelayClient {
  NachweisDoppel(this.identity);

  @override
  final SignalIdentity identity;

  final bestaetigt = <int>[];
  final _ereignisse = StreamController<RelayEvent>.broadcast();

  void liefere(RelayEvent e) => _ereignisse.add(e);

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;
  @override
  bool get isConnected => true;
  @override
  String get address => identity.address;

  @override
  Future<int> register(RelayPreKeyBundle bundle) async => 100;
  @override
  Future<void> connect() async {}
  @override
  Future<void> send(String to, Uint8List ciphertext) async {}
  @override
  void setzePushEndpunkt(String? endpunkt) {}

  @override
  void bestaetigeEmpfang(int q) => bestaetigt.add(q);

  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {
    if (!_ereignisse.isClosed) await _ereignisse.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

/// Alice und Bob bis zum aktiven Kontakt bringen.
///
/// Der Umweg ueber Anfrage und Annahme ist noetig und nicht Zierrat: ohne
/// Sitzung gibt es keine entschluesselbare Nachricht, und ohne die laesst sich
/// ueber die Reihenfolge von Speichern und Bestaetigen nichts sagen.
Future<void> _beideVerbinden(Nutzer alice, RealMessengerCore bob) async {
  final beiBob = <ContactEvent>[];
  final abo = bob.contactEvents.listen(beiBob.add);
  try {
    await alice.core.connect();
    await bob.connect();

    await alice.core.addContact(bob.myId, displayName: 'Bob');
    final kam = await Nutzer.warteBis(
        () => beiBob.any((e) => e.type == ContactEventType.incomingRequest));
    if (!kam) throw StateError('Bob bekam keine Kontaktanfrage');

    await bob.acceptRequest(alice.core.myId);
    final angenommen = await Nutzer.warteBis(() => alice.kontaktEreignisse
        .any((e) => e.type == ContactEventType.requestAccepted));
    if (!angenommen) throw StateError('Alice sah die Annahme nicht');
  } finally {
    await abo.cancel();
  }
}

void main() {
  group('mit echtem Relay', () {
    Relay? relay;
    late Directory tmp;
    var n = 0;

    setUpAll(() async => relay = await Relay.starten());
    tearDownAll(() async => relay?.beenden());

    setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_nachweis'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows gibt Handles verzoegert frei.
      }
    });

    String pfad(String name) => '${tmp.path}/${name}_${n++}.db';

    /// Wie viele Zeilen beim Relay fuer [empfaenger] noch offen sind.
    int offeneZeilen(String empfaenger) {
      final db = sqlite.sqlite3.open('${relay!.datenverzeichnis.path}/relay.db');
      try {
        return db.select('SELECT COUNT(*) AS n FROM queue WHERE recipient = ?',
            [empfaenger]).first['n'] as int;
      } finally {
        db.dispose();
      }
    }

    test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
      expect(relay, isNotNull,
          reason: 'relay_server.py liess sich nicht starten. '
              'py -3 -m pip install -r secure-messenger/server/requirements.txt');
    });

    test('DER NACHWEIS GEHT ERST NACH DEM SPEICHERN HINAUS', () async {
      // DER EINE TEST, der die Reihenfolge wirklich prueft. Alle anderen
      // blieben gruen, wenn der Nachweis zu frueh ginge — der Relay loeschte
      // dann seine Zeile, waehrend die App noch gar nichts geschrieben hat,
      // und beim naechsten Absturz waere die Nachricht weg.
      final alice = Nutzer('alice', pfad('alice'), relay!.uri);
      addTearDown(alice.aufraeumen);
      await alice.starten();
      await alice.core.createIdentity();

      // Der Verlauf wird im Augenblick des Nachweises abgefragt.
      //
      // getMessages ist zwar als Future deklariert, hat aber vor dem Lesen
      // kein einziges await — der Rumpf laeuft also synchron durch, und das
      // zurueckgegebene Future traegt den Stand GENAU DIESES AUGENBLICKS.
      // Wer dort spaeter ein await davorsetzt, macht diesen Test blind; dann
      // muss er neu gebaut werden.
      Future<List<Message>>? standBeimNachweis;
      late RealMessengerCore bobKern;

      bobKern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: pfad('bob'),
        relayUri: relay!.uri,
        relayFactory: (uri, id) => NachweisSpitzel(
          baseUri: uri,
          identity: id,
          beiNachweis: (_) =>
              standBeimNachweis ??= bobKern.getMessages(alice.core.myId),
        ),
      );
      addTearDown(bobKern.dispose);
      await bobKern.initialize();
      await bobKern.createIdentity();

      // Erst eine gewoehnliche Unterhaltung, damit es eine Sitzung gibt.
      await _beideVerbinden(alice, bobKern);

      // DEN MERKER ZURUECKSETZEN, sonst misst dieser Test den falschen
      // Nachweis.
      //
      // Seit dem 27.07.2026 puffert der Relay AUCH live weitergereichte
      // Nachrichten (sonst war eine live zugestellte Nachricht bei einem
      // Leitungsabriss endgueltig weg). Damit erzeugt schon der
      // Sitzungsaufbau oben einen Nachweis, und `??=` haette dessen Stand
      // festgehalten — einen Moment, in dem es die Nachricht unten noch gar
      // nicht gab.
      standBeimNachweis = null;

      // Jetzt geht Bob offline — nur dann bekommt die Nachricht eine Zeile in
      // der Warteschlange und damit ueberhaupt eine Kennung.
      await bobKern.disconnect();
      await alice.core.sendMessage(bobKern.myId, 'aus der Warteschlange');
      expect(await Nutzer.warteBis(() => offeneZeilen(bobKern.myId) == 1),
          isTrue,
          reason: 'die Nachricht wurde gar nicht erst gepuffert');

      await bobKern.connect();
      expect(await Nutzer.warteBis(() => standBeimNachweis != null), isTrue,
          reason: 'es ging ueberhaupt kein Nachweis hinaus');

      final schonDa = await standBeimNachweis!;
      expect(schonDa.map((m) => m.text), contains('aus der Warteschlange'),
          reason: 'der Nachweis ging hinaus, BEVOR die Nachricht auf der '
              'Platte stand — der Verlust waere damit nur von der Leitung in '
              'die App verschoben');

      // Und die Wirkung: der Relay hat die Zeile daraufhin geloescht.
      expect(await Nutzer.warteBis(() => offeneZeilen(bobKern.myId) == 0),
          isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('eine zweite Zustellung landet nicht zweimal im Verlauf', () async {
      // Die Kehrseite des Nachweises: Wiederholungen werden vom Ausnahmefall
      // zum Normalfall. Das traegt nur, solange sie den Nutzer nicht
      // behelligen — sonst waere aus einem stillen Verlust ein lautes
      // Aergernis geworden.
      final alice = Nutzer('alice', pfad('alice'), relay!.uri);
      addTearDown(alice.aufraeumen);
      await alice.starten();
      await alice.core.createIdentity();

      // Dieser Bob bestaetigt NIE — er stellt eine App nach, die zwischen dem
      // Speichern und dem Nachweis stirbt.
      final bobKern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: pfad('bob'),
        relayUri: relay!.uri,
        relayFactory: (uri, id) =>
            NachweisSpitzel(baseUri: uri, identity: id, stumm: true),
      );
      addTearDown(bobKern.dispose);
      await bobKern.initialize();
      await bobKern.createIdentity();

      final eingang = <Message>[];
      final abo = bobKern.incomingMessages.listen(eingang.add);
      addTearDown(abo.cancel);

      await _beideVerbinden(alice, bobKern);
      await bobKern.disconnect();

      // RELATIV MESSEN, nicht absolut.
      //
      // Seit dem 27.07.2026 puffert der Relay auch live weitergereichte
      // Nachrichten. Dieser Bob bestaetigt NIE — also bleibt schon vom
      // Sitzungsaufbau oben eine Zeile liegen, und eine feste 1 waere ab da
      // eine Aussage ueber den Aufbau statt ueber die Nachricht.
      final vorher = offeneZeilen(bobKern.myId);

      await alice.core.sendMessage(bobKern.myId, 'nur einmal bitte');
      expect(
          await Nutzer.warteBis(
              () => offeneZeilen(bobKern.myId) == vorher + 1),
          isTrue);

      await bobKern.connect();
      expect(await Nutzer.warteBis(() => eingang.length == 1), isTrue);
      expect(offeneZeilen(bobKern.myId), vorher + 1,
          reason: 'ohne Nachweis muss die Zeile liegen bleiben');

      // Und jetzt kommt sie ein zweites Mal.
      await bobKern.disconnect();
      await bobKern.connect();
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(eingang, hasLength(1),
          reason: 'die Wiederholung wurde ein zweites Mal gemeldet');
      final verlauf = await bobKern.getMessages(alice.core.myId);
      expect(verlauf.where((m) => m.text == 'nur einmal bitte'), hasLength(1),
          reason: 'die Wiederholung steht ein zweites Mal im Verlauf');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('scheitert das Speichern, geht KEIN Nachweis hinaus', () async {
      // Die andere Haelfte derselben Regel. Bestaetigt wird an jedem Punkt, an
      // dem die Verarbeitung dauerhaft geworden ist — und an keinem davor.
      // Wirft das Schreiben, bleibt die Zeile beim Relay liegen, und die
      // Nachricht kommt beim naechsten Verbinden wieder.
      final alice = Nutzer('alice', pfad('alice'), relay!.uri);
      addTearDown(alice.aufraeumen);
      await alice.starten();
      await alice.core.createIdentity();

      final spitzel = <NachweisSpitzel>[];
      final bobKern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: pfad('bob'),
        relayUri: relay!.uri,
        relayFactory: (uri, id) {
          final s = NachweisSpitzel(baseUri: uri, identity: id);
          spitzel.add(s);
          return s;
        },
      );
      addTearDown(bobKern.dispose);
      await bobKern.initialize();
      await bobKern.createIdentity();

      await _beideVerbinden(alice, bobKern);

      await bobKern.disconnect();
      await alice.core.sendMessage(bobKern.myId, 'das schlaegt fehl');
      expect(await Nutzer.warteBis(() => offeneZeilen(bobKern.myId) == 1),
          isTrue);

      // DAS SCHREIBEN KAPUTTMACHEN. Kein nachgebautes Repository: die Tabelle
      // wird wirklich weggenommen, der INSERT scheitert wirklich, und die
      // Transaktion rollt wirklich zurueck. Das ist der einzige Weg, an dieser
      // Stelle einen echten Schreibfehler zu bekommen.
      bobKern.datenbankFuerTest.raw.execute('DROP TABLE messages');

      // Der Fehler verlaesst _verarbeiteEingang, das per unawaited laeuft.
      // Ohne diese Zone waere er ein unbehandelter Fehler und riss den Test
      // um, statt gepruefft zu werden.
      final entwischt = <Object>[];
      await runZonedGuarded(() async {
        await bobKern.connect();
        await Nutzer.warteBis(() => entwischt.isNotEmpty,
            frist: const Duration(seconds: 10));
      }, (fehler, _) => entwischt.add(fehler));

      expect(entwischt, isNotEmpty,
          reason: 'das Speichern haette scheitern muessen');
      expect(spitzel.last.bestaetigt, isEmpty,
          reason: 'trotz gescheitertem Speichern ging ein Nachweis hinaus');
      // Und der Relay hat die Zeile folgerichtig behalten.
      expect(offeneZeilen(bobKern.myId), 1);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('ohne Netz', () {
    late Directory ordner;
    late RealMessengerCore kern;
    late NachweisDoppel doppel;

    setUp(() async {
      ordner = await Directory.systemTemp.createTemp('bitdm-nachweis-doppel');
      kern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
        relayFactory: (uri, id) => doppel = NachweisDoppel(id),
      );
      await kern.initialize();
      await kern.createIdentity();
      await kern.connect();
    });

    tearDown(() async {
      await kern.dispose();
      try {
        await ordner.delete(recursive: true);
      } catch (_) {}
    });

    /// Ein Umschlag, den niemand entschluesseln kann.
    RelayMessage muell({int? q}) => RelayMessage(
          from: 'a' * 56,
          ciphertext: Uint8List.fromList(List.filled(40, 7)),
          at: DateTime.now().toUtc(),
          q: q,
        );

    test('auch das Unlesbare wird bestaetigt', () async {
      // Der Sitzungsfortschritt ist an dieser Stelle festgeschrieben; ab da
      // laesst sich dieser Umschlag nie wieder entschluesseln. Ihn 14 Tage
      // lang bei jedem Verbinden erneut zu schicken hilft niemandem.
      doppel.liefere(muell(q: 8));
      expect(await Nutzer.warteBis(() => doppel.bestaetigt.isNotEmpty,
              frist: const Duration(seconds: 5)),
          isTrue,
          reason: 'ein unlesbarer Umschlag blieb unbestaetigt liegen');
      expect(doppel.bestaetigt, [8]);
    });

    test('kein Nachweis ohne Kennung', () async {
      // Live zugestellt, oder ein Relay, der den Nachweis gar nicht kennt. In
      // beiden Faellen gibt es keine Zeile, die man bestaetigen koennte — ein
      // Rahmen dafuer waere reine Luft auf der Leitung.
      doppel.liefere(muell());
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(doppel.bestaetigt, isEmpty);
    });
  });
}
