"""Meldet die Seiten von bitdm.net per IndexNow an Bing, Yandex, Seznam & Co.

Warum es das gibt: bitdm.net stand im Oktober 2026 in keinem Suchindex — wer
nach "BitDM" suchte, fand das GitHub-Repo und bitdms.net, einen Haendler-
Software-Anbieter aus den USA, aber nie die Seite selbst. Bing liefert die
Treffer fuer die ChatGPT-Suche und Copilot; was Bing nicht kennt, kennen die
auch nicht. IndexNow sagt den Suchmaschinen "diese Adressen haben sich
geaendert", ohne Konto und ohne Webmaster-Konsole. Google nimmt nicht teil.

Der Beweis, dass die Meldung von uns kommt, ist eine Datei auf der Seite
selbst: website/<schluessel>.txt, deren Inhalt der Schluessel ist. Der
Schluessel ist kein Geheimnis — er MUSS oeffentlich lesbar sein, sonst kann
die Suchmaschine ihn nicht pruefen. Wer ihn kennt, kann hoechstens unsere
eigenen Adressen noch einmal melden.

Bevor gemeldet wird, holt das Skript die Schluesseldatei von der LIVE-Seite.
Ohne diese Probe meldet die API erst 202 ("angenommen") und verwirft die
Meldung spaeter still, wenn die Datei fehlt — etwa weil der Deploy noch nicht
gezogen wurde oder Cloudflare die Anfrage abweist.

Start (auf dem Haupt-VPS, nach jedem `git -C /opt/bitdm pull`):
    python3 /opt/bitdm/secure-messenger/deploy/indexnow.py
    python3 .../indexnow.py https://bitdm.net/vs.html   # nur diese Adresse
    python3 .../indexnow.py --dry-run                    # nur zeigen, nichts senden

Nur Standardbibliothek: laeuft mit dem System-Python, ohne venv.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

HOST = "bitdm.net"
API = "https://api.indexnow.org/indexnow"
WEBSITE = Path(__file__).resolve().parent.parent / "website"
SITEMAP_NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
# Eigener Name statt "Python-urllib": den weist Cloudflare eher ab, und im
# Zweifel sieht man am Namen, wer da fragt.
USER_AGENT = "bitdm-indexnow/1 (+https://bitdm.net)"
SCHLUESSEL_MUSTER = re.compile(r"[0-9a-f]{32}\.txt")

# Was die API mit ihren Antworten meint (https://www.indexnow.org/documentation).
BEDEUTUNG = {
    200: "angenommen",
    202: "angenommen, Schluessel wird noch geprueft",
    400: "Anfrage fehlerhaft",
    403: "Schluessel ungueltig — Datei nicht gefunden oder Inhalt passt nicht",
    422: "Adressen gehoeren nicht zu HOST, oder Schluessel passt nicht zum Format",
    429: "zu viele Anfragen — spaeter noch einmal",
}


def finde_schluessel() -> str:
    """Genau eine Schluesseldatei, deren Inhalt ihr eigener Name ist."""
    treffer = [p for p in WEBSITE.iterdir() if SCHLUESSEL_MUSTER.fullmatch(p.name)]
    if len(treffer) != 1:
        namen = ", ".join(p.name for p in treffer) or "keine"
        sys.exit(f"Erwartet genau eine Schluesseldatei in {WEBSITE}, gefunden: {namen}")
    datei = treffer[0]
    schluessel = datei.stem
    inhalt = datei.read_text(encoding="utf-8").strip()
    if inhalt != schluessel:
        sys.exit(f"{datei.name} enthaelt nicht den eigenen Namen als Schluessel")
    return schluessel


def adressen_aus_sitemap() -> list[str]:
    baum = ET.parse(WEBSITE / "sitemap.xml")
    adressen = [loc.text.strip() for loc in baum.iter(f"{SITEMAP_NS}loc") if loc.text]
    if not adressen:
        sys.exit("sitemap.xml enthaelt keine <loc>-Eintraege")
    return adressen


def hole(url: str, daten: bytes | None = None) -> tuple[int, str]:
    kopf = {"User-Agent": USER_AGENT}
    if daten is not None:
        kopf["Content-Type"] = "application/json; charset=utf-8"
    anfrage = urllib.request.Request(url, data=daten, headers=kopf)
    try:
        with urllib.request.urlopen(anfrage, timeout=20) as antwort:
            return antwort.status, antwort.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as fehler:
        return fehler.code, fehler.read().decode("utf-8", "replace")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("adressen", nargs="*", help="nur diese Adressen melden (Standard: alle aus sitemap.xml)")
    parser.add_argument("--dry-run", action="store_true", help="Probe und Nutzlast zeigen, nichts senden")
    args = parser.parse_args()

    schluessel = finde_schluessel()
    schluessel_url = f"https://{HOST}/{schluessel}.txt"
    adressen = args.adressen or adressen_aus_sitemap()

    fremd = [a for a in adressen if not a.startswith(f"https://{HOST}/")]
    if fremd:
        sys.exit(f"Nicht von {HOST}: {', '.join(fremd)}")

    status, inhalt = hole(schluessel_url)
    if status != 200 or inhalt.strip() != schluessel:
        sys.exit(
            f"Schluesseldatei live nicht lesbar: {schluessel_url} -> HTTP {status}. "
            "Erst deployen (git pull), dann melden."
        )
    print(f"Schluesseldatei live: {schluessel_url} (200)")

    nutzlast = {
        "host": HOST,
        "key": schluessel,
        "keyLocation": schluessel_url,
        "urlList": adressen,
    }
    if args.dry_run:
        print(json.dumps(nutzlast, indent=2))
        return 0

    status, antwort = hole(API, json.dumps(nutzlast).encode("utf-8"))
    print(f"IndexNow: HTTP {status} — {BEDEUTUNG.get(status, 'unbekannte Antwort')}")
    for adresse in adressen:
        print(f"  {adresse}")
    if antwort.strip():
        print(antwort.strip())
    return 0 if status in (200, 202) else 1


if __name__ == "__main__":
    sys.exit(main())
