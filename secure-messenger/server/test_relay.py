"""
test_relay.py  --  End-to-End-Test fuer den BitDM-Relay-Server.

DIESE DATEI HAT ZWEI HAELFTEN, und sie werden verschieden gestartet.

1. `main()` weiter unten spielt echte Nutzer ueber echte Netzwerk-Sockets
   durch und braucht einen LAUFENDEN Server. Der "Ciphertext" ist ein
   Platzhalter-Blob — getestet wird der SERVER, nicht die App-Krypto.
   Neben dem Normalbetrieb werden gezielt die Angriffe geprueft, gegen die der
   Server gehaertet wurde:
     S2  fremdes Bundle ueberschreiben, Registrierung ohne/mit falschem Nachweis
     S4  uebergrosser Ciphertext
         One-Time-Prekeys duerfen nur genau einmal ausgegeben werden

       py -m uvicorn relay_server:app --app-dir server --host 127.0.0.1 --port 8099
       py test_relay.py

2. Die `test_*`-Funktionen ganz unten laufen unter pytest, ohne Server und
   ohne Netz. Sie decken das ab, was sich von aussen NICHT zuverlaessig
   treffen laesst: zwei Threads auf derselben SQLite-Verbindung, ein Abriss
   mitten in der Nachzustellung, die Riegel gegen das Volllaufen der
   Warteschlange und den Anstoss-Weg.

       py -m pytest test_relay.py -q

   pytest sammelt aus Haelfte 1 nichts ein (main() ist keine Testfunktion),
   und der Skriptlauf ruehrt Haelfte 2 nicht an. Die beiden stoeren sich also
   nicht.
"""

import asyncio
import base64
import hashlib
import http.server
import json
import os
import re
import socket
import threading
import time
from pathlib import Path

import httpx
import pytest
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


