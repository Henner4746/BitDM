"""Der Durchstich: App -> Relay -> Zwischenlager, ueber die echten Adressen.

Was hier zum ERSTEN MAL zusammen laeuft und in keinem lokalen Test vorkommt:

  * die WebSocket-Anmeldung gegen relay.bitdm.net durch nginx und TLS,
  * eine Marke, die der LAUFENDE Relay mit dem Geheimnis aus seiner
    systemd-Umgebung unterschreibt,
  * dieselbe Marke, gegen die der LAUFENDE Blob-Dienst auf einem ANDEREN
    Rechner prueft.

Weicht das Format der Unterschrift zwischen den beiden Maschinen um ein
Zeichen ab, laeuft alles andere weiter und nur die Uploads scheitern — mit
403 und ohne einen Hinweis darauf, woran es liegt. Genau dafuer ist dieser
Lauf da. Ein Test gegen 127.0.0.1 kann ihn nicht ersetzen: die beiden
Geheimnisse liegen auf zwei Rechnern, und ob sie uebereinstimmen, zeigt sich
nur hier.

Die Wegwerf-Identitaet wird am Ende wieder aus der Datenbank entfernt. Deshalb
laeuft das Skript AUF dem Relay-Rechner und nicht von aussen — es braucht die
Datenbank, um hinter sich aufzuraeumen.

Start (auf dem Haupt-VPS, als root):
    /opt/bitdm-relay/venv/bin/python durchstich_zwischenlager.py
"""

import asyncio
import base64
import hashlib
import json
import secrets
import sqlite3
import sys

import httpx
import websockets
from xeddsa.bindings import ed25519_priv_sign, priv_force_sign, priv_to_curve25519_pub

RELAY = "https://relay.bitdm.net"
WS = "wss://relay.bitdm.net/ws"
DB = "/var/lib/bitdm-relay/relay.db"
QUELLE = "/opt/bitdm/secure-messenger/server"


def b64(b):
    return base64.b64encode(b).decode()


def kennung_id(pub):
    return base64.b32encode(pub + hashlib.sha256(pub).digest()[:3]).decode().lower()


def sign(priv, msg):
    return ed25519_priv_sign(priv_force_sign(priv, False), msg)


def kanonisch(bundle):
    """Nimmt die Funktion des Servers SELBST, keine Nachbildung.

    Eine zweite Umsetzung derselben Serialisierung laeuft frueher oder spaeter
    auseinander — und dann prueft dieser Lauf etwas anderes als das, was
    wirklich passiert. Genau daran ist der erste Versuch gescheitert.
    """
    sys.path.insert(0, QUELLE)
    from relay_server import PreKeyBundle
    return PreKeyBundle(**bundle).canonical_bytes()


async def main():
    priv = secrets.token_bytes(32)
    pub = priv_to_curve25519_pub(priv)
    user_id = kennung_id(pub)
    spk_priv = secrets.token_bytes(32)
    spk_pub = priv_to_curve25519_pub(spk_priv)

    bundle = {
        "user_id": user_id,
        "identity_key": b64(pub),
        "registration_id": 4711,
        "signed_prekey_id": 1,
        "signed_prekey": b64(spk_pub),
        "signed_prekey_sig": b64(sign(priv, spk_pub)),
        "one_time_prekeys": [
            {"key_id": i,
             "public_key": b64(priv_to_curve25519_pub(secrets.token_bytes(32)))}
            for i in range(1, 4)
        ],
    }

    fehler = 0

    def pruefe(was, ok):
        nonlocal fehler
        print(f"  {'ok   ' if ok else 'FEHLT'} {was}")
        if not ok:
            fehler += 1

    async with httpx.AsyncClient(timeout=20) as http:
        chal = await http.post(f"{RELAY}/register/challenge", json={"user_id": user_id})
        nonce = base64.b64decode(chal.json()["nonce"])
        sig = sign(priv, nonce + hashlib.sha256(kanonisch(bundle)).digest())
        r = await http.post(f"{RELAY}/register",
                            json={"bundle": bundle, "signature": b64(sig)})
        pruefe("Wegwerf-Identitaet angemeldet", r.status_code == 200)
        if r.status_code != 200:
            print(r.text)
            return 1

    # AB HIER GIBT ES DIE WEGWERF-IDENTITAET IN DER ECHTEN DATENBANK, und sie
    # muss wieder heraus — auch wenn unterwegs etwas scheitert. Vorher stand
    # das Aufraeumen nur am Ende: am 25.09.2026 lief das Hochladen in einen
    # ConnectTimeout (Storage-VPS offline), das Skript brach ab, und zwei
    # Wegwerf-Identitaeten blieben in der Relay-Datenbank liegen.
    try:
        return await _durchstich(priv, user_id, pruefe) or fehler
    except Exception as e:  # noqa: BLE001 — jeder Abbruch ist ein Befund
        pruefe(f"Durchstich brach ab: {type(e).__name__}: {e}", False)
        return fehler
    finally:
        _raeume_auf(user_id, pruefe)
        print("\nALLES GRUEN" if fehler == 0 else f"\n{fehler} FEHLGESCHLAGEN")


