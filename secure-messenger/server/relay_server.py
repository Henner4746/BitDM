"""
relay_server.py  --  Relay- + Key-Server (MVP, Phase 1)
=======================================================

Der Server ist BEWUSST "dumm" und kann Nachrichten NICHT lesen. Er macht nur:

  1. Prekey-Bundles speichern & ausliefern.
     -> braucht man fuer Signals X3DH-Sitzungsaufbau, damit man auch jemanden
        anschreiben kann, der gerade OFFLINE ist.
  2. Verschluesselte Umschlaege zwischen Nutzern weiterleiten (WebSocket) und
     zwischenspeichern, wenn der Empfaenger offline ist.

Auth: Wer sich verbindet, muss beweisen, dass ihm die Identitaet hinter seiner ID
gehoert  ->  Challenge-Response: Server schickt Zufallszahl, Client signiert sie
mit seinem Identity-Schluessel, Server prueft die Signatur.

Alles echte Krypto (X3DH, Double Ratchet, Ver-/Entschluesselung) passiert in der
App. Der Server sieht nur base64-Blobs.

MVP-Vereinfachungen (siehe README-Roadmap zum Haerten):
  * Speicher liegt im RAM. Clients registrieren sich bei jedem Connect neu.
  * Signatur-Pruefung nutzt Ed25519. Beim echten Flutter-Client wird das auf die
    Identity-Signatur von libsignal umgestellt -> nur die eine Funktion
    `verify_ownership` aendert sich.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import time
from collections import defaultdict

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel


# --------------------------------------------------------------------------- #
#  ID <-> Schluessel  (identisch zur crypto_core-Logik, damit alles zusammenpasst)
# --------------------------------------------------------------------------- #

def encode_id(public_key_bytes: bytes) -> str:
    checksum = hashlib.sha256(public_key_bytes).digest()[:2]
    return base64.b32encode(public_key_bytes + checksum).decode().rstrip("=").lower()


def b64d(s: str) -> bytes:
    return base64.b64decode(s)


# --------------------------------------------------------------------------- #
#  Datenmodelle
# --------------------------------------------------------------------------- #

class OneTimePreKey(BaseModel):
    key_id: int
    public_key: str            # base64


class PreKeyBundle(BaseModel):
    user_id: str               # die "lange Nummer" = kodierter Identity-Key
    identity_key: str          # base64, Ed25519-Public-Key
    signed_prekey_id: int
    signed_prekey: str         # base64
    signed_prekey_sig: str     # base64
    one_time_prekeys: list[OneTimePreKey] = []


class Envelope(BaseModel):
    to: str
    ciphertext: str            # base64 (Server kann es nicht lesen)


# --------------------------------------------------------------------------- #
#  Speicher (RAM)
# --------------------------------------------------------------------------- #

bundles: dict[str, PreKeyBundle] = {}
otk_pool: dict[str, list[OneTimePreKey]] = {}
offline_queue: dict[str, list[dict]] = defaultdict(list)
connections: dict[str, WebSocket] = {}

app = FastAPI(title="Secure Messenger Relay", version="0.1")


# --------------------------------------------------------------------------- #
#  REST: Registrieren & Prekey-Bundle holen
# --------------------------------------------------------------------------- #

@app.get("/health")
def health():
    return {"ok": True, "users": len(bundles), "online": len(connections)}


@app.post("/register")
def register(bundle: PreKeyBundle):
    """App laedt beim Start ihr Prekey-Bundle hoch."""
    if encode_id(b64d(bundle.identity_key)) != bundle.user_id:
        raise HTTPException(400, "user_id passt nicht zum identity_key")
    bundles[bundle.user_id] = bundle
    otk_pool[bundle.user_id] = list(bundle.one_time_prekeys)
    return {"ok": True, "one_time_prekeys": len(otk_pool[bundle.user_id])}


@app.get("/prekey/{user_id}")
def get_prekey(user_id: str):
    """Wer jemanden addet, holt sich hier dessen Bundle fuer den X3DH-Aufbau.
    Ein One-Time-Prekey wird dabei 'verbraucht' (entnommen)."""
    b = bundles.get(user_id)
    if not b:
        raise HTTPException(404, "unbekannte ID")
    pool = otk_pool.get(user_id, [])
    otk = pool.pop(0) if pool else None       # jeder OTK wird nur einmal vergeben
    return {
        "user_id": b.user_id,
        "identity_key": b.identity_key,
        "signed_prekey_id": b.signed_prekey_id,
        "signed_prekey": b.signed_prekey,
        "signed_prekey_sig": b.signed_prekey_sig,
        "one_time_prekey": (otk.model_dump() if otk else None),
    }


# --------------------------------------------------------------------------- #
#  Auth: Besitz der Identitaet beweisen
# --------------------------------------------------------------------------- #

def verify_ownership(identity_key_b64: str, nonce: bytes, signature: bytes) -> bool:
    """Prueft, ob 'signature' wirklich mit dem privaten Identity-Key erzeugt wurde.
    >>> Einziger Umstellungspunkt fuer den echten libsignal-Client. <<<"""
    try:
        Ed25519PublicKey.from_public_bytes(b64d(identity_key_b64)).verify(signature, nonce)
        return True
    except (InvalidSignature, Exception):
        return False


# --------------------------------------------------------------------------- #
#  WebSocket: Verbindung, Auth, Weiterleitung, Offline-Zustellung
# --------------------------------------------------------------------------- #

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    user_id = ws.query_params.get("user_id", "")

    if user_id not in bundles:
        await ws.send_json({"type": "error", "reason": "erst /register aufrufen"})
        await ws.close(code=4401)
        return

    # ---- Challenge-Response ----
    nonce = secrets.token_bytes(32)
    await ws.send_json({"type": "challenge", "nonce": base64.b64encode(nonce).decode()})
    try:
        reply = await ws.receive_json()
    except WebSocketDisconnect:
        return
    signature = b64d(reply.get("signature", ""))
    if not verify_ownership(bundles[user_id].identity_key, nonce, signature):
        await ws.send_json({"type": "auth_result", "ok": False})
        await ws.close(code=4403)
        return
    await ws.send_json({"type": "auth_result", "ok": True})

    # ---- verbunden: wartende Offline-Nachrichten zustellen ----
    connections[user_id] = ws
    for env in offline_queue.pop(user_id, []):
        await ws.send_json({"type": "message", **env})

    # ---- Hauptschleife: Umschlaege weiterleiten ----
    try:
        while True:
            data = await ws.receive_json()
            if data.get("type") != "message":
                continue
            to = data.get("to", "")
            envelope = {"from": user_id, "ciphertext": data.get("ciphertext", ""), "ts": time.time()}
            target = connections.get(to)
            if target is not None:
                await target.send_json({"type": "message", **envelope})
            else:
                offline_queue[to].append(envelope)   # Empfaenger offline -> puffern
            await ws.send_json({"type": "ack", "to": to})
    except WebSocketDisconnect:
        pass
    finally:
        if connections.get(user_id) is ws:
            del connections[user_id]
