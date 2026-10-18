// bausteine.dart — Wiederkehrende Bausteine: Knoepfe, Karten, Hinweiskaesten, Zeit- und Fristtexte.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

/// Fristen, die die Oberflaeche anbietet. null = aus.
const Map<String, Duration?> _fristen = {
  "off": null,
  "1h": Duration(hours: 1),
  "24h": Duration(hours: 24),
  "7d": Duration(days: 7),
};

extension _Bausteine on _HomeState {
  // ---- helpers ----
  /// Uhrzeit einer Nachricht, bei aelteren zusaetzlich der Tag.
  String zeitVon(DateTime utc) {
    final l = utc.toLocal();
    final heute = DateTime.now();
    final hm = '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
    if (l.year == heute.year && l.month == heute.month && l.day == heute.day) {
      return hm;
    }
    return '${l.day.toString().padLeft(2, '0')}.'
        '${l.month.toString().padLeft(2, '0')}. $hm';
  }

  String fristText(Duration? d) {
    if (d == null) return t("off");
    if (d.inHours <= 1) return t("h1");
    if (d.inHours <= 24) return t("h24");
    return t("d7");
  }

  String get _fristSchluessel {
    final d = st.einstellungen.messageLifetime;
    if (d == null) return "off";
    if (d.inHours <= 1) return "1h";
    if (d.inHours <= 24) return "24h";
    return "7d";
  }

