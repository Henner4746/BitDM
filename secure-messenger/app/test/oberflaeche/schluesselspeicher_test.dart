// schluesselspeicher_test.dart — Start mit gesperrtem Schluesselbund.
//
// GEFUNDEN beim ersten echten Linux-Lauf (17.10.2026, Debian 13 unter Xvfb,
// ohne entsperrten GNOME Keyring): flutter_secure_storage meldete
// `KeyringLocked`, daraus wurde eine unbehandelte StorageException
// (DeviceSecretStore.read ← RealMessengerCore.initialize ← AppState.boot ←
// _HomeState.initState), und das Fenster blieb dauerhaft leer, ohne ein Wort.
//
// Die ersten Faelle fahren dieselbe Kette: der Kanal des Plugins antwortet mit
// dem Fehler, den flutter_secure_storage_linux 3.0.1 bei gesperrtem oder
// fehlendem Schluesselbund schickt (flutter_secure_storage_linux_plugin.cc:
// 154-155, Code "KeyringLocked"), und darueber liegen die echten
// DeviceSecretStore, VaultSecretStore, RealMessengerCore und AppState.

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/data.dart';
import 'package:bitdm/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _kanal = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// Was flutter_secure_storage_linux bei gesperrtem Schluesselbund schickt.
PlatformException _gesperrt() =>
    PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');

/// Ein Kern, dessen Schluesselspeicher zu ist, bis [zu] false wird — fuer die
/// Faelle, in denen es auf die Datenbank dahinter nicht ankommt.
class _ZuerKern extends FakeMessengerCore {
  bool zu = true;
  int angelegt = 0;
  int wiederhergestellt = 0;

  @override
  Future<bool> initialize() async {
    if (zu) {
      throw const SchluesselspeicherException(
          'Schluesselspeicher nicht lesbar (PlatformException)');
    }
    return super.initialize();
  }

  @override
  Future<List<String>> createIdentity() {
    angelegt++;
    return super.createIdentity();
  }

  @override
  Future<String> restoreIdentity(List<String> words) {
    wiederhergestellt++;
    return super.restoreIdentity(words);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Jede Methode, mit der der Kanal gerufen wurde.
  final aufrufe = <String>[];

  /// Ob der Schluesselbund zu ist. Offen liefert er [inhalt] (null = leer).
  var zu = true;
  String? inhalt;

  setUp(() {
    aufrufe.clear();
    zu = true;
    inhalt = null;
    final bote = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    bote.setMockMethodCallHandler(_kanal, (c) async {
      aufrufe.add(c.method);
      if (zu) throw _gesperrt();
      return switch (c.method) {
        'read' => inhalt,
        'containsKey' => inhalt != null,
        _ => null,
      };
    });
    bote.setMockMethodCallHandler(
        const MethodChannel('bitdm/fenster'), (_) async => true);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final bote = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    bote.setMockMethodCallHandler(_kanal, null);
    bote.setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
  });

  /// Die echte Kette aus main.dart, nur mit Pfaden im Temp-Ordner und einem
  /// Relay, den es nicht gibt (er wird in keinem Fall erreicht).
  (AppState, Directory) echteKette() {
    final ordner = Directory.systemTemp.createTempSync('bitdm-schluesselbund');
    final tresor = VaultSecretStore(
      datei: vaultDateiIn(ordner.path),
      basis: DeviceSecretStore(),
      jetzt: () => 1000,
    );
    final kern = RealMessengerCore(
      secretStore: tresor,
      databasePath: '${ordner.path}/bitdm.db',
      relayUri: Uri.parse('http://127.0.0.1:9'),
    );
    return (AppState(kern, tresor: tresor), ordner);
  }

  void raeumeWeg(AppState st, Directory ordner) {
    st.dispose();
    try {
      ordner.deleteSync(recursive: true);
    } catch (_) {}
  }

  Future<void> warte(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(Duration(milliseconds: ms ~/ 2));
    }
  }

  final en = strings['en']!;
  Finder meldung() => find.byKey(const ValueKey('schluesselspeicher-zu'));
  Finder knopf(String k) => find.text(en[k]!.toUpperCase());

  group('DeviceSecretStore', () {
    test('GESPERRT ist nicht dasselbe wie KAPUTT', () async {
      final speicher = DeviceSecretStore();
      await expectLater(speicher.read(), throwsA(isA<SchluesselspeicherException>()));
      await expectLater(speicher.write(Uint8List(16)), throwsA(isA<SchluesselspeicherException>()));
      await expectLater(speicher.delete(), throwsA(isA<SchluesselspeicherException>()));

      // Unsinn im offenen Speicher ist eine beschaedigte Identitaet — und
      // gerade KEIN gesperrter Schluesselbund. Bis 17.10.2026 fing ein
      // gemeinsames catch beides.
      zu = false;
      inhalt = 'kein base64 ###';
      await expectLater(
          speicher.read(),
          throwsA(allOf(isA<StorageException>(),
              isNot(isA<SchluesselspeicherException>()))));
      inhalt = base64.encode(List.filled(8, 1));
      await expectLater(
          speicher.read(),
          throwsA(allOf(isA<StorageException>(),
              isNot(isA<SchluesselspeicherException>()))));
      inhalt = base64.encode(List.filled(16, 1));
      expect(await speicher.read(), List.filled(16, 1));
    });

    test('die Meldung traegt nichts aus dem Plugin weiter', () async {
      final speicher = DeviceSecretStore();
      try {
        await speicher.read();
        fail('haette werfen muessen');
      } on SchluesselspeicherException catch (e) {
        expect(e.message, isNot(contains('KeyringLocked')));
        expect(e.message, contains('PlatformException'));
      }
    });
  });

