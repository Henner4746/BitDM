#!/bin/bash
# bitdm-storage-waechter — meldet, wenn das Zwischenlager (Storage-VPS) weg ist.
#
# WARUM. Vom 23. bis 25.09.2026 war der Storage-VPS drei Tage weg (Rechnung
# offen), und niemand hat es gemerkt: Anhaenge scheiterten still. Dieser
# Waechter laeuft alle 5 Minuten auf dem Haupt-VPS und schickt ueber das eigene
# ntfy (push.bitdm.net) eine Meldung — beim Ausfall, bei knappem Platz und wenn
# es wieder laeuft. Nie zweimal dieselbe: der Zustand liegt in $STATE_DIR.
#
# Drei Pruefungen, weil jede etwas anderes abdeckt:
#   1. SSH + /health auf dem Storage-VPS selbst (Dienst laeuft, Platz frei)
#   2. HTTPS von aussen auf dateien.bitdm.net (nginx, Zertifikat, DNS)
# Erst nach ZWEI Fehlschlaegen hintereinander wird gemeldet — ein einzelner
# Aussetzer im Netz ist kein Ausfall.
set -u
: "${NTFY_TOPIC:?NTFY_TOPIC fehlt (in /etc/bitdm/waechter.env)}"
NTFY_URL="${NTFY_URL:-http://127.0.0.1:2586}"
STORAGE_HOST="${STORAGE_HOST:-5.231.234.142}"
# Eigener Schluessel und eigener Nutzer auf beiden Seiten (seit 25.09.2026,
# siehe README.md). Der Schluessel darf auf dem Storage-VPS NUR den curl auf
# /health ausfuehren — das erzwingt dort authorized_keys (command=...,restrict),
# der Befehl unten ist nur noch die Beschreibung dessen, was ohnehin laeuft.
SSH_KEY="${SSH_KEY:-/etc/bitdm/waechter_ssh/id_ed25519}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-/etc/bitdm/waechter_ssh/known_hosts}"
SSH_USER="${SSH_USER:-bitdm-waechter}"
MIN_FREI_GB="${MIN_FREI_GB:-80}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/bitdm-waechter}"
mkdir -p "$STATE_DIR"

melde() { # titel, text, prioritaet, tags
  curl -fsS -m 15 -H "Title: $1" -H "Priority: $3" -H "Tags: $4" \
       -d "$2" "$NTFY_URL/$NTFY_TOPIC" >/dev/null || echo "ntfy nicht erreichbar"
}

fehler=""
health=$(ssh -F /dev/null -i "$SSH_KEY" -o IdentitiesOnly=yes \
             -o BatchMode=yes -o ConnectTimeout=10 \
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
             -o GlobalKnownHostsFile=/dev/null \
             "$SSH_USER@$STORAGE_HOST" \
             'curl -fsS -m 10 http://127.0.0.1:8081/health' 2>&1) \
  || fehler="Storage-VPS nicht erreichbar oder Dienst bitdm-blob steht (${health:0:120})"

if [ -z "$fehler" ]; then
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' https://dateien.bitdm.net/health)
  # /health ist von aussen gesperrt: 403/404 heisst "nginx und Zertifikat leben".
  case "$code" in 403|404) ;; *) fehler="dateien.bitdm.net antwortet von aussen mit HTTP $code";; esac
fi

zaehler_datei="$STATE_DIR/fehlschlaege"
zustand_datei="$STATE_DIR/zustand"
zaehler=$(cat "$zaehler_datei" 2>/dev/null || echo 0)
zustand=$(cat "$zustand_datei" 2>/dev/null || echo ok)

if [ -n "$fehler" ]; then
  zaehler=$((zaehler + 1)); echo "$zaehler" > "$zaehler_datei"
  echo "Fehlschlag $zaehler: $fehler"
  if [ "$zaehler" -ge 2 ] && [ "$zustand" != "weg" ]; then
    melde "BitDM: Zwischenlager weg" "$fehler. Anhaenge gehen gerade nicht. Erste Frage: ist die Rechnung beim Anbieter bezahlt?" urgent "rotating_light"
    echo weg > "$zustand_datei"
  fi
  exit 0
fi

echo 0 > "$zaehler_datei"
frei=$(printf '%s' "$health" | sed -n 's/.*"frei_gb":\([0-9.]*\).*/\1/p')
if [ "$zustand" = "weg" ]; then
  melde "BitDM: Zwischenlager wieder da" "Dienst und HTTPS antworten wieder. Frei: ${frei:-?} GB." default "white_check_mark"
  echo ok > "$zustand_datei"; zustand=ok
fi
if [ -n "$frei" ] && awk "BEGIN{exit !($frei < $MIN_FREI_GB)}"; then
  if [ "$zustand" != "knapp" ]; then
    melde "BitDM: Zwischenlager wird knapp" "Nur noch $frei GB frei (Grenze $MIN_FREI_GB GB). Unter 50 GB nimmt der Dienst nichts mehr an." high "warning"
    echo knapp > "$zustand_datei"
  fi
elif [ "$zustand" = "knapp" ]; then
  echo ok > "$zustand_datei"
fi
echo "ok, frei ${frei:-?} GB"