async def connect_authed(user, *, nachweis=False):
    """WS-Verbindung aufbauen und die Challenge des Servers signieren.

    [nachweis] kuendigt an, dass diese Gegenstelle den Empfangsnachweis
    beherrscht — dasselbe Feld im selben Rahmen, das auch der echte Client
    setzt. OHNE das Argument verhaelt sich dieser Helfer wie eine der im
    Umlauf befindlichen aelteren App-Fassungen, und genau darauf bauen die
    Tests weiter oben: sie sind der Regressionswall dafuer, dass ein alter
    Client nicht schlechter bedient wird als vor der Aenderung.
    """
    ws = await websockets.connect(f"{WS}?user_id={user['user_id']}")
    challenge = json.loads(await ws.recv())
    assert challenge["type"] == "challenge"
    nonce = base64.b64decode(challenge["nonce"])
    antwort = {"signature": b64(sign(user["priv"], nonce))}
    if nachweis:
        antwort["empfangsnachweis"] = True
    await ws.send(json.dumps(antwort))
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
        #
        # DER REGRESSIONSWALL FUER DIE ALTEN APP-FASSUNGEN IM UMLAUF: dieser
        # bob hat sich OHNE `nachweis=True` angemeldet, also wie eine App, die
        # den Empfangsnachweis nicht kennt. Fuer sie muss alles bleiben, wie es
        # war — sofort loeschen, kein zweites Mal zustellen. Wuerde der Server
        # auch ohne angekuendigtes Koennen auf einen Nachweis warten, bekaeme
        # jede alte App ihre Nachrichten bei jedem Verbinden erneut, und dieser
        # Test wird rot.
        await bob_ws2.close()
        await asyncio.sleep(0.3)
        bob_ws3 = await connect_authed(bob)
        try:
            again = await expect(bob_ws3, "message", timeout=1.5)
            check("Zugestellte Nachricht wird geloescht", False)
        except asyncio.TimeoutError:
            check("Zugestellte Nachricht wird geloescht", True)

        # ═══════════════════════════════════════════ Empfangsnachweis
        #
        # Der Verlust, den das behebt: geloescht wurde, sobald der Rahmen im
        # Schreibpuffer stand. Was danach auf der Strecke abriss, war weg —
        # und der Absender hatte sein `ack` seit Tagen.
        #
        # Hier laeuft es ueber ECHTE Sockets, weil genau das die Frage ist: ob
        # eine Zeile den Weg durch uvicorn, den Kernelpuffer und einen Abriss
        # ueberlebt. Die pytest-Haelfte unten trifft dafuer die Faelle, die
        # sich von aussen nicht stellen lassen.
        await bob_ws3.close()
        await asyncio.sleep(0.3)

        # (a) Die Anmeldung spiegelt zurueck, ob der Server es verstanden hat.
        #     Ohne diesen Rueckspiegel liesse sich ein neuer Client, der das
        #     Flag versehentlich nicht setzt, von einem alten Server nicht
        #     unterscheiden — er saehe in beiden Faellen einfach kein `q`.
        probe = await websockets.connect(f"{WS}?user_id={bob['user_id']}")
        chal = json.loads(await probe.recv())
        await probe.send(json.dumps({
            "signature": b64(sign(bob["priv"], base64.b64decode(chal["nonce"]))),
            "empfangsnachweis": True,
        }))
        res = json.loads(await probe.recv())
        check("Anmeldung bestaetigt das Koennen", res.get("empfangsnachweis") is True)
        await probe.close()
        await asyncio.sleep(0.3)

        probe = await websockets.connect(f"{WS}?user_id={bob['user_id']}")
        chal = json.loads(await probe.recv())
        await probe.send(json.dumps(
            {"signature": b64(sign(bob["priv"], base64.b64decode(chal["nonce"])))}))
        res = json.loads(await probe.recv())
        check("Ohne Flag meldet die Anmeldung kein Koennen",
              res.get("empfangsnachweis") is False)
        await probe.close()
        await asyncio.sleep(0.3)

        # (b) Wer den Nachweis kann, ihn aber nicht schickt, bekommt die
        #     Nachricht noch einmal. Der Server wartet dabei NIE auf ihn — er
        #     verschiebt nur das Loeschen.
        halten_ct = b64(b"<verschluesselter-blob-3>")
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"], "ciphertext": halten_ct}))
        await expect(alice_ws, "ack")

        bob_n1 = await connect_authed(bob, nachweis=True)
        erste = await expect(bob_n1, "message")
        check("Gepufferter Rahmen traegt eine ganzzahlige Kennung",
              isinstance(erste.get("q"), int) and not isinstance(erste.get("q"), bool))
        await bob_n1.close()
        await asyncio.sleep(0.3)

        bob_n2 = await connect_authed(bob, nachweis=True)
        wieder = await expect(bob_n2, "message")
        check("Ohne Nachweis kommt die Nachricht wieder",
              wieder["ciphertext"] == halten_ct)

        # (c) Und mit Nachweis ist sie weg.
        await bob_n2.send(json.dumps({"type": "empfangen", "ids": [wieder["q"]]}))
        # Auf den Nachweis gibt es KEINE Antwort — der Client koennte mit ihr
        # nichts anfangen. Deshalb hier kurz warten statt lesen.
        await asyncio.sleep(0.4)
        await bob_n2.close()
        await asyncio.sleep(0.3)

        bob_n3 = await connect_authed(bob, nachweis=True)
        try:
            await expect(bob_n3, "message", timeout=1.5)
            check("Nach dem Nachweis ist die Zeile weg", False)
        except asyncio.TimeoutError:
            check("Nach dem Nachweis ist die Zeile weg", True)
        await bob_n3.close()
        await asyncio.sleep(0.3)

        # (d) Der Kern: Abriss mitten in der Zustellung. Vorher waren die
        #     Umschlaege danach endgueltig weg — in der Datenbank geloescht,
        #     beim Client nie eingetroffen.
        for i in range(30):
            await alice_ws.send(json.dumps(
                {"type": "message", "to": bob["user_id"],
                 "ciphertext": b64(f"<blob-abriss-{i:02d}>".encode())}))
            await expect(alice_ws, "ack")

        bob_n4 = await connect_authed(bob, nachweis=True)
        await expect(bob_n4, "message")
        # HART abreissen und nicht close(): ein sauberes Schliessen wuerde die
        # Frage nicht stellen. Genau so faehrt ein Telefon in ein Funkloch.
        bob_n4.transport.abort()
        await asyncio.sleep(0.5)

        bob_n5 = await connect_authed(bob, nachweis=True)
        wiedergekommen = []
        try:
            while True:
                wiedergekommen.append(await expect(bob_n5, "message", timeout=2.0))
        except asyncio.TimeoutError:
            pass
        check("Abriss ohne Nachweis: alle 30 kommen wieder",
              len(wiedergekommen) == 30)

        # Und dieselben 30 raeumt der Nachweis wieder ab — sonst laege hier
        # ein Rest, der den naechsten Testabschnitt stoert.
        await bob_n5.send(json.dumps(
            {"type": "empfangen", "ids": [m["q"] for m in wiedergekommen]}))
        await asyncio.sleep(0.5)
        await bob_n5.close()
        await asyncio.sleep(0.3)

        bob_n6 = await connect_authed(bob, nachweis=True)
        rest = 0
        try:
            while True:
                await expect(bob_n6, "message", timeout=1.5)
                rest += 1
        except asyncio.TimeoutError:
            pass
        check("Ein Nachweis raeumt auch 30 Zeilen ab", rest == 0)
        await bob_n6.close()
        await asyncio.sleep(0.3)

        # (e) Muell im Nachweis darf die Verbindung nicht umbringen. Ohne die
        #     isinstance-Pruefungen wirft executemany, die Schleife endet, und
        #     das `ack` unten bleibt aus.
        muell_ws = await connect_authed(bob, nachweis=True)
        for kaputt in ({"type": "empfangen"},
                       {"type": "empfangen", "ids": "alles"},
                       {"type": "empfangen", "ids": [None, True, "x", 1.5]},
                       {"type": "empfangen", "ids": []}):
            await muell_ws.send(json.dumps(kaputt))
        await muell_ws.send(json.dumps(
            {"type": "message", "to": alice["user_id"],
             "ciphertext": b64(b"<lebt-noch>"), "id": "nach-muell"}))
        try:
            quittung = await expect(muell_ws, "ack", timeout=3.0)
            check("Muell im Nachweis laesst die Verbindung stehen",
                  quittung.get("id") == "nach-muell")
        except asyncio.TimeoutError:
            check("Muell im Nachweis laesst die Verbindung stehen", False)
        await muell_ws.close()
        await asyncio.sleep(0.3)

        # (f) Der wichtigste: fremde Warteschlangen bleiben fremd. Die
        #     Kennungen sind fortlaufend und damit zu erraten — ohne
        #     `AND recipient=?` im DELETE koennte jeder Angemeldete die
        #     Warteschlange eines anderen leeren.
        carol = make_user()
        await register(http, carol)
        fremd_ct = b64(b"<verschluesselter-blob-fremd>")
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"], "ciphertext": fremd_ct}))
        await expect(alice_ws, "ack")

        carol_ws = await connect_authed(carol, nachweis=True)
        await carol_ws.send(json.dumps(
            {"type": "empfangen", "ids": list(range(1, 200))}))
        await asyncio.sleep(0.5)
        await carol_ws.close()
        await asyncio.sleep(0.3)

        bob_n7 = await connect_authed(bob, nachweis=True)
        try:
            trotzdem = await expect(bob_n7, "message", timeout=3.0)
            check("Fremde Warteschlange laesst sich nicht leeren",
                  trotzdem["ciphertext"] == fremd_ct)
            await bob_n7.send(json.dumps(
                {"type": "empfangen", "ids": [trotzdem["q"]]}))
            await asyncio.sleep(0.4)
        except asyncio.TimeoutError:
            check("Fremde Warteschlange laesst sich nicht leeren", False)
        await bob_n7.close()
        await asyncio.sleep(0.3)

        # (g) Die Kennung steht NUR am gepufferten Rahmen. Der live
        #     weitergereichte hat keine Zeile, die sich bestaetigen liesse —
        #     ein `q` dort waere eine Einladung, fremde Kennungen zu loeschen.
        bob_live = await connect_authed(bob, nachweis=True)
        await asyncio.sleep(0.3)
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"],
             "ciphertext": b64(b"<live-ohne-kennung>")}))
        live = await expect(bob_live, "message")
        check("Der live weitergereichte Rahmen traegt keine Kennung",
              "q" not in live)
        await bob_live.close()
        await asyncio.sleep(0.3)

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

        # ------------------------------------- Marken fuer das Zwischenlager
        #
        # Der Server legt hier keine Datei ab und sieht auch keine. Er stellt
        # eine Erlaubnis aus, weil er als einziger schon weiss, wem diese
        # Adresse gehoert. Geprueft wird deshalb genau zweierlei: dass die
        # Unterschrift zu der passt, die blob_server.py erwartet, und dass die
        # Grenzen nicht vom Client bestimmt werden.
        import hmac as _hmac
        from relay_server import (BLOB_MAX_BYTES, BLOB_TAGESMENGE,
                                  blob_geheimnis)

        def kennung():
            return base64.b32encode(os.urandom(32)).decode().rstrip("=").lower()

        k = kennung()
        await alice_ws.send(json.dumps(
            {"type": "blob_marke", "kennung": k, "groesse": 1024}))
        res = await expect(alice_ws, "blob_marke_ok")
        check("Marke wird ausgestellt", res.get("kennung") == k)

        # DIE ENTSCHEIDENDE ZEILE. Hier rechnen zwei Programme dieselbe
        # Unterschrift aus, die auf zwei verschiedenen Rechnern laufen. Weicht
        # das Format um ein Zeichen ab, laeuft alles andere weiter und nur die
        # Uploads scheitern — mit 403, ohne dass irgendwo steht, warum.
        try:
            erwartet = _hmac.new(
                blob_geheimnis(),
                f"{k}|1024|{res['ablauf']}".encode(),
                hashlib.sha256,
            ).hexdigest()
            check("Unterschrift passt zu der, die das Lager prueft",
                  _hmac.compare_digest(erwartet, res.get("marke", "")))
        except OSError:
            check("Unterschrift passt zu der, die das Lager prueft (kein "
                  "Geheimnis auf dieser Maschine, uebersprungen)", True)

        check("Die Marke gilt nur begrenzt",
              0 < res["ablauf"] - time.time() <= 24 * 3600)
        check("Die Adressen zeigen auf das Lager, nicht auf den Relay",
              res.get("ablegen", "").endswith(f"/ablegen/{k}")
              and res.get("holen", "").endswith(f"/blob/{k}"))

        await alice_ws.send(json.dumps(
            {"type": "blob_marke", "kennung": "zu-kurz", "groesse": 1024}))
        res = await expect(alice_ws, "error")
        check("Unsinnige Kennung wird abgelehnt", "Kennung" in res.get("reason", ""))

        # Ohne diese Pruefung koennte sich ein Client eine Marke fuer eine
        # Groesse holen, die das Lager gar nicht annimmt — und merkte es erst
        # nach dem Hochladen.
        await alice_ws.send(json.dumps(
            {"type": "blob_marke", "kennung": kennung(),
             "groesse": BLOB_MAX_BYTES + 1}))
        res = await expect(alice_ws, "error")
        check("Zu grosse Datei wird abgelehnt", "Groesse" in res.get("reason", ""))

        for schlecht in (0, -1, "1024", 1.5, True, None):
            await alice_ws.send(json.dumps(
                {"type": "blob_marke", "kennung": kennung(), "groesse": schlecht}))
            res = await expect(alice_ws, "error")
            check(f"Groesse {schlecht!r} wird abgelehnt",
                  "Groesse" in res.get("reason", ""))

        # Die Tagesmenge. Sie ist die eigentliche Verteidigung — eine Adresse
        # anzulegen kostet nichts, also muss die Grenze an der Menge haengen
        # und nicht an der Identitaet.
        #
        # Ausgeschoepft wird sie in Brocken von je BLOB_MAX_BYTES. Ein einziger
        # Antrag ueber die ganze Tagesmenge waere GROESSER als eine einzelne
        # Datei sein darf und flaege schon an der Groessenpruefung raus — der
        # Test haette dann bestanden, ohne die Menge je zu beruehren.
        # Geschrieben wird dabei nichts: es sind Marken, keine Dateien.
        verbraucht = 1024
        marken = 0
        while verbraucht + BLOB_MAX_BYTES <= BLOB_TAGESMENGE:
            await alice_ws.send(json.dumps(
                {"type": "blob_marke", "kennung": kennung(),
                 "groesse": BLOB_MAX_BYTES}))
            res = await expect(alice_ws, "blob_marke_ok", timeout=5)
            if res.get("groesse") != BLOB_MAX_BYTES:
                break
            verbraucht += BLOB_MAX_BYTES
            marken += 1
        check("Bis zur Tagesmenge geht es",
              marken > 0 and verbraucht + BLOB_MAX_BYTES > BLOB_TAGESMENGE)

        await alice_ws.send(json.dumps(
            {"type": "blob_marke", "kennung": kennung(),
             "groesse": BLOB_MAX_BYTES}))
        res = await expect(alice_ws, "error")
        check("Darueber ist Schluss", "Tagesmenge" in res.get("reason", ""))
        check("Und es steht dabei, wie viel noch frei ist", "frei" in res)

        # Die Grenze gilt JE ADRESSE. Waere sie global, brauchte ein Angreifer
        # nur sein eigenes Kontingent zu verbrauchen, um alle anderen
        # auszusperren — aus einer Mengengrenze waere eine Abschaltung
        # geworden.
        bob_ws4 = await connect_authed(bob)
        await bob_ws4.send(json.dumps(
            {"type": "blob_marke", "kennung": kennung(), "groesse": 4096}))
        res = await expect(bob_ws4, "blob_marke_ok")
        check("Die Grenze trifft nur die eine Adresse", res.get("groesse") == 4096)
        await bob_ws4.close()

        await alice_ws.close()
        await bob_ws3.close()

    print("\n=== Ergebnis ===")
    for name, ok in passed:
        print(f"  [{'PASS' if ok else 'FAIL'}]  {name}")
    n_ok = sum(ok for _, ok in passed)
    print(f"\n{'ALLE TESTS BESTANDEN' if n_ok == len(passed) else 'ES GAB FEHLER'} "
          f"({n_ok}/{len(passed)})")
    return 0 if n_ok == len(passed) else 1


