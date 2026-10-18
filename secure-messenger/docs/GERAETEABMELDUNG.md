# Geraeteabmeldung — Bedrohungsmodell, Entscheidung, Protokoll

Stand 17.10.2026, Zweig `feat/geraeteabmeldung` (ab `feat/libsignal-offiziell`,
2.0.0). Ergaenzt und ersetzt `MEHRGERAETE.md` §6 ("kein Widerruf") und §12.5.

**Entscheidung Henriks vom 17.10.2026: Option B, beide Stufen (Relay UND
Kontakte pruefen), dazu der ehrliche Hinweis. Option C (Identitaetsrotation)
spaeter als eigenes Vorhaben.** §1–§7 sind das Bedrohungsmodell, auf dem die
Wahl beruht; §8 ist der Vertrag zwischen Relay und App.

---

## 1. Ausgangslage — nachgesehen, nicht vermutet

1. **Jedes Geraet haelt die vollen zwoelf Woerter.** Die 16 Byte Entropie
   liegen im Schluesselspeicher (`real_messenger_core.dart:538`, `:593`
   `getRecoveryPhrase`), auf Wunsch hinter der App-Sperre. Wer ein Geraet samt
   Schluesselspeicher hat, hat die Woerter. Kein Geraet besitzt irgendetwas,
   das ein anderes nicht auch besitzt.
2. **Der Relay prueft nur zwei Dinge:** "kann mit dem Identitaetsschluessel
   signieren" und "nennt eine Geraetenummer" (`relay_server.py` `/register`
   ab `:2209`, `/ws` ab `:2850`).
3. **Eine Loeschung am Relay haelt nicht einmal ein unbeaufsichtigtes
   Telefon auf.** Kennt der Relay ein Geraet nicht, schliesst er mit 4401
   (`:2871`). Die App wertet das als `RelayUnbekannt`, vergisst ihre Anmeldung
   (`real_messenger_core.dart:990`) und meldet sich beim naechsten Versuch
   von selbst neu an (`_meldeAnWennNoetig`, `:1034`). Das verlorene Telefon in
   der Schublade waere nach Sekunden wieder da — ohne dass ein Mensch etwas tut.
4. **Der Datenbankschluessel stammt aus der Entropie** (`:604-609`,
   `keys.databaseKey`). Entfernt ein Geraet die Entropie, bleibt sein Verlauf
   verschluesselt liegen und ist nur mit den zwoelf Woertern wieder zu oeffnen.
   Das ist der Hebel fuer "abgemeldet heisst unlesbar", ohne Daten zu
   vernichten.
5. **Ein Relay kann kein Geraet erfinden, das Kontakte annehmen** — Prekeys
   sind mit dem Identitaetsschluessel signiert. Er kann aber Geraete
   verstecken, zeigen und (§12.1) die eigenen signierten Prekeys unter einer
   erfundenen Nummer wiederholen.

## 2. Angreifer

| | Wer | Hat |
|---|---|---|
| **A0** | Telefon verloren, niemand bedient es (Schublade, Finder ohne Entsperrcode) | nichts; die App selbst laeuft aber weiter, wenn keine App-Sperre greift |
| **A1** | Dieb oder Finder mit dem **entsperrten** Telefon, bedient nur die Oberflaeche | ein vollwertiges Geraet der Identitaet, solange es angemeldet bleibt |
| **A2** | Hat die **zwoelf Woerter**: im Einstellungsbildschirm abgelesen, aus dem Schluesselspeicher gezogen, den Zettel gefunden, k Teile von Vertrauenskontakten | alles, was der Besitzer auch hat; kann eigene Clients bauen |
| **A3** | Boeser oder uebernommener **Relay** (als Verstaerker der anderen) | kann Abmeldungen ignorieren, alte Stande wiederholen, Geraete verstecken |

## 3. Ziele

- **Z1** Ein abgemeldetes Geraet bekommt nichts Neues mehr: keine Post von
  Kontakten, keine Spiegel der eigenen Geraete.
- **Z2** Es kommt nicht zurueck: weder durch die eigene Wiederverbindung (A0)
  noch unter derselben oder einer neuen Geraetenummer.
- **Z3** Es spricht nicht mehr als der Besitzer.
- **Z4** Der Besitzer sieht jedes Geraet. Ein Mitleser ist nie still.
- **Z5** Kein neues Druckmittel: wer ein gestohlenes Geraet hat, darf den
  Besitzer, der die Woerter hat, nicht aussperren und seinen Verlauf nicht
  vernichten.
- **Z6** Der Normalfall bleibt ein Schritt: Woerter auf dem neuen Telefon,
  altes Telefon ist raus.

## 4. Die Grenze, die keine Option aufhebt

Wer die zwoelf Woerter hat (A2), ist kryptographisch der Besitzer. Kein
Protokoll, das nur die Woerter kennt, kann die beiden unterscheiden. Moeglich
ist nur:

- dass A2 nicht **still** dazukommt (laute Uebernahme statt Mitlesen), und
- dass der Besitzer sich zurueckholt — worauf A2 dasselbe tun kann.

Die einzige Heilung ist ein neuer Wurzelschluessel, also eine neue Identitaet.
Das muss die App so sagen.

## 5. Optionen

### A — Abmeldung plus Sperrliste am Relay, signiert vom Identitaetsschluessel

Ein Geraet signiert "Geraet d abmelden"; der Relay loescht Zeile und
Warteschlange, setzt (Adresse, d) auf eine Sperrliste und schliesst mit
einem neuen Code (4410). Das abgemeldete Geraet prueft die signierte
Abmeldung selbst und entfernt seine Entropie. Jede neue Geraeteanmeldung
meldet der Relay an die anderen eigenen Geraete.

- A0 ✔, A1 ✔ (die App gehorcht ja).
- A2 ✘: meldet sich unter einer neuen Nummer (2..127) neu an und liest wieder
  mit. Sichtbar wird es nur ueber die Meldung "neues Geraet".
- A3 ✘: kann die Sperrliste ignorieren.
- Aufwand klein.

