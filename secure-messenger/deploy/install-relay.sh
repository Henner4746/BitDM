#!/usr/bin/env bash
# install-relay.sh — richtet den BitDM-Relay auf einem Debian/Ubuntu-Server ein.
#
# Laesst sich gefahrlos wiederholen. Aendert nichts an bestehenden Diensten und
# oeffnet KEINEN neuen Port nach aussen.
#
# Die Begruendungen zu den Entscheidungen stehen in README.md — sie sind
# wichtiger als die Befehle hier.
#
#   sudo ./install-relay.sh relay.bitdm.net deine@mail.example
#
# Voraussetzungen:
#   - nginx laeuft, certbot ist da, /var/www/acme existiert
#   - der DNS-Name zeigt auf DIESEN Server, in Cloudflare mit GRAUER Wolke
#   - das Repo liegt unter /opt/bitdm

set -euo pipefail

DOMAIN="${1:?Aufruf: install-relay.sh <domain> <email>}"
EMAIL="${2:?Aufruf: install-relay.sh <domain> <email>}"

REPO=/opt/bitdm
SRC="$REPO/secure-messenger/server"
APP=/opt/bitdm-relay
STATE=/var/lib/bitdm-relay
USER=bitdm-relay
PORT=8465

[[ $EUID -eq 0 ]] || { echo "Als root ausfuehren."; exit 1; }
[[ -d "$SRC" ]]   || { echo "Quellen fehlen: $SRC"; exit 1; }