# =========================================================================== #
#  Haelfte 2: pytest, ohne Server und ohne Netz
# =========================================================================== #
#
# WARUM NICHT ALS check(...) IN main(): die vier Faelle hier brauchen Zugriff
# auf den Innenraum des Servers — zwei Threads auf DERSELBEN Verbindung, ein
# Abriss zwischen zwei Rahmen, ein Zaehler im Modul. Von aussen, ueber einen
# Socket, sind sie entweder gar nicht oder nur mit Gluecksspiel zu treffen.
#
# Der Aufbau ist deshalb bewusst nah am Code: die Endpunkte sind gewoehnliche
# Funktionen und werden als solche gerufen. Was dadurch NICHT mitgeprueft wird
# — nginx, TLS, echte Sockets, uvicorns WebSocket-Umsetzung — prueft Haelfte 1.


@pytest.fixture()
def relay(tmp_path, monkeypatch):
    """Ein frischer Relay je Test, ohne lifespan und ohne Netz.

    Kein importlib.reload wie in test_blob.py: relay_server liest DB_PATH erst
    im lifespan, es genuegt also, die Modulfelder zu setzen. monkeypatch
    stellt sie danach zurueck, sonst schleppte der naechste Test die Eimer und
    Verbindungen des vorigen mit.
    """
    import relay_server as rs

    conn = rs.init_db(tmp_path / "relay.db")
    monkeypatch.setattr(rs, "DB_PATH", tmp_path / "relay.db")
    monkeypatch.setattr(rs, "db", conn, raising=False)
    monkeypatch.setattr(rs, "_buckets", {})
    monkeypatch.setattr(rs, "_nonces", {})
    monkeypatch.setattr(rs, "connections", {})
    monkeypatch.setattr(rs, "_queue_zeilen", 0)
    try:
        yield rs
    finally:
        conn.close()


class _Anfrage:
    """Nur so viel Request, wie client_ip() anfasst."""

    headers: dict = {}
    client = None


def _lege_an(rs, user, n_otk=3):
    """Traegt eine Identitaet ein, ohne den ganzen /register-Weg zu gehen.

    Der Weg ueber /register braeuchte Nonce, Signatur und Ratenbegrenzung —
    alles schon in Haelfte 1 geprueft und hier nur Rauschen um den Punkt herum.
    """
    pub = base64.b64decode(user["bundle"]["identity_key"])
    with rs.db:
        rs.db.execute(
            "INSERT OR REPLACE INTO identities (user_id, identity_key,"
            " registration_id, signed_prekey_id, signed_prekey,"
            " signed_prekey_sig, updated_at) VALUES (?,?,?,?,?,?,?)",
            (user["user_id"], pub, 4711, 1, os.urandom(32), os.urandom(64),
             time.time()),
        )
        rs.db.executemany(
            "INSERT INTO one_time_prekeys (user_id, key_id, public_key)"
            " VALUES (?,?,?)",
            [(user["user_id"], i, os.urandom(32)) for i in range(n_otk)],
        )


def _puffere(rs, empfaenger, absender, n=1):
    """Legt n Zeilen direkt in die Warteschlange."""
    with rs.db:
        rs.db.executemany(
            "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
            [(empfaenger, absender, b"<blob>", time.time()) for _ in range(n)],
        )
    rs.queue_zeilen_neu_zaehlen()


# --------------------------------------------------------------------------- #
#  Befund A: geteilte SQLite-Verbindung
# --------------------------------------------------------------------------- #

class _Bremse:
    """Legt sich der geteilten Verbindung kurz VOR dem COMMIT in den Weg.

    Genau dieser Augenblick wird gebraucht: das DELETE ist gelaufen, committet
    ist es noch nicht. Ein Trace-Callback taugt dafuer nicht — der laeuft
    innerhalb von sqlite3_step und haelt dabei die Verbindung, der zweite
    Thread kaeme also gar nicht erst zum Zug.
    """

    def __init__(self, echt):
        self._echt = echt
        self.scharf = False
        self.im_gange = threading.Event()
        self.weiter = threading.Event()

    def __getattr__(self, name):
        return getattr(self._echt, name)

    def __enter__(self):
        self._echt.__enter__()
        return self

    def __exit__(self, *ausnahme):
        if self.scharf:
            self.scharf = False
            self.im_gange.set()
            self.weiter.wait(10.0)
        return self._echt.__exit__(*ausnahme)


def test_fremder_rollback_holt_den_ausgegebenen_prekey_nicht_zurueck(
        relay, monkeypatch):
    """Der Kern des Befundes, in der gefaehrlichen Richtung.

    Ohne `schreibsperre` in get_prekey nimmt der Rollback eines fremden
    Threads das DELETE mit zurueck — der Prekey steht dann wieder in der
    Tabelle, obwohl er schon im JSON an einen Anrufer gegangen ist. Der
    naechste bekommt denselben Einmalschluessel.
    """
    rs = relay
    ziel, stoerer = make_user(), make_user()
    _lege_an(rs, ziel, n_otk=3)

    bremse = _Bremse(rs.db)
    monkeypatch.setattr(rs, "db", bremse)

    ergebnis = {}

    def abholer():
        try:
            ergebnis["antwort"] = rs.get_prekey(ziel["user_id"], _Anfrage())
        except BaseException as exc:          # noqa: BLE001 — wird unten geprueft
            ergebnis["fehler"] = exc

    bremse.scharf = True
    a = threading.Thread(target=abholer)
    a.start()
    assert bremse.im_gange.wait(10.0), "der Abholer kam nie bis zum COMMIT"

    def stoerung():
        # Genau der Ausloeser aus /register: die Liste mit b64d(...) wird
        # INNERHALB von `with db:` gebaut und wirft bei kaputtem base64.
        # Nachgestellt statt ueber HTTP gerufen, damit der Ablauf
        # deterministisch bleibt und kein Produktions-SQL doppelt im Test steht.
        try:
            with rs.schreibsperre, rs.db:
                rs.db.execute(
                    "INSERT INTO identities (user_id, identity_key,"
                    " registration_id, signed_prekey_id, signed_prekey,"
                    " signed_prekey_sig, updated_at) VALUES (?,?,?,?,?,?,?)",
                    (stoerer["user_id"], b"k" * 32, 1, 1, b"s" * 32,
                     b"g" * 64, time.time()),
                )
                raise ValueError("kaputtes base64")
        except ValueError:
            pass

    b = threading.Thread(target=stoerung)
    b.start()
    time.sleep(0.5)
    bremse.weiter.set()
    a.join(15)
    b.join(15)

    assert "fehler" not in ergebnis, ergebnis.get("fehler")
    otk = ergebnis["antwort"]["one_time_prekey"]
    assert otk is not None, "ohne ausgegebenen Prekey prueft der Test nichts"
    zurueck = rs.db.execute(
        "SELECT key_id FROM one_time_prekeys WHERE user_id=? AND key_id=?",
        (ziel["user_id"], otk["key_id"]),
    ).fetchone()
    assert zurueck is None, "der ausgegebene Prekey liegt wieder in der Tabelle"


