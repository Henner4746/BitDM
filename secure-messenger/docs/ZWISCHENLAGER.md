# Das Zwischenlager — große Anhänge, wenn niemand online ist

Stand: 25.07.2026, Grenzen und Sichtbarkeit korrigiert am 25.09.2026 (Audit).
Server steht und ist geprüft.

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

### Die Kennung wählt der Client — der Relay sieht sie, speichert sie aber nicht

Bis zum 25.09.2026 stand hier „der Relay unterschreibt sie blind“. Das stimmte
nie: die Kennung steht im Klartext im `blob_marke`-Rahmen, und der Relay muss
sie in die Marke rechnen. Was stimmt: er **schreibt sie nirgends hin** — die
Marken-Tabelle hat keine Spalte dafür, und protokolliert wird sie auch nicht.
Wer den laufenden Relay-Prozess beobachten kann (also wer den Server
übernommen hat), sieht die Verbindung Adresse → Kennung trotzdem.

Würfelte der Relay die Kennung selbst, wüsste er sie auf jeden Fall und müsste
sie zurückschicken. Der Unterschied ist also nur, dass nichts davon liegen
bleibt — das ist wenig, aber umsonst zu haben.

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
| Größtes **Stück** je Marke/PUT | 33 MiB | `BITDM_BLOB_MAX`, beidseitig (Relay **und** Lager) |
| Größte Datei | 5 GiB | nur in der App (`AnhangVersand.hoechstGroesse`), 160 Stücke zu 32 MiB |
| Tagesmenge je Adresse | 25 GiB | `BITDM_BLOB_QUOTA`, Relay |
| Tagesmenge des ganzen Relays | 200 GiB | `BITDM_BLOB_QUOTA_TOTAL`, Relay |
| Gültigkeit einer Marke | 12 h, **einmal** benutzbar | `BITDM_BLOB_MARKE_TTL`, Relay |
| Aufbewahrung | 14 Tage | `BITDM_BLOB_TTL`, Kehrmaschine |
| Bruchstücke | 1 Tag | `BITDM_BLOB_TEIL_TTL`, Kehrmaschine |
| Mindestens frei | 50 GiB (inkl. laufender Uploads) | `BITDM_BLOB_MIN_FREE`, Lager |

**Die Grenze gilt je Stück, nicht je Datei** (seit 25.09.2026). Eine Marke
erlaubt genau ein Stück; die App zerlegt jede Datei in Stücke zu 32 MiB und
holt je Stück eine Marke. Bis dahin stand `BITDM_BLOB_MAX` auf 5 GiB — die
Dateigrenze der App, an der falschen Stelle: ein einzelner PUT durfte 5 GiB
am Stück schreiben. 33 MiB lassen ein MiB Luft über dem echten Stück
(32 MiB + 16 Byte GCM-Anhang). **Steht in einer der beiden Units noch ein
`BITDM_BLOB_MAX=…` von früher, gilt der alte Wert weiter** — dann dort
entfernen, auf beiden Seiten.

**Eine Marke gilt genau einmal.** Früher ließ sie sich wiederverwenden:
ablegen, löschen (braucht keine Marke), mit derselben Marke noch einmal
ablegen — zwölf Stunden lang. Das Lager merkt sich jetzt jede benutzte Marke
bis zu ihrem Ablauf und antwortet danach mit 409. Grenze: die Liste lebt im
Arbeitsspeicher; nach einem Neustart des Lagers ist eine Marke, deren Datei
schon wieder gelöscht war, bis zu ihrem Ablauf noch einmal benutzbar.

**Gleichzeitige Uploads unterschreiten den Mindestplatz nicht mehr.** Jeder
Upload reserviert seine angesagte Größe, bevor er anfängt, und zwei PUTs
derselben Kennung schreiben in getrennte Nebendateien — der zweite bekommt
409, statt die Datei des ersten zu überschreiben.

**Die Tagesmenge ist die eigentliche Verteidigung, nicht die Marke.** Die Marke
hält Fremde draußen — aber eine Adresse anzulegen kostet nichts als ein
Schlüsselpaar. Ohne Mengengrenze könnte sich jemand ein paar Adressen machen
und die Platte in einer Nacht füllen.

Sie gilt **je Adresse** (25 GiB) — und seit 25.09.2026 zusätzlich für den
**ganzen Relay** (200 GiB). Die zweite Grenze ist, was hier früher abgelehnt
wurde: eine globale Grenze macht aus einer Mengengrenze eine Abschaltung für
alle, sobald jemand sie ausschöpft. Ohne sie reichten aber vierzig Adressen für
1 TiB am Tag, und die Platte (rund 940 GB frei) wäre in einer Nacht voll — dann
weist das Lager mit 507 ab, ebenfalls für alle, und zwar bis die Kehrmaschine
aufräumt. Deshalb steht sie hoch: 200 GiB am Tag lassen der Platte mindestens
vier Tage, und der Storage-Waechter meldet schon bei 80 GB frei. Wer sie
erreicht, bekommt `Zwischenlager fuer heute ausgelastet` statt
`Tagesmenge erschoepft`.

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

## Die App-Seite

`app/lib/core/anhang/` — gebaut und geprüft, aber **noch nicht an den Chat
angeschlossen** (siehe unten).

