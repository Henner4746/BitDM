// anhang_tempo_test.dart — wie schnell verschluesselt das ECHTE Geraet?
//
// Laeuft NICHT auf dem Entwicklungsrechner, sondern auf dem Telefon:
//
//     flutter test integration_test/anhang_tempo_test.dart -d <geraet>
//
// WOFUER DAS DA IST
// Auf dem Entwicklungsrechner schafft die reine Dart-Umsetzung von AES-GCM
// rund 12 MB/s (gemessen 25.07.2026, 8 MiB in 662 ms). Daraus wurde die
// Entscheidung abgeleitet, Verschluesseln und Hochladen zu verschraenken
// statt eine native Bibliothek einzubinden. Diese Entscheidung haengt an
// einer Zahl vom FALSCHEN Rechner — ein Telefon ist kein Desktop, in beide
// Richtungen.
//
// Der Test behauptet keine Mindestgeschwindigkeit. Er MISST, und die Zahl
// steht in der Ausgabe. Eine Schranke waere hier falsch: sie wuerde auf einem
// langsamen Geraet rot, ohne dass etwas kaputt ist.

import 'dart:typed_data';

import 'package:bitdm/core/anhang/anhang_versand.dart';
import 'package:bitdm/core/anhang/stueck_krypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('AES-GCM auf diesem Geraet', () async {
    const krypto = GcmStueckKrypto();
    final schluessel = Uint8List(32);
    final nonce = Uint8List(12);
    final klar = Uint8List(8 * 1024 * 1024);

    // Einmal warmlaufen: der erste Aufruf zahlt das Aufsetzen mit.
    await krypto.verschluessle(
        klar: Uint8List(65536),
        schluessel: schluessel,
        nonce: nonce,
        nummer: 0,
        vonWievielen: 1);

    final uhr = Stopwatch()..start();
    final geheim = await krypto.verschluessle(
        klar: klar,
        schluessel: schluessel,
        nonce: nonce,
        nummer: 0,
        vonWievielen: 1);
    uhr.stop();
    final hoch = 8000 / uhr.elapsedMilliseconds;

    final uhr2 = Stopwatch()..start();
    await krypto.entschluessle(
        geheim: geheim,
        schluessel: schluessel,
        nonce: nonce,
        nummer: 0,
        vonWievielen: 1);
    uhr2.stop();
    final runter = 8000 / uhr2.elapsedMilliseconds;

    // ignore: avoid_print
    print('GEMESSEN verschluesseln: ${hoch.toStringAsFixed(1)} MB/s '
        '(8 MiB in ${uhr.elapsedMilliseconds} ms)');
    // ignore: avoid_print
    print('GEMESSEN entschluesseln: ${runter.toStringAsFixed(1)} MB/s '
        '(8 MiB in ${uhr2.elapsedMilliseconds} ms)');

    // Was das fuer die Stueckgroesse heisst: ein 16-MiB-Stueck braucht so
    // lange, und genau diese Zeit muss die Uebertragung des vorigen Stuecks
    // ueberdecken.
    final jeStueck = AnhangVersand.standardStueckGroesse / 1024 / 1024 / hoch;
    // ignore: avoid_print
    print('=> ein 16-MiB-Stueck: ${jeStueck.toStringAsFixed(1)} s');
    // ignore: avoid_print
    print('=> 3 GiB am Stueck:   '
        '${(3 * 1024 / hoch / 60).toStringAsFixed(1)} min reine Rechenzeit');

    expect(hoch, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
