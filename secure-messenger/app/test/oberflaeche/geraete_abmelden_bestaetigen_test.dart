// geraete_abmelden_bestaetigen_test.dart — ein anderes Geraet abmelden nur mit
// frischer Anmeldung (QA-Bericht vom 18.11.2026, T3-SIGNOUT).
//
// Bis 22.11.2026 genuegte "Ja": wer ein entsperrtes Zweitgeraet in der Hand
// hatte, meldete das Telefon des Besitzers ab. Jetzt kommt vor dem Abmelden
// dieselbe Huerde wie vor dem Zeigen der Woerter (GeraeteStil.frischBestaetigt).

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/geraete_seite.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _t(String k) => strings['de']![k] ?? k;

/// Zwei Geraete, dieses ist Mitglied — ohne Kern und Relay: hier geht es nur
/// darum, was die Knoepfe tun.
class _ZweiGeraete extends AppState {
  _ZweiGeraete() : super(FakeMessengerCore());

  final abgemeldet = <int>[];
  var alleAnderen = 0;

  @override
  ListenStand get geraeteStand => ListenStand.mitglied;
  @override
  bool get hatGeraeteliste => true;
  @override
  List<GeraetAnzeige> get eigeneGeraete => const [
        GeraetAnzeige(id: 1, istDieses: true, name: 'Telefon'),
        GeraetAnzeige(id: 2, istDieses: false, name: 'Laptop'),
      ];
  @override
  Future<void> meldeGeraetAb(int id) async => abgemeldet.add(id);
  @override
  Future<void> meldeAlleAnderenAb() async => alleAnderen++;
}

GeraeteStil _stil(Future<bool> Function()? frisch) => GeraeteStil(
      p: palDark,
      t: _t,
      text: (g, f, {fett = false}) => TextStyle(fontSize: g, color: f),
      titel: (g, f) => TextStyle(fontSize: g, color: f),
      hinweis: (s, {warnend = true}) => Text(s),
      frischBestaetigt: frisch,
    );

void main() {
  Future<void> oeffne(WidgetTester tester, AppState st, GeraeteStil stil) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GeraeteKachel(st: st, stil: stil))));
    await tester.tap(find.byKey(const ValueKey('geraete-verwalten')));
    await tester.pumpAndSettle();
  }

  Future<void> jaSagen(WidgetTester tester, String knopf) async {
    // Die Rueckfrage hat zwei Knoepfe; der zweite ist "ja".
    await tester.tap(find.widgetWithText(TextButton, knopf).last);
    await tester.pumpAndSettle();
  }

  testWidgets('OHNE FRISCHE ANMELDUNG BLEIBT DAS ANDERE GERAET ANGEMELDET',
      (tester) async {
    final st = _ZweiGeraete();
    var gefragt = 0;
    await oeffne(tester, st, _stil(() async {
      gefragt++;
      return false;
    }));
    await tester.tap(find.byKey(const ValueKey('abmelden-2')));
    await tester.pumpAndSettle();
    await jaSagen(tester, _t('geraeteAbmelden'));
    expect(gefragt, 1, reason: 'die frische Anmeldung wurde nicht verlangt');
    expect(st.abgemeldet, isEmpty,
        reason: 'ein Tippen auf "Ja" meldete das Geraet ab');

    await tester.tap(find.byKey(const ValueKey('alle-anderen-abmelden')));
    await tester.pumpAndSettle();
    await jaSagen(tester, _t('geraeteAlleAnderen'));
    expect(gefragt, 2);
    expect(st.alleAnderen, 0);
  });

  testWidgets('MIT FRISCHER ANMELDUNG GEHT ES', (tester) async {
    final st = _ZweiGeraete();
    await oeffne(tester, st, _stil(() async => true));
    await tester.tap(find.byKey(const ValueKey('abmelden-2')));
    await tester.pumpAndSettle();
    await jaSagen(tester, _t('geraeteAbmelden'));
    expect(st.abgemeldet, [2]);

    await tester.tap(find.byKey(const ValueKey('alle-anderen-abmelden')));
    await tester.pumpAndSettle();
    await jaSagen(tester, _t('geraeteAlleAnderen'));
    expect(st.alleAnderen, 1);
  });

  testWidgets('WER "ABBRECHEN" SAGT, WIRD GAR NICHT ERST NACH DEM PASSWORT GEFRAGT',
      (tester) async {
    final st = _ZweiGeraete();
    var gefragt = 0;
    await oeffne(tester, st, _stil(() async {
      gefragt++;
      return true;
    }));
    await tester.tap(find.byKey(const ValueKey('abmelden-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, _t('cancel')).last);
    await tester.pumpAndSettle();
    expect(gefragt, 0);
    expect(st.abgemeldet, isEmpty);
  });

  test('DER WIEDERHERSTELLEN-TEXT SAGT NICHT MEHR, ABMELDEN GEHE NICHT', () {
    // T1-UX-005: der Satz stand neben "Alle anderen abmelden".
    for (final sprache in ['de', 'en']) {
      final text = strings[sprache]!['restoreIntro']!;
      expect(text.contains('A device cannot be logged out'), isFalse);
      expect(text.contains('Abmelden lässt sich ein Gerät nicht'), isFalse);
    }
  });
}
