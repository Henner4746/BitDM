// lager_client_test.dart — reden mit dem Zwischenlager.
//
// Gegen einen ECHTEN HttpServer, nicht gegen einen nachgebauten Client. Was
// hier schiefgehen kann, geht auf der Leitung schief: Kopfzeilen, Bereiche,
// abgeschnittene Antworten, Zeitgrenzen. Ein Nachbau der HTTP-Schicht wuerde
// genau die Stellen ueberspringen, an denen es klemmt.
//
// Der Server hier verhaelt sich wie blob_server.py hinter nginx — inklusive
// der Faelle, in denen er sich SCHLECHT verhaelt. Denn dass er sich gut
// verhaelt, ist eine Annahme und keine Zusicherung.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/lager_client.dart';
import 'package:flutter_test/flutter_test.dart';

const kennung =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; // 52

Uint8List zaehlend(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 13 + 5) % 251));

/// Ein Lager, das sich einstellen laesst.
class StubLager {
  StubLager._(this._server);
  final HttpServer _server;

  final aufrufe = <HttpRequest>[];
  final koerper = <String, List<int>>{};

  /// Was der Server ausliefern soll (Kennung -> Bytes).
  final inhalt = <String, Uint8List>{};

  /// Feste Antwort erzwingen.
  int? statusFuerPut;
  bool schneideAbNach = false;
  Duration? verzoegerung;
  bool schickeZuViel = false;

  static Future<StubLager> starte() async =>
      StubLager._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
        .._lausche();

  Uri get basis => Uri.parse('http://127.0.0.1:${_server.port}');

  void _lausche() {
    _server.listen((anfrage) async {
      aufrufe.add(anfrage);
      final teile = anfrage.uri.pathSegments;
      final k = teile.length > 1 ? teile[1] : '';

      if (verzoegerung != null) await Future<void>.delayed(verzoegerung!);

      switch ((anfrage.method, teile.isEmpty ? '' : teile.first)) {
        case ('PUT', 'ablegen'):
          final bytes = <int>[];
          await for (final s in anfrage) {
            bytes.addAll(s);
          }
          koerper[k] = bytes;
          if (statusFuerPut != null) {
            anfrage.response.statusCode = statusFuerPut!;
          } else {
            inhalt[k] = Uint8List.fromList(bytes);
            anfrage.response.write('{"ok":true}');
          }

        case ('GET', 'blob'):
          final da = inhalt[k];
          if (da == null) {
            anfrage.response.statusCode = 404;
            break;
          }
          final bereich = anfrage.headers.value(HttpHeaders.rangeHeader);
          var ab = 0;
          if (bereich != null) {
            ab = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(bereich)!.group(1)!);
            anfrage.response.statusCode = 206;
          }
          var raus = Uint8List.sublistView(da, ab);
          if (schneideAbNach) raus = Uint8List.sublistView(raus, 0, raus.length ~/ 2);
          anfrage.response.add(raus);
          if (schickeZuViel) anfrage.response.add(Uint8List(100));

        case ('DELETE', 'wegwerfen'):
          inhalt.remove(k);
          anfrage.response.write('{"ok":true}');

        default:
          anfrage.response.statusCode = 404;
      }
      await anfrage.response.close();
    });
  }

  Future<void> stoppe() => _server.close(force: true);
}

Marke marke(int groesse, {String k = kennung}) => Marke(
    kennung: k, groesse: groesse, ablauf: 9999999999, marke: 'x' * 64);

