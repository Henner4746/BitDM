// identitaet.dart — Identitaet anlegen, zwoelf Woerter, eigene Adresse.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
// SICHERHEITSRELEVANT: wer die Sperre prueft, liest home.dart, sperre.dart
// und zugriff.dart und sucht in den uebrigen Teilen nach frischBestaetigt.
part of '../home.dart';

/// Kopiert etwas Geheimes und raeumt die Zwischenablage nach 30 Sekunden
/// wieder — aber nur, wenn dort noch GENAU das steht. Was der Nutzer
/// inzwischen selbst kopiert hat, bleibt.
///
/// Die Zwischenablage lesen andere Apps, Tastaturen und auf manchen
/// Telefonen auch die Cloud-Synchronisation; ein Teil der zwoelf Woerter
/// hat dort nichts auf Dauer verloren.
const Duration ablageFrist = Duration(seconds: 30);

extension _Identitaet on _HomeState {
  /// Legt eine echte Identitaet an und zeigt danach die zwoelf Woerter.
  ///
  /// Der Entwurf sprang von hier direkt zu den Anmeldeverfahren. Das ging
  /// nicht: die Phrase ist der EINZIGE Weg zurueck, wenn das Telefon weg ist,
  /// und wer sie nie zu sehen bekommt, verliert seine Identitaet beim ersten
  /// kaputten Bildschirm. Deshalb liegt jetzt ein Schritt dazwischen.
  Future<void> doCreate() async {
    setState(() { screen = 'creating'; wiped = false; });
    await st.identitaetAnlegen();
    if (!mounted) return;
    setState(() => screen = 'phrase');
  }

