# Mehrgeraete — Spezifikation

Stand 30.07.2026. Aus zwei Erkundungen (Client, Relay) zu einer Festlegung
zusammengezogen. **Diese Datei entscheidet.** Wo etwas offen bleiben muss,
steht es in §12 und nirgends sonst.

Zwei Leute koennen hieraus unabhaengig bauen: §1–§3 ist der Vertrag zwischen
ihnen (Kennung, Nachweisbytes, Drahtformat), §4–§7 ist Clientarbeit mit
Serverstuetze, §8 ist die Umstellung, §11 sagt, wer wann was fertig hat.

In dieser Sitzung wurde **nichts gebaut und nichts getestet** (zwei parallele
Arbeiten am selben Verzeichnis). Alle Zahlen sind gelesen oder gerechnet; der
Messbefehl steht jeweils dabei, gesammelt in §14.

---

## 0. Die Voraussetzung, und was sie NICHT loest

**Belegt:** Der Identitaetsschluessel ist rein deterministisch aus den zwoelf
Woertern. `bip39.dart:136-153` (PBKDF2-HMAC-SHA512, 2048 Runden, Salt
`"mnemonic"`, leere Passphrase) → `key_derivation.dart:84-103` (HKDF-SHA256,
festes `info='bitdm identity key v1'` in Zeile 66, leeres Salt in 115,
RFC-7748-Clamping 124-130). Kein Zufall, keine Geraeteeigenschaft in der ganzen
Kette.

**Belegt:** Der Relay prueft nichts anderes als „kannst du mit dem Schluessel
signieren, dessen Base32 diese Adresse ist" — `relay_server.py:687-688`
(`encode_id(identity_key) != bundle.user_id` → 400), `:700` (`/register`),
`:981` (WebSocket). Clientseitig `relay_client.dart:162-170` und `252-262`,
beide mit `identity.keyPair.getPrivateKey()`.

**Daraus folgt:** Signals Stufe „Hauptgeraet beglaubigt Untergeraet" faellt
weg. Jedes Geraet signiert seine eigenen Sitzungsschluessel selbst. Es gibt
kein Geraet mit mehr Recht auf die Adresse als ein anderes. Es gibt deshalb
**keine Kopplungsmaske, keinen QR-Fluss, kein Hauptgeraet** — der Besitz der
zwoelf Woerter IST die Kopplung.

**Was die Voraussetzung nicht loest:** Die AUTHENTISIERUNG faellt weg, die
ADRESSIERUNG nicht. Der Relay kennt heute nur Adressen: eine Buendelzeile je
`user_id` (`:292` `user_id TEXT PRIMARY KEY`), eine WebSocket je Adresse
(`:1006-1034`, Verdraengung mit Code 4409), eine Warteschlange je Empfaenger
(`:311`). Spielt man heute dieselben zwoelf Woerter auf zwei Geraeten ein,
melden sich beide erfolgreich an und **keines merkt etwas**: das zuletzt
angemeldete besitzt das Buendel, `:746` loescht dabei die Einmalschluessel des
anderen, das erste wird stumm getrennt, und beide rasten anschliessend an
derselben Sitzung `name:1`.

---

## 1. Gerätekennung (`device_id`)

| Frage | Festlegung |
|---|---|
| Typ | Ganzzahl, `1 <= device_id <= 2147483647` (2^31−1). Passt in SQLite INTEGER, Dart `int`, Python `int`, 4 Byte unsigned auf der Leitung. |
| Herkunft | **Erstes Geraet einer Adresse: fest `1`.** Jedes weitere: `Random.secure()` aus `2 .. 2^31-1`. |
| „erstes Geraet" | `GET /prekey/<eigene Adresse>?nur_geraete=1` liefert eine leere Geraeteliste **oder** 404 → `1`. Sonst Zufall. Genau ein zusaetzlicher Aufruf, genau einmal je Installation, vor der ersten Registrierung. |
| Ausnahme Bestandsgeraet | Steht `relay_angemeldet_bei` in `meta` (gesetzt in `real_messenger_core.dart:460-464`), ist dies eine bestehende Installation → **`1` ohne zu fragen.** Siehe §8. |
| Speicher | `meta`-Zeile `device_id` in der geraetelokalen verschluesselten Datenbank, genau wie `registration_id` (`signal_store_repository.dart:23,58-74`). Sie haengt am `databasePath` des Geraets (`real_messenger_core.dart:253`), ist also je Installation eine eigene. |
| Ableitung aus dem Seed? | **Nein.** Abgeleitet waeren beide Geraete gleich — das ist genau der Fehler, den wir behandeln. Dieselbe Begruendung wie bei `registration_id` (`signal_store_repository.dart:51-57`, korrekt). |
| `registration_id` dafuer nehmen? | **Nein.** Sie wechselt bei jeder Wiederherstellung (`signal_identity.dart:42-48`), Bereich nur 1..16380 (`:92`, `generateRegistrationId(false)`). Eine Kennung, die sich beim Wiederherstellen aendert, legte eine neue Geraetezeile an statt die alte zu erneuern — nach fuenf Wiederherstellungen waere die Obergrenze aus §6 verbraucht. Sie bleibt unveraendert daneben stehen (§13.1). |

