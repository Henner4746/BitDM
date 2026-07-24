# BitDM — Projektplan

Stand: 2026-07-25. Ersetzt `secure-messenger/docs/TEAM-PLAN.md` (dort sind mehrere
Annahmen inzwischen widerlegt, siehe §6).

---

## 1. Was BitDM ist

Ein Ende-zu-Ende verschlüsselter Messenger ohne Telefonnummer und ohne Username.
Die Identität **ist** ein kryptografischer Schlüssel; die Adresse zum Weitergeben
ist dessen öffentlicher Teil. Krypto nach Signal-Protokoll (X3DH + Double Ratchet).
Server sieht ausschließlich Chiffrat.

**Zielgruppe:** zunächst privat (Freundeskreis), später öffentlich.
**Lizenz:** GPL-3.0 — quelloffen ist Pflicht, nicht Option.
**Vertrieb später:** Google Play **und** F-Droid parallel.

---

## 2. Entscheidungsprotokoll

Alle Punkte sind bewusst entschieden. Änderung nur mit Begründung im Repo.

### Identität und Schlüssel

| Punkt | Festlegung |
|---|---|
| Wiederherstellung | **BIP39, 12 Wörter** (128 Bit) — passt zum Sicherheitsniveau von X25519; 24 Wörter wären Zahlenkosmetik |
| Schlüsselwurzel | Seed → HKDF → **zwei getrennte Ableitungen** über verschiedene Labels: Identitätsschlüssel und Datenbankschlüssel |
| Adressformat | `base32(pubkey32 ‖ sha256(pubkey)[:3])` = **exakt 56 Zeichen**, kleingeschrieben, nie Padding. Anzeige: **14 Gruppen à 4** |
| Mehrere Geräte | v1 einzelnes Gerät. Wiederherstellung erzeugt neue `registrationId` + frische Prekeys → **„letzte Wiederherstellung gewinnt"**, altes Gerät wird stillgelegt |
| Verlauf | Nachrichten sind nach Wiederherstellung **nicht** zurück — nur Identität und Kontakte. Verschlüsseltes Verlaufs-Backup bleibt später nachrüstbar, weil der DB-Schlüssel aus dem Seed stammt |

### Warum 3-Byte-Prüfsumme statt 2

35 Bytes gehen in Base32 **glatt** auf (7 Blöcke à 5 Bytes → 56 Zeichen, nie ein
`=`). Damit entfällt der `rstrip("=")`-Hack aus `crypto_core.py:58`, und die
Tippfehlererkennung steigt von 16 auf 24 Bit.

### Krypto

| Punkt | Festlegung |
|---|---|
| Bibliothek | `libsignal_protocol_dart` **0.8.2** (Publisher mixin.dev, ~6,3k Downloads/Woche, pures Dart). Bewusst **nicht** das `libsignal`-Rust-Paket: AGPL, unverifizierter Uploader, 3 Likes |
| Sitzungsaufbau | X3DH · Forward Secrecy: Double Ratchet |
| Umschlag | `base64(version ‖ msg_type ‖ signal_message)`. **`msg_type` ist Pflicht** — Empfänger muss PreKey- von Ratchet-Nachricht unterscheiden. `id`, `kind`, `timestamp` liegen **verschlüsselt innen** |
| Server-Auth | **XEdDSA**, nicht Ed25519 (siehe §4, Befund S1) |
| Safety Number | 60 Ziffern, 12 Gruppen à 5 — Signal-Format |

### Server

| Punkt | Festlegung |
|---|---|
| Standort | `henner` (77.90.4.46), aber **isoliert**: eigener unprivilegierter Nutzer, systemd-Härtung, Bindung nur auf `127.0.0.1`, nginx davor |
| Adressierung | Client bekommt **Hostnamen**, nie eine rohe IP — sonst ist jeder Umzug ein Zwangsupdate |
| Persistenz | SQLite. Kein Docker, ein Prozess |
| Aufbewahrung | IPs anonymisiert, 7 Tage, DB separat verschlüsselt im Backup. **Umschaltbar per Konfiguration** auf strikte Datensparsamkeit vor dem öffentlichen Schritt |
| Ressourcen | Kein echter Engpass (16 GiB, 8,1 frei, Last 0,13). Trotzdem schlank bauen |