def test_prekey_haelt_die_sperre_ueber_die_ganze_anfrage(relay):
    """Der billige, direkte Mutationsmelder zu get_prekey.

    Deckt auch den SELECT mit ab: er soll in derselben Sperre liegen wie das
    DELETE, damit das ausgelieferte Bundle aus EINEM Zustand stammt.
    """
    rs = relay
    ziel = make_user()
    _lege_an(rs, ziel)

    fertig = threading.Event()

    def abholer():
        rs.get_prekey(ziel["user_id"], _Anfrage())
        fertig.set()

    with rs.schreibsperre:
        t = threading.Thread(target=abholer)
        t.start()
        assert not fertig.wait(0.5), "get_prekey lief an der Sperre vorbei"
    assert fertig.wait(10.0), "get_prekey kam nach der Sperre nicht durch"
    t.join(10)


def test_purge_committet_keine_halbfertige_registrierung(relay):
    """Die Gegenrichtung: ein fremdes COMMIT macht Halbfertiges dauerhaft.

    purge_expired laeuft stuendlich auf dem Event-Loop und committet auf
    derselben Verbindung. Ohne Sperre schreibt es die Identitaet eines
    Registrierungsversuchs fest, der gleich darauf scheitert — eine Adresse
    ohne einen einzigen Prekey, obwohl /register 400 gemeldet hat.
    """
    rs = relay
    halb = make_user()
    with rs.db:
        rs.db.execute(
            "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
            (halb["user_id"], halb["user_id"], b"<alt>",
             time.time() - rs.QUEUE_TTL_SECONDS - 60),
        )

    tor = threading.Event()
    weg = {}

    def halbfertig():
        try:
            with rs.schreibsperre, rs.db:
                rs.db.execute(
                    "INSERT INTO identities (user_id, identity_key,"
                    " registration_id, signed_prekey_id, signed_prekey,"
                    " signed_prekey_sig, updated_at) VALUES (?,?,?,?,?,?,?)",
                    (halb["user_id"], b"k" * 32, 1, 1, b"s" * 32, b"g" * 64,
                     time.time()),
                )
                tor.set()
                time.sleep(0.4)
                raise ValueError("kaputtes base64")
        except ValueError:
            pass

    def aufraeumen():
        tor.wait(10.0)
        weg["n"] = rs.purge_expired()

    x = threading.Thread(target=halbfertig)
    y = threading.Thread(target=aufraeumen)
    x.start()
    y.start()
    x.join(15)
    y.join(15)

    assert rs.db.execute(
        "SELECT 1 FROM identities WHERE user_id=?", (halb["user_id"],)
    ).fetchone() is None, "purge hat die halbfertige Registrierung festgeschrieben"
    # Die zweite Haelfte der Zusicherung: purge darf nicht bloss blockiert
    # worden sein, es muss die abgelaufene Zeile wirklich losgeworden sein.
    assert weg["n"] == 1
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 0


def test_keine_sperre_ueber_ein_await():
    """Haelt die Regel fest, an der ein Deadlock haengt.

    Das ist ein Textscan mit allen Grenzen eines Textscans — er sieht nur
    Einrueckung, nicht den Programmablauf. Er ist trotzdem das Einzige, was
    einen `await` innerhalb von `with schreibsperre` vor der Rueckkehr
    schuetzt: der Loop-Thread stuende dann in acquire(), die Koroutine mit der
    Sperre wuerde nie fortgesetzt, und asyncio.wait_for koennte es nicht
    abfangen.
    """
    quelle = (Path(__file__).with_name("relay_server.py")
              .read_text(encoding="utf-8").splitlines())
    verstoesse = []
    for i, zeile in enumerate(quelle):
        if "with schreibsperre" not in zeile.split("#")[0]:
            continue
        einzug = len(zeile) - len(zeile.lstrip())
        for j in range(i + 1, len(quelle)):
            folge = quelle[j]
            if not folge.strip():
                continue
            if len(folge) - len(folge.lstrip()) <= einzug:
                break
            if re.search(r"\bawait\b", folge.split("#")[0]):
                verstoesse.append((j + 1, folge.strip()))
    assert not verstoesse, f"await innerhalb der Sperre: {verstoesse}"


# --------------------------------------------------------------------------- #
#  Befund B: Nachzustellung ausserhalb von try/finally
# --------------------------------------------------------------------------- #

class _StummerSocket:
    """So viel WebSocket, wie ws_endpoint anfasst.

    Ein echter Socket taugt hier nicht: gebraucht wird ein Abriss an einer
    BESTIMMTEN Stelle der Nachzustellung, und der laesst sich ueber das Netz
    nur mit Gluecksspiel treffen.
    """

    def __init__(self, user_id, priv, *, antworten=None, reisst_bei=None,
                 nachweis=False, bestaetigt=False):
        self.query_params = {"user_id": user_id}
        self._priv = priv
        self._antworten = list(antworten or [])
        self._reisst_bei = reisst_bei
        # Kuendigt der Server-Gegenseite an, dass diese Verbindung den
        # Empfangsnachweis beherrscht. Steht per Vorgabe auf False, damit die
        # aelteren Tests weiterhin einen Alt-Client nachstellen.
        self._nachweis = nachweis
        # Schickt fuer jeden Rahmen mit `q` einen Nachweis nach — so, wie es
        # der echte Client nach dem Speichern tut.
        self._bestaetigt = bestaetigt
        self._nachrichten = 0
        self.gesendet = []
        self.geschlossen = None

    async def accept(self):
        pass

    async def send_json(self, obj):
        if obj.get("type") == "message":
            self._nachrichten += 1
            if self._reisst_bei is not None and self._nachrichten >= self._reisst_bei:
                raise relay_modul().WebSocketDisconnect(1006)
            if self._bestaetigt and obj.get("q") is not None:
                # ANGEHAENGT und nicht vorn eingefuegt: die Nachzustellung
                # laeuft komplett durch, bevor die Hauptschleife das erste Mal
                # liest — genau wie auf der Leitung.
                self._antworten.append(
                    {"type": "empfangen", "ids": [obj["q"]]})
        self.gesendet.append(obj)
        if obj.get("type") == "challenge":
            # Die Challenge wird gleich hier beantwortet: ohne gueltige
            # Signatur kaeme der Ablauf nie bis zur Nachzustellung.
            nonce = base64.b64decode(obj["nonce"])
            antwort = {"signature": b64(sign(self._priv, nonce))}
            if self._nachweis:
                antwort["empfangsnachweis"] = True
            self._antworten.insert(0, antwort)

    async def receive_json(self):
        if not self._antworten:
            raise relay_modul().WebSocketDisconnect(1000)
        return self._antworten.pop(0)

    async def close(self, code=None):
        self.geschlossen = code


class _Zuhoerer:
    """Ein verbundener Empfaenger, der nur mitschreibt."""

    def __init__(self):
        self.empfangen = []

    async def send_json(self, obj):
        self.empfangen.append(obj)


def relay_modul():
    import relay_server
    return relay_server


def _sitzung(rs, user, rahmen=(), **kw):
    """Eine ganze WebSocket-Sitzung durchspielen. Rueckgabe: was rausging."""
    sock = _StummerSocket(user["user_id"], user["priv"], antworten=list(rahmen),
                          **kw)
    asyncio.run(rs.ws_endpoint(sock))
    return sock.gesendet


def test_abriss_in_der_nachzustellung_hinterlaesst_keine_leiche(relay):
    """Der Befund selbst.

    Reisst die Verbindung mitten in der Nachzustellung, verliess die Ausnahme
    ws_endpoint am `finally` vorbei — der tote Socket blieb in `connections`,
    und ab da schrieb jeder Absender an diese Adresse hinein, statt zu puffern.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=3)

    sock = _StummerSocket(bob["user_id"], bob["priv"], reisst_bei=2)
    entwischt = None
    try:
        asyncio.run(rs.ws_endpoint(sock))
    except BaseException as exc:              # noqa: BLE001 — wird geprueft
        entwischt = exc

    assert rs.connections == {}, "der tote Socket steht weiter in connections"
    assert entwischt is None, f"Ausnahme verlaesst ws_endpoint: {entwischt!r}"
    # Schuetzt gegen die falsche Behebung: wer die Leiche dadurch loest, dass
    # er das DELETE vorzieht, verliert die Nachrichten.
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 3


def test_verdraengte_verbindung_reisst_die_neue_nicht_mit(relay):
    """Der Nachbar in denselben Zeilen: `except RuntimeError` war zu eng.

    Was close() auf der alten Verbindung wirft, haengt an der
    WebSocket-Umsetzung, die uvicorn gerade gewaehlt hat. AssertionError steht
    hier stellvertretend fuer alles, was kein RuntimeError ist.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=1)

    class _AlteVerbindung:
        async def close(self, code=None):
            raise AssertionError("zwei Aufgaben auf demselben Protokoll")

    rs.connections[bob["user_id"]] = _AlteVerbindung()

    sock = _StummerSocket(bob["user_id"], bob["priv"])
    entwischt = None
    try:
        asyncio.run(rs.ws_endpoint(sock))
    except BaseException as exc:              # noqa: BLE001 — wird geprueft
        entwischt = exc

    assert entwischt is None, f"die neue Verbindung starb mit: {entwischt!r}"
    assert [m for m in sock.gesendet if m.get("type") == "message"], \
        "die neue Verbindung kam nicht bis zur Nachzustellung"
    assert rs.connections == {}


