// kontakt_hinzufuegen_test.dart — sagt der Hinzufuegen-Bildschirm, was
// wirklich passiert ist?
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// Bis 15.10.2026 gab `kontaktHinzufuegen` immer true zurueck, und der
// Bildschirm sagte "Anfrage gesendet" — auch mit "nur in der Naehe", wo eine
// Kontaktanfrage nie hinausgeht (nahweg_test "EIN NEUER KONTAKT ENTSTEHT NICHT
// UEBER FUNK"), und auch bei jemandem, der laengst Kontakt war.
//
// Was der Kern dabei tut, steht in real_core_test ("WER EINE ANFRAGE HAT UND
// SELBST HINZUFUEGT"). Hier steht, was der Nutzer davon zu lesen bekommt.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState st;

  /// Eine gueltige Adresse fuer den Uebungskern, die noch niemand hat.
  const neu = 'abcdefghijklmnopqrstuvwxyz0123456789';

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  String en(String k) => strings['en']![k]!;

  /// Bis zum Hinzufuegen-Bildschirm, derselbe Weg wie am Telefon.
  Future<void> zumHinzufuegen(WidgetTester tester) async {
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
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('CHATS').first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('+'));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> sendeAnfrage(WidgetTester tester, String adresse) async {
    await tester.enterText(find.byType(TextField).last, adresse);
    await tester.pump();
    await tester.tap(find.text(en('sendReq').toUpperCase()));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('NUR IN DER NAEHE steht da NICHT "Anfrage gesendet"',
      (tester) async {
    await zumHinzufuegen(tester);
    await tester.runAsync(() async => st.setzeEinstellungen(
        st.einstellungen.copyWith(naheAn: true, nurNahbereich: true)));
    await tester.pump();

    await sendeAnfrage(tester, neu);

    expect(find.text(en('reqSentNote')), findsNothing,
        reason: 'gesendet wurde nichts — die Anfrage braucht den Relay');
    expect(find.text(en('reqWaitsNote')), findsOneWidget,
        reason: 'der Nutzer muss erfahren, wann sie hinausgeht');
    // Der Uebungskern nimmt nach 1,2 s von selbst an.
    await tester.pump(const Duration(seconds: 2));
  });

  group('was kontaktHinzufuegen meldet', () {
    Future<void> bereit() async {
      await st.boot();
      await st.identitaetAnlegen();
    }

    test('mit Internet: angefragt', () async {
      await bereit();
      expect((await st.kontaktHinzufuegen(neu)).art, Hinzugefuegt.angefragt);
    });

    test('nur in der Naehe: wartet', () async {
      await bereit();
      await st.setzeEinstellungen(
          st.einstellungen.copyWith(naheAn: true, nurNahbereich: true));
      expect((await st.kontaktHinzufuegen(neu)).art, Hinzugefuegt.wartet);
    });

    test('ein bestaetigter Kontakt: schon Kontakt, nichts gesendet', () async {
      await bereit();
      final k = st.aktiveKontakte.first;
      expect((await st.kontaktHinzufuegen(k.id)).art,
          Hinzugefuegt.schonKontakt);
    });

    test('wer schon angefragt hat: angenommen, mit Kennung', () async {
      await bereit();
      // Der Uebungskern meldet kurz nach dem Verbinden eine Anfrage.
      for (var i = 0; i < 60 && st.offeneAnfragen.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final id = st.offeneAnfragen.single.id;

      final r = await st.kontaktHinzufuegen(id);
      expect(r.art, Hinzugefuegt.angenommen);
      expect(r.id, id, reason: 'ohne Kennung kann der Chat nicht aufgehen');
      expect(st.aktiveKontakte.map((k) => k.id), contains(id));
      expect(st.offeneAnfragen, isEmpty);
    });
  });

  testWidgets('MIT INTERNET bleibt es bei "Anfrage gesendet"', (tester) async {
    // DIE GEGENPROBE: der neue Satz darf nicht den alten ersetzen, wo der
    // alte stimmt.
    await zumHinzufuegen(tester);
    await sendeAnfrage(tester, neu);

    expect(find.text(en('reqSentNote')), findsOneWidget);
    expect(find.text(en('reqWaitsNote')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });
}
