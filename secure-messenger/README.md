# Secure Messenger (Arbeitstitel)

Ein Ende-zu-Ende verschlüsselter Messenger im Stil von **CREO / Session**:
keine Handynummer, kein Username — deine Identität ist ein kryptografischer
Schlüssel, und die "lange Nummer" zum Hinzufügen ist dein *öffentlicher* Schlüssel.

## Konzept

| | |
|---|---|
| **Identität** | X25519-Schlüsselpaar, einmalig auf dem Gerät erzeugt. Privater Schlüssel verlässt das Handy nie. |
| **Deine ID** | = öffentlicher Schlüssel, als lange ID kodiert (mit Prüfsumme). Das teilst du. |
| **Kontakt adden** | Du fügst jemanden über seine ID hinzu. Keine Registrierung, keine Nummer. |
| **Verschlüsselung** | ECDH (X25519) → HKDF → **AES-256-GCM**. Server sieht nur Zeichensalat. |

## Architektur (3 Teile)

```
 [ Android-App ]  <--- verschlüsselt --->  [ Relay-Server ]  <--- verschlüsselt --->  [ Android-App ]
   Krypto + GUI                             leitet nur                                  Krypto + GUI
   Schlüssel lokal                          Zeichensalat weiter                         Schlüssel lokal
                                            (kann NICHT mitlesen)
```

1. **Krypto-Kern** — `core/crypto_core.py` ✅ (fertig, lauffähig)
   Identität, ID-Kodierung, Ver-/Entschlüsselung. Ist gleichzeitig die *Spezifikation*,
   die die App 1:1 nachbaut.
2. **Relay-Server** — Python (FastAPI + WebSocket). Nimmt verschlüsselte Nachrichten
   entgegen, stellt sie zu, speichert sie zwischen wenn der Empfänger offline ist.
   Sieht **nur Ciphertext**. → kann auf deinem VPS laufen.
3. **Android-App** — Flutter, Krypto via `libsignal_protocol_dart`. Cleanes GUI,
   erzeugt Schlüssel, zeigt deine ID (auch als QR), Kontakte adden, chatten.

## Entscheidungen (v1)

- **App:** Flutter (eine Codebasis, cleanes GUI); Krypto via **`libsignal_protocol_dart`** — echtes Signal-Protokoll, **Double Ratchet + Forward Secrecy von Anfang an**.
- **Server:** Python-Relay auf dem VPS (77.90.4.46).
- **Umfang v1:** 1:1-Textchat.

## Roadmap

- [x] **Phase 0** — Krypto-Kern + ID-System (Proof of Concept, Python)
- [x] **Phase 1** — Relay-/Key-Server (Python, FastAPI + WebSocket): Prekey-Bundles, Auth, Live- & Offline-Zustellung. **Getestet, 4/4 ✅**
- [ ] **Phase 2** — Flutter-App MVP: Identität erzeugen, ID anzeigen/teilen (QR), Kontakt adden, X3DH + Double Ratchet über libsignal, 1:1-Textchat
- [ ] **Phase 3** — Cleanes GUI (Chat-Liste, Chat-Screen), Feinschliff
- [ ] **Phase 4** — Härtung: Server-Persistenz (SQLite), Push-Notifications, Medien, VPS-Deployment mit TLS

## Faktencheck "256 vs. 512 Bit"

Ehrlich, damit du's weißt: **AES-256 ist der Goldstandard** — das nutzen Signal,
WhatsApp, iMessage. "512-Bit-Verschlüsselung" (wie CREO wirbt) gibt es bei
symmetrischer Verschlüsselung praktisch nicht und ist reines Marketing; 256 Bit
sind schon jenseits von "knackbar". Sicherheit kommt **nicht** von einer größeren
Zahl, sondern vom *Protokoll* (Schlüsseltausch + Forward Secrecy). Wir bauen es
deshalb auf AES-256 + X25519 auf — genau wie die Großen.

## Ausprobieren

Krypto-Kern (Alice & Bob schreiben sich):
```bash
py -m pip install cryptography
py core/crypto_core.py
```

Relay-Server + End-to-End-Test:
```bash
py -m pip install fastapi uvicorn websockets httpx
py -m uvicorn relay_server:app --app-dir server --host 127.0.0.1 --port 8099
py server/test_relay.py
```

GUI-Prototyp (**BitDM**, Direction „Nocturne") — lauffähige Web-Umsetzung des Designs.
UI-only (Mock-Daten, noch keine Krypto), responsive: am Desktop im Handy-Rahmen,
am Handy im Vollbild wie eine echte App. Vorlage für die Flutter-Screens, mappt 1:1 aufs
[MessengerCore-Interface](app/lib/core/messenger_core.dart).

**Am PC ansehen:**
```bash
py -m http.server 8123 --directory prototype
```
→ [http://127.0.0.1:8123](http://127.0.0.1:8123)

**Am Handy testen** (Handy im selben WLAN), Server für LAN starten:
```bash
py -m http.server 8123 --bind 0.0.0.0 --directory prototype
```
Dann am Handy `http://<PC-LAN-IP>:8123` öffnen (LAN-IP via `ipconfig`). Vollbild-Modus,
`≡`-Button unten rechts springt zwischen allen Screens. Für App-Feeling: Browser-Menü →
„Zum Startbildschirm hinzufügen" (installiert BitDM als Standalone-App-Icon).
Falls das Handy nicht verbindet: Port 8123 in der Windows-Firewall für „Privat" erlauben.

### Native Android-App (`app/`)

Flutter-Port des UI (Nocturne), gebaut mit Flutter 3.44.8 — installierbare **`app-release.apk`**.
UI-only (Mock-Daten), Krypto/Backend werden später über das MessengerCore-Interface angebunden.
```bash
# einmalig JAVA_HOME/ANDROID_HOME setzen, dann im app/-Ordner:
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk (~69 MB)
```
Aufs Handy: APK am Handy von `http://<PC-LAN-IP>:8123/BitDM.apk` laden und installieren
(„Unbekannte Quellen/Apps installieren" erlauben). Toolchain: Flutter `C:\Users\Lennard\flutter`,
JDK 17 (Temurin), Android-SDK `C:\Users\Lennard\Android\sdk`.
