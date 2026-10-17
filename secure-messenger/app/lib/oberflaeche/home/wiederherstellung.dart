// wiederherstellung.dart — Wiederherstellen mit den zwoelf Woertern, Teilgeheimnisse.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
// SICHERHEITSRELEVANT: wer die Sperre prueft, liest home.dart, sperre.dart
// und zugriff.dart und sucht in den uebrigen Teilen nach frischBestaetigt.
part of '../home.dart';

extension _Wiederherstellung on _HomeState {
  /// Fragt nach k von n, zerlegt die Woerter und zeigt die Teile.
  Future<void> _erzeugeTeile() async {
    // Die Teile SIND die zwoelf Woerter, nur zerlegt — also erst ausweisen.
    if (!await frischBestaetigt()) return;
    if (!mounted) return;
    var wahl = '3/5';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          title: Text(t('trustTitle')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('trustHow'), style: mono(size: 12, color: p.muted, height: 1.5)),
            const SizedBox(height: 12),
            segmented(['2/3', '3/5', '4/7'], ['2 / 3', '3 / 5', '4 / 7'], wahl, (v) => neu(() => wahl = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('actCreate'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final k = int.parse(wahl.split('/')[0]);
    final n = int.parse(wahl.split('/')[1]);
    final List<Teil> teile;
    try {
      teile = teileWoerter(await st.phraseAusEinstellungen(), schwelle: k, anzahl: n);
    } catch (e) {
      _hinweis('$e');
      return;
    }
    if (!mounted) return;
    // Die Teile sind die Woerter in Stuecken: Screenshot-Schutz, solange das
    // Blatt offen ist — auch wenn er in den Einstellungen aus ist.
    await st.geheimnisSichtbar(true);
    if (!mounted) {
      await st.geheimnisSichtbar(false);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('trustSheetTitle').replaceFirst('{k}', '$k').replaceFirst('{n}', '$n'),
                style: mono(size: 14, weight: FontWeight.w600, color: p.ink, height: 1.4)),
            const SizedBox(height: 6),
            Text(t('trustWarn').replaceFirst('{k}', '$k'),
                style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
            const SizedBox(height: 12),
            for (var i = 0; i < teile.length; i++)
              Container(
                key: ValueKey('teil-$i'),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${t('trustPart')} ${i + 1} / $n',
                      style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1)),
                  const SizedBox(height: 4),
                  SelectableText(teile[i].alsText(), style: mono(size: 11, color: p.ink, height: 1.5)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: outlineBtn(t('copy'), () {
                      _kopiereGeheim(teile[i].alsText());
                      _hinweis(t('copiedSecret'));
                    }, padding: const EdgeInsets.all(8))),
                    const SizedBox(width: 8),
                    Expanded(child: outlineBtn(t('trustSend'), () => _sendeTeil(teile[i]),
                        accent: false, padding: const EdgeInsets.all(8))),
                  ]),
                ]),
              ),
          ]),
        ),
      ),
    ).whenComplete(() => st.geheimnisSichtbar(false));
  }

  /// Schickt einen Teil verschluesselt an einen Kontakt.
  Future<void> _sendeTeil(Teil teil) async {
    final kandidaten = st.aktiveKontakte.where((k) => !st.istNotizen(k.id)).toList();
    if (kandidaten.isEmpty) {
      _hinweis(t('trustNoContacts'));
      return;
    }
    final ziel = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t('trustSend')),
        children: [
          for (final k in kandidaten)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, k.id),
              child: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 13, color: p.ink)),
            ),
        ],
      ),
    );
    if (ziel == null) return;
    // GEHEIM: nach der Zustellung aus dem eigenen Verlauf geschwaerzt und
    // nicht an die eigenen Zweitgeraete gespiegelt — sonst laegen alle Teile
    // hier im Klartext, und die frische Anmeldung vor "Teile erzeugen" waere
    // mit einem Blick in den Verlauf umgangen.
    await st.senden(ziel, '${t('trustMsg')}\n\n${teil.alsText()}', geheim: true);
    _hinweis(t('trustSent'));
  }

  /// Die eingegebenen Woerter, klein und ohne Leerraum.
  List<String> get _phraseWoerter => phraseCtl.text
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Welche davon nicht in der BIP39-Liste stehen.
  Set<int> get _unbekannteWoerter {
    final aus = <int>{};
    final woerter = _phraseWoerter;
    for (var i = 0; i < woerter.length; i++) {
      if (!bip39EnglishWordlist.contains(woerter[i])) aus.add(i);
    }
    return aus;
  }

  Future<void> _stelleWieder() async {
    var woerter = _phraseWoerter;
    setState(() => restoreFehler = null);

    // TEILE VON VERTRAUENSKONTAKTEN statt der Woerter: stehen sie im Feld,
    // werden daraus die zwoelf Woerter, und danach geht es genau so weiter,
    // als haette jemand sie getippt — mit derselben Pruefsumme am Ende.
    if (phraseCtl.text.toUpperCase().contains('BITDM-TEIL')) {
      try {
        final teile = phraseCtl.text
            .split(RegExp(r'(?=BITDM-TEIL)', caseSensitive: false))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map(Teil.ausText)
            .toList();
        woerter = woerterAusTeilen(teile);
      } catch (e) {
        setState(() => restoreFehler = '${t('restorePartsBad')} $e');
        return;
      }
      setState(() => screen = 'creating');
      final ok = await st.identitaetWiederherstellen(woerter);
      if (!mounted) return;
      if (ok) {
        phraseCtl.clear();
        setState(() => screen = 'chats');
      } else {
        setState(() {
          screen = 'restore';
          restoreFehler = t('restoreChecksum');
        });
      }
      return;
    }

    if (woerter.length != kRecoveryPhraseWords) {
      setState(() => restoreFehler = t('restoreCount')
          .replaceFirst('{n}', '${woerter.length}')
          .replaceFirst('{soll}', '$kRecoveryPhraseWords'));
      return;
    }
    if (_unbekannteWoerter.isNotEmpty) {
      setState(() => restoreFehler = t('restoreUnknownWord'));
      return;
    }

    setState(() => screen = 'creating');
    final ok = await st.identitaetWiederherstellen(woerter);
    if (!mounted) return;
    if (ok) {
      phraseCtl.clear();
      setState(() => screen = 'chats');
    } else {
      // Die Woerter stehen alle in der Liste, aber die Pruefsumme stimmt
      // nicht: es sind die richtigen Woerter in der falschen Reihenfolge,
      // oder eines ist ein anderes aus derselben Liste. Das muss anders
      // klingen als "ein Wort kenne ich nicht".
      setState(() {
        screen = 'restore';
        restoreFehler = t('restoreChecksum');
      });
    }
  }

  Widget wiederherstellenScreen() {
    final woerter = _phraseWoerter;
    final unbekannt = _unbekannteWoerter;
    final vollstaendig = woerter.length == kRecoveryPhraseWords;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // EINE GLYPHE FUER ALLE ZURUECK-KNOEPFE, auf jeder Plattform. Dieser
          // hier war der einzige mit '<', 'add', 'test' und 'nahHilfe' hatten
          // schon '‹' — und die beiden sehen deutlich verschieden aus. Das ist
          // eine Vereinheitlichung und keine Desktop-Sache: sie aendert das
          // Zeichen auch auf dem Telefon, und das ist gewollt (30.07.2026).
          // Nicht auf `go` umgestellt — hier muss zusaetzlich `restoreFehler`
          // weg.
          iconBtn('‹', () => setState(() { screen = 'onboard'; restoreFehler = null; })),
          const SizedBox(width: 11),
          Expanded(child: h2(t('restoreTitle'), size: 24)),
        ]),
        const SizedBox(height: 12),
        Text(t('restoreIntro'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 6),
        Text(t('restoreParts'),
            style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 16),

        // DER RAHMEN ZEIGT DEN FOKUS — IM FENSTER. Der Kasten zeichnet den
        // Rahmen, das Feld darin weiss nichts davon; beim Hineinklicken oder
        // Hineintabben aenderte sich bisher nichts Sichtbares, und auf einem
        // leeren Feld war damit nicht zu erkennen, dass es am Zug ist. Auf dem
        // Telefon bleibt er still: dort ist Tippen ins Feld der Normalfall, der
        // Rahmen wuerde bei jeder Benutzung wechseln, und jeder Wechsel kostet
        // einen Neubau des ganzen _HomeState (siehe initState).
        //
        // DEN FOKUS BEIM OEFFNEN bekommt dieses Feld im Fenster von
        // [_sorgeFuerFokus] — nicht ueber `autofocus`, siehe die Begruendung
        // dort. Auf dem Telefon geschieht das absichtlich nicht: dort wuerde
        // die Tastatur ungefragt aufklappen und den halben Bildschirm nehmen.
        // STRG+EINGABE STELLT WIEDER HER, Eingabe allein nicht: das Feld hat
        // vier Zeilen, dort ist die Eingabetaste der Zeilenumbruch. Strg+
        // Eingabe ist am Schreibtisch die uebliche Abkuerzung fuer "fertig" in
        // einem mehrzeiligen Feld — ohne sie war der wichtigste Bildschirm der
        // App ohne Maus nicht zu bedienen.
        _mitStrgEingabe(
          _stelleWieder,
          Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _imFenster && _phraseFokus.hasFocus
                      ? p.accent
                      : p.line)),
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: phraseCtl,
            focusNode: _phraseFokus,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            onChanged: (_) => setState(() => restoreFehler = null),
            style: mono(size: 14, color: p.ink, height: 1.6),
            cursorColor: p.accent,
            decoration: InputDecoration.collapsed(
                hintText: t('restoreHint'),
                hintStyle: mono(size: 13, color: p.dim, height: 1.6)),
          ),
        ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          smallBtn(t('paste'), () async {
            final d = await Clipboard.getData(Clipboard.kTextPlain);
            final txt = d?.text?.trim();
            if (txt == null || txt.isEmpty || !mounted) return;
            setState(() { phraseCtl.text = txt; restoreFehler = null; });
          }),
          const Spacer(),
          Text('${woerter.length} / $kRecoveryPhraseWords',
              style: mono(
                  size: 11,
                  weight: FontWeight.w600,
                  color: vollstaendig && unbekannt.isEmpty ? p.accLight : p.dim)),
        ]),
        const SizedBox(height: 14),

        // Die Woerter einzeln, damit sichtbar wird, WELCHES nicht stimmt.
        if (woerter.isNotEmpty)
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < woerter.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                    color: unbekannt.contains(i) ? p.tint : p.surf,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: unbekannt.contains(i) ? p.accent : p.line)),
                child: Text('${i + 1} ${woerter[i]}',
                    style: mono(
                        size: 11.5,
                        color: unbekannt.contains(i) ? p.tintInk : p.muted)),
              ),
          ]),

        if (restoreFehler != null) ...[
          const SizedBox(height: 14),
          _hinweisKasten(restoreFehler!),
        ],

        const SizedBox(height: 18),
        _knopfBreite(outlineBtn(t('restoreDo'), _stelleWieder,
            padding: const EdgeInsets.all(14), fontSize: 13)),
        const SizedBox(height: 14),

        // WAS DIE WIEDERHERSTELLUNG NICHT ZURUECKBRINGT. Das gehoert VOR die
        // Handlung, nicht danach: wer hier erwartet, seine Unterhaltungen
        // wiederzusehen, wird sonst zweimal enttaeuscht.
        Text(t('restoreNote'), style: mono(size: 11, color: p.dim, height: 1.55)),
      ]),
    );
  }
}
