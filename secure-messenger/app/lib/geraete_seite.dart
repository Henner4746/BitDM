// geraete_seite.dart — Geraete verwalten, beitreten, abgemeldet sein.
//
// Die Oberflaeche der Geraeteabmeldung (docs/GERAETEABMELDUNG.md). EIGENE
// DATEI und nicht in oberflaeche/home: dort haengen nur drei Zeilen, die
// hierher zeigen (Meine ID, Chatliste, Startbildschirm).
//
// Was hier steht:
//   * [GeraeteKachel]     — in "Meine ID": wie viele Geraete, und der Weg
//                           zur Verwaltung.
//   * [zeigeGeraete]      — die Liste: abmelden, hinzufuegen (Code zeigen).
//   * [BeitrittsKarte]    — auf einem Geraet, das nicht in der Liste steht:
//                           Code eingeben oder alle anderen abmelden.
//   * [abgemeldetText]    — der Satz fuer den Startbildschirm danach.

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/real_messenger_core.dart' show ListenStand, GeraetAnzeige;
import 'data.dart' show Pal;

/// Was diese Oberflaeche vom Hauptbildschirm braucht: Farben, Texte,
/// Schriften und den Hinweiskasten. Als Buendel, weil die Bausteine dort
/// Methoden des Bildschirmzustands sind.
class GeraeteStil {
  const GeraeteStil({
    required this.p,
    required this.t,
    required this.text,
    required this.titel,
    required this.hinweis,
  });

  final Pal p;
  final String Function(String) t;
  final TextStyle Function(double groesse, Color farbe, {bool fett}) text;
  final TextStyle Function(double groesse, Color farbe) titel;
  final Widget Function(String text, {bool warnend}) hinweis;
}

/// Hoechstens so viele Geraete nimmt der Relay (GERAETE_MAX).
const int _geraeteHoechstens = 5;

/// "Dieses Geraet wurde abgemeldet …" fuer den Startbildschirm.
String abgemeldetText(AppState st, String Function(String) t) {
  final von = st.abmeldung?.von;
  return t('abgemeldetHinweis').replaceFirst(
      '{von}', von == null ? '' : t('abgemeldetVon').replaceFirst('{name}', von));
}

String geraeteName(GeraetAnzeige g, String Function(String) t) =>
    g.name ?? t('geraeteOhneName').replaceFirst('{n}', '${g.id}');

String _datum(DateTime d) {
  final l = d.toLocal();
  return '${l.day}.${l.month}.${l.year}';
}

/// In "Meine ID": die Zahl der Geraete und der Knopf zur Verwaltung.
///
/// DIE ZAHL BLEIBT VERPFLICHTEND (MEHRGERAETE.md §6): aus einem unsichtbaren
/// Mitleser wird eine sichtbare Zahl, die nicht stimmt. Mit Geraeteliste kommt
/// der Weg dazu, ihn abzumelden; ohne (alter Relay) bleibt es bei der Warnung,
/// dass das nicht geht.
class GeraeteKachel extends StatelessWidget {
  const GeraeteKachel({super.key, required this.st, required this.stil});

  final AppState st;
  final GeraeteStil stil;

  @override
  Widget build(BuildContext context) {
    final t = stil.t;
    final liste = st.hatGeraeteliste;
    final n = liste ? st.eigeneGeraete.length : (st.geraeteZahl ?? 0);
    if (!liste && st.geraeteZahl == null) return const SizedBox.shrink();
    final satz = n <= 1
        ? t('geraeteEins')
        : (liste ? t('geraeteVieleListe') : t('geraeteViele'))
            .replaceFirst('{n}', '$n');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      stil.hinweis(satz, warnend: n > 1),
      if (liste) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('geraete-verwalten'),
          onPressed: () => zeigeGeraete(context, st, stil),
          child: Text(t('geraeteVerwalten')),
        ),
      ],
    ]);
  }
}

/// Die Geraeteliste als Dialog.
Future<void> zeigeGeraete(BuildContext context, AppState st, GeraeteStil stil) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('geraete-dialog'),
        backgroundColor: stil.p.surf,
        title: Text(stil.t('geraeteTitel'),
            style: stil.titel(17, stil.p.ink)),
        content: SizedBox(
          width: 380,
          child: ListenableBuilder(
            listenable: st,
            builder: (ctx, _) => _GeraeteInhalt(st: st, stil: stil),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(stil.t('close'))),
        ],
      ),
    );

