// nachricht.dart — Nachrichtenblase, Reaktionen, Nachrichtenmenue, Widerruf.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

/// Die sechs Reaktionen, die Signal zuerst anbietet.
const schnellReaktionen = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

extension _Nachricht on _HomeState {
  /// Das Menue an einer Nachricht: Reaktionen oben, Aktionen darunter.
  void nachrichtMenue(String cid, Message m) {
    final meine = st.reaktionenZu(cid, m.id)[st.meineAdresse];
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
        Widget eintrag(String text, VoidCallback tun, {bool warnend = false}) =>
            InkWell(
              onTap: () {
                Navigator.pop(ctx);
                tun();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(text,
                    style: mono(size: 13.5, color: warnend ? p.tintInk : p.ink)),
              ),
            );
        return SafeArea(
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            if (!m.widerrufen)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  for (final z in schnellReaktionen)
                    Semantics(
                      button: true,
                      selected: meine == z,
                      label: z,
                      child: GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          // Dieselbe noch einmal nimmt sie zurueck — wie bei Signal.
                          st.reagiere(cid, m.id, meine == z ? null : z);
                        },
                        child: Container(
                          width: 44, height: 44, alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: meine == z ? p.tint : null,
                              shape: BoxShape.circle,
                              border: meine == z ? Border.all(color: p.tintLine) : null),
                          child: Text(z, style: const TextStyle(fontSize: 22)),
                        ),
                      ),
                    ),
                ]),
              ),
            Container(height: 1, color: p.lineSoft),
            if (!m.widerrufen)
              eintrag(t('reply'), () {
                setState(() {
                  _bearbeitungsZiel = null;
                  _antwortZiel = m;
                });
              }),
            if (!m.widerrufen)
              eintrag(m.angeheftetAm == null ? t('pinMsg') : t('unpinMsg'),
                  () => st.hefteAn(cid, m.id, m.angeheftetAm == null)),
            if (!m.widerrufen)
              eintrag(m.sternAm == null ? t('star') : t('unstar'),
                  () => st.setzeStern(cid, m.id, m.sternAm == null)),
            if (m.isMine && st.gruppeZu(cid) != null)
              eintrag(t('msgInfo'), () => _zeigeZustellung(cid, m)),
            if (!m.widerrufen && m.kind == MessageKind.text)
              eintrag(t('copyMsg'), () {
                Clipboard.setData(ClipboardData(text: m.text));
              }),
            if (AppState.bearbeitbar(m))
              eintrag(t('edit'), () {
                setState(() {
                  _antwortZiel = null;
                  _bearbeitungsZiel = m;
                  draftCtl.text = m.text;
                });
              }),
            if (AppState.widerrufbar(m))
              eintrag(t('deleteAll'), () => _bestaetigeWiderruf(cid, m), warnend: true),
            eintrag(t('deleteMe'), () => st.loescheFuerMich(cid, m.id), warnend: true),
            const SizedBox(height: 6),
          ])),
        );
      },
    );
  }

  Future<void> _bestaetigeWiderruf(String cid, Message m) async {
    final ja = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        title: Text(t('deleteAllAsk'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
        content: Text(t('deleteAllBody'), style: mono(size: 12.5, color: p.muted, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('deleteAll'))),
        ],
      ),
    );
    if (ja == true) await st.widerrufe(cid, m.id);
  }

  Widget msgBubble(String cid, Message m, int i) {
    final me = m.isMine;
    final time = zeitVon(m.timestamp);
    // Sprachnachrichten gibt es in Fassung 1 noch nicht — der Entwurf zeigte
    // sie, der Kern kennt nur Text. Lieber nichts anzeigen, als etwas
    // vorzutaeuschen — die Darstellung dafuer steht in der Versionsgeschichte
    // und kommt zurueck, sobald es Sprachnachrichten wirklich gibt.
    final bub = BoxDecoration(
      color: me ? p.tint : p.surf,
      borderRadius: me
          ? const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(2))
          : const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(2), bottomRight: Radius.circular(8)),
      border: me ? Border.all(color: p.tintLine) : null,
    );
    final reaktionen = st.reaktionenZu(cid, m.id);
    final bezug = st.bezugVon(m);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: me ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
        Flexible(
          child: GestureDetector(
          // Langdruck am Telefon, Rechtsklick am Rechner — dasselbe Menue.
          onLongPress: () => nachrichtMenue(cid, m),
          onSecondaryTap: () => nachrichtMenue(cid, m),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 252),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: bub,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              // DAS ZITAT KOMMT AUS DEM EIGENEN VERLAUF, nicht aus der
              // Nachricht. Steht die Bezugsnachricht hier nicht (mehr), sagt
              // die Blase das — statt etwas zu zeigen, das der Absender
              // behauptet.
              // IN EINER GRUPPE: wer es geschrieben hat. Ohne das waeren alle
              // fremden Blasen gleich, und niemand wuesste, wer was sagt.
              if (!me && Gruppe.istGruppenId(cid))
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(shortId(adresseFormatiert(m.senderId)),
                        style: mono(size: 9.5, weight: FontWeight.w600, color: p.accLight)),
                  ),
                ),
              if (m.antwortAuf != null && !m.widerrufen)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  decoration: BoxDecoration(
                      color: p.surf2,
                      borderRadius: BorderRadius.circular(4),
                      border: Border(left: BorderSide(color: p.accent, width: 2))),
                  child: Text(bezug == null ? t('replyGone') : auszug(bezug),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: mono(size: 11, color: p.muted, height: 1.4)),
                ),
              if (m.widerrufen)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(me ? t('deletedMine') : t('deletedMsg'),
                      style: TextStyle(fontSize: 13, color: p.dim, fontStyle: FontStyle.italic, height: 1.4)),
                )
              else if (m.kind == MessageKind.anhang)
                anhangInhalt(cid, m)
              else if (m.kind == MessageKind.umfrage)
                umfrageInhalt(cid, m)
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: entschluesselt(
                      m,
                      TextStyle(fontSize: 13.5, color: p.ink, height: 1.4),
                      FormatierterText(m.text,
                          stil: TextStyle(fontSize: 13.5, color: p.ink, height: 1.4),
                          festStil: mono(size: 12.5, color: p.ink, height: 1.4),
                          verdeckt: p.muted)),
                ),
              const SizedBox(height: 3),
              Row(mainAxisSize: MainAxisSize.min, children: [
                // DAS EINZIGE, WAS DIE NAEHE SICHTBAR MACHT.
                //
                // Hier steht, wie diese Nachricht gegangen IST — nicht, wo
                // jemand gerade IST. Der Unterschied ist der Grund, warum es
                // an keiner Stelle dieser App eine Anwesenheitsanzeige gibt:
                // ein Punkt am Kontakt waere bequem und verriete jedes Mal,
                // wer neben wem sitzt.
                //
                // Ein Wort statt eines Zeichens. Ein Funkwellen-Glyph waere
                // kuerzer und muesste doch erklaert werden — und ob ihn eine
                // Schrift ueberhaupt hat, weiss man erst auf dem Geraet.
                if (m.ueberNaehe) ...[
                  Semantics(
                    button: true,
                    label: t('viaNearbyTitle'),
                    child: GestureDetector(
                      onTap: _erklaereNaehe,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 4),
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: p.tintLine)),
                        child: Text(t('viaNearby').toUpperCase(),
                            style: mono(
                                size: 8,
                                weight: FontWeight.w600,
                                color: p.accLight,
                                spacing: 0.9)),
                      ),
                    ),
                  ),
                ],
                if (m.sternAm != null && !m.widerrufen) ...[
                  Text('★', key: ValueKey('stern-${m.id}'),
                      style: TextStyle(fontSize: 10, color: p.accLight, height: 1)),
                  const SizedBox(width: 5),
                ],
                if (m.bearbeitet && !m.widerrufen) ...[
                  Text(t('edited'), style: mono(size: 9.5, color: p.dim)),
                  const SizedBox(width: 5),
                ],
                // GEPLANT: statt der Uhrzeit und der Uhr der Zeitpunkt, zu
                // dem sie hinausgeht — sonst sahe sie aus wie eine, die
                // haengt.
                if (m.geplantFuer != null && m.status == MessageStatus.sending)
                  Text('${t('scheduledFor')} ${zeitVon(m.geplantFuer!)}',
                      style: mono(size: 9.5, color: p.accLight))
                else
                Text(time, style: mono(size: 9.5, color: p.dim)),
                if (me && !(m.geplantFuer != null && m.status == MessageStatus.sending)) ...[
                  const SizedBox(width: 5),
                  // Ein Haken je erreichter Stufe: abgeschickt, zugestellt,
                  // gelesen. Solange sie noch beim Absender liegt, eine Uhr.
                  Text(
                    switch (m.status) {
                      MessageStatus.sending => '◷',
                      MessageStatus.sent => '✓',
                      MessageStatus.delivered => '✓✓',
                      MessageStatus.read => '✓✓',
                      MessageStatus.failed => '!',
                    },
                    style: mono(
                        size: 9.5,
                        color: m.status == MessageStatus.read
                            ? p.accLight
                            : p.dim),
                  ),
                ],
              ]),
            ]),
          ),
          ),
        ),
      ]),
      if (reaktionen.isNotEmpty) reaktionsLeiste(cid, m, reaktionen),
      ]),
    );
  }

  /// Die Reaktionen unter einer Blase: je Zeichen eines, mit Anzahl.
  /// Die eigene ist hervorgehoben; antippen nimmt sie zurueck.
  Widget reaktionsLeiste(String cid, Message m, Reaktionen r) {
    final zaehler = <String, int>{};
    for (final z in r.values) {
      zaehler[z] = (zaehler[z] ?? 0) + 1;
    }
    final meine = r[st.meineAdresse];
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(spacing: 4, children: [
        for (final e in zaehler.entries)
          Semantics(
            button: e.key == meine,
            label: '${e.key} ${e.value}',
            // Sonst liest die Vorleseschrift die Reaktion zweimal: einmal
            // aus diesem Etikett, einmal aus dem Text darunter.
            excludeSemantics: true,
            child: GestureDetector(
              onTap: e.key == meine ? () => st.reagiere(cid, m.id, null) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: e.key == meine ? p.tint : p.surf,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: e.key == meine ? p.tintLine : p.line)),
                child: Text(e.value > 1 ? '${e.key} ${e.value}' : e.key,
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════ Anhaenge
  //
  // Eine Anhang-Blase zeigt IMMER dasselbe oben — Kaestchen, Name, Groesse —
  // und darunter das, was gerade zu tun ist. Die Reihenfolge bleibt also
  // gleich, waehrend sich der Zustand aendert; nur der untere Teil wechselt.
  // Ein Aufbau, der bei jedem Zustand anders aussieht, laesst eine Liste
  // unruhig wirken, obwohl sich nur eine Zeile bewegt hat.

  /// Laesst eine eintreffende Textnachricht sich sichtbar entschluesseln —
  /// einmal, wenn ihre Blase zum ersten Mal erscheint. Danach [fertig].
  Widget entschluesselt(Message m, TextStyle stil, Widget fertig) {
    if (m.isMine || !st.einstellungen.entschluesseln) return fertig;
    var seit = _entschluesseltSeit[m.id];
    if (seit == null) {
      if (!st.frischeNachrichten.remove(m.id)) return fertig;
      seit = _entschluesseltSeit[m.id] = DateTime.now();
    }
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return fertig;
    if (DateTime.now().difference(seit) >= EntschluesselnderText.dauerFuer(m.text)) {
      return fertig;
    }
    return EntschluesselnderText(
      key: ValueKey('entschluesseln-${m.id}'),
      // Der Salat entsteht aus dem SCHLICHTEN Text: sonst stuende ein Spoiler
      // waehrend des Effekts fuer einen Augenblick im Klartext da.
      text: Formatierung.schlicht(m.text),
      stil: stil,
      seit: seit,
      chiffre: _thema.chiffre,
      fertig: fertig,
    );
  }
}
