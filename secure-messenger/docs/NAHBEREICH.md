# In der Nähe — Entwurf

Stand 25.07.2026. Entschieden im Gespräch mit Henrik; hier steht das Ergebnis
und **warum** es so entschieden wurde, damit es beim nächsten Anfassen nicht neu
verhandelt werden muss.

---

## Wozu

Nachrichten zwischen zwei Telefonen ohne Internet. Zwei Ausbaustufen, in dieser
Reihenfolge:

1. **Ausfallsicherung.** Kein Netz, Relay nicht erreichbar, Funkloch. Dieselben
   Kontakte, dieselben Unterhaltungen — die Nachricht nimmt nur einen anderen
   Weg. Die App schaltet von selbst um.
2. **Spurlos-Modus.** Später. Ein Schalter, mit dem gar nichts je einen Server
   berührt — auch keine Prekey-Abfrage.

Stufe 2 ist kein zweites Produkt, sondern eine Einschränkung von Stufe 1. Wenn
Stufe 1 richtig gebaut ist, kostet sie wenig.

---

## Zwei Funde, die den Entwurf tragen

**Die Adresse IST der öffentliche Schlüssel.** `base32(pubkey || prüfsumme)`,
siehe `lib/core/crypto/address.dart`. Damit lässt sich die Signatur auf einem
Prekey-Bundle allein aus der Adresse prüfen. Der Relay *verteilt* Bundles, er
*verbürgt* sie nicht.

→ Bundles über die Nahverbindung auszutauschen ist kryptografisch gleichwertig.
Der Spurlos-Modus ist damit wirklich möglich und nicht nur fast.

**Kontakte hinzufügen läuft schon offline.** `addContact` prüft die Adresse
gegen ihre eigene Prüfsumme und speichert lokal; die Kontaktanfrage wird
nachgeschickt, sobald ein Weg da ist.

→ Der Ablauf „zwei treffen sich ohne Netz" trägt vollständig:
QR scannen → beide kennen die Adresse → gemeinsames Geheimnis rechenbar →
Leuchtfeuer greift → Bundles über die Nahverbindung → Nachricht.

---

## Entscheidungen

### Erkennen: Leuchtfeuer

Steht und ist geprüft (`lib/core/nah/leuchtfeuer.dart`, 15 Tests). Je Kontakt
ein gemeinsames Geheimnis aus X25519, daraus 6 Byte je 15-Minuten-Fenster.

Die eigene Adresse auszusenden wäre der schlimmste denkbare Weg gewesen: wer sie
einmal gesehen hat, könnte damit überall verfolgen, wo dieses Telefon ist. Ein
Messenger ohne Telefonnummer, der stattdessen eine dauerhafte Funkkennung in die
Gegend ruft, hätte nichts gewonnen.

**Folge, die man kennen muss:** man findet ausschließlich Leute, die man schon
als Kontakt hat. Fremde sind unsichtbar — nicht aus Versehen, sondern von
Bauart. Wer jemanden neu kennenlernt, scannt seinen QR-Code (geht offline).

### Transport: BLE finden, Wi-Fi Direct übertragen

Henriks Entscheidung, gegen meine Empfehlung. Meine Empfehlung war BLE allein:
eine Nachricht ist 400–700 Byte, BLE schafft 5–20 KB/s, das wäre in
Millisekunden drüben — und ein zweiter Verbindungsweg ist eine zweite
Fehlerquelle.

Sein Argument trägt: Wi-Fi Direct hält die Tür für Anhänge offen, und dieselbe
Schicht später nachzurüsten wäre teurer als sie gleich richtig zu bauen.

**Zwei Punkte, die der Wegwerf-Test klären muss:**

- Wi-Fi Direct trennt auf vielen Geräten die bestehende WLAN-Verbindung oder
  stört sie. Bei „kein Netz" egal; bei „schlechtes Netz" macht es die Lage
  womöglich schlimmer.
- Ob auf Samsung ein Systemdialog erscheint, den die Gegenseite bestätigen muss.
  Das ist der Unterschied zwischen „läuft von selbst" und „beide müssen tippen".

Nicht aus dem Gedächtnis beantworten. Messen.

### Vorgehen: Wegwerf-Test zuerst

