# Das Zwischenlager — große Anhänge, wenn niemand online ist

Stand: 25.07.2026. Server steht und ist geprüft; die App-Seite fehlt noch
(Aufgabe 19).

## Wofür es da ist

Der bevorzugte Weg für einen großen Anhang bleibt **direkt von Gerät zu
Gerät**. Aber der funktioniert nur, wenn beide gleichzeitig online sind — und
das ist bei einem Messenger die Ausnahme, nicht die Regel. Das Zwischenlager
ist der Weg für alles andere: der Absender legt ab, der Empfänger holt, wann
immer er das nächste Mal auftaucht.

Nicht über den Relay, und das aus einem sehr konkreten Grund: dessen
Bandbreite ist auf 10 TB im Monat begrenzt, wovon 0,24 TB verbraucht sind. Ein
einziger 3-GB-Anhang kostet dort 6 GB (rein und raus). Der Speicher-VPS hat
50 TB und eine 1-TB-Platte, von der 941 GB frei sind.

## Die Aufteilung

```
  Telefon ──── WebSocket ────► relay.bitdm.net     (Marke ausstellen)
     │
     ├──── PUT ──────────────► dateien.bitdm.net/ablegen/<kennung>
     │                          ↳ nginx ↳ blob_server.py ↳ Platte
     │
     └──── GET ──────────────► dateien.bitdm.net/blob/<kennung>
                                ↳ nginx direkt von der Platte
```

Drei Rechner, drei Aufgaben, und keiner davon kann etwas lesen.

## Die zwei Entscheidungen, an denen alles hängt

### Hochladen braucht eine Erlaubnis, herunterladen nicht

Ohne Erlaubnis zum Hochladen wäre das ein kostenloser Speicher für die ganze
Welt. Die Erlaubnis stellt der **Relay** aus — er weiß beim Verbinden schon,
wem eine Adresse gehört, weil er es per Challenge-Response geprüft hat. Das
Lager ein zweites Mal denselben Nachweis führen zu lassen, wäre eine zweite
Gelegenheit, ihn falsch zu machen.

Beim **Herunterladen ist die Kennung selbst die Erlaubnis**: 32 Byte Zufall,
die nur Absender und Empfänger kennen, weil sie verschlüsselt übertragen
wurden. Wer sie hat, bekommt einen Block, den er ohne den Schlüssel nicht
lesen kann.

### Die Kennung wählt der Client, der Relay unterschreibt sie blind

Der Relay könnte sie genauso gut würfeln. Dann wüsste er aber, welche Datei im
Lager zu welcher Adresse gehört. So weiß er es nicht — und das ist umsonst zu
haben.

## Die Marke

```
marke = HMAC-SHA256(geheimnis, "<kennung>|<groesse>|<ablauf>")
```

Alle drei Teile stehen mit drin, und keiner davon ist Beiwerk:

| Teil | Was ohne ihn passiert |
|---|---|
| `kennung` | Eine Marke ließe sich beliebig oft für neue Dateien benutzen |
| `groesse` | Marke für 1 MB holen, 3 GB ablegen |
| `ablauf` | Die Frist ließe sich in der Kopfzeile nachträglich verschieben |

Das Geheimnis (48 Zufallsbytes, base64) liegt auf beiden Rechnern in
`/etc/bitdm/blob.secret` und geht über `EnvironmentFile` an die Dienste —
systemd liest es als root, bevor es die Rechte abgibt. Keiner der beiden
Dienste darf `/etc/bitdm` selbst betreten.

**Beim Tauschen des Geheimnisses müssen beide Seiten neu starten.** Passiert es
nur auf einer, scheitern ab dann alle Uploads mit 403 — und nichts anderes
fällt aus. `durchstich_zwischenlager.py` ist genau dafür da.

## Die Grenzen

| Was | Wert | Wo |
|---|---|---|
| Größte Datei | 3 GiB | `BITDM_BLOB_MAX`, beidseitig |
| Tagesmenge je Adresse | 10 GiB | `BITDM_BLOB_QUOTA`, Relay |
| Gültigkeit einer Marke | 12 h | `BITDM_BLOB_MARKE_TTL`, Relay |
| Aufbewahrung | 14 Tage | `BITDM_BLOB_TTL`, Kehrmaschine |
| Bruchstücke | 1 Tag | `BITDM_BLOB_TEIL_TTL`, Kehrmaschine |
| Mindestens frei | 50 GiB | `BITDM_BLOB_MIN_FREE`, Lager |

**Die Tagesmenge ist die eigentliche Verteidigung, nicht die Marke.** Die Marke
hält Fremde draußen — aber eine Adresse anzulegen kostet nichts als ein
Schlüsselpaar. Ohne Mengengrenze könnte sich jemand ein paar Adressen machen
und die Platte in einer Nacht füllen. Sie gilt **je Adresse**; eine globale
Grenze wäre aus einer Mengengrenze eine Abschaltung geworden.

