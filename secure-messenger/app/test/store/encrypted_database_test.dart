// encrypted_database_test.dart — prueft die Datei selbst, nicht die API.
//
// Der wichtigste Test hier oeffnet die Datenbankdatei mit dart:io und sieht sie
// sich Byte fuer Byte an. Das ist Absicht: jeder Test, der die Verschluesselung
// ueber sqlite3 prueft, wuerde auch dann gruen bleiben, wenn ueberhaupt nicht
// verschluesselt wird — man bekaeme seine Daten ja zurueck. Nur die Rohbytes
// koennen den Unterschied zeigen.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Die ersten 16 Bytes jeder UNVERSCHLUESSELTEN SQLite-Datei.
const _sqliteKopf = 'SQLite format 3\x00';

Uint8List schluessel(int fuellwert) =>
    Uint8List.fromList(List.filled(32, fuellwert));

void main() {
  late Directory tmp;
  var zaehler = 0;

  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_db_test'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Dateihandles verzoegert frei; fuer den Test unerheblich.
    }
  });

  String neuerPfad() => '${tmp.path}/db${zaehler++}.db';

  String dateiAlsText(String pfad) =>
      String.fromCharCodes(File(pfad).readAsBytesSync());

  group('Die Datei ist wirklich verschluesselt', () {
    test('kein SQLite-Kopf und kein Klartext in der Datei', () {
      final pfad = neuerPfad();
      final db = EncryptedDatabase.open(pfad, schluessel(0x11));
      db.transaction((raw) {
        raw.execute('CREATE TABLE probe (t TEXT)');
        raw.execute("INSERT INTO probe VALUES ('MARKER_IM_KLARTEXT')");
      });
      db.close();

      final inhalt = dateiAlsText(pfad);
      expect(File(pfad).lengthSync(), greaterThan(0),
          reason: 'eine leere Datei wuerde diesen Test wertlos machen');
      expect(inhalt.startsWith(_sqliteKopf), isFalse,
          reason: 'die Datei traegt den Kopf einer unverschluesselten '
              'SQLite-Datenbank');
      expect(inhalt.contains('MARKER_IM_KLARTEXT'), isFalse);
      expect(inhalt.contains('CREATE TABLE probe'), isFalse,
          reason: 'auch das Schema darf nicht lesbar sein');
    });

    test('auch die WAL-Datei enthaelt keinen Klartext', () {
      // Frisch geschriebene Nachrichten liegen zuerst NUR in der WAL-Datei.
      // Waere die unverschluesselt, waere die Verschluesselung der Hauptdatei
      // fuer genau die neuesten Daten wirkungslos.
      final pfad = neuerPfad();
      final db = EncryptedDatabase.open(pfad, schluessel(0x22));
      db.transaction((raw) {
        raw.execute('CREATE TABLE probe (t TEXT)');
        final stmt = raw.prepare('INSERT INTO probe VALUES (?)');
        for (var i = 0; i < 300; i++) {
          stmt.execute(['WAL_MARKER_$i']);
        }
        stmt.close();
      });

      final wal = File('$pfad-wal');
      expect(wal.existsSync(), isTrue,
          reason: 'ohne WAL-Datei prueft dieser Test nichts');
      expect(wal.lengthSync(), greaterThan(0));
      expect(String.fromCharCodes(wal.readAsBytesSync()).contains('WAL_MARKER_'),
          isFalse);

      db.close();
    });

    test('ohne Schluessel laesst sich nichts lesen', () {
      final pfad = neuerPfad();
      final db = EncryptedDatabase.open(pfad, schluessel(0x33));
      db.transaction((raw) => raw.execute('CREATE TABLE probe (t TEXT)'));
      db.close();

      final roh = sqlite3.open(pfad);
      addTearDown(roh.close);
      expect(() => roh.select('SELECT name FROM sqlite_master'),
          throwsA(isA<SqliteException>()));
    });

    test('mit falschem Schluessel schlaegt das Oeffnen sofort fehl', () {
      final pfad = neuerPfad();
      EncryptedDatabase.open(pfad, schluessel(0x44)).close();

      expect(() => EncryptedDatabase.open(pfad, schluessel(0x45)),
          throwsA(isA<DatabaseUnlockException>()));
    });

    test('die Fehlermeldung enthaelt den Schluessel NICHT', () {
      // SqliteException haengt an jeden Fehler die ausloesende Anweisung an.
      // Bei `PRAGMA key = "x'...'"` waere das der Datenbankschluessel — in
      // einem Protokoll oder Absturzbericht.
      final pfad = neuerPfad();
      EncryptedDatabase.open(pfad, schluessel(0x44)).close();

      final falsch = schluessel(0xAB);
      final hexDesSchluessels = 'ab' * 32;

      // Der Wurf wird ausserhalb des try geprueft. Stuende `fail()` drin,
      // finge der nackte `catch (e)` die TestFailure wieder ein, und deren
      // Text enthaelt weder den Schluessel noch 'pragma key' — beide
      // Erwartungen gingen durch, obwohl gar nichts geworfen wurde.
      Object? geworfen;
      try {
        EncryptedDatabase.open(pfad, falsch);
      } catch (e) {
        geworfen = e;
      }
      expect(geworfen, isNotNull, reason: 'haette werfen muessen');
      expect('$geworfen'.toLowerCase(), isNot(contains(hexDesSchluessels)));
      expect('$geworfen'.toLowerCase(), isNot(contains('pragma key')));
    });
  });

  group('Das Verfahren ist festgenagelt', () {
    test('eine Datei mit anderem Verfahren wird nicht stillschweigend geoeffnet',
        () {
      // Belegt, warum `PRAGMA cipher` ausdruecklich gesetzt wird: aendert eine
      // kuenftige Fassung von sqlite3mc ihren Standard, muss das laut
      // scheitern und darf nicht in einer scheinbar leeren Datenbank enden.
      final pfad = neuerPfad();
      final hex = 'cd' * 32;
      final fremd = sqlite3.open(pfad);
      fremd.execute("PRAGMA cipher = 'aes256cbc'");
      fremd.execute('PRAGMA key = "x\'$hex\'"');
      fremd.execute('CREATE TABLE probe (t TEXT)');
      fremd.close();

      expect(() => EncryptedDatabase.open(pfad, schluessel(0xcd)),
          throwsA(isA<DatabaseUnlockException>()));
    });

    test('die geladene Bibliothek kann ueberhaupt verschluesseln', () {
      // Schlaegt dieser Test fehl, fehlt in pubspec.yaml der hooks-Block.
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      expect(db.select('PRAGMA cipher'), isNotEmpty);
      expect(db.select('PRAGMA gibtesnicht'), isEmpty,
          reason: 'unbekannte PRAGMAs liefern leer — darauf beruht die Pruefung');
    });
  });

  group('Grundeinstellungen', () {
    test('WAL, FULL, MEMORY, secure_delete sind gesetzt', () {
      final db = EncryptedDatabase.open(neuerPfad(), schluessel(0x55));
      addTearDown(db.close);
      expect(db.raw.select('PRAGMA journal_mode').first.values.first, 'wal');
      // synchronous: 2 = FULL, temp_store: 2 = MEMORY, secure_delete: 1 = ON
      expect(db.raw.select('PRAGMA synchronous').first.values.first, 2);
      expect(db.raw.select('PRAGMA temp_store').first.values.first, 2);
      expect(db.raw.select('PRAGMA secure_delete').first.values.first, 1);
    });

    test('das Schema wird angelegt und die Fassung vermerkt', () {
      final db = EncryptedDatabase.open(neuerPfad(), schluessel(0x66));
      addTearDown(db.close);
      final tabellen = db.raw
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'] as String)
          .toSet();
      expect(tabellen,
          containsAll(['meta', 'identities', 'pre_keys', 'signed_pre_keys', 'sessions']));
      expect(db.meta('schema_version'), '${EncryptedDatabase.schemaVersion}');
    });

    test('SCHRITT 6 SPERRT DIE LIEGENGEBLIEBENEN FUER DIE NAEHE', () {
      // Was vor dieser Stufe liegengeblieben ist, stammt aus einer Fassung, in
      // der der Nachversand ausschliesslich aus connect() heraus lief — es
      // wartet ohnehin auf den Relay, und moeglicherweise war es dort auch
      // schon. Mit der 0 duerfte die erste dieser Nachrichten nach dem Update
      // ueber die Naehe hinausgehen, obwohl sie drueben liegen kann. Von den
      // beiden Irrtuemern ist dieser der teure.
      //
      // NACHGESTELLT WIRD DIE ALTE DATEI, nicht bloss die Abfrage: Spalte weg,
      // Fassung zurueck auf 5. Genau so sieht die Datei einer bestehenden
      // Installation aus.
      const spalten = '(id, chat_id, sender_id, body, kind, is_mine, sent_at, '
          'status, ueber_naehe, schon_beim_relay)';
      final pfad = neuerPfad();
      final db = EncryptedDatabase.open(pfad, schluessel(0xA1));
      db.transaction((raw) {
        // status 0 = sending (liegengeblieben), 1 = sent (draussen).
        raw.execute('INSERT INTO messages $spalten '
            "VALUES ('liegt','A','A','x',0,1,0,0,0,0)");
        raw.execute('INSERT INTO messages $spalten '
            "VALUES ('raus','A','A','y',0,1,0,1,0,0)");
        raw.execute('INSERT INTO messages $spalten '
            "VALUES ('fremd','A','B','z',0,0,0,0,0,0)");
        raw.execute('ALTER TABLE messages DROP COLUMN schon_beim_relay');
        // BEIDE Spalten weg, nicht nur die von Schritt 6.
        //
        // Die Fassung geht auf 5 zurueck, also laeuft beim Wiederoeffnen auch
        // Schritt 7 noch einmal — und der legt `schon_in_der_naehe` an. Bleibt
        // sie stehen, scheitert die Wanderung an "duplicate column name", und
        // der Test misst das statt der Sache. Wer spaeter einen Schritt 8
        // anlegt, muss diese Zeile mitziehen.
        raw.execute('ALTER TABLE messages DROP COLUMN schon_in_der_naehe');
        raw.execute("UPDATE meta SET value = '5' WHERE key = 'schema_version'");
      });
      db.close();

      final wieder = EncryptedDatabase.open(pfad, schluessel(0xA1));
      addTearDown(wieder.close);
      int vermerk(String id) => wieder.raw
          .select('SELECT schon_beim_relay s FROM messages WHERE id = ?', [id])
          .first['s'] as int;

      expect(vermerk('liegt'), 1,
          reason: 'die wartet auf den Relay und kann dort schon liegen');
      expect(vermerk('raus'), 0,
          reason: 'sie ist durch — der Vermerk wuerde nie gelesen, und eine '
              'pauschale 1 verwischte, wovon er handelt');
      expect(vermerk('fremd'), 0,
          reason: 'eine EMPFANGENE Nachricht wird nie nachversandt');
    });

    test('eine Datei aus einer NEUEREN App-Fassung wird abgelehnt', () {
      final pfad = neuerPfad();
      final db = EncryptedDatabase.open(pfad, schluessel(0x77));
      db.transaction((raw) => raw.execute(
          "UPDATE meta SET value = '999' WHERE key = 'schema_version'"));
      db.close();

      expect(() => EncryptedDatabase.open(pfad, schluessel(0x77)),
          throwsA(isA<StateError>()));
    });
  });

  group('Transaktion', () {
    test('bei einem Fehler bleibt nichts stehen', () {
      final db = EncryptedDatabase.open(neuerPfad(), schluessel(0x88));
      addTearDown(db.close);
      db.transaction((raw) => raw.execute('CREATE TABLE t (a INTEGER)'));

      expect(
          () => db.transaction((raw) {
                raw.execute('INSERT INTO t VALUES (1)');
                throw StateError('mittendrin');
              }),
          throwsStateError);

      expect(db.raw.select('SELECT * FROM t'), isEmpty,
          reason: 'die halbe Transaktion haette zurueckgerollt werden muessen');
    });

    test('der Stand steigt nur bei Erfolg', () {
      final db = EncryptedDatabase.open(neuerPfad(), schluessel(0x99));
      addTearDown(db.close);
      final vorher = db.generation;

      db.transaction((raw) => raw.execute('CREATE TABLE t (a INTEGER)'));
      expect(db.generation, vorher + 1);

      try {
        db.transaction((raw) => throw StateError('nein'));
      } catch (_) {}
      expect(db.generation, vorher + 1, reason: 'ein Fehlschlag zaehlt nicht');
    });

    test('ein zweiter Schreiber mit veraltetem Zustand wird abgewiesen', () {
      // Das ist der Fall, den SQLites eigene Sperren NICHT abfangen: zwei
      // Isolate (App und Weckruf im Sparmodus) haben je einen eigenen Zustand
      // im Arbeitsspeicher. Ohne diesen Zaehler wuerde der zweite den ersten
      // ueberschreiben, ohne dass irgendetwas fehlschlaegt.
      final pfad = neuerPfad();
      final key = schluessel(0xAA);

      final a = EncryptedDatabase.open(pfad, key);
      a.transaction((raw) => raw.execute('CREATE TABLE t (a INTEGER)'));

      // Ein zweiter Verbinder, wie ihn ein anderes Isolate haette. Er umgeht
      // die Sperre gegen doppeltes Oeffnen bewusst, denn genau diese Sperre
      // wirkt zwischen Isolaten nicht.
      final b = sqlite3.open(pfad);
      addTearDown(b.close);
      b.execute("PRAGMA cipher = 'chacha20'");
      b.execute('PRAGMA key = "x\'${'aa' * 32}\'"');
      b.execute("UPDATE meta SET value = '99' WHERE key = 'generation'");

      expect(() => a.transaction((raw) => raw.execute('INSERT INTO t VALUES (1)')),
          throwsA(isA<StaleStateException>()));
      a.close();

      // Und die Aenderung ist nicht durchgekommen.
      expect(b.select('SELECT * FROM t'), isEmpty);
    });
  });

  test('dieselbe Datei laesst sich nicht zweimal oeffnen', () {
    final pfad = neuerPfad();
    final db = EncryptedDatabase.open(pfad, schluessel(0xBB));
    addTearDown(db.close);
    expect(() => EncryptedDatabase.open(pfad, schluessel(0xBB)),
        throwsStateError);
  });

  test('ein Schluessel mit falscher Laenge wird abgelehnt', () {
    expect(() => EncryptedDatabase.open(neuerPfad(), Uint8List(16)),
        throwsArgumentError);
  });
}
