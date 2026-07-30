#!/usr/bin/env python3
"""testaufbau.py — Relay und Zwischenlager auf diesem Rechner, fuer den Emulator.

WOFUER
Ein Testlauf im Emulator soll nicht den echten Server treffen. Er wuerde dort
Muell hinterlassen, und jeder Fehlversuch waere in den Statistiken eines
Dienstes zu sehen, der Leuten gehoert. Also laeuft beides hier.

DER EMULATOR ERREICHT DEN HOST UNTER 10.0.2.2 — und zwar dessen 127.0.0.1.
Das ist kein Zufall und kein Loch: die Umsetzung passiert im Emulator selbst.
Deshalb binden beide Dienste hier auf 127.0.0.1 und sonst nirgends. Wer sie
auf 0.0.0.0 legt, hat einen Relay ohne Anmeldung im Heimnetz stehen.

WAS DER UNTERSCHIED ZUM ECHTEN BETRIEB IST
Im Betrieb liefert nginx GET /blob/{kennung} direkt von der Platte aus.
Hier gibt es kein nginx, also haengt dieses Skript genau diese eine Route an
den Blob-Dienst — mehr nicht. Sie ist bewusst so dumm wie moeglich: Datei
oeffnen, ausliefern. Wer hier Bereichs-Anfragen oder Zwischenspeicher
nachbaut, prueft am Ende sein Nachgebautes und nicht die App.
"""

from __future__ import annotations

import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HIER = Path(__file__).resolve().parent
SERVER = HIER.parent

RELAY_PORT = 8080
LAGER_PORT = 8099


def main() -> int:
    arbeit = Path(tempfile.mkdtemp(prefix="bitdm-test-"))
    blobs = arbeit / "blobs"
    blobs.mkdir()

    # EIN FRISCHES GEHEIMNIS JE LAUF. Ein festes waere bequemer und stuende
    # nach dem ersten Mal in irgendeiner Datei, aus der es niemand wieder
    # entfernt.
    geheimnis = secrets.token_hex(32)

    umgebung = dict(os.environ)
    umgebung.update(
        BITDM_DB=str(arbeit / "relay.db"),
        BITDM_BLOB_SECRET=geheimnis,
        BITDM_BLOB_DIR=str(blobs),
        BITDM_BLOB_BASE=f"http://10.0.2.2:{LAGER_PORT}",
        # Der Testrechner hat keine 50 GB frei zu verschenken, und die Pruefung
        # wuerde sonst jeden Upload ablehnen, bevor irgendetwas geprueft ist.
        BITDM_BLOB_MIN_FREE=str(100 * 1024**2),
        PYTHONPATH=str(SERVER),
        PYTHONUNBUFFERED="1",
    )

    # Der Blob-Dienst bekommt die GET-Route, die im Betrieb nginx erledigt.
    lager_start = arbeit / "lager_start.py"
    lager_start.write_text(
        "from fastapi.responses import FileResponse\n"
        "from fastapi import HTTPException\n"
        "import blob_server as b\n"
        "\n"
        "@b.app.get('/blob/{kennung}')\n"
        "def hole(kennung: str):\n"
        "    if not b.KENNUNG_MUSTER.fullmatch(kennung):\n"
        "        raise HTTPException(400, 'kennung')\n"
        "    weg = b.LAGER / kennung\n"
        "    if not weg.is_file():\n"
        "        raise HTTPException(404, 'weg')\n"
        "    return FileResponse(weg)\n"
        "\n"
        "app = b.app\n",
        encoding="utf-8",
    )

    laeufe = [
        ("relay", [sys.executable, "-m", "uvicorn", "relay_server:app",
                   "--host", "127.0.0.1", "--port", str(RELAY_PORT)], SERVER),
        ("lager", [sys.executable, "-m", "uvicorn", "lager_start:app",
                   "--host", "127.0.0.1", "--port", str(LAGER_PORT)], arbeit),
    ]

    prozesse = []
    try:
        for name, befehl, ordner in laeufe:
            p = subprocess.Popen(befehl, cwd=str(ordner), env=umgebung)
            prozesse.append((name, p))

        print(f"ARBEITSORDNER {arbeit}")
        print(f"RELAY  http://10.0.2.2:{RELAY_PORT}")
        print(f"LAGER  http://10.0.2.2:{LAGER_PORT}")
        print("bereit", flush=True)

        while True:
            for name, p in prozesse:
                if p.poll() is not None:
                    print(f"{name} ist beendet ({p.returncode})", flush=True)
                    return 1
            time.sleep(1)
    except KeyboardInterrupt:
        return 0
    finally:
        for _, p in prozesse:
            try:
                p.send_signal(signal.SIGTERM)
            except Exception:
                pass
        for _, p in prozesse:
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
        shutil.rmtree(arbeit, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
