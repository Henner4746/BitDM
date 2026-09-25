# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Zwei Gruppen, bewusst gestaffelt auf einer Seite:

1. **Technisch versierte Datenschutz-Interessierte** — ordnen Signal-Protokoll,
   Forward Secrecy und Metadaten selbst ein, prüfen Behauptungen nach und
   erkennen Schwätzerei sofort. Sie sind die Gruppe, die ein neues
   Krypto-Projekt überhaupt zuerst ausprobiert.
2. **Normale Nutzer**, die einfach sicher schreiben wollen. Sie kommen später,
   wenn die App im Store steht.

Die Seite spricht oben verständlich und liefert weiter unten die technischen
Belege für alle, die nachprüfen wollen.

Dazu kommt ein dritter, nicht-menschlicher Leser: die **Google-Play-Prüfung**.

## Product Purpose

Informationsseite für **BitDM**, einen Ende-zu-Ende verschlüsselten Messenger
ohne Telefonnummer und ohne Username.

Der unmittelbare Anlass ist funktional, nicht werblich: Die Seite wird für das
**Google-Play-Console-Konto** gebraucht. Als Entwickler-Website ist bereits
`bitdm.net` hinterlegt.

Erfolg heißt: (1) die Play-Anforderungen sind erfüllt, (2) ein technisch
kundiger Besucher versteht in unter einer Minute, was BitDM anders macht und
was es **nicht** kann, (3) niemand fühlt sich getäuscht.

## Positioning

Die Identität **ist** ein kryptografischer Schlüssel. Es gibt keine
Registrierung, keine Telefonnummer, keinen Username, kein Konto und kein
Passwort — die Adresse, die man weitergibt, ist der öffentliche Schlüssel
selbst. Ein bösartiger Server kann deshalb keinen fremden Schlüssel
unterschieben, ohne dass die Adresse sich ändert und auffällt.

Darunter läuft das Signal-Protokoll (X3DH für den Sitzungsaufbau, Double
Ratchet für Forward Secrecy), quelloffen unter AGPL-3.0.

## Operating Context

- Zieladresse: **`bitdm.net`** (bereits in der Play Console hinterlegt).
- Gehostet auf dem vorhandenen VPS hinter nginx, wie die übrigen vHosts.
- Besucher kommen überwiegend über einen Link — aus der Play-Console-Prüfung,
  von GitHub oder aus einer Empfehlung. Kein Suchmaschinen-Traffic zu erwarten.
- Zweisprachig **Deutsch und Englisch, im Betrieb umschaltbar**. Die App
  beherrscht beide Sprachen bereits (`app/lib/data.dart`).

## Capabilities and Constraints

**Bestätigte Produktwahrheit** (belegt im Repository):
- Signal-Protokoll über `libsignal_protocol_dart`, X3DH + Double Ratchet.
- Identität aus einer **BIP39-Seed-Phrase mit 12 Wörtern**; daraus abgeleitet
  der Identitätsschlüssel und der Schlüssel der lokalen Datenbank.
- Adresse: 56 Zeichen, Base32 mit Prüfsumme, angezeigt in 14 Gruppen à 4.
- Server ist ein reines Relay: speichert Prekey-Bundles, leitet undurchsichtige
  Blobs weiter, **kann Nachrichten nicht lesen**.
- Lokale Nachrichtendatenbank verschlüsselt; privater Schlüssel verlässt das
  Gerät nie; Android-Auto-Backup ist abgeschaltet.
- Die App stellt **keine Netzwerkanfrage für Typografie** — Schriften sind
  lokal eingebettet.

**Grenzen, die genannt werden müssen und nicht beschönigt werden dürfen:**
- v1: ein Gerät je Identität, nur 1:1, nur Text.
- Der Relay sieht **Metadaten** — wer wann mit wem. Ende-zu-Ende-Verschlüsselung
  schützt das prinzipiell nicht. Das ist zu benennen, nicht zu verschweigen.