### B — Geraetezertifikate mit Epoche (Geraeteliste)

- Jedes Geraet erzeugt bei der Einrichtung einen **eigenen Geraeteschluessel**,
  zufaellig, nie aus den Woertern. Er liegt in der verschluesselten Datenbank.
- Die Identitaet fuehrt beim Relay eine **signierte Geraeteliste**: Epoche
  (streng steigend), je Geraet Nummer und oeffentlicher Geraeteschluessel,
  dazu ein Name, der mit einem Schluessel aus den Woertern verschluesselt ist
  (der Relay sieht ihn nicht).
- Jede Aenderung traegt **zwei Unterschriften**: Identitaetsschluessel UND
  Geraeteschluessel eines Geraets, das in der bisherigen Liste steht.
- Der Relay laesst `/register` und `/ws` nur fuer Geraete der aktuellen Liste
  zu, mit einer zweiten Signatur des Geraeteschluessels ueber dieselbe
  Challenge.
- **Abmelden:** ein Geraet der Liste veroeffentlicht Epoche+1 ohne das Geraet.
  Der Relay loescht Zeile und Warteschlange und trennt mit 4410; Kontakte
  bekommen "Zielgeraet unbekannt" und verwerfen die Sitzung.
- **Ein weiteres Geraet:** Woerter eingeben, dann bestaetigt ein Geraet der
  Liste den Beitritt (Vergleichscode auf beiden Bildschirmen). Die Woerter
  allein reichen nicht mehr fuer einen STILLEN Beitritt.
- **Telefon verloren, kein anderes Geraet:** Woerter eingeben, "alle anderen
  Geraete abmelden". Dafuer genuegt der Identitaetsschluessel, die neue Liste
  enthaelt nur dieses Geraet. Das ist laut: jedes andere Geraet erfaehrt es
  sofort.
- **Das abgemeldete Geraet glaubt nicht dem Relay**, sondern prueft die
  signierte Liste selbst. Erst dann entfernt es die Entropie; der Verlauf
  bleibt verschluesselt liegen und geht mit den Woertern wieder auf. Ein Relay
  kann so niemanden aussperren, und ein Dieb, der das Zweitgeraet des
  Besitzers abmeldet, vernichtet nichts (Z5): der Besitzer gibt dort die
  Woerter ein und setzt zurueck.
- **Stufe 2 — Kontakte pruefen selbst:** sie holen die Liste mit dem Buendel,
  pruefen beide Signaturen und die Epoche (kein Rueckschritt) und
  verschluesseln nur an gelistete Geraete. Das haelt gegen einen Relay, der
  eine Liste faelscht oder zurueckdreht, und schliesst `MEHRGERAETE.md` §12.1
  (Reflexion) strukturell: auch die eigenen Spiegel gehen nur noch an
  gelistete Geraete. **Gegen einen Relay, der eine neue Fassung verschweigt,
  hielt es in 2.0.0 nicht** — siehe §12.

Wirkung:

- A0 ✔, A1 ✔ (A1 kann zwar das Zweitgeraet des Besitzers abmelden, der
  Besitzer setzt mit den Woertern zurueck, A1 hat danach nichts mehr).
- A2 ◐: kann **nicht still** dazukommen. Sein einziger Zug ist das
  Zuruecksetzen, und das wirft den Besitzer sichtbar hinaus. Danach
  Ping-Pong, Heilung nur ueber eine neue Identitaet (§4).
- A3 ◐ mit Stufe 2: Faelschen und Zurueckdrehen ✔, Verschweigen erst mit
  §12 (Listenstempel Ende-zu-Ende, Sitzungen an den Geraeteschluessel
  gebunden).
- Aufwand gross: Relay (Liste, zweite Signatur, Beitritt, Zuruecksetzen),
  App (Geraeteschluessel, Liste, Beitritts- und Abmeldeoberflaeche,
  Pruefung bei Kontakten), Tests auf beiden Seiten.

### C — Identitaetsrotation mit Uebergabe an die Kontakte

Neue Woerter, neue Adresse; die alte Identitaet schickt allen Kontakten
"ich bin jetzt X", signiert mit dem alten Schluessel.

- Die einzige echte Heilung gegen A2 — aber die Uebergabe ist mit genau dem
  Schluessel signiert, den A2 auch hat. A2 kann eine Gegen-Uebergabe auf seine
  eigene Adresse schicken. Ohne Abgleich ausserhalb der App (QR, Pruefnummer)
  ist die Uebergabe selbst angreifbar.
- Fuer A0/A1 voellig ueberzogen: alle Kontakte muessten neu pruefen, weil ein
  Telefon in der Schublade liegt.
- Aufwand sehr gross (Kontakte, Gruppen, Vertrauensmerker, Nahbereich).

### D — Kombination

Abmeldung fuer den Normalfall (A oder B) und der ehrliche Satz "Woerter in
fremder Hand → neue Identitaet", C spaeter als eigenes Vorhaben.

## 6. Ueberblick

| | A0 Schublade | A1 entsperrt | A2 Woerter | A3 Relay | Aufwand |
|---|---|---|---|---|---|
| A Sperrliste | ✔ | ✔ | ✘ still zurueck | ✘ | klein |
| B Geraeteliste | ✔ | ✔ | ◐ nur laut | ◐ Stufe 2, ✔ mit §12 | gross |
| C Rotation | – | – | ✔ wenn ausserhalb abgeglichen | ✔ | sehr gross |
| D = B + Hinweis, C spaeter | ✔ | ✔ | ◐ + ehrlicher Weg | ◐, ✔ mit §12 | gross |

## 7. Empfehlung

**D auf Grundlage von B, beide Stufen, auf diesem Zweig.** Begruendung:

- A loest das Problem des Kritikers nur fuer Telefone, die niemand bedient.
  Gegen jeden, der die Woerter hat, bleibt der stille Mitleser — genau der
  Satz aus `MEHRGERAETE.md` §6 ("ohne dass irgendwo etwas auffaellt").