# ─────────────────────────────────────────────────── Vorbedingung: DNS
echo "== DNS pruefen =="
ZIEL=$(dig +short "$DOMAIN" A @1.1.1.1 | head -1)
MEINE=$(curl -s --max-time 8 https://api.ipify.org || true)
echo "   $DOMAIN -> ${ZIEL:-nichts}   (dieser Server: ${MEINE:-unbekannt})"
if [[ -z "$ZIEL" ]]; then
    echo "   FEHLER: kein A-Record. Erst in Cloudflare anlegen, GRAUE Wolke."
    exit 1
fi
if [[ "$ZIEL" != "$MEINE" ]]; then
    echo "   WARNUNG: zeigt nicht auf diesen Server."
    echo "   Beginnt die Adresse mit 104. oder 172.67., ist der"
    echo "   Cloudflare-Proxy AN (orange Wolke). Das muss aus:"
    echo "   Cloudflare saehe sonst zu jeder Verbindung, wer wann mit wem"
    echo "   spricht — genau die Angabe, die diese App vermeidet."
    exit 1
fi

# ─────────────────────────────────────────────── Nutzer und Verzeichnisse
echo "== Dienstnutzer und Verzeichnisse =="
id "$USER" >/dev/null 2>&1 || useradd --system --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin \
    --comment "BitDM Relay" "$USER"
install -d -o root  -g root  -m 0755 "$APP"
install -d -o "$USER" -g "$USER" -m 0700 "$STATE"

# libsodium wird von xeddsa gebraucht.
dpkg -l | grep -q "^ii  libsodium23" || apt-get install -y libsodium23

# ─────────────────────────────────────────────────────────── Python
echo "== Python-Umgebung =="
[[ -d "$APP/venv" ]] || python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install --quiet --upgrade pip
"$APP/venv/bin/pip" install --quiet -r "$SRC/requirements.txt"

# ────────────────────────────────────────────────────────── systemd
echo "== systemd-Unit =="
cat > /etc/systemd/system/bitdm-relay.service <<UNIT
[Unit]
Description=BitDM Relay (verschluesselte Nachrichtenweiterleitung)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=$USER
Group=$USER
WorkingDirectory=$SRC
Environment=BITDM_DB=$STATE/relay.db
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1

# NUR 127.0.0.1. Niemals 0.0.0.0 — das war am 12.07.2026 auf dieser Maschine
# die Einbruchsursache. Erreichbar ist der Dienst ausschliesslich ueber nginx.
#
# --no-access-log ist entschieden, nicht vergessen: das Zugriffsprotokoll von
# uvicorn schriebe zu jeder Anfrage die IP des Nutzers mit Zeitstempel.
#
# --forwarded-allow-ips: X-Forwarded-For wird nur von nginx auf demselben
# Rechner geglaubt. Sonst koennte jeder seine Herkunft faelschen und die
# Ratenbegrenzung aushebeln.
ExecStart=$APP/venv/bin/uvicorn relay_server:app \\
    --host 127.0.0.1 --port $PORT \\
    --no-access-log --log-level warning \\
    --proxy-headers --forwarded-allow-ips 127.0.0.1 \\
    --timeout-keep-alive 75

Restart=on-failure
RestartSec=5s

# ══════ Haertung ══════
# Die wichtigste Zeile ist IPAddressDeny=any weiter unten.
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
PrivateUsers=yes

ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$STATE
PrivateTmp=yes
PrivateDevices=yes
ProtectProc=invisible
ProcSubset=pid

ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RemoveIPC=yes

SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @debug @mount @swap @reboot @module @raw-io @cpu-emulation

RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# HIER. Der Relay ruft von sich aus NIEMANDEN an — kein Update, kein Webhook,
# keine Telemetrie. Wer ihn uebernimmt, sitzt in einem Raum ohne Tuer nach
# draussen: kein Nachladen, kein Miner-Pool, kein Abfliessen.
IPAddressDeny=any
IPAddressAllow=localhost

MemoryMax=512M
TasksMax=64
LimitNOFILE=4096
LimitCORE=0
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

# ──────────────────────────────────────────────────────────── nginx
echo "== nginx =="
cat > /etc/nginx/conf.d/bitdm-relay-limits.conf <<'LIM'
# Absichtlich WEIT. Die eigentliche Verteidigung sitzt im Relay und greift je
# ZIELADRESSE statt je Herkunft — das wirkt auch, wenn der Angreifer die IP
# wechselt. Ein enges Limit hier wuerde stattdessen ganze Mobilfunknetze
# aussperren (Carrier-Grade-NAT) und die elegante Loesung des Relays aushebeln,
# der bei einem Drain-Versuch das Bundle OHNE Einmalschluessel liefert statt
# abzuweisen. Gemessen: bei 20 r/s fielen 8 von 40 echten Anfragen durch.
limit_req_zone  $binary_remote_addr zone=bitdm_relay_req:10m rate=100r/s;
limit_conn_zone $binary_remote_addr zone=bitdm_relay_conn:10m;
limit_req_status  429;
limit_conn_status 429;
LIM

cat > /etc/nginx/snippets/bitdm-relay-proxy.conf <<'SNIP'
# X-Forwarded-For wird ERSETZT, nicht ergaenzt. Mit
# $proxy_add_x_forwarded_for koennte ein Client selbst eine Kopfzeile
# mitschicken und der Ratenbegrenzung eine fremde Herkunft vorspielen.
proxy_set_header Host              $host;
proxy_set_header X-Forwarded-For   $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP         $remote_addr;
proxy_http_version 1.1;
proxy_read_timeout 30s;
proxy_connect_timeout 5s;
SNIP

# Schritt 1: nur HTTP, damit certbot pruefen kann.
cat > /etc/nginx/sites-available/$DOMAIN <<CONF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
CONF
ln -sfn /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
nginx -t && systemctl reload nginx

if [[ ! -d /etc/letsencrypt/live/$DOMAIN ]]; then
    certbot certonly --webroot -w /var/www/acme -d "$DOMAIN" \
        --non-interactive --agree-tos --email "$EMAIL" --no-eff-email
fi

# Schritt 2: die richtige Konfiguration.
cat > /etc/nginx/sites-available/$DOMAIN <<CONF
# $DOMAIN — Weiterleitung verschluesselter Umschlaege.
# Der Dienst dahinter lauscht nur auf 127.0.0.1:$PORT.
#
# GRAUE WOLKE IN CLOUDFLARE — sonst saehe Cloudflare zu jeder Verbindung, wer
# wann mit wem spricht.

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}