def _raeume_auf(user_id, pruefe):
    # Die Marken-Zeile bleibt — sie faellt nach 24 Stunden von selbst weg und
    # enthaelt ohnehin nur eine Zahl.
    c = sqlite3.connect(DB, timeout=10)
    with c:
        c.execute("DELETE FROM identities WHERE user_id=?", (user_id,))
        c.execute("DELETE FROM one_time_prekeys WHERE user_id=?", (user_id,))
    uebrig = c.execute(
        "SELECT COUNT(*) FROM identities WHERE user_id=?", (user_id,)).fetchone()[0]
    pruefe("Wegwerf-Identitaet wieder entfernt", uebrig == 0)


async def _durchstich(priv, user_id, pruefe):
    ws = await websockets.connect(f"{WS}?user_id={user_id}")
    # Auch beim Abbruch schliessen: sonst meldet asyncio beim Beenden einen
    # "Fatal error on SSL transport", der wie ein zweiter Fehler aussieht.
    try:
        return await _mit_verbindung(ws, priv, pruefe)
    finally:
        await ws.close()


async def _mit_verbindung(ws, priv, pruefe):
    ch = json.loads(await ws.recv())
    await ws.send(json.dumps({"signature": b64(sign(priv, base64.b64decode(ch["nonce"])))}))
    auth = json.loads(await ws.recv())
    pruefe("ueber TLS und nginx angemeldet", auth.get("ok") is True)

    inhalt = secrets.token_bytes(3 * 1024 * 1024)
    k = base64.b32encode(secrets.token_bytes(32)).decode().rstrip("=").lower()

    await ws.send(json.dumps(
        {"type": "blob_marke", "kennung": k, "groesse": len(inhalt)}))
    while True:
        antwort = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
        if antwort.get("type") in ("blob_marke_ok", "error"):
            break
    pruefe("Der laufende Relay stellt eine Marke aus",
           antwort.get("type") == "blob_marke_ok")
    if antwort.get("type") != "blob_marke_ok":
        print(antwort)
        return 1

    # Zehn Sekunden fuer den Verbindungsaufbau: ein Lager, das gar nicht
    # antwortet, soll als solches gemeldet werden und nicht erst nach zwei
    # Minuten.
    async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=10)) as http:
        r = await http.put(
            antwort["ablegen"], content=inhalt,
            headers={"X-Bitdm-Size": str(len(inhalt)),
                     "X-Bitdm-Expires": str(antwort["ablauf"]),
                     "X-Bitdm-Token": antwort["marke"]})
        pruefe("DER DURCHSTICH: das Lager nimmt die Marke des Relays an",
               r.status_code == 200)
        if r.status_code != 200:
            print(r.status_code, r.text)

        r = await http.get(antwort["holen"])
        pruefe("und liefert dieselben Bytes zurueck",
               r.status_code == 200 and r.content == inhalt)

        r = await http.delete(antwort["wegwerfen"])
        pruefe("wegwerfen geht", r.status_code == 200)
        r = await http.get(antwort["holen"])
        pruefe("danach ist es weg", r.status_code == 404)

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