# --------------------------------------------------------------------------- #
#  Befund C: Warteschlange mit erfundenen Empfaengeradressen volllaufen lassen
# --------------------------------------------------------------------------- #

def test_erfundene_zieladresse_wird_nicht_gepuffert(relay):
    """32 Zufallsbytes mit selbst gerechneter Pruefsumme sind keine Adresse.

    Vorher quittierte der Server sie mit `ack` und legte 64 KiB fuer 14 Tage
    ab — und der Deckel je Empfaenger zaehlte nie mit, weil der Absender sich
    die Empfaengeradresse aussucht.
    """
    rs = relay
    alice = make_user()
    _lege_an(rs, alice)
    erfunden = encode_id(os.urandom(32))

    raus = _sitzung(rs, alice, [
        {"type": "message", "to": erfunden, "ciphertext": b64(b"x"), "id": "m1"},
    ])
    fehler = [m for m in raus if m.get("type") == "error"]
    assert fehler, "der Server hat die erfundene Adresse angenommen"
    assert fehler[0]["reason"] == "Zieladresse unbekannt"
    assert fehler[0].get("id") == "m1"
    assert not [m for m in raus if m.get("type") == "ack"]
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 0


def test_ein_ack_bedeutet_weiterhin_eine_zeile(relay):
    """Der Gegenpol: eine ueberschiessende Behebung faellt hier auf."""
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)

    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x")},
    ])
    assert [m for m in raus if m.get("type") == "ack"]
    assert rs.db.execute(
        "SELECT COUNT(*) FROM queue WHERE recipient=?", (bob["user_id"],)
    ).fetchone()[0] == 1


def test_abgetippte_schreibweise_landet_beim_richtigen_empfaenger(relay):
    """Kanonisieren MUSS vor der Existenzpruefung stehen.

    decode_id nimmt Grossschreibung und Bindestriche an; identities und
    connections kennen aber nur die kanonische Form. Steht die Existenzfrage
    zuerst, weist der Server eine abgetippte, aber voellig zustellbare Adresse
    ab.
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    getippt = "-".join(bob["user_id"][i:i + 8].upper() for i in range(0, 56, 8))

    raus = _sitzung(rs, alice, [
        {"type": "message", "to": getippt, "ciphertext": b64(b"x")},
    ])
    assert [m for m in raus if m.get("type") == "ack"], \
        [m for m in raus if m.get("type") == "error"]
    assert rs.db.execute(
        "SELECT recipient FROM queue"
    ).fetchone()[0] == bob["user_id"]


def test_bremse_trifft_das_puffern_und_nicht_die_unterhaltung(relay, monkeypatch):
    """Der Eimer je Absender — und dass er den Live-Weg in Ruhe laesst.

    Gepuffert wird auf Veranlassung des Absenders, also haengt die Bremse an
    ihm. Eine laufende Unterhaltung schreibt nichts auf die Platte und darf
    deshalb nicht gebremst werden.
    """
    rs = relay
    alice, bob, carol = make_user(), make_user(), make_user()
    for u in (alice, bob, carol):
        _lege_an(rs, u)
    monkeypatch.setattr(rs, "MSG_CAPACITY", 3)
    monkeypatch.setattr(rs, "MSG_REFILL_PER_SEC", 0.0)

    horcher = _Zuhoerer()
    rs.connections[carol["user_id"]] = horcher

    rahmen = [{"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x")}
              for _ in range(5)]
    rahmen += [{"type": "message", "to": carol["user_id"], "ciphertext": b64(b"y")}
               for _ in range(5)]
    raus = _sitzung(rs, alice, rahmen)

    acks = [m for m in raus if m.get("type") == "ack"]
    gebremst = [m for m in raus if m.get("reason") == "zu viele Nachrichten"]
    assert len(gebremst) == 2, raus
    # 3 gepufferte + 5 durchgereichte
    assert len(acks) == 8
    assert len(horcher.empfangen) == 5, "die laufende Unterhaltung wurde gebremst"
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 3


def test_das_dach_ueber_der_ganzen_tabelle_haelt(relay, monkeypatch):
    """QUEUE_MAX_PER_USER haengt an einer Groesse, die der Absender aussucht.

    Ohne ein zweites, festes Dach ist der Deckel beliebig oft zu haben — man
    braucht nur eine weitere Zieladresse.
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    monkeypatch.setattr(rs, "QUEUE_MAX_TOTAL", 2)

    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x")}
        for _ in range(3)
    ])
    assert len([m for m in raus if m.get("type") == "ack"]) == 2
    voll = [m for m in raus if m.get("reason") == "Warteschlange voll"]
    assert len(voll) == 1, raus
    # Nicht der Deckel je Empfaenger — der steht bei 500.
    assert rs.QUEUE_MAX_PER_USER > 2
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 2


def test_der_zaehler_laeuft_nach_dem_zustellen_wieder_runter(relay, monkeypatch):
    """Sonst bliebe die Warteschlange nach einem Zustellzyklus fuer immer zu."""
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob, n_otk=30)
    monkeypatch.setattr(rs, "QUEUE_MAX_TOTAL", 2)

    _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x")}
        for _ in range(2)
    ])
    assert rs._queue_zeilen == 2

    abgeholt = _sitzung(rs, bob)
    assert len([m for m in abgeholt if m.get("type") == "message"]) == 2
    assert rs._queue_zeilen == 0

    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"z")},
    ])
    assert [m for m in raus if m.get("type") == "ack"], raus


def test_neustart_setzt_den_zaehler_auf_den_stand_der_tabelle(tmp_path, monkeypatch):
    """Ohne den Abgleich beim Hochfahren waere das Dach nach jedem Neustart weg.

    Hier laeuft absichtlich der echte lifespan ueber den TestClient: geprueft
    werden soll die VERDRAHTUNG, nicht die Funktion — die Funktion allein
    gruen zu haben, hiesse nichts, wenn sie beim Start niemand ruft.
    """
    from fastapi.testclient import TestClient
    import relay_server as rs

    vorher = rs.init_db(tmp_path / "relay.db")
    with vorher:
        vorher.executemany(
            "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
            [("a" * 56, "b" * 56, b"<blob>", time.time()) for _ in range(5)],
        )
    vorher.close()

    monkeypatch.setattr(rs, "DB_PATH", tmp_path / "relay.db")
    monkeypatch.setattr(rs, "_queue_zeilen", 0)
    monkeypatch.setattr(rs, "db", None, raising=False)
    with TestClient(rs.app):
        assert rs._queue_zeilen == 5


# --------------------------------------------------------------------------- #
#  Befund D: der Anstoss geht nicht hinaus und scheitert stumm
# --------------------------------------------------------------------------- #

@pytest.fixture()
def klage_frisch(monkeypatch):
    import relay_server as rs
    monkeypatch.setattr(rs, "_push_klage_zuletzt", None)
    monkeypatch.setattr(rs, "_push_fehler_seither", 0)
    return rs


def _push_server(gesehen, status=200):
    """Ein Zuhoerer auf dem Loopback, der mitschreibt, was ankommt."""

    class Griff(http.server.BaseHTTPRequestHandler):
        def do_POST(self):                       # noqa: N802 — von der Basisklasse
            laenge = int(self.headers.get("Content-Length") or 0)
            gesehen.append((self.path, self.rfile.read(laenge)))
            self.send_response(status)
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Griff)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_anstoss_nimmt_nur_den_pfad(monkeypatch):
    """Der Host aus dem Endpunkt wird bewusst nicht benutzt.

    Er ist oben schon gegen PUSH_ERLAUBTE_HOSTS geprueft, und hinaus darf
    dieser Server ohnehin nicht — die Unit sperrt jede ausgehende Verbindung.
    """
    rs = relay_modul()
    monkeypatch.setattr(rs, "PUSH_ZIEL_BASIS", "http://127.0.0.1:2586")
    ziel = rs.anstoss_ziel("https://push.bitdm.net/upAbc123_-xyz")
    assert ziel == "http://127.0.0.1:2586/upAbc123_-xyz"
    assert "push.bitdm.net" not in ziel


