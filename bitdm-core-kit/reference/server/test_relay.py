"""
test_relay.py  --  automatischer End-to-End-Test fuer den Relay-Server.

Spielt zwei echte Nutzer (Alice & Bob) ueber echte Netzwerk-Sockets durch:
  Test 1: beide online  -> Nachricht kommt sofort an.
  Test 2: Empfaenger offline -> Nachricht wird gepuffert und beim Reconnect zugestellt.

Der "Ciphertext" ist hier ein Platzhalter-Blob -- getestet wird der SERVER
(Registrierung, Prekey-Ausgabe, Auth, Weiterleitung), nicht die App-Krypto.
"""

import asyncio
import base64
import hashlib
import json
import os

import httpx
import websockets
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

BASE = "http://127.0.0.1:8099"
WS = "ws://127.0.0.1:8099/ws"


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def encode_id(public_key_bytes: bytes) -> str:
    checksum = hashlib.sha256(public_key_bytes).digest()[:2]
    return base64.b32encode(public_key_bytes + checksum).decode().rstrip("=").lower()


def make_user():
    priv = Ed25519PrivateKey.generate()
    pub = priv.public_key().public_bytes_raw()
    user_id = encode_id(pub)
    bundle = {
        "user_id": user_id,
        "identity_key": b64(pub),
        "signed_prekey_id": 1,
        "signed_prekey": b64(os.urandom(32)),       # Platzhalter (echte Werte: libsignal)
        "signed_prekey_sig": b64(os.urandom(64)),
        "one_time_prekeys": [{"key_id": i, "public_key": b64(os.urandom(32))} for i in range(5)],
    }
    return {"priv": priv, "user_id": user_id, "bundle": bundle}


async def connect_authed(user):
    """WS-Verbindung aufbauen und die Challenge des Servers signieren."""
    ws = await websockets.connect(f"{WS}?user_id={user['user_id']}")
    challenge = json.loads(await ws.recv())
    assert challenge["type"] == "challenge"
    nonce = base64.b64decode(challenge["nonce"])
    signature = user["priv"].sign(nonce)
    await ws.send(json.dumps({"signature": b64(signature)}))
    result = json.loads(await ws.recv())
    assert result.get("ok") is True, "Auth fehlgeschlagen"
    return ws


async def main():
    passed = []

    async with httpx.AsyncClient() as http:
        alice, bob = make_user(), make_user()

        # ---- Registrierung ----
        r1 = await http.post(f"{BASE}/register", json=alice["bundle"])
        r2 = await http.post(f"{BASE}/register", json=bob["bundle"])
        assert r1.json()["ok"] and r2.json()["ok"]
        print(f"[i] Alice ID: {alice['user_id'][:24]}...")
        print(f"[i] Bob   ID: {bob['user_id'][:24]}...")

        # ---- Alice holt Bobs Prekey-Bundle (X3DH-Vorbereitung) ----
        pk = (await http.get(f"{BASE}/prekey/{bob['user_id']}")).json()
        ok_prekey = pk["identity_key"] == bob["bundle"]["identity_key"] and pk["one_time_prekey"] is not None
        passed.append(("Prekey-Bundle abrufen", ok_prekey))

        # ---- Test 1: beide online ----
        bob_ws = await connect_authed(bob)
        alice_ws = await connect_authed(alice)
        secret_ct = b64(b"<verschluesselter-blob-1>")
        await alice_ws.send(json.dumps({"type": "message", "to": bob["user_id"], "ciphertext": secret_ct}))
        await alice_ws.recv()  # ack
        msg = json.loads(await asyncio.wait_for(bob_ws.recv(), timeout=5))
        ok_online = msg["type"] == "message" and msg["from"] == alice["user_id"] and msg["ciphertext"] == secret_ct
        passed.append(("Live-Zustellung (beide online)", ok_online))

        # ---- Test 2: Empfaenger offline -> puffern -> Reconnect ----
        await bob_ws.close()
        await asyncio.sleep(0.2)
        offline_ct = b64(b"<verschluesselter-blob-2>")
        await alice_ws.send(json.dumps({"type": "message", "to": bob["user_id"], "ciphertext": offline_ct}))
        await alice_ws.recv()  # ack
        bob_ws2 = await connect_authed(bob)
        queued = json.loads(await asyncio.wait_for(bob_ws2.recv(), timeout=5))
        ok_offline = queued["type"] == "message" and queued["ciphertext"] == offline_ct
        passed.append(("Offline-Zustellung (gepuffert)", ok_offline))

        # ---- Test 3: Auth mit falscher Signatur muss scheitern ----
        ok_authfail = False
        try:
            bad_ws = await websockets.connect(f"{WS}?user_id={alice['user_id']}")
            json.loads(await bad_ws.recv())  # challenge
            await bad_ws.send(json.dumps({"signature": b64(os.urandom(64))}))  # Muell
            res = json.loads(await bad_ws.recv())
            ok_authfail = res.get("ok") is False
            await bad_ws.close()
        except Exception:
            ok_authfail = True
        passed.append(("Falsche Signatur wird abgelehnt", ok_authfail))

        await alice_ws.close()
        await bob_ws2.close()

    print("\n=== Ergebnis ===")
    for name, ok in passed:
        print(f"  [{'PASS' if ok else 'FAIL'}]  {name}")
    all_ok = all(ok for _, ok in passed)
    print(f"\n{'ALLE TESTS BESTANDEN' if all_ok else 'ES GAB FEHLER'} ({sum(ok for _, ok in passed)}/{len(passed)})")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
