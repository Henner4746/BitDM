// krypto_tempo.dart — wie schnell BitDM ueberhaupt verschluesseln kann.
//
// WOFUER
// Ueber die Naehe gibt es kein Zwischenlager und damit keine Servergrenze:
// zwei Telefone koennen sich schicken, was auf die Platte passt. Was dann
// bleibt, ist Zeit — und die haengt an einer einzigen Zahl, naemlich wie
// viele Megabyte je Sekunde durch AES-GCM gehen.
//
// Wi-Fi Direct schafft auf heutigen Geraeten 20 bis 60 MB/s. Ist die
// Verschluesselung langsamer, ist SIE die Grenze und nicht der Funk — und
// dann nuetzt jede Verbesserung am Transport nichts.
//
//   flutter test tool/krypto_tempo.dart
//
// DIESE ZAHL GILT FUER DIESEN RECHNER. Auf dem Telefon ist sie kleiner; die
// letzte Messung dort lag bei 5 bis 8 MB/s. Der Vergleich beider Zahlen sagt,
// wie viel ein Wechsel auf nativen Code brächte.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/stueck_krypto.dart';
import 'package:flutter_test/flutter_test.dart';

void sag(String s) => stdout.writeln(s);

void main() {
  test('AES-256-GCM: wie viel geht durch', () async {
    const krypto = GcmStueckKrypto();
    final schluessel = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xFF));
    final nonce = Uint8List.fromList(List.generate(12, (i) => i));

    // Erst warmlaufen: der erste Durchlauf zahlt das Einrichten mit.
    await krypto.verschluessle(
        klar: Uint8List(1 << 20),
        schluessel: schluessel,
        nonce: nonce,
        nummer: 0,
        vonWievielen: 1);

    for (final mib in [4, 32]) {
      final klar = Uint8List(mib << 20);
      for (var i = 0; i < klar.length; i += 4096) {
        klar[i] = i & 0xFF;
      }

      final hin = Stopwatch()..start();
      final geheim = await krypto.verschluessle(
          klar: klar,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);
      hin.stop();

      final zurueck = Stopwatch()..start();
      final wieder = await krypto.entschluessle(
          geheim: geheim,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);
      zurueck.stop();

      expect(wieder.length, klar.length);

      String tempo(Stopwatch u) =>
          '${(mib * 1000 / u.elapsedMilliseconds).toStringAsFixed(1)} MB/s';
      sag('$mib MiB   zu: ${hin.elapsedMilliseconds} ms (${tempo(hin)})   '
          'auf: ${zurueck.elapsedMilliseconds} ms (${tempo(zurueck)})');

      // Was das fuer eine grosse Datei heisst.
      final proGb = 1024 * hin.elapsedMilliseconds / mib / 1000;
      sag('        macht ${proGb.toStringAsFixed(0)} s je GiB, '
          '${(proGb * 5 / 60).toStringAsFixed(1)} min fuer 5 GiB');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
