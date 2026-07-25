"""
test_relay.py  --  End-to-End-Test fuer den BitDM-Relay-Server.

Spielt echte Nutzer ueber echte Netzwerk-Sockets durch. Der "Ciphertext" ist ein
Platzhalter-Blob — getestet wird der SERVER, nicht die App-Krypto.

Neben dem Normalbetrieb werden gezielt die Angriffe geprueft, gegen die der
Server gehaertet wurde:
  S2  fremdes Bundle ueberschreiben, Registrierung ohne/mit falschem Nachweis
  S4  uebergrosser Ciphertext
      One-Time-Prekeys duerfen nur genau einmal ausgegeben werden

Start des Servers vorher:
    py -m uvicorn relay_server:app --app-dir server --host 127.0.0.1 --port 8099
"""

import asyncio
import base64
import hashlib
import json
import os

import httpx
import websockets
from xeddsa.bindings import (ed25519_priv_sign, priv_force_sign,
                             priv_to_curve25519_pub)

from relay_server import PreKeyBundle
from signature_vectors import DART_SIGNATURES, MESSAGE

# Standard: ein lokal gestarteter Server. Fuer einen Lauf gegen die echte
# Instanz hinter nginx:
#
#   BITDM_TEST_BASE=https://relay.bitdm.net py -3 test_relay.py
#
# Das ist der einzige Weg, die Kette WIRKLICH zu pruefen — nginx, TLS,
# WebSocket-Upgrade, Zeitgrenzen und Ratenbegrenzung sind bei einem Lauf gegen
# 127.0.0.1 alle nicht dabei.
BASE = os.getenv("BITDM_TEST_BASE", "http://127.0.0.1:8099").rstrip("/")
WS = BASE.replace("https://", "wss://").replace("http://", "ws://") + "/ws"


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def encode_id(public_key_bytes: bytes) -> str:
    """Muss exakt der Serverfunktion entsprechen: 56 Zeichen, 3-Byte-Pruefsumme."""
    checksum = hashlib.sha256(public_key_bytes).digest()[:3]
    return base64.b32encode(public_key_bytes + checksum).decode("ascii").lower()


def sign(priv: bytes, msg: bytes) -> bytes:
    """XEdDSA nach Spezifikation, mit erzwungenem Vorzeichenbit 0.

    ACHTUNG — das deckt NICHT den ganzen Server ab.
    libxeddsa erzwingt beim Signieren ein Vorzeichenbit von 0. libsignal, also
    der echte Client, behaelt dagegen das natuerliche Vorzeichen und legt es in
    das oberste Bit der Signatur. Signaturen aus diesem Test haben deshalb immer
    Bit 0 — die andere Haelfte des Wertebereichs bleibt ungeprueft.

    Genau daran ist die urspruengliche Fassung gescheitert: sie signierte mit
    demselben falschen Vorzeichenbit, mit dem der Server prueffte. Test und
    Implementierung teilten die Annahme, waren in sich stimmig und beide falsch —
    15/15 gruen, waehrend echte Clients zur Haelfte abgewiesen worden waeren.

    Die Luecke schliesst test_signature_vectors() weiter unten mit echten
    Signaturen aus dem Dart-Client.
    """
    return ed25519_priv_sign(priv_force_sign(priv, False), msg)


def canonical_bytes(bundle: dict) -> bytes:
    """Nutzt die Funktion des Servers selbst statt einer Nachbildung.

    Hier stand frueher eine zweite Umsetzung derselben Serialisierung. Das ist
    genau die Sorte Kopie, die irgendwann auseinanderlaeuft: wer im Server ein
    Feld ergaenzt und die Kopie vergisst, bekommt einen Test, der gruen bleibt,
    waehrend echte Clients abgewiesen werden.

    Der Dart-Client MUSS eine eigene Umsetzung haben — andere Sprache. Genau
    deshalb prueft app/test/net/relay_protocol_test.dart ihn gegen erzeugte
    Vergleichswerte aus diesem Server.
    """
    return PreKeyBundle(**bundle).canonical_bytes()


