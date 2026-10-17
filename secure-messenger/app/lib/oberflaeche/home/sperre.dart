// sperre.dart — Sperrbildschirm, Entsperren, frische Anmeldung, Geheimnisabfrage, Stick-PIN; dazu der Bildschirm bei verschlossenem Schluesselspeicher.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
// SICHERHEITSRELEVANT: wer die Sperre prueft, liest home.dart, sperre.dart
// und zugriff.dart und sucht in den uebrigen Teilen nach frischBestaetigt.
part of '../home.dart';

extension _Sperre on _HomeState {
  /// Uebersetzt einen Fehler in etwas, mit dem der Nutzer etwas anfangen kann.
  ///
  /// BEIM STICK IST DAS WICHTIGER ALS SONST: er zaehlt Fehlversuche selbst mit
  /// und sperrt sich nach acht endgueltig. Eine Meldung im Stil von "Fehler
  /// 0x31" laesst den Nutzer weiterraten, bis der Stick unbrauchbar ist.
  String _stickMeldung(Object e) => switch (e) {
        PinFalschException(:final verbleibend) => verbleibend == null
            ? t('stickPinWrong')
            : t('stickPinWrongLeft').replaceFirst('{n}', '$verbleibend'),
        StickPinNoetigException() => t('stickPinNeeded'),
        StickUngeeignetException(:final grund) => grund,
        KeinStickException(:final grund) => grund,
        CtapException(:final bedeutung) => bedeutung,
        _ => '$e',
      };

