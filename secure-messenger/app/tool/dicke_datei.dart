// dicke_datei.dart — eine wirklich grosse Datei durch den ganzen Weg schicken.
//
// WOFUER
// Bei Anhaengen faellt alles Interessante erst bei Groesse auf: Zaehler, die
// ueberlaufen, Speicher, der nicht freigegeben wird, Fortschrittsanzeigen, die
// ueber hundert Prozent gehen, Grenzen, die an vier Stellen verschieden sind.
// Mit einer 3-KB-Datei laeuft alles davon durch, ohne etwas zu beweisen.
//
// GEGEN DEN SERVER AUF DIESEM RECHNER, nicht gegen den echten. Fuenf Gigabyte
// ueber eine Hausleitung hochzuladen dauert eine Stunde und beweist nichts,
// was localhost nicht auch beweist — die Stueckelung, die Verschluesselung,
// die Buchfuehrung ueber 160 Stuecke und das Wiederzusammensetzen sind
// dieselben.
//
// Was localhost NICHT beweist: dass eine Uebertragung ueber eine echte,
// wackelige Leitung durchhaelt. Dafuer ist das Fortsetzen ueber Bereichs-
// Anfragen gebaut, und das hat einen eigenen Test.
//
//   1. server/tools/testaufbau.py starten
//   2. flutter test tool/dicke_datei.dart --dart-define=GROESSE_GB=5
//
// Ohne GROESSE_GB laeuft er mit 1 GB — gross genug, dass die Zahlen etwas
// heissen, klein genug fuer zwischendurch.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/anhang_empfang.dart';
import 'package:bitdm/core/anhang/anhang_versand.dart';
import 'package:bitdm/core/anhang/lager_client.dart';
import 'package:bitdm/core/anhang/rezept.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

class ImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

void sag(String s) => stdout.writeln(s);

String mb(int b) => '${(b / (1024 * 1024)).toStringAsFixed(1)} MiB';
String gb(int b) => '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';

/// Legt eine Datei der gewuenschten Groesse an, ohne sie im Speicher zu haben.
///
/// MIT WECHSELNDEM INHALT und nicht mit Nullen: eine Datei aus lauter Nullen
/// verschluesselt sich genauso schnell, aber ein Fehler beim Zusammensetzen —
/// zwei Stuecke vertauscht, eines doppelt — faellt bei lauter Nullen NICHT
/// auf. Der Vergleich am Ende waere dann wertlos.
Future<void> legeAn(File ziel, int groesse) async {
  const block = 8 * 1024 * 1024;
  final muster = Uint8List(block);
  for (var i = 0; i < block; i++) {
    muster[i] = (i * 31 + (i >> 11) * 7) & 0xFF;
  }
  final aus = ziel.openWrite();
  var geschrieben = 0;
  var runde = 0;
  while (geschrieben < groesse) {
    final rest = groesse - geschrieben;
    // Je Runde ein Byte veraendern, damit sich kein Block wiederholt.
    muster[0] = runde & 0xFF;
    muster[1] = (runde >> 8) & 0xFF;
    if (rest >= block) {
      aus.add(muster);
      geschrieben += block;
    } else {
      aus.add(Uint8List.sublistView(muster, 0, rest));
      geschrieben += rest;
    }
    runde++;
  }
  await aus.flush();
  await aus.close();
}

