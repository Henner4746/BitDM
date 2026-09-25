// encrypted_database.dart — die verschluesselte lokale Datenbank.
//
// Alles, was BitDM auf dem Geraet behaelt, liegt in dieser einen Datei:
// Sitzungen, Prekeys, Identitaeten und spaeter die Nachrichten selbst. Die
// Datei ist als Ganzes verschluesselt, nicht bloss ihre Inhalte — wer sie in
// die Hand bekommt, sieht nicht einmal, wie viele Kontakte es gibt.
//
// Der Schluessel kommt NICHT aus einem Passwort, sondern aus der Seed-Phrase
// (KeyDerivation, Label "bitdm database key v1"). Er hat volle Entropie.
// Deshalb wird er als Rohschluessel uebergeben und nicht durch eine
// Schluesselableitung geschickt: eine KDF haerten nur schwache Eingaben, und
// wir haben keine schwache Eingabe. Gemessen macht das beim Oeffnen den
// Unterschied zwischen 27 ms und 0,8 ms — auf einem Telefon bei jedem
// Kaltstart.

// KEIN dart:io und KEIN package:sqlite3/sqlite3.dart. Beides gibt es im
// Browser nicht — der ffi-Import bricht schon den Bau, der File-Konstruktor
// erst zur Laufzeit. Was plattformabhaengig ist, steht in sqlite_zugang.dart
// und ist dort begruendet: sqliteLaufzeit, absoluterPfad, journalModus.
import 'dart:typed_data';

import 'package:sqlite3/common.dart';

import 'sqlite_zugang.dart';

/// Wird geworfen, wenn die geladene SQLite-Bibliothek gar nicht verschluesseln
/// kann.
///
/// Das ist der gefaehrlichste denkbare Fehler dieser Datei, weil er sich
/// ANDERNFALLS NICHT BEMERKBAR MACHT: gewoehnliches SQLite ignoriert unbekannte
/// PRAGMAs stillschweigend. `PRAGMA key` liefe ohne Fehler durch, jede Abfrage
/// funktionierte, und die Datenbank laege im Klartext auf dem Geraet.
class DatabaseNotEncryptedException implements Exception {
  const DatabaseNotEncryptedException();
  @override
  String toString() => 'DatabaseNotEncryptedException: die geladene '
      'SQLite-Bibliothek kennt keine Verschluesselung (PRAGMA cipher leer). '
      'Steht in pubspec.yaml unter hooks/user_defines/sqlite3 noch '
      'source: sqlite3mc?';
}

/// Wird geworfen, wenn sich die Datenbank nicht aufschliessen laesst.
///
/// Bewusst ohne die urspruengliche Meldung: SqliteException haengt an jeden
/// Fehler die ausloesende Anweisung an — und die ausloesende Anweisung ist hier
/// `PRAGMA key = "x'...'"`. Diese Meldung landet sonst in Protokollen und
/// Absturzberichten und traegt den Datenbankschluessel mit sich.
class DatabaseUnlockException implements Exception {
  final String hinweis;
  const DatabaseUnlockException(this.hinweis);
  @override
  String toString() => 'DatabaseUnlockException: $hinweis';
}

/// Wird geworfen, wenn seit dem Laden jemand anderes geschrieben hat.
///
/// Siehe [EncryptedDatabase.transaction]. Der Fall ist kein Sperrkonflikt —
/// SQLite regelt Sperren selbst — sondern ein Zustand im Arbeitsspeicher, der
/// nicht mehr zur Datei passt.
class StaleStateException implements Exception {
  final int erwartet;
  final int gefunden;
  const StaleStateException(this.erwartet, this.gefunden);
  @override
  String toString() => 'StaleStateException: erwartete Stand $erwartet, '
      'gefunden $gefunden — der Zustand im Arbeitsspeicher ist veraltet';
}

class EncryptedDatabase {
  EncryptedDatabase._(this._db, this.pfad, this._generation);

  final CommonDatabase _db;
  final String pfad;
  int _generation;

  /// Aktueller Schreibstand der Datei. Siehe [transaction].
  int get generation => _generation;

  CommonDatabase get raw => _db;

  /// Aktuelle Fassung des Schemas. Wird bei jeder Aenderung erhoeht.
  static const int schemaVersion = 13;

  /// Verhindert, dass dieselbe Datei im selben Isolate zweimal offen ist.
  ///
  /// Gegen ZWEI Isolate hilft das nicht — die teilen keinen Speicher. Dafuer
  /// ist der Standzaehler in [transaction] da.
  static final Set<String> _offen = <String>{};