| Datei | Wofür |
|---|---|
| `rezept.dart` | Die Anleitung: wo die Stücke liegen, womit sie aufgehen |
| `stueck_krypto.dart` | Ein Stück ver-/entschlüsseln (AES-256-GCM) |
| `lager_client.dart` | PUT/GET/DELETE, strömend, mit Bereichs-Anfragen |
| `anhang_versand.dart` | Zerlegen, verschlüsseln, Marken holen, ablegen |
| `anhang_empfang.dart` | Holen, entschlüsseln, zusammensetzen, prüfen |

**Stückgröße 32 MiB** (bis 26.07.2026 16 MiB). Nach unten begrenzt, weil die
Anleitung in einen 64-KiB-Umschlag passen muss; nach oben, weil ein Stück beim
Verschlüsseln im Arbeitsspeicher liegt und ein Abbruch verlorene Übertragung
ist. Bei 32 MiB braucht die größte erlaubte Datei (5 GiB) 160 Stücke — das
passt in die 256, die eine Anleitung fassen darf, und kostet rund 21 KB.

**Je Stück ein eigener Zufallsschlüssel.** Nicht aus Übervorsicht: AES-GCM ist
*gebrochen*, sobald ein Schlüssel zweimal mit demselben Nonce benutzt wird —
der Schlüssel lässt sich dann aus zwei solchen Blöcken herausrechnen. Bei einem
Schlüssel für die ganze Datei müsste ein Zähler über alle Stücke sauber geführt
werden, über Abbrüche und Wiederaufnahmen hinweg. Bei einem Schlüssel je Stück
gibt es nichts zu zählen. Preis: 44 Zeichen je Stück in der Anleitung.

**Die Stücknummer steckt im beglaubigten Zusatz.** Fälschen kann das Lager
nichts. Aber es könnte *vertauschen*: unter der Kennung von Stück 3 die Bytes
von Stück 5 ausliefern. Jedes Stück für sich würde sauber entschlüsseln, und
die zusammengesetzte Datei wäre still falsch. Mit Nummer und Gesamtzahl im AAD
geht ein vertauschtes Stück gar nicht mehr auf.

**Die Adressen kommen nicht vom Relay.** Er schickt fertige URLs mit; sie
werden ignoriert. Der Client kennt die Kennung — er hat sie selbst gewürfelt —
und seinen Lagerplatz aus der eigenen Einstellung. Sonst könnte ein
übernommener Relay die Uploads auf einen fremden Rechner umlenken.

**Verschlüsseln und Hochladen laufen ineinander.** Die reine
Dart-Umsetzung von AES-GCM schafft ~12 MB/s (gemessen: 8 MiB in 662 ms).
Nacheinander wäre die Gesamtzeit die *Summe*; verschränkt ist sie das
*Maximum* — und über jede Mobilfunkstrecke ist das Senden ohnehin langsamer.
`webcrypto` (BoringSSL) wäre schneller, wurde probeweise aufgenommen und wieder
entfernt: `flutter test` braucht dafür `pub run webcrypto:setup` und damit
cmake. Die Verschlüsselung sitzt hinter einer schmalen Schnittstelle und lässt
sich tauschen, wenn eine Messung auf echten Geräten es rechtfertigt.

### Was noch fehlt

Der Weg ist vollständig, aber der Chat weiß noch nichts davon:

- **Verlauf**: ein empfangener Anhang landet nirgends. `real_messenger_core.dart`
  kennt `PayloadKind.anhang` und tut nichts damit — ausdrücklich aufgeführt und
  nicht über einen `default`-Fall abgeräumt, damit der Analyzer die Stelle
  meldet.
- **Oberfläche**: Datei auswählen, Fortschritt, empfangene Datei öffnen.
- **Android**: Dateiauswahl über SAF, und der Vordergrunddienst muss den
  Versand am Leben halten, wenn die App in den Hintergrund geht.

## Betrieb

```bash
# Läuft alles?
ssh -i ~/.ssh/<dein-schlüssel> root@dateien.bitdm.net \
  'systemctl is-active bitdm-blob; curl -sS http://127.0.0.1:8081/health'
```

```bash
# Aktualisieren (Storage-VPS). Dienst und Kehrmaschine laufen aus /opt/bitdm-blob.
# VORHER: steht in der Unit ein BITDM_BLOB_MAX von früher, gilt die neue
# Stückgrenze (33 MiB) nicht — die Zeile entfernen, auf dem Relay ebenso.
systemctl cat bitdm-blob | grep -n BITDM_BLOB_MAX
# blob_server.py und blob_kehrmaschine.py aus dem Repo nach /opt/bitdm-blob kopieren, dann:
systemctl restart bitdm-blob
curl -sS http://127.0.0.1:8081/health
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
| Kennung | **ja, im Rahmen** — aber nicht gespeichert | ja |
| Wer ablegt | ja | nein |
| Wie groß, wann | ja | ja |

Die Kennung steht bewusst **nicht** in der Marken-Tabelle des Relays. Sie wäre
die Verbindung zwischen einer Adresse und einer bestimmten Datei — und genau
die soll er nicht aufbewahren. Sehen muss er sie, um die Marke zu rechnen
(siehe oben). Für eine Mengenrechnung reicht, wie viel wann. Die
Zeilen fallen nach 24 Stunden weg; ein Protokoll, das länger lebt, als es
gebraucht wird, ist ein Protokoll.
