import 'dart:math';
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

// 25x25 fake-but-deterministic QR
class QrView extends StatelessWidget {
  final String seed;
  final Color fg;
  final Color bg;
  final double cell;
  const QrView(this.seed, this.fg, this.bg, {this.cell = 5, super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 25 * cell,
      height: 25 * cell,
      child: CustomPaint(painter: _QrPainter(seed, fg, bg)),
    );
  }
}

class _QrPainter extends CustomPainter {
  final String seed;
  final Color fg;
  final Color bg;
  _QrPainter(this.seed, this.fg, this.bg);

  @override
  void paint(Canvas canvas, Size size) {
    const n = 25;
    final h = bitHash(seed);
    final cw = size.width / n, ch = size.height / n;
    final p = Paint();
    for (int i = 0; i < n * n; i++) {
      final r = i ~/ n, cc = i % n;
      final corner = (r < 7 && cc < 7) || (r < 7 && cc > n - 8) || (r > n - 8 && cc < 7);
      bool on;
      if (corner) {
        final rr = r < 7 ? r : n - 1 - r;
        final ccc = cc < 7 ? cc : n - 1 - cc;
        on = max((rr - 3).abs(), (ccc - 3).abs()) != 2;
      } else {
        on = ((((h ^ (i * 2654435761)) & 0xFFFFFFFF) >> 5) % 100) < 47;
      }
      p.color = on ? fg : bg;
      canvas.drawRect(Rect.fromLTWH(cc * cw, r * ch, cw + 0.6, ch + 0.6), p);
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) =>
      old.seed != seed || old.fg != fg || old.bg != bg;
}

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
