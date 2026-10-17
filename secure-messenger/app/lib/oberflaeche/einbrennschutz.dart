// einbrennschutz.dart — verschiebt die Oberflaeche alle 40 Sekunden um ein
// Pixel, damit OLED-Bildschirme nicht einbrennen.
//
// Aus main.dart herausgeloest, Zeichen fuer Zeichen (docs/MAIN-DART-AUFTEILUNG.md).

import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;

/// Verschiebt den Inhalt langsam um wenige Pixel — gegen Einbrennen auf OLED.
///
/// WOGEGEN GENAU
///
/// Auf einem OLED altert jedes Leuchtelement einzeln. Was tagelang an
/// derselben Stelle in derselben Farbe steht, bleibt als Schatten sichtbar,
/// auch wenn laengst etwas anderes dort ist. BitDM hat davon mehr als die
/// meisten Apps: die Reiterleiste steht immer unten, die Kopfzeile immer oben,
/// und der QR-Bildschirm wird bewusst liegengelassen, waehrend jemand ihn
/// abscannt.
///
/// ZWEI PIXEL GENUEGEN, und das ist der ganze Trick: die Alterung verteilt
/// sich auf mehrere Elemente, sobald das Bild nicht exakt stehenbleibt. Mehr
/// waere sichtbar und damit stoerend — hier soll niemand etwas bemerken.
///
/// KEIN DAUERLAUF. Es waere naheliegend, das zu animieren; das hiesse aber,
/// die Bildwiederholung nie zur Ruhe kommen zu lassen und dafuer Akku zu
/// verbrennen. Stattdessen ein Schritt alle 40 Sekunden — fuer die Alterung
/// ist das schnell genug, fuer den Akku unsichtbar.
///
/// Die Schrittfolge ist absichtlich KEIN Kreis mit gerader Laenge: sechs
/// Stellungen, deren Summe null ist, aber deren Reihenfolge das Bild nicht in
/// zwei Haelften teilt. Ein Hin und Her zwischen zwei Punkten waere nur die
/// halbe Wirkung.
class Einbrennschutz extends StatefulWidget {
  const Einbrennschutz({super.key, required this.child});

  final Widget child;

  @override
  State<Einbrennschutz> createState() => _EinbrennschutzState();
}

class _EinbrennschutzState extends State<Einbrennschutz> {
  static const _stellungen = <Offset>[
    Offset(0, 0),
    Offset(1, -1),
    Offset(2, 0),
    Offset(1, 1),
    Offset(-1, 1),
    Offset(-1, -1),
  ];

  int _wo = 0;
  Timer? _takt;

  @override
  void initState() {
    super.initState();
    _takt = Timer.periodic(const Duration(seconds: 40), (_) {
      if (!mounted) return;
      setState(() => _wo = (_wo + 1) % _stellungen.length);
    });
  }

  @override
  void dispose() {
    _takt?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Transform.translate UND NICHT Padding: das hier verschiebt beim Zeichnen
    // und loest kein neues Layout aus. Ein Padding, das sich alle 40 Sekunden
    // aendert, liesse den ganzen Baum neu rechnen — fuer zwei Pixel.
    return Transform.translate(
      offset: _stellungen[_wo],
      child: widget.child,
    );
  }
}
