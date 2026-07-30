// kontakt_entfernen_test.dart — laesst sich ein Kontakt wieder loswerden?
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// `removeContact` steht seit jeher im Kern. Gerufen hat es NIEMAND: es gab
// keine einzige Stelle in der Oberflaeche, von der aus man einen Kontakt
// entfernen konnte. Wer eine falsche Adresse eintippte — 56 Zeichen, das ist
// kein Randfall —, wurde sie nie wieder los.
//
// Aufgefallen ist es am 29.07.2026 nur nebenbei: auf einem Testgeraet blieb
// ein toter Kontakt stehen, und beim Suchen nach dem Entfernen-Knopf war
// keiner da. Eine Funktion, die im Kern liegt und die niemand ruft, besteht
// jeden Test der Welt — deshalb tippt dieser hier wirklich.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FunkAttrappe implements Nahfunk {
  @override
  Future<Funkzustand> zustand() async => const Funkzustand(
      zuAlt: false, vorhanden: true, an: true, rechte: true, jeWerbung: 20);
  @override
  Future<Rechtelage> fordereRechte() async => Rechtelage.erteilt;
  @override
  Future<void> oeffneEinstellungen() async {}
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

void main() {
  late AppState st;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore())..funk = FunkAttrappe();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  /// Findet einen Text unabhaengig von Gross- und Kleinschreibung.
  ///
  /// Die Knoepfe setzen ihre Beschriftung teils in Grossbuchstaben; welcher
  /// das tut, ist eine Gestaltungsfrage und nichts, woran ein Test haengen
  /// sollte.
  Finder textEgalWie(String teil) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').toUpperCase().contains(teil.toUpperCase()));

  /// Baut die App, geht durchs Onboarding und oeffnet die Unterhaltung.
  Future<void> inDieUnterhaltung(WidgetTester tester) async {
    await tester.runAsync(() async => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CREATE IDENTITY'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('SKIP FOR NOW'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('CHATS'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
        find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').contains('2L-X')).first,
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Oeffnet das Blatt ueber den Kontaktnamen in der Kopfzeile.
  Future<void> oeffneBlatt(WidgetTester tester) async {
    // UEBER "DETAILS" UND NICHT UEBER DIE ADRESSE.
    //
    // Nachgemessen: die Liste schreibt sie 'BITD...2L-X', die Kopfzeile der
    // Unterhaltung 'bitd...q2lx' — andere Gruppierung, andere Schreibweise.
    // Auf eine der beiden zu wetten hiesse, den Test an eine
    // Darstellungsentscheidung zu binden, die sich jederzeit aendern darf.
    final kopf = find.textContaining('DETAILS');
    expect(kopf, findsWidgets, reason: 'die Kopfzeile ist nicht zu finden');
    await tester.tap(kopf.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('EIN KONTAKT LAESST SICH ENTFERNEN', (tester) async {
    await inDieUnterhaltung(tester);
    final vorher = st.kontakte.length;
    expect(vorher, greaterThan(0), reason: 'ohne Kontakte prueft das nichts');

    await oeffneBlatt(tester);
    expect(textEgalWie('Remove contact'), findsOneWidget,
        reason: 'DAS IST DIE GANZE LUECKE: es gab keinen Weg dorthin');

    await tester.tap(textEgalWie('Remove contact'));
    await tester.pump(const Duration(milliseconds: 400));

    // Die Rueckfrage muss kommen — Entfernen nimmt den Verlauf mit.
    expect(textEgalWie('REMOVE'), findsWidgets,
        reason: 'ohne Rueckfrage waere ein Fehltipp endgueltig');
    await tester.tap(textEgalWie('REMOVE').last);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(st.kontakte.length, vorher - 1,
        reason: 'der Kontakt steht noch in der Liste');
  });

  testWidgets('und ein Abbruch entfernt nichts', (tester) async {
    // Die Gegenprobe, und sie ist keine Formsache: ein Dialog, dessen
    // Abbrechen genauso wirkt wie sein Bestaetigen, ist schlimmer als keiner.
    await inDieUnterhaltung(tester);
    final vorher = st.kontakte.length;

    await oeffneBlatt(tester);
    await tester.tap(textEgalWie('Remove contact'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(textEgalWie('Cancel'));
    await tester.pump(const Duration(milliseconds: 600));

    expect(st.kontakte.length, vorher,
        reason: 'abgebrochen, und der Kontakt ist trotzdem weg');
  });
}
