// navigation.dart — Bildschirmwechsel (go), Zurueck-Ziele, Reiter, buildScreen und buildNav.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

/// Die drei Reiter der unteren Leiste, in ihrer Reihenfolge.
///
/// Steht hier und nicht nur in buildNav, weil das Wischen dieselbe
/// Reihenfolge braucht. Zwei Listen waeren zwei Gelegenheiten, sie
/// auseinanderlaufen zu lassen.
const List<String> reiter = ['chats', 'id', 'set'];

extension _Navigation on _HomeState {
  // ---- actions ----
  void go(String s) {
    // Die Richtung mitfuehren, damit ein Tippen auf die Leiste genauso
    // aussieht wie ein Wischen dorthin. Sonst kaeme der Bildschirm beim Tippen
    // immer von rechts, auch wenn man nach links gegangen ist.
    // BEIM VERLASSEN DER UNTERHALTUNG DAS GEDAECHTNIS LOESCHEN.
    //
    // Sonst gilt das erneute Oeffnen DERSELBEN Unterhaltung nicht als Wechsel,
    // und sie geht dort auf, wo man sie verlassen hat — beim Testen war das
    // ganz oben, bei der aeltesten Nachricht.
    if (screen == 'chat' && s != 'chat') _scrollChat = null;
    final von = reiter.indexOf(screen);
    final nach = reiter.indexOf(s);
    if (von >= 0 && nach >= 0 && von != nach) _richtung = nach > von ? 1 : -1;
    setState(() { screen = s; sheet = false; panic = false; });
    // JEDES MAL neu fragen, nicht einmal beim Start. Bluetooth laesst sich
    // ausserhalb der App umschalten; eine gemerkte Antwort waere spaetestens
    // beim zweiten Hinsehen falsch, und der Nutzer saehe "Bluetooth ist aus",
    // waehrend es laengst an ist.
    if (s == 'set') unawaited(st.pruefeFunk());
  }

  /// Wohin die Zurueck-Geste als Naechstes fuehrt — oder null, wenn es hier
  /// nichts mehr zu schliessen gibt und die App sich beenden darf.
  ///
  /// Getrennt von [_gehZurueck], weil `PopScope.canPop` die Antwort BEIM BAUEN
  /// braucht, das Handeln aber erst danach kommt. Eine Methode, die beides
  /// taete, muesste beim Bauen schon etwas veraendern.
  ///
  /// Die Rueckgabe ist entweder ein Bildschirmcode oder eine der '#'-Marken
  /// fuer die Ueberlagerungen — die haben keinen eigenen Bildschirm, muessen
  /// aber zuerst weg.
  String? _zurueckZiel() {
    // Ueberlagerungen zuerst, in der Reihenfolge, in der sie uebereinander
    // liegen: was oben liegt, geht zuerst.
    if (enroll != null) return '#enroll';
    if (panic && screen == 'set') return '#panic';
    if (sheet && screen == 'chat') return '#sheet';

    // Gesperrt: die Geste darf die Sperre nicht umgehen. Sie beendet die App,
    // und das ist richtig so — die Identitaet bleibt verschlossen.
    if (st.gesperrt) return null;

    return switch (screen) {
      // Unterbildschirme, zurueck zu ihrem Ausgangspunkt. Dieselben Ziele wie
      // die ‹-Knoepfe in den jeweiligen Kopfzeilen.
      'chat' || 'add' => 'chats',
      'test' || 'nahHilfe' => 'set',
      'secure' => 'id',
      'restore' => 'onboard',

      // Die Reiter: zurueck heisst zum ersten Reiter, wie ueberall unter
      // Android.
      'id' || 'set' => 'chats',

      // 'chats' ist die Wurzel, 'onboard' der Anfang — dort beendet die Geste
      // die App. 'creating' und 'phrase' ebenfalls, und zwar mit Absicht: die
      // Wiederherstellungswoerter stehen nur einmal da. Ein Zurueck mitten
      // hinein waere ein Weg, sie zu verlieren.
      _ => null,
    };
  }

  void _gehZurueck() {
    final ziel = _zurueckZiel();
    if (ziel == null) return;
    switch (ziel) {
      case '#enroll':
        setState(() { enroll = null; stickSchritt = null; });
      case '#panic':
        setState(() => panic = false);
      case '#sheet':
        setState(() => sheet = false);
      case 'onboard':
        setState(() { screen = 'onboard'; restoreFehler = null; });
      default:
        go(ziel);
    }
  }