  /// Zeigt die zwoelf Woerter — nach frischer Anmeldung und mit erzwungenem
  /// Screenshot-Schutz, gleich was in den Einstellungen steht.
  Future<void> _zeigeWoerter() async {
    if (!await frischBestaetigt()) return;
    final List<String> woerter;
    try {
      woerter = await st.phraseAusEinstellungen();
    } catch (_) {
      _hinweis(t('phraseShowFailed'));
      return;
    }
    if (!mounted) return;
    await st.geheimnisSichtbar(true);
    try {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('woerter-dialog'),
          backgroundColor: p.surf,
          title: Text(t('phraseTitle'), style: doto(size: 17, color: p.ink)),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('phraseShowWarn'), style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
                const SizedBox(height: 12),
                _zweiSpaltenGitter(
                  woerter.length,
                  (i) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                    decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
                    child: Row(children: [
                      SizedBox(width: 20, child: Text('${i + 1}', style: mono(size: 10, color: p.dim))),
                      Expanded(child: Text(woerter[i],
                          style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 0.6))),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('close'))),
          ],
        ),
      );
    } finally {
      await st.geheimnisSichtbar(false);
    }
  }

  void _kopiereGeheim(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    Timer(ablageFrist, () async {
      try {
        final jetzt = await Clipboard.getData(Clipboard.kTextPlain);
        if (jetzt?.text == text) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {
        // Keine Zwischenablage — dann gibt es auch nichts zu raeumen.
      }
    });
  }

  /// Die eigene Adresse, wie der Entwurf sie zeigt: Vierergruppen mit
  /// Bindestrichen. Solange noch keine Identitaet da ist, bleibt es leer.
  String get meineAdresseAnzeige =>
      st.meineAdresse.isEmpty ? '' : adresseFormatiert(st.meineAdresse);

  void copyId() {
    if (st.meineAdresse.isEmpty) return;
    // MIT Bindestrichen, genau wie die App sie ueberall zeigt.
    //
    // Bis zum 25.07.2026 ging die rohe Adresse in die Zwischenablage. Das war
    // gut gemeint — sie sollte anderswo ohne Nacharbeit funktionieren — hatte
    // aber eine Folge, die einen Tester gekostet hat: das Beispiel im
    // Eingabefeld zeigte Striche, das Eingefuegte hatte keine, und es sah aus,
    // als waere beim Kopieren etwas schiefgegangen.
    //
    // Die Striche schaden nirgends: jedes Eingabefeld dieser App entfernt sie
    // wieder, und ueber 56 Zeichen hinweg machen sie den Unterschied zwischen
    // lesbar und nicht lesbar. Im QR-Code steht weiterhin die rohe Adresse —
    // dort zaehlt Dichte, nicht Lesbarkeit.
    Clipboard.setData(ClipboardData(text: adresseFormatiert(st.meineAdresse)));
    setState(() => copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () { if (mounted) setState(() => copied = false); });
  }

  // ---- ONBOARD ----
  Widget onboardScreen() {
    return LayoutBuilder(builder: (ctx, con) {
      // IM FENSTER OBEN ANSCHLAGEN. Der Inhalt ist etwa 700 px hoch; in dem
      // 984x1040 grossen Fenster vom 30.07.2026 blieben durch die Zentrierung
      // oben und unten je ueber 160 px tote Flaeche, die die Seitenlinien der
      // Spalte als fast leeren Kasten mitzeichneten.
      //
      // Damit fallen ConstrainedBox und IntrinsicHeight im Fenster weg: sie
      // sind nur fuer die Zentrierung auf niedrigen Telefonen da, und
      // IntrinsicHeight kostet bei jedem Aufbau einen zweiten Layout-Durchgang
      // ueber den ganzen Teilbaum.
      final Widget inhalt = Padding(
              // 40 px Kopfabstand im Fenster, gemessen an 1040 px Fensterhoehe:
              // weniger klebte das Zeichen an der Fensterkante, mehr fing an,
              // wieder wie Zentrierung auszusehen. Die 22 sind der Rand der
              // Abfolgen (Masse.rand).
              padding: EdgeInsets.fromLTRB(22, _imFenster ? 40 : 22, 22, 22),
              child: Column(
                mainAxisAlignment: _imFenster
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46, height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                    child: Text('B', style: doto(size: 22, weight: FontWeight.w900, color: p.accLight)),
                  ),
                  const SizedBox(height: 16),
                  // DIE UEBERSCHRIFT WAECHST NICHT MIT. [_schriftFaktor] ist
                  // fuer Lesetext gedacht; 36 mal 1.15 waeren 41 pt und
                  // brachen "SECURE MESSAGING" in der 560er Spalte um. 28 mal
                  // 1.15 sind 32 pt — im Fenster also bewusst KLEINER als auf
                  // dem Telefon, wo die Ueberschrift den ganzen Bildschirm
                  // traegt (30.07.2026).
                  Text('${t('h1a')}\n${t('h1b')}', style: doto(size: _imFenster ? 28 : 36, weight: FontWeight.w800, color: p.ink, height: 1.05, spacing: 0.4)),
                  const SizedBox(height: 10),
                  Text(t('intro'), style: mono(size: 13.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
                  const SizedBox(height: 16),
                  bullet(t('b1')), bullet(t('b2')), bullet(t('b3')),
                  // IM BROWSER VOR DEM ERSTEN KNOPF, nicht irgendwo in den
                  // Einstellungen: wer hier eine Identitaet anlegt, muss
                  // wissen, dass sie das Neuladen ohne Passwort nicht
                  // ueberlebt (main() bei `basis:`).
                  if (kIsWeb) ...[
                    const SizedBox(height: 12),
                    webHinweis(t('webOnboard')),
                  ],
                  // Gerade abgemeldet (geraete_seite.dart): warum die App
                  // aussieht wie frisch installiert, und wie es zurueckgeht.
                  if (st.abgemeldetHinweis) ...[
                    const SizedBox(height: 12),
                    _hinweisKasten(abgemeldetText(st, t)),
                  ],
                  if (wiped) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                      child: Text(t('wiped'), style: mono(size: 12, color: p.tintInk)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _knopfBreite(outlineBtn(t('create'), doCreate, padding: const EdgeInsets.all(15), fontSize: 13)),
                  const SizedBox(height: 8),
                  Text(t('createNote'), style: mono(size: 11, color: p.dim)),

                  // DER WEG ZURUECK. Er fehlte bis zum 25.07.2026 ganz —
                  // waehrend der Bildschirm mit den zwoelf Woertern sagte,
                  // sie seien "der einzige Weg zurueck, wenn dieses Telefon
                  // verloren ist". Wer sie brav aufgeschrieben hatte, stand
                  // auf einem neuen Telefon vor einer App, die sie nirgends
                  // annahm.
                  //
                  // Leiser gesetzt als das Anlegen: die meisten kommen hier
                  // zum ersten Mal an. Aber sichtbar, denn wer ihn braucht,
                  // braucht ihn dringend.
                  const SizedBox(height: 22),
                  Container(height: 1, color: p.lineSoft),
                  const SizedBox(height: 18),
                  // EIN VERWEIS MUSS SICH WIE EINER VERHALTEN. Bisher war das
                  // ein Text in Akzentfarbe, ueber dem der Zeiger ein
                  // Text-Cursor blieb — am Schreibtisch das Zeichen fuer "hier
                  // ist nichts". Und das ist der Weg, den nach einem
                  // Geraeteverlust jemand dringend braucht.
                  //
                  // Unterstrichen wird nur beim Ueberfahren und im Fokus:
                  // dauerhaft unterstrichen saehe er auf dem Telefon anders aus
                  // als heute, und dort ist er unstrittig.
                  _restoreVerweis(),
                  const SizedBox(height: 6),
                  Text(t('restoreLinkSub'), style: mono(size: 11, color: p.dim, height: 1.5)),
                ],
              ),
      );

      return SingleChildScrollView(
        child: _imFenster
            ? inhalt
            : ConstrainedBox(
                constraints: BoxConstraints(minHeight: con.maxHeight),
                child: IntrinsicHeight(child: inhalt),
              ),
      );
    });
  }

  /// Der Weg zur Wiederherstellung auf 'onboard'.
  Widget _restoreVerweis() {
    void hin() {
      phraseCtl.clear();
      setState(() { screen = 'restore'; restoreFehler = null; });
    }

    return _Bedienbar(
      imFenster: _imFenster,
      onTap: hin,
      bau: (ueber, fokus) => GestureDetector(
        onTap: hin,
        child: Text(
          t('restoreLink').toUpperCase(),
          style: mono(
            size: 11,
            weight: FontWeight.w600,
            color: ueber || fokus ? p.accHover : p.accLight,
            spacing: 1.2,
          ).copyWith(
            decoration:
                ueber || fokus ? TextDecoration.underline : TextDecoration.none,
            decorationColor: p.accHover,
          ),
        ),
      ),
    );
  }

  // ---- WIRD ANGELEGT ----
  //
  // EIN DREHENDER RING GEHOERT DAZU. Vorher war das eine einzige graue Zeile
  // in der Mitte — in einem 984x1040 grossen Fenster ein winziger Schriftzug
  // in einer leeren Flaeche, nicht zu unterscheiden von einer haengenden App.
  // Der Bildschirm steht beim Anlegen, beim Wiederherstellen und beim
  // Loeschen, und das Wiederherstellen dauert wegen PBKDF2 merkbar laenger als
  // die versprochene Sekunde.
  //
  // KEIN BALKEN UND KEINE PROZENTE: die Dauer ist nicht bekannt. Dieselben
  // Masse wie der Ring in `methodRow` (strokeWidth 1.6, p.accLight), damit es
  // nicht nach einem zweiten Entwurf aussieht.
  //
  // NUR IM FENSTER, und diesmal nicht nur wegen Android: ein Ring dreht sich
  // endlos, und `pumpAndSettle` wartet auf das Ende einer Animation. Im
  // Widget-Test meldet Flutter android — dort bleibt dieser Bildschirm die
  // eine Zeile, und kein Test wartet auf etwas, das nie aufhoert.
  Widget arbeitetScreen() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_imFenster) ...[
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: p.accLight),
            ),
            const SizedBox(height: 16),
          ],
          Text(t('creating').toUpperCase(),
              style: mono(size: 12, color: p.dim, spacing: 1.8)),
        ]),
      );

  // ---- WIEDERHERSTELLUNGSPHRASE ----
  //
  // Diesen Bildschirm gab es im Entwurf nicht. Er ist trotzdem nicht optional:
  // die zwoelf Woerter sind der einzige Weg zurueck, wenn das Telefon
  // verloren, kaputt oder geloescht ist. Es gibt keinen Server, bei dem man
  // sich ausweisen und die Identitaet zurueckholen koennte — wer sie nicht
  // notiert hat, ist weg.
  //
  // Gestaltet mit denselben Bausteinen wie der Rest, damit sich nichts
  // Fremdes anfuehlt.
  Widget phraseScreen() {
    final woerter = st.frischePhrase ?? const <String>[];

    // ZWEI SPALTEN AUS DEM PLATZ DER SPALTE, nicht aus der Fensterbreite —
    // Begruendung und Zahlen stehen an [_zweiSpaltenGitter].
    final Widget gitter = _zweiSpaltenGitter(
      woerter.length,
      (i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          SizedBox(
            width: 20,
            child: Text('${i + 1}', style: mono(size: 10, color: p.dim)),
          ),
          Expanded(
            child: Text(woerter[i],
                style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
          ),
        ]),
      ),
    );

    final Widget inhalt = Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('phraseTitle')),
        const SizedBox(height: 6),
        Text(t('phraseSub'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        // IM FENSTER KEIN Expanded. Es frisst dort die ganze Resthoehe, und
        // Warnkasten und Knopf klebten am unteren Fensterrand — weit weg von
        // den Woertern, auf die sie sich beziehen. Stattdessen scrollt der
        // ganze Bildschirm (wie 'restore' und 'test'); das faengt gleich den
        // zweiten Fall mit ab: zieht man das Fenster niedriger als etwa 350 px,
        // lief der Inhalt vorher in den gelb-schwarzen Ueberlaufbalken.
        if (_imFenster) gitter else Expanded(child: SingleChildScrollView(child: gitter)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.tint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.tintLine),
          ),
          child: Text(t('phraseWarn'), style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
        ),
        const SizedBox(height: 12),
        _knopfBreite(outlineBtn(t('phraseDone'), () {
          st.phraseBestaetigt();
          go('secure');
        }, padding: const EdgeInsets.all(13))),
      ]),
    );

    return _imFenster ? SingleChildScrollView(child: inhalt) : inhalt;
  }

  // ---- MY ID ----
  Widget idScreen() {
    // OHNE IDENTITAET GIBT ES NICHTS ZU ZEIGEN. Vorher stand hier ein QR-Code
    // aus einer leeren Zeichenkette und darunter leere Kaestchen — eine Seite,
    // die aussah, als waere sie kaputt. Erreichbar ist dieser Zustand ueber
    // die Reiter, bevor eine Identitaet angelegt wurde.
    if (st.meineAdresse.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            Masse.rand, Masse.block, Masse.rand, Masse.rand),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          h2(t('myId')),
          const SizedBox(height: Masse.block),
          _hinweisKasten(t('myIdEmpty'), warnend: false),
        ]),
      );
    }

    final bloecke = meineAdresseAnzeige.split('-');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('myId')),
        const SizedBox(height: 4),
        Text(t('myIdSub'), style: mono(size: 12, color: p.dim)),
        const SizedBox(height: 16),
        // HELLE KARTE, DUNKLE MODULE — auch im dunklen Thema.
        //
        // Ein QR-Code ist nach Norm dunkel auf hell. Umgekehrt lesen ihn viele
        // Kameras nicht; ZXing kehrt nicht von sich aus um. Der Code hier soll
        // aber von JEDER App gelesen werden koennen, nicht nur von BitDM.
        // Deshalb bricht diese eine Flaeche mit dem dunklen Thema.
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: const Color(0xFFF2F2F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.line)),
            child: QrBild(
              st.meineAdresse,
              vordergrund: const Color(0xFF0B0B10),
              hintergrund: const Color(0xFFF2F2F2),
              kante: 220,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // EINE BESCHRIFTUNG FUER DIE GANZE ADRESSE, nicht vierzehn.
        //
        // Die Vierergruppen sind eine Lesehilfe fuer die AUGEN — sie machen
        // aus 56 Zeichen etwas, das man abtippen und vergleichen kann. Fuer
        // einen Screenreader sind sie das Gegenteil: vierzehn
        // zusammenhanglose Haeppchen, zwischen denen er jedes Mal neu
        // ansetzt. `excludeSemantics` blendet sie deshalb aus und legt EINEN
        // Text darueber.
        //
        // Aufgefallen ist es an einer anderen Ecke: die Adresse liess sich auf
        // dem Galaxy S10 nicht aus dem Bedienungsbaum lesen (auf dem S25
        // schon), und damit war ein Zwei-Telefon-Test nicht zu fahren. Der
        // Grund war derselbe wie beim Screenreader — die Gruppen sind
        // vierzehn beilaeufige Textknoten und keine Angabe. Ein Testkniff
        // haette mein Problem geloest und das der Nutzer stehen gelassen.
        //
        // DIESELBE BREITENRECHNUNG WIE AUF 'phrase', und das ist der Punkt:
        // hier stand bis zum 30.07.2026 noch die Fensterbreite. Ab 1402 px
        // Fenster fielen die vierzehn Vierergruppen zu vierzehn spaltenbreiten
        // Zeilen zusammen — auf dem Bildschirm, dessen Zweck das Vergleichen
        // der Adresse ist. Zahlen und Herleitung an [_zweiSpaltenGitter].
        Semantics(
          label: adresseFormatiert(st.meineAdresse),
          excludeSemantics: true,
          child: _zweiSpaltenGitter(
            bloecke.length,
            (i) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                  color: p.surf2, borderRadius: BorderRadius.circular(4)),
              child: Text(bloecke[i],
                  style: doto(
                      size: 16,
                      weight: FontWeight.w600,
                      color: p.ink,
                      spacing: 1.4)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Das Schluesselbild: wer die Adresse weitergibt, kann das Bild gleich
        // mit vergleichen lassen — schneller als 56 Zeichen.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SchluesselbildAnsicht(schluessel: st.meineAdresse, farbe: p.accLight, leer: p.line, punkt: 9, beschriftung: t('keyArtLabel')),
          const SizedBox(width: 14),
          Expanded(child: Text(t('keyArtSelf'), style: mono(size: 11, color: p.dim, height: 1.5))),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: outlineBtn(copied ? t('copied') : t('copy'), copyId, padding: const EdgeInsets.all(11))),
          // TEILEN NUR AUF ANDROID: der Teilen-Dialog haengt am Kotlin-Kanal.
          // Am Rechner und im Browser war der Knopf da und tat nichts — die
          // Meldung ging in `lockFehler`, und den zeigt dieser Bildschirm nicht.
          if (_nurAufAndroid) ...[
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('share'), () async {
              // Geteilt wird die Adresse MIT Strichen — genau das, was der
              // Empfaenger dann in sein Eingabefeld einfuegt und dort auch als
              // Beispiel stehen sieht.
              final ok = await FremdeApp.teile(
                  adresseFormatiert(st.meineAdresse),
                  titel: t('share'));
              if (!ok && mounted) _hinweis(t('shareFailed'));
            }, accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
          ],
        ]),
        const SizedBox(height: 16),

        // WIE VIELE GERAETE AUF DIESER IDENTITAET SITZEN — und seit der
        // Geraeteabmeldung (docs/GERAETEABMELDUNG.md) der Weg, eines davon
        // abzumelden. Die Zahl bleibt verpflichtend: aus einem unsichtbaren
        // Mitleser wird eine sichtbare Zahl, die nicht stimmt. Ohne
        // Geraeteliste (alter Relay) bleibt es bei der Warnung, dass Abmelden
        // nicht geht. Nichts steht da, solange niemand gefragt hat. Alles
        // Weitere in geraete_seite.dart.
        if (st.geraeteZahl != null || st.hatGeraeteliste) ...[
          GeraeteKachel(st: st, stil: _geraeteStil),
          const SizedBox(height: 16),
        ],

        Text(t('idNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }
}
