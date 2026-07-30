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
