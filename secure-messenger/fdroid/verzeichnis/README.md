# Eigenes F-Droid-Verzeichnis — bitdm.net/fdroid/repo

Seit 15.10.2026. F-Droid hat BitDM am selben Tag nicht aufgenommen
(fdroiddata!52566). Dieses Verzeichnis ist der Ersatz: Wer es einmal in
F-Droid, Droid-ify oder Neo Store hinzufügt, bekommt Updates wie aus F-Droid
selbst.

## Adresse

```
https://bitdm.net/fdroid/repo?fingerprint=7C35B6517F5E4E2D35729C15EE9AC0839930E44C773D57ED60A959CD8F1D6B85
```

- Der Fingerabdruck ist der SHA-256 des Index-Zertifikats
  (`CN=BitDM F-Droid Repo`). Er bleibt gleich, solange der Schlüssel derselbe
  ist. Die F-Droid-App lehnt einen Index ab, der nicht damit signiert ist.
- QR-Code mit genau dieser Adresse: <https://bitdm.net/fdroid/repo/index.png>
  (von `fdroid update` erzeugt; die Seite `repo/index.html` zeigt ihn).
- `https://bitdm.net/fdroid/` leitet auf `/fdroid/repo/` weiter.

**Welcher Link öffnet die App?** F-Droid 2.x (geprüft 2.0.1) fängt nur zwei
Formen ab — die nackte Adresse oben öffnet nur den Browser:

- `https://fdroid.link/#https://bitdm.net/fdroid/repo?fingerprint=7C35…6B85`
  — F-Droids eigene Seite. Die Repo-Adresse steht hinter dem `#` und geht
  deshalb nicht an deren Server. Ohne installierte App erklärt die Seite, was
  zu tun ist. So verlinkt auch `repo/index.html`.
- `fdroidrepos://bitdm.net/fdroid/repo?fingerprint=7C35…6B85` — ohne Dritte,
  tut aber nichts, wenn keine passende App installiert ist.

Von Hand (Repositories → hinzufügen) oder per QR-Scan soll die App auch die
nackte Adresse nehmen. Im Test unten war das nicht eigens dran.

## Was drin ist

- **Bitgenau die APK vom GitHub-Release**, signiert mit dem
  Entwicklerschlüssel (`e325b01c…2063`), nicht neu signiert. Wer BitDM von
  GitHub oder aus Obtainium hat, kann deshalb ohne Neuinstallation wechseln.
  `AllowedAPKSigningKeys` in `metadata/com.bitdm.bitdm.yml` lässt
  `fdroid update` jede APK mit einem anderen Zertifikat abweisen.
- Signiert wird nur der **Index**, mit einem eigenen Schlüssel (nicht
  `bitdm-release.jks`).
- Name, Beschreibungen, Bilder und Changelogs kommen aus
  `app/fastlane/metadata/android/` **im Release-Tag**, nicht aus dem
  Arbeitsstand.
- Anti-Feature `TetheredNet` wie im fdroiddata-Rezept.
- Drei Fassungen im Repo, ältere unter `/fdroid/archive`.
- Bekannte Lücke: fdroidserver 2.4.5 schreibt „Was ist neu“ in `index-v2.json`
  nur bei Apps mit Bau-Block. Die F-Droid-App zeigt es deshalb nicht an,
  Droid-ify und Neo Store schon (sie lesen `index-v1`).

## Pro Release

Nach Schritt 5 in `../README.md` (signierte APK hängt am GitHub-Release), in
WSL im Repo-Wurzelordner:

```
git fetch --tags
bash secure-messenger/fdroid/verzeichnis/veroeffentlichen.sh 1.9.2
```

Das Skript bricht ab, wenn eine Prüfung scheitert:

1. sha256 der Release-APK = `.sha256` am Release = `releases/<fassung>/` auf
   diesem Rechner (falls vorhanden),
2. Zertifikat = Entwicklerschlüssel, genau ein Signierer,
3. Paketname und Fassung stimmen,
4. eine schon veröffentlichte `com.bitdm.bitdm_<code>.apk` wird nie durch
   eine andere Datei ersetzt,
5. nach dem Hochladen liefert bitdm.net das neue `entry.jar` aus.

`--ohne-hochladen` baut nur den Index im Arbeitsordner.

## Wo was liegt

| Was | Wo |
|---|---|
| Index-Schlüssel | Windows-Profil, `bitdm-fdroid-index.p12` (PKCS12, Alias `bitdm-fdroid-index`, RSA 4096, gültig bis 2054). Vom PC-Backup erfasst. |
| Passwort dazu | daneben, `bitdm-fdroid-index.passwort`. Zusätzlich im Passwortmanager. |
| Arbeitsordner | WSL `~/bitdm-fdroid/verzeichnis` (`repo/`, `archive/`, `tmp/`). Nur Zustand — aus den GitHub-Releases jederzeit neu aufzubauen. |
| Werkzeug | WSL `~/bitdm-fdroid`: `venv-fd` (fdroidserver 2.4.5), `jdk`, `android-sdk/build-tools/36.0.0` (apksigner, aapt2) |
| Upload-Schlüssel | WSL `~/.ssh/bitdm_fdroid_deploy`, Eintrag `bitdm-fdroid-vps` in `~/.ssh/config` |
| Server | `/var/www/bitdm-fdroid/fdroid/{repo,archive}` |

`config.yml` enthält keine Geheimnisse: Schlüsseldatei und Passwort kommen
über `BITDM_FDROID_KEYSTORE` und `BITDM_FDROID_PASS` herein. Das Skript liest
sie aus dem Windows-Profil (`%USERPROFILE%`), überschreibbar mit
`BITDM_FDROID_KEYSTORE` / `BITDM_FDROID_PASSDATEI`.

