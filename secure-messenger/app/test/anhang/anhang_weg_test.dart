// anhang_weg_test.dart — der ganze Weg einer Datei und zurueck.
//
// Echte Datei, echter HTTP-Server, echte Verschluesselung. Nachgebaut ist nur
// der Relay — und zwar so, wie er sich WIRKLICH verhaelt: er unterschreibt
// dieselbe Marke, die blob_server.py prueft, mit demselben HMAC ueber
// "kennung|groesse|ablauf". Weicht das Format je auseinander, faellt es hier
// auf und nicht erst auf dem Telefon.
//
// Was hier gepruefte Eigenschaften sind, statt bloss "es laeuft durch":
//
//   * Eine Datei kommt BYTEGLEICH wieder an.
//   * Ein VERTAUSCHTES Stueck fliegt auf.
//   * Ein VERAENDERTES Byte fliegt auf.
//   * Ein Abbruch hinterlaesst keine halbe Datei, die ganz aussieht.
//   * Verschluesseln und Hochladen laufen INEINANDER, nicht nacheinander.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:bitdm/core/anhang/anhang_empfang.dart';
import 'package:bitdm/core/anhang/anhang_versand.dart';
import 'package:bitdm/core/anhang/lager_client.dart';
import 'package:bitdm/core/anhang/rezept.dart';
import 'package:bitdm/core/anhang/stueck_krypto.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

const geheimnis = 'testgeheimnis-testgeheimnis-testgeheimnis-48z';

/// Ein Lager, das sich wie blob_server.py hinter nginx verhaelt — inklusive
/// der Markenpruefung. Genau die ist die Stelle, an der beide Seiten
/// uebereinstimmen muessen.
class EchtesLager {
  EchtesLager._(this._server);
  final HttpServer _server;
  final bloecke = <String, Uint8List>{};
  final abgelehnt = <String>[];

  /// Macht das Ablegen kuenstlich langsam. Nur fuer die Messung, ob
  /// Verschluesseln und Hochladen ineinander laufen — bei einem Upload ueber
  /// die Schleife ist der Unterschied sonst nicht zu sehen.
  Duration? bremseBeimAblegen;

  static Future<EchtesLager> starte() async =>
      EchtesLager._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
        .._lausche();

  Uri get basis => Uri.parse('http://127.0.0.1:${_server.port}');

  /// Dieselbe Rechnung wie marke_gueltig() in blob_server.py.
  ///
  /// Ueber package:cryptography und NICHT ueber package:crypto: letzteres ist
  /// nur transitiv da, und ein Test, der an einer Abhaengigkeit haengt, die
  /// niemand angefordert hat, faellt beim naechsten Aufraeumen um.
  static Future<String> marke(String kennung, int groesse, int ablauf) async {
    final ergebnis = await Hmac.sha256().calculateMac(
        utf8.encode('$kennung|$groesse|$ablauf'),
        secretKey: SecretKey(utf8.encode(geheimnis)));
    return ergebnis.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  void _lausche() {
    _server.listen((a) async {
      final teile = a.uri.pathSegments;
      final k = teile.length > 1 ? teile[1] : '';
      switch (teile.isEmpty ? '' : teile.first) {
        case 'ablegen':
          final groesse = int.parse(a.headers.value('X-Bitdm-Size')!);
          final ablauf = int.parse(a.headers.value('X-Bitdm-Expires')!);
          final gegeben = a.headers.value('X-Bitdm-Token')!;
          if (gegeben != await marke(k, groesse, ablauf)) {
            // Genau das, was der echte Dienst tut: 403, und nichts liegt da.
            abgelehnt.add(k);
            a.response.statusCode = 403;
            break;
          }
          final bytes = <int>[];
          await for (final s in a) {
            bytes.addAll(s);
          }
          if (bytes.length != groesse) {
            a.response.statusCode = 400;
            break;
          }
          if (bremseBeimAblegen != null) {
            await Future<void>.delayed(bremseBeimAblegen!);
          }
          bloecke[k] = Uint8List.fromList(bytes);
          a.response.write('{"ok":true}');

        case 'blob':
          final da = bloecke[k];
          if (da == null) {
            a.response.statusCode = 404;
            break;
          }
          final bereich = a.headers.value(HttpHeaders.rangeHeader);
          var ab = 0;
          if (bereich != null) {
            ab = int.parse(
                RegExp(r'bytes=(\d+)-').firstMatch(bereich)!.group(1)!);
            a.response.statusCode = 206;
          }
          a.response.add(Uint8List.sublistView(da, ab));

        case 'wegwerfen':
          bloecke.remove(k);
          a.response.write('{"ok":true}');

        default:
          a.response.statusCode = 404;
      }
      await a.response.close();
    });
  }

  Future<void> stoppe() => _server.close(force: true);
}

/// Ein Relay, der nur eines kann: Marken ausstellen — mit demselben HMAC wie
/// der echte.
class MarkenRelay implements RelayClient {
  MarkenRelay({this.tagesmenge = 10 * 1024 * 1024 * 1024});