- Wer die Seed-Phrase verliert, verliert die Identität endgültig. Es gibt keinen
  Zurücksetzen-Link.
- Die App ist **noch nicht veröffentlicht**.

**Offen, nicht erfunden:**
- Zieladresse für das E-Mail-Formular (Backend noch nicht festgelegt).
- Eine mit dem echten Release-Schlüssel signierte APK existiert inzwischen
  (Zertifikat CN=Henrik Reuber, SHA-256 e325b01c…). Der Download bleibt aber
  bewusst geschlossen: die App kann noch keine Nachricht senden. Erst wenn sie
  funktioniert, geht die Datei samt Fingerabdruck online.

## Brand Commitments

- Name: **BitDM**. Paketname `com.bitdm.bitdm`.
- Visuelle Welt **„Nocturne"**, bereits im Prototyp und in der App festgelegt:
  sehr dunkler Grund (`#0b0c12`), Flächen (`#161826`), Violett-Akzente
  (`#9184d9`, `#b5abfc`, `#d2cefd`), gedämpfte Texttöne (`#9397ab`, `#cfd3e5`).
- Schriften: **Doto** für Überschriften (versal, 700, leicht gesperrt),
  **Chivo Mono** für Lauftext. Beide unter SIL Open Font License, lokal
  eingebettet — die Seite lädt ebenfalls keine Schriften von Dritten nach.
- Lizenz **AGPL-3.0**, quelloffen. Bei einem Sicherheitsversprechen ist das
  Voraussetzung, nicht Beiwerk: Nachprüfbarkeit ist das Argument.

## Evidence on Hand

**Echt und belegbar:**
- Quellcode im Repository, AGPL-3.0.
- Relay-Server gehärtet, 15/15 Tests grün (Besitznachweis, XEdDSA, Rate-Limits).
- App: 165 Tests grün, darunter alle 24 offiziellen BIP39-Testvektoren und
  Kreuzvektoren gegen eine unabhängige Nachrechnung.
- Bildschirmfotos aus dem lauffähigen Prototyp (`prototype/index.html`).

**Existiert NICHT und darf nicht erfunden werden:**
- Keine Nutzer, keine Bewertungen, keine Downloadzahlen.
- Keine Presse, keine Auszeichnungen, keine Referenzkunden.
- Kein externes Sicherheitsaudit.
- Keine Verfügbarkeit im Play Store — der Link ist ein reservierter Platz.

## Product Principles

1. **Ehrlichkeit schlägt Reichweite.** Bei einem Sicherheitsprodukt ist eine
   kleine Unehrlichkeit auf der Startseite teurer als späte Bekanntheit. Was
   fehlt, wird als fehlend gezeigt.
2. **Behauptungen tragen Belege.** Jede technische Aussage muss im Quellcode
   nachprüfbar sein. Marketingvokabular ohne Deckung wird weggelassen.
3. **Grenzen gehören auf dieselbe Seite wie die Versprechen** — nicht ins
   Kleingedruckte. Wer Metadaten verschweigt, verliert genau die Leser, die
   das Projekt tragen würden.
4. **Die Seite verhält sich wie das Produkt.** Keine Fremd-Schriften, keine
   Tracker, keine Analyse-Skripte. Ein Datenschutz-Messenger, dessen Website
   Besucher verfolgt, widerlegt sich selbst.

## Accessibility & Inclusion

- Zweisprachig Deutsch/Englisch, umschaltbar; `lang`-Attribut wechselt mit.
- Sehr dunkle Gestaltung, aber Kontraste müssen WCAG AA erfüllen — die
  gedämpften Grautöne der Nocturne-Palette sind auf Textgrößen zu prüfen.
- Vollständig ohne JavaScript lesbar, soweit möglich; Inhalte dürfen nicht
  erst durch Skripte entstehen.
- `prefers-reduced-motion` respektieren.
