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
import secrets
import shutil
import threading
import time
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

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

# Groesstes STUECK, das ein einzelner PUT ablegen darf. Muss zu
# BLOB_MAX_BYTES in relay_server.py passen.
#
# SEIT 25.09.2026 33 MiB STATT 5 GiB. Die App zerlegt jede Datei in Stuecke
# zu 32 MiB (anhang_versand.dart, standardStueckGroesse) und legt jedes
# Stueck einzeln ab, mit 16 Byte GCM-Anhang. Die 5 GiB waren die Grenze fuer
# die ganze DATEI (in der App weiter hoechstGroesse) und erlaubten hier einem
# einzelnen PUT, 5 GiB am Stueck zu schreiben — mit einer einzigen Marke.
# 33 MiB lassen ein MiB Luft ueber dem echten Stueck.
MAX_BYTES = int(os.getenv("BITDM_BLOB_MAX", str(33 * 1024**2)))

# Wie lange etwas liegen bleibt, steht NICHT hier, sondern in
# blob_kehrmaschine.py — dort, wo es auch angewendet wird. Eine Konstante an
# dieser Stelle sieht aus, als wuerde dieser Dienst die Frist durchsetzen; er
# tut es nicht, und beim Lesen wuerde man es fuer erledigt halten.

# Unter diesem freien Platz werden keine neuen Uploads mehr angenommen. Eine
# volle Platte legt nicht nur diesen Dienst lahm, sondern auch die Sicherungen,
# die auf demselben Traeger liegen.
MIN_FREI_BYTES = int(os.getenv("BITDM_BLOB_MIN_FREE", str(50 * 1024**3)))

# Kennungen sind 32 Byte Zufall in Base32 ohne Auffuellung: 52 Zeichen.
#
# IMMER MIT fullmatch. Mit `^...$` und .match() ging auch "<52 Zeichen>\n"
# durch — `$` passt VOR einem letzten Zeilenumbruch —, und der Dateiname
# waere ein anderer gewesen als der, den die Marke meinte.
KENNUNG_MUSTER = re.compile(r"[a-z2-7]{52}")

# Eine Marke ist ein HMAC-SHA256 in Kleinbuchstaben-Hex.
MARKE_MUSTER = re.compile(r"[0-9a-f]{64}")

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
    # ERST DIE FORM, DANN DER VERGLEICH. hmac.compare_digest nimmt zwei str nur
    # an, wenn beide reines ASCII sind — Starlette liest Kopfzeilen als
    # latin-1, und ein einziges "\xe9" in X-Bitdm-Token warf TypeError, also
    # 500 statt 403 (Audit vom 25.09.2026). Eine echte Marke hat genau diese
    # Form; alles andere ist keine.
    if not isinstance(marke, str) or not MARKE_MUSTER.fullmatch(marke):
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


def pfad_im_lager(name: str) -> Path:
    """Der Pfad einer Datei im Lager — mit der Gewissheit, dass er DORT liegt.

    Die Kennung ist vorher schon gegen KENNUNG_MUSTER geprueft, und darin gibt
    es weder "/" noch "..". Diese zweite Pruefung ist trotzdem da: sie haengt
    nicht an einem regulaeren Ausdruck, den jemand spaeter lockert, und sie
    ist das, was CodeQL (py/path-injection) als Beweis versteht — der
    aufgeloeste Pfad hat das Lager als unmittelbares Elternverzeichnis, sonst
    wird gar nichts angefasst.
    """
    lager = os.path.realpath(LAGER)
    ziel = os.path.realpath(os.path.join(lager, name))
    # Beides: `startswith` nach dem Normalisieren ist das Muster, das CodeQL
    # als Schutz erkennt; `dirname` stellt zusaetzlich sicher, dass es keine
    # Unterordner gibt.
    if not ziel.startswith(lager + os.sep) or os.path.dirname(ziel) != lager:
        raise HTTPException(400, "Kennung ungueltig")
    return Path(ziel)


# --------------------------------------------------------------------------- #
#  Buchfuehrung ueber laufende Uploads und verbrauchte Marken
# --------------------------------------------------------------------------- #
#
# Beides lebt im Arbeitsspeicher dieses einen Prozesses (uvicorn laeuft mit
# einem Worker, siehe die Unit). Eine Sperre, weil das Schreiben seit dem
# 25.09.2026 in Threads laeuft und die Zaehler von dort fortgeschrieben
# werden.
_buchsperre = threading.Lock()