Ein Bildschirm, der nur eines tut: finden, verbinden, ein paar Byte hin und
zurück, und anzeigen was passiert. Erst danach die richtige Schicht.

Das ist dieselbe Disziplin, die in diesem Projekt jeden ernsten Fehler gefunden
hat — die 33-gegen-32-Byte-Falle bei libsignal, das stille `PRAGMA key` bei
gewöhnlichem SQLite, `Ecdh.p256`, das `UnimplementedError` wirft.

### Wann gesendet und gesucht wird

Solange die App offen ist — **und** im Hintergrund, solange der Relay nicht
erreichbar ist und der Hintergrundempfang an ist.

Der Zusatz ist nicht Bequemlichkeit. Ohne ihn müssten **beide** Seiten
gleichzeitig BitDM offen haben, und die Funktion wäre eine, die niemand je
erlebt. Genau dann, wenn kein Netz da ist, kostet das Suchen ohnehin nichts:
die Verbindung, die sonst Akku bräuchte, gibt es ja gerade nicht.

**Hängt an derselben Sperre wie der Hintergrundempfang.** Bei Sperrfrist
„sofort" ist die Entropie beim Weglegen weg, und ohne sie gibt es keine
Signal-Sitzung — auch nicht über Bluetooth.

### Wegwahl: Relay zuerst, Nähe als Ausfall

Der gewohnte Weg bleibt der Hauptweg. Vorhersagbar, und die Nachricht kommt auch
an, wenn der andere weggeht.

**NIEMALS BEIDE WEGE FÜR DIESELBE NACHRICHT.** Das wären zwei verschiedene
Verschlüsselungen desselben Textes, und der Empfänger zeigte ihn zweimal an. Je
Nachricht genau ein Weg.

### Anwesenheit: je Kontakt abschaltbar

Standard an, für einzelne Kontakte abschaltbar. Der Grund ist konkret: wer
jemanden in den Kontakten hat, dem er nicht mehr begegnen will, verrät ihm sonst
jedes Mal seine Anwesenheit, wenn beide im selben Café sitzen. Ein Messenger
ohne Telefonnummer, der stattdessen Anwesenheit verrät, hätte an der falschen
Stelle gespart.

Braucht ein Feld am Kontakt und damit eine Schemaänderung.

### Anzeige: ein Zeichen an der Nachricht

Eine über die Nähe zugestellte Nachricht bekommt ein kleines Zeichen; antippen
erklärt: „Direkt übertragen, kein Server beteiligt."

Kein Anwesenheitspunkt an Kontakten. Der wäre bequem, wäre aber eine
Anwesenheitsanzeige — und die soll es in dieser App nirgends geben.

---

## Was noch offen ist

- Der Wegwerf-Test. Alles darunter hängt an seinem Ergebnis.
- Wer verbindet, wenn sich beide sehen. Vorschlag: die kleinere Adresse fängt
  an — deterministisch, ohne Aushandeln.
- Wie oft ausgesendet wird (Akku gegen Auffindezeit).
- Der Spurlos-Modus. Erst wenn Stufe 1 steht.


---

# Der Wegwerf-Test ist gelaufen — 26.07.2026

Zwei echte Telefone, beide am Kabel, vom Rechner aus gefahren und mitgemessen.

| | |
|---|---|
| A | Samsung SM-S938B (Galaxy S25 Ultra), Android 16, API 36 |
| B | Samsung SM-G973F (Galaxy S10), DerpFest, Android 16, API 36 |

## Was herauskam

**BLE findet sofort.** A sah B nach **52 ms**, B sah A nach **133 ms**, jeweils
mit der vollen 6-Byte-Nutzlast und −25 bis −30 dBm auf zwei Metern. Das
Leuchtfeuer passt also unveraendert in ein Werbepaket, und die Suchzeit spielt
im Gesamtbild keine Rolle.

**Ohne Standortzugriff.** Beide Geraete laufen auf API 36, dort traegt
`NEARBY_WIFI_DEVICES` das Wi-Fi-Direct-Teil, und die BLE-Suche kommt mit
`BLUETOOTH_SCAN` aus — sofern das Flag `neverForLocation` gesetzt ist. Damit
faellt die Sorge weg, die diesen Test ueberhaupt in eine eigene App verbannt
hat.

