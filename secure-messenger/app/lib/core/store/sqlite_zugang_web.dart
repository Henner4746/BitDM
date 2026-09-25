// Der Zweig fuer den Browser.
//
// DER KNACKPUNKT WAR SYNCHRON GEGEN ASYNCHRON: `WasmSqlite3.loadFromUrlString`
// ist asynchron, `EncryptedDatabase.open` ist synchron und soll es bleiben — 27
// Aufrufstellen in vier Testdateien haengen daran. Aufgeloest wird das hier:
// das Laden passiert EINMAL in [sqliteVorbereiten], das Ergebnis bleibt in
// [_laufzeit] liegen, und `open()` davon ist wieder synchron
// (package:sqlite3/src/sqlite3.dart:22 — "CommonDatabase open(String filename,
// ...)"). Der asynchrone Anteil endet damit an der einen Zeile in
// real_messenger_core.dart und dringt nicht weiter nach oben.

// Kein eigener Import von package:sqlite3/common.dart: wasm.dart:15 gibt
// `export 'common.dart';` weiter, CommonSqlite3 kommt also schon mit.
import 'package:sqlite3/wasm.dart';

/// Wird nur von [sqliteVorbereiten] gesetzt. `null` heisst: noch nicht geladen.
WasmSqlite3? _laufzeit;

/// Das virtuelle Dateisystem in IndexedDB. Gebraucht zum Loeschen
/// ([loescheDatenbank]) und zum Festschreiben ([flush]).
IndexedDbFileSystem? _dateisystem;

/// Unter diesem Namen haengt das IndexedDB-Dateisystem an SQLite.
const String _vfsName = 'bitdm-idb';

/// UND UNTER DIESEM WIRD GEOEFFNET — nicht unter [_vfsName].
///
/// Das war der Grund, warum die erste Datenbank im Browser nie aufging
/// (gemessen am 25.09.2026, Chrome headless): `PRAGMA cipher` bzw. `PRAGMA
/// key` scheiterten mit einer SqliteException, [EncryptedDatabase] machte
/// daraus ordnungsgemaess eine DatabaseUnlockException, und im Browser stand
/// nur "Error". sqlite3mc verschluesselt nicht in SQLite selbst, sondern als
/// Zwischenschicht UEBER einem Dateisystem. Fuer jedes Dateisystem, das man
/// in sqlite3mc.wasm anmeldet, legt es eine solche Schicht mit dem Vorsatz
/// "multipleciphers-" an — nachzulesen im Beispiel des Pakets,
/// package:sqlite3-3.5.0/example/web/main.dart:46. Wer das nackte Dateisystem
/// oeffnet, bekommt gewoehnliches SQLite ohne Verschluesselung, und das
/// PRAGMA scheitert (oder wuerde, schlimmer, still nichts tun — genau dagegen
/// steht _pruefeVerschluesselung).
const String _vfsMitVerschluesselung = 'multipleciphers-$_vfsName';

CommonSqlite3 get sqliteLaufzeit {
  final geladen = _laufzeit;
  if (geladen == null) {
    // Absichtlich laut. Ohne diesen Wurf waere die Folge eine Nullreferenz
    // irgendwo mitten im Oeffnen, und die zeigt nicht auf die Ursache.
    throw StateError('sqliteVorbereiten() wurde nicht abgewartet — im Browser '
        'muss das WASM-Modul vor dem ersten open() geladen sein');
  }
  return geladen;
}

/// Oeffnet die Datei ueber die verschluesselnde Schicht. Siehe
/// [_vfsMitVerschluesselung] — ohne diesen Namen gaebe es keine
/// Verschluesselung.
CommonDatabase oeffneDatei(String pfad) =>
    sqliteLaufzeit.open(pfad, vfs: _vfsMitVerschluesselung);

