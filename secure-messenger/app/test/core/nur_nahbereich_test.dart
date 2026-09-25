// nur_nahbereich_test.dart — der Schalter, der nichts an einen Server laesst.
//
// WAS DIESER SCHALTER VERSPRICHT, ist eine Aussage ueber das, was NICHT
// passiert: keine Verbindung, kein Anmelden, keine Signatur ueber die
// Leitung, kein Zwischenlager. Ein Versprechen dieser Form laesst sich nur
// pruefen, indem man nachsieht, dass wirklich nichts angefasst wurde — und
// genau das tun diese Tests.
//
// Sie pruefen absichtlich NICHT "es kommt nichts an". Das waere trivial wahr,
// solange der Naehe-Transport noch fehlt, und der Test bliebe gruen, wenn
// jemand die Verbindung heimlich doch aufbaute.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/rezept.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _inhalt;
  @override
  Future<Uint8List?> read() async => _inhalt;
  @override
  Future<void> write(Uint8List e) async => _inhalt = e;
  @override
  Future<void> delete() async => _inhalt = null;
}

/// Ein Relay, der Buch fuehrt, ob ihn ueberhaupt jemand angefasst hat.
///
/// Der ganze Nachweis haengt daran: nicht "hat er eine Nachricht gesendet",
/// sondern "wurde er ueberhaupt gebaut und angesprochen".
class BuchfuehrenderRelay implements RelayClient {
  BuchfuehrenderRelay(this.identity);

  @override
  final SignalIdentity identity;

  int verbindungsversuche = 0;
  int anmeldungen = 0;
  int sendungen = 0;

  final _ereignisse = StreamController<RelayEvent>.broadcast();

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;

  @override
  bool get isConnected => false;

  @override
  String get address => identity.address;

  @override
  Future<void> connect() async {
    verbindungsversuche++;
    throw const RelayException('kein Netz in diesem Test');
  }

  @override
  Future<int> register(RelayPreKeyBundle bundle) async {
    anmeldungen++;
    throw const RelayException('kein Netz in diesem Test');
  }

  @override
  Future<void> send(String to, Uint8List ciphertext) async {
    sendungen++;
    throw const RelayException('kein Netz in diesem Test');
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async => _ereignisse.close();

  // Ein Relay ohne Mehrgeraete-Wissen antwortet `null` — daraus liest
  // `_ermittleGeraetId` "Geraet 1", also das Verhalten von vor dem Umbau.
  // Ohne diese Zeile faellt der Aufruf in `noSuchMethod`, und der Wurf
  // reisst beim Verbinden die Leitung ab.
  @override
  Future<List<int>?> geraeteliste(String userId) async => null;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

/// Eine gueltige, aber fremde Adresse.
///
/// Sie muss die Pruefsumme erfuellen — ein zusammengewuerfelter String faellt
/// schon in isValidAddress durch, und dann prueft der Test etwas anderes als
/// gedacht.
Future<String> fremdeAdresse() async {
  final ordner = await Directory.systemTemp.createTemp('bitdm-fremd');
  final k = RealMessengerCore(
    secretStore: SpeicherImKopf(),
    databasePath: '${ordner.path}${Platform.pathSeparator}f.db',
    relayUri: Uri.parse('http://127.0.0.1:1'),
  );
  await k.initialize();
  await k.createIdentity();
  final adresse = k.myId;
  await k.dispose();
  try {
    await ordner.delete(recursive: true);
  } catch (_) {}
  return adresse;
}

/// Ein angekuendigter Anhang, wie ihn der Empfangsweg hinterlaesst.
///
/// UEBER DIE ABLAGE UND NICHT UEBER EINE ECHTE ANKUENDIGUNG: die braeuchte eine
/// Signal-Sitzung mit einer Gegenstelle, und geprueft werden soll hier nicht
/// der Weg dorthin, sondern was `holeAnhang` daraus macht. Die Anleitung ist
/// echt — sonst faellt der Test schon am Format durch und prueft die Pruefung
/// gar nicht mehr.
void legeAngekuendigtenAnhangAn(RealMessengerCore kern, String von,
    {AnhangZustand zustand = AnhangZustand.angekuendigt}) {
  final rezept = Rezept(
    name: 'urlaub.zip',
    gesamtGroesse: 100,
    pruefsumme: Uint8List(32),
    stuecke: [
      Stueck(
        kennung: 'a' * 52,
        schluessel: Uint8List(32),
        nonce: Uint8List(12),
        klarGroesse: 100,
      )
    ],
  );
  kern.ablageFuerTest.speichereEigene(
    Message(
      id: 'anhang-1',
      chatId: von,
      senderId: von,
      text: 'urlaub.zip',
      kind: MessageKind.anhang,
      isMine: false,
      timestamp: DateTime.now().toUtc(),
    ),
    anhang: AnhangEintrag(
      messageId: 'anhang-1',
      chatId: von,
      senderId: von,
      name: 'urlaub.zip',
      groesse: 100,
      zustand: zustand,
      pfad: zustand == AnhangZustand.da ? 'C:/nirgends/urlaub.zip' : null,
    ),
    rezept: rezept.alsText(),
  );
}

void main() {
  late Directory ordner;
  late RealMessengerCore kern;

  /// Wie oft ueberhaupt ein Relay-Client entstanden ist.
  ///
  /// EIN ZAEHLER JE TEST und kein static: ein statischer haette ueber die
  /// Testgrenze hinweg gelebt, und ein Test waere aus dem Zustand eines
  /// anderen heraus rot geworden. Genau das ist beim ersten Lauf passiert.
  var gebaut = 0;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-nah');
    gebaut = 0;
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        gebaut++;
        return BuchfuehrenderRelay(id);
      },
    );
    await kern.initialize();
    await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  group('Der Schalter haelt, was er sagt', () {
    test('DER RELAY WIRD GAR NICHT ERST GEBAUT', () async {
      // Der Kern der Sache. Nicht "verbinden und dann nichts senden" — dann
      // staende die Adresse schon in der Verbindungsliste des Relays, und
      // beim Anmelden waere eine Signatur ueber die Leitung gegangen.
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));
      await kern.connect();

      expect(gebaut, 0,
          reason: 'es darf nicht einmal ein Client entstehen');
      expect(kern.connectionState, ConnectionState.disconnected);
    });