**Bewusst akzeptiert:** Der Relay sieht `from`, `to` und Zeitstempel — den
vollständigen Sozialgraphen. Ende-zu-Ende-Verschlüsselung schützt das
prinzipiell nicht. Für die private Phase akzeptiert, **vor dem öffentlichen
Schritt ein Blocker** (Gegenmittel: Sealed Sender).

### App

| Punkt | Festlegung |
|---|---|
| Empfang (Standard) | **Sparmodus** — System weckt alle ~15 Min, App holt Warteschlange, trennt wieder. Kein Dauerdienst, kein 6-Stunden-Limit, kein Dauer-Symbol |
| Empfang (Optionen) | „Immer verbunden" (Vordergrunddienst, `specialUse`) · „nur beim Öffnen" |
| Play-Variante | FCM statt Sparmodus — dort sparsamer *und* schneller |
| F-Droid-Variante | Nie Google. Abhängigkeiten **exakt gepinnt** (reproduzierbare Builds) |
| UI | Lennards Optik bleibt **unangetastet**. Struktur wird nachgezogen: `lib/ui/` + `lib/state/` |

### Lokaler Modus (ohne Internet)

| Punkt | Festlegung |
|---|---|
| Zweck | Kein WLAN, kein Mobilfunk — Festival, Zug, Ausfall |
| Technik | **BLE zum Finden, Wi-Fi Direct zum Übertragen** |
| Mindestversion | **Android 12+**, damit nie eine Standortberechtigung nötig wird (`BLUETOOTH_SCAN` + `neverForLocation`). Rest der App bleibt ab Android 7 |
| Aktivierung | **Nur auf Knopfdruck**, nie im Hintergrund — sonst frisst die Funksuche den Akku |
| Google Nearby | **Nein.** Würde alles vereinfachen, ist aber Teil der Play-Dienste → bricht F-Droid |
| Krypto | Identisch. Gleicher Umschlag, gleiche Session, nur anderer Transportweg. Erstkontakt geht direkt — der Server erfährt nie, dass sich zwei Leute kennen |

**Sichtbarkeitsfalle:** Naive Gerätesuche kündigt die Adresse im Netz an und
verrät „Nutzer X ist hier" — schlimmer als das Relay-Leck. Gegenmittel:
**rotierende Kennungen**, die nur bekannte Kontakte wiedererkennen.

---

## 3. Architektur

```
BIP39 (12 Wörter)
   └─ Seed
       ├─ HKDF(info="bitdm identity v1") → Curve25519-Identitätsschlüssel → Adresse
       └─ HKDF(info="bitdm db v1")       → SQLCipher-Schlüssel
```

```
      ┌──────────── Transportschicht (austauschbar) ────────────┐
App ──┤  WebSocket → Relay (henner)                             ├── App
      │  BLE + Wi-Fi Direct → direkt (lokaler Modus)            │
      └─────────────────────────────────────────────────────────┘
              gleicher Umschlag · gleiche Signal-Session
```

Der Relay bleibt **dumm**: er speichert Prekey-Bundles, schiebt undurchsichtige
Blobs zwischen zwei Adressen und puffert für Offline-Empfänger. Er entschlüsselt nie.

---

## 4. Sicherheitsbefunde

### Offen — Server

**S1 · XEdDSA-Fehlanpassung.** `relay_server.py:135` prüft mit
`Ed25519PublicKey.verify()`. libsignal-Identitätsschlüssel sind aber Curve25519
und signieren per XEdDSA. Pythons `cryptography` kann das nicht — **die Auth
bricht, sobald der echte Client sich verbindet.** Lösung: `XEdDSA`-Paket (PyPI
1.2.0, braucht libsodium).

**S2 · `/register` ohne Besitznachweis.** `relay_server.py:101` prüft nur
`encode_id(identity_key) == user_id` — selbstreferenziell. Wer eine öffentliche
Adresse kennt, kann das fremde Bundle überschreiben: Sessions brechen,
Prekey-Pool ist weg. Vollständige Übernahme scheitert nur daran, dass libsignal
clientseitig `signed_prekey_sig` prüft — die Verteidigung liegt also zufällig
beim Client. Zu dünn. Lösung: signierte Nonce.

