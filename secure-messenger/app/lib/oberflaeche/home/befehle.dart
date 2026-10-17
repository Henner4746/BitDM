// befehle.dart — /-Befehle, Erwaehnungen, Plus-Menue, Umfragen.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

const _befehle = ['timer', 'verify', 'poll', 'theme', 'shrug', 'wipe'];

extension _Befehle on _HomeState {
  /// Vorschlaege fuer "@" in einer Gruppe: die Mitglieder ausser mir.
  List<String> _passendeErwaehnungen() {
    final g = st.gruppeZu(chat ?? '');
    final text = draftCtl.text;
    final at = text.lastIndexOf('@');
    if (g == null || at < 0) return const [];
    final teil = text.substring(at + 1).toUpperCase();
    if (teil.contains(' ') || teil.contains('\n')) return const [];
    return g.mitglieder
        .where((m) => m != st.meineAdresse)
        .map(AppState.erwaehnungVon)
        .where((e) => e.substring(1).startsWith(teil))
        .toList();
  }

  /// Die Leiste mit den Mitgliedern, sobald in einer Gruppe "@" getippt wird.
  Widget erwaehnungsLeiste() {
    final passend = _passendeErwaehnungen();
    if (passend.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
          color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in passend)
          GestureDetector(
            key: ValueKey('erwaehne-$e'),
            onTap: () {
              final text = draftCtl.text;
              final at = text.lastIndexOf('@');
              draftCtl.text = '${text.substring(0, at)}$e ';
              draftCtl.selection = TextSelection.collapsed(offset: draftCtl.text.length);
              setState(() {});
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), border: Border.all(color: p.tintLine)),
              child: Text(e, style: mono(size: 11, weight: FontWeight.w600, color: p.accLight)),
            ),
          ),
      ]),
    );
  }

  List<String> _passendeBefehle() {
    final text = draftCtl.text;
    if (!text.startsWith('/') || text.contains('\n')) return const [];
    final wort = text.substring(1).split(' ').first.toLowerCase();
    // Steht der Befehl schon vollstaendig da und ein Argument dahinter, ist die
    // Leiste nur noch im Weg — ausser beim Thema, dort zeigt sie die Namen.
    if (text.contains(' ') && wort != 'theme' && wort != 'timer') return const [];
    return _befehle.where((b) => b.startsWith(wort)).toList();
  }

  /// Die Vorschlaege ueber der Schreibzeile, sobald sie mit "/" beginnt.
  Widget befehlsLeiste() {
    final passend = _passendeBefehle();
    if (passend.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(17, 0, 17, 8),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
          color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final b in passend)
          InkWell(
            key: ValueKey('befehl-$b'),
            onTap: () {
              draftCtl.text = '/$b ';
              draftCtl.selection = TextSelection.collapsed(offset: draftCtl.text.length);
              setState(() {});
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              child: Row(children: [
                Text('/$b', style: mono(size: 12.5, weight: FontWeight.w600, color: p.accLight)),
                const SizedBox(width: 10),
                Expanded(child: Text(
                    b == 'theme'
                        ? _themen.map((th) => th.id.toLowerCase()).join(' · ')
                        : t('cmd_$b'),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: mono(size: 10.5, color: p.dim, height: 1.4))),
              ]),
            ),
          ),
      ]),
    );
  }

  /// Fuehrt einen Befehl aus. false = kein bekannter Befehl, der Text geht
  /// als Nachricht hinaus.
  Future<bool> _fuehreBefehlAus(String eingabe) async {
    final cid = chat;
    if (cid == null) return false;
    final teile = eingabe.substring(1).trim().split(RegExp(r'\s+'));
    final befehl = teile.first.toLowerCase();
    final arg = teile.length > 1 ? teile[1].toLowerCase() : '';
    switch (befehl) {
      case 'timer':
        const fristen = <String, Duration?>{
          '1h': Duration(hours: 1),
          '24h': Duration(hours: 24),
          '1d': Duration(hours: 24),
          '7d': Duration(days: 7),
          '1w': Duration(days: 7),
          // Duration.zero ist "aus fuer diesen Chat", null "wie in den
          // Einstellungen" — dieselben Werte wie im Verschluesselungsblatt.
          'off': Duration.zero,
          'aus': Duration.zero,
          'std': null,
        };
        if (!fristen.containsKey(arg)) {
          _hinweis(t('cmdTimerBad'));
          return true;
        }
        await st.setzeChatFrist(cid, fristen[arg]);
        _hinweis('${t('selfDestruct')}: ${fristText(st.fristFuer(cid))}');
        return true;
      case 'verify':
        if (st.gruppeZu(cid) != null || st.istNotizen(cid)) {
          _hinweis(t('cmdVerifyNone'));
          return true;
        }
        setState(() => sheet = true);
        unawaited(_ladePruefnummer(cid));
        return true;
      case 'poll':
        unawaited(_legeUmfrageAn(cid));
        return true;
      case 'theme':
        final ziel = _themen.where((th) =>
            th.id.toLowerCase() == arg ||
            th.name.values.any((n) => n.toLowerCase().replaceAll(' ', '') == arg));
        if (ziel.isEmpty) {
          _hinweis(t('cmdThemeBad'));
          return true;
        }
        await _waehleThema(ziel.first.id);
        return true;
      case 'wipe':
        if (st.gruppeZu(cid) != null || st.istNotizen(cid)) {
          _hinweis(t('cmdVerifyNone'));
          return true;
        }
        final sicher = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t('wipeAskTitle')),
            content: Text(t('wipeAskText').replaceFirst('{id}', shortId(adresseFormatiert(cid))),
                style: mono(size: 12, color: p.muted, height: 1.5)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('wipeSend'))),
            ],
          ),
        );
        if (sicher == true) {
          await st.sendeLoeschanfrage(cid);
          _hinweis(t('wipeSent'));
        }
        return true;
      case 'shrug':
        // Der Rest NACH dem Befehlswort, nicht nach einer festen Stelle: bei
        // "/ shrug hi" schnitt `substring(1 + 5)` mitten ins Wort ("g hi").
        final rest = eingabe.substring(1).trimLeft().substring(befehl.length).trim();
        await st.senden(cid, rest.isEmpty ? r'¯\_(ツ)_/¯' : '$rest ' r'¯\_(ツ)_/¯');
        return true;
    }
    return false;
  }

  void plusMenue(String cid) {
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
        // [tun] null: abgeschaltet — grau und ohne Wirkung.
        Widget eintrag(String text, VoidCallback? tun) => InkWell(
              onTap: tun == null
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      tun();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(text, style: mono(size: 13.5, color: tun == null ? p.dim : p.ink)),
              ),
            );
        // ABGESCHALTET MIT GRUND statt eines Punkts, der auf Druck nichts tut
        // (so war es am PC bis 17.10.2026). Heute nur noch im Browser.
        final fehlt = st.dateien.auswahlFehlt;
        return SafeArea(
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            eintrag(t('attach'), fehlt == null ? () => anhangWaehlen(cid) : null),
            eintrag(t('attachOnce'), fehlt == null ? () => anhangWaehlen(cid, einmal: true) : null),
            if (fehlt != null)
              Padding(
                key: const ValueKey('anhang-grund'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(fehlt == 'anhangWeb' ? t('attachWeb') : t('attachNoPicker'),
                    style: mono(size: 11, color: p.muted, height: 1.45)),
              ),
            eintrag(t('pollNew'), () => _legeUmfrageAn(cid)),
            const SizedBox(height: 6),
          ])),
        );
      },
    );
  }

  Future<void> _legeUmfrageAn(String cid) async {
    final frage = TextEditingController();
    final optionen = [TextEditingController(), TextEditingController()];
    var mehrfach = false;
    String? fehler;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('pollNew'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: frage, maxLength: Umfrage.maxFrage, enableIMEPersonalizedLearning: false,
                  style: mono(size: 13, color: p.ink),
                  decoration: InputDecoration(hintText: t('pollQuestion'), counterText: '', hintStyle: mono(size: 13, color: p.dim))),
              for (var i = 0; i < optionen.length; i++)
                TextField(controller: optionen[i], maxLength: Umfrage.maxOption, enableIMEPersonalizedLearning: false,
                    style: mono(size: 13, color: p.ink),
                    decoration: InputDecoration(hintText: '${t('pollOption')} ${i + 1}', counterText: '', hintStyle: mono(size: 13, color: p.dim))),
              if (optionen.length < Umfrage.maxOptionen)
                TextButton(
                  onPressed: () => neu(() => optionen.add(TextEditingController())),
                  child: Text('+ ${t('pollOption')}'),
                ),
              Row(children: [
                Checkbox(value: mehrfach, onChanged: (v) => neu(() => mehrfach = v ?? false)),
                Expanded(child: Text(t('pollMulti'), style: mono(size: 12, color: p.muted))),
              ]),
              if (fehler != null)
                Text(fehler!, style: mono(size: 11.5, color: p.tintInk)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                final antworten = [
                  for (final o in optionen)
                    if (o.text.trim().isNotEmpty) o.text.trim(),
                ];
                final u = Umfrage(frage.text.trim(), antworten, mehrfach: mehrfach);
                if (Umfrage.lies(u.alsText()) == null) {
                  neu(() => fehler = t('pollInvalid'));
                  return;
                }
                Navigator.pop(ctx);
                _selbstGeschrieben = true;
                await st.sendeUmfrage(cid, u);
              },
              child: Text(t('send')),
            ),
          ],
        ),
      ),
    );
    _entsorgeNachDemSchliessen([frage, ...optionen]);
  }

  /// Eine Umfrage in der Blase: Frage, und je Antwort Anzahl und Balken.
  /// Antippen waehlt oder nimmt die Wahl zurueck.
  Widget umfrageInhalt(String cid, Message m) {
    final u = Umfrage.lies(m.text);
    if (u == null) return const SizedBox.shrink();
    final stimmen = st.stimmenZu(cid, m.id);
    final meine = stimmen[st.meineAdresse] ?? const <int>[];
    final zaehler = List<int>.filled(u.optionen.length, 0);
    for (final a in stimmen.values) {
      for (final i in a) {
        if (i >= 0 && i < zaehler.length) zaehler[i]++;
      }
    }
    final gesamt = stimmen.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(u.frage, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: p.ink, height: 1.4)),
      const SizedBox(height: 2),
      Text(u.mehrfach ? t('pollMulti') : t('pollSingle'), style: mono(size: 9.5, color: p.dim)),
      const SizedBox(height: 6),
      for (var i = 0; i < u.optionen.length; i++)
        Semantics(
          button: true,
          selected: meine.contains(i),
          label: '${u.optionen[i]}, ${zaehler[i]}',
          child: GestureDetector(
            // DIE GANZE ZEILE, nicht nur Text und Kreis. Ohne `opaque` traf
            // nur, was gemalt ist — ein Tipp auf den Balken oder den
            // Zwischenraum ging ins Leere (Emulatorlauf 25.09.2026: die
            // Mitte der Zeile zaehlte nicht).
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final neu = meine.contains(i)
                  ? (List.of(meine)..remove(i))
                  : (u.mehrfach ? [...meine, i] : [i]);
              st.stimme(cid, m.id, neu);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  wahlZeichen(meine.contains(i), u.mehrfach,
                      ValueKey('wahl-${m.id}-$i-${meine.contains(i) ? 'an' : 'aus'}')),
                  const SizedBox(width: 8),
                  Expanded(child: Text(u.optionen[i], style: TextStyle(fontSize: 13, color: p.ink))),
                  Text('${zaehler[i]}', style: mono(size: 11, color: p.muted)),
                ]),
                const SizedBox(height: 3),
                // Ohne Prozentzeile: die Zahl steht rechts schon da.
                fortschrittsBalken(gesamt == 0 ? 0 : zaehler[i] / gesamt, mitZahl: false),
              ]),
            ),
          ),
        ),
    ]);
  }
}
