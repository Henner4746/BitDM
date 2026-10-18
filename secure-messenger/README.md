# secure-messenger

The code behind BitDM. What BitDM is, what works and what does not is in the
[README of the repository](../README.md) ([Deutsch](../README.de.md)). This
page only says where things are.

| Folder | What is in it |
|---|---|
| `app/` | the Flutter app for Android, Windows, Linux and the web |
| `server/` | relay and blob store in Python, with their tests |
| `docs/` | operations, specifications, measurements, review findings (mostly German) |
| `website/` | bitdm.net |
| `deploy/` | relay installer, web app, onion service, storage monitor, IndexNow |
| `fdroid/` | F-Droid build recipe and the own repository at bitdm.net/fdroid |
| `tools/` | test runs on phones, emulators and a PC |
| `nah-test/` | throwaway app for a Wi-Fi Direct test, not part of BitDM |
| `core/` | the first crypto prototype in Python (July 2026); the app does not use it |
| `prototype/` | the first web mock-up of the interface, with made-up data |

`DESIGN.md` and `PRODUCT.md` describe the look of the interface and who it is
for.

Until 18.10.2026 this page held the design notes from July 2026, written
before the app existed. They are kept in
[`docs/ENTWURF-2026-07.md`](docs/ENTWURF-2026-07.md); much of it no longer
holds.