- B ist das Staerkste, was ohne neuen Wurzelschluessel geht: aus dem stillen
  Mitleser wird eine laute Uebernahme, ein Relay kann Abmeldungen weder
  faelschen noch zuruecknehmen, und §12.1 ist nebenbei zu.
- C ersetzt B nicht, sondern ergaenzt es fuer den Fall A2. Es ist ein eigenes
  Vorhaben und braucht B ohnehin (die neue Identitaet braucht wieder eine
  Geraeteliste).

**Preis, der genannt werden muss:** Ein zweites Geraet koppeln heisst kuenftig
"Woerter eingeben UND auf einem anderen Geraet bestaetigen". Wer kein anderes
Geraet mehr hat, setzt zurueck. `MEHRGERAETE.md` §0 ("der Besitz der zwoelf
Woerter IST die Kopplung") gilt dann nicht mehr — gewollt.

**Umstellung:** 2.0.0 ist ohnehin ein harter Schnitt (alle Sitzungen werden
neu gebaut, Kyber). Das erste 2.x-Geraet einer Adresse legt Epoche 1 mit sich
allein an; jedes weitere bestehende Geraet wird einmal bestaetigt. Adressen
ohne Liste laufen am Relay wie heute.

---

## 8. Protokoll (Vertrag zwischen Relay und App)

### 8.1 Geraeteschluessel

Jede Installation erzeugt beim ersten Bedarf einen eigenen Curve25519-Schluessel
(`PrivateKey.generate()` aus libsignal), **nie aus den Woertern**. Er liegt in
der verschluesselten Datenbank (`meta` `geraeteschluessel`). Signiert wird mit
XEdDSA wie beim Identitaetsschluessel; der Relay prueft mit derselben
`verify_signature`. Auf der Leitung steht der oeffentliche Teil als **32 rohe
Byte** (ohne Typbyte 0x05), base64.

Drei feste Praefixe trennen die Verwendungen, damit keine Signatur in einem
anderen Zusammenhang gilt:

| Praefix (ASCII, mit `\n`) | signiert |
|---|---|
| `BitDM-Geraeteliste-v1\n` | eine Geraeteliste (Identitaets- UND Geraeteschluessel) |
| `BitDM-Beitritt-v1\n` | eine Beitrittsanfrage (beide) |
| `BitDM-Geraet-Anmeldung-v1\n` | die Anmeldung bei `/register` und `/ws` (nur Geraeteschluessel) |

### 8.2 Die Geraeteliste

Kanonisches JSON, Schluessel sortiert, ohne Leerraum, nur ASCII — Python
`json.dumps(x, sort_keys=True, separators=(",", ":"))`, in Dart dieselbe
Reihenfolge per Einfuegereihenfolge:

```
{"adresse":"<56>","epoche":3,"geraete":[[1,"<GS b64>","<Info b64>"],[37,"…","…"]],"unterzeichner":37,"v":1,"zeit":1760700000}
```

| Feld | Regel |
|---|---|
| `adresse` | die 56-Zeichen-Adresse in Normalform |
| `epoche` | Ganzzahl `1 <= e <= 2^53`, je Aenderung **genau +1** |
| `geraete` | 1 bis `GERAETE_MAX` Eintraege `[device_id, schluessel, info]`, nach `device_id` streng aufsteigend; `device_id` 1..127; `schluessel` 32 Byte; kein Schluessel doppelt |
| `info` | base64 von `nonce(12) ‖ AES-256-GCM(json {"n": Name, "s": seit})`, Schluessel `HKDF(seed, "bitdm device info v1")`. Der Relay sieht nur Rauschen; jedes eigene Geraet liest es. Hoechstens 512 Zeichen, darf leer sein. |
| `unterzeichner` | `device_id` des Geraets, das diese Fassung signiert hat. Steht in `geraete` — ausser ein Mitglied meldet sich selbst ab, dann stand es in der vorigen Fassung |
| `zeit` | Uhr des Unterzeichners, Sekunden. Nur zur Anzeige, nie fuer Entscheidungen |

Unterschrieben wird `PRAEFIX ‖ liste` zweimal: mit dem Identitaetsschluessel
(`sig_identitaet`) und mit dem Geraeteschluessel des Unterzeichners
(`sig_geraet`). Uebertragen wird die Liste **als Zeichenkette**, genau die
signierten Bytes; der Relay prueft, dass sie kanonisch ist.

### 8.3 Wer welche Fassung setzen darf (Relay)

Gegeben die gespeicherte Fassung `alt` (oder keine) und die eingereichte `neu`:

1. `sig_identitaet` muss gegen die Adresse aufgehen. Sonst 403.
2. **Keine Liste da:** nur `epoche = 1` und `neu.geraete == [unterzeichner]`
   (Anlage). `sig_geraet` gegen dessen eigenen Schluessel.
3. **Liste da:** `neu.epoche == alt.epoche + 1`, sonst 409.
   - Steht der Unterzeichner in `alt` und in `neu` **mit demselben
     Schluessel** (oder fehlt er in `neu`, weil er sich selbst abmeldet):
     Aenderung durch ein Mitglied, `sig_geraet` gegen seinen Schluessel aus
     `alt`.
     Jede Aenderung erlaubt (hinzufuegen, abmelden, sich selbst abmelden),
     solange mindestens ein Geraet bleibt.
   - Sonst: **Zuruecksetzen**. Nur erlaubt, wenn `neu.geraete ==
     [unterzeichner]`; `sig_geraet` gegen den neuen Schluessel. Dafuer genuegt
     also der Identitaetsschluessel — das ist der Weg "Telefon verloren, kein
     anderes Geraet", und er ist laut.
4. Danach: Jedes Geraet, das in `alt` stand (oder eine Zeile hatte) und in
   `neu` fehlt oder dort einen anderen Schluessel hat, wird geloescht (Zeile,
   Warteschlange, Prekeys) und, falls verbunden, mit
   `{"type":"abgemeldet","epoche":n}` und Code **4410** getrennt. Die
   verbleibenden verbundenen Geraete bekommen `{"type":"geraeteliste","epoche":n}`.
   Erledigte Beitrittsanfragen fallen weg.

### 8.4 Durchsetzung bei der Anmeldung

Hat die Adresse eine Liste:

- `/register` verlangt, dass `(Adresse, device_id)` in der Liste steht (sonst
  403 "Geraet nicht in der Geraeteliste"), und ein neues Feld
  `geraete_signatur`: Geraeteschluessel ueber `ANMELDE-PRAEFIX ‖ nonce ‖
  sha256(canonical_bytes)` (sonst 403).
- `/ws` schliesst ein Geraet, das nicht in der Liste steht, **vor** der
  Challenge mit `{"type":"abgemeldet"}` und 4410 (nicht 4401 — sonst meldete
  sich die App von selbst neu an). Die Antwort auf die Challenge braucht
  zusaetzlich `geraete_signatur` ueber `ANMELDE-PRAEFIX ‖ signierte Bytes`
  (sonst 4403).

Adressen ohne Liste laufen wie bisher. `canonical_bytes` bleibt unveraendert.

### 8.5 Beitritt

**Auf dem vorhandenen Geraet** ("Geraet hinzufuegen") erzeugt die App einen
**Beitrittscode**: 10 Zufallsbyte, als 16 Zeichen Base32 in vier Gruppen
angezeigt (`ABCD-EFGH-IJKL-MNOP`). Er verlaesst dieses
Geraet nie — auch der Relay sieht ihn nicht — und gilt 10 Minuten fuer genau
einen Beitritt.

**Das neue Geraet** (Woerter eingegeben, steht nicht in der Liste) bekommt den
Code eingetippt oder gescannt und schickt `POST /geraeteliste/beitritt` mit

```
{"adresse":"…","device_id":37,"info":"…","nachweis":"<b64 32>","schluessel":"<GS b64>","v":1,"zeit":…}
```

`nachweis = HMAC-SHA256(Code, "BitDM-Beitritt-Nachweis-v1
" ‖ adresse ‖ "
" ‖ device_id ‖ "
" ‖ schluessel)`.
Unterschrieben mit beiden Schluesseln (Beitritts-Praefix): der
Identitaetsschluessel belegt den Besitz der Woerter (sonst koennte jeder fremde
Adressen mit Anfragen fluten), der Geraeteschluessel den Besitz des neuen
Schluessels. Der Relay prueft beide Signaturen und die Form des Nachweises,
haelt hoechstens 3 Anfragen je Adresse fuer 10 Minuten und meldet verbundenen
Mitgliedern `{"type":"beitritt"}`.

**Das vorhandene Geraet** holt die Anfragen (`GET /geraeteliste/<adresse>/beitritte`),
prueft beide Signaturen selbst und laesst **nur** die Anfrage zu, deren
Nachweis zu seinem Code passt — indem es eine neue Fassung mit dem Eintrag
veroeffentlicht. Danach ist der Code verbraucht.

**Warum kein Vergleichscode** (erster Entwurf): Anfragen sind oeffentlich, und
ein sechsstelliger Code aus der Anfrage selbst laesst sich mit den Woertern in
Sekunden fuer eine eigene Anfrage nachrechnen. Wer dann die echte Anfrage
verdraengt (hoechstens 3 je Adresse), bekaeme sein Geraet vom Besitzer selbst
bestaetigt — genau der stille Mitleser, den B verhindern soll. Ein Code, der
nie das bestaetigende Geraet verlaesst, hat dieses Problem nicht: ohne ihn
gibt es keinen passenden Nachweis, und 80 Bit lassen sich nicht durchprobieren.

### 8.6 Abruf

- `GET /geraeteliste/<adresse>` → `{"liste","sig_identitaet","sig_geraet"}` oder 404.
- `GET /prekey/<adresse>` und `?nur_geraete=1` tragen dieselben drei Felder
  unter `geraeteliste`, wenn es eine gibt. Damit bekommen Kontakte jede neue
  Fassung mit der Auffrischung, die sie ohnehin machen.

### 8.7 Die App

- **Eigene Liste nach jedem Verbinden**, vor der Anmeldung: pruefen (beide
  Signaturen, kanonisch, Adresse), nie hinter eine schon gesehene Epoche
  zurueck.
  - Keine Liste: Fassung 1 mit sich allein anlegen.
  - Selbst drin (Kennung UND Geraeteschluessel): weiter wie bisher, Merker
    `geraeteliste_mitglied = epoche`.
  - Nicht drin, Merker gesetzt, Epoche hoeher: **abgemeldet** (unten).
  - Nicht drin, kein Merker: **Beitritt noetig** — die Oberflaeche bietet
    "auf einem anderen Geraet bestaetigen" und "alle anderen Geraete abmelden".
- **Abgemeldet** heisst nur nach einer GEPRUEFTEN Liste ohne dieses Geraet,
  nie auf ein 4410 allein. Dann: Sitzungen, Geraeteschluessel, Geraetekennung
  und Anmeldevermerke aus der Datenbank, danach die Entropie aus dem
  Schluesselspeicher. Die Datenbank bleibt verschluesselt liegen; mit den
  zwoelf Woertern geht sie samt Verlauf wieder auf, und das Geraet tritt
  danach mit neuer Kennung und neuem Schluessel bei.
- **Kontakte (Stufe 2):** die Liste kommt mit `/prekey` und wird geprueft und
  je Adresse gespeichert (nie zurueck hinter eine gesehene Epoche). Gibt es
  eine, wird nur an gelistete Geraete verschluesselt, Sitzungen zu anderen
  werden verworfen, und Post von einem nicht gelisteten Geraet wird nach
  einer Auffrischung ohne Entschluesseln verworfen. Das gilt auch fuer die
  eigene Adresse: Spiegel gehen nur an gelistete eigene Geraete und werden nur
  von solchen angenommen — damit ist `MEHRGERAETE.md` §12.1 strukturell zu.
  Ohne Liste (Gegenstelle mit alter App) bleibt es beim bisherigen Verhalten.
- **Kosten:** Nachgeladen wird die Liste einer Gegenstelle bei der
  Auffrischung, die es ohnehin gibt (6 Stunden), und wenn Post von einem
  Geraet kommt, das nicht in ihrer Liste steht (hoechstens einmal je Minute,
  bei Gegenstellen ohne Liste alle 6 Stunden). Bei einem **Fremden**, der zum
  ersten Mal schreibt, fragt die App nicht nach — dort gibt es nichts zu
  schuetzen. Die Pruefung vor dem Entschluesseln entscheidet im Normalfall
  ohne Wartestelle; gewartet wird nur, wenn wirklich nachgeladen wird.
- **Relay-Bremsen:** `POST /geraeteliste` hat eine eigene Familie (`liste`,
  2 Marken), `POST /geraeteliste/beitritt` ebenfalls (`beitritt`, 5). In der
  Familie der Anmeldung (`reg`) verdoppelte die Anlage der Liste die Kosten
  jeder Erstanmeldung — gemessen an den Ende-zu-Ende-Tests, die danach in
  429 liefen.

### 8.8 Die Oberflaeche

- **Einstellungen › Meine ID:** die Zahl der Geraete wie bisher. Mit Liste
  dazu "Geraete verwalten": jedes Geraet mit Name (verschluesselt in der
  Liste) und Einrichtungsdatum, "Abmelden" je anderem Geraet, "Alle anderen
  abmelden", "Dieses Geraet abmelden", "Geraet hinzufuegen" (zeigt den Code)
  und immer sichtbar der ehrliche Satz aus §4. Ohne Liste (alter Relay) bleibt
  der alte Satz stehen, dass Abmelden nicht geht — er stimmt dort weiterhin.
- **Chatliste, wenn dieses Geraet nicht in der Liste steht:** eine Karte mit
  Codefeld und "Kein anderes Geraet mehr? — Alle anderen Geraete abmelden"
  (mit Rueckfrage, die sagt, dass das jeder mit den Woertern kann). Die
  Verbindungszeile sagt "Geraet nicht bestaetigt" statt "keine Verbindung".
- **Startbildschirm nach einer Abmeldung:** "Dieses Geraet wurde abgemeldet …
  mit deinen 12 Woertern holst du sie zurueck — ein anderes Geraet muss das
  dann bestaetigen." Nur im laufenden Prozess; nach einem Neustart weiss das
  Geraet davon nichts mehr (die Woerter und damit die Datenbank sind zu).

Code: `lib/core/net/geraeteliste.dart` (Protokoll), `lib/core/geraeteverwaltung.dart`
(Kern, `part of real_messenger_core.dart`), `lib/geraete_seite.dart`
(Oberflaeche), drei kleine Einhaengungen in `lib/main.dart`.

---

## 9. Belege

**Relay** (`server/test_relay.py`, Abschnitt "Geraeteabmeldung", 17 Faelle):
Anlage nur mit sich allein; mit Liste reicht der Identitaetsschluessel nicht
mehr (`/register` und `/ws`); Abmelden raeumt Zeile, Warteschlange und Prekeys
ab und trennt mit 4410; **das abgemeldete Geraet kommt auf keinem Weg zurueck**
(Wiederverbindung, alte Kennung, neue Kennung, eigene Liste, Beitrittsanfrage)
— nur das laute Zuruecksetzen bleibt; Beitritt nur mit Bestaetigung; Epoche
genau +1; kanonische Schreibweise; Selbstabmeldung; die Luecke zwischen
Vorraum und `connections`.

**App gegen den echten Relay** (`app/test/net/geraeteabmeldung_test.dart`):
(1) dieselben Woerter allein reichen nicht, ein falscher Code auch nicht;
(2+3) Abmeldung: Woerter weg, Datenbank bleibt, Annas Post nur noch ans
Telefon, nichts liegt beim Relay; Neustart ohne Identitaet; wer die Woerter
wieder eingibt, bekommt den Verlauf, aber keine neue Nachricht; (2b) abgemeldet,
waehrend es aus war — es merkt es beim naechsten Verbinden; (4) Zuruecksetzen.

**Oberflaeche** (`app/test/oberflaeche/geraete_seite_test.dart`, echter Kern
mit Attrappe): die Beitrittskarte weist einen falschen Code ab, die Rueckfrage
beim Zuruecksetzen sagt, dass das jeder mit den Woertern kann, und danach steht
nur dieses Geraet in der Liste; die Geraeteliste zeigt "dieses Geraet" und den
ehrlichen Satz, bei einem einzigen Geraet keine Abmeldeknoepfe, und
"Geraet hinzufuegen" zeigt einen gueltigen Code, der mit dem Schliessen
verfaellt.

**Bestehende Tests, angepasst:** `zwei_geraete_test.dart` koppelt das Tablet
jetzt per Code (`test/support/geraete_koppeln.dart`); der Fall "altes Tablet
ohne Kyber" belegt zusaetzlich, dass eine alte App bei einer Adresse mit Liste
nicht mehr hereinkommt. `sicherung_test.dart` ("Telefon weg, wiederherstellen")
setzt auf dem neuen Telefon zurueck, wie es ein Mensch dort tun muss.

**App, Stufe 2** (`app/test/net/geraeteliste_stufe2_test.dart`, gegen eine
Attrappe, die luegt): kein Spiegel an ein eigenes Geraet ausserhalb der Liste,
auch mit echtem, von uns signiertem Prekey; nichts an ein Geraet ausserhalb der
Liste einer Gegenstelle — bei der ersten Nachricht, bei alten Sitzungen, nach
einer Abmeldung, nach einem Wiedereinspielen einer alten Fassung; ein neuer
Schluessel unter alter Kennung verwirft die alte Sitzung; Post von einem nicht
gelisteten Geraet wird nicht entschluesselt; ein alter Relay ohne Listen aendert
nichts.

**Beide Sprachen** (`app/test/net/geraeteliste_test.dart` mit
`geraeteliste_fixtures.json` aus `server/tools/write_geraeteliste_fixtures.py`):
Dart schreibt die Liste Zeichen fuer Zeichen wie Python, libsignal nimmt die
Signaturen des Relays an, jede Veraenderung faellt auf.

**Mutationsproben** (je Riegel einzeln ausgeschaltet, Rueckbau per SHA-256
geprueft): 12 im Relay, 10 in der App — alle werden rot. Drei App-Riegel waren
zuerst durch eine andere Schicht verdeckt (Listenfilter beim Versand, beim
Sitzungsaufbau, Abmeldung beim Verbinden); die Faelle, die sie einzeln zeigen,
sind seither dabei.

## 10. Grenzen und Offenes

- **Wer die Woerter hat, kann zuruecksetzen** (§4). Das ist laut, aber nicht
  zu verhindern. Heilung: neue Identitaet — Option C, eigenes Vorhaben.
- **Ein gestohlenes, entsperrtes Mitglied** kann bis zu seiner Abmeldung selbst
  abmelden und hinzufuegen (es ist ein Mitglied). Der Besitzer setzt mit den
  Woertern zurueck; danach hat das Geraet nichts mehr.
- **QR-Code zum Scannen** des Beitrittscodes: der vorhandene Leser haengt
  privat in `main.dart` am Kontakt-Hinzufuegen. Nach der Aufteilung von
  `main.dart` nachruesten.
- **Umbenennen von Geraeten** und **"zuletzt gesehen"** in der Liste: nicht
  gebaut. Der Name ist die Plattform ("Android", "Windows" …) plus Datum.
- **Relay verliert seine Datenbank:** das erste Geraet legt neu an (Epoche 1);
  die anderen sehen eine aeltere Epoche, als sie kennen, und behandeln sie als
  Rueckschritt — sie muessen neu beitreten. Selten, aber dann laestig.
- **Kennung eines abgemeldeten Geraets** kann ein spaeteres Geraet zufaellig
  wieder bekommen (1 zu ~120). Gegenstellen verwerfen die alte Sitzung, sobald
  sie die neue Fassung sehen (Schluessel geaendert); bis dahin kann eine
  Nachricht an das neue Geraet scheitern und wird nachgesendet.
- **Umstellung:** 2.0.0 ist ein harter Schnitt. Das erste aktualisierte Geraet
  einer Adresse legt die Liste an; jedes weitere tritt einmal per Code bei.
  Geraete mit alter App fallen bei der Anlage heraus (sie koennten mit 2.0.0
  ohnehin nicht mehr reden).
- **Der Relay muss zuerst** ausgerollt werden. Gegen einen alten Relay laeuft
  die App ohne Liste weiter wie bisher — ohne Abmeldung.

## 11. Vorschlag fuer die FAQ der Webseite

Nicht eingebaut: die Webseite darf sich erst mit der Fassung aendern, die das
hier ausliefert (siehe die Sperre fuer `fix/audit-2026-10-16` und alles darauf).

**DE — Was passiert, wenn mein Telefon weg ist?**

> Mit deinen zwölf Wörtern holst du deine Identität auf einem neuen Gerät
> zurück. Hast du noch ein anderes Gerät, meldest du das verlorene dort unter
> „Geräte verwalten“ ab. Hast du keins mehr, wählst du auf dem neuen
> „Alle anderen Geräte abmelden“. Das alte Telefon bekommt ab da keine
> Nachricht mehr, kann sich nicht wieder anmelden und vergisst deine Wörter,
> sobald es online geht. Seine Unterhaltungen bleiben darauf verschlüsselt.
> Eine Grenze bleibt: Wer deine zwölf Wörter kennt, kann dasselbe tun und dich
> abmelden. War das Telefon entsperrt oder liegen die Wörter nicht sicher,
> leg danach eine neue Identität an.

**EN — What happens if I lose my phone?**

> Your twelve words bring your identity back on a new device. If you still
> have another device, sign the lost one out there under “Manage devices”. If
> you have none left, choose “Sign out all other devices” on the new one. From
> then on the old phone gets no messages, cannot sign back in, and forgets
> your words as soon as it goes online. Its chats stay encrypted on it. One
> limit remains: anyone who knows your twelve words can do the same and sign
> you out. If the phone was unlocked or the words are not safe, create a new
> identity afterwards.

Dazu im JSON-LD-Block oben (`"name": "What happens if I lose my phone?"`)
derselbe englische Text.

---

## 12. Relay verschweigt eine Abmeldung (Befund 18.10.2026)

Entwurf, Stand 18.10.2026, Zweig `fix/geraeteliste-verschwiegen` ab `main`
(2.0.0). Zuerst zur Abstimmung; gebaut wird erst nach Henriks Ja.

### 12.1 Befund

Kontakte bekommen die signierte Liste nur ueber den Relay (`/prekey`,
`/geraeteliste`). `_nimmListe` weist nur eine AELTERE Fassung ab. Dass eine
neuere FEHLT, merkt die App nicht. Ein boeser Relay nimmt Epoche 3 (Tablet
abgemeldet) an, liefert allen weiter Epoche 2 und trennt das Tablet nicht. Die
Kontakte verschluesseln weiter ans Tablet, das Tablet schreibt weiter als
Besitzer, und der Besitzer sieht es als abgemeldet. §5 B ("A3 ✔ mit Stufe 2")
war zu stark, ebenso der Kommentar in `_frischeGeraeteAuf`.

Beim Nachsehen kamen drei Wege dazu, auf denen das abgemeldete Geraet mit Hilfe
des Relays mitliest, **obwohl der Kontakt die neue Liste schon kennt**:

- **(a) Buendel unter fremder Kennung.** Prekey-Buendel sind nur vom
  Identitaetsschluessel signiert, und den hat das Tablet auch. Der Relay
  liefert das Buendel des Tablets unter der Kennung des Laptops aus. Der
  Kontakt baut eine Sitzung "zum Laptop", die nur das Tablet entschluesseln
  kann (`prekey_bundle_bridge.dart` prueft nur die Adresse).
- **(b) Erstnachricht unter fremder Kennung.** `from_device` setzt der Relay
  (`relay_client.dart`, Rahmen `message`). Eine Erstnachricht des Tablets mit
  der Kennung des Laptops baut beim Kontakt eine neue Sitzung "Laptop" auf und
  verdraengt die echte. Alle Antworten an den Laptop liest danach das Tablet.
- **(c) "Zielgeraet unbekannt" loescht die Sitzung** (`_sendePayload`). Damit
  erzwingt der Relay einen Neuaufbau, und der laeuft ueber (a).

### 12.2 Ziel

1. Was der Relay verschweigt, erfahren Kontakte und eigene Geraete
   Ende-zu-Ende vom Besitzer.
2. Solange sie es nicht haben, wissen sie, DASS ihnen etwas fehlt. Dann
   schicken sie nichts an Geraete, die die neue Fassung nicht nachweislich
   kennen, und nehmen von solchen nichts an.
3. Eine Sitzung gehoert nachweislich zu dem Geraeteschluessel, unter dessen
   Kennung sie laeuft. `from_device` und die Buendel des Relays sind dann
   geprueft und keine Behauptung mehr.

### 12.3 Teil 1: Listenstempel und Verteilung Ende-zu-Ende (nur App)

**Stempel.** Jede Nutzlast (`payload.dart`) traegt drei freiwillige Felder.
Aeltere Fassungen ueberlesen sie:

| Feld | Inhalt |
|---|---|
| `le` | Epoche der eigenen Liste (nur, wenn dieses Geraet Mitglied ist) |
| `lh` | die ersten 12 Byte von SHA-256 ueber die signierten Zeichen (`liste`), base64 |
| `ke` | die Epoche der Liste des EMPFAENGERS, die der Absender kennt (0: keine) |

Kosten: rund 40 Byte je Nutzlast. Statt bis etwa 180 Zeichen passt eine
Nachricht dann bis etwa 140 Zeichen in einen 256er-Block.

**Neue Art `geraeteliste` (20).** In `x` steht die signierte Liste
(`{"liste","sig_identitaet","sig_geraet"}`). Sie traegt ihre Beweise selbst
(beide Signaturen, Kette), deshalb ist egal, wer sie ueberbringt. Sie wird
nicht gespiegelt und erscheint nie im Verlauf. 2.0.0 verwirft unbekannte Arten
still.

**Regeln:**

1. **Verteilen.** Wer eine Fassung veroeffentlicht (anlegen, hinzufuegen,
   abmelden, zuruecksetzen), schickt sie ueber den Ausgang an alle aktiven
   Kontakte und Gruppenmitglieder und an die eigenen Geraete der neuen Liste.
   Einmal geht sie auch an jedes gerade abgemeldete Geraet, solange dessen
   Sitzung noch steht. Es prueft sie und entfernt die Woerter, auch wenn der
   Relay es nie trennt.
2. **Ankuendigung merken.** Nennt ein Stempel von Adresse X eine hoehere
   Epoche, als wir kennen, merkt sich die App das in `meta`: Epoche, Hash und
   welche Geraete von X sie genannt haben. Dann laedt sie die Liste beim Relay
   nach.
3. **Veraltet.** Als veraltet gilt die bekannte Liste von X, solange sie hinter
   der Ankuendigung liegt: kleinere Epoche, oder gleiche Epoche mit anderem
   Hash. Dann gilt:
   - Versand an X geht nur an Geraete, die die Ankuendigung selbst gestempelt
     haben. Hat keines davon eine Sitzung, bleibt die Nachricht liegen.
   - Post von X, deren Stempel hinter der Ankuendigung liegt oder fehlt, wird
     nach dem Entschluesseln verworfen (quittiert, nicht angezeigt). Die Art 20
     ist ausgenommen.
4. **Heilen.** Schreibt ein Kontakt mit `ke` unter unserer Epoche, schickt der
   Besitzer ihm die Liste nach, hoechstens einmal je 10 Minuten und Adresse.
   Dasselbe gilt fuer ein eigenes Geraet mit kleinerem `le`. Eine verschluckte
   Verteilung holt so die naechste Nachricht des Kontakts nach.
5. **Widerspruch.** Zwei verschiedene Fassungen derselben Epoche (aus Stempel
   oder Liste) kann ein ehrlicher Relay nicht erzeugen, er nimmt nur genau +1
   an. Die App merkt sich das je Adresse und zeigt im Chat den Hinweis
   "Geraeteliste widerspruechlich, Sicherheitsnummer vergleichen". Es bleibt
   bei der zuerst gesehenen Fassung, versandt wird nach Regel 3.

### 12.4 Teil 2: Der Besitzer prueft, was der Relay ausliefert (nur App)

Nach jedem Veroeffentlichen und bei jedem Verbinden vergleicht die App die
eigene Liste, die der Relay liefert, mit der, die sie selbst kennt. Ist die
gelieferte aelter oder anders, zeigt "Geraete verwalten" eine Warnung: "Der
Server liefert deine letzte Aenderung der Geraeteliste nicht aus. Deine
Kontakte erfahren sie ueber deine Nachrichten."

Grenze: Ein Relay, der gezielt luegt, zeigt dem Besitzer die Wahrheit. Dagegen
hilft Teil 1, nicht Teil 2.

### 12.5 Teil 3: Sitzungen an den Geraeteschluessel binden (Relay und App)

**(a) Buendel.** Die App signiert ihren signierten Prekey zusaetzlich mit dem
Geraeteschluessel:

```
spk_geraete_sig = Sig(GS, "BitDM-Prekey-v1\n" ‖ adresse ‖ "\n" ‖ device_id ‖ "\n"
                          ‖ signed_prekey_id ‖ "\n" ‖ base64(signed_prekey))
```

Der Relay prueft sie bei `/register` gegen die Liste (falsch: 403). Er
speichert sie in einer neuen Spalte und gibt sie in `/prekey` je Geraet mit
aus. Der Absender prueft sie beim Sitzungsaufbau gegen den Schluessel aus der
Liste. Das genuegt: Ohne den privaten Teil des signierten Prekeys des Laptops
kann das Tablet die Sitzung nicht ausrechnen, auch nicht mit dem
Identitaetsschluessel (DH1 und DH3 in X3DH).

**(b) Erstnachricht.** Solange libsignal fuer eine Sitzung noch
PreKey-Nachrichten schickt (im Sitzungsdatensatz steht `pending_pre_key`),
traegt die Nutzlast an genau dieses Geraet zusaetzlich:

```
gs = Sig(GS, "BitDM-Sitzung-v1\n" ‖ absender ‖ "\n" ‖ absendergeraet ‖ "\n"
             ‖ empfaenger ‖ "\n" ‖ empfaengergeraet ‖ "\n" ‖ base64(basisschluessel))
```

Der Empfaenger prueft `gs` gegen den Listenschluessel der Kennung, unter der
die Nachricht ankommt, und gegen den Basisschluessel der PreKey-Nachricht.
Passt sie nicht, verwirft er die neue Sitzung (Schnappschuss zurueck, wie bei
einer wiederholten Kyber-Erstnachricht) und zeigt nichts an. Damit ist
`from_device` geprueft: eine Nachricht unter fremder Kennung entschluesselt
entweder nicht, oder sie hat den falschen Nachweis.

**(c) "Zielgeraet unbekannt"** loescht die Sitzung nicht mehr, wenn das Geraet
in der signierten Liste steht. Die App laedt die Liste nach. Fehlt das Geraet
dort, faellt die Sitzung ueber `_nimmListe` wie bisher. Steht es noch drin,
bleibt die Sitzung, und das Geraet wird bis zur naechsten Auffrischung
(hoechstens 6 Stunden) uebersprungen, damit die Nachricht nicht ewig liegt.
Ohne Liste (alter Relay) bleibt es beim Loeschen. (c) ist reine App und
schliesst schon vor (a) den einfachsten Weg in (a).

**Uebergang.** Fassungen vor diesem Teil signieren nichts. Pflicht wird die
Pruefung erst, wenn keine solche Fassung mehr erwartet wird. Bis dahin gilt:
eine FALSCHE Signatur wird nie angenommen, eine FEHLENDE schon. Bei (b) hilft
das sofort, denn `gs` steht im verschluesselten Inhalt, und der Relay kann ihn
nicht entfernen. Ein abgemeldetes Geraet mit unveraenderter App nennt darin
seine eigene Kennung. Bei (a) hilft es erst mit der Pflicht, vorher kann der
Relay die Signatur einfach weglassen.

### 12.6 Was bleibt

- **Das Fenster bis zur ersten Nachricht.** Hat ein Kontakt seit der Abmeldung
  nichts vom Besitzer bekommen, weder die Verteilung noch eine gestempelte
  Nachricht, kann er nicht wissen, dass ihm etwas fehlt. Was er bis dahin an
  X schickt, bekommt auch das Tablet. Ein Relay kann die Verteilung an
  Zeitpunkt und Groesse erkennen und gezielt verwerfen. Die naechste
  gewoehnliche Nachricht des Besitzers kann er von anderen nicht
  unterscheiden.
- **Vollstaendiges Abschneiden.** Verwirft der Relay ALLES vom Besitzer an
  einen Kontakt, bleibt der Kontakt auf dem alten Stand. Sichtbar wird das
  beim Besitzer: seine Nachrichten an diesen Kontakt bekommen keinen zweiten
  Haken. Ohne einen Weg am Relay vorbei (Nahbereich, Treffen) ist das nicht zu
  schliessen.
- **Erster Kontakt.** Sieht ein Kontakt eine Adresse zum ersten Mal, kann der
  Relay die Liste weglassen. Dann gilt der Altmodus, bis der erste Stempel
  kommt.
- **Wer die zwoelf Woerter hat** (A2), kann Stempel und Listen erzeugen wie
  der Besitzer (§4).

### 12.7 Welche Fassung was bekommt (Vorschlag)

| Teil | Wo | Fassung |
|---|---|---|
| 1 Stempel, Art 20, Verteilen, Heilen, Widerspruch | App | 2.0.1 |
| 2 Warnung beim Besitzer | App | 2.0.1 |
| 3c "Zielgeraet unbekannt" | App | 2.0.1 |
| 3a/3b signieren, speichern, ausliefern, falsche abweisen | Relay zuerst, dann App | 2.0.1 |
| 3a/3b fehlende Signatur abweisen (Pflicht) | App | 2.0.2, nach dem Pflicht-Fenster von 2.0.1 |

Teil 3 braucht einen Relay mit neuer Spalte und neuem Feld. Beides ist
additiv: Alte Apps senden das Feld nicht, und alte Relays ignorieren es. Der
Relay geht wie immer zuerst raus. Neue Endpunkte gibt es nicht, an der
nginx-Liste aendert sich nichts.

### 12.8 Belege, die dazu entstehen

- `app/test/net/geraeteliste_verschwiegen_test.dart`, gegen eine Attrappe, die
  Epoche 3 annimmt, aber weiter Epoche 2 ausliefert und das Tablet nicht
  trennt. Faelle: Verteilung kommt an, Kontakt schickt nichts mehr ans Tablet
  und nimmt nichts mehr von ihm; Verteilung verschluckt, die naechste
  Nachricht des Besitzers macht den Kontakt veraltet; Heilen ueber `ke`; das
  Tablet entfernt nach dem Abschied seine Woerter; Warnung beim Besitzer;
  Widerspruch; Buendel des Tablets unter fremder Kennung abgewiesen;
  Erstnachricht des Tablets unter fremder Kennung abgewiesen; "Zielgeraet
  unbekannt" laesst die Sitzung stehen.
- `server/test_relay.py`: `spk_geraete_sig` wird geprueft, gespeichert und je
  Geraet ausgeliefert; ohne Liste und ohne Feld bleibt alles wie bisher; nach
  einer neuen Fassung liefern `/geraeteliste`, `/prekey` und
  `/prekey?nur_geraete=1` dieselbe Epoche.
- Mutationsproben je Riegel wie in §9.
