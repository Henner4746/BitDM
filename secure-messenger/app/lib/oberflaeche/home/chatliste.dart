// chatliste.dart — Chatliste: Filter, Suche, Anfragen, Update-Karte.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Chatliste on _HomeState {
  /// Adressen der Unterhaltungen, die in der Liste erscheinen.
  List<String> get contacts => st.aktiveKontakte.map((c) => c.id).toList();

  /// Das Menue an einer Unterhaltung in der Liste.
  void unterhaltungMenue(String id) {
    final kontakt = st.kontakte.where((c) => c.id == id).firstOrNull;
    final gruppe = st.gruppeZu(id);
    if (kontakt == null && gruppe == null) return;
    final k = (
      angeheftet: kontakt?.angeheftet ?? gruppe!.angeheftet,
      archiviert: kontakt?.archiviert ?? gruppe!.archiviert,
      stumm: kontakt?.stumm ?? gruppe!.stumm,
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      // HOEHER ALS DIE VORGABE, WENN NOETIG. Ohne das darf ein Blatt nur
      // 9/16 des Bildschirms hoch sein, und das Nachrichtenmenue lief im
      // Querformat unten ueber (Widget-Test, 600 px Hoehe: 18 px zu viel).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) {
        Widget eintrag(String text, VoidCallback tun) => InkWell(
              onTap: () {
                Navigator.pop(ctx);
                tun();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(text, style: mono(size: 13.5, color: p.ink)),
              ),
            );
        return SafeArea(
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            eintrag(k.angeheftet ? t('unpin') : t('pin'),
                () => st.setzeOrdnung(id, angeheftet: !k.angeheftet)),
            eintrag(k.archiviert ? t('unarchive') : t('archive'),
                () => st.setzeOrdnung(id, archiviert: !k.archiviert)),
            eintrag(k.stumm ? t('unmute') : t('mute'),
                () => st.setzeOrdnung(id, stumm: !k.stumm)),
            const SizedBox(height: 6),
          ])),
        );
      },
    );
  }

  /// Der Filter, der gerade WIRKT: im Archiv keiner. Die Leiste ist dort
  /// ausgeblendet — ein unsichtbarer Filter liess archivierte Chats einfach
  /// verschwinden, und unter "Archiv" stand dann die Sternliste.
  String get _wirksamerFilter => _zeigeArchiv ? 'alle' : _filter;

  bool _passt(String id, bool gruppe) => switch (_wirksamerFilter) {
        'gruppen' => gruppe,
        'ungelesen' => st.ungelesenIn(id) > 0,
        _ => true,
      };

  /// Der ruhige Hinweis auf eine neue Fassung ueber der Chatliste.
  ///
  /// KEIN ALARM UND KEINE SPERRE: die App bleibt voll benutzbar, und "Spaeter"
  /// nimmt die Karte fuer genau diese Fassung weg (AppState.updateSpaeter).
  /// Im Browser gibt es nichts zu installieren — dort laedt "Neu laden" die
  /// Seite, und der Server liefert die neue Fassung aus.
  Widget updateKarte(String neu) {
    return Container(
      key: const ValueKey('update-hinweis'),
      margin: const EdgeInsets.fromLTRB(17, 8, 17, 0),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
          color: p.surf2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('updateAvail').replaceFirst('{neu}', neu),
            style: mono(size: 12, color: p.ink, height: 1.4)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: outlineBtn(
              kIsWeb ? t('updateReload') : t('updateSite'),
              kIsWeb ? browserNeuLaden : () => _oeffneLink('https://bitdm.net'),
              padding: const EdgeInsets.all(8))),
          const SizedBox(width: 8),
          Expanded(child: outlineBtn(t('updateLater'), () => unawaited(st.updateSpaeter()),
              accent: false, padding: const EdgeInsets.all(8))),
        ]),
      ]),
    );
  }

  Widget filterLeiste() {
    const filter = ['alle', 'ungelesen', 'gruppen', 'stern'];
    final namen = {
      'alle': t('filterAll'),
      'ungelesen': t('filterUnread'),
      'gruppen': t('filterGroups'),
      'stern': '★',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 4, 17, 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final f in filter)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                button: true,
                selected: _filter == f,
                label: f == 'stern' ? t('filterStarred') : namen[f],
                excludeSemantics: true,
                child: GestureDetector(
                  key: ValueKey('filter-$f'),
                  onTap: () {
                    setState(() => _filter = f);
                    if (f == 'stern') unawaited(st.ladeSterne());
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: _filter == f ? p.tint : Colors.transparent,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: _filter == f ? p.tintLine : p.line),
                    ),
                    child: Text(namen[f]!.toUpperCase(),
                        style: mono(size: 9.5, weight: FontWeight.w600, spacing: 0.9,
                            color: _filter == f ? p.tintInk : p.muted)),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  List<Contact> get sichtbareKontakte {
    final hier = st.aktiveKontakte.where((c) => c.archiviert == _zeigeArchiv);
    return [...hier.where((c) => c.angeheftet), ...hier.where((c) => !c.angeheftet)];
  }

  /// Suchfeld und Treffer. Ohne Suchtext steht hier nur das Feld.
  Widget suchFeld() => Container(
        margin: const EdgeInsets.fromLTRB(17, 8, 17, 4),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: TextField(
          controller: suchCtl,
          enableIMEPersonalizedLearning: false,
          onChanged: st.suche,
          style: mono(size: 13, color: p.ink),
          cursorColor: p.accent,
          decoration: InputDecoration.collapsed(
              hintText: t('search'), hintStyle: mono(size: 13, color: p.dim)),
        ),
      );

  /// Nachrichten als Trefferzeilen — fuer die Suche und fuer die Sterne.
  Widget suchTreffer({List<Message>? liste, String? leer}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if ((liste ?? st.suchTreffer).isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
            child: Text(leer ?? t('noResults'), style: mono(size: 12, color: p.dim, height: 1.5)),
          ),
        for (final m in liste ?? st.suchTreffer)
          InkWell(
            onTap: () {
              suchCtl.clear();
              st.suche('');
              oeffneChat(m.chatId);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              child: Row(children: [
                // WIE IN DER CHATLISTE: eine Gruppe mit Namen und Mitgliederzahl,
                // die Notizen als Notizen. Vorher stand hier fuer jede
                // Unterhaltung die rohe Kennung, bei Gruppen also "G-XL…" statt
                // des Namens — und der Text roh, mit Sternchen und dem Spoiler
                // im Klartext (Emulatorlauf 25.09.2026).
                if (st.gruppeZu(m.chatId) case final g?)
                  Container(
                    width: 32, height: 32, alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                    child: Text('${g.mitglieder.length}', style: doto(size: 13, weight: FontWeight.w600, color: p.tintInk)),
                  )
                else
                  Identicon(m.chatId, 32, avp, 8),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        st.gruppeZu(m.chatId)?.name ??
                            (st.istNotizen(m.chatId) ? t('notes') : shortId(adresseFormatiert(m.chatId))),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: doto(size: 13, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                    const SizedBox(height: 2),
                    Text(auszug(m), maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: mono(size: 12, color: p.muted)),
                  ]),
                ),
                const SizedBox(width: 8),
                Text(zeitVon(m.timestamp), style: mono(size: 10.5, color: p.dim)),
              ]),
            ),
          ),
      ]);

  Future<void> acceptReq(String id) async {
    await Benachrichtigungen.instanz.frageErlaubnis();
    await st.anfrageAnnehmen(id);
    if (!mounted) return;
    await st.unterhaltungOeffnen(id);
    if (!mounted) return;
    setState(() { screen = 'chat'; chat = id; });
  }

  Future<void> oeffneChat(String id) async {
    setState(() { screen = 'chat'; chat = id; sheet = false; });
    await st.unterhaltungOeffnen(id);
  }

  // ---- CHATS ----
  /// Zeigt, ob die App mit dem Relay verbunden ist.
  ///
  /// DAS FEHLTE BISHER GANZ. Wer eine Nachricht schickte und nichts
  /// zurueckbekam, konnte nicht unterscheiden zwischen "kein Netz" und "der
  /// andere antwortet nicht" — zwei Lagen, die voellig verschiedenes Handeln
  /// verlangen.
  ///
  /// Der Punkt atmet, solange verbunden wird, und steht still, sobald es
  /// steht. Ein Punkt, der dauernd blinkt, macht nervoes; einer, der sich nie
  /// ruehrt, sagt nichts.
  Widget verbindungsPunkt() {
    final (farbe, text, aktiv) = switch (st.verbindung) {
      ConnectionState.online => (p.accLight, t('connOnline'), false),
      ConnectionState.connecting => (p.muted, t('connConnecting'), true),
      // ABGEWIESEN IST NICHT "KEIN NETZ". Der Relay hat mit 507 gesagt, dass
      // diese Adresse schon genug Geraete hat (§6) — daran aendert Warten
      // nichts, und die App versucht es auch nicht mehr. Wer hier "keine
      // Verbindung" liest, sucht den Fehler bei seinem WLAN.
      ConnectionState.error => (
          p.dim,
          st.geraeteStand == ListenStand.beitrittNoetig ||
                  st.geraeteStand == ListenStand.wartetAufBestaetigung
              ? t('connBeitritt')
              : st.abgewiesen
              ? t('connGeraeteVoll')
              : t('connError'),
          false
        ),
      ConnectionState.disconnected => (p.dim, t('connOffline'), false),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AtmenderPunkt(farbe: farbe, aktiv: aktiv, groesse: 7),
      const SizedBox(width: 6),
      // Kuerzen statt ueberlaufen, wenn die Kopfzeile eng wird (siehe dort):
      // ein abgeschnittenes "KEINE VERBIND…" sagt noch etwas, ein gelb
      // gestreifter Balken nichts.
      Flexible(
        child: AnimatedDefaultTextStyle(
          duration: Bewegung.klein,
          style: mono(size: 10, weight: FontWeight.w500, color: farbe, spacing: 1.1),
          child: Text(text.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ]);
  }

  /// Was das '+' in der Kopfzeile tut. Als Methode, weil [_Bedienbar] die
  /// Handlung zweimal braucht — fuer den Zeiger und fuer den Tipp.
  void _zumHinzufuegen() =>
      setState(() { screen = 'add'; addCtl.clear(); reqErgebnis = null; });

  Widget chatsScreen() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 11, 22, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          // FLEXIBEL, WEIL DIE LINKE SPALTE ENG IST. Im Schreibtisch-Geruest
          // steht diese Kopfzeile in 300 px minus 44 px Rand = 256 px, und
          // darin liegen 'CHATS', der Punkt, sein Text und das '+'. Der neue
          // Fenster-Test hat den Ueberlauf am 30.07.2026 gemeldet: 31 px zu
          // viel (mit der Testschrift, die breiter baut als Doto — auf dem
          // Geraet passt es, aber mit einem langen Text wie "keine
          // Verbindung" nur knapp). Flexible aendert nichts, solange es
          // passt, und laesst den Text kuerzen statt ueberzulaufen.
          Flexible(
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              h2(t('chats')),
              const SizedBox(width: 10),
              Flexible(child: verbindungsPunkt()),
            ]),
          ),
          _Bedienbar(
            imFenster: _imFenster,
            onTap: _zumHinzufuegen,
            bau: (ueber, fokus) => GestureDetector(
              onTap: _zumHinzufuegen,
              child: Container(
                width: 32, height: 32, alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: fokus ? p.wash : null,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: ueber || fokus ? p.accHover : p.accent)),
                // EIGENE BESCHRIFTUNG FUER DIE VORLESEFUNKTION.
                //
                // Ohne sie liest ein Screenreader die ganze Kopfzeile als einen
                // Block vor: "CHATS OFFLINE +". Das Pluszeichen ist der einzige
                // Weg, jemanden hinzuzufuegen, und es hatte keinen Namen.
                child: Semantics(
                  label: t('addContact'),
                  button: true,
                  child: Text('+', style: TextStyle(color: p.accLight, fontSize: 18, height: 1)),
                ),
              ),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      if (st.fernloeschung.faellig != null) fernBanner(),
      if (st.updateHinweis != null) updateKarte(st.updateHinweis!),
      // NICHT IN DER GERAETELISTE: Code eingeben oder alle anderen abmelden
      // (geraete_seite.dart). Ohne das stuende hier nur "keine Verbindung".
      if (st.geraeteStand == ListenStand.beitrittNoetig ||
          st.geraeteStand == ListenStand.wartetAufBestaetigung)
        BeitrittsKarte(st: st, stil: _geraeteStil),
      // SOLANGE ES KEIN APP-PASSWORT GIBT, steht das hier, und zwar ohne
      // Knopf zum Wegklicken: die Identitaet ist in dem Zustand beim
      // naechsten Neuladen weg, und das ist keine Meldung, die man einmal
      // liest und dann vergessen darf.
      if (kIsWeb && st.faktoren.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
          child: webHinweis(t('webVolatile')),
        ),
      suchFeld(),
      if (st.suchText.trim().isEmpty && !_zeigeArchiv) filterLeiste(),
      Expanded(
        child: st.suchText.trim().isNotEmpty
            ? ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [suchTreffer()])
            : _wirksamerFilter == 'stern'
            ? ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
                suchTreffer(liste: st.sterne, leer: t('starEmpty')),
              ])
            : ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
          if (_zeigeArchiv)
            InkWell(
              onTap: () => setState(() => _zeigeArchiv = false),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
                child: Text('‹ ${t('backToChats')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          if (!_zeigeArchiv) ...[
          for (final k in st.offeneAnfragen) pendingCard(k),
          // Ausgehende Anfragen erscheinen ebenfalls. Vorher waren sie
          // unsichtbar: wer jemanden hinzugefuegt hatte, sah danach eine leere
          // Liste und musste annehmen, es habe nicht funktioniert.
          for (final k in st.eigeneAnfragen) wartendeAnfrage(k),
          ],
          // ANGEHEFTET HEISST GANZ OBEN — ueber beide Arten hinweg. Vorher
          // standen erst alle Gruppen, dann alle Kontakte, und ein angehefteter
          // Kontakt blieb unter jeder Gruppe (Emulatorlauf 25.09.2026).
          if (!_zeigeArchiv && _wirksamerFilter == 'alle')
            for (final v in st.verteiler) verteilerZeile(v),
          for (final g in sichtbareGruppen.where((g) => g.angeheftet && _passt(g.id, true))) gruppenZeile(g),
          for (final k in sichtbareKontakte.where((k) => k.angeheftet && _passt(k.id, false))) contactRow(k.id),
          for (final g in sichtbareGruppen.where((g) => !g.angeheftet && _passt(g.id, true))) gruppenZeile(g),
          for (final k in sichtbareKontakte.where((k) => !k.angeheftet && _passt(k.id, false))) contactRow(k.id),
          if (!_zeigeArchiv && !st.kontakte.any((k) => st.istNotizen(k.id)) && st.meineAdresse.isNotEmpty)
            InkWell(
              onTap: () async {
                final id = await st.notizenOeffnen();
                if (mounted) oeffneChat(id);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: Text('+ ${t('notes')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          // Das Archiv ist ein Eintrag am Ende der Liste, wie bei Signal —
          // und nur, wenn es etwas enthaelt.
          if (!_zeigeArchiv && st.meineAdresse.isNotEmpty)
            InkWell(
              onTap: _legeGruppeAnDialog,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: Text('+ ${t('groupCreate')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          if (!_zeigeArchiv && st.meineAdresse.isNotEmpty)
            InkWell(
              key: const ValueKey('verteiler-neu'),
              onTap: _legeVerteilerAnDialog,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
                child: Text('+ ${t('listCreate')}', style: mono(size: 12, color: p.accLight)),
              ),
            ),
          if (!_zeigeArchiv &&
              (st.aktiveKontakte.any((c) => c.archiviert) || st.gruppen.any((g) => g.archiviert)))
            InkWell(
              onTap: () => setState(() => _zeigeArchiv = true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: Text(
                    '${t('archived').toUpperCase()} (${st.aktiveKontakte.where((c) => c.archiviert).length + st.gruppen.where((g) => g.archiviert).length})',
                    style: mono(size: 11, color: p.muted, spacing: 1.2)),
              ),
            ),
          if (contacts.isEmpty && st.offeneAnfragen.isEmpty && st.eigeneAnfragen.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
              child: Text(t('noChats'), style: mono(size: 12, color: p.dim, height: 1.6)),
            ),
          Padding(padding: const EdgeInsets.fromLTRB(22, 16, 22, 16), child: Text(t('noNames'), style: mono(size: 11, color: p.dim, height: 1.5))),
        ]),
      ),
    ]);
  }

  /// Eine Anfrage, die WIR gestellt haben und die noch offen ist.
  ///
  /// Bewusst nicht antippbar: es gibt noch keine Sitzung, und ein Chat, in dem
  /// man nicht schreiben kann, waere verwirrender als gar keiner.
  Widget wartendeAnfrage(Contact k) => Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Opacity(opacity: 0.45, child: Identicon(k.id, 40, avp, 8)),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(shortId(adresseFormatiert(k.id)),
                  style: doto(size: 15, weight: FontWeight.w600, color: p.muted, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(t('waitingForAccept'), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.line)),
            child: Text(t('pending').toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.2)),
          ),
        ]),
      );

  Widget pendingCard(Contact k) => Container(
        margin: const EdgeInsets.fromLTRB(17, 8, 17, 11),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(shortId(adresseFormatiert(k.id)), style: doto(size: 13, weight: FontWeight.w600, color: p.tintInk, spacing: 0.8)),
          const SizedBox(height: 6),
          Text(t('wantsChat'), style: mono(size: 11.5, color: p.muted)),
          const SizedBox(height: 8),
          // Annehmen und Ablehnen stehen IN der Chatliste und sind echte
          // Knoepfe — also auch durch [_Bedienbar]. Nicht auf `smallBtn`
          // umgestellt: dessen Masse sind andere, und das waere eine
          // Layout-Aenderung am Telefon fuer nichts.
          Row(children: [
            _Bedienbar(
              imFenster: _imFenster,
              onTap: () => acceptReq(k.id),
              bau: (ueber, fokus) => GestureDetector(
                onTap: () => acceptReq(k.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(color: fokus ? p.wash : null, borderRadius: BorderRadius.circular(4), border: Border.all(color: ueber || fokus ? p.accHover : p.accent)),
                  child: Text(t('accept').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _Bedienbar(
              imFenster: _imFenster,
              onTap: () => st.anfrageAblehnen(k.id),
              bau: (ueber, fokus) => GestureDetector(
                onTap: () => st.anfrageAblehnen(k.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(color: fokus ? p.wash : null, borderRadius: BorderRadius.circular(4), border: Border.all(color: ueber || fokus ? p.accHover : p.line)),
                  child: Text(t('decline').toUpperCase(), style: mono(size: 11, color: p.muted, spacing: 1.2)),
                ),
              ),
            ),
          ]),
        ]),
      );

  Widget contactRow(String id) {
    final list = st.verlaufVon(id);
    final letzte = list.isEmpty ? null : list.last;
    // Leere Notizen sind kein "neuer Kontakt" — das stand dort bis 25.09.2026.
    final last = letzte == null
        ? (st.istNotizen(id) ? t('notesEmpty') : t('newContact'))
        : auszug(letzte);
    final k = st.kontakte.where((c) => c.id == id).firstOrNull;
    final marken = [
      if (k?.angeheftet ?? false) t('pinnedTag'),
      if (k?.stumm ?? false) t('mutedTag'),
    ];
    final time = letzte == null ? '' : zeitVon(letzte.timestamp);
    // Ungelesen: die letzte Nachricht kam von der Gegenstelle und diese
    // Unterhaltung ist gerade nicht offen.
    // DIE ECHTE ZAHL statt "die letzte Nachricht ist fremd": die alte Regel
    // liess den Punkt stehen, bis man selbst antwortete, und blendete ihn fuer
    // die zuletzt geoeffnete Unterhaltung aus, auch nachdem man sie verlassen
    // hatte.
    final zahl = (screen == 'chat' && chat == id) ? 0 : st.ungelesenIn(id);
    // Die Zeilen der Chatliste sind die am haeufigsten angetippten der App und
    // waren im Fenster die letzten ohne Zeiger, Ueberfahren und Tab. Die
    // Fuellung ist die Rueckmeldung: die Zeile hat keinen Rahmen, den man
    // faerben koennte, und ein neuer haette sie um 1 px verschoben.
    return _Bedienbar(
      imFenster: _imFenster,
      onTap: () => oeffneChat(id),
      bau: (ueber, fokus) => GestureDetector(
      onTap: () => oeffneChat(id),
      // Langdruck am Telefon, Rechtsklick am Rechner — dasselbe Menue.
      onLongPress: () => unterhaltungMenue(id),
      onSecondaryTap: () => unterhaltungMenue(id),
      child: Container(
        color: ueber || fokus ? p.wash : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Identicon(id, 40, avp, 8),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(st.istNotizen(id) ? t('notes') : shortId(adresseFormatiert(id)), style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(last, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(time, style: mono(size: 10.5, color: p.dim)),
            const SizedBox(height: 6),
            if (marken.isNotEmpty) ...[
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final mk in marken) Padding(padding: const EdgeInsets.only(left: 4), child: marke(mk)),
              ]),
              const SizedBox(height: 4),
            ],
            ungelesenMarke(zahl),
          ]),
        ]),
      ),
      ),
    );
  }
}