**Wi-Fi Direct verbindet und reisst das WLAN NICHT ab.** Vor, waehrend und nach
der Verbindung meldeten beide Telefone `aktives Netz ist WLAN: true, Internet:
true, geprueft: true`. Der Gruppenbesitzer war 192.168.49.1; 500 Byte hin und
zurueck brauchten **25,8 ms**.

**Beim ERSTEN Mal kommt ein Systemdialog.** Auf dem eingeladenen Telefon
erschien `com.android.wifi.dialog`: *„Einladung zum Aufbau einer Verbindung —
Von: Galaxy S25 Ultra — Ablehnen / Akzeptieren"*. Ohne Tippen passiert nichts.

**Beim ZWEITEN Mal kommt keiner.** Nach `Alles stoppen`, neu suchen und erneut
verbinden lief der Aufbau ohne jede Rueckfrage durch — 20 Sekunden lang
beobachtet, kein Dialog. Android merkt sich das Geraet.

## Was das fuer den Entwurf heisst

Die Entscheidung „BLE finden, Wi-Fi Direct uebertragen" **bleibt**, und der
Einwand gegen sie ist entkraeftet: das WLAN ueberlebt, und der Dialog ist kein
Dauerzustand, sondern ein einmaliger Schritt je Geraetepaar.

Er gehoert damit dorthin, wo man ihn erwartet: **ins Hinzufuegen eines
Kontakts**, nicht in den Versand einer Nachricht. Wer sich gegenseitig
aufnimmt, steht ohnehin nebeneinander und scannt einen QR-Code — dabei einmal
„Akzeptieren" zu tippen faellt nicht auf. Waere der Dialog bei jeder Nachricht
gekommen, waere Wi-Fi Direct als Ausfallweg gestorben und es haette BLE allein
werden muessen.

**Offen bleibt**, ob die Erinnerung einen Neustart oder laengere Zeit
uebersteht. Das entscheidet, ob der Dialog wirklich einmalig ist oder
gelegentlich wiederkommt — und damit, ob die Oberflaeche ihn erklaeren muss.

## Was am Test selbst nicht stimmte

Drei Dinge, die beim naechsten Mal Zeit sparen:

- **`neverForLocation` fehlte am `BLUETOOTH_SCAN`.** Ohne das Flag haelt
  Android eine BLE-Suche fuer eine Standortbestimmung und verlangt zusaetzlich
  `ACCESS_FINE_LOCATION`. Fehlt die, werden Treffer **stillschweigend**
  verworfen: die Suche laeuft, `onScanResult` kommt nie, kein Fehler, kein
  Hinweis. Erster Durchgang: beide sendeten, beide suchten, keiner fand.
- **Der Server-Socket des Gruppenbesitzers nimmt nur eine Verbindung an.**
  Runde 1 lief (25,8 ms), Runde 2 und 3 scheiterten mit `ECONNREFUSED`, und
  parallel meldete der Besitzer `EADDRINUSE`. Ein Fehler der Testapp, keine
  Eigenschaft von Wi-Fi Direct — der Durchsatz ist damit an EINEM Messwert
  belegt und nicht an dreien.
- **Die Zeitmessung auf der annehmenden Seite ist Unsinn** (`VERBUNDEN nach
  1785065582352 ms`): dort wird nie ein Startzeitpunkt gesetzt, ausgegeben wird
  die Uhrzeit selbst. Auch die 33,5 Sekunden auf der einladenden Seite sind
  kein Protokollwert — darin steckt die Zeit, bis die Automatik den Dialog
  bemerkt und angetippt hat.

---

# Zweite Messrunde — 26.07.2026, abends

Dieselben zwei Telefone, wieder vom Rechner aus gefahren. Sie beantwortet die
drei Fragen, die der erste Durchgang offengelassen hat — und eine, die er
aufgeworfen hat.

## 1. Wie viele Leuchtfeuer passen in eine Werbung?

Das ist die Frage, die unter „Was noch offen ist" als *„Wie oft ausgesendet
wird (Akku gegen Auffindezeit)"* stand. Sie stellt sich, weil das Leuchtfeuer
**je Kontakt verschieden** ist (`leuchtfeuer.dart`, `eigenesFuer` rechnet aus
dem Geheimnis mit genau diesem einen Kontakt): wer zwanzig Kontakte hat, hat
zwanzig verschiedene 6-Byte-Werte auszusenden, und eine Werbung trägt zu einem
Zeitpunkt genau eine Nutzlast.

