// unterhaltung.dart — Chatbildschirm: Eingabe, Senden, Planen, Bildlauf.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Unterhaltung on _HomeState {
  /// Haelt die Unterhaltung am unteren Ende.
  ///
  /// Wird beim Bauen des Chatbildschirms gerufen und tut in zwei Faellen
  /// etwas — die sich absichtlich unterschiedlich verhalten:
  ///
  ///   BEIM OEFFNEN springt sie immer ans Ende, ohne Ruecksicht auf den
  ///   Schalter. Eine Unterhaltung, die bei der aeltesten Nachricht aufgeht,
  ///   ist kein Merkmal, das man abschalten koennen muss. (Genau das tat sie
  ///   bisher: die Liste hatte keine Steuerung und begann oben.)
  ///
  ///   BEI EINER NEUEN NACHRICHT nur, wenn [AppPreferences.autoScroll] an ist
  ///   — und selbst dann nicht, wenn der Leser gerade weiter oben steht. Wer
  ///   Alteres liest, soll nicht mitten im Satz weggerissen werden. Eigene
  ///   Nachrichten nehmen ihn trotzdem mit: wer schreibt, will sehen, was er
  ///   geschrieben hat.
  void _haltUnten(String cid, int anzahl) {
    final gewechselt = cid != _scrollChat;
    final eigene = _selbstGeschrieben;
    if (!gewechselt && anzahl == _scrollAnzahl) return;
    _scrollChat = cid;
    _scrollAnzahl = anzahl;
    _selbstGeschrieben = false;
    if (!gewechselt && !st.einstellungen.autoScroll) return;

    // NACH dem Bau, nicht waehrend: vorher steht die Hoehe der Liste noch
    // nicht fest, und maxScrollExtent waere der Wert von gestern.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScroll.hasClients) return;
      final unten = _chatScroll.position.maxScrollExtent;
      if (gewechselt) {
        _chatScroll.jumpTo(unten);
        return;
      }
      // Etwa eine Nachrichtenhoehe Spielraum: wer so nah am Ende steht, hat
      // die Liste nicht verlassen, sondern nur einen Rest Schwung uebrig.
      if (!eigene && unten - _chatScroll.offset > 140) return;
      _chatScroll.animateTo(unten,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    });
  }

  Future<void> send() async {
    final d = draftCtl.text.trim();
    if (d.isEmpty || chat == null) return;
    if (d.startsWith('/') && _bearbeitungsZiel == null && await _fuehreBefehlAus(d)) {
      draftCtl.clear();
      if (mounted) setState(() {});
      return;
    }
    _vergissPlanFehler();
    draftCtl.clear();
    final bearbeitet = _bearbeitungsZiel;
    final antwort = _antwortZiel;
    setState(() {
      _bearbeitungsZiel = null;
      _antwortZiel = null;
    });
    if (bearbeitet != null) {
      await st.bearbeite(chat!, bearbeitet.id, d);
      return;
    }
    // VOR dem Senden setzen, nicht danach: `senden` meldet die Aenderung
    // selbst, der Neubau laeuft also noch waehrend dieses `await`. Danach
    // waere die Marke zu spaet.
    _selbstGeschrieben = true;
    await st.senden(chat!, d, antwortAuf: antwort?.id);
  }

  /// Fragt nach Tag und Uhrzeit und plant die Nachricht im Eingabefeld.
  /// "Die Zeit ist schon vorbei" gilt fuer EINEN Versuch. Stehen blieb sie
  /// sonst auch dann noch, als der naechste Versuch laengst geplant war
  /// (Emulatorlauf 25.09.2026).
  void _vergissPlanFehler() {
    if (st.letzterFehler == 'geplantVorbei') st.vergissFehler();
  }

  Future<void> _planeSenden() async {
    final d = draftCtl.text.trim();
    if (d.isEmpty || chat == null || _bearbeitungsZiel != null) return;
    _vergissPlanFehler();
    final jetzt = DateTime.now();
    final tag = await showDatePicker(
        context: context,
        initialDate: jetzt,
        firstDate: jetzt,
        lastDate: jetzt.add(const Duration(days: 365)),
        helpText: t('scheduleTitle'));
    if (tag == null || !mounted) return;
    final zeit = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(jetzt.add(const Duration(hours: 1))));
    if (zeit == null) return;
    final um = DateTime(tag.year, tag.month, tag.day, zeit.hour, zeit.minute);
    if (!um.isAfter(DateTime.now())) {
      st.setzeFehler('geplantVorbei');
      return;
    }
    final antwort = _antwortZiel;
    draftCtl.clear();
    setState(() => _antwortZiel = null);
    await st.senden(chat!, d, antwortAuf: antwort?.id, um: um);
  }

  /// Ein kurzer Auszug einer Nachricht — fuer Zitat, Antwortleiste und Liste.
  String auszug(Message m) {
    if (m.widerrufen) return t('deletedMsg');
    if (m.kind == MessageKind.anhang && sprachName.hasMatch(m.text)) {
      return t('voice');
    }
    if (m.kind == MessageKind.anhang) return '${t('attachment')}: ${m.text}';
    if (m.kind == MessageKind.umfrage) {
      return '${t('poll')}: ${Umfrage.lies(m.text)?.frage ?? ''}';
    }
    return Formatierung.schlicht(m.text);
  }

  // ═══════════════════════════════════════════════ Befehle der Schreibzeile
  //
  // "/timer 1h", "/verify", "/poll", "/theme aurora", "/shrug". Wie in einem
  // Terminal — und nur die bekannten: alles andere mit "/" am Anfang geht als
  // gewoehnliche Nachricht hinaus, wer "/s" schreibt, meint Ironie.

  /// Die Zeile, die zeigt, worauf die naechste Nachricht antwortet oder dass
  /// gerade bearbeitet wird. Das Kreuz bricht ab.
  Widget eingabeBezug() {
    final ziel = _bearbeitungsZiel ?? _antwortZiel;
    if (ziel == null) return const SizedBox.shrink();
    final bearbeitung = _bearbeitungsZiel != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
          color: p.surf2,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: p.accent, width: 3))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((bearbeitung ? t('editing') : t('replyTo')).toUpperCase(),
                style: mono(size: 9.5, weight: FontWeight.w600, color: p.accLight, spacing: 1)),
            const SizedBox(height: 2),
            Text(auszug(ziel), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: mono(size: 12, color: p.muted)),
          ]),
        ),
        Semantics(
          button: true,
          label: t('cancel'),
          child: Masse.trefferflaeche(
            onTap: () => setState(() {
              if (bearbeitung) draftCtl.clear();
              _antwortZiel = null;
              _bearbeitungsZiel = null;
            }),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text('×', style: TextStyle(color: p.muted, fontSize: 16, height: 1)),
            ),
          ),
        ),
      ]),
    );
  }

  /// Die Leiste unter der Kopfzeile: die angeheftete Nachricht, bei mehreren
  /// schaltet Antippen zur naechsten weiter.
  Widget angeheftetLeiste(String cid) {
    final liste = st.angeheftete(cid);
    if (liste.isEmpty) return const SizedBox.shrink();
    final i = _angeheftetStelle % liste.length;
    return Semantics(
      button: liste.length > 1,
      label: t('pinnedTitle'),
      child: GestureDetector(
        onTap: liste.length > 1 ? () => setState(() => _angeheftetStelle++) : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(17, 7, 17, 7),
          decoration: BoxDecoration(
              color: p.surf2, border: Border(bottom: BorderSide(color: p.lineSoft))),
          child: Row(children: [
            marke(t('pinnedTag')),
            const SizedBox(width: 8),
            Expanded(
              child: Text(auszug(liste[i]), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: mono(size: 12, color: p.muted)),
            ),
            if (liste.length > 1)
              Text('${i + 1}/${liste.length}', style: mono(size: 10.5, color: p.dim)),
          ]),
        ),
      ),
    );
  }

  // ---- CHAT ----
  Widget chatScreen() {
    final cid = chat ?? c1;
    final hints = <String>[];
    // NICHT IM BROWSER: dort gibt es keinen Screenshot-Schutz (der Kanal
    // bitdm/fenster fehlt, und eine Webseite kann das Abfotografieren
    // grundsaetzlich nicht verhindern). "Screenshot-Schutz aktiv" stand dort
    // bis 25.09.2026 trotzdem ueber jedem Chat.
    // UND NUR, WENN DIE PLATTFORM "GESETZT" GEMELDET HAT — nicht schon, weil
    // der Schalter an ist. Am Rechner ohne Gegenseite stand der Hinweis sonst
    // ueber jedem Chat und versprach etwas, das nicht galt.
    if (st.screenshotSchutzAktiv && !kIsWeb) hints.add(t("hintShot"));
    hints.add(t("hintEnc"));
    // ZUERST in der Zeile, weil es das Wichtigste ist: was hier geschrieben
    // wird, geht gerade nirgendwo hin. Wer das nicht sieht, haelt eine
    // liegengebliebene Nachricht fuer zugestellt.
    if (st.einstellungen.nurNahbereich) hints.insert(0, t("nearOnlyWaiting"));
    if (st.fristFuer(cid) != null) {
      hints.add(t("hintEph") + fristText(st.fristFuer(cid)));
    }
    final list = st.verlaufVon(cid);
    _haltUnten(cid, list.length);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(17, 8, 17, 8),
        child: Row(children: [
          // KEIN ZURUECK BEI ZWEI SPALTEN. Die Liste steht dann links und ist
          // nie verlassen worden — ein Pfeil, der "zurueck zur Liste" heisst,
          // zeigt dort auf etwas, das schon sichtbar ist.
          if (!_zweiSpalten) ...[
            iconBtn('‹', () => go('chats')),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: GestureDetector(
              // Die Notizen haben kein Gegenueber — keine Pruefnummer, kein
              // Kontakt zum Entfernen. Das Blatt waere leer oder falsch.
              onTap: Gruppe.istGruppenId(cid)
                  ? () => gruppenBlatt(cid)
                  : st.istNotizen(cid) ? null : () { setState(() => sheet = true); _ladePruefnummer(cid); },
              child: Row(children: [
                Identicon(cid, 32, avp, 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // DIESELBE SCHREIBWEISE WIE UEBERALL SONST.
                    //
                    // Hier stand `shortId(cid)` — die ROHE Kennung, ohne
                    // `adresseFormatiert`. Die Liste zeigte dieselbe Adresse
                    // als "BITD...2L-X", diese Kopfzeile als "bitd...q2lx":
                    // andere Gruppierung, andere Schreibweise, dasselbe
                    // Gegenueber. Wer zwei Geraete vergleichen will — und
                    // genau das tut man bei einer Adresse, die der Schluessel
                    // IST —, muss die beiden erst ineinander umrechnen.
                    Text(st.gruppeZu(cid)?.name ?? (st.istNotizen(cid) ? t('notes') : shortId(adresseFormatiert(cid))), maxLines: 1, overflow: TextOverflow.ellipsis, style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                    // "TIPPT ..." an der Stelle der Unterzeile, nicht als
                    // eigene Zeile: sonst sprang die ganze Unterhaltung um eine
                    // Zeile, jedes Mal, wenn die Gegenseite zu tippen anfaengt.
                    Text(st.tipptGerade(cid) ? t('typing').toUpperCase() : t('encDetails').toUpperCase(),
                        style: mono(size: 10, color: st.tipptGerade(cid) ? p.accLight : p.dim, spacing: 1)),
                  ]),
                ),
              ]),
            ),
          ),
          if (!st.istNotizen(cid)) GestureDetector(
            onTap: Gruppe.istGruppenId(cid)
                ? () => gruppenBlatt(cid)
                : () { setState(() => sheet = true); _ladePruefnummer(cid); },
            child: Container(
              width: 30, height: 30, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              child: Text('i', style: TextStyle(color: p.accLight, fontSize: 12)),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      angeheftetLeiste(cid),
      Expanded(
        child: ListView(
          controller: _chatScroll,
          padding: const EdgeInsets.all(17),
          children: [
            Center(child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(hints.join(' · '), textAlign: TextAlign.center, style: mono(size: 10.5, color: p.dim, height: 1.5)))),
            for (int i = 0; i < list.length; i++)
              // Nur die LETZTE Nachricht bewegt sich. Wuerde die ganze Liste
              // beim Oeffnen hereingleiten, waere das eine Vorfuehrung, keine
              // Auskunft — und beim Scrollen zurueck wuerde alles noch einmal
              // tanzen.
              if (i == list.length - 1)
                Hereingleiten(
                  key: ValueKey(list[i].id),
                  vonRechts: list[i].isMine,
                  child: msgBubble(cid, list[i], i),
                )
              else
                msgBubble(cid, list[i], i),
            // Ganz unten, weil es die neueste "Nachricht" ist — auch wenn es
            // noch keine gibt.
            if (st.schwebenderChat == cid) schwebenderAnhang(),
          ],
        ),
      ),
      // WAS NICHT RAUSGING, MUSS DASTEHEN. "zuLang" wurde bisher gesetzt und
      // nirgends gezeigt: die Nachricht verschwand aus dem Eingabefeld und kam
      // nie an, ohne dass irgendwo etwas stand.
      befehlsLeiste(),
      erwaehnungsLeiste(),
      eingabeBezug(),
      // DIE GEGENSTELLE HAT NUR EINE APP VOR 2.0.0. Ruhig, nicht als Fehler:
      // hier ist nichts schiefgegangen, und nichts geht verloren — die
      // Nachrichten warten im Nachversand. Ohne diesen Kasten standen sie
      // stumm auf "wird gesendet", und niemand erfuhr, warum.
      if (st.brauchtNeuereApp(cid))
        Padding(
          key: const ValueKey('hinweis-neuere-app'),
          padding: const EdgeInsets.fromLTRB(17, 0, 17, 8),
          child: _hinweisKasten(t('peerNeedsUpdate'), warnend: false),
        ),
      if (chatFehlerText() != null)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: p.tint,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.tintLine)),
          child: Text(chatFehlerText()!,
              style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
        ),
      if (Gruppe.istGruppenId(cid) && !(st.gruppeZu(cid)?.aktiv ?? false))
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(17, 14, 17, 18),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: p.lineSoft))),
          child: SafeArea(
            top: false,
            child: Text(t('groupNotMember'), textAlign: TextAlign.center,
                style: mono(size: 12, color: p.dim)),
          ),
        )
      else
      Container(
        padding: const EdgeInsets.fromLTRB(17, 11, 17, 16),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: p.lineSoft))),
        // DER ABSTAND GEHOERT NACH INNEN, nicht um das Container herum: so
        // laeuft die Trennlinie und der Hintergrund bis an den Rand durch, und
        // nur der Inhalt bleibt ueber der Systemleiste. Genauso macht es die
        // Reiterleiste in buildNav().
        //
        // Bei offener Tastatur ist padding.bottom von sich aus 0 — Flutter
        // zieht die Tastaturhoehe ab. Es entsteht also kein doppelter Abstand.
        child: SafeArea(
          top: false,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // DIESER KNOPF WAR EIN BILD. Bis zum 26.07.2026 stand hier ein
          // Container ohne GestureDetector: er sah aus wie ein Knopf, liess
          // sich druecken und tat nichts. Jetzt haengt die Dateiauswahl daran.
          //
          // Waehrend ein Versand laeuft, ist er stumm — einer nach dem
          // anderen. Dass er das ist, sieht man ihm an (p.dim statt p.muted),
          // statt dass ein Tippen ins Leere geht.
          Masse.trefferflaeche(
            // DATEI ODER UMFRAGE. Ein Menue statt zweier Knoepfe: die
            // Eingabezeile ist am Telefon schon voll.
            onTap: st.schwebendeKennung == null ? () => plusMenue(cid) : null,
            child: Container(
              width: 36, height: 36, alignment: Alignment.center,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: st.schwebendeKennung == null ? p.line : p.lineSoft)),
              child: Text('+',
                  style: TextStyle(
                      color: st.schwebendeKennung == null ? p.muted : p.dim,
                      fontSize: 16,
                      height: 1)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 2),
              child: TextField(
                controller: draftCtl,
                // INKOGNITO-TASTATUR, wie bei Signal und Threema — hier immer:
                // die Tastatur soll aus verschluesselten Unterhaltungen keine
                // Woerter lernen und sie spaeter anderswo vorschlagen. Das
                // Woerterbuch der Tastatur ist eine Kopie, die niemand
                // verschluesselt.
                enableIMEPersonalizedLearning: false,
                onChanged: (text) {
                  if (st.letzterFehler == 'zuLang') st.vergissFehler();
                  // Ein Befehl ist kein Tippen fuer die Gegenseite: wer
                  // "/timer" schreibt, schreibt niemandem.
                  st.eingabeGeaendert(cid, text.startsWith('/') ? '' : text);
                  // Neu zeichnen, solange ein Befehl dasteht — und EINMAL
                  // danach, damit die Leiste auch wieder verschwindet.
                  // "/" am Anfang oder ein "@" in einer Gruppe: die Leisten
                  // darueber haengen am Text.
                  final befehl = text.startsWith('/') ||
                      (text.contains('@') && st.gruppeZu(cid) != null);
                  if (befehl || _warBefehl) setState(() {});
                  _warBefehl = befehl;
                },
                style: mono(size: 13.5, color: p.ink),
                cursorColor: p.accent,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => send(),
                decoration: InputDecoration.collapsed(hintText: t('message'), hintStyle: mono(size: 13.5, color: p.dim)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // SPRACHNACHRICHT: nur, wo es den Kanal gibt (Android). Einmal
          // tippen nimmt auf, noch einmal tippen schickt; das Kreuz daneben
          // verwirft. Kein "gedrueckt halten": das verlangt eine ruhige Hand,
          // und ein verrutschter Daumen schickte eine halbe Nachricht.
          if (st.spracheMoeglich && _bearbeitungsZiel == null) ...[
            if (_aufnahmeSeit != null) ...[
              Semantics(
                button: true,
                toggled: _spracheEinmal,
                label: t('onceToggle'),
                child: GestureDetector(
                  key: const ValueKey('sprache-einmal'),
                  onTap: () => setState(() => _spracheEinmal = !_spracheEinmal),
                  child: Container(
                    width: 36, height: 36, alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: _spracheEinmal ? p.tint : null,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _spracheEinmal ? p.tintLine : p.line)),
                    child: Text('1×', style: mono(size: 11, weight: FontWeight.w600,
                        color: _spracheEinmal ? p.tintInk : p.muted)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Semantics(
                button: true,
                label: t('voiceDiscard'),
                child: GestureDetector(
                  onTap: _verwirfAufnahme,
                  child: Container(
                    width: 36, height: 36, alignment: Alignment.center,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
                    child: Text('×', style: TextStyle(color: p.muted, fontSize: 16, height: 1)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Semantics(
              button: true,
              label: _aufnahmeSeit == null ? t('voice') : t('voiceSend'),
              child: GestureDetector(
                onTap: () => _aufnahmeSeit == null ? _starteAufnahme(cid) : _schickeAufnahme(cid),
                child: Container(
                  key: ValueKey(_aufnahmeSeit == null ? 'mikro-bereit' : 'mikro-laeuft'),
                  height: 36, alignment: Alignment.center,
                  constraints: const BoxConstraints(minWidth: 36),
                  padding: EdgeInsets.symmetric(horizontal: _aufnahmeSeit == null ? 0 : 10),
                  decoration: BoxDecoration(
                      color: _aufnahmeSeit == null ? null : p.tint,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _aufnahmeSeit == null ? p.line : p.tintLine)),
                  // GEZEICHNET, NICHT GESETZT: Punkt = aufnehmen, Quadrat =
                  // anhalten, wie an jedem Rekorder. Als Textzeichen (● ■)
                  // hing ihre Groesse an der Schrift — das ● war in Chivo Mono
                  // ein Stecknadelkopf neben dem vollen "+" (Emulatorlauf
                  // 25.09.2026).
                  child: _aufnahmeSeit == null
                      ? Container(
                          width: 11, height: 11,
                          decoration: BoxDecoration(color: p.muted, shape: BoxShape.circle))
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                              width: 9, height: 9,
                              decoration: BoxDecoration(
                                  color: p.tintInk, borderRadius: BorderRadius.circular(1.5))),
                          const SizedBox(width: 8),
                          Text(_aufnahmeDauer(), style: mono(size: 12, color: p.tintInk)),
                        ]),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: send,
            // LANGER DRUCK PLANT, wie bei Signal. Rechtsklick am Rechner.
            onLongPress: _planeSenden,
            onSecondaryTap: _planeSenden,
            child: Container(
              height: 36, alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.accent)),
              child: Text(t('send').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
            ),
          ),
          ]),
        ),
      ),
    ]);
  }

  String? chatFehlerText() {
    final f = st.letzterFehler;
    if (f == null) return null;
    if (f == 'zuLang') return t('tooLong');
    if (f == 'nichtMehrMoeglich') return t('notPossible');
    if (f == 'geplantVorbei') return t('schedulePast');
    if (f == 'mikrofonNein') return t('micDenied');
    if (f == 'mikrofonDauerhaft') return t('micDeniedForever');
    if (f == 'aufnahmeFehler') return t('micFailed');
    if (f == 'lagerVoll') return t('attachFull');
    if (f == 'tagesmenge') return t('attachQuota');
    if (f == 'anhangKaputt') return t('attachBroken');
    if (f == 'anhangNetz' || f == 'anhangFehler') return t('attachNet');
    if (f == 'anhangWeb') return t('attachWeb');
    if (f == 'anhangLaeuft') return t('attachBusy');
    if (f == 'anhangKeineApp') return t('attachNoApp');
    if (f == 'anhangUnlesbar') return t('attachUnreadable');
    if (f == 'anhangFehlt') return t('attachMissing');
    if (f == 'nurNahbereich') return t('nearOnlyNoAttach');
    if (f.startsWith('anhangZuGross:')) return t('attachTooBig');
    if (f == 'metaNichtEntfernt') return t('metaNotRemoved');
    // Schluessel, die anderswo gesetzt werden, aber hier landen koennen —
    // roh stand dann "phraseUngueltig" ueber der Eingabezeile.
    if (f == 'phraseUngueltig') return t('phraseInvalid');
    if (f == 'adresseUngueltig') return t('badAddress');
    if (f == 'pushFremd') return t('pushForeign');
    if (f == 'sicherungPasstNicht') return t('backupWrong');
    // WAS HIER NICHT AUFGEZAEHLT IST, WIRD TROTZDEM GEZEIGT.
    //
    // Vorher stand hier `return null` — jeder Fehler ohne eigenen Satz
    // verschwand also spurlos. Das ist die schlechteste aller Auskuenfte: der
    // Nutzer sieht, dass nichts ankommt, und die App schweigt dazu.
    //
    // Ein unuebersetzter technischer Text ist haesslich, aber er laesst sich
    // abfotografieren und weitergeben. Genau das brauchte ich am 29.07.2026
    // und hatte es nicht.
    return f;
  }
}
