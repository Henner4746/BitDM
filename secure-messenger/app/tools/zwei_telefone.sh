#!/usr/bin/env bash
# Faehrt BEIDE Telefone und laesst sie eine Nachricht ueber Bluetooth
# austauschen — ohne Internet.
#
# Das ist der einzige Beweis, der zaehlt. 771 gruene Tests sagen, dass die
# Buchfuehrung stimmt; ob zwei echte Funkgeraete einander finden, sagen nur
# zwei echte Funkgeraete.

ADB="${ADB:-/c/Users/Henrik/AppData/Local/Android/Sdk/platform-tools/adb.exe}"
PAKET=com.bitdm.bitdm
A="${A:-R3CYA0CHD9L}"   # Galaxy S25 Ultra
B="${B:-RF8M9112BJE}"   # Galaxy S10

# Der UI-Baum — mit einer Datei, die JEDES MAL neu entsteht.
#
# WARUM DAS WICHTIG IST: `uiautomator dump` scheitert gelegentlich (waehrend
# einer Animation, bei einem Fensterwechsel). Schrieb es dann nicht, lieferte
# `cat` stillschweigend den Baum von VORHIN — und jede Pruefung darauf misst
# einen Bildschirm, den es nicht mehr gibt.
#
# Genau das ist am 27.07. passiert: zehn Minuten lang schien ein Tipp "nichts
# zu tun", waehrend das Telefon laengst in einer anderen App stand. Deshalb
# wird die Datei vorher geloescht; kommt nichts zurueck, ist das ein Fehler
# und keine Antwort.
baum() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$1" shell rm -f /sdcard/ui.xml >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$ADB" -s "$1" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  local x
  x=$(MSYS_NO_PATHCONV=1 "$ADB" -s "$1" shell cat /sdcard/ui.xml 2>/dev/null | tr -d '\r')
  if [ -z "$x" ]; then echo "!!BAUM-LEER!!"; return 1; fi
  echo "$x"
}

# In welcher App wir gerade sind. Ein Tipp, der die App verlaesst, faellt
# sonst nicht auf — er sieht aus wie ein Tipp, der nichts bewirkt.
vordergrund() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$1" shell dumpsys window 2>/dev/null \
    | grep -oE 'mCurrentFocus=[^ ]* [^ /]*/[^ }]*' | head -1 | sed 's/.* //'
}

# Tippt auf das Element, dessen Beschriftung mit $2 anfaengt.
tippe() {
  local d="$1" text="$2" b
  b=$(baum "$d" | grep -oE "(content-desc|text)=\"$text[^\"]*\"[^>]*bounds=\"[^\"]*\"" \
      | grep -o 'bounds="[^"]*"' | head -1 | sed 's/bounds="//;s/"//')
  [ -z "$b" ] && { echo "   !! '$text' nicht auf $d"; return 1; }
  local x1 y1 x2 y2
  x1=$(echo "$b" | sed 's/\[\([0-9]*\),.*/\1/'); y1=$(echo "$b" | sed 's/\[[0-9]*,\([0-9]*\)\].*/\1/')
  x2=$(echo "$b" | sed 's/.*\]\[\([0-9]*\),.*/\1/'); y2=$(echo "$b" | sed 's/.*,\([0-9]*\)\]$/\1/')
  "$ADB" -s "$d" shell input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 )) >/dev/null 2>&1
  sleep 1.5
}

sichtbar() {
  baum "$1" | grep -oE '(content-desc|text)="[^"]{2,120}"' \
    | sed 's/^[a-z-]*="//;s/"$//' | sort -u
}

neustart() {
  "$ADB" -s "$1" shell am force-stop $PAKET
  "$ADB" -s "$1" shell monkey -p $PAKET -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 5
}

bild() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$1" shell screencap -p /sdcard/s.png >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$ADB" -s "$1" pull /sdcard/s.png "$2" >/dev/null 2>&1
}

# Die eigene Adresse — 56 Grossbuchstaben/Ziffern, im UI-Baum als Text.
adresse() {
  baum "$1" | grep -oE '[A-Z2-7]{56}' | head -1
}

# Netz aus, Bluetooth an: der Fall, um den es geht.
nurFunk() {
  for d in "$1" "$2"; do
    "$ADB" -s "$d" shell svc wifi disable  >/dev/null 2>&1
    "$ADB" -s "$d" shell svc data disable  >/dev/null 2>&1
    "$ADB" -s "$d" shell svc bluetooth enable >/dev/null 2>&1
  done
  sleep 3
}

netzZurueck() {
  for d in "$1" "$2"; do
    "$ADB" -s "$d" shell svc wifi enable >/dev/null 2>&1
    "$ADB" -s "$d" shell svc data enable >/dev/null 2>&1
  done
}
