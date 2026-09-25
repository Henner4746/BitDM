// sperre_oberflaeche_test.dart — was die Oberflaeche beim Sperren schliesst,
// wann sie eine frische Anmeldung verlangt, und wo der Screenshot-Schutz
// gilt, auch wenn er in den Einstellungen aus ist.
//
// Echter Tresor und echtes Argon2id wie in panik_passwort_test; der Stick ist
// der nachgebaute aus test/fido/fake_stick.dart, der Fehlversuche mitzaehlt.

import 'dart:async';
import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/messenger_core.dart' show AppPreferences;
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/data.dart' show shortId;
import 'package:bitdm/main.dart';
import 'package:bitdm/themen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fido/fake_stick.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i + 7));
  @override
  Future<Uint8List?> read() async => inhalt;
  @override
  Future<void> write(Uint8List e) async => inhalt = e;
  @override
  Future<void> delete() async => inhalt = null;
}

class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};
  @override
  Future<String?> lies(String k) async => daten[k];
  @override
  Future<void> schreibe(String k, String v) async => daten[k] = v;
  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

const echtes = 'Kupfer-Regen-Turm-Zaun-9042';

void main() {
  late Directory verzeichnis;
  late FakeMessengerCore kern;
  late FakeStick stick;
  late AppState st;

  /// Was die Oberflaeche zuletzt an den Screenshot-Kanal geschickt hat.
  final schutz = <bool>[];

  /// Was der Kanal antwortet — false heisst "hier nicht moeglich".
  var kanalKann = true;

  setUp(() {
    schutz.clear();
    kanalKann = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), (c) async {
      if (c.method == 'setzeScreenshotSperre') {
        schutz.add((c.arguments as Map)['an'] as bool);
        return kanalKann;
      }
      return null;
    });
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-oberflaeche');
    kern = FakeMessengerCore()..simulateExistingIdentity = true;
    stick = FakeStick();
    final ablage = FakeAblage();
    st = AppState(
      kern,
      tresor: VaultSecretStore(
        datei: vaultDateiIn(verzeichnis.path),
        basis: FakeBasis(),
        jetzt: () => 1000,
      ),
      ablagen: (_) => ablage,
      stickZugang: (_) async => stick,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  /// Wartet, bis [was] erscheint — Argon2id und der Stick laufen in echter
  /// Zeit, nicht in der Testzeit.
  Future<void> bisDa(WidgetTester tester, Finder was, {int runden = 60}) async {
    for (var i = 0; i < runden && was.evaluate().isEmpty; i++) {
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> starte(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await warte(tester);
  }

  Future<void> zuDenEinstellungen(WidgetTester tester) async {
    await tester.tap(find.text('SETTINGS'));
    await warte(tester);
  }

  testWidgets('SPERREN SCHLIESST, WAS UEBER DEM BILDSCHIRM LIEGT', (tester) async {
    await starte(tester);
    await tester.runAsync(() => st.fuegePasswortHinzu(echtes));
    await warte(tester);
    final ctx = tester.element(find.byType(Scaffold).first);
    unawaited(showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(key: ValueKey('fremder-dialog'), content: Text('geheim'))));
    await warte(tester);
    expect(find.byKey(const ValueKey('fremder-dialog')), findsOneWidget);

    await tester.runAsync(() => st.sperreWieder());
    await warte(tester);

    expect(st.gesperrt, isTrue);
    expect(find.byKey(const ValueKey('fremder-dialog')), findsNothing,
        reason: 'der Dialog lag weiter ueber dem Sperrbildschirm');
    expect(find.text('LOCKED'), findsOneWidget);
  });

  testWidgets('DIE ZWOELF WOERTER IN DEN EINSTELLUNGEN — MIT ERZWUNGENEM SCREENSHOT-SCHUTZ',
      (tester) async {
    await starte(tester);
    await tester.runAsync(
        () => st.setzeEinstellungen(st.einstellungen.copyWith(blockScreenshots: false)));
    await zuDenEinstellungen(tester);
    expect(schutz.last, isFalse);

    await tester.ensureVisible(find.byKey(const ValueKey('woerter-zeigen')));
    await tester.tap(find.byKey(const ValueKey('woerter-zeigen')));
    await bisDa(tester, find.byKey(const ValueKey('woerter-dialog')));
    expect(find.byKey(const ValueKey('woerter-dialog')), findsOneWidget);
    expect(find.text('abandon'), findsWidgets);
    expect(schutz.last, isTrue, reason: 'die Woerter standen ohne Screenshot-Schutz da');

    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('woerter-dialog')), matching: find.byType(TextButton)));
    await warte(tester);
    expect(find.byKey(const ValueKey('woerter-dialog')), findsNothing);
    expect(schutz.last, isFalse, reason: 'der Schutz blieb nach dem Schliessen erzwungen');
  });

  testWidgets('MIT SPERRE ZEIGEN SICH DIE WOERTER NUR NACH FRISCHER ANMELDUNG', (tester) async {
    await starte(tester);
    await tester.runAsync(() => st.fuegePasswortHinzu(echtes));
    await zuDenEinstellungen(tester);

    Future<void> versuche(String passwort) async {
      await tester.ensureVisible(find.byKey(const ValueKey('woerter-zeigen')));
      await tester.tap(find.byKey(const ValueKey('woerter-zeigen')));
      await bisDa(tester, find.text('Confirm it is you'));
      expect(find.text('Confirm it is you'), findsOneWidget, reason: 'keine Rueckfrage');
      await tester.enterText(find.byType(TextField).last, passwort);
      await tester.tap(find.text('Unlock'));
      await bisDa(tester, find.byKey(const ValueKey('woerter-dialog')), runden: 40);
    }

    await versuche('Falsch-Falsch-Falsch-0000');
    expect(find.byKey(const ValueKey('woerter-dialog')), findsNothing,
        reason: 'ein falsches Passwort zeigte die Woerter');
    await warte(tester, 2400);

    await versuche(echtes);
    expect(find.byKey(const ValueKey('woerter-dialog')), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('woerter-dialog')), matching: find.byType(TextButton)));
    await warte(tester, 2400);
  });

  testWidgets('FALSCHE STICK-PIN: ES WIRD NEU GEFRAGT, NIE STILL NOCHMAL GESCHICKT', (tester) async {
    // ERST die App, DANN sperren: die Attrappe kennt keine Sperre, und das
    // boot() aus initState oeffnete sie sonst wieder.
    await starte(tester);
    await tester.runAsync(() async {
      await st.fuegeStickHinzu(pin: '123456');
      await st.sperreWieder();
    });
    await warte(tester);
    expect(find.text('LOCKED'), findsOneWidget);

    await tester.tap(find.text('USE SECURITY KEY'));
    await bisDa(tester, find.text('Key PIN'));
    expect(find.text('Key PIN'), findsOneWidget, reason: 'keine PIN-Abfrage');
    await tester.enterText(find.byType(TextField).last, '000000');
    await tester.tap(find.text('Unlock'));
    await bisDa(tester, find.textContaining('Wrong PIN'));
    expect(stick.fehlversuche, 1);
    expect(find.textContaining('Wrong PIN'), findsOneWidget,
        reason: 'nach der falschen PIN wurde nicht neu gefragt');

    await tester.tap(find.text('Cancel'));
    await warte(tester);
    expect(find.text('Key PIN'), findsNothing);

    // Der naechste Druck fragt WIEDER — vorher ging die alte PIN ungefragt
    // erneut hinaus und kostete einen weiteren der acht Versuche.
    await tester.tap(find.text('USE SECURITY KEY'));
    await bisDa(tester, find.text('Key PIN'));
    expect(find.text('Key PIN'), findsOneWidget);
    expect(stick.fehlversuche, 1, reason: 'die falsche PIN ging still ein zweites Mal hinaus');

    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('Unlock'));
    for (var i = 0; i < 60 && st.gesperrt; i++) {
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(st.gesperrt, isFalse);
    await warte(tester, 2400);
  });

  testWidgets('DIE WOERTER NACH DEM ANLEGEN STEHEN IMMER UNTER SCHUTZ', (tester) async {
    kern.simulateExistingIdentity = false;
    await kern.setPreferences(const AppPreferences(blockScreenshots: false));
    await starte(tester);
    await tester.tap(find.text('CREATE IDENTITY'));
    await bisDa(tester, find.text('I WROTE THEM DOWN'));
    await warte(tester);
    expect(schutz.last, isTrue, reason: 'die frischen Woerter standen ohne Schutz da');
    await tester.tap(find.text('I WROTE THEM DOWN'));
    await warte(tester);
    expect(schutz.last, isFalse, reason: 'der Schutz blieb nach den Woertern erzwungen');
  });

  testWidgets('"SCREENSHOT-SCHUTZ AKTIV" NUR, WENN DIE PLATTFORM ES BESTAETIGT', (tester) async {
    kanalKann = false; // wie am Rechner ohne Gegenseite
    await starte(tester);
    final c = st.aktiveKontakte.first.id;
    await tester.tap(find.textContaining(shortId(adresseFormatiert(c))).first, warnIfMissed: false);
    await warte(tester);
    expect(st.einstellungen.blockScreenshots, isTrue);
    expect(find.textContaining('Screenshot protection on'), findsNothing,
        reason: 'der Hinweis versprach einen Schutz, den es hier nicht gibt');

    kanalKann = true;
    await tester.runAsync(() => st.setzeEinstellungen(st.einstellungen.copyWith()));
    await warte(tester);
    expect(find.textContaining('Screenshot protection on'), findsOneWidget);
    await warte(tester, 2400);
  });

  testWidgets('IM ARCHIV GILT KEIN FILTER', (tester) async {
    await starte(tester);
    final c = st.aktiveKontakte.first.id;
    await tester.runAsync(() => st.setzeOrdnung(c, archiviert: true));
    await warte(tester);
    await tester.tap(find.byKey(const ValueKey('filter-ungelesen')));
    await warte(tester);
    await tester.tap(find.textContaining('ARCHIVED'));
    await warte(tester);
    expect(find.textContaining(shortId(adresseFormatiert(c))), findsOneWidget,
        reason: 'der unsichtbare Filter "ungelesen" leerte das Archiv');
  });

  testWidgets('DAS GESPEICHERTE THEMA ERNEUT WAEHLEN HOLT DIE ANZEIGE ZURUECK', (tester) async {
    await starte(tester);
    // Die Werkseinstellung, dunkel, also im Wanderkreis.
    const gespeichert = 'nocturne';
    expect(st.einstellungen.thema, gespeichert);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(anzeigeThema.value.id, gespeichert);
    // Wandern zieht die Anzeige weg, die Einstellung bleibt. In der Testzeit
    // gesetzt, nicht in runAsync — sonst liefe der Wecker in echter Zeit.
    unawaited(st.setzeEinstellungen(st.einstellungen.copyWith(themaWandern: 1)));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(minutes: 1));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(anzeigeThema.value.id, isNot(gespeichert));
    expect(st.einstellungen.thema, gespeichert);
    await tester.runAsync(() => st.setzeEinstellungen(st.einstellungen.copyWith(themaWandern: 0)));

    await zuDenEinstellungen(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('thema-$gespeichert')));
    await tester.tap(find.byKey(const ValueKey('thema-$gespeichert')));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(anzeigeThema.value.id, gespeichert, reason: 'das Antippen des gespeicherten Themas tat nichts');
    anzeigeThema.value = bauThemen().first;
  });
}