  /// Wechselt zum Nachbarreiter, wenn es einen gibt.
  ///
  /// NUR VON DEN DREI REITERN AUS. Aus einem Chat oder dem Hinzufuegen-
  /// Bildschirm heraus zu wischen waere ein Weg, den niemand sucht und den
  /// jeder versehentlich findet — dort wischt man, um zu scrollen.
  void _wischeZuReiter(int schritte) {
    final jetzt = reiter.indexOf(screen);
    if (jetzt < 0) return;
    final ziel = jetzt + schritte;
    if (ziel < 0 || ziel >= reiter.length) return;
    setState(() {
      _richtung = schritte;
      screen = reiter[ziel];
      sheet = false;
      panic = false;
    });
  }

  Widget buildScreen() {
    if (!st.bereit) {
      return st.schluesselspeicherZu
          ? schluesselspeicherScreen()
          : const SizedBox.shrink();
    }
    // Die Sperre kommt VOR allem anderen. Es gibt eine Identitaet, der
    // gesicherte Bereich des Geraets ruecke sie nur noch nicht heraus.
    if (st.gesperrt) return gesperrtScreen();

    final inhalt = switch (screen) {
      'creating' => arbeitetScreen(),
      'phrase' => phraseScreen(),
      'secure' => secureScreen(),
      'id' => idScreen(),
      'add' => addScreen(),
      'restore' => wiederherstellenScreen(),
      'test' => testScreen(),
      'nahHilfe' => nahHilfeScreen(),
      'chats' => chatsScreen(),
      'chat' => chatScreen(),
      'set' => settingsScreen(),
      _ => onboardScreen(),
    };

    // Nur auf den drei Reitern gewischt und ueberblendet. Anderswo waere
    // beides falsch: der Chat scrollt, und ein Wechsel dorthin ist kein
    // Nachbarschaftswechsel, sondern ein Sprung.
    if (!reiter.contains(screen)) return inhalt;

    return GestureDetector(
      // Nur waagerecht. Ohne diese Beschraenkung faengt die Geste jedes
      // Scrollen ab.
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        // Unter 200 Pixeln je Sekunde ist es kein Wischen, sondern ein
        // verrutschter Finger.
        if (v < -200) {
          _wischeZuReiter(1);
        } else if (v > 200) {
          _wischeZuReiter(-1);
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (kind, animation) {
          // Der neue Bildschirm kommt von der Seite herein, in die gewischt
          // wurde. Kaeme er immer von rechts, fuehlte sich das
          // Zurueckwischen falsch an — man sieht die Bewegung und erwartet
          // sie in der eigenen Richtung.
          final hinein = Tween<Offset>(
            begin: Offset(0.06 * _richtung, 0),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: hinein, child: kind),
          );
        },
        // Der Schluessel sagt dem Wechsler, DASS sich etwas geaendert hat.
        // Ohne ihn haelt er zwei verschiedene Bildschirme fuer denselben und
        // blendet nichts ueber.
        child: KeyedSubtree(key: ValueKey(screen), child: inhalt),
      ),
    );
  }

  // ---- NAV ----
  Widget buildNav() {
    final active = screen == 'chat' ? 'chats' : screen;
    final items = [
      ['chats', t('navChats')],
      ['id', t('navId')],
      ['set', t('navSet')],
    ];
    return Container(
      decoration: BoxDecoration(color: p.navbg, border: Border(top: BorderSide(color: p.lineSoft))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          for (final it in items)
            Expanded(
              child: GestureDetector(
                onTap: () => go(it[0]),
                child: Container(
                  padding: const EdgeInsets.only(top: 11, bottom: 15),
                  // Der Balken und die Schriftfarbe wandern mit. Ein Sprung
                  // sagt "es ist etwas anderes", eine Bewegung sagt "du bist
                  // dorthin gegangen" — und genau das ist beim Wischen die
                  // Frage.
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: active == it[0] ? p.accent : Colors.transparent, width: 2))),
                  alignment: Alignment.center,
                  child: AnimatedDefaultTextStyle(
                    duration: Bewegung.klein,
                    curve: Curves.easeOut,
                    style: mono(size: 10.5, weight: FontWeight.w500, color: active == it[0] ? p.ink : p.dim, spacing: 1.2),
                    child: Text(it[1].toUpperCase()),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  // ---- DEV JUMP ----
  void showDevJump() {
    final labels = jumpLabels[lang]!;
    const codes = ['onboard', 'secure', 'id', 'add', 'chats', 'chat', 'set'];
    showModalBottomSheet(
      context: context,
      backgroundColor: p.surf,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SCREENS · DEV JUMP', style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1.6)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (int i = 0; i < codes.length; i++)
              GestureDetector(
                onTap: () { Navigator.pop(ctx); setState(() { screen = codes[i]; chat ??= c1; sheet = false; panic = false; }); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: screen == codes[i] ? p.accent : p.line)),
                  child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: screen == codes[i] ? p.accLight : p.muted)),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
