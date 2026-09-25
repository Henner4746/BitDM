// themen.dart — die Themen der App und wie sie ineinander uebergehen.
//
// EIN THEMA IST MEHR ALS EINE PALETTE. Es bringt seine Schriften mit (die
// Terminal-Themen setzen auch den Nachrichtentext in Monoschrift, das
// Material-Thema alles in der Schrift des Systems), seine Farben fuer die
// Kennungsbilder, und die Zeichen, aus denen sein Uebergang besteht.
//
// DER UEBERGANG IST ABSICHTLICH LANGSAM. Kein Umschalten, sondern ein
// Umschluesseln: die Farben gleiten ueber Sekunden, waehrend ein Schleier aus
// Chiffrezeichen ueber den Bildschirm zieht und in der Mitte der Name des
// neuen Themas aus Zeichensalat heraus entschluesselt wird. Die Schrift
// wechselt in der Mitte, wenn der Schleier am dichtesten ist.
//
// WER BEWEGUNG ABGESCHALTET HAT (Bedienungshilfen), bekommt keinen Schleier
// und keinen Verlauf, sondern den neuen Stand sofort. Das prueft die
// Oberflaeche ueber MediaQuery.disableAnimations, nicht dieses Modul.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import 'data.dart';

class Thema {
  const Thema({
    required this.id,
    required this.name,
    required this.pal,
    required this.avatar,
    required this.dunkel,
    this.anzeigeSchrift = 'Doto',
    this.monoSchrift = 'Chivo Mono',
    this.textSchrift,
    this.chiffre = _base32,
  });

  final String id;

  /// Anzeigename je Sprache: {'en': ..., 'de': ...}.
  final Map<String, String> name;
  final Pal pal;
  final List<Color> avatar;
  final bool dunkel;

  /// Schrift fuer Ueberschriften und Kennungen. null = Schrift des Systems.
  final String? anzeigeSchrift;

  /// Schrift fuer Bedienbeschriftungen. null = Schrift des Systems.
  final String? monoSchrift;

  /// Schrift fuer den Nachrichtentext. null = Schrift des Systems — die liest
  /// sich in Saetzen am besten, darum ist das der Normalfall.
  final String? textSchrift;

  /// Die Zeichen, aus denen der Schleier beim Wechsel zu diesem Thema besteht.
  final String chiffre;

  String nameIn(String sprache) => name[sprache] ?? name['en']!;
}

/// Dasselbe Alphabet wie die Adressen: A-Z und 2-7.
const _base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const _hex = '0123456789ABCDEF';
const _binaer = '01010011';
const _enigma = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _punkte = '·•○●◌◍◎';
const _wellen = '~≈∿-=+*';

/// Die Grundfarbe von Material 3, wenn das System keine eigene liefert.
const materialGrundfarbe = Color(0xFF6750A4);

/// Aus einem Material-3-Farbschema eine Palette der App machen.
///
/// Die Rollen passen gut aufeinander: `surface*` ist der Hintergrund in
/// Stufen, `onSurface*` die Schrift, `primary` der Akzent und
/// `primaryContainer` die getoente Flaeche.
Pal palAusSchema(ColorScheme s) {
  final dunkel = s.brightness == Brightness.dark;
  return Pal(
    shell: s.surfaceContainerLowest,
    bg: s.surface,
    surf: s.surfaceContainer,
    surf2: s.surfaceContainerLow,
    navbg: s.surfaceContainer,
    ink: s.onSurface,
    muted: s.onSurfaceVariant,
    dim: s.outline,
    line: s.outlineVariant,
    lineSoft: s.onSurface.withValues(alpha: 0.14),
    accent: s.primary,
    accLight: dunkel ? s.primary : s.onPrimaryContainer,
    wash: s.primary.withValues(alpha: dunkel ? 0.14 : 0.12),
    tint: s.primaryContainer,
    tintLine: s.primary.withValues(alpha: 0.5),
    tintInk: s.onPrimaryContainer,
    scrim: s.scrim.withValues(alpha: dunkel ? 0.66 : 0.4),
    onAcc: s.onPrimary,
    accHover: s.onPrimaryContainer,
  );
}

