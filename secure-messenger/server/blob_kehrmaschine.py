#!/usr/bin/env python3
"""blob_kehrmaschine.py — raeumt das Zwischenlager auf.

Laeuft als systemd-Timer, einmal am Tag. Nicht im Dienst selbst: ein Verzeichnis
mit tausend Dateien durchzugehen dauert, und waehrenddessen soll niemand auf
seinen Upload warten.

DREI SORTEN MUELL

1. ABGELAUFENE BLOECKE. Nach 14 Tagen weg — dieselbe Frist wie beim Relay. Was
   so lange nicht abgeholt wurde, wird auch nicht mehr abgeholt. Und was nicht
   mehr da ist, laesst sich nicht beschlagnahmen; das ist hier kein Nebeneffekt,
   sondern der Hauptgrund.

2. ANGEFANGENE UND NIE FERTIGE UPLOADS (".kennung.teil"). Bei drei Gigabyte auf
   Mobilfunk der Normalfall. Der Dienst raeumt sie selbst weg, wenn er den
   Abbruch mitbekommt — bei einem Absturz oder einem harten Neustart bekommt er
   ihn nicht mit. Diese Reste haben eine viel kuerzere Frist: einen Tag. Laenger
   dauert kein Upload, und sie belegen denselben Platz wie fertige Dateien.

   OHNE DIESEN PUNKT waere die Platte irgendwann voll mit Bruchstuecken, die
   niemand je anfordert und die in keiner Statistik auftauchen.

3. NICHTS SONST. Was nicht wie eine Kennung aussieht und kein Bruchstueck ist,
   bleibt liegen und wird gemeldet. Ein Aufraeumer, der alles loescht, was er
   nicht kennt, ist eine Waffe, die auf das eigene Verzeichnis zeigt.

DIE ZEIT, DIE ZAEHLT, IST DIE AENDERUNGSZEIT (st_mtime) und nicht die
Zugriffszeit. Auf ext4 mit relatime ist atime unzuverlaessig; eine Frist, die
sich auf einen Wert stuetzt, der je nach Mount-Option gepflegt wird oder nicht,
loescht entweder zu frueh oder nie.
"""

from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path

LAGER = Path(os.getenv("BITDM_BLOB_DIR", "/srv/storage/bitdm-blobs"))

# 14 Tage, wie beim Relay.
TTL_SEKUNDEN = int(os.getenv("BITDM_BLOB_TTL", str(14 * 24 * 3600)))

# Bruchstuecke: ein Tag. Ein Upload, der laenger als das laeuft, ist keiner
# mehr.
TEIL_TTL_SEKUNDEN = int(os.getenv("BITDM_BLOB_TEIL_TTL", str(24 * 3600)))

KENNUNG_MUSTER = re.compile(r"^[a-z2-7]{52}$")
TEIL_MUSTER = re.compile(r"^\.[a-z2-7]{52}\.teil$")


def kehre() -> int:
    jetzt = time.time()
    weg = befreit = fremd = 0

    for p in LAGER.iterdir():
        try:
            if p.is_dir():
                fremd += 1
                continue
            alter = jetzt - p.stat().st_mtime
            groesse = p.stat().st_size
        except FileNotFoundError:
            # Zwischen iterdir() und stat() abgeholt und geloescht. Kein
            # Fehler — genau dafuer ist der Loeschweg da.
            continue

        if KENNUNG_MUSTER.match(p.name):
            frist = TTL_SEKUNDEN
        elif TEIL_MUSTER.match(p.name):
            frist = TEIL_TTL_SEKUNDEN
        else:
            fremd += 1
            continue

        if alter > frist:
            try:
                p.unlink()
                weg += 1
                befreit += groesse
            except FileNotFoundError:
                pass

    print(
        f"{weg} Dateien entfernt, {befreit / 1024**3:.2f} GB frei geworden"
        + (f", {fremd} unbekannte Eintraege liegen gelassen" if fremd else "")
    )
    return fremd


if __name__ == "__main__":
    if not LAGER.is_dir():
        # NICHT stillschweigend nichts tun: ein Aufraeumer, der das falsche
        # Verzeichnis nicht findet, meldet jahrelang Erfolg, waehrend das
        # richtige volllaeuft.
        sys.exit(f"Lager {LAGER} gibt es nicht")
    kehre()
