// schema16_test.dart — der Vermerk "Kontakt muss BitDM aktualisieren"
// (Schema-Stufe 16, encrypted_database.dart `_schemaV16`).
//
// Die Stufe legt nur eine Spalte an: `contacts.braucht_neuere_app`. Gemessen
// wird, was dabei schiefgehen kann:
//
//  - Bestehende Kontakte muessen BLEIBEN, Spalte fuer Spalte, und bekommen die
//    0 — vor dem ersten Sendeversuch mit 2.0.0 weiss niemand, ob ein Kontakt
//    noch eine alte App hat.
//  - Die Stufe muss WIEDERHOLBAR sein ([_schemaV8]): eine Datei, deren Spalte
//    schon da ist, darf nicht an "duplicate column name" haengenbleiben.
//  - Die Ablage liest und schreibt den Vermerk, und `speichereKontakt` mit
//    einem anderen Feld wirft ihn nicht weg.
//  - Er geht NICHT in die Sicherung.
//
// NACHGESTELLT WIRD DIE ALTE DATEI wie in schema15_test.dart: eine Datenbank
// auf der aktuellen Stufe, die Spalte weg, die Fassung auf 15 zurueck.

import 'dart:io';
import 'dart:typed_data';

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

List<Map<String, Object?>> _kontakte(CommonDatabase db) => db
    .select('SELECT * FROM contacts ORDER BY address')
    .map((r) => {
          for (final k in r.keys)
            k: r[k] is Uint8List ? (r[k] as Uint8List).toList() : r[k]
        })
    .toList();