  /// Oeffnet die Datenbank und schliesst sie mit [databaseKey] auf.
  ///
  /// [databaseKey] sind die 32 Bytes aus KeyDerivation. Eine Passphrase ist
  /// hier nicht vorgesehen.
  static EncryptedDatabase open(String pfad, Uint8List databaseKey) {
    if (databaseKey.length != 32) {
      throw ArgumentError('Datenbankschluessel muss 32 Bytes haben, '
          'hat ${databaseKey.length}');
    }
    final absolut = absoluterPfad(pfad);
    if (!_offen.add(absolut)) {
      throw StateError('Datenbank ist in diesem Isolate bereits offen: $absolut');
    }

    CommonDatabase? db;
    try {
      // Im Browser wirft das einen StateError, wenn sqliteVorbereiten() nicht
      // abgewartet wurde. Auf der VM ist sqliteVorbereiten() ein leerer Future
      // und diese Zeile dieselbe wie vorher.
      db = sqliteLaufzeit.open(pfad);

      // Der Verschluesselungsteil MUSS vor allem anderen kommen. Sobald
      // irgendetwas die Datei liest, ist es zu spaet.
      _entsperren(db, databaseKey);
      _pruefeVerschluesselung(db);
      _pruefeSchluessel(db);
      _grundeinstellungen(db);
      final generation = _schemaAnlegen(db);

      return EncryptedDatabase._(db, absolut, generation);
    } catch (_) {
      db?.close();
      _offen.remove(absolut);
      rethrow;
    }
  }

  static void _entsperren(CommonDatabase db, Uint8List key) {
    // Das Verfahren wird ausdruecklich festgenagelt statt dem Standard
    // ueberlassen. sqlite3mc kennt mehrere (chacha20, aes256cbc, sqlcipher,
    // ...) und waehlt eines davon als Standard. Aendert eine kuenftige Fassung
    // diesen Standard, liesse sich jede bestehende Datenbank nach einem
    // App-Update nicht mehr oeffnen — geprueft: mit dem falschen Verfahren
    // meldet SQLite "file is not a database".
    //
    // chacha20 ist hier ChaCha20-Poly1305. Auf Telefonen ohne
    // AES-Hardwarebefehle ist es deutlich schneller als AES, und die gibt es
    // im Zielbereich ab minSdk 24 durchaus noch.
    const cipher = 'chacha20';

    // x'...' uebergibt den Schluessel roh. Ohne die x'...'-Schreibweise gaelte
    // die Zeichenkette als Passphrase und liefe durch eine KDF — sinnlose
    // Arbeit bei einem Schluessel mit voller Entropie.
    final hex = _hex(key);
    try {
      db.execute("PRAGMA cipher = '$cipher'");
      db.execute('PRAGMA key = "x\'$hex\'"');
    } on SqliteException catch (e) {
      // Die Meldung von SqliteException traegt die ausloesende Anweisung —
      // also den Schluessel. Sie darf hier nicht nach draussen.
      throw DatabaseUnlockException('Aufschliessen fehlgeschlagen '
          '(SQLite-Code ${e.resultCode})');
    }
  }

  /// Beweist, dass ueberhaupt eine verschluesselnde Bibliothek geladen ist.
  ///
  /// Gewoehnliches SQLite liefert auf unbekannte PRAGMAs eine leere Ergebnis-
  /// menge statt eines Fehlers — nachgemessen. Genau diese Stille macht den
  /// Fehler so gefaehrlich, und genau sie wird hier abgefragt.
  ///
  /// Das ist eine Aussage ueber die BIBLIOTHEK, nicht ueber die Datei. Dass
  /// auch wirklich verschluesselt auf die Platte geschrieben wird, prueft
  /// test/store/encrypted_database_test.dart an den Rohbytes.
  static void _pruefeVerschluesselung(CommonDatabase db) {
    final ergebnis = db.select('PRAGMA cipher');
    if (ergebnis.isEmpty) throw const DatabaseNotEncryptedException();
  }

  /// Prueft, ob der Schluessel wirklich passt — und zwar sofort.
  ///
  /// `PRAGMA key` selbst meldet einen falschen Schluessel NICHT. Es merkt sich
  /// ihn nur; der Fehler faellt erst beim ersten Lesen der Datei auf. Ohne
  /// diese Zeile kaeme er darum irgendwo tief in der App heraus, als
  /// SqliteException "file is not a database" — an einer Stelle, die mit
  /// Schluesseln nichts zu tun hat.
  ///
  /// Das Inhaltsverzeichnis zu zaehlen ist die billigste Abfrage, die
  /// tatsaechlich eine Seite entschluesseln muss. Bei einer noch leeren Datei
  /// gelingt sie und liefert 0 — richtig so, das ist der Erstlauf.
  static void _pruefeSchluessel(CommonDatabase db) {
    try {
      db.select('SELECT count(*) FROM sqlite_master');
    } on SqliteException catch (e) {
      throw DatabaseUnlockException('falscher Schluessel oder beschaedigte '
          'Datei (SQLite-Code ${e.resultCode})');
    }
  }