List<Color> _avatarAusSchema(ColorScheme s) => [
      s.primary,
      s.secondary,
      s.tertiary,
      s.primaryContainer,
      s.secondaryContainer,
      s.tertiaryContainer,
    ];

/// Alle Themen. [systemAkzent] faerbt die beiden Material-Themen ein
/// (Material You); ohne ihn nehmen sie die Grundfarbe von Material 3.
List<Thema> bauThemen({Color? systemAkzent}) {
  final grund = systemAkzent ?? materialGrundfarbe;
  final mDunkel = ColorScheme.fromSeed(seedColor: grund, brightness: Brightness.dark);
  final mHell = ColorScheme.fromSeed(seedColor: grund);
  return [
    const Thema(
      id: 'nocturne',
      name: {'en': 'Nocturne', 'de': 'Nocturne'},
      pal: palDark,
      avatar: avPalDark,
      dunkel: true,
    ),
    const Thema(
      id: 'papier',
      name: {'en': 'Paper', 'de': 'Papier'},
      pal: palLight,
      avatar: avPalLight,
      dunkel: false,
    ),
    Thema(
      id: 'material',
      name: const {'en': 'Material', 'de': 'Material'},
      pal: palAusSchema(mDunkel),
      avatar: _avatarAusSchema(mDunkel),
      dunkel: true,
      anzeigeSchrift: null,
      monoSchrift: null,
      chiffre: _punkte,
    ),
    Thema(
      id: 'materialHell',
      name: const {'en': 'Material light', 'de': 'Material hell'},
      pal: palAusSchema(mHell),
      avatar: _avatarAusSchema(mHell),
      dunkel: false,
      anzeigeSchrift: null,
      monoSchrift: null,
      chiffre: _punkte,
    ),
    const Thema(
      id: 'oled',
      name: {'en': 'Void', 'de': 'Leere'},
      pal: Pal(
        shell: Color(0xFF000000),
        bg: Color(0xFF000000),
        surf: Color(0xFF0E0E12),
        surf2: Color(0xFF08080A),
        navbg: Color(0xFF050507),
        ink: Color(0xFFF2F2F5),
        muted: Color(0xFF9A9AAA),
        dim: Color(0xFF6E6E7C),
        line: Color(0xFF26262E),
        lineSoft: Color(0x24F2F2F5),
        accent: Color(0xFF9184D9),
        accLight: Color(0xFFB5ABFC),
        wash: Color(0x249184D9),
        tint: Color(0xFF1A1730),
        tintLine: Color(0xFF3A3363),
        tintInk: Color(0xFFD2CEFD),
        scrim: Color(0xC0000000),
        onAcc: Color(0xFF000000),
        accHover: Color(0xFFB5ABFC),
      ),
      avatar: avPalDark,
      dunkel: true,
    ),
    const Thema(
      id: 'phosphor',
      name: {'en': 'Phosphor', 'de': 'Phosphor'},
      pal: Pal(
        shell: Color(0xFF020402),
        bg: Color(0xFF050A06),
        surf: Color(0xFF0B150D),
        surf2: Color(0xFF08100A),
        navbg: Color(0xFF08110A),
        ink: Color(0xFF9CFFB0),
        muted: Color(0xFF52C06A),
        dim: Color(0xFF3A8A4C),
        line: Color(0xFF1E4A28),
        lineSoft: Color(0x249CFFB0),
        accent: Color(0xFF33FF66),
        accLight: Color(0xFF7DFF9B),
        wash: Color(0x2433FF66),
        tint: Color(0xFF0E2A15),
        tintLine: Color(0xFF1F6B33),
        tintInk: Color(0xFFB8FFC8),
        scrim: Color(0xB8020402),
        onAcc: Color(0xFF031006),
        accHover: Color(0xFFB8FFC8),
      ),
      avatar: [
        Color(0xFF33FF66), Color(0xFF1F6B33), Color(0xFF0E2A15),
        Color(0xFF7DFF9B), Color(0xFF08100A), Color(0xFF3A8A4C),
      ],
      dunkel: true,
      textSchrift: 'Chivo Mono',
      chiffre: _binaer,
    ),
    const Thema(
      id: 'bernstein',
      name: {'en': 'Amber', 'de': 'Bernstein'},
      pal: Pal(
        shell: Color(0xFF070500),
        bg: Color(0xFF0D0900),
        surf: Color(0xFF1A1206),
        surf2: Color(0xFF140E04),
        navbg: Color(0xFF150F05),
        ink: Color(0xFFFFD58A),
        muted: Color(0xFFC8923A),
        dim: Color(0xFF8F6A2C),
        line: Color(0xFF4A3512),
        lineSoft: Color(0x24FFD58A),
        accent: Color(0xFFFFB000),
        accLight: Color(0xFFFFC84D),
        wash: Color(0x24FFB000),
        tint: Color(0xFF2E2008),
        tintLine: Color(0xFF7A5410),
        tintInk: Color(0xFFFFE2A8),
        scrim: Color(0xB8070500),
        onAcc: Color(0xFF1A1000),
        accHover: Color(0xFFFFE2A8),
      ),
      avatar: [
        Color(0xFFFFB000), Color(0xFF7A5410), Color(0xFF2E2008),
        Color(0xFFFFC84D), Color(0xFF140E04), Color(0xFFC8923A),
      ],
      dunkel: true,
      textSchrift: 'Chivo Mono',
      chiffre: _hex,
    ),
    const Thema(
      id: 'enigma',
      name: {'en': 'Enigma', 'de': 'Enigma'},
      pal: Pal(
        shell: Color(0xFF120C08),
        bg: Color(0xFF1B130D),
        surf: Color(0xFF2A1E15),
        surf2: Color(0xFF22180F),
        navbg: Color(0xFF241A11),
        ink: Color(0xFFEFE4CF),
        muted: Color(0xFFBCA886),
        dim: Color(0xFF8C7A5E),
        line: Color(0xFF4D3B28),
        lineSoft: Color(0x24EFE4CF),
        accent: Color(0xFFC9A227),
        accLight: Color(0xFFE3C35A),
        wash: Color(0x24C9A227),
        tint: Color(0xFF3A2C14),
        tintLine: Color(0xFF7A5E22),
        tintInk: Color(0xFFF3DFA0),
        scrim: Color(0xB0120C08),
        onAcc: Color(0xFF1B130D),
        accHover: Color(0xFFF3DFA0),
      ),
      avatar: [
        Color(0xFFC9A227), Color(0xFF7A5E22), Color(0xFF4D3B28),
        Color(0xFFE3C35A), Color(0xFF22180F), Color(0xFF8C7A5E),
      ],
      dunkel: true,
      chiffre: _enigma,
    ),
    const Thema(
      id: 'aurora',
      name: {'en': 'Aurora', 'de': 'Aurora'},
      pal: Pal(
        shell: Color(0xFF03080F),
        bg: Color(0xFF07111C),
        surf: Color(0xFF0F1E2E),
        surf2: Color(0xFF0B1826),
        navbg: Color(0xFF0C1A29),
        ink: Color(0xFFE2F3FF),
        muted: Color(0xFF8FB4CC),
        dim: Color(0xFF6A8BA3),
        line: Color(0xFF24405A),
        lineSoft: Color(0x24E2F3FF),
        accent: Color(0xFF3DDCCB),
        accLight: Color(0xFF8AF5EA),
        wash: Color(0x243DDCCB),
        tint: Color(0xFF10323A),
        tintLine: Color(0xFF1F6A6E),
        tintInk: Color(0xFFC4FFF8),
        scrim: Color(0xB003080F),
        onAcc: Color(0xFF04161A),
        accHover: Color(0xFFC4FFF8),
      ),
      avatar: [
        Color(0xFF3DDCCB), Color(0xFFB77CFF), Color(0xFF24405A),
        Color(0xFF8AF5EA), Color(0xFF0B1826), Color(0xFF5E7BFF),
      ],
      dunkel: true,
      chiffre: _wellen,
    ),
  ];
}