  /// Eine kurze Rueckmeldung am unteren Rand.
  void _hinweis(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  /// Eine kleine Rahmen-Marke in Monoschrift — derselbe Aufbau wie die
  /// Marke "VIA NEARBY" an einer Nachricht.
  ///
  /// STATT FARB-EMOJIS. Die App zeichnet ihre Zeichen als Text in ihrer
  /// eigenen Schrift (‹, +, ✓✓, ◷); ein buntes 📌 oder 🔕 aus dem
  /// Emoji-Satz des Telefons faellt darin heraus und sieht auf jedem
  /// Hersteller anders aus.
  Widget marke(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: p.tintLine)),
        child: Text(text.toUpperCase(),
            style: mono(size: 8, weight: FontWeight.w600, color: p.accLight, spacing: 0.9)),
      );

  /// Die Wahl-Markierung einer Umfrage-Antwort: gezeichnet, nicht als
  /// Unicode-Zeichen — Kreis fuer Einzelwahl, Kaestchen fuer Mehrfachwahl.
  Widget wahlZeichen(bool gewaehlt, bool mehrfach, Key key) => Container(
        key: key,
        width: 14,
        height: 14,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: mehrfach ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: mehrfach ? BorderRadius.circular(3) : null,
          border: Border.all(color: p.accLight, width: 1.4),
        ),
        child: gewaehlt
            ? Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: p.accLight,
                  shape: mehrfach ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: mehrfach ? BorderRadius.circular(1.5) : null,
                ),
              )
            : null,
      );

  /// Die Zahl der ungelesenen Nachrichten als Pille — leer, wenn keine.
  Widget ungelesenMarke(int zahl) => zahl <= 0
      ? const SizedBox(height: 16)
      : Container(
          key: const ValueKey('ungelesen-zahl'),
          constraints: const BoxConstraints(minWidth: 18),
          height: 18,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(99)),
          child: Text(zahl > 99 ? '99+' : '$zahl',
              style: mono(size: 9.5, weight: FontWeight.w700, color: p.onAcc, height: 1)),
        );

  // ---- small UI atoms ----
  Widget h2(String s, {double size = 26}) =>
      Text(s.toUpperCase(), style: doto(size: size, weight: FontWeight.w700, color: p.ink, spacing: 0.4, height: 1.1));

  Widget label6(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s.toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.8)),
      );

  /// [onTap] darf null sein: dann ist der Knopf sichtbar, aber nicht bedienbar
  /// — und behaelt den Standardzeiger, statt eine Hand zu zeigen, die nichts
  /// verspricht. [fuellung] und [rahmen] sind fuer die Faelle, in denen ein
  /// Knopf einen Hintergrund traegt (der Start des Verbindungstests) — dort
  /// gehoeren Fuellung und Rahmen zusammen, `accent` allein trifft es nicht.
  Widget outlineBtn(String labelTxt, VoidCallback? onTap,
      {bool accent = true, double fontSize = 12, EdgeInsets? padding, FontWeight weight = FontWeight.w600, Color? textColor, Color? fuellung, Color? rahmen}) {
    // RUECKMELDUNG OHNE LAYOUT: nur Rahmenfarbe und Fuellung wechseln, nie
    // Rahmenbreite oder Abstand. Ein Fokusring aussen herum haette jeden Knopf
    // im Fenster um 3 px verschoben — auch auf den vier fertigen
    // Schreibtisch-Bildschirmen, die outlineBtn mitbenutzen.
    //
    // p.accHover lag seit dem Entwurf in beiden Paletten und wurde nirgends
    // benutzt (data.dart:58/80, nachgesehen am 30.07.2026). Die Entscheidung
    // war also getroffen, nur nie angeschlossen.
    return _Bedienbar(
      imFenster: _imFenster,
      onTap: onTap,
      bau: (ueber, fokus) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: padding ?? const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fokus ? p.wash : fuellung,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: ueber || fokus
                    ? p.accHover
                    : (rahmen ?? (accent ? p.accent : p.line))),
          ),
          child: Text(labelTxt.toUpperCase(),
              style: mono(size: fontSize, weight: weight, color: textColor ?? (accent ? p.ink : p.muted), spacing: fontSize * 0.12)),
        ),
      ),
    );
  }

  /// Ein kleiner runder Knopf. SICHTBAR 30 dp, ANTIPPBAR 48.
  ///
  /// Die beiden Masse gehoeren nicht zusammen: 30 dp sieht richtig aus, 48 dp
  /// trifft man. Wer den Knopf auf 48 aufblaest, damit er sich treffen laesst,
  /// bekommt eine Oberflaeche aus lauter Klotzen; wer ihn bei 30 laesst, wird
  /// danebengetippt — nicht von ungeschickten Leuten, sondern von allen, nur
  /// unterschiedlich oft.
  Widget iconBtn(String glyph, VoidCallback onTap, {Color? color, double fontSize = 15}) =>
      _Bedienbar(
        imFenster: _imFenster,
        onTap: onTap,
        bau: (ueber, fokus) => Masse.trefferflaeche(
          onTap: onTap,
          child: Container(
            width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: fokus ? p.wash : null,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: ueber || fokus ? p.accHover : p.line)),
            child: Text(glyph, style: TextStyle(color: ueber ? p.accHover : (color ?? p.muted), fontSize: fontSize, height: 1)),
          ),
        ),
      );

  Widget bullet(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // GEZEICHNET, NICHT GESETZT, wie der Aufnahmepunkt. Bis 18.10.2026
          // stand hier ein Gedankenstrich als Zeichen; ein gezeichneter Punkt
          // haengt an keiner Schrift (im Browser kein Ersatzkaestchen) und
          // sitzt auf Hoehe der ersten Zeile (mono 12 ist rund 18 hoch).
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
                width: 5, height: 5,
                decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(1))),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(s, style: mono(size: 12, color: p.dim))),
        ]),
      );

  Widget smallBtn(String labelTxt, VoidCallback onTap) => _Bedienbar(
        imFenster: _imFenster,
        onTap: onTap,
        bau: (ueber, fokus) => Masse.trefferflaeche(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
                color: fokus ? p.wash : null,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: ueber || fokus ? p.accHover : p.line)),
            child: Text(labelTxt.toUpperCase(),
                style: mono(
                    size: 11,
                    weight: FontWeight.w400,
                    color: ueber ? p.accHover : p.muted,
                    spacing: 1.2)),
          ),
        ),
      );

  /// Was ueber der Eingabezeile steht, wenn etwas schiefging.
  ///
  /// AN EINER STELLE STATT AN FUENF. Vorher hing hier nur 'zuLang'; jede neue
  /// Fehlerart haette eine weitere if-Zeile im Aufbau gebraucht, und die
  /// erste, die jemand vergisst, verschwindet spurlos. Genau so war 'zuLang'
  /// selbst einmal gesetzt und nirgends gezeigt.
  /// Der dauerhafte Hinweis der Browser-Fassung. Gleiche Farben wie die
  /// Meldung nach dem Loeschen (`wiped`) — ein Hinweis, kein Fehler.
  Widget webHinweis(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
            color: p.tint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.tintLine)),
        child: Text(text, style: mono(size: 11.5, color: p.tintInk, height: 1.45)),
      );

  /// Ein Balken. Duenn, ohne Rahmen, ohne Rundung an den Enden — er soll den
  /// Blick nicht auf sich ziehen, sondern nur sagen, dass es vorangeht.
  Widget fortschrittsBalken(double anteil, {bool mitZahl = true}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
                color: p.line, borderRadius: BorderRadius.circular(2)),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: anteil.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                    color: p.accent, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
          if (mitZahl) ...[
            const SizedBox(height: 4),
            Text('${(anteil * 100).clamp(0, 100).toStringAsFixed(0)} %',
                style: mono(size: 9.5, color: p.dim)),
          ],
        ],
      );

  /// Eine Karte in den Einstellungen. Mit [onTap] ist sie eine ANTIPPBARE
  /// Zeile — und dann im Fenster auch zeigerbar, ueberfahrbar und tabbar.
  ///
  /// HIER UND NICHT AN JEDER ZEILE: 'set' hat die meisten antippbaren Zeilen der
  /// App, und die liefen alle als blanke GestureDetector um diese Karte. Ein
  /// [_Bedienbar] je Aufrufstelle waere derselbe Fehler in sechs Ausfuehrungen —
  /// die siebte Zeile haette ihn wieder. Ohne [onTap] bleibt die Karte reine
  /// Anzeige (die Fingerabdruck-Zeile), und dort gehoert kein Zeigerwechsel hin.
  Widget settingCard({required Widget child, VoidCallback? onTap}) {
    Widget karte(bool ueber, bool fokus) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          // RUECKMELDUNG OHNE LAYOUT, wie bei `outlineBtn`: nur die Fuellung
          // wechselt, kein Rahmen — ein Rahmen haette den Inhalt jeder Zeile
          // beim Ueberfahren um 1 px eingerueckt. `p.wash` liegt UEBER der
          // Flaeche und ersetzt sie nicht (er ist durchscheinend, 0x24/0x1F in
          // data.dart), sonst waere die Karte beim Ueberfahren verschwunden.
          decoration: BoxDecoration(
              color: ueber || fokus
                  ? Color.alphaBlend(p.wash, p.surf2)
                  : p.surf2,
              borderRadius: BorderRadius.circular(8)),
          child: child,
        );
    if (onTap == null) return karte(false, false);
    return _Bedienbar(
      imFenster: _imFenster,
      onTap: onTap,
      bau: (ueber, fokus) =>
          GestureDetector(onTap: onTap, child: karte(ueber, fokus)),
    );
  }

  Widget settingHead(String title, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13.5, color: p.ink)),
        Text(sub, style: mono(size: 11, color: p.dim)),
      ]);

  Widget segmented(List<String> keys, List<String> labels, String cur, ValueChanged<String> onPick) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        for (int i = 0; i < keys.length; i++)
          Expanded(
            child: _Bedienbar(
              imFenster: _imFenster,
              onTap: () => onPick(keys[i]),
              bau: (ueber, fokus) => GestureDetector(
                onTap: () => onPick(keys[i]),
                child: Container(
                  margin: EdgeInsets.only(right: i < keys.length - 1 ? 3 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: cur == keys[i]
                          ? p.tint
                          : (ueber || fokus ? p.wash : Colors.transparent),
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: cur == keys[i] ? p.tintInk : p.muted)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  /// Eine Zeile mit Schalter.
  ///
  /// DER ZUSTAND MUSS ANGESAGT WERDEN, und er wurde es nicht.
  ///
  /// Der Schalter ist reine Grafik: eine Farbe und eine Ausrichtung. Wer ihn
  /// sieht, weiss sofort, ob er an ist. Wer ihn vorlesen laesst, hoerte
  /// bisher nur "Neuen Nachrichten folgen. Springt zur neuesten Nachricht." —
  /// weder den Zustand noch ueberhaupt, dass es ein Schalter ist. Damit war
  /// jede Einstellung der App fuer einen blinden Nutzer unlesbar: umlegen
  /// ginge, feststellen wohin nicht.
  ///
  /// Aufgefallen am 29.07.2026 beim Durchgehen der taeglichen Ablaeufe auf
  /// dem Emulator — betroffen waren ALLE fuenf Schalter der Einstellungen.
  ///
  /// `toggled` setzt in Android die Merkmale "checkable" und "checked"; die
  /// Vorlesefunktion sagt dann von sich aus "an" oder "aus" dazu. `container`
  /// haelt den Knoten beisammen — sonst verschmilzt der Zustand mit der
  /// Nachbarzeile und haengt an beiden.
  Widget toggleRow(String title, String sub, bool on, VoidCallback onTap) =>
      Semantics(
        toggled: on,
        container: true,
        child: settingCard(
          onTap: onTap,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 13.5, color: p.ink)),
                Text(sub, style: mono(size: 11, color: p.dim)),
              ]),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 40, height: 22, padding: const EdgeInsets.all(2),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(color: on ? p.tint : p.surf, borderRadius: BorderRadius.circular(99), border: Border.all(color: on ? p.accent : p.line)),
              child: Container(width: 16, height: 16, decoration: BoxDecoration(color: on ? p.accLight : p.muted, shape: BoxShape.circle)),
            ),
          ]),
        ),
      );

  // ══════════════════════════════════════════════════════════ In der Naehe

  // ---- OVERLAYS ----
  Widget scrim(Widget child, {Alignment align = Alignment.bottomCenter, VoidCallback? onTapOutside}) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onTapOutside,
        child: Container(
          color: p.scrim,
          alignment: align,
          child: GestureDetector(onTap: () {}, child: child),
        ),
      ),
    );
  }

  /// Ein Blatt, das von unten hereinkommt.
  ///
  /// SCROLLBAR UND IN DER HOEHE BEGRENZT, seit dem 25.07.2026: die Anleitung
  /// zum Anstoss-Verteiler ist laenger als der Bildschirm. Vorher lief sie
  /// unten heraus — der Schliessen-Knopf lag ausserhalb, und weil die Karte
  /// den ganzen Bildschirm fuellte, gab es auch daneben nichts mehr zum
  /// Antippen. Das Blatt liess sich schlicht nicht mehr schliessen.
  ///
  /// 85 Prozent, damit oben ein Streifen frei bleibt: dort tippt man hin, um
  /// abzubrechen, und ohne ihn faende man diesen Weg nicht.
  Widget sheetCard({required List<Widget> children}) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: p.surf, borderRadius: const BorderRadius.vertical(top: Radius.circular(14)), border: Border.all(color: p.line)),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                22, 22, 22, 22 + MediaQuery.of(context).padding.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ),
      );

  /// Entsorgt Eingabefelder eines Dialogs ERST NACH seiner Schliess-Animation.
  ///
  /// `showDialog` kehrt zurueck, sobald `pop` gerufen ist — der Dialog
  /// zeichnet sich danach aber noch einmal, waehrend er ausblendet, und
  /// greift dabei auf seine Felder zu. Sofort entsorgt, warf das "A
  /// TextEditingController was used after being disposed" (Widget-Test
  /// 25.09.2026). Die Ausblendung eines Dialogs dauert 150 ms; eine halbe
  /// Sekunde laesst reichlich Luft.
  void _entsorgeNachDemSchliessen(List<TextEditingController> felder) {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      for (final f in felder) {
        f.dispose();
      }
    });
  }

  Widget kvRow(String k, String v, {bool mono2 = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k, style: mono(size: 12, color: p.muted))),
          const SizedBox(width: 16),
          Text(v, style: mono2 ? doto(size: 12, weight: FontWeight.w600, color: p.ink, spacing: 0.8) : TextStyle(fontSize: 12, color: p.ink)),
        ]),
      );

  /// Ein Textfeld im Stil der App, fuer Geheimnisse.
  Widget _geheimFeld(TextEditingController ctl, String hinweis,
      {bool aktiv = true, bool nurZahlen = false, bool autofokus = false}) {
    return Container(
      decoration: BoxDecoration(
          color: p.surf2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.line)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: ctl,
        enabled: aktiv,
        obscureText: true,
        autofocus: autofokus,
        keyboardType: nurZahlen ? TextInputType.number : null,
        style: mono(size: 14, color: p.ink, spacing: 2),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hinweis,
          hintStyle: mono(size: 13, color: p.dim),
        ),
      ),
    );
  }

  /// Die Bausteine fuer die Oberflaeche der Geraeteabmeldung
  /// (geraete_seite.dart).
  GeraeteStil get _geraeteStil => GeraeteStil(
        p: p,
        t: t,
        text: (g, f, {fett = false}) => mono(
            size: g, color: f, weight: fett ? FontWeight.w600 : FontWeight.w400),
        titel: (g, f) => doto(size: g, color: f, weight: FontWeight.w700),
        hinweis: (s, {warnend = true}) => _hinweisKasten(s, warnend: warnend),
      );

  /// Ein Kasten fuer etwas, das der Nutzer wissen muss.
  ///
  /// ZWEI BEDEUTUNGEN, ZWEI AUSSEHEN. Bis zum 25.07.2026 sah beides gleich
  /// aus: "dein Fingerabdruck wurde nicht erkannt" und "so richtest du ntfy
  /// ein" hatten dieselbe Farbe. Wer eine Oberflaeche schnell ueberfliegt —
  /// und das tut jeder — liest Farbe vor Text. Zwei Dinge in derselben Farbe
  /// sind fuer ihn dasselbe Ding.
  ///
  /// Der Akzent bleibt dem vorbehalten, was schiefging oder Aufmerksamkeit
  /// braucht. Ruhige Hinweise bekommen die gewoehnliche Umrandung — sie
  /// stehen da, ohne zu rufen.
  Widget _hinweisKasten(String text, {bool warnend = true}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Masse.innen),
        decoration: BoxDecoration(
            color: warnend ? p.tint : p.surf2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: warnend ? p.tintLine : p.line)),
        child: Text(text,
            style: mono(
                size: 11.5,
                color: warnend ? p.tintInk : p.muted,
                height: 1.5)),
      );

  /// Eine nummerierte Zeile in einer Anleitung.
  Widget _schritt(int nummer, String titel, String text,
      {List<Widget> knoepfe = const []}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: p.tint,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.tintLine)),
          child: Text('$nummer',
              style: mono(size: 10.5, weight: FontWeight.w600, color: p.tintInk)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titel, style: TextStyle(fontSize: 13.5, color: p.ink)),
            const SizedBox(height: 3),
            Text(text, style: mono(size: 11.5, color: p.muted, height: 1.5)),
            if (knoepfe.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: knoepfe),
            ],
          ]),
        ),
      ]),
    );
  }

  /// Ein kleiner Knopf innerhalb einer Anleitung.
  Widget _kleinerKnopf(String text, VoidCallback tun) => Masse.trefferflaeche(
        onTap: tun,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
              color: p.surf,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.line)),
          child: Text(text.toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w500,
                  color: p.accLight,
                  spacing: 1.1)),
        ),
      );

  Future<void> _oeffneLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }
}
