// relay_vergessen_test.dart — der Relay hat dieses Geraet vergessen.
//
// Am 25.09.2026 im Emulator gefunden: der Relay kennt das Geraet nicht mehr
// (neue Datenbank, oder er hat es nach langer Funkstille aufgeraeumt) und
// schliesst die WebSocket mit 4401 "erst /register aufrufen". Die App hielt
// sich trotzdem fuer angemeldet (`relay_angemeldet_bei` stand noch da),
// meldete sich nie neu an und zeigte fuer immer "ohne Verbindung".

import 'dart:io';

import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_vergessen'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  test('VERGISST DER RELAY DAS GERAET, MELDET ES SICH BEIM NAECHSTEN VERSUCH NEU AN',
      () async {
    if (relay == null) return;
    final alice = Nutzer('alice', '${tmp.path}/alice.db', relay!.uri);
    addTearDown(alice.aufraeumen);
    await alice.starten();
    await alice.core.createIdentity();
    await alice.core.connect();
    expect(await Nutzer.warteBis(() => alice.core.connectionState == ConnectionState.online),
        isTrue, reason: 'Alice kam gar nicht erst online');
    final ich = alice.core.myId;

    await alice.core.disconnect();

    // Der Relay vergisst Alice — so, wie es das Aufraeumen vergessener
    // Geraete oder eine frische Datenbank tut.
    final db = '${relay!.datenverzeichnis.path}/relay.db'.replaceAll('\\', '/');
    final r = await Process.run('py', [
      '-3', '-c',
      'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); '
          'c.execute("DELETE FROM one_time_prekeys WHERE user_id=?", (sys.argv[2],)); '
          'c.execute("DELETE FROM identities WHERE user_id=?", (sys.argv[2],)); '
          'c.commit(); print(c.execute("SELECT COUNT(*) FROM identities WHERE user_id=?", (sys.argv[2],)).fetchone()[0])',
      db, ich,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect((r.stdout as String).trim(), '0');

    // Erster Versuch: der Relay sagt 4401. Das darf scheitern — aber es muss
    // den Vermerk "angemeldet" loeschen.
    await alice.core.connect();
    await Nutzer.warteBis(() => alice.core.connectionState != ConnectionState.connecting);

    // Der naechste Versuch (in der App der Wiederverbindungszeitgeber) meldet
    // sich neu an und kommt online.
    if (alice.core.connectionState != ConnectionState.online) {
      await alice.core.connect();
    }
    expect(
        await Nutzer.warteBis(() => alice.core.connectionState == ConnectionState.online),
        isTrue,
        reason: 'nach dem Vergessen kam Alice nie wieder online — keine Neuanmeldung');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
