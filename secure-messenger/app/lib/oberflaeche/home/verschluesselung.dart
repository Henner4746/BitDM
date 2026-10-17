// verschluesselung.dart — Schloss-Blatt einer Unterhaltung: Pruefnummer, Frist, Anwesenheit.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Verschluesselung on _HomeState {
  Future<void> _ladePruefnummer(String id) async {
    setState(() { pruefnummer = null; pruefnummerFehler = null; });
    try {
      final n = await st.pruefnummer(id);
      if (mounted) setState(() => pruefnummer = n);
    } on MessengerException {
      // Es gibt noch keine Sitzung — erst muss eine Nachricht geflossen sein.
      if (mounted) setState(() => pruefnummerFehler = "verifyNoSession");
    }
  }

  Widget encSheet() {
    return scrim(
      onTapOutside: () => setState(() => sheet = false),
      sheetCard(children: [
        Center(child: Container(width: 36, height: 3, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('encryption'), size: 20),
        const SizedBox(height: 11),
        kvRow(t('protocol'), 'Double-Ratchet, X25519'),
        kvRow(t('selfDestruct'), fristText(st.fristFuer(chat ?? c1))),
        // JE UNTERHALTUNG, wie bei Signal. "Standard" folgt den
        // Einstellungen; alles andere gilt nur hier — und nur fuer das, was
        // man selbst schreibt.
        segmented(
          ['std', 'off', '1h', '24h', '7d'],
          [t('chatFristStd'), t('off'), t('h1'), t('h24'), t('d7')],
          _chatFristSchluessel(chat ?? c1),
          (v) => st.setzeChatFrist(chat ?? c1,
              v == 'std' ? null : (_fristen[v] ?? Duration.zero)),
        ),
        const SizedBox(height: 8),
        kvRow(t('readReceipts'), st.einstellungen.readReceipts ? t('on') : t('off')),
        const SizedBox(height: 11),

        // Die echte Pruefnummer. Hier stand vorher ein erfundener Wert
        // ('a3f9 21bd 77c4') — er sah nach Sicherheit aus und war keine.
        //
        // Beide Seiten sehen dieselben 60 Ziffern. Stimmen sie ueberein, sitzt
        // wirklich der Erwartete am anderen Ende und niemand dazwischen. Das
        // ist der einzige Weg, den ein Nutzer selbst gehen kann.
        label6(t('safetyNumber')),
        if (pruefnummerFehler != null)
          Text(t(pruefnummerFehler!), style: mono(size: 11.5, color: p.dim, height: 1.5))
        else if (pruefnummer == null)
          Text('…', style: mono(size: 13, color: p.dim))
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final g in pruefnummer!.groups)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
                child: Text(g, style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
              ),
          ]),

        const SizedBox(height: 14),
        label6(t('keyArt')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SchluesselbildAnsicht(schluessel: chat ?? c1, farbe: p.accLight, leer: p.line, punkt: 8, beschriftung: t('keyArtLabel')),
          const SizedBox(width: 12),
          Expanded(child: Text(t('keyArtPeer'), style: mono(size: 10.5, color: p.dim, height: 1.45))),
        ]),

        const SizedBox(height: 8),
        Container(height: 1, color: p.lineSoft),
        const SizedBox(height: 8),
        Text(t('verifyNote'), style: mono(size: 11, color: p.dim, height: 1.5)),

        // ANWESENHEIT JE KONTAKT.
        //
        // Sie steht hier und nicht in den Einstellungen, weil sie zu EINEM
        // Kontakt gehoert — und weil dies der einzige Ort ist, an dem man
        // ohnehin ueber diesen einen nachdenkt.
        //
        // NUR wenn der Funk ueberhaupt an ist: ein Schalter fuer eine
        // Anwesenheit, die niemand aussendet, waere eine Einstellung ohne
        // Wirkung — und der Nutzer wuesste nicht, warum sie nichts tut.
        if (st.einstellungen.naheAn) ...[
          const SizedBox(height: 11),
          Container(height: 1, color: p.lineSoft),
          const SizedBox(height: 11),
          label6(t('nearby')),
          toggleRow(
            t('presence'),
            t('presenceSub'),
            _zeigtAnwesenheit(chat ?? c1),
            () => _legeAnwesenheitUm(chat ?? c1),
          ),
        ],

        const SizedBox(height: 11),
        // ENTFERNEN GEHOERT HIERHER, und es fehlte ganz.
        //
        // `removeContact` steht seit jeher im Kern; gerufen hat es niemand.
        // Wer eine falsche Adresse eintippte — 56 Zeichen, kein Randfall —,
        // wurde sie nie wieder los. Am 29.07.2026 blieb auf einem Testgeraet
        // ein toter Kontakt stehen, den nichts mehr entfernen konnte.
        //
        // In diesem Blatt und nicht in der Liste: hier steht schon alles
        // andere ueber die Gegenstelle, und ein Wisch-zum-Loeschen in der
        // Chatliste waere die Sorte Geste, die man versehentlich macht.
        outlineBtn(t('removeContact'), _entferneOffenenKontakt,
            accent: false, padding: const EdgeInsets.all(11)),
        const SizedBox(height: 6),
        outlineBtn(t('close'), () => setState(() => sheet = false), padding: const EdgeInsets.all(11)),
      ]),
    );
  }

  String _chatFristSchluessel(String id) {
    final s = st.kontakte.where((k) => k.id == id).firstOrNull?.fristSekunden;
    if (s == null) return 'std';
    if (s == 0) return 'off';
    if (s <= 3600) return '1h';
    if (s <= 86400) return '24h';
    return '7d';
  }

  /// Ob dieser Kontakt uns sieht. Unbekannt heisst ja — so steht es im
  /// Datenmodell, und ein "nein" hier waere eine stille Abweichung davon.
  bool _zeigtAnwesenheit(String id) =>
      st.kontakte
          .where((k) => k.id == id)
          .map((k) => k.zeigtAnwesenheit)
          .firstOrNull ??
      true;

  Future<void> _legeAnwesenheitUm(String id) async {
    try {
      await st.setzeAnwesenheit(id, !_zeigtAnwesenheit(id));
    } on MessengerException {
      // Ein Kontakt, den es nicht mehr gibt. Kein Grund, das Blatt
      // wegzuwerfen — es schliesst sich gleich ohnehin.
    }
    if (mounted) setState(() {});
  }
}
