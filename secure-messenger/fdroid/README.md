# F-Droid — bereit zum Einreichen ab 1.9.1

Stand 14.10.2026. Das Rezept `com.bitdm.bitdm.yml` besteht `fdroid lint` und
ist in F-Droids Normalform (`fdroid rewritemeta` ändert nichts, fdroidserver
2.4.5). Eingereicht wird es mit der ersten Fassung, die nach dem Ablauf unten
gebaut ist — 1.9.1. Die 1.9.0-APK kann F-Droid nicht nachbauen (siehe Messung).

## Was F-Droid verlangt, und wie es hier gelöst ist

| Vorgabe (MR-Vorlage „App inclusion“) | Stand |
|---|---|
| Store-Texte, Bilder, Changelogs im Fastlane-Format, `en-US` dabei | `app/fastlane/metadata/android/` (en-US, de-DE), Changelogs je versionCode |
| `commit` als voller Hash, kein Tag | der Workflow trägt ihn ein; beim Einreichen den Hash des Release-Tags nehmen |
| Externe Repos als Git-Submodul statt srclib | Flutter liegt als Submodul in `app/.flutter`, fest auf 3.44.8 (`058e0af2c2b5…`). Damit reist die Flutter-Fassung mit dem Quellstand: ein späteres Flutter-Update bricht F-Droids automatische Aktualisierung nicht |
| Reproducible Builds — „if you don't enable reproducible build then the apk will be signed with our key so you can't enable it later“ | `Binaries` + `AllowedAPKSigningKeys` im Rezept; die Release-APK entsteht im F-Droid-Image (unten) |
| Releases getaggt, Auto-Update an | `UpdateCheckMode: Tags ^v[0-9.]+$`, `AutoUpdateMode: Version` |
| AuthorName, Issue-Tracker | ja |
| Keine proprietären Abhängigkeiten | geprüft (alle 128 Pakete in `pubspec.lock`): kein Firebase, keine Play Services, kein ML Kit, keine Tracker; Push über UnifiedPush; sqlite3mc aus Quelltext (`app/third_party/sqlite3mc/`); alle Pakete exakt gepinnt, Bau mit `pub get --enforce-lockfile` |
| ABI-Split, wenn die APK groß ist | **bewusst nicht**, siehe unten |

## Die Messung vom 14.10.2026

v1.9.0 nach dem Rezept unter Linux (WSL, Ubuntu 24.04, Flutter 3.44.8 als
Git-Checkout, NDK r28c, cmake 3.22.1), Inhalte Datei für Datei verglichen:

| Vergleich | Ergebnis |
|---|---|
| zweimal derselbe Pfad, JDK 17 | **bitgleich** (ganze Datei, sha256 `f475e11e…`) |
| anderer Pfad, JDK 17 | `libapp.so`, `libdartjni.so`, `libwebcrypto.so` verschieden |
| JDK 17 gegen JDK 25 | zusätzlich `classes.dex` und das Baseline-Profil |
| Linux gegen die Windows-Release-APK 1.9.0 | zusätzlich `libsqlite3.so`, `NOTICES.Z`, `NativeAssetsManifest.json`; die Ordner unter `lib/x86_64` passen gar nicht |

Woher der Pfad kommt: `libapp.so` trägt den absoluten Pfad des App-Ordners
(`file:///…/secure-messenger/app/.dart_tool/flutter_build/dart_plugin_registrant.dart`),
`libwebcrypto.so` die Pfade der BoringSSL-Quellen im Pub-Cache (`__FILE__`),
und daraus folgt eine andere Build-ID in `libdartjni.so`. SDK- und NDK-Pfade
stehen nicht darin.

**Daraus folgt:** bitgleich wird es nur im selben Pfad mit demselben JDK. F-Droid
baut in `/home/vagrant/build/com.bitdm.bitdm`, im Image
`registry.gitlab.com/fdroid/fdroidserver:buildserver-trixie`, mit OpenJDK 21.
Also entsteht die Release-APK genau dort: `.github/workflows/android-fdroid.yml`
lässt `fdroid build` mit diesem Rezept laufen — Scanner eingeschlossen, denn der
löscht vor dem Bau Binärdateien in `.flutter` und `.pub-cache` (`scandelete`).

**Windows-Bauten werden nicht mehr veröffentlicht.** Für Tests auf dem eigenen
Telefon bleibt der Windows-Bau, wie er ist.

## Nur ARM, eine APK

- **Kein x86_64.** Die 1.9.0-APK hatte einen Ordner `lib/x86_64` mit vier
  Plugin-Bibliotheken, aber ohne `libflutter.so`, `libapp.so` und
  `libsqlite3.so` — ein x86_64-Gerät (Chromebook, Emulator) wählt diesen Ordner
  und stürzt beim Start ab. Seit 14.10.2026 verpackt `android/app/build.gradle.kts`
  nur, wofür Flutter gebaut hat; gebaut wird mit
  `--target-platform android-arm,android-arm64`. x86_64-Geräte nehmen die
  ARM-Fassung über die Übersetzung des Systems.
