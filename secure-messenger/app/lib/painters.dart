import 'package:flutter/material.dart';

int bitHash(String s) {
  int h = 2166136261;
  for (int i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

// 3x3 deterministic identicon
class Identicon extends StatelessWidget {
  final String id;
  final double size;
  final List<Color> pal;
  final double radius;
  const Identicon(this.id, this.size, this.pal, this.radius, {super.key});

  @override
  Widget build(BuildContext context) {
    final h = bitHash(id);
    final cells = <Widget>[];
    for (int i = 0; i < 9; i++) {
      final v = (h >> (i * 3)) % pal.length;
      cells.add(Container(color: pal[(v + i) % pal.length]));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: GridView.count(
          crossAxisCount: 3,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: cells,
        ),
      ),
    );
  }
}

// DER GEFAELSCHTE QR-CODE IST WEG.
//
// Hier stand ein `QrView` mit dem Kommentar "25x25 fake-but-deterministic QR":
// drei Ecken wie bei einem QR-Code und dazwischen Rauschen aus einem Hash der
// Adresse. Er sah ueberzeugend aus und enthielt nichts. Der Bildschirm "Meine
// ID" forderte damit zum Scannen auf, und jeder Versuch — mit BitDM oder mit
// einer beliebigen anderen App — musste scheitern.
//
// Ersetzt durch core/qr_bild.dart, das zxing2 zum Kodieren benutzt. Der Weg
// vom gezeichneten Bild zurueck zur Adresse ist in test/core/qr_gemalt_test
// nachgewiesen.

// 16-bar voice waveform
class WaveRow extends StatelessWidget {
  final String seed;
  final Color color;
  const WaveRow(this.seed, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    final h = bitHash(seed);
    final bars = <Widget>[];
    for (int i = 0; i < 16; i++) {
      final ht = 4 + ((h >> (i % 20)) % 12);
      bars.add(Padding(
        padding: const EdgeInsets.only(right: 2),
        child: Container(width: 2, height: ht.toDouble(), color: color),
      ));
    }
    return SizedBox(
      height: 16,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: bars),
    );
  }
}
