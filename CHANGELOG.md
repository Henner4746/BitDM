# Changelog

Alle Fassungen der App BitDM. Details und Belege je Funktion:
[`secure-messenger/docs/FUNKTIONSVERGLEICH.md`](secure-messenger/docs/FUNKTIONSVERGLEICH.md).
Downloads: [GitHub-Releases](https://github.com/Henner4746/BitDM/releases) und <https://bitdm.net>.

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
