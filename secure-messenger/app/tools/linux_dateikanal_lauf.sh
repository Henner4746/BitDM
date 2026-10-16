#!/usr/bin/env bash
# Der Kanal bitdm/dateien unter Linux, im echten Programm, ohne Bildschirm.
#
# Startet integration_test/datei_kanal_test.dart unter Xvfb. Der Dialog wird
# dort per xdotool bedient. Fuer "Oeffnen" bekommt der Lauf eigene
# XDG-Ordner mit drei Attrappen als Standardprogrammen — fuer PDF, fuer Text
# und fuer HTML ("Browser"). Jede schreibt eine Zeile ins Protokoll; der Test
# prueft, dass HTML beim Text landet und nie beim Browser.
#
# Braucht: Flutter mit Linux-Werkzeugen (clang, cmake, ninja, GTK 3), Xvfb,
# xvfb-run, xdotool, shared-mime-info. Aufruf aus secure-messenger/app:
#   tools/linux_dateikanal_lauf.sh
set -euo pipefail

APP=$(cd "$(dirname "$0")/.." && pwd)
PROBE=$(mktemp -d "${TMPDIR:-/tmp}/bitdm-dateikanal.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/config" "$PROBE/daten/applications" "$PROBE/bin"
cat > "$PROBE/bin/attrappe" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$BITDM_TEST_PROTOKOLL"
EOF
chmod +x "$PROBE/bin/attrappe"

for art in pdf text browser; do
  case $art in
    pdf) typ=application/pdf ;;
    text) typ=text/plain ;;
    browser) typ=text/html ;;
  esac
  cat > "$PROBE/daten/applications/bitdm-attrappe-$art.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BitDM-Attrappe $art
Exec=$PROBE/bin/attrappe $art %f
MimeType=$typ;
NoDisplay=true
EOF
done
cat > "$PROBE/config/mimeapps.list" <<'EOF'
[Default Applications]
application/pdf=bitdm-attrappe-pdf.desktop
text/plain=bitdm-attrappe-text.desktop
text/html=bitdm-attrappe-browser.desktop
EOF

export BITDM_TEST_PROTOKOLL="$PROBE/geoeffnet.txt"
export XDG_DATA_HOME="$PROBE/daten"
# XDG_CONFIG_HOME traegt die mimeapps.list. Das Flutter-Werkzeug liest dort
# auch seine eigenen Einstellungen und nimmt bei einem leeren Ordner die
# Vorgaben — Linux als Ziel ist darin eingeschaltet. Die App erbt alles.
cd "$APP"
XDG_CONFIG_HOME="$PROBE/config" xvfb-run -a -s "-screen 0 1280x800x24" \
  flutter test integration_test/datei_kanal_test.dart -d linux \
  --dart-define=BITDM_TEST_OEFFNEN=true
