# Unabhängiges Sicherheitsaudit — Wege dahin und vorbereiteter Antrag

Stand 25.09.2026. BitDM hat **kein externes Audit**. Ein professionelles Audit
eines Messengers kostet üblicherweise fünfstellig; die Wege unten bezahlen es
für freie Software. Eingereicht werden kann nur von Henrik (Konto,
Identität, Zusagen) — der Text ist vorbereitet.

## Die Wege, nach Eignung

| Programm | Was es gibt | Passt, weil | Haken |
|---|---|---|---|
| **OTF Security Lab** (früher Red Team Lab) — <https://www.opentech.fund/labs/security-lab/>, Antrag: <https://apply.opentech.fund/security-lab/> | Audit durch einen Partner (z. B. Cure53, Include Security, Assured), kostenlos für das Projekt | Messenger ohne Telefonnummer, Tor/Onion, Nahbereich ohne Internet = „Internet Freedom" | Nutzer in Ländern mit Überwachung müssen plausibel sein; Wartezeit; US-Förderung (USAGM) |
| **NLnet — Open Internet Stack** — <https://nlnet.nl/propose/>, nächste Frist **3. November 2026, 12:00 CET** | Förderung 5–50 k€, dazu Audit durch Radically Open Security als Zusatzleistung | Europäisches Projekt, freie Lizenz (AGPL), Datensparsamkeit | Audit nur im Paket mit Förderung; NLnet will ausdrücklich keine KI-erzeugten Projekte oder Anträge — der Antrag muss von Henrik selbst stammen, und dass große Teile des Codes mit KI-Hilfe entstanden sind, gehört offen gesagt |
| **GitHub Secure Open Source Fund** — <https://github.com/open-source/github-secure-open-source-fund> | 10 000 USD + dreiwöchiges Sicherheitsprogramm | Öffentliches Repo auf GitHub | Kein Audit durch Dritte, sondern Schulung; bevorzugt verbreitete Projekte |
| **OSTIF** — <https://ostif.org/get-an-audit/> | Verwaltet Audits, sucht Geldgeber | — | Realistisch nur für verbreitete oder stiftungsgestützte Projekte |

**Empfehlung:** zuerst OTF Security Lab (passt inhaltlich am besten, kein
Förderantrag nötig), parallel NLnet zur Frist am 3. November.

## Was schon ohne Geld läuft (kein Ersatz für ein Audit)

- Eigene Prüfungen mit Befunden: [`BEFUNDE-2026-07-26.md`](BEFUNDE-2026-07-26.md)
  und die Prüfung vom 25.09.2026 (Changelog 1.8.1).
- Automatisch bei jedem Push: `flutter analyze`, 1000+ Tests, `pytest`
  (`.github/workflows/ci.yml`).
- Abhängigkeiten gegen die OSV-Datenbank geprüft (25.09.2026: 121 Dart-Pakete,
  Server-Pakete — keine bekannten Schwachstellen), Bandit über den Server.
- Private Meldungen über GitHub und kontakt@bitdm.net ([`SECURITY.md`](../../SECURITY.md)).

## Vorbereiteter Antragstext (OTF Security Lab)

**Project name:** BitDM

**Website / source:** https://bitdm.net — https://github.com/Henner4746/BitDM (AGPL-3.0)

**Short description:** BitDM is an end-to-end encrypted messenger that needs
no phone number, e-mail or account. The address is the public key itself; an
identity is created on the device and restored from twelve words. Messages use
the Signal protocol (X3DH + Double Ratchet via libsignal_protocol_dart) through
a small relay that stores only padded ciphertext for at most 14 days. Nearby
mode delivers messages phone-to-phone over Bluetooth LE without any internet.
The relay is also reachable as a Tor onion service, and the app can route all
traffic through Orbot. Platforms: Android, Windows, Linux, and a browser build.

**Why it matters for internet freedom:** Phone-number-based messengers tie
every account to a SIM registered with a real identity in many countries, and
shut-downs cut them off entirely. BitDM needs neither: no identifier beyond a
key, and nearby delivery keeps working when the network is switched off.

**What we want audited (scope):**
1. Cryptographic design and its use: identity derivation from the recovery
   words, Signal session handling incl. multi-device, group fan-out, the
   encrypted local database (SQLite3MultipleCiphers), app lock (Argon2id),
   Shamir-shared recovery words, encrypted backups.
2. The relay and the attachment store (Python/FastAPI): authentication by
   signature challenge, what metadata they can see, abuse resistance.
3. Nearby mode over BLE: what a nearby attacker can learn or disrupt.
4. Android platform integration: exported components, key storage,
   foreground service, file handling.
5. Remote wipe by trusted contacts (k-of-n) and view-once media.

**Size:** ~34 000 lines Dart, ~2 800 lines Kotlin, ~4 000 lines Python.

**Team:** one maintainer. **Users:** early stage, public releases since
September 2026. **Previous audits:** none external; internal reviews
documented in the repository.

**Disclosure:** we agree to coordinated disclosure and publishing the report
after fixes.
