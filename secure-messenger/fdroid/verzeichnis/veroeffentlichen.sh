#!/usr/bin/env bash
# veroeffentlichen.sh — eine BitDM-Fassung ins eigene F-Droid-Verzeichnis
# bringen (https://bitdm.net/fdroid/repo).
#
# AUFRUF, in WSL, NACHDEM die signierte APK am GitHub-Release haengt:
#   bash secure-messenger/fdroid/verzeichnis/veroeffentlichen.sh 1.9.2
#   bash .../veroeffentlichen.sh 1.9.2 --ohne-hochladen   (nur der Index, lokal)
#
# WAS ES TUT
# 1. Holt bitdm-<fassung>.apk vom GitHub-Release und prueft sie: Pruefsumme
#    gegen das .sha256 am Release UND gegen releases/<fassung>/ auf diesem
#    Rechner, Zertifikat gegen den Entwicklerschluessel, Paketname und
#    Fassung. NEU SIGNIERT WIRD NICHTS — im Verzeichnis liegt bitgenau die
#    Datei vom Release. Wer BitDM von GitHub oder aus Obtainium hat, kann
#    deshalb ohne Neuinstallation wechseln.
# 2. Legt sie als com.bitdm.bitdm_<versionCode>.apk in den Arbeitsordner und
#    nimmt config.yml, Metadaten und die Fastlane-Texte AUS DEM RELEASE-TAG
#    dazu — Beschreibung und Changelog passen so genau zur Fassung.
# 3. `fdroid update` schreibt den Index und signiert ihn mit dem
#    Index-Schluessel.
# 4. `fdroid deploy` laedt per rsync hoch: erst die APKs, zuletzt die
#    Indexdateien. Ein Index zeigt also nie auf eine Datei, die noch fehlt.
#
# WAS DAFUER AUF DIESEM RECHNER LIEGEN MUSS — einmalig, siehe README.md:
# fdroidserver im venv, build-tools mit apksigner, der Index-Schluessel samt
# Passwortdatei im Windows-Profil, der SSH-Zugang `bitdm-fdroid-vps`.
set -euo pipefail

PAKET=com.bitdm.bitdm
# SHA-256 des Entwicklerzertifikats — derselbe Wert wie AllowedAPKSigningKeys.
APK_ZERTIFIKAT=e325b01c08a1a679b6aac20ac9ae3ee255591b46b37dd92717f97085acc22063
GITHUB=https://github.com/Henner4746/BitDM

FASSUNG=
HOCHLADEN=1
for a in "$@"; do
  case "$a" in
    --ohne-hochladen) HOCHLADEN=0 ;;
    -*) echo "Unbekannter Schalter: $a" >&2; exit 2 ;;
    *) FASSUNG=$a ;;
  esac
