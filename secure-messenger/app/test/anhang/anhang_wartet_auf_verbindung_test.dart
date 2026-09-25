// anhang_wartet_auf_verbindung_test.dart — der Wettlauf mit der Dateiauswahl.
//
// WAS AM 26.07.2026 PASSIERT IST
// Anhaenge scheiterten auf dem Telefon mit "nicht verbunden", waehrend der
// Verbindungstest unmittelbar daneben alles gruen meldete — den ganzen Weg ins
// Zwischenlager eingeschlossen. Der Grund ist die Dateiauswahl selbst: sie
// gehoert Android und legt sich VOR die App. BitDM zaehlt damit als weggelegt,
// trennt die Verbindung und schaltet auf Hintergrundempfang. Kommt der Nutzer
// mit seiner Datei zurueck, laeuft der Wiederaufbau noch — rund eine Sekunde.
// Der Versand griff in genau diese Luecke.
//
// Wer eine Datei auswaehlte, sorgte damit selbst dafuer, dass sie nicht
// abgeschickt werden konnte. Und weil "nicht verbunden" auf denselben Satz
// abgebildet wurde wie ein Netzfehler, stand danach "Check the connection and
// try again" auf einem Bildschirm, dessen Verbindung in Ordnung war.
//
// Diese Tests halten fest: der Versand WARTET, statt abzubrechen — und bricht
// trotzdem ab, wenn es wirklich keine Verbindung gibt.

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

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

/// Ein Relay, der erst nach einer Weile bereit ist — so wie einer, der gerade
/// wieder aufgebaut wird.
class LangsamerRelay implements RelayClient {
  LangsamerRelay(this.identity, {required this.brauchtZeit});

  @override
  final SignalIdentity identity;

  /// Wie lange connect() braucht, bis isConnected wahr wird. Null heisst: nie.
  final Duration? brauchtZeit;

  bool _verbunden = false;
  int verbindungsversuche = 0;
  int markenAnfragen = 0;

  final _ereignisse = StreamController<RelayEvent>.broadcast();

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;
  @override
  bool get isConnected => _verbunden;
  @override
  String get address => identity.address;

  @override
  Future<void> connect() async {
    verbindungsversuche++;
    final z = brauchtZeit;
    if (z == null) throw const RelayException('kein Netz');
    await Future<void>.delayed(z);
    _verbunden = true;
  }

  @override
  Future<int> register(RelayPreKeyBundle b) async => 100;

  @override
  Future<BlobMarke> holeMarke(String kennung, int groesse) async {
    markenAnfragen++;
    if (!_verbunden) throw const RelayException('nicht verbunden');
    // Weiter kommt der Test nicht — das Lager gibt es hier nicht. Entscheidend
    // ist ALLEIN, ob ueberhaupt bis hierher gefragt wurde.
    throw const RelayException('bis hierher und nicht weiter');
  }

  @override
  Future<void> send(String to, Uint8List c) async {}
  @override
  Future<void> close() async => _verbunden = false;
  @override
  Future<void> dispose() async {
    _verbunden = false;
    await _ereignisse.close();
  }

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
Future<String> fremdeAdresse() async {
  final o = await Directory.systemTemp.createTemp('bitdm-fremd');
  final k = RealMessengerCore(
    secretStore: SpeicherImKopf(),
    databasePath: '${o.path}${Platform.pathSeparator}f.db',
    relayUri: Uri.parse('http://127.0.0.1:1'),
  );
  await k.initialize();
  await k.createIdentity();
  final a = k.myId;
  await k.dispose();
  try {
    await o.delete(recursive: true);
  } catch (_) {}
  return a;
}

void main() {
  late Directory ordner;
  late File datei;
  late String anderer;

  setUpAll(() async {
    anderer = await fremdeAdresse();
  });

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-warte');
    datei = File('${ordner.path}${Platform.pathSeparator}probe.bin');
    await datei.writeAsBytes(Uint8List(2048));
  });

  tearDown(() async {
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  /// DIE LISTE UND KEIN `late`: der Relay entsteht erst beim ersten
  /// Verbindungsversuch. Ein `late relay` waere zu dem Zeitpunkt, an dem
  /// dieser Helfer zurueckkehrt, noch nicht zugewiesen — und der Test
  /// scheiterte an sich selbst statt an der Sache.
  Future<(RealMessengerCore, List<LangsamerRelay>)> kernMit(
      Duration? zeit) async {
    final gebaut = <LangsamerRelay>[];
    final kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = LangsamerRelay(id, brauchtZeit: zeit);
        gebaut.add(r);
        return r;
      },
    );
    await kern.initialize();
    await kern.createIdentity();
    await kern.addContact(anderer);
    return (kern, gebaut);
  }

  test('DER VERSAND WARTET, bis die Verbindung wieder steht', () async {
    // Der Fall aus der Dateiauswahl: die Verbindung kommt gleich, nur nicht
    // sofort. Vorher brach der Versand in dieser Luecke ab.
    final (kern, _) = await kernMit(const Duration(milliseconds: 600));

    // NICHT verbinden — genau wie nach der Rueckkehr aus dem Dialog.
    await expectLater(
      kern.sendeAnhang(anderer, datei),
      throwsA(predicate((e) =>
          e is RelayException && e.grund == 'bis hierher und nicht weiter')),
      reason: 'der Versand muss bis zur Marke gekommen sein, nicht vorher '
          'an "nicht verbunden" scheitern',
    );

    await kern.dispose();
  });

  test('und stoesst den Aufbau selbst an', () async {
    final (kern, gebaut) = await kernMit(const Duration(milliseconds: 300));
    try {
      await kern.sendeAnhang(anderer, datei);
    } catch (_) {}
    expect(gebaut.single.verbindungsversuche, greaterThan(0),
        reason: 'nur zu warten reicht nicht — es muss auch jemand verbinden');
    await kern.dispose();
  });

  test('OHNE NETZ bricht er trotzdem ab, statt ewig zu haengen', () async {
    // Die Gegenprobe. Ein Versand, der bei fehlendem Netz endlos wartet, waere
    // schlimmer als einer, der abbricht: der Nutzer sieht einen Fortschritt,
    // hinter dem nichts passiert.
    final (kern, gebaut) = await kernMit(null);

    final uhr = Stopwatch()..start();
    await expectLater(
      kern.sendeAnhang(anderer, datei),
      throwsA(isA<RelayException>()),
    );
    uhr.stop();

    expect(uhr.elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'ein Fehlschlag beim Verbinden muss sofort durchschlagen und '
            'nicht die volle Wartezeit absitzen');
    expect(gebaut.isEmpty ? 0 : gebaut.single.markenAnfragen, 0,
        reason: 'ohne Verbindung darf gar keine Marke angefragt werden');
    await kern.dispose();
  });

  test('bei "nur in der Naehe" wird gar nicht erst gewartet', () async {
    // Sonst saesse der Nutzer fuenfzehn Sekunden vor einer Wartezeit, deren
    // Ausgang von Anfang an feststeht.
    final (kern, gebaut) = await kernMit(const Duration(milliseconds: 300));
    await kern.setPreferences(const AppPreferences(nurNahbereich: true));

    final uhr = Stopwatch()..start();
    await expectLater(
      kern.sendeAnhang(anderer, datei),
      throwsA(isA<NurNahbereichException>()),
    );
    uhr.stop();

    expect(uhr.elapsed, lessThan(const Duration(seconds: 1)));
    expect(gebaut, isEmpty);
    await kern.dispose();
  });
}
