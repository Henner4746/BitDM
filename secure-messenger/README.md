# Secure Messenger (Arbeitstitel)

Ein Ende-zu-Ende verschlüsselter Messenger im Stil von **CREO / Session**:
keine Handynummer, kein Username — deine Identität ist ein kryptografischer
Schlüssel, und die "lange Nummer" zum Hinzufügen ist dein *öffentlicher* Schlüssel.

## Konzept

| | |
|---|---|
| **Identität** | Curve25519-Schlüsselpaar, abgeleitet aus einer **BIP39-Seed-Phrase** (12 Wörter). Privater Schlüssel verlässt das Gerät nie. |
| **Deine ID** | = öffentlicher Schlüssel als **56-stellige Adresse** (Base32 + 3-Byte-Prüfsumme), angezeigt in 14 Gruppen à 4. Das teilst du. |
| **Kontakt adden** | Du fügst jemanden über seine Adresse hinzu. Keine Registrierung, keine Nummer. |
| **Verschlüsselung** | **Signal-Protokoll**: X3DH für den Sitzungsaufbau, Double Ratchet für Forward Secrecy. Server sieht nur Zeichensalat. |
| **Wiederherstellung** | Neues Gerät: 12 Wörter eingeben → gleiche Identität. Nachrichten kommen **nicht** zurück, nur Identität und Kontakte. |

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

- **App:** Flutter (eine Codebasis, cleanes GUI); Krypto via **`libsignal_protocol_dart` 0.8.2** — echtes Signal-Protokoll, **Double Ratchet + Forward Secrecy von Anfang an**.
- **Server:** Python-Relay auf dem VPS, erreichbar über **Hostnamen** (nie über die rohe IP — sonst wäre jeder Umzug ein Zwangsupdate).
- **Umfang v1:** 1:1-Textchat, ein Gerät je Identität.
- **Lizenz:** **AGPL-3.0** (Volltext in [LICENSE](LICENSE), festgelegt am 26.07.2026) — quelloffen ist bei einem Sicherheitsversprechen Voraussetzung, nicht Beiwerk. Vertrieb später über F-Droid *und* Play.

  Warum AGPL statt GPL: dieses Projekt besteht nicht nur aus einer App, sondern auch aus dem Relay in `server/`. Die GPL greift erst beim *Verteilen* von Programmen — wer einen abgewandelten Relay bloß betreibt, verteilt nichts und müsste seine Änderungen nie herausgeben. Genau das ist hier der Fall, der zählt: der Server sieht, wer wann online ist. Die AGPL schließt diese Lücke und passt damit zu dem Versprechen, dass jeder seinen eigenen Server betreiben kann und niemand eine geschlossene Abwandlung davon anbieten darf.

> Vollständiges Entscheidungsprotokoll samt Begründungen, Sicherheitsbefunden und
> Phasenplan: **[`../PLAN.md`](../PLAN.md)**

## Roadmap

- [x] **Krypto-Kern + ID-System** (Proof of Concept, Python)
- [x] **UI-Gestaltung** (Lennard) — Screens fertig, aber noch ohne Anbindung an den Core
- [x] **Relay-/Key-Server gehärtet** — Besitznachweis, XEdDSA, SQLite, Rate-Limits, Queue-Grenzen. **15/15 Tests ✅**
- [x] **Android-Sicherheitsbefunde** — echter Signaturschlüssel, Auto-Backup aus, Schriften lokal, Versionen gepinnt
- [ ] **Erste echte Ende-zu-Ende-Nachricht** über den Relay (Seed, libsignal, verschlüsselte DB, WebSocket-Client)
- [ ] **UI-Umbau** — Zustandsschicht bauen, an den Core hängen; Optik bleibt unangetastet
- [ ] **Empfangsmodi + Build-Varianten** (F-Droid ohne Google, Play mit FCM)
- [ ] **Lokaler Modus** — ohne Internet, per Bluetooth finden und Wi-Fi Direct übertragen

Reihenfolge und Begründungen: **[`../PLAN.md`](../PLAN.md) §5**

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

Relay-Server + End-to-End-Test (Abhängigkeiten sind exakt gepinnt):
```bash
py -m pip install -r server/requirements.txt
```
Server starten (in einem eigenen Fenster):
```bash
py -m uvicorn relay_server:app --app-dir server --host 127.0.0.1 --port 8099
```
Tests laufen lassen:
```bash
py server/test_relay.py
```
Geprüft werden nicht nur Registrierung und Zustellung, sondern gezielt die
Angriffe: Registrierung ohne Besitznachweis, mit falscher Signatur, Überschreiben
fremder Bundles, Prekey-Drain, übergroße Umschläge, Doppelzustellung.

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

**Zwei Fallen beim Bauen unter Windows** — beide kosten sonst jedes Mal drei Anläufe:

- **`Unable to delete directory … mergeReleaseAssets`.** Ein Gradle-Dämon hält
  Dateien offen. Lösung: `cd android && ./gradlew --stop`, dann `rm -rf build`.
  **Nicht** die Prozesse abschießen — dabei stirbt `adb` mit, und ein
  angeschlossenes Telefon ist weg.
- **`Package dev.flutter.plugins.integration_test ist nicht vorhanden`.** Wer
  vorher einen Gerätetest gefahren hat (`flutter test integration_test/…`),
  hat damit `GeneratedPluginRegistrant.java` mit dem Testplugin neu schreiben
  lassen; im Release-Bau gibt es das Paket nicht. `flutter pub get` erzeugt
  dieselbe Datei wieder — nur **`flutter clean`** hilft, danach baut es durch.
Aufs Handy: APK am Handy von `http://<PC-LAN-IP>:8123/BitDM.apk` laden und installieren
(„Unbekannte Quellen/Apps installieren" erlauben). Toolchain: Flutter `C:\Users\Lennard\flutter`,
JDK 17 (Temurin), Android-SDK `C:\Users\Lennard\Android\sdk`.