Gezählt wird beim **Ausstellen**, nicht beim Hochladen — der Relay erfährt nie,
ob wirklich hochgeladen wurde. Wer sich Marken holt und verfallen lässt,
verbraucht sein eigenes Kontingent. Das ist die richtige Richtung für den
Irrtum.

## Warum nginx herunterlädt und nicht der Dienst

Ein 3-GB-Download durch Python zu schleifen kostet Speicher und einen Prozess,
der eine Viertelstunde beschäftigt ist. nginx tut es aus dem Kern heraus und
kann **Bereichs-Anfragen** von sich aus — damit kann ein Client nach einem
Funkloch dort weitermachen, wo er war. Bei drei Gigabyte ist das kein Luxus,
sondern die Bedingung dafür, dass es jemals ankommt.

Deshalb haben Hoch- und Herunterladen **verschiedene Pfade**. Ein gemeinsamer
wäre handlicher, aber nginx müsste dann innerhalb einer Location nach Methode
verzweigen — und das geht nur über `if`, die bekannteste Fußangel in nginx.

```
PUT    /ablegen/{kennung}     → Dienst   (braucht Marke)
DELETE /wegwerfen/{kennung}   → Dienst   (braucht nichts)
GET    /blob/{kennung}        → nginx    (braucht nichts)
alles andere                  → 404
```

`proxy_request_buffering off` ist dabei der wichtigste Schalter. Ohne ihn
schreibt nginx die ganzen drei Gigabyte erst nach `/var/lib/nginx/body` — auf
die 49-GB-Systemplatte, nicht auf die große — und fängt danach erst an,
weiterzureichen. **Gemessen am 25.07.2026:** bei einem 1-GB-Upload blieb das
Verzeichnis durchgehend leer, während die Nebendatei im Lager stetig wuchs.

## Was gemessen wurde

Zwischen Haupt- und Speicher-VPS, 1 GiB:

| | Zeit | Rate |
|---|---|---|
| Hochladen (durch nginx + Dienst) | 15,8 s | 68 MB/s |
| Herunterladen (nginx direkt) | 11,2 s | 96 MB/s |

Hochgerechnet sind 3 GiB knapp 50 Sekunden zwischen den Servern. Vom Telefon
aus entscheidet die Mobilfunkstrecke, nicht der Server.

**Wer hochlädt, muss strömen.** `curl --data-binary @datei` liest die Datei
erst vollständig in den Arbeitsspeicher und bricht bei 1 GB mit „out of
memory" ab; `curl -T` strömt. Derselbe Fehler wartet auf der App-Seite.

## Offen für die App-Seite (Aufgabe 19)

**Ein Upload ist nicht fortsetzbar.** Bricht er bei 80 % ab, fängt er von vorn
an — `PUT` ist ganz oder gar nicht. Bei 3 GB auf Mobilfunk ist das keine
theoretische Sorge.

Der Ausweg ist, die Datei in der App in **Stücke von 32–64 MB** zu zerlegen,
jedes als eigener Block mit eigener Kennung und eigenem Schlüssel. Dann kostet
ein Abbruch ein Stück statt der ganzen Datei, mehrere Stücke können
gleichzeitig laufen, und das Fortsetzen fällt nebenbei ab. Der Relay stellt
schon heute so viele Marken aus, wie gefragt werden — 3 GB in 64-MB-Stücken
sind 48 Anfragen über eine bestehende Verbindung.

## Betrieb

```bash
# Läuft alles?
ssh -i /root/.ssh/storage_transfer root@5.231.234.142 \
  'systemctl is-active bitdm-blob; curl -sS http://127.0.0.1:8081/health'
```

```bash
# Das Lager selbst prüfen (auf dem Haupt-VPS)
bash /opt/bitdm/secure-messenger/server/abnahme_zwischenlager.sh
```

```bash
# Die ganze Kette prüfen, inklusive Relay und Marke (auf dem Haupt-VPS)
/opt/bitdm-relay/venv/bin/python /opt/bitdm/secure-messenger/server/durchstich_zwischenlager.py
```

Die Kehrmaschine läuft täglich um 04:17 (± 30 min) als
`bitdm-blob-kehr.timer`. Sie meldet, was sie weggeräumt hat, und **lässt alles
liegen, was sie nicht kennt** — ein Aufräumer, der alles löscht, was er nicht
kennt, ist eine Waffe, die auf das eigene Verzeichnis zeigt.

## Was der Server sieht und was nicht

| | Relay | Lager |
|---|---|---|
| Inhalt | nein (verschlüsselt) | nein (verschlüsselt) |
| Schlüssel | nein (reist als Nachricht) | nein |
| Kennung | **nein** (blind unterschrieben) | ja |
| Wer ablegt | ja | nein |
| Wie groß, wann | ja | ja |

Die Kennung steht bewusst **nicht** in der Marken-Tabelle des Relays. Sie wäre
die Verbindung zwischen einer Adresse und einer bestimmten Datei — und genau
die soll er nicht haben. Für eine Mengenrechnung reicht, wie viel wann. Die
Zeilen fallen nach 24 Stunden weg; ein Protokoll, das länger lebt, als es
gebraucht wird, ist ein Protokoll.
