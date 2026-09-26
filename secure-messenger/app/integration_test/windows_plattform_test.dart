// windows_plattform_test.dart — BitDM auf dem echten Windows, nicht in der Test-VM.
//
// Seit 26.09.2026. Die ~1250 Tests unter test/ laufen in der Dart-VM ohne
// Plattformkanaele: kein Windows-Schluesselspeicher, keine
// Screenshot-Sperre, kein echtes Fenster. Dieser Lauf startet die App als
// richtiges Windows-Programm und prueft genau das, was nur dort existiert —
// plus den Weg Nachricht/Anhang/Gruppe/Sperre mit zwei echten Kernen gegen
// einen lokalen Relay.
//
// Vorher starten (liefert Relay 127.0.0.1:8080 und Zwischenlager :8099):
//   cd ../server/tools && py testaufbau.py   (Port: BITDM_TEST_RELAY_PORT)
// Dann:
//   flutter test integration_test/windows_plattform_test.dart -d windows
//     [--dart-define=BITDM_TEST_RELAY=http://127.0.0.1:<port>]

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/fenster.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/main.dart' show BitApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Verschiebbar mit --dart-define=BITDM_TEST_RELAY=... (8080 ist manchmal belegt).
final _relay = Uri.parse(const String.fromEnvironment('BITDM_TEST_RELAY', defaultValue: 'http://127.0.0.1:8080'));
final _lager = Uri.parse(const String.fromEnvironment('BITDM_TEST_LAGER', defaultValue: 'http://127.0.0.1:8099'));

