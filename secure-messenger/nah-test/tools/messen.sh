#!/usr/bin/env bash
# Faehrt die Wegwerf-App auf zwei angeschlossenen Telefonen und liest mit.
#
# Warum ein Skript und nicht Antippen von Hand: die Messwerte sind der ganze
# Zweck. Wer die Knoepfe selbst drueckt, hat zwischen den beiden Geraeten eine
# Verzoegerung von einer Sekunde und weiss hinterher nicht, ob eine Zahl daran
# lag. Vom Rechner aus liegen zwischen "A sendet" und "B sucht" 200 ms, und die
# stehen im Protokoll.

ADB="/c/Users/Henrik/AppData/Local/Android/Sdk/platform-tools/adb.exe"
PAKET="com.bitdm.nahtest"

A="${A:-R3CYA0CHD9L}"   # Galaxy S25 Ultra
B="${B:-RF8M9112BJE}"   # Galaxy S10

# Tippt auf den Knopf, dessen Beschriftung mit $2 anfaengt.
#
# Ueber uiautomator statt fester Koordinaten: die Knoepfe stehen in einem Wrap
# und rutschen je nach Bildschirmbreite. Feste Zahlen sind am 26.07. schon
# einmal bei 1080 statt 1440 Pixeln danebengegangen.
tippe() {
  local d="$1" text="$2"
  # MSYS_NO_PATHCONV: Git Bash macht sonst aus "/sdcard/ui.xml" den
  # Windows-Pfad "C:/Program Files/Git/sdcard/ui.xml" und adb legt die Datei
  # ins Nirgendwo. Der Fehler sieht aus wie ein kaputtes uiautomator.
  local xml
  MSYS_NO_PATHCONV=1 "$ADB" -s "$d" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  xml=$(MSYS_NO_PATHCONV=1 "$ADB" -s "$d" shell cat /sdcard/ui.xml 2>/dev/null | tr -d '\r')
  # Flutter haengt die Beschriftung eines Knopfes an content-desc, nicht an
  # text — text tragen nur Eingabefelder. Beides zu pruefen kostet nichts und
  # spart beim naechsten Mal die Viertelstunde, die es heute gekostet hat.
  local bounds
  bounds=$(echo "$xml" \
           | grep -oE "(content-desc|text)=\"$text[^\"]*\"[^>]*bounds=\"[^\"]*\"" \
           | grep -o 'bounds="[^"]*"' | head -1 | sed 's/bounds="//;s/"//')
  if [ -z "$bounds" ]; then
    echo "   !! Knopf '$text' nicht gefunden auf $d"
    return 1
  fi
  local x1 y1 x2 y2
  x1=$(echo "$bounds" | sed 's/\[\([0-9]*\),.*/\1/')
  y1=$(echo "$bounds" | sed 's/\[[0-9]*,\([0-9]*\)\].*/\1/')
  x2=$(echo "$bounds" | sed 's/.*\]\[\([0-9]*\),.*/\1/')
  y2=$(echo "$bounds" | sed 's/.*,\([0-9]*\)\]$/\1/')
  "$ADB" -s "$d" shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 )) >/dev/null 2>&1
  echo "   $d <- '$text'"
}

starte() {
  for d in "$A" "$B"; do
    "$ADB" -s "$d" shell am force-stop $PAKET >/dev/null 2>&1
    "$ADB" -s "$d" logcat -c >/dev/null 2>&1
    "$ADB" -s "$d" shell monkey -p $PAKET -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  done
  sleep 4
}

lies() {
  local d="$1" name="$2"
  echo "── $name ($d)"
  "$ADB" -s "$d" logcat -d -s NAHTEST:I 2>/dev/null \
    | grep -oE 'NAHTEST\s*:.*' | sed 's/^NAHTEST\s*:\s*/   /' | tr -d '\r'
}