**Warum `1` fuer das erste Geraet und nicht durchgaengig Zufall:** Ein alter,
nicht aktualisierter Client schickt kein Zielgeraet, der Relay setzt dann `1`
ein (§3). Waere die einzige Kennung einer frischen Installation eine
Zufallszahl, koennten alte Clients diese Adresse **nie mehr erreichen**
(„Zielgeraet unbekannt"). Mit dieser Regel ist das erste Geraet jeder Adresse
immer `1`, und die Rueckwaertsverträglichkeit haelt dauerhaft, nicht nur bis
zur ersten Neuinstallation.

### Kollision

Kollisionen sind nur **innerhalb einer Adresse** moeglich (dieselben zwoelf
Woerter). Fuer `d` Geraete sind `d−1` Kennungen zufaellig; Geburtstagsschranke
`(d−1)(d−2)/2 / 2^31`:

| Geraete | Wahrscheinlichkeit | eins in |
|---|---|---|
| 2 | 0 (die zweite ist die erste Zufallszahl) | — |
| 3 | 4,66e-10 | 2 147 483 648 |
| 5 | 2,79e-09 | 357 913 941 |
| 8 (ueber der Grenze) | 9,78e-09 | 102 261 126 |

Gerechnet mit `py -c "d=5;print((d-1)*(d-2)/2/2**31)"`.

**Was bei einer Kollision passiert:** nichts Besonderes, und das ist eine
Entscheidung. Der Relay kann eine Kollision nicht von einer Neuinstallation
desselben Geraeteplatzes unterscheiden — beide fuehren denselben
Besitznachweis und schreiben dieselbe Zeile. Die beiden Geraete
ueberschreiben sich dann gegenseitig Buendel und Einmalschluessel, also genau
das heutige Verhalten, **beschraenkt auf diese zwei Geraete einer Adresse**.
Erkennungsversuche (409 bei abweichender `registration_id`) wurden verworfen:
sie treffen den haeufigen, legitimen Fall „Geraet neu aufgesetzt" genauso.
Heilung: auf einem der beiden Geraete die App-Daten loeschen, es wuerfelt neu.

**Der eine echte Wettlauf:** Zwei Neuinstallationen derselben Phrase innerhalb
weniger Sekunden sehen beide die leere Liste und nehmen beide `1`. Ergebnis =
heutiges Verhalten fuer dieses Paar. Bewusst nicht abgesichert.

---

## 2. Anmeldung — genau welche Bytes

Der heutige Besitznachweis traegt weiter, er wird nur um die Kennung
**erweitert**. Schluessel ist in allen Faellen der private
Identitaetsschluessel (XEdDSA, `Curve.calculateSignature`), Pruefung
serverseitig `verify_signature` (`relay_server.py:251-283`, Curve25519 →
Ed25519 mit beiden Vorzeichenbits).

### 2.1 `/register` (zwei Schritte, unveraendert im Aufbau)

1. `POST /register/challenge` mit `{"user_id": …, "device_id": …}` → `{"nonce": b64(32)}`.
   Der Server haelt Nonces ab jetzt unter dem Schluessel **`(user_id, device_id)`**
   (heute `_nonces[user_id]`, `:474-489`). Fehlt `device_id`, ist der Schluessel
   `(user_id, None)` — ein alter Client kollidiert damit nie mit einem neuen.
   Frist unveraendert 120 s (`:68`), Verbrauch unveraendert per `pop`.
2. `POST /register` signiert **`nonce || SHA256(canonical_bytes)`** — Wortlaut
   unveraendert (`relay_server.py:694`, `relay_protocol.dart:122-128`).

`canonical_bytes` (`relay_server.py:523-547`) bekommt **ein** Feld dazu, und
zwar **nur wenn es gesetzt ist**:

```python
payload = {}
if self.device_id is not None:
    payload["device_id"] = self.device_id      # sort_keys => steht vorne
payload.update({ "user_id": …, "identity_key": …, "registration_id": …, … })
return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
```

Dart-Gegenstueck (`relay_protocol.dart:105-120`) — `device_id` als **erster**
Schluessel in der Map, weil Dart in Einfuegereihenfolge schreibt und `d` vor
`i` kommt:

```dart
final payload = <String, Object?>{
  if (deviceId != null) 'device_id': deviceId,
  'identity_key': identityKey, 'one_time_prekeys': …, 'registration_id': …,
  'signed_prekey': …, 'signed_prekey_id': …, 'signed_prekey_sig': …,
  'user_id': userId,
};
```

**Weil das Feld bei `None` fehlt, sind die Bytes eines alten Clients Byte fuer
Byte die heutigen.** Das ist die ganze Rueckwaertsverträglichkeit von
`/register`. Die Fixtures in `app/test/net/canonical_fixtures.json` werden um
Faelle *mit* `device_id` erweitert, die bestehenden bleiben unveraendert
(Erzeuger: `py -3 server/tools/write_canonical_fixtures.py`).

**Warum die Kennung in die Signatur muss:** Stuende sie nur im Rumpf, koennte
ein Weiterleitender sie aendern und dieselbe Signatur weiterverwenden. Die
Registrierung landete unter fremder Geraetenummer und loeschte dort die
Einmalschluessel des echten Geraets — dieselbe Luecke, die
`relay_server.py:526-533` fuer `registration_id` schon beschreibt.

### 2.2 `/ws`

Query: `?user_id=<56>&device_id=<n>`. Signiert wird

* **mit** `device_id` in der Query: `nonce || uint32be(device_id)` (36 Byte)
* **ohne**: `nonce` (32 Byte) — heutiges Verhalten, `relay_server.py:981`

```python
erwartet = nonce if roh_device is None else nonce + device_id.to_bytes(4, "big")
```

```dart
final b = ByteData(4)..setUint32(0, deviceId, Endian.big);
final sig = Curve.calculateSignature(priv,
    Uint8List.fromList([...nonce, ...b.buffer.asUint8List()]));
```

Ein Herunterhandeln ist nicht moeglich und faellt geschlossen aus: streicht
jemand `device_id` aus der Query eines neuen Clients, erwartet der Server 32
Byte, der Client hat 36 signiert → 4403. Ohne den privaten
Identitaetsschluessel kommt ueberhaupt keine Signatur zustande (`:959-965`
plus `:981`).

Der Server prueft zusaetzlich vor der Challenge:
`SELECT identity_key FROM identities WHERE user_id=? AND device_id=?` — kein
Treffer → `{"type":"error","reason":"erst /register aufrufen"}` und 4401,
unveraendert (`:959-965`).

Nach erfolgreicher Anmeldung: `identities.last_seen = time.time()` fuer dieses
(Adresse, Geraet). Einmal je Verbindung, siehe §7.

`auth_result` traegt zusaetzlich `"device_id": <n>` zurueck — reine Diagnose,
dieselbe Begruendung wie beim Rueckspiegel des Empfangsnachweises
(`:998-1004`). Alte Clients lesen nur `ok`.

---

## 3. Drahtformat, alt neben neu

Regel fuer die ganze Umstellung: **fehlt `device_id` / `to_device`, ist es
Geraet 1.** Kein Endpunkt aendert seine Form, alle Ergaenzungen sind additiv.

### 3.1 `POST /register/challenge`

| | Rumpf |
|---|---|
| alt | `{"user_id":"aaa…"}` |
| neu | `{"user_id":"aaa…","device_id":4711}` |

Antwort unveraendert `{"nonce": b64}`.

### 3.2 `POST /register`

Bundle bekommt `"device_id": 4711` (optional). Antwort unveraendert
`{"ok":true,"one_time_prekeys":<Anzahl>}` — die Anzahl zaehlt ab jetzt **nur
dieses Geraet** (`WHERE user_id=? AND device_id=?`, heute `:755-757`
adressweit). Der Client leitet daraus ab, ob er nachliefern muss
(`relay_client.dart:170`), und das muss je Geraet stimmen.

Neuer Fehler: `507 "Diese Adresse hat schon <N> Geraete"` (§6). `507` und
nicht `429`, nach dem Muster `:725-729`: das ist keine Bremse, die nachgibt.

Zusaetzliche Pruefung: `device_id` muss `int`, `1 <= x <= 2^31-1` und kein
`bool` sein (Python: `isinstance(x, bool)` ist `int`! — dieselbe Falle wie bei
`:1131-1132` und der Blob-Groesse), sonst 400.

### 3.3 `GET /prekey/{addr}`

| | Antwort |
|---|---|
| alt | `{user_id, identity_key, registration_id, signed_prekey_id, signed_prekey, signed_prekey_sig, one_time_prekey}` |
| neu | dasselbe **plus** `"geraete": [ {device_id, registration_id, signed_prekey_id, signed_prekey, signed_prekey_sig, one_time_prekey}, … ]`, aufsteigend nach `device_id` |

* Die **flachen Felder bleiben** und sind eine **Kopie von `geraete[0]`**, also
  dem Geraet mit der kleinsten Kennung. Nicht „Geraet 1": ist Geraet 1
  weggeraeumt (§7), muss ein alter Client trotzdem jemanden erreichen.
  Ausdruecklich **kein zweiter Einmalschluessel** fuer den flachen Block — es
  ist derselbe, sonst kostet jede Abfrage einen Schluessel zu viel.
* `?nur_geraete=1` → `{"user_id":…, "geraete":[{"device_id":…,"registration_id":…}, …]}`.
  **Keine Schluessel, kein Einmalschluessel wird gezogen, kein
  OTK-Token verbraucht** — nur der IP-Eimer (`:771`). Das ist der Aufruf, der
  oft kommt (§4).
* Ein eigener Endpunkt `/devices/<addr>` wurde verworfen: derselbe Handler
  laedt die Zeilen ohnehin, ein zweiter Pfad waere eine zweite Stelle mit
  Ratenbegrenzung und nginx-Regel.
* `otk_limit_ok` (`:791`) wird **einmal je Anfrage** gebucht, nicht je
  ausgegebenem Schluessel. Greift die Bremse, kommen **alle** Geraete ohne
  Einmalschluessel — bewusst, unveraenderte Begruendung `:785-791`. Preis:
  der Prekey-Drain ist um den Geraetefaktor billiger (bei 5 Geraeten 5×). Das
  ist tragbar, weil das Ergebnis eines geleerten Vorrats laut Entwurf kein
  Fehler ist, sondern X3DH ohne Einmalschluessel.
* 404 „unbekannte Adresse" unveraendert, wenn die Adresse **kein** Geraet hat.

### 3.4 `/ws` Rahmen

| Richtung | alt | neu |
|---|---|---|
| Client → Server | `{"type":"message","id":…,"to":…,"ciphertext":b64}` | `+ "to_device": 4711` |
| Server → Client | `{"type":"message","from":…,"ciphertext":…,"ts":…,"q":…}` | `+ "from_device": 4711` |
| Client → Server | `{"type":"empfangen","ids":[…]}` | unveraendert |
| Server → Client | `{"type":"ack","id":…,"to":…}` | unveraendert, **eins je Rahmen** |
| Server → Client | `{"type":"prekeys_low","remaining":n}` | unveraendert, zaehlt jetzt je Geraet |
| Server → Client | `{"type":"push_ok"…}`, `blob_marke_ok`, `error` | unveraendert |

* `from_device` ist die **wichtigste Erweiterung des ganzen Vorhabens**, und
  sie liegt auf der Empfangsseite. Ohne sie weiss der Empfaenger nicht, gegen
  welche Sitzung er entschluesseln soll (`real_messenger_core.dart:911` baut
  den `SessionCipher` heute mit `SignalProtocolAddress(von, 1)`), und jedes
  Fanout ist wirkungslos: zwei Chiffretexte kaemen an, beide gegen `name:1`
  probiert, einer scheitert immer — und `:989-993` schreibt den
  Ratchet-Fortschritt auch beim Fehlschlag fest.
* `from_device` ist die Geraetekennung der **angemeldeten Verbindung** des
  Absenders, nie ein Wert aus dem Rahmen.
* `empfangen` loescht mit `WHERE id=? AND recipient=? AND recipient_device=?`,
  Geraet **aus der Verbindung**. Das ist die gefaehrlichste Einzelstelle:
  `recipient` allein trennt nicht mehr, beide Geraete haben dieselbe Adresse,
  und die Zeilenkennungen sind fortlaufend und erratbar (Begruendung schon in
  `:1125-1130`). Ohne diese Bedingung koennte Geraet A die noch nicht
  zugestellte Post von Geraet B loeschen — stiller Verlust, kein Fehler, keine
  Spur. Dasselbe fuer die Sammelloeschung `:1071-1075`.
* Neuer `error`-Grund: `"Zielgeraet unbekannt"` (Existenzpruefung `:1296` wird
  `WHERE user_id=? AND device_id=?`). Sonst koennte ein Absender an Geraet 999
  puffern, das nie existiert, und dieselbe Flut ueber eine echte Adresse
  fahren.
* `ack` bleibt eins je Rahmen. Kein neues „Teil-ack": der Client schickt n
  Rahmen und zaehlt selbst (§4).

### 3.5 Datenmodell des Relays

```sql
identities        PRIMARY KEY (user_id, device_id)        -- heute nur user_id (:292)
                  + last_seen REAL NOT NULL DEFAULT 0
                  push_endpoint bleibt Spalte -> damit automatisch je Geraet
one_time_prekeys  PRIMARY KEY (user_id, device_id, key_id) -- heute (user_id,key_id) (:305)
                  FOREIGN KEY (user_id, device_id) REFERENCES identities(...) ON DELETE CASCADE
queue             + recipient_device INTEGER NOT NULL DEFAULT 1
                  + sender_device    INTEGER NOT NULL DEFAULT 1
                  INDEX (recipient, recipient_device)
blob_marken       UNVERAENDERT, ausdruecklich (§6)
```

**`sender_device` gehoert dazu und fehlte in der Erkundung** (§13.3): eine
gepufferte Zeile wird spaeter zugestellt und muss dann `from_device` tragen
(`:1038-1057`) — ohne die Spalte weiss der Server beim Nachzustellen nicht
mehr, von welchem Geraet die Nachricht kam.

`connections: dict[str, dict[int, WebSocket]]`, `nachweisfaehig` ebenso
zweistufig. Verdraengung mit 4409 **nur bei gleichem (Adresse, Geraet)**
(`:1006-1024`). Der Aufraeumzweig `:1446-1453` behaelt die Pruefung
`is ws` — sonst reisst ein Geraet den Eintrag eines anderen weg.

`/health` (`:643-651`): `users` → `COUNT(DISTINCT user_id)`, neu `geraete` →
`COUNT(*)`, `online` → Summe der Sockets ueber alle Adressen (bisher
gleichbedeutend). `IDENTITAETEN_MAX` (`:723`) prueft ebenfalls
`COUNT(DISTINCT user_id)`, sonst sinkt die Aufnahmegrenze des Relays um den
Geraetefaktor und die Betriebszahl bedeutet etwas anderes als vorher.

`stosse_an` (`:923-951`) bekommt `(user_id, device_id)` und liest den Endpunkt
der Geraetezeile. Ein Anstoss je gepufferter Zeile, also je Zielgeraet einer.
Der POST bleibt leer (Begruendung `:821-829`).

`msg_limit_ok` (`:442-455`): Fanout heisst n Rahmen je Nutzernachricht.
`MSG_CAPACITY` 60 → **180**, `MSG_REFILL_PER_SEC` 2,0 → **6,0**. Begruendung
und Zahl gehoeren in den Kommentar: 180 Rahmen × 64 KiB = **11,25 MiB** Stoss
je Absender (`py -c "print(180*65536/1024**2)"` → 11.25); bei drei Geraeten je
Adresse bleiben das die heutigen 60 Nutzernachrichten, im schlechtesten Fall
(9 Rahmen) 20. Die Platte bleibt durch `QUEUE_MAX_TOTAL` und
`QUEUE_MAX_PER_USER` gedeckelt — die Bremse ist nicht die einzige
Verteidigung.

---

## 4. Fanout

**Genau eine Stelle im Client:** `real_messenger_core.dart:1788-1838`
(`_sendePayload`). Dort wird die Sitzung gewaehlt (`:1792`) UND das Buendel
geholt (`:1824`), und **alle** Versandwege laufen dort durch: `sendMessage`
(`:1341`), `sendeAnhang` (`:1393`), `markRead` (`:1692`), Quittungen,
Kontaktzusage und -absage. Deshalb gehoert auch der Spiegel (§5) hierher und
nicht in `sendMessage`.

```
_sendePayload(an, p, {spiegeln = true}):
  ziele = geraeteliste(an)                 # s.u.
  fuer jedes g in ziele:
     ziel = SignalProtocolAddress(an, g)
     wenn keine Sitzung: Buendel von g holen, processPreKeyBundle
     ct = SessionCipher(ziel).encrypt(p.toBytes())
     bescheid[g] = Wegwahl.schicke(an, g, Envelope.of(ct).toBytes())
  commit(store)                            # EINMAL, nach der Schleife
  ergebnis = Weg.relay/naehe  wenn MINDESTENS EIN g angenommen hat
             sonst Weg.liegt
  wenn spiegeln und ergebnis != liegt und p.kind spiegelfaehig:
     _sendePayload(myId, Payload.spiegel(an, p), spiegeln: false)
```

**Verdichtung des Rueckgabewerts:** `draussen`, sobald **mindestens ein**
Geraet angenommen hat, sonst `liegt`. Sonst blieben Nachrichten auf `sending`
stehen, nur weil das Tablet der Gegenstelle seit Wochen aus ist. Der
`Wegbescheid` (`wegwahl.dart:59-104`) traegt `beimRelay`/`inDerNaehe` — beide
werden ver-ODERt, denn sie schuetzen vor doppeltem Versand ueber den anderen
Weg und muessen im Zweifel `true` sein.

**Die Geraeteliste einer Adresse ist der Sitzungsspeicher.** Kein neuer
Speicher, keine neue Tabelle: Sitzungen sind bereits mit `name:geraetId`
geschluesselt (`signal_store.dart:317/330/335/339`, Schema
`encrypted_database.dart:308-311` `address TEXT PRIMARY KEY`), und
`getSubDeviceSessions` (`:354-366`) plus `_nameOf`/`_deviceOf` (`:376-384`)
zerlegen den Schluessel schon. „Bekannte Geraete" = „Geraete, mit denen eine
Sitzung besteht".

**Wann wird nachgefragt:**

| Anlass | Aufruf |
|---|---|
| keine Sitzung mit irgendeinem Geraet dieser Adresse | `GET /prekey/{addr}` (voll, mit Schluesseln) |
| Liste aelter als **6 Stunden** | `GET /prekey/{addr}?nur_geraete=1`, danach fuer neue Kennungen `GET /prekey/{addr}` |
| eigene Adresse, nach jedem erfolgreichen `connect()` | `?nur_geraete=1` |
| `error: "Zielgeraet unbekannt"` fuer Geraet g | `deleteSession(name:g)` (`signal_store.dart:339`), Liste sofort neu holen |
| Nachricht von unbekanntem `from_device` | nichts. Der eingehende PreKey-Umschlag legt die Sitzung selbst an. |

Der Zeitstempel der letzten Pruefung: **eine neue Spalte
`geraete_geprueft INTEGER` an `contacts`** (Schema-Aufstockung, ein
`ALTER TABLE`), keine neue Tabelle und keine Meta-Zeile je Kontakt. Fuer die
eigene Adresse genuegt eine `meta`-Zeile.

**Kosten der 6 Stunden, gerechnet:** ein `?nur_geraete=1` je Kontakt und
Fenster, also 4 Anfragen je Kontakt und Tag, ohne Schluesselverbrauch. Bei 50
Kontakten 200 Anfragen am Tag gegen den IP-Eimer (120 Stoss, 2/s Nachschub,
`:75-76`) — das ist unter einer Minute Nachschub.

**Die eigene Adresse ist Sonderfall genau in einem Punkt:** `/prekey/{myId}`
enthaelt auch die **eigene** Geraetezeile. Der Client muss seine eigene
`device_id` beim Aufbau ueberspringen — niemals an sich selbst
verschluesseln.

**Neues Geraet zwischen Holen und Senden:** Es bekommt diese Nachricht nicht.
Es bekommt alles ab dem naechsten Fenster (≤6 h), und sofort alles, sobald es
selbst einmal schreibt — dann kennt die Gegenstelle es aus `from_device` und
legt die Rueckrichtung an. Ein frisch installiertes Zweitgeraet ist also bis
zu 6 Stunden still, wenn es nicht selbst schreibt. Fuer die **eigenen**
Geraete ist dieses Fenster durch die Auffrischung bei jedem `connect()`
praktisch auf einen App-Start verkuerzt — das ist Henriks Kernszenario und der
Grund fuer diese Ausnahme.

---

## 5. Eigene Geraete: Spiegel

### 5.1 Neuer `PayloadKind` 8

`payload.dart:37-45` belegt 1..7. **Code 8 = `spiegel`.** Die Codes duerfen
nie umgedeutet werden (Kommentar `:35-37`), also 8 nehmen und nicht 1
erweitern.

Inhalt (im bestehenden JSON-Rahmen von `toBytes()`, `:155-168`):

| Feld | Bedeutung |
|---|---|
| `id` | Kennung der **inneren** Nachricht (unveraendert uebernommen) |
| `t` | `sentAt` der inneren Nachricht |
| `c` | **neu:** Ziel-Chat, die 56-Zeichen-Adresse der Gegenstelle |
| `x` | base64 der **vollstaendigen inneren `Payload.toBytes()`** |

Die inneren Bytes sind genau die, die die Gegenstelle bekommen hat — kein
zweites Format, keine Moeglichkeit, dass Spiegel und Original auseinander
laufen. Kosten: base64 +33 % plus Auffuellung. Eine einbloeckige Textnachricht
(256 B) wird zu 342 B base64 plus Rahmen, also zwei Bloecke (512 B). Der
groesste Fall ist ein Anhang-Rezept (rund 23 KB, `encrypted_database.dart:379-386`)
→ rund 31 KB base64, weit unter `MAX_CIPHERTEXT_BYTES` 64 KiB
(`relay_server.py:65`).

`c` wird beim Lesen geprueft wie alles von draussen (`BitdmAddress.decode`,
Muster wie bei `id` in `payload.dart:200-219`), sonst
`PayloadFormatException`.

**Rueckwaertsverträglich ohne Zusatzarbeit:** `byCode` (`:59-64`) gibt bei
unbekanntem Code `null`, `fromBytes` wirft dann
`PayloadFormatException('unbekannte Art 8')` (`:185-190`), und der Eingang
verwirft still (`real_messenger_core.dart:913-923`, `_behandleEingangsfehler`
in `:914`). Ein Geraet mit alter App
sieht Spiegel-Umschlaege also gar nicht, statt abzustuerzen. Die Auffuellung
auf 256er-Bloecke (`:145-168`) verbirgt zusaetzlich, dass ein Spiegel anders
gebaut ist als ein Text.

### 5.2 Was gespiegelt wird

| `PayloadKind` | gespiegelt | Wirkung auf Geraet B |
|---|---|---|
| `text` (1) | ja | eigene Nachricht in Chat `c`, `isMine: true` |
| `anhang` (7) | ja | Anhangeintrag, Zustand „angekuendigt" (Zustand und Pfad sind ortsgebunden, `encrypted_database.dart:387-390`) |
| `contactRequest` (2) | ja | Kontakt anlegen, ausgehend |
| `contactAccept` (3) | ja | Kontakt anlegen/bestaetigen |
| `contactDecline` (4) | ja | Kontakt entfernen |
| `deliveryReceipt` (5) | **nein** | — |
| `readReceipt` (6) | **nein** | — |

Quittungen werden nicht gespiegelt: sie verdoppelten das Sendevolumen fuer
eine Information, die B selbst erzeugt, und der Empfaenger der Quittung ist
die Gegenstelle, nicht ich. Folge (Grenze, kein Fehler): **Haken- und
Lesezustand sind je Geraet.** Siehe §12.3.

**Kontaktabgleich faellt damit fast von selbst an, ohne Listenabgleich.**
Eingehend ohnehin: die Gegenstelle faechert an beide meiner Geraete, beide
legen den Kontakt an (`real_messenger_core.dart:1014-1020`). Ausgehend ueber
den Spiegel. Nicht abgeglichen werden Kontakte, die nur angelegt und nie
beschrieben wurden, sowie Anzeigenamen und der „verifiziert"-Haken
(`contacts.display_name`, `contacts.verified`). Das ist die faule Fassung von
Henriks „dieselben Kontakte" und trifft seinen Umfang: wer alte Verlaeufe
nicht uebertraegt, darf auch mit einer leeren Kontaktliste anfangen, die sich
ab dann mitfuehrt. `ponytail:`-Kommentar an `chat_repository.dart:44` mit
dieser Decke.

### 5.3 „Von mir selbst" erkennen

**`von == myId` genuegt, und es ist kryptographisch statt behauptet.** Eine
Nachricht ist nur entschluesselbar, wenn sie ueber eine Sitzung mit unserem
eigenen Identitaetsschluessel lief, und `isTrustedIdentity`
(`signal_store.dart:188-196`) rechnet die Adresse aus dem Schluessel **nach**
(`_keyMatchesAddress`). Ein Fremder kann `from` beliebig behaupten, aber nicht
entschluesselbar machen. Die Behauptung **in** der Nutzlast wird nie gefragt.

Der Zweig gehoert in den Verteiler `real_messenger_core.dart:925-939`, **vor**
`_legeEingangAb` (`:1006`): bei `von == myId` und `kind == spiegel` die innere
Nutzlast auspacken und mit `chatId: c`, `senderId: myId`, `isMine: true`
speichern. `_legeEingangAb` legt heute hart `chatId: von, senderId: von,
isMine: false` fest (`:1036-1039`) und ist fuer Spiegel nicht benutzbar.

**Drei Stolperfallen, die beim ersten Selbst-Fanout sofort sichtbar werden:**

1. Die eigene Adresse darf **nicht** als „eingehende Kontaktanfrage" in der
   Liste erscheinen — Ausschluss vor `:1014`.
2. **Keine Empfangs- oder Lesequittung an sich selbst** (`:1060`, `markRead`
   `:1692`).
3. Der Spiegelversand darf **nicht** ueber die oeffentliche
   `sendMessage`-API laufen, weil `:1342` `_fordereKontakt(myId)` aufruft und
   `_fordereKontakt` (`:1317-1322`) fuer jede Adresse ausserhalb der
   Kontaktliste `UnknownContactException` wirft — auch fuer die eigene. Der
   Spiegel geht ueber `_sendePayload` direkt.

### 5.4 Entdoppelung

Schon vorhanden: `CREATE UNIQUE INDEX idx_messages_eindeutig ON
messages(chat_id, sender_id, id)` (`encrypted_database.dart:354-355`) und
`INSERT OR IGNORE INTO messages` (`chat_repository.dart:335`). Ein Spiegel
traegt `chat_id = c`, `sender_id = myId`, `id = <innere Kennung>` und ist
damit gegen Wiederholungen abgesichert — noetig, weil der Nachversand
(`real_messenger_core.dart:1863` `nachversand`, Schleife `:1898`) dieselbe
Nutzlast erneut schickt und damit erneut spiegelt.

Kein Spiegel eines Spiegels: `_sendePayload(myId, …, spiegeln: false)`.

**Spiegel erst nach dem Original.** Hat kein Geraet der Gegenstelle
angenommen (`liegt`), wird nicht gespiegelt — sonst zeigte Geraet B eine
Nachricht als versandt, die nie hinausging. Beim Nachversand geht beides
zusammen hinaus.

---

## 6. Obergrenze

**`BITDM_GERAETE_MAX = 5` je Adresse.**

Begruendung mit Zahlen: jedes Geraet kostet dem Absender eine Verschluesselung
und dem Relay eine Warteschlangenzeile. Schlechtester Fall fuer **eine**
Nutzernachricht: 5 Geraete der Gegenstelle + 4 eigene = **9** Verschluesselungen
und 9 Zeilen. Platte je Adresse: 5 × `QUEUE_MAX_PER_USER` 500 ×
`MAX_CIPHERTEXT_BYTES` 64 KiB = **156,25 MiB**
(`py -c "print(5*500*65536/1024**2)"` → 156.25; je Geraet 31,25 MiB).
Einmalschluessel: 5 × 100 = 500 je Adresse, der Deckel
`OTK_MAX_JE_BUENDEL` 200 gilt weiter je Buendel, also je Geraet
(`relay_server.py:134`, `:520-521`, App laedt 100 —
`real_messenger_core.dart:99`). Fuenf deckt Telefon + Tablet + Laptop +
Schreibtisch + Reserve.

**Beim Ueberschreiten**, im selben Sperrblock wie `:719-729`:

1. Gibt es unter dieser Adresse ein Geraet mit
   `last_seen < now - BITDM_GERAET_TTL` (30 Tage, §7)? → **das aelteste
   davon loeschen** (Kaskade nimmt Prekeys mit, Warteschlangenzeilen
   ausdruecklich mit loeschen) und die Registrierung annehmen.
2. Sonst **507 „Diese Adresse hat schon 5 Geraete"**.

Kein Verdraengen lebender Geraete: bei sechs lebenden Geraeten wuerden sie
sich gegenseitig bei jeder Bundle-Erneuerung hinauswerfen (die App erneuert
regelmaessig: `:1080-1081` schickt `prekeys_low`,
`real_messenger_core.dart:543` faengt es und ruft `_fuelleNachUndMelde`
→ `_meldeAn`, `:553-566`) — ein
Dauerpendeln mit Nachrichtenverlust waere schlimmer als eine ehrliche Absage.

**Was NICHT je Geraet zaehlt:** die Blob-Tagesmenge. `blob_menge_heute`
(`:201-206`), `blob_marken` (`:319-334`), `BLOB_TAGESMENGE` 25 GiB (`:174`)
bleiben **an der Adresse**. Mit `device_id` bekaeme dieselbe Person mit 5
Geraeten 125 GiB am Tag — die Verteidigung waere fuer den Preis eines zweiten
Geraets aufzuheben (Begruendung `:165-170`). Als **Absicht kommentieren**,
damit die naechste Runde nicht „der Vollstaendigkeit halber" nachtraegt.

**Der Preis der Obergrenze ist Sichtbarkeit:** Der Relay listet Geraete je
Adresse oeffentlich auf (`?nur_geraete=1`, ohne Anmeldung — wie `/prekey`
heute schon `registration_id` und das ganze Buendel oeffentlich ausgibt). Wer
fragt, sieht, **wie viele Geraete** eine Adresse hat. Siehe §12.4.

**Sicherheitsfolge, die genannt werden MUSS:** Wer die zwoelf Woerter hat,
kann heute schon vollstaendig auftreten. Mit Mehrgeraete bekommt er
zusaetzlich **von jedem Absender eine eigene Kopie** jeder Nachricht, ohne
dass irgendwo etwas auffaellt. Es gibt **keinen Widerruf** — ein Geraet
abzumelden ist unmoeglich, weil kein Geraet mehr Recht hat als ein anderes;
die einzige Abhilfe ist eine neue Identitaet. Deshalb **verpflichtend**: die
App zeigt auf dem Identitaets-/Einstellungsbildschirm die Zahl der Geraete
dieser Adresse (`?nur_geraete=1` fuer die eigene Adresse, eine Zeile,
**keine** Verwaltungsmaske). Damit wird aus einem unsichtbaren Mitleser eine
sichtbare Zahl, die nicht stimmt.

---

## 7. Vergessene Geraete

Ein Geraet, das nie wieder kommt, heilt heute allein durch
`QUEUE_TTL_SECONDS` = 14 Tage (`:63`), stuendlich von `purge_expired`
(`:398-407`) und dem `janitor` (`:574-581`). Es sammelt sich also nicht fuer
immer. Aber solange es lebt, ist seine Schlange dauerhaft am Deckel
(`QUEUE_MAX_PER_USER` 500, geprueft `:1343-1350` und `:1414-1419`), und jeder
Absender bekaeme dafuer „Warteschlange voll" (`:1347`, `:1418`) — bei einer
Adressen-Schlange faellt das niemandem auf, je Geraet macht ein totes Telefon
die Adresse **teilweise unbeschickbar**.

Zwei Festlegungen:

1. **`BITDM_GERAET_TTL` = 30 Tage.** Der `janitor` (`:574-581`) loescht
   Geraetezeilen mit `last_seen < now - GERAET_TTL` samt Warteschlangenzeilen;
   die Prekeys nimmt die Kaskade. 30 Tage sind laenger als der Urlaub eines
   Tablets und kuerzer als „vergessen". Entscheidet der **Betreiber** per
   Umgebungsvariable, wie alle Aufbewahrungsfristen (`:61-65`).
2. **Bei vollem Geraete-Deckel die AELTESTE Zeile dieses Geraets verwerfen**,
   statt den Absender abzuweisen. Sonst haengt eine lebende Unterhaltung an
   einem toten Telefon. Der Verlust trifft nur das tote Geraet; auf den
   anderen Geraeten derselben Adresse liegt die Nachricht. `QUEUE_MAX_TOTAL`
   (`:105`, 200 000 Zeilen = **12,207 GiB** im schlechtesten Fall,
   `py -c "print(200000*65536/1024**3)"` → 12.20703125) **weist weiter ab** —
   das Dach ueber der ganzen Tabelle darf nicht nachgeben.

`last_seen` wird bei erfolgreicher `/ws`-Anmeldung gesetzt (§2.2), einmal je
Verbindung. `updated_at` (`:298`) bleibt, was es ist: Zeitpunkt der letzten
Registrierung.

---

## 8. Umstellung einer bestehenden Installation

**Bedingung: keine Unterhaltung darf verloren gehen.** Sie geht auch nicht
verloren, und zwar aus einem Grund: **eine bestehende Installation behaelt
`device_id = 1`.** Alle bestehenden Sitzungen sind mit `name:1` geschluesselt
(`signal_store.dart:317`), alle Gegenstellen bleiben Geraet 1, also aendert
sich an keiner einzigen Sitzung etwas. Kein neuer X3DH, keine neue
Pruefnummer, kein Ratchet-Neustart.

### Relay (einmal, in `init_db`)

`CREATE TABLE IF NOT EXISTS` laesst eine bestehende Tabelle unangetastet, neue
Spalten werden schon heute per `PRAGMA table_info` + `ALTER TABLE` nachgezogen
(`:372-392`). Fuer diese Umstellung reicht das **nicht ueberall**:

| Tabelle | Weg |
|---|---|
| `queue` | `ALTER TABLE ADD COLUMN recipient_device INTEGER NOT NULL DEFAULT 1`, dasselbe fuer `sender_device`. Der Primaerschluessel ist die AUTOINCREMENT-Kennung, er wird nicht angefasst. Neuen Index anlegen, `idx_queue_recipient` verwerfen. |
| `identities` | **Neuanlage + Kopie.** Der Primaerschluessel ist heute `user_id` (`:292`) und liesse ein zweites Geraet gar nicht zu; ein Primaerschluessel ist in SQLite per `ALTER` nicht erweiterbar. |
| `one_time_prekeys` | **Neuanlage + Kopie**, gleicher Grund (`:305`), dazu der neue zusammengesetzte Fremdschluessel. |
| `blob_marken` | unveraendert |

Ablauf, genau in dieser Reihenfolge, einmal beim Start:

```
PRAGMA foreign_keys=OFF          -- MUSS vor BEGIN stehen; innerhalb einer
                                 -- Transaktion ist dieses PRAGMA wirkungslos
BEGIN
  CREATE TABLE identities_neu (... PRIMARY KEY (user_id, device_id) ...)
  INSERT INTO identities_neu SELECT user_id, 1, identity_key, registration_id,
         signed_prekey_id, signed_prekey, signed_prekey_sig, updated_at,
         push_endpoint, 0 FROM identities
  CREATE TABLE otk_neu (... PRIMARY KEY (user_id, device_id, key_id),
         FOREIGN KEY (user_id, device_id) REFERENCES identities(user_id, device_id)
         ON DELETE CASCADE)
  INSERT INTO otk_neu SELECT user_id, 1, key_id, public_key FROM one_time_prekeys
  DROP TABLE one_time_prekeys; DROP TABLE identities
  ALTER TABLE identities_neu RENAME TO identities
  ALTER TABLE otk_neu        RENAME TO one_time_prekeys
  PRAGMA foreign_key_check   -- muss leer sein
COMMIT
PRAGMA foreign_keys=ON
```

Erkennung, ob die Umstellung noetig ist: `device_id` fehlt in
`PRAGMA table_info(identities)`. Alle bestehenden Zeilen werden **Geraet 1**.

### Client

1. Update laeuft an. `device_id` fehlt in `meta`, aber
   `relay_angemeldet_bei` steht da (`real_messenger_core.dart:437`,
   geschrieben `:460-464`) → `device_id = 1` schreiben, **ohne** den Relay zu
   fragen.
2. `_meldeAnWennNoetig` (`:416-444`) bleibt wie sie ist: sie prueft die
   eigenen Meta-Zeilen `relay_prekey_count` und `relay_angemeldet_bei`, ist
   also schon geraetelokal gedacht und damit richtig. Aus dem Ueberschreiben
   beim Relay (`:736`/`:746`) wird von selbst ein Nebeneinander, sobald der
   Relay je (Adresse, Geraet) speichert. **Kein Zusatzcode fuer
   Geraeteverwaltung.**
3. Sitzungen: unangetastet. Die Geraeteliste eines Kontakts ist zunaechst
   `{1}` (aus dem Sitzungsspeicher), die erste Auffrischung nach 6 h holt
   spaetere Geraete dazu.
4. Ein **neues** Geraet derselben Phrase: `?nur_geraete=1` liefert `[1]` →
   Zufallskennung, Registrierung daneben, ab da Fanout.

### Reihenfolge zwischen den Seiten

**Der Relay geht zuerst und allein.** Er ist mit `device_id`-Standard 1
vollstaendig rueckwaertsverträglich; ein unveraenderter Client merkt nichts
(dieselbe Ruecksicht wie beim Empfangsnachweis, `:986-996`). Ein neuer Client
gegen einen alten Relay dagegen faellt aus: `to_device` wird ignoriert, alle
Chiffretexte laufen an Geraet 1, und der Empfaenger bekommt Umschlaege, die er
nicht zuordnen kann. Deshalb §11.

### Was nach einer Wiederherstellung passiert (kein Regress, aber genau so)

Neues Telefon aus zwoelf Woertern: Liste ist nicht leer (das alte Geraet 1
steht noch drin) → Zufallskennung. Gegenstellen faechern weiter auch an das
tote Geraet 1, bis es nach 30 Tagen weggeraeumt wird; Nachrichten an das neue
Telefon kommen an, sobald es einmal geschrieben hat oder das 6-Stunden-Fenster
umgelaufen ist. Vorher gingen sie an Geraet 1 und sind fuer den Nutzer
verloren — das ist heute genauso (die Sitzung passt nicht, `:989-993`
schreibt den Fortschritt fest, `_behandleEingangsfehler` verwirft), nur heilt
es jetzt nach spaetestens 6 Stunden statt beim naechsten Zufall.

Hilfreich dabei: `SessionBuilder.processPreKeyBundle` ruft
`sessionRecord.archiveCurrentState()`, wenn der Datensatz nicht frisch ist
(libsignal_protocol_dart 0.8.2, `lib/src/session_builder.dart:139`) — ein
neuer Sitzungsaufbau **archiviert** den alten Zustand statt ihn zu loeschen,
noch unterwegs befindliche Nachrichten der alten Sitzung bleiben also
entschluesselbar.

---

## 9. Was dieser Entwurf nicht leistet — und wie die App es sagt

**Kein Verlaufsuebertrag.** Henriks Entscheidung. Geraet B sieht **keine**
Nachricht, die vor seiner Kopplung geschrieben wurde. Ab dem Moment der
Kopplung sieht es alles, was ueber den Relay laeuft.

Weiter nicht geleistet: kein Zusammenfuehren von Kontaktlisten (§5.2), keine
Anzeigenamen und kein „verifiziert"-Haken auf dem zweiten Geraet, keine
Geraeteverwaltung, kein Widerruf (§6), kein Abgleich von Haken- und
Lesezustand (§5.2), kein Mehrgeraetebetrieb ueber den Nahbereich (§13.4),
keine Anhang-Dateien auf dem zweiten Geraet (nur der Eintrag; `zustand` und
`pfad` sind ortsgebunden, `encrypted_database.dart:387-390`).

**Wie es der Nutzer erfaehrt** — zwei Stellen, beide reiner Text, keine neue
Maske:

1. `restoreIntro` in `data.dart:107` (englisch) und `:389` (deutsch), gezeigt
   in `main.dart:2319` auf dem Wiederherstellen-Bildschirm (`:2298`), bekommt
   einen Satz: **„Alte Nachrichten kommen nicht mit. Dieses Geraet beginnt mit
   einer leeren Unterhaltungsliste und sieht ab jetzt alles Neue."** Das ist
   derselbe Bildschirm, den ein Zweitgeraet benutzt — es gibt keinen anderen
   Weg hinein, und deshalb genau die richtige Stelle.
2. Der Leerzustand der Unterhaltungsliste sagt dasselbe in einem Satz, damit
   es auch der liest, der beim Eintippen der Woerter nicht gelesen hat.

Beides muss **vor** der Bestaetigung stehen, nicht danach: wer glaubt, sein
Verlauf komme mit, loescht das alte Telefon.

---

## 10. Was bricht, wenn man es falsch macht

**Eine Signal-Sitzung ist eine Hashkette:** Wurzelschluessel, Sendekette,
Empfangskette, Zaehler N, Vorrat uebersprungener Schluessel — ein einziger
serialisierter Blob je Adressstring (`signal_store.dart:316-331`).

* Jedes `encrypt` rueckt die Sendekette weiter und erhoeht N.
* Jedes `decrypt` rueckt die Empfangskette weiter und **wirft den benutzten
  Kettenschluessel weg**. Genau das ist Vorwaertsgeheimhaltung.

**Rasten zwei Geraete dieselbe Sitzung weiter**, senden beide eine Nachricht
mit **demselben N** und verschiedenem Klartext. Die Gegenstelle entschluesselt
die erste, loescht den Schluessel und kann den fuer dasselbe N **nie wieder**
ableiten — die zweite Nachricht ist unwiederbringlich Muell. Macht ein Geraet
einen DH-Ratchet-Schritt, ist der Wurzelschluessel des anderen dauerhaft
veraltet.

**Zusammenfuehren ist unmoeglich.** Eine Hashkette ist kein zusammenfuehrbarer
Datentyp; sie hat genau eine gueltige Zukunft. Es gibt keinen Kunstgriff, der
das umgeht — keine Sperre, kein „letzter gewinnt", keine Kopie.

Der Code sagt es schon, nur als Begruendung fuer etwas anderes:
`signal_store_repository.dart:106-110` — „Der Ratchet ist beim Entschluesseln
weitergerueckt; genau diese Nachricht laesst sich danach nie wieder
entschluesseln." Dazu `real_messenger_core.dart:989-993`: der Fortschritt wird
**auch bei Fehlschlag** festgeschrieben.

**Daraus folgt zwingend:** eine Sitzung je **Geraetepaar**, und der Absender
verschluesselt an **jedes** Empfaengergeraet **einzeln**. Nicht als Vorsicht,
sondern weil die Alternative stillen, dauerhaften Nachrichtenverlust
bedeutet.

Zwei weitere Wege in denselben Verlust, die beim Bauen naheliegen:

* **`from_device` weglassen und „einfach beide Sitzungen probieren".** Der
  erste Fehlversuch rueckt den Ratchet und schreibt ihn fest (`:989-993`) —
  der zweite Versuch scheitert dann auch.
* **`empfangen` ohne `recipient_device` filtern.** Geraet A loescht durch
  Raten fortlaufender Kennungen die Post von Geraet B. Kein Fehler, keine
  Spur (§3.4).

---

## 11. Arbeitsreihenfolge

Jeder Schritt ist **allein** abgeschlossen und beweisbar. Zwei Leute koennen
S0/S1 (Relay) und S2 (Client) gleichzeitig anfangen; erst S3 braucht beide.

### S0 — Relay: Datenmodell und Umstellung

Schema, Migration (§8), `device_id` optional mit Standard 1 in
`/register/challenge`, `/register`, `canonical_bytes`, Prekey-Zaehlung je
Geraet.

*Beweis:* `server/test_relay.py` — **die 35 bestehenden Tests bleiben gruen**
(`grep -c "^def test_" server/test_relay.py` → 35), das ist der eigentliche
Rueckwaertsverträglichkeits-Beweis. Neu:
`test_zwei_geraete_teilen_sich_die_adresse_ohne_sich_zu_loeschen` (zwei
`/register` mit verschiedenen `device_id`, danach hat jedes Geraet seine 100
Einmalschluessel und sein eigenes `signed_prekey`),
`test_alte_registrierung_signiert_dieselben_bytes_wie_vorher` (Fixture ohne
`device_id`),
`test_bestehende_datenbank_wird_geraet_eins` (alte Tabellen anlegen, `init_db`
laufen lassen, Zeilen zaehlen und `foreign_key_check` leer erwarten).

### S1 — Relay: Adressierung

`/prekey` mit `geraete[]` und `?nur_geraete=1`, `/ws` mit `device_id` in der
Signatur, `connections` zweistufig, `queue` je Geraet inklusive
`sender_device`, `from_device` beim Zustellen, `empfangen` mit Geraetefilter,
Existenzpruefung je Geraet, Push je Geraet, `/health`.

*Beweis:* pytest je Punkt, vor allem
`test_fremdes_geraet_derselben_adresse_leert_die_schlange_nicht` (die
gefaehrlichste Stelle) und
`test_zwei_geraete_derselben_adresse_verdraengen_sich_nicht` (Gegenstueck zu
`test_verdraengte_verbindung_reisst_die_neue_nicht_mit`, `:1075`).
**Zusaetzlich und wichtiger:** `app/test/net/relay_end_to_end_test.dart` und
`test/net/anhang_end_to_end_test.dart` bleiben mit **unveraendertem** Client
gruen — sie starten den echten `relay_server.py` als Prozess
(`test/support/relay_process.dart:26-52`). Das ist der Punkt, an dem sich
zeigt, ob ein altes Telefon nach dem Relay-Update noch schreiben kann. Bis
hierher ist noch **nichts** am Client geaendert.

### S2 — Client: Kennung fuehren (parallel zu S0/S1 baubar, braucht S0/S1 zum Ausrollen)

`meta`-Zeile `device_id` (§1), Ermittlung bei Erstanlage, `device_id` in
Bundle, `canonicalBytes` und `/ws`-Signatur, Adressierung mit der **eigenen**
echten Kennung. Noch **kein** Fanout: es existiert je Adresse nur ein Geraet,
das Verhalten bleibt gleich.

*Beweis:* `relay_end_to_end_test.dart` und `real_core_test.dart` gruen. Neu:
`test/net/zwei_geraete_test.dart` — zwei `Nutzer` (`test/support/nutzer.dart`)
mit **derselben** Phrase (`core.restoreIdentity(woerter)`,
`messenger_core.dart:82`) und verschiedenem `pfad`, beide melden sich am
echten Relay an, danach zeigt `GET /prekey/<addr>?nur_geraete=1` **zwei**
Geraete und beide Bundles sind vollstaendig. Das ist der Test, der heute
scheitern MUSS und den ganzen Befund belegt.

### S3 — Client: Fanout und Empfangsseite (braucht S1 + S2)

`_sendePayload` als Schleife (§4), Verdichtung des `Wegbescheid`, Geraeteliste
und ihre Auffrischung, `from_device` benutzen in
`real_messenger_core.dart:911`, `deleteSession` bei „Zielgeraet unbekannt".

*Beweis:* **ein** Test traegt den ganzen Schritt:
`test_anna_schreibt_und_beide_geraete_von_bob_haben_es` — Anna (ein Geraet),
Bob als zwei `Nutzer` mit derselben Phrase, echter Relay; Anna sendet eine
Nachricht, `Nutzer.warteBis` prueft, dass sie in **beiden** `eingang`-Listen
liegt. Dieser eine Test beweist Fanout, `from_device`, Sitzung je
Geraetepaar und Warteschlange je Geraet zusammen. Dazu
`test_ein_ausgeschaltetes_zweitgeraet_haelt_die_nachricht_nicht_auf` (Bobs
zweiter Nutzer wird vor dem Senden beendet; Anna sieht trotzdem
`Weg.relay`).

### S4 — Client: Spiegel (braucht S3)

`PayloadKind.spiegel` (8), Feld `c`, Spiegelversand in `_sendePayload`,
Zweig im Verteiler `:925-939`, die drei Stolperfallen aus §5.3.

*Beweis:* `test_was_geraet_a_schreibt_steht_auf_geraet_b` (Bob A schreibt an
Anna, Bob B hat die Nachricht mit `isMine: true` im Chat mit Anna). Dazu als
Regressionsschloss `test_ein_altes_geraet_verwirft_art_acht_sauber`: eine
Nutzlast mit Code 8 durch `Payload.fromBytes` gibt
`PayloadFormatException('unbekannte Art 8')` und keinen Absturz — gilt heute
schon (`payload.dart:185-190`), soll auch morgen gelten. Und
`test_kein_spiegel_an_sich_selbst_erzeugt_eine_kontaktanfrage`.

### S5 — Grenzen, Aufraeumen, Kommentare (unabhaengig von S4)

`GERAETE_MAX`, `GERAET_TTL`, aelteste Zeile verwerfen, `msg_limit_ok`
neu bemessen, Kommentare (§13), Geraetezahl im Einstellungsbildschirm (§6).

*Beweis:* pytest mit `monkeypatch` auf die Konstanten, nach dem Muster
`test_ein_volles_relay_nimmt_keine_neuen_adressen_mehr` (`:1868`):
`test_das_sechste_geraet_wird_abgewiesen`,
`test_ein_totes_geraet_macht_platz`,
`test_bei_voller_geraeteschlange_faellt_die_aelteste_zeile`.

### Was `test/support/relay_process.dart` kann — und was fehlt

Kann: den **echten** `relay_server.py` per `py -3 -m uvicorn` auf einem freien
Port starten, mit eigener `BITDM_DB` im Temp-Verzeichnis, wartet auf
`/health`, gibt `null` zurueck, wenn Python oder die Abhaengigkeiten fehlen
(dann sagt der Test das laut, statt still durchzurutschen), und raeumt am Ende
auf. Einzige heute setzbare Umgebungsvariable ist `BITDM_BLOB_SECRET`
(`:44-47`).

Fehlt fuer S5: ein durchgereichtes `Map<String,String>? umgebung` an
`Process.start`, um `BITDM_GERAETE_MAX` oder `BITDM_QUEUE_MAX` klein zu
setzen. Zwei Zeilen. Alternativ (fauler und ausreichend): S5 nur in pytest
pruefen, wo `monkeypatch` das schon kann.

---

## 12. Offene Fragen

**12.1 X3DH zwischen zwei Geraeten mit demselben Identitaetsschluessel.** Das
ist der einzige Punkt, an dem dieser Entwurf die Literatur verlaesst: bei
Signal hat jedes Geraet seinen **eigenen** Identitaetsschluessel, bei BitDM
teilen die eigenen Geraete ihn. Nachgesehen in libsignal_protocol_dart 0.8.2:
`session_builder.dart:103-155` prueft **nicht**, ob der fremde
Identitaetsschluessel der eigene ist, und `ratcheting_session.dart:56-70`
rechnet `DH(SPK_B, ik_A)`, `DH(IK_B, base_A)`, `DH(SPK_B, base_A)` und
optional `DH(OPK_B, base_A)` — **kein** Selbst-DH der Form `DH(x_pub,
x_priv)`, alle vier Werte bleiben verschieden und geheim. Es rechnet also und
es laeuft. Ob daraus ein Angriff folgt (Reflexion, Unknown-Key-Share), habe
ich **nicht** geprueft und kann es aus dem Code nicht beantworten. Das
gehoert vor S4 geklaert, nicht danach.

**12.2 Auffrischungsfenster 6 Stunden.** Gesetzt, nicht gemessen. Zu kurz
kostet Anfragen (§4: 4 je Kontakt und Tag), zu lang laesst ein neues Geraet
der Gegenstelle lange stumm. Der Wert gehoert in eine Konstante mit Kommentar,
damit er sich nach dem ersten Betrieb aendern laesst.

**12.3 Haken und Lesezustand je Geraet.** Folge davon, dass Quittungen nicht
gespiegelt werden (§5.2). Auf Geraet B steht an einer gespiegelten Nachricht
dauerhaft „gesendet", auch wenn A schon „gelesen" zeigt. Henrik muss sagen, ob
ihn das stoert; die Behebung waere ein Spiegel auch fuer Code 5 und 6 und
kostet Sendevolumen.

**12.4 Geraetezahl ist oeffentlich.** `?nur_geraete=1` braucht keine
Anmeldung, wie `/prekey` heute. Wer eine Adresse kennt, sieht, wie viele
Geraete sie hat. Ob das hinter die angemeldete WebSocket gehoert, ist offen —
mit dem Preis, dass ein Absender dann erst verbinden muss, bevor er
verschluesseln kann.

**12.5 Kein Widerruf.** Steht in §6 als Sicherheitsfolge und ist keine Luecke
in dieser Spezifikation, sondern eine Eigenschaft des Entwurfs „die Adresse
IST der Schluessel". Es gibt keine Loesung, die den Besitz der zwoelf Woerter
entwertet, ohne die Identitaet zu wechseln. Muss so benannt bleiben.

**12.6 Der gleichzeitige Wettlauf um Kennung 1** (§1) ist nicht abgesichert.

---

## 13. Korrekturen an den beiden Erkundungen

Belegt gemessen, nicht vermutet.

**13.1 „Die `registrationId`-Heuristik muss umgedeutet werden" (schwere:
hoch) — sie existiert im Code nicht.** `grep -rn "registrationId" app/lib/`
liefert 18 Fundstellen: Feld, Konstruktor, Bundle-Uebergabe, Meta-Zugriff,
`getLocalRegistrationId`. **Keine** Stelle vergleicht sie oder verwirft
deswegen eine Sitzung. Im Paket selbst
(`grep -rln "registrationId" lib/src/` in
`libsignal_protocol_dart-0.8.2`) taucht sie nur in
`pre_key_signal_message.dart`, `pre_key_bundle.dart`, `session_state.dart` und
dem Protobuf auf — `session_builder.dart` und `session_cipher.dart` fassen sie
**nicht** an. „Letzte Wiederherstellung gewinnt" ist also eine
**dokumentierte Absicht** (`signal_identity.dart:42-48`,
`relay_protocol.dart:51-57`, `relay_server.py:505-512`, PLAN.md §2), die nie
umgesetzt wurde. **Folge:** kein Codeaenderungsbedarf, nur drei Kommentare,
die aufhoeren muessen, eine Wirkung zu behaupten, die es nicht gibt. Aus
„schwere: hoch" wird „Kommentar".