server {
    # 'listen ... http2' statt 'http2 on' — letzteres gibt es erst ab
    # nginx 1.25, hier laeuft 1.18.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # KEIN Zugriffsprotokoll. Der Pfad /prekey/<adresse> enthaelt die Adresse
    # des GESPRAECHSPARTNERS — ein Protokoll waere eine fortlaufende Liste,
    # wer wann mit wem Kontakt aufgenommen hat.
    access_log off;
    error_log  /var/log/nginx/$DOMAIN.error.log warn;

    server_tokens off;
    client_max_body_size 256k;
    client_body_timeout  20s;
    client_header_timeout 20s;
    limit_conn bitdm_relay_conn 128;

    # Fehler als JSON. Der Client erwartet ueberall JSON und stolperte sonst
    # ueber eine HTML-Seite.
    error_page 429 = \@zu_schnell;
    location \@zu_schnell {
        default_type application/json;
        return 429 '{"detail":"zu viele Anfragen"}';
    }

    add_header X-Content-Type-Options "nosniff"     always;
    add_header Referrer-Policy        "no-referrer" always;
    add_header X-Frame-Options        "DENY"        always;

    location = /ws {
        limit_req zone=bitdm_relay_req burst=100 nodelay;
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       \$host;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Eine ruhende Verbindung darf nicht nach 60 s abgeraeumt werden —
        # staendiges Neuverbinden kostet auf einem Telefon Akku.
        proxy_read_timeout  1h;
        proxy_send_timeout  1h;
        proxy_buffering     off;
    }

    location = /register/challenge { limit_req zone=bitdm_relay_req burst=100 nodelay; proxy_pass http://127.0.0.1:$PORT; include /etc/nginx/snippets/bitdm-relay-proxy.conf; }
    location = /register           { limit_req zone=bitdm_relay_req burst=100 nodelay; proxy_pass http://127.0.0.1:$PORT; include /etc/nginx/snippets/bitdm-relay-proxy.conf; }
    location ^~ /prekey/           { limit_req zone=bitdm_relay_req burst=200 nodelay; proxy_pass http://127.0.0.1:$PORT; include /etc/nginx/snippets/bitdm-relay-proxy.conf; }

    # /health verraet Nutzerzahl und wie viele gerade online sind. Auch das
    # ist eine Angabe, die niemanden ausser dem Betreiber etwas angeht.
    location = /health {
        allow 127.0.0.1; allow ::1; deny all;
        proxy_pass http://127.0.0.1:$PORT;
        include /etc/nginx/snippets/bitdm-relay-proxy.conf;
    }

    location / { return 404; }
}
CONF

# ─────────────────────────────── nginx nach Zertifikatserneuerung neu laden
# Ohne diesen Hook liefert nginx nach jeder Erneuerung weiter das ALTE
# Zertifikat aus — fuer alle Domains des Servers.
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
set -eu
if ! nginx -t >/dev/null 2>&1; then
    echo "nginx-Konfiguration fehlerhaft — KEIN Reload" >&2
    exit 1
fi
systemctl reload nginx
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

cat > /etc/logrotate.d/bitdm-relay <<ROT
/var/log/nginx/$DOMAIN.error.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 "\$(cat /run/nginx.pid)"
    endscript
}
ROT

# ─────────────────────────────────────────────── Backup: bewusst auslassen
if [[ -f /etc/vps-backup/excludes.txt ]] && ! grep -q "$STATE" /etc/vps-backup/excludes.txt; then
    cat >> /etc/vps-backup/excludes.txt <<EXC

# BitDM-Relay: BEWUSST nicht sichern. Er loescht Umschlaege nach 14 Tagen
# selbst; eine Sicherung wuerde genau das aufbewahren, was er vergessen soll —
# wer wann mit wem Kontakt hatte. Er ist als wegwerfbar entworfen.
$STATE
EXC
fi

# ────────────────────────────────────────────────────────── starten
systemctl daemon-reload
systemctl enable --now bitdm-relay
nginx -t && systemctl reload nginx
sleep 3

# ────────────────────────────────────────────────────────── pruefen
echo
echo "════════════════ Abnahme ════════════════"
p() { printf "%-38s " "$1"; }
p "Dienst laeuft";           systemctl is-active bitdm-relay
p "startet nach Reboot";     systemctl is-enabled bitdm-relay
p "lauscht nur lokal";       ss -tlnH "( sport = :$PORT )" | grep -q "127.0.0.1:$PORT" && echo ja || echo NEIN
p "unprivilegierter Nutzer"; ps -o user= -p "$(systemctl show -p MainPID --value bitdm-relay)"
p "kein offener Port";       ufw status 2>/dev/null | grep -q "$PORT" && echo "NEIN!" || echo ja
p "Haertungsnote";           systemd-analyze security bitdm-relay 2>/dev/null | tail -1 | grep -oE "[0-9.]+ [A-Z]+"
p "/health gesperrt";        curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 "https://$DOMAIN/health"
p "unbekannter Pfad";        curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 "https://$DOMAIN/admin"
echo
echo "Vollstaendiger Test (ueber nginx, TLS und WebSocket):"
echo "  cd $SRC && BITDM_TEST_BASE=https://$DOMAIN $APP/venv/bin/python test_relay.py"
