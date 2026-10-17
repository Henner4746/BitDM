// nahbereich_hinweis_test.dart — welches Hindernis zeigen die Einstellungen
// unter "Bluetooth benutzen"?
//
// DIE LUECKE, DIE ES HIERHER GEBRACHT HAT
//
// `nahbereichBlock` fragte `erweitert` nur, wenn `geht` schon falsch war — und
// `geht` enthaelt `erweitert` nicht. Ein Telefon mit Bluetooth 4.2 (BLE, aber
// keine erweiterte Werbung) bekam also GAR KEINEN Hinweis: der Schalter ging
// an, und es war fuer niemanden sichtbar (NahfunkKanal.kt, ESP32-Messung vom
// 29.07.2026).
//
// UND UMGEKEHRT: mit ausgeschaltetem Bluetooth meldet Android
// `isLeExtendedAdvertisingSupported() == false` (BluetoothAdapter.java:
// `if (!getLeAccess()) return false;`, getLeAccess verlangt STATE_ON oder
// STATE_BLE_ON). Weil die Pruefung vor `!an` stand, sagte die App dann "kein
// Bluetooth LE" statt "Bluetooth ist ausgeschaltet".

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FunkMitZustand implements Nahfunk {
  FunkMitZustand(this.z);
  final Funkzustand z;
  @override
  Future<Funkzustand> zustand() async => z;
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

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  String en(String k) => strings['en']![k]!;

  /// In die Einstellungen, mit einem Telefon, das [z] meldet.
  Future<void> einstellungenMit(WidgetTester tester, Funkzustand z) async {
    st = AppState(FakeMessengerCore())..funk = FunkMitZustand(z);
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
    await tester.tap(find.text('SETTINGS'));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 400));
    // Unter dem Block steht der Link zur Anleitung; ist er zu sehen, ist der
    // Block gebaut.
    await tester
        .ensureVisible(find.text(en('nearGuideLink').toUpperCase()));
    await tester.pump(const Duration(milliseconds: 200));
  }

  const hindernisse = [
    'nearbyTooOld',
    'nearbyNoHardware',
    'nearbyNoExtended',
    'nearbyNoPerm',
    'nearbyBtOff',
  ];

  /// Welche Hindernisse gerade dastehen.
  List<String> sichtbar() => [
        for (final k in hindernisse)
          if (find.text(en(k)).evaluate().isNotEmpty) k
      ];

  testWidgets('BLUETOOTH 4.2: ein Hinweis statt Schweigen', (tester) async {
    await einstellungenMit(
        tester,
        const Funkzustand(
            zuAlt: false,
            vorhanden: true,
            an: true,
            rechte: true,
            erweitert: false,
            jeWerbung: 20));
    expect(sichtbar(), ['nearbyNoExtended'],
        reason: 'der Schalter geht an, und das Telefon ist fuer niemanden '
            'sichtbar — ohne ein Wort');
  });

  testWidgets('BLUETOOTH AUS: so heisst es auch, nicht "kein Bluetooth LE"',
      (tester) async {
    // `erweitert: false`, weil Android es bei ausgeschaltetem Bluetooth so
    // meldet (Kopf dieser Datei).
    await einstellungenMit(
        tester,
        const Funkzustand(
            zuAlt: false,
            vorhanden: true,
            an: false,
            rechte: true,
            erweitert: false,
            jeWerbung: 20));
    expect(sichtbar(), ['nearbyBtOff']);
  });

  testWidgets('OHNE BLUETOOTH LE: das bleibt "kein Bluetooth LE"',
      (tester) async {
    await einstellungenMit(
        tester,
        const Funkzustand(
            zuAlt: false,
            vorhanden: false,
            an: false,
            rechte: true,
            erweitert: false,
            jeWerbung: 20));
    expect(sichtbar(), ['nearbyNoHardware']);
  });

  testWidgets('ALLES DA: kein Hindernis', (tester) async {
    await einstellungenMit(
        tester,
        const Funkzustand(
            zuAlt: false,
            vorhanden: true,
            an: true,
            rechte: true,
            jeWerbung: 20));
    expect(sichtbar(), isEmpty);
  });
}