# Wie viele Bytes laufende Uploads noch schreiben WERDEN.
#
# freier_platz() sieht nur, was schon auf der Platte liegt. Zehn Uploads zu
# je 33 MiB, die gleichzeitig beginnen, sahen alle denselben freien Platz,
# bestanden alle die Pruefung gegen MIN_FREI_BYTES und schrieben dann
# gemeinsam darunter. Jetzt reserviert jeder seinen Rest, bevor er anfaengt,
# und gibt ihn Stueck fuer Stueck frei, waehrend er schreibt (was er
# geschrieben hat, zaehlt ab da freier_platz() mit).
_reserviert = 0

# Kennung -> Ablauf der Marke, fuer jede Marke, mit der schon einmal
# erfolgreich abgelegt wurde.
#
# OHNE DAS WAR EINE MARKE WIEDERVERWENDBAR: ablegen, loeschen (DELETE braucht
# keine Marke), mit derselben Marke noch einmal ablegen — zwoelf Stunden lang,
# so oft man will. Die Tagesmenge des Relays zaehlte nur das erste Mal.
# Gemerkt wird bis zum Ablauf der Marke; danach weist marke_gueltig sie
# ohnehin ab, und der Eintrag darf weg.
#
# GRENZE, ehrlich benannt: nach einem Neustart des Dienstes ist die Liste
# leer. Eine Marke, deren Datei vor dem Neustart schon wieder geloescht war,
# liesse sich danach bis zu ihrem Ablauf noch EINMAL benutzen. Das kostet
# hoechstens die Tagesmenge eines Tages ein zweites Mal und ist den Aufwand
# einer Datei auf der Platte nicht wert.
_verbraucht: dict[str, int] = {}


def _raeume_verbraucht_auf(jetzt: float) -> None:
    """Ruft NUR auf, wer _buchsperre haelt."""
    for k in [k for k, ablauf in _verbraucht.items() if ablauf < jetzt]:
        del _verbraucht[k]


def _schreibe(fd: int, stueck: bytes) -> None:
    """Ein Stueck ganz auf die Platte. Laeuft im Thread, nie auf dem Loop."""
    ansicht = memoryview(stueck)
    while ansicht:
        n = os.write(fd, ansicht)
        ansicht = ansicht[n:]