/// Laedt das WASM-Modul und haengt das virtuelle Dateisystem daran.
///
/// Mehrfachaufruf ist erlaubt und tut ab dem zweiten Mal nichts. Nicht gegen
/// zwei GLEICHZEITIGE Aufrufe abgesichert: der einzige Aufrufer ist
/// `RealMessengerCore._oeffne`, und der laeuft je Identitaet einmal.
Future<void> sqliteVorbereiten() async {
  if (_laufzeit != null) return;

  // sqlite3mc.wasm, nicht sqlite3.wasm: nur die MultipleCiphers-Fassung kennt
  // `PRAGMA key`. Mit dem gewoehnlichen Modul lieferte `PRAGMA cipher` eine
  // leere Ergebnismenge und encrypted_database.dart wuerfe
  // DatabaseNotEncryptedException — richtig so, aber die Datei muss eben da
  // sein. Der Name ist relativ zur Seite; alles in web/ landet unveraendert in
  // build/web/.
  final WasmSqlite3 modul;
  try {
    modul = await WasmSqlite3.loadFromUrlString('sqlite3mc.wasm');
  } catch (e) {
    // Der wahrscheinlichste Fehler ist ein 404, und dessen eigene Meldung sagt
    // nicht, WELCHE Datei fehlt und wo sie herkommt.
    throw StateError('sqlite3mc.wasm liess sich nicht laden ($e). Die Datei '
        'gehoert nach web/sqlite3mc.wasm und muss zur Fassung von '
        'package:sqlite3 passen (3.5.0) — sie kommt aus den GitHub-Releases '
        'von simolus3/sqlite3.dart. WASM-Module aus anderen Quellen (sql.js) '
        'passen nicht zu den WasmBindings.');
  }

  // WARUM IndexedDB UND NICHT OPFS. OPFS ist schneller, aber
  // SimpleOpfsFileSystem sagt in seinem eigenen Doc-Kommentar
  // (package:sqlite3/src/wasm/vfs/simple_opfs.dart:110) "only works in
  // dedicated web workers". BitDM laeuft im Haupt-Isolate; die andere OPFS-
  // Fassung (WasmVfs) braucht dafuer einen eigenen Worker samt
  // SharedArrayBuffer, und der braucht die COOP/COEP-Kopfzeilen auf dem Server.
  // Das ist eine Anforderung an die AUSLIEFERUNG, nicht an den Code — dafuer
  // ist eine Datenbank, die einfach funktioniert, zu wichtig. IndexedDB kann
  // jeder Browser, den Flutter Web ueberhaupt bedient.
  //
  // HALTBARKEIT, bewusst entschieden statt geerbt: writeAutomatically bleibt
  // auf dem Standard true. Laut Doku (vfs/indexed_db.dart:462) heisst das
  // "asynchronously ... without any durability guarantees" — ein bestaetigtes
  // COMMIT kann also den geschlossenen Tab NICHT ueberleben, obwohl
  // `PRAGMA synchronous = FULL` gesetzt ist. Die Gegenmassnahme waere
  // writeAutomatically: false plus ein `await flush()` je Transaktion — und
  // flush() ist asynchron, waehrend EncryptedDatabase.transaction synchron ist
  // und synchron bleiben soll. Der Preis dafuer waere die gesamte Store-Schicht
  // in async, der Gewinn eine Zusage, die der Browser ohnehin nur ungefaehr
  // haelt. Was das kostet, steht bei synchronous = FULL in
  // encrypted_database.dart: im schlimmsten Fall ein verbrauchter Prekey ohne
  // die zugehoerige neue Sitzung, also ein toter Gespraechsfaden mit diesem
  // einen Gegenueber. Auf dem Telefon ist das ausgeschlossen, im Browser nicht.
  final dateisystem =
      await IndexedDbFileSystem.open(dbName: 'bitdm', vfsName: _vfsName);
  modul.registerVirtualFileSystem(dateisystem, makeDefault: true);

  _dateisystem = dateisystem;
  _laufzeit = modul;
}