class _GeraeteInhalt extends StatelessWidget {
  const _GeraeteInhalt({required this.st, required this.stil});

  final AppState st;
  final GeraeteStil stil;

  Future<bool> _frage(BuildContext context, String text, String ja) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: stil.p.surf,
          content: Text(text, style: stil.text(13, stil.p.ink)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(stil.t('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(ja)),
          ],
        ),
      ) ??
      false;

  Future<void> _versuche(BuildContext context, Future<void> Function() tu) async {
    try {
      await tu();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(stil.t('geraeteFehler'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = stil.t;
    final p = stil.p;
    final geraete = st.eigeneGeraete;
    final mehrere = geraete.length > 1;
    return SingleChildScrollView(
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!st.hatGeraeteliste) stil.hinweis(t('geraeteKeineListe')),
            for (final g in geraete)
              Container(
                key: ValueKey('geraet-${g.id}'),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: p.surf2,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: g.istDieses ? p.accent : p.line)),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(geraeteName(g, t),
                              style: stil.text(14, p.ink, fett: true)),
                          Text(
                              [
                                if (g.istDieses) t('geraeteDieses'),
                                if (g.seit != null)
                                  t('geraeteSeit')
                                      .replaceFirst('{d}', _datum(g.seit!)),
                              ].join(' · '),
                              style: stil.text(11, p.muted)),
                        ]),
                  ),
                  if (!g.istDieses)
                    TextButton(
                      key: ValueKey('abmelden-${g.id}'),
                      onPressed: () async {
                        final ja = await _frage(
                            context,
                            t('geraeteAbmeldenFrage')
                                .replaceFirst('{name}', geraeteName(g, t)),
                            t('geraeteAbmelden'));
                        if (ja && context.mounted) {
                          await _versuche(context, () => st.meldeGeraetAb(g.id));
                        }
                      },
                      child: Text(t('geraeteAbmelden')),
                    ),
                ]),
              ),
            const SizedBox(height: 8),
            if (st.geraeteStand == ListenStand.mitglied)
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (geraete.length < _geraeteHoechstens)
                  OutlinedButton(
                    key: const ValueKey('geraet-hinzufuegen'),
                    onPressed: () => _zeigeCode(context),
                    child: Text(t('geraeteHinzufuegen')),
                  ),
                if (mehrere)
                  OutlinedButton(
                    key: const ValueKey('alle-anderen-abmelden'),
                    onPressed: () async {
                      final ja = await _frage(context,
                          t('geraeteAlleAnderenFrage'), t('geraeteAlleAnderen'));
                      if (ja && context.mounted) {
                        await _versuche(context, st.meldeAlleAnderenAb);
                      }
                    },
                    child: Text(t('geraeteAlleAnderen')),
                  ),
                if (mehrere)
                  TextButton(
                    key: const ValueKey('dieses-abmelden'),
                    onPressed: () async {
                      final ja = await _frage(context,
                          t('geraeteDiesesAbmeldenFrage'),
                          t('geraeteDiesesAbmelden'));
                      if (ja && context.mounted) {
                        Navigator.of(context).pop();
                        await st.meldeDiesesGeraetAb();
                      }
                    },
                    child: Text(t('geraeteDiesesAbmelden')),
                  ),
              ]),
            if (geraete.length >= _geraeteHoechstens) ...[
              const SizedBox(height: 8),
              stil.hinweis(t('geraeteVoll'), warnend: false),
            ],
            const SizedBox(height: 12),
            // DER EHRLICHE SATZ, immer sichtbar. Abmelden haelt jedes Geraet
            // auf, das nur ein Geraet ist — nicht jemanden, der die Woerter
            // kennt (docs/GERAETEABMELDUNG.md §4).
            stil.hinweis(t('geraeteWoerterHinweis'), warnend: false),
          ]),
    );
  }

  Future<void> _zeigeCode(BuildContext context) async {
    final code = await st.starteHinzufuegen();
    if (code == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('beitrittscode-dialog'),
        backgroundColor: stil.p.surf,
        title: Text(stil.t('geraeteCodeTitel'),
            style: stil.titel(16, stil.p.ink)),
        content: SizedBox(
          width: 340,
          child: ListenableBuilder(
            listenable: st,
            builder: (ctx, _) {
              final fertig = st.beitrittscode == null && st.zuletztHinzugefuegt != null;
              return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (fertig)
                      Text(stil.t('geraeteHinzugefuegt'),
                          style: stil.text(14, stil.p.accLight, fett: true))
                    else ...[
                      Text(stil.t('geraeteCodeText'),
                          style: stil.text(12, stil.p.muted)),
                      const SizedBox(height: 14),
                      Center(
                        child: SelectableText(st.beitrittscode ?? code,
                            key: const ValueKey('beitrittscode'),
                            style: stil.titel(22, stil.p.ink)),
                      ),
                      const SizedBox(height: 14),
                      Row(children: [
                        SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: stil.p.muted)),
                        const SizedBox(width: 10),
                        Text(stil.t('geraeteCodeWartet'),
                            style: stil.text(11.5, stil.p.muted)),
                      ]),
                    ],
                  ]);
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(stil.t('close'))),
        ],
      ),
    );
    st.beendeHinzufuegen();
  }
}

