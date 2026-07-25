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
