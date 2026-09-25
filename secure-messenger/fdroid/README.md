# F-Droid — vorbereitet, nicht eingereicht

Stand 25.09.2026, BitDM 1.7.0 (versionCode 15).

## Was erledigt ist

- **Store-Texte und Bilder** im Fastlane/Triple-T-Format unter
  `app/fastlane/metadata/android/` — F-Droid liest sie direkt aus dem Repo,
  sie gehören also NICHT in fdroiddata.
  - `en-US/` und `de-DE/`: `title.txt`, `short_description.txt` (≤ 80 Zeichen),
    `full_description.txt`, `changelogs/14.txt` (1.6.1) und `changelogs/15.txt`
    (1.7.0, je ≤ 500 Zeichen).
  - `en-US/images/icon.png` (512 px aus `icon_bitdm_1024.png`) und sechs
    Telefon-Bildschirmfotos aus dem Emulatorlauf (Testkennungen, keine echten
    Daten). Andere Sprachen fallen auf `en-US` zurück.
  - Für jede neue Fassung: `changelogs/<versionCode>.txt` in beiden Sprachen.
- **Baurezept-Entwurf** `com.bitdm.bitdm.yml` für fdroiddata: Flutter 3.44.8
  als srclib, NDK r28c, ein APK für alle drei ABIs wie im GitHub-Release,
  `pub get --enforce-lockfile`, Reproducible-Build-Felder (`Binaries`,
  `AllowedAPKSigningKeys`), Anti-Feature `TetheredNet`, Update-Prüfung über
  Tags `v*` und `pubspec.yaml`.
- **Gradle** baut ohne `android/key.properties` eine unsignierte Release-APK
  und warnt nur (`app/android/app/build.gradle.kts`); abgebrochen wird nur mit
  `-PbitdmRequireSigning=true`. Das Rezept setzt die Eigenschaft nicht.
- **Abhängigkeiten geprüft** (`pubspec.lock`, alle 128 Pakete): kein Firebase,
  keine Google Play Services, kein ML Kit, keine Werbung oder Tracker. Alle
  Lizenzen frei (BSD, MIT, Apache-2.0, MPL-2.0; `libsignal_protocol_dart` ist
  GPL-3.0 und mit der AGPL-3.0 vereinbar). Push läuft über UnifiedPush, nicht
  FCM. Schriften unter OFL im Repo.

## Was vor dem Einreichen noch fehlt

1. **sqlite3mc aus Quelltext bauen (blockiert die Aufnahme).** Mit
   `hooks.user_defines.sqlite3.source: sqlite3mc` lädt der Build-Hook von
   `package:sqlite3` eine fertige `libsqlite3mc.so` von GitHub herunter
   (SHA-256-geprüft, aber vorkompiliert). F-Droid baut nur aus Quelltext.
   Ausweg wie im Kommentar in `app/pubspec.yaml`: die Amalgamation von
   SQLite3MultipleCiphers ins Repo legen und auf `source: source` +
   `path: third_party/sqlite3mc_amalgamation.c` umstellen. Das geht nur mit
   einer neuen Fassung (z. B. 1.7.1+16) — das Rezept dann auf diese Fassung
   umstellen. Für 1.7.0 selbst kann F-Droid nichts Sauberes bauen.
2. **Abhängigkeits-Block aus der APK nehmen.** Die veröffentlichte APK trägt im
   Signaturblock den `DEPENDENCY_INFO_BLOCK` (ID `0x504b4453`), den AGP mit
   einem Google-Schlüssel verschlüsselt. F-Droid verlangt, ihn abzuschalten.
   In `app/android/app/build.gradle.kts` im `android { }`-Block:

   ```kotlin
   dependenciesInfo {
       includeInApk = false
       includeInBundle = false
   }
   ```

   Gleich mit prüfen: `META-INF/version-control-info.textproto`. Im
   Release-Bau stand dort `NO_SUPPORTED_VCS_FOUND`; im git-Checkout von F-Droid
   stünde der Commit darin, und schon wäre die Datei verschieden. Sicherer:
   `vcsInfo { include = false }` im `release`-Buildtyp.
