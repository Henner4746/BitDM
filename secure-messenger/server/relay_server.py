"""
relay_server.py  --  Relay- + Key-Server fuer BitDM
====================================================

Der Server ist BEWUSST dumm und kann Nachrichten NICHT lesen. Er macht nur:

  1. Prekey-Bundles speichern & ausliefern (fuer Signals X3DH-Sitzungsaufbau,
     damit man auch jemanden anschreiben kann, der gerade offline ist).
  2. Verschluesselte Umschlaege zwischen Nutzern weiterleiten (WebSocket) und
     zwischenspeichern, wenn der Empfaenger offline ist.

Alles echte Krypto (X3DH, Double Ratchet, Ver-/Entschluesselung) passiert in der
App. Der Server sieht nur base64-Blobs.

WAS SICH GEGENUEBER DEM ENTWURF GEAENDERT HAT
---------------------------------------------
S1  Auth laeuft jetzt ueber XEdDSA statt Ed25519. libsignal-Identitaetsschluessel
    sind Curve25519; mit `cryptography` allein waere die Pruefung unmoeglich
    gewesen und die Auth waere gebrochen, sobald der echte Client kommt.
S2  /register verlangt einen Besitznachweis. Vorher wurde nur geprueft, ob
    encode_id(identity_key) == user_id — das ist selbstreferenziell, jeder mit
    Kenntnis einer oeffentlichen Adresse konnte fremde Bundles ueberschreiben.
S3  /prekey ist ratenbegrenzt. Vorher konnte eine Schleife den One-Time-Prekey-
    Pool jedes Nutzers leeren.
S4  Offline-Warteschlange ist nach Anzahl, Groesse und Alter begrenzt.
S5  Persistenz in SQLite statt RAM; Fehlerbehandlung ist nicht mehr pauschal.

Ausserdem: Adressformat auf 56 Zeichen umgestellt (3-Byte-Pruefsumme statt 2),
damit Base32 glatt aufgeht und kein Padding abgeschnitten werden muss.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
import urllib.parse

import httpx
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field
from xeddsa.bindings import curve25519_pub_to_ed25519_pub, ed25519_verify

# --------------------------------------------------------------------------- #
#  Konfiguration  (alles per Umgebungsvariable ueberschreibbar)
# --------------------------------------------------------------------------- #

DB_PATH = Path(os.getenv("BITDM_DB", "bitdm_relay.db"))

# Aufbewahrung. Umschalten auf "Wegwerf-Server" = diese Werte kleiner setzen;
# der Umbau ist damit eine Konfigurationsaenderung, kein Code-Eingriff.
QUEUE_TTL_SECONDS = int(os.getenv("BITDM_QUEUE_TTL", 14 * 24 * 3600))   # 14 Tage
QUEUE_MAX_PER_USER = int(os.getenv("BITDM_QUEUE_MAX", 500))             # Nachrichten
MAX_CIPHERTEXT_BYTES = int(os.getenv("BITDM_MAX_CT", 64 * 1024))        # 64 KiB

# Ein Challenge-Nonce ist kurzlebig und nur einmal verwendbar.
NONCE_TTL_SECONDS = 120

# Ratenbegrenzung, zweistufig.
#
# Je IP: nur ein grobes Missbrauchsnetz, bewusst grosszuegig. Ein scharfes
# IP-Limit waere hier sogar schaedlich — Mobilfunkanbieter setzen
# Carrier-Grade-NAT ein, hinter einer einzigen IP haengen tausende Kunden.
RATE_CAPACITY = int(os.getenv("BITDM_RATE_BURST", 120))
RATE_REFILL_PER_SEC = float(os.getenv("BITDM_RATE_REFILL", 2.0))

# Je Ziel-Adresse: das ist die eigentliche Verteidigung gegen den Prekey-Drain.
# Der Angriff zielt auf den Pool EINES Nutzers, also wird dort begrenzt — das
# wirkt unabhaengig davon, von wie vielen IPs der Angreifer kommt.
OTK_CAPACITY = int(os.getenv("BITDM_OTK_BURST", 10))
OTK_REFILL_PER_SEC = float(os.getenv("BITDM_OTK_REFILL", 0.1))   # 6 pro Minute

# Ab wann der Client aufgefordert wird, One-Time-Prekeys nachzuliefern.
OTK_LOW_WATERMARK = int(os.getenv("BITDM_OTK_LOW", 20))


# --------------------------------------------------------------------------- #
#  Das Zwischenlager  (dateien.bitdm.net, siehe blob_server.py)
# --------------------------------------------------------------------------- #
#
# Grosse Anhaenge gehen nicht durch diesen Server. Er stellt nur die Erlaubnis
# aus, sie woanders abzulegen — er weiss ja schon, wem eine Adresse gehoert,
# weil er es beim Verbinden geprueft hat. Das Lager muesste denselben Nachweis
# sonst ein zweites Mal fuehren.
#
# WAS DIESER SERVER DABEI NICHT SIEHT: den Inhalt (verschluesselt), den
# Schluessel (reist als gewoehnliche Nachricht) und die Datei selbst (liegt auf
# einem anderen Rechner). Er sieht: wer wann wie viele Bytes ablegen will.

BLOB_BASIS = os.getenv("BITDM_BLOB_BASE", "https://dateien.bitdm.net")

# Muss zu MAX_BYTES in blob_server.py passen. Steht hier trotzdem noch einmal:
# eine Marke fuer mehr auszustellen, als das Lager annimmt, hiesse den Client
# erst laden zu lassen und ihn dann abzuweisen.
BLOB_MAX_BYTES = int(os.getenv("BITDM_BLOB_MAX", 3 * 1024**3))

# Wie lange eine Marke gilt. Grosszuegig, und das ist vertretbar: sie gilt fuer
# GENAU EINE Kennung und GENAU EINE Groesse, und eine schon belegte Kennung
# weist das Lager ab. Eine kurze Frist wuerde dagegen jeden Upload treffen, der
# ueber eine schlechte Mobilfunkstrecke laenger dauert — und das ist genau der
# Fall, fuer den das Lager gebaut ist.
BLOB_MARKE_TTL = int(os.getenv("BITDM_BLOB_MARKE_TTL", 12 * 3600))

# Wie viel eine Adresse pro Tag ablegen darf.
#
# DAS IST DIE EIGENTLICHE VERTEIDIGUNG, nicht die Marke. Die Marke haelt
# Fremde draussen — aber eine Adresse anzulegen kostet nichts als ein
# Schluesselpaar. Ohne diese Grenze koennte sich jemand ein paar Adressen
# machen und die Platte in einer Nacht fuellen.
BLOB_TAGESMENGE = int(os.getenv("BITDM_BLOB_QUOTA", 10 * 1024**3))

BLOB_KENNUNG_MUSTER = re.compile(r"^[a-z2-7]{52}$")


def blob_geheimnis() -> bytes:
    """Das mit dem Lager geteilte Geheimnis.

    BEI JEDEM AUFRUF NEU GELESEN und nicht beim Start einmal. Wird es getauscht,
    genuegt sonst ein Neustart auf einer der beiden Seiten, um alle Uploads
    stillschweigend scheitern zu lassen — mit 403 beim Lager und ohne Hinweis
    darauf, woran es liegt.
    """
    aus_umgebung = os.getenv("BITDM_BLOB_SECRET")
    if aus_umgebung:
        return aus_umgebung.encode()
    return Path(
        os.getenv("BITDM_BLOB_SECRET_FILE", "/etc/bitdm/blob.secret")
    ).read_bytes().strip()


def blob_marke(kennung: str, groesse: int, ablauf: int) -> str:
    """Muss Zeichen fuer Zeichen zu marke_gueltig() in blob_server.py passen."""
    nachricht = f"{kennung}|{groesse}|{ablauf}".encode()
    return hmac.new(blob_geheimnis(), nachricht, hashlib.sha256).hexdigest()


def blob_menge_heute(user_id: str) -> int:
    seit = time.time() - 24 * 3600
    return db.execute(
        "SELECT COALESCE(SUM(groesse), 0) FROM blob_marken WHERE user_id=? AND ts > ?",
        (user_id, seit),
    ).fetchone()[0]


# --------------------------------------------------------------------------- #
#  Adresse  <->  Identitaetsschluessel
# --------------------------------------------------------------------------- #

def encode_id(public_key_bytes: bytes) -> str:
    """32-Byte-Curve25519-Public-Key -> 56-stellige Adresse.

    35 Bytes (32 Schluessel + 3 Pruefsumme) gehen in Base32 glatt auf:
    7 Bloecke a 5 Byte -> exakt 56 Zeichen, nie ein '='-Padding. Die 3-Byte-
    Pruefsumme faengt Tippfehler mit 24 statt 16 Bit ab.
    """
    checksum = hashlib.sha256(public_key_bytes).digest()[:3]
    return base64.b32encode(public_key_bytes + checksum).decode("ascii").lower()


def decode_id(address: str) -> bytes:
    """Adresse -> 32-Byte-Public-Key. Wirft ValueError bei kaputter Pruefsumme."""
    s = address.strip().replace(" ", "").replace("-", "").upper()
    if len(s) != 56:
        raise ValueError("Adresse muss 56 Zeichen haben")
    try:
        raw = base64.b32decode(s)
    except Exception as exc:
        raise ValueError("keine gueltige Base32-Adresse") from exc
    key, checksum = raw[:32], raw[32:35]
    if hashlib.sha256(key).digest()[:3] != checksum:
        raise ValueError("Pruefsumme stimmt nicht — vertippt?")
    return key


def b64d(s: str) -> bytes:
    return base64.b64decode(s)


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


# --------------------------------------------------------------------------- #
#  Signaturpruefung  (XEdDSA ueber Curve25519 — wie libsignal signiert)
# --------------------------------------------------------------------------- #

def verify_signature(identity_key: bytes, message: bytes, signature: bytes) -> bool:
    """Prueft eine XEdDSA-Signatur gegen den Curve25519-Identitaetsschluessel.

    ACHTUNG, hier lag ein schwerer Fehler:
    Frueher wurde der Montgomery-Key fest mit set_sign_bit=False umgerechnet.
    Das ist falsch. Der Edwards-Punkt A zu einem Curve25519-Schluessel hat ein
    Vorzeichenbit (die x-Paritaet), das je Identitaet praktisch zufaellig ist.
    libsignal legt es beim Signieren in das oberste Bit der Signatur:

        signature[63] |= publicKey[31] & 0x80      (ecc/ed25519.dart:87)

    und holt es beim Pruefen von dort wieder heraus:

        A_ed[31]     |= signature[63] & 0x80       (ecc/ed25519.dart:110)
        signature[63] &= 0x7F                      (ecc/ed25519.dart:111)

    Mit fest gesetztem False wurden rund die HAELFTE aller gueltigen Signaturen
    abgelehnt — gemessen 19 von 40. Der Fehler haette sich als sporadisch
    fehlschlagende Anmeldung geaeussert, abhaengig davon, welchen Schluessel ein
    Nutzer zufaellig gezogen hat. Genau die Sorte Fehler, die man in Produktion
    monatelang jagt.
    """
    if len(identity_key) != 32 or len(signature) != 64:
        return False
    try:
        # Vorzeichenbit aus der Signatur holen ...
        sign_bit = bool(signature[63] & 0x80)
        # ... und aus der Signatur entfernen, bevor sie geprueft wird.
        clean_sig = signature[:63] + bytes([signature[63] & 0x7F])
        ed_pub = curve25519_pub_to_ed25519_pub(identity_key, sign_bit)
        return ed25519_verify(clean_sig, ed_pub, message)
    except Exception:
        return False


# --------------------------------------------------------------------------- #
#  Datenbank
# --------------------------------------------------------------------------- #

SCHEMA = """
CREATE TABLE IF NOT EXISTS identities (
    user_id           TEXT PRIMARY KEY,
    identity_key      BLOB NOT NULL,
    registration_id   INTEGER NOT NULL DEFAULT 0,
    signed_prekey_id  INTEGER NOT NULL,
    signed_prekey     BLOB NOT NULL,
    signed_prekey_sig BLOB NOT NULL,
    updated_at        REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
    user_id    TEXT NOT NULL,
    key_id     INTEGER NOT NULL,
    public_key BLOB NOT NULL,
    PRIMARY KEY (user_id, key_id),
    FOREIGN KEY (user_id) REFERENCES identities(user_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS queue (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    recipient  TEXT NOT NULL,
    sender     TEXT NOT NULL,
    ciphertext BLOB NOT NULL,
    ts         REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_queue_recipient ON queue(recipient);
CREATE INDEX IF NOT EXISTS idx_queue_ts        ON queue(ts);

-- Ausgestellte Marken fuer das Zwischenlager. NUR fuer die Tagesmenge da.
--
-- Die Kennung steht hier ABSICHTLICH NICHT drin. Sie waere die Verbindung
-- zwischen einer Adresse und einer bestimmten Datei im Lager — und genau die
-- soll dieser Server nicht haben. Fuer eine Mengenrechnung reicht, wie viel
-- wann; wofuer, geht ihn nichts an.
--
-- Die Zeilen werden nach 24 Stunden weggeraeumt (purge_expired). Ein
-- Protokoll, das laenger lebt, als es gebraucht wird, ist ein Protokoll.
CREATE TABLE IF NOT EXISTS blob_marken (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    groesse INTEGER NOT NULL,
    ts      REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_blob_marken ON blob_marken(user_id, ts);
"""

db: sqlite3.Connection


def init_db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)

    # Nachtraeglich hinzugekommene Spalten. `CREATE TABLE IF NOT EXISTS` laesst
    # eine bestehende Tabelle unangetastet — ohne diese Zeilen liefe ein
    # bereits laufender Relay nach dem Update in "no such column".
    vorhanden = {row[1] for row in conn.execute("PRAGMA table_info(identities)")}
    if "registration_id" not in vorhanden:
        conn.execute(
            "ALTER TABLE identities ADD COLUMN registration_id INTEGER NOT NULL DEFAULT 0"
        )
    if "push_endpoint" not in vorhanden:
        # Wohin angestossen wird, wenn der Empfaenger nicht verbunden ist.
        #
        # WAS HIER STEHT: eine UnifiedPush-Adresse, die der Verteiler auf dem
        # Telefon vergeben hat. Kein Google-Token, keine Geraetekennung — ein
        # Zufallsname auf einem Server, den der Nutzer selbst gewaehlt hat.
        #
        # WAS DAS TROTZDEM IST: eine dauerhafte Kennung neben der Adresse. Wer
        # diese Datenbank in die Hand bekaeme, koennte damit anstossen und so
        # pruefen, ob ein bestimmtes Geraet gerade erreichbar ist. Deshalb ist
        # Push abschaltbar, und beim Abschalten wird die Zeile geleert statt
        # bloss ignoriert.
        conn.execute("ALTER TABLE identities ADD COLUMN push_endpoint TEXT")

    conn.commit()
    return conn


def purge_expired() -> int:
    """Entfernt abgelaufene Warteschlangeneintraege. Rueckgabe: Anzahl."""
    cutoff = time.time() - QUEUE_TTL_SECONDS
    with db:
        cur = db.execute("DELETE FROM queue WHERE ts < ?", (cutoff,))
        # Marken-Zeilen aelter als die Tagesfrist zaehlen fuer nichts mehr.
        # Sie stehenzulassen hiesse, ein Protokoll darueber zu fuehren, wer
        # wann wie viel abgelegt hat — ohne dass es noch einem Zweck diente.
        db.execute("DELETE FROM blob_marken WHERE ts < ?", (time.time() - 24 * 3600,))
    return cur.rowcount


# --------------------------------------------------------------------------- #
#  Ratenbegrenzung  (Token-Bucket je IP)
# --------------------------------------------------------------------------- #

_buckets: dict[str, tuple[float, float]] = {}


def _take(key: str, capacity: float, refill: float, cost: float) -> bool:
    now = time.monotonic()
    tokens, last = _buckets.get(key, (capacity, now))
    tokens = min(capacity, tokens + (now - last) * refill)
    if tokens < cost:
        _buckets[key] = (tokens, now)
        return False
    _buckets[key] = (tokens - cost, now)
    return True


def rate_limit_ok(key: str, cost: float = 1.0) -> bool:
    """Grobes Missbrauchsnetz je IP."""
    return _take(key, float(RATE_CAPACITY), RATE_REFILL_PER_SEC, cost)


def otk_limit_ok(user_id: str) -> bool:
    """Schutz des One-Time-Prekey-Pools EINES Nutzers.

    Greift je Ziel-Adresse statt je Herkunft, weil der Drain-Angriff auf einen
    bestimmten Nutzer zielt und ein Angreifer die IP beliebig wechseln kann.
    """
    return _take(f"otk:{user_id}", float(OTK_CAPACITY), OTK_REFILL_PER_SEC, 1.0)


def client_ip(request: Request) -> str:
    """Client-IP hinter nginx.

    Der Dienst lauscht ausschliesslich auf 127.0.0.1 und haengt hinter nginx;
    X-Forwarded-For stammt daher aus vertrauenswuerdiger Quelle.
    """
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unbekannt"


# --------------------------------------------------------------------------- #
#  Einmal-Nonces fuer Besitznachweise
# --------------------------------------------------------------------------- #

_nonces: dict[str, tuple[bytes, float]] = {}


def issue_nonce(user_id: str) -> bytes:
    nonce = secrets.token_bytes(32)
    _nonces[user_id] = (nonce, time.monotonic() + NONCE_TTL_SECONDS)
    return nonce


def consume_nonce(user_id: str) -> bytes | None:
    """Holt das Nonce und verbraucht es — jedes Nonce gilt genau einmal."""
    entry = _nonces.pop(user_id, None)
    if entry is None:
        return None
    nonce, expires = entry
    return nonce if time.monotonic() < expires else None


# --------------------------------------------------------------------------- #
#  Datenmodelle
# --------------------------------------------------------------------------- #

class OneTimePreKey(BaseModel):
    key_id: int
    public_key: str                       # base64


class PreKeyBundle(BaseModel):
    user_id: str
    identity_key: str                     # base64, Curve25519

    # Bezeichnet das GERAET, nicht die Identitaet.
    #
    # Bei BitDM ist das die einzige Moeglichkeit zu bemerken, dass eine
    # Gegenstelle neu aufgesetzt wurde: der Identitaetsschluessel bleibt
    # derselbe, weil er aus der Seed-Phrase kommt, und die Adresse damit auch.
    # Wechselt die Nummer, sitzt am anderen Ende ein anderes Geraet — der
    # Client kann darauf hinweisen, statt es stillschweigend hinzunehmen.
    registration_id: int = 0

    signed_prekey_id: int
    signed_prekey: str                    # base64
    signed_prekey_sig: str                # base64
    one_time_prekeys: list[OneTimePreKey] = Field(default_factory=list)

    def canonical_bytes(self) -> bytes:
        """Deterministische Serialisierung fuer die Signatur.

        Der Besitznachweis signiert Nonce UND Bundle-Inhalt. Wuerde nur das
        Nonce signiert, koennte ein Angreifer eine abgefangene gueltige
        Signatur mit einem eigenen Bundle kombinieren.

        registration_id gehoert mit hinein: sonst koennte ein Angreifer ein
        abgefangenes Bundle mit veraenderter Nummer erneut einreichen und beim
        Gegenueber den Eindruck eines Geraetewechsels erzeugen — oder einen
        echten Wechsel verbergen.
        """
        payload = {
            "user_id": self.user_id,
            "identity_key": self.identity_key,
            "registration_id": self.registration_id,
            "signed_prekey_id": self.signed_prekey_id,
            "signed_prekey": self.signed_prekey,
            "signed_prekey_sig": self.signed_prekey_sig,
            "one_time_prekeys": sorted(
                ([k.key_id, k.public_key] for k in self.one_time_prekeys),
                key=lambda x: x[0],
            ),
        }
        return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()


class RegisterRequest(BaseModel):
    bundle: PreKeyBundle
    signature: str                        # base64, XEdDSA ueber nonce||sha256(bundle)


class ChallengeRequest(BaseModel):
    user_id: str


# --------------------------------------------------------------------------- #
#  App
# --------------------------------------------------------------------------- #

@asynccontextmanager
async def lifespan(app: FastAPI):
    global db
    db = init_db(DB_PATH)
    purged = purge_expired()
    if purged:
        print(f"[i] {purged} abgelaufene Nachrichten entfernt")

    async def janitor():
        while True:
            await asyncio.sleep(3600)
            try:
                purge_expired()
            except sqlite3.Error as exc:
                print(f"[!] Aufraeumen fehlgeschlagen: {exc}")

    task = asyncio.create_task(janitor())
    try:
        yield
    finally:
        task.cancel()
        db.close()


app = FastAPI(title="BitDM Relay", version="1.0", lifespan=lifespan)

connections: dict[str, WebSocket] = {}


@app.get("/health")
def health():
    users = db.execute("SELECT COUNT(*) FROM identities").fetchone()[0]
    queued = db.execute("SELECT COUNT(*) FROM queue").fetchone()[0]
    return {"ok": True, "users": users, "online": len(connections), "queued": queued}


# ---------------------------------------------------------------- Registrieren

@app.post("/register/challenge")
def register_challenge(req: ChallengeRequest, request: Request):
    """Schritt 1 des Besitznachweises: Server gibt ein Einmal-Nonce aus."""
    if not rate_limit_ok(f"chal:{client_ip(request)}"):
        raise HTTPException(429, "zu viele Anfragen")
    try:
        decode_id(req.user_id)
    except ValueError as exc:
        raise HTTPException(400, f"ungueltige Adresse: {exc}") from exc
    return {"nonce": b64e(issue_nonce(req.user_id))}


@app.post("/register")
def register(req: RegisterRequest, request: Request):
    """Schritt 2: Bundle hochladen, signiert mit dem Identitaetsschluessel.

    Ohne diesen Nachweis konnte frueher jeder, der eine oeffentliche Adresse
    kannte, das fremde Bundle ueberschreiben — Sessions brachen, der
    Prekey-Pool war weg.
    """
    if not rate_limit_ok(f"reg:{client_ip(request)}", cost=5):
        raise HTTPException(429, "zu viele Anfragen")

    bundle = req.bundle
    try:
        identity_key = b64d(bundle.identity_key)
    except Exception as exc:
        raise HTTPException(400, "identity_key ist kein gueltiges base64") from exc

    if len(identity_key) != 32:
        raise HTTPException(400, "identity_key muss 32 Byte sein")
    if encode_id(identity_key) != bundle.user_id:
        raise HTTPException(400, "user_id passt nicht zum identity_key")

    nonce = consume_nonce(bundle.user_id)
    if nonce is None:
        raise HTTPException(401, "kein gueltiges Nonce — erst /register/challenge")

    message = nonce + hashlib.sha256(bundle.canonical_bytes()).digest()
    try:
        signature = b64d(req.signature)
    except Exception as exc:
        raise HTTPException(400, "signature ist kein gueltiges base64") from exc

    if not verify_signature(identity_key, message, signature):
        raise HTTPException(403, "Besitznachweis fehlgeschlagen")

    try:
        with db:
            db.execute(
                "INSERT INTO identities (user_id, identity_key, registration_id,"
                " signed_prekey_id, signed_prekey, signed_prekey_sig, updated_at)"
                " VALUES (?,?,?,?,?,?,?)"
                " ON CONFLICT(user_id) DO UPDATE SET identity_key=excluded.identity_key,"
                " registration_id=excluded.registration_id,"
                " signed_prekey_id=excluded.signed_prekey_id,"
                " signed_prekey=excluded.signed_prekey,"
                " signed_prekey_sig=excluded.signed_prekey_sig,"
                " updated_at=excluded.updated_at",
                (bundle.user_id, identity_key, bundle.registration_id,
                 bundle.signed_prekey_id, b64d(bundle.signed_prekey),
                 b64d(bundle.signed_prekey_sig), time.time()),
            )
            db.execute("DELETE FROM one_time_prekeys WHERE user_id=?", (bundle.user_id,))
            db.executemany(
                "INSERT INTO one_time_prekeys (user_id, key_id, public_key) VALUES (?,?,?)",
                [(bundle.user_id, k.key_id, b64d(k.public_key))
                 for k in bundle.one_time_prekeys],
            )
    except (sqlite3.Error, ValueError) as exc:
        raise HTTPException(400, f"Bundle konnte nicht gespeichert werden: {exc}") from exc

    count = db.execute(
        "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=?", (bundle.user_id,)
    ).fetchone()[0]
    return {"ok": True, "one_time_prekeys": count}


# ------------------------------------------------------------- Prekeys abholen

@app.get("/prekey/{user_id}")
def get_prekey(user_id: str, request: Request):
    """Bundle fuer den X3DH-Aufbau. Ein One-Time-Prekey wird dabei verbraucht.

    Ratenbegrenzt: sonst leert eine Schleife den Pool eines beliebigen Nutzers
    und zwingt alle kuenftigen Kontakte auf den schwaecheren X3DH-Pfad ohne
    One-Time-Prekey.
    """
    if not rate_limit_ok(f"pk:{client_ip(request)}"):
        raise HTTPException(429, "zu viele Anfragen")

    row = db.execute(
        "SELECT identity_key, signed_prekey_id, signed_prekey, signed_prekey_sig,"
        " registration_id FROM identities WHERE user_id=?", (user_id,)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "unbekannte Adresse")

    # One-Time-Prekey nur ausgeben, wenn das Limit dieser Adresse es zulaesst.
    # Bei Ueberschreitung kommt das Bundle OHNE — X3DH funktioniert auch dann,
    # nur etwas schwaecher. Das ist bewusst besser als ein 429: legitime
    # Kontakte koennen weiterhin eine Sitzung aufbauen, waehrend der
    # Drain-Angriff ins Leere laeuft.
    otk = None
    if otk_limit_ok(user_id):
        # Genau einmalige Ausgabe: DELETE ... RETURNING ist atomar.
        with db:
            otk = db.execute(
                "DELETE FROM one_time_prekeys WHERE rowid = ("
                "  SELECT rowid FROM one_time_prekeys WHERE user_id=? LIMIT 1"
                ") RETURNING key_id, public_key", (user_id,)
            ).fetchone()

    return {
        "user_id": user_id,
        "identity_key": b64e(row[0]),
        "registration_id": row[4],
        "signed_prekey_id": row[1],
        "signed_prekey": b64e(row[2]),
        "signed_prekey_sig": b64e(row[3]),
        "one_time_prekey": (
            {"key_id": otk[0], "public_key": b64e(otk[1])} if otk else None
        ),
    }


# ------------------------------------------------------------------ WebSocket

# ═══════════════════════════════════════════════════════════════ Anstossen
#
# WAS DABEI RAUSGEHT: ein LEERER POST. Kein Absender, kein Inhalt, keine
# Anzahl. Der Push-Server erfaehrt nur, dass fuer dieses Thema etwas anliegt —
# die Nachricht selbst holt die App danach hier ab, verschluesselt wie immer.
#
# Ein Absender im Anstoss waere der schlimmste denkbare Fehler: er stuende
# unverschluesselt auf dem Sperrbildschirm und im Protokoll jedes Servers
# dazwischen.

PUSH_TIMEOUT = 8.0

# Nur eigene Push-Server. Ein Endpunkt, den ein Client frei waehlen darf,
# machte diesen Relay zu einem Werkzeug, mit dem sich beliebige fremde Server
# anschreiben lassen — jemand traegt eine fremde Adresse ein und laesst den
# Relay fuer sich klopfen.
PUSH_ERLAUBTE_HOSTS = {"push.bitdm.net"}


def push_endpunkt_gueltig(url: str) -> bool:
    """Ob dieser Anstoss-Endpunkt angenommen wird."""
    if not isinstance(url, str) or len(url) > 512:
        return False
    try:
        teile = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if teile.scheme != "https":
        return False
    if teile.hostname not in PUSH_ERLAUBTE_HOSTS:
        return False
    # UnifiedPush-Themen heissen "up" + Zufallszeichen. Alles andere waere
    # kein Anstoss-Endpunkt, sondern irgendein Pfad auf dem Push-Server.
    return re.fullmatch(r"/up[A-Za-z0-9_-]+", teile.path) is not None


async def stosse_an(user_id: str) -> None:
    row = db.execute(
        "SELECT push_endpoint FROM identities WHERE user_id=?", (user_id,)
    ).fetchone()
    if row is None or not row[0]:
        return
    try:
        async with httpx.AsyncClient(timeout=PUSH_TIMEOUT) as client:
            await client.post(row[0], content=b"")
    except Exception:
        # Ein Anstoss, der nicht ankommt, ist kein Fehler des Absenders. Die
        # Nachricht liegt in der Warteschlange und wird beim naechsten Start
        # der App zugestellt — Push beschleunigt nur.
        pass


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    user_id = ws.query_params.get("user_id", "")

    row = db.execute(
        "SELECT identity_key FROM identities WHERE user_id=?", (user_id,)
    ).fetchone()
    if row is None:
        await ws.send_json({"type": "error", "reason": "erst /register aufrufen"})
        await ws.close(code=4401)
        return
    identity_key = row[0]

    # ---- Challenge-Response ----
    nonce = secrets.token_bytes(32)
    await ws.send_json({"type": "challenge", "nonce": b64e(nonce)})
    try:
        reply = await asyncio.wait_for(ws.receive_json(), timeout=30)
    except (WebSocketDisconnect, asyncio.TimeoutError, json.JSONDecodeError, RuntimeError):
        return

    try:
        signature = b64d(reply.get("signature", ""))
    except Exception:
        signature = b""

    if not verify_signature(identity_key, nonce, signature):
        await ws.send_json({"type": "auth_result", "ok": False})
        await ws.close(code=4403)
        return
    await ws.send_json({"type": "auth_result", "ok": True})

    # Nur eine aktive Verbindung je Adresse: eine neue verdraengt die alte.
    old = connections.get(user_id)
    if old is not None:
        try:
            await old.close(code=4409)
        except RuntimeError:
            pass
    connections[user_id] = ws

    # ---- wartende Nachrichten zustellen ----
    rows = db.execute(
        "SELECT id, sender, ciphertext, ts FROM queue WHERE recipient=? ORDER BY id",
        (user_id,)
    ).fetchall()
    delivered: list[int] = []
    for row_id, sender, ciphertext, ts in rows:
        await ws.send_json({
            "type": "message",
            "from": sender,
            "ciphertext": b64e(ciphertext),
            "ts": ts,
        })
        delivered.append(row_id)
    if delivered:
        with db:
            db.executemany("DELETE FROM queue WHERE id=?", [(i,) for i in delivered])

    otk_left = db.execute(
        "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=?", (user_id,)
    ).fetchone()[0]
    if otk_left < OTK_LOW_WATERMARK:
        await ws.send_json({"type": "prekeys_low", "remaining": otk_left})

    # ---- Hauptschleife: Umschlaege weiterleiten ----
    try:
        while True:
            data = await ws.receive_json()

            # ── Anstoss-Endpunkt eintragen oder loeschen ──────────────────
            #
            # UEBER DIE BESTEHENDE VERBINDUNG, nicht ueber einen eigenen
            # HTTP-Pfad. Hier ist schon nachgewiesen, wem diese Adresse
            # gehoert — ein eigener Pfad muesste denselben Nachweis noch
            # einmal fuehren, und jede zweite Umsetzung desselben Nachweises
            # ist eine Gelegenheit, ihn falsch zu machen.
            if data.get("type") == "push_endpoint":
                endpunkt = data.get("endpoint")
                if endpunkt in (None, ""):
                    with db:
                        db.execute(
                            "UPDATE identities SET push_endpoint=NULL WHERE user_id=?",
                            (user_id,),
                        )
                    await ws.send_json({"type": "push_ok", "set": False})
                elif push_endpunkt_gueltig(endpunkt):
                    with db:
                        db.execute(
                            "UPDATE identities SET push_endpoint=? WHERE user_id=?",
                            (endpunkt, user_id),
                        )
                    await ws.send_json({"type": "push_ok", "set": True})
                else:
                    await ws.send_json(
                        {"type": "error", "reason": "Anstoss-Endpunkt ungueltig"}
                    )
                continue

            # ── Erlaubnis zum Ablegen im Zwischenlager ────────────────────
            #
            # DIE KENNUNG SUCHT SICH DER CLIENT AUS, dieser Server
            # unterschreibt sie blind. Er koennte sie genauso gut selbst
            # wuerfeln — dann wuesste er aber, welche Datei im Lager zu
            # welcher Adresse gehoert. So weiss er es nicht, und das ist
            # umsonst zu haben.
            #
            # Dass der Client sie waehlt, kostet nichts: eine schon belegte
            # Kennung weist das Lager mit 409 ab, und 32 Byte Zufall zu
            # erraten ist keine Angriffsflaeche.
            if data.get("type") == "blob_marke":
                kennung = data.get("kennung", "")
                groesse = data.get("groesse")
                marken_ref = {"kennung": kennung} if isinstance(kennung, str) else {}

                if not isinstance(kennung, str) or not BLOB_KENNUNG_MUSTER.match(kennung):
                    await ws.send_json({"type": "error", "reason": "Kennung ungueltig"})
                    continue
                if not isinstance(groesse, int) or isinstance(groesse, bool) \
                        or not 0 < groesse <= BLOB_MAX_BYTES:
                    await ws.send_json(
                        {"type": "error", "reason": "Groesse ungueltig", **marken_ref}
                    )
                    continue

                # Die Tagesmenge. Sie wird beim AUSSTELLEN gezaehlt, nicht beim
                # Hochladen — dieser Server erfaehrt nie, ob wirklich
                # hochgeladen wurde. Wer sich Marken holt und sie verfallen
                # laesst, verbraucht damit sein eigenes Kontingent; das ist die
                # richtige Richtung fuer den Irrtum.
                verbraucht = blob_menge_heute(user_id)
                if verbraucht + groesse > BLOB_TAGESMENGE:
                    await ws.send_json({
                        "type": "error",
                        "reason": "Tagesmenge erschoepft",
                        "frei": max(0, BLOB_TAGESMENGE - verbraucht),
                        **marken_ref,
                    })
                    continue

                ablauf = int(time.time()) + BLOB_MARKE_TTL
                try:
                    marke = blob_marke(kennung, groesse, ablauf)
                except OSError:
                    # Das Geheimnis fehlt oder ist nicht lesbar. NICHT so tun,
                    # als laege es am Client: sonst sucht jemand tagelang in
                    # der App nach einem Fehler, der auf dem Server sitzt.
                    await ws.send_json({
                        "type": "error",
                        "reason": "Zwischenlager nicht eingerichtet",
                        **marken_ref,
                    })
                    continue

                with db:
                    db.execute(
                        "INSERT INTO blob_marken (user_id, groesse, ts) VALUES (?,?,?)",
                        (user_id, groesse, time.time()),
                    )
                await ws.send_json({
                    "type": "blob_marke_ok",
                    "kennung": kennung,
                    "groesse": groesse,
                    "ablauf": ablauf,
                    "marke": marke,
                    "ablegen": f"{BLOB_BASIS}/ablegen/{kennung}",
                    "holen": f"{BLOB_BASIS}/blob/{kennung}",
                    "wegwerfen": f"{BLOB_BASIS}/wegwerfen/{kennung}",
                })
                continue

            if data.get("type") != "message":
                continue

            to = data.get("to", "")
            raw_ct = data.get("ciphertext", "")

            # Optionale Kennung des Clients, die in Bestaetigung und Fehler
            # zurueckgespiegelt wird.
            #
            # Ohne sie traegt die Bestaetigung nur die Zieladresse — und ein
            # Client, der zwei Nachrichten an denselben Kontakt geschickt hat,
            # kann nicht sagen, welche davon angekommen ist. Genau das braucht
            # er aber, um nach einem Verbindungsabbruch die richtige Nachricht
            # zu wiederholen. Der Server merkt sich nichts davon; er reicht die
            # Kennung nur zurueck. Weggelassen werden darf sie weiterhin.
            msg_id = data.get("id")
            ref = {"id": msg_id} if isinstance(msg_id, str) else {}

            try:
                ciphertext = b64d(raw_ct)
            except Exception:
                await ws.send_json({"type": "error", "reason": "ciphertext ungueltig", **ref})
                continue

            if not ciphertext or len(ciphertext) > MAX_CIPHERTEXT_BYTES:
                await ws.send_json({"type": "error", "reason": "ciphertext zu gross", **ref})
                continue
            try:
                decode_id(to)
            except ValueError:
                await ws.send_json({"type": "error", "reason": "Zieladresse ungueltig", **ref})
                continue

            target = connections.get(to)
            if target is not None:
                await target.send_json({
                    "type": "message",
                    "from": user_id,
                    "ciphertext": raw_ct,
                    "ts": time.time(),
                })
                await ws.send_json({"type": "ack", "to": to, **ref})
                continue

            # Empfaenger offline -> puffern, aber gedeckelt.
            queued = db.execute(
                "SELECT COUNT(*) FROM queue WHERE recipient=?", (to,)
            ).fetchone()[0]
            if queued >= QUEUE_MAX_PER_USER:
                await ws.send_json({"type": "error", "reason": "Warteschlange voll", "to": to, **ref})
                continue

            with db:
                db.execute(
                    "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
                    (to, user_id, ciphertext, time.time()),
                )
            await ws.send_json({"type": "ack", "to": to, **ref})

            # Den Empfaenger anstossen, falls er das eingeschaltet hat.
            #
            # NICHT ABWARTEN: der Absender hat sein ack schon. Wenn der
            # Push-Server hakt, darf das seine Verbindung nicht aufhalten.
            asyncio.create_task(stosse_an(to))

    except (WebSocketDisconnect, json.JSONDecodeError, RuntimeError):
        pass
    finally:
        if connections.get(user_id) is ws:
            del connections[user_id]