  test('BOOT MIT GESPERRTEM SCHLUESSELBUND: kein Wurf, nicht bereit, nichts geschrieben', () async {
    final (st, ordner) = echteKette();
    addTearDown(() => raeumeWeg(st, ordner));

    await st.boot();

    expect(st.schluesselspeicherZu, isTrue);
    expect(st.bereit, isFalse,
        reason: 'bereit hiesse Onboarding — als gaebe es keine Identitaet');
    expect(st.hatIdentitaet, isFalse);
    expect(st.startetGerade, isFalse);
    expect(aufrufe, isNotEmpty, reason: 'der Schluesselbund wurde gar nicht gefragt');
    expect(aufrufe, everyElement('read'),
        reason: 'bei gesperrtem Speicher wird nur gelesen — nichts geschrieben, nichts geloescht');
    expect(File('${ordner.path}/bitdm.db').existsSync(), isFalse,
        reason: 'ohne Schluessel wird keine Datenbank angelegt');

    // Schluesselbund entsperrt, und er ist leer: jetzt erst ist klar, dass
    // es keine Identitaet gibt.
    zu = false;
    await st.boot();
    expect(st.schluesselspeicherZu, isFalse);
    expect(st.bereit, isTrue);
    expect(st.hatIdentitaet, isFalse);
  });

  test('ZWEI AUFRUFE AUF EINMAL teilen sich einen Lauf', () async {
    final kern = _ZuerKern();
    final st = AppState(kern);
    addTearDown(st.dispose);
    final a = st.boot();
    final b = st.boot();
    expect(identical(a, b), isTrue);
    expect(st.startetGerade, isTrue);
    await a;
    expect(st.startetGerade, isFalse);
  });

  testWidgets('UNTER LINUX: Meldung mit GNOME Keyring und KWallet, Erneut versuchen fuehrt zum Onboarding',
      (tester) async {
    final (st, ordner) = echteKette();
    addTearDown(() => raeumeWeg(st, ordner));
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await warte(tester);

    expect(meldung(), findsOneWidget);
    expect(find.text(en['keyStoreTitle']!.toUpperCase()), findsOneWidget);
    expect(find.text(en['keyStoreLinux']!), findsOneWidget);
    expect(find.text(en['keyStoreSafe']!), findsOneWidget);
    // Kein Onboarding: weder Anlegen noch Wiederherstellen.
    expect(knopf('create'), findsNothing);
    expect(find.text(en['restoreLink']!.toUpperCase()), findsNothing);
    expect(find.text(en['restoreLink']!), findsNothing);

    // Noch zu: es bleibt bei der Meldung, und weiter wird nur gelesen.
    await tester.tap(knopf('keyStoreRetry'));
    await warte(tester);
    expect(meldung(), findsOneWidget);
    expect(knopf('keyStoreRetry'), findsOneWidget, reason: 'der Knopf muss wieder bedienbar sein');
    expect(aufrufe, everyElement('read'));

    // Entsperrt und leer: jetzt das Onboarding.
    zu = false;
    await tester.tap(knopf('keyStoreRetry'));
    await warte(tester);
    expect(meldung(), findsNothing);
    expect(knopf('create'), findsOneWidget);
    expect(aufrufe, everyElement('read'));

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('MIT IDENTITAET: nach dem Entsperren die Chatliste, ohne dass etwas angelegt wurde',
      (tester) async {
    final kern = _ZuerKern()..simulateExistingIdentity = true;
    final st = AppState(kern);
    addTearDown(st.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() => st.boot());
    await tester.pumpWidget(BitApp(state: st));
    await warte(tester);

    // Android (die Vorgabe im Widget-Test): ohne Schluesselbund-Namen.
    expect(meldung(), findsOneWidget);
    expect(find.text(en['keyStoreOther']!), findsOneWidget);
    expect(find.text(en['keyStoreLinux']!), findsNothing);
    expect(find.text('CHATS'), findsNothing, reason: 'keine Leiste, solange nichts offen ist');

    kern.zu = false;
    await tester.tap(knopf('keyStoreRetry'));
    await warte(tester, 800);

    expect(meldung(), findsNothing);
    expect(st.hatIdentitaet, isTrue);
    expect(st.bereit, isTrue);
    expect(find.text('CHATS'), findsWidgets);
    expect(kern.angelegt, 0);
    expect(kern.wiederhergestellt, 0);
  });
}