  /// Der Schluesselspeicher des Systems war beim Start nicht zu lesen
  /// (AppState.schluesselspeicherZu) — unter Linux ein gesperrter oder gar
  /// nicht laufender Schluesselbund.
  ///
  /// NUR "Erneut versuchen", kein Anlegen und kein Wiederherstellen: ob es
  /// eine Identitaet gibt, ist gerade unbekannt. Das Onboarding saehe aus, als
  /// waere sie weg.
  Widget schluesselspeicherScreen() {
    final aufLinux = !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
    final laeuft = st.startetGerade;
    return SingleChildScrollView(
      key: const ValueKey('schluesselspeicher-zu'),
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          h2(t('keyStoreTitle')),
          const SizedBox(height: 8),
          Text(t(aufLinux ? 'keyStoreLinux' : 'keyStoreOther'),
              style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
          const SizedBox(height: 22),
          _hinweisKasten(t('keyStoreSafe'), warnend: false),
          const SizedBox(height: 14),
          outlineBtn(
              t(laeuft ? 'keyStoreTrying' : 'keyStoreRetry'),
              laeuft
                  ? null
                  : () {
                      _starte();
                      // boot() traegt sich sofort als laufend ein; neu
                      // zeichnen, damit der Knopf das zeigt.
                      setState(() {});
                    },
              padding: const EdgeInsets.all(13),
              weight: FontWeight.w500),
        ],
      ),
    );
  }

  /// Wartet darauf, dass ein Faktor das Fach oeffnet.
  ///
  /// Angeboten wird nur, was auch eingerichtet ist. Ein Knopf fuer einen
  /// Faktor, den es nicht gibt, waere hier besonders bitter: der Nutzer haelt
  /// einen Stick an das Telefon und wartet auf etwas, das nie kommt.
  ///
  /// Fingerabdruck und PIN fragt die App NICHT selbst ab und bekommt sie nie
  /// zu sehen — sie versucht nur, den Fachschluessel zu lesen, und die Abfrage
  /// zeigt das System.
  Widget gesperrtScreen() {
    final bio = st.hatFaktor(UnlockFactorKind.biometric);
    final pin = st.hatFaktor(UnlockFactorKind.deviceCredential);
    final stick = st.hatFaktor(UnlockFactorKind.hardwareKey);
    // Auch dann, wenn es nur das PANIK-WORT gibt (Fingerabdruck plus
    // Panik-Wort): dort wird es eingetippt. Welches der beiden hinter dem
    // Feld steht, sieht man dem Bildschirm nicht an (AppState
    // sperreBietetPasswort).
    final pw = st.sperreBietetPasswort;

    // Der erste Knopf traegt die Betonung. Welcher das ist, haengt davon ab,
    // was eingerichtet ist — ein blasser einziger Knopf saehe aus, als waere
    // er nicht gemeint.
    var ersterHervorgehoben = true;
    Widget knopf(String text, VoidCallback tun) {
      final hervor = ersterHervorgehoben;
      ersterHervorgehoben = false;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: outlineBtn(text, tun,
            accent: hervor,
            padding: const EdgeInsets.all(13),
            weight: hervor ? FontWeight.w500 : FontWeight.w400),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          h2(t("locked")),
          const SizedBox(height: 8),
          Text(t("lockedSub"),
              style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
          const SizedBox(height: 22),

          if (lockFehler != null) ...[
            _hinweisKasten(lockFehler!),
            const SizedBox(height: 14),
          ],

          if (bio) knopf(t('unlockBio'), _entsperreMitBiometrie),
          if (pin) knopf(t('unlockDevPin'), _entsperreMitGeraetePin),
          if (pw) knopf(t('unlockPw'), _fragePasswort),
          if (stick) ...[
            knopf(t('unlockStick'), _entsperreMitStick),
            Row(children: [
              Expanded(child: _wegKnopf(StickWeg.usb, t('stickUsb'))),
              const SizedBox(width: 8),
              Expanded(child: _wegKnopf(StickWeg.nfc, t('stickNfc'))),
            ]),
          ],
          if (!bio && !pin && !stick && !pw)
            // Kann nur passieren, wenn die Fachdatei kaputt ist. Ohne diesen
            // Hinweis stuende der Nutzer vor einem Bildschirm ohne Knopf.
            Text(t('lockedNoFactor'),
                style: mono(size: 12, color: p.dim, height: 1.6)),
        ],
      ),
    );
  }

  Future<void> _entsperreMitBiometrie() =>
      _versucheEntsperren(st.entsperreMitBiometrie);

  Future<void> _entsperreMitGeraetePin() =>
      _versucheEntsperren(st.entsperreMitGeraetePin);

  /// Fragt das App-Passwort ab und versucht damit zu oeffnen.
  Future<void> _fragePasswort() async {
    pwCtl.clear();
    final ok = await _frageGeheimnis(
        titel: t('unlockPw'), ctl: pwCtl, hinweis: t('pwUnlockHint'));
    if (ok != true || !mounted) return;
    final eingabe = pwCtl.text;
    pwCtl.clear();
    await _versucheEntsperren(() => st.entsperreMitPasswort(eingabe));
  }

  Future<void> _versucheEntsperren(Future<bool> Function() tun) async {
    setState(() => lockFehler = null);
    try {
      final ok = await tun();
      if (!ok && mounted) setState(() => lockFehler = t('unlockFailed'));
    } on UnlockFailedException {
      // ABSICHTLICH OHNE GRUND: falsches Passwort, abgebrochene Anmeldung und
      // beschaedigtes Fach sollen von aussen gleich aussehen. Ein Fehler, der
      // sie unterscheidet, ist ein Hinweis fuer jeden, der Passwoerter
      // durchprobiert. Beim Stick ist es umgekehrt — siehe _stickMeldung.
      if (mounted) setState(() => lockFehler = t('unlockFailed'));
    } catch (e) {
      if (mounted) setState(() => lockFehler = _stickMeldung(e));
    }
  }

  /// Verlangt eine FRISCHE Anmeldung, bevor etwas Folgenreiches passiert: die
  /// Sperre aendern, die Fernloeschung aufhalten oder umstellen, die zwoelf
  /// Woerter oder ihre Teile zeigen.
  ///
  /// EIN OFFENER BILDSCHIRM IST KEIN AUSWEIS. Wer das entsperrte Telefon
  /// einen Moment in der Hand hat, soll damit weder die Sperre abschalten
  /// noch die Woerter abfotografieren koennen.
  ///
  /// Ohne eingerichteten Faktor gibt es nichts, womit man sich ausweisen
  /// koennte; dann fragt die App nur nach, wenn [frage] gesetzt ist.
  /// Rueckgabe: ob weitergemacht werden darf.
  Future<bool> frischBestaetigt({String? frage}) async {
    if (!st.brauchtFrischeAnmeldung) {
      if (frage == null) return true;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('nachfrage'),
          title: Text(t('confirmTitle')),
          content: Text(frage, style: mono(size: 12, color: p.muted, height: 1.5)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('confirmYes'))),
          ],
        ),
      );
      return ok == true;
    }
    // Nur, was hier auch geht — am Rechner bleibt vom Faktor-Satz nur das
    // Passwort (siehe [_faktorGehtHier]).
    final arten = [
      for (final k in zugriffsZeilen.where(_faktorGehtHier))
        if (st.hatFaktor(zeilenArt[k]!)) k,
    ];
    if (arten.isEmpty) {
      _hinweis(t('freshAuthNone'));
      return false;
    }
    var wahl = arten.first;
    if (arten.length > 1) {
      final gewaehlt = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(t('freshAuthTitle')),
          children: [
            for (final k in arten)
              SimpleDialogOption(
                key: ValueKey('frisch-$k'),
                onPressed: () => Navigator.pop(ctx, k),
                child: Text(t(k), style: mono(size: 13, color: p.ink)),
              ),
          ],
        ),
      );
      if (gewaehlt == null || !mounted) return false;
      wahl = gewaehlt;
    }
    try {
      final bool? ok;
      switch (zeilenArt[wahl]!) {
        case UnlockFactorKind.biometric:
          ok = await st.bestaetigeMitBiometrie();
        case UnlockFactorKind.deviceCredential:
          ok = await st.bestaetigeMitGeraetePin();
        case UnlockFactorKind.passphrase:
          pwCtl.clear();
          final eingegeben = await _frageGeheimnis(
              titel: t('freshAuthTitle'), ctl: pwCtl, hinweis: t('freshAuthPw'));
          final pw = pwCtl.text;
          pwCtl.clear();
          if (eingegeben != true || !mounted) return false;
          ok = await st.bestaetigeMitPasswort(pw);
        case UnlockFactorKind.hardwareKey:
          ok = await _mitStickPin(
              (pin) => st.bestaetigeMitStick(weg: stickWeg, pin: pin));
          if (ok == null) return false;
      }
      if (ok != true) _hinweis(t('unlockFailed'));
      return ok == true;
    } on AnmeldungFehlgeschlagen catch (e) {
      if (!e.abgebrochen) _hinweis(e.grund);
      return false;
    } on UnlockFailedException {
      _hinweis(t('unlockFailed'));
      return false;
    } catch (e) {
      _hinweis(_stickMeldung(e));
      return false;
    } finally {
      stickPinCtl.clear();
    }
  }

  /// Entsperrt mit dem Stick, und fragt nach der PIN, wenn er eine verlangt.
  Future<void> _entsperreMitStick() async {
    setState(() => lockFehler = null);
    try {
      final ok = await _mitStickPin(
          (pin) => st.entsperreMitStick(weg: stickWeg, pin: pin));
      if (ok == false && mounted) setState(() => lockFehler = t('unlockFailed'));
    } catch (e) {
      if (mounted) setState(() => lockFehler = _stickMeldung(e));
    } finally {
      stickPinCtl.clear();
    }
  }

  /// Bedient den Stick und fragt die PIN nach, wenn er sie verlangt — oder
  /// wenn sie falsch war. Rueckgabe: was [tun] meldet, oder null, wenn der
  /// Nutzer die PIN-Abfrage abbricht.
  ///
  /// NIE STILL EIN ZWEITES MAL. Vorher blieb eine falsche PIN im Feld stehen,
  /// und das naechste Antippen von "Mit Schluessel oeffnen" schickte sie
  /// ungefragt wieder — jeder Druck kostete einen der acht Versuche, nach
  /// denen sich der Stick endgueltig sperrt. Jetzt wird nach jedem
  /// Fehlversuch neu gefragt, mit der Zahl der verbleibenden Versuche.
  Future<bool?> _mitStickPin(Future<bool> Function(String? pin) tun) async {
    String? pin;
    while (true) {
      String? meldung;
      try {
        return await tun(pin);
      } on StickPinNoetigException {
        meldung = null;
      } on PinFalschException catch (e) {
        // Bei null Versuchen ist der Stick zu — fragen hilft dann nicht mehr.
        if (e.verbleibend == 0) rethrow;
        meldung = _stickMeldung(e);
      } finally {
        pin = null;
        stickPinCtl.clear();
      }
      if (!mounted) return null;
      final ok = await _frageGeheimnis(
          titel: t('stickPinLabel'),
          ctl: stickPinCtl,
          hinweis: meldung == null
              ? t('stickPinHint')
              : '$meldung\n\n${t('stickPinHint')}',
          nurZahlen: true);
      pin = stickPinCtl.text;
      stickPinCtl.clear();
      if (ok != true || pin.isEmpty || !mounted) return null;
    }
  }

  /// Fragt ein Geheimnis ab, ohne es irgendwo abzulegen.
  Future<bool?> _frageGeheimnis({
    required String titel,
    required TextEditingController ctl,
    required String hinweis,
    bool nurZahlen = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surf,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: p.line)),
        title: Text(titel, style: doto(size: 17, color: p.ink)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctl,
            obscureText: true,
            autofocus: true,
            keyboardType: nurZahlen ? TextInputType.number : null,
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
            style: mono(size: 15, color: p.ink, spacing: 2),
            decoration: InputDecoration(
              hintText: '••••••',
              hintStyle: mono(size: 15, color: p.dim, spacing: 2),
            ),
          ),
          const SizedBox(height: 10),
          Text(hinweis, style: mono(size: 11, color: p.dim, height: 1.5)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('cancel'), style: mono(size: 12, color: p.dim))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child:
                  Text(t('unlock'), style: mono(size: 12, color: p.accLight))),
        ],
      ),
    );
  }

  // Die PIN DES STICKS (nicht die des Telefons) fragt [_mitStickPin] ab. Sie
  // verlaesst das Telefon nie im Klartext: uebertragen werden die ersten 16
  // Byte ihres SHA-256, und auch die nur verschluesselt.

  // ---- WIEDERHERSTELLEN ----
  //
  // DIESEN BILDSCHIRM GAB ES BIS ZUM 25.07.2026 NICHT — waehrend der
  // Bildschirm mit den zwoelf Woertern sagte, sie seien "der einzige Weg
  // zurueck, wenn dieses Telefon verloren, kaputt oder geloescht ist".
  //
  // Der Kern konnte es die ganze Zeit (restoreIdentity), AppState auch
  // (identitaetWiederherstellen), die Pruefung ebenfalls. Nur der Weg dorthin
  // fehlte. Wer sein Telefon verlor und die Woerter brav aufgeschrieben hatte,
  // stand auf dem neuen vor einer App, die sie nirgends annahm.
  //
  // WARUM JEDES WORT EINZELN GEPRUEFT WIRD
  // "Phrase ungueltig" hilft bei zwoelf Woertern niemandem — man weiss nicht,
  // welches. Hier wird jedes Wort gegen die Liste gehalten und das falsche
  // hervorgehoben. Bei etwas, das ueber den Verlust der Identitaet
  // entscheidet, ist das kein Feinschliff.

  Widget _wegKnopf(StickWeg weg, String beschriftung) {
    final an = stickWeg == weg;
    return GestureDetector(
      onTap: stickSchritt != null ? null : () => setState(() => stickWeg = weg),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: an ? p.tint : p.surf2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: an ? p.tintLine : p.line)),
        child: Text(beschriftung.toUpperCase(),
            style: mono(
                size: 11,
                weight: FontWeight.w500,
                color: an ? p.tintInk : p.dim,
                spacing: 1.2)),
      ),
    );
  }
}
