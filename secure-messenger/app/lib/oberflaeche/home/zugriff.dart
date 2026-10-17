// zugriff.dart — Faktoren einrichten und entfernen, Sperrfrist, Zugriffsbildschirm.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
// SICHERHEITSRELEVANT: wer die Sperre prueft, liest home.dart, sperre.dart
// und zugriff.dart und sucht in den uebrigen Teilen nach frischBestaetigt.
part of '../home.dart';

/// Die Zeilen im Zugriffs-Bildschirm, in dieser Reihenfolge.
///
/// ALLE VIER SIND ECHT. Vorher standen hier zwei weitere, die nichts
/// einrichteten und nur erklaerten, warum es sie nicht gibt — Passkey und
/// Zwei-Faktor-Code. Sie sind raus: eine Liste, in der die Haelfte der
/// Eintraege nichts tut, laesst den Nutzer bei jedem der anderen zweifeln,
/// ob der wohl auch nur so tut.
const List<String> zugriffsZeilen = ['bio', 'devpin', 'hw', 'pw'];

/// Welche Faktorart hinter welcher Zeile steckt.
///
/// DIESE ZUORDNUNG WAR DER FEHLER, DER AM 25.07.2026 GEMELDET WURDE: vorher
/// wurde alles ausser 'hw' auf die Biometrie abgebildet. Ein Druck auf
/// "Passkey" fand damit das Fingerabdruck-Fach und ENTFERNTE es — mit einer
/// Zeile, die davon nichts sagte.
///
/// Steht auf oberster Ebene, damit ein Test sie sehen kann. Eine Zuordnung,
/// bei der zwei Zeilen auf dieselbe Art zeigen, ist genau der Fehler von
/// damals — und ohne Test faellt er erst am Geraet auf.
const Map<String, UnlockFactorKind> zeilenArt = {
  'bio': UnlockFactorKind.biometric,
  'devpin': UnlockFactorKind.deviceCredential,
  'hw': UnlockFactorKind.hardwareKey,
  'pw': UnlockFactorKind.passphrase,
};

// EHEMALS STATISCHE MITGLIEDER VON _HomeState (Aufteilung, Schritt 5).
//
// Eine `extension on _HomeState` erreicht statische Mitglieder der Klasse
// nicht ohne Klassennamen. Als Top-Level-Deklarationen dieser Bibliothek
// sind sie fuer die Klasse und jeden Teil (home/*.dart) unter demselben
// Namen sichtbar; jede zieht mit ihrem Modul um.

/// Laeuft die App dort, wo die Kotlin-Kanaele ueberhaupt existieren?
///
/// Drei Dinge in dieser App stecken vollstaendig in Kotlin und haben auf
/// keiner anderen Plattform eine Gegenseite:
///
///   * `bitdm/schluesselfach` — Biometrie und Geraetesperre
///   * `bitdm/usb_hid` und NFC — der Sicherheitsschluessel
///   * `bitdm/nahfunk` — der ganze Nahbereich
///
/// Dazu UnifiedPush, ein Android-Plugin. Ein Aufruf ohne Gegenseite endet in
/// einer MissingPluginException — sichtbar als Bedienelement, das auf Tippen
/// mit einem Fehler antwortet statt mit einer Wirkung.
///
/// `kIsWeb` MUSS mitgeprueft werden: im Browser auf einem Android-Telefon
/// meldet `defaultTargetPlatform` android, Kanaele gibt es dort aber keine.
///
/// Im Widget-Test meldet Flutter android, dort bleibt also alles sichtbar
/// und keiner der vorhandenen Tests aendert sein Verhalten.
bool get _nurAufAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