  static void _grundeinstellungen(CommonDatabase db) {
    // WAL: weniger Schreibvorgaenge je Aenderung, und Lesen blockiert nicht.
    // Im Browser steht hier DELETE, weil die WASM-VFS kein WAL kann — die
    // Begruendung steht bei journalModus in sqlite_zugang_web.dart.
    db.execute('PRAGMA journal_mode = $journalModus');

    // FULL, nicht NORMAL. NORMAL spart fsync-Aufrufe, kann bei Stromausfall
    // aber die zuletzt bestaetigten Transaktionen verlieren — also genau das
    // zurueckgeben, was die Alles-oder-nichts-Transaktion gerade erkauft hat:
    // ein verbrauchter Prekey ohne die zugehoerige neue Sitzung. Eine
    // Nachricht je Sekunde ist kein Durchsatzproblem, ein toter Gespraechs-
    // faden schon.
    //
    // IM BROWSER VERSPRICHT FULL WENIGER. Das virtuelle Dateisystem schreibt
    // nach IndexedDB "asynchronously ... without any durability guarantees"
    // (package:sqlite3 3.5.0, src/wasm/vfs/indexed_db.dart:462) — ein
    // bestaetigtes COMMIT kann den geschlossenen Tab also verlieren. Warum das
    // so bleibt, steht bei sqliteVorbereiten() in sqlite_zugang_web.dart.
    db.execute('PRAGMA synchronous = FULL');

    // Zwischenergebnisse (Sortierungen, temporaere Tabellen) bleiben im
    // Arbeitsspeicher. Sonst koennte SQLite sie in eine temporaere DATEI
    // auslagern, und fuer die gilt die Verschluesselung der Hauptdatei nicht
    // zwingend.
    db.execute('PRAGMA temp_store = MEMORY');

    // Geloeschte Inhalte werden ueberschrieben statt nur freigegeben. Die
    // Datei ist zwar verschluesselt, aber wer spaeter an den Schluessel kommt,
    // koennte sonst geloeschte Nachrichten aus der Freiliste zurueckholen.
    db.execute('PRAGMA secure_delete = ON');

    db.execute('PRAGMA foreign_keys = ON');

    // Ausdruecklich gesetzt statt dem Standard ueberlassen: 2 MB Seitencache.
    db.execute('PRAGMA cache_size = -2000');
  }