void main() {
  late StubLager lager;
  late LagerClient client;

  setUp(() async {
    lager = await StubLager.starte();
    client = LagerClient(
        basis: lager.basis, stille: const Duration(seconds: 3));
  });

  tearDown(() async {
    client.schliesse();
    await lager.stoppe();
  });

  group('Hochladen', () {
    test('die Bytes kommen an, unveraendert', () async {
      final geheim = zaehlend(300000);
      await client.lege(marke(geheim.length), geheim);
      expect(lager.koerper[kennung], geheim);
    });

    test('DIE DREI KOPFZEILEN GEHEN MIT', () async {
      // Ohne sie lehnt das Lager mit 403 ab — und zwar erst NACH der
      // Uebertragung. Bei drei Gigabyte ist das eine teure Art, einen
      // vergessenen Kopf zu bemerken.
      final geheim = zaehlend(100);
      await client.lege(
          Marke(kennung: kennung, groesse: 100, ablauf: 1234, marke: 'abc'),
          geheim);

      final a = lager.aufrufe.single;
      expect(a.headers.value('X-Bitdm-Size'), '100');
      expect(a.headers.value('X-Bitdm-Expires'), '1234');
      expect(a.headers.value('X-Bitdm-Token'), 'abc');
    });

    test('DIE ADRESSE KOMMT AUS DER EIGENEN EINSTELLUNG', () async {
      // Die Antwort des Relays enthaelt fertige Adressen. Sie werden nicht
      // benutzt — sonst koennte ein uebernommener Relay die Uploads auf einen
      // fremden Rechner umlenken.
      await client.lege(marke(10), zaehlend(10));
      expect(lager.aufrufe.single.uri.path, '/ablegen/$kennung');
      expect(lager.aufrufe.single.headers.host, '127.0.0.1');
    });

    test('eine falsche Groesse faellt SOFORT auf, nicht erst am Server',
        () async {
      // Ein Rechenfehler soll nicht erst nach der Uebertragung auffliegen.
      await expectLater(client.lege(marke(100), zaehlend(99)),
          throwsA(isA<LagerException>()));
      expect(lager.aufrufe, isEmpty, reason: 'es darf gar nichts losgehen');
    });

    test('kein Platz mehr ist ein EIGENER Fehler', () async {
      // Die Oberflaeche muss darauf etwas anderes sagen: spaeter noch einmal
      // hilft, sofort noch einmal nicht.
      lager.statusFuerPut = 507;
      await expectLater(
          client.lege(marke(10), zaehlend(10)), throwsA(isA<LagerVoll>()));
    });

    test('eine abgelehnte Marke wird gemeldet', () async {
      lager.statusFuerPut = 403;
      await expectLater(client.lege(marke(10), zaehlend(10)),
          throwsA(isA<LagerException>().having((e) => e.status, 'status', 403)));
    });

    test('der Fortschritt zaehlt bis zum Ende', () async {
      final gesehen = <int>[];
      final geheim = zaehlend(700000);
      await client.lege(marke(geheim.length), geheim,
          fortschritt: gesehen.add);
      expect(gesehen.last, geheim.length);
      expect(gesehen.length, greaterThan(1),
          reason: 'es soll waehrenddessen melden, nicht erst am Schluss');
    });
  });

  group('Herunterladen', () {
    test('holt, was hochgeladen wurde', () async {
      final geheim = zaehlend(50000);
      await client.lege(marke(geheim.length), geheim);
      expect(await client.hole(kennung, erwarteteGroesse: geheim.length),
          geheim);
    });

    test('FORTSETZEN nach einem Funkloch', () async {
      // Der Grund, warum nginx den Download direkt macht. Ohne
      // Bereichs-Anfragen faengt jedes Funkloch das Stueck von vorne an.
      final geheim = zaehlend(50000);
      await client.lege(marke(geheim.length), geheim);

      final rest = await client.hole(kennung,
          erwarteteGroesse: geheim.length, abByte: 20000);

      expect(rest.length, 30000);
      expect(rest, Uint8List.sublistView(geheim, 20000));
      expect(lager.aufrufe.last.headers.value(HttpHeaders.rangeHeader),
          'bytes=20000-');
    });

    test('was nicht da ist, ist ein EIGENER Fehler', () async {
      // Nach vierzehn Tagen ist es weg, und wenn der Empfaenger es schon
      // geholt hat, hat er es selbst weggeworfen. Beides ist kein Absturz.
      await expectLater(client.hole(kennung, erwarteteGroesse: 10),
          throwsA(isA<LagerLeer>()));
    });

    test('EINE ABGESCHNITTENE ANTWORT gilt nicht als fertig', () async {
      // Der gefaehrlichste Fall: die Verbindung bricht mittendrin ab, der
      // Server hat sauber geschlossen. Ohne diese Pruefung waere die Haelfte
      // eines Stuecks ein "erfolgreicher" Download — und die
      // Entschluesselung schluege erst danach fehl, ohne zu sagen warum.
      final geheim = zaehlend(50000);
      await client.lege(marke(geheim.length), geheim);
      lager.schneideAbNach = true;

      await expectLater(client.hole(kennung, erwarteteGroesse: geheim.length),
          throwsA(isA<LagerException>()));
    });

    test('MEHR DATEN ALS ANGEKUENDIGT laufen nicht in den Speicher', () async {
      // Ein boesartiges Lager koennte endlos senden. Der Platz wird vorher
      // reserviert, also endet das im Fehler und nicht im Absturz.
      final geheim = zaehlend(1000);
      await client.lege(marke(geheim.length), geheim);
      lager.schickeZuViel = true;

      await expectLater(client.hole(kennung, erwarteteGroesse: geheim.length),
          throwsA(isA<LagerException>()));
    });

    test('der Fortschritt zaehlt bis zum Ende', () async {
      final geheim = zaehlend(400000);
      await client.lege(marke(geheim.length), geheim);
      final gesehen = <int>[];
      await client.hole(kennung,
          erwarteteGroesse: geheim.length, fortschritt: gesehen.add);
      expect(gesehen.last, geheim.length);
    });
  });

  group('Wegwerfen', () {
    test('wirft weg', () async {
      await client.lege(marke(10), zaehlend(10));
      await client.wirfWeg(kennung);
      await expectLater(client.hole(kennung, erwarteteGroesse: 10),
          throwsA(isA<LagerLeer>()));
    });

    test('EIN FEHLER BEIM WEGWERFEN STOERT NICHT', () async {
      // Wegwerfen ist Aufraeumen, kein Arbeitsschritt. Ist es schon weg, ist
      // das Ziel erreicht; klemmt das Netz, holt es die Kehrmaschine nach.
      // Einen Empfang deshalb scheitern zu lassen waere das Gegenteil von
      // hilfreich.
      await lager.stoppe();
      await client.wirfWeg(kennung); // darf nicht werfen
    });
  });

  group('Wenn nichts mehr kommt', () {
    test('eine stehende Uebertragung bricht ab, statt zu haengen', () async {
      final schnell = LagerClient(
          basis: lager.basis, stille: const Duration(milliseconds: 300));
      lager.verzoegerung = const Duration(seconds: 5);

      await expectLater(schnell.lege(marke(10), zaehlend(10)),
          throwsA(isA<LagerException>()));
      schnell.schliesse();
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}
