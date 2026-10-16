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
  verschluesseln nur an gelistete Geraete. Das haelt auch gegen einen
  luegenden Relay (A3) und schliesst `MEHRGERAETE.md` §12.1 (Reflexion)
  strukturell: auch die eigenen Spiegel gehen nur noch an gelistete Geraete.

Wirkung:

- A0 ✔, A1 ✔ (A1 kann zwar das Zweitgeraet des Besitzers abmelden, der
  Besitzer setzt mit den Woertern zurueck, A1 hat danach nichts mehr).
- A2 ◐: kann **nicht still** dazukommen. Sein einziger Zug ist das
  Zuruecksetzen, und das wirft den Besitzer sichtbar hinaus. Danach
  Ping-Pong, Heilung nur ueber eine neue Identitaet (§4).
- A3 ✔ mit Stufe 2.
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
| B Geraeteliste | ✔ | ✔ | ◐ nur laut | ✔ (Stufe 2) | gross |
| C Rotation | – | – | ✔ wenn ausserhalb abgeglichen | ✔ | sehr gross |
| D = B + Hinweis, C spaeter | ✔ | ✔ | ◐ + ehrlicher Weg | ✔ | gross |

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

Ein Geraet, das nicht in der Liste steht, schickt
`POST /geraeteliste/beitritt` mit

```
{"adresse":"…","device_id":37,"info":"…","schluessel":"<GS b64>","v":1,"zeit":…}
```

signiert mit beiden Schluesseln (Beitritts-Praefix). Der Identitaetsschluessel
belegt den Besitz der Woerter (sonst koennte jeder fremde Adressen mit
Anfragen fluten), der Geraeteschluessel den Besitz des neuen Schluessels. Der
Relay haelt hoechstens 3 Anfragen je Adresse fuer 10 Minuten und meldet
verbundenen Mitgliedern `{"type":"beitritt"}`. Mitglieder holen sie mit
`GET /geraeteliste/<adresse>/beitritte`, pruefen beide Signaturen selbst und
zeigen den **Vergleichscode**: die ersten 4 Byte von `SHA-256("BitDM-Vergleich-v1\n" ‖ anfrage)`
als Zahl modulo 10^6, sechsstellig. Das neue Geraet zeigt denselben Code. Erst
dann laesst das Mitglied zu, indem es eine neue Fassung mit dem Eintrag
veroeffentlicht.

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
