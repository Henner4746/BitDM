#!/usr/bin/env bash
# Faehrt BitDM auf einem angeschlossenen Telefon vom Rechner aus.
#
# Warum vom Rechner und nicht von Hand: eine Oberflaeche, die man nur selbst
# antippen kann, wird genau einmal angesehen und danach nie wieder geprueft.
# So laesst sich derselbe Weg nach jeder Aenderung in zwanzig Sekunden
# wiederholen.

ADB="${ADB:-/c/Users/Henrik/AppData/Local/Android/Sdk/platform-tools/adb.exe}"
G="${G:-R3CYA0CHD9L}"
PAKET=com.bitdm.bitdm

# MSYS_NO_PATHCONV: Git Bash macht sonst aus "/sdcard/..." einen
# Windows-Pfad, und adb legt die Datei ins Nirgendwo.
baum() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$G" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$ADB" -s "$G" shell cat /sdcard/ui.xml 2>/dev/null | tr -d '\r'
}

# Tippt auf das Element, dessen Beschriftung mit $1 anfaengt.
# Flutter haengt sie an content-desc, nicht an text — text tragen nur
# Eingabefelder.
tippe() {
  local text="$1"
  local b
  b=$(baum | grep -oE "(content-desc|text)=\"$text[^\"]*\"[^>]*bounds=\"[^\"]*\"" \
      | grep -o 'bounds="[^"]*"' | head -1 | sed 's/bounds="//;s/"//')
  if [ -z "$b" ]; then echo "   !! '$text' nicht gefunden"; return 1; fi
  local x1 y1 x2 y2
  x1=$(echo "$b" | sed 's/\[\([0-9]*\),.*/\1/')
  y1=$(echo "$b" | sed 's/\[[0-9]*,\([0-9]*\)\].*/\1/')
  x2=$(echo "$b" | sed 's/.*\]\[\([0-9]*\),.*/\1/')
  y2=$(echo "$b" | sed 's/.*,\([0-9]*\)\]$/\1/')
  "$ADB" -s "$G" shell input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 )) >/dev/null 2>&1
  echo "   -> '$text'"
  sleep 1.5
}

sichtbar() { baum | grep -oE '(content-desc|text)="[^"]{2,90}"' | sed 's/^[a-z-]*="//;s/"$//' | sort -u; }

bild() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$G" shell screencap -p /sdcard/s.png >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$ADB" -s "$G" pull /sdcard/s.png "$1" >/dev/null 2>&1
  echo "   Bild: $1"
}

neustart() {
  "$ADB" -s "$G" shell am force-stop $PAKET
  "$ADB" -s "$G" shell monkey -p $PAKET -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 5
}