def test_ohne_ziel_bleibt_es_beim_endpunkt(monkeypatch):
    """Abwaertskompatibel: wer BITDM_PUSH_TARGET nicht setzt, aendert nichts.

    Das betrifft Relays nach docs/EIGENER-SERVER.md, die hinausduerfen. Auf
    dem gesperrten Relay scheitert es weiterhin — aber nicht mehr stumm.
    """
    rs = relay_modul()
    monkeypatch.setattr(rs, "PUSH_ZIEL_BASIS", "")
    assert rs.anstoss_ziel("https://push.bitdm.net/upAbc") == \
        "https://push.bitdm.net/upAbc"


def test_klage_hoechstens_einmal_je_stunde(klage_frisch, capsys):
    rs = klage_frisch
    for _ in range(20):
        rs._push_ging_daneben("x")
    zeilen = [z for z in capsys.readouterr().out.splitlines()
              if "Anstoss geht nicht raus" in z]
    assert len(zeilen) == 1, zeilen

    # Eine Stunde spaeter muss die naechste Meldung kommen — und die
    # verschluckten Fehlversuche mitzaehlen.
    rs._push_klage_zuletzt -= rs.PUSH_KLAGE_ABSTAND + 1
    rs._push_ging_daneben("x")
    zweite = [z for z in capsys.readouterr().out.splitlines()
              if "Anstoss geht nicht raus" in z]
    assert len(zweite) == 1
    assert "20 Fehlversuche" in zweite[0], zweite[0]


def test_klage_nennt_weder_adresse_noch_endpunkt(relay, klage_frisch, monkeypatch,
                                                 capsys):
    """deploy/README.md, "Was NICHT protokolliert wird" — das gilt auch hier.

    Der Endpunkt ist eine dauerhafte Geraetekennung, die Adresse der
    Empfaenger. Beides in eine Fehlermeldung zu nehmen ist beim naechsten
    Umbau die naheliegendste Bequemlichkeit — und genau die Aufzeichnung, die
    dieser Server nicht fuehren soll.
    """
    rs = relay
    empfaenger = make_user()
    _lege_an(rs, empfaenger)
    endpunkt = "https://push.bitdm.net/upGeheimesThema42"
    with rs.db:
        rs.db.execute("UPDATE identities SET push_endpoint=? WHERE user_id=?",
                      (endpunkt, empfaenger["user_id"]))

    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    toter_port = s.getsockname()[1]
    s.close()
    monkeypatch.setattr(rs, "PUSH_ZIEL_BASIS", f"http://127.0.0.1:{toter_port}")
    asyncio.run(rs.stosse_an(empfaenger["user_id"]))

    ausgabe = capsys.readouterr().out
    assert "Anstoss geht nicht raus" in ausgabe
    assert empfaenger["user_id"] not in ausgabe
    assert "upGeheimesThema42" not in ausgabe


def test_anstoss_geht_ueber_loopback_raus(relay, klage_frisch, monkeypatch, capsys):
    rs = relay
    empfaenger = make_user()
    _lege_an(rs, empfaenger)
    with rs.db:
        rs.db.execute("UPDATE identities SET push_endpoint=? WHERE user_id=?",
                      ("https://push.bitdm.net/upGeheim123", empfaenger["user_id"]))

    gesehen = []
    srv = _push_server(gesehen)
    try:
        monkeypatch.setattr(
            rs, "PUSH_ZIEL_BASIS", f"http://127.0.0.1:{srv.server_address[1]}")
        asyncio.run(rs.stosse_an(empfaenger["user_id"]))
    finally:
        srv.shutdown()

    # Leerer Rumpf, und nur der Pfad. Ein Absender im Anstoss stuende
    # unverschluesselt auf dem Sperrbildschirm.
    assert gesehen == [("/upGeheim123", b"")]
    assert "Anstoss geht nicht raus" not in capsys.readouterr().out


def test_fuenfhundert_wird_bemerkt(relay, klage_frisch, monkeypatch, capsys):
    """httpx wirft bei 5xx nicht von sich aus.

    Ohne die Statuspruefung bliebe ein antwortender, aber ablehnender
    Push-Server genauso unsichtbar wie vorher der gesperrte Connect.
    """
    rs = relay
    empfaenger = make_user()
    _lege_an(rs, empfaenger)
    with rs.db:
        rs.db.execute("UPDATE identities SET push_endpoint=? WHERE user_id=?",
                      ("https://push.bitdm.net/upGeheim123", empfaenger["user_id"]))

    gesehen = []
    srv = _push_server(gesehen, status=500)
    try:
        monkeypatch.setattr(
            rs, "PUSH_ZIEL_BASIS", f"http://127.0.0.1:{srv.server_address[1]}")
        asyncio.run(rs.stosse_an(empfaenger["user_id"]))
    finally:
        srv.shutdown()

    ausgabe = capsys.readouterr().out
    assert "Anstoss geht nicht raus" in ausgabe
    assert "HTTP 500" in ausgabe


def test_toter_push_server_wird_bemerkt(relay, klage_frisch, monkeypatch, capsys):
    """Der eigentliche Befund: `except Exception: pass` verschluckte alles."""
    rs = relay
    empfaenger = make_user()
    _lege_an(rs, empfaenger)
    with rs.db:
        rs.db.execute("UPDATE identities SET push_endpoint=? WHERE user_id=?",
                      ("https://push.bitdm.net/upGeheim123", empfaenger["user_id"]))

    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    toter_port = s.getsockname()[1]
    s.close()

    monkeypatch.setattr(rs, "PUSH_ZIEL_BASIS", f"http://127.0.0.1:{toter_port}")
    asyncio.run(rs.stosse_an(empfaenger["user_id"]))

    ausgabe = capsys.readouterr().out
    assert "Anstoss geht nicht raus" in ausgabe
    assert "ConnectError" in ausgabe


# --------------------------------------------------------------------------- #
#  Befund E: gepufferte Nachrichten wurden geloescht, sobald sie im Socket
#            standen — der Client bestaetigte nie
# --------------------------------------------------------------------------- #
#
# WAS HIER GEPRUEFT WIRD, ist eine Aussage ueber ZWEI Verbindungen: was beim
# zweiten Verbinden noch da ist. Die Faelle laufen deshalb fast alle als zwei
# Sitzungen nacheinander gegen dieselbe Datenbank.
#
# Der teuerste Fall — Abriss mitten in der Zustellung — steht auch in Haelfte 1
# ueber echte Sockets. Hier ist er trotzdem noch einmal, weil sich der Abriss
# nur hier an einer BESTIMMTEN Nachricht setzen laesst.


def _warteschlange(rs, empfaenger):
    """Die Kennungen, die fuer diese Adresse noch offen sind."""
    return [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient=? ORDER BY id", (empfaenger,))]


def test_ohne_flag_wird_weiterhin_sofort_geloescht(relay):
    """Der Regressionswall fuer die App-Fassungen im Umlauf.

    Ein Client, der den Nachweis nicht ankuendigt, muss exakt das bisherige
    Verhalten bekommen: sofort loeschen. Wartete der Server auch auf ihn,
    bekaeme jede alte App ihre Nachrichten bei jedem Verbinden erneut — das
    waere schlimmer als der Verlust, den die Aenderung behebt.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=3)

    raus = _sitzung(rs, bob)                       # ohne nachweis=True
    assert len([m for m in raus if m.get("type") == "message"]) == 3
    assert _warteschlange(rs, bob["user_id"]) == []
    assert rs._queue_zeilen == 0

    # Und beim naechsten Verbinden kommt nichts mehr.
    assert not [m for m in _sitzung(rs, bob) if m.get("type") == "message"]


def test_ohne_nachweis_bleibt_die_zeile_liegen(relay):
    """Der Kern: zugestellt heisst noch nicht angekommen.

    Der Server WARTET dabei nicht — er verschiebt nur das Loeschen. Die
    Sitzung laeuft ganz normal durch, die Zeilen bleiben stehen.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=3)
    vorher = _warteschlange(rs, bob["user_id"])

    raus = _sitzung(rs, bob, nachweis=True)
    kennungen = [m["q"] for m in raus if m.get("type") == "message"]
    assert kennungen == vorher
    assert _warteschlange(rs, bob["user_id"]) == vorher

    # Beim zweiten Verbinden kommen dieselben drei noch einmal.
    nochmal = _sitzung(rs, bob, nachweis=True)
    assert [m["q"] for m in nochmal if m.get("type") == "message"] == vorher


