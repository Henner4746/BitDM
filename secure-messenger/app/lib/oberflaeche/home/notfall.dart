// notfall.dart — Panik-Passwort, Alles loeschen, Fernloeschung, Codewort.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
// SICHERHEITSRELEVANT: wer die Sperre prueft, liest home.dart, sperre.dart
// und zugriff.dart und sucht in den uebrigen Teilen nach frischBestaetigt.
part of '../home.dart';

extension _Notfall on _HomeState {
  /// Der rote Balken ueber der Chatliste, solange eine Fernloeschung laeuft.
  ///
  /// Die Zeit ist die ECHTE: bis zur Faelligkeit oder, wenn sie schon vorbei
  /// war, bis zum Ende der Nachfrist ([AppState.fernFrist]). In der letzten
  /// Minute in Sekunden.
  Widget fernBanner() {
    final f = st.fernFrist ?? st.fernloeschung.faellig!;
    // Aufgerundet: "noch 0 s", solange es noch nicht passiert ist, waere
    // falsch. Die Nachfrist (genau 60 s) steht damit sofort in Sekunden da.
    final sek = (f.difference(DateTime.now().toUtc()).inMilliseconds / 1000).ceil();
    final text = sek <= 60
        ? t('wipeBannerSec').replaceFirst('{s}', '${sek < 0 ? 0 : sek}')
        : t('wipeBanner').replaceFirst('{m}', '${(sek / 60).ceil()}');
    return Container(
      key: const ValueKey('fern-banner'),
      margin: const EdgeInsets.fromLTRB(17, 8, 17, 0),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
      child: Row(children: [
        Expanded(child: Text(text,
            style: mono(size: 12, weight: FontWeight.w600, color: p.tintInk, height: 1.4))),
        const SizedBox(width: 8),
        outlineBtn(t('cancel'), () async {
          // NUR MIT FRISCHER ANMELDUNG. Sonst haelt jeder, der das entsperrte
          // Telefon gerade hat, die Loeschung auf, die wegen ihm laeuft.
          if (!await frischBestaetigt(frage: t('wipeCancelAsk'))) return;
          await st.brichFernloeschungAb();
          _hinweis(t('wipeCancelled'));
        }, padding: const EdgeInsets.all(8)),
      ]),
    );
  }

  void _planeFernAnzeige() {
    final f = st.fernFrist ?? st.fernloeschung.faellig;
    if (f == null) {
      _fernAnzeigeTakt?.cancel();
      _fernAnzeigeTakt = null;
      return;
    }
    if (_fernAnzeigeTakt != null) return;
    final rest = f.difference(DateTime.now().toUtc());
    final abstand = rest.inSeconds <= 61
        ? const Duration(seconds: 1)
        : Duration(seconds: rest.inSeconds % 60 == 0 ? 60 : rest.inSeconds % 60);
    _fernAnzeigeTakt = Timer(abstand, () {
      _fernAnzeigeTakt = null;
      if (!mounted) return;
      setState(() {});
      _planeFernAnzeige();
    });
  }

