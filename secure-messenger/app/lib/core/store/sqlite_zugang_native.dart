// Der Zweig fuer Android, Windows und Linux. Er bildet ab, was
// encrypted_database.dart vor der Weiche unmittelbar getan hat — hier darf sich
// nichts verhalten wie vorher nicht.

import 'dart:io';

import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' as ffi;

/// Die geladene SQLite-Bibliothek.
///
/// `ffi.sqlite3` laedt beim ersten Zugriff selbst nach (libsqlite3mc.so bzw.
/// sqlite3mc.dll aus dem Paket-Hook), darum ist hier nichts vorzubereiten.
CommonSqlite3 get sqliteLaufzeit => ffi.sqlite3;

/// Oeffnet die Datei. Auf der VM ist die geladene Bibliothek selbst schon
/// sqlite3mc, es braucht also keinen VFS-Namen — anders als im Browser, siehe
/// `_vfsMitVerschluesselung` in sqlite_zugang_web.dart.
CommonDatabase oeffneDatei(String pfad) => sqliteLaufzeit.open(pfad);

/// Absichtlich leer.
///
/// Das Gegenstueck im Browser laedt hier das WASM-Modul. Auf der VM waere jede
/// Arbeit an dieser Stelle nur ein zusaetzlicher Umlauf der Ereignisschleife
/// beim Kaltstart.
Future<void> sqliteVorbereiten() async {}

/// Der Pfad, unter dem die Datei tatsaechlich liegt.
///
/// Absolut, weil `EncryptedDatabase._offen` damit erkennt, ob dieselbe Datei
/// zweimal offen ist — zwei verschiedene relative Pfade auf dieselbe Datei
/// wuerden sonst durchrutschen.
String absoluterPfad(String pfad) => File(pfad).absolute.path;

/// WAL: weniger Schreibvorgaenge je Aenderung, und Lesen blockiert nicht.
/// Siehe die Begruendung fuer den Browser in sqlite_zugang_web.dart.
const String journalModus = 'WAL';

/// Entfernt die Datenbankdateien. Genau die Schleife, die vorher in
/// `RealMessengerCore.wipeEverything` stand — sie ist nur hierher gewandert,
/// weil es im Browser keine Dateien gibt.
Future<void> loescheDatenbank(String pfad) async {
  for (final endung in const ['', '-wal', '-shm']) {
    final f = File('$pfad$endung');
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // Die Datei bleibt vielleicht liegen — ohne Schluessel ist sie
      // wertlos. Kein Grund, den Loeschvorgang deswegen abzubrechen.
    }
  }
}

/// Auf dem Geraet liegt die Entropie im Schluesselspeicher und ueberlebt den
/// Neustart; eine Datenbank ohne Schluessel entsteht hier nicht im Normalfall.
/// Das Verhalten bleibt deshalb, wie es war. Begruendung fuer den Browser in
/// sqlite_zugang_web.dart.
const bool verwaisteDatenbankMoeglich = false;
