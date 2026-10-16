// schema15_test.dart — der Umstieg einer bestehenden Datenbank auf die
// offizielle libsignal (Schema-Stufe 15, encrypted_database.dart `_schemaV15`).
//
// Das ist der einzige Schritt, der beim Update Daten WEGWIRFT, und deshalb
// wird er hier genau vermessen:
//
//  - Sitzungen und Prekeys stammen aus libsignal_protocol_dart. Die offizielle
//    Bibliothek kann sie nicht lesen; sie muessen weg, sonst scheitert die
//    erste Nachricht an einem unlesbaren Record.
//  - Identitaeten, Kontakte und Nachrichten muessen BLEIBEN. Was hier verloren
//    ginge, waere fuer den Nutzer der Verlauf seiner Unterhaltungen.
//  - `relay_prekey_count` muss weg, damit sich die App beim naechsten
//    Verbinden mit den neuen Prekeys (EC und Kyber) beim Relay neu anmeldet.
//
// NACHGESTELLT WIRD DIE ALTE DATEI, wie in encrypted_database_test.dart: eine
// Datenbank auf der aktuellen Stufe, die Kyber-Tabellen weg, die Fassung auf
// 14 zurueck. Genau so sieht die Datei einer Installation mit 1.9.x aus — die
// Stufen 1 bis 14 sind dieselben.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart';

import '../support/signal_hilfe.dart';

/// Bytes im Format der alten Bibliothek — fuer die Migration nur Ballast, der
/// verschwinden muss. Der Inhalt ist absichtlich kein gueltiges Record der
/// offiziellen libsignal.
Uint8List _alt(int marke) =>
    Uint8List.fromList([0x0a, 0x21, 0x05, ...List<int>.filled(32, marke)]);

/// Alle Zeilen einer Tabelle, sortiert, als einfache Werte.
List<Map<String, Object?>> _zeilen(CommonDatabase db, String tabelle,
        String ordnung) =>
    db
        .select('SELECT * FROM $tabelle ORDER BY $ordnung')
        .map((r) => {
              for (final k in r.keys)
                k: r[k] is Uint8List ? (r[k] as Uint8List).toList() : r[k]
            })
        .toList();

Set<String> _tabellen(CommonDatabase db) => db
    .select("SELECT name FROM sqlite_master WHERE type = 'table'")
    .map((r) => r['name'] as String)
    .toSet();

Set<String> _spalten(CommonDatabase db, String tabelle) => db
    .select('PRAGMA table_info($tabelle)')
    .map((r) => r['name'] as String)
    .toSet();

int _zahl(CommonDatabase db, String tabelle) =>
    db.select('SELECT count(*) c FROM $tabelle').first['c'] as int;

