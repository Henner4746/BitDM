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
import 'package:bitdm/core/anhang/native_krypto.dart';
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
    print('=> ein 32-MiB-Stueck: ${jeStueck.toStringAsFixed(1)} s');
    // ignore: avoid_print
    print('=> 5 GiB am Stueck:   '
        '${(5 * 1024 / hoch / 60).toStringAsFixed(1)} min reine Rechenzeit');

    expect(hoch, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ═══════════════════════════════════════════════════════════════════════
  //
  // SEIT 26.07.2026: derselbe Vorgang ueber den nativen Kanal.
  //
  // Die Zahl oben war der Grund, AES aus Dart herauszunehmen. Hier steht,
  // was es gebracht hat — auf DIESEM Geraet, nicht auf einem Desktop und
  // nicht auf einer JVM. Beide Messungen rechnen dasselbe mit denselben
  // Eingaben; der einzige Unterschied ist, wer rechnet.

  test('AES-GCM nativ gegen Dart, auf diesem Geraet', () async {
    final schluessel =
        Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xFF));
    final nonce = Uint8List.fromList(List.generate(12, (i) => i));
    final klar = Uint8List(AnhangVersand.standardStueckGroesse);
    for (var i = 0; i < klar.length; i += 997) {
      klar[i] = i & 0xFF;
    }
    final mib = klar.length / (1024 * 1024);

    Future<(int, Uint8List)> miss(StueckKrypto k) async {
      // Warmlaufen, dann messen.
      await k.verschluessle(
          klar: Uint8List(65536),
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);
      final u = Stopwatch()..start();
      final aus = await k.verschluessle(
          klar: klar,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);
      u.stop();
      return (u.elapsedMilliseconds, aus);
    }

    final nativ = NativeStueckKrypto();
    final (msNativ, ausNativ) = await miss(nativ);
    final (msDart, ausDart) = await miss(const GcmStueckKrypto());

    // DIE WICHTIGSTE ZEILE DIESES TESTS. Schneller zu sein nuetzt nichts,
    // wenn dabei etwas anderes herauskommt — dann kann die Gegenseite es
    // nicht lesen. Die JVM-Vektoren zeigen dasselbe; hier steht es fuer die
    // Hardware, auf der es wirklich laeuft.
    expect(ausNativ, ausDart,
        reason: 'nativ und Dart muessen bitgleich rechnen');

    String tempo(int ms) => (mib * 1000 / ms).toStringAsFixed(1);
    // ignore: avoid_print
    print('TEMPO nativ:  $msNativ ms fuer ${mib.toStringAsFixed(0)} MiB '
        '= ${tempo(msNativ)} MB/s');
    // ignore: avoid_print
    print('TEMPO Dart:   $msDart ms = ${tempo(msDart)} MB/s');
    // ignore: avoid_print
    print('TEMPO Faktor: ${(msDart / msNativ).toStringAsFixed(1)}x');
    // ignore: avoid_print
    print('TEMPO 5 GiB:  nativ '
        '${(5 * 1024 * msNativ / mib / 1000 / 60).toStringAsFixed(1)} min, '
        'in Dart ${(5 * 1024 * msDart / mib / 1000 / 60).toStringAsFixed(1)} min');
    // ignore: avoid_print
    print('TEMPO Rueckfall: ${nativ.imRueckfall ?? "nein, laeuft nativ"}');
    // ignore: avoid_print
    print('TEMPO Anbieter: ${nativ.anbieter}');
    expect(nativ.anbieter, isNot('BC'),
        reason: 'BouncyCastle waere reines Java — bitgleich, aber zwanzigmal '
            'langsamer, und kein anderer Test wuerde davon rot');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