done
if ! [[ $FASSUNG =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Aufruf: $0 <fassung, z.B. 1.9.2> [--ohne-hochladen]" >&2
  exit 2
fi

HIER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QUELLE=$(cd "$HIER/../../.." && pwd)
WERKZEUG=${BITDM_FDROID_WERKZEUG:-$HOME/bitdm-fdroid}
ARBEIT=${BITDM_FDROID_ARBEIT:-$WERKZEUG/verzeichnis}
FDROID=$WERKZEUG/venv-fd/bin/fdroid
export JAVA_HOME=${JAVA_HOME:-$WERKZEUG/jdk}
export ANDROID_HOME=${ANDROID_HOME:-$WERKZEUG/android-sdk}
export PATH=$JAVA_HOME/bin:$PATH

# Schluessel und Passwort liegen im Windows-Profil (vom PC-Backup erfasst),
# nicht in WSL und nirgends im Repository.
if [[ -z ${BITDM_FDROID_KEYSTORE:-} || -z ${BITDM_FDROID_PASSDATEI:-} ]]; then
  WINPROFIL=$(wslpath -u "$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")
fi
export BITDM_FDROID_KEYSTORE=${BITDM_FDROID_KEYSTORE:-$WINPROFIL/bitdm-fdroid-index.p12}
PASSDATEI=${BITDM_FDROID_PASSDATEI:-$WINPROFIL/bitdm-fdroid-index.passwort}

neuestes() { ls -d "$ANDROID_HOME"/build-tools/*/"$1" 2>/dev/null | sort -V | tail -n1; }
APKSIGNER=$(neuestes apksigner)
AAPT2=$(neuestes aapt2)

fehlt=0
for p in "$FDROID" "$APKSIGNER" "$AAPT2" "$JAVA_HOME/bin/jarsigner" \
         "$BITDM_FDROID_KEYSTORE" "$PASSDATEI"; do
  [[ -n $p && -e $p ]] || { echo "FEHLT: ${p:-apksigner/aapt2 in \$ANDROID_HOME/build-tools}" >&2; fehlt=1; }
done
(( fehlt == 0 )) || exit 1

echo "== BitDM $FASSUNG -> F-Droid-Verzeichnis (Arbeitsordner $ARBEIT)"
mkdir -p "$ARBEIT/eingang" "$ARBEIT/repo" "$ARBEIT/metadata"
EINGANG=$ARBEIT/eingang/bitdm-$FASSUNG.apk

# --- 1. APK vom Release holen und pruefen --------------------------------
URL=$GITHUB/releases/download/v$FASSUNG/bitdm-$FASSUNG.apk
curl -fsSL --proto '=https' --tlsv1.2 -o "$EINGANG.teil" "$URL"
mv "$EINGANG.teil" "$EINGANG"
IST=$(sha256sum "$EINGANG" | cut -d' ' -f1)
AM_RELEASE=$(curl -fsSL --proto '=https' --tlsv1.2 "$URL.sha256" | cut -d' ' -f1)
[[ $IST == "$AM_RELEASE" ]] || { echo "Pruefsumme passt nicht zum .sha256 am Release" >&2; exit 1; }
LOKAL=$QUELLE/releases/$FASSUNG/bitdm-$FASSUNG.apk.sha256
if [[ -f $LOKAL ]]; then
  [[ $IST == "$(cut -d' ' -f1 "$LOKAL")" ]] || { echo "Release-APK ist NICHT die hier signierte ($LOKAL)" >&2; exit 1; }
  echo "   sha256 $IST (Release = lokal signierte Datei)"
else
  echo "   sha256 $IST (kein $LOKAL zum Gegenpruefen — nur das .sha256 am Release)"
fi

ZERT=$("$APKSIGNER" verify --print-certs "$EINGANG")
# Bei einem Fehler nur die Fingerabdruecke zeigen, nicht den ganzen Zertifikatsnamen.
grep -q "^Signer #1 certificate SHA-256 digest: $APK_ZERTIFIKAT$" <<<"$ZERT" \
  || { echo "APK ist nicht mit dem BitDM-Schluessel signiert:" >&2; grep 'SHA-256 digest' <<<"$ZERT" >&2; exit 1; }
! grep -q '^Signer #2' <<<"$ZERT" || { echo "APK hat mehr als einen Signierer" >&2; exit 1; }

# Erst ganz einlesen, dann die erste Zeile nehmen: `| head -n1` beendet aapt2
# mit SIGPIPE, und unter pipefail bricht das Skript dann wortlos ab.
KOPF=$("$AAPT2" dump badging "$EINGANG")
KOPF=${KOPF%%$'\n'*}
[[ $KOPF =~ name=\'([^\']+)\'\ versionCode=\'([0-9]+)\'\ versionName=\'([^\']+)\' ]] \
  || { echo "aapt2 liefert keinen Paketkopf: $KOPF" >&2; exit 1; }
[[ ${BASH_REMATCH[1]} == "$PAKET" && ${BASH_REMATCH[3]} == "$FASSUNG" ]] \
  || { echo "APK ist ${BASH_REMATCH[1]} ${BASH_REMATCH[3]}, erwartet $PAKET $FASSUNG" >&2; exit 1; }
CODE=${BASH_REMATCH[2]}
echo "   $PAKET $FASSUNG (versionCode $CODE), Zertifikat ${APK_ZERTIFIKAT:0:8}…"

# --- 2. In den Arbeitsordner ----------------------------------------------
NAME=${PAKET}_$CODE.apk
for d in repo archive; do
  if [[ -f $ARBEIT/$d/$NAME ]]; then
    # Eine veroeffentlichte Datei nie mit anderem Inhalt ersetzen: F-Droid
    # kennt ihren Hash schon und wuerde sie als kaputt verwerfen.
    [[ $(sha256sum "$ARBEIT/$d/$NAME" | cut -d' ' -f1) == "$IST" ]] \
      || { echo "$d/$NAME liegt schon mit ANDEREM Inhalt da — abgebrochen" >&2; exit 1; }
    echo "   $d/$NAME ist schon da (gleicher Inhalt)"
  fi
done
[[ -f $ARBEIT/repo/$NAME || -f $ARBEIT/archive/$NAME ]] || cp "$EINGANG" "$ARBEIT/repo/$NAME"
rm -f "$EINGANG"

install -m 600 "$HIER/config.yml" "$ARBEIT/config.yml"
install -m 644 "$HIER/metadata/$PAKET.yml" "$ARBEIT/metadata/$PAKET.yml"

# Fastlane aus dem Tag, nicht aus dem Arbeitsstand.
GIT=(git -c "safe.directory=$QUELLE" -C "$QUELLE")
"${GIT[@]}" rev-parse -q --verify "refs/tags/v$FASSUNG" >/dev/null \
  || { echo "Tag v$FASSUNG fehlt lokal — erst 'git fetch --tags'" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"${GIT[@]}" archive "v$FASSUNG" secure-messenger/app/fastlane/metadata/android | tar -x -C "$TMP"
FL=$TMP/secure-messenger/app/fastlane/metadata/android
rm -rf "$ARBEIT/metadata/$PAKET"
cp -r "$FL" "$ARBEIT/metadata/$PAKET"
install -m 644 "$FL/en-US/images/icon.png" "$ARBEIT/bitdm-icon.png"

# --- 3. Index schreiben und signieren ----------------------------------------
cd "$ARBEIT"
BITDM_FDROID_PASS=$(<"$PASSDATEI")
export BITDM_FDROID_PASS
"$FDROID" update
FP=$(keytool -exportcert -keystore "$BITDM_FDROID_KEYSTORE" -storepass:env BITDM_FDROID_PASS \
       -alias bitdm-fdroid-index | sha256sum | cut -d' ' -f1 | tr a-f A-F)
unset BITDM_FDROID_PASS

# --- 4. Hochladen -------------------------------------------------------------
if (( HOCHLADEN )); then
  "$FDROID" deploy
  ENTRY_HIER=$(sha256sum repo/entry.jar | cut -d' ' -f1)
  ENTRY_DORT=$(curl -fsSL -H 'Cache-Control: no-cache' https://bitdm.net/fdroid/repo/entry.jar | sha256sum | cut -d' ' -f1)
  [[ $ENTRY_HIER == "$ENTRY_DORT" ]] \
    || { echo "WARNUNG: bitdm.net liefert ein anderes entry.jar aus (Cache?)" >&2; exit 1; }
  echo "   hochgeladen, bitdm.net liefert das neue entry.jar aus"
else
  echo "   nicht hochgeladen (--ohne-hochladen)"
fi

echo
echo "Repo-Adresse: https://bitdm.net/fdroid/repo?fingerprint=$FP"
