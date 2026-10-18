# Bluetooth zwischen zwei Telefonen messen — Anleitung

Stand: 17.10.2026, für BitDM 1.9.1.

## Wozu

Im README steht unter „Bekannte Lücken“: Der Nahbereich ist einmal
Telefon→Telefon gemessen (29.07.2026) und Telefon↔PC in beide Richtungen
(26.09.2026). **Zwei aktuelle Telefone gegeneinander sind seit 1.8.x nicht neu
gemessen.** Diese Anleitung erzeugt genau diese Messung, mit einem Protokoll,
das sich ins README übernehmen lässt.

Das geht nicht im Emulator und nicht im Container: Es braucht zwei echte
Funkchips. Deshalb macht es ein Mensch mit zwei Telefonen in der Hand.

## Was gebraucht wird

- **Zwei Android-Telefone mit Android 12 oder neuer.** Darunter verlangt
  Android für eine Bluetooth-Suche den Standortzugriff, und den fragt BitDM
  nicht ab.
- **Beide mit Bluetooth 5.0 oder neuer** (laut Datenblatt). Bluetooth 4.2 kann
  keine erweiterte Werbung empfangen, das ist gemessen. Achtung, bekannter
  Fehler: Ein Telefon mit Bluetooth 4.2 bekommt in der App derzeit keinen
  klaren Hinweis darauf. Also vorher im Datenblatt nachsehen.
- **Auf beiden dieselbe BitDM-Fassung**, z. B. das signierte APK 1.9.1 von
  bitdm.net oder aus dem eigenen F-Droid-Verzeichnis. Die Fassung zeigt
  Android unter Einstellungen → Apps → BitDM; notieren.
- Eine Uhr mit Sekunden (Stoppuhr am dritten Gerät oder die Uhrzeit an der
  Nachricht).
- Optional: `adb` am Rechner, um nach der Messung die Protokolle zu sichern.

## Ablauf

### 1. Vorher Kontakte werden — mit Internet

Auf beiden Telefonen eine Identität anlegen (oder die vorhandene benutzen).

**Nur einer fügt hinzu, der andere nimmt an.** Telefon A fügt B per QR-Code
oder Adresse hinzu, B nimmt die Anfrage an. **Nicht beide gegenseitig
hinzufügen:** Dann bleiben beide Seiten auf „ausstehend“ stehen (bekannter
Fehler, auch mit Internet).

Die Kontaktanfrage geht nur über den Relay. Über Bluetooth findet BitDM nur,
wer schon bestätigter Kontakt ist. Deshalb muss dieser Schritt mit Internet
passieren.

Dann je eine Nachricht A→B und B→A über den Relay schicken und warten, bis
beide angekommen sind. Damit steht die verschlüsselte Sitzung, bevor der Funk
übernimmt.

### 2. Beide Schalter auf beiden Telefonen

Auf **beiden** Telefonen in den Einstellungen (die App erklärt dasselbe unter
„Nur in der Nähe, Schritt für Schritt“):

1. **„Bluetooth benutzen“** einschalten und die Bluetooth-Berechtigung
   erlauben. Nach dem Standort wird nicht gefragt; wenn doch, ist etwas falsch,
   bitte notieren.
2. **„Nur in der Nähe“** einschalten. Dann spricht BitDM keinen Server mehr an.

Jeder Schalter gilt nur für sein Telefon. Wer „Nur in der Nähe“ aus hat,
schickt weiter über den Server, und die Messung misst dann nicht den Funk.

Der Schalter ist kein Flugmodus: Das Telefon behält sein Internet, nur BitDM
benutzt es nicht. Für einen zweiten, strengeren Durchgang (siehe 5.) beide
Telefone zusätzlich in den Flugmodus und **Bluetooth danach wieder
einschalten**.

### 3. Aufstellen

- Abstand 1–2 m, derselbe Raum, keine Wand dazwischen. Gemessen ist bisher nur
  so; durch Wände reicht es weniger weit.
- Bei beiden Telefonen BitDM im Vordergrund geöffnet, Bildschirm an, und auf
  beiden den Chat mit dem anderen offen.

### 4. Messen: beide Richtungen

**A → B:**

