// veraltete_app_hinweis_test.dart — sagt der Chat, dass die Gegenseite
// BitDM aktualisieren muss?
//
// SEIT 2.0.0 gibt es keine Sitzung mehr mit einer App ohne Kyber. Bis
// 17.10.2026 stand eine Nachricht an so einen Kontakt stumm auf "wird
// gesendet". Jetzt traegt der Kontakt [Contact.brauchtNeuereApp] (gesetzt und
// geloescht im Kern, test/net/veraltete_app_test.dart), und der Chat zeigt
// darueber einen ruhigen Kasten.
//
// Hier wird nur die Oberflaeche gemessen: der Kasten erscheint, wenn der Kern
// den Wechsel meldet, und verschwindet wieder, wenn der Vermerk faellt —
// ohne dass jemand den Chat neu oeffnet.

import 'dart:async';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Die Attrappe des Kerns, deren Kontakte auf Kommando eine alte App haben.
///
/// Die Ereignisse kommen aus einem EIGENEN Strom: die der Attrappe sind
/// privat, und gebraucht wird hier nur der eine Wechsel.
class _KernMitAlterGegenseite extends FakeMessengerCore {
  bool alt = false;
  final _wechsel = StreamController<ContactEvent>.broadcast();

  @override
  Stream<ContactEvent> get contactEvents => _wechsel.stream;

  @override
  Future<List<Contact>> getContacts() async => [
        for (final k in await super.getContacts())
          k.copyWith(brauchtNeuereApp: alt),
      ];

  /// Wie `_merkeAppFassung` im echten Kern: erst die Ablage, dann das
  /// Ereignis.
  void melde(bool veraltet) {
    alt = veraltet;
    _wechsel.add(ContactEvent(
        type: ContactEventType.needsUpdateChanged,
        contactId: 'egal',
        at: DateTime.now().toUtc()));
  }
}

void main() {
  late AppState st;
  late _KernMitAlterGegenseite kern;
  const kasten = ValueKey('hinweis-neuere-app');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    kern = _KernMitAlterGegenseite();
    st = AppState(kern);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  Future<void> warte(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Baut die App, geht durchs Onboarding und oeffnet eine Unterhaltung —
  /// derselbe Weg wie in kontakt_entfernen_test.dart.
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

  testWidgets('MELDET DER KERN EINE ALTE APP, STEHT DER HINWEIS IM CHAT — '
      'UND GEHT MIT DEM UPDATE WIEDER', (tester) async {
    await inDieUnterhaltung(tester);
    expect(find.textContaining('DETAILS'), findsWidgets,
        reason: 'die Unterhaltung ist nicht offen, dann misst das nichts');
    expect(find.byKey(kasten), findsNothing,
        reason: 'ohne Vermerk kein Hinweis');

    kern.melde(true);
    await warte(tester);
    expect(find.byKey(kasten), findsOneWidget,
        reason: 'DIE LUECKE: die Nachricht stand stumm auf "wird gesendet"');
    expect(find.text(strings['en']!['peerNeedsUpdate']!), findsOneWidget);

    kern.melde(false);
    await warte(tester);
    expect(find.byKey(kasten), findsNothing,
        reason: 'nach dem Update stimmt der Hinweis nicht mehr');
  });

  test('den Satz gibt es auf Deutsch und Englisch', () {
    final de = strings['de']!['peerNeedsUpdate'];
    final en = strings['en']!['peerNeedsUpdate'];
    expect(de, isNotNull);
    expect(en, isNotNull);
    expect(de, isNot(en), reason: 'eine Sprache ist nicht uebersetzt');
  });
}