  final int tagesmenge;
  var verbraucht = 0;
  final ausgestellt = <String>[];

  /// Wann welche Marke geholt wurde — daran laesst sich ablesen, ob
  /// Verschluesseln und Hochladen ineinander laufen.
  final zeitpunkte = <int>[];

  final _uhr = Stopwatch()..start();

  @override
  Future<BlobMarke> holeMarke(String kennung, int groesse) async {
    if (verbraucht + groesse > tagesmenge) {
      throw const RelayException('Tagesmenge erschoepft');
    }
    verbraucht += groesse;
    ausgestellt.add(kennung);
    zeitpunkte.add(_uhr.elapsedMicroseconds);
    final ablauf = 4102444800; // weit in der Zukunft
    return BlobMarke(
      kennung: kennung,
      groesse: groesse,
      ablauf: ablauf,
      marke: await EchtesLager.marke(kennung, groesse, ablauf),
    );
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

Future<File> dateiMit(Directory ordner, int bytes, {String name = 'p.bin'}) async {
  final zufall = Random(42);
  final f = File('${ordner.path}${Platform.pathSeparator}$name');
  final s = f.openWrite();
  const block = 65536;
  for (var g = 0; g < bytes; g += block) {
    final n = min(block, bytes - g);
    s.add(Uint8List.fromList(List.generate(n, (_) => zufall.nextInt(256))));
  }
  await s.close();
  return f;
}

void main() {
  late Directory ordner;
  late EchtesLager lager;
  late LagerClient client;
  late MarkenRelay relay;
  late AnhangVersand versand;
  late AnhangEmpfang empfang;

  // Kleine Stuecke, damit ueberhaupt mehrere entstehen. Die Groesse ist eine
  // Einstellung und keine Eigenschaft — was hier zaehlt, ist das Verhalten
  // bei MEHREREN Stuecken.
  const stueckGroesse = 64 * 1024;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-anhang');
    lager = await EchtesLager.starte();
    client = LagerClient(basis: lager.basis);
    relay = MarkenRelay();
    versand = AnhangVersand(
        relay: relay,
        lager: client,
        zufall: Random.secure(),
        stueckGroesse: stueckGroesse);
    empfang = AnhangEmpfang(lager: client);
  });