/// Auf einem Geraet, das nicht in der Liste steht: Code eingeben — oder,
/// wenn kein anderes Geraet mehr da ist, alle anderen abmelden.
class BeitrittsKarte extends StatefulWidget {
  const BeitrittsKarte({super.key, required this.st, required this.stil});

  final AppState st;
  final GeraeteStil stil;

  @override
  State<BeitrittsKarte> createState() => _BeitrittsKarteState();
}

class _BeitrittsKarteState extends State<BeitrittsKarte> {
  final _code = TextEditingController();
  String? _fehler;
  bool _laeuft = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _bestaetigen() async {
    setState(() {
      _fehler = null;
      _laeuft = true;
    });
    try {
      final ok = await widget.st.trittBei(_code.text);
      if (!ok) _fehler = widget.stil.t('beitrittCodeFalsch');
    } catch (_) {
      _fehler = widget.stil.t('geraeteFehler');
    }
    if (mounted) setState(() => _laeuft = false);
  }

  Future<void> _zuruecksetzen() async {
    final s = widget.stil;
    final ja = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            key: const ValueKey('zuruecksetzen-frage'),
            backgroundColor: s.p.surf,
            title: Text(s.t('beitrittZuruecksetzen'), style: s.titel(16, s.p.ink)),
            content: Text(s.t('beitrittZuruecksetzenFrage'),
                style: s.text(12.5, s.p.ink)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(s.t('cancel'))),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(s.t('beitrittZuruecksetzen'))),
            ],
          ),
        ) ??
        false;
    if (!ja) return;
    setState(() => _laeuft = true);
    try {
      await widget.st.setzeZurueck();
    } catch (_) {
      _fehler = s.t('geraeteFehler');
    }
    if (mounted) setState(() => _laeuft = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stil;
    final p = s.p;
    final wartet = widget.st.geraeteStand == ListenStand.wartetAufBestaetigung;
    return Container(
      key: const ValueKey('beitritts-karte'),
      margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: p.tint,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.tintLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.t('beitrittTitel'), style: s.text(14, p.tintInk, fett: true)),
        const SizedBox(height: 6),
        Text(s.t('beitrittText'), style: s.text(12, p.tintInk)),
        const SizedBox(height: 10),
        if (wartet)
          Row(children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: p.tintInk)),
            const SizedBox(width: 10),
            Expanded(
                child: Text(s.t('beitrittWartet'),
                    style: s.text(12, p.tintInk))),
            TextButton(
                onPressed: widget.st.brichBeitrittAb,
                child: Text(s.t('beitrittAbbrechen'))),
          ])
        else ...[
          TextField(
            key: const ValueKey('beitrittscode-eingabe'),
            controller: _code,
            enabled: !_laeuft,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            style: s.titel(15, p.ink),
            decoration: InputDecoration(
              labelText: s.t('beitrittCode'),
              hintText: 'ABCD-EFGH-IJKL-MNOP',
              errorText: _fehler,
            ),
            onSubmitted: (_) => _bestaetigen(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            key: const ValueKey('beitritt-senden'),
            onPressed: _laeuft ? null : _bestaetigen,
            child: Text(s.t('beitrittSenden')),
          ),
          const SizedBox(height: 14),
          Text(s.t('beitrittKeinGeraet'), style: s.text(11.5, p.tintInk)),
          TextButton(
            key: const ValueKey('beitritt-zuruecksetzen'),
            onPressed: _laeuft ? null : _zuruecksetzen,
            child: Text(s.t('beitrittZuruecksetzen')),
          ),
        ],
      ]),
    );
  }
}