/// Die Themen, durch die das Wandern zieht: nur die dunklen. Mitten in der
/// Nacht von allein auf Papierweiss zu gleiten waere kein Effekt, sondern ein
/// Blendangriff.
List<Thema> wanderKreis(List<Thema> alle) => alle.where((t) => t.dunkel).toList();

// ═════════════════════════════════════════════════════════ Der Schleier

/// Zeichnet den Chiffreschleier eines Themenwechsels.
///
/// [fortschritt] laeuft von 0 bis 1. Ein Band aus Zeichen zieht von oben nach
/// unten, jede Zelle flackert eine Weile und verlischt. Ueber allem liegt ein
/// leichter Hauch, der in der Mitte am dichtesten ist — dort wechselt die
/// Schrift. In der Mitte des Bildschirms wird [titel] entschluesselt.
class ChiffreSchleier extends StatelessWidget {
  const ChiffreSchleier({
    super.key,
    required this.fortschritt,
    required this.farbe,
    required this.hauch,
    required this.chiffre,
    required this.titel,
    this.schrift,
    this.saat = 7,
  });

  final double fortschritt;
  final Color farbe;
  final Color hauch;
  final String chiffre;
  final String titel;
  final String? schrift;
  final int saat;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
          size: Size.infinite,
          painter: _SchleierMaler(fortschritt, farbe, hauch, chiffre, titel, schrift, saat),
        ),
      );
}