  tearDown(() async {
    client.schliesse();
    await lager.stoppe();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  group('DER GANZE WEG', () {
    test('eine Datei kommt bytegleich wieder an', () async {
      final quelle = await dateiMit(ordner, 200000, name: 'urlaub.zip');
      final vorher = await quelle.readAsBytes();

      final rezept = await versand.schicke(quelle);

      expect(rezept.name, 'urlaub.zip');
      expect(rezept.gesamtGroesse, 200000);
      expect(rezept.stuecke, hasLength(4));
      expect(lager.bloecke, hasLength(4));

      // Die Anleitung reist als Text — also auch durch das Lesen und
      // Schreiben, das der echte Weg macht.
      final gelesen = Rezept.ausText(rezept.alsText());

      final ziel = File('${ordner.path}${Platform.pathSeparator}zurueck.zip');
      await empfang.hole(gelesen, ziel);

      expect(await ziel.readAsBytes(), vorher);

      // UND ES BLEIBT NICHTS LIEGEN. Geschrieben wird in eine Nebendatei und
      // erst am Ende umbenannt; bliebe sie stehen, laege jeder empfangene
      // Anhang doppelt auf dem Telefon — bei drei Gigabyte fuellt das den
      // Speicher, ohne dass irgendwo etwas davon zu sehen waere.
      expect(await File('${ziel.path}.teil').exists(), isFalse);
    });

    test('nach dem Empfang ist das Lager wieder leer', () async {
      final quelle = await dateiMit(ordner, 100000);
      final rezept = await versand.schicke(quelle);
      expect(lager.bloecke, isNotEmpty);

      await empfang.hole(rezept,
          File('${ordner.path}${Platform.pathSeparator}z.bin'));

      // Wegwerfen laeuft ohne Warten — kurz Zeit lassen.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(lager.bloecke, isEmpty,
          reason: 'was abgeholt ist, hat im Lager nichts mehr verloren');
    });

    test('eine Datei, die genau ein Stueck fuellt', () async {
      // Randfall: kein Rest. Ein Stueck zu wenig oder eines zu viel faellt bei
      // krummen Groessen nicht auf.
      final quelle = await dateiMit(ordner, stueckGroesse);
      final rezept = await versand.schicke(quelle);
      expect(rezept.stuecke, hasLength(1));

      final ziel = File('${ordner.path}${Platform.pathSeparator}z.bin');
      await empfang.hole(rezept, ziel);
      expect(await ziel.length(), stueckGroesse);
    });

    test('eine winzige Datei', () async {
      final quelle = await dateiMit(ordner, 1);
      final rezept = await versand.schicke(quelle);
      expect(rezept.stuecke, hasLength(1));
      final ziel = File('${ordner.path}${Platform.pathSeparator}z.bin');
      await empfang.hole(rezept, ziel);
      expect(await ziel.readAsBytes(), await quelle.readAsBytes());
    });

    test('DIE MARKE GILT FUER DIE GROESSE IM LAGER, nicht fuer die im Klartext',
        () async {
      // Der teuerste denkbare Fehler: die Marke fuer die Klargroesse holen.
      // Das Lager lehnt dann mit 403 ab — nach der Uebertragung.
      final quelle = await dateiMit(ordner, 100000);
      await versand.schicke(quelle);

      expect(lager.abgelehnt, isEmpty);
      for (final k in lager.bloecke.keys) {
        expect(lager.bloecke[k]!.length % stueckGroesse, isNot(0),
            reason: 'jeder Block traegt 16 Byte Beglaubigung mehr');
      }
    });
  });

  group('Was der Server anrichten koennte', () {
    late Rezept rezept;
    late File ziel;

    setUp(() async {
      rezept = await versand.schicke(await dateiMit(ordner, 200000));
      ziel = File('${ordner.path}${Platform.pathSeparator}z.bin');
    });

    test('ZWEI STUECKE VERTAUSCHT — fliegt auf', () async {
      // Faelschen kann das Lager nicht, jedes Stueck ist beglaubigt. Aber es
      // koennte unter der Kennung von Stueck 1 die Bytes von Stueck 3
      // ausliefern. Ohne die Nummer im beglaubigten Zusatz wuerde das sauber
      // entschluesseln und still die falsche Datei ergeben.
      final k = rezept.stuecke.map((s) => s.kennung).toList();
      final hilf = lager.bloecke[k[0]]!;
      lager.bloecke[k[0]] = lager.bloecke[k[2]]!;
      lager.bloecke[k[2]] = hilf;

      await expectLater(
          empfang.hole(rezept, ziel), throwsA(isA<AnhangKaputt>()));
      expect(await ziel.exists(), isFalse);
    });

    test('EIN VERAENDERTES BYTE — fliegt auf', () async {
      final k = rezept.stuecke.first.kennung;
      lager.bloecke[k]![100] ^= 1;

      await expectLater(
          empfang.hole(rezept, ziel), throwsA(isA<AnhangKaputt>()));
    });

    test('EINE FALSCHE PRUEFSUMME faengt, was sonst niemand sieht', () async {
      // Der einzige Fall, in dem die Summe ueber die ganze Datei etwas
      // beitraegt: jedes Stueck fuer sich ist einwandfrei, an der richtigen
      // Stelle und beglaubigt — und die Datei ist trotzdem nicht die, die
      // gemeint war. Ein fehlerhafter Absender koennte das schicken.
      final falsch = Rezept(
        name: rezept.name,
        gesamtGroesse: rezept.gesamtGroesse,
        pruefsumme: Uint8List.fromList(rezept.pruefsumme)..[0] ^= 1,
        stuecke: rezept.stuecke,
      );

      await expectLater(
          empfang.hole(falsch, ziel), throwsA(isA<AnhangKaputt>()));
      expect(await ziel.exists(), isFalse);
      expect(await File('${ziel.path}.teil').exists(), isFalse,
          reason: 'auch die Nebendatei muss weg sein');
    });

    test('EIN FEHLER SAGT, WELCHES STUECK', () async {
      // Bei einer Datei aus 192 Stuecken ist "mehr Daten als angekuendigt"
      // keine brauchbare Meldung. Geprueft wird deshalb genau das: dass die
      // Nummer dabeisteht.
      //
      // Der Fehler entsteht hier ueber eine Anleitung, die fuer Stueck 3 eine
      // andere Groesse nennt als im Lager liegt — der Download nagelt die
      // Groesse fest und lehnt ab.
      final s = rezept.stuecke[2];
      final verdreht = Rezept(
        name: rezept.name,
        gesamtGroesse: rezept.gesamtGroesse,
        pruefsumme: rezept.pruefsumme,
        stuecke: [
          ...rezept.stuecke.take(2),
          Stueck(
              kennung: s.kennung,
              schluessel: s.schluessel,
              nonce: s.nonce,
              klarGroesse: s.klarGroesse - 10),
          ...rezept.stuecke.skip(3),
        ],
      );

      await expectLater(
          empfang.hole(verdreht, ziel),
          throwsA(isA<AnhangKaputt>()
              .having((e) => e.grund, 'Grund', contains('Stueck 3'))));
    });

    test('ein Stueck fehlt', () async {
      lager.bloecke.remove(rezept.stuecke[1].kennung);
      await expectLater(empfang.hole(rezept, ziel),
          throwsA(isA<LagerLeer>()));
    });

    test('KEINE HALBE DATEI BLEIBT LIEGEN', () async {
      // Bricht der Empfang ab, darf nichts uebrig sein, das ganz aussieht.
      lager.bloecke.remove(rezept.stuecke[2].kennung);
      await expectLater(empfang.hole(rezept, ziel), throwsA(anything));

      expect(await ziel.exists(), isFalse,
          reason: 'die fertige Datei darf es nie gegeben haben');
    });
  });

  group('Wenn der Relay nicht mitspielt', () {
    test('erschoepfte Tagesmenge bricht ab, statt endlos zu versuchen',
        () async {
      final knapp = MarkenRelay(tagesmenge: 100000);
      final v = AnhangVersand(
          relay: knapp, lager: client, stueckGroesse: stueckGroesse);

      await expectLater(v.schicke(await dateiMit(ordner, 500000)),
          throwsA(isA<RelayException>()));
    });

    test('EINE GEFAELSCHTE MARKE WIRD VOM LAGER ABGELEHNT', () async {
      // Der Nachweis, dass die Markenpruefung ueberhaupt greift — sonst
      // koennten alle anderen Tests gruen sein, waehrend jeder beliebige
      // Upload durchginge.
      final marke = Marke(
          kennung: AnhangVersand.neueKennung(Random.secure()),
          groesse: 10,
          ablauf: 4102444800,
          marke: 'f' * 64);

      await expectLater(client.lege(marke, Uint8List(10)),
          throwsA(isA<LagerException>().having((e) => e.status, 'status', 403)));
    });
  });

  group('Grenzen', () {
    test('eine leere Datei geht nicht', () async {
      final leer = File('${ordner.path}${Platform.pathSeparator}leer.bin');
      await leer.writeAsBytes([]);
      await expectLater(
          versand.schicke(leer), throwsA(isA<AnhangZuGross>()));
    });

    test('zu viele Stuecke faellt VOR der Uebertragung auf', () async {
      // Wer eines Tages die Stueckgroesse verkleinert, soll es hier merken —
      // und nicht daran, dass der letzte Umschlag beim Relay abprallt,
      // nachdem alles hochgeladen ist.
      final winzig = AnhangVersand(
          relay: relay, lager: client, stueckGroesse: 100);
      await expectLater(
          winzig.schicke(await dateiMit(ordner, 100 * 300)),
          throwsA(isA<StateError>()));
      expect(lager.bloecke, isEmpty);
    });
  });

  group('VERSCHLUESSELN UND HOCHLADEN LAUFEN INEINANDER', () {
    test('vier Stuecke brauchen weniger als vier volle Runden', () async {
      // BEIDE Seiten muessen kuenstlich langsam sein, sonst ist nichts zu
      // sehen: ueber die Schleife dauert ein Upload wenige Millisekunden, und
      // dann kostet fehlende Verschraenkung fast nichts. Mit je 100 ms:
      //
      //   nacheinander:  4 x (100 + 100)          = 800 ms
      //   ineinander:    100 + 4 x max(100, 100)  = 500 ms
      //
      // Der erste Durchgang laesst sich nicht verschraenken — es gibt noch
      // nichts, womit. Deshalb 100 ms Vorlauf in der zweiten Zeile.
      const bremse = Duration(milliseconds: 100);
      lager.bremseBeimAblegen = bremse;
      final langsam = AnhangVersand(
        relay: relay,
        lager: client,
        krypto: const LangsamesKrypto(bremse),
        stueckGroesse: stueckGroesse,
      );

      final uhr = Stopwatch()..start();
      await langsam.schicke(await dateiMit(ordner, 4 * stueckGroesse));
      uhr.stop();

      expect(relay.ausgestellt, hasLength(4));
      expect(uhr.elapsedMilliseconds, lessThan(700),
          reason: 'gemessen: ${uhr.elapsedMilliseconds} ms — nacheinander '
              'waeren es rund 800 ms, ineinander rund 500');
      // Und die untere Schranke: schneller als 500 ms KANN es nicht sein.
      // Waere es das, misst der Test etwas anderes als gedacht — zum
      // Beispiel eine Bremse, die gar nicht greift.
      expect(uhr.elapsedMilliseconds, greaterThan(400),
          reason: 'unter 500 ms kann es nicht gehen; dann bremst etwas nicht');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('Ein Name von draussen', () {
    test('ein Pfad wird zu einem Namen', () {
      expect(AnhangEmpfang.sichererName('../../shared_prefs/x.xml'),
          isNot(contains('/')));
      expect(AnhangEmpfang.sichererName('../../etc/passwd'),
          isNot(startsWith('.')));
    });

    test('was nichts uebrig laesst, bekommt einen Ersatznamen', () {
      for (final roh in ['...', '/', '///', '..']) {
        final n = AnhangEmpfang.sichererName(roh);
        expect(n, isNotEmpty, reason: 'bei "$roh"');
        expect(n, isNot(contains('..')), reason: 'bei "$roh"');
      }
    });

    test('ein harmloser Name bleibt, wie er ist', () {
      expect(AnhangEmpfang.sichererName('Urlaub_2026-07.zip'),
          'Urlaub_2026-07.zip');
    });

    test('ein absurd langer Name wird gekuerzt', () {
      expect(AnhangEmpfang.sichererName('x' * 500).length, lessThan(200));
    });
  });
}

/// Eine Verschluesselung mit eingebauter Bremse — nur fuer die Messung oben.
class LangsamesKrypto extends StueckKrypto {
  const LangsamesKrypto(this.dauer);
  final Duration dauer;

  static const _echt = GcmStueckKrypto();

  @override
  Future<Uint8List> verschluessle({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) async {
    await Future<void>.delayed(dauer);
    return _echt.verschluessle(
        klar: klar,
        schluessel: schluessel,
        nonce: nonce,
        nummer: nummer,
        vonWievielen: vonWievielen);
  }

  @override
  Future<Uint8List> entschluessle({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) =>
      _echt.entschluessle(
          geheim: geheim,
          schluessel: schluessel,
          nonce: nonce,
          nummer: nummer,
          vonWievielen: vonWievielen);
}