def _schliesse_ab(fd: int) -> None:
    """fsync und schliessen. Laeuft im Thread: fsync auf einer vollen Platte
    dauert gern Sekunden, und auf dem Loop haelt es JEDEN anderen Upload an."""
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _lege_endgueltig_ab(unfertig: Path, ziel: Path) -> None:
    """Die fertige Nebendatei unter ihren echten Namen bringen — NIE ueber
    eine bestehende Datei hinweg. Wirft FileExistsError, wenn es sie gibt.

    FRUEHER: `ziel.exists()` am Anfang, `rename` am Ende. Zwei gleichzeitige
    PUTs derselben Kennung bestanden beide die Pruefung, schrieben beide in
    DIESELBE Nebendatei (".<kennung>.teil") und benannten sie nacheinander
    um — heraus kam, was gerade zuletzt geschrieben hatte.

    JETZT hat jeder PUT seine eigene Nebendatei (O_EXCL, Zufallsendung), und
    der letzte Schritt kann nicht ueberschreiben:

    - Linux: os.link legt einen zweiten Namen an und scheitert mit EEXIST,
      wenn es den schon gibt — atomar, im Kern entschieden. Danach wird die
      Nebendatei entfernt.
    - Windows (nur die Tests): os.rename ueberschreibt dort nie, sondern
      wirft FileExistsError — also dieselbe Zusage.
    - Ein Dateisystem ohne harte Verknuepfungen (manche Netz- oder
      FUSE-Mounts): Pruefen und Umbenennen. Das hat das alte kleine Fenster
      wieder, aber nur dort, und immer noch mit getrennten Nebendateien.
    """
    if os.name == "nt":
        os.rename(unfertig, ziel)
        return
    try:
        os.link(unfertig, ziel)
    except FileExistsError:
        raise
    except OSError:
        if ziel.exists():
            raise FileExistsError(str(ziel)) from None
        os.rename(unfertig, ziel)
        return
    unfertig.unlink(missing_ok=True)


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
    global _reserviert
    if not KENNUNG_MUSTER.fullmatch(kennung):
        raise HTTPException(400, "Kennung ungueltig")
    if not 0 < x_bitdm_size <= MAX_BYTES:
        raise HTTPException(413, "Groesse ausserhalb des Erlaubten")
    if not marke_gueltig(kennung, x_bitdm_size, x_bitdm_expires, x_bitdm_token):
        raise HTTPException(403, "Marke ungueltig")

    ziel = pfad_im_lager(kennung)
    with _buchsperre:
        _raeume_verbraucht_auf(time.time())
        schon_benutzt = kennung in _verbraucht
    if schon_benutzt or ziel.exists():
        # Kennungen sind Zufall; dass eine zweimal vorkommt, ist praktisch
        # ausgeschlossen. Passiert es doch, darf die alte Datei nicht
        # ueberschrieben werden — sie gehoert jemand anderem. Und mit einer
        # schon verbrauchten Marke wird nichts ein zweites Mal abgelegt,
        # auch wenn die Datei inzwischen geloescht ist (siehe _verbraucht).
        #
        # 409 in beiden Faellen: fuer den Client heisst es dasselbe — unter
        # dieser Kennung wurde schon abgelegt.
        raise HTTPException(409, "gibt es schon")

    # PLATZ RESERVIEREN, BEVOR ES LOSGEHT — unter der Sperre, damit zwei
    # gleichzeitige Uploads nicht denselben freien Platz fuer sich zaehlen.
    with _buchsperre:
        if freier_platz() - _reserviert - x_bitdm_size < MIN_FREI_BYTES:
            raise HTTPException(507, "kein Platz mehr")
        _reserviert += x_bitdm_size
    noch_reserviert = x_bitdm_size

    # In eine EIGENE Nebendatei schreiben und erst danach unter den echten
    # Namen bringen. Bricht die Uebertragung ab — auf Mobilfunk der
    # Normalfall —, bleibt kein halber Block liegen, den jemand fuer
    # vollstaendig haelt. Die Zufallsendung trennt gleichzeitige PUTs
    # derselben Kennung; O_EXCL stellt sicher, dass keiner eine fremde
    # Nebendatei oeffnet. Die Kehrmaschine kennt beide Namensformen.
    unfertig = pfad_im_lager(f".{kennung}.{secrets.token_hex(8)}.teil")
    geschrieben = 0
    try:
        try:
            fd = os.open(unfertig,
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | getattr(os, "O_BINARY", 0), 0o600)
        except OSError:
            raise HTTPException(500, "Ablegen fehlgeschlagen")
        try:
            try:
                async for stueck in request.stream():
                    if not stueck:
                        continue
                    geschrieben += len(stueck)
                    # DER ANGEKUENDIGTEN GROESSE NICHT GLAUBEN. Wer die Marke
                    # fuer 1 MB hat, koennte sonst einfach weiterschicken.
                    if geschrieben > x_bitdm_size:
                        raise HTTPException(413, "mehr Daten als angekuendigt")
                    # IM THREAD. os.write auf dem Event-Loop hielt bei einer
                    # langsamen Platte alle anderen Uploads und jede andere
                    # Anfrage an, bis das Stueck unten war.
                    await run_in_threadpool(_schreibe, fd, stueck)
                    with _buchsperre:
                        _reserviert -= len(stueck)
                    noch_reserviert -= len(stueck)
            finally:
                await run_in_threadpool(_schliesse_ab, fd)
        except HTTPException:
            unfertig.unlink(missing_ok=True)
            raise
        except Exception:
            unfertig.unlink(missing_ok=True)
            raise HTTPException(500, "Ablegen fehlgeschlagen")

        if geschrieben != x_bitdm_size:
            unfertig.unlink(missing_ok=True)
            raise HTTPException(400, "weniger Daten als angekuendigt")

        try:
            await run_in_threadpool(_lege_endgueltig_ab, unfertig, ziel)
        except FileExistsError:
            # Ein gleichzeitiger PUT derselben Kennung war schneller. Seine
            # Datei bleibt, diese Nebendatei geht.
            unfertig.unlink(missing_ok=True)
            raise HTTPException(409, "gibt es schon")
        except OSError:
            unfertig.unlink(missing_ok=True)
            raise HTTPException(500, "Ablegen fehlgeschlagen")
    finally:
        with _buchsperre:
            _reserviert -= noch_reserviert

    with _buchsperre:
        _verbraucht[kennung] = x_bitdm_expires
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

    Die Marke, mit der sie abgelegt wurde, bleibt dabei verbraucht — siehe
    _verbraucht, warum sich sonst mit Ablegen und Loeschen im Wechsel beliebig
    viel durch eine einzige Marke schieben liesse.
    """
    if not KENNUNG_MUSTER.fullmatch(kennung):
        raise HTTPException(400, "Kennung ungueltig")
    pfad_im_lager(kennung).unlink(missing_ok=True)
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