**S3 · Prekey-Drain.** `/prekey/{user_id}` hat kein Rate-Limit; jeder Aufruf
verbraucht einen One-Time-Prekey (`relay_server.py:116`). Schleife leert den Pool.

**S4 · Unbegrenzte Offline-Queue** im RAM (`relay_server.py:83`) → Speicher-DoS.

**S5 · Alles im RAM**, `except (InvalidSignature, Exception)` schluckt jeden Fehler.

### Offen — Android

**A1 · Release-APK mit Debug-Schlüssel signiert.** `build.gradle.kts:32` setzt
`signingConfig = signingConfigs.getByName("debug")`. Die ausgelieferte APK trägt
`CN=Android Debug`, SHA-256 `9a3d9f97…` — den **universellen Debug-Schlüssel, der
auf jedem Rechner mit Android-SDK identisch liegt**, Passwort „android". Jeder
kann damit eine APK bauen, die Android als gültiges Update für BitDM akzeptiert.
Die App-Signatur ist die äußerste Vertrauensschicht; ist sie offen, ist die
Signal-Krypto darunter wirkungslos.

**A2 · Auto-Backup aktiv.** Kein `android:allowBackup="false"` im Manifest →
Standard ist `true`. Android sichert den privaten App-Ordner nach Google Drive —
künftig also Schlüsselmaterial und verschlüsselte Nachrichten-DB. Widerspricht
direkt „private Keys verlassen das Gerät nie". Braucht zusätzlich
`dataExtractionRules` (Android 12+).

**A3 · `google_fonts` lädt zur Laufzeit.** Keine `fonts:`-Sektion in
`pubspec.yaml`, in `flutter_assets/fonts` liegt nur ein 1.256-Byte-Icon-Stub. Die
App holt Schriften bei jedem Kaltstart von `fonts.gstatic.com` — Google erfährt
IP und Zeitstempel jedes Starts. In einer App, die mit „keine Telefonnummer, kein
Username" wirbt, ein Selbstwiderspruch. Nebeneffekt: `http`, `crypto` und
`path_provider` sind **nur** über `google_fonts` transitiv drin — bundelt man die
Schriften, verschwindet der gesamte Netzwerk-Stack.

**A4 · Caret-Bereiche statt exakter Pins** (`pubspec.yaml:36-37`) → keine
reproduzierbaren Builds, für F-Droid Pflicht.

### Erledigt / zurückgezogen

- ~~`android.permission.DUMP`~~ — Fehlbefund. Rohe String-Suche im Binär-XML;
  mit `aapt2` geprüft hat die App nur `INTERNET` und die von AndroidX erzeugte
  `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`.
- ~~„Profile-Build"~~ — Fehlbefund. Kein `debuggable`-Flag → echter Release-Build.
  Die 72 MB sind drei Architekturen in einer APK (`flutter build apk --release`
  ohne `--split-per-abi`).
- `minSdk 24` ✓ (libsignal braucht ≥ 24), `targetSdk 36`, `compileSdk 36`, Java 17,
  `pubspec.lock` eingecheckt.

---

## 5. Phasen

### Phase 0 — Absichern *(zuerst, klein)*

1. `git init` in `BitDM/`, **Lennards Stand als erster Commit** — ab da ist nichts
   mehr verlierbar
2. `BitDM/` in `C:\KI-Workstation/.gitignore` eintragen, damit ein `git add .` das
   Projekt nicht in Henriks persönliches Repo mit VPS-Doku, Audit-Berichten und
   Finanzskripten zieht
3. Privates GitHub-Repo als Remote; später per Schalter öffentlich

### Phase 1 — Bestehende Risiken schließen

Befunde A1–A4. Kleine, isolierte Änderungen. Danach ist die App nicht mehr
schlechter geschützt als nötig.

### Phase 2 — Relay härten

Befunde S1–S5. Zusätzlich: systemd-Härtung, eigener Nutzer, nginx + TLS,
Aufbewahrungsregeln, Hostname statt IP. Hängt an nichts anderem.

### Phase 3 — Erste echte Nachricht *(das Kernziel)*

Zwei Geräte tauschen eine echte Signal-verschlüsselte Nachricht über den
gehärteten Server. Umfasst: Seed-Ableitung, libsignal mit den vier
Store-Implementierungen, `flutter_secure_storage`, SQLCipher, WebSocket-Client
mit XEdDSA-Auth und Reconnect, Prekey-Verwaltung. Oberfläche nur so viel wie nötig.

