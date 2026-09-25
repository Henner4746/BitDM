# Google Play — vorbereitet, nicht eingereicht

Stand 25.09.2026. Alles, was sich ohne Entwicklerkonto vorbereiten lässt, ist
hier. Was fehlt, steht am Ende — das kann nur Henrik tun.

## Store-Eintrag

Die Texte und Bilder liegen im Triple-T/fastlane-Format, das Play genauso
liest wie F-Droid:

    app/fastlane/metadata/android/de-DE/   (title, short_description, full_description, changelogs)
    app/fastlane/metadata/android/en-US/
    app/fastlane/metadata/android/*/images/icon.png, phoneScreenshots/1..6.png

Die Grafik 1024 × 500 ("Feature graphic") liegt als images/featureGraphic.png
in beiden Sprachen bei.

## App-Bundle

    cd app
    flutter build appbundle --release       # build/app/outputs/bundle/release/app-release.aab

Signiert mit demselben Schlüssel wie die APK (`e325b01c…`, `android/key.properties`).
**Play App Signing:** beim ersten Hochladen fragt Play, ob Google den
App-Signaturschlüssel verwalten soll. Wird der vorhandene Schlüssel
hochgeladen ("Export and upload a key from Java keystore"), bleiben
Play-Fassung und GitHub/bitdm.net-Fassung gegenseitig aktualisierbar. Lässt
man Google einen neuen erzeugen, sind es zwei verschiedene Apps für Android.

## Datensicherheit (Data safety) — die Antworten

Grundlage: `website/privacy.html`. Google nimmt Daten, die **Ende zu Ende
verschlüsselt** übertragen werden, ausdrücklich von der Angabepflicht aus.

| Frage | Antwort | Warum |
|---|---|---|
| Erhebt oder teilt die App erforderliche Nutzerdaten? | **Nein** | Nachrichten und Anhänge sind E2E-verschlüsselt; es gibt kein Konto, keine Telefonnummer, keine E-Mail. |
| Werden Daten bei der Übertragung verschlüsselt? | Ja | TLS zum Relay und zum Zwischenlager, darunter Signal-Protokoll. |
| Können Nutzer das Löschen ihrer Daten verlangen? | Ja | Alles liegt auf dem Gerät; „Alles löschen" in der App, Deinstallieren. Auf dem Server: unzugestellte Nachrichten verfallen nach 14 Tagen. |
| Werbung | Keine | |
| Analyse, Absturzberichte | Keine | Keine SDKs dafür (pubspec.lock geprüft, siehe fdroid/README.md). |

Was der Server trotzdem sieht (Adressen = öffentliche Schlüssel, Zeitpunkt,
auf 256 Byte gerundete Größe), zählt Google nicht als „erhobene
Nutzerdaten", solange es nicht mit einer Person verknüpft wird — und die
Datenschutzerklärung nennt es trotzdem vollständig. Beides muss
übereinstimmen: Play prüft Formular gegen Erklärung.

## Berechtigungen — was Play dazu wissen will

| Berechtigung | Wofür | Play-Formular |
|---|---|---|
| `RECORD_AUDIO` | Sprachnachrichten, nur während der Aufnahme | keines, aber im Eintrag erwähnen |
| `CAMERA` | QR-Code einer Adresse scannen | keines |
| Bluetooth scan/advertise/connect (`neverForLocation`) | Nahbereich ohne Internet | keines (kein Standort) |
| `NFC` | Hardware-Sicherheitsschlüssel (FIDO2) | keines |
| `FOREGROUND_SERVICE_DATA_SYNC` | Empfang im Hintergrund | **Erklärung zum Vordergrunddienst mit kurzem Video** der Funktion |
| `POST_NOTIFICATIONS` | Hinweis auf neue Nachrichten (ohne Inhalt) | keines |

## Einstufung (Content rating, IARC)

Messenger mit Nutzerkommunikation: „Nutzer interagieren miteinander: Ja",
„Teilen von Inhalten zwischen Nutzern: Ja", keine Gewalt, keine Glücksspiele,
kein Standortteilen. Ergebnis erfahrungsgemäß USK 0 / PEGI 3 mit dem Zusatz
„Nutzerinteraktion".

## Zielgruppe

18+ empfohlen: ein Ende-zu-Ende-Messenger ohne Moderation ist für Kinder
nicht gedacht, und „für Kinder" zöge die Familienrichtlinien nach sich.

## Was nur Henrik tun kann

1. **Entwicklerkonto** bei Google Play (einmalig 25 USD, Identitätsprüfung).
2. **Anschrift im Impressum** (`website/privacy.html`, Abschnitt
   „Verantwortlicher") — Play verlangt eine vollständige Entwickleridentität.
3. **Video für den Vordergrunddienst** (Bildschirmaufnahme: Hintergrund-
   empfang einschalten, Nachricht kommt bei geschlossener App).
4. **Feature-Grafik** ansehen und freigeben (images/featureGraphic.png).
5. Entscheidung **Play App Signing** (vorhandenen Schlüssel hochladen — empfohlen).
6. Bei neuen Konten: **geschlossener Test mit 12 Testern über 14 Tage**, bevor
   eine Produktionsfreigabe möglich ist (Regel seit Nov. 2023).