extension _Zugriff on _HomeState {
  /// Richtet einen Faktor ein oder entfernt ihn.
  ///
  /// Bis zum 25.07.2026 stand hier eine Attrappe: eine Einrichtungs-Animation,
  /// danach ein Haken, dahinter nichts. Jetzt liegt darunter ein
  /// Schluesselfach — die Entropie ist ohne den Faktor wirklich nicht mehr zu
  /// haben, auch nicht mit Root, auch nicht mit der Datei in der Hand.
  Future<void> methodAct(String key) async {
    final art = zeilenArt[key];
    if (art == null || laeuftZeile != null) return;

    final vorhanden = st.sichtbareFaktoren.where((s) => s.kind == art).toList();
    if (vorhanden.isNotEmpty) {
      // Einen Faktor herausnehmen schwaecht die Sperre — also erst ausweisen.
      if (!await frischBestaetigt()) return;
      await _entferneFaktor(key, vorhanden.first.id);
      return;
    }

    switch (art) {
      case UnlockFactorKind.hardwareKey:
        await _richteStickEin();
      case UnlockFactorKind.passphrase:
        await _richtePasswortEin();
      case UnlockFactorKind.biometric:
        await _richteKeystoreEin(key, art, st.fuegeBiometrieHinzu);
      case UnlockFactorKind.deviceCredential:
        await _richteKeystoreEin(key, art, st.fuegeGeraetePinHinzu);
    }
  }

  /// Richtet ein Fach im gesicherten Bereich des Geraets ein.
  ///
  /// BIS ZUM 25.07.2026 PASSIERTE HIER BEIM ANTIPPEN SICHTBAR NICHTS. Zwei
  /// Gruende kamen zusammen: der Anmeldedialog erschien nicht (dazu
  /// SchluesselfachKanal.kt), und wenn doch ein Fehler kam, landete er in
  /// einer Variablen, die dieser Bildschirm gar nicht anzeigte.
  ///
  /// Deshalb jetzt drei Dinge: vorher fragen, ob es ueberhaupt gehen KANN;
  /// waehrenddessen zeigen, dass etwas laeuft; und jeden Fehler sichtbar
  /// machen.
  Future<void> _richteKeystoreEin(
      String zeile, UnlockFactorKind art, Future<void> Function() anlegen) async {
    setState(() {
      lockFehler = null;
      laeuftZeile = zeile;
    });
    try {
      // Erst fragen, dann tippen lassen. Ohne diese Frage wartet der Nutzer
      // auf einen Dialog, den das Geraet gar nicht zeigen kann.
      final stand = await st.geraetestand(art);
      if (!stand.ok) {
        if (mounted) {
          setState(() => lockFehler = stand.grund ?? t('lockNoScreenLockBody'));
        }
        return;
      }
      await anlegen();
    } on AnmeldungFehlgeschlagen catch (e) {
      // Ein Abbruch ist keine Panne, sondern eine Entscheidung — dafuer keine
      // rote Meldung.
      if (mounted && !e.abgebrochen) setState(() => lockFehler = e.grund);
    } on GeraetKannNicht catch (e) {
      if (mounted) setState(() => lockFehler = e.grund);
    } on LockUnavailableException catch (e) {
      if (mounted) setState(() => lockFehler = e.grund);
    } on UnlockFailedException {
      if (mounted) setState(() => lockFehler = t('unlockFailed'));
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    } finally {
      if (mounted) setState(() => laeuftZeile = null);
    }
  }

