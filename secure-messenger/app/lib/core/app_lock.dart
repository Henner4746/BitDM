// app_lock.dart — die Fehler, die beim Sperren auftreten koennen.
//
// WAS HIER FRUEHER STAND
// Ein SecretStore mit zwei Stufen: die Entropie im Schluesselspeicher,
// wahlweise mit oder ohne Anmeldezwang. Das trug genau EINEN Faktor. Sobald
// ein zweiter dazukam, ging es nicht mehr — die Entropie laege dann an zwei
// Stellen, und die schwaechere entscheidet. Ein Hardware-Stick waere wertlos,
// wenn dieselbe Entropie daneben ohne ihn zu haben ist.
//
// Abgeloest hat ihn lib/core/lock/vault_store.dart: die Entropie liegt nur
// noch verschluesselt, in je einem Fach pro Faktor. Der alte Speicher ist
// ENTFERNT und nicht bloss ungenutzt liegen geblieben. Toter Code an dieser
// Stelle waere eine Einladung, ihn wieder anzuschliessen — mit genau der
// Schwaeche, wegen der er weg ist.
//
// Geblieben sind die beiden Fehler. Sie beschreiben Zustaende, nicht
// Umsetzungen, und werden vom Kern wie von der Oberflaeche gebraucht.

/// Die Sperre laesst sich auf diesem Geraet nicht einrichten.
///
/// Haeufigster Fall: das Telefon hat gar keine Bildschirmsperre. Dann gibt es
/// nichts, woran sich ein Schluessel binden liesse.
class LockUnavailableException implements Exception {
  final String grund;
  const LockUnavailableException(this.grund);
  @override
  String toString() => 'LockUnavailableException: $grund';
}

/// Es gibt eine Identitaet, sie ist nur nicht zu haben.
///
/// Kein Fehler, sondern der Zweck der Sperre: das Fach ist zu, und welcher
/// Faktor es oeffnen soll, entscheidet die Oberflaeche — ein Schluesselspeicher
/// kann nicht nachfragen, ob gerade ein Stick anliegt.
class LockedException implements Exception {
  const LockedException();
  @override
  String toString() => 'LockedException: die App ist gesperrt';
}
