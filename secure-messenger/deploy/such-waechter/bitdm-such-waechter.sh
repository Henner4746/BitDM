#!/bin/bash
# bitdm-such-waechter — meldet, wenn bitdm.net fuer Suchmaschinen falsch steht.
#
# WARUM. Am 24.10.2026 stand bei der Google-Suche "BitDM" nicht mehr die
# Startseite oben, sondern die F-Droid-Quelle: fdroidserver erzeugt
# /fdroid/repo/index.html bei jedem Update mit Titel "BitDM" und robots
# "index", ein exakter Treffer fuer die Markensuche. Bemerkt hat es erst
# Henrik selbst, beim Suchen. Seitdem sendet /fdroid/ "X-Robots-Tag: noindex"
# (nginx), und dieser Waechter prueft alle 6 Stunden, dass das so bleibt und
# dass nichts die eigentlichen Seiten aus dem Index nimmt: noindex, ein
# falscher Canonical, eine Fehlerseite, eine robots.txt, die alles sperrt.
#
# Meldet ueber dasselbe ntfy-Thema wie der Storage-Waechter (push.bitdm.net),
# einmal, wenn etwas falsch wird, und einmal, wenn es wieder stimmt. Ein
# Befund zaehlt erst, wenn er eine Minute spaeter noch da ist: ein einzelner
# Aussetzer im Netz oder bei Cloudflare ist kein Fehler der Seite.
#
# Zum Ausprobieren ohne ntfy:  TROCKEN=1 NTFY_TOPIC=x ./bitdm-such-waechter.sh
set -u
: "${NTFY_TOPIC:?NTFY_TOPIC fehlt (in /etc/bitdm/waechter.env)}"
NTFY_URL="${NTFY_URL:-http://127.0.0.1:2586}"
SEITE="${SEITE:-https://bitdm.net}"
WIEDERHOLEN_NACH="${WIEDERHOLEN_NACH:-60}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/bitdm-waechter}"
mkdir -p "$STATE_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

melde() { # titel, text, prioritaet, tags
  if [ -n "${TROCKEN:-}" ]; then printf 'MELDUNG [%s] %s\n%s\n' "$3" "$1" "$2"; return; fi
  curl -fsS -m 15 -H "Title: $1" -H "Priority: $3" -H "Tags: $4" \
       -d "$2" "$NTFY_URL/$NTFY_TOPIC" >/dev/null || echo "ntfy nicht erreichbar"
}

# Holt eine Adresse ohne Cloudflare-Zwischenspeicher (eigener Parameter je
# Lauf) und legt Kopf und Inhalt in $TMP ab. Gibt den HTTP-Code aus.
hole() { # url
  local trenner='?'
  case "$1" in *\?*) trenner='&';; esac
  curl -sS -m 25 -A "bitdm-such-waechter (+https://bitdm.net)" \
       -D "$TMP/kopf" -o "$TMP/inhalt" -w '%{http_code}' \
       "$1${trenner}waechter=$LAUF" 2>/dev/null || echo 000
}

# Eine Seite, die in den Index gehoert: 200, kein noindex, Canonical auf sich.
pruefe_seite() { # url
  local url="$1" code
  code=$(hole "$url")
  if [ "$code" != 200 ]; then echo "$url antwortet mit HTTP $code"; return; fi
  if grep -qiE '^x-robots-tag:.*noindex' "$TMP/kopf"; then
    echo "$url sendet X-Robots-Tag noindex"
  fi
  case "$url" in */|*.html) ;; *) return;; esac
  if grep -qiE '<meta[^>]+name="(robots|googlebot)"[^>]+noindex' "$TMP/inhalt"; then
    echo "$url traegt <meta robots noindex>"
  fi
  local kanon
  kanon=$(grep -oiE '<link rel="canonical" href="[^"]*"' "$TMP/inhalt" | head -1 | sed 's/.*href="//; s/"$//')
  if [ -z "$kanon" ]; then
    echo "$url hat keinen Canonical"
  elif [ "$kanon" != "$url" ]; then
    echo "$url verweist mit Canonical auf $kanon"
  fi
}