def test_mit_nachweis_ist_die_zeile_weg(relay):
    """Das Gegenstueck. Ohne diesen Test bliebe die Warteschlange voll."""
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=3)

    raus = _sitzung(rs, bob, nachweis=True, bestaetigt=True)
    assert len([m for m in raus if m.get("type") == "message"]) == 3
    assert _warteschlange(rs, bob["user_id"]) == []
    # Der Zaehler fuer QUEUE_MAX_TOTAL muss dem Nachweis folgen. Laeuft er
    # nicht mit, verstopft der Deckel irgendwann fuer alle.
    assert rs._queue_zeilen == 0

    assert not [m for m in _sitzung(rs, bob, nachweis=True)
                if m.get("type") == "message"]


def test_die_kennung_steht_nur_am_gepufferten_rahmen(relay):
    """Live weitergereicht gibt es keine Zeile, die man bestaetigen koennte.

    Ein `q` am Live-Rahmen waere schlimmer als nutzlos: es lieferte dem
    Empfaenger eine fremde Kennung frei Haus.
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)

    zuhoerer = _Zuhoerer()
    rs.connections[bob["user_id"]] = zuhoerer
    _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x")},
    ])
    live = [m for m in zuhoerer.empfangen if m.get("type") == "message"]
    assert live and "q" not in live[0]

    # Und der gepufferte Weg traegt sie sehr wohl — ganzzahlig.
    del rs.connections[bob["user_id"]]
    _puffere(rs, bob["user_id"], alice["user_id"], n=1)
    raus = _sitzung(rs, bob, nachweis=True)
    gepuffert = [m for m in raus if m.get("type") == "message"]
    assert gepuffert
    q = gepuffert[0].get("q")
    assert isinstance(q, int) and not isinstance(q, bool)


def test_fremde_warteschlange_laesst_sich_nicht_leeren(relay):
    """Der wichtigste Fall dieses Abschnitts.

    Die Kennungen sind fortlaufend und damit zu erraten. Faellt das
    `AND recipient=?` aus dem DELETE, kann jeder Angemeldete die Warteschlange
    eines beliebigen anderen leeren — aus einem Datenverlust bei schlechtem
    Funk wuerde ein Datenverlust auf Zuruf.
    """
    rs = relay
    bob, carol = make_user(), make_user()
    _lege_an(rs, bob, n_otk=30)
    _lege_an(rs, carol, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=5)
    bobs = _warteschlange(rs, bob["user_id"])

    _sitzung(rs, carol, [{"type": "empfangen", "ids": bobs}], nachweis=True)
    assert _warteschlange(rs, bob["user_id"]) == bobs

    # Und Bob bekommt sie trotzdem.
    raus = _sitzung(rs, bob, nachweis=True)
    assert [m["q"] for m in raus if m.get("type") == "message"] == bobs


def test_abriss_in_der_zustellung_haelt_alles_fest(relay):
    """Die Probe aus der Begruendung, mit umgekehrtem Erwartungswert.

    Vorher waren die Umschlaege nach einem Abriss endgueltig weg: in der
    Datenbank geloescht, beim Client nie eingetroffen, und die Absender hatten
    ihr `ack` seit Tagen.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=30)
    vorher = _warteschlange(rs, bob["user_id"])

    sock = _StummerSocket(bob["user_id"], bob["priv"], reisst_bei=7,
                          nachweis=True)
    asyncio.run(rs.ws_endpoint(sock))

    assert _warteschlange(rs, bob["user_id"]) == vorher
    alle = _sitzung(rs, bob, nachweis=True)
    assert [m["q"] for m in alle if m.get("type") == "message"] == vorher


def test_muell_im_nachweis_reisst_die_verbindung_nicht(relay):
    """Was hereinkommt, ist irgendein JSON-Wert.

    Ohne die isinstance-Pruefungen wirft executemany, die Hauptschleife endet,
    und der Absender bekommt sein `ack` nicht mehr.
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice, n_otk=30)
    _lege_an(rs, bob)

    raus = _sitzung(rs, alice, [
        {"type": "empfangen"},
        {"type": "empfangen", "ids": "alles"},
        {"type": "empfangen", "ids": [None, True, "x", 1.5]},
        {"type": "empfangen", "ids": []},
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x"),
         "id": "nach-muell"},
    ], nachweis=True)

    quittungen = [m for m in raus if m.get("type") == "ack"]
    assert quittungen and quittungen[0].get("id") == "nach-muell"


def test_true_ist_keine_kennung(relay):
    """bool ist in Python ein int.

    Ohne `not isinstance(i, bool)` waere `True` die Kennung 1 — und die
    gehoert irgendwem. Der Fall steht getrennt, weil ihn der Muelltest oben
    nicht sichtbar macht: dort faellt True zusammen mit allem anderen weg.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=1)
    offen = _warteschlange(rs, bob["user_id"])
    assert offen == [1], "dieser Test haengt daran, dass die erste Kennung 1 ist"

    _sitzung(rs, bob, [{"type": "empfangen", "ids": [True]}], nachweis=True)
    assert _warteschlange(rs, bob["user_id"]) == offen