  Future<void> _richteFernloeschungEin() async {
    final kandidaten = st.aktiveKontakte.where((k) => !st.istNotizen(k.id)).toList();
    final gewaehlt = st.fernloeschung.vertraute.toSet();
    var an = st.fernloeschung.an;
    var k = st.fernloeschung.schwelle;
    String? fehler;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          title: Text(t('wipeTitle')),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('wipeExplain'), style: mono(size: 11, color: p.dim, height: 1.5)),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  value: an, onChanged: (v) => neu(() => an = v),
                  title: Text(t('wipeEnable'), style: mono(size: 12.5, color: p.ink)),
                ),
                Text(t('wipeThreshold'), style: mono(size: 11, color: p.muted)),
                const SizedBox(height: 4),
                segmented(['2', '3', '4'], ['2', '3', '4'], '$k', (v) => neu(() => k = int.parse(v))),
                const SizedBox(height: 6),
                for (final kontakt in kandidaten)
                  CheckboxListTile(
                    dense: true, contentPadding: EdgeInsets.zero,
                    value: gewaehlt.contains(kontakt.id),
                    onChanged: (v) => neu(() => v == true ? gewaehlt.add(kontakt.id) : gewaehlt.remove(kontakt.id)),
                    title: Text(shortId(adresseFormatiert(kontakt.id)), style: mono(size: 12, color: p.ink)),
                  ),
                if (fehler != null) Text(fehler!, style: mono(size: 11.5, color: p.tintInk)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
            TextButton(
              onPressed: () {
                if (an && gewaehlt.length < k) {
                  neu(() => fehler = t('wipeTooFew').replaceFirst('{k}', '$k'));
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(t('actSave')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // ABSCHALTEN ODER UMSTELLEN NUR MIT FRISCHER ANMELDUNG. Wer die Liste der
    // Vertrauten oder die Schwelle aendert, kann die Fernloeschung genauso
    // aushebeln wie jemand, der sie abschaltet. Das erste Einschalten
    // schwaecht nichts und braucht es nicht.
    final vorher = st.fernloeschung;
    final geaendert = !an ||
        k != vorher.schwelle ||
        gewaehlt.length != vorher.vertraute.length ||
        !gewaehlt.containsAll(vorher.vertraute);
    if (vorher.an && geaendert && !await frischBestaetigt(frage: t('wipeChangeAsk'))) {
      return;
    }
    await st.setzeFernloeschung(st.fernloeschung.copyWith(
        an: an, schwelle: k, vertraute: gewaehlt.toList(), anfragen: const {}));
  }

  /// Wie die Fernloeschung funktioniert — derselbe Text wie im Dialog zum
  /// Einrichten, hier ohne ihn oeffnen zu muessen.
  Future<void> _zeigeFernErklaerung() => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('fern-erklaerung'),
          title: Text(t('wipeTitle')),
          content: SingleChildScrollView(
              child: Text(t('wipeExplain'), style: mono(size: 12, color: p.muted, height: 1.5))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('close'))),
          ],
        ),
      );

  /// Setzt oder aendert das Fernloesch-Codewort.
  ///
  /// ERST DAS WORT, DANN DIE ANMELDUNG: der Beleg der frischen Anmeldung
  /// gilt nur zwei Minuten (VaultSecretStore.nachweisGueltigkeit), und wer
  /// sich beim Tippen Zeit laesst, soll nicht an einem abgelaufenen Beleg
  /// scheitern.
  Future<void> _richteCodewortEin() async {
    final eins = TextEditingController();
    final zwei = TextEditingController();
    String? fehler;
    final wort = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          key: const ValueKey('codewort-dialog'),
          backgroundColor: p.surf,
          title: Text(t('wipeCodeTitle'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('wipeCodeBody'), style: mono(size: 12, color: p.muted, height: 1.5)),
              const SizedBox(height: 10),
              TextField(key: const ValueKey('codewort-eins'), controller: eins, obscureText: true,
                  autocorrect: false, enableSuggestions: false,
                  style: mono(size: 13, color: p.ink),
                  decoration: InputDecoration(hintText: t('wipeCodeHint'), hintStyle: mono(size: 13, color: p.dim))),
              TextField(key: const ValueKey('codewort-zwei'), controller: zwei, obscureText: true,
                  autocorrect: false, enableSuggestions: false,
                  style: mono(size: 13, color: p.ink),
                  decoration: InputDecoration(hintText: t('wipeCodeAgain'), hintStyle: mono(size: 13, color: p.dim))),
              if (fehler != null) ...[
                const SizedBox(height: 8),
                Text(fehler!, style: mono(size: 11.5, color: p.tintInk, height: 1.4)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () {
                // Verglichen wird in derselben Form, in der spaeter geprueft
                // wird — "Rote Katze" und "rote  katze" sind dasselbe Wort.
                if (FernCodewort.normalisiere(eins.text) != FernCodewort.normalisiere(zwei.text)) {
                  neu(() => fehler = t('pwMismatch'));
                  return;
                }
                if (!FernCodewort.taugt(eins.text)) {
                  neu(() => fehler = t('wipeCodeShort'));
                  return;
                }
                Navigator.pop(ctx, eins.text);
              },
              child: Text(t('actSave')),
            ),
          ],
        ),
      ),
    );
    eins.clear();
    zwei.clear();
    _entsorgeNachDemSchliessen([eins, zwei]);
    if (wort == null || !mounted) return;
    if (!await frischBestaetigt(frage: t('wipeCodeAsk'))) return;
    try {
      await st.setzeFernCodewort(wort);
      _hinweis(t('wipeCodeSaved'));
    } on NachweisNoetigException {
      _hinweis(t('unlockFailed'));
    }
  }

  /// Nimmt das Codewort weg — wie das Setzen nur mit frischer Anmeldung.
  Future<void> _entferneCodewort() async {
    if (!await frischBestaetigt(frage: t('wipeCodeRemoveAsk'))) return;
    try {
      await st.setzeFernCodewort(null);
      _hinweis(t('wipeCodeRemoved'));
    } on NachweisNoetigException {
      _hinweis(t('unlockFailed'));
    }
  }

  /// Loescht Identitaet, Schluessel und alle Nachrichten — wirklich.
  ///
  /// Bis zum 25.07.2026 setzte diese Funktion nur Anzeigewerte zurueck. Bei
  /// einem Entwurf war das folgenlos; jetzt liegen echte Nachrichten und eine
  /// echte Identitaet dahinter, und ein Knopf, der "alles geloescht" behauptet
  /// und es nicht tut, waere in dieser App der schlimmste denkbare Fehler.
  Future<void> doWipe() async {
    setState(() { panic = false; screen = 'creating'; });
    await st.allesLoeschen();
    if (!mounted) return;
    setState(() {
      final l = lang;
      screen = 'onboard'; chat = null; reqErgebnis = null; sheet = false;
      wiped = true; copied = false;
      enroll = null;
      lang = l;
      // Auch Filter und Suche: "ungelesen" oder ein Suchwort der alten
      // Identitaet stuenden sonst ueber der leeren Liste der neuen.
      _filter = 'alle';
      _zeigeArchiv = false;
      suchCtl.clear();
      draftCtl.clear(); addCtl.clear(); codeCtl.clear();
    });
  }

  Future<void> _richtePanikPasswortEin() async {
    final eins = TextEditingController();
    final zwei = TextEditingController();
    String? fehler;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, neu) => AlertDialog(
          backgroundColor: p.surf,
          title: Text(t('panicPw'), style: mono(size: 15, weight: FontWeight.w600, color: p.ink)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('panicPwBody'), style: mono(size: 12, color: p.muted, height: 1.5)),
              // OHNE APP-PASSWORT: wo tippt man es dann ein? Im Passwortfeld,
              // das der Sperrbildschirm trotzdem anbietet (AppState
              // sperreBietetPasswort).
              if (!st.hatFaktor(UnlockFactorKind.passphrase)) ...[
                const SizedBox(height: 8),
                Text(t('panicPwNoPw'), key: const ValueKey('panik-ohne-passwort'),
                    style: mono(size: 12, color: p.ink, height: 1.5)),
              ],
              const SizedBox(height: 10),
              // KEIN trim, nirgends: was hier steht, muss am Sperrbildschirm
              // Zeichen fuer Zeichen wieder so eingetippt werden (siehe
              // AppState.setzePanikPasswort).
              TextField(key: const ValueKey('panik-eins'), controller: eins, obscureText: true,
                  autocorrect: false, enableSuggestions: false,
                  style: mono(size: 13, color: p.ink),
                  decoration: InputDecoration(hintText: t('panicPwHint'), hintStyle: mono(size: 13, color: p.dim))),
              TextField(key: const ValueKey('panik-zwei'), controller: zwei, obscureText: true,
                  autocorrect: false, enableSuggestions: false,
                  style: mono(size: 13, color: p.ink),
                  decoration: InputDecoration(hintText: t('panicPwAgain'), hintStyle: mono(size: 13, color: p.dim))),
              if (fehler != null) ...[
                const SizedBox(height: 8),
                Text(fehler!, style: mono(size: 11.5, color: p.tintInk, height: 1.4)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
            TextButton(
              onPressed: () async {
                if (eins.text != zwei.text) {
                  neu(() => fehler = t('pwMismatch'));
                  return;
                }
                try {
                  await st.setzePanikPasswort(eins.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                } on PanikWortUngueltigException catch (e) {
                  neu(() => fehler = t(e.grund == PanikWortFehler.zuKurz
                      ? 'panicPwShort'
                      : 'panicPwEdge'));
                } on PanikGleichException {
                  neu(() => fehler = t('panicPwSame'));
                }
              },
              child: Text(t('actSave')),
            ),
          ],
        ),
      ),
    );
    // Das Passwort nicht laenger als noetig im Speicher stehen lassen.
    eins.clear();
    zwei.clear();
    _entsorgeNachDemSchliessen([eins, zwei]);
  }

  Widget panicModal() {
    return scrim(
      align: Alignment.center,
      Container(
        margin: const EdgeInsets.all(22),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          h2(t('panicTitle'), size: 20),
          const SizedBox(height: 11),
          Text(t('panicBody'), style: mono(size: 12.5, color: p.muted, height: 1.5)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: outlineBtn(t('cancel'), () => setState(() => panic = false), accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('delete'), doWipe, padding: const EdgeInsets.all(11), textColor: p.tintInk)),
          ]),
        ]),
      ),
    );
  }
}
