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

Der Relay ist ein reiner Server. Nach draussen ruft er niemanden an: kein
Update, kein Webhook, keine Telemetrie. Genau eine ausgehende Verbindung gibt
es, und die verlaesst diese Maschine nicht — der UnifiedPush-Anstoss geht ueber
127.0.0.1 an den Push-Server, der hier ohnehin laeuft. Alles andere bleibt
verboten.

Wer diesen Dienst uebernimmt, sitzt damit in einem Raum ohne Tuer nach
draussen — er kann keinen Schadcode nachladen, keinen Miner-Pool erreichen und
nichts abfliessen lassen. Am 12.07.2026 wurde auf genau dieser Maschine ein
Dienst gekapert und lud einen Kryptominer nach. Mit dieser Zeile waere daraus
nichts geworden.

Der naheliegende andere Weg waere gewesen, die oeffentliche IP von
`push.bitdm.net` freizugeben. Sie zeigt auf genau diesen Rechner — es waere
also eine echte Tuer nach draussen gewesen, um ins Nachbarzimmer zu kommen,
und sie haette nicht einen Pfad geoeffnet, sondern alle Ports dieser IP.

Nachpruefbar:

```bash
systemd-run --property=User=bitdm-relay \
  --property=IPAddressDeny=any --property=IPAddressAllow=localhost \
  --pipe --wait /usr/bin/curl -s --max-time 5 https://api.ipify.org
# muss fehlschlagen

# Und der Anstoss geht trotzdem raus — auf dieser Maschine, ueber das
# Loopback. Diese Zeile muss LEER bleiben:
journalctl -u bitdm-relay --since -24h | grep 'Anstoss geht nicht raus'
```

Das Ziel des Anstosses steht in der Unit, nicht im Quelltext:
`Environment=BITDM_PUSH_TARGET=http://127.0.0.1:<port>`. `install-relay.sh`
setzt die Zeile nur, wenn beim Aufruf `BITDM_PUSH_TARGET=...` mitgegeben wird —
den Loopback-Port des Push-Servers muss man nachsehen (`ss -tlnp | grep -i
ntfy`), nicht raten. Ohne die Zeile bleibt der Anstoss aus; still tut er es
seit dem 26.07.2026 nicht mehr.

## Was NICHT protokolliert wird, und warum

`access_log off` im vHost und `--no-access-log` bei uvicorn. Beides ist
entschieden, nicht vergessen.

Der Pfad `/prekey/<adresse>` enthaelt die Adresse des **Gespraechspartners**.
Ein Zugriffsprotokoll waere damit eine fortlaufende Liste, wer wann mit wem
Kontakt aufgenommen hat — bei einem Messenger, dessen ganzer Zweck das
Vermeiden solcher Aufzeichnungen ist. Ende-zu-Ende-Verschluesselung schuetzt
den Inhalt, nicht die Tatsache des Kontakts.

Das Fehlerprotokoll steht seit 25.09.2026 auf **`crit`** statt `warn`. Auf
Stufe `error` schreibt nginx bei jedem Fehler des Upstreams (502/504, z. B.
waehrend eines Neustarts) und bei jeder Abweisung durch `limit_req` die
Client-IP **und** die Anfragezeile mit — bei `/prekey/<adresse>` also genau
die Liste "wer fragte wann nach wem", die `access_log off` verhindern soll.
Zum Fehlersuchen voruebergehend auf `warn` stellen und das Protokoll danach
loeschen. nginx' eigene 502/504 gehen als JSON an den Client
(`{"detail":"Relay voruebergehend nicht erreichbar"}`, Status 503).

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

**IPv6 zaehlt je /64** (seit 25.09.2026), in nginx (`map $remote_addr
$bitdm_limit_key`) wie im Relay (`limit_schluessel`). Ein Anschluss bekommt
mindestens ein /64, und jede Adresse darin ist frei waehlbar — je voller
Adresse gezaehlt war jedes Limit fuer IPv6 praktisch abgeschaltet. Die Zonen
heissen deshalb jetzt `bitdm_relay_req64`/`bitdm_relay_conn64`: nginx
verweigert beim reload eine bestehende Zone mit geaendertem Schluessel, und
`nginx -t` merkt das nicht vorher.