  /// Stellt um, wann die App sich von selbst wieder abschliesst.
  Future<void> _setzeSperrfrist(int sekunden) async {
    if (sekunden == st.sperrfristAlsZahl) return;
    // Eine laengere Frist ist eine schwaechere Sperre — erst ausweisen.
    if (!await frischBestaetigt()) return;
    try {
      await st.setzeSperrfrist(sekunden);
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Nimmt einen Faktor wieder heraus.
  ///
  /// Verlangt einen offenen Tresor. Sonst waere die Sperre einen Fingertipp
  /// weit — jemand mit dem entsperrten Telefon koennte sie einfach abschalten.
  Future<void> _entferneFaktor(String zeile, String slotId) async {
    setState(() {
      lockFehler = null;
      laeuftZeile = zeile;
    });
    try {
      await st.entferneFaktor(slotId);
    } on StateError catch (e) {
      // Das letzte Fach: dahinter steckt kein Fehler, sondern die Regel, dass
      // immer ein Weg hinein bleiben muss.
      if (mounted) setState(() => lockFehler = e.message);
    } on AnmeldungFehlgeschlagen catch (e) {
      if (mounted && !e.abgebrochen) setState(() => lockFehler = e.grund);
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    } finally {
      if (mounted) setState(() => laeuftZeile = null);
    }
  }

  /// Oeffnet das Blatt, auf dem ein App-Passwort eingerichtet wird.
  Future<void> _richtePasswortEin() async {
    pwCtl.clear();
    pwCtl2.clear();
    setState(() {
      enroll = 'pw';
      lockFehler = null;
    });
  }

  /// Legt das Passwort-Fach an.
  Future<void> _passwortAnlegen() async {
    final pw = pwCtl.text;
    if (pw != pwCtl2.text) {
      setState(() => lockFehler = t('pwMismatch'));
      return;
    }
    setState(() => lockFehler = null);
    try {
      await st.fuegePasswortHinzu(pw);
      pwCtl.clear();
      pwCtl2.clear();
      if (mounted) setState(() => enroll = null);
    } on WeakPassphraseException catch (e) {
      // Die Zahl mitzugeben ist der Unterschied zwischen "zu schwach" und
      // "zu schwach, und zwar um so viel".
      if (mounted) {
        setState(() => lockFehler = t('pwWeak')
            .replaceFirst('{ist}', '${e.geschaetzteBits}')
            .replaceFirst('{soll}', '${e.verlangteBits}'));
      }
    } catch (e) {
      if (mounted) setState(() => lockFehler = '$e');
    }
  }

  /// Oeffnet das Blatt, auf dem der Stick eingerichtet wird.
  Future<void> _richteStickEin() async {
    stickPinCtl.clear();
    setState(() {
      enroll = 'hw';
      lockFehler = null;
      stickSchritt = null;
    });
  }

  /// Legt den Zugang auf dem Stick an und verschliesst die Identitaet damit.
  Future<void> _stickAnlegen() async {
    setState(() {
      stickSchritt = t('stickWorking');
      lockFehler = null;
    });
    try {
      await st.fuegeStickHinzu(
        weg: stickWeg,
        pin: stickPinCtl.text.isEmpty ? null : stickPinCtl.text,
      );
      stickPinCtl.clear();
      if (mounted) setState(() { enroll = null; stickSchritt = null; });
    } catch (e) {
      if (mounted) {
        setState(() { lockFehler = _stickMeldung(e); stickSchritt = null; });
      }
    }
  }

  // ---- SECURE ----
  /// Oeffnet den Faehigkeitstest fuer einen Sicherheitsschluessel.
  Future<void> _pruefeStick() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => FidoProbeScreen(
        titel: t('fidoProbe'),
        anhalten: t('fidoHold'),
        keinNfc: t('fidoNoNfc'),
        schliessen: t('close'),
      ),
    ));
  }

  Widget secureScreen() {
    // DER SPACER WAR DER AUFFAELLIGSTE EINZELNE GRUND, warum die Abfolgen im
    // Fenster nicht wie eine Desktop-App aussahen: auf dem Desktop bleibt von
    // den vier Zugriffszeilen nur eine uebrig (siehe `_faktorGehtHier` — nur
    // 'pw' hat dort eine Gegenseite), der Bildschirm hat also etwa 260 px
    // Inhalt, und in einem 1040 px hohen Fenster klebten darunter nach ueber
    // 600 px Leere zwei Knoepfe am Boden (30.07.2026).
    //
    // 24 px ist der Abstand zwischen zwei Gruppen (Masse.gruppe ist 22, hier
    // eine Stufe mehr, weil darunter die Handlung folgt).
    //
    // ZWEI KNOEPFE NEBENEINANDER, ABER NICHT MEHR GEDEHNT: die beiden Expanded
    // machten aus ihnen zwei 254 px breite Halbbanner. Im Fenster nehmen sie
    // ihre Textbreite und stehen links, wie alles andere auf diesem Bildschirm.
    final Widget knoepfe = _imFenster
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            outlineBtn(t('secureSkip'), () => go('id'),
                accent: false,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                weight: FontWeight.w400),
            const SizedBox(width: 8),
            outlineBtn(t('secureDone'), () => go('id'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 13)),
          ])
        : Row(children: [
            Expanded(child: outlineBtn(t('secureSkip'), () => go('id'), accent: false, padding: const EdgeInsets.all(13), weight: FontWeight.w400)),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('secureDone'), () => go('id'), padding: const EdgeInsets.all(13))),
          ]);

    final Widget inhalt = Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('secureTitle')),
        const SizedBox(height: 6),
        Text(t('secureSub'), style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        ...zugriffsBlock(statusMode: true),
        const SizedBox(height: 4),
        Text(t('secureFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
        if (_imFenster) const SizedBox(height: 24) else const Spacer(),
        _imFenster
            ? Align(alignment: Alignment.centerLeft, child: knoepfe)
            : knoepfe,
      ]),
    );

    // Scrollbar im Fenster, sobald der Spacer weg ist — sonst ueberlaeuft der
    // Bildschirm, wenn jemand das Fenster niedriger zieht als seinen Inhalt.
    // Spacer und Scrollview gehen nicht zusammen, deshalb geht beides nur
    // gemeinsam.
    return _imFenster ? SingleChildScrollView(child: inhalt) : inhalt;
  }

  Widget methodRow(String key, {bool statusMode = true}) {
    final art = zeilenArt[key];
    final on = art != null && st.hatFaktor(art);
    final laeuft = laeuftZeile == key;
    // Ein anderer Faktor arbeitet gerade. Zwei Anmeldedialoge gleichzeitig
    // gehen nicht, und der zweite bliebe stumm haengen.
    final blockiert = laeuftZeile != null && !laeuft;

    final mark = laeuft ? '·' : (on ? '✓' : '·');
    final right = laeuft
        ? t('waiting')
        : statusMode
            ? (on ? t('on2') : t('offMethod'))
            : (on ? t('remove') : t('add'));

    // ALS KNOPF ANSAGEN, UND OB ER GERADE GEHT.
    //
    // Die ganze Zeile ist das Bedienelement; ein eigenes "SET UP" gibt es
    // nicht. Vorgelesen wurde deshalb nur eine Aneinanderreihung von Texten —
    // "Geraetesperre, Die PIN dieses Telefons, Einrichten" —, ohne dass
    // erkennbar war, dass man sie antippen kann.
    //
    // `enabled` traegt die zweite Haelfte: waehrend ein anderer Faktor
    // arbeitet, ist die Zeile gesperrt. Sichtbar ist das an der Transparenz.
    // Wer sie nicht sieht, tippte bisher ins Leere und bekam keine Auskunft,
    // warum nichts geschieht.
    //
    // Aufgefallen am 29.07.2026: beim Durchgehen der Ablaeufe traf mein
    // eigener Tipp die Zeile nicht, weil sie kein eigener Knoten war.
    // AM ZEIGER WAR VON ALLEM NICHTS ZU SEHEN. Auf 'secure' ist diese Zeile im
    // Fenster die EINZIGE (nur 'pw' ueberlebt `_faktorGehtHier`), also der
    // einzige Weg zu einem App-Passwort — und sie sah aus wie eine
    // Statuszeile. `blockiert` behaelt den Standardzeiger: eine Hand ueber
    // etwas, das gerade nicht geht, verspricht etwas, was nicht kommt.
    return Semantics(
      button: true,
      enabled: !blockiert,
      container: true,
      child: Opacity(
      opacity: blockiert ? 0.4 : 1,
      child: _Bedienbar(
        imFenster: _imFenster,
        onTap: blockiert ? null : () => methodAct(key),
        bau: (ueber, fokus) => GestureDetector(
        onTap: blockiert ? null : () => methodAct(key),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              color: ueber || fokus ? p.surf : p.surf2,
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Container(
              width: 26, height: 26, alignment: Alignment.center,
              decoration: BoxDecoration(color: on ? p.tint : p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: on || laeuft ? p.accent : p.line)),
              child: laeuft
                  // Sichtbar, dass etwas laeuft. Fehlte das, sah ein Antippen
                  // waehrend der Anmeldung aus wie ein Antippen ins Leere.
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.6, color: p.accLight))
                  : Text(mark, style: doto(size: 12, weight: FontWeight.w600, color: on ? p.accLight : p.dim)),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t(key), style: TextStyle(fontSize: 13.5, color: p.ink)),
                Text(t('${key}Sub'), style: mono(size: 11, color: p.dim, height: 1.35)),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: on ? p.tint : Colors.transparent, borderRadius: BorderRadius.circular(4), border: Border.all(color: on ? p.tintLine : p.line)),
              child: Text(right.toUpperCase(), style: mono(size: 10, weight: FontWeight.w500, color: on ? p.tintInk : p.dim, spacing: 1.2)),
            ),
          ]),
        ),
      ),
      ),
    ),
    );
  }

  /// Kann dieser Faktor auf DIESEM Geraet ueberhaupt etwas einrichten?
  ///
  /// Drei der vier haengen an Android: Biometrie und Geraetesperre am
  /// Schluesselfach (`bitdm/schluesselfach`), der Sicherheitsschluessel an
  /// USB-HID und NFC. Auf Windows gibt es diese Kanaele nicht — ein Druck
  /// darauf endet in einer MissingPluginException. Nur das App-Passwort ist
  /// reines Dart und laeuft ueberall.
  ///
  /// DAS IST DERSELBE FEHLER, DER SCHON UEBER `zugriffsZeilen` STEHT: eine
  /// Liste, in der die Haelfte der Eintraege nichts tut, laesst den Nutzer bei
  /// jedem der anderen zweifeln. Am 30.07.2026 bot der erste Windows-Bau vier
  /// Faktoren an, von denen drei nicht funktionieren konnten — und einer sagte
  /// "the PIN, pattern or password of this phone" auf einem PC.
  ///
  /// Im Test meldet Flutter Android, dort bleiben also alle vier sichtbar.
  bool _faktorGehtHier(String k) => k == 'pw' || _nurAufAndroid;

  /// Die Blaetter, die ueber dem Zugriffs-Bildschirm liegen.
  Widget enrollModal() {
    final en = enroll!;
    if (en == 'keineSperre') {
      return scrim(
        onTapOutside: () => setState(() => enroll = null),
        sheetCard(children: [
          const SizedBox(height: 8),
          h2(t('lockNoScreenLock'), size: 18),
          const SizedBox(height: 11),
          Text(t('lockNoScreenLockBody'), style: mono(size: 12.5, color: p.muted, height: 1.6)),
          const SizedBox(height: 14),
          outlineBtn(t('close'), () => setState(() => enroll = null), padding: const EdgeInsets.all(11)),
        ]),
      );
    }
    if (en == 'hw') return stickModal();
    if (en == 'pw') return passwortModal();
    if (en == 'pushHilfe') return pushHilfeModal();

    // Alles andere ist ein Fehler im Programm, kein Zustand des Nutzers.
    // Frueher standen hier Passkey und Zwei-Faktor-Code; die Zeilen sind weg.
    return const SizedBox.shrink();
  }

  /// Das App-Passwort wird eingerichtet.
  ///
  /// Dieses Fach haengt an NICHTS ausser dem Passwort — kein gesicherter
  /// Bereich, kein Stick. Wer die Fachdatei kopiert, probiert auf eigener
  /// Hardware, so lange er will. Deshalb steht die Anforderung hier deutlich
  /// da und wird nicht erst beim Absenden nachgereicht.
  Widget passwortModal() {
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
        h2(t('enrollPw'), size: 20),
        const SizedBox(height: 10),
        Text(t('pwIntro'), style: mono(size: 12.5, color: p.muted, height: 1.6)),
        const SizedBox(height: 14),
        _geheimFeld(pwCtl, t('pwHint'), autofokus: true),
        const SizedBox(height: 8),
        _geheimFeld(pwCtl2, t('pwAgain')),
        const SizedBox(height: 12),
        if (lockFehler != null) ...[
          _hinweisKasten(lockFehler!),
          const SizedBox(height: 12),
        ],
        Row(children: [
          Expanded(
              child: outlineBtn(t('cancel'), () => setState(() => enroll = null),
                  accent: false,
                  padding: const EdgeInsets.all(11),
                  weight: FontWeight.w400)),
          const SizedBox(width: 8),
          Expanded(
              child: outlineBtn(t('add'), _passwortAnlegen,
                  padding: const EdgeInsets.all(11))),
        ]),
        const SizedBox(height: 10),
        Text(t('pwLostNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  /// Der Stick wird eingerichtet.
  ///
  /// Zwei Dinge stehen hier bewusst DRAUF und nicht im Kleingedruckten:
  /// dass es ZWEI Beruehrungen braucht (sonst haelt man die zweite
  /// Aufforderung fuer einen Fehler), und was passiert, wenn der Stick
  /// verloren geht.
  Widget stickModal() {
    final laeuft = stickSchritt != null;
    return scrim(
      onTapOutside: laeuft ? () {} : () => setState(() => enroll = null),
      sheetCard(children: [
        Center(
            child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                    color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('enrollHw'), size: 20),
        const SizedBox(height: 10),
        Text(t('stickIntro'), style: mono(size: 12.5, color: p.muted, height: 1.6)),
        const SizedBox(height: 14),

        // Der Weg zum Stick.
        Row(children: [
          Expanded(child: _wegKnopf(StickWeg.usb, t('stickUsb'))),
          const SizedBox(width: 8),
          Expanded(child: _wegKnopf(StickWeg.nfc, t('stickNfc'))),
        ]),
        const SizedBox(height: 14),

        Text(t('stickPinLabel').toUpperCase(),
            style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1.4)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
              color: p.surf2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.line)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: stickPinCtl,
            enabled: !laeuft,
            obscureText: true,
            keyboardType: TextInputType.number,
            style: mono(size: 14, color: p.ink, spacing: 2),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: '••••••',
              hintStyle: mono(size: 14, color: p.dim, spacing: 2),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(t('stickPinHint'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 14),

        if (lockFehler != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: p.tint,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.tintLine)),
            child: Text(lockFehler!,
                style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
          ),
          const SizedBox(height: 12),
        ],

        if (laeuft) ...[
          Text(stickSchritt!,
              style: mono(size: 12.5, color: p.accLight, height: 1.5)),
          const SizedBox(height: 12),
        ],

        Row(children: [
          Expanded(
              child: outlineBtn(t('cancel'),
                  laeuft ? () {} : () => setState(() => enroll = null),
                  accent: false,
                  padding: const EdgeInsets.all(11),
                  weight: FontWeight.w400)),
          const SizedBox(width: 8),
          Expanded(
              child: outlineBtn(laeuft ? t('waiting') : t('add'),
                  laeuft ? () {} : _stickAnlegen,
                  padding: const EdgeInsets.all(11))),
        ]),
        const SizedBox(height: 10),
        Text(t('stickLostNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 10),
        // Ob ein Stick hmac-secret ueberhaupt kann, steht in keiner
        // Produktbeschreibung — die Erweiterung ist optional, und Hersteller
        // werben nicht damit. Deshalb der Weg, ihn vorher selbst zu fragen.
        GestureDetector(
          onTap: laeuft ? null : _pruefeStick,
          child: Text(t('fidoProbe').toUpperCase(),
              style: mono(
                  size: 10,
                  weight: FontWeight.w600,
                  color: p.accLight,
                  spacing: 1.3)),
        ),
      ]),
    );
  }

  /// Die Zeilen samt Fehlerkasten.
  ///
  /// DER KASTEN IST DER PUNKT: bis zum 25.07.2026 wurden Fehler beim
  /// Einrichten zwar gesetzt, aber auf diesem Bildschirm nie angezeigt. Wer
  /// tippte, sah nichts — weder Dialog noch Grund.
  List<Widget> zugriffsBlock({required bool statusMode}) => [
        for (final k in zugriffsZeilen.where(_faktorGehtHier)) ...[
          methodRow(k, statusMode: statusMode),
          const SizedBox(height: 3),
        ],
        if (lockFehler != null) ...[
          const SizedBox(height: 6),
          _hinweisKasten(lockFehler!),
        ],
      ];
}