**13.2 Die Pruefnummer muss NICHT angepasst werden.**
`real_messenger_core.dart:1926` benutzt `SignalProtocolAddress(contactId, 1)`,
aber `getIdentity` liest `_state.identities[address.getName()]`
(`signal_store.dart:164-166`) — die Geraetenummer wird verworfen. Dasselbe
gilt fuer `isTrustedIdentity` (`:188-196`) und `saveIdentity` (`:205`).
Identitaeten sind je Adresse gespeichert, Sitzungen je Geraetepaar, und das
ist fuer Mehrgeraete genau die richtige Aufteilung. Die Pruefnummer haengt am
Identitaetsschluessel und aendert sich beim Koppeln eines zweiten Geraets
**nicht**. Zeile 1926 bleibt, wie sie ist.

**13.3 `queue` braucht ZWEI Geraetespalten, nicht eine.** Die Relay-Erkundung
nennt nur `device_id` fuer den Empfaenger. Ohne `sender_device` kann die
Nachzustellung (`:1038-1057`) kein `from_device` setzen — die Zeile weiss
dann nicht mehr, von welchem Geraet sie kam, und der Empfaenger kann sie nicht
zuordnen. Siehe §3.5.

**13.4 `identities` laesst sich NICHT per `ALTER TABLE` umstellen.** Die
Relay-Erkundung schreibt „fuer `device_id` reicht das bei
`identities`/`queue`". Reicht es nicht: `identities` hat
`user_id TEXT PRIMARY KEY` (`:292`), und ein Primaerschluessel ist in SQLite
per `ALTER` nicht erweiterbar — mit dem alten Schluessel liesse sich ein
zweites Geraet gar nicht einfuegen. Neuanlage plus Kopie ist also fuer
**zwei** Tabellen noetig, nicht fuer eine. Siehe §8.

