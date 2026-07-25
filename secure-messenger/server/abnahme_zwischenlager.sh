#!/bin/bash
# Abnahme des Zwischenlagers — von aussen, ueber die echte Adresse, mit TLS.
#
# Ein Lauf gegen 127.0.0.1 wuerde nginx, TLS und die Pfadmuster ueberspringen,
# also genau die Haelfte, die neu ist. Gehoert auf den Haupt-VPS: er hat das
# Geheimnis, mit dem der Relay unterschreibt.
#
#   bash abnahme_zwischenlager.sh
#
# Fuer den Weg DURCH den Relay (WebSocket, Marke, Tagesmenge) ist
# durchstich_zwischenlager.py zustaendig. Dieses Skript prueft das Lager
# selbst.
set -uo pipefail
BASIS=https://dateien.bitdm.net
GEHEIMNIS=$(cat /etc/bitdm/blob.secret)
FEHLER=0

marke() { # kennung groesse ablauf
  printf '%s|%s|%s' "$1" "$2" "$3" | openssl dgst -sha256 -hmac "$GEHEIMNIS" -r | cut -d' ' -f1
}
kennung() { head -c 32 /dev/urandom | base32 | tr -d '=' | tr 'A-Z' 'a-z'; }
pruefe() { # was erwartet ist
  if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FEHLT $1: erwartet $2, war $3"; FEHLER=$((FEHLER+1)); fi
}

echo "=== 1. Der Normalfall: ablegen, holen, wegwerfen ==="
K=$(kennung)
dd if=/dev/urandom of=/tmp/probe.bin bs=1M count=8 status=none
G=$(stat -c%s /tmp/probe.bin)
A=$(( $(date +%s) + 300 ))
CODE=$(curl -sS -o /tmp/put.out -w '%{http_code}' -X PUT "$BASIS/ablegen/$K" \
  -H "X-Bitdm-Size: $G" -H "X-Bitdm-Expires: $A" -H "X-Bitdm-Token: $(marke "$K" "$G" "$A")" \
  --data-binary @/tmp/probe.bin)
pruefe "hochladen" 200 "$CODE"
cat /tmp/put.out; echo

CODE=$(curl -sS -o /tmp/hol.bin -w '%{http_code}' "$BASIS/blob/$K")
pruefe "herunterladen" 200 "$CODE"
pruefe "Inhalt unveraendert" "$(sha256sum < /tmp/probe.bin)" "$(sha256sum < /tmp/hol.bin)"

echo "=== 2. Bereichs-Anfrage (Fortsetzen nach Funkloch) ==="
CODE=$(curl -sS -o /tmp/teil.bin -w '%{http_code}' -r 1048576-2097151 "$BASIS/blob/$K")
pruefe "Teilinhalt" 206 "$CODE"
pruefe "Teilgroesse" 1048576 "$(stat -c%s /tmp/teil.bin)"
pruefe "Teilinhalt stimmt" \
  "$(dd if=/tmp/probe.bin bs=1 skip=1048576 count=1048576 status=none | sha256sum)" \
  "$(sha256sum < /tmp/teil.bin)"

echo "=== 3. Was nicht durchkommen darf ==="
K2=$(kennung)
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$BASIS/ablegen/$K2" \
  -H "X-Bitdm-Size: 100" -H "X-Bitdm-Expires: $A" -H "X-Bitdm-Token: $(printf '%064d' 0)" \
  --data-binary "@/dev/null")
pruefe "gefaelschte Marke" 403 "$CODE"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASIS/health")
pruefe "/health von aussen" 404 "$CODE"

# nginx weist die Adresse schon als fehlerhaft ab (400), bevor das Pfadmuster
# ueberhaupt drankommt. Das ist strenger als 404, deshalb sind beide recht —
# gepruefte Eigenschaft ist: es wird NICHTS ausgeliefert.
CODE=$(curl -sS -o /tmp/aus.out -w '%{http_code}' "$BASIS/blob/../../etc/passwd" --path-as-is)
case "$CODE" in 400|404) echo "  ok    Pfadausbruch (HTTP $CODE)";;
  *) echo "  FEHLT Pfadausbruch: erwartet 400 oder 404, war $CODE"; FEHLER=$((FEHLER+1));; esac
if grep -q "root:" /tmp/aus.out 2>/dev/null; then
  echo "  FEHLT Pfadausbruch hat Inhalt geliefert"; FEHLER=$((FEHLER+1))
else
  echo "  ok    nichts ausgeliefert"
fi
rm -f /tmp/aus.out

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASIS/")
pruefe "Wurzel" 404 "$CODE"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASIS/blob/")
pruefe "Verzeichnisliste" 404 "$CODE"

# Eine Marke fuer 1 MB, aber 8 MB schicken. Muss WAEHREND des Schreibens
# auffallen, nicht danach.
K3=$(kennung)
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$BASIS/ablegen/$K3" \
  -H "X-Bitdm-Size: 1048576" -H "X-Bitdm-Expires: $A" -H "X-Bitdm-Token: $(marke "$K3" 1048576 "$A")" \
  --data-binary @/tmp/probe.bin)
pruefe "mehr Daten als angesagt" 413 "$CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASIS/blob/$K3")
pruefe "und nichts davon liegt da" 404 "$CODE"

echo "=== 4. Wegwerfen ==="
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASIS/wegwerfen/$K")
pruefe "wegwerfen" 200 "$CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASIS/blob/$K")
pruefe "danach weg" 404 "$CODE"

echo "=== 5. Umleitung und TLS ==="
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "http://dateien.bitdm.net/blob/$K")
pruefe "http wird umgeleitet" 301 "$CODE"

rm -f /tmp/probe.bin /tmp/hol.bin /tmp/teil.bin /tmp/put.out
echo
[ "$FEHLER" -eq 0 ] && echo "ALLES GRUEN" || echo "$FEHLER FEHLGESCHLAGEN"
exit "$FEHLER"
