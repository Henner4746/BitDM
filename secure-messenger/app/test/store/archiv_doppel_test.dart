// archiv_doppel_test.dart — Doppelkopien im Sitzungsarchiv, die aus
// bestehenden Datenbanken verschwinden muessen.
//
// libsignal_protocol_dart 0.8.2 liess beim Rueckfall auf einen archivierten
// Sitzungszustand eine bytegleiche Kopie der aktiven Sitzung im Archiv
// zurueck (das Entfernen lief auf ein neues Objekt und damit ins Leere). Die
// Kopie altert nicht mit: sie haelt Nachrichtenschluessel fest, die die
// aktive Sitzung laengst verbraucht hat. Sobald die aktive Sitzung einen
// wiederholten alten Umschlag nicht mehr als Duplikat erkennt, entschluesselt
// die Kopie ihn erneut — und wird dabei wieder zur aktiven Sitzung.
//
// Der eigene Stand der Bibliothek legt keine neuen mehr an
// (test/crypto/signal_bibliothek_test.dart). Wer BitDM schon benutzt, hat sie
// aber womoeglich in der Datei, und dort wirken sie weiter. Deshalb raeumt
// das Repository sie einmal je Datenbank weg.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  late Directory tmp;
  late DerivedKeys keys;
  late String pfad;
  var n = 0;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bitdm_archiv');
    keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    pfad = '${tmp.path}${Platform.pathSeparator}t${n++}.db';
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  /// Baut einen Record mit zwei archivierten Zustaenden.
  ///
  /// Mit [doppelt] ist der erste davon bytegleich mit der aktiven Sitzung —
  /// genau die Lage, die die alte Bibliothek hinterliess: eine Momentaufnahme
  /// der aktiven Sitzung im Archiv. Ohne [doppelt] sind beide echte alte
  /// Sitzungen.
  Uint8List recordMitDoppel({bool doppelt = true}) {
    // Ein Zustand mit Inhalt: aliceBaseKey unterscheidet die Zustaende, und
    // die Sitzungsfassung macht sie zu gueltigen Records.
    SessionState zustand(int marke) => SessionState()
      ..sessionVersion = 3
      ..aliceBaseKey = Uint8List.fromList(List<int>.filled(33, marke));

    // promoteState legt den bisherigen aktiven Zustand ins Archiv und macht
    // den uebergebenen zum neuen aktiven.
    final record = SessionRecord.fromSessionState(zustand(9))
      ..promoteState(zustand(1))
      ..promoteState(zustand(doppelt ? 1 : 2));
    return Uint8List.fromList(record.serialize());
  }

  int archivZahl(Uint8List bytes) =>
      SessionRecord.fromSerialized(bytes).previousSessionStates.length;

  test('eine bytegleiche Archivkopie wird entfernt, der Rest bleibt', () {
    final db = EncryptedDatabase.open(pfad, keys.databaseKey);
    addTearDown(db.close);
    final roh = recordMitDoppel();
    final vorher = archivZahl(roh);
    expect(vorher, 2, reason: 'ohne zwei Archiveintraege prueft der Test wenig');
    db.transaction((raw) => raw.execute(
        'INSERT INTO sessions (address, record) VALUES (?, ?)',
        ['abc', roh]));

    final entfernt = SignalStoreRepository(db).bereinigeArchivDoppel();

    expect(entfernt, 1);
    final nachher = db.raw
        .select('SELECT record FROM sessions WHERE address = ?', ['abc'])
        .first['record'] as Uint8List;
    expect(archivZahl(nachher), vorher - 1);
    // Die aktive Sitzung bleibt unberuehrt — es wird aufgeraeumt, nicht
    // zurueckgesetzt.
    expect(
        SessionRecord.fromSerialized(nachher).sessionState.serialize(),
        SessionRecord.fromSerialized(roh).sessionState.serialize());
  });

  test('ein Archiv ohne Doppelkopie bleibt, wie es ist', () {
    // Ein archivierter Zustand, der sich vom aktiven unterscheidet, ist eine
    // echte alte Sitzung. Die wird gebraucht, damit Nachrichten ankommen, die
    // vor einem Sitzungswechsel unterwegs waren.
    final db = EncryptedDatabase.open(pfad, keys.databaseKey);
    addTearDown(db.close);
    final roh = recordMitDoppel(doppelt: false);
    db.transaction((raw) => raw.execute(
        'INSERT INTO sessions (address, record) VALUES (?, ?)',
        ['abc', roh]));

    expect(SignalStoreRepository(db).bereinigeArchivDoppel(), 0);

    final nachher = db.raw
        .select('SELECT record FROM sessions WHERE address = ?', ['abc'])
        .first['record'] as Uint8List;
    expect(nachher, roh);
  });

  test('es laeuft nur einmal je Datenbank', () {
    // Nach dem Umstieg entstehen keine neuen Doppelkopien mehr. Ein zweiter
    // Lauf waere also nur Arbeit bei jedem Start.
    final db = EncryptedDatabase.open(pfad, keys.databaseKey);
    addTearDown(db.close);
    final repo = SignalStoreRepository(db);
    db.transaction((raw) => raw.execute(
        'INSERT INTO sessions (address, record) VALUES (?, ?)',
        ['abc', recordMitDoppel()]));

    expect(repo.bereinigeArchivDoppel(), 1);

    // Noch einmal dasselbe einspielen: der Merker haelt den zweiten Lauf an.
    db.transaction((raw) => raw.execute(
        'UPDATE sessions SET record = ? WHERE address = ?',
        [recordMitDoppel(), 'abc']));
    expect(repo.bereinigeArchivDoppel(), 0);
    expect(
        archivZahl(db.raw
            .select('SELECT record FROM sessions WHERE address = ?', ['abc'])
            .first['record'] as Uint8List),
        2);
  });

  test('eine leere Datenbank ueberlebt den Lauf', () {
    final db = EncryptedDatabase.open(pfad, keys.databaseKey);
    addTearDown(db.close);
    expect(SignalStoreRepository(db).bereinigeArchivDoppel(), 0);
  });
}