def test_die_anmeldung_spiegelt_das_koennen_zurueck(relay):
    """Reine Diagnose, aber die einzige.

    Ein neuer Client, der das Flag versehentlich nicht setzt, verhaelt sich
    sonst wie ein alter — er sieht die `q` trotzdem und schickt Nachweise auf
    laengst geloeschte Zeilen. Ohne den Rueckspiegel ist das von aussen nicht
    zu unterscheiden.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)

    mit = [m for m in _sitzung(rs, bob, nachweis=True)
           if m.get("type") == "auth_result"]
    assert mit and mit[0]["empfangsnachweis"] is True

    ohne = [m for m in _sitzung(rs, bob)
            if m.get("type") == "auth_result"]
    assert ohne and ohne[0]["empfangsnachweis"] is False


def test_der_nachweis_zaehlt_nicht_gegen_die_absenderbremse(relay, monkeypatch):
    """Wer viel bestaetigt, hat viel bekommen.

    Ihn dafuer zu drosseln hiesse, ausgerechnet den Nachweis zu verhindern, an
    dem das Loeschen haengt — die Warteschlange liefe voll, und der Absender
    bekaeme 'Warteschlange voll'.
    """
    rs = relay
    bob = make_user()
    _lege_an(rs, bob, n_otk=30)
    _puffere(rs, bob["user_id"], bob["user_id"], n=3)

    gefragt = []
    echt = rs.msg_limit_ok
    monkeypatch.setattr(rs, "msg_limit_ok",
                        lambda uid: (gefragt.append(uid), echt(uid))[1])

    _sitzung(rs, bob, nachweis=True, bestaetigt=True)
    assert gefragt == [], "der Nachweis wurde auf die Absenderbremse gebucht"
    assert _warteschlange(rs, bob["user_id"]) == []


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))


# --------------------------------------------------------------------------- #
#  Die Widerlegung vom 27.07.2026
# --------------------------------------------------------------------------- #
#
# Drei Befunde, die eine adversarische Gegenpruefung an der Arbeit desselben
# Tages gefunden hat. Sie stehen zusammen, weil sie einen gemeinsamen Zug
# haben: jeder entsteht dort, wo eine Behebung an EINER Stelle einen zweiten,
# ungedeckten Weg zur selben Sache uebrigliess.


def test_zu_viele_einmalschluessel_werden_abgewiesen():
    """Ein Bundle mit mehr als OTK_MAX_JE_BUENDEL kommt gar nicht erst an.

    Vorher hatte `one_time_prekeys` kein Laengenlimit. nginx laesst 256 KiB
    Rumpf durch, das sind rund 2900 Einmalschluessel — gemessen 837 KiB
    Plattenwachstum je Registrierung, und `purge_expired` ruehrt diese Tabelle
    nie an. Eine einzige IP schob so 20,4 MiB in 30 Sekunden durch.
    """
    import pydantic
    import relay_server as rs_mod

    zu_viele = [{"key_id": i, "public_key": b64(os.urandom(32))}
                for i in range(rs_mod.OTK_MAX_JE_BUENDEL + 1)]
    with pytest.raises(pydantic.ValidationError):
        PreKeyBundle(
            user_id="x" * 56, identity_key=b64(os.urandom(32)),
            registration_id=1, signed_prekey_id=1,
            signed_prekey=b64(os.urandom(32)),
            signed_prekey_sig=b64(os.urandom(64)),
            one_time_prekeys=zu_viele,
        )

    # Die Gegenprobe: genau die Grenze geht noch durch. Ohne sie waere der
    # Test auch mit einem Limit von 0 gruen.
    gerade_noch = zu_viele[:rs_mod.OTK_MAX_JE_BUENDEL]
    PreKeyBundle(
        user_id="x" * 56, identity_key=b64(os.urandom(32)),
        registration_id=1, signed_prekey_id=1,
        signed_prekey=b64(os.urandom(32)),
        signed_prekey_sig=b64(os.urandom(64)),
        one_time_prekeys=gerade_noch,
    )


def test_der_empfangen_rahmen_wird_vor_dem_aufbauen_abgeschnitten(relay):
    """Eine Riesenliste darf nicht erst gebaut und dann gekuerzt werden.

    Der Zweig ist ausdruecklich von jeder Bremse ausgenommen. Ein einziger
    Rahmen von 16 MiB (uvicorns Vorgabe) enthaelt 8,4 Millionen Kennungen;
    der Aufbau belegte gemessen 579 MiB und blockierte den Event-Loop 2,1 s —
    bei MemoryMax=512M erschlug das den Dienst.

    Beobachtbar ist die Abschneidung daran, dass Kennungen HINTER der Grenze
    gar nicht mehr angesehen werden. Das ist zugleich die ehrliche Folge:
    mehr offene Zeilen als QUEUE_MAX_PER_USER kann eine Adresse nie haben.
    """
    rs = relay
    alice = make_user()
    _lege_an(rs, alice)
    _puffere(rs, alice["user_id"], "wer", n=2)
    echte = [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient=?", (alice["user_id"],))]
    assert len(echte) == 2

    # Erst QUEUE_MAX_PER_USER Kennungen Muell, DANN die echten. Wird vorher
    # abgeschnitten, ueberleben die echten Zeilen.
    # nachweis=True ist hier keine Nebensache: ohne das Flag raeumt schon die
    # Nachzustellung beim Anmelden die Zeilen weg (der alte Weg), und der
    # Test haette gemessen, dass sie hinterher fehlen — aus dem falschen
    # Grund.
    muell = list(range(10_000, 10_000 + rs.QUEUE_MAX_PER_USER))
    _sitzung(rs, alice, [{"type": "empfangen", "ids": muell + echte}],
             nachweis=True)

    uebrig = rs.db.execute(
        "SELECT COUNT(*) FROM queue WHERE recipient=?",
        (alice["user_id"],)).fetchone()[0]
    assert uebrig == 2, ("die Liste wurde vollstaendig verarbeitet — dann "
                         "traegt auch die Groessengrenze nicht")


def test_eine_live_nachricht_liegt_bis_zum_nachweis_in_der_warteschlange(relay):
    """Der Datenverlust, den der Empfangsnachweis uebriggelassen hatte.

    Eine live weitergereichte Nachricht ging ohne jede Zeile hinaus.
    `await target.send_json(...)` sagt nur, dass der Rahmen im Schreibpuffer
    der ANDEREN Verbindung liegt. Reisst deren Leitung, existiert die
    Nachricht nirgends mehr — und der Absender hat sein `ack`.
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)

    class Empfaenger:
        def __init__(self):
            self.bekommen = []

        async def send_json(self, obj):
            self.bekommen.append(obj)

    bobs_leitung = Empfaenger()
    rs.connections[bob["user_id"]] = bobs_leitung
    rs.nachweisfaehig[bob["user_id"]] = True
    try:
        raus = _sitzung(rs, alice, [
            {"type": "message", "to": bob["user_id"],
             "ciphertext": b64(b"hallo"), "id": "m1"},
        ])
    finally:
        rs.connections.pop(bob["user_id"], None)
        rs.nachweisfaehig.pop(bob["user_id"], None)

    assert [m for m in raus if m.get("type") == "ack"], "kein ack an Alice"
    assert bobs_leitung.bekommen, "Bob hat nichts bekommen"
    zugestellt = bobs_leitung.bekommen[-1]
    assert "q" in zugestellt, ("ohne Kennung kann Bob nie bestaetigen — dann "
                              "haengt die Zeile fuer immer")

    offen = rs.db.execute("SELECT COUNT(*) FROM queue WHERE recipient=?",
                          (bob["user_id"],)).fetchone()[0]
    assert offen == 1, ("die live zugestellte Nachricht liegt nicht in der "
                        "Warteschlange — reisst Bobs Leitung jetzt, ist sie weg")

    # Und der Nachweis raeumt sie weg.
    _sitzung(rs, bob, [{"type": "empfangen", "ids": [zugestellt["q"]]}])
    danach = rs.db.execute("SELECT COUNT(*) FROM queue WHERE recipient=?",
                           (bob["user_id"],)).fetchone()[0]
    assert danach == 0, "der Nachweis hat die Zeile nicht geloescht"


def test_ein_alter_client_bekommt_weiterhin_den_alten_weg(relay):
    """Die Gegenprobe, und sie ist wichtiger, als sie aussieht.

    Fuer eine Gegenstelle, die den Nachweis NICHT beherrscht, darf keine Zeile
    entstehen: sie wuerde sie nie bestaetigen, und ihre Warteschlange liefe
    voll, bis nichts mehr ankommt. Das waere schlimmer als der Verlust, den
    die Aenderung behebt.
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)

    class Empfaenger:
        def __init__(self):
            self.bekommen = []

        async def send_json(self, obj):
            self.bekommen.append(obj)

    alt = Empfaenger()
    rs.connections[bob["user_id"]] = alt
    rs.nachweisfaehig[bob["user_id"]] = False
    try:
        _sitzung(rs, alice, [
            {"type": "message", "to": bob["user_id"],
             "ciphertext": b64(b"hallo"), "id": "m1"},
        ])
    finally:
        rs.connections.pop(bob["user_id"], None)
        rs.nachweisfaehig.pop(bob["user_id"], None)

    assert alt.bekommen and "q" not in alt.bekommen[-1]
    offen = rs.db.execute("SELECT COUNT(*) FROM queue WHERE recipient=?",
                          (bob["user_id"],)).fetchone()[0]
    assert offen == 0, ("fuer einen Alt-Client darf keine Zeile entstehen — "
                        "er bestaetigt sie nie")


def test_ein_volles_relay_nimmt_keine_neuen_adressen_mehr(relay, monkeypatch):
    """Das Dach ueber `identities` — der zweite, dauerhafte Weg auf die Platte.

    Ohne es schob eine einzige IP gemessen 20,4 MiB in 30 Sekunden durch,
    hochgerechnet rund 57 GiB am Tag. Und anders als die Warteschlange heilt
    das nicht von selbst: `purge_expired` ruehrt diese Tabelle nie an.
    """
    rs = relay
    monkeypatch.setattr(rs, "IDENTITAETEN_MAX", 1)
    alice, bob = make_user(), make_user()

    # Erste Adresse geht durch.
    r = rs.register(rs.RegisterRequest(
        bundle=rs.PreKeyBundle(**alice["bundle"]),
        signature=b64(_unterschreibe(alice))), _Anfrage())
    assert r["ok"] is True

    # Zweite nicht mehr.
    with pytest.raises(rs.HTTPException) as fehler:
        rs.register(rs.RegisterRequest(
            bundle=rs.PreKeyBundle(**bob["bundle"]),
            signature=b64(_unterschreibe(bob))), _Anfrage())
    assert fehler.value.status_code == 507, (
        "429 waere falsch: das ist keine Bremse, die nachgibt, sondern eine "
        "volle Ablage — sonst versucht es der Client fuer immer")

    # ABER: WER SCHON DA IST, KOMMT IMMER DURCH.
    #
    # Das ist der wichtigere Teil. Ein volles Relay, das seinen eigenen
    # Nutzern die Erneuerung ihres Bundles verweigert, macht sie nach dem
    # Aufbrauchen ihrer Einmalschluessel unerreichbar — die Grenze richtete
    # sich dann gegen genau die, die sie schuetzen soll.
    r = rs.register(rs.RegisterRequest(
        bundle=rs.PreKeyBundle(**alice["bundle"]),
        signature=b64(_unterschreibe(alice))), _Anfrage())
    assert r["ok"] is True


def _unterschreibe(user):
    """Der Besitznachweis, wie ihn `register` erwartet."""
    import relay_server as rs
    nonce = rs.issue_nonce(user["user_id"])
    bundle = rs.PreKeyBundle(**user["bundle"])
    nachricht = nonce + hashlib.sha256(bundle.canonical_bytes()).digest()
    return sign(user["priv"], nachricht)
