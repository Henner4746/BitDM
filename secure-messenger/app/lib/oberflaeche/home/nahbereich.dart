// nahbereich.dart — Nahbereich: Block in den Einstellungen, Funkrechte, Hilfe, Verbindungstest.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Nahbereich on _HomeState {
  /// Der Funk und die Einschraenkung — in dieser Reihenfolge, in EINEM
  /// Abschnitt.
  ///
  /// WARUM ZUSAMMEN. Vorher gab es nur "nur in der Naehe", und der sass bei
  /// der Sicherheit. Das war richtig, solange es den Funk nicht gab: der
  /// Schalter verbot einen Server und baute keinen Weg. Jetzt gibt es beides,
  /// und getrennt waere es irrefuehrend — wer nur die Einschraenkung sieht,
  /// legt sie um und wundert sich, dass nichts mehr ankommt.
  ///
  /// Die Reihenfolge ist die Aussage: erst der WEG, dann das VERBOT.
  Widget nahbereichBlock() {
    final z = st.funkzustand;
    final prefs = st.einstellungen;

    // NUR EIN HINDERNIS, das erste, das zutrifft. Vier Zeilen untereinander
    // waeren eine Fehlerliste; gebraucht wird der naechste Schritt.
    //
    // Die Reihenfolge ist nicht beliebig: die fehlende Berechtigung steht vor
    // dem ausgeschalteten Bluetooth, weil sie sich mit einem Tipp in der App
    // erledigen laesst und das andere einen Weg in die Systemleiste braucht.
    //
    // NICHT NUR BEI `!z.geht`: `geht` enthaelt `erweitert` nicht. Bis
    // 15.10.2026 stand die ganze Kette in `if (!z.geht)`, und ein Telefon mit
    // Bluetooth 4.2 bekam gar keinen Hinweis — der Schalter ging an, und es
    // war fuer niemanden sichtbar.
    String? hindernis;
    Widget? ausweg;
    if (z != null) {
      if (z.zuAlt) {
        hindernis = t('nearbyTooOld');
      } else if (!z.vorhanden) {
        hindernis = t('nearbyNoHardware');
      } else if (!z.rechte) {
        // Der Knopf aus den Anleitungen, links eingerueckt wie die Zeile
        // darueber. `Masse.trefferflaeche` sorgt darin fuer eine Flaeche, die
        // man auch mit dem Daumen trifft — deshalb kein eigener Knopf hier.
        Widget links(Widget w) => Align(
            alignment: Alignment.centerLeft,
            child: Padding(
                padding: const EdgeInsets.only(left: 11), child: w));
        if (st.rechteEndgueltigWeg) {
          hindernis = t('nearbyBlocked');
          ausweg = links(_kleinerKnopf(
              t('nearbyOpenSettings'), st.oeffneSystemeinstellungen));
        } else {
          hindernis = t('nearbyNoPerm');
          ausweg = links(_kleinerKnopf(t('nearbyAllow'), _fordereFunkRechte));
        }
      } else if (!z.an) {
        hindernis = t('nearbyBtOff');
      } else if (!z.erweitert) {
        // ERST NACH `an`, und das ist keine Geschmackssache: Android meldet
        // `isLeExtendedAdvertisingSupported()` bei ausgeschaltetem Bluetooth
        // als false (BluetoothAdapter `getLeAccess`). Davor gefragt, stuende
        // bei jedem, der nur Bluetooth aus hat, "dieses Telefon kann es
        // nicht" — so war es bis 15.10.2026, mit "kein Bluetooth LE".
        hindernis = t('nearbyNoExtended');
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      label6(t('nearby')),
      toggleRow(t('nearbyUse'), t('nearbyUseSub'), prefs.naheAn, _schalteFunkUm),

      if (hindernis != null) ...[
        const SizedBox(height: 3),
        _hinweisKasten(hindernis, warnend: false),
        if (ausweg != null) ...[
          const SizedBox(height: 6),
          ausweg,
        ],
      ],

      // Was es KOSTET, und zwar erst wenn es an ist. Vorher waere es eine
      // Warnung vor etwas, das niemand vorhat.
      // Der Abstand ist hier die Aussage: eng an den Schalter darueber, weit
      // weg vom naechsten Feld. Mit gleichem Abstand nach beiden Seiten las
      // sich der Satz wie eine Anmerkung zu "nur in der Naehe" — also zu dem
      // Schalter, um den es dabei gerade nicht geht.
      // Nicht neben einem Hindernis: "kostet Akku" unter "kein Bluetooth 5"
      // laese sich, als funke das Telefon trotzdem.
      if (prefs.naheAn && hindernis == null && (z?.geht ?? false)) ...[
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Text(t('nearbyCost'),
              style: mono(size: 11, color: p.dim, height: 1.5)),
        ),
        const SizedBox(height: 13),
      ] else
        const SizedBox(height: 3),

      toggleRow(t('nearOnly'), t('nearOnlySub'), prefs.nurNahbereich,
          () => st.setzeEinstellungen(
              prefs.copyWith(nurNahbereich: !prefs.nurNahbereich))),

      // WIEDER DA, seit die Wegwahl am Nachrichtenweg haengt.
      //
      // Der Hinweis lag eine Weile still, weil er falscher Rat war: der Funk
      // fand zwar Kontakte, trug aber keine Nachrichten, und Bluetooth
      // einzuschalten aenderte an der Zustellung nichts. Jetzt aendert es
      // alles — mit "nur in der Naehe" allein geht ueberhaupt nichts hinaus.
      //
      // NUR WENN "NUR IN DER NAEHE" AN IST UND DER FUNK AUS. Sonst waere es
      // eine Werbung fuer eine Einstellung, um die gerade niemand gebeten
      // hat; hier ist es der fehlende zweite Schalter zu einer Entscheidung,
      // die der Nutzer schon getroffen hat.
      if (prefs.nurNahbereich && !prefs.naheAn) ...[
        const SizedBox(height: 3),
        _hinweisKasten(t('nearbyNeedsBoth')),
      ],

      // DER KASTEN GEHOERT UNTER SEINEN SCHALTER, nicht unter den Link. Er
      // stand vorher darunter, und dazwischen las sich "Wie das funktioniert"
      // wie eine Ueberschrift zu einer Warnung, zu der es nicht gehoert.
      if (prefs.nurNahbereich) ...[
        const SizedBox(height: 3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Masse.innen),
          decoration: BoxDecoration(
              color: p.tint,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.tintLine)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('nearOnlyNow').toUpperCase(),
                style: mono(
                    size: 10,
                    weight: FontWeight.w600,
                    color: p.tintInk,
                    spacing: 1.1)),
            const SizedBox(height: Masse.eng),
            // ZWEI FASSUNGEN, je nachdem ob der Funk an ist. Mit nur einer
            // stuende "Bluetooth ist noch nicht gebaut" direkt unter einem
            // eingeschalteten Bluetooth-Schalter. Jeder Satz fuer sich waere
            // wahr, zusammen saehe es nach einem Fehler aus — und der Nutzer
            // wuesste nicht, welchem von beiden er glauben soll.
            Text(prefs.naheAn ? t('nearOnlyWarnRadio') : t('nearOnlyWarn'),
                style: mono(size: 11.5, color: p.tintInk, height: 1.55)),
          ]),
        ),
      ],

      // Die Anleitung ist IMMER erreichbar, nicht erst wenn etwas an ist.
      // Wer wissen will, was ihn erwartet, soll nachlesen koennen, BEVOR er
      // etwas umlegt.
      const SizedBox(height: 3),
      GestureDetector(
        onTap: () => go('nahHilfe'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 2, 11, 6),
          child: Text(t('nearGuideLink').toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w600,
                  color: p.accLight,
                  spacing: 1.2)),
        ),
      ),
    ]);
  }

  Future<void> _fordereFunkRechte() async {
    await st.erlaubeFunk();
    if (mounted) setState(() {});
  }

  /// Beim EINSCHALTEN erst fragen, dann umlegen.
  ///
  /// Ein Schalter, der auf "an" steht, waehrend die Berechtigung fehlt, waere
  /// eine Einstellung ohne Wirkung — und der Nutzer haette keinen Anlass,
  /// weiter zu suchen. Ausschalten geht dagegen immer sofort.
  /// Entfernt den Kontakt der offenen Unterhaltung — nach Rueckfrage.
  ///
  /// MIT RUECKFRAGE, weil es den ganzen Verlauf mitnimmt und sich nicht
  /// zurueckholen laesst. Der Knopf steht bewusst ohne Betonung da: er ist
  /// noetig, aber nichts, wozu die Oberflaeche einladen sollte.
  Future<void> _entferneOffenenKontakt() async {
    final id = chat;
    if (id == null) return;
    final sicher = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        title: Text(t('removeContact'),
            style: mono(size: 15, weight: FontWeight.w500, color: p.ink)),
        content: Text(t('removeAsk'),
            style: mono(size: 12.5, color: p.muted, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('cancel'), style: mono(size: 12.5, color: p.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('removeDo'),
                style: mono(size: 12.5, weight: FontWeight.w500, color: p.accLight)),
          ),
        ],
      ),
    );
    if (sicher != true || !mounted) return;
    await st.entferneKontakt(id);
    if (!mounted) return;
    // ZURUECK ZUR LISTE, denn die Unterhaltung, die hier offen war, gibt es
    // nicht mehr. Stehenzubleiben zeigte einen leeren Chat zu einem Kontakt,
    // den es nicht mehr gibt.
    setState(() {
      sheet = false;
      chat = null;
    });
    go('chats');
  }

  Future<void> _schalteFunkUm() async {
    final prefs = st.einstellungen;
    if (prefs.naheAn) {
      await st.setzeEinstellungen(prefs.copyWith(naheAn: false));
      return;
    }
    await st.pruefeFunk();
    final z = st.funkzustand;
    if (z != null && !z.geht && !z.rechte && !z.zuAlt && z.vorhanden) {
      final ok = await st.erlaubeFunk();
      if (!ok) {
        if (mounted) setState(() {});
        return;
      }
    }
    await st.setzeEinstellungen(st.einstellungen.copyWith(naheAn: true));
    if (mounted) setState(() {});
  }

  /// Was das Zeichen an einer Nachricht bedeutet.
  void _erklaereNaehe() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 26),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 36,
                    height: 3,
                    decoration: BoxDecoration(
                        color: p.line,
                        borderRadius: BorderRadius.circular(99))),
              ),
              const SizedBox(height: 14),
              h2(t('viaNearbyTitle'), size: 18),
              const SizedBox(height: 10),
              Text(t('viaNearbyWhat'),
                  style: mono(size: 12.5, color: p.muted, height: 1.55)),
            ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════ Verbindungstest

  /// Sagt, WO die Kette reisst — statt "versuch es nochmal".
  ///
  /// Der Bildschirm ist bewusst nuechtern: eine Zeile je Glied, ein Zeichen
  /// davor, die Dauer dahinter, und beim ersten, das nicht haelt, der
  /// technische Grund. Wer ihn abfotografiert und weiterschickt, hat alles
  /// beisammen, was jemand zum Beheben braucht.
  Widget testScreen() {
    Color farbe(Befund b) => switch (b) {
          Befund.gut => p.accLight,
          Befund.schlecht => p.accent,
          Befund.hinweis => p.accLight,
          Befund.uebersprungen => p.dim,
        };
    String zeichen(Befund b) => switch (b) {
          Befund.gut => 'OK',
          Befund.schlecht => '!',
          Befund.hinweis => '·',
          Befund.uebersprungen => '-',
        };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('set')),
          const SizedBox(width: 11),
          Expanded(child: h2(t('connTest'), size: 20)),
        ]),
        const SizedBox(height: 6),
        Text(t('connTestSub'), style: mono(size: 12, color: p.dim, height: 1.5)),
        const SizedBox(height: 16),

        for (final sch in st.testSchritte)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
                color: p.surf2, borderRadius: BorderRadius.circular(8)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(
                  width: 28,
                  child: Text(zeichen(sch.befund),
                      style: mono(
                          size: 11,
                          weight: FontWeight.w600,
                          color: farbe(sch.befund))),
                ),
                Expanded(
                  child: Text(t(sch.schluessel),
                      style: TextStyle(fontSize: 13.5, color: p.ink)),
                ),
                if (sch.dauer != null)
                  Text('${sch.dauer!.inMilliseconds} ms',
                      style: mono(size: 10.5, color: p.dim)),
              ]),
              // DER GRUND STEHT DABEI, nicht in einem Protokoll, das niemand
              // findet. Unuebersetzt: er soll weitergegeben werden koennen,
              // und eine uebersetzte Fehlermeldung ist beim Suchen wertlos.
              if (sch.detail != null)
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 6),
                  child: SelectableText(sch.detail!,
                      style: mono(size: 11, color: p.muted, height: 1.5)),
                ),
              if (sch.befund == Befund.hinweis &&
                  sch.schluessel == 'pruefNahbereich')
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 6),
                  child: Text(t('pruefNahbereichWas'),
                      style: mono(size: 11, color: p.muted, height: 1.5)),
                ),
            ]),
          ),

        if (st.testLaeuft)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child:
                Text(t('connTestRunning'), style: mono(size: 11.5, color: p.dim)),
          ),

        const SizedBox(height: 12),
        // AUF outlineBtn UMGESTELLT. Vorher war das ein eigener
        // GestureDetector mit `width: double.infinity` — ein 516 px breites
        // Banner ohne Zeigerwechsel, ohne Ueberfahr-Zustand und ohne Fokus,
        // und waehrend `testLaeuft` war `onTap` null, wobei der Kasten weiter
        // wie ein Knopf aussah. Ueber den Baustein greift beides jetzt von
        // selbst; die Sonderfarben liegen in `fuellung`, `accent` und
        // `textColor`.
        _knopfBreite(outlineBtn(
          st.testSchritte.isEmpty ? t('connTestStart') : t('connTestAgain'),
          st.testLaeuft ? null : () => st.verbindungPruefen(),
          fuellung: st.testLaeuft ? p.surf2 : p.tint,
          rahmen: st.testLaeuft ? p.line : p.tintLine,
          textColor: st.testLaeuft ? p.dim : p.tintInk,
          fontSize: 11,
          padding: const EdgeInsets.symmetric(vertical: 12),
        )),

        // WAS ZULETZT SCHIEFGING, auch wenn der Test gerade gruen ist. Ein
        // Fehler, der nur manchmal auftritt, waere sonst nicht zu fassen: bis
        // der Nutzer den Test oeffnet, ist die Lage wieder in Ordnung.
        if (st.letzteTechnischeMeldung != null) ...[
          const SizedBox(height: 22),
          label6(t('connLast')),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: p.surf2, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(st.letzteTechnischeMeldung!,
                style: mono(size: 11, color: p.muted, height: 1.5)),
          ),
        ],
      ]),
    );
  }

  // ══════════════════════════════════════════════════ Anleitung zur Naehe

  /// Schritt fuer Schritt, was "nur in der Naehe" verlangt und was es leistet.
  ///
  /// EHRLICH AN DER STELLE, AN DER ES WEHTUT: Funk erreicht nur Kontakte, die
  /// schon bestaetigt sind, und nur ueber wenige Meter. Das steht hier nicht im
  /// Kleingedruckten, sondern in einem eigenen Kasten ganz oben — wer die
  /// Schritte befolgt und dann vergeblich wartet, verliert das Vertrauen in
  /// alles andere mit. Bis 15.10.2026 stand in diesem Kasten, die Zustellung
  /// ueber Funk sei noch nicht gebaut; das war seit dem 29.07.2026 ueberholt.
  ///
  /// NUR UNTER ANDROID ERREICHBAR. Der einzige Weg hierher ist `go('nahHilfe')`
  /// in `nahbereichBlock()`, und der ganze Block steht in den Einstellungen
  /// hinter `if (_nurAufAndroid)`. Auf Windows, Linux und im Web kann diesen
  /// Bildschirm niemand oeffnen — beim Desktop-Feinschliff am 30.07.2026 ist er
  /// deshalb bewusst ungeschliffen geblieben (er hat dieselben Maengel wie
  /// 'test' hatte, aber niemand sieht sie). Wenn der Nahbereich fuer den
  /// Desktop kommt, faellt er zusammen mit `nahbereichBlock` wieder an.
  Widget nahHilfeScreen() {
    Widget schritt(int nr, String titel, String text) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
              color: p.surf2, borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 26,
              child: Text('$nr',
                  style: doto(
                      size: 15, weight: FontWeight.w600, color: p.accLight)),
            ),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titel, style: TextStyle(fontSize: 13.5, color: p.ink)),
                    const SizedBox(height: 3),
                    Text(text,
                        style: mono(size: 11.5, color: p.muted, height: 1.55)),
                  ]),
            ),
          ]),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('set')),
          const SizedBox(width: 11),
          Expanded(child: h2(t('nearGuide'), size: 20)),
        ]),
        const SizedBox(height: 12),
        _hinweisKasten(t('nearGuideKurz')),
        const SizedBox(height: 18),
        label6(t('nearGuideWhat')),
        Text(t('nearGuideWhatBody'),
            style: mono(size: 12, color: p.muted, height: 1.6)),
        const SizedBox(height: 18),
        label6(t('nearGuideSteps')),
        schritt(1, t('nearStep1'), t('nearStep1Body')),
        schritt(2, t('nearStep2'), t('nearStep2Body')),
        schritt(3, t('nearStep3'), t('nearStep3Body')),
        schritt(4, t('nearStep4'), t('nearStep4Body')),
        schritt(5, t('nearStep5'), t('nearStep5Body')),
        const SizedBox(height: 18),
        label6(t('nearGuideBack')),
        Text(t('nearGuideBackBody'),
            style: mono(size: 12, color: p.muted, height: 1.6)),
        const SizedBox(height: 18),
        label6(t('nearGuideLimits')),
        Text(t('nearGuideLimitsBody'),
            style: mono(size: 12, color: p.muted, height: 1.6)),
      ]),
    );
  }
}