pruefe_alles() {
  local code url
  # robots.txt: darf die Seite nicht sperren und muss die Sitemap nennen.
  code=$(hole "$SEITE/robots.txt")
  if [ "$code" != 200 ]; then
    echo "robots.txt antwortet mit HTTP $code"
  else
    grep -qiE '^[[:space:]]*Disallow:[[:space:]]*/[[:space:]]*$' "$TMP/inhalt" \
      && echo "robots.txt sperrt die ganze Seite (Disallow: /)"
    grep -qi '^Sitemap:' "$TMP/inhalt" || echo "robots.txt nennt keine Sitemap"
  fi

  # Jede Seite der Sitemap, die Startseite muss dabei sein.
  code=$(hole "$SEITE/sitemap.xml")
  if [ "$code" != 200 ]; then
    echo "sitemap.xml antwortet mit HTTP $code"
  else
    grep -o '<loc>[^<]*</loc>' "$TMP/inhalt" | sed 's/<[^>]*>//g' > "$TMP/liste"
    grep -qx "$SEITE/" "$TMP/liste" || echo "Die Startseite fehlt in der Sitemap"
    while read -r url; do pruefe_seite "$url"; done < "$TMP/liste"
  fi

  # Die Startseite muss den Namen im Titel tragen: um genau diese Suche geht es.
  code=$(hole "$SEITE/")
  if [ "$code" = 200 ] && ! grep -qiE '<title>[^<]*BitDM' "$TMP/inhalt"; then
    echo "Der Titel der Startseite enthaelt nicht mehr \"BitDM\""
  fi

  # Die F-Droid-Quelle muss draussen bleiben (siehe WARUM oben).
  for url in "$SEITE/fdroid/repo/" "$SEITE/fdroid/repo/index.html"; do
    code=$(hole "$url")
    if [ "$code" = 200 ] && ! grep -qiE '^x-robots-tag:.*noindex' "$TMP/kopf"; then
      echo "$url ist ohne noindex: Google kann sie wieder statt der Startseite zeigen"
    fi
  done

  # Nur eine Adresse fuer die Startseite: http und www leiten dauerhaft um.
  for url in "http://bitdm.net/" "https://www.bitdm.net/"; do
    code=$(curl -sS -m 25 -o /dev/null -D "$TMP/kopf" -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    ziel=$(grep -i '^location:' "$TMP/kopf" | tr -d '\r' | sed 's/^[Ll]ocation:[[:space:]]*//')
    if [ "$code" != 301 ] || [ "$ziel" != "$SEITE/" ]; then
      echo "$url leitet nicht dauerhaft auf $SEITE/ um (HTTP $code${ziel:+ nach $ziel})"
    fi
  done
}

LAUF=$(date +%s)
pruefe_alles | sort -u > "$TMP/erst"
if [ -s "$TMP/erst" ]; then
  sleep "$WIEDERHOLEN_NACH"
  LAUF=$(date +%s)
  pruefe_alles | sort -u > "$TMP/dann"
  # Nur, was beide Male auffiel.
  comm -12 "$TMP/erst" "$TMP/dann" > "$TMP/befund"
else
  : > "$TMP/befund"
fi

zustand_datei="$STATE_DIR/suche-befund"
vorher=$(cat "$zustand_datei" 2>/dev/null || true)
jetzt=$(cat "$TMP/befund")

if [ -n "$jetzt" ]; then
  echo "Befund:"; echo "$jetzt"
  if [ "$jetzt" != "$vorher" ]; then
    melde "BitDM: Google-Suche in Gefahr" "$jetzt

Hintergrund und Abhilfe: secure-messenger/deploy/such-waechter/README.md" high "mag"
    printf '%s' "$jetzt" > "$zustand_datei"
  fi
  exit 0
fi

if [ -n "$vorher" ]; then
  melde "BitDM: Suche wieder in Ordnung" "Alle Pruefungen stimmen wieder." default "white_check_mark"
  : > "$zustand_datei"
fi
echo "ok: $(wc -l < "$TMP/liste" 2>/dev/null || echo ?) Seiten der Sitemap, F-Droid noindex, Weiterleitungen"
