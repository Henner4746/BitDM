// kontakt_neu.dart — Kontakt hinzufuegen, QR-Scan, Anfrage senden.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _KontaktNeu on _HomeState {
  /// Liest eine Adresse per Kamera ein.
  ///
  /// Der sicherste Weg, eine Adresse auszutauschen: ein QR-Code im
  /// persoenlichen Gespraech geht durch keinen Kanal, den jemand veraendern
  /// koennte. Bei 56 Zeichen ist Abtippen ausserdem fehleranfaellig.
  Future<void> _scanneQr() async {
    final adresse = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          titel: t('scan'),
          hinweis: t('scanHint'),
          keineKamera: t('scanNoCamera'),
          abbrechen: t('cancel'),
          // BEIDE STELLEN MUESSEN NORMALISIEREN, und beide auf dieselbe Art.
          //
          // Hier stand `RegExp(r'[s-]')` — eine Zeichenklasse aus 's' und '-',
          // nicht "Leerraum oder Strich". Aus jeder gescannten Adresse fiel
          // damit der Buchstabe s heraus, und Adressen sind Base32 in
          // Kleinbuchstaben: s kommt in fast jeder vor. Die Pruefsumme
          // scheiterte, der Leser nahm den Code NIE an und suchte weiter. Von
          // aussen sah es aus, als koenne die App keine QR-Codes lesen.
          //
          // Unten in dieser Methode war derselbe Fehler schon behoben — hier
          // oben nicht, und HIER faellt die Entscheidung. Deshalb steht jetzt
          // an beiden Stellen dieselbe Funktion statt einer zweiten
          // handgeschriebenen Fassung davon.
          istGueltig: (s) => st.adresseGueltig(BitdmAddress.normalize(s)),
        ),
      ),
    );
    if (adresse == null || !mounted) return;
    setState(() => addCtl.text = adresseFormatiert(BitdmAddress.normalize(adresse)));
  }

  Future<void> sendReq() async {
    final eingabe = addCtl.text.replaceAll(RegExp(r'[\s\-]'), '');
    if (eingabe.isEmpty) return;
    final r = await st.kontaktHinzufuegen(eingabe);
    if (!mounted) return;
    // HATTE DIE GEGENSEITE SCHON ANGEFRAGT, war das ein Annehmen — und dann
    // geht der Chat auf, genau wie beim Annehmen auf der Karte ([acceptReq]).
    final id = r.id;
    if (r.art == Hinzugefuegt.angenommen && id != null) {
      await Benachrichtigungen.instanz.frageErlaubnis();
      if (!mounted) return;
      await st.unterhaltungOeffnen(id);
      if (!mounted) return;
      setState(() { reqErgebnis = null; screen = 'chat'; chat = id; });
      return;
    }
    setState(() =>
        reqErgebnis = r.art == Hinzugefuegt.ungueltig ? null : r.art);
  }

  // ---- ADD ----
  Widget addScreen() {
    final Widget inhalt = Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('chats')),
          const SizedBox(width: 11),
          // FEHLERBEHEBUNG, AUCH FUER ANDROID: ohne Expanded laeuft eine
          // laengere Uebersetzung aus der Row heraus ("Kontakt hinzufügen" auf
          // einem schmalen Telefon). Dass 'restore', 'test' und 'nahHilfe' das
          // Expanded schon hatten, macht es hier nicht zur Angleichung — es war
          // an dieser Stelle schlicht kaputt.
          Expanded(child: h2(t('addTitle'), size: 20)),
        ]),
        const SizedBox(height: 16),
        Text(t('idLabel').toUpperCase(), style: mono(size: 10.5, color: p.dim, spacing: 1.6)),
        const SizedBox(height: 6),
        // Strg+Eingabe schickt die Anfrage; Begruendung siehe 'restore'. Der
        // Rahmen zeigt den Fokus, damit man das leere Feld am Zug erkennt.
        _mitStrgEingabe(
          sendReq,
          Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _imFenster && _addFokus.hasFocus ? p.accent : p.line)),
          padding: const EdgeInsets.all(11),
          child: TextField(
            controller: addCtl,
            focusNode: _addFokus,
            maxLines: 3,
            style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 1.4, height: 1.7),
            cursorColor: p.accent,
            decoration: InputDecoration.collapsed(hintText: beispielAdresse, hintStyle: doto(size: 15, weight: FontWeight.w600, color: p.dim, spacing: 1.4, height: 1.7)),
          ),
        ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          smallBtn(t('paste'), () async {
            final d = await Clipboard.getData(Clipboard.kTextPlain);
            final txt = d?.text?.trim();
            if (txt == null || txt.isEmpty || !mounted) return;
            setState(() => addCtl.text = txt);
          }),
          // KEIN QR-SCANNER AUSSERHALB VON ANDROID. pubspec.lock bringt nur
          // camera_android_camerax, camera_avfoundation und camera_web mit —
          // auf Windows und Linux wirft `availableCameras()` eine
          // MissingPluginException, und `_starte()` in qr_scan_screen.dart
          // faengt nur CameraException. Der Druck landete also auf einer Seite
          // mit Fehlerbild statt auf einem Scanner. Im Web gibt es camera_web,
          // dort ist aber `startImageStream` nicht umgesetzt — dasselbe Ende.
          //
          // Dieselbe Begruendung wie bei den Anmeldefaktoren (`_faktorGehtHier`):
          // ein Bedienelement, das auf Tippen mit einem Fehler antwortet, laesst
          // am Rest der App zweifeln. Im Widget-Test meldet Flutter android,
          // dort bleibt der Knopf sichtbar.
          if (_nurAufAndroid) const SizedBox(width: 8),
          if (_nurAufAndroid) smallBtn(t('scan'), _scanneQr),
        ]),
        const SizedBox(height: 16),
        _knopfBreite(outlineBtn(t('sendReq'), sendReq, padding: const EdgeInsets.all(13))),
        if (reqErgebnis case final erg?) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                // "Ausstehend" nur, wo etwas aussteht.
                if (erg != Hinzugefuegt.schonKontakt) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(4)),
                    child: Text(t('pending').toUpperCase(), style: mono(size: 10, weight: FontWeight.w500, color: p.tintInk, spacing: 1.2)),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                    shortId(adresseFormatiert(
                        addCtl.text.replaceAll(RegExp(r'[\s\-]'), ''))),
                    style: doto(size: 13, weight: FontWeight.w600, color: p.muted, spacing: 0.8)),
              ]),
              const SizedBox(height: 6),
              Text(
                  t(switch (erg) {
                    Hinzugefuegt.wartet => 'reqWaitsNote',
                    Hinzugefuegt.schonKontakt => 'reqKnownNote',
                    _ => 'reqSentNote',
                  }),
                  style: mono(size: 12, color: p.muted, height: 1.4)),
            ]),
          ),
        ],
        if (st.letzterFehler == 'adresseUngueltig') ...[
          const SizedBox(height: 12),
          Text(t('badAddress'), style: mono(size: 11.5, color: p.accLight, height: 1.5)),
        ],
        // Wie auf 'secure': im Fenster schob der Spacer die 11-pt-Fussnote an
        // den unteren Fensterrand, mit mehreren hundert Pixeln Leere darueber.
        // Und weil Spacer und Scrollview nicht zusammengehen, war der
        // Bildschirm gleichzeitig nicht scrollbar — mit eingeblendetem
        // Ergebnis-Kasten lief er in einem niedrigen Fenster ueber.
        if (_imFenster) const SizedBox(height: 22) else const Spacer(),
        Text(t('addFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );

    return _imFenster ? SingleChildScrollView(child: inhalt) : inhalt;
  }
}