  static int _schemaAnlegen(CommonDatabase db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      )
    ''');

    final vorhanden = _metaLesen(db, 'schema_version');
    var gefunden = vorhanden == null ? 0 : int.parse(vorhanden);

    if (gefunden > schemaVersion) {
      throw StateError('Datenbank stammt aus einer neueren App-Fassung '
          '(Schema $gefunden, diese App kennt $schemaVersion)');
    }

    if (gefunden == 0) {
      _metaSchreiben(db, 'generation', '0');
    }

    // Jede Stufe einzeln und in einer eigenen Transaktion. Bricht der Vorgang
    // in der Mitte ab, ist die Datenbank auf der letzten vollstaendig
    // erreichten Stufe — nicht irgendwo dazwischen.
    while (gefunden < schemaVersion) {
      final naechste = gefunden + 1;
      db.execute('BEGIN IMMEDIATE');
      try {
        switch (naechste) {
          case 1:
            _schemaV1(db);
          case 2:
            _schemaV2(db);
          case 3:
            _schemaV3(db);
          case 4:
            _schemaV4(db);
          case 5:
            _schemaV5(db);
          case 6:
            _schemaV6(db);
          case 7:
            _schemaV7(db);
          case 8:
            _schemaV8(db);
          case 9:
            _schemaV9(db);
          case 10:
            _schemaV10(db);
          case 11:
            _schemaV11(db);
          case 12:
            _schemaV12(db);
          case 13:
            _schemaV13(db);
          default:
            throw StateError('keine Migration nach Schema $naechste');
        }
        _metaSchreiben(db, 'schema_version', '$naechste');
        db.execute('COMMIT');
      } catch (_) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
        rethrow;
      }
      gefunden = naechste;
    }

    return int.parse(_metaLesen(db, 'generation') ?? '0');
  }

  static void _schemaV1(CommonDatabase db) {
    // Adressen sind BitDM-Adressen (Base32 des oeffentlichen Schluessels),
    // Sitzungsadressen zusaetzlich mit ":geraeteId". Sie sind damit selbst
    // schon der Schluessel — eine eigene ID waere nur eine Umleitung.
    db.execute('''
      CREATE TABLE identities (
        address TEXT PRIMARY KEY NOT NULL,
        key     BLOB NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE pre_keys (
        id     INTEGER PRIMARY KEY NOT NULL,
        record BLOB NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE signed_pre_keys (
        id     INTEGER PRIMARY KEY NOT NULL,
        record BLOB NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE sessions (
        address TEXT PRIMARY KEY NOT NULL,
        record  BLOB NOT NULL
      )
    ''');
  }

  /// Kontakte und Nachrichten.
  static void _schemaV2(CommonDatabase db) {
    db.execute('''
      CREATE TABLE contacts (
        address      TEXT PRIMARY KEY NOT NULL,
        display_name TEXT,
        added_at     INTEGER NOT NULL,
        state        INTEGER NOT NULL,
        verified     INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // seq ist der Grund, warum diese Tabelle nicht nach der Zeit sortiert.
    //
    // sent_at kommt vom ABSENDER. Er kann hineinschreiben, was er will — eine
    // Gegenstelle koennte ihre Nachrichten mit einem Datum von 2030 versehen
    // und damit dauerhaft oben in der Unterhaltung kleben, oder mit 1970 und
    // sich verstecken. Sortiert wird deshalb nach seq: einer Nummer, die
    // DIESES Geraet beim Speichern vergibt und die niemand von aussen
    // beeinflussen kann. Angezeigt wird trotzdem sent_at — das ist die
    // Information, die den Nutzer interessiert.
    db.execute('''
      CREATE TABLE messages (
        seq         INTEGER PRIMARY KEY AUTOINCREMENT,
        id          TEXT NOT NULL,
        chat_id     TEXT NOT NULL,
        sender_id   TEXT NOT NULL,
        body        TEXT NOT NULL,
        kind        INTEGER NOT NULL,
        is_mine     INTEGER NOT NULL,
        sent_at     INTEGER NOT NULL,
        received_at INTEGER,
        status      INTEGER NOT NULL
      )
    ''');

    // Doppelt zugestellte Nachrichten fallen hier auf, statt zweimal in der
    // Unterhaltung zu stehen. sender_id gehoert dazu: sonst koennte die
    // Gegenstelle eine Kennung belegen, die spaeter fuer eine eigene Nachricht
    // gebraucht wird.
    db.execute(
        'CREATE UNIQUE INDEX idx_messages_eindeutig ON messages(chat_id, sender_id, id)');
    db.execute('CREATE INDEX idx_messages_chat ON messages(chat_id, seq)');
  }

  /// Verfallszeit fuer Nachrichten.
  ///
  /// Die Oberflaeche bot "Verschwinden nach 24 Stunden" schon an, als es im
  /// Kern nichts dergleichen gab — der Schalter stand da und tat nichts. Wer
  /// glaubt, seine Nachrichten verschwinden, schreibt Dinge, die er sonst
  /// nicht schriebe; das ist schlimmer als eine fehlende Funktion.
  ///
  /// NULL bedeutet "bleibt". Der Zeitpunkt wird beim Speichern berechnet und
  /// nicht bei jeder Abfrage aus Alter plus Frist — sonst wuerde eine spaeter
  /// geaenderte Einstellung rueckwirkend Nachrichten loeschen oder
  /// wiederauferstehen lassen.
  static void _schemaV3(CommonDatabase db) {
    db.execute('ALTER TABLE messages ADD COLUMN expires_at INTEGER');
    db.execute(
        'CREATE INDEX idx_messages_verfall ON messages(expires_at) '
        'WHERE expires_at IS NOT NULL');
  }

  /// Anhaenge.
  ///
  /// EIGENE TABELLE UND NICHT ZWEI SPALTEN AN messages. Der Grund ist die
  /// Anleitung: sie ist bei einer grossen Datei rund 23 KB und wird beim
  /// Anzeigen einer Unterhaltung nie gebraucht. Laege sie in body, muesste
  /// jede Liste sie mitschleppen und beim Zeichnen ueberspringen. In body
  /// steht deshalb der ANGEZEIGTE NAME, und die Anleitung wird erst geholt,
  /// wenn jemand tatsaechlich herunterlaedt.
  ///
  /// zustand und pfad sind ORTSGEBUNDEN — sie beschreiben, was auf DIESEM
  /// Telefon vorliegt, und reisen nie mit. Auf einem wiederhergestellten
  /// Geraet steht dort wieder "angekuendigt", und das ist richtig so: die
  /// Datei liegt dort ja auch nicht.
  static void _schemaV4(CommonDatabase db) {
    db.execute('''
      CREATE TABLE anhaenge (
        chat_id    TEXT NOT NULL,
        sender_id  TEXT NOT NULL,
        message_id TEXT NOT NULL,
        name       TEXT NOT NULL,
        groesse    INTEGER NOT NULL,
        rezept     TEXT NOT NULL,
        zustand    INTEGER NOT NULL,
        pfad       TEXT,
        PRIMARY KEY (chat_id, sender_id, message_id)
      )
    ''');
    // Derselbe Schluessel wie der eindeutige Index auf messages. Eine reine
    // message_id waere zu wenig: die Gegenstelle vergibt ihre Kennungen
    // selbst und koennte eine belegen, die spaeter fuer eine eigene gebraucht
    // wird.
  }

  /// In der Naehe.
  ///
  /// ZWEI SPALTEN, ZWEI GANZ VERSCHIEDENE DINGE — auch wenn sie zusammen
  /// kommen:
  ///
  /// `contacts.zeigt_anwesenheit` ist eine ENTSCHEIDUNG des Nutzers: wem er
  /// sich zeigt. Standard 1, weil eine Ausfallsicherung, die man erst je
  /// Kontakt einschalten muss, keine ist. Wer sie fuer jemanden abschaltet,
  /// sendet fuer ihn kein Leuchtfeuer mehr aus und erwartet auch keines —
  /// beides zusammen, sonst wuerde man ihn zwar nicht mehr finden, ihm aber
  /// weiter zeigen, wo man ist.
  ///
  /// `messages.ueber_naehe` ist eine TATSACHE ueber eine einzelne Nachricht:
  /// sie ging direkt von Geraet zu Geraet. Standard 0, und alles, was vor
  /// dieser Stufe geschrieben wurde, ist ueber den Relay gegangen — die 0
  /// stimmt also auch rueckwirkend und ist nicht bloss ein Platzhalter.
  static void _schemaV5(CommonDatabase db) {
    db.execute('ALTER TABLE contacts '
        'ADD COLUMN zeigt_anwesenheit INTEGER NOT NULL DEFAULT 1');
    db.execute('ALTER TABLE messages '
        'ADD COLUMN ueber_naehe INTEGER NOT NULL DEFAULT 0');
    // KEIN Index auf ueber_naehe. Danach wird nie gesucht, es wird nur
    // angezeigt; ein Index waere Schreibarbeit bei jeder Nachricht fuer eine
    // Abfrage, die es nicht gibt.
  }

  /// War dieser Umschlag schon einmal beim Relay?
  ///
  /// WARUM UEBERHAUPT EINE SPALTE. Regel 2 aus wegwahl.dart — nie beide Wege
  /// fuer dieselbe Nachricht — galt bisher nur innerhalb eines einzigen
  /// Versandversuchs. Der Nachversand baut eine frische Wegwahl, die frei
  /// waehlt: gemessen ging eine Nachricht, deren Relay-Versuch geworfen hatte,
  /// beim naechsten Anlauf ueber die Naehe hinaus — moeglicherweise ein
  /// zweites Mal, und mit dem Zeichen "kein Server war beteiligt".
  ///
  /// WARUM NICHT IM ARBEITSSPEICHER. Die Frage wird genau dann gestellt, wenn
  /// der Arbeitsspeicher weg ist: `unversandt()` liest nach einem Neustart aus
  /// der Datei, was liegengeblieben ist. Ein Vermerk, der den Neustart nicht
  /// ueberlebt, fehlte in genau dem Fall, fuer den es ihn gibt.
  ///
  /// WARUM AN messages UND NICHT IN EINER EIGENEN TABELLE. Ein Bit, das zu
  /// genau einer Zeile gehoert, hoechstens einmal geschrieben und nur von der
  /// einen Abfrage gelesen wird, die diese Zeile ohnehin holt. Eine
  /// Nebentabelle waere ein JOIN in der einzigen Abfrage, die es je braucht —
  /// und ein zweiter Ort, an dem etwas fehlen kann.
  ///
  /// KEIN INDEX, aus demselben Grund wie bei ueber_naehe.
  ///
  /// DIE BESTEHENDEN LIEGENGEBLIEBENEN BEKOMMEN DIE 1, nicht die 0. Sie sind
  /// aus einer Fassung, in der der Nachversand ausschliesslich aus `connect()`
  /// heraus lief — sie warten also ohnehin auf den Relay, und die 1 nimmt
  /// ihnen nichts. Mit der 0 duerfte die erste davon nach dem Update ueber die
  /// Naehe gehen, obwohl sie moeglicherweise schon drueben liegt. Von den
  /// beiden Irrtuemern ist dieser der teure.
  static void _schemaV6(CommonDatabase db) {
    db.execute('ALTER TABLE messages '
        'ADD COLUMN schon_beim_relay INTEGER NOT NULL DEFAULT 0');
    // 0 ist MessageStatus.sending. Die Reihenfolge des Enums ist Teil des
    // Datenbankformats (models.dart sagt das ausdruecklich), sie steht fest.
    db.execute(
        'UPDATE messages SET schon_beim_relay = 1 WHERE is_mine = 1 AND status = 0');
  }

  /// Die Gegenrichtung von Schritt 6.
  ///
  /// Schritt 6 hielt fest, dass ein Umschlag schon beim Relay war, und
  /// sperrte danach die Naehe. Die Umkehrung fehlte: was ueber die Naehe
  /// mehrdeutig gescheitert war, durfte anschliessend ueber den Relay — und
  /// kam moeglicherweise zweimal an.
  ///
  /// KEIN UPDATE FUER BESTEHENDE ZEILEN, anders als bei Schritt 6.
  ///
  /// Dort war die 1 richtig, weil liegengebliebene Nachrichten aus einer
  /// Fassung stammten, in der es nur den Relay gab — sie warteten also
  /// nachweislich auf ihn. Hier ist es umgekehrt: vor diesem Schritt konnte
  /// nichts ueber die Naehe hinausgegangen sein, was nicht schon zugestellt
  /// waere. Eine 1 fuer alles wuerde bestehende Liegengebliebene grundlos vom
  /// Relay aussperren.
  static void _schemaV7(CommonDatabase db) {
    db.execute('ALTER TABLE messages '
        'ADD COLUMN schon_in_der_naehe INTEGER NOT NULL DEFAULT 0');
  }

  /// Wann zuletzt nachgesehen wurde, welche GERAETE ein Kontakt hat.
  ///
  /// EINE SPALTE UND KEINE TABELLE, KEINE META-ZEILE JE KONTAKT. Es ist ein
  /// Zeitstempel je Kontakt, gelesen und geschrieben von genau der Abfrage,
  /// die die Kontaktzeile ohnehin anfasst. Eine Nebentabelle waere ein JOIN
  /// fuer ein Feld und ein zweiter Ort, an dem eine Zeile fehlen kann; Meta-
  /// Zeilen je Kontakt waeren dasselbe in unsortiert.
  ///
  /// 0 HEISST "NIE GEFRAGT" und ist damit sofort faellig — richtig fuer jeden
  /// bestehenden Kontakt: seine Geraeteliste ist bisher `{1}` aus dem
  /// Sitzungsspeicher, und ob daneben inzwischen ein zweites Telefon steht,
  /// hat noch niemand nachgesehen. NOT NULL, weil ein NULL hier nichts
  /// bedeuten wuerde, was die 0 nicht schon sagt.
  /// NUR WENN SIE FEHLT, und das ist der einzige Schritt, der so vorgeht.
  ///
  /// `ALTER TABLE ADD COLUMN` auf eine vorhandene Spalte ist in SQLite ein
  /// harter Fehler ("duplicate column name"), und der rollt die ganze Stufe
  /// zurueck. Die Stufe bliebe damit dauerhaft unerreichbar — eine Datei, die
  /// diesen Zustand einmal hat, laesst sich nie wieder oeffnen. Das kann
  /// vorkommen: eine Fassung dazwischen hat die Spalte angelegt, die
  /// Fassungsnummer aber nicht erhoeht, oder ein Abbruch traf genau zwischen
  /// ALTER und COMMIT.
  ///
  /// Der Preis ist eine Abfrage beim Wandern von 7 auf 8, also genau einmal je
  /// Installation.
  static void _schemaV8(CommonDatabase db) {
    final spalten = db
        .select('PRAGMA table_info(contacts)')
        .map((r) => r['name'] as String);
    if (spalten.contains('geraete_geprueft')) return;
    db.execute('ALTER TABLE contacts '
        'ADD COLUMN geraete_geprueft INTEGER NOT NULL DEFAULT 0');
    // KEIN INDEX. Die Spalte wird nur gelesen, wenn die Zeile ohnehin geholt
    // wird — nie gesucht, nie sortiert. Derselbe Grund wie bei ueber_naehe.
  }

  /// Antworten, Bearbeiten, Fuer-alle-loeschen, Reaktionen, der Ausgang fuer
  /// Steuernachrichten und die oertlichen Ordnungsschalter der Unterhaltungen.
  ///
  /// ALLES IN EINER STUFE, weil es zusammen ausgeliefert wird: eine App, die
  /// Reaktionen kennt, aber keinen Ausgang, verloere jede Reaktion, die sie
  /// ohne Verbindung setzt.
  ///
  /// WIEDERHOLBAR WIE [_schemaV8], aus demselben Grund: eine Stufe, die an
  /// "duplicate column name" scheitert, rollt zurueck und ist danach nie
  /// wieder erreichbar. Jede Spalte nur, wenn sie fehlt; jede Tabelle mit
  /// IF NOT EXISTS.
  /// GRUPPENHAKEN: welches Mitglied eine eigene Gruppennachricht schon hat.
  static void _schemaV13(CommonDatabase db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS gruppen_quittung (
        chat_id    TEXT NOT NULL,
        message_id TEXT NOT NULL,
        mitglied   TEXT NOT NULL,
        am         INTEGER NOT NULL,
        PRIMARY KEY (chat_id, message_id, mitglied)
      )
    ''');
  }

  /// EINMAL-ANSICHT: 1, wenn der Anhang nur einmal geoeffnet werden darf.
  static void _schemaV12(CommonDatabase db) {
    _spalteDazu(db, 'anhaenge', 'einmal', 'INTEGER NOT NULL DEFAULT 0');
  }

  /// GELESEN: je Unterhaltung bis zu welcher Nachricht (seq) gelesen wurde —
  /// fuer die Zahl an der Chatzeile. Nur lokal.
  ///
  /// Beim Umstieg gilt alles Vorhandene als gelesen: sonst stuenden nach dem
  /// Update an jeder alten Unterhaltung Hunderte "ungelesene" Nachrichten.
  static void _schemaV11(CommonDatabase db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS gelesen (
        chat_id TEXT PRIMARY KEY NOT NULL,
        bis_seq INTEGER NOT NULL
      )
    ''');
    db.execute('INSERT OR IGNORE INTO gelesen (chat_id, bis_seq) '
        'SELECT chat_id, MAX(seq) FROM messages GROUP BY chat_id');
  }

  /// STERNE: wann eine Nachricht markiert wurde (ms), sonst NULL. Nur lokal.
  static void _schemaV10(CommonDatabase db) {
    _spalteDazu(db, 'messages', 'stern', 'INTEGER');
  }

  static void _schemaV9(CommonDatabase db) {
    _spalteDazu(db, 'messages', 'antwort_auf', 'TEXT');
    // Zahl UND Zeitpunkt: die Zahl deckelt (Signal: zehnmal), der Zeitpunkt
    // ordnet — zwei Bearbeitungen koennen ueber zwei Wege in vertauschter
    // Reihenfolge ankommen, und dann darf die aeltere die neuere nicht
    // ueberschreiben.
    _spalteDazu(db, 'messages', 'bearbeitet_zahl', 'INTEGER NOT NULL DEFAULT 0');
    _spalteDazu(db, 'messages', 'bearbeitet_at', 'INTEGER');
    _spalteDazu(db, 'messages', 'widerrufen', 'INTEGER NOT NULL DEFAULT 0');

    // Je Person und Nachricht EINE Zeile — der Primaerschluessel ist die
    // Regel "eine neue Reaktion ersetzt die alte".
    db.execute('''
      CREATE TABLE IF NOT EXISTS reaktionen (
        chat_id    TEXT NOT NULL,
        message_id TEXT NOT NULL,
        von        TEXT NOT NULL,
        zeichen    TEXT NOT NULL,
        at         INTEGER NOT NULL,
        PRIMARY KEY (chat_id, message_id, von)
      )
    ''');

    // DER AUSGANG: Steuernachrichten, die nicht verloren gehen duerfen, aber
    // keine Zeile im Verlauf haben — Reaktion, Bearbeitung, Widerruf. Eine
    // Textnachricht wartet als `sending` in `messages`; fuer diese drei gab es
    // keinen solchen Platz, und eine Reaktion ohne Verbindung waere still
    // verschwunden.
    //
    // Die fertigen Nutzlast-Bytes, nicht ihre Einzelteile: was nachgeschickt
    // wird, soll bitgenau das sein, was beim ersten Versuch hinausging. Die
    // Datenbank ist verschluesselt; Klartext liegt hier nicht offener als im
    // Verlauf daneben.
    db.execute('''
      CREATE TABLE IF NOT EXISTS ausgang (
        seq     INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id TEXT NOT NULL,
        nutzlast BLOB NOT NULL,
        angelegt INTEGER NOT NULL
      )
    ''');

    // Nur auf diesem Geraet — sie reisen nicht, der Relay erfaehrt nichts.
    _spalteDazu(db, 'contacts', 'angeheftet', 'INTEGER NOT NULL DEFAULT 0');
    _spalteDazu(db, 'contacts', 'archiviert', 'INTEGER NOT NULL DEFAULT 0');
    _spalteDazu(db, 'contacts', 'stumm', 'INTEGER NOT NULL DEFAULT 0');
    // NULL = folgt der Grundeinstellung, 0 = hier nie, sonst Sekunden.
    _spalteDazu(db, 'contacts', 'frist', 'INTEGER');
    // ANGEHEFTET: positiv = angeheftet um t (ms), NEGATIV = geloest um |t|,
    // NULL = nie beruehrt. Das Vorzeichen ist der Grabstein: ohne ihn liesse
    // ein verspaetetes "anheften" von gestern eine heute geloeste Nachricht
    // wieder oben erscheinen.
    _spalteDazu(db, 'messages', 'angeheftet', 'INTEGER');
    // GEPLANT: wann eine eigene Nachricht fruehestens hinausgeht (ms), sonst
    // NULL. Bis dahin steht sie auf `sending` und wird vom Nachversand
    // uebersprungen.
    _spalteDazu(db, 'messages', 'faellig', 'INTEGER');

    db.execute('''
      CREATE TABLE IF NOT EXISTS gruppen (
        id         TEXT PRIMARY KEY NOT NULL,
        name       TEXT NOT NULL,
        admin      TEXT NOT NULL,
        mitglieder TEXT NOT NULL,
        version    INTEGER NOT NULL,
        aktiv      INTEGER NOT NULL DEFAULT 1,
        angeheftet INTEGER NOT NULL DEFAULT 0,
        archiviert INTEGER NOT NULL DEFAULT 0,
        stumm      INTEGER NOT NULL DEFAULT 0,
        frist      INTEGER,
        angelegt   INTEGER NOT NULL
      )
    ''');

    // Je Person und Umfrage EINE Zeile; eine neue Stimme ersetzt die alte.
    db.execute('''
      CREATE TABLE IF NOT EXISTS stimmen (
        chat_id    TEXT NOT NULL,
        umfrage_id TEXT NOT NULL,
        von        TEXT NOT NULL,
        auswahl    TEXT NOT NULL,
        at         INTEGER NOT NULL,
        PRIMARY KEY (chat_id, umfrage_id, von)
      )
    ''');
  }

  /// `ALTER TABLE ... ADD COLUMN`, aber nur, wenn die Spalte fehlt.
  static void _spalteDazu(
      CommonDatabase db, String tabelle, String spalte, String art) {
    final da = db
        .select('PRAGMA table_info($tabelle)')
        .any((r) => r['name'] == spalte);
    if (!da) db.execute('ALTER TABLE $tabelle ADD COLUMN $spalte $art');
  }

  static String? _metaLesen(CommonDatabase db, String key) {
    final r = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  static void _metaSchreiben(CommonDatabase db, String key, String value) {
    db.execute(
      'INSERT INTO meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  String? meta(String key) => _metaLesen(_db, key);

  /// Fuehrt [arbeit] in genau EINER Transaktion aus.
  ///
  /// BEGIN IMMEDIATE nimmt die Schreibsperre sofort statt erst beim ersten
  /// Schreibzugriff. Sonst koennte die Transaktion nach halber Arbeit an einem
  /// SQLITE_BUSY scheitern.
  ///
  /// STANDZAEHLER: Vor der Arbeit wird geprueft, ob die Datei noch auf dem
  /// Stand ist, den dieser Verbinder zuletzt gesehen hat. Das faengt einen
  /// Fall ab, den SQLites eigene Sperren NICHT abfangen: zwei Isolate — etwa
  /// die App und ein Weckruf im Sparmodus — halten je einen eigenen Zustand im
  /// Arbeitsspeicher. Beide Transaktionen waeren fuer sich sauber, aber die
  /// zweite schriebe einen Zustand zurueck, der die Aenderungen der ersten nie
  /// gesehen hat. Sitzungen gingen verloren, ohne dass ein Fehler auftritt.
  ///
  /// Hier wird daraus ein lautes [StaleStateException] statt eines stillen
  /// Datenverlusts.
  T transaction<T>(T Function(CommonDatabase db) arbeit) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final inDatei = int.parse(_metaLesen(_db, 'generation') ?? '0');
      if (inDatei != _generation) {
        throw StaleStateException(_generation, inDatei);
      }

      final ergebnis = arbeit(_db);

      final neu = _generation + 1;
      _metaSchreiben(_db, 'generation', '$neu');
      _db.execute('COMMIT');
      _generation = neu;
      return ergebnis;
    } catch (_) {
      // Ein fehlgeschlagenes ROLLBACK darf den eigentlichen Fehler nicht
      // verdecken.
      try {
        _db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  void close() {
    _db.close();
    _offen.remove(pfad);
  }

  static const _ziffern = '0123456789abcdef';

  static String _hex(Uint8List bytes) {
    final b = StringBuffer();
    for (final byte in bytes) {
      b.write(_ziffern[(byte >> 4) & 0x0F]);
      b.write(_ziffern[byte & 0x0F]);
    }
    return b.toString();
  }
}
