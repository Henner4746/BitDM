// geraete_seite_test.dart — die Oberflaeche der Geraeteabmeldung.
//
// GEGEN DEN ECHTEN KERN, mit der Relay-Attrappe: die Geraeteverwaltung gibt
// es nur im echten Kern (die Kern-Attrappe kennt keinen Relay). Was der Kern
// dabei tut, belegen geraeteabmeldung_test.dart und
// geraeteliste_stufe2_test.dart; hier geht es darum, dass die Knoepfe da sind,
// das Richtige tun und das Ehrliche sagen.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/geraete_seite.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

String _t(String k) => strings['de']![k] ?? k;

final _stil = GeraeteStil(
  p: palDark,
  t: _t,
  text: (g, f, {fett = false}) => TextStyle(fontSize: g, color: f),
  titel: (g, f) => TextStyle(fontSize: g, color: f),
  hinweis: (s, {warnend = true}) => Text(s),
);

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late AppState st;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-geraete-ui');
  });

  tearDown(() async {
    st.dispose();
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  /// Ein Kern, dessen Adresse schon eine Liste hat — ohne dieses Geraet.
  /// Genau die Lage nach "zwoelf Woerter auf einem neuen Telefon".
  Future<void> neuesGeraet(WidgetTester tester) async {
    await tester.runAsync(() async {
      await signalBereit();
      lage = Relaylage()
        ..liste = []
        ..kenntListen = true;
      kern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}k.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
        relayFactory: (uri, id) {
          final r = RelayAttrappe(id, lage);
          lage.gebaut.add(r);
          return r;
        },
      );
      await kern.initialize();
      final woerter = await kern.createIdentity();
      final ich = SignalIdentityBridge.fromDerived(
          await KeyDerivation.fromMnemonic(woerter),
          registrationId: 1);
      final anderes = PrivateKey.generate();
      lage.listen[kern.myId] = Geraeteliste.unterschreibe(
        identitaet: ich,
        geraeteschluessel: anderes,
        epoche: 1,
        geraete: [GeraeteEintrag(99, rohOeffentlich(anderes), '')],
        unterzeichner: 99,
      ).alsJson();
      await kern.connect();
      st = AppState(kern);
    });
  }

  testWidgets('DIE BEITRITTSKARTE: Code, ehrliche Rueckfrage, Zuruecksetzen',
      (tester) async {
    await neuesGeraet(tester);
    expect(kern.geraeteStand, ListenStand.beitrittNoetig);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BeitrittsKarte(st: st, stil: _stil))));
    expect(find.text(_t('beitrittTitel')), findsOneWidget);

    // Ein Code, der keiner ist.
    await tester.enterText(find.byKey(const ValueKey('beitrittscode-eingabe')), 'hallo');
    await tester.tap(find.byKey(const ValueKey('beitritt-senden')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text(_t('beitrittCodeFalsch')), findsOneWidget);

    // "Kein anderes Geraet mehr?" — die Rueckfrage sagt, dass das jeder mit
    // den Woertern kann.
    await tester.tap(find.byKey(const ValueKey('beitritt-zuruecksetzen')));
    await tester.pump();
    expect(find.byKey(const ValueKey('zuruecksetzen-frage')), findsOneWidget);
    expect(find.textContaining('12 Wörter kennt'), findsOneWidget);
    await tester.tap(find.text(_t('beitrittZuruecksetzen')).last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(kern.geraeteStand, ListenStand.mitglied);
    expect(Geraeteliste.pruefe(lage.listen[kern.myId], adresse: kern.myId)
        .kennungen, {kern.geraetId},
        reason: 'nach dem Zuruecksetzen steht nur dieses Geraet in der Liste');
  });

  testWidgets('DIE GERAETELISTE: dieses Geraet, Hinzufuegen, ehrlicher Satz',
      (tester) async {
    await neuesGeraet(tester);
    await tester.runAsync(() => kern.setzeZurueck());
    expect(kern.geraeteStand, ListenStand.mitglied);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GeraeteKachel(st: st, stil: _stil))));
    expect(find.text(_t('geraeteEins')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('geraete-verwalten')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('geraete-dialog')), findsOneWidget);
    expect(find.byKey(ValueKey('geraet-${kern.geraetId}')), findsOneWidget);
    expect(find.textContaining(_t('geraeteDieses')), findsOneWidget);
    expect(find.text(_t('geraeteWoerterHinweis')), findsOneWidget,
        reason: 'die Grenze gehoert dauerhaft dorthin, wo man abmeldet');
    // Mit einem einzigen Geraet gibt es nichts abzumelden.
    expect(find.byKey(const ValueKey('alle-anderen-abmelden')), findsNothing);
    expect(find.byKey(const ValueKey('dieses-abmelden')), findsNothing);

    // Hinzufuegen zeigt einen Code mit 16 Zeichen.
    await tester.tap(find.byKey(const ValueKey('geraet-hinzufuegen')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('beitrittscode')))
        .data!;
    expect(Beitrittscode.lies(code), isNotNull, reason: code);
    expect(kern.beitrittscode, code);
    // Schliessen beendet das Hinzufuegen — der Code gilt danach nicht mehr.
    await tester.tap(find.text(_t('close')).last);
    await tester.pumpAndSettle();
    expect(kern.beitrittscode, isNull);
  });
}