Future<bool> warteBis(bool Function() b, {int sekunden = 30}) async {
  final ende = DateTime.now().add(Duration(seconds: sekunden));
  while (DateTime.now().isBefore(ende)) {
    if (b()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return b();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory ordner;
  setUpAll(() async {
    final basis = await getApplicationSupportDirectory();
    ordner = Directory('${basis.path}${Platform.pathSeparator}itest-${DateTime.now().millisecondsSinceEpoch}')
      ..createSync(recursive: true);
  });
  tearDownAll(() {
    try {
      ordner.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('SCREENSHOT-SPERRE: der Windows-Kanal setzt sie wirklich', () async {
    expect(await Fenster.screenshotSperre(true), isTrue,
        reason: 'SetWindowDisplayAffinity hat nicht gegriffen (flutter_window.cpp)');
    expect(await Fenster.screenshotSperre(false), isFalse);
  });

  test('SCHLUESSELSPEICHER: Windows-Anmeldeinformationen, hin und zurueck', () async {
    final s = DeviceSecretStore();
    final vorher = await s.read();
    final probe = Uint8List.fromList(List.generate(16, (i) => i * 7 % 256));
    try {
      await s.write(probe);
      expect(await s.read(), probe);
    } finally {
      // Nichts Fremdes zuruecklassen und nichts Vorhandenes zerstoeren.
      if (vorher != null) {
        await s.write(vorher);
      } else {
        await s.delete();
      }
    }
  });

  test('ZWEI KERNE: Kontakt, Nachricht, Quittung, Anhang, Gruppe', () async {
    RealMessengerCore kern(String name) => RealMessengerCore(
          secretStore: InMemorySecretStore(),
          databasePath: '${ordner.path}${Platform.pathSeparator}$name.db',
          relayUri: _relay,
          lagerUri: _lager,
        );
    final anna = kern('anna'), ben = kern('ben');
    addTearDown(anna.dispose);
    addTearDown(ben.dispose);
    final beiBen = <Message>[], beiAnna = <Message>[];
    final kontaktBen = <ContactEvent>[], kontaktAnna = <ContactEvent>[];
    final statusAnna = <MessageStatusUpdate>[];
    ben.incomingMessages.listen(beiBen.add);
    anna.incomingMessages.listen(beiAnna.add);
    ben.contactEvents.listen(kontaktBen.add);
    anna.contactEvents.listen(kontaktAnna.add);
    anna.messageStatusUpdates.listen(statusAnna.add);

    await anna.initialize();
    await ben.initialize();
    await anna.createIdentity();
    await ben.createIdentity();
    await anna.connect();
    await ben.connect();
    expect(anna.connectionState, ConnectionState.online,
        reason: 'lokaler Relay laeuft nicht — erst testaufbau.py starten');

    await anna.addContact(ben.myId);
    expect(await warteBis(() => kontaktBen.any((e) => e.type == ContactEventType.incomingRequest)), isTrue);
    await ben.acceptRequest(anna.myId);
    expect(await warteBis(() => kontaktAnna.any((e) => e.type == ContactEventType.requestAccepted)), isTrue);

    final m = await anna.sendMessage(ben.myId, 'Hallo von Windows');
    expect(await warteBis(() => beiBen.any((x) => x.id == m.id)), isTrue);
    expect(await warteBis(() => statusAnna.any((s) => s.messageId == m.id && s.status.index >= MessageStatus.delivered.index)),
        isTrue, reason: 'keine Zustellquittung');
    final antwort = await ben.sendMessage(anna.myId, 'Antwort');
    expect(await warteBis(() => beiAnna.any((x) => x.id == antwort.id)), isTrue);

    // Anhang: eine Datei auf der Windows-Platte, verschickt, geholt,
    // entschluesselt — und im Anhangordner NICHT im Klartext.
    final inhalt = Uint8List.fromList(List.generate(300000, (i) => (i * 31) % 251));
    final quelle = File('${ordner.path}${Platform.pathSeparator}quelle.bin')..writeAsBytesSync(inhalt);
    final vorher = beiBen.length;
    await anna.sendeAnhang(ben.myId, quelle);
    expect(await warteBis(() => beiBen.length > vorher), isTrue, reason: 'Anhang kam nicht an');
    final ankuendigung = beiBen.last;
    final geholt = await ben.holeAnhang(anna.myId, ankuendigung.id);
    final roh = await File(geholt.pfad!).readAsBytes();
    expect(_enthaelt(roh, inhalt.sublist(1000, 1064)), isFalse,
        reason: 'der Anhang liegt im Klartext auf der Platte');
    final klar = await ben.entschluesselterAnhang(anna.myId, ankuendigung.id);
    expect(await klar.readAsBytes(), inhalt);
    await ben.gibAnhangFrei(klar);

    // Gruppe mit beiden.
    final g = await anna.legeGruppeAn('Windows-Test', [ben.myId]);
    var benKenntSie = false;
    for (var i = 0; i < 100 && !benKenntSie; i++) {
      benKenntSie = (await ben.getGruppen()).any((x) => x.id == g.id);
      if (!benKenntSie) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(benKenntSie, isTrue, reason: 'Ben kennt die Gruppe nicht');
    final gm = await anna.sendMessage(g.id, 'an die Gruppe');
    expect(await warteBis(() => beiBen.any((x) => x.id == gm.id)), isTrue, reason: 'Gruppennachricht fehlt');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('NEU IN 1.9: Fernloesch-Codewort und Update-Hinweis mit drei Kernen', () async {
    RealMessengerCore kern(String name) => RealMessengerCore(
          secretStore: InMemorySecretStore(),
          databasePath: '${ordner.path}${Platform.pathSeparator}$name-19.db',
          relayUri: _relay,
          lagerUri: _lager,
        );
    final ben = kern('ben'), anna = kern('anna'), carl = kern('carl');
    for (final k in [ben, anna, carl]) {
      addTearDown(k.dispose);
      await k.initialize();
      await k.createIdentity();
      await k.connect();
    }
    final beiBen = <Message>[];
    ben.incomingMessages.listen(beiBen.add);
    final ausgeloest = <Fernloeschung>[];
    ben.fernloeschungAusgeloest.listen(ausgeloest.add);

    Future<void> befreunde(RealMessengerCore von) async {
      final anfragen = <ContactEvent>[];
      final sub = ben.contactEvents.listen(anfragen.add);
      await von.addContact(ben.myId);
      expect(await warteBis(() => anfragen.any((e) => e.type == ContactEventType.incomingRequest)), isTrue);
      await ben.acceptRequest(von.myId);
      await sub.cancel();
      await Future<void>.delayed(const Duration(seconds: 2)); // Annahme ankommen lassen
    }

    await befreunde(anna);
    await befreunde(carl);
    await ben.setzeFernloeschung(Fernloeschung(an: true, schwelle: 2, vertraute: [anna.myId, carl.myId]));
    await ben.setzeFernCodewort('Rote Katze im Schnee');

    // Update-Hinweis: der Relay nennt die neueste Fassung bei der Anmeldung.
    const erwartet = String.fromEnvironment('BITDM_TEST_NEUESTE');
    if (erwartet.isNotEmpty) {
      expect(await warteBis(() => ben.neuesteFassung == erwartet), isTrue,
          reason: 'auth_result ohne "neueste" (BITDM_NEUESTE_FASSUNG am Relay?)');
    }

    // Eine gewoehnliche Nachricht von Anna kommt an ...
    final normal = await anna.sendMessage(ben.myId, 'ganz normal');
    expect(await warteBis(() => beiBen.any((x) => x.id == normal.id)), isTrue);

    // ... das Codewort (anders geschrieben) nicht, und zaehlt als Anfrage.
    final w1 = await anna.sendMessage(ben.myId, '  rote KATZE im   schnee ');
    var anfragen = 0;
    for (var i = 0; i < 100 && anfragen < 1; i++) {
      anfragen = (await ben.getFernloeschung()).anfragen.length;
      if (anfragen < 1) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(anfragen, 1, reason: 'das Codewort zaehlte nicht als Loeschanfrage');
    expect(ausgeloest, isEmpty, reason: 'eine Stimme darf bei k=2 nichts ausloesen');

    // Die zweite Vertraute: jetzt ist die Loeschung geplant.
    final w2 = await carl.sendMessage(ben.myId, 'Rote Katze im Schnee');
    expect(await warteBis(() => ausgeloest.isNotEmpty), isTrue, reason: 'zwei Stimmen loesten nicht aus');
    expect((await ben.getFernloeschung()).faellig, isNotNull);
    expect(beiBen.any((x) => x.id == w1.id || x.id == w2.id), isFalse,
        reason: 'das Codewort erschien als Nachricht');
    final verlauf = [...await ben.getMessages(anna.myId), ...await ben.getMessages(carl.myId)];
    expect(verlauf.any((x) => x.text.toLowerCase().contains('katze')), isFalse,
        reason: 'das Codewort steht im Verlauf');

    // Abbrechen, damit nichts geloescht wird.
    final f = await ben.getFernloeschung();
    await ben.setzeFernloeschung(f.copyWith(anfragen: const {}, ohneFaellig: true));
    expect((await ben.getFernloeschung()).faellig, isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('OBERFLAECHE: Start, Identitaet erstellen, Passwort-Sperre', (tester) async {
    // Wie in main.dart: der Kern liest seine Entropie DURCH den Tresor.
    final tresor = VaultSecretStore(
      datei: vaultDateiIn(ordner.path),
      basis: InMemorySecretStore(),
      jetzt: () => DateTime.now().millisecondsSinceEpoch,
    );
    final kern = RealMessengerCore(
      secretStore: tresor,
      databasePath: '${ordner.path}${Platform.pathSeparator}ui.db',
      relayUri: _relay,
      lagerUri: _lager,
    );
    final st = AppState(kern, tresor: tresor)..verbindungImHintergrund = true;
    await tester.pumpWidget(BitApp(state: st));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final erstellen = find.textContaining(RegExp(r'Identität erstellen|Create identity', caseSensitive: false));
    expect(erstellen, findsWidgets, reason: 'Startbildschirm ohne "Identitaet erstellen"');
    await tester.tap(erstellen.first);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(st.hatIdentitaet, isTrue);
    expect(st.frischePhrase, isNotNull, reason: 'die zwoelf Woerter wurden nicht gezeigt');

    // Passwort-Sperre auf Windows: Argon2id, sperren, wieder oeffnen.
    await st.fuegePasswortHinzu('windows-probe-9431');
    await st.sperreWieder();
    expect(st.gesperrt, isTrue);
    await expectLater(st.entsperreMitPasswort('falsch-falsch'), throwsA(isA<UnlockFailedException>()));
    expect(st.gesperrt, isTrue);
    expect(await st.entsperreMitPasswort('windows-probe-9431'), isTrue);
    expect(st.gesperrt, isFalse);

    // Panik-Wort (neu in 1.9: ein Satz mit Leerzeichen, keine Staerkeprobe).
    // Am Sperrbildschirm eingegeben, loescht es still alles.
    await st.setzePanikPasswort('mir ist kalt');
    await st.sperreWieder();
    expect(await st.entsperreMitPasswort('mir ist kalt'), isFalse);
    expect(st.gesperrt, isFalse);
    expect(st.hatIdentitaet, isFalse, reason: 'das Panik-Wort hat nicht geloescht');
    await kern.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

bool _enthaelt(Uint8List heu, List<int> nadel) {
  outer:
  for (var i = 0; i + nadel.length <= heu.length; i++) {
    for (var j = 0; j < nadel.length; j++) {
      if (heu[i + j] != nadel[j]) continue outer;
    }
    return true;
  }
  return false;
}
