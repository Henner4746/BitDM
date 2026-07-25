# Nah-Test — Ablauf

Wegwerf-App. Nach dem Test wird sie deinstalliert und der Ordner gelöscht.

Sie gehört **nicht** zu BitDM. Der Grund: für Wi-Fi Direct braucht es unterhalb
von Android 13 den Standortzugriff. Der wäre in einem Messenger, der Metadaten
vermeidet, die invasivste Berechtigung überhaupt — und ob es ihn wirklich
braucht, soll dieser Test zeigen, bevor er irgendwo dauerhaft steht.

---

## Vorbereitung

Auf **beiden** Telefonen:

- App installieren, öffnen, alle Berechtigungen erlauben
- **Bluetooth an**
- **WLAN an** — auch wenn ihr keins benutzt. Wi-Fi Direct braucht den Funkchip,
  und wir wollen ja gerade sehen, ob eine bestehende WLAN-Verbindung darunter
  leidet
- Am besten **im selben WLAN**, damit Frage 4 überhaupt messbar ist
- Denselben **Code** eintragen (Standard 1234)

Telefone nebeneinander legen, ein bis zwei Meter reichen.

---

## Durchgang

### Schritt 1 — Bluetooth

Auf **beiden**: `1a BLE aussenden`, dann `1b BLE suchen`.

Erwartet: auf beiden erscheint innerhalb weniger Sekunden eine grüne Zeile
`BLE: GEFUNDEN nach … ms`.

**Notieren:** wie viele Millisekunden. Das ist die Zeit, die „In der Nähe"
später zum Finden braucht.

Kommt nichts: kurz `Alles stoppen`, dann noch einmal. Manche Geräte brauchen
einen Moment, bis der Werber steht.

### Schritt 2 — Wi-Fi Direct vorbereiten

Auf **beiden**: `2 Wi-Fi Direct starten`.

Vorher wird die WLAN-Lage protokolliert — das ist der Vergleichswert für
Schritt 4.

Erwartet: nach einigen Sekunden `P2P: 1 Geraet(e): …`. Dann erscheint ein
`3 Verbinden #1`-Knopf.

### Schritt 3 — Verbinden

**Nur auf EINEM** Telefon: `3 Verbinden #1`.

> **Jetzt aufs andere Telefon sehen.** Kommt dort ein Systemdialog? Muss jemand
> etwas bestätigen? Das ist Frage 3, und sie lässt sich nur mit den Augen
> beantworten.

Erwartet: `P2P: VERBUNDEN nach … ms`, danach drei Zeilen
`Socket: Runde n — 500 Byte hin und zurück in … ms`.

### Schritt 4 — Was ist mit dem WLAN?

Auf beiden: `WLAN prüfen`.

Vergleichen mit der Zeile von vorhin. Interessant ist:

- Steht `aktives Netz ist WLAN` noch auf `true`?
- Steht `Internet: true` und `geprueft: true` noch da?
- Lädt eine Webseite noch?

### Schritt 5 — Aufräumen

Auf beiden: `Alles stoppen`. Dann `Protokoll kopieren` und mir schicken.

---

## Worauf es ankommt

| Frage | Woran man es sieht |
|---|---|
| Wird das Leuchtfeuer gesehen? | grüne `BLE: GEFUNDEN`-Zeile, und wie schnell |
| Verbindet Wi-Fi Direct? | grüne `P2P: VERBUNDEN`-Zeile, und wie lange es dauert |
| Kommt ein Dialog? | mit den Augen, auf dem anderen Telefon |
| Reißt das WLAN ab? | Vergleich der beiden `WLAN`-Zeilen |
| Wie schnell ist es? | die drei `Socket: Runde`-Zeilen |

Rote Zeilen sind Fehler, grüne sind Erfolge, gelbe sind Hinweise an dich.

**Alles ist ein Ergebnis** — auch „Wi-Fi Direct verbindet nicht". Dann wissen
wir es, bevor etwas darauf gebaut ist, und nehmen Bluetooth allein. Genau dafür
ist der Test da.