void main() {
  const gbText = String.fromEnvironment('GROESSE_GB', defaultValue: '1');
  final groesse = (double.parse(gbText) * 1024 * 1024 * 1024).round();

  test('eine dicke Datei durch den ganzen Weg', () async {
    final ordner = await Directory.systemTemp.createTemp('bitdm-dick');
    final quelle = File('${ordner.path}${Platform.pathSeparator}dick.bin');
    final kern = RealMessengerCore(
      secretStore: ImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}d.db',
      relayUri: Uri.parse('http://127.0.0.1:8080'),
      lagerUri: Uri.parse('http://127.0.0.1:8099'),
    );

    final uhr = Stopwatch()..start();
    try {
      sag('Grenze der App   ${gb(AnhangVersand.hoechstGroesse)}');
      sag('Stueckgroesse    ${mb(AnhangVersand.standardStueckGroesse)}');
      sag('Ziel             ${gb(groesse)}');
      final zahl = (groesse / AnhangVersand.standardStueckGroesse).ceil();
      sag('ergibt           $zahl Stuecke (erlaubt ${Rezept.hoechstStueckzahl})');
      sag('');

      sag('1) Datei anlegen ...');
      await legeAn(quelle, groesse);
      final wirklich = await quelle.length();
      expect(wirklich, groesse, reason: 'die Datei ist nicht so gross wie gedacht');
      sag('   ${gb(wirklich)} in ${uhr.elapsed.inSeconds} s');

      sag('2) verbinden ...');
      await kern.initialize();
      await kern.createIdentity();
      await kern.connect();
      expect(kern.connectionState, ConnectionState.online,
          reason: 'laeuft server/tools/testaufbau.py?');

      sag('3) verschluesseln und hochladen ...');
      final vorher = uhr.elapsed;
      var letzterStand = 0;
      final abo = kern.anhangFortschritt.listen((f) {
        final prozent = (f.fertigeBytes * 100 / f.gesamtBytes).floor();
        expect(prozent, lessThanOrEqualTo(100),
            reason: 'der Fortschritt darf nicht ueber hundert gehen');
        if (prozent >= letzterStand + 10) {
          letzterStand = prozent - prozent % 10;
          sag('   $letzterStand %  nach ${uhr.elapsed.inSeconds} s');
        }
      });

      final lager = LagerClient(basis: kern.lagerUri);
      final rezept = await AnhangVersand(
        relay: kern.relayFuerTest,
        lager: lager,
      ).schicke(quelle, name: 'dick.bin');
      await abo.cancel();

      final hoch = uhr.elapsed - vorher;
      sag('   fertig nach ${hoch.inSeconds} s '
          '(${(groesse / hoch.inMilliseconds * 1000 / (1024 * 1024)).toStringAsFixed(1)} MiB/s)');
      final anleitung = rezept.alsText().length;
      sag('   ${rezept.stuecke.length} Stuecke, Anleitung $anleitung Byte');
      expect(rezept.stuecke.length, zahl);
      expect(anleitung, lessThan(64 * 1024),
          reason: 'die Anleitung muss in einen Umschlag passen');

      sag('4) wieder herunterladen und vergleichen ...');
      final vorherRunter = uhr.elapsed;
      final ziel = File('${ordner.path}${Platform.pathSeparator}zurueck.bin');
      await AnhangEmpfang(lager: lager).hole(rezept, ziel);
      final runter = uhr.elapsed - vorherRunter;
      sag('   fertig nach ${runter.inSeconds} s');

      expect(await ziel.length(), groesse, reason: 'andere Groesse zurueck');
      expect(await gleich(quelle, ziel), isTrue,
          reason: 'der Inhalt ist unterwegs ein anderer geworden');
      sag('   INHALT STIMMT, Byte fuer Byte');

      sag('');
      sag('DURCHSTICH GESCHAFFT in ${uhr.elapsed.inSeconds} s');
    } finally {
      await kern.dispose();
      try {
        await ordner.delete(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}

/// Vergleicht zwei Dateien, ohne eine davon ganz in den Speicher zu holen.
///
/// Blockweise ueber RandomAccessFile statt ueber Streams: ein Stream laesst
/// sich nicht Stueck fuer Stueck gegen einen zweiten fuehren, ohne beide zu
/// puffern — und bei fuenf Gigabyte ist genau das der Fehler, den dieser Test
/// finden soll.
Future<bool> gleich(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  final ra = await a.open(), rb = await b.open();
  try {
    const block = 8 * 1024 * 1024;
    while (true) {
      final pa = await ra.read(block);
      final pb = await rb.read(block);
      if (pa.isEmpty) return pb.isEmpty;
      if (pa.length != pb.length) return false;
      for (var i = 0; i < pa.length; i++) {
        if (pa[i] != pb[i]) return false;
      }
    }
  } finally {
    await ra.close();
    await rb.close();
  }
}
