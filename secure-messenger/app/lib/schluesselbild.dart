// schluesselbild.dart — ein Bild aus einem Schluessel (Randomart).
//
// WOZU. Eine Adresse aus 56 Zeichen vergleicht niemand Zeichen fuer Zeichen.
// Ein Bild schon: ein anderer Schluessel ergibt ein voellig anderes Muster,
// und das sieht man mit einem Blick. OpenSSH zeigt Serverschluessel seit 2008
// so an ("drunken bishop", Dirk Loss: The drunken bishop, 2009).
//
// DAS VERFAHREN. Aus dem Schluessel wird ein SHA-256 gebildet. Ein Laeufer
// startet in der Mitte eines 17x9-Feldes und zieht fuer jedes Bitpaar der 32
// Bytes (niederwertiges zuerst) diagonal: 00 nach links oben, 01 rechts oben,
// 10 links unten, 11 rechts unten. Am Rand bleibt er haengen. Gezaehlt wird,
// wie oft er jedes Feld betritt. Das Muster ist genau das von OpenSSH, nur
// gezeichnet statt als Zeichen gesetzt — als Punktmatrix wie die Schrift der
// App.
//
// HIER NICHT FUER DIE SICHERHEIT ERSETZT: die Pruefnummer bleibt der Weg, eine
// Verbindung zu bestaetigen. Das Bild ist eine Wiedererkennungshilfe — "ist das
// derselbe Schluessel wie letzte Woche?" — und kein Beweis.

import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

class Schluesselbild {
  static const breite = 17;
  static const hoehe = 9;

  /// Wie oft der Laeufer jedes Feld betreten hat, zeilenweise.
  /// Start und Ende sind als -1 (Start) und -2 (Ende) markiert.
  static List<int> felder(String schluessel) {
    final normal = schluessel.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final bytes = Sha256().toSync().hashSync(utf8.encode(normal)).bytes;
    final f = List<int>.filled(breite * hoehe, 0);
    var x = breite ~/ 2, y = hoehe ~/ 2;
    final start = y * breite + x;
    for (final b in bytes) {
      for (var i = 0; i < 4; i++) {
        final paar = (b >> (2 * i)) & 3;
        x = (x + ((paar & 1) == 1 ? 1 : -1)).clamp(0, breite - 1);
        y = (y + ((paar & 2) == 2 ? 1 : -1)).clamp(0, hoehe - 1);
        f[y * breite + x]++;
      }
    }
    final ende = y * breite + x;
    f[start] = -1;
    f[ende] = -2;
    return f;
  }

  /// Die Zeichen von OpenSSH — fuer Tests und fuer die Vorleseschrift.
  static String alsText(String schluessel) {
    const zeichen = ' .o+=*BOX@%&#/^';
    final f = felder(schluessel);
    final aus = StringBuffer();
    for (var y = 0; y < hoehe; y++) {
      for (var x = 0; x < breite; x++) {
        final v = f[y * breite + x];
        aus.write(v == -1 ? 'S' : v == -2 ? 'E' : zeichen[math.min(v, zeichen.length - 1)]);
      }
      if (y < hoehe - 1) aus.write('\n');
    }
    return aus.toString();
  }
}

/// Zeichnet das Schluesselbild als Punktmatrix.
class SchluesselbildAnsicht extends StatelessWidget {
  const SchluesselbildAnsicht({
    super.key,
    required this.schluessel,
    required this.farbe,
    required this.leer,
    this.punkt = 9,
  });

  final String schluessel;
  final Color farbe;
  final Color leer;

  /// Kantenlaenge eines Feldes in logischen Pixeln.
  final double punkt;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Schluesselbild',
        excludeSemantics: true,
        child: CustomPaint(
          size: Size(Schluesselbild.breite * punkt, Schluesselbild.hoehe * punkt),
          painter: _BildMaler(Schluesselbild.felder(schluessel), farbe, leer, punkt),
        ),
      );
}

class _BildMaler extends CustomPainter {
  _BildMaler(this.f, this.farbe, this.leer, this.punkt);

  final List<int> f;
  final Color farbe;
  final Color leer;
  final double punkt;

  @override
  void paint(Canvas canvas, Size size) {
    final maxZahl = f.fold<int>(1, math.max);
    for (var y = 0; y < Schluesselbild.hoehe; y++) {
      for (var x = 0; x < Schluesselbild.breite; x++) {
        final v = f[y * Schluesselbild.breite + x];
        final mitte = Offset((x + 0.5) * punkt, (y + 0.5) * punkt);
        if (v == -1 || v == -2) {
          // Start als Ring, Ende als volles Quadrat — die beiden Enden des Wegs.
          final r = punkt * 0.38;
          if (v == -1) {
            canvas.drawCircle(mitte, r,
                Paint()..color = farbe..style = PaintingStyle.stroke..strokeWidth = punkt * 0.14);
          } else {
            canvas.drawRect(Rect.fromCenter(center: mitte, width: r * 2, height: r * 2),
                Paint()..color = farbe);
          }
          continue;
        }
        if (v == 0) {
          canvas.drawCircle(mitte, punkt * 0.08, Paint()..color = leer);
          continue;
        }
        final anteil = v / maxZahl;
        canvas.drawCircle(mitte, punkt * (0.16 + 0.26 * anteil),
            Paint()..color = farbe.withValues(alpha: 0.35 + 0.65 * anteil));
      }
    }
  }

  @override
  bool shouldRepaint(_BildMaler alt) => alt.farbe != farbe || alt.leer != leer || alt.f != f;
}