def make_user(n_otk: int = 5):
    priv = os.urandom(32)
    pub = priv_to_curve25519_pub(priv)
    bundle = {
        "user_id": encode_id(pub),
        "identity_key": b64(pub),
        "registration_id": 4711,
        "signed_prekey_id": 1,
        "signed_prekey": b64(os.urandom(32)),        # Platzhalter (echt: libsignal)
        "signed_prekey_sig": b64(os.urandom(64)),
        "one_time_prekeys": [
            {"key_id": i, "public_key": b64(os.urandom(32))} for i in range(n_otk)
        ],
    }
    return {"priv": priv, "user_id": bundle["user_id"], "bundle": bundle}


async def register(http, user, *, signer_priv=None, skip_challenge=False):
    """Registrierung mit Besitznachweis. signer_priv erlaubt es, absichtlich
    mit dem falschen Schluessel zu signieren."""
    bundle = user["bundle"]
    if skip_challenge:
        return await http.post(f"{BASE}/register",
                               json={"bundle": bundle, "signature": b64(os.urandom(64))})

    chal = await http.post(f"{BASE}/register/challenge", json={"user_id": bundle["user_id"]})
    nonce = base64.b64decode(chal.json()["nonce"])
    message = nonce + hashlib.sha256(canonical_bytes(bundle)).digest()
    signature = sign(signer_priv or user["priv"], message)
    return await http.post(f"{BASE}/register",
                           json={"bundle": bundle, "signature": b64(signature)})


async def connect_authed(user):
    """WS-Verbindung aufbauen und die Challenge des Servers signieren."""
    ws = await websockets.connect(f"{WS}?user_id={user['user_id']}")
    challenge = json.loads(await ws.recv())
    assert challenge["type"] == "challenge"
    nonce = base64.b64decode(challenge["nonce"])
    await ws.send(json.dumps({"signature": b64(sign(user["priv"], nonce))}))
    result = json.loads(await ws.recv())
    assert result.get("ok") is True, "Auth fehlgeschlagen"
    return ws


async def expect(ws, wanted_type, timeout=5):
    """Liest, bis eine Nachricht des gewuenschten Typs kommt.

    Noetig, weil der Server auch unaufgefordert sendet — direkt nach der Auth
    z. B. `prekeys_low`, und nach jedem Versand ein `ack`. Ohne dieses
    Ueberspringen liest ein Test die Antwort auf die falsche Anfrage.
    """
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
        if msg.get("type") == wanted_type:
            return msg


