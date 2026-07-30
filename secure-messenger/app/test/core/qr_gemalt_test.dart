// qr_gemalt_test.dart — das GEMALTE Bild wieder einlesen.
//
// WARUM ES DIESEN TEST ZUSAETZLICH ZU qr_rundlauf_test.dart GIBT
// Jener prueft die Kette Kodierer -> Leser, malt das Zwischenbild aber selbst.
// Damit bleibt genau der Teil ungeprueft, den der Nutzer zu sehen bekommt: der
// CustomPainter. Ruhezone, Modulbreite, Farben und Rundung leben dort — und
// jede dieser vier Kleinigkeiten kann einen Code unlesbar machen, ohne dass
// irgendetwas anderes davon merkt.
//
// Aufgefallen ist die Luecke bei einem Mutationstest: `const rand = 4` im
// Maler auf 0 zu setzen — also die Ruhezone zu entfernen — liess alle Tests
// gruen. Genau das ist der haeufigste Grund, warum ein QR-Code auf einem
// Bildschirm nicht gelesen wird.
//
// Hier wird das Widget wirklich gezeichnet, als Bild ausgelesen und mit dem
// Leser der App wieder dekodiert.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bitdm/core/qr_bild.dart';
import 'package:bitdm/core/qr_leser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const adresse = 'muwlhp6gz5ctvhas35udstzqe3ilaay5gdceqgamn4whunuo55ji2cnf';

/// Zeichnet [kind] und gibt die Helligkeit je Bildpunkt zurueck.
Future<({Uint8List y, int breite, int hoehe})> malen(
  WidgetTester tester,
  Widget kind, {
  double pixelverhaeltnis = 1.0,
}) async {
  final schluessel = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        // DUNKLER GRUND wie in der App. Ohne ihn liegt der Code auf Weiss, und
        // eine fehlende Ruhezone faellt nicht auf — der weisse Grund
        // uebernimmt sie dann.
        backgroundColor: const Color(0xFF0B0B10),
        body: Center(
          child: RepaintBoundary(key: schluessel, child: kind),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final grenze = schluessel.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;

  // IN runAsync, sonst haengt der Test.
  //
  // Ein Widget-Test laeuft in einer kuenstlichen Zeit; toImage() und
  // toByteData() geben Futures zurueck, die von der ECHTEN Ereignisschleife
  // erfuellt werden. Ohne runAsync wartet der Test auf eine Uhr, die niemand
  // weiterstellt — er laeuft nicht in einen Fehler, sondern steht still, bis
  // die Zeitschranke greift.
  final rgba = (await tester.runAsync(() async {
    final bild = await grenze.toImage(pixelRatio: pixelverhaeltnis);
    final daten = await bild.toByteData(format: ui.ImageByteFormat.rawRgba);
    final b = (breite: bild.width, hoehe: bild.height,
        bytes: daten!.buffer.asUint8List());
    bild.dispose();
    return b;
  }))!;

  final y = Uint8List(rgba.breite * rgba.hoehe);
  for (var i = 0; i < y.length; i++) {
    final r = rgba.bytes[i * 4],
        g = rgba.bytes[i * 4 + 1],
        b = rgba.bytes[i * 4 + 2];
    // Uebliche Gewichtung nach Rec. 601 — genau das, was eine Kamera liefert.
    y[i] = ((r * 299 + g * 587 + b * 114) ~/ 1000).clamp(0, 255);
  }
  return (y: y, breite: rgba.breite, hoehe: rgba.hoehe);
}

void main() {
  final leser = QrLeser();

  Widget karte(double kante) => Container(
        color: const Color(0xFFF2F2F2),
        padding: const EdgeInsets.all(14),
        child: QrBild(
          adresse,
          vordergrund: const Color(0xFF0B0B10),
          hintergrund: const Color(0xFFF2F2F2),
          kante: kante,
        ),
      );

  group('Der gezeichnete Code ist lesbar', () {
    testWidgets('bei 220 Punkten Kantenlaenge, so wie in der App',
        (tester) async {
      final b = await malen(tester, karte(220));
      expect(leser.lies(b.y, b.breite, b.breite, b.hoehe), adresse);
    });

    testWidgets('auf einem Bildschirm mit dreifacher Punktdichte',
        (tester) async {
      // Auf dem Geraet wird nicht 1:1 gezeichnet. Bei krummen Modulbreiten
      // zieht die Kantenglaettung graue Saeume, und dann sieht der Leser
      // Zwischenwerte, wo er Schwarz oder Weiss braucht.
      final b = await malen(tester, karte(220), pixelverhaeltnis: 3.0);
      expect(leser.lies(b.y, b.breite, b.breite, b.hoehe), adresse);
    });

    testWidgets('auch klein, wie in einer Vorschau', (tester) async {
      final b = await malen(tester, karte(125), pixelverhaeltnis: 2.0);
      expect(leser.lies(b.y, b.breite, b.breite, b.hoehe), adresse);
    });
  });

  group('Das Widget allein, ohne Karte drumherum', () {
    // WICHTIG, WEIL DIE KARTE SONST DIE ARBEIT MACHT. In der App liegt der
    // Code in einem hellen Container mit 14 Punkten Innenabstand — der
    // liefert Ruhezone und hellen Grund gleich mit. Ein Mutationstest zeigte
    // deshalb: die Ruhezone IM WIDGET zu entfernen faellt nirgends auf.
    //
    // Verlassen darf man sich darauf nicht. Wer QrBild an einer zweiten
    // Stelle einsetzt, bekommt keine Karte geschenkt.
    testWidgets('bringt Ruhezone und Grund selbst mit', (tester) async {
      final b = await malen(
        tester,
        QrBild(adresse,
            vordergrund: const Color(0xFF0B0B10),
            hintergrund: const Color(0xFFF2F2F2),
            kante: 260),
        pixelverhaeltnis: 2.0,
      );
      expect(leser.lies(b.y, b.breite, b.breite, b.hoehe), adresse,
          reason: 'ohne Ruhezone oder ohne hellen Grund findet der Leser '
              'den Code auf dunklem Untergrund nicht');
    });
  });

  group('Woran es scheitern wuerde', () {
    testWidgets('OHNE DIE HELLE KARTE liest ihn niemand', (tester) async {
      // Die Gegenprobe zur Entscheidung im Bildschirm "Meine ID": dort bricht
      // eine einzige Flaeche mit dem dunklen Thema. Dieser Test zeigt, was
      // passiert, wenn jemand sie zurueckdreht.
      final b = await malen(
        tester,
        Container(
          color: const Color(0xFF14141C),
          padding: const EdgeInsets.all(14),
          child: QrBild(adresse,
              vordergrund: const Color(0xFFE8E8F0),
              hintergrund: const Color(0xFF14141C),
              kante: 220),
        ),
      );
      expect(leser.lies(b.y, b.breite, b.breite, b.hoehe), isNull);
    });

    testWidgets('leerer Inhalt zeigt eine leere Flaeche statt eines Absturzes',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: QrBild('',
                vordergrund: const Color(0xFF000000),
                hintergrund: const Color(0xFFFFFFFF),
                kante: 100),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
