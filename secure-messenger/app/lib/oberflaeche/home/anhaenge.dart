// anhaenge.dart — Anhaenge, Bilder, Einmal-Ansicht, Sprachaufnahme.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

final _bildEndung = RegExp(r'\.(jpe?g|png|webp|gif|heic|heif|avif)$', caseSensitive: false);

/// Aus Bytes eine Zahl, die man vorlesen kann.
///
/// Tausenderschritte und nicht 1024er: die Zahl steht neben einem
/// Dateinamen, nicht in einem Speichermonitor, und "1,2 GB" ist das, was
/// auch auf der Rechnung des Mobilfunkanbieters steht.
String groesseText(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).toStringAsFixed(0)} KB';
  if (bytes < 1000 * 1000 * 1000) {
    return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
}

extension _Anhaenge on _HomeState {
  String _aufnahmeDauer() {
    final d = DateTime.now().difference(_aufnahmeSeit ?? DateTime.now());
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _starteAufnahme(String cid) async {
    final recht = await Sprache.rechte();
    if (recht != 'ja') {
      st.setzeFehler(recht == 'dauerhaft' ? 'mikrofonDauerhaft' : 'mikrofonNein');
      return;
    }
    if (!await Sprache.starte()) {
      st.setzeFehler('aufnahmeFehler');
      return;
    }
    setState(() => _aufnahmeSeit = DateTime.now());
    // Die Anzeige der Dauer zaehlt sichtbar mit — sonst weiss niemand, ob
    // das Mikrofon wirklich laeuft.
    _aufnahmeTakt = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  Future<void> _schickeAufnahme(String cid) async {
    _aufnahmeTakt?.cancel();
    setState(() => _aufnahmeSeit = null);
    final a = await Sprache.stoppe();
    if (a == null) return; // zu kurz — nichts aufgenommen
    // AUCH EINE SPRACHNACHRICHT IST "SELBST GESCHRIEBEN" — siehe
    // [_haltUnten]. Ohne das galt sie als fremde, und weil ihre Blase hoeher
    // ist als der Spielraum von 140 Punkten, blieb die Liste stehen: die
    // eigene Sprachnachricht war abgeschickt und unsichtbar (Emulatorlauf
    // 25.09.2026). Dasselbe fuer Umfrage und Anhang.
    _selbstGeschrieben = true;
    final einmal = _spracheEinmal;
    setState(() => _spracheEinmal = false);
    await st.sendeSprachnachricht(cid, a, einmal: einmal);
  }

  bool istBildName(String name) => _bildEndung.hasMatch(name);

  /// Zeigt ein Bild bildschirmfuellend. Bei einer Einmal-Ansicht mit
  /// erzwungener Bildschirmsperre, und beim Schliessen ist die Datei weg.
  ///
  /// IM `finally`: sperrt die App, waehrend das Bild offen ist, schliesst die
  /// Sperre die Route (siehe [_raeumeOberflaecheAuf]) — und die Datei muss
  /// trotzdem weg. [AppState.verbraucheEinmal] kommt mit einem gesperrten
  /// Kern zurecht.
  ///
  /// DIE DATEI IST VERSCHLUESSELT (seit 25.09.2026). Bis 20 MB wird das Bild
  /// im Speicher entschluesselt und von dort gezeigt, ohne Klartextdatei;
  /// darueber ueber eine kurzlebige Kopie, die beim Schliessen wieder geht.
  /// ERST ENTSCHLUESSELN, DANN ZEIGEN: geht das schief, bleibt eine
  /// Einmal-Ansicht unverbraucht, statt ungesehen zu verschwinden.
  Future<void> zeigeBild(String cid, AnhangEintrag a) async {
    final pfad = a.pfad;
    if (pfad == null) return;
    Uint8List? bytes;
    File? klar;
    if (a.groesse <= AppState.vorschauGrenze) {
      // Die Einmal-Ansicht NICHT ueber den Vorschauspeicher — ihre Bytes
      // sollen nach dem Ansehen nirgends bleiben.
      bytes = a.einmal
          ? await st.anhangBytes(cid, a.messageId)
          : await st.anhangVorschau(cid, a);
    }
    if (bytes == null) {
      klar = await st.anhangAlsDatei(cid, a.messageId);
      if (klar == null) return;
    }
    if (a.einmal) await st.geheimnisSichtbar(true);
    try {
      if (!mounted) return;
      await _zeigeBildRoute(
          bytes != null ? MemoryImage(bytes) : FileImage(klar!) as ImageProvider, a);
    } finally {
      if (klar != null) await st.gibAnhangFrei(klar);
      if (a.einmal) {
        await st.geheimnisSichtbar(false);
        await st.verbraucheEinmal(cid, a.messageId, pfad: pfad);
      }
    }
  }

  Future<void> _zeigeBildRoute(ImageProvider bild, AnhangEintrag a) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(child: Image(image: bild,
                    errorBuilder: (_, _, _) => Text(t('imageUnreadable'),
                        style: mono(size: 12, color: Colors.white70)))),
              ),
            ),
            Positioned(
              top: 12, left: 12,
              child: iconBtn('‹', () => Navigator.of(ctx).pop()),
            ),
            if (a.einmal)
              Positioned(
                top: 20, right: 16,
                child: marke(t('onceTag')),
              ),
          ]),
        ),
      ),
    ));
  }

  /// Holt (falls noetig) und oeffnet eine empfangene Einmal-Ansicht.
  Future<void> oeffneEinmal(String cid, Message m) async {
    var a = st.anhangZu(cid, m.id);
    if (a == null) return;
    if (a.zustand != AnhangZustand.da) {
      await st.anhangHolen(cid, m.id);
      a = st.anhangZu(cid, m.id);
      if (a == null || a.zustand != AnhangZustand.da) return;
    }
    if (sprachName.hasMatch(a.name)) {
      // Abspielen und sofort verbrauchen: der Spieler haelt die Datei offen
      // (SprachKanal.kt kehrt erst nach prepare() zurueck), das Loeschen nimmt
      // nur den Namen weg. Das gilt fuer die entschluesselte Kopie genauso
      // wie fuer die verschluesselte Ablage.
      final klar = await st.anhangAlsDatei(cid, m.id);
      if (klar == null) return;
      try {
        await Sprache.spiele(klar.path);
      } finally {
        await st.gibAnhangFrei(klar);
      }
      await st.verbraucheEinmal(cid, m.id, pfad: a.pfad);
      return;
    }
    await zeigeBild(cid, a);
  }

  Future<void> _verwirfAufnahme() async {
    _aufnahmeTakt?.cancel();
    _aufnahmeTakt = null;
    if (mounted) setState(() => _aufnahmeSeit = null);
    // Am Rechner gibt es den Kanal nicht — dann laeuft auch nichts.
    try {
      await Sprache.verwirf();
    } on MissingPluginException {
      // nichts zu verwerfen
    } on PlatformException {
      // die Aufnahme war schon zu Ende
    }
  }

  /// Datei aussuchen und schicken.
  ///
  /// Der Zugang wird IMMER freigegeben, auch wenn das Senden scheitert —
  /// sonst bleibt eine Dateikennung offen, und davon hat ein Prozess nur eine
  /// begrenzte Zahl. Nach ein paar abgebrochenen Versuchen ginge gar nichts
  /// mehr, und niemand wuesste warum.
  Future<void> anhangWaehlen(String cid, {bool einmal = false}) async {
    // IM BROWSER SAGEN, WARUM NICHTS PASSIERT. Die Dateiwahl laeuft ueber den
    // Kanal bitdm/dateien, den es dort nicht gibt; ohne diese Zeile kaeme
    // null zurueck und der Menuepunkt taete einfach nichts. Der ganze
    // Anhang-Weg ist an dart:io-Dateien gebaut (anhang_versand.dart,
    // anhang_empfang.dart) — im Browser ist er nicht nachgebaut.
    if (kIsWeb) {
      st.meldeFehler('anhangWeb');
      return;
    }
    final gewaehlt = await st.imSystemDialog(st.dateien.waehlen);
    if (gewaehlt == null) return;
    // EINMAL-ANSICHT NUR FUER BILDER: die zeigt die App selbst und loescht
    // sie beim Schliessen. Eine beliebige Datei ginge an eine fremde App, und
    // was die damit tut, laesst sich nicht zuruecknehmen.
    if (einmal && !istBildName(gewaehlt.name)) {
      await st.dateien.gibFrei(gewaehlt.zettel);
      _hinweis(t('onceOnlyImages'));
      return;
    }
    _selbstGeschrieben = true;
    try {
      // Doch gesperrt (zu lange im Waehler): nach dem Entsperren senden,
      // statt an der geschlossenen Datenbank zu scheitern.
      if (!await st.wartBisOffen()) return;
      await st.anhangSenden(cid, gewaehlt.datei,
          name: gewaehlt.name, groesse: gewaehlt.groesse, einmal: einmal);
    } finally {
      await st.dateien.gibFrei(gewaehlt.zettel);
    }
  }

  Future<void> oeffneAnhang(AnhangEintrag a) async {
    if (a.pfad == null) return;
    // Ueber eine entschluesselte Kopie — die Ablage selbst ist verschluesselt
    // (AppState.anhangOeffnen sagt, wann die Kopie wieder geht). Null heisst:
    // liess sich nicht entschluesseln, die Meldung steht schon da.
    final ging = await st.anhangOeffnen(a);
    if (ging == false && mounted) {
      // Keine App auf dem Geraet kann diese Art Datei oeffnen. Das ist keine
      // Panne, sondern eine Auskunft — und sie gehoert dorthin, wo der Nutzer
      // gerade hinsieht.
      st.setzeFehler('anhangKeineApp');
    }
  }

  /// Die Dateiendung in einem Kaestchen, hoechstens vier Zeichen.
  ///
  /// KEIN SYMBOLZEICHEN. Die App zeichnet ihre Symbole als Text (‹, +, ✓✓),
  /// und Doto hat nicht jedes Zeichen — ein fehlendes waere ein leeres
  /// Rechteck. Die Endung gibt es immer, sie ist in jeder Schrift vorhanden,
  /// und sie sagt mehr als ein allgemeines Dateisymbol.
  Widget endungsKaestchen(String name) {
    final punkt = name.lastIndexOf('.');
    var endung = punkt > 0 && punkt < name.length - 1
        ? name.substring(punkt + 1).toUpperCase()
        : '···';
    if (endung.length > 4) endung = endung.substring(0, 4);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.line),
      ),
      child: Text(endung,
          maxLines: 1,
          style: mono(
              size: endung.length > 3 ? 7.5 : 9,
              color: p.muted,
              spacing: 0.5)),
    );
  }

  /// Der Knopf unter einer Anhang-Blase. Schmaler als outlineBtn, damit er in
  /// eine Blase passt, ohne sie zu sprengen.
  Widget anhangKnopf(String text, VoidCallback? tun, {bool betont = false}) =>
      Masse.trefferflaeche(
        onTap: tun,
        child: Container(
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: betont ? p.accent : p.line),
          ),
          child: Text(text.toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w600,
                  color: tun == null ? p.dim : p.ink,
                  spacing: 1.1)),
        ),
      );

  /// Der Kopf jeder Anhang-Blase: Kaestchen, Name, Groesse.
  Widget anhangKopf(String name, int groesse, {String? statt}) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          endungsKaestchen(name),
          const SizedBox(width: Masse.nah),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Der Name kommt von der Gegenstelle. Er ist beim Speichern
                // schon gesaeubert worden; hier wird er nur noch gekuerzt,
                // damit ein 200 Zeichen langer Name die Blase nicht sprengt.
                Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mono(size: 12, color: p.ink, height: 1.35)),
                const SizedBox(height: 2),
                Text(statt ?? groesseText(groesse),
                    style: mono(size: 9.5, color: p.dim)),
              ],
            ),
          ),
        ],
      );

  Widget anhangInhalt(String cid, Message m) {
    final a = st.anhangZu(cid, m.id);
    if (a == null) {
      // Die Nachricht sagt "Anhang", der Eintrag fehlt. Sollte es nicht
      // geben — beides wird in derselben Transaktion geschrieben. Falls doch,
      // lieber der Name als eine leere Blase.
      return Align(
          alignment: Alignment.centerLeft,
          child: anhangKopf(m.text, 0, statt: '—'));
    }

    final f = st.fortschritt[m.id];
    final laeuft = a.zustand == AnhangZustand.laedt ||
        (m.isMine && m.status == MessageStatus.sending);

    // EINMAL-ANSICHT: kein Name, keine Vorschau, kein Oeffnen fuer den
    // Absender — nur, was es ist und ob es schon angesehen wurde.
    if (a.einmal) {
      final sprache = sprachName.hasMatch(a.name);
      return Align(
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          marke(t('onceTag')),
          const SizedBox(width: Masse.nah),
          if (laeuft)
            SizedBox(width: 120, child: fortschrittsBalken(f?.anteil ?? 0, mitZahl: false))
          else if (m.isMine)
            Text(a.zustand == AnhangZustand.verbraucht ? t('onceViewed') : t('onceSent'),
                style: mono(size: 10.5, color: p.muted))
          else
            switch (a.zustand) {
              AnhangZustand.verbraucht => Text(t('onceViewed'), style: mono(size: 10.5, color: p.muted)),
              AnhangZustand.weg => Text(t('attachGone'), style: mono(size: 10.5, color: p.muted)),
              _ => anhangKnopf(sprache ? t('oncePlay') : t('onceView'),
                  () => oeffneEinmal(cid, m), betont: true),
            },
        ]),
      );
    }

    // BILDER ZEIGEN, sobald sie da sind — geholt wird trotzdem nur auf
    // Knopfdruck (ein Anhang kann gross sein, siehe holeAnhang).
    final bild = a.zustand == AnhangZustand.da && a.pfad != null && istBildName(a.name);

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bild) ...[
            GestureDetector(
              key: ValueKey('bild-${m.id}'),
              onTap: () => zeigeBild(cid, a),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                // AUS DEM SPEICHER, nicht aus der Datei: die ist verschluesselt.
                // AppState.anhangVorschau gibt je Anhang dieselbe Zukunft
                // zurueck — ein Neuaufbau der Liste entschluesselt nicht neu.
                child: FutureBuilder<Uint8List?>(
                  future: st.anhangVorschau(cid, a),
                  builder: (_, schnappschuss) {
                    final b = schnappschuss.data;
                    if (b == null) return const SizedBox.shrink();
                    return Image.memory(b,
                        width: 220, fit: BoxFit.cover, cacheWidth: 440,
                        errorBuilder: (_, _, _) => const SizedBox.shrink());
                  },
                ),
              ),
            ),
            const SizedBox(height: Masse.nah),
          ],
          anhangKopf(a.name, a.groesse),
          if (laeuft) ...[
            const SizedBox(height: Masse.innen),
            SizedBox(width: 200, child: fortschrittsBalken(f?.anteil ?? 0)),
          ] else ...[
            const SizedBox(height: Masse.nah),
            switch (a.zustand) {
              // Beim eigenen Anhang liegt die Datei ohnehin hier. Ein Knopf
              // "holen" waere Unsinn, ein Knopf "oeffnen" ist es nicht.
              AnhangZustand.da => Row(mainAxisSize: MainAxisSize.min, children: [
                  if (sprachName.hasMatch(a.name))
                    anhangKnopf(t('voicePlay'), () async {
                      // Erst der eigene Spieler, sonst die App des Systems.
                      // Die entschluesselte Kopie geht gleich nach dem Start
                      // wieder — der Spieler haelt sie offen (siehe
                      // [oeffneEinmal]).
                      if (a.pfad == null) return;
                      final klar = await st.anhangAlsDatei(cid, a.messageId);
                      if (klar == null) return; // die Meldung steht schon da
                      var spielt = false;
                      try {
                        spielt = await Sprache.spiele(klar.path);
                      } finally {
                        await st.gibAnhangFrei(klar);
                      }
                      if (!spielt) await oeffneAnhang(a);
                    }, betont: true)
                  else
                  anhangKnopf(t('attachOpen'), () => oeffneAnhang(a)),
                  const SizedBox(width: Masse.nah),
                  Flexible(
                      child: Text(t('attachHere'),
                          style: mono(size: 9.5, color: p.dim))),
                ]),
              AnhangZustand.angekuendigt => anhangKnopf(
                  t('attachGet'), () => st.anhangHolen(cid, m.id),
                  betont: true),
              AnhangZustand.gescheitert => anhangKnopf(
                  t('attachAgain'), () => st.anhangHolen(cid, m.id)),
              // KEIN KNOPF. Nach vierzehn Tagen ist der Block weg, und wer
              // ihn geholt hat, hat ihn selbst weggeworfen. "Nochmal
              // versuchen" waere hier eine Luege — deshalb steht stattdessen
              // da, warum.
              AnhangZustand.weg => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t('attachGone'),
                        style: mono(size: 10.5, color: p.muted)),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: 200,
                      child: Text(t('attachGoneWhy'),
                          style: mono(size: 9.5, color: p.dim, height: 1.45)),
                    ),
                  ],
                ),
              AnhangZustand.laedt => const SizedBox.shrink(),
              AnhangZustand.verbraucht => Text(t('onceViewed'),
                  style: mono(size: 10.5, color: p.muted)),
            },
          ],
        ],
      ),
    );
  }

  /// Die Blase, die es noch nicht gibt.
  ///
  /// Ein Versand entsteht erst als Nachricht, wenn ALLES oben ist — bei drei
  /// Gigabyte also nach Minuten. Bis dahin stuende die Unterhaltung
  /// unveraendert da, und niemand wuesste, ob etwas passiert.
  Widget schwebenderAnhang() {
    final f = st.fortschritt[st.schwebendeKennung];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 252),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: p.tint,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(2)),
              border: Border.all(color: p.tintLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                anhangKopf(st.schwebenderName ?? '…',
                    f?.gesamtBytes ?? 0,
                    statt: f == null ? t('attachSend') : null),
                const SizedBox(height: Masse.innen),
                SizedBox(width: 200, child: fortschrittsBalken(f?.anteil ?? 0)),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
