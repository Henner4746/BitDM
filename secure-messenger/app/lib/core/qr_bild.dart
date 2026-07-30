// qr_bild.dart — einen ECHTEN QR-Code zeichnen.
//
// WAS HIER VORHER STAND, war keiner.
//
// In painters.dart lag ein `_QrPainter` mit dem Kommentar
// "25x25 fake-but-deterministic QR": drei Ecken wie bei einem QR-Code und
// dazwischen Rauschen aus einem Hash der Adresse. Ein Bild, das aussieht wie
// ein QR-Code und keines ist. Es stammt aus dem Entwurf, in dem die
// Oberflaeche ohne Daten gebaut wurde, und ist nie ersetzt worden.
//
// Die Folge war nicht "der Scanner ist ungenau", sondern: er konnte gar nichts
// finden, weil nichts da war. Der Bildschirm "Meine ID" sagte dabei
// ausdruecklich "Share it so someone can add you". Eine Oberflaeche, die zum
// Scannen auffordert und dabei ein Muster zeigt, ist schlimmer als eine ohne
// QR-Code: der Nutzer sucht den Fehler bei sich und seiner Kamera.
//
// WARUM zxing2 UND KEIN NEUES PAKET
// zxing2 steckt schon drin, weil der Leser es braucht — und es bringt den
// Kodierer gleich mit (`Encoder`, `QRCode`). Reines Dart, kein Google, kein
// MLKit. qr_flutter waere eine zweite Abhaengigkeit fuer dasselbe.
//
// FEHLERKORREKTUR M und nicht L: 15 statt 7 Prozent. Ein Bildschirm wird
// abfotografiert, oft schraeg, oft mit Spiegelungen darauf. Der Code wird
// dadurch etwa eine Version groesser, und das faellt bei 56 Zeichen nicht ins
// Gewicht.

import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

/// Zeichnet [inhalt] als QR-Code.
///
/// Bricht NICHT ab, wenn das Kodieren scheitert: dann bleibt die Flaeche leer
/// statt dass der ganze Bildschirm mit einem roten Kasten stehenbleibt. Der
/// Inhalt steht ohnehin darunter als Text.
class QrBild extends StatelessWidget {
  const QrBild(
    this.inhalt, {
    required this.vordergrund,
    required this.hintergrund,
    this.kante = 125,
    super.key,
  });

  final String inhalt;
  final Color vordergrund;
  final Color hintergrund;

  /// Kantenlaenge in logischen Punkten.
  final double kante;

  @override
  Widget build(BuildContext context) {
    final m = _matrix(inhalt);
    return SizedBox(
      width: kante,
      height: kante,
      child: m == null
          ? ColoredBox(color: hintergrund)
          : CustomPaint(painter: _QrMalen(m, vordergrund, hintergrund)),
    );
  }

  /// Der Code als quadratisches Feld aus true/false.
  ///
  /// Oeffentlich, damit ein Test ihn nachlesen und wieder dekodieren kann —
  /// das ist die einzige Pruefung, die wirklich etwas aussagt.
  static List<List<bool>>? matrixVon(String inhalt) => _matrix(inhalt);

  static List<List<bool>>? _matrix(String inhalt) {
    // Ein leerer Inhalt kommt beim Start vor, bevor die eigene Adresse
    // feststeht. zxing2 kodiert ihn klaglos zu einem Code, der nichts enthaelt
    // — angezeigt waere das ein QR-Code, der auf nichts zeigt.
    if (inhalt.isEmpty) return null;
    try {
      final code = Encoder.encode(inhalt, ErrorCorrectionLevel.m);
      final b = code.matrix;
      if (b == null) return null;
      return [
        for (var y = 0; y < b.height; y++)
          [for (var x = 0; x < b.width; x++) b.get(x, y) == 1]
      ];
    } catch (_) {
      return null;
    }
  }
}

class _QrMalen extends CustomPainter {
  _QrMalen(this.feld, this.vg, this.hg);

  final List<List<bool>> feld;
  final Color vg;
  final Color hg;

  @override
  void paint(Canvas canvas, Size size) {
    final n = feld.length;

    // DIE RUHEZONE GEHOERT DAZU. Die Norm verlangt vier Module Rand; ohne sie
    // finden viele Leser den Code nicht, wenn er direkt an dunklem Grund
    // anliegt — und der Hintergrund dieser App ist dunkel.
    const rand = 4;
    final gesamt = n + 2 * rand;

    // AUF GANZE BILDPUNKTE RUNDEN. Bei krummen Modulbreiten zieht die
    // Kantenglaettung graue Saeume zwischen die Module; ein Leser sieht dann
    // Zwischenwerte, wo er Schwarz oder Weiss erwartet.
    final modul = (size.width / gesamt).floorToDouble().clamp(1.0, size.width);
    final bild = modul * gesamt;
    final versatz = ((size.width - bild) / 2).floorToDouble();

    final farbe = Paint()..style = PaintingStyle.fill;

    farbe.color = hg;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), farbe);

    farbe.color = vg;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (!feld[y][x]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            versatz + (x + rand) * modul,
            versatz + (y + rand) * modul,
            modul,
            modul,
          ),
          farbe,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrMalen alt) =>
      alt.vg != vg || alt.hg != hg || !identical(alt.feld, feld);
}
