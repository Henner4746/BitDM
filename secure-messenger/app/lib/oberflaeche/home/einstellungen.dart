// einstellungen.dart — Einstellungsbildschirm, Empfangstakt, Ruhezeit, Push-Hilfe.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Einstellungen on _HomeState {
  Future<void> _waehleRuhe(bool anfang) async {
    final jetzt = anfang ? st.einstellungen.ruheVon : st.einstellungen.ruheBis;
    final zeit = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: jetzt ~/ 60, minute: jetzt % 60),
        helpText: anfang ? t('quietFrom') : t('quietTo'));
    if (zeit == null) return;
    final m = zeit.hour * 60 + zeit.minute;
    await st.setzeEinstellungen(anfang
        ? st.einstellungen.copyWith(ruheVon: m)
        : st.einstellungen.copyWith(ruheBis: m));
  }

  /// Stellt um, wie oft im Hintergrund nach Nachrichten gesehen wird.
  Future<void> _setzeEmpfangsTakt(int minuten) async {
    setState(() => lockFehler = null);
    try {
      await st.setzeEmpfangsTakt(EmpfangsTakt.vonMinuten(minuten));
    } on PushException catch (e) {
      // KEIN VERTEILER: statt einer Fehlermeldung die Anleitung. Der Nutzer
      // hat nichts falsch gemacht — ihm fehlt eine App, und er kann nicht
      // wissen welche.
      if (!mounted) return;
      if (e.grund == PushHindernis.keinVerteiler) {
        // Zurueckstellen: eine Stufe, die nicht laeuft, darf nicht als
        // ausgewaehlt dastehen.
        await st.setzeEmpfangsTakt(EmpfangsTakt.aus);
        if (mounted) setState(() => enroll = 'pushHilfe');
      } else {
        setState(() => lockFehler = t('pushFailed'));
      }
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Was die gewaehlte Einstellung praktisch bedeutet.
  ///
  /// Steht als Fliesstext unter der Auswahl, weil die Unterschiede nicht
  /// selbsterklaerend sind: "alle 15 Minuten" klingt haeufiger als es sich
  /// anfuehlt, und "staendig" klingt teurer als es ist.
  String _empfangErklaerung() => switch (st.empfangsTakt) {
        EmpfangsTakt.aus => t('bgOffNote'),
        EmpfangsTakt.staendig => t('bgLiveNote'),
        EmpfangsTakt.viertelstunde => t('bg15Note'),
        EmpfangsTakt.stunde => t('bg60Note'),
        EmpfangsTakt.vierStunden => t('bg240Note'),
        EmpfangsTakt.push => t('bgPushNote'),
      };

  // ---- SETTINGS ----
  Widget settingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 11, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('settings')),
        const SizedBox(height: 17),
        label6(t('general')),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('language'), t('languageSub')),
          const SizedBox(height: 8),
          segmented(['en', 'de'], ['English', 'Deutsch'], lang, (v) {
            setState(() { lang = v; _setzeMeldetexte(); });
            // Gespeichert — bis 25.09.2026 vergass die App die Sprache bei
            // jedem Neustart.
            st.setzeEinstellungen(st.einstellungen.copyWith(sprache: v));
          }),
        ])),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('appearance'), t('appearanceSub')),
          const SizedBox(height: 10),
          themenWahl(),
          const SizedBox(height: 14),
          settingHead(t('themeDrift'), t('themeDriftSub')),
          const SizedBox(height: 8),
          segmented(['0', '1', '10', '60'], [t('off'), '1 min', '10 min', '1 h'],
              '${st.einstellungen.themaWandern}',
              (v) => st.setzeEinstellungen(
                  st.einstellungen.copyWith(themaWandern: int.parse(v)))),
        ])),
        const SizedBox(height: 3),
        toggleRow(t('quietHours'), t('quietHoursSub'), st.einstellungen.ruheAn,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(ruheAn: !st.einstellungen.ruheAn))),
        if (st.einstellungen.ruheAn)
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 6, 11, 4),
            child: Row(children: [
              Expanded(child: outlineBtn('${t('quietFrom')} ${_uhr(st.einstellungen.ruheVon)}',
                  () => _waehleRuhe(true), padding: const EdgeInsets.all(10))),
              const SizedBox(width: 8),
              Expanded(child: outlineBtn('${t('quietTo')} ${_uhr(st.einstellungen.ruheBis)}',
                  () => _waehleRuhe(false), padding: const EdgeInsets.all(10))),
            ]),
          ),
        const SizedBox(height: 3),
        toggleRow(t('decryptFx'), t('decryptFxSub'), st.einstellungen.entschluesseln,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                entschluesseln: !st.einstellungen.entschluesseln))),
        const SizedBox(height: 3),
        // Steht bei "Allgemein" und nicht bei "Sicherheit": das ist eine
        // Frage der Bequemlichkeit, nicht des Schutzes. Die beiden nicht zu
        // vermischen ist der Grund, warum die Abschnitte ueberhaupt getrennt
        // sind.
        toggleRow(t('autoScroll'), t('autoScrollSub'), st.einstellungen.autoScroll,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                autoScroll: !st.einstellungen.autoScroll))),
        const SizedBox(height: 22),
        label6(t('access')),
        ...zugriffsBlock(statusMode: false),
        Padding(padding: const EdgeInsets.fromLTRB(11, 3, 11, 0), child: Text(t('minOne'), style: mono(size: 10.5, color: p.dim))),

        // Die Frist erscheint erst, wenn es etwas zu sperren gibt. Ohne
        // Faktor waere sie eine Einstellung ohne Wirkung.
        if (st.faktoren.isNotEmpty) ...[
          const SizedBox(height: 3),
          settingCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                settingHead(t('lockDelay'), t('lockDelaySub')),
                const SizedBox(height: 8),
                segmented(
                  const ['0', '60', '300', '-1'],
                  [t('delayNow'), t('delay1m'), t('delay5m'), t('delayNever')],
                  '${st.sperrfristAlsZahl}',
                  (v) => _setzeSperrfrist(int.parse(v)),
                ),
              ])),
        ],

        // NICHT IM BROWSER: ein geschlossener Tab empfaengt nichts, und der
        // Weckdienst (UnifiedPush) wie der Vordergrunddienst sind Android.
        // Solange der Tab offen ist, bleibt die Verbindung ohnehin stehen.
        if (!kIsWeb) ...[
          const SizedBox(height: 22),
          label6(t('receiving')),
          settingCard(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            settingHead(t('bgReceive'), t('bgReceiveSub')),
            const SizedBox(height: 8),
            // OHNE PUSH AUF DEM DESKTOP. '-2' ist der Push-Takt, und der laeuft
            // ueber UnifiedPush — ein Android-Plugin. Auf Windows waehlbar zu
            // sein, aber beim Umschalten zu scheitern, ist schlechter als nicht
            // angeboten zu werden. Die Verbindung bleibt dort ohnehin offen, ein
            // Weckdienst von aussen wird also nicht gebraucht.
            segmented(
              _nurAufAndroid
                  ? const ['0', '-2', '-1', '15', '60']
                  : const ['0', '-1', '15', '60'],
              _nurAufAndroid
                  ? [t('bgOff'), t('bgPush'), t('bgLive'), t('bg15'), t('bg60')]
                  : [t('bgOff'), t('bgLive'), t('bg15'), t('bg60')],
              '${st.empfangsTakt.minuten}',
              (v) => _setzeEmpfangsTakt(int.parse(v)),
            ),
            const SizedBox(height: 10),
            Text(_empfangErklaerung(),
                style: mono(size: 11, color: p.dim, height: 1.55)),

            // Die Anleitung bleibt erreichbar, auch wenn Push schon laeuft:
            // ntfy kann nach einer Neuinstallation wieder auf seinem eigenen
            // Server stehen, und dann geht es ohne erkennbaren Grund nicht mehr.
            if (st.empfangsTakt.angestossen) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => enroll = 'pushHilfe'),
                child: Text(t('pushGuideLink').toUpperCase(),
                    style: mono(
                        size: 10,
                        weight: FontWeight.w600,
                        color: p.accLight,
                        spacing: 1.2)),
              ),
            ],

            // DER WIDERSPRUCH, DEN DER NUTZER KENNEN MUSS: eine Sperre, die
            // sofort zugeht, macht Hintergrundempfang unmoeglich. Nicht aus
            // Bequemlichkeit — der Relay verlangt eine Unterschrift mit dem
            // Identitaetsschluessel, und der liegt hinter der Sperre.
            if (st.empfangsTakt.an && !st.empfangMoeglich) ...[
              const SizedBox(height: 10),
              _hinweisKasten(t('bgConflict'), warnend: false),
            ]
            // Und die mildere Form davon: bei 1 oder 5 Minuten empfaengt die
            // App nur, bis die Frist um ist — sie verlaengert sich dafuer
            // nicht (AppState, "Sperren im Hintergrund").
            else if (st.empfangEndetMitFrist) ...[
              const SizedBox(height: 10),
              _hinweisKasten(t('bgUntilLock'), warnend: false),
            ],
          ])),
        ],

        // IN DER NAEHE steht VOR der Sicherheit, weil es ein Weg ist und
        // keine Einschraenkung. Die Einschraenkung "nur in der Naehe" ist
        // mitgewandert — sie gehoert zu dem Weg, den sie erzwingt, nicht zu
        // Bildschirmfotos und Lesebestaetigungen.
        // NUR WO ES FUNK GIBT. Der Nahbereich haengt vollstaendig am
        // Kotlin-Kanal `bitdm/nahfunk`; auf Windows gibt es ihn nicht, und zwei
        // Schalter, die nichts schalten, sind schlimmer als keine.
        if (_nurAufAndroid) ...[
          const SizedBox(height: 22),
          nahbereichBlock(),
        ],

        const SizedBox(height: 22),
        label6(t('security')),
        // Im Browser ohne Wirkung — derselbe Grund wie beim Hinweis im Chat.
        if (!kIsWeb) ...[
          toggleRow(t("screenshot"), t("screenshotSub"), st.einstellungen.blockScreenshots,
              () => st.setzeEinstellungen(st.einstellungen.copyWith(
                  blockScreenshots: !st.einstellungen.blockScreenshots))),
          const SizedBox(height: 3),
        ],
        toggleRow(t("readReceipts"), t("readReceiptsSub"), st.einstellungen.readReceipts,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                readReceipts: !st.einstellungen.readReceipts))),
        const SizedBox(height: 3),
        // FERNLOESCHUNG: gemeinsam koennen Vertrauenskontakte dieses Geraet
        // loeschen lassen (k von n, 24 Stunden, 10 Minuten Countdown).
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('wipeTitle'), t('wipeSub')),
          const SizedBox(height: 8),
          outlineBtn(st.fernloeschung.an
                  ? t('wipeOn').replaceFirst('{k}', '${st.fernloeschung.schwelle}')
                      .replaceFirst('{n}', '${st.fernloeschung.vertraute.length}')
                  : t('wipeSetup'),
              _richteFernloeschungEin, padding: const EdgeInsets.all(9)),
          const SizedBox(height: 10),
          // DAS CODEWORT: statt /wipe schreibt ein Vertrauenskontakt das
          // vereinbarte Wort. Angezeigt wird nur, OB es gesetzt ist — das
          // Wort selbst steht nirgends mehr (fern_codewort.dart).
          Text(t('wipeCode'), style: mono(size: 12, weight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 3),
          Text(st.fernCodewortGesetzt ? t('wipeCodeIsSet') : t('wipeCodeNone'),
              key: const ValueKey('codewort-stand'),
              style: mono(size: 11, color: p.dim, height: 1.45)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: outlineBtn(
                st.fernCodewortGesetzt ? t('wipeCodeChange') : t('wipeCodeSet'),
                _richteCodewortEin,
                accent: false, padding: const EdgeInsets.all(9))),
            if (st.fernCodewortGesetzt) ...[
              const SizedBox(width: 8),
              Expanded(child: outlineBtn(t('wipeCodeRemove'), _entferneCodewort,
                  accent: false, padding: const EdgeInsets.all(9))),
            ],
          ]),
          const SizedBox(height: 6),
          outlineBtn(t('wipeHow'), _zeigeFernErklaerung,
              accent: false, padding: const EdgeInsets.all(9)),
        ])),
        const SizedBox(height: 3),
        // VERTRAUENSKONTAKTE: die zwoelf Woerter in Teile zerlegt (Shamir,
        // core/crypto/teilgeheimnis.dart). Einige zusammen stellen die
        // Identitaet wieder her, einer allein verraet nichts.
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('trustTitle'), t('trustSub')),
          const SizedBox(height: 8),
          outlineBtn(t('trustCreate'), _erzeugeTeile, padding: const EdgeInsets.all(9)),
        ])),
        const SizedBox(height: 3),
        // TOR: alles, was zum Relay und ins Zwischenlager geht, ueber Orbot.
        // Nicht im Browser: der kann weder SOCKS noch .onion.
        if (!kIsWeb) ...[
          toggleRow(t('torTitle'), t('torSub').replaceFirst('{port}', '${st.einstellungen.torPort}'),
              st.einstellungen.tor,
              () => st.setzeEinstellungen(st.einstellungen.copyWith(tor: !st.einstellungen.tor))),
          const SizedBox(height: 3),
        ],
        toggleRow(t('coverTitle'), t('coverSub'), st.einstellungen.tarnverkehr,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(tarnverkehr: !st.einstellungen.tarnverkehr))),
        const SizedBox(height: 3),
        // SICHERUNG: Kontakte und Verlauf als verschluesselte Datei, die nur
        // mit den zwoelf Woertern aufgeht. Zwei Knoepfe, weil es zwei Wege
        // sind, und die Erklaerung darunter sagt, was NICHT darin ist.
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('backup'), t('backupSub')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: outlineBtn(t('backupCreate'), () async {
              // Mit oder ohne die Dateien selbst — ohne ist klein und
              // verschickbar, mit ist vollstaendig (bis 100 MB).
              final mit = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(t('backup')),
                  content: Text(t('backupFilesAsk'), style: mono(size: 12, color: p.muted, height: 1.5)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('backupNoFiles'))),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('backupWithFiles'))),
                  ],
                ),
              );
              if (mit == null) return;
              final wo = await st.sichere(mitDateien: mit);
              if (wo != null && mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text('${t('backupSaved')} $wo')));
              }
            }, padding: const EdgeInsets.all(9))),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('backupRestore'), () async {
              final n = await st.spieleSicherungEin();
              if (n != null && mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text('${t('backupRestored')} $n')));
              }
            }, accent: false, padding: const EdgeInsets.all(9))),
          ]),
          if (st.letzterFehler == 'sicherungPasstNicht') ...[
            const SizedBox(height: 6),
            Text(t('backupWrong'), style: mono(size: 11.5, color: p.tintInk, height: 1.4)),
          ],
        ])),
        const SizedBox(height: 3),
        // DAS PANIK-WORT (frueher "Panik-Passwort"; ein Wort oder Satz). Nur,
        // wenn es eine Sperre gibt — ohne Sperre fragt die App nach nichts,
        // und ein Panik-Wort haette keinen Ort, an dem man es eingeben
        // koennte.
        if (st.sichtbareFaktoren.isNotEmpty) ...[
          toggleRow(t('panicPw'), t('panicPwSub'), st.hatPanikPasswort,
              () async {
                // Das Panik-Passwort ist Teil der Sperre: erst ausweisen.
                if (!await frischBestaetigt()) return;
                if (st.hatPanikPasswort) {
                  await st.entfernePanikPasswort();
                } else {
                  await _richtePanikPasswortEin();
                }
              }),
          const SizedBox(height: 3),
        ],
        toggleRow(t("typingSetting"), t("typingSettingSub"), st.einstellungen.tippAnzeige,
            () => st.setzeEinstellungen(st.einstellungen.copyWith(
                tippAnzeige: !st.einstellungen.tippAnzeige))),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('selfDestruct'), t('selfDestructSub')),
          const SizedBox(height: 8),
          segmented(["off", "1h", "24h", "7d"], [t("off"), t("h1"), t("h24"), t("d7")],
              _fristSchluessel,
              (v) => st.setzeEinstellungen(st.einstellungen.copyWith(
                  messageLifetime: _fristen[v], loescheLebensdauer: _fristen[v] == null))),
        ])),
        // Der Verbindungstest steht bei der Sicherheit und nicht ganz unten:
        // wer hier landet, sucht meist einen Fehler und soll ihn finden,
        // bevor er die Notfallknoepfe erreicht.
        const SizedBox(height: 3),
        settingCard(
            onTap: () {
              go('test');
              st.verbindungPruefen();
            },
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('connTestRow'),
                          style: TextStyle(fontSize: 13.5, color: p.ink)),
                      Text(t('connTestRowSub'),
                          style: mono(size: 11, color: p.dim)),
                    ]),
              ),
              Text('›', style: TextStyle(fontSize: 18, color: p.dim)),
            ])),

        const SizedBox(height: 22),
        label6(t('identity')),
        settingCard(
          onTap: () => go('id'),
          child: Row(children: [
            // Expanded: auf Deutsch ist die Beschriftung laenger, und die Zeile
            // lief bei 420 Punkten Breite um 38 ueber (Widget-Test 25.09.2026).
            Expanded(child: Text(t('myIdQr'), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: p.ink))),
            const SizedBox(width: 8),
            Text(shortId(meineAdresseAnzeige), style: doto(size: 12.5, weight: FontWeight.w600, color: p.dim, spacing: 0.8)),
          ]),
        ),
        const SizedBox(height: 3),
        // DIE ZWOELF WOERTER NOCH EINMAL. Bis hierher standen sie genau einmal
        // da, direkt nach dem Anlegen; wer sie damals nicht sauber notiert
        // hatte, kam nie wieder heran — obwohl die App sie die ganze Zeit
        // hatte. Hinter einer frischen Anmeldung und mit Screenshot-Schutz.
        KeyedSubtree(
          key: const ValueKey('woerter-zeigen'),
          child: settingCard(
            onTap: _zeigeWoerter,
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t('phraseShow'), style: TextStyle(fontSize: 13.5, color: p.ink)),
                  Text(t('phraseShowSub'), style: mono(size: 11, color: p.dim)),
                ]),
              ),
              Text('›', style: TextStyle(fontSize: 18, color: p.dim)),
            ]),
          ),
        ),
        const SizedBox(height: 3),
        // DAS SCHLUESSELBILD. Hier stand bis 25.09.2026 ein erfundener
        // "Fingerabdruck" ('b7d2 4e10 9af3') — derselbe Fehler, den die
        // Pruefnummer im Verschluesselungsblatt schon hinter sich hatte: er sah
        // nach Sicherheit aus und war keine. Das Bild entsteht aus der eigenen
        // Adresse, und die Kontakte sehen fuer diesen Schluessel dasselbe.
        settingCard(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SchluesselbildAnsicht(schluessel: st.meineAdresse, farbe: p.accLight, leer: p.line, punkt: 7, beschriftung: t('keyArtLabel')),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('keyArt'), style: TextStyle(fontSize: 13.5, color: p.ink)),
            const SizedBox(height: 3),
            Text(t('keyArtSelf'), style: mono(size: 10.5, color: p.dim, height: 1.45)),
          ])),
        ])),
        const SizedBox(height: 22),
        label6(t('emergency')),
        // Die Notfallzeile ist keine settingCard (eigene Warnfarben), braucht
        // die Huelle aber genauso: sie ist die folgenreichste Zeile der App.
        _Bedienbar(
          imFenster: _imFenster,
          onTap: () => setState(() => panic = true),
          bau: (ueber, fokus) => GestureDetector(
            onTap: () => setState(() => panic = true),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: ueber || fokus ? p.accHover : p.tintLine)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('panic'), style: TextStyle(fontSize: 13.5, color: p.tintInk)),
                Text(t('panicSub'), style: mono(size: 11, color: p.muted, height: 1.4)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  /// Die Anleitung fuer den Anstoss-Verteiler.
  ///
  /// WARUM DAS EINE EIGENE SEITE BRAUCHT: der Nutzer muss in einer ANDEREN App
  /// eine Einstellung finden, und zwar VOR dem Einschalten hier. Wer das in
  /// einen Satz packt, schickt ihn suchen. Die Menuepunkte stehen deshalb
  /// woertlich da, in der Reihenfolge, in der sie vorkommen.
  ///
  /// DIE REIHENFOLGE IST NICHT KOSMETISCH: ntfy baut die Anstoss-Adresse beim
  /// Anmelden aus dem eingestellten Standardserver. Wer erst hier einschaltet,
  /// bekommt eine Adresse auf ntfy.sh — und BitDM lehnt sie ab, weil der Relay
  /// nur den eigenen Push-Server annimmt.
  Widget pushHilfeModal() {
    return scrim(
      onTapOutside: () => setState(() => enroll = null),
      sheetCard(children: [
        Center(
            child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                    color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('pushGuideTitle'), size: 20),
        const SizedBox(height: 8),
        Text(t('pushGuideIntro'),
            style: mono(size: 12, color: p.muted, height: 1.55)),
        const SizedBox(height: 16),

        _schritt(1, t('pushStep1'), t('pushStep1Sub'), knoepfe: [
          _kleinerKnopf('F-Droid',
              () => _oeffneLink('https://f-droid.org/packages/io.heckel.ntfy/')),
          _kleinerKnopf('Play Store',
              () => _oeffneLink('https://play.google.com/store/apps/details?id=io.heckel.ntfy')),
        ]),

        _schritt(2, t('pushStep2'), t('pushStep2Sub'), knoepfe: [
          _kleinerKnopf(t('copy'), () {
            Clipboard.setData(const ClipboardData(text: pushBasis));
            setState(() => copied = true);
            Future.delayed(const Duration(milliseconds: 1400), () {
              if (mounted) setState(() => copied = false);
            });
          }),
          _kleinerKnopf(t('pushOpenNtfy'), () async {
            final da = await FremdeApp.oeffne(FremdeApp.ntfy);
            if (!da && mounted) {
              setState(() => lockFehler = t('pushNoNtfy'));
            }
          }),
        ]),

        // Die Adresse zum Abtippen, falls das Kopieren nicht ankommt.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          margin: const EdgeInsets.only(left: 32, bottom: 14),
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.line)),
          child: Text(copied ? t('copied') : pushBasis,
              style: mono(size: 12, color: copied ? p.accLight : p.ink)),
        ),

        _schritt(3, t('pushStep3'), t('pushStep3Sub')),
        _schritt(4, t('pushStep4'), t('pushStep4Sub')),

        _hinweisKasten(t('pushOrderWarning'), warnend: false),
        const SizedBox(height: 14),

        outlineBtn(t('close'), () => setState(() => enroll = null),
            padding: const EdgeInsets.all(11)),
      ]),
    );
  }

  String _uhr(int minuten) =>
      '${(minuten ~/ 60).toString().padLeft(2, '0')}:${(minuten % 60).toString().padLeft(2, '0')}';
}