- **Kein ABI-Split.** Die APK hat rund 47 MB, je ABI wären es etwa 25. Ein Split
  hieße drei versionCodes je Fassung (Flutter rechnet 1000/2000/4000 dazu), drei
  Release-Dateien und ein Downgrade-Problem für alle, die zwischen GitHub-APK
  und F-Droid wechseln. Fragt der Reviewer danach: das ist die Begründung, und
  umstellbar ist es später mit `VercodeOperation` und `Binaries` je ABI.

## Release-Ablauf (Android), ab 1.9.1

1. Fassung in `app/pubspec.yaml` heben (`1.9.1+21`) **und** `appFassung` in
   `app/lib/fassung.dart` gleich mit (der Workflow bricht sonst ab), Changelogs
   `app/fastlane/metadata/android/{en-US,de-DE}/changelogs/<versionCode>.txt`
   (je höchstens 500 Zeichen), `CHANGELOG.md`.
2. Erst wenn die CI auf `main` grün ist: Tag setzen und pushen
   (`git tag v1.9.1 && git push origin v1.9.1`). Der
   Workflow **Android (F-Droid-Bau)** baut die unsignierte APK und beglaubigt
   sie. Dauer rund eine halbe Stunde.
3. Holen und prüfen:
   ```
   gh run download <lauf-id> -R Henner4746/BitDM -n android-unsigniert
   gh attestation verify bitdm-1.9.1-unsigned.apk -R Henner4746/BitDM
   ```
4. Lokal signieren — der Schlüssel verlässt den Rechner nicht. Speicherdatei und
   Alias stehen in `app/android/key.properties` (`storeFile`, `keyAlias`):
   ```
   & "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\apksigner.bat" sign --alignment-preserved --ks <storeFile> --ks-key-alias <keyAlias> --out bitdm-1.9.1.apk bitdm-1.9.1-unsigned.apk
   & "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0\apksigner.bat" verify --print-certs bitdm-1.9.1.apk
   ```
   **`--alignment-preserved` IST PFLICHT.** Ohne den Schalter baut apksigner die
   Datei beim Signieren um (eigene Ausrichtungsfelder in den Dateiköpfen), und
   F-Droid kann die Signatur nicht mehr auf seinen eigenen, bitgleichen Bau
   übertragen: „compared built binary to supplied reference binary but
   failed … CHUNKED_SHA512 digest mismatch“. So geschehen bei der ersten
   Einreichung von 1.9.1 (15.10.2026). Die unsignierte APK aus dem Workflow ist
   bereits richtig ausgerichtet (4 Byte, `.so` auf 16 KiB), es geht dabei nichts
   verloren. Gegenprobe vor dem Hochladen, genau wie F-Droid sie macht:
   `apksigcopier compare bitdm-1.9.1.apk --unsigned bitdm-1.9.1-unsigned.apk`.
   Der Zertifikats-Fingerabdruck (SHA-256) muss `e325b01c…2063` sein — derselbe
   wie in `AllowedAPKSigningKeys`.
5. `bitdm-1.9.1.apk` an den GitHub-Release hängen (der Name muss genau so sein,
   `Binaries:` im Rezept zeigt darauf), danach wie bisher die Seite.
6. Eigenes F-Droid-Verzeichnis (bitdm.net/fdroid/repo), in WSL:
   `bash secure-messenger/fdroid/verzeichnis/veroeffentlichen.sh 1.9.1` —
   übernimmt genau diese APK vom Release, siehe `verzeichnis/README.md`.
7. Erste Fassung: Merge-Request in fdroiddata mit dem vollen Commit-Hash des
   Tags (`git rev-list -n1 v1.9.1`). Danach findet F-Droid neue Tags selbst.

## Gegenprobe ohne GitHub

`vergleich.py` vergleicht zwei APKs Eintrag für Eintrag ohne die
Signaturdateien — so ist die Messung oben entstanden:

```
python3 vergleich.py bitdm-1.9.1-unsigned.apk eigener-bau.apk
```

## Berechtigungen (für Rückfragen im Merge-Request)

Ausgelesen aus der gebauten APK (`aapt2 dump permissions`, 14.10.2026):

`INTERNET`, `ACCESS_NETWORK_STATE` für den Relay · `RECORD_AUDIO` nur für
Sprachnachrichten · `CAMERA` nur für den QR-Scan · `BLUETOOTH_SCAN` mit
`neverForLocation`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` für den
Nahbereich (ab Android 12) · `NFC` für Sicherheitsschlüssel · `USE_BIOMETRIC`,
`USE_FINGERPRINT` für die App-Sperre · `POST_NOTIFICATIONS`, `VIBRATE` für
Benachrichtigungen · `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` für
den Hintergrundempfang (ab Werk aus) · `WAKE_LOCK` von UnifiedPush. Kein
Standort, kein Speicherzugriff — die Speicherrechte, die das camera-Plugin
mitbringt, entfernt das Manifest.

## TetheredNet

Bleibt, solange die Relay-Adresse nur beim Bauen einstellbar ist
(`--dart-define=BITDM_RELAY`). Der Relay ist freie Software im selben Repo,
deshalb nicht NonFreeNet.
