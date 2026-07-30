// krypto_vektoren.dart — Pruefvektoren aus der Dart-Fassung erzeugen.
//
// WOFUER
// Der native AES-Kanal muss BITGLEICH zur Dart-Fassung rechnen. Sonst kann
// die eine Seite nicht lesen, was die andere geschrieben hat — und weil
// beide Seiten in verschiedenen Sprachen laufen, faellt das erst auf einem
// echten Geraet auf, in einer Lage, in der niemand mehr einen Debugger hat.
//
// Deshalb: hier ausrechnen, was die Dart-Fassung liefert, und daraus einen
// JVM-Test in Kotlin erzeugen. Der laeuft mit `gradlew :app:testDebugUnitTest`
// und braucht kein Telefon — javax.crypto gibt es auf der JVM genauso wie auf
// Android.
//
// DAS IST DIE ANTWORT AUF "wie prueft man nativen Code?". Nicht "auf dem
// Geraet ausprobieren", sondern: feste Ein- und Ausgaben, beide Seiten
// dagegen.
//
//   flutter test tool/krypto_vektoren.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/stueck_krypto.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List folge(int n, int saat) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 37 + saat * 101) & 0xFF));

void main() {
  test('Vektoren erzeugen', () async {
    const krypto = GcmStueckKrypto();

    // Faelle, die etwas Verschiedenes pruefen:
    //   leer        — geht ueberhaupt eine Nutzlast von 0 Byte?
    //   1           — kuerzer als ein Block
    //   16          — genau ein Block
    //   17          — ein Block plus Rest
    //   1000        — mehrere Bloecke
    //   65536       — gross genug, dass eine Blockschleife auffaellt
    // und je Fall eine andere Stuecknummer, damit der AAD wirklich eingeht.
    final faelle = <int>[0, 1, 16, 17, 1000, 65536];

    final zeilen = <String>[];
    for (var i = 0; i < faelle.length; i++) {
      final n = faelle[i];
      final klar = folge(n, i + 1);
      final schluessel = folge(32, i + 7);
      final nonce = folge(12, i + 13);
      final nummer = i;
      final zahl = faelle.length;

      final geheim = await krypto.verschluessle(
        klar: klar,
        schluessel: schluessel,
        nonce: nonce,
        nummer: nummer,
        vonWievielen: zahl,
      );

      // Gegenprobe im selben Atemzug: was hier rauskommt, muss auch wieder
      // reingehen. Ein Vektor, der nur in eine Richtung stimmt, ist keiner.
      final zurueck = await krypto.entschluessle(
        geheim: geheim,
        schluessel: schluessel,
        nonce: nonce,
        nummer: nummer,
        vonWievielen: zahl,
      );
      expect(zurueck, klar, reason: 'Fall $n');

      zeilen.add('    Vektor(\n'
          '      klar = "${hex(klar)}",\n'
          '      schluessel = "${hex(schluessel)}",\n'
          '      nonce = "${hex(nonce)}",\n'
          '      nummer = $nummer,\n'
          '      zahl = $zahl,\n'
          '      geheim = "${hex(geheim)}",\n'
          '    ),');

      stdout.writeln('$n Byte -> ${geheim.length} Byte '
          '(Aufschlag ${geheim.length - n})');
    }

    // Und der AAD selbst, damit die Kotlin-Seite ihn nicht nachbauen muss.
    final aad = StueckKrypto.zusatz(3, 6);
    stdout.writeln('AAD fuer 3/6: ${utf8.decode(aad)}  (${hex(aad)})');

    final ziel = File('android/app/src/test/kotlin/com/bitdm/bitdm/Vektoren.kt');
    await ziel.parent.create(recursive: true);
    await ziel.writeAsString('''
// Vektoren.kt — ERZEUGT, nicht von Hand geschrieben.
//
// Quelle: app/tool/krypto_vektoren.dart, ausgerechnet mit der Dart-Fassung
// (package:cryptography, AesGcm.with256bits). Wer diese Datei von Hand
// aendert, verliert genau die Eigenschaft, wegen der es sie gibt.
//
// Neu erzeugen:  flutter test tool/krypto_vektoren.dart

package com.bitdm.bitdm

data class Vektor(
    val klar: String,
    val schluessel: String,
    val nonce: String,
    val nummer: Int,
    val zahl: Int,
    val geheim: String,
)

/** Was die Dart-Fassung fuer diese Eingaben liefert. */
val VEKTOREN = listOf(
${zeilen.join('\n')}
)
''');
    stdout.writeln('geschrieben: ${ziel.path}');
  });
}