1. Auf A eine Nachricht schreiben, die den Lauf benennt, z. B.
   `Messung 1 A→B 14:03:20`, und mit dem Senden die Stoppuhr starten.
2. Stoppen, sobald sie auf B erscheint.
3. Prüfen: Trägt die Nachricht auf B (und auf A) das Zeichen **„Direkt“**? Nur
   dann ging sie über Bluetooth. Ohne „Direkt“ ist die Messung ungültig.
4. Auf A die Haken ansehen: zugestellt (✓✓)? gelesen?

**B → A:** dasselbe in die Gegenrichtung, als `Messung 1 B→A …`.

Jede Richtung **dreimal** wiederholen, damit ein Ausreißer auffällt.

### 5. Wenn Zeit ist: Zusatzläufe

Jeweils mit beiden Richtungen und mit eigener Zeile im Protokoll:

- **Strenger Durchgang:** beide im Flugmodus, Bluetooth an (siehe 2.).
- **Längere Nachricht:** etwa 700 Zeichen.
- **Zehn kurze Nachrichten hintereinander:** Kommen alle an, in der richtigen
  Reihenfolge?
- **Abstand:** 5 m im selben Raum, dann durch eine Wand.
- **Telefon B mit gesperrtem Bildschirm:** Kommt etwas an, und wann?

### 6. Zurückschalten

Auf beiden „Nur in der Nähe“ wieder ausschalten. Dabei prüfen:

- Geht etwas, das gewartet hat, jetzt über den Relay hinaus?
- Erscheint eine Nachricht doppelt?

### 7. Belege sichern

- **Bildschirmfotos** beider Chats, auf denen das Zeichen „Direkt“ und die
  Uhrzeiten zu sehen sind.
- Optional, direkt nach der Messung, mit `adb`:

  ```bash
  adb -s <seriennummer-a> logcat -d > telefon-a-logcat.txt
  adb -s <seriennummer-b> logcat -d > telefon-b-logcat.txt
  ```

  Diese Protokolle können Geräte- und Netznamen enthalten. Vor dem
  Weitergeben durchsehen und nicht ungeprüft ins Repository legen.

## Protokoll-Vorlage

Einmal je Lauf eine Zeile:

| Datum | Telefon A (Modell, Android, BT) | Telefon B (Modell, Android, BT) | BitDM | Durchgang | Abstand | Richtung | gesendet | angekommen | Sekunden | „Direkt“ | Haken | Bemerkung |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| | | | 1.9.1 | Nur in der Nähe | 1,5 m | A→B | | | | ja/nein | ✓/✓✓ | |
| | | | 1.9.1 | Nur in der Nähe | 1,5 m | B→A | | | | ja/nein | ✓/✓✓ | |

## Wenn nichts ankommt

Der Reihe nach prüfen, auf **beiden** Telefonen:

1. Steht der Kontakt als bestätigt in der Chatliste (nicht als ausstehende
   Karte)? Wenn nicht: zurück zu Schritt 1, mit Internet.
2. Sind „Bluetooth benutzen“ **und** „Nur in der Nähe“ an?
3. Ist Bluetooth im System an? Zeigen die Einstellungen unter „Bluetooth
   benutzen“ eine Warnung („Bluetooth ist ausgeschaltet“, „BitDM darf
   Bluetooth noch nicht benutzen“, „Braucht Android 12“)?
4. Android 12 oder neuer und Bluetooth 5 auf beiden?
5. Beide Apps im Vordergrund, Bildschirm an, höchstens 2 m Abstand?

Kommt dann immer noch nichts an, ist das ein Ergebnis: bitte mit Protokoll und
`logcat` festhalten, nicht wegwiederholen.

## Was danach ins README gehört

Die Zeile „Zwei aktuelle Telefone gegeneinander sind seit 1.8.x nicht neu
gemessen“ (README.md und README.de.md, „Bekannte Lücken“) durch das Ergebnis
ersetzen: Datum, beide Telefonmodelle, Fassung, Abstand, Zeit je Richtung und
ob das Zeichen „Direkt“ zu sehen war. Dazu in der Tabelle „Nahbereich, zweite
Richtung“ den Telefon↔Telefon-Lauf eintragen.
