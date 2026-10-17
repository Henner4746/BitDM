// bedienbar.dart — Bedienbar-Huelle: Maus, Tastatur und Fokus fuer selbst gezeichnete Knoepfe am Rechner.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

/// Was Leertaste und Eingabetaste auf einem FOKUSSIERTEN Bedienelement
/// ausloesen sollen.
///
/// UEBER DIE INTENTS UND NICHT UEBER TASTEN. Die Zuordnung Taste → Absicht
/// haengt schon in `WidgetsApp` ueber der ganzen App; hier wird nur gesagt, was
/// die Absicht bewirkt. Wer stattdessen selbst auf die Eingabetaste hoert,
/// nimmt sie dem fokussierten Bedienelement weg — genau der Fehler, der am
/// 30.07.2026 auf 'onboard' eine neue Identitaet anlegte, obwohl der Verweis
/// "Ich habe schon 12 Woerter" den Fokus hatte.
///
/// BEIDE ABSICHTEN SIND NOETIG: im Browser bildet WidgetsApp die Eingabetaste
/// auf [ButtonActivateIntent] ab, nicht auf [ActivateIntent]
/// (flutter/lib/src/widgets/app.dart:1317, nachgesehen am 30.07.2026) — mit nur
/// einer der beiden waere im Web allein die Leertaste ein Druck.
Map<Type, Action<Intent>> _aktivierung(VoidCallback tun) => {
      ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
        tun();
        return null;
      }),
      ButtonActivateIntent:
          CallbackAction<ButtonActivateIntent>(onInvoke: (_) {
        tun();
        return null;
      }),
    };

/// Macht ein Bedienelement im Fenster zeigerbar, ueberfahrbar und fokussierbar.
///
/// WARUM ES DAS BRAUCHT. Am 30.07.2026 kam MouseRegion in ganz lib/ nicht ein
/// einziges Mal vor: der Zeiger blieb ueber jedem Knopf ein Pfeil, ueber
/// Textknoepfen sogar ein Text-Cursor, und mit Tab war kein Knopf der App
/// erreichbar. Am Schreibtisch ist der Zeiger das erste, woran man erkennt,
/// dass etwas ein Knopf ist — bleibt er ein Pfeil, sucht man weiter.
///
/// DER TIPP BLEIBT DRINNEN. Diese Huelle bringt KEIN eigenes GestureDetector
/// mit; das Antippen behandelt weiter der Baustein, um den sie liegt
/// (`outlineBtn`, `Masse.trefferflaeche`, die freien GestureDetector). Zwei
/// Erkenner um dieselbe Flaeche waeren zwei Wege zu derselben Wirkung — und
/// einer davon wuerde irgendwann anders reagieren als der andere.
///
/// AUF ANDROID FAELLT SIE WEG, nicht "wirkt nicht": bei `imFenster == false`
/// gibt sie den Baum unveraendert zurueck. Damit bleibt dort jedes Pixel und
/// jeder Test, wie er war — im Widget-Test meldet Flutter android.
class _Bedienbar extends StatefulWidget {
  const _Bedienbar({
    required this.imFenster,
    required this.bau,
    this.onTap,
  });

  final bool imFenster;

  /// Null heisst: gerade nicht bedienbar. Dann bleibt der Standardzeiger, und
  /// die Huelle nimmt keinen Fokus — eine Hand ueber etwas, das nicht geht,
  /// verspricht etwas, was nicht kommt.
  final VoidCallback? onTap;

  final Widget Function(bool ueberfahren, bool fokus) bau;

  @override
  State<_Bedienbar> createState() => _BedienbarState();
}

class _BedienbarState extends State<_Bedienbar> {
  bool _ueber = false, _fokus = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.imFenster) return widget.bau(false, false);
    final an = widget.onTap != null;
    return FocusableActionDetector(
      enabled: an,
      mouseCursor: an ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (v) => setState(() => _ueber = v),
      onShowFocusHighlight: (v) => setState(() => _fokus = v),
      actions: _aktivierung(() => widget.onTap?.call()),
      child: widget.bau(_ueber && an, _fokus),
    );
  }
}