void main() {
  late Directory tmp;
  late DerivedKeys ich;
  var n = 0;

  setUpAll(() async {
    await signalBereit();
    ich = await KeyDerivation.fromMnemonic(Bip39.generate());
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_schema16'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });
  String neuerPfad() => '${tmp.path}/s16_${n++}.db';

  /// Zwei Kontakte in jeder Spalte, die es vor Stufe 16 gab.
  void legeKontakteAn(CommonDatabase raw) {
    raw.execute(
        'INSERT INTO contacts (address, display_name, added_at, state, verified, '
        'zeigt_anwesenheit, angeheftet, archiviert, stumm, frist, '
        'geraete_geprueft) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        ['bitdmaaaa', 'Anna mit Ümlaut', 1700000000000, 2, 1, 0, 1, 0, 1, 3600, 99]);
    raw.execute(
        'INSERT INTO contacts (address, display_name, added_at, state, verified) '
        'VALUES (?,?,?,?,?)',
        ['bitdmbbbb', null, 1700000000001, 0, 0]);
  }

  test('nach Stufe 16: jeder Kontakt unveraendert und mit der 0', () {
    final pfad = neuerPfad();
    final db0 = EncryptedDatabase.open(pfad, ich.databaseKey);
    db0.transaction((raw) {
      raw.execute('ALTER TABLE contacts DROP COLUMN braucht_neuere_app');
      legeKontakteAn(raw);
      raw.execute("UPDATE meta SET value = '15' WHERE key = 'schema_version'");
    });
    final vorher = _kontakte(db0.raw);
    expect(vorher, hasLength(2), reason: 'sonst vergleicht der Test leer');
    // DIE GEGENPROBE: die nachgestellte Datei hat die Spalte wirklich nicht.
    // Sonst bestuende der Test auch an einer Datei, die Stufe 16 nie sah.
    expect(_spalten(db0.raw, 'contacts'), isNot(contains('braucht_neuere_app')));
    db0.close();

    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(db.close);
    expect(db.meta('schema_version'), '16');
    expect(_kontakte(db.raw),
        [for (final k in vorher) {...k, 'braucht_neuere_app': 0}]);
  });

  test('ist die Spalte schon da, laeuft die Stufe trotzdem durch', () {
    // Eine Fassung dazwischen hat die Spalte angelegt, die Nummer aber nicht
    // erhoeht, oder ein Abbruch traf zwischen ALTER und COMMIT. Ohne die
    // Wiederholbarkeit liesse sich diese Datei nie wieder oeffnen.
    final pfad = neuerPfad();
    final db0 = EncryptedDatabase.open(pfad, ich.databaseKey);
    db0.transaction((raw) {
      legeKontakteAn(raw);
      raw.execute(
          "UPDATE contacts SET braucht_neuere_app = 1 WHERE address = 'bitdmaaaa'");
      raw.execute("UPDATE meta SET value = '15' WHERE key = 'schema_version'");
    });
    db0.close();

    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(db.close);
    expect(db.meta('schema_version'), '16');
    final zeile = db.raw.select(
        "SELECT braucht_neuere_app FROM contacts WHERE address = 'bitdmaaaa'");
    expect(zeile.first['braucht_neuere_app'], 1,
        reason: 'ein schon gesetzter Vermerk darf beim Wandern nicht fallen');
  });

  group('die Ablage', () {
    late EncryptedDatabase db;
    late ChatRepository ablage;

    setUp(() {
      db = EncryptedDatabase.open(neuerPfad(), ich.databaseKey);
      ablage = ChatRepository(db, SignalStoreRepository(db));
      ablage.speichereKontakt(Contact(
          id: 'bitdmaaaa',
          addedAt: DateTime.utc(2026, 10, 17),
          state: ContactState.active));
    });
    tearDown(() => db.close());

    test('setzt, liest und loescht den Vermerk — und sagt, ob er umsprang',
        () {
      expect(ablage.kontakt('bitdmaaaa')!.brauchtNeuereApp, isFalse);
      expect(ablage.setzeBrauchtNeuereApp('bitdmaaaa', true), isTrue);
      expect(ablage.kontakt('bitdmaaaa')!.brauchtNeuereApp, isTrue);
      expect(ablage.alleKontakte().single.brauchtNeuereApp, isTrue);

      final stand = db.generation;
      expect(ablage.setzeBrauchtNeuereApp('bitdmaaaa', true), isFalse,
          reason: 'ohne Wechsel kein Ereignis fuer die Oberflaeche');
      expect(db.generation, stand,
          reason: 'ohne Wechsel auch kein Schreibvorgang');

      expect(ablage.setzeBrauchtNeuereApp('bitdmaaaa', false), isTrue);
      expect(ablage.kontakt('bitdmaaaa')!.brauchtNeuereApp, isFalse);
    });

    test('eine Adresse ohne Kontakt aendert nichts', () {
      expect(ablage.setzeBrauchtNeuereApp('bitdmzzzz', true), isFalse);
      expect(ablage.kennt('bitdmzzzz'), isFalse,
          reason: 'der Vermerk darf keinen Kontakt anlegen');
    });

    test('speichereKontakt mit einem anderen Feld behaelt den Vermerk', () {
      ablage.setzeBrauchtNeuereApp('bitdmaaaa', true);
      ablage.speichereKontakt(
          ablage.kontakt('bitdmaaaa')!.copyWith(stumm: true));
      final k = ablage.kontakt('bitdmaaaa')!;
      expect(k.stumm, isTrue);
      expect(k.brauchtNeuereApp, isTrue,
          reason: 'Stummschalten ist kein Update der Gegenseite');
    });

    test('der Vermerk geht nicht in die Sicherung', () {
      // Eine wiederhergestellte Ablage hat keine wartenden Nachrichten mehr
      // (sicherung.dart macht sie zu "gescheitert"), und ob die Gegenseite
      // inzwischen aktualisiert hat, zeigt der naechste Sendeversuch.
      ablage.setzeBrauchtNeuereApp('bitdmaaaa', true);
      final kontakte =
          ablage.sicherungsInhalt()['kontakte']! as List<Map<String, Object?>>;
      expect(kontakte.single['address'], 'bitdmaaaa');
      expect(kontakte.single.containsKey('braucht_neuere_app'), isFalse);
    });
  });
}
