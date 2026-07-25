# Relay auf einem Server betreiben

Stand: 25.07.2026, laeuft auf `relay.bitdm.net`.

`install-relay.sh` richtet alles ein und laesst sich gefahrlos wiederholen.
Diese Datei erklaert, WARUM es so eingerichtet ist — die Entscheidungen sind
wichtiger als die Befehle.

## Die eine Zeile, auf die es ankommt

```
IPAddressDeny=any
IPAddressAllow=localhost
```

Der Relay ist ein reiner Server. Er ruft von sich aus niemanden an: kein
Update, kein Webhook, keine Telemetrie. Also darf man ihm jede ausgehende
Verbindung verbieten.

Wer diesen Dienst uebernimmt, sitzt damit in einem Raum ohne Tuer nach
draussen — er kann keinen Schadcode nachladen, keinen Miner-Pool erreichen und
nichts abfliessen lassen. Am 12.07.2026 wurde auf genau dieser Maschine ein
Dienst gekapert und lud einen Kryptominer nach. Mit dieser Zeile waere daraus
nichts geworden.

Nachpruefbar:

```bash
systemd-run --property=User=bitdm-relay \
  --property=IPAddressDeny=any --property=IPAddressAllow=localhost \
  --pipe --wait /usr/bin/curl -s --max-time 5 https://api.ipify.org
# muss fehlschlagen
```

## Was NICHT protokolliert wird, und warum

`access_log off` im vHost und `--no-access-log` bei uvicorn. Beides ist
entschieden, nicht vergessen.

Der Pfad `/prekey/<adresse>` enthaelt die Adresse des **Gespraechspartners**.
Ein Zugriffsprotokoll waere damit eine fortlaufende Liste, wer wann mit wem
Kontakt aufgenommen hat — bei einem Messenger, dessen ganzer Zweck das
Vermeiden solcher Aufzeichnungen ist. Ende-zu-Ende-Verschluesselung schuetzt
den Inhalt, nicht die Tatsache des Kontakts.

Fehler landen weiterhin im Fehlerprotokoll, aber erst ab `warn`.

## Graue Wolke in Cloudflare — nicht verhandelbar

`relay.bitdm.net` muss in Cloudflare **nur DNS** sein, kein Proxy.

Mit oranger Wolke saehe Cloudflare zu jeder Verbindung, wer wann online ist und
mit wem er spricht. Diese Angabe an einen Dritten zu geben waere ein
Selbstwiderspruch zur ganzen App. `bitdm.net` (die Website) darf orange
bleiben — dort gibt es nichts zu verraten.

Pruefen:

```bash
dig +short relay.bitdm.net A    # muss die Server-IP sein, nicht 104.x/172.67.x
```

## Warum die nginx-Ratenbegrenzung so weit ist

Der erste Anlauf stand bei 20 Anfragen je Sekunde. Ein Testlauf gegen die echte
Instanz zeigte: 8 von 40 Anfragen wurden mit 503 abgewiesen. Falsch, aus zwei
Gruenden.

**Es hebelt die bessere Logik im Relay aus.** Bei einem Versuch, den Vorrat an
Einmalschluesseln leerzuraeumen, weist der Relay nicht ab — er liefert das
Bundle *ohne* Einmalschluessel. Ein echter Kontakt kann weiterhin eine Sitzung
aufbauen, der Angriff laeuft ins Leere. Ein hartes nginx-Limit davor macht
daraus wieder einen Totalausfall.

**Es trifft die Falschen.** Mobilfunkanbieter setzen Carrier-Grade-NAT ein:
hinter einer IP haengen tausende Kunden. Eine enge Grenze je IP sperrt im
Zweifel ein ganzes Mobilfunknetz aus, und die Betroffenen sehen nur, dass "die
App nicht geht".

Die eigentliche Verteidigung sitzt im Relay und greift je **Zieladresse** statt
je Herkunft — das wirkt auch, wenn der Angreifer die IP wechselt. nginx ist nur
noch ein grobes Netz gegen rohe Fluten.

## Das Backup laesst den Relay bewusst aus

`/var/lib/bitdm-relay` steht in `/etc/vps-backup/excludes.txt`.

Der Relay loescht Umschlaege nach 14 Tagen selbst. Eine Sicherung wuerde genau
das aufbewahren, was er nach seiner eigenen Regel vergessen soll: wer wann mit
wem Kontakt hatte. Die Umschlaege sind zwar verschluesselt, aber Absender,
Empfaenger und Zeitstempel stehen im Klartext daneben.

Geht die Datei verloren, melden sich die Clients beim naechsten Verbinden neu
an; nur noch nicht zugestellte Nachrichten sind weg. Der Relay ist als
wegwerfbar entworfen.

## Fallstricke dieses Servers

- **nginx 1.18**: `http2 on;` gibt es erst ab 1.25. Hier gilt die alte
  Schreibweise `listen 443 ssl http2;`. Das ist schon einmal fehlgeschlagen.
- **`add_header` in einem `location`-Block loescht alle geerbten Header.**
  Entweder komplett wiederholen oder gar nicht im location-Block setzen.
- **certbot lud nginx nicht neu.** Vor dem 25.07.2026 gab es keinen
  Deploy-Hook — nach jeder Erneuerung haette nginx weiter das alte Zertifikat
  ausgeliefert, fuer *alle* 20 Domains. `reload-nginx.sh` behebt das.

## Pruefen, ob alles steht

```bash
# gegen die echte Instanz, ueber nginx, TLS und WebSocket
cd /opt/bitdm/secure-messenger/server
BITDM_TEST_BASE=https://relay.bitdm.net /opt/bitdm-relay/venv/bin/python test_relay.py
```

Ein Lauf gegen `127.0.0.1` laesst die halbe Kette aus. Genau dort sitzen die
Fehler, die man beim Deployen macht.

```bash
systemd-analyze security bitdm-relay        # Stand 25.07.2026: 0.9 SAFE
curl -o /dev/null -w '%{http_code}\n' https://relay.bitdm.net/health   # 403
ss -tlnp '( sport = :8465 )'                # nur 127.0.0.1
ufw status | grep 8465                      # muss LEER sein
```

## Aktualisieren

```bash
cd /opt/bitdm && git pull
systemctl restart bitdm-relay
```

Der Dienst laeuft direkt aus dem Git-Verzeichnis, das ihm gehoert **nicht** —
er kann seinen eigenen Code nicht veraendern. Das ist Absicht.
