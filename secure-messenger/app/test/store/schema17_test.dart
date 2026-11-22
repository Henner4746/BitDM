// schema17_test.dart — die Aufnahmefassung je Gruppenmitglied
// (Schema-Stufe 17, encrypted_database.dart `_schemaV17`, QA-Bericht vom
// 18.11.2026, T1-GRP-003).
//
// Die Stufe legt nur eine Spalte an: `gruppen.aufgenommen`. Gemessen wird:
//
//  - Bestehende Gruppen BLEIBEN, Spalte fuer Spalte, und bekommen NULL —
//    wer vor der Stufe dazukam, gilt als Gruender (das bisherige Verhalten).
//  - Die Stufe ist WIEDERHOLBAR ([_schemaV8]).
//  - Die Ablage schreibt und liest die Angabe, und ein Speichern ohne sie
//    raeumt sie wieder weg.
//
// NACHGESTELLT WIRD DIE ALTE DATEI wie in schema16_test.dart.

import 'dart:io';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/store/chat_repository.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import '../support/signal_hilfe.dart';

Set<String> _spalten(CommonDatabase db, String tabelle) => db
    .select('PRAGMA table_info($tabelle)')
    .map((r) => r['name'] as String)
    .toSet();

List<Map<String, Object?>> _gruppen(CommonDatabase db) => db
    .select('SELECT * FROM gruppen ORDER BY id')
    .map((r) => {for (final k in r.keys) k: r[k]})
    .toList();

const _gid = 'g-CCCCCCCCCCCCCCCCCCCCCC';

void main() {
  late Directory tmp;
  late DerivedKeys ich;
  var n = 0;

  setUpAll(() async {
    await signalBereit();
    ich = await KeyDerivation.fromMnemonic(Bip39.generate());
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_schema17'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });
  String neuerPfad() => '${tmp.path}/s17_${n++}.db';

  void legeGruppeAn(CommonDatabase raw) {
    raw.execute(
        'INSERT INTO gruppen (id, name, admin, mitglieder, version, aktiv, '
        'angeheftet, archiviert, stumm, frist, angelegt, verlassen) '
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
        [_gid, 'Wanderung mit Ümlaut', 'bitdmaaaa', '["bitdmaaaa","bitdmbbbb"]',
         7, 0, 1, 0, 1, 3600, 1700000000000, 1]);
  }

  test('nach Stufe 17: jede Gruppe unveraendert und mit NULL', () {
    final pfad = neuerPfad();
    final db0 = EncryptedDatabase.open(pfad, ich.databaseKey);
    db0.transaction((raw) {
      raw.execute('ALTER TABLE gruppen DROP COLUMN aufgenommen');
      legeGruppeAn(raw);
      raw.execute("UPDATE meta SET value = '16' WHERE key = 'schema_version'");
    });
    final vorher = _gruppen(db0.raw);
    expect(vorher, hasLength(1), reason: 'sonst vergleicht der Test leer');
    expect(_spalten(db0.raw, 'gruppen'), isNot(contains('aufgenommen')));
    db0.close();

    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(db.close);
    expect(db.meta('schema_version'), '17');
    expect(_gruppen(db.raw), [for (final g in vorher) {...g, 'aufgenommen': null}]);
    final g = ChatRepository(db, SignalStoreRepository(db)).gruppe(_gid)!;
    expect(g.aufgenommen, isEmpty);
    expect(g.verlassen, isTrue, reason: 'die alte Spalte darf nicht verlorengehen');
    expect(g.version, 7);
  });

  test('ist die Spalte schon da, laeuft die Stufe trotzdem durch', () {
    final pfad = neuerPfad();
    final db0 = EncryptedDatabase.open(pfad, ich.databaseKey);
    db0.transaction((raw) {
      legeGruppeAn(raw);
      raw.execute("UPDATE gruppen SET aufgenommen = '{\"bitdmbbbb\":5}'");
      raw.execute("UPDATE meta SET value = '16' WHERE key = 'schema_version'");
    });
    db0.close();

    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(db.close);
    expect(db.meta('schema_version'), '17');
    expect(ChatRepository(db, SignalStoreRepository(db)).gruppe(_gid)!.aufgenommen,
        {'bitdmbbbb': 5});
  });

  test('die Ablage schreibt, liest und raeumt die Aufnahmefassung', () {
    final db = EncryptedDatabase.open(neuerPfad(), ich.databaseKey);
    addTearDown(db.close);
    final ablage = ChatRepository(db, SignalStoreRepository(db));
    const g = Gruppe(
        id: _gid,
        name: 'G',
        admin: 'bitdmaaaa',
        mitglieder: ['bitdmaaaa', 'bitdmbbbb'],
        version: 3,
        aufgenommen: {'bitdmbbbb': 3});
    ablage.speichereGruppe(g);
    expect(ablage.gruppe(_gid)!.aufgenommen, {'bitdmbbbb': 3});
    expect(ablage.alleGruppen().single.aufgenommen, {'bitdmbbbb': 3});

    ablage.speichereGruppe(g.copyWith(aufgenommen: const {}));
    expect(ablage.gruppe(_gid)!.aufgenommen, isEmpty);
    expect(db.raw.select('SELECT aufgenommen FROM gruppen').first['aufgenommen'],
        isNull, reason: 'leer heisst NULL, wie bei einer Zeile vor der Stufe');
  });

  test('eine kaputte Angabe in der Datei gilt als leer', () {
    final db = EncryptedDatabase.open(neuerPfad(), ich.databaseKey);
    addTearDown(db.close);
    db.transaction((raw) {
      legeGruppeAn(raw);
      raw.execute("UPDATE gruppen SET aufgenommen = 'kein json'");
    });
    expect(ChatRepository(db, SignalStoreRepository(db)).gruppe(_gid)!.aufgenommen,
        isEmpty);
  });
}