| | S25 Ultra | S10 (LineageOS) |
|---|---|---|
| erweiterte Werbung | ja | ja |
| **gemeldete** Grenze | 1650 Byte | 1024 Byte |
| **gemessene** Grenze | **240 Byte** | **240 Byte** |
| das sind | **40 Leuchtfeuer** | **40 Leuchtfeuer** |
| alte Werbung | 3 Leuchtfeuer | 3 Leuchtfeuer |

**Die gemeldete Grenze ist unbrauchbar.** `leMaximumAdvertisingDataLength` sagt
auf dem S25 1650 Byte; schon 270 werden mit `ADVERTISE_FAILED_DATA_TOO_LARGE`
abgewiesen. Beide Geräte nehmen unabhängig voneinander bei exakt 240 Byte an —
das entspricht dem, was in **ein** Paket der erweiterten Werbung passt. Wer
1650 glaubt, baut etwas, das auf keinem Gerät läuft.

→ **Entwurf: 40 Leuchtfeuer je Werbung, auf feste 240 Byte aufgefüllt.** Das
Auffüllen ist kein Rest, sondern Absicht: die Länge der Werbung verriete sonst,
wie viele Kontakte jemand hat. Wer mehr als 40 hat, wechselt reihum durch —
aber 40 deckt fast jeden ab, und die Rundlauf-Sorge ist damit erledigt.

Eine Verwechslung durch die Füllbytes ist ausgeschlossen: 6 Byte sind 2⁴⁸
Möglichkeiten, und die Zuordnung fällt danach ohnehin beim Schlüsselaustausch
auf.

## 2. Geht eine Nachricht über BLE, ganz ohne Systemdialog?

Diese Frage hat der erste Durchgang aufgeworfen, indem er den Wi-Fi-Direct-
Dialog gemessen hat. Für den Fall, um den es geht — kein Netz, eine Nachricht
soll raus — ist ein Dialog auf der Gegenseite der Unterschied zwischen „kommt
an" und „kommt an, wenn der andere gerade hinsieht".

Gemessen mit einem GATT-Dienst und 700 Byte, der Größe einer echten Nachricht
mit Umschlag und Polsterung:

```
Server gefunden nach          77 ms
MTU ausgehandelt              517  (Nutzlast 514 → zwei Häppchen)
700 Byte hin und zurück      202 ms
ab Verbindung insgesamt      759 ms
Inhalt                       gleich
Systemdialog                 KEINER, auf keinem der beiden Geräte
```

**Damit braucht eine Nachricht kein Wi-Fi Direct.** Unter einer Sekunde vom
Suchbeginn bis zur bestätigten Zustellung, ohne dass jemand etwas antippt.

Das ist keine Umkehr der Entscheidung „BLE finden, Wi-Fi Direct übertragen“,
sondern ihre Verfeinerung mit dem, was inzwischen gemessen ist. Henriks Grund
für Wi-Fi Direct war, die Tür für **Anhänge** offenzuhalten — die bleibt offen,
und für sie ist der einmalige Dialog auch zumutbar (man schickt ein Video
bewusst, nicht nebenbei). Für Nachrichten wäre er der Unterschied zwischen
einer Funktion, die es gibt, und einer, die niemand erlebt.

→ **Entwurf: GATT für Nachrichten, Wi-Fi Direct für Anhänge.**

## 3. BLE-5-Fähigkeiten

Beide Geräte: erweiterte Werbung, mehrere Werbungen gleichzeitig, 2M-PHY,
Coded-PHY, periodische Werbung. Nichts davon ist knapp; die Grenze ist allein
die Paketgröße aus Punkt 1.

## Was an dieser Messrunde nicht stimmte

Drei eigene Fehler, alle drei stumme — und deshalb die lehrreichsten:

- **`addServiceData` ohne `addServiceUuid`.** Der Sucher filtert mit
  `ScanFilter.setServiceUuid` auf das *Service-UUID*-Feld, nicht auf die
  Dienstdaten. Fehlt das Feld, läuft die Suche und findet nie etwas — kein
  Fehler, kein Hinweis. Dieselbe Sorte stiller Fehlschlag wie das fehlende
  `neverForLocation` in Runde eins. Die vier Byte, die das Feld kostet, sind
  dagegen nichts.

- **„4 Sekunden Auffindezeit" gab es nie.** Über drei Messreihen hinweg kamen
  konstant ~4000 ms heraus, bei alter wie erweiterter Werbung, auf einem wie
  auf allen PHYs. Ich habe daraus zweimal eine Eigenschaft der Funkstrecke
  geschlossen und lag beide Male falsch: der `uiautomator dump`, mit dem das
  Skript die Knöpfe findet, dauert selbst mehrere Sekunden. Die Uhr lief
  bereits, während der Sender noch gar nicht sendete. Mit dem Sender **zuerst**
  gestartet: **120 ms und 157 ms** — dieselbe Größenordnung wie in Runde eins.

  Die Lehre ist nicht „adb ist langsam", sondern: eine Zahl, die über drei
  Versuchsanordnungen hinweg gleich bleibt, obwohl sich die gemessene Sache
  ändert, misst die Anordnung und nicht die Sache.

- **Häppchen in einer Schleife mit `Thread.sleep`.** BLE lässt immer nur *eine*
  GATT-Operation offen; jede weitere wird abgewiesen, und `writeCharacteristic`
  sagt das nur über seinen Rückgabewert. Ergebnis beim ersten Versuch: 704 Byte
  „hinausgeschrieben", auf der Gegenseite **kein einziges Byte** angekommen.
  Richtig ist, das nächste Häppchen erst in `onCharacteristicWrite` des vorigen
  loszuschicken — und dasselbe gilt für Benachrichtigungen in der Gegenrichtung
  (`onNotificationSent`).

## 4. Übersteht die Wi-Fi-Direct-Erinnerung einen Neustart?

Die letzte offene Frage aus Runde eins. **Ja.**

Beide Telefone wurden neu gestartet, während eine Wi-Fi-Direct-Gruppe bestand
(bewusst ohne `removeGroup` vorher — das hätte die Erinnerung gelöscht und die
Messung wertlos gemacht).

| | vor dem Neustart | nach dem Neustart |
|---|---|---|
| Verbindung steht nach | 1201 ms | **1412 ms** |
| Systemdialog | keiner | **keiner** |
| 500 Byte hin und zurück | — | 28,3 ms |

Nebenbei: Android hat den Wi-Fi-Direct-Gerätenamen beim Neustart gewechselt
(`Android_CMev` → `Android_u3RH`). Die Paarung hängt also an den Zugangsdaten
der dauerhaften Gruppe, nicht am Namen — was auch heißt, dass der Name keine
Kennung ist, an der man ein Gerät wiedererkennt.

→ **Der Dialog ist wirklich einmalig, je Gerätepaar, für immer.** Die
Oberfläche muss ihn genau einmal erklären: beim Hinzufügen eines Kontakts,
wenn beide ohnehin nebeneinanderstehen.

## Die Entscheidung

Beide Wege sind damit ohne Nutzertipperei benutzbar. Der Entwurf steht auf:

- **Nachrichten über GATT.** Nie ein Dialog, 700 Byte in 202 ms, unter einer
  Sekunde vom Suchbeginn an. `android.bluetooth.*` liegt vollständig in AOSP —
  kein Google Play Services, keine proprietäre Bibliothek. Das ist keine
  Nebensache, sondern Bedingung: BitDM soll über F-Droid verteilbar bleiben.
- **Anhänge über Wi-Fi Direct.** Der einmalige Dialog ist dort zumutbar, und
  er kommt nach dieser Messung wirklich nur ein einziges Mal.
- **40 Leuchtfeuer je Werbung**, auf feste 240 Byte aufgefüllt.

## Was jetzt noch offen ist

- Wer verbindet, wenn sich beide sehen. Vorschlag steht: die kleinere Adresse
  fängt an.
- Der Sockel darunter: **es gibt keine Lizenzdatei im Baum.** Ohne eine
  anerkannte freie Lizenz nimmt F-Droid nichts auf — unabhängig davon, wie
  sauber der Code sonst ist.