**Ueber Tor gibt es keine Bremse je IP** — dort kommen alle von 127.0.0.1, und
eine Bremse je IP waere eine einzige fuer alle Tor-Nutzer. Stattdessen:
Grenzen in tor und im Onion-vHost, siehe `onion/README.md`. Der Onion-vHost
kennzeichnet seine Anfragen mit `X-BitDM-Onion: 1`; dieser vHost setzt die
Kopfzeile ausdruecklich leer.

## Grenzen im Relay (Umgebungsvariablen)

Alle mit Vorgabe; ueberschreiben per `Environment=` in der Unit
(`systemctl edit bitdm-relay`). Die Begruendungen stehen am jeweiligen Wert in
`relay_server.py`.

| Variable | Vorgabe | Was |
|---|---|---|
| `BITDM_QUEUE_MAX` | 500 | Zeilen je Zielgeraet |
| `BITDM_QUEUE_MAX_PAIR` | 100 | Zeilen je Absender **je Zielgeraet**; darueber faellt seine eigene aelteste |
| `BITDM_QUEUE_MAX_SENDER` | 2000 | Zeilen je Absender insgesamt; darueber "Warteschlange voll" |
| `BITDM_QUEUE_MAX_TOTAL` | 200 000 | ganze Tabelle; am Dach weicht der schwerste Absender |
| `BITDM_NONCE_SLOTS` | 8 | offene Challenge-Nonces je (Adresse, Geraet) |
| `BITDM_MEM_ENTRIES_MAX` | 200 000 | Dach fuer Nonces und Eimer im Arbeitsspeicher; darueber 503 |
| `BITDM_MEM_PRUNE_AT` | 50 000 | ab dieser Groesse wird zusaetzlich (max. 1x/s) aufgeraeumt; sonst alle 60 s |
| `BITDM_WS_AUTH_TIMEOUT` | 10 | Sekunden fuer die Antwort auf die Challenge (frueher 30) |
| `BITDM_WS_PREAUTH_MAX` | 1000 | gleichzeitig nicht angemeldete WebSockets; darueber Close 1013 |
| `BITDM_FRAME_BURST` / `BITDM_FRAME_REFILL` | 1000 / 50 pro s | Rahmen je Verbindung, jede Art; darueber Close 4429 |
| `BITDM_LIVE_BURST` / `BITDM_LIVE_REFILL` | 600 / 20 pro s | Live-Durchreichen an alte Clients (ohne Empfangsnachweis), je Absender |
| `BITDM_BLOB_MAX` | 33 MiB | groesstes Stueck je Marke — **muss zu `bitdm-blob` passen** |
| `BITDM_BLOB_QUOTA` | 25 GiB | Marken je Adresse und Tag |
| `BITDM_BLOB_QUOTA_TOTAL` | 200 GiB | Marken des ganzen Relays je Tag |

**`LimitNOFILE` hochsetzen.** Jede WebSocket ist ein Dateideskriptor. Mit dem
Vorraum-Deckel (1000) plus den angemeldeten Verbindungen reichen die frueheren
4096 nicht mehr sicher; am Deckel scheitert sonst `accept()` fuer alle, statt
dass der Relay selbst ordentlich abweist. `install-relay.sh` setzt jetzt 16384.

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

### Aenderung vom 25.09.2026 (Audit) aufspielen — Haupt-VPS

`install-relay.sh` NICHT erneut laufen lassen: es schreibt die Unit neu und
nimmt dabei alles mit, was dort von Hand dazugekommen ist (z. B. das
`EnvironmentFile` mit dem Blob-Geheimnis oder `BITDM_PUSH_TARGET`). Stattdessen
gezielt:

```bash
cd /opt/bitdm && git pull
D=/opt/bitdm/secure-messenger/deploy
V=/etc/nginx/sites-available/relay.bitdm.net
STAMP=$(date +%F-%H%M)
cp -a /etc/nginx/conf.d/bitdm-relay-limits.conf{,.$STAMP}
cp -a /etc/nginx/snippets/bitdm-relay-proxy.conf{,.$STAMP}
cp -a "$V" "$V.$STAMP"
cp -a /etc/nginx/sites-available/relay-onion{,.$STAMP}

# 1. Zonen (IPv6 je /64, neue Namen) und Proxy-Schnipsel (leert X-BitDM-Onion)
#    direkt aus install-relay.sh ziehen:
sed -n "/<<'LIM'\$/,/^LIM\$/p"   $D/install-relay.sh | sed '1d;$d' > /etc/nginx/conf.d/bitdm-relay-limits.conf
sed -n "/<<'SNIP'\$/,/^SNIP\$/p" $D/install-relay.sh | sed '1d;$d' > /etc/nginx/snippets/bitdm-relay-proxy.conf

# 2. Den bestehenden vHost nachziehen (neue Zonennamen, error_log crit,
#    X-BitDM-Onion in /ws leeren, JSON fuer 502/504):
sed -i \
 -e 's/zone=bitdm_relay_req burst=/zone=bitdm_relay_req64 burst=/g' \
 -e 's/limit_conn bitdm_relay_conn 128;/limit_conn bitdm_relay_conn64 128;/' \
 -e 's#\(error_log  */var/log/nginx/[^ ]*\.error\.log\) warn;#\1 crit;#' \
 -e '/location = \/ws {/,/}/ s/^\( *\)proxy_set_header X-Forwarded-Proto \$scheme;$/&\n\1proxy_set_header X-BitDM-Onion     "";/' \
 -e '/return 429 .{"detail":"zu viele Anfragen"}.;/{n;s/^    }$/    }\n    error_page 502 504 = @relay_weg;\n    location @relay_weg {\n        default_type application\/json;\n        return 503 '"'"'{"detail":"Relay voruebergehend nicht erreichbar"}'"'"';\n    }/}' \
 "$V"
grep -n 'bitdm_relay_req64\|bitdm_relay_conn64\|crit;\|X-BitDM-Onion\|relay_weg' "$V"   # 4x req64, 1x conn64, crit, Onion, relay_weg

# 3. Onion-vHost und tor: siehe onion/README.md, "Aufspielen der Aenderung".
cp $D/onion/relay-onion.nginx /etc/nginx/sites-available/relay-onion

# 4. Mehr Dateideskriptoren fuer den Relay, ohne die Unit neu zu schreiben:
mkdir -p /etc/systemd/system/bitdm-relay.service.d
printf '[Service]\nLimitNOFILE=16384\n' > /etc/systemd/system/bitdm-relay.service.d/nofile.conf
systemctl daemon-reload

# 5. Stand ein BITDM_BLOB_MAX von frueher in der Unit, gilt die neue
#    Stueckgrenze (33 MiB) nicht — dann entfernen (auch auf dem Storage-VPS):
systemctl cat bitdm-relay | grep -n BITDM_BLOB_MAX

nginx -t && systemctl reload nginx
systemctl restart bitdm-relay     # legt beim Start die neuen Indizes an
journalctl -u bitdm-relay -n 20 --no-pager
curl -s -o /dev/null -w '%{http_code}\n' https://relay.bitdm.net/health   # 403
```

**Datenbank:** keine Handarbeit. Beim ersten Start legt `init_db` die Indizes
`idx_queue_paar (recipient, recipient_device, sender)`, `idx_queue_absender
(sender)` und `idx_blob_marken_ts (ts)` an und wirft danach den nun
ueberfluessigen `idx_queue_empfaenger` weg — `CREATE INDEX IF NOT EXISTS`,
also bei jedem weiteren Start ein Nichts. Bei einigen tausend Zeilen dauert es
Millisekunden. Zurueck auf die alte Fassung geht ohne Weiteres: sie legt
`idx_queue_empfaenger` beim Start wieder an und stoert sich an den neuen nicht.

Der Dienst laeuft direkt aus dem Git-Verzeichnis, das ihm gehoert **nicht** —
er kann seinen eigenen Code nicht veraendern. Das ist Absicht.
