// thema.dart — Palette, Schriften, Themenwechsel und das Wandern der Themen.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Thema on _HomeState {
  /// Das Thema, dessen Schriften und Kennungsfarben gerade gelten: bis zur
  /// Mitte eines Wechsels das alte, danach das neue.
  Thema get _schriftThema =>
      (_vonThema != null && _wechsel.value < 0.5) ? _vonThema! : _thema;

  /// Wechselt zu [neu], als kurze Ueberblendung der Farben. Mitten in einem
  /// Wechsel geht es vom Zwischenstand aus weiter, nicht mit einem Sprung
  /// zurueck. Mit [sofort] ohne jede Bewegung.
  ///
  /// SEIT 24.10.2026 KURZ UND OHNE SCHLEIER. Vorher dauerte eine Wahl 2,8 s,
  /// und ein Chiffreschleier zog dabei ueber den ganzen Bildschirm. Weil die
  /// App beim Start in das gespeicherte Thema glitt, kam beides bei jedem
  /// Neustart. Henrik: "zu viel des Guten".
  void wechsleThema(Thema neu,
      {Duration dauer = const Duration(milliseconds: 350), bool sofort = false}) {
    if (neu.id == _thema.id && _vonThema == null) return;
    final ohneBewegung = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (sofort || ohneBewegung) {
      _wechsel.stop();
      setState(() {
        _vonThema = null;
        _thema = neu;
      });
      anzeigeThema.value = neu;
      return;
    }
    final von = _vonThema == null
        ? _thema
        : Thema(
            id: '_zwischen',
            name: const {'en': ''},
            pal: p,
            avatar: avp,
            dunkel: _schriftThema.dunkel,
            anzeigeSchrift: _schriftThema.anzeigeSchrift,
            monoSchrift: _schriftThema.monoSchrift,
            textSchrift: _schriftThema.textSchrift,
          );
    setState(() {
      _vonThema = von;
      _thema = neu;
    });
    _wechsel.duration = dauer;
    _wechsel.forward(from: 0);
  }

  /// Das Wandern: alle paar Minuten gleitet das Thema von allein zum
  /// naechsten dunklen weiter — langsamer als ein gewaehlter Wechsel.
  void _planeWandern(int minuten) {
    _wanderTakt?.cancel();
    _wanderTakt = null;
    if (minuten <= 0) return;
    _wanderTakt = Timer.periodic(Duration(minutes: minuten), (_) {
      if (!mounted) return;
      final kreis = wanderKreis(_themen);
      final i = kreis.indexWhere((t) => t.id == _thema.id);
      wechsleThema(kreis[(i + 1) % kreis.length], dauer: const Duration(seconds: 7));
    });
  }

  /// Uebernimmt, was in den Einstellungen steht — beim Start, nach dem
  /// Entsperren und nach jeder Aenderung.
  ///
  /// Uebergeblendet wird nur, wenn das Thema gerade in den Einstellungen
  /// gewaehlt wurde. Beim Start und nach dem Entsperren steht das gespeicherte
  /// Thema sofort da: das ist kein Wechsel, den jemand sehen wollte.
  void _uebernimmEinstellungen() {
    final e = st.einstellungen;
    if (e.thema != _gemeldetesThema) {
      _gemeldetesThema = e.thema;
      final gewaehlt = _themaGewaehlt;
      _themaGewaehlt = false;
      final ziel = _themen.firstWhere((t) => t.id == e.thema, orElse: () => _themen.first);
      if (ziel.id != _thema.id) wechsleThema(ziel, sofort: !gewaehlt);
    }
    if (e.themaWandern != _gemeldetesWandern) {
      _gemeldetesWandern = e.themaWandern;
      _planeWandern(e.themaWandern);
    }
    final sprache = e.sprache;
    if (sprache != null && sprache != lang) {
      lang = sprache;
      _setzeMeldetexte();
    }
  }

  Pal get p => _vonThema == null
      ? _thema.pal
      : Pal.lerp(_vonThema!.pal, _thema.pal, Curves.easeInOut.transform(_wechsel.value));

  List<Color> get avp => _schriftThema.avatar;

  // ---- fonts (bundled locally; the app never fetches them at runtime) ----
  //
  // Both families are variable fonts with a `wght` axis, so a single file
  // covers every weight the UI uses (w300 … w900). `fontWeight` alone does not
  // drive that axis reliably, so the axis is set explicitly via fontVariations
  // and `fontWeight` is kept for Flutter's own fallback/metrics handling.
  TextStyle _font(String? family, double size, FontWeight weight, Color? color, double? spacing, double height) {
    // DIE EINE STELLE, an der die Schrift der Abfolgen im Fenster waechst —
    // siehe [_schriftFaktor]. Der Faktor haengt am Bildschirm und nicht nur an
    // der Plattform: die vier fertigen Schreibtisch-Bildschirme sind
    // ausgemessen, wie sie sind, und sollen sich nicht verschieben.
    if (_abfolgeImFenster) size *= _schriftFaktor;
    return TextStyle(
      fontFamily: family,
      fontFamilyFallback: symbolSchriften,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: spacing,
      height: height,
    );
  }

  TextStyle doto({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.2}) =>
      _font(_schriftThema.anzeigeSchrift, size, weight, color, spacing, height);

  TextStyle mono({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.4}) =>
      _font(_schriftThema.monoSchrift, size, weight, color, spacing, height);

  /// Waehlt ein Thema — auch das, das schon gespeichert ist.
  ///
  /// DAS WANDERN laesst die Anzeige vom gespeicherten Thema wegziehen, ohne
  /// die Einstellung zu aendern. Wer dann das gespeicherte erneut antippt,
  /// aenderte bisher nichts: `setzeEinstellungen` mit demselben Wert, und
  /// [_uebernimmEinstellungen] sah keinen Unterschied. Jetzt gleitet die
  /// Anzeige zurueck.
  Future<void> _waehleThema(String id) async {
    if (id == st.einstellungen.thema) {
      final ziel = _themen.firstWhere((th) => th.id == id, orElse: () => _themen.first);
      if (ziel.id != _thema.id || _vonThema != null) wechsleThema(ziel);
      return;
    }
    _themaGewaehlt = true;
    try {
      await st.setzeEinstellungen(st.einstellungen.copyWith(thema: id));
    } finally {
      // Kam keine Aenderung an (etwa weil das Speichern scheiterte), darf
      // die naechste, nicht gewaehlte nicht ueberblenden.
      _themaGewaehlt = false;
    }
  }

  /// Die Themen als Kacheln: jede zeigt ihre eigenen Farben und Schrift, nicht
  /// die des gerade gueltigen Themas — sonst saehe man nicht, wohin man geht.
  Widget themenWahl() {
    final gewaehlt = st.einstellungen.thema;
    return LayoutBuilder(builder: (context, platz) {
      final breite = ((platz.maxWidth - 16) / 3).floorToDouble();
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final th in _themen)
          Semantics(
            button: true,
            selected: th.id == gewaehlt,
            label: th.nameIn(lang),
            excludeSemantics: true,
            child: GestureDetector(
              key: ValueKey('thema-${th.id}'),
              onTap: () => _waehleThema(th.id),
              child: Container(
                width: breite,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: th.pal.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: th.id == gewaehlt ? p.accLight : th.pal.line,
                      width: th.id == gewaehlt ? 2 : 1),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Eine Mini-Blase und ein Akzentstrich: genug, um das Thema
                  // zu erkennen, ohne eine ganze Vorschau zu zeichnen.
                  Row(children: [
                    Container(width: 14, height: 14,
                        decoration: BoxDecoration(color: th.pal.accent, borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 5),
                    Expanded(child: Container(height: 8,
                        decoration: BoxDecoration(color: th.pal.surf, borderRadius: BorderRadius.circular(3)))),
                  ]),
                  const SizedBox(height: 5),
                  Container(height: 3, width: breite * 0.45,
                      decoration: BoxDecoration(color: th.pal.accLight, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 7),
                  Text(th.nameIn(lang),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: th.monoSchrift, fontSize: 10.5,
                          fontWeight: FontWeight.w600, color: th.pal.ink)),
                ]),
              ),
            ),
          ),
      ]);
    });
  }
}