**Erfordert Interface-Erweiterung:** `initialize({String? recoveryPhrase})` und
`getRecoveryPhrase()`. Das Interface ist nicht mehr eingefroren (Lennard ist raus).

### Phase 3b — Wegwerf-Test Funk *(parallel, früh)*

Ohne Krypto, ohne Anbindung: Finden sich zwei Geräte per BLE, kommt eine
Wi-Fi-Direct-Verbindung zustande? Über Samsung/Xiaomi/Pixel testen. **Die einzige
echte Unbekannte im Projekt** — sie muss früh beantwortet sein, nicht nach Monaten.
Fällt sie negativ aus, wird der lokale Modus auf „nur BLE" reduziert, was für
4-KB-Textnachrichten völlig reicht.

### Phase 4 — UI-Umbau und Verdrahtung

Das eine 1034-Zeilen-Widget mechanisch in `lib/ui/` und `lib/state/` zerlegen —
**ohne eine einzige Design-Entscheidung anzufassen**. Dann an den Core hängen.
Neue Screens: Seed anzeigen + bestätigen, Wiederherstellung, Safety Number,
Kontaktanfragen.

### Phase 5 — Empfangsmodi und Build-Varianten

Drei Modi, zwei Gradle-Varianten (F-Droid ohne Google, Play mit FCM),
reproduzierbare Builds.

### Phase 6 — Lokaler Modus

BLE-Suche mit rotierenden Kennungen, Wi-Fi-Direct-Übertragung, Umschaltlogik.
Nativer Android-Code über Plattformkanäle. **Größter Einzelposten des Projekts.**

---

## 6. Was in den alten Unterlagen nicht mehr stimmt

- `TEAM-PLAN.md:124` — „bei M2 wird nur **eine Zeile** getauscht:
  `MockMessengerCore()` → `RealMessengerCore()`". **Widerlegt.** `main.dart`,
  `data.dart` und `painters.dart` enthalten **keine einzige Referenz** auf
  `MessengerCore`. Die Trennung wurde dokumentiert, nie verdrahtet. Die gesamte
  Zustandsschicht fehlt; die App ist ein StatefulWidget mit 32 `setState` und fest
  eingetippten Konstanten (`data.dart:4`).
- `TEAM-PLAN.md:48` — die Ordner `lib/ui/` und `lib/state/` existieren nicht.
- `DECISIONS.md:14` — „keine Recovery" ist durch die Seed-Phrase ersetzt.
- `README.md:37`, `TEAM-PLAN.md:66` — rohe IP `77.90.4.46` → Hostname.
- Rollenaufteilung — Lennard ist raus, das Interface ist nicht mehr eingefroren.

---

## 7. Bewusst nicht in v1

| | Warum |
|---|---|
| Gruppen | Eigenes Protokoll (Sender Keys) |
| Mehrere Geräte gleichzeitig | Sesame-Protokoll, großer Aufwand |
| Lesebestätigungen, verschwindende Nachrichten | Gehören in den Core, brauchen Interface-Änderung → v1.1 |
| Medien (Bilder, Dateien) | Erst wenn Wi-Fi Direct steht |
| Sealed Sender | **Blocker vor dem öffentlichen Schritt**, nicht vorher |

## 8. Bekannte Risiken

1. **Wi-Fi Direct über Herstellergrenzen** — größte technische Unbekannte, wird in
   Phase 3b früh geprüft.
2. **`specialUse`-Vordergrunddienst im Play-Review** — Google verweist gern auf
   FCM. Entschärft dadurch, dass die Play-Variante ohnehin FCM nutzt.
3. **Metadaten beim Relay** — akzeptiert für privat, Blocker für öffentlich.
4. **Schadensreichweite auf `henner`** — der Relay teilt die Maschine mit Mailcow,
   Spieleservern und einem LLM-Gateway. Dieselbe Kiste wurde am 12.07.2026 über
   einen exponierten Port übernommen. Isolation mildert, beseitigt nicht.
5. **Kein Android-Spezialist im Team** — Phasen 5 und 6 sind nativ-lastig.
