#!/usr/bin/env python3
"""blob_server.py — das Zwischenlager fuer grosse Anhaenge.

WOFUER
Anhaenge bis in den Gigabyte-Bereich, wenn der Empfaenger nicht online ist.
Kleine Nachrichten laufen weiter ueber den Relay; der ist dafuer gebaut und
haelt sie im Arbeitsspeicher einer SQLite-Datei. Eine 3-GB-Datei gehoert dort
nicht hinein.

WAS HIER LIEGT
Verschluesselte Bloecke, sonst nichts. Der Schluessel dazu ist ein
Zufallswert je Datei und reist als gewoehnliche kleine Nachricht durch die
Signal-Sitzung — dieser Dienst sieht ihn nie. Er kennt Groesse und Zeitpunkt,
und das ist alles, was er kennen kann.

═══════════════════════════════════════════════════ DIE ZWEI ENTSCHEIDUNGEN

HOCHLADEN BRAUCHT EINE ERLAUBNIS, HERUNTERLADEN NICHT.

Ohne Erlaubnis zum Hochladen waere das hier ein kostenloser Speicher fuer die
ganze Welt — in Stunden voll, und zwar mit fremdem Material. Die Erlaubnis
stellt der Relay aus: er weiss schon, wem eine Adresse gehoert, weil er es
beim Verbinden geprueft hat. Er unterschreibt eine kurze Marke, dieser Dienst
prueft sie. Ein zweites Mal denselben Nachweis zu fuehren waere eine zweite
Gelegenheit, ihn falsch zu machen.

Beim HERUNTERLADEN ist die Kennung selbst die Erlaubnis: 32 Byte Zufall, die
nur Absender und Empfaenger kennen, weil sie verschluesselt uebertragen
wurden. Wer sie hat, darf holen — und bekommt einen Block, den er ohne den
Schluessel nicht lesen kann. Eine zusaetzliche Anmeldung braechte nichts
ausser der Notwendigkeit, sie zu bauen.

WARUM NGINX HERUNTERLAEDT UND NICHT DIESER DIENST
Ein 3-GB-Download durch Python zu schleifen kostet Speicher und einen
Prozess, der eine Viertelstunde beschaeftigt ist. nginx tut es aus dem Kern
heraus, kann Bereichs-Anfragen von sich aus und macht damit das Fortsetzen
nach einem Funkloch moeglich — ohne dass hier eine Zeile dafuer steht.

DESHALB HABEN HOCH- UND HERUNTERLADEN VERSCHIEDENE PFADE:

    PUT    /ablegen/{kennung}      -> dieser Dienst
    DELETE /wegwerfen/{kennung}    -> dieser Dienst
    GET    /blob/{kennung}         -> nginx, direkt von der Platte

Ein gemeinsamer Pfad waere handlicher, aber nginx muesste dann innerhalb einer
Location nach Methode verzweigen. Das geht nur ueber `if`, und `if` in einer
Location ist in nginx die bekannteste Fussangel ueberhaupt: was dabei mit dem
Anfragekoerper passiert, haengt an Feinheiten der Reihenfolge. Bei einem
Dienst, der jahrelang unbeaufsichtigt laufen soll, ist ein zweiter Pfad der
billigere Preis. Nebenbei macht er die Asymmetrie sichtbar, um die es hier
geht: das eine braucht eine Erlaubnis, das andere nicht.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import shutil
import time
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

# --------------------------------------------------------------------------- #
#  Einstellungen
# --------------------------------------------------------------------------- #

LAGER = Path(os.getenv("BITDM_BLOB_DIR", "/srv/storage/bitdm-blobs"))

# Das Geheimnis, mit dem der Relay Marken unterschreibt. OHNE STANDARDWERT:
# ein voreingestelltes Geheimnis waere kein Geheimnis, und ein Dienst, der
# ohne startet, sieht funktionierend aus und ist offen.
GEHEIMNIS = os.getenv("BITDM_BLOB_SECRET", "").encode()
if len(GEHEIMNIS) < 32:
    raise SystemExit(
        "BITDM_BLOB_SECRET fehlt oder ist zu kurz (mindestens 32 Zeichen)"
    )

# Groesste Datei. 3 GiB — darueber wird es auf einem Telefon ohnehin zur
# Geduldsprobe, und die Grenze steht besser hier als im Ermessen des Clients.
MAX_BYTES = int(os.getenv("BITDM_BLOB_MAX", str(3 * 1024**3)))

# Wie lange etwas liegen bleibt, steht NICHT hier, sondern in
# blob_kehrmaschine.py — dort, wo es auch angewendet wird. Eine Konstante an
# dieser Stelle sieht aus, als wuerde dieser Dienst die Frist durchsetzen; er
# tut es nicht, und beim Lesen wuerde man es fuer erledigt halten.

# Unter diesem freien Platz werden keine neuen Uploads mehr angenommen. Eine
# volle Platte legt nicht nur diesen Dienst lahm, sondern auch die Sicherungen,
# die auf demselben Traeger liegen.
MIN_FREI_BYTES = int(os.getenv("BITDM_BLOB_MIN_FREE", str(50 * 1024**3)))

# Kennungen sind 32 Byte Zufall in Base32 ohne Auffuellung: 52 Zeichen.
KENNUNG_MUSTER = re.compile(r"^[a-z2-7]{52}$")

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


# --------------------------------------------------------------------------- #
#  Marken
# --------------------------------------------------------------------------- #

def marke_gueltig(kennung: str, groesse: int, ablauf: int, marke: str) -> bool:
    """Prueft die Erlaubnis des Relays zum Hochladen.

    DIE GROESSE STEHT MIT DRIN, und das ist kein Beiwerk: ohne sie koennte
    jemand eine Marke fuer eine kleine Datei bekommen und damit drei Gigabyte
    ablegen. Die Kennung ebenfalls — sonst liesse sich eine Marke beliebig oft
    fuer neue Dateien wiederverwenden.
    """
    if ablauf < time.time():
        return False
    nachricht = f"{kennung}|{groesse}|{ablauf}".encode()
    erwartet = hmac.new(GEHEIMNIS, nachricht, hashlib.sha256).hexdigest()
    # Zeitkonstanter Vergleich. Ein gewoehnlicher == verraet ueber die Dauer,
    # wie viele Zeichen stimmen, und damit laesst sich eine Marke Zeichen fuer
    # Zeichen erraten.
    return hmac.compare_digest(erwartet, marke)


def freier_platz() -> int:
    # shutil und nicht os.statvfs: das gibt es unter Windows nicht, und dann
    # laufen die Tests nur auf dem Server. Der Wert ist derselbe — shutil liest
    # unter Linux f_bavail * f_frsize, also den Platz OHNE die Reserve fuer
    # root.
    return shutil.disk_usage(LAGER).free


# --------------------------------------------------------------------------- #
#  Hochladen
# --------------------------------------------------------------------------- #

@app.put("/ablegen/{kennung}")
async def lege_ab(
    kennung: str,
    request: Request,
    x_bitdm_size: int = Header(...),
    x_bitdm_expires: int = Header(...),
    x_bitdm_token: str = Header(...),
):
    if not KENNUNG_MUSTER.match(kennung):
        raise HTTPException(400, "Kennung ungueltig")
    if not 0 < x_bitdm_size <= MAX_BYTES:
        raise HTTPException(413, "Groesse ausserhalb des Erlaubten")
    if not marke_gueltig(kennung, x_bitdm_size, x_bitdm_expires, x_bitdm_token):
        raise HTTPException(403, "Marke ungueltig")

    ziel = LAGER / kennung
    if ziel.exists():
        # Kennungen sind Zufall; dass eine zweimal vorkommt, ist praktisch
        # ausgeschlossen. Passiert es doch, darf die alte Datei nicht
        # ueberschrieben werden — sie gehoert jemand anderem.
        raise HTTPException(409, "gibt es schon")

    if freier_platz() - x_bitdm_size < MIN_FREI_BYTES:
        raise HTTPException(507, "kein Platz mehr")

    # In eine Nebendatei schreiben und erst danach umbenennen. Bricht die
    # Uebertragung ab — bei drei Gigabyte auf Mobilfunk der Normalfall —, bleibt
    # kein halber Block liegen, den jemand fuer vollstaendig haelt.
    unfertig = LAGER / f".{kennung}.teil"
    geschrieben = 0
    try:
        with unfertig.open("wb") as f:
            async for stueck in request.stream():
                geschrieben += len(stueck)
                # DER ANGEKUENDIGTEN GROESSE NICHT GLAUBEN. Wer die Marke fuer
                # 1 MB hat, koennte sonst einfach weiterschicken.
                if geschrieben > x_bitdm_size:
                    raise HTTPException(413, "mehr Daten als angekuendigt")
                f.write(stueck)
            f.flush()
            os.fsync(f.fileno())
    except HTTPException:
        unfertig.unlink(missing_ok=True)
        raise
    except Exception:
        unfertig.unlink(missing_ok=True)
        raise HTTPException(500, "Ablegen fehlgeschlagen")

    if geschrieben != x_bitdm_size:
        unfertig.unlink(missing_ok=True)
        raise HTTPException(400, "weniger Daten als angekuendigt")

    unfertig.rename(ziel)
    return {"ok": True, "bytes": geschrieben}


# --------------------------------------------------------------------------- #
#  Aufraeumen und Auskunft
# --------------------------------------------------------------------------- #

@app.delete("/wegwerfen/{kennung}")
def loesche(kennung: str):
    """Wegwerfen, sobald abgeholt.

    OHNE MARKE, und das ist Absicht: die Kennung kennen nur die beiden
    Beteiligten. Wer sie hat, darf die Datei ohnehin lesen; sie loeschen zu
    duerfen gibt ihm nichts dazu. Und je frueher etwas weg ist, desto besser.
    """
    if not KENNUNG_MUSTER.match(kennung):
        raise HTTPException(400, "Kennung ungueltig")
    (LAGER / kennung).unlink(missing_ok=True)
    return {"ok": True}


@app.get("/health")
def health():
    """Nur von der Schleife erreichbar — nginx laesst diesen Pfad nicht durch.

    Die Zahl der liegenden Dateien verraete, wie viel gerade unterwegs ist.
    """
    dateien = [p for p in LAGER.iterdir() if not p.name.startswith(".")]
    return {
        "ok": True,
        "dateien": len(dateien),
        "belegt_gb": round(sum(p.stat().st_size for p in dateien) / 1024**3, 2),
        "frei_gb": round(freier_platz() / 1024**3, 1),
    }


@app.exception_handler(HTTPException)
def als_json(request: Request, exc: HTTPException):
    # Der Client erwartet ueberall JSON. Eine HTML-Fehlerseite laesst ihn beim
    # Auswerten stolpern, statt den Fehler zu erkennen.
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)


LAGER.mkdir(parents=True, exist_ok=True)