3. **Reproduzierbarkeit nachweisen.** Die 1.7.0-APK wurde unter Windows gebaut,
   F-Droid baut unter Debian in `/home/vagrant/build/com.bitdm.bitdm`. Vor dem
   Einreichen selbst unter Linux mit genau dem Rezept bauen (`fdroid build` im
   fdroiddata-Checkout oder ein Docker-Buildserver) und mit
   `apksigcopier compare` bzw. `diffoscope` gegen die Release-APK vergleichen.
   Am besten die eigenen Releases künftig ebenfalls unter Linux (CI) bauen,
   mit Flutter 3.44.8 und NDK r28c. Klappt es nicht, `Binaries` und
   `AllowedAPKSigningKeys` im Rezept auskommentieren — dann signiert F-Droid
   mit eigenem Schlüssel, und Nutzer können nicht zwischen GitHub- und
   F-Droid-APK wechseln (anderer Signaturschlüssel).
4. **fdroiddata-Merge-Request.**
   - https://gitlab.com/fdroid/fdroiddata forken (GitLab-Konto nötig).
   - `com.bitdm.bitdm.yml` nach `metadata/` kopieren, die Kopfkommentare
     kürzen.
   - `fdroid readmeta`, `fdroid rewritemeta com.bitdm.bitdm`,
     `fdroid lint com.bitdm.bitdm`, `fdroid build -v -l com.bitdm.bitdm`.
   - Branch `com.bitdm.bitdm` pushen, Merge-Request mit der Vorlage „App
     inclusion" öffnen; die Pipeline baut die App dort noch einmal.
5. **Berechtigungen im MR begründen** — Reviewer fragen danach:
   `RECORD_AUDIO` (nur Sprachnachrichten, seit 1.6.0), `CAMERA` (nur
   QR-Scan), `BLUETOOTH_SCAN` mit `neverForLocation`, `BLUETOOTH_ADVERTISE`,
   `BLUETOOTH_CONNECT` (Nahbereich, ab Android 12), `NFC` (Sicherheitsschlüssel),
   `FOREGROUND_SERVICE_DATA_SYNC` (Hintergrundempfang, ab Werk aus),
   `WAKE_LOCK` (von UnifiedPush). Kein Standort, kein Speicherzugriff.
6. **TetheredNet** fällt weg, sobald die Relay-Adresse in der App einstellbar
   ist; bis dahin ist die Angabe ehrlich und bleibt drin.

## Gefundene Ungereimtheiten (nicht geändert)

- **Lizenz:** `LICENSE`, beide READMEs, `docs.html` und `privacy.html` sagen
  AGPL-3.0. Noch **GPL-3.0** steht in `website/index.html` (Meta-Beschreibung
  Zeile 52 und Abschnitt Quellcode Zeile 1408/1411), in `PRODUCT.md`
  (Zeilen 47, 96, 102) und im Schrift-Kommentar in `app/pubspec.yaml`. Im
  Rezept steht `AGPL-3.0-only`, weil nirgends „or later" erklärt ist — wer
  „or later" will, muss das im Repo sagen.
- **Pins:** Der Kommentar in `pubspec.yaml` sagt „alle Versionen EXAKT
  gepinnt", sieben Einträge haben aber noch `^`. Reproduzierbar ist der Bau
  trotzdem über die eingecheckte `pubspec.lock`, solange mit
  `--enforce-lockfile` geholt wird.
- **Release-Text 1.7.0/1.6.1:** „arm64 + arm32" — die APK enthält auch
  `x86_64`.
- **README „Bekannte Lücken"** nennt noch „Keine Gruppenchats", obwohl
  Gruppen bis 20 seit 1.6.0 gebaut sind.