/// Entfernt die Datenbank samt Rollback-Journal aus IndexedDB.
///
/// Die Blocks darin sind verschluesselt; ohne den Schluessel sind sie so viel
/// wert wie auf der Platte. Geloescht wird trotzdem, und zwar bis nach
/// IndexedDB durch ([IndexedDbFileSystem.flush]): das Dateisystem haelt eine
/// Kopie im Arbeitsspeicher und schreibt sonst erst irgendwann.
///
/// Laeuft auch, wenn sqliteVorbereiten() noch nie aufgerufen wurde — das
/// Loeschen der Identitaet darf nicht davon abhaengen, ob in dieser Sitzung
/// schon eine Datenbank offen war.
Future<void> loescheDatenbank(String pfad) async {
  await sqliteVorbereiten();
  final fs = _dateisystem!;
  for (final endung in const ['', '-journal']) {
    // UEBER xFullPathName. SQLite oeffnet 'bitdm.db' als '/bitdm.db' — es
    // fragt die VFS vorher nach dem vollen Namen —, und das Dateisystem
    // kennt die Datei nur unter diesem. Ein xAccess('bitdm.db') findet sie
    // nicht; so blieb im ersten Anlauf die alte Datei liegen, und die neue
    // Identitaet scheiterte an ihr mit einer DatabaseUnlockException
    // (gemessen am 25.09.2026 in Chrome).
    final name = fs.xFullPathName('$pfad$endung');
    try {
      if (fs.xAccess(name, 0) != 0) fs.xDelete(name, 0);
    } catch (_) {
      // Weiter loeschen — dieselbe Haltung wie auf der Platte.
    }
  }
  await fs.flush();
}

/// IM BROWSER UEBERLEBT DIE IDENTITAET OHNE APP-PASSWORT KEINEN NEUSTART —
/// die Datenbank schon.
///
/// Die Entropie liegt dort ohne Passwort nur im Arbeitsspeicher (siehe
/// main.dart bei `basis:`), die verschluesselte Datenbank dagegen in
/// IndexedDB. Nach dem Neuladen steht also eine Datei da, zu der es keinen
/// Schluessel mehr gibt, ausser den zwoelf Woertern. [RealMessengerCore]
/// braucht das zu wissen: eine NEUE Identitaet darf an dieser Datei nicht
/// scheitern, eine wiederhergestellte soll sie wieder oeffnen.
const bool verwaisteDatenbankMoeglich = true;

/// Im Browser gibt es keine absoluten Pfade.
///
/// Der Pfad ist hier nur ein Name im virtuellen Dateisystem. Er wird
/// unveraendert durchgereicht: '/bitdm/bitdm.db' ist als Name genauso
/// eindeutig, und `EncryptedDatabase._offen` erkennt damit weiterhin die
/// doppelt geoeffnete Datei.
String absoluterPfad(String pfad) => pfad;

/// KEIN WAL im Browser — das ist keine Vorsicht, sondern unmoeglich.
///
/// WAL braucht die xShm-Rueckrufe der VFS fuer geteilten Speicher. In
/// package:sqlite3 3.5.0 kommt "xShm" in lib/src/wasm/ NICHT EIN EINZIGES MAL
/// vor (nachgesehen am 30.07.2026; auch die FFI-Fassung setzt fuer in Dart
/// geschriebene VFS iVersion = 1, src/ffi/bindings.dart:392). SQLites
/// sqlite3PagerWalSupported verlangt iVersion >= 2 UND xShmMap != 0 und liefert
/// sonst SQLITE_CANTOPEN. Das PRAGMA selbst laeuft dabei moeglicherweise noch
/// durch und der Fehler faellt erst bei der ersten Schreibtransaktion — also an
/// einer Stelle, die mit Journalen nichts zu tun hat.
///
/// DELETE und nicht MEMORY: MEMORY haelt das Rollback-Journal im
/// Arbeitsspeicher und gibt damit die Alles-oder-nichts-Zusage der Transaktion
/// auf. Genau die ist der Grund, warum es diese Transaktionen gibt.
const String journalModus = 'DELETE';
