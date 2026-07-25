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
import json
import os
import secrets
import sqlite3
import time
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
"""

db: sqlite3.Connection


def init_db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def purge_expired() -> int:
    """Entfernt abgelaufene Warteschlangeneintraege. Rueckgabe: Anzahl."""
    cutoff = time.time() - QUEUE_TTL_SECONDS
    with db:
        cur = db.execute("DELETE FROM queue WHERE ts < ?", (cutoff,))
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
    signed_prekey_id: int
    signed_prekey: str                    # base64
    signed_prekey_sig: str                # base64
    one_time_prekeys: list[OneTimePreKey] = Field(default_factory=list)

    def canonical_bytes(self) -> bytes:
        """Deterministische Serialisierung fuer die Signatur.

        Der Besitznachweis signiert Nonce UND Bundle-Inhalt. Wuerde nur das
        Nonce signiert, koennte ein Angreifer eine abgefangene gueltige
        Signatur mit einem eigenen Bundle kombinieren.
        """
        payload = {
            "user_id": self.user_id,
            "identity_key": self.identity_key,
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
                "INSERT INTO identities (user_id, identity_key, signed_prekey_id,"
                " signed_prekey, signed_prekey_sig, updated_at)"
                " VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(user_id) DO UPDATE SET identity_key=excluded.identity_key,"
                " signed_prekey_id=excluded.signed_prekey_id,"
                " signed_prekey=excluded.signed_prekey,"
                " signed_prekey_sig=excluded.signed_prekey_sig,"
                " updated_at=excluded.updated_at",
                (bundle.user_id, identity_key, bundle.signed_prekey_id,
                 b64d(bundle.signed_prekey), b64d(bundle.signed_prekey_sig), time.time()),
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
        "SELECT identity_key, signed_prekey_id, signed_prekey, signed_prekey_sig"
        " FROM identities WHERE user_id=?", (user_id,)
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
        "signed_prekey_id": row[1],
        "signed_prekey": b64e(row[2]),
        "signed_prekey_sig": b64e(row[3]),
        "one_time_prekey": (
            {"key_id": otk[0], "public_key": b64e(otk[1])} if otk else None
        ),
    }


# ------------------------------------------------------------------ WebSocket

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
            if data.get("type") != "message":
                continue

            to = data.get("to", "")
            raw_ct = data.get("ciphertext", "")
            try:
                ciphertext = b64d(raw_ct)
            except Exception:
                await ws.send_json({"type": "error", "reason": "ciphertext ungueltig"})
                continue

            if not ciphertext or len(ciphertext) > MAX_CIPHERTEXT_BYTES:
                await ws.send_json({"type": "error", "reason": "ciphertext zu gross"})
                continue
            try:
                decode_id(to)
            except ValueError:
                await ws.send_json({"type": "error", "reason": "Zieladresse ungueltig"})
                continue

            target = connections.get(to)
            if target is not None:
                await target.send_json({
                    "type": "message",
                    "from": user_id,
                    "ciphertext": raw_ct,
                    "ts": time.time(),
                })
                await ws.send_json({"type": "ack", "to": to})
                continue

            # Empfaenger offline -> puffern, aber gedeckelt.
            queued = db.execute(
                "SELECT COUNT(*) FROM queue WHERE recipient=?", (to,)
            ).fetchone()[0]
            if queued >= QUEUE_MAX_PER_USER:
                await ws.send_json({"type": "error", "reason": "Warteschlange voll", "to": to})
                continue

            with db:
                db.execute(
                    "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
                    (to, user_id, ciphertext, time.time()),
                )
            await ws.send_json({"type": "ack", "to": to})

    except (WebSocketDisconnect, json.JSONDecodeError, RuntimeError):
        pass
    finally:
        if connections.get(user_id) is ws:
            del connections[user_id]