`apksigner` ist Pflicht, nicht Zierde: BitDM hat minSdk 28 und darum keine
v1-Signatur. Ohne apksigner prüft fdroidserver mit jarsigner und verwirft die
APK.

## Server (eingerichtet am 15.10.2026)

**Hochladen.** Eigener Systembenutzer `bitdm-fdroid` ohne Passwort. Sein
`authorized_keys` gehört root und erlaubt genau eines:

```
command="/usr/bin/rrsync -wo /var/www/bitdm-fdroid",restrict ssh-ed25519 … bitdm-fdroid-deploy
```

Nur schreiben, nur unterhalb von `/var/www/bitdm-fdroid` (ein führender `/`
ist relativ dazu, darum `serverwebroot: bitdm-fdroid-vps:/fdroid`). Geprüft:
eine Shell, das Herunterladen und `..` werden abgewiesen. `fdroid deploy`
lädt erst die APKs und zuletzt die Indexdateien hoch.

**nginx** — in `sites-enabled/bitdm.net`, vor `location /`:

```nginx
location = /fdroid  { return 301 /fdroid/repo/; }
location = /fdroid/ { return 301 /fdroid/repo/; }
location ^~ /fdroid/ {
    root /var/www/bitdm-fdroid;
    add_header X-Frame-Options        "DENY"        always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff"     always;
    add_header Referrer-Policy        "no-referrer" always;
    add_header Permissions-Policy     "geolocation=(), microphone=(), camera=(), interest-cohort=()" always;
    add_header Content-Security-Policy "default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;
    add_header Cache-Control $bitdm_fdroid_cache always;
    location ~ /\. { deny all; }
}
```

`^~` hält die Regex-Blöcke der Seite heraus (sonst bekäme `index.html`
`expires 10m`). Die Sicherheitsheader stehen noch einmal da, weil jedes
`add_header` in einem Block die der Serverebene löscht. `style-src 'self'`
braucht die `index.css`, die `fdroid update` neben `index.html` legt.

`/etc/nginx/conf.d/bitdm-fdroid-cache.conf`:

```nginx
map $uri $bitdm_fdroid_cache {
    ~\.apk$  "public, max-age=31536000, immutable";
    ~\.jar$  "no-store";
    default  "no-cache";
}
```

**Cloudflare.** Die Index-Dateien dürfen nie aus einem Cache kommen:
`entry.jar` nennt den Hash von `index-v2.json`, und ein altes `entry.jar` zu
einem neuen Index lässt die Prüfung in der App scheitern. Gemessen am
15.10.2026:

- `.json` und `.html` cacht Cloudflare nicht (`DYNAMIC`), `no-cache` kommt
  unverändert an.
- `.jar` gilt bei Cloudflare als statisch. Aus `no-cache` machte es den
  Browser-Cache der Zone (`max-age=14400`). `no-store` reicht es durch
  (`BYPASS`).
- APKs behalten ihren Namen nie mit anderem Inhalt, also ein Jahr Cache.
- Die Browser-Integritätsprüfung sperrt die Kennung `Python-urllib` (403).
  F-Droid, Droid-ify, okhttp, Ktor und Dalvik kommen durch, Teil-Downloads
  (206) gehen.

## Test (15.10.2026, bestanden)

Auf dem Mini-PC im Container `android-test` (CT 107, Proxmox, Kerne 4–11,
`/dev/kvm` durchgereicht, ohne Autostart): Android-15-Emulator
(`google_apis/x86_64`, übersetzt arm64 über `libndk_translation`).

1. Frisches F-Droid 2.0.1 von f-droid.org (Zertifikat `43238d51…ccab`).
2. Link `https://fdroid.link/#…` geöffnet. F-Droid lädt den Index, prüft den
   Fingerabdruck und zeigt „Add repository“ mit Name, Beschreibung und BitDM.
   Danach ist das Repo hinzugefügt.
3. BitDM 1.9.1 über F-Droid installiert (`installer=org.fdroid.fdroid`,
   versionCode 21).
4. Die installierte `base.apk` aus dem Emulator ist **bitgleich** mit der
   GitHub-APK (sha256 `7b69794f…`), also auch dieselbe Signatur.

Wiederholen: CT 107 starten, als Benutzer `android` `./start-emu.sh`, dann
`adb install F-Droid-*.apk`; `ui.py zeige` / `ui.py tippe <regex>` lesen und
bedienen die Oberfläche. **BitDM dort nicht öffnen:** Der Emulator hat echtes
DNS, und schon das Onboarding meldet eine Testidentität beim echten Relay an.
Danach `pct shutdown 107`.

Ohne Emulator prüft `fdroidserver.index.download_repo_index_v2()` den Index
genau wie die App (Signatur, Fingerabdruck, Hash). Die Anfrage braucht dabei
eine eigene Kennung, denn Cloudflare sperrt `Python-urllib`.

## Wenn etwas verloren geht

- **Index-Schlüssel oder Passwort weg:** neuen Schlüssel erzeugen. Das ergibt
  einen neuen Fingerabdruck, also eine neue Adresse, und alle Nutzer müssen das
  Repo neu hinzufügen. Die installierte App und ihre Updates (APK-Signatur)
  sind davon nicht betroffen.
- **Arbeitsordner weg:** `veroeffentlichen.sh` für die letzten drei
  Fassungen nacheinander laufen lassen, die älteste zuerst, alle bis auf die
  neueste mit `--ohne-hochladen`. Sonst löscht `rsync --delete-after` auf dem
  Server, was lokal noch fehlt.