async def main():
    passed = []

    def check(name, ok):
        passed.append((name, bool(ok)))

    async with httpx.AsyncClient(timeout=10) as http:
        alice, bob = make_user(), make_user()

        # ------------------------------- Signaturpruefung gegen echte Clients
        # Der wichtigste Test der Datei. Er benutzt Signaturen, die der echte
        # Dart-Client erzeugt hat — die Haelfte davon mit gesetztem
        # Vorzeichenbit. Genau die wurden vom Server frueher abgelehnt.
        from relay_server import verify_signature
        angenommen = sum(
            1 for pk, sig in DART_SIGNATURES
            if verify_signature(base64.b64decode(pk), MESSAGE, base64.b64decode(sig))
        )
        check("Echte libsignal-Signaturen werden akzeptiert",
              angenommen == len(DART_SIGNATURES))
        mit_bit = sum(1 for _, sig in DART_SIGNATURES
                      if base64.b64decode(sig)[63] & 0x80)
        check("Vektoren decken beide Vorzeichenbits ab",
              0 < mit_bit < len(DART_SIGNATURES))
        # Manipulation muss weiterhin scheitern
        pk0, sig0 = DART_SIGNATURES[0]
        kaputt = bytearray(base64.b64decode(sig0)); kaputt[0] ^= 1
        check("Veraenderte Signatur wird abgelehnt",
              not verify_signature(base64.b64decode(pk0), MESSAGE, bytes(kaputt)))

        # ---------------------------------------------------- Grundfunktionen
        check("Adresse ist 56 Zeichen", len(alice["user_id"]) == 56)

        r1 = await register(http, alice)
        r2 = await register(http, bob)
        check("Registrierung mit Besitznachweis", r1.status_code == 200 and r2.status_code == 200)

        pk = (await http.get(f"{BASE}/prekey/{bob['user_id']}")).json()
        check("Prekey-Bundle abrufen",
              pk["identity_key"] == bob["bundle"]["identity_key"]
              and pk["one_time_prekey"] is not None)

        # One-Time-Prekeys duerfen nie doppelt vergeben werden
        seen = {pk["one_time_prekey"]["key_id"]}
        dup = False
        for _ in range(4):
            got = (await http.get(f"{BASE}/prekey/{bob['user_id']}")).json()["one_time_prekey"]
            if got is None:
                break
            if got["key_id"] in seen:
                dup = True
            seen.add(got["key_id"])
        check("One-Time-Prekey nur einmal vergeben", not dup)

        # ------------------------------------- S3: Prekey-Drain laeuft ins Leere
        # Opfer mit vielen Prekeys; ein Angreifer versucht, den Pool zu leeren.
        victim = make_user(n_otk=60)
        await register(http, victim)
        handed_out = 0
        for _ in range(40):
            got = (await http.get(f"{BASE}/prekey/{victim['user_id']}")).json()
            if got["one_time_prekey"] is not None:
                handed_out += 1
        # Das Bundle bleibt weiterhin abrufbar (Sitzungsaufbau bleibt moeglich),
        # aber die Zahl ausgegebener One-Time-Prekeys ist gedeckelt.
        still_reachable = (await http.get(f"{BASE}/prekey/{victim['user_id']}")).status_code
        check("S3: Prekey-Drain gedeckelt", handed_out <= 12)
        check("S3: Bundle trotz Drosselung erreichbar", still_reachable == 200)

        # ------------------------------------------------------- S2: Angriffe
        mallory = make_user()

        # (a) Registrierung ohne vorherige Challenge
        r = await register(http, mallory, skip_challenge=True)
        check("S2: Registrierung ohne Nonce abgelehnt", r.status_code == 401)

        # (b) Richtiges Nonce, aber mit fremdem Schluessel signiert
        r = await register(http, mallory, signer_priv=os.urandom(32))
        check("S2: falsche Signatur abgelehnt", r.status_code == 403)

        # (c) Angreifer will Alices Bundle mit eigenen Prekeys ueberschreiben
        forged = {
            "priv": mallory["priv"],
            "user_id": alice["user_id"],
            "bundle": {**alice["bundle"],
                       "one_time_prekeys": [{"key_id": 99, "public_key": b64(os.urandom(32))}]},
        }
        r = await register(http, forged)          # signiert mit Mallorys Schluessel
        check("S2: fremdes Bundle ueberschreiben abgelehnt", r.status_code == 403)

        # ------------------------------------------------------ Zustellung
        bob_ws = await connect_authed(bob)
        alice_ws = await connect_authed(alice)

        secret_ct = b64(b"<verschluesselter-blob-1>")
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"], "ciphertext": secret_ct}))
        msg = await expect(bob_ws, "message")
        check("Live-Zustellung (beide online)",
              msg["from"] == alice["user_id"] and msg["ciphertext"] == secret_ct)

        await bob_ws.close()
        await asyncio.sleep(0.3)
        offline_ct = b64(b"<verschluesselter-blob-2>")
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"], "ciphertext": offline_ct}))
        bob_ws2 = await connect_authed(bob)
        queued = await expect(bob_ws2, "message")
        check("Offline-Zustellung (gepuffert)", queued["ciphertext"] == offline_ct)

        # Nach Zustellung muss die Warteschlange leer sein (keine Doppel-Zustellung)
        await bob_ws2.close()
        await asyncio.sleep(0.3)
        bob_ws3 = await connect_authed(bob)
        try:
            again = await expect(bob_ws3, "message", timeout=1.5)
            check("Zugestellte Nachricht wird geloescht", False)
        except asyncio.TimeoutError:
            check("Zugestellte Nachricht wird geloescht", True)

        # -------------------------------------------------------- S4: Groesse
        huge = b64(os.urandom(128 * 1024))        # > 64 KiB Grenze
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"], "ciphertext": huge}))
        resp = await expect(alice_ws, "error")
        check("S4: uebergrosser Ciphertext abgelehnt", "gross" in resp.get("reason", ""))

        # Ungueltige Zieladresse
        await alice_ws.send(json.dumps(
            {"type": "message", "to": "keine-gueltige-adresse", "ciphertext": secret_ct}))
        resp = await expect(alice_ws, "error")
        check("Ungueltige Zieladresse abgelehnt", "Zieladresse" in resp.get("reason", ""))

        # ------------------------------------------------ WS-Auth mit Muell
        ok_authfail = False
        try:
            bad = await websockets.connect(f"{WS}?user_id={alice['user_id']}")
            json.loads(await bad.recv())                       # challenge
            await bad.send(json.dumps({"signature": b64(os.urandom(64))}))
            res = json.loads(await bad.recv())
            ok_authfail = res.get("ok") is False
            await bad.close()
        except Exception:
            ok_authfail = True
        check("Falsche WS-Signatur wird abgelehnt", ok_authfail)

        # ═══════════════════════════════════ Anstoss-Endpunkt (UnifiedPush)
        #
        # DER GEFAEHRLICHSTE TEIL DIESER FUNKTION: der Relay schickt eine
        # Anfrage an eine Adresse, die ein Client ihm nennt. Ohne Pruefung
        # waere er ein Werkzeug, mit dem sich beliebige fremde Server
        # anschreiben lassen — jemand traegt eine fremde Adresse ein und laesst
        # den Relay fuer sich klopfen. Genau dafuer sind die naechsten Tests da.
        from relay_server import push_endpunkt_gueltig

        gut = "https://push.bitdm.net/upAbc123_-xyz"
        check("Eigener Push-Endpunkt wird angenommen",
              push_endpunkt_gueltig(gut))

        schlecht = {
            "fremder Host":        "https://evil.example.com/upAbc123",
            "ohne TLS":            "http://push.bitdm.net/upAbc123",
            "fremder Pfad":        "https://push.bitdm.net/admin",
            "Pfad ohne up-Praefix":"https://push.bitdm.net/geheim123",
            "Pfadwanderung":       "https://push.bitdm.net/upAbc/../admin",
            "leer":                "",
            "kein String":         None,
            "zu lang":             "https://push.bitdm.net/up" + "A" * 600,
            "Host im Nutzerteil":  "https://push.bitdm.net@evil.example.com/upAbc",
        }
        for name, url in schlecht.items():
            check(f"Push-Endpunkt abgelehnt: {name}",
                  not push_endpunkt_gueltig(url))

        # Ueber die Verbindung eintragen und wieder loeschen.
        await alice_ws.send(json.dumps(
            {"type": "push_endpoint", "endpoint": gut}))
        res = json.loads(await alice_ws.recv())
        check("Endpunkt laesst sich eintragen",
              res.get("type") == "push_ok" and res.get("set") is True)

        await alice_ws.send(json.dumps(
            {"type": "push_endpoint", "endpoint": "https://evil.example.com/upX"}))
        res = json.loads(await alice_ws.recv())
        check("Fremder Endpunkt wird ueber die Verbindung abgelehnt",
              res.get("type") == "error")

        await alice_ws.send(json.dumps({"type": "push_endpoint", "endpoint": ""}))
        res = json.loads(await alice_ws.recv())
        check("Endpunkt laesst sich wieder loeschen",
              res.get("type") == "push_ok" and res.get("set") is False)

        await alice_ws.close()
        await bob_ws3.close()

    print("\n=== Ergebnis ===")
    for name, ok in passed:
        print(f"  [{'PASS' if ok else 'FAIL'}]  {name}")
    n_ok = sum(ok for _, ok in passed)
    print(f"\n{'ALLE TESTS BESTANDEN' if n_ok == len(passed) else 'ES GAB FEHLER'} "
          f"({n_ok}/{len(passed)})")
    return 0 if n_ok == len(passed) else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
