// gruppen.dart — Gruppen und Verteiler, Zustellung.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Gruppen on _HomeState {
  /// Die Unterhaltungen, die die Liste gerade zeigt: angeheftete zuerst, und
  /// entweder das Archiv oder alles andere.
  List<Gruppe> get sichtbareGruppen {
    final hier = st.gruppen.where((g) => g.archiviert == _zeigeArchiv);
    return [...hier.where((g) => g.angeheftet), ...hier.where((g) => !g.angeheftet)];
  }

  Widget gruppenZeile(Gruppe g) {
    final list = st.verlaufVon(g.id);
    final letzte = list.isEmpty ? null : list.last;
    final marken = [if (g.angeheftet) t('pinnedTag'), if (g.stumm) t('mutedTag')];
    final zeit = letzte == null ? '' : zeitVon(letzte.timestamp);
    return InkWell(
      onTap: () => oeffneChat(g.id),
      onLongPress: () => unterhaltungMenue(g.id),
      onSecondaryTap: () => unterhaltungMenue(g.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
            child: Text('${g.mitglieder.length}', style: doto(size: 15, weight: FontWeight.w600, color: p.tintInk)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: doto(size: 15, weight: FontWeight.w600, color: g.aktiv ? p.ink : p.dim, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(letzte == null ? (g.aktiv ? t('groupNew') : t('groupLeft')) : auszug(letzte),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(zeit, style: mono(size: 10.5, color: p.dim)),
            if ((screen == 'chat' && chat == g.id ? 0 : st.ungelesenIn(g.id)) > 0) ...[
              const SizedBox(height: 5),
              ungelesenMarke(st.ungelesenIn(g.id)),
            ],
            if (marken.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final mk in marken) Padding(padding: const EdgeInsets.only(left: 4), child: marke(mk)),
              ]),
            ],
          ]),
        ]),
      ),
    );
  }

  /// Eine Zeile fuer eine Verteilerliste — Antippen oeffnet das Schreibblatt.
  Widget verteilerZeile(Verteiler v) => InkWell(
        key: ValueKey('verteiler-${v.id}'),
        onTap: () => verteilerBlatt(v),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
          child: Row(children: [
            Container(
              width: 40, height: 40, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
              child: Text('⇉', style: TextStyle(fontSize: 18, color: p.accLight, height: 1)),
            ),
            const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
              const SizedBox(height: 3),
              Text('${t('listTag')} · ${v.mitglieder.length} ${t('groupMembers')}',
                  style: mono(size: 11.5, color: p.muted)),
            ])),
          ]),
        ),
      );

  /// Schreiben an eine Verteilerliste — und die Liste loeschen.
  void verteilerBlatt(Verteiler v) {
    final text = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v.name, style: doto(size: 18, weight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 4),
          Text(t('listExplain'), style: mono(size: 11, color: p.dim, height: 1.5)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in v.mitglieder) marke(shortId(adresseFormatiert(m))),
          ]),
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(minHeight: Masse.eingabeHoehe),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(Masse.eingabeRund), border: Border.all(color: p.line)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: TextField(
              key: const ValueKey('verteiler-text'),
              controller: text,
              minLines: 1, maxLines: 5,
              enableIMEPersonalizedLearning: false,
              style: mono(size: 13.5, color: p.ink),
              decoration: InputDecoration(border: InputBorder.none, hintText: t('message'),
                  hintStyle: mono(size: 13.5, color: p.dim)),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: outlineBtn(t('listDelete'), () async {
              Navigator.pop(ctx);
              await st.loescheVerteiler(v.id);
            }, accent: false, padding: const EdgeInsets.all(10))),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('send'), () async {
              final r = await st.sendeAnVerteiler(v.id, text.text);
              if (ctx.mounted) Navigator.pop(ctx);
              // Auch die, bei denen es scheiterte — sonst hielt man die Liste
              // fuer erledigt, waehrend die Haelfte nichts bekam.
              _hinweis(r.fehlgeschlagen == 0
                  ? t('listSent').replaceFirst('{n}', '${r.gesendet}')
                  : t('listSentFailed')
                      .replaceFirst('{n}', '${r.gesendet}')
                      .replaceFirst('{f}', '${r.fehlgeschlagen}'));
            }, padding: const EdgeInsets.all(10))),
          ]),
        ]),
      ),
    ).whenComplete(() => _entsorgeNachDemSchliessen([text]));
  }

  Future<void> _legeVerteilerAnDialog() async {
    final name = TextEditingController();
    final gewaehlt = <String>{};
    String? fehler;
    final kandidaten = st.aktiveKontakte.where((k) => !st.istNotizen(k.id)).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          title: Text(t('listCreate')),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('listExplain'), style: mono(size: 11, color: p.dim, height: 1.5)),
                TextField(controller: name, maxLength: Gruppe.maxName, enableIMEPersonalizedLearning: false,
                    style: mono(size: 13, color: p.ink),
                    decoration: InputDecoration(hintText: t('listName'), counterText: '', hintStyle: mono(size: 13, color: p.dim))),
                const SizedBox(height: 6),
                if (kandidaten.isEmpty)
                  Text(t('groupNoContacts'), style: mono(size: 12, color: p.muted)),
                for (final k in kandidaten)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: gewaehlt.contains(k.id),
                    onChanged: (v) => neu(() => v == true ? gewaehlt.add(k.id) : gewaehlt.remove(k.id)),
                    title: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 12, color: p.ink)),
                  ),
                if (fehler != null) Text(fehler!, style: mono(size: 11.5, color: p.tintInk)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || gewaehlt.isEmpty) {
                  neu(() => fehler = t('listInvalid'));
                  return;
                }
                Navigator.pop(ctx);
                await st.legeVerteilerAn(name.text, gewaehlt.toList());
              },
              child: Text(t('actCreate')),
            ),
          ],
        ),
      ),
    );
    _entsorgeNachDemSchliessen([name]);
  }

  Future<void> _legeGruppeAnDialog() async {
    final name = TextEditingController();
    final gewaehlt = <String>{};
    String? fehler;
    final kandidaten = st.aktiveKontakte.where((k) => !st.istNotizen(k.id)).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('groupCreate'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(controller: name, maxLength: Gruppe.maxName, enableIMEPersonalizedLearning: false,
                    style: mono(size: 13, color: p.ink),
                    decoration: InputDecoration(hintText: t('groupName'), counterText: '', hintStyle: mono(size: 13, color: p.dim))),
                const SizedBox(height: 6),
                if (kandidaten.isEmpty)
                  Text(t('groupNoContacts'), style: mono(size: 12, color: p.muted)),
                for (final k in kandidaten)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: gewaehlt.contains(k.id),
                    onChanged: (v) => neu(() => v == true ? gewaehlt.add(k.id) : gewaehlt.remove(k.id)),
                    title: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 12, color: p.ink)),
                  ),
                if (fehler != null) Text(fehler!, style: mono(size: 11.5, color: p.tintInk)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || gewaehlt.isEmpty ||
                    gewaehlt.length + 1 > Gruppe.maxMitglieder) {
                  neu(() => fehler = t('groupInvalid'));
                  return;
                }
                Navigator.pop(ctx);
                final id = await st.legeGruppeAn(name.text, gewaehlt.toList());
                if (mounted) oeffneChat(id);
              },
              child: Text(t('actCreate')),
            ),
          ],
        ),
      ),
    );
    _entsorgeNachDemSchliessen([name]);
  }

  /// Das Blatt einer Gruppe: Mitglieder, und fuer den Admin Hinzufuegen,
  /// Entfernen, Umbenennen. Austreten fuer alle.
  void gruppenBlatt(String gid) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.surf,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, neu) {
        final g = st.gruppeZu(gid);
        if (g == null) return const SizedBox.shrink();
        final admin = g.admin == st.meineAdresse && g.aktiv;
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                h2(g.name, size: 20),
                const SizedBox(height: 4),
                Text('${g.mitglieder.length} / ${Gruppe.maxMitglieder} ${t('groupMembers')}',
                    style: mono(size: 11, color: p.dim)),
                const SizedBox(height: 10),
                for (final m in g.mitglieder)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Identicon(m, 24, avp, 6),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            st.istNotizen(m) ? t('groupYou') : shortId(adresseFormatiert(m)),
                            style: mono(size: 12, color: p.ink)),
                      ),
                      if (m == g.admin) Text(t('groupAdmin'), style: mono(size: 10, color: p.accLight)),
                      if (admin && m != st.meineAdresse)
                        IconButton(
                          tooltip: t('groupRemove'),
                          onPressed: () async {
                            await st.entferneAusGruppe(gid, m);
                            neu(() {});
                          },
                          icon: Text('×', style: TextStyle(color: p.muted, fontSize: 16)),
                        ),
                    ]),
                  ),
                const SizedBox(height: 10),
                if (admin) ...[
                  outlineBtn(t('groupAdd'), () async {
                    Navigator.pop(ctx);
                    await _fuegeMitgliederHinzuDialog(gid);
                  }, padding: const EdgeInsets.all(10)),
                  const SizedBox(height: 6),
                  outlineBtn(t('groupRename'), () async {
                    Navigator.pop(ctx);
                    await _benenneGruppeDialog(gid);
                  }, accent: false, padding: const EdgeInsets.all(10)),
                  const SizedBox(height: 6),
                ],
                if (g.aktiv)
                  outlineBtn(t('groupLeave'), () async {
                    Navigator.pop(ctx);
                    await st.verlasseGruppe(gid);
                  }, accent: false, padding: const EdgeInsets.all(10)),
              ]),
            ),
          ),
        );
      }),
    );
  }

  Future<void> _fuegeMitgliederHinzuDialog(String gid) async {
    final g = st.gruppeZu(gid);
    if (g == null) return;
    final gewaehlt = <String>{};
    final kandidaten = st.aktiveKontakte
        .where((k) => !st.istNotizen(k.id) && !g.mitglieder.contains(k.id))
        .toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('groupAdd'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (kandidaten.isEmpty)
                  Text(t('groupNoContacts'), style: mono(size: 12, color: p.muted)),
                for (final k in kandidaten)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: gewaehlt.contains(k.id),
                    onChanged: (v) => neu(() => v == true ? gewaehlt.add(k.id) : gewaehlt.remove(k.id)),
                    title: Text(shortId(adresseFormatiert(k.id)), style: mono(size: 12, color: p.ink)),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (gewaehlt.isNotEmpty) await st.fuegeZuGruppeHinzu(gid, gewaehlt.toList());
              },
              child: Text(t('add')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _benenneGruppeDialog(String gid) async {
    final name = TextEditingController(text: st.gruppeZu(gid)?.name ?? '');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        title: Text(t('groupRename'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
        content: TextField(controller: name, maxLength: Gruppe.maxName, enableIMEPersonalizedLearning: false,
            style: mono(size: 13, color: p.ink)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (name.text.trim().isNotEmpty) await st.benenneGruppe(gid, name.text);
            },
            child: Text(t('actSave')),
          ),
        ],
      ),
    );
    _entsorgeNachDemSchliessen([name]);
  }

  // ═══════════════════════════════════════════════════════ Filter der Liste
  //
  // Alle · Ungelesen · Gruppen · ★. Nur eine Sicht, nichts wird verschoben —
  // und "ungelesen" folgt derselben Regel wie der Punkt an der Zeile, damit
  // Filter und Punkt sich nie widersprechen.

  /// Wer in der Gruppe eine eigene Nachricht schon hat.
  Future<void> _zeigeZustellung(String gid, Message m) async {
    final g = st.gruppeZu(gid);
    if (g == null) return;
    final haben = await st.zugestelltAn(gid, m.id);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('msgInfo'), style: mono(size: 14, weight: FontWeight.w600, color: p.ink)),
            const SizedBox(height: 4),
            Text(t('msgInfoSub'), style: mono(size: 10.5, color: p.dim, height: 1.5)),
            const SizedBox(height: 10),
            for (final mitglied in g.mitglieder.where((x) => x != st.meineAdresse))
              Padding(
                key: ValueKey('zustellung-$mitglied'),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Identicon(mitglied, 22, avp, 5),
                  const SizedBox(width: 10),
                  Expanded(child: Text(shortId(adresseFormatiert(mitglied)),
                      style: mono(size: 12.5, color: p.ink))),
                  Text(haben.contains(mitglied) ? '✓✓' : '✓',
                      style: TextStyle(fontSize: 12, color: haben.contains(mitglied) ? p.accLight : p.dim)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}