void main() {
  late Directory tmp;
  late DerivedKeys ich;
  late DerivedKeys kontakt;
  var n = 0;

  setUpAll(() async {
    await signalBereit();
    ich = await KeyDerivation.fromMnemonic(Bip39.generate());
    kontakt = await KeyDerivation.fromMnemonic(Bip39.generate());
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_schema15'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });
  String neuerPfad() => '${tmp.path}/s15_${n++}.db';

  /// Legt eine Datei an, wie sie eine Installation mit Schema 14 hat — mit
  /// Inhalt in jeder Tabelle, die der Schritt anfasst oder in Ruhe lassen muss.
  void legeStufe14An(String pfad) {
    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    db.transaction((raw) {
      raw.execute('DROP TABLE kyber_pre_keys');
      raw.execute('DROP TABLE kyber_benutzt');
      raw.execute("DELETE FROM meta WHERE key = 'signal_bibliothek'");

      // Was die alte Bibliothek hinterlassen hat.
      raw.execute('INSERT INTO sessions (address, record) VALUES (?, ?)',
          ['${kontakt.address}:1', _alt(1)]);
      raw.execute('INSERT INTO sessions (address, record) VALUES (?, ?)',
          ['${kontakt.address}:2', _alt(2)]);
      for (var id = 1; id <= 3; id++) {
        raw.execute(
            'INSERT INTO pre_keys (id, record) VALUES (?, ?)', [id, _alt(10 + id)]);
      }
      raw.execute(
          'INSERT INTO signed_pre_keys (id, record) VALUES (?, ?)', [1, _alt(20)]);

      // Was bleiben muss. Die Identitaet im Format beider Bibliotheken:
      // Typbyte 0x05 und die rohen 32 Bytes.
      raw.execute('INSERT INTO identities (address, key) VALUES (?, ?)', [
        kontakt.address,
        Uint8List.fromList(
            [SignalIdentityBridge.curve25519Typ, ...kontakt.identityPublicKey]),
      ]);
      raw.execute(
          'INSERT INTO contacts (address, display_name, added_at, state, verified) '
          'VALUES (?, ?, ?, ?, ?)',
          [kontakt.address, 'Kontakt mit Ümlaut', 1700000000000, 2, 1]);
      const spalten =
          '(id, chat_id, sender_id, body, kind, is_mine, sent_at, received_at, status)';
      raw.execute('INSERT INTO messages $spalten VALUES (?,?,?,?,?,?,?,?,?)', [
        'm1', kontakt.address, kontakt.address, 'Hallo, alte Fassung', 0, 0,
        1700000000001, 1700000000002, 3,
      ]);
      raw.execute('INSERT INTO messages $spalten VALUES (?,?,?,?,?,?,?,?,?)', [
        'm2', kontakt.address, ich.address, 'Antwort', 0, 1, 1700000000003,
        null, 1,
      ]);

      raw.execute(
          "INSERT INTO meta (key, value) VALUES ('relay_prekey_count', '100')");
      raw.execute(
          "INSERT INTO meta (key, value) VALUES ('signal_archiv_bereinigt_v1', '1')");
      raw.execute("INSERT INTO meta (key, value) VALUES ('registration_id', '777') "
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value');
      raw.execute("UPDATE meta SET value = '14' WHERE key = 'schema_version'");
    });
    db.close();
  }

  /// Oeffnet die Datei an EncryptedDatabase vorbei — so, wie sie auf der
  /// Platte liegt, ohne dass ein Migrationsschritt laeuft.
  Database roh(String pfad) {
    final db = sqlite3.open(pfad);
    db.execute("PRAGMA cipher = 'chacha20'");
    final hex = ich.databaseKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  test('die nachgestellte Datei steht wirklich auf Stufe 14', () {
    // Ohne diese Gegenprobe koennte der Haupttest an einer Datei bestehen,
    // die die Stufe 15 nie gesehen hat.
    final pfad = neuerPfad();
    legeStufe14An(pfad);
    final db = roh(pfad);
    addTearDown(db.close);
    expect(
        db.select("SELECT value FROM meta WHERE key = 'schema_version'")
            .first['value'],
        '14');
    expect(_tabellen(db), isNot(contains('kyber_pre_keys')));
    expect(_zahl(db, 'sessions'), 2);
    expect(_zahl(db, 'pre_keys'), 3);
  });

  test('nach Stufe 15: Sitzungen und Prekeys leer, Identitaeten, Kontakte und '
      'Nachrichten unveraendert, relay_prekey_count weg', () {
    final pfad = neuerPfad();
    legeStufe14An(pfad);

    final vorher = roh(pfad);
    final identitaeten = _zeilen(vorher, 'identities', 'address');
    final kontakte = _zeilen(vorher, 'contacts', 'address');
    final nachrichten = _zeilen(vorher, 'messages', 'seq');
    vorher.close();
    expect(nachrichten, hasLength(2), reason: 'sonst vergleicht der Test leer');

    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(db.close);
    final raw = db.raw;

    expect(db.meta('schema_version'), '15');

    // Weg: alles aus der alten Bibliothek.
    expect(_zahl(raw, 'sessions'), 0);
    expect(_zahl(raw, 'pre_keys'), 0);
    expect(_zahl(raw, 'signed_pre_keys'), 0);

    // Unveraendert: Byte fuer Byte, Spalte fuer Spalte.
    expect(_zeilen(raw, 'identities', 'address'), identitaeten);
    expect(_zeilen(raw, 'contacts', 'address'), kontakte);
    expect(_zeilen(raw, 'messages', 'seq'), nachrichten);

    // Meta: die Zaehlung weg, damit neu angemeldet wird; der Vermerk der
    // alten Archivbereinigung auch; die Registrierungsnummer bleibt.
    expect(db.meta('relay_prekey_count'), isNull);
    expect(db.meta('signal_archiv_bereinigt_v1'), isNull);
    expect(db.meta('registration_id'), '777');
    expect(db.meta('signal_bibliothek'), 'libsignal-offiziell');

    // Die Kyber-Tabellen gibt es, mit den Spalten, die
    // signal_store_repository.dart liest und schreibt.
    expect(_tabellen(raw), containsAll(['kyber_pre_keys', 'kyber_benutzt']));
    expect(_spalten(raw, 'kyber_pre_keys'), {'id', 'record', 'letzte_rettung'});
    expect(_spalten(raw, 'kyber_benutzt'), {'tripel'});
    expect(_zahl(raw, 'kyber_pre_keys'), 0);
    expect(_zahl(raw, 'kyber_benutzt'), 0);
  });

  test('die alte Identitaet eines Kontakts ist fuer die neue Bibliothek '
      'lesbar', () async {
    // Der Grund, warum identities bleiben darf: beide Bibliotheken
    // speichern 0x05 + 32 Byte. Liest die neue sie nicht, waere jede
    // Pruefnummer nach dem Update weg.
    final pfad = neuerPfad();
    legeStufe14An(pfad);
    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(db.close);

    final store = SignalStoreRepository(db).openStore(ich);
    expect(store.state.sessions, isEmpty);
    expect(store.state.preKeys, isEmpty);
    expect(store.state.kyberPreKeys, isEmpty);
    expect(store.identity.registrationId, 777);

    final schluessel = await store.getIdentity(adr(kontakt.address));
    expect(schluessel, isNotNull);
    expect(SignalIdentityBridge.addressOf(schluessel!), kontakt.address);
  });

  test('Stufe 15 laeuft genau einmal — neue Sitzungen ueberleben den '
      'naechsten Start', () {
    // Liefe der Schritt bei jedem Oeffnen, waeren nach jedem Neustart alle
    // Sitzungen weg und jede Unterhaltung finge neu an.
    final pfad = neuerPfad();
    legeStufe14An(pfad);
    final db = EncryptedDatabase.open(pfad, ich.databaseKey);
    db.transaction((raw) {
      raw.execute('INSERT INTO sessions (address, record) VALUES (?, ?)',
          ['${kontakt.address}:1', _alt(99)]);
      raw.execute('INSERT INTO kyber_benutzt (tripel) VALUES (?)', ['1:1:ab']);
    });
    db.close();

    final wieder = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(wieder.close);
    expect(_zahl(wieder.raw, 'sessions'), 1);
    expect(_zahl(wieder.raw, 'kyber_benutzt'), 1);
  });

  test('bricht der Schritt ab, steht die Datei vollstaendig auf Stufe 14',
      () {
    // Alles in EINER Transaktion (encrypted_database.dart). Sonst bliebe eine
    // Datei, deren Sitzungen weg sind, deren Fassung aber noch 14 sagt — oder
    // umgekehrt eine 15 mit alten Sitzungen, an denen die neue Bibliothek
    // scheitert.
    final pfad = neuerPfad();
    legeStufe14An(pfad);
    // Ein Ausloeser in der Datei, der das Leeren der Prekeys verweigert —
    // mitten im Schritt, NACH dem Anlegen der Kyber-Tabellen und dem Leeren
    // der Sitzungen.
    final vorbereiten = roh(pfad);
    vorbereiten.execute('CREATE TRIGGER sperre BEFORE DELETE ON pre_keys '
        "BEGIN SELECT RAISE(ABORT, 'gesperrt'); END");
    vorbereiten.close();

    expect(() => EncryptedDatabase.open(pfad, ich.databaseKey),
        throwsA(isA<SqliteException>()));

    final db = roh(pfad);
    addTearDown(db.close);
    expect(
        db.select("SELECT value FROM meta WHERE key = 'schema_version'")
            .first['value'],
        '14');
    expect(_zahl(db, 'sessions'), 2,
        reason: 'das Leeren der Sitzungen muss mit zurueckgerollt sein');
    expect(_tabellen(db), isNot(contains('kyber_pre_keys')));
    expect(
        db.select("SELECT value FROM meta WHERE key = 'relay_prekey_count'"),
        isNotEmpty);

    // Ist das Hindernis weg, gelingt der Schritt beim naechsten Start.
    db.execute('DROP TRIGGER sperre');
    final wieder = EncryptedDatabase.open(pfad, ich.databaseKey);
    addTearDown(wieder.close);
    expect(wieder.meta('schema_version'), '15');
    expect(_zahl(wieder.raw, 'sessions'), 0);
  });

  test('eine frische Datenbank bekommt die Kyber-Tabellen gleich mit', () {
    final db = EncryptedDatabase.open(neuerPfad(), ich.databaseKey);
    addTearDown(db.close);
    expect(_tabellen(db.raw), containsAll(['kyber_pre_keys', 'kyber_benutzt']));
    expect(db.meta('signal_bibliothek'), 'libsignal-offiziell');
  });
}
