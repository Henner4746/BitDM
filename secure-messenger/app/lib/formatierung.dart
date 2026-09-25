// formatierung.dart — *fett*, _kursiv_, ~durchgestrichen~, `fest` und
// ||Spoiler|| in Textnachrichten.
//
// NUR DIE ANZEIGE. Auf der Leitung und in der Datenbank steht der Text mit
// seinen Zeichen, genau wie getippt. Das hat zwei Folgen, beide gewollt:
// eine alte App-Fassung zeigt "*fett*" mit Sternchen statt gar nicht, und es
// gibt kein zweites Format, das neben dem Text herlaufen und von ihm abweichen
// koennte. Signal schickt Bereichsangaben mit; das ist genauer, braucht aber
// ein Feld in der Nutzlast, das eine veraenderte Gegenstelle auf Stellen
// zeigen lassen kann, die es nicht gibt.
//
// Die Regeln sind die von WhatsApp und Signal-Desktop beim Einfuegen: ein
// Zeichen oeffnet nur am Wortanfang und schliesst nur am Wortende, und
// dazwischen muss etwas stehen. So bleibt "2*3*4" eine Rechnung und
// "datei_name_neu" ein Dateiname.

import 'package:flutter/material.dart';

/// Ein Stueck Text mit seinen Auszeichnungen.
class Abschnitt {
  const Abschnitt(this.text,
      {this.fett = false,
      this.kursiv = false,
      this.durch = false,
      this.fest = false,
      this.spoiler = false});

  final String text;
  final bool fett;
  final bool kursiv;
  final bool durch;
  final bool fest;
  final bool spoiler;

  bool get schlicht => !fett && !kursiv && !durch && !fest && !spoiler;

  @override
  String toString() => [
        text,
        if (fett) 'fett',
        if (kursiv) 'kursiv',
        if (durch) 'durch',
        if (fest) 'fest',
        if (spoiler) 'spoiler',
      ].join('|');
}

class Formatierung {
  /// Die Marken, laengste zuerst — sonst fraesse `|` das `||` auf.
  static const _marken = ['||', '*', '_', '~', '`'];

  static bool _wortzeichen(String c) =>
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

  /// Zerlegt [text] in Abschnitte. Ohne Auszeichnung: genau ein Abschnitt.
  static List<Abschnitt> zerlege(String text) {
    final aus = <Abschnitt>[];
    _zerlege(text, const Abschnitt(''), aus, 0);
    // Benachbarte schlichte Stuecke zusammenlegen: "a" "b" → "ab".
    final zusammen = <Abschnitt>[];
    for (final a in aus) {
      if (a.text.isEmpty) continue;
      if (zusammen.isNotEmpty && zusammen.last.schlicht && a.schlicht) {
        zusammen[zusammen.length - 1] =
            Abschnitt(zusammen.last.text + a.text);
      } else {
        zusammen.add(a);
      }
    }
    return zusammen.isEmpty ? [Abschnitt(text)] : zusammen;
  }

  /// Tiefe begrenzt: `*_~*_~...` in tausend Schichten soll kein Stapel-
  /// ueberlauf werden. Fuenf Arten, also hoechstens fuenf sinnvolle Ebenen.
  static void _zerlege(String s, Abschnitt art, List<Abschnitt> aus, int tiefe) {
    var i = 0;
    var start = 0;
    while (i < s.length) {
      String? marke;
      for (final m in _marken) {
        if (s.startsWith(m, i)) {
          marke = m;
          break;
        }
      }
      // Oeffnen nur am Wortanfang: davor kein Wortzeichen, danach kein
      // Leerzeichen.
      final davorOk = i == 0 || !_wortzeichen(s[i - 1]);
      if (marke != null && davorOk && tiefe < 5 && !art.fest) {
        final innenStart = i + marke.length;
        final ende = _schliessend(s, marke, innenStart);
        if (ende != null) {
          aus.add(_mit(art, s.substring(start, i)));
          final innen = s.substring(innenStart, ende);
          final neu = _setze(art, marke);
          if (marke == '`') {
            // Fest gesetzter Text wird nicht weiter ausgewertet — sonst waere
            // `a*b*c` kein Code mehr.
            aus.add(_mit(neu, innen));
          } else {
            _zerlege(innen, neu, aus, tiefe + 1);
          }
          i = ende + marke.length;
          start = i;
          continue;
        }
      }
      i++;
    }
    aus.add(_mit(art, s.substring(start)));
  }

  /// Wo die schliessende Marke steht, oder null. Innen nicht leer, nicht mit
  /// Leerzeichen am Rand, und danach kein Wortzeichen.
  static int? _schliessend(String s, String marke, int von) {
    if (von >= s.length || s[von].trim().isEmpty) return null;
    var j = s.indexOf(marke, von + 1);
    while (j != -1) {
      final innenOk = s[j - 1].trim().isNotEmpty;
      final danach = j + marke.length;
      final danachOk = danach >= s.length || !_wortzeichen(s[danach]);
      if (innenOk && danachOk && j > von) return j;
      j = s.indexOf(marke, j + 1);
    }
    return null;
  }

  static Abschnitt _setze(Abschnitt a, String marke) => Abschnitt('',
      fett: a.fett || marke == '*',
      kursiv: a.kursiv || marke == '_',
      durch: a.durch || marke == '~',
      fest: a.fest || marke == '`',
      spoiler: a.spoiler || marke == '||');

  static Abschnitt _mit(Abschnitt art, String text) => Abschnitt(text,
      fett: art.fett,
      kursiv: art.kursiv,
      durch: art.durch,
      fest: art.fest,
      spoiler: art.spoiler);
}

/// Zeigt eine Textnachricht mit ihren Auszeichnungen. Ein Spoiler ist
/// verdeckt, bis man ihn antippt — und bleibt es fuer diese Blase dann nicht
/// mehr.
class FormatierterText extends StatefulWidget {
  const FormatierterText(this.text,
      {super.key, required this.stil, required this.festStil, required this.verdeckt});

  final String text;
  final TextStyle stil;

  /// Fuer `fest` gesetzten Text — die Schrift der App fuer Adressen.
  final TextStyle festStil;

  /// Die Farbe, mit der ein Spoiler zugedeckt wird.
  final Color verdeckt;

  @override
  State<FormatierterText> createState() => _FormatierterTextState();
}

class _FormatierterTextState extends State<FormatierterText> {
  bool _aufgedeckt = false;

  @override
  Widget build(BuildContext context) {
    final teile = Formatierung.zerlege(widget.text);
    if (teile.length == 1 && teile.single.schlicht) {
      return Text(widget.text, style: widget.stil);
    }
    final hatSpoiler = teile.any((a) => a.spoiler);
    final text = Text.rich(TextSpan(children: [
      for (final a in teile)
        TextSpan(
          text: a.text,
          style: (a.fest ? widget.festStil : widget.stil).copyWith(
            fontWeight: a.fett ? FontWeight.w700 : null,
            fontStyle: a.kursiv ? FontStyle.italic : null,
            decoration: a.durch ? TextDecoration.lineThrough : null,
            color: a.spoiler && !_aufgedeckt ? widget.verdeckt : null,
            backgroundColor: a.spoiler && !_aufgedeckt ? widget.verdeckt : null,
          ),
        ),
    ]));
    if (!hatSpoiler || _aufgedeckt) return text;
    return GestureDetector(
      onTap: () => setState(() => _aufgedeckt = true),
      child: text,
    );
  }
}