**13.5 Funkweg bleibt Geraet 1, bewusst.** `_nimmBuendelUeberFunk`
(`:868-885`) und `_schickeBuendelUeberFunk` (`:831-865`) bleiben unveraendert.
Der Nahbereich schluesselt ausschliesslich ueber die Kontaktliste (Kommentar
`:771-774`), das eigene Zweitgeraet ist dort kein Kontakt, und in Reichweite
liegen selten beide Geraete der Gegenstelle. `ponytail:`-Kommentar an `:868`:
Grenze benannt, Ausbau erst, wenn jemand zwei Geraete nebeneinander betreibt.

**13.6 Falsche Zahl im Kommentar `relay_server.py:100-101`:** „rund 12,5 GiB"
fuer 200 000 Zeilen à 64 KiB. Nachgerechnet
`py -c "print(200000*65536/1024**3)"` → **12,207 GiB**. 12,5 ist keine
Rundung von 12,2, sondern 2,4 % daneben. Zu **„rund 12,2 GiB"** aendern; die
abgeleiteten Zahlen daneben (31 Konten × 500 = 15 500 Zeilen, `:102-103`)
stimmen.

**13.7 Kommentar `signal_store.dart:356-359`** („Bei BitDM v1 ist die Liste
immer leer, weil es nur ein Geraet je Identitaet gibt") wird mit S3 falsch und
muss mit umgeschrieben werden. Ebenso `prekey_bundle_bridge.dart:57`
(„`deviceId` ist bei BitDM immer 1 — eine Identitaet, ein Geraet").

---

## 14. Messbefehle

Alles hier Behauptete ist so nachgesehen worden:

```
wc -l server/relay_server.py                                  -> 1453
wc -l app/lib/core/real_messenger_core.dart                   -> 2215
wc -l app/test/support/relay_process.dart                     -> 107
grep -rn "SignalProtocolAddress(" app/lib/                    -> 4 Treffer:
        real_messenger_core.dart 870, 911, 1792, 1926 — alle mit ", 1)"
grep -rn "deviceId" app/lib/                                  -> 3, alle in
        prekey_bundle_bridge.dart 57/59/69
grep -rn "registrationId" app/lib/                            -> 18, keine
        Auswertung, kein Vergleich
grep -rln "registrationId" lib/src/  (libsignal 0.8.2)        -> 6 Dateien,
        session_builder.dart und session_cipher.dart NICHT darunter
grep -n "ON CONFLICT\|DELETE FROM one_time_prekeys" server/relay_server.py
grep -n "CREATE TABLE" -A 14 app/lib/core/store/encrypted_database.dart
        -> sessions: address TEXT PRIMARY KEY (308-311)
        -> UNIQUE INDEX idx_messages_eindeutig(chat_id,sender_id,id) (354)
grep -n "INSERT" app/lib/core/store/chat_repository.dart      -> 335:
        INSERT OR IGNORE INTO messages
grep -c "^def test_" server/test_relay.py                     -> 35
py -c "print(200000*65536/1024**3)"                           -> 12.20703125
py -c "print(500*65536/1024**2)"                              -> 31.25
py -c "print(5*500*65536/1024**2)"                            -> 156.25
py -c "print(180*65536/1024**2)"                              -> 11.25
py -c "d=5;print((d-1)*(d-2)/2/2**31)"                        -> 2.79e-09
```

Gelesen (nicht gegriffen): `relay_server.py` 55-205, 285-415, 470-600,
640-820, 900-1180, 1225-1454; `real_messenger_core.dart` 405-475, 860-1010,
1330-1420, 1680-1710, 1770-1870, 1915-1940; `relay_client.dart` 140-300,
370-400; `relay_protocol.dart` 1-200; `payload.dart` 25-275;
`signal_store.dart` 160-215, 350-385; `signal_store_repository.dart` 1-120;
`encrypted_database.dart` 228-405; `main.dart` 2298-2360; `data.dart` 107/389;
`test/support/relay_process.dart`, `test/support/nutzer.dart`;
libsignal 0.8.2 `session_builder.dart`, `ratcheting_session.dart` 32-90.