class _SchleierMaler extends CustomPainter {
  _SchleierMaler(this.t, this.farbe, this.hauch, this.chiffre, this.titel, this.schrift, this.saat);

  final double t;
  final Color farbe;
  final Color hauch;
  final String chiffre;
  final String titel;
  final String? schrift;
  final int saat;

  static const _zelle = 18.0;

  /// Vorbereitete Zeichen, damit nicht jedes Bild hunderte TextPainter neu
  /// setzen muss. Schluessel: Zeichen, Farbe mit Deckkraftstufe, Schrift.
  static final Map<String, TextPainter> _satz = {};

  TextPainter _zeichen(String z, Color c, double groesse, {FontWeight dicke = FontWeight.w500}) {
    final schluessel = '$z|${c.toARGB32()}|$groesse|$schrift|${dicke.value}';
    final vorhanden = _satz[schluessel];
    if (vorhanden != null) return vorhanden;
    if (_satz.length > 800) _satz.clear();
    final tp = TextPainter(
      text: TextSpan(
          text: z,
          style: TextStyle(fontFamily: schrift, fontSize: groesse, color: c, fontWeight: dicke, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    return _satz[schluessel] = tp;
  }

  /// Ein fester Zufall je Zelle — derselbe in jedem Bild, sonst flimmert das
  /// Muster statt zu wandern.
  static double _zufall(int a, int b, int c) {
    var h = a * 374761393 + b * 668265263 + c * 2147483647;
    h = (h ^ (h >> 13)) * 1274126177;
    h = h ^ (h >> 16);
    return (h & 0xFFFF) / 0xFFFF;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1 || chiffre.isEmpty) return;

    // Der Hauch: am dichtesten in der Mitte, wenn die Schrift wechselt.
    final dichte = math.pow(math.sin(math.pi * t), 2).toDouble();
    canvas.drawRect(Offset.zero & size,
        Paint()..color = hauch.withValues(alpha: hauch.a * 0.55 * dichte));

    final spalten = (size.width / _zelle).ceil();
    final zeilen = (size.height / _zelle).ceil();
    final takt = (t * 36).floor(); // wie oft die Zeichen umspringen
    final band = t * 1.4 - 0.2; // wo das Band gerade steht, von oben nach unten

    for (var y = 0; y < zeilen; y++) {
      for (var x = 0; x < spalten; x++) {
        final r = _zufall(x, y, saat);
        if (r > 0.55) continue; // nicht jede Zelle, sonst ist es eine Wand
        final lage = (y / zeilen) * 0.75 + r * 0.25;
        final abstand = (band - lage).abs();
        if (abstand > 0.14) continue;
        final staerke = 1 - abstand / 0.14;
        final stufe = (staerke * 4).ceil().clamp(1, 4);
        final c = farbe.withValues(alpha: stufe / 4 * 0.8);
        final i = (_zufall(x, y, takt + saat) * chiffre.length).floor() % chiffre.length;
        final tp = _zeichen(chiffre[i], c, 12);
        tp.paint(canvas, Offset(x * _zelle + (_zelle - tp.width) / 2, y * _zelle + (_zelle - tp.height) / 2));
      }
    }

    // Der Name des neuen Themas, aus Zeichensalat entschluesselt.
    if (titel.isNotEmpty && t > 0.15 && t < 0.95) {
      final sichtbar = t < 0.8 ? 1.0 : (0.95 - t) / 0.15;
      final teile = <String>[];
      for (var k = 0; k < titel.length; k++) {
        final ab = 0.3 + 0.35 * (k / titel.length);
        if (titel[k] == ' ' || t >= ab) {
          teile.add(titel[k]);
        } else {
          teile.add(chiffre[(_zufall(k, takt, saat) * chiffre.length).floor() % chiffre.length]);
        }
      }
      final tp = TextPainter(
        text: TextSpan(
          text: teile.join(),
          style: TextStyle(
              fontFamily: schrift,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 6,
              color: farbe.withValues(alpha: sichtbar.clamp(0.0, 1.0))),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(_SchleierMaler alt) =>
      alt.t != t || alt.farbe != farbe || alt.titel != titel || alt.chiffre != chiffre;
}

// ═════════════════════════════════════════ Entschluesselnder Nachrichtentext

/// Zeigt einen Text, der sich aus Chiffrezeichen heraus entschluesselt, und
/// danach [fertig].
///
/// [seit] ist der Zeitpunkt, an dem das Entschluesseln begann — von aussen
/// gehalten, nicht hier. Baut die Liste die Blase waehrenddessen neu (und das
/// tut sie bei jeder eintreffenden Nachricht), laeuft der Effekt weiter, statt
/// von vorn zu beginnen oder abzubrechen.
///
/// Die Vorleseschrift bekommt von Anfang an den Klartext: der Effekt ist fuer
/// die Augen, nicht fuer die Ohren.
class EntschluesselnderText extends StatefulWidget {
  const EntschluesselnderText({
    super.key,
    required this.text,
    required this.stil,
    required this.seit,
    required this.chiffre,
    required this.fertig,
  });

  final String text;
  final TextStyle stil;
  final DateTime seit;
  final String chiffre;
  final Widget fertig;

  /// Wie lange das Entschluesseln dauert — mit der Laenge etwas laenger,
  /// aber nie so lang, dass man auf eine Nachricht warten muss.
  static Duration dauerFuer(String text) =>
      Duration(milliseconds: (500 + text.length * 14).clamp(500, 1300));

  @override
  State<EntschluesselnderText> createState() => _EntschluesselnderTextState();
}

class _EntschluesselnderTextState extends State<EntschluesselnderText>
    with SingleTickerProviderStateMixin {
  /// NICHT `late final` mit Initialisierer: war der Effekt beim Anlegen schon
  /// vorbei, entstuende der Ticker erst in dispose() — und fragte dort einen
  /// Baum, den es nicht mehr gibt (im vollen Testlauf aufgefallen).
  Ticker? _takt;

  double get _fortschritt {
    final dauer = EntschluesselnderText.dauerFuer(widget.text).inMilliseconds;
    final vergangen = DateTime.now().difference(widget.seit).inMilliseconds;
    return (vergangen / dauer).clamp(0.0, 1.0);
  }

  @override
  void initState() {
    super.initState();
    if (_fortschritt < 1) {
      _takt = createTicker((_) {
        if (_fortschritt >= 1) _takt?.stop();
        if (mounted) setState(() {});
      })
        ..start();
    }
  }

  @override
  void dispose() {
    _takt?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = _fortschritt;
    if (f >= 1 || widget.chiffre.isEmpty) return widget.fertig;
    final takt = DateTime.now().millisecondsSinceEpoch ~/ 55;
    final zeichen = widget.text.characters.toList();
    final aus = StringBuffer();
    for (var k = 0; k < zeichen.length; k++) {
      final z = zeichen[k];
      if (z.trim().isEmpty || f >= (k + 1) / zeichen.length) {
        aus.write(z);
      } else {
        aus.write(widget.chiffre[(_SchleierMaler._zufall(k, takt, 3) * widget.chiffre.length).floor() %
            widget.chiffre.length]);
      }
    }
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: Text(aus.toString(), style: widget.stil),
    );
  }
}
