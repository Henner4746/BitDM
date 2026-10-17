# Changelog

Alle Fassungen der App BitDM. Details und Belege je Funktion:
[`secure-messenger/docs/FUNKTIONSVERGLEICH.md`](secure-messenger/docs/FUNKTIONSVERGLEICH.md).
Downloads: [GitHub-Releases](https://github.com/Henner4746/BitDM/releases) und <https://bitdm.net>.

## 2.0.0 — noch nicht veröffentlicht

**Signals offizielle libsignal statt der Dart-Nachbildung.** Bis 1.9.x lief die Verschlüsselung über `libsignal_protocol_dart`, eine nie geprüfte Nachbildung in reinem Dart. Das Sicherheitsaudit vom 16.10.2026 fand darin zwei schwere Fehler in der Zustandsverwaltung. Ab 2.0.0 rechnet Signals eigene Bibliothek (Rust, libsignal 0.105, über das Paket `libsignal` 8.0.0). Plan und Nachweise: [`secure-messenger/docs/LIBSIGNAL-UMSTIEG.md`](secure-messenger/docs/LIBSIGNAL-UMSTIEG.md).

- **Post-Quanten-Sitzungsaufbau (PQXDH, Kyber-1024).** Jede neue Sitzung nutzt ihn; ohne Kyber gibt es keine Sitzung.
- **Adressen, Chats und Kontakte bleiben.** Dieselben zwölf Wörter ergeben dieselbe Adresse (nachgemessen). Beim ersten Start wird mit jedem Kontakt die Sitzung neu aufgebaut.
- **Nicht mit 1.9.x verträglich.** Eine App vor 2.0.0 kann keine Sitzung mit 2.0.0 aufbauen und umgekehrt. Beide Seiten müssen aktualisieren.
- **Der Chat sagt, wenn die Gegenseite aktualisieren muss.** Hat ein Kontakt nur eine App vor 2.0.0, warten deine Nachrichten an ihn. Sie gehen von selbst hinaus, sobald er aktualisiert hat. Bisher standen sie ohne Erklärung auf „wird gesendet“.
- **Signierte Prekeys werden jetzt wöchentlich erneuert** (vorher nie, Audit LS-4).
- **Über Bluetooth werden keine Einmalschlüssel mehr verschenkt.** Vorher konnte derselbe Schlüssel auch beim Relay ausgegeben werden, und eine Erstnachricht ging still verloren (Audit PR-4).
- **Keine Nachricht geht mehr doppelt hinaus.** Kam während des Sendens jemand in Bluetooth-Reichweite oder stand die Verbindung wieder, schickte der Nachversand dieselbe Nachricht ein zweites Mal.
- **Erst festschreiben, dann senden.** Der Sitzungsstand wird gespeichert, bevor eine Nachricht hinausgeht. Ein Absturz genau dazwischen konnte vorher dazu führen, dass ein Nachrichtenschlüssel zweimal benutzt wurde.

**Anhänge am PC.** Bis 1.9.x stand „Datei anhängen“ unter Windows und Linux im Menü und tat auf Druck nichts — die Dateiauswahl gab es nur unter Android. Ebenso „Sicherung einspielen“; „Öffnen“ bei einem empfangenen Anhang meldete fälschlich, keine App könne die Datei öffnen.
- Unter Windows und Linux öffnet sich jetzt der Dateidialog des Systems. Geschickt wird die Originaldatei, ohne Kopie.
- Empfangene Anhänge lassen sich am PC öffnen. Unter Windows laufen sie vorher durch die Anhangprüfung des Systems (Markierung „aus dem Internet“, Virenscanner); dann fragt Windows bei Programmen und Skripten nach, und Office öffnet in der geschützten Ansicht. HTML, SVG und Skripte gehen wie unter Android als Text auf.
- Im Browser ist der Menüpunkt ausgegraut und nennt den Grund, statt nichts zu tun.

**Geräte abmelden.** Bis 1.9.x blieb ein verlorenes Telefon Teil der Identität und bekam weiter jede Nachricht — auch nachdem man sie mit den zwölf Wörtern auf einem neuen wiederhergestellt hatte. Ab 2.0.0 führt jede Identität eine signierte Geräteliste. Bedrohungsmodell und Protokoll: [`secure-messenger/docs/GERAETEABMELDUNG.md`](secure-messenger/docs/GERAETEABMELDUNG.md).
- **Abmelden** unter Einstellungen › Meine ID › Geräte verwalten. Das abgemeldete Gerät bekommt sofort nichts mehr, kommt beim Relay nicht wieder hinein und vergisst die zwölf Wörter; seine Unterhaltungen bleiben verschlüsselt darauf.
- **Ein weiteres Gerät** braucht jetzt zusätzlich zu den Wörtern einen Code vom vorhandenen Gerät. Wer kein Gerät mehr hat, meldet auf dem neuen alle anderen ab.
- **Kontakte prüfen die Liste selbst** und verschlüsseln nur an Geräte darin — auch dann, wenn ein Relay etwas anderes behauptet.
- **Die Grenze bleibt benannt:** Wer die zwölf Wörter kennt, kann alle Geräte abmelden und übernehmen. Dann hilft nur eine neue Identität.
- **Beim Update** legt das erste aktualisierte Gerät die Liste an; jedes weitere tritt einmal per Code bei. Der Relay muss vorher aktualisiert sein.

**Weitere Behebungen aus dem Audit vom 16.10.2026**
- Eine „Absage“ oder „Zusage“ eines Kontakts wird nur noch als Antwort auf eine eigene Anfrage angenommen. Vorher konnte jeder Kontakt damit die ganze Unterhaltung löschen bzw. sich ein Fremder selbst zum Kontakt machen (PR-1, PR-2).
- Unbeantwortete Anfragen von Fremden bekommen keine Bluetooth-Leuchtfeuer mehr (PR-3).
- Die Anmeldung beim Relay signiert nur noch eine Challenge von genau 32 Byte (KR-2, App-Teil).
- Linux- und F-Droid-Workflow setzen Werte aus dem Bau-Schritt nicht mehr ungeprüft in Skripte ein (PL-1).

**Linux und Rechner** (aus dem ersten echten Linux-Lauf am 17.10.2026)
- Ohne erreichbaren oder entsperrten Schlüsselbund (GNOME Keyring, KWallet) blieb das Fenster unter Linux leer. Jetzt steht dort eine Meldung mit „Erneut versuchen“. Gelöscht oder neu angelegt wird dabei nichts.
- Am Rechner und im Browser ist in Sperrbildschirm, 12-Wörter-Seite, Startseite, Wiederherstellen und Fernlöschung von „diesem Gerät“ die Rede statt vom Telefon. In der Android-App bleibt es beim Telefon.

## 1.9.1 — veröffentlicht am 15.10.2026

Behebungen aus der Prüfung vom 14.10.2026 (Quellstand `e5aefdf`), Einzelheiten
in [`secure-messenger/docs/BEFUNDE-2026-10-14.md`](secure-messenger/docs/BEFUNDE-2026-10-14.md).

**Behoben (App)**
- Die APK enthielt einen unvollständigen Ordner für x86_64 (Plugin-Bibliotheken ohne Flutter). Ein x86_64-Gerät wie ein Chromebook wählte genau diesen Ordner, und die App stürzte beim Start ab. Verpackt wird jetzt nur, wofür Flutter gebaut hat.
- Ein Download, der mittendrin abbrach (App weggewischt oder gesperrt), stand für immer auf „lädt“, und der Anhang ließ sich nicht mehr holen. Beim nächsten Öffnen wird er jetzt zurückgesetzt.
- Mit einem Sicherheitsschlüssel (FIDO-Stick) hing die Oberfläche während jeder USB-Übertragung bis zu fünf Sekunden. Die Übertragung läuft jetzt auf einem eigenen Faden.
- Die Einstellungen der Passwort-Ableitung (Argon2id) aus der Fachdatei werden vor dem Entsperren geprüft. Eine manipulierte Datei konnte die App vorher abstürzen oder minutenlang hängen lassen.
- Der Wiederherstellen-Bildschirm sagt jetzt, dass ein anderes Gerät mit denselben 12 Wörtern angemeldet bleibt und weiter Nachrichten bekommt.
- Die Anleitung „Nur in der Nähe“ behauptete, die Zustellung über Funk sei noch nicht gebaut, und verlangte den Standortzugriff, den BitDM gar nicht anfordert. Sie beschreibt jetzt, was der Nahbereich tatsächlich kann: Bluetooth 5 und Android 12 auf beiden Seiten, rund zwei Meter gemessen, und die Kontaktanfrage geht erst über den Relay hinaus.

**Behoben (Relay)**
- Ein Fremder konnte die Anmeldung eines Geräts stören, indem er dessen Einmal-Nonce verdrängte. Die Plätze gehören jetzt der Herkunft der Anfrage; über Tor dem Circuit, sobald der Onion-Dienst die Circuit-Kennung weitergibt.
- Jede Zwischenlager-Marke zählt mindestens 1 MiB gegen die Tagesmenge. Vorher ließen sich mit winzigen Marken beliebig viele Einträge und Dateien anlegen.
- Der Onion-Dienst bremst je Circuit statt nur für alle zusammen (Vorlage in `deploy/onion/`).
- Die Relay-Vorlage setzt HSTS.
- `install.sh` richtet ein festes Release ein (Tag und Commit), nicht mehr den jeweils neuesten Stand von `main`.

**Dokumentation**
- Das README beschrieb das Mehrgeräte-Verhalten falsch („eine Identität je Gerät“). Richtig ist: bis zu fünf Geräte je Adresse, und ein Gerät abmelden geht nicht.

**Tests**
- Die Testhilfen laufen auch unter Linux und macOS (`python3`, `BITDM_PYTHON`), und die Anhang-Tests hängen nicht mehr je nach Startreihenfolge.

**Bau**
- Die Android-APK entsteht ab dieser Fassung im F-Droid-Image (Workflow „Android (F-Droid-Bau)“) und wird lokal signiert. So kann F-Droid sie bitgleich nachbauen und die Entwickler-Signatur übernehmen. Flutter liegt dafür als Submodul in `secure-messenger/app/.flutter`. Einzelheiten in [`secure-messenger/fdroid/README.md`](secure-messenger/fdroid/README.md).

## 1.9.0 — 26.09.2026

**Neu**
- **Codewort für die Fernlöschung.** Du legst selbst ein Wort oder einen Satz fest und sagst es deinen Vertrauenskontakten persönlich. Schreibt ein Vertrauenskontakt dir genau dieses Wort (Groß/klein und Leerzeichen egal), zählt es wie `/wipe` — es erscheint nicht im Chat und löst keine Benachrichtigung aus. Von allen anderen ist es eine normale Nachricht. Gespeichert ist nur ein gesalzener Prüfwert, nicht das Wort. Setzen, ändern und entfernen verlangt eine frische Entsperrung.
- **Panik-Wort oder -Satz.** Mindestens 4 Zeichen, auch mit Leerzeichen, keine Stärkeprobe mehr. Am Sperrbildschirm statt des Passworts eingetippt, löscht es still alles. Wer nur mit Fingerabdruck oder Geräte-PIN entsperrt, bekommt am Sperrbildschirm jetzt immer das Feld „App-Passwort“, um es einzutippen (vorher fehlte es nach dem erneuten Sperren).
- **Update-Hinweis.** Der Relay nennt bei der Anmeldung die neueste Fassung; ist sie neuer, zeigt die Chatliste „BitDM X ist verfügbar. Du kannst aktualisieren, musst aber nicht.“ „Später“ blendet ihn für diese Fassung aus. Auf Android einmal pro Fassung eine leise Benachrichtigung. Keine zusätzlichen Anfragen.

**Behoben (Nahbereich)**
- Nach dem ersten Anhalten (Sperren, „Nahbereich aus“) hörte BitDM nicht mehr auf Bluetooth-Ereignisse, bis die App neu startete: Nachrichten über den Nahbereich blieben hängen. Geprüft auf einem Galaxy S25 Ultra mit dem PC als Gegenstelle, auch nach Sperren und Entsperren.

**Geprüft**
- Neuer Testlauf auf echtem Windows (`integration_test/windows_plattform_test.dart`): Screenshot-Sperre, Windows-Schlüsselspeicher, zwei und drei echte Kerne gegen einen lokalen Relay (Nachricht, Quittung, Anhang verschlüsselt auf der Platte, Gruppe, Codewort, Update-Hinweis), Passwort-Sperre und Panik-Satz über die Oberfläche.

## 1.8.3 — 26.09.2026

**Behoben (Nahbereich)**
- Android meldet BitDMs Bluetooth-Postfach jede Verbindung des Telefons — auf dem S25 sofort ein Fitbit und ein weiteres gekoppeltes Gerät. BitDM zählte sie als Gegenstellen, sie belegten Plätze, und BitDM versuchte sie zu trennen (bei mehr als vier Geräten, ab 1.8.1 schon nach 10 Sekunden Stille). Blieb eine solche Verbindung bestehen, verwarf BitDM danach alles, was über sie kam. Jetzt wird eine Verbindung erst mit dem ersten Schreiben ins Postfach zur Gegenstelle; andere Geräte fasst BitDM nicht an.
- Geprüft auf einem Galaxy S25 Ultra (Android 16) mit dem PC als Gegenstelle: Schreiben sofort und nach 19 Sekunden Stille kommt an; mit 1.8.2 ging der zweite Fall verloren.

## 1.8.2 — 26.09.2026

**Behoben**
- Bei Sperrfrist „sofort" sperrte die eigene Dateiauswahl die App: Android legt den Dateiwähler vor die App, und das zählte als Verlassen. Das Ergebnis kam trotzdem an, und der Anhang lief in die geschlossene Datenbank — nach dem Entsperren stand nur ein Fehler da. Jetzt zählen die eigene Dateiauswahl und „Speichern unter" nicht als Verlassen (höchstens 2 Minuten, danach greift die Sperre doch); wurde dennoch gesperrt, geht die Datei nach dem Entsperren hinaus. Wer die App wirklich verlässt, wird weiter sofort gesperrt.
- Die Windows- und Linux-Fassung horchen nicht mehr auf den Bluetooth-Kanal, den es nur auf Android gibt.

## 1.8.1 — 25.09.2026

Sicherheitsfassung. Eine eigene Prüfung in fünf Bereichen (Server, Kryptografie und Speicher, Protokoll, Oberfläche, Plattform) fand rund 80 Befunde; alle sind behoben oder unter „Bekannte Lücken" im README benannt. Ein externes Audit ist das nicht — der Weg dahin steht in `secure-messenger/docs/AUDIT.md`.

**Schwerwiegend, behoben**
- Relay: ohne Anmeldung ließ sich der Speicher erschöpfen (Nonces und Bremsen wurden nie aufgeräumt); ein Fremder konnte durch Fluten die wartenden Nachrichten eines anderen verdrängen.
- Foto-Metadaten: nach dem ersten Bild einer JPEG blieb alles erhalten — zweite eingebettete Bilder mit GPS, Samsung-Anhänge, Bewegtfoto-Videos.
- Gesendete Sprachaufnahmen blieben unverschlüsselt auf dem Gerät, auch nach „Alles löschen" und Fernlöschung.
- Die Sperre legte sich nicht über offene Dialoge — Teile der zwölf Wörter blieben nach dem Sperren sichtbar.
- Eine Nachricht, die einmal Bluetooth versucht hatte, ging nie mehr über den Relay; der Nachversand eines Anhangs schickte den Dateinamen statt der Anleitung; Gruppenpost ging bei vorübergehenden Fehlern verloren.
- Der erste Empfänger eines Anhangs löschte ihn für alle anderen (Zweitgeräte, Gruppen).

**Weiter behoben (Auswahl)**
- Anhänge liegen auf dem Gerät verschlüsselt; entschlüsselt wird nur zum Ansehen.
- Tor: TLS bis in den Onion-Dienst, geprüft gegen das Zertifikat von relay.bitdm.net — ein falscher Proxy auf 127.0.0.1 liest nichts mehr mit. Im Browser ist Tor ausgeblendet.
- Fernlöschung nur von aktuellen Vertrauenskontakten, 24-Stunden-Fenster ab Absendezeit, Abbrechen nur mit frischer Anmeldung.
- Teile der zwölf Wörter mit Fingerabdruck (`BITDM-TEIL-2`), nach der Zustellung aus dem eigenen Verlauf geschwärzt.
- App-Passwort mit nicht-lateinischen Zeichen war schwächer als es aussah; ein Panik-Passwort war an der Zahl der Fächer erkennbar.
- Frische Anmeldung vor heiklen Aktionen (Teile erzeugen, Wörter anzeigen, Faktor entfernen, Sperrfrist ändern).
- Mikrofon geht aus, sobald die App nicht mehr sichtbar ist; empfangene HTML/SVG öffnen als Text.
- Bluetooth-Postfach: Sperre bei Überfüllung, stumme Verbindungen fliegen nach 10 s.
- Windows: Screenshot-Sperre wirkt jetzt wirklich (vorher nur angezeigt).
- Zwischenlager: 33 MiB je Stück, Marken nur einmal verwendbar, Platz unter Sperre reserviert.

**Unter der Haube**
- CodeQL, OpenSSF Scorecard und Dependabot auf GitHub; alle Aktionen per Commit-SHA gepinnt; Linux-Paket mit Herkunftsnachweis (`gh attestation verify`).
- Server-Abhängigkeiten mit Prüfsummen gesperrt.
- Datenbankschema 14; `SECURITY.md` mit privatem Meldeweg.

## 1.8.0 — 25.09.2026

**Neu**
- Echte Ungelesen-Zahl je Unterhaltung; Nachrichten in die offene Unterhaltung gelten sofort als gelesen.
- Ruhezeiten (auch über Mitternacht); angeheftete Chats und Erwähnungen kommen durch.
- Wiederherstellung über Vertrauenskontakte: die zwölf Wörter als Shamir-Teile (2/3, 3/5, 4/7).
- Fernlöschung durch Vertrauenskontakte: k von n, 24 Stunden, 10 Minuten Countdown mit Abbrechen.
- Einmal-Ansicht für Fotos und Sprachnachrichten; geholte Bilder erscheinen in der Blase.
- Verteilerlisten; Erwähnungen in Gruppen (`@XLLW…S7JD`); Zustellhaken je Gruppenmitglied.
- Sicherung wahlweise mit den Anhangdateien selbst (bis 100 MB).
- Metadaten auch aus HEIC, AVIF, MP4, MOV und 3GP entfernt.
- Verbindung über Tor (Orbot/SOCKS5), der Relay als Onion-Dienst; wahlweise Tarnverkehr.
- Notizen: Bearbeiten, Löschen, Reaktionen und Anheften reisen auf die eigenen Geräte.
- Windows-Installer (Inno Setup).

**Behoben**
- Eigene Anhänge ließen sich nach dem Versand nicht öffnen (der Pfad zeigte auf die Quelle).
- Der Punkt „ungelesen" blieb stehen, bis man selbst antwortete.
- Leere Notizen hießen in der Liste „Neuer Kontakt".

**Unter der Haube**
- SQLite3 Multiple Ciphers wird aus Quelltext übersetzt statt vorgebaut geladen (F-Droid).
- Keine Google-verschlüsselten Abhängigkeitsdaten und keine Versionsverwaltungs-Angaben in der APK.
- Datenbankschema 13; ältere Datenbanken werden beim Start umgestellt.
- Prüfung bei jedem Push auf GitHub (flutter analyze, flutter test, pytest).

## 1.7.0 — 25.09.2026

- Neun Themen, darunter Material mit der Akzentfarbe des Systems; langsamer Wechsel mit Chiffre-Schleier; wandernde Themen.
- Neue Nachrichten entschlüsseln sich sichtbar (abschaltbar).
- Foto-Metadaten (GPS, Kamera, Zeit) aus JPEG, PNG und WebP entfernt, neutrale Bildnamen.
- Markierte Nachrichten (★) und Filter der Chatliste.
- Befehle in der Schreibzeile: `/timer`, `/verify`, `/poll`, `/theme`, `/shrug`.
- Schlüsselbild (Randomart) statt eines erfundenen „Fingerabdrucks".
- Quittungen zufällig verzögert gegen Zuordnung über die Zeit.
- Sprache und Aussehen werden gespeichert.

## 1.6.1 — 25.09.2026

- Eine Lesebestätigung konnte ältere, noch nicht verschickte Nachrichten auf „gelesen" setzen — sie wären nie mehr gesendet worden.
- Nach einem Neustart fehlten Gruppen in der Chatliste.
- Spoiler standen in Vorschau, Zitat und Suche im Klartext.
- Dialoge und Auswahlfenster im Stil der App.

## 1.6.0 — 25.09.2026

- Gruppen bis 20, Umfragen, Sprachnachrichten, Reaktionen, Antworten, Bearbeiten, Löschen für alle, Anheften, Archiv, Stumm, Suche, Formatierung mit Spoilern, geplante Nachrichten, Notiz an mich, Sicherung, Panik-Passwort, Inkognito-Tastatur, Mehrgeräte.
