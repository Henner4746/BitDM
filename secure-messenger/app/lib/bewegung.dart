// bewegung.dart — die Animationen der Oberflaeche.
//
// WOFUER BEWEGUNG DA IST, UND WOFUER NICHT
// Jede Animation hier beantwortet eine Frage, die der Nutzer sonst selbst
// beantworten muesste:
//
//   "Ist das neu?"          — eine neue Nachricht gleitet herein
//   "Wo bin ich gelandet?"  — der Reiterbalken wandert, statt zu springen
//   "Passiert gerade was?"  — der Verbindungspunkt atmet, solange verbunden
//                             wird, und steht still, sobald es steht
//
// Was NICHT hier steht: Bewegung, die nur huebsch ist. Bei einer App, die
// jemand im Zweifel hektisch aufmacht, um etwas zu lesen, ist jede
// Zehntelsekunde Warten auf eine Animation eine Zumutung.
//
// ZWEI ZAHLEN, DIE UEBERALL GELTEN
// 220 ms fuer Wechsel, 160 ms fuer Kleinigkeiten. Kuerzer wirkt hektisch,
// laenger wirkt zaeh. Beides ist unterhalb dessen, was als Verzoegerung
// auffaellt.
//
// RUECKSICHT AUF DIE SYSTEMEINSTELLUNG: wer im Betriebssystem Animationen
// abgeschaltet hat, hat oft einen Grund — Uebelkeit bei Bewegung ist ein
// haeufiger. [Bewegung.aus] fragt das ab, und die Bausteine hier halten sich
// daran.

import 'package:flutter/material.dart';

class Bewegung {
  const Bewegung._();

  /// Fuer Wechsel zwischen Bildschirmen.
  static const Duration wechsel = Duration(milliseconds: 220);

  /// Fuer Kleinigkeiten: Haken, Balken, Farben.
  static const Duration klein = Duration(milliseconds: 160);

  /// Ob das System um moeglichst wenig Bewegung gebeten hat.
  static bool aus(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}

/// Laesst etwas einmalig hereingleiten, wenn es neu erscheint.
///
/// Fuer Nachrichten in der Unterhaltung. Der Sinn ist nicht Schmuck: eine
/// Nachricht, die einfach da ist, unterscheidet sich nicht von einer, die
/// schon da war. Die kurze Bewegung sagt "das ist neu" — und zwar genau
/// einmal, denn beim Scrollen darf sich nichts mehr ruehren.
class Hereingleiten extends StatefulWidget {
  const Hereingleiten({
    super.key,
    required this.child,
    this.vonRechts = false,
    this.verzoegerung = Duration.zero,
  });

  final Widget child;

  /// Eigene Nachrichten kommen von rechts, fremde von links — dorthin, wo sie
  /// ohnehin stehen.
  final bool vonRechts;

  final Duration verzoegerung;

  @override
  State<Hereingleiten> createState() => _HereingleitenState();
}

class _HereingleitenState extends State<Hereingleiten>
    with SingleTickerProviderStateMixin {
  late final AnimationController _steuerung = AnimationController(
    vsync: this,
    duration: Bewegung.klein,
  );

  @override
  void initState() {
    super.initState();
    if (widget.verzoegerung == Duration.zero) {
      _steuerung.forward();
    } else {
      Future<void>.delayed(widget.verzoegerung, () {
        if (mounted) _steuerung.forward();
      });
    }
  }

  @override
  void dispose() {
    _steuerung.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Bewegung.aus(context)) return widget.child;

    final weich = CurvedAnimation(
      parent: _steuerung,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: weich,
      child: SlideTransition(
        position: Tween<Offset>(
          // Klein halten. Eine Nachricht, die quer durch den Bildschirm
          // fliegt, ist naechste Woche nur noch laestig.
          begin: Offset(widget.vonRechts ? 0.08 : -0.08, 0.15),
          end: Offset.zero,
        ).animate(weich),
        child: widget.child,
      ),
    );
  }
}

/// Ein Punkt, der atmet, solange etwas laeuft — und still steht, wenn nicht.
///
/// Fuer die Verbindungsanzeige. Ein Punkt, der immer gleich aussieht, sagt
/// nichts; einer, der immer blinkt, macht nervoes. Er bewegt sich genau dann,
/// wenn wirklich etwas im Gange ist.
class AtmenderPunkt extends StatefulWidget {
  const AtmenderPunkt({
    super.key,
    required this.farbe,
    required this.aktiv,
    this.groesse = 8,
  });

  final Color farbe;

  /// Ob gerade etwas laeuft. Steht es, haelt der Punkt an.
  final bool aktiv;

  final double groesse;

  @override
  State<AtmenderPunkt> createState() => _AtmenderPunktState();
}

class _AtmenderPunktState extends State<AtmenderPunkt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _steuerung = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.aktiv) _steuerung.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AtmenderPunkt alt) {
    super.didUpdateWidget(alt);
    if (widget.aktiv && !_steuerung.isAnimating) {
      _steuerung.repeat(reverse: true);
    } else if (!widget.aktiv && _steuerung.isAnimating) {
      // Nicht abrupt stehenbleiben, sondern in die volle Deckkraft
      // zurueckfahren — sonst friert der Punkt in einem halb verblassten
      // Zustand ein und sieht nach Fehler aus.
      _steuerung.stop();
      _steuerung.animateTo(0, duration: Bewegung.klein);
    }
  }

  @override
  void dispose() {
    _steuerung.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final punkt = Container(
      width: widget.groesse,
      height: widget.groesse,
      decoration: BoxDecoration(color: widget.farbe, shape: BoxShape.circle),
    );
    if (Bewegung.aus(context)) return punkt;

    return AnimatedBuilder(
      animation: _steuerung,
      builder: (_, kind) => Opacity(
        // Nicht bis auf null: ein Punkt, der ganz verschwindet, wirkt wie ein
        // Fehler. Zwischen ganz und halb ist genug zu sehen.
        opacity: 1 - (_steuerung.value * 0.55),
        child: kind,
      ),
      child: punkt,
    );
  }
}