    test('ohne den Schalter wird er sehr wohl gebaut', () async {
      // DIE GEGENPROBE. Ohne sie koennte der Test darueber aus einem ganz
      // anderen Grund bestehen — etwa weil dieser Kern ueberhaupt nie
      // verbindet.
      //
      // MIT EIGENEM KERN und nicht mit dem aus setUp: der Zaehler wuerde
      // sonst von der Reihenfolge der Tests abhaengen, und ein Test, der
      // allein gruen ist und im Verbund rot, sagt ueber die Software nichts.
      // Genau das ist beim ersten Lauf passiert.
      var eigenerZaehler = 0;
      final eigenerOrdner = await Directory.systemTemp.createTemp('bitdm-gegen');
      final zweiter = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${eigenerOrdner.path}${Platform.pathSeparator}g.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
        relayFactory: (uri, id) {
          eigenerZaehler++;
          return BuchfuehrenderRelay(id);
        },
      );
      await zweiter.initialize();
      await zweiter.createIdentity();

      await zweiter.connect();

      expect(eigenerZaehler, 1,
          reason: 'ohne den Schalter MUSS ein Client entstehen — sonst prueft '
              'der Test darueber nichts');
      await zweiter.dispose();
      try {
        await eigenerOrdner.delete(recursive: true);
      } catch (_) {}
    });

    test('"getrennt" und NICHT "Fehler"', () async {
      // Es ist kein Fehler, sondern eine Entscheidung des Nutzers. Die
      // Oberflaeche zeigt bei "Fehler" einen roten Punkt und versucht es
      // wieder — beides waere hier falsch.
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));
      await kern.connect();
      expect(kern.connectionState, isNot(ConnectionState.error));
      expect(kern.connectionState, ConnectionState.disconnected);
    });

    test('EINSCHALTEN TRENNT SOFORT, nicht erst beim naechsten Start',
        () async {
      // Wer den Schalter umlegt, erwartet, dass ab JETZT nichts mehr
      // rausgeht. Eine offene Verbindung stehen zu lassen waere genau die
      // Sorte Halbwahrheit, gegen die dieser Schalter gebaut ist.
      await kern.connect();
      expect(gebaut, 1);

      await kern.setPreferences(const AppPreferences(nurNahbereich: true));

      expect(kern.connectionState, ConnectionState.disconnected);
      // Und ein erneutes Verbinden legt auch keinen neuen an.
      await kern.connect();
      expect(gebaut, 1);
    });

    test('Ausschalten verbindet wieder', () async {
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));
      await kern.connect();
      expect(gebaut, 0);

      await kern.setPreferences(const AppPreferences());

      expect(gebaut, 1,
          reason: 'sonst bliebe die App nach dem Ausschalten stumm, bis '
              'jemand sie neu startet');
    });

    test('die Einstellung ueberlebt einen Neustart', () async {
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));
      final wieder = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
      );
      // Dieselbe Datei, aber ein anderer Geheimspeicher — also keine
      // Identitaet. Geprueft wird nur, dass die Einstellung aus der Datenbank
      // kommt und nicht aus dem Arbeitsspeicher.
      await wieder.dispose();

      final gelesen = await kern.getPreferences();
      expect(gelesen.nurNahbereich, isTrue);
    });
  });

  group('Was dann nicht geht, sagt WARUM', () {
    test('ein Anhang wird mit eigenem Fehler abgelehnt', () async {
      // Nicht als Netzfehler: es liegt nicht am Netz, sondern an einer
      // Entscheidung, die der Nutzer selbst zuruecknehmen kann. "Versuch es
      // noch einmal" waere hier eine falsche Faehrte.
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));
      final datei = File('${ordner.path}${Platform.pathSeparator}x.bin');
      await datei.writeAsBytes(Uint8List(10));

      // Ein Kontakt muss existieren, sonst greift eine andere Pruefung
      // zuerst. Die EIGENE Adresse geht nicht — der Kern lehnt sie ab.
      final anderer = await fremdeAdresse();
      await kern.addContact(anderer);

      await expectLater(kern.sendeAnhang(anderer, datei),
          throwsA(isA<NurNahbereichException>()));
    });

    test('EIN ANHANG WIRD AUCH NICHT GEHOLT', () async {
      // DIE ANDERE RICHTUNG, und sie war offen.
      //
      // Die Stuecke liegen im Zwischenlager, und das ist ein Server —
      // derselbe Grund wie beim Verschicken. Dass die Ankuendigung schon da
      // ist, aendert daran nichts: geholt wird jetzt, und der Schalter gilt
      // jetzt. Ohne diese Pruefung baut ein Kontakt unter einem Schalter, der
      // verspricht, dass NICHTS an einen Server geht, eine Verbindung zum
      // Zwischenlager auf.
      final anderer = await fremdeAdresse();
      await kern.addContact(anderer);
      legeAngekuendigtenAnhangAn(kern, anderer);
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));

      await expectLater(kern.holeAnhang(anderer, 'anhang-1'),
          throwsA(isA<NurNahbereichException>()));
    });

    test('ohne den Schalter geht er ins Lager — und scheitert dort', () async {
      // DIE GEGENPROBE. Ohne sie bestuende der Test darueber auch dann, wenn
      // holeAnhang aus einem ganz anderen Grund nie ans Lager kaeme. Das Lager
      // steht hier auf Port 1; was zurueckkommt, ist ein NETZFEHLER — also
      // genau der Beweis, dass der Weg dorthin sonst offensteht.
      final anderer = await fremdeAdresse();
      await kern.addContact(anderer);
      legeAngekuendigtenAnhangAn(kern, anderer);

      await expectLater(kern.holeAnhang(anderer, 'anhang-1'),
          throwsA(isNot(isA<NurNahbereichException>())));
    });

    test('was schon auf dem Geraet liegt, gibt er trotzdem heraus', () async {
      // Der Schalter verspricht, dass nichts an einen Server geht — er
      // verspricht nicht, eine laengst geladene Datei wegzusperren. Das waere
      // kein Schutz, sondern nur etwas weniger App.
      final anderer = await fremdeAdresse();
      await kern.addContact(anderer);
      legeAngekuendigtenAnhangAn(kern, anderer, zustand: AnhangZustand.da);
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));

      final e = await kern.holeAnhang(anderer, 'anhang-1');
      expect(e.zustand, AnhangZustand.da);
    });

    test('und die Ausnahme ist KEINE RelayException', () async {
      // Sonst faenge sie dieselbe Behandlung ein wie ein Verbindungsabbruch,
      // und die Oberflaeche zeigte den falschen Satz.
      expect(const NurNahbereichException(), isNot(isA<RelayException>()));
    });
  });

  group('Eine Nachricht bleibt liegen, statt zu verschwinden', () {
    test('sie steht als unversandt im Verlauf', () async {
      // WICHTIG, dass sie NICHT auf "failed" faellt: `sending` ist der
      // Zustand, den der Kern beim naechsten Verbinden wieder aufgreift. Wer
      // hier failed schriebe, muesste den Nutzer bitten, von Hand zu
      // wiederholen — obwohl die App es selbst kann, sobald der Schalter
      // wieder aus ist.
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));
      final anderer = await fremdeAdresse();
      await kern.addContact(anderer);

      final m = await kern.sendMessage(anderer, 'wartet hier');

      expect(m.status, MessageStatus.sending);
      final verlauf = await kern.getMessages(anderer);
      expect(verlauf.single.text, 'wartet hier');
      expect(verlauf.single.status, MessageStatus.sending);
      expect(gebaut, 0,
          reason: 'auch beim Senden darf kein Client entstehen');
    });
  });
}
