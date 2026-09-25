# SQLite3 Multiple Ciphers — Amalgamation

Unveraendert aus dem offiziellen Release:

- Quelle: https://github.com/utelle/SQLite3MultipleCiphers/releases/tag/v2.3.6
- Datei: `sqlite3mc-2.3.6-sqlite-3.53.3-amalgamation.zip`
- SHA-256 des Zip: `bbd0434f9456d810cd1bb8d3767985f18f6b84648f1cd9cd1db6ccfb01819da2`
  (stimmt mit dem Digest ueberein, den GitHub fuer das Release-Asset angibt)
- Lizenz: SQLite3 Multiple Ciphers MIT, SQLite selbst gemeinfrei.

WARUM HIER. Bis 1.7.0 lud der Bau-Hook von `package:sqlite3` eine fertige
`libsqlite3mc.so` herunter. F-Droid baut aber grundsaetzlich aus Quelltext;
seitdem uebersetzt der Hook diese Datei selbst (`hooks.user_defines.sqlite3`
in `pubspec.yaml`, `source: source`). Die Fassung ist dieselbe, die
`package:sqlite3` 3.5.0 vorgebaut ausliefert (CHANGELOG: SQLite 3.53.3,
Multiple Ciphers 2.3.6). Die App setzt das Verfahren ausdruecklich
(`PRAGMA cipher = 'chacha20'`), vorhandene Datenbanken bleiben also lesbar —
am 25.09.2026 mit einer Datei aus der vorgebauten Bibliothek geprueft.

Beim Aktualisieren von `package:sqlite3`: diese Dateien auf die Fassung aus
dessen CHANGELOG mitziehen.
