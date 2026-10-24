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
import sqlite3
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

        # (g) Auch der live weitergereichte Rahmen traegt eine Kennung, wenn
        #     die Gegenstelle den Nachweis kann. Der Relay legt die Zeile an,
        #     BEVOR er live weiterreicht ("ERST IN DIE WARTESCHLANGE, DANN LIVE
        #     SCHICKEN", relay_server.py): riss die Leitung des Empfaengers im
        #     falschen Augenblick, war die Nachricht sonst weg, und der
        #     Absender hatte sein `ack`. Die Apps 2.0.0 und 2.0.1 bestaetigen
        #     genau dieses `q`. Es zeigt in Bobs EIGENE Warteschlange — fremde
        #     loescht es nicht, siehe (f).
        #
        #     Bis 24.10.2026 verlangte dieser Punkt das Gegenteil ("traegt keine
        #     Kennung") und meldete im Live-Lauf 56 von 57. Er kam im selben
        #     Commit (18c4348) wie der Weg, den er pruefen sollte, und
        #     beschrieb einen Zwischenstand. Ohne Kennung bleibt es nur fuer
        #     eine Gegenstelle OHNE Nachweis — das prueft der letzte Teil.
        bob_live = await connect_authed(bob, nachweis=True)
        await asyncio.sleep(0.3)
        live_ct = b64(b"<live-mit-kennung>")
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"], "ciphertext": live_ct}))
        live = await expect(bob_live, "message")
        check("Der live weitergereichte Rahmen traegt eine Kennung",
              live["ciphertext"] == live_ct
              and isinstance(live.get("q"), int)
              and not isinstance(live.get("q"), bool))
        # Unbestaetigt muss sie wiederkommen — sonst stuende hinter dem `q`
        # gar keine Zeile, und es waere nur ein Etikett.
        await bob_live.close()
        await asyncio.sleep(0.3)
        bob_live2 = await connect_authed(bob, nachweis=True)
        nochmal = []
        try:
            while True:
                nochmal.append(await expect(bob_live2, "message", timeout=1.5))
        except asyncio.TimeoutError:
            pass
        check("Live weitergereicht und unbestaetigt kommt sie wieder",
              any(m["ciphertext"] == live_ct and m.get("q") == live.get("q")
                  for m in nochmal))
        await bob_live2.send(json.dumps(
            {"type": "empfangen", "ids": [m["q"] for m in nochmal if "q" in m]}))
        await asyncio.sleep(0.4)
        await bob_live2.close()
        await asyncio.sleep(0.3)

        # Eine Gegenstelle OHNE Nachweis (Apps von vor dem Nachweis) bekommt
        # live weiter keine Kennung: fuer sie legt der Relay keine Zeile an.
        bob_alt = await connect_authed(bob)
        await asyncio.sleep(0.3)
        await alice_ws.send(json.dumps(
            {"type": "message", "to": bob["user_id"],
             "ciphertext": b64(b"<live-ohne-kennung>")}))
        alt = await expect(bob_alt, "message")
        check("Ohne Nachweis traegt der Live-Rahmen keine Kennung",
              "q" not in alt)
        await bob_alt.close()
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
    monkeypatch.setattr(rs, "_nonce_zahl", 0)
    monkeypatch.setattr(rs, "_schwerster", None)
    monkeypatch.setattr(rs, "_ws_im_vorraum", 0)
    monkeypatch.setattr(rs, "connections", {})
    monkeypatch.setattr(rs, "nachweisfaehig", {})
    monkeypatch.setattr(rs, "_queue_zeilen", 0)
    # Der Kyber-Stand gehoert zur frischen Datenbank wie der der Warteschlange
    # — sonst erbte ein Test das Dach (KYBER_OTK_MAX_GESAMT) des vorigen.
    monkeypatch.setattr(rs, "_kyber_zeilen", 0)
    # Der Stichtag-Schalter wird bei jeder Anmeldung aus der Umgebung gelesen
    # (kyber_pflicht). Steht er auf dem Rechner, auf dem die Tests laufen,
    # zufaellig auf 1, fielen alle Anmeldungen ohne Kyber durch.
    monkeypatch.delenv("BITDM_KYBER_PFLICHT", raising=False)
    # Dasselbe fuer die Anmeldung mit Kontext (KR-2): stuende der Schalter auf
    # dem Testrechner, fielen alle Anmeldungen in der alten Form durch.
    monkeypatch.delenv("BITDM_ANMELDUNG_PFLICHT", raising=False)
    monkeypatch.delenv("BITDM_RELAY_NAMEN", raising=False)
    # Die Anstoesse (SV-7): wer gerade angestossen wird, und der gemeinsame
    # Client - beides gehoert zum einzelnen Test.
    monkeypatch.setattr(rs, "_anstoss_nochmal", {}, raising=False)
    monkeypatch.setattr(rs, "_push_klient", None, raising=False)
    # Die Meldung "Adressdach fast voll" (SV-3) kommt hoechstens einmal je
    # Stunde - je Test von vorn.
    monkeypatch.setattr(rs, "_dach_gemeldet", None, raising=False)
    try:
        yield rs
    finally:
        conn.close()


class _Anfrage:
    """Nur so viel Request, wie client_ip() anfasst."""

    headers: dict = {}
    client = None


def _lege_an(rs, user, n_otk=3, geraet=1, last_seen=None):
    """Traegt eine Identitaet ein, ohne den ganzen /register-Weg zu gehen.

    Der Weg ueber /register braeuchte Nonce, Signatur und Ratenbegrenzung —
    alles schon in Haelfte 1 geprueft und hier nur Rauschen um den Punkt herum.

    [geraet] ist die Vorgabe 1, damit jeder Aufruf von vor dem
    Mehrgeraete-Umbau unveraendert dasselbe tut.
    """
    pub = base64.b64decode(user["bundle"]["identity_key"])
    jetzt = time.time()
    with rs.db:
        rs.db.execute(
            "INSERT OR REPLACE INTO identities (user_id, device_id, identity_key,"
            " registration_id, signed_prekey_id, signed_prekey,"
            " signed_prekey_sig, updated_at, last_seen) VALUES (?,?,?,?,?,?,?,?,?)",
            (user["user_id"], geraet, pub, 4711, 1, os.urandom(32),
             os.urandom(64), jetzt if last_seen is None else last_seen,
             jetzt if last_seen is None else last_seen),
        )
        rs.db.executemany(
            "INSERT INTO one_time_prekeys (user_id, device_id, key_id, public_key)"
            " VALUES (?,?,?,?)",
            [(user["user_id"], geraet, i, os.urandom(32)) for i in range(n_otk)],
        )


def _puffere(rs, empfaenger, absender, n=1, geraet=1, von_geraet=1):
    """Legt n Zeilen direkt in die Warteschlange."""
    with rs.db:
        rs.db.executemany(
            "INSERT INTO queue (recipient, recipient_device, sender,"
            " sender_device, ciphertext, ts) VALUES (?,?,?,?,?,?)",
            [(empfaenger, geraet, absender, von_geraet, b"<blob>", time.time())
             for _ in range(n)],
        )
    rs.queue_zeilen_neu_zaehlen()


def _verbinde(rs, user, leitung, *, geraet=1, nachweis=True):
    """Haengt eine gefaelschte Leitung als angemeldetes Geraet ein.

    `connections` und `nachweisfaehig` sind seit dem Mehrgeraete-Umbau
    zweistufig (Adresse -> Geraet -> Leitung). Diese Funktion ist die einzige
    Stelle, die das in den Tests weiss.
    """
    rs.connections.setdefault(user["user_id"], {})[geraet] = leitung
    rs.nachweisfaehig.setdefault(user["user_id"], {})[geraet] = nachweis


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
                 nachweis=False, bestaetigt=False, geraet=None,
                 signiert_geraet=None, geraete_priv=None, bei_auth=None):
        # Der Geraeteschluessel (GERAETEABMELDUNG.md §8.4). Ohne ihn fehlt
        # `geraete_signatur` in der Antwort — so wie bei jedem Client von vor
        # der Geraeteliste.
        self._geraete_priv = geraete_priv
        # Wird gerufen, sobald auth_result rausgeht: damit laesst sich eine
        # Abmeldung GENAU zwischen Vorraum und Eintrag in `connections` legen.
        self._bei_auth = bei_auth
        self.query_params = {"user_id": user_id}
        # OHNE `geraet` steht keine device_id in der Query, und signiert wird
        # nur das Nonce — das ist der Client von vor dem Mehrgeraete-Umbau,
        # auf den alle aelteren Tests dieser Datei bauen.
        if geraet is not None:
            self.query_params["device_id"] = str(geraet)
        self._geraet = geraet
        # Welche Kennung in die SIGNIERTEN Bytes geht. Weicht sie von `geraet`
        # ab, wird die Signatur eines anderen Geraets wiederverwendet — genau
        # der Angriff, den nonce||uint32be(device_id) abwehren soll.
        self._signiert = geraet if signiert_geraet is None else signiert_geraet
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
        if obj.get("type") == "auth_result" and self._bei_auth is not None:
            self._bei_auth()
        if obj.get("type") == "challenge":
            # Die Challenge wird gleich hier beantwortet: ohne gueltige
            # Signatur kaeme der Ablauf nie bis zur Nachzustellung.
            nonce = base64.b64decode(obj["nonce"])
            zu_signieren = nonce if self._geraet is None else (
                nonce + self._signiert.to_bytes(4, "big"))
            antwort = {"signature": b64(sign(self._priv, zu_signieren))}
            if self._nachweis:
                antwort["empfangsnachweis"] = True
            if self._geraete_priv is not None:
                antwort["geraete_signatur"] = b64(sign(
                    self._geraete_priv, b"BitDM-Geraet-Anmeldung-v1\n" + zu_signieren))
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

    _verbinde(rs, bob, _AlteVerbindung())

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
    # nachweis=False haelt den Weg von vor dem Empfangsnachweis: live
    # durchreichen ohne Warteschlangenzeile. Genau darauf zaehlen die
    # Erwartungen unten.
    _verbinde(rs, carol, horcher, nachweis=False)

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
    asyncio.run(rs.stosse_an(empfaenger["user_id"], 1))

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
        asyncio.run(rs.stosse_an(empfaenger["user_id"], 1))
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
        asyncio.run(rs.stosse_an(empfaenger["user_id"], 1))
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
    asyncio.run(rs.stosse_an(empfaenger["user_id"], 1))

    ausgabe = capsys.readouterr().out
    assert "Anstoss geht nicht raus" in ausgabe
    assert "ConnectError" in ausgabe


def test_anstoss_im_hintergrund_bleibt_festgehalten_bis_er_fertig_ist(relay, monkeypatch):
    """SonarQube Cloud, python:S7502 (18.10.2026): der Anstoss lief als
    nacktes asyncio.create_task ohne Verweis und durfte vom
    Speicherbereiniger mittendrin weggeraeumt werden."""
    import gc

    rs = relay
    angekommen = []

    async def langsamer_anstoss(user_id, device_id):
        await asyncio.sleep(0.05)
        angekommen.append((user_id, device_id))

    monkeypatch.setattr(rs, "stosse_an", langsamer_anstoss)

    async def lauf():
        rs.stosse_im_hintergrund_an("empfaenger", 3)
        assert len(rs._laufende_anstoesse) == 1, "Aufgabe nicht festgehalten"
        gc.collect()
        await asyncio.sleep(0.2)
        assert not rs._laufende_anstoesse, "fertige Aufgabe nicht ausgetragen"

    asyncio.run(lauf())
    assert angekommen == [("empfaenger", 3)]


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
    """OHNE NACHWEIS gibt es live keine Zeile, die man bestaetigen koennte.

    Gilt fuer eine Gegenstelle, die den Nachweis nicht angekuendigt hat (Apps
    von vor dem Nachweis): ihr reicht der Relay live weiter, ohne eine Zeile
    anzulegen, und ein `q` daran waere eine Kennung ohne Zeile. Kann sie den
    Nachweis, legt er die Zeile VOR dem Weiterreichen an, und der Live-Rahmen
    traegt ihr `q` — siehe Pruefpunkt (g) in main().
    """
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)

    zuhoerer = _Zuhoerer()
    _verbinde(rs, bob, zuhoerer, nachweis=False)
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
    _verbinde(rs, bob, bobs_leitung)
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
    _verbinde(rs, bob, alt, nachweis=False)
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


# --------------------------------------------------------------------------- #
#  Mehrgeraete  (docs/MEHRGERAETE.md, 30.07.2026)
# --------------------------------------------------------------------------- #
#
# Der Befund, der das Ganze ausgeloest hat: spielt man dieselben zwoelf Woerter
# auf zwei Geraeten ein, melden sich beide erfolgreich an und KEINES merkt
# etwas. Das zuletzt angemeldete besitzt das Buendel, seine Registrierung
# loescht die Einmalschluessel des anderen, das erste wird stumm getrennt — und
# beide rasten anschliessend an derselben Signal-Sitzung weiter, was jede
# zweite Nachricht unwiederbringlich vernichtet.
#
# Die Tests hier stehen in der Reihenfolge der Spezifikation: erst das
# Datenmodell und die Wanderung (§8), dann die Adressierung (§3), dann die
# Angriffe (§2), zuletzt die Grenzen (§6, §7).


def _bundle_mit(user, geraet=None, **aenderungen):
    """Das Bundle des Nutzers, mit Geraetekennung und optionalen Aenderungen."""
    import relay_server as rs
    roh = dict(user["bundle"])
    if geraet is not None:
        roh["device_id"] = geraet
    roh.update(aenderungen)
    return rs.PreKeyBundle(**roh)


def _melde_an(rs, user, geraet=None, **aenderungen):
    """Eine vollstaendige Registrierung ueber den echten Endpunkt.

    Anders als _lege_an geht das hier durch Nonce, canonical_bytes und
    Signaturpruefung — bei Mehrgeraete haengt genau daran die Sicherheit, also
    darf es hier nicht abgekuerzt werden.
    """
    bundle = _bundle_mit(user, geraet, **aenderungen)
    nonce = rs.issue_nonce(user["user_id"], geraet)
    sig = sign(user["priv"],
               nonce + hashlib.sha256(bundle.canonical_bytes()).digest())
    return rs.register(
        rs.RegisterRequest(bundle=bundle, signature=b64(sig)), _Anfrage())


def _geraete(rs, user_id):
    return [r[0] for r in rs.db.execute(
        "SELECT device_id FROM identities WHERE user_id=? ORDER BY device_id",
        (user_id,))]


# ------------------------------------------------- §8  Wanderung der Bestandsdaten

# Das Schema, wie es auf relay.bitdm.net LAEUFT — woertlich und nicht aus
# relay_server.SCHEMA abgeleitet. Eine Kopie, die mitwandert, wuerde genau den
# Fall nicht mehr pruefen, um den es geht.
ALTES_SCHEMA = """
CREATE TABLE identities (
    user_id           TEXT PRIMARY KEY,
    identity_key      BLOB NOT NULL,
    registration_id   INTEGER NOT NULL DEFAULT 0,
    signed_prekey_id  INTEGER NOT NULL,
    signed_prekey     BLOB NOT NULL,
    signed_prekey_sig BLOB NOT NULL,
    updated_at        REAL NOT NULL,
    push_endpoint     TEXT
);
CREATE TABLE one_time_prekeys (
    user_id    TEXT NOT NULL,
    key_id     INTEGER NOT NULL,
    public_key BLOB NOT NULL,
    PRIMARY KEY (user_id, key_id),
    FOREIGN KEY (user_id) REFERENCES identities(user_id) ON DELETE CASCADE
);
CREATE TABLE queue (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    recipient  TEXT NOT NULL,
    sender     TEXT NOT NULL,
    ciphertext BLOB NOT NULL,
    ts         REAL NOT NULL
);
CREATE INDEX idx_queue_recipient ON queue(recipient);
CREATE INDEX idx_queue_ts        ON queue(ts);
"""


def _alte_datenbank(pfad, user, n_otk=4, n_queue=2):
    alt = sqlite3.connect(pfad)
    alt.executescript(ALTES_SCHEMA)
    pub = base64.b64decode(user["bundle"]["identity_key"])
    with alt:
        alt.execute(
            "INSERT INTO identities (user_id, identity_key, registration_id,"
            " signed_prekey_id, signed_prekey, signed_prekey_sig, updated_at,"
            " push_endpoint) VALUES (?,?,?,?,?,?,?,?)",
            (user["user_id"], pub, 4711, 9, b"spk", b"sig", 1_700_000_000.0,
             "https://push.bitdm.net/upAlt"),
        )
        alt.executemany(
            "INSERT INTO one_time_prekeys (user_id, key_id, public_key)"
            " VALUES (?,?,?)",
            [(user["user_id"], i, bytes([i]) * 32) for i in range(n_otk)],
        )
        alt.executemany(
            "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
            [(user["user_id"], "b" * 56, b"<blob>", time.time())
             for _ in range(n_queue)],
        )
    alt.close()


def test_bestehende_datenbank_wird_geraet_eins(tmp_path):
    """DER GEFAEHRLICHSTE TEST DER DATEI.

    relay.bitdm.net laeuft und hat echte Daten — Henriks eigene Registrierung
    liegt dort. `identities` hatte `user_id TEXT PRIMARY KEY`, und ein
    Primaerschluessel ist in SQLite per ALTER nicht erweiterbar; die Umstellung
    MUSS die Tabelle also neu anlegen und kopieren. Eine Neuanlage ohne Kopie
    loeschte seine Identitaet vom Relay, und er merkte es erst, wenn ihm niemand
    mehr schreiben kann.
    """
    import relay_server as rs
    pfad = tmp_path / "alt.db"
    user = make_user()
    _alte_datenbank(pfad, user)

    conn = rs.init_db(pfad)
    try:
        zeilen = conn.execute(
            "SELECT user_id, device_id, registration_id, signed_prekey_id,"
            " signed_prekey, push_endpoint, updated_at FROM identities"
        ).fetchall()
        assert len(zeilen) == 1, "die bestehende Registrierung ist weg"
        uid, geraet, reg, spk_id, spk, push, aktualisiert = zeilen[0]
        assert uid == user["user_id"]
        assert geraet == 1, "eine Bestandszeile MUSS Geraet 1 werden"
        # Feld fuer Feld unveraendert: eine Wanderung, die Werte verliert, ist
        # nicht besser als eine, die Zeilen verliert.
        assert (reg, spk_id, spk) == (4711, 9, b"spk")
        assert push == "https://push.bitdm.net/upAlt"
        assert aktualisiert == 1_700_000_000.0

        prekeys = conn.execute(
            "SELECT device_id, COUNT(*) FROM one_time_prekeys GROUP BY device_id"
        ).fetchall()
        assert prekeys == [(1, 4)], "die Einmalschluessel sind nicht mitgekommen"

        # Die Warteschlange behaelt ihre Zeilen und wird Post an Geraet 1.
        assert conn.execute(
            "SELECT COUNT(*) FROM queue WHERE recipient_device=1 AND sender_device=1"
        ).fetchone()[0] == 2

        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []

        # Der neue, zusammengesetzte Fremdschluessel muss auch NACH der
        # Wanderung greifen — sonst blieben beim Aufraeumen eines Geraets
        # dessen Einmalschluessel als Waisen liegen.
        # Ohne `with conn:` und mit rollback danach: die Probe darf den Rest
        # des Tests nicht veraendern.
        conn.execute("DELETE FROM identities WHERE user_id=?",
                     (user["user_id"],))
        assert conn.execute(
            "SELECT COUNT(*) FROM one_time_prekeys").fetchone()[0] == 0, \
            "die Kaskade ist bei der Wanderung verloren gegangen"
        conn.rollback()
        assert conn.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 1

        # Und ein zweiter Start ruehrt nichts mehr an.
        conn.close()
        conn = rs.init_db(pfad)
        assert conn.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 1
    finally:
        conn.close()


def test_die_wanderung_ueberlebt_den_ersten_janitorlauf(tmp_path, monkeypatch):
    """Die Falle, die die Spezifikation aufreisst — und die teuerste hier.

    §8 uebernimmt jede Bestandszeile mit `last_seen = 0`, §7 laesst den Janitor
    alles mit `last_seen < now - GERAET_TTL` loeschen. Beides woertlich
    genommen loescht JEDE Bestandsregistrierung beim ersten Aufraeumen — die
    Wanderung rettet die Zeile, und der Janitor loescht sie zwei Zeilen
    spaeter wieder.

    Am 30.07.2026 gegen den echten Serverstart gemessen und genau so
    eingetreten: `/health` meldete nach dem Hochfahren `users: 0`.

    Die Bestandszeile hier traegt `updated_at = 1_700_000_000` (Nov 2023) —
    der realistische Fall, denn `updated_at` ist der Zeitpunkt der letzten
    REGISTRIERUNG, nicht des letzten Besuchs. Ein Telefon, das taeglich
    verbindet, aber seit Monaten genug Einmalschluessel hat, steht dort alt da.
    """
    import relay_server as rs
    pfad = tmp_path / "alt.db"
    user = make_user()
    _alte_datenbank(pfad, user)

    conn = rs.init_db(pfad)
    monkeypatch.setattr(rs, "db", conn, raising=False)
    monkeypatch.setattr(rs, "_queue_zeilen", 0)
    try:
        assert conn.execute(
            "SELECT updated_at FROM identities").fetchone()[0] == 1_700_000_000.0, \
            "dieser Test haengt an einem ALTEN updated_at"

        assert rs.raeume_vergessene_geraete() == 0, (
            "der Janitor hat eine Bestandsregistrierung weggeraeumt — genau "
            "das, was die Wanderung eine Zeile vorher verhindert hat")
        assert conn.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 2

        # Und der zweite Fall, den LEBENSZEICHEN abdeckt: gerade registriert,
        # noch nie verbunden. last_seen steht auf 0, updated_at auf jetzt.
        with conn:
            conn.execute("UPDATE identities SET updated_at=?, last_seen=0",
                         (time.time(),))
        assert rs.raeume_vergessene_geraete() == 0, (
            "ein Geraet, das sein Buendel gerade hochgeladen hat, lebt")
    finally:
        conn.close()


# ------------------------------------------- §3.1/§3.2  Registrierung je Geraet

def test_zwei_geraete_teilen_sich_die_adresse_ohne_sich_zu_loeschen(relay):
    """Der Befund selbst, in seiner Umkehrung.

    Vorher loeschte `DELETE FROM one_time_prekeys WHERE user_id=?` bei jeder
    Registrierung den Vorrat des anderen Geraets mit, und
    `ON CONFLICT(user_id)` ueberschrieb dessen signed_prekey. Nach kurzer Zeit
    war ein Geraet ohne Einmalschluessel und mit fremdem Buendel im Netz.
    """
    rs = relay
    henrik = make_user(n_otk=5)

    a = _melde_an(rs, henrik, geraet=1)
    b = _melde_an(rs, henrik, geraet=4711,
                  signed_prekey=b64(b"S" * 32), signed_prekey_id=99)

    # Die Zahl in der Antwort zaehlt JE GERAET — der Client leitet daraus ab,
    # ob er nachliefern muss.
    assert a == {"ok": True, "one_time_prekeys": 5}
    assert b == {"ok": True, "one_time_prekeys": 5}

    assert _geraete(rs, henrik["user_id"]) == [1, 4711]
    assert rs.db.execute(
        "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=?",
        (henrik["user_id"],)).fetchone()[0] == 10, (
            "eine Registrierung hat dem anderen Geraet die Schluessel geloescht")

    # Und jedes Geraet behaelt SEIN eigenes signed_prekey.
    buendel = dict(rs.db.execute(
        "SELECT device_id, signed_prekey_id FROM identities WHERE user_id=?",
        (henrik["user_id"],)).fetchall())
    assert buendel == {1: 1, 4711: 99}


def test_alte_registrierung_signiert_dieselben_bytes_wie_vorher(relay):
    """Der eigentliche Rueckwaertsvertraeglichkeits-Beweis von /register.

    Fehlt `device_id`, fehlt es auch in canonical_bytes — die signierten Bytes
    einer App im Umlauf sind damit Byte fuer Byte die von vor dem Umbau. Waere
    das Feld immer dabei (etwa als 1), wuerde jede installierte App ab dem
    Aufspielen mit 403 abgewiesen.
    """
    rs = relay
    user = make_user(n_otk=2)

    ohne = rs.PreKeyBundle(**user["bundle"]).canonical_bytes()
    assert b"device_id" not in ohne
    # Genau die Bytes, die vor dem Umbau entstanden sind: sortierte Schluessel,
    # keine Leerzeichen, kein zusaetzliches Feld.
    assert ohne.startswith(b'{"identity_key":')

    mit = _bundle_mit(user, geraet=1).canonical_bytes()
    assert b'"device_id":1' in mit
    assert mit != ohne, (
        "die Kennung faellt aus der Signatur heraus — dann laesst sich eine "
        "abgefangene Signatur auf ein anderes Geraet ummuenzen")

    # Und der Endpunkt nimmt die alte Form weiterhin an, mit Geraet 1.
    assert _melde_an(rs, user)["ok"] is True
    assert _geraete(rs, user["user_id"]) == [1]


# ------------------------------------------------------------- §2  Die Angriffe

def test_geraet_unter_fremder_adresse_anmelden_scheitert(relay):
    """Mallory traegt sich als Geraet 7 unter Henriks Adresse ein.

    Der Riegel ist derselbe wie vor dem Umbau und muss es bleiben: die Adresse
    IST der Schluessel, `encode_id(identity_key) != user_id` faellt sofort auf.
    Eine Geraetekennung aendert daran nichts — sie waehlt nur die Zeile
    INNERHALB einer Adresse aus, die man schon besitzen muss.
    """
    rs = relay
    henrik, mallory = make_user(), make_user()
    _melde_an(rs, henrik, geraet=1)

    gefaelscht = _bundle_mit(mallory, geraet=7)
    gefaelscht.user_id = henrik["user_id"]
    nonce = rs.issue_nonce(henrik["user_id"], 7)
    sig = sign(mallory["priv"],
               nonce + hashlib.sha256(gefaelscht.canonical_bytes()).digest())

    with pytest.raises(rs.HTTPException) as fehler:
        rs.register(rs.RegisterRequest(bundle=gefaelscht, signature=b64(sig)),
                    _Anfrage())
    assert fehler.value.status_code == 400
    assert _geraete(rs, henrik["user_id"]) == [1]


def test_fremdes_geraet_kommt_nicht_ueber_die_websocket_rein(relay):
    """Dasselbe am anderen Tor.

    Mallory kennt Henriks Adresse (sie ist oeffentlich) und weiss, dass es dort
    ein Geraet 1 gibt (`?nur_geraete=1` sagt es jedem). Ohne den privaten
    Identitaetsschluessel kommt trotzdem keine gueltige Signatur zustande.
    """
    rs = relay
    henrik, mallory = make_user(), make_user()
    _lege_an(rs, henrik)

    sock = _StummerSocket(henrik["user_id"], mallory["priv"], geraet=1)
    asyncio.run(rs.ws_endpoint(sock))

    assert sock.geschlossen == 4403
    assert rs.connections == {}


def test_signatur_eines_anderen_geraets_laesst_sich_nicht_wiederverwenden(relay):
    """WARUM die Kennung in canonical_bytes gehoert — und nicht nur in den Rumpf.

    Stuende sie nur im Rumpf, koennte ein Weiterleitender sie aendern und
    dieselbe Signatur weiterverwenden. Die Registrierung landete unter fremder
    Geraetenummer, ueberschriebe dort das Buendel und loeschte die
    Einmalschluessel des echten Geraets.

    Der Test gibt dem Angreifer ABSICHTLICH ein gueltiges eigenes Nonce fuer
    Geraet 2 — sonst scheiterte er schon am Nonce, und die Frage, ob die Bytes
    die Kennung decken, bliebe ungeprueft.
    """
    rs = relay
    henrik = make_user()

    fuer_geraet_1 = _bundle_mit(henrik, geraet=1)
    nonce = rs.issue_nonce(henrik["user_id"], 2)
    abgefangen = sign(
        henrik["priv"],
        nonce + hashlib.sha256(fuer_geraet_1.canonical_bytes()).digest())

    umgemuenzt = _bundle_mit(henrik, geraet=2)
    with pytest.raises(rs.HTTPException) as fehler:
        rs.register(rs.RegisterRequest(bundle=umgemuenzt,
                                       signature=b64(abgefangen)), _Anfrage())
    assert fehler.value.status_code == 403
    assert _geraete(rs, henrik["user_id"]) == []


def test_ws_signatur_von_geraet_eins_gilt_nicht_fuer_geraet_zwei(relay):
    """Dasselbe fuer die Anmeldung: signiert wird nonce||uint32be(device_id).

    Ohne die Kennung in den signierten Bytes koennte jemand, der die Antwort
    von Geraet 1 abfaengt, sie unter Geraet 2 einreichen — das Nonce steht
    offen auf der Leitung.
    """
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1)
    _lege_an(rs, henrik, geraet=2)

    sock = _StummerSocket(henrik["user_id"], henrik["priv"],
                          geraet=2, signiert_geraet=1)
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.geschlossen == 4403

    # Gegenprobe: mit der richtigen Kennung geht dieselbe Anmeldung durch.
    ok = _StummerSocket(henrik["user_id"], henrik["priv"], geraet=2)
    asyncio.run(rs.ws_endpoint(ok))
    ergebnis = [m for m in ok.gesendet if m.get("type") == "auth_result"]
    assert ergebnis and ergebnis[0]["ok"] is True
    assert ergebnis[0]["device_id"] == 2


def test_ohne_geraetekennung_wird_weiterhin_nur_das_nonce_signiert(relay):
    """Der Regressionswall fuer die Apps im Umlauf.

    Sie haengen kein `device_id` an die Query und signieren 32 Byte. Erwartete
    der Server auch von ihnen 36, waere jede installierte App ab dem
    Aufspielen ausgesperrt.
    """
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, n_otk=30)
    _puffere(rs, henrik["user_id"], "b" * 56, n=2)

    raus = _sitzung(rs, henrik)                    # ohne geraet=
    ergebnis = [m for m in raus if m.get("type") == "auth_result"]
    assert ergebnis and ergebnis[0]["ok"] is True
    assert ergebnis[0]["device_id"] == 1, "ein alter Client ist Geraet 1"
    assert len([m for m in raus if m.get("type") == "message"]) == 2


# ------------------------------------------------------------ §3.3  /prekey

def test_prekey_gibt_alle_geraete_und_bleibt_flach_lesbar(relay):
    """Beide Leser derselben Antwort.

    Ein neuer Client liest `geraete[]` und verschluesselt an jedes einzeln. Ein
    alter liest die flachen Felder und erreicht damit weiterhin GENAU EIN
    Geraet — das mit der kleinsten Kennung, nicht fest Geraet 1: ist Geraet 1
    weggeraeumt, muss er trotzdem jemanden erreichen.
    """
    rs = relay
    henrik = make_user(n_otk=3)
    _melde_an(rs, henrik, geraet=4711, signed_prekey_id=99)
    _melde_an(rs, henrik, geraet=1, signed_prekey_id=7)

    antwort = rs.get_prekey(henrik["user_id"], _Anfrage())

    assert [g["device_id"] for g in antwort["geraete"]] == [1, 4711], \
        "aufsteigend nach Kennung"
    assert antwort["signed_prekey_id"] == 7, "flach = geraete[0]"
    assert antwort["registration_id"] == antwort["geraete"][0]["registration_id"]
    # Der Identitaetsschluessel gehoert der Adresse und steht nur einmal da.
    assert antwort["identity_key"] == henrik["bundle"]["identity_key"]

    # JEDES Geraet bekommt einen eigenen Einmalschluessel, und der flache ist
    # DERSELBE wie der von geraete[0] — kein zweiter, sonst kostete jede
    # Abfrage einen Schluessel zu viel.
    schluessel = [g["one_time_prekey"] for g in antwort["geraete"]]
    assert all(s is not None for s in schluessel)
    assert antwort["one_time_prekey"] == schluessel[0]
    assert rs.db.execute(
        "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=?",
        (henrik["user_id"],)).fetchone()[0] == 4, "3+3 minus je einer"

    # Und das kleinste Geraet ist nicht fest die 1.
    with rs.db:
        rs.db.execute("DELETE FROM identities WHERE user_id=? AND device_id=1",
                      (henrik["user_id"],))
    assert rs.get_prekey(henrik["user_id"], _Anfrage())["signed_prekey_id"] == 99


def test_nur_geraete_verbraucht_keinen_einmalschluessel(relay):
    """Der Aufruf, der oft kommt, darf nichts kosten.

    Der Client frischt seine Geraeteliste je Kontakt alle 6 Stunden auf. Zoege
    das jedes Mal einen Einmalschluessel, waere die Auffrischung selbst der
    Prekey-Drain, gegen den otk_limit_ok gebaut wurde.
    """
    rs = relay
    henrik = make_user(n_otk=3)
    _melde_an(rs, henrik, geraet=1)
    _melde_an(rs, henrik, geraet=2)
    vorher = rs.db.execute("SELECT COUNT(*) FROM one_time_prekeys").fetchone()[0]

    antwort = rs.get_prekey(henrik["user_id"], _Anfrage(), nur_geraete=True)

    assert antwort == {
        "user_id": henrik["user_id"],
        "geraete": [{"device_id": 1, "registration_id": 4711},
                    {"device_id": 2, "registration_id": 4711}],
    }
    assert "signed_prekey" not in antwort, "keine Schluessel in dieser Antwort"
    assert rs.db.execute(
        "SELECT COUNT(*) FROM one_time_prekeys").fetchone()[0] == vorher
    # Auch der Eimer je Adresse bleibt unangetastet: 20 Auffrischungen in
    # Folge, und der naechste echte Abruf bekommt trotzdem seinen Schluessel.
    for _ in range(20):
        rs.get_prekey(henrik["user_id"], _Anfrage(), nur_geraete=True)
    assert rs.get_prekey(
        henrik["user_id"], _Anfrage())["one_time_prekey"] is not None


# ----------------------------------------------------- §3.4  Zustellung je Geraet

def test_die_post_geht_an_das_genannte_geraet_und_traegt_from_device(relay):
    """`from_device` ist die wichtigste Erweiterung des ganzen Vorhabens.

    Ohne sie weiss der Empfaenger nicht, gegen welche Sitzung er entschluesseln
    soll. Zwei Umschlaege kaemen an, beide wuerden gegen `name:1` probiert,
    einer scheitert immer — und der Fehlversuch schreibt den Ratchet-Fortschritt
    fest, womit die Nachricht endgueltig verloren ist.
    """
    rs = relay
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna, geraet=3, n_otk=30)
    _lege_an(rs, bob, geraet=1, n_otk=30)
    _lege_an(rs, bob, geraet=2, n_otk=30)

    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "to_device": 1,
         "ciphertext": b64(b"an-eins"), "id": "m1"},
        {"type": "message", "to": bob["user_id"], "to_device": 2,
         "ciphertext": b64(b"an-zwei"), "id": "m2"},
    ], geraet=3)
    assert len([m for m in raus if m.get("type") == "ack"]) == 2

    # Jedes Geraet bekommt GENAU SEINEN Umschlag, mit Annas echter Kennung.
    for geraet, erwartet in ((1, b"an-eins"), (2, b"an-zwei")):
        seins = [m for m in _sitzung(rs, bob, geraet=geraet, nachweis=True)
                 if m.get("type") == "message"]
        assert len(seins) == 1, f"Geraet {geraet} bekam {len(seins)} Umschlaege"
        assert base64.b64decode(seins[0]["ciphertext"]) == erwartet
        assert seins[0]["from_device"] == 3, (
            "ohne from_device kann Bob die Sitzung nicht waehlen")


def test_from_device_kommt_aus_der_verbindung_und_nicht_aus_dem_rahmen(relay):
    """Sonst koennte jeder behaupten, von einem beliebigen Geraet zu schreiben.

    Live wie gepuffert: die Kennung ist die der angemeldeten Verbindung des
    Absenders.
    """
    rs = relay
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna, geraet=5, n_otk=30)
    _lege_an(rs, bob, n_otk=30)

    horcher = _Zuhoerer()
    _verbinde(rs, bob, horcher, nachweis=False)
    _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x"),
         # Die Luege im Rahmen. Sie darf nirgends ankommen.
         "from_device": 99, "sender_device": 99},
    ], geraet=5)

    live = [m for m in horcher.empfangen if m.get("type") == "message"]
    assert live and live[0]["from_device"] == 5


def test_zielgeraet_unbekannt_wird_nicht_gepuffert(relay):
    """Sonst liefe die Flut ueber eine echte Adresse mit erfundener Kennung.

    Die Existenzpruefung war bisher `WHERE user_id=?`. Damit haette ein
    Absender an Geraet 999 einer echten Adresse puffern koennen, das es nie
    gab — und der Deckel je Geraet zaehlte fuer jedes erfundene neu.
    """
    rs = relay
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna)
    _lege_an(rs, bob, geraet=1)

    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "to_device": 999,
         "ciphertext": b64(b"x"), "id": "m1"},
        # bool ist in Python ein int: ohne die zweite Pruefung waere True die
        # Kennung 1, und die gehoert einem echten Geraet.
        {"type": "message", "to": bob["user_id"], "to_device": True,
         "ciphertext": b64(b"x"), "id": "m2"},
    ])
    fehler = [m for m in raus if m.get("type") == "error"]
    assert [f["id"] for f in fehler] == ["m1", "m2"]
    assert all(f["reason"] == "Zielgeraet unbekannt" for f in fehler)
    assert not [m for m in raus if m.get("type") == "ack"]
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 0


def test_ohne_to_device_geht_die_post_an_das_kleinste_lebende_geraet(relay):
    """Der Rueckwaertsvertrag haelt nur, wenn beide Haelften dasselbe meinen.

    /prekey gibt dem alten Client die flachen Felder von `geraete[0]`, also vom
    Geraet mit der KLEINSTEN Kennung — ausdruecklich nicht fest Geraet 1, damit
    er nach dem Wegraeumen noch jemanden erreicht (§3.3, Docstring von
    get_prekey). Sein Rahmen kann kein `to_device` tragen. Setzte der Sendeweg
    dafuer fest 1, bekaeme er die richtigen Schluessel und trotzdem dauerhaft
    "Zielgeraet unbekannt" — eine Adresse ohne lebendes Geraet 1 waere fuer
    JEDEN nicht aktualisierten Client unerreichbar. Und Geraet 1 faellt weg:
    raeume_vergessene_geraete kennt keine Ausnahme fuer die 1, ebensowenig die
    Verdraengung beim vollen Geraetedeckel.
    """
    rs = relay
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna)
    _lege_an(rs, bob, geraet=1, last_seen=time.time() - rs.GERAET_TTL - 60)
    _lege_an(rs, bob, geraet=4711)
    assert rs.raeume_vergessene_geraete() == 1
    assert _geraete(rs, bob["user_id"]) == [4711]
    # Beide Haelften der Antwort meinen dasselbe Geraet.
    assert rs.get_prekey(bob["user_id"], _Anfrage())["geraete"][0]["device_id"] \
        == 4711

    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"alt"),
         "id": "m1"},
    ])
    assert [m["reason"] for m in raus if m.get("type") == "error"] == []
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["m1"]
    assert rs.db.execute(
        "SELECT recipient_device FROM queue WHERE recipient=?",
        (bob["user_id"],)).fetchall() == [(4711,)]

    # Gegenpol: lebt Geraet 1, ist es weiterhin das Ziel — MIN(device_id) IST
    # dann die 1, und der alte Weg bleibt unveraendert.
    _lege_an(rs, bob, geraet=1)
    _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"alt2"),
         "id": "m2"},
    ])
    assert [r[0] for r in rs.db.execute(
        "SELECT recipient_device FROM queue WHERE recipient=? ORDER BY id",
        (bob["user_id"],))] == [4711, 1]


def test_riesige_geraetekennung_in_der_query_reisst_die_verbindung_nicht(relay):
    """`int()` kennt keine Obergrenze, die SQLite-Bindung schon.

    `?device_id=9223372036854775808` ging bis hierher unveraendert in die
    Bindung. Der OverflowError faellt nicht in `except ValueError`, verlaesst
    ws_endpoint ungefangen und kappt die Verbindung ohne Close-Frame — und das
    VOR der Challenge: ohne Registrierung, ohne Schluessel, ohne gueltige
    Adresse. Der /ws-Handler hat keine Ratenbremse, jeder Versuch schrieb rund
    3,7 kB Traceback ins Log.
    """
    rs = relay
    fremder = make_user()
    for kennung in (2**63, 10**23, -(10**23), 0, 2**31):
        sock = _StummerSocket(fremder["user_id"], fremder["priv"], geraet=kennung)
        entwischt = None
        try:
            asyncio.run(rs.ws_endpoint(sock))
        except BaseException as exc:          # noqa: BLE001 — wird geprueft
            entwischt = exc
        assert entwischt is None, f"device_id={kennung} entwischt: {entwischt!r}"
        assert sock.gesendet == [
            {"type": "error", "reason": "erst /register aufrufen"}], kennung
        assert sock.geschlossen == 4401, kennung


def test_riesige_kennungen_im_rahmen_reissen_die_verbindung_nicht(relay):
    """Dieselbe Wurzel eine Ebene weiter, hier fuer einen ANGEMELDETEN Absender.

    `to_device` und die Zeilenkennungen im Empfangsnachweis kommen roh aus dem
    JSON. Jenseits 2**63 wirft die Bindung OverflowError, und die Fangliste der
    Hauptschleife kennt ihn nicht: die Verbindung riss mitten im Versand ab,
    die Nachricht war danach weder gepuffert noch quittiert.
    """
    rs = relay
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna, geraet=1, n_otk=30)
    _lege_an(rs, bob, geraet=1, n_otk=30)
    _puffere(rs, anna["user_id"], bob["user_id"], n=2, geraet=1)
    offen = [r[0] for r in rs.db.execute("SELECT id FROM queue ORDER BY id")]

    entwischt, raus = None, []
    try:
        raus = _sitzung(rs, anna, [
            {"type": "message", "to": bob["user_id"], "to_device": 10**30,
             "ciphertext": b64(b"x"), "id": "m1"},
            {"type": "empfangen", "ids": [10**30, -(2**63)]},
            # Und danach muss die Leitung noch stehen.
            {"type": "message", "to": bob["user_id"],
             "ciphertext": b64(b"y"), "id": "m2"},
        ], geraet=1, nachweis=True)
    except BaseException as exc:              # noqa: BLE001 — wird geprueft
        entwischt = exc
    assert entwischt is None, f"Ausnahme verlaesst ws_endpoint: {entwischt!r}"
    assert [(m["id"], m["reason"]) for m in raus if m.get("type") == "error"] \
        == [("m1", "Zielgeraet unbekannt")]
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["m2"]
    assert [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient=? ORDER BY id",
        (anna["user_id"],))] == offen, "eigene Post am Nachweis verloren"


def test_riesige_zahlen_im_bundle_sind_ein_fehler_des_absenders(relay):
    """400 statt 500 — und nichts halb Gespeichertes.

    registration_id, signed_prekey_id und key_id sind blanke `int` ohne
    Obergrenze. Ab 2**63 wirft die Bindung OverflowError; er erbt nicht von
    ValueError und fiel deshalb an der Fangliste des Endpunkts vorbei. Der
    Server meldete einen Fehler des Absenders als seinen eigenen.
    """
    rs = relay
    henrik = make_user(n_otk=1)
    riesen = [
        {"registration_id": 10**30},
        {"signed_prekey_id": 10**30},
        {"one_time_prekeys": [{"key_id": 10**30, "public_key": b64(b"k" * 32)}]},
    ]
    for aenderung in riesen:
        with pytest.raises(rs.HTTPException) as fehler:
            _melde_an(rs, henrik, **aenderung)
        assert fehler.value.status_code == 400, aenderung
    # Der key_id-Fall legt die Identitaetszeile an, bevor er scheitert: ohne
    # das `with db:` darum bliebe sie stehen.
    assert _geraete(rs, henrik["user_id"]) == []


def test_fremdes_geraet_derselben_adresse_leert_die_schlange_nicht(relay):
    """DIE GEFAEHRLICHSTE EINZELNE STELLE DES UMBAUS.

    `AND recipient=?` trennt nicht mehr: beide Geraete FUEHREN dieselbe
    Adresse, beide sind angemeldet, und die Zeilenkennungen sind fortlaufend
    und damit zu erraten. Ohne `AND recipient_device=?` koennte Geraet A die
    noch nicht zugestellte Post von Geraet B loeschen — stiller Verlust, kein
    Fehler, keine Spur.
    """
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1, n_otk=30)
    _lege_an(rs, henrik, geraet=2, n_otk=30)
    _puffere(rs, henrik["user_id"], "b" * 56, n=4, geraet=2)
    fuer_zwei = [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient_device=2 ORDER BY id")]
    assert len(fuer_zwei) == 4

    # Geraet 1 bestaetigt die Kennungen von Geraet 2 — mit derselben Adresse
    # und einem gueltigen Besitznachweis.
    _sitzung(rs, henrik, [{"type": "empfangen", "ids": fuer_zwei}],
             geraet=1, nachweis=True)

    assert [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient_device=2 ORDER BY id")] == fuer_zwei, \
        "Geraet 1 hat die Post von Geraet 2 geloescht"

    # Und Geraet 2 bekommt sie trotzdem, samt seiner eigenen Bestaetigung.
    raus = _sitzung(rs, henrik, geraet=2, nachweis=True, bestaetigt=True)
    assert [m["q"] for m in raus if m.get("type") == "message"] == fuer_zwei
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 0


def test_die_nachzustellung_gibt_jedem_geraet_nur_seine_eigene_post(relay):
    """Das Gegenstueck zur Loeschseite.

    Bekaeme jedes Geraet die Umschlaege des anderen mit, waere jeder davon
    gegen eine Sitzung verschluesselt, die es nicht hat — und der erste
    Fehlversuch schreibt den Ratchet-Fortschritt fest.
    """
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1, n_otk=30)
    _lege_an(rs, henrik, geraet=2, n_otk=30)
    _puffere(rs, henrik["user_id"], "b" * 56, n=2, geraet=1)
    _puffere(rs, henrik["user_id"], "b" * 56, n=3, geraet=2)

    fuer_eins = _sitzung(rs, henrik, geraet=1, nachweis=True)
    fuer_zwei = _sitzung(rs, henrik, geraet=2, nachweis=True)
    assert len([m for m in fuer_eins if m.get("type") == "message"]) == 2
    assert len([m for m in fuer_zwei if m.get("type") == "message"]) == 3


def test_zwei_geraete_derselben_adresse_verdraengen_sich_nicht(relay):
    """Das Gegenstueck zu test_verdraengte_verbindung_reisst_die_neue_nicht_mit.

    Frueher verdraengte jede neue Verbindung die einzige der Adresse. Zwei
    Geraete mit denselben zwoelf Woertern warfen sich damit abwechselnd
    hinaus, und keines merkte etwas. Verdraengt werden darf nur noch dasselbe
    GERAET — das ist ein App-Neustart und soll die alte Leitung ersetzen.
    """
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1, n_otk=30)
    _lege_an(rs, henrik, geraet=2, n_otk=30)

    class _Leitung:
        def __init__(self):
            self.geschlossen = None
            self.empfangen = []

        async def send_json(self, obj):
            self.empfangen.append(obj)

        async def close(self, code=None):
            self.geschlossen = code

    eins = _Leitung()
    _verbinde(rs, henrik, eins, geraet=1)

    _sitzung(rs, henrik, geraet=2, nachweis=True)
    assert eins.geschlossen is None, "Geraet 2 hat Geraet 1 hinausgeworfen"
    assert rs.connections[henrik["user_id"]] == {1: eins}

    # Dasselbe Geraet noch einmal verdraengt dagegen sehr wohl.
    _sitzung(rs, henrik, geraet=1, nachweis=True)
    assert eins.geschlossen == 4409


# ------------------------------------------------------ §6/§7  Grenzen und Zerfall

def test_das_sechste_geraet_wird_abgewiesen(relay, monkeypatch):
    """Jedes Geraet kostet dem ABSENDER eine Verschluesselung.

    Ohne Deckel bezahlt ein Fremder beliebig viel Rechenzeit und
    Warteschlangenplatz dafuer, dass jemand anders sich Geraete anlegt. 507 und
    nicht 429: das ist keine Bremse, die nachgibt.
    """
    rs = relay
    monkeypatch.setattr(rs, "GERAETE_MAX", 3)
    henrik = make_user()
    for g in (1, 2, 3):
        assert _melde_an(rs, henrik, geraet=g)["ok"] is True

    with pytest.raises(rs.HTTPException) as fehler:
        _melde_an(rs, henrik, geraet=4)
    assert fehler.value.status_code == 507
    assert "3 Geraete" in fehler.value.detail
    assert _geraete(rs, henrik["user_id"]) == [1, 2, 3]

    # WER SCHON DA IST, KOMMT IMMER DURCH — sonst koennte ein Geraet an einer
    # vollen Adresse nie mehr Einmalschluessel nachliefern und waere nach dem
    # Aufbrauchen des Vorrats unerreichbar.
    assert _melde_an(rs, henrik, geraet=2)["ok"] is True


def test_ein_totes_geraet_macht_platz(relay, monkeypatch):
    """Sonst waere eine Adresse nach fuenf Neuinstallationen fuer immer voll.

    Verdraengt wird NUR, was seit GERAET_TTL kein Lebenszeichen gegeben hat.
    Lebende Geraete werden nicht verdraengt: bei sechs lebenden wuerfen sie
    sich bei jeder Buendel-Erneuerung gegenseitig hinaus, und aus dem
    Dauerpendeln wuerde Nachrichtenverlust.
    """
    rs = relay
    monkeypatch.setattr(rs, "GERAETE_MAX", 2)
    henrik = make_user()
    _melde_an(rs, henrik, geraet=1)
    _melde_an(rs, henrik, geraet=2)
    _puffere(rs, henrik["user_id"], "b" * 56, n=3, geraet=1)
    assert rs._queue_zeilen == 3

    # Geraet 1 ist seit 40 Tagen nicht mehr da gewesen.
    lange_her = time.time() - 40 * 24 * 3600
    with rs.db:
        rs.db.execute("UPDATE identities SET last_seen=?, updated_at=?"
                      " WHERE user_id=? AND device_id=1",
                      (lange_her, lange_her, henrik["user_id"]))

    assert _melde_an(rs, henrik, geraet=3)["ok"] is True
    assert _geraete(rs, henrik["user_id"]) == [2, 3], \
        "das tote Geraet haette weichen muessen, nicht das lebende"

    # Seine Warteschlange geht mit — sie zeigt auf ein Geraet, das es nicht
    # mehr gibt, und laege sonst bis QUEUE_TTL_SECONDS herum.
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 0
    assert rs._queue_zeilen == 0
    # Die Einmalschluessel nimmt die Kaskade.
    assert rs.db.execute(
        "SELECT COUNT(*) FROM one_time_prekeys WHERE device_id=1").fetchone()[0] == 0


def test_vergessene_geraete_raeumt_der_janitor_weg(relay, monkeypatch):
    """Ein totes Telefon macht die Adresse sonst teilweise unbeschickbar.

    Solange seine Zeile lebt, hat es eine eigene Warteschlange, die dauerhaft
    an ihrem Deckel steht — und ab da faellt fuer jeden Absender an dieses
    Geraet die aelteste Zeile weg.
    """
    rs = relay
    monkeypatch.setattr(rs, "GERAET_TTL", 30 * 24 * 3600)
    henrik = make_user()
    lange_her = time.time() - 40 * 24 * 3600
    _lege_an(rs, henrik, geraet=1)
    _lege_an(rs, henrik, geraet=2, last_seen=lange_her)
    _puffere(rs, henrik["user_id"], "b" * 56, n=2, geraet=2)

    assert rs.raeume_vergessene_geraete() == 1
    assert _geraete(rs, henrik["user_id"]) == [1]
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 0
    assert rs._queue_zeilen == 0


def test_bei_voller_geraeteschlange_faellt_die_aelteste_zeile(relay, monkeypatch):
    """Nicht der Absender wird abgewiesen, sondern die aelteste Zeile faellt.

    Sonst haengt eine lebende Unterhaltung an einem toten Telefon: der
    Absender bekaeme 'Warteschlange voll' fuer eine Adresse, deren anderes
    Geraet direkt neben ihm liegt. Der Verlust trifft nur das volle Geraet.
    """
    rs = relay
    monkeypatch.setattr(rs, "QUEUE_MAX_PER_USER", 2)
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna)
    _lege_an(rs, bob, geraet=1)
    _lege_an(rs, bob, geraet=2)
    _puffere(rs, bob["user_id"], anna["user_id"], n=2, geraet=1)
    alt = [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient_device=1 ORDER BY id")]

    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "to_device": 1,
         "ciphertext": b64(b"neu"), "id": "m1"},
    ])
    assert [m for m in raus if m.get("type") == "ack"], \
        "der Absender wurde abgewiesen, statt die aelteste Zeile fallen zu lassen"

    jetzt = [r[0] for r in rs.db.execute(
        "SELECT id FROM queue WHERE recipient_device=1 ORDER BY id")]
    assert len(jetzt) == 2 and alt[0] not in jetzt and alt[1] in jetzt
    assert rs._queue_zeilen == 2, "der Zaehler ist dem Wegwerfen nicht gefolgt"

    # Das ANDERE Geraet derselben Adresse ist davon unberuehrt — der Deckel
    # haengt am Geraet, nicht an der Adresse.
    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "to_device": 2,
         "ciphertext": b64(b"auch-neu"), "id": "m2"},
    ])
    assert [m for m in raus if m.get("type") == "ack"]
    assert rs.db.execute(
        "SELECT COUNT(*) FROM queue WHERE recipient_device=2").fetchone()[0] == 1


def test_das_dach_ueber_der_tabelle_gibt_auch_je_geraet_nicht_nach(relay,
                                                                  monkeypatch):
    """Die Gegenprobe zum Wegwerfen: QUEUE_MAX_TOTAL weist WEITER ab.

    Gaebe auch das Dach nach, waere der Deckel je Geraet beliebig oft zu
    haben — man braucht nur ein weiteres Zielgeraet.
    """
    rs = relay
    monkeypatch.setattr(rs, "QUEUE_MAX_TOTAL", 1)
    anna, bob = make_user(), make_user()
    _lege_an(rs, anna)
    _lege_an(rs, bob, geraet=1)
    _lege_an(rs, bob, geraet=2)

    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "to_device": 1,
         "ciphertext": b64(b"x"), "id": "m1"},
        {"type": "message", "to": bob["user_id"], "to_device": 2,
         "ciphertext": b64(b"y"), "id": "m2"},
    ])
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["m1"]
    voll = [m for m in raus if m.get("reason") == "Warteschlange voll"]
    assert [m["id"] for m in voll] == ["m2"]


def test_health_zaehlt_adressen_und_geraete_getrennt(relay):
    """Sonst bedeutete die Betriebszahl etwas anderes als vor dem Umbau.

    `users` haengt an IDENTITAETEN_MAX. Zaehlte es Zeilen statt Adressen,
    saenke die Aufnahmegrenze des Relays um den Geraetefaktor — bei fuenf
    Geraeten je Adresse auf ein Fuenftel, ohne dass jemand etwas geaendert
    haette.
    """
    rs = relay
    henrik, anna = make_user(), make_user()
    _lege_an(rs, henrik, geraet=1)
    _lege_an(rs, henrik, geraet=2)
    _lege_an(rs, anna, geraet=1)

    stand = rs.health()
    assert stand["users"] == 2
    assert stand["geraete"] == 3
    assert stand["online"] == 0

    _verbinde(rs, henrik, _Zuhoerer(), geraet=1)
    _verbinde(rs, henrik, _Zuhoerer(), geraet=2)
    assert rs.health()["online"] == 2, "online zaehlt Sockets, nicht Adressen"


def test_die_tagesmenge_des_zwischenlagers_bleibt_an_der_adresse(relay):
    """Als ABSICHT festgehalten, damit es niemand 'der Vollstaendigkeit halber'
    nachtraegt.

    Mit einer Geraetespalte bekaeme dieselbe Person mit 5 Geraeten 125 GiB am
    Tag statt 25 — die Verteidigung waere fuer den Preis eines zweiten Geraets
    aufzuheben, und ein Geraet anzulegen kostet nichts.
    """
    rs = relay
    spalten = {r[1] for r in rs.db.execute("PRAGMA table_info(blob_marken)")}
    assert "device_id" not in spalten
    assert spalten == {"id", "user_id", "groesse", "ts"}


def test_tarnverkehr_wird_still_verworfen(relay):
    """Ein "geraeus"-Rahmen sieht aus wie eine Nachricht und darf nichts tun:
    keine Zeile in der Warteschlange — und die Verbindung bleibt fuer echte
    Nachrichten offen.

    SEIT 25.09.2026 MIT ANTWORT: frueher hiess es hier "keine Antwort (ein ack
    oder error verriete ihn)". Das Gegenteil stimmte — auf eine echte
    Nachricht folgt ein `ack`, auf Tarnverkehr kam nichts, und genau das
    Fehlen verriet ihn einem Beobachter der Leitung. Die Antwort ist jetzt ein
    `ack` desselben Aufbaus; wie sie genau aussieht, prueft
    test_tarnverkehr_bekommt_ein_ack_wie_eine_echte_nachricht."""
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    raus = _sitzung(rs, alice, [
        {"type": "geraeus", "to": bob["user_id"], "ciphertext": b64(os.urandom(600)), "id": "g1"},
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x"), "id": "m1"},
    ])
    assert [m.get("type") for m in raus if m.get("id") == "g1"] == ["ack"], \
        "Tarnverkehr bekam nicht genau ein ack"
    assert [m for m in raus if m.get("type") == "ack" and m.get("id") == "m1"]
    assert rs.db.execute(
        "SELECT COUNT(*) FROM queue WHERE recipient=?", (bob["user_id"],)
    ).fetchone()[0] == 1, "der Tarnrahmen landete in der Warteschlange"


# --------------------------------------------------------------------------- #
#  Audit vom 25.09.2026
# --------------------------------------------------------------------------- #
#
# Je Befund mindestens ein Test, der ohne die Behebung rot ist. Die Nummern
# sind die des Audits; die Beweisskripte des Pruefers haben dieselben Faelle
# gegen einen echten uvicorn gefahren.


class _Kopf:
    """Eine Anfrage mit frei waehlbaren Kopfzeilen (klein geschrieben, wie
    Starlette sie liefert).

    `x_forwarded_for` steht zusaetzlich in `client`: so macht es uvicorn mit
    `--proxy-headers --forwarded-allow-ips 127.0.0.1`, wenn nginx auf der
    Schleife der Gegenueber ist. Mit `gegenueber` steht stattdessen der
    unmittelbare Gegenueber dort - ein Relay, der ohne nginx lauscht und der
    Kopfzeile deshalb nicht glaubt (SV-10)."""

    def __init__(self, gegenueber=None, **kopfzeilen):
        self.headers = {k.replace("_", "-"): v for k, v in kopfzeilen.items()}
        host = gegenueber or kopfzeilen.get("x_forwarded_for")
        self.client = _Gegenueber(host) if host else None


class _Gegenueber:
    def __init__(self, host):
        self.host = host


def _registriere_mit(rs, user, nonce, priv=None, geraet=None, anfrage=None):
    """/register mit einer Signatur ueber GENAU dieses Nonce."""
    bundle = _bundle_mit(user, geraet)
    sig = sign(priv or user["priv"],
               nonce + hashlib.sha256(bundle.canonical_bytes()).digest())
    return rs.register(rs.RegisterRequest(bundle=bundle, signature=b64(sig)),
                       anfrage or _Anfrage())


# ---------------------------------------------- 1  Speicher der Nonces und Eimer

def test_abgelaufene_nonces_und_volle_eimer_werden_weggeraeumt(relay):
    """Frueher wuchsen _nonces und _buckets mit jeder /register/challenge fuer
    eine erfundene Adresse, und nichts raeumte je auf (proof_mem.py: 50 000
    Anfragen, 50 000 Eintraege je Tabelle, dauerhaft)."""
    rs = relay
    for _ in range(50):
        rs.issue_nonce(encode_id(os.urandom(32)), 1)
        rs.rate_limit_ok(f"chal:10.0.0.{os.urandom(1)[0]}")
    assert rs._nonce_zahl == 50 and rs._buckets

    spaeter = time.monotonic() + max(rs.NONCE_TTL_SECONDS,
                                     rs.RATE_CAPACITY / rs.RATE_REFILL_PER_SEC) + 1
    with rs._speichersperre:
        rs._raeume_speicher_auf(spaeter)
    assert rs._nonces == {} and rs._nonce_zahl == 0
    assert rs._buckets == {}, "ein wieder voller Eimer ist von keinem nicht zu unterscheiden"


def test_ein_halb_leerer_eimer_ueberlebt_das_aufraeumen(relay):
    """Die Gegenprobe: wer gerade gebremst wird, bekommt durch das Aufraeumen
    keinen frischen Eimer geschenkt."""
    rs = relay
    for _ in range(rs.OTK_CAPACITY):
        rs.otk_limit_ok("ziel")
    assert not rs.otk_limit_ok("ziel")
    with rs._speichersperre:
        rs._raeume_speicher_auf(time.monotonic() + 1)
    assert not rs.otk_limit_ok("ziel"), "der leere Eimer wurde weggeraeumt"


def test_am_speicherdach_antwortet_die_challenge_mit_503(relay, monkeypatch):
    rs = relay
    monkeypatch.setattr(rs, "SPEICHER_MAX", 5)
    for _ in range(5):
        rs.issue_nonce(encode_id(os.urandom(32)))
    with pytest.raises(rs.HTTPException) as fehler:
        rs.register_challenge(
            rs.ChallengeRequest(user_id=encode_id(os.urandom(32))), _Anfrage())
    assert fehler.value.status_code == 503
    assert rs._nonce_zahl == 5, "am Dach darf nichts mehr dazukommen"


# ---------------------------------------- 2/3  Deckel je Absender, kein Wegspuelen

def test_ein_fremder_spuelt_die_wartende_post_anderer_nicht_weg(relay, monkeypatch):
    """Der Befund: bei vollem Geraet fiel die aelteste Zeile, gleich von wem.
    Ein Fremder spuelte so mit ein paar Rahmen alles weg, was echte Kontakte
    dem abwesenden Opfer hinterlassen hatten (proof_ws.py P7)."""
    rs = relay
    monkeypatch.setattr(rs, "QUEUE_MAX_PER_USER", 5)
    opfer, freund, fremder = make_user(), make_user(), make_user()
    for u in (opfer, freund, fremder):
        _lege_an(rs, u)
    _puffere(rs, opfer["user_id"], freund["user_id"], n=2)

    raus = _sitzung(rs, fremder, [
        {"type": "message", "to": opfer["user_id"], "ciphertext": b64(b"spam")}
        for _ in range(10)
    ])
    assert len([m for m in raus if m.get("type") == "ack"]) == 10
    absender = [r[0] for r in rs.db.execute(
        "SELECT sender FROM queue WHERE recipient=?", (opfer["user_id"],))]
    assert absender.count(freund["user_id"]) == 2, "die Post des Freundes ist weg"
    assert len(absender) == 5


def test_voll_je_paar_faellt_nur_die_eigene_aelteste(relay, monkeypatch):
    rs = relay
    monkeypatch.setattr(rs, "QUEUE_MAX_JE_PAAR", 3)
    opfer, freund, fremder = make_user(), make_user(), make_user()
    for u in (opfer, freund, fremder):
        _lege_an(rs, u)
    _puffere(rs, opfer["user_id"], freund["user_id"], n=1)

    _sitzung(rs, fremder, [
        {"type": "message", "to": opfer["user_id"],
         "ciphertext": b64(b"spam%d" % i)} for i in range(5)
    ])
    zeilen = rs.db.execute(
        "SELECT sender, ciphertext FROM queue WHERE recipient=? ORDER BY id",
        (opfer["user_id"],)).fetchall()
    vom_fremden = [ct for s, ct in zeilen if s == fremder["user_id"]]
    assert vom_fremden == [b"spam2", b"spam3", b"spam4"], "nicht die eigene aelteste"
    assert [s for s, _ in zeilen].count(freund["user_id"]) == 1
    assert rs._queue_zeilen == 4


def test_ein_absender_hat_einen_eigenen_deckel(relay, monkeypatch):
    rs = relay
    monkeypatch.setattr(rs, "QUEUE_MAX_JE_ABSENDER", 3)
    fremder = make_user()
    ziele = [make_user() for _ in range(4)]
    for u in [fremder] + ziele:
        _lege_an(rs, u)
    raus = _sitzung(rs, fremder, [
        {"type": "message", "to": z["user_id"], "ciphertext": b64(b"x"), "id": f"m{i}"}
        for i, z in enumerate(ziele)
    ])
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["m0", "m1", "m2"]
    assert [m["id"] for m in raus if m.get("reason") == "Warteschlange voll"] == ["m3"]


def test_am_dach_weicht_der_schwerste_absender_und_nicht_alle(relay, monkeypatch):
    """Frueher wies das Dach JEDEN ab — ein einziger Flutender schaltete die
    Offline-Zustellung fuer alle ab. Jetzt faellt dessen aelteste Zeile; er
    selbst wird weiter abgewiesen."""
    rs = relay
    monkeypatch.setattr(rs, "QUEUE_MAX_TOTAL", 3)
    fremder, opfer, anna, bob = (make_user() for _ in range(4))
    for u in (fremder, opfer, anna, bob):
        _lege_an(rs, u)
    _puffere(rs, opfer["user_id"], fremder["user_id"], n=3)

    raus = _sitzung(rs, anna, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"echt"), "id": "a1"},
    ])
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["a1"]
    assert rs.db.execute("SELECT COUNT(*) FROM queue WHERE sender=?",
                         (fremder["user_id"],)).fetchone()[0] == 2
    assert rs._queue_zeilen == 3

    raus = _sitzung(rs, fremder, [
        {"type": "message", "to": opfer["user_id"], "ciphertext": b64(b"x"), "id": "f1"},
    ])
    assert [m["id"] for m in raus if m.get("reason") == "Warteschlange voll"] == ["f1"]


def test_die_warteschlange_hat_die_indizes_fuer_die_deckel(relay):
    rs = relay
    namen = {r[1] for r in rs.db.execute("PRAGMA index_list(queue)")}
    assert {"idx_queue_paar", "idx_queue_absender", "idx_queue_ts"} <= namen
    plan = " ".join(str(r) for r in rs.db.execute(
        "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM queue WHERE recipient=?"
        " AND recipient_device=? AND sender=?", ("a", 1, "b")))
    assert "idx_queue_paar" in plan


# ------------------------------------------------ 4  Laengen im Buendel

@pytest.mark.parametrize("aenderung", [
    {"signed_prekey": b64(os.urandom(100))},
    {"signed_prekey": b64(b"\x07" + os.urandom(32))},
    {"signed_prekey_sig": b64(os.urandom(65))},
    {"signed_prekey": "!!!kein base64!!!"},
    {"one_time_prekeys": [{"key_id": 1, "public_key": b64(os.urandom(190_000))}]},
    {"one_time_prekeys": [{"key_id": 1, "public_key": b64(os.urandom(31))}]},
])
def test_falsche_schluessellaengen_werden_abgewiesen(relay, aenderung):
    """Ohne Pruefung konnte jede Registrierung rund 190 KiB in identities und
    one_time_prekeys ablegen — dauerhaft."""
    rs = relay
    henrik = make_user()
    with pytest.raises(rs.HTTPException) as fehler:
        _melde_an(rs, henrik, **aenderung)
    assert fehler.value.status_code == 400
    assert _geraete(rs, henrik["user_id"]) == []


def test_serialisierte_schluessel_mit_typbyte_gehen_durch(relay):
    """So schickt die App sie wirklich: 33 Byte, 0x05 vorn."""
    rs = relay
    henrik = make_user()
    r = _melde_an(rs, henrik,
                  signed_prekey=b64(b"\x05" + os.urandom(32)),
                  one_time_prekeys=[{"key_id": i, "public_key": b64(b"\x05" + os.urandom(32))}
                                    for i in range(3)])
    assert r == {"ok": True, "one_time_prekeys": 3}


def test_der_datenbankfehler_geht_nicht_an_den_client(relay):
    """Frueher stand der SQLite-Text in der Antwort ("UNIQUE constraint
    failed: one_time_prekeys...")."""
    rs = relay
    henrik = make_user()
    doppelt = [{"key_id": 1, "public_key": b64(os.urandom(32))}] * 2
    with pytest.raises(rs.HTTPException) as fehler:
        _melde_an(rs, henrik, one_time_prekeys=doppelt)
    assert fehler.value.status_code == 400
    assert fehler.value.detail == "Bundle konnte nicht gespeichert werden"


# ------------------------------------------------ 5  Mehrere offene Nonces

def test_eine_fremde_challenge_nimmt_dem_opfer_sein_nonce_nicht(relay):
    """proof_ws.py P6: das zweite /register/challenge ueberschrieb das erste."""
    rs = relay
    opfer = make_user()
    eigenes = rs.issue_nonce(opfer["user_id"])
    rs.issue_nonce(opfer["user_id"])          # der Stoerer
    assert _registriere_mit(rs, opfer, eigenes)["ok"] is True


def test_ein_fehlversuch_verbraucht_das_nonce_nicht(relay):
    """Sonst liesse sich mit einem Unsinns-/register das Nonce eines Fremden
    wegwerfen."""
    rs = relay
    opfer, stoerer = make_user(), make_user()
    nonce = rs.issue_nonce(opfer["user_id"])
    with pytest.raises(rs.HTTPException) as fehler:
        _registriere_mit(rs, opfer, nonce, priv=stoerer["priv"])
    assert fehler.value.status_code == 403
    assert _registriere_mit(rs, opfer, nonce)["ok"] is True


def test_jedes_nonce_gilt_weiterhin_genau_einmal(relay):
    rs = relay
    henrik = make_user()
    nonce = rs.issue_nonce(henrik["user_id"])
    assert _registriere_mit(rs, henrik, nonce)["ok"] is True
    with pytest.raises(rs.HTTPException) as fehler:
        _registriere_mit(rs, henrik, nonce)
    assert fehler.value.status_code == 401


def test_mehr_als_die_plaetze_verdraengen_das_aelteste_nonce(relay):
    rs = relay
    henrik = make_user()
    ausgegeben = [rs.issue_nonce(henrik["user_id"]) for _ in range(rs.NONCE_PLAETZE + 1)]
    offen = rs.offene_nonces(henrik["user_id"])
    assert offen == ausgegeben[1:]
    assert rs._nonce_zahl == rs.NONCE_PLAETZE


# B3 der Pruefung vom 14.10.2026: mit acht Plaetzen je Paar verdraengte ein
# Fremder das Nonce des Opfers weiterhin, wenn er acht Challenges in dessen
# Fenster legte. Jetzt gehoeren die Plaetze der Herkunft.

def _challenge(rs, user, anfrage, geraet=None):
    r = rs.register_challenge(
        rs.ChallengeRequest(user_id=user["user_id"], device_id=geraet), anfrage)
    return base64.b64decode(r["nonce"])


def test_ein_stoerer_aus_einem_anderen_netz_verdraengt_das_nonce_nicht(relay):
    rs = relay
    opfer = make_user()
    beim_opfer = _Kopf(x_forwarded_for="198.51.100.20")
    nonce = _challenge(rs, opfer, beim_opfer)
    # Dreimal so viele Challenges, wie es Plaetze gibt — von woanders.
    for _ in range(3 * rs.NONCE_PLAETZE):
        rs.issue_nonce(opfer["user_id"], None, "203.0.113.7")
    assert _registriere_mit(rs, opfer, nonce, anfrage=beim_opfer)["ok"] is True


def test_derselbe_angriff_ueber_einen_anderen_tor_circuit(relay):
    rs = relay
    opfer = make_user()
    kreis_a = _Kopf(x_bitdm_onion="1", x_forwarded_for="127.0.0.1",
                    x_bitdm_kreis="fc00:dead:beef:4dad::1:2a")
    kreis_b = _Kopf(x_bitdm_onion="1", x_forwarded_for="127.0.0.1",
                    x_bitdm_kreis="fc00:dead:beef:4dad::1:2b")
    nonce = _challenge(rs, opfer, kreis_a)
    for _ in range(3 * rs.NONCE_PLAETZE):
        _challenge(rs, opfer, kreis_b)
    assert _registriere_mit(rs, opfer, nonce, anfrage=kreis_a)["ok"] is True


def test_aus_derselben_herkunft_bleibt_es_bei_acht_plaetzen(relay):
    """Die Gegenprobe: innerhalb EINER Herkunft gilt die alte Regel weiter."""
    rs = relay
    henrik = make_user()
    hier = _Kopf(x_forwarded_for="198.51.100.20")
    erstes = _challenge(rs, henrik, hier)
    for _ in range(rs.NONCE_PLAETZE):
        _challenge(rs, henrik, hier)
    with pytest.raises(rs.HTTPException) as fehler:
        _registriere_mit(rs, henrik, erstes, anfrage=hier)
    assert fehler.value.status_code == 403


def test_ein_netzwechsel_zwischen_challenge_und_register_schadet_nicht(relay):
    """WLAN -> Mobilfunk, IPv4 -> IPv6: das eigene Nonce liegt dann unter der
    alten Herkunft und muss trotzdem zaehlen."""
    rs = relay
    henrik = make_user()
    nonce = _challenge(rs, henrik, _Kopf(x_forwarded_for="198.51.100.20"))
    neu = _Kopf(x_forwarded_for="2001:db8:5:6::1")
    assert _registriere_mit(rs, henrik, nonce, anfrage=neu)["ok"] is True


def test_das_paar_hat_trotzdem_ein_dach(relay):
    rs = relay
    henrik = make_user()
    erstes = rs.issue_nonce(henrik["user_id"], None, "netz-0")
    for i in range(rs.NONCE_HERKUENFTE * rs.NONCE_PLAETZE):
        rs.issue_nonce(henrik["user_id"], None, f"netz-{i % rs.NONCE_HERKUENFTE + 1}")
    offen = rs.offene_nonces(henrik["user_id"])
    assert len(offen) == rs.NONCE_HERKUENFTE * rs.NONCE_PLAETZE
    assert erstes not in offen, "ueber dem Dach faellt das aelteste des Paares"
    assert rs._nonce_zahl == len(offen)


def test_die_eigene_herkunft_wird_zuerst_geprueft(relay):
    rs = relay
    henrik = make_user()
    fremd = [rs.issue_nonce(henrik["user_id"], None, "anderswo") for _ in range(3)]
    eigen = rs.issue_nonce(henrik["user_id"], None, "hier")
    assert rs.offene_nonces(henrik["user_id"], None, "hier") == [eigen, *fremd]


# ------------------------------------------------ 6  Herkunft, Onion, Vorraum

def test_ipv6_zaehlt_je_64er_netz(relay):
    rs = relay
    a = rs.limit_schluessel(_Kopf(x_forwarded_for="2001:db8:1:2:aaaa::1"))
    b = rs.limit_schluessel(_Kopf(x_forwarded_for="2001:db8:1:2:bbbb:cccc:dddd:eeee"))
    c = rs.limit_schluessel(_Kopf(x_forwarded_for="2001:db8:1:3::1"))
    assert a == b == "2001:db8:1:2::/64"
    assert c != a
    assert rs.limit_schluessel(_Kopf(x_forwarded_for="203.0.113.7")) == "203.0.113.7"
    assert rs.limit_schluessel(_Kopf(x_forwarded_for="::ffff:203.0.113.7")) == "203.0.113.7"


def test_onion_nur_von_der_schleife(relay):
    rs = relay
    ueber_tor = _Kopf(x_bitdm_onion="1", x_forwarded_for="127.0.0.1")
    gefaelscht = _Kopf(x_bitdm_onion="1", x_forwarded_for="203.0.113.7")
    assert rs.kommt_ueber_onion(ueber_tor)
    assert rs.limit_schluessel(ueber_tor) is None
    assert not rs.kommt_ueber_onion(gefaelscht)
    assert rs.limit_schluessel(gefaelscht) == "203.0.113.7"


def test_der_tor_circuit_wird_zur_herkunft(relay):
    rs = relay
    ueber_tor = dict(x_bitdm_onion="1", x_forwarded_for="127.0.0.1")
    assert rs.limit_schluessel(
        _Kopf(**ueber_tor, x_bitdm_kreis="fc00:dead:beef:4dad::ffff:ffff")) == "kreis:4294967295"
    assert rs.limit_schluessel(
        _Kopf(**ueber_tor, x_bitdm_kreis="fc00:dead:beef:4dad::2a")) == "kreis:42"
    # Alles, was tor so nicht schreibt, zaehlt nicht als Circuit.
    for falsch in ["", "2001:db8::2a", "fc00:dead:beef:4dae::2a", "127.0.0.1", "kreis:42"]:
        assert rs.limit_schluessel(_Kopf(**ueber_tor, x_bitdm_kreis=falsch)) is None, falsch
    # Und von aussen hilft die Kopfzeile nichts: dort zaehlt die echte IP.
    gefaelscht = _Kopf(x_bitdm_onion="1", x_forwarded_for="203.0.113.7",
                       x_bitdm_kreis="fc00:dead:beef:4dad::2a")
    assert rs.limit_schluessel(gefaelscht) == "203.0.113.7"
    assert rs.nonce_herkunft(_Kopf(**ueber_tor)) == "onion"


def test_ein_tor_circuit_bremst_nur_sich_selbst(relay, monkeypatch):
    rs = relay
    monkeypatch.setattr(rs, "RATE_CAPACITY", 1)
    monkeypatch.setattr(rs, "RATE_REFILL_PER_SEC", 0.0)
    kreis = lambda n: _Kopf(x_bitdm_onion="1", x_forwarded_for="127.0.0.1",
                            x_bitdm_kreis=f"fc00:dead:beef:4dad::{n:x}")
    rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))), kreis(1))
    with pytest.raises(rs.HTTPException) as fehler:
        rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))), kreis(1))
    assert fehler.value.status_code == 429
    rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))), kreis(2))


def test_tor_nutzer_teilen_sich_keine_ip_bremse(relay, monkeypatch):
    """Ueber Tor kommen alle von 127.0.0.1. Eine Bremse je IP war dort eine
    einzige Bremse fuer ALLE Tor-Nutzer."""
    rs = relay
    monkeypatch.setattr(rs, "RATE_CAPACITY", 1)
    monkeypatch.setattr(rs, "RATE_REFILL_PER_SEC", 0.0)
    ueber_tor = _Kopf(x_bitdm_onion="1", x_forwarded_for="127.0.0.1")
    for _ in range(3):
        rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))),
                              ueber_tor)
    oeffentlich = _Kopf(x_forwarded_for="203.0.113.7")
    rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))),
                          oeffentlich)
    with pytest.raises(rs.HTTPException) as fehler:
        rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))),
                              oeffentlich)
    assert fehler.value.status_code == 429


def test_der_vorraum_ist_gedeckelt(relay, monkeypatch):
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.setattr(rs, "WS_VORRAUM_MAX", 0)
    sock = _StummerSocket(henrik["user_id"], henrik["priv"])
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.geschlossen == 1013
    assert sock.gesendet == [], "am Deckel gibt es nicht einmal eine Challenge"


def test_der_vorraum_zaehlt_wieder_runter(relay):
    rs = relay
    henrik, mallory = make_user(), make_user()
    _lege_an(rs, henrik)
    _sitzung(rs, henrik)
    asyncio.run(rs.ws_endpoint(_StummerSocket(henrik["user_id"], mallory["priv"])))
    asyncio.run(rs.ws_endpoint(_StummerSocket(encode_id(os.urandom(32)), mallory["priv"])))
    assert rs._ws_im_vorraum == 0
    assert rs.WS_ANMELDEFRIST <= 10


def test_die_deploy_dateien_tragen_die_onion_riegel():
    """Die Haelfte der Behebung steht in nginx und tor. Ein Textscan, mit allen
    Grenzen eines Textscans — aber er faellt auf, wenn jemand die Zeilen
    beim naechsten Umbau verliert."""
    deploy = Path(__file__).resolve().parent.parent / "deploy"
    onion = (deploy / "onion" / "relay-onion.nginx").read_text(encoding="utf-8")
    torrc = (deploy / "onion" / "torrc.snippet").read_text(encoding="utf-8")
    install = (deploy / "install-relay.sh").read_text(encoding="utf-8")
    assert re.search(r'proxy_set_header\s+X-BitDM-Onion\s+"1"', onion)
    assert "limit_conn " in onion and "limit_req " in onion
    assert "HiddenServiceMaxStreams 20" in torrc
    assert "HiddenServiceMaxStreamsCloseCircuit 1" in torrc
    # Der oeffentliche vHost muss die Kopfzeile LEEREN — im Schnipsel und in
    # der /ws-location, die den Schnipsel nicht einbindet.
    assert len(re.findall(r'proxy_set_header\s+X-BitDM-Onion\s+""', install)) >= 2
    assert "$bitdm_limit_key" in install
    # DIE CIRCUIT-KENNUNG (seit 14.10.2026) gibt es nur als Paar: tor schreibt
    # sie, nginx muss sie an BEIDEN listen-Zeilen erwarten. Eines ohne das
    # andere legt den Onion-Dienst lahm.
    assert "HiddenServiceExportCircuitID haproxy" in torrc
    listen = re.findall(r"^\s*listen\s+127\.0\.0\.1:847[01][^;]*;", onion, re.M)
    assert len(listen) == 2 and all("proxy_protocol" in z for z in listen), listen
    assert len(re.findall(r"proxy_set_header\s+X-BitDM-Kreis\s+\$proxy_protocol_addr", onion)) >= 2
    assert "zone=bitdm_onion_kreis" in onion
    assert len(re.findall(r'proxy_set_header\s+X-BitDM-Kreis\s+""', install)) >= 2
    assert 'Strict-Transport-Security' in install


# ------------------------------------------------ 7/12  Zwischenlager-Marken

def test_marken_gelten_nur_fuer_stuecke(relay, monkeypatch):
    rs = relay
    if os.getenv("BITDM_BLOB_MAX") is None:
        assert rs.BLOB_MAX_BYTES == 33 * 1024**2
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    alice = make_user()
    _lege_an(rs, alice)
    raus = _sitzung(rs, alice, [
        {"type": "blob_marke", "kennung": "a" * 52, "groesse": rs.BLOB_MAX_BYTES + 1},
        {"type": "blob_marke", "kennung": "b" * 52 + "\n", "groesse": 10},
    ])
    fehler = [m["reason"] for m in raus if m.get("type") == "error"]
    assert fehler == ["Groesse ungueltig", "Kennung ungueltig"]


# test_die_tagesmenge_des_ganzen_relays stand hier bis zum 23.10.2026. Sie
# hielt fest, dass Marken ANDERER Adressen eine Adresse aussperren - genau das
# ist SV-2 aus dem Audit vom 16.10.2026. Die Gegenprobe steht jetzt unten bei
# test_sv2_marken_anderer_adressen_sperren_niemanden_aus, die Menge des ganzen
# Relays in test_blob.py (das Lager zaehlt sie).


def test_eine_winzige_marke_kostet_die_mindestmenge(relay, monkeypatch):
    """B4 der Pruefung vom 14.10.2026: gezaehlt wurden nur Bytes, also gab es
    fuer 1-Byte-Marken praktisch kein Dach — je eine Zeile und je eine Datei."""
    rs = relay
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    monkeypatch.setattr(rs, "BLOB_MINDESTMENGE", 1024**2)
    monkeypatch.setattr(rs, "BLOB_TAGESMENGE", 3 * 1024**2)
    alice = make_user()
    _lege_an(rs, alice)
    raus = _sitzung(rs, alice, [
        {"type": "blob_marke", "kennung": c * 52, "groesse": 10} for c in "abcd"
    ])
    ok = [m for m in raus if m.get("type") == "blob_marke_ok"]
    assert [m["kennung"][0] for m in ok] == ["a", "b", "c"]
    assert all(m["groesse"] == 10 for m in ok), "die Marke gilt fuer die echte Groesse"
    assert [m.get("reason") for m in raus if m.get("type") == "error"] == ["Tagesmenge erschoepft"]
    summe = rs.db.execute("SELECT SUM(groesse) FROM blob_marken WHERE user_id=?",
                          (alice["user_id"],)).fetchone()[0]
    assert summe == 3 * 1024**2


# ------------------------------------------------ 9  Strenges base64

def test_muell_im_base64_geht_nicht_an_den_empfaenger(relay):
    """proof_ws.py P5: 200 000 Zeichen Muell plus vier echte gingen an der
    Groessengrenze vorbei und wurden ROH weitergereicht."""
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    horcher = _Zuhoerer()
    _verbinde(rs, bob, horcher, nachweis=False)
    muell = "!" * 200_000 + b64(b"tiny")
    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": muell, "id": "m1"},
        {"type": "message", "to": bob["user_id"], "ciphertext": muell,
         "fluechtig": True, "id": "m2"},
    ])
    assert [m["id"] for m in raus if m.get("reason") == "ciphertext ungueltig"] == ["m1", "m2"]
    assert horcher.empfangen == []


def test_weitergereicht_wird_die_neu_kodierte_form(relay):
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    horcher = _Zuhoerer()
    _verbinde(rs, bob, horcher, nachweis=True)
    inhalt = os.urandom(300)
    _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(inhalt)},
    ])
    assert [m["ciphertext"] for m in horcher.empfangen] == [b64(inhalt)]


# ------------------------------------------------ 10  Kaputte Rahmen

class _RohSocket(_StummerSocket):
    """Wie _StummerSocket, nur dass ein Eintrag in den Antworten, der eine
    Ausnahme ist, beim Lesen geworfen wird — so wirft Starlettes
    receive_json bei einem binaeren Rahmen (KeyError 'text'), bei tief
    verschachteltem JSON (RecursionError) und bei kaputtem JSON (ValueError).
    [anmeldung] ersetzt die Antwort auf die Challenge."""

    def __init__(self, *a, anmeldung=None, **kw):
        super().__init__(*a, **kw)
        self._anmeldung = anmeldung

    async def send_json(self, obj):
        await super().send_json(obj)
        if obj.get("type") == "challenge" and self._anmeldung is not None:
            self._antworten[0] = self._anmeldung

    async def receive_json(self):
        wert = await super().receive_json()
        if isinstance(wert, BaseException):
            raise wert
        return wert


@pytest.mark.parametrize("muell", [KeyError("text"), RecursionError(),
                                   ValueError("kein JSON"), [], 5, "text"])
def test_kaputte_anmeldung_endet_mit_4403_und_nicht_mit_traceback(relay, muell):
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    sock = _RohSocket(henrik["user_id"], henrik["priv"], anmeldung=muell)
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.geschlossen == 4403
    assert rs._ws_im_vorraum == 0


def test_kaputte_rahmen_nach_der_anmeldung_reissen_nichts_ab(relay):
    """proof_ws.py P3/P4: eine Liste warf AttributeError an data.get, eine
    Zahl als "to" AttributeError an .strip — beide rissen die Verbindung ab."""
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    sock = _RohSocket(alice["user_id"], alice["priv"], antworten=[
        KeyError("text"), RecursionError(), ValueError("kaputt"), [], 5, None,
        {"type": "message", "to": 123, "ciphertext": b64(b"x"), "id": "zahl"},
        {"type": "message", "to": bob["user_id"], "ciphertext": 7, "id": "ct"},
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x"), "id": "gut"},
    ])
    asyncio.run(rs.ws_endpoint(sock))
    gruende = {m.get("id"): m.get("reason") for m in sock.gesendet if m.get("type") == "error"}
    assert gruende == {"zahl": "Zieladresse ungueltig", "ct": "ciphertext ungueltig"}
    assert [m["id"] for m in sock.gesendet if m.get("type") == "ack"] == ["gut"]


# ------------------------------------------------ 15  Fremde Leitung reisst nicht mit

class _ToteLeitung:
    async def send_json(self, obj):
        raise RuntimeError("Leitung weg")


def test_tote_empfaengerleitung_mit_nachweis_kostet_den_absender_nichts(relay):
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    _verbinde(rs, bob, _ToteLeitung(), nachweis=True)
    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"a"), "id": "m1"},
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"b"), "id": "m2"},
    ])
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["m1", "m2"]
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 2


def test_tote_alte_empfaengerleitung_wird_gepuffert_statt_verloren(relay):
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    _verbinde(rs, bob, _ToteLeitung(), nachweis=False)
    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"a"), "id": "m1"},
    ])
    assert [m["id"] for m in raus if m.get("type") == "ack"] == ["m1"]
    assert rs.db.execute("SELECT ciphertext FROM queue").fetchall() == [(b"a",)]


def test_der_alte_live_weg_hat_eine_eigene_bremse(relay, monkeypatch):
    rs = relay
    monkeypatch.setattr(rs, "LIVE_CAPACITY", 2)
    monkeypatch.setattr(rs, "LIVE_REFILL_PER_SEC", 0.0)
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    horcher = _Zuhoerer()
    _verbinde(rs, bob, horcher, nachweis=False)
    raus = _sitzung(rs, alice, [
        {"type": "message", "to": bob["user_id"], "ciphertext": b64(b"x"), "id": f"m{i}"}
        for i in range(3)
    ])
    assert len(horcher.empfangen) == 2
    assert [m["id"] for m in raus if m.get("reason") == "zu viele Nachrichten"] == ["m2"]


# ------------------------------------------------ 16  Rahmenbudget

def test_das_rahmenbudget_gilt_fuer_jede_art(relay, monkeypatch):
    """Auch Rahmen, an denen keine andere Bremse haengt, kosten."""
    rs = relay
    monkeypatch.setattr(rs, "RAHMEN_BURST", 3)
    monkeypatch.setattr(rs, "RAHMEN_REFILL_PER_SEC", 0.0)
    alice = make_user()
    _lege_an(rs, alice, n_otk=30)
    sock = _StummerSocket(alice["user_id"], alice["priv"], antworten=[
        {"type": "empfangen", "ids": [1]}, {"type": "unbekannt"}, [],
        {"type": "geraeus", "to": "a" * 56, "ciphertext": "", "id": "g1"},
    ])
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.geschlossen == 4429
    assert not [m for m in sock.gesendet if m.get("id") == "g1"]
    assert rs.connections == {}


# ------------------------------------------------ Tarnverkehr sieht aus wie echt

def test_tarnverkehr_bekommt_ein_ack_wie_eine_echte_nachricht(relay):
    """Fehlte die Antwort auf "geraeus", zaehlte ein Beobachter der Leitung
    einfach die kleinen Rahmen zurueck und wusste, welche Rahmen echt waren."""
    rs = relay
    alice, bob = make_user(), make_user()
    _lege_an(rs, alice)
    _lege_an(rs, bob)
    tarn_an = "".join(chr(0x61 + os.urandom(1)[0] % 26) for _ in range(56))
    raus = _sitzung(rs, alice, [
        {"type": "geraeus", "id": "7-123", "to": tarn_an, "ciphertext": b64(os.urandom(400))},
        {"type": "message", "id": "7-124", "to": bob["user_id"], "ciphertext": b64(b"x")},
    ])
    acks = [m for m in raus if m.get("type") == "ack"]
    assert len(acks) == 2
    tarn, echt = acks
    # Dieselben Felder in derselben Reihenfolge, gleich lange Werte.
    assert list(tarn) == list(echt) == ["type", "to", "id"]
    assert len(json.dumps(tarn)) == len(json.dumps(echt))
    assert tarn == {"type": "ack", "to": tarn_an, "id": "7-123"}
    assert rs.db.execute("SELECT COUNT(*) FROM queue").fetchone()[0] == 1


def test_neueste_fassung_geht_im_auth_result_mit(relay, monkeypatch):
    """Seit 26.09.2026: der Relay nennt die neueste App-Fassung ("neueste").

    Die App zeigt daraufhin einen ruhigen Hinweis. Ohne gesetzten Wert fehlt
    das Feld ganz — aeltere Apps kennen es ohnehin nicht.
    """
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1)

    monkeypatch.setattr(rs, "NEUESTE_FASSUNG", "")
    ohne = _StummerSocket(henrik["user_id"], henrik["priv"], geraet=1)
    asyncio.run(rs.ws_endpoint(ohne))
    ergebnis = [m for m in ohne.gesendet if m.get("type") == "auth_result"]
    assert ergebnis and ergebnis[0]["ok"] is True
    assert "neueste" not in ergebnis[0]

    monkeypatch.setattr(rs, "NEUESTE_FASSUNG", "1.9.0")
    mit = _StummerSocket(henrik["user_id"], henrik["priv"], geraet=1)
    asyncio.run(rs.ws_endpoint(mit))
    ergebnis = [m for m in mit.gesendet if m.get("type") == "auth_result"]
    assert ergebnis[0]["neueste"] == "1.9.0"


# --------------------------------------------------------------------------- #
#  Kyber-Prekeys  (PQXDH, 16.10.2026 — LIBSIGNAL-UMSTIEG.md, MEHRGERAETE.md §15)
# --------------------------------------------------------------------------- #
#
# Die offizielle libsignal baut ein Buendel nur MIT signiertem Kyber-Prekey.
# Der Relay prueft davon Laenge, Typbyte und Signatur — echte
# ML-KEM-Schluessel braucht es dafuer nicht. Die Tests nehmen deshalb 0x08 und
# 1568 Zufallsbytes und signieren die vollen 1569 Byte mit sign() von oben,
# genau wie libsignal den serialisierten Schluessel signiert.


def _kyber_schluessel() -> bytes:
    return bytes([0x08]) + os.urandom(1568)


def _kyber_einmal(priv, kennung, schluessel=None, signiert=None):
    """Ein Kyber-Einmalschluessel im Rumpfformat.

    [signiert] erlaubt es, absichtlich andere Bytes zu unterschreiben als die
    geschickten — etwa die 1568 Byte OHNE Typbyte.
    """
    schluessel = _kyber_schluessel() if schluessel is None else schluessel
    unterschrieben = schluessel if signiert is None else signiert
    return {"key_id": kennung, "public_key": b64(schluessel),
            "signature": b64(sign(priv, unterschrieben))}


def _kyber(user, n=3, kennung=900_000, erste=1):
    """Der ganze Kyber-Teil eines Buendels: Last-Resort plus n Einmalschluessel.

    Als dict, das _melde_an / _bundle_mit direkt ins Buendel legen.
    """
    priv = user["priv"]
    letzter = _kyber_schluessel()
    return {
        "kyber_prekey_id": kennung,
        "kyber_prekey": b64(letzter),
        "kyber_prekey_sig": b64(sign(priv, letzter)),
        "one_time_kyber_prekeys": [_kyber_einmal(priv, erste + i) for i in range(n)],
    }


def _kyber_je_geraet(rs, user_id):
    """{Geraet: [key_id, ...]} des Kyber-Einmalvorrats, sortiert."""
    stand: dict = {}
    for geraet, kid in rs.db.execute(
            "SELECT device_id, key_id FROM one_time_kyber_prekeys WHERE user_id=?"
            " ORDER BY device_id, key_id", (user_id,)):
        stand.setdefault(geraet, []).append(kid)
    return stand


def _kyber_stand(rs, user_id):
    """Alles, was der Relay zu dieser Adresse an Kyber haelt, Byte fuer Byte."""
    return (
        rs.db.execute(
            "SELECT device_id, kyber_prekey_id, kyber_prekey, kyber_prekey_sig"
            " FROM identities WHERE user_id=? ORDER BY device_id",
            (user_id,)).fetchall(),
        rs.db.execute(
            "SELECT device_id, key_id, public_key, signature"
            " FROM one_time_kyber_prekeys WHERE user_id=?"
            " ORDER BY device_id, key_id", (user_id,)).fetchall(),
    )


# ------------------------------------------------ Die signierten Bytes

# DAS SOLL FUER BEIDE SEITEN. Derselbe String steht im Dart-Test der App
# (relay_protocol_test.dart); weicht eine Seite ab, scheitert jede Anmeldung
# mit "Besitznachweis fehlgeschlagen", einer Meldung, die auf alles deutet,
# nur nicht auf die Reihenfolge von JSON-Schluesseln. Bewusst als
# ausgeschriebener String und nicht aus canonical_bytes() abgeleitet — ein
# Soll, das der Code selbst ausrechnet, waere immer erfuellt.
KYBER_KANONISCH_MIT_GERAET = (
    '{"device_id":2,"identity_key":"SWRLZXk=","kyber_prekey":"Kk==",'
    '"kyber_prekey_id":7,"kyber_prekey_sig":"S3NpZw==",'
    '"one_time_kyber_prekeys":[[1,"Ef==","Gh=="],[2,"Ab==","Cd=="]],'
    '"one_time_prekeys":[[5,"T1RL"]],"registration_id":1234,'
    '"signed_prekey":"U1BL","signed_prekey_id":1,"signed_prekey_sig":"U2ln",'
    '"user_id":"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"}')

KYBER_KANONISCH_LEERER_VORRAT = (
    '{"identity_key":"SWRLZXk=","kyber_prekey":"Kk==","kyber_prekey_id":0,'
    '"kyber_prekey_sig":"S3NpZw==","one_time_kyber_prekeys":[],'
    '"one_time_prekeys":[],"registration_id":1234,"signed_prekey":"U1BL",'
    '"signed_prekey_id":1,"signed_prekey_sig":"U2ln",'
    '"user_id":"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"}')

# Dasselbe Buendel wie oben, nur ohne Kyber — so sahen die Bytes vor dem
# 16.10.2026 aus, und so muessen sie fuer eine App ohne Kyber bleiben.
KANONISCH_OHNE_KYBER = (
    '{"device_id":2,"identity_key":"SWRLZXk=","one_time_prekeys":[[5,"T1RL"]],'
    '"registration_id":1234,"signed_prekey":"U1BL","signed_prekey_id":1,'
    '"signed_prekey_sig":"U2ln",'
    '"user_id":"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"}')


def test_die_kanonischen_bytes_mit_kyber_stehen_fest():
    """Die Regel (MEHRGERAETE.md §15.2), an festen Werten.

    NUR WENN kyber_prekey gesetzt ist, kommen vier Schluessel dazu; der
    Einmalvorrat als [key_id, public_key, signature], aufsteigend nach key_id
    — hier VERKEHRT herum uebergeben, weil genau das eine App falsch machen
    wuerde, die in Eingabereihenfolge schreibt. Ein leerer Vorrat steht als
    [] da und fehlt nicht. Die Kennung 0 wird ausgeschrieben, sie ist ein
    gueltiger Wert und keine Vorgabe.
    """
    basis = dict(user_id="k" * 56, identity_key="SWRLZXk=", registration_id=1234,
                 signed_prekey_id=1, signed_prekey="U1BL", signed_prekey_sig="U2ln")

    mit = PreKeyBundle(
        **basis, device_id=2,
        one_time_prekeys=[{"key_id": 5, "public_key": "T1RL"}],
        kyber_prekey_id=7, kyber_prekey="Kk==", kyber_prekey_sig="S3NpZw==",
        one_time_kyber_prekeys=[
            {"key_id": 2, "public_key": "Ab==", "signature": "Cd=="},
            {"key_id": 1, "public_key": "Ef==", "signature": "Gh=="},
        ])
    assert mit.canonical_bytes().decode() == KYBER_KANONISCH_MIT_GERAET

    leer = PreKeyBundle(**basis, kyber_prekey_id=0, kyber_prekey="Kk==",
                        kyber_prekey_sig="S3NpZw==")
    assert leer.canonical_bytes().decode() == KYBER_KANONISCH_LEERER_VORRAT

    # Ohne kyber_prekey: Zeichen fuer Zeichen die alten Bytes. Sonst bekaeme
    # jede installierte App ab dem Aufspielen des Relays 403.
    ohne = PreKeyBundle(**basis, device_id=2,
                        one_time_prekeys=[{"key_id": 5, "public_key": "T1RL"}])
    assert ohne.canonical_bytes().decode() == KANONISCH_OHNE_KYBER


def test_die_kyber_felder_sind_mitsigniert(relay):
    """Ein Weiterleitender kann den Kyber-Teil nicht austauschen.

    Jeder einzelne Kyber-Schluessel ist zwar signiert — aber /prekey gibt
    signierte Schluessel desselben Opfers an jeden heraus. Ohne Bindung an die
    Anmeldung liessen sie sich einsetzen (alte, laengst verbrauchte), der
    Vorrat leeren oder der ganze Kyber-Teil streichen. Jede dieser Aenderungen
    muss am Besitznachweis scheitern.
    """
    rs = relay
    henrik = make_user()
    echt = _bundle_mit(henrik, **_kyber(henrik, n=2))
    nonce = rs.issue_nonce(henrik["user_id"])
    sig = b64(sign(henrik["priv"],
                   nonce + hashlib.sha256(echt.canonical_bytes()).digest()))

    roh = echt.model_dump()
    fremd_signiert = _kyber(henrik, n=1, kennung=5, erste=50)
    for aenderung in (
        # gueltig signierte Einmalschluessel desselben Geraets, nur andere
        {"one_time_kyber_prekeys": fremd_signiert["one_time_kyber_prekeys"]},
        {"one_time_kyber_prekeys": []},
        # ein anderer, ebenfalls gueltig signierter Last-Resort-Schluessel
        {k: fremd_signiert[k] for k in
         ("kyber_prekey_id", "kyber_prekey", "kyber_prekey_sig")},
        # der ganze Kyber-Teil gestrichen
        {"kyber_prekey_id": None, "kyber_prekey": None, "kyber_prekey_sig": None,
         "one_time_kyber_prekeys": []},
    ):
        gefaelscht = rs.PreKeyBundle(**{**roh, **aenderung})
        with pytest.raises(rs.HTTPException) as fehler:
            rs.register(rs.RegisterRequest(bundle=gefaelscht, signature=sig),
                        _Anfrage())
        assert fehler.value.status_code == 403, aenderung.keys()

    # Die Gegenprobe: das echte Buendel geht mit derselben Signatur durch.
    # Die Fehlversuche haben das Nonce nicht verbraucht (verbrauche_nonce
    # laeuft erst nach einer gueltigen Signatur).
    r = rs.register(rs.RegisterRequest(bundle=echt, signature=sig), _Anfrage())
    assert r == {"ok": True, "one_time_prekeys": 5, "one_time_kyber_prekeys": 2}


# ------------------------------------------------ Anmeldung

def test_eine_volle_anmeldung_mit_kyber_wird_gespeichert(relay):
    """Der Normalfall der neuen App, mit dem vollen Einmalvorrat.

    KYBER_OTK_MAX_JE_BUENDEL Einmalschluessel und der Last-Resort-Schluessel:
    51 Signaturen, alle geprueft, alle gespeichert, Byte fuer Byte.
    """
    rs = relay
    henrik = make_user(n_otk=3)
    teil = _kyber(henrik, n=rs.KYBER_OTK_MAX_JE_BUENDEL, kennung=77)

    r = _melde_an(rs, henrik, **teil)

    assert r == {"ok": True, "one_time_prekeys": 3,
                 "one_time_kyber_prekeys": rs.KYBER_OTK_MAX_JE_BUENDEL}
    letzter, einmal = _kyber_stand(rs, henrik["user_id"])
    assert letzter == [(1, 77, base64.b64decode(teil["kyber_prekey"]),
                        base64.b64decode(teil["kyber_prekey_sig"]))]
    assert einmal == sorted(
        (1, k["key_id"], base64.b64decode(k["public_key"]),
         base64.b64decode(k["signature"]))
        for k in teil["one_time_kyber_prekeys"])
    assert rs._kyber_zeilen == rs.KYBER_OTK_MAX_JE_BUENDEL


def _setze_letzten(user, teil, schluessel):
    """Einen anderen Last-Resort-Schluessel einsetzen, korrekt signiert."""
    teil["kyber_prekey"] = b64(schluessel)
    teil["kyber_prekey_sig"] = b64(sign(user["priv"], schluessel))


def _einmal_ohne_typbyte_signiert(priv, kennung):
    schluessel = _kyber_schluessel()
    return _kyber_einmal(priv, kennung, schluessel, signiert=schluessel[1:])


def _letzter_ohne_typbyte_signiert(user, teil):
    schluessel = base64.b64decode(teil["kyber_prekey"])
    teil["kyber_prekey_sig"] = b64(sign(user["priv"], schluessel[1:]))


# Jeder Fall bekommt (Nutzer, Kyber-Teil) und verdirbt den Teil an genau
# einer Stelle. Die Signaturen der FORM-Faelle (Laenge, Typbyte) sind gueltig
# — abgewiesen werden muss also wirklich die Form, nicht die Signatur.
KAPUTTE_KYBER = {
    "Last-Resort 1568 Byte samt Typbyte":
        lambda u, t: _setze_letzten(u, t, b"\x08" + os.urandom(1567)),
    "Last-Resort 1570 Byte":
        lambda u, t: _setze_letzten(u, t, b"\x08" + os.urandom(1569)),
    "Last-Resort mit Typbyte 0x05":
        lambda u, t: _setze_letzten(u, t, b"\x05" + os.urandom(1568)),
    "Last-Resort nackt, 1568 Byte ohne Typbyte":
        lambda u, t: _setze_letzten(u, t, os.urandom(1568)),
    "Last-Resort-Signatur 63 Byte":
        lambda u, t: t.update(kyber_prekey_sig=b64(os.urandom(63))),
    "Last-Resort-Signatur eines fremden Schluessels":
        lambda u, t: t.update(kyber_prekey_sig=b64(
            sign(os.urandom(32), base64.b64decode(t["kyber_prekey"])))),
    "Last-Resort-Signatur ueber die Bytes ohne Typbyte":
        _letzter_ohne_typbyte_signiert,
    "Einmal 1568 Byte samt Typbyte":
        lambda u, t: t["one_time_kyber_prekeys"].append(
            _kyber_einmal(u["priv"], 99, b"\x08" + os.urandom(1567))),
    "Einmal mit Typbyte 0x05":
        lambda u, t: t["one_time_kyber_prekeys"].append(
            _kyber_einmal(u["priv"], 99, b"\x05" + os.urandom(1568))),
    "Einmal-Signatur 65 Byte":
        lambda u, t: t["one_time_kyber_prekeys"].append(
            {**_kyber_einmal(u["priv"], 99), "signature": b64(os.urandom(65))}),
    "Einmal-Signatur eines fremden Schluessels":
        lambda u, t: t["one_time_kyber_prekeys"].append(
            _kyber_einmal(os.urandom(32), 99)),
    "Einmal-Signatur ueber die Bytes ohne Typbyte":
        lambda u, t: t["one_time_kyber_prekeys"].append(
            _einmal_ohne_typbyte_signiert(u["priv"], 99)),
    "kyber_prekey ohne Signatur":
        lambda u, t: t.pop("kyber_prekey_sig"),
    "kyber_prekey ohne Kennung":
        lambda u, t: t.pop("kyber_prekey_id"),
    "Einmalschluessel ohne Last-Resort":
        lambda u, t: [t.pop(k) for k in
                      ("kyber_prekey_id", "kyber_prekey", "kyber_prekey_sig")],
    "key_id doppelt":
        lambda u, t: t["one_time_kyber_prekeys"].append(_kyber_einmal(
            u["priv"], t["one_time_kyber_prekeys"][0]["key_id"])),
    "Last-Resort-Kennung auch unter den Einmalschluesseln":
        lambda u, t: t["one_time_kyber_prekeys"].append(
            _kyber_einmal(u["priv"], t["kyber_prekey_id"])),
    "kaputtes base64":
        lambda u, t: t.update(kyber_prekey="!!!kein base64!!!"),
}


@pytest.mark.parametrize("fall", list(KAPUTTE_KYBER))
def test_kaputte_kyber_felder_werden_abgewiesen(relay, fall):
    """400 — IMMER, auch ohne BITDM_KYBER_PFLICHT (die Vorrichtung loescht sie).

    "Optional" heisst "darf fehlen", nicht "darf kaputt sein". Und eine
    abgewiesene Erneuerung darf vom gespeicherten Satz nichts anfassen:
    sonst stuende das Geraet nach einem einzigen kaputten Versuch ohne Kyber
    oder mit halbem Vorrat da.

    Die Signatur UEBER DIE BYTES OHNE TYPBYTE ist der Fehler, den eine App am
    ehesten macht (die 1568 Schluesselbytes sind "der Schluessel"). libsignal
    prueft gegen die serialisierte Form und wirft beim Absender
    `invalidSignature` — der Relay soll so einen Schluessel gar nicht erst
    ausgeben.
    """
    rs = relay
    henrik = make_user()
    _melde_an(rs, henrik, **_kyber(henrik, n=2, kennung=5, erste=100))
    vorher = _kyber_stand(rs, henrik["user_id"])

    teil = _kyber(henrik)
    KAPUTTE_KYBER[fall](henrik, teil)
    with pytest.raises(rs.HTTPException) as fehler:
        _melde_an(rs, henrik, **teil)

    assert fehler.value.status_code == 400, fehler.value.detail
    # Jeder Fall muss in der PRUEFUNG auffallen und nicht erst als
    # IntegrityError an der Datenbank — dort kaeme er erst nach bis zu 51
    # Signaturpruefungen an, und die Meldung sagte dem Client nichts.
    assert fehler.value.detail != "Bundle konnte nicht gespeichert werden"
    assert _kyber_stand(rs, henrik["user_id"]) == vorher, \
        "eine abgewiesene Anmeldung hat den gespeicherten Kyber-Satz veraendert"
    assert rs._kyber_zeilen == 2


def test_eine_anmeldung_ohne_kyber_raeumt_den_alten_satz_weg(relay):
    """Meldet sich ein Geraet ohne Kyber an (alte App, etwa zurueckgespielt),
    passen die gespeicherten Kyber-Schluessel nicht mehr zu dem, was dort
    laeuft. Stehen gelassen, baute jede neue App damit eine Sitzung, die das
    Geraet nicht entschluesseln kann."""
    rs = relay
    henrik = make_user(n_otk=2)
    _melde_an(rs, henrik, **_kyber(henrik, n=4))
    assert rs._kyber_zeilen == 4

    r = _melde_an(rs, henrik)

    assert r == {"ok": True, "one_time_prekeys": 2}, \
        "ohne Kyber muss die Antwort die alte bleiben"
    assert _kyber_stand(rs, henrik["user_id"]) == ([(1, None, None, None)], [])
    assert rs._kyber_zeilen == 0
    antwort = rs.get_prekey(henrik["user_id"], _Anfrage())
    assert not [k for k in antwort if k.startswith("kyber")]


def test_zu_viele_kyber_einmalschluessel_und_falsche_kennungen_scheitern_am_modell():
    """Der Deckel und der Wertebereich wirken VOR jeder Dekodierung (422).

    Die Kennungen sind vereinbart als 0 <= id <= 2^31-1, und zwar als echtes
    int: `true` waere in lax mode die 1, "7" die 7.
    """
    import pydantic
    import relay_server as rs_mod

    basis = dict(user_id="x" * 56, identity_key=b64(os.urandom(32)),
                 registration_id=1, signed_prekey_id=1,
                 signed_prekey=b64(os.urandom(33)),
                 signed_prekey_sig=b64(os.urandom(64)),
                 kyber_prekey_id=1, kyber_prekey="Kk==",
                 kyber_prekey_sig="S3NpZw==")
    einmal = [{"key_id": i, "public_key": "Kk==", "signature": "Cd=="}
              for i in range(rs_mod.KYBER_OTK_MAX_JE_BUENDEL + 1)]
    with pytest.raises(pydantic.ValidationError):
        PreKeyBundle(**basis, one_time_kyber_prekeys=einmal)
    # Gegenprobe: genau die Grenze geht noch durch.
    PreKeyBundle(**basis, one_time_kyber_prekeys=einmal[:-1])

    for falsch in (-1, 2**31, True, "7", 1.0):
        with pytest.raises(pydantic.ValidationError):
            PreKeyBundle(**{**basis, "kyber_prekey_id": falsch})
        with pytest.raises(pydantic.ValidationError):
            PreKeyBundle(**basis, one_time_kyber_prekeys=[
                {"key_id": falsch, "public_key": "Kk==", "signature": "Cd=="}])
    for richtig in (0, 2**31 - 1):
        PreKeyBundle(**{**basis, "kyber_prekey_id": richtig})


def test_ein_volles_buendel_passt_durch_nginx():
    """Der Deckel muss unter dem liegen, was nginx durchlaesst — sonst zieht
    nginx die Grenze, mit 413 und ohne Text, den die App zeigen koennte.

    Schlechtester Fall: OTK_MAX_JE_BUENDEL EC- und KYBER_OTK_MAX_JE_BUENDEL
    Kyber-Einmalschluessel, alle Kennungen zehnstellig, ohne Leerzeichen wie
    Darts jsonEncode. Gelesen wird die Grenze aus BEIDEN vHosts, nicht
    abgeschrieben — wer sie dort senkt, sieht es hier.
    """
    import relay_server as rs_mod
    deploy = Path(__file__).resolve().parent.parent / "deploy"
    grenzen = []
    for datei in (deploy / "install-relay.sh", deploy / "onion" / "relay-onion.nginx"):
        text = datei.read_text(encoding="utf-8")
        grenzen += [int(k) * 1024 for k in
                    re.findall(r"client_max_body_size\s+(\d+)k;", text)]
    assert grenzen, "client_max_body_size nicht gefunden"

    gross = 2**31 - 1
    ec = b64(b"\x05" + os.urandom(32))
    kyber = b64(_kyber_schluessel())
    sig = b64(os.urandom(64))
    bundle = {
        "user_id": "a" * 56, "identity_key": b64(os.urandom(32)),
        "device_id": gross, "registration_id": gross,
        "signed_prekey_id": gross, "signed_prekey": ec, "signed_prekey_sig": sig,
        "one_time_prekeys": [{"key_id": gross - i, "public_key": ec}
                             for i in range(rs_mod.OTK_MAX_JE_BUENDEL)],
        "kyber_prekey_id": gross, "kyber_prekey": kyber, "kyber_prekey_sig": sig,
        "one_time_kyber_prekeys": [
            {"key_id": gross - 1 - i, "public_key": kyber, "signature": sig}
            for i in range(rs_mod.KYBER_OTK_MAX_JE_BUENDEL)],
    }
    rumpf = json.dumps({"bundle": bundle, "signature": sig}, separators=(",", ":"))
    # Gemessen 130 849 Byte. Die Haelfte von 256 KiB (plus ein wenig) laesst
    # Luft fuer kuenftige Felder; wer den Deckel hebt, soll hier anhalten und
    # nachrechnen, statt bis kurz vor die nginx-Grenze zu gehen.
    assert len(rumpf) <= min(grenzen) // 2 + 4096, (len(rumpf), min(grenzen))


# ------------------------------------------------ /prekey

def test_ein_kyber_einmalschluessel_geht_genau_einmal_raus(relay):
    """Atomar entnommen wie der EC-Einmalschluessel, danach der Last-Resort.

    Und `nur_geraete` zieht auch hier nichts — der Aufruf kommt oft.
    """
    rs = relay
    henrik = make_user(n_otk=5)
    teil = _kyber(henrik, n=2, kennung=4242, erste=1)
    _melde_an(rs, henrik, **teil)

    rs.get_prekey(henrik["user_id"], _Anfrage(), nur_geraete=True)
    assert rs._kyber_zeilen == 2

    gesehen = []
    for _ in range(4):
        antwort = rs.get_prekey(henrik["user_id"], _Anfrage())
        geraet = antwort["geraete"][0]
        # Flach = geraete[0], derselbe Schluessel und kein zweiter gezogener.
        for feld in ("kyber_prekey_id", "kyber_prekey", "kyber_prekey_sig",
                     "kyber_einmal"):
            assert antwort[feld] == geraet[feld]
        gesehen.append((geraet["kyber_prekey_id"], geraet["kyber_prekey"],
                        geraet["kyber_prekey_sig"], geraet["kyber_einmal"]))

    einmal = {(k["key_id"], k["public_key"], k["signature"], True)
              for k in teil["one_time_kyber_prekeys"]}
    assert set(gesehen[:2]) == einmal, "jeder Einmalschluessel genau einmal"
    letzter = (4242, teil["kyber_prekey"], teil["kyber_prekey_sig"], False)
    assert gesehen[2] == gesehen[3] == letzter, \
        "danach der Last-Resort-Schluessel, so oft wie gefragt"
    assert _kyber_je_geraet(rs, henrik["user_id"]) == {}
    assert rs._kyber_zeilen == 0


def test_die_bremse_gibt_den_last_resort_und_laesst_den_vorrat_stehen(
        relay, monkeypatch):
    """otk_limit_ok gilt fuer beide Vorraete zusammen, ein Token je Anfrage.

    Greift die Bremse, kommt der Last-Resort-Schluessel — PQXDH laeuft
    weiter — und der Kyber-Vorrat bleibt unangetastet. Sonst waere die Bremse
    fuer den Kyber-Teil keine.
    """
    rs = relay
    monkeypatch.setattr(rs, "OTK_CAPACITY", 1)
    henrik = make_user(n_otk=3)
    _melde_an(rs, henrik, **_kyber(henrik, n=3, kennung=4242))

    erste = rs.get_prekey(henrik["user_id"], _Anfrage())
    zweite = rs.get_prekey(henrik["user_id"], _Anfrage())

    assert erste["kyber_einmal"] is True
    assert erste["one_time_prekey"] is not None
    assert zweite["kyber_einmal"] is False
    assert zweite["kyber_prekey_id"] == 4242
    assert zweite["one_time_prekey"] is None, \
        "die Bremse gilt fuer beide Vorraete, nicht nur fuer den EC-Vorrat"
    assert _kyber_je_geraet(rs, henrik["user_id"]) == {1: [2, 3]}, \
        "die Bremse hat trotzdem einen Kyber-Einmalschluessel verbraucht"
    assert rs._kyber_zeilen == 2


def test_jedes_geraet_hat_seinen_eigenen_kyber_satz(relay):
    """Mehrgeraete: Last-Resort und Vorrat haengen am GERAET, nicht an der
    Adresse — wie signed_prekey und der EC-Vorrat.

    Geraet 1 ist eine alte App ohne Kyber. Bei ihm fehlen die Felder ganz,
    und weil es geraete[0] ist, auch flach. Die Erneuerung eines Geraets
    ersetzt nur SEINEN Vorrat.
    """
    rs = relay
    henrik = make_user(n_otk=2)
    _melde_an(rs, henrik, geraet=1)
    zwei = _kyber(henrik, n=2, kennung=20, erste=200)
    drei = _kyber(henrik, n=2, kennung=30, erste=300)
    _melde_an(rs, henrik, geraet=2, **zwei)
    _melde_an(rs, henrik, geraet=3, **drei)

    antwort = rs.get_prekey(henrik["user_id"], _Anfrage())
    g1, g2, g3 = antwort["geraete"]

    assert not [k for k in g1 if k.startswith("kyber")]
    assert not [k for k in antwort if k.startswith("kyber")], \
        "flach = geraete[0], und das hat kein Kyber"
    for eintrag, satz in ((g2, zwei), (g3, drei)):
        assert eintrag["kyber_einmal"] is True
        eigene = {(k["key_id"], k["public_key"], k["signature"])
                  for k in satz["one_time_kyber_prekeys"]}
        assert (eintrag["kyber_prekey_id"], eintrag["kyber_prekey"],
                eintrag["kyber_prekey_sig"]) in eigene, \
            "ein Geraet hat einen Schluessel eines anderen ausgegeben"

    neu = _kyber(henrik, n=1, kennung=21, erste=210)
    assert _melde_an(rs, henrik, geraet=2, **neu)["one_time_kyber_prekeys"] == 1

    vorrat = _kyber_je_geraet(rs, henrik["user_id"])
    assert vorrat[2] == [210]
    assert len(vorrat[3]) == 1 and vorrat[3][0] in (300, 301), \
        "die Erneuerung von Geraet 2 hat den Vorrat von Geraet 3 angefasst"
    letzte = dict(rs.db.execute(
        "SELECT device_id, kyber_prekey_id FROM identities WHERE user_id=?",
        (henrik["user_id"],)).fetchall())
    assert letzte == {1: None, 2: 21, 3: 30}
    assert rs._kyber_zeilen == 2


def test_mit_kyber_ist_die_geraetekennung_hoechstens_127(relay):
    """Signals offizielle libsignal nimmt Geraetekennungen nur von 1 bis 127.

    Eine App ab 2.0.0 (erkennbar an Kyber) mit groesserer Kennung koennte
    niemand erreichen — keine Gegenstelle baut eine Sitzung zu ihr. Das soll
    beim Anmelden auffallen. Eine alte App OHNE Kyber darf ihre grosse
    Kennung bis zum Stichtag behalten.
    """
    rs = relay
    henrik = make_user()
    _melde_an(rs, henrik, geraet=1)
    assert _melde_an(rs, henrik, geraet=127,
                     **_kyber(henrik, n=1, kennung=40, erste=400))
    with pytest.raises(rs.HTTPException) as fehler:
        _melde_an(rs, henrik, geraet=128,
                  **_kyber(henrik, n=1, kennung=50, erste=500))
    assert fehler.value.status_code == 400, fehler.value.detail
    assert "127" in fehler.value.detail
    # Ohne Kyber (alte App) bleibt die grosse Kennung erlaubt.
    assert _melde_an(rs, henrik, geraet=2**31 - 1)


# ------------------------------------------------ Der Stichtag

def test_der_stichtag_lehnt_anmeldungen_ohne_kyber_ab(relay, monkeypatch):
    """BITDM_KYBER_PFLICHT=1: ohne Kyber 400, mit Kyber wie immer.

    Gesetzt wird die ECHTE Umgebungsvariable, nicht eine Modulkonstante —
    deshalb liest kyber_pflicht() sie bei jedem Aufruf. Und schon
    angemeldete alte Geraete bleiben abrufbar: der Stichtag sperrt das
    Anmelden, nicht das Erreichen.
    """
    rs = relay
    alt, neu, frueher = make_user(), make_user(), make_user()
    _melde_an(rs, frueher)

    monkeypatch.setenv("BITDM_KYBER_PFLICHT", "1")
    with pytest.raises(rs.HTTPException) as fehler:
        _melde_an(rs, alt)
    assert fehler.value.status_code == 400
    assert "Kyber" in fehler.value.detail
    assert _geraete(rs, alt["user_id"]) == []
    assert _melde_an(rs, neu, **_kyber(neu))["ok"] is True
    assert rs.get_prekey(frueher["user_id"], _Anfrage())["signed_prekey_id"] == 1

    # Nur genau "1" schaltet ein — im Zweifel bleibt der Uebergang offen.
    for wert in ("true", "ja", " 1", "1 ", "0", ""):
        monkeypatch.setenv("BITDM_KYBER_PFLICHT", wert)
        assert rs.kyber_pflicht() is False, repr(wert)

    monkeypatch.delenv("BITDM_KYBER_PFLICHT")
    assert _melde_an(rs, alt) == {"ok": True, "one_time_prekeys": 5}


# ------------------------------------------------ Datenbank

# Das Schema, wie es seit dem Mehrgeraete-Umbau (30.07.2026) bis vor Kyber
# LAEUFT — woertlich, aus derselben Ueberlegung wie ALTES_SCHEMA oben: eine
# Kopie von relay_server.SCHEMA wanderte mit und pruefte den Fall nicht mehr.
SCHEMA_VOR_KYBER = """
CREATE TABLE identities (
    user_id           TEXT NOT NULL,
    device_id         INTEGER NOT NULL DEFAULT 1,
    identity_key      BLOB NOT NULL,
    registration_id   INTEGER NOT NULL DEFAULT 0,
    signed_prekey_id  INTEGER NOT NULL,
    signed_prekey     BLOB NOT NULL,
    signed_prekey_sig BLOB NOT NULL,
    updated_at        REAL NOT NULL,
    push_endpoint     TEXT,
    last_seen         REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, device_id)
);
CREATE TABLE one_time_prekeys (
    user_id    TEXT NOT NULL,
    device_id  INTEGER NOT NULL DEFAULT 1,
    key_id     INTEGER NOT NULL,
    public_key BLOB NOT NULL,
    PRIMARY KEY (user_id, device_id, key_id),
    FOREIGN KEY (user_id, device_id)
        REFERENCES identities(user_id, device_id) ON DELETE CASCADE
);
CREATE TABLE queue (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    recipient        TEXT NOT NULL,
    recipient_device INTEGER NOT NULL DEFAULT 1,
    sender           TEXT NOT NULL,
    sender_device    INTEGER NOT NULL DEFAULT 1,
    ciphertext       BLOB NOT NULL,
    ts               REAL NOT NULL
);
CREATE INDEX idx_queue_ts ON queue(ts);
CREATE INDEX idx_queue_paar ON queue(recipient, recipient_device, sender);
CREATE INDEX idx_queue_absender ON queue(sender);
CREATE TABLE blob_marken (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    groesse INTEGER NOT NULL,
    ts      REAL NOT NULL
);
CREATE INDEX idx_blob_marken ON blob_marken(user_id, ts);
CREATE INDEX idx_blob_marken_ts ON blob_marken(ts);
"""


def _datenbank_vor_kyber(pfad, user, n_otk=4):
    alt = sqlite3.connect(pfad)
    alt.executescript(SCHEMA_VOR_KYBER)
    pub = base64.b64decode(user["bundle"]["identity_key"])
    jetzt = time.time()
    with alt:
        alt.execute(
            "INSERT INTO identities (user_id, device_id, identity_key,"
            " registration_id, signed_prekey_id, signed_prekey,"
            " signed_prekey_sig, updated_at, push_endpoint, last_seen)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (user["user_id"], 1, pub, 4711, 9, b"spk", b"sig", jetzt,
             "https://push.bitdm.net/upAlt", jetzt))
        alt.executemany(
            "INSERT INTO one_time_prekeys (user_id, device_id, key_id, public_key)"
            " VALUES (?,?,?,?)",
            [(user["user_id"], 1, i, bytes([i]) * 33) for i in range(n_otk)])
    alt.close()


def _kyber_fremdschluessel(conn):
    return {(r[2], r[3], r[4], r[6]) for r in
            conn.execute("PRAGMA foreign_key_list(one_time_kyber_prekeys)")}


def test_eine_datenbank_ohne_kyber_spalten_wird_erweitert(relay, tmp_path, monkeypatch):
    """Der Fall, der beim Aufspielen auf relay.bitdm.net eintritt.

    Die laufende Datenbank hat weder die drei Spalten noch die Tabelle. Nach
    dem Start hat sie beides, jede bestehende Registrierung steht
    unveraendert da (ohne Kyber), ein zweiter Start ruehrt nichts an — und
    auf der erweiterten Datenbank laeuft eine Anmeldung mit Kyber durch.
    """
    rs = relay
    pfad = tmp_path / "vor_kyber.db"
    henrik = make_user()
    _datenbank_vor_kyber(pfad, henrik)

    conn = rs.init_db(pfad)
    try:
        spalten = {r[1] for r in conn.execute("PRAGMA table_info(identities)")}
        assert {"kyber_prekey_id", "kyber_prekey", "kyber_prekey_sig"} <= spalten
        assert conn.execute(
            "SELECT device_id, registration_id, signed_prekey_id, signed_prekey,"
            " push_endpoint, kyber_prekey_id, kyber_prekey, kyber_prekey_sig"
            " FROM identities").fetchall() == [
                (1, 4711, 9, b"spk", "https://push.bitdm.net/upAlt",
                 None, None, None)], "die bestehende Registrierung hat sich veraendert"
        assert conn.execute(
            "SELECT COUNT(*) FROM one_time_prekeys").fetchone()[0] == 4
        assert _kyber_fremdschluessel(conn) == {
            ("identities", "user_id", "user_id", "CASCADE"),
            ("identities", "device_id", "device_id", "CASCADE")}
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []

        # Ein zweiter Start ist ein Nichts.
        conn.close()
        conn = rs.init_db(pfad)
        assert rs.ergaenze_kyber_spalten(conn) is False

        # Und die erweiterte Datenbank traegt den neuen Weg.
        monkeypatch.setattr(rs, "db", conn)
        assert rs.kyber_zeilen_neu_zaehlen() == 0
        vorher = rs.get_prekey(henrik["user_id"], _Anfrage())
        assert not [k for k in vorher if k.startswith("kyber")]
        assert _melde_an(rs, henrik, **_kyber(henrik, n=2, kennung=8))[
            "one_time_kyber_prekeys"] == 2
        nachher = rs.get_prekey(henrik["user_id"], _Anfrage())
        assert nachher["kyber_einmal"] is True
    finally:
        conn.close()


def test_kyber_kommt_auch_auf_die_aelteste_datenbank(tmp_path):
    """Eine Datenbank von VOR dem Mehrgeraete-Umbau, in einem Schritt hoch.

    Die Falle: SCHEMA legt one_time_kyber_prekeys an, BEVOR
    wandere_auf_geraete `identities` neu baut — der Fremdschluessel zeigt in
    diesem Moment auf eine Tabelle ohne device_id. Und die Wanderung baut
    `identities` aus einer festen Spaltenliste; kaemen die Kyber-Spalten vor
    ihr dazu, fielen sie beim Neubau weg. Am Ende muss beides stimmen, und
    die Kaskade muss greifen.
    """
    import relay_server as rs
    pfad = tmp_path / "alt.db"
    user = make_user()
    _alte_datenbank(pfad, user)

    conn = rs.init_db(pfad)
    try:
        spalten = {r[1] for r in conn.execute("PRAGMA table_info(identities)")}
        assert {"device_id", "kyber_prekey_id", "kyber_prekey",
                "kyber_prekey_sig"} <= spalten
        assert _kyber_fremdschluessel(conn) == {
            ("identities", "user_id", "user_id", "CASCADE"),
            ("identities", "device_id", "device_id", "CASCADE")}
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []

        # Ohne `with conn:` und mit rollback danach — die Probe darf nichts
        # hinterlassen (dieselbe Art wie test_bestehende_datenbank_wird_geraet_eins).
        conn.execute(
            "INSERT INTO one_time_kyber_prekeys (user_id, device_id, key_id,"
            " public_key, signature) VALUES (?,?,?,?,?)",
            (user["user_id"], 1, 1, _kyber_schluessel(), os.urandom(64)))
        conn.execute("DELETE FROM identities WHERE user_id=?", (user["user_id"],))
        assert conn.execute(
            "SELECT COUNT(*) FROM one_time_kyber_prekeys").fetchone()[0] == 0, \
            "die Kaskade auf die Kyber-Einmalschluessel greift nach der Wanderung nicht"
        conn.rollback()
    finally:
        conn.close()


def test_ein_vergessenes_geraet_nimmt_seine_kyber_zeilen_mit(relay, monkeypatch):
    """Der janitor raeumt die Kyber-Zeilen AUSDRUECKLICH weg — auch mit
    abgeschalteter Kaskade, und der Stand fuer das Dach folgt.

    PRAGMA foreign_keys gilt je Verbindung. Wer mit einem eigenen
    sqlite3-Aufruf aufraeumt, hat es aus; 1,7 KB je verwaister Zeile waeren
    Platte, die nie wieder frei wird.
    """
    rs = relay
    monkeypatch.setattr(rs, "GERAET_TTL", 30 * 24 * 3600)
    henrik = make_user()
    _melde_an(rs, henrik, geraet=1, **_kyber(henrik, n=3, erste=10))
    _melde_an(rs, henrik, geraet=2, **_kyber(henrik, n=4, erste=20))
    assert rs._kyber_zeilen == 7

    lange_her = time.time() - 40 * 24 * 3600
    with rs.db:
        rs.db.execute("UPDATE identities SET last_seen=?, updated_at=?"
                      " WHERE user_id=? AND device_id=2",
                      (lange_her, lange_her, henrik["user_id"]))
    rs.db.execute("PRAGMA foreign_keys=OFF")
    try:
        assert rs.raeume_vergessene_geraete() == 1
    finally:
        rs.db.execute("PRAGMA foreign_keys=ON")

    assert _geraete(rs, henrik["user_id"]) == [1]
    assert _kyber_je_geraet(rs, henrik["user_id"]) == {1: [10, 11, 12]}
    assert rs._kyber_zeilen == 3


def test_ein_verdraengtes_totes_geraet_nimmt_seine_kyber_zeilen_mit(
        relay, monkeypatch):
    """Der zweite Weg, auf dem ein Geraet verschwindet: es macht am
    Geraetedeckel einem neuen Platz (register)."""
    rs = relay
    monkeypatch.setattr(rs, "GERAETE_MAX", 1)
    henrik = make_user()
    _melde_an(rs, henrik, geraet=1, **_kyber(henrik, n=3, erste=10))

    lange_her = time.time() - 40 * 24 * 3600
    with rs.db:
        rs.db.execute("UPDATE identities SET last_seen=?, updated_at=?"
                      " WHERE user_id=?", (lange_her, lange_her, henrik["user_id"]))
    assert _melde_an(rs, henrik, geraet=2, **_kyber(henrik, n=2, erste=20))["ok"]

    assert _geraete(rs, henrik["user_id"]) == [2]
    assert _kyber_je_geraet(rs, henrik["user_id"]) == {2: [20, 21]}
    assert rs._kyber_zeilen == 2


# ------------------------------------------------ Das Dach

def test_das_dach_ueber_den_kyber_vorrat_kuerzt_statt_abzuweisen(relay, monkeypatch):
    """KYBER_OTK_MAX_GESAMT, an einem Dach von 5 Zeilen.

    Am Dach geht die Anmeldung durch, nur der Vorrat wird gekuerzt — die
    kleinsten Kennungen bleiben, und die Antwort sagt, wie viele. Der eigene
    alte Vorrat zaehlt bei einer Erneuerung nicht gegen einen, und wer Platz
    freigibt, macht ihn fuer andere frei.
    """
    rs = relay
    monkeypatch.setattr(rs, "KYBER_OTK_MAX_GESAMT", 5)
    alice, bob = make_user(), make_user()

    assert _melde_an(rs, alice, **_kyber(alice, n=3))["one_time_kyber_prekeys"] == 3
    r = _melde_an(rs, bob, **_kyber(bob, n=4, kennung=99, erste=1))
    assert r["ok"] is True
    assert r["one_time_kyber_prekeys"] == 2, "am Dach wird gekuerzt, nicht abgewiesen"
    assert _kyber_je_geraet(rs, bob["user_id"]) == {1: [1, 2]}
    assert rs._kyber_zeilen == 5

    # Bob erneuert: sein alter Vorrat ist weg und zaehlt nicht gegen ihn.
    assert _melde_an(rs, bob, **_kyber(bob, n=4, kennung=99, erste=10))[
        "one_time_kyber_prekeys"] == 2
    assert rs._kyber_zeilen == 5

    # Alice meldet sich ohne Kyber an und gibt ihre drei Zeilen frei.
    _melde_an(rs, alice)
    assert rs._kyber_zeilen == 2
    assert _melde_an(rs, bob, **_kyber(bob, n=4, kennung=99, erste=20))[
        "one_time_kyber_prekeys"] == 4
    assert rs._kyber_zeilen == 4 == rs.db.execute(
        "SELECT COUNT(*) FROM one_time_kyber_prekeys").fetchone()[0]


# ------------------------------------------------ prekeys_low

def _prekeys_low(rs, user, geraet=1):
    return [m for m in _sitzung(rs, user, geraet=geraet)
            if m.get("type") == "prekeys_low"]


def test_ein_knapper_kyber_vorrat_loest_prekeys_low_aus(relay, monkeypatch):
    """Dieselbe Nachricht, ein Feld mehr — und nur fuer Geraete mit Kyber.

    `remaining` bleibt der EC-Vorrat. Eine alte App bekommt die Nachricht nie
    wegen Kyber (sonst meldete sie sich bei jeder Verbindung neu an, ohne dass
    sich etwas aenderte), und am Dach kommt sie aus demselben Grund nicht:
    nachzuliefern brachte dort nichts.
    """
    rs = relay
    knapp = make_user(n_otk=25)
    _melde_an(rs, knapp, geraet=1, **_kyber(knapp, n=3))
    assert _prekeys_low(rs, knapp) == [
        {"type": "prekeys_low", "remaining": 25, "kyber_remaining": 3}]

    satt = make_user(n_otk=25)
    _melde_an(rs, satt, geraet=1, **_kyber(satt, n=25))
    assert _prekeys_low(rs, satt) == []

    alt_satt = make_user(n_otk=25)
    _melde_an(rs, alt_satt, geraet=1)
    assert _prekeys_low(rs, alt_satt) == [], \
        "eine alte App ohne Kyber darf nicht wegen Kyber nachliefern muessen"

    alt_knapp = make_user(n_otk=3)
    _melde_an(rs, alt_knapp, geraet=1)
    assert _prekeys_low(rs, alt_knapp) == [
        {"type": "prekeys_low", "remaining": 3}], \
        "fuer eine alte App bleibt die Nachricht Zeichen fuer Zeichen die alte"

    # Am Dach: fuer `knapp` waeren nur noch 8 Plaetze frei (seine 3 plus 5),
    # weniger als OTK_LOW_WATERMARK — die Nachlieferung braechte ihn nicht
    # ueber die Schwelle.
    monkeypatch.setattr(rs, "KYBER_OTK_MAX_GESAMT", rs._kyber_zeilen + 5)
    assert _prekeys_low(rs, knapp) == []


# --------------------------------------------------------------------------- #
#  Geraeteabmeldung  (docs/GERAETEABMELDUNG.md, 17.10.2026)
# --------------------------------------------------------------------------- #
#
# Der Befund, der das ausgeloest hat: nach "Telefon verloren, mit den zwoelf
# Woertern auf dem neuen wiederhergestellt" blieb das alte Geraet Teil der
# Identitaet und bekam weiter jede Nachricht. Abmelden ging nicht — und eine
# Loeschung nur hier haette nicht einmal ein Telefon in der Schublade
# aufgehalten: die App meldet sich auf 4401 von selbst neu an.
#
# Jedes Geraet hat deshalb einen eigenen Geraeteschluessel, und die Adresse
# fuehrt eine signierte Liste. Die Tests hier pruefen, dass ein abgemeldetes
# Geraet auf KEINEM Weg zurueckkommt, und halten die eine Grenze fest, die es
# per Konstruktion gibt (§4): mit den Woertern kann es zuruecksetzen — laut.

LISTE_PRAEFIX_T = b"BitDM-Geraeteliste-v1\n"
BEITRITT_PRAEFIX_T = b"BitDM-Beitritt-v1\n"
ANMELDE_PRAEFIX_T = b"BitDM-Geraet-Anmeldung-v1\n"


def _geraet():
    """Ein Geraeteschluessel: zufaellig, NIE aus den Woertern."""
    priv = os.urandom(32)
    return {"priv": priv, "pub": priv_to_curve25519_pub(priv)}


def _liste(user, epoche, geraete, unterzeichner, *, signer_ik=None,
           signer_gs=None, zeit=1760700000):
    """Baut und unterschreibt eine Fassung. geraete: {device_id: geraet}."""
    import relay_server as rs
    roh = rs.kanonisch({
        "adresse": user["user_id"], "epoche": epoche,
        "geraete": [[k, b64(g["pub"]), ""] for k, g in sorted(geraete.items())],
        "unterzeichner": unterzeichner, "v": 1, "zeit": zeit})
    nachricht = LISTE_PRAEFIX_T + roh.encode()
    gs = signer_gs or geraete[unterzeichner]
    return rs.GeraetelisteRequest(
        liste=roh,
        sig_identitaet=b64(sign(signer_ik or user["priv"], nachricht)),
        sig_geraet=b64(sign(gs["priv"], nachricht)))


def _setze(rs, anfrage):
    return asyncio.run(rs.setze_geraeteliste(anfrage, _Anfrage()))


def _status(fn):
    """HTTP-Status einer Absage, oder 200."""
    from fastapi import HTTPException
    try:
        fn()
    except HTTPException as exc:
        return exc.status_code
    return 200


def _melde_an_mit(rs, user, geraet, gs, **aenderungen):
    """Registrierung ueber den echten Endpunkt, mit Geraeteschluessel (§8.4).

    Geraet 1 schickt keine Kennung — wie die App (relay_client.dart).
    """
    kennung = None if geraet == 1 else geraet
    bundle = _bundle_mit(user, kennung, **aenderungen)
    nonce = rs.issue_nonce(user["user_id"], kennung)
    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    sig = sign(user["priv"], nonce + inhalt)
    gsig = None if gs is None else b64(
        sign(gs["priv"], ANMELDE_PRAEFIX_T + nonce + inhalt))
    return rs.register(rs.RegisterRequest(
        bundle=bundle, signature=b64(sig), geraete_signatur=gsig), _Anfrage())


def _beitritt(user, geraet_id, gs, *, signer_ik=None, zeit=1760700000):
    import relay_server as rs
    roh = rs.kanonisch({
        "adresse": user["user_id"], "device_id": geraet_id, "info": "",
        # Der HMAC mit dem Code des bestaetigenden Geraets. Den prueft nur das
        # Mitglied; dieser Server sieht nur seine Form.
        "nachweis": b64(os.urandom(32)),
        "schluessel": b64(gs["pub"]), "v": 1, "zeit": zeit})
    nachricht = BEITRITT_PRAEFIX_T + roh.encode()
    return rs.BeitrittRequest(
        anfrage=roh,
        sig_identitaet=b64(sign(signer_ik or user["priv"], nachricht)),
        sig_geraet=b64(sign(gs["priv"], nachricht)))


def _bitte(rs, anfrage):
    return asyncio.run(rs.beantrage_beitritt(anfrage, _Anfrage()))


def _auth_ok(gesendet):
    return any(m.get("type") == "auth_result" and m.get("ok") for m in gesendet)


def _zeilen(rs, tabelle, user, geraet):
    spalten = {"one_time_prekeys": ("user_id", "device_id"),
               "queue": ("recipient", "recipient_device")}[tabelle]
    return rs.db.execute(
        f"SELECT COUNT(*) FROM {tabelle} WHERE {spalten[0]}=? AND {spalten[1]}=?",
        (user["user_id"], geraet)).fetchone()[0]


class _Leitung:
    """Eine verbundene Leitung, die mitschreibt und sich schliessen laesst."""

    def __init__(self):
        self.empfangen = []
        self.geschlossen = None

    async def send_json(self, obj):
        self.empfangen.append(obj)

    async def close(self, code=None):
        self.geschlossen = code


def test_die_erste_liste_enthaelt_nur_das_anlegende_geraet(relay):
    """Anlage geht nur mit sich allein.

    Mehr Geraete gleich bei der Anlage gingen nur mit dem
    Identitaetsschluessel — genau dem, den jedes Geraet hat. Weitere kommen
    ueber den Beitritt, und den bestaetigt ein Mitglied.
    """
    rs = relay
    henrik = make_user()
    a, b = _geraet(), _geraet()
    assert _status(lambda: _setze(rs, _liste(henrik, 1, {1: a, 7: b}, 1))) == 403
    assert _status(lambda: _setze(rs, _liste(henrik, 2, {1: a}, 1))) == 409
    assert _setze(rs, _liste(henrik, 1, {1: a}, 1)) == {"ok": True, "epoche": 1}
    # Wer als zweiter anlegen will, verliert — und muss beitreten.
    assert _status(lambda: _setze(rs, _liste(henrik, 1, {7: b}, 7))) == 409


def test_mit_liste_reicht_der_identitaetsschluessel_nicht_mehr(relay):
    """Der Kern der Abmeldung: den Identitaetsschluessel hat JEDES Geraet."""
    rs = relay
    henrik = make_user()
    a = _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))

    assert _status(lambda: _melde_an_mit(rs, henrik, 1, None)) == 403
    assert _status(lambda: _melde_an_mit(rs, henrik, 1, _geraet())) == 403
    assert _melde_an_mit(rs, henrik, 1, a)["ok"] is True
    # Ein Geraet ausserhalb der Liste kommt auch mit einem eigenen, sauber
    # unterschriebenen Geraeteschluessel nicht hinein.
    assert _status(lambda: _melde_an_mit(rs, henrik, 7, _geraet())) == 403
    assert _geraete(rs, henrik["user_id"]) == [1]


def test_die_websocket_verlangt_den_geraeteschluessel(relay):
    rs = relay
    henrik = make_user()
    a = _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    _melde_an_mit(rs, henrik, 1, a)

    ohne = _StummerSocket(henrik["user_id"], henrik["priv"])
    asyncio.run(rs.ws_endpoint(ohne))
    assert ohne.geschlossen == 4403

    falsch = _StummerSocket(henrik["user_id"], henrik["priv"],
                            geraete_priv=_geraet()["priv"])
    asyncio.run(rs.ws_endpoint(falsch))
    assert falsch.geschlossen == 4403

    richtig = _StummerSocket(henrik["user_id"], henrik["priv"],
                             geraete_priv=a["priv"])
    asyncio.run(rs.ws_endpoint(richtig))
    assert _auth_ok(richtig.gesendet)
    assert rs.connections == {}


def test_ohne_liste_bleibt_alles_wie_bisher(relay):
    """Adressen ohne Liste (alte Apps) merken nichts — auch keine Pflicht
    zum Geraeteschluessel."""
    rs = relay
    alt = make_user()
    assert _melde_an(rs, alt)["ok"] is True
    assert _auth_ok(_sitzung(rs, alt))
    assert "geraeteliste" not in rs.get_prekey(alt["user_id"], _Anfrage())
    assert _status(lambda: rs.hole_geraeteliste(alt["user_id"], _Anfrage())) == 404


def test_abmelden_raeumt_das_geraet_ab_und_trennt_es(relay):
    rs = relay
    henrik, anna = make_user(), make_user()
    handy, tablet = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    _bitte(rs, _beitritt(henrik, 7, tablet))
    _setze(rs, _liste(henrik, 2, {1: handy, 7: tablet}, 1))
    _melde_an_mit(rs, henrik, 1, handy)
    _melde_an_mit(rs, henrik, 7, tablet)
    _puffere(rs, henrik["user_id"], anna["user_id"], n=3, geraet=7)
    l_handy, l_tablet = _Leitung(), _Leitung()
    _verbinde(rs, henrik, l_handy, geraet=1)
    _verbinde(rs, henrik, l_tablet, geraet=7)

    assert _setze(rs, _liste(henrik, 3, {1: handy}, 1)) == {"ok": True, "epoche": 3}

    assert _geraete(rs, henrik["user_id"]) == [1]
    assert _zeilen(rs, "one_time_prekeys", henrik, 7) == 0
    assert _zeilen(rs, "queue", henrik, 7) == 0, \
        "die Post des abgemeldeten Geraets bleibt nicht liegen"
    assert l_tablet.empfangen == [{"type": "abgemeldet", "epoche": 3}]
    assert l_tablet.geschlossen == 4410
    assert l_handy.empfangen == [{"type": "geraeteliste", "epoche": 3}]
    assert l_handy.geschlossen is None


def test_das_abgemeldete_geraet_kommt_auf_keinem_weg_zurueck(relay):
    """DER Fall der Aufgabe: das alte Telefon versucht es wieder.

    Es hat alles, was es vorher hatte — den Identitaetsschluessel (aus den
    Woertern) und seinen Geraeteschluessel. Es kommt trotzdem nicht durch:
    nicht ueber die WebSocket, nicht ueber /register unter alter oder neuer
    Kennung, nicht mit einer selbst geschriebenen Liste, nicht ueber eine
    Beitrittsanfrage. Der einzige Zug, der ihm bleibt, ist das Zuruecksetzen
    — und das wirft das neue Geraet sichtbar hinaus.
    """
    rs = relay
    henrik = make_user()
    altes, neues = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: altes}, 1))
    _melde_an_mit(rs, henrik, 1, altes)

    # Das Ersatztelefon: Woerter eingegeben, kein anderes Geraet greifbar.
    assert _setze(rs, _liste(henrik, 2, {23: neues}, 23)) == {"ok": True, "epoche": 2}
    _melde_an_mit(rs, henrik, 23, neues)

    # 1) Die eigene Wiederverbindung der App: 4410 VOR der Challenge — nicht
    #    4401, sonst meldete sie sich von selbst neu an.
    sock = _StummerSocket(henrik["user_id"], henrik["priv"],
                          geraete_priv=altes["priv"])
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.geschlossen == 4410
    assert sock.gesendet == [{"type": "abgemeldet", "epoche": 2}]

    # 2) /register unter der alten Kennung mit dem alten Geraeteschluessel.
    assert _status(lambda: _melde_an_mit(rs, henrik, 1, altes)) == 403
    # 3) unter einer neuen Kennung mit einem neuen Geraeteschluessel.
    assert _status(lambda: _melde_an_mit(rs, henrik, 99, _geraet())) == 403
    # 4) mit einer selbst geschriebenen Liste, die es wieder aufnimmt —
    #    als Unterzeichner selbst, und als angebliches neues Geraet.
    assert _status(lambda: _setze(
        rs, _liste(henrik, 3, {1: altes, 23: neues}, 1))) == 403
    assert _status(lambda: _setze(
        rs, _liste(henrik, 3, {1: altes, 23: neues}, 23, signer_gs=altes))) == 403
    # 5) Eine Beitrittsanfrage stellen kann es; zulassen muss sie ein Mitglied.
    _bitte(rs, _beitritt(henrik, 1, altes))
    assert _status(lambda: _melde_an_mit(rs, henrik, 1, altes)) == 403
    assert _geraete(rs, henrik["user_id"]) == [23]

    # DIE GRENZE (GERAETEABMELDUNG.md §4): mit den Woertern kann es
    # zuruecksetzen. Still ist das nicht — das neue Geraet faellt heraus.
    l_neu = _Leitung()
    _verbinde(rs, henrik, l_neu, geraet=23)
    assert _setze(rs, _liste(henrik, 3, {1: altes}, 1))["ok"] is True
    assert l_neu.geschlossen == 4410
    assert l_neu.empfangen == [{"type": "abgemeldet", "epoche": 3}]


def test_beitritt_braucht_die_bestaetigung_eines_mitglieds(relay):
    rs = relay
    henrik = make_user()
    handy, tablet = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    l_handy = _Leitung()
    _verbinde(rs, henrik, l_handy, geraet=1)

    assert _bitte(rs, _beitritt(henrik, 5, tablet)) == {"ok": True}
    assert l_handy.empfangen == [{"type": "beitritt"}]
    offen = rs.hole_beitritte(henrik["user_id"], _Anfrage())["beitritte"]
    assert [json.loads(b["anfrage"])["device_id"] for b in offen] == [5]

    # Vor der Bestaetigung: kein Zutritt, auch mit den Woertern nicht.
    assert _status(lambda: _melde_an_mit(rs, henrik, 5, tablet)) == 403

    _setze(rs, _liste(henrik, 2, {1: handy, 5: tablet}, 1))
    assert _melde_an_mit(rs, henrik, 5, tablet)["ok"] is True
    assert rs.hole_beitritte(henrik["user_id"], _Anfrage())["beitritte"] == [], \
        "die erledigte Anfrage bleibt nicht liegen"
    sock = _StummerSocket(henrik["user_id"], henrik["priv"], geraet=5,
                          geraete_priv=tablet["priv"])
    asyncio.run(rs.ws_endpoint(sock))
    assert _auth_ok(sock.gesendet)


def test_eine_beitrittsanfrage_braucht_die_woerter(relay):
    rs = relay
    henrik, mallory = make_user(), make_user()
    _setze(rs, _liste(henrik, 1, {1: _geraet()}, 1))
    fremd = _geraet()
    assert _status(lambda: _bitte(
        rs, _beitritt(henrik, 5, fremd, signer_ik=mallory["priv"]))) == 403
    # Schon vergebene Kennung: das neue Geraet muss eine freie waehlen.
    assert _status(lambda: _bitte(rs, _beitritt(henrik, 1, fremd))) == 409
    # Ohne Liste gibt es niemanden, der bestaetigen koennte.
    anna = make_user()
    assert _status(lambda: _bitte(rs, _beitritt(anna, 5, fremd))) == 409
    # Und eine Anfrage, deren Geraeteschluessel nicht unterschrieben hat.
    a = _beitritt(henrik, 6, fremd)
    a.sig_geraet = b64(sign(_geraet()["priv"],
                            BEITRITT_PRAEFIX_T + a.anfrage.encode()))
    assert _status(lambda: _bitte(rs, a)) == 403


def test_hoechstens_drei_anfragen_und_nur_fuer_kurze_zeit(relay, monkeypatch):
    rs = relay
    henrik = make_user()
    _setze(rs, _liste(henrik, 1, {1: _geraet()}, 1))
    for k in (2, 3, 4, 5):
        _bitte(rs, _beitritt(henrik, k, _geraet()))
    offen = rs.hole_beitritte(henrik["user_id"], _Anfrage())["beitritte"]
    assert sorted(json.loads(b["anfrage"])["device_id"] for b in offen) == [3, 4, 5]

    monkeypatch.setattr(rs, "BEITRITT_TTL", -1)
    assert rs.hole_beitritte(henrik["user_id"], _Anfrage())["beitritte"] == []
    assert rs.raeume_beitritte_auf() == 3


def test_die_epoche_geht_genau_einen_schritt(relay):
    """Kein Sprung nach vorn, kein Wiedereinspielen einer alten Fassung."""
    rs = relay
    henrik = make_user()
    a, b = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    assert _status(lambda: _setze(rs, _liste(henrik, 3, {1: a, 2: b}, 1))) == 409
    _setze(rs, _liste(henrik, 2, {1: a, 2: b}, 1))
    assert _status(lambda: _setze(rs, _liste(henrik, 2, {1: a}, 1))) == 409
    assert _status(lambda: _setze(rs, _liste(henrik, 1, {1: a}, 1))) == 409


def test_nur_der_identitaetsschluessel_der_adresse_unterschreibt(relay):
    rs = relay
    henrik, mallory = make_user(), make_user()
    assert _status(lambda: _setze(rs, _liste(
        henrik, 1, {1: _geraet()}, 1, signer_ik=mallory["priv"]))) == 403


def test_dieselbe_kennung_mit_anderem_schluessel_ist_ein_anderes_geraet(relay):
    """Wer seinen Eintrag gegen einen neuen Schluessel tauscht, ist kein
    Mitglied mehr, sondern setzt zurueck — und darf dann niemanden mitnehmen."""
    rs = relay
    henrik = make_user()
    a, b, getauscht = _geraet(), _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    _setze(rs, _liste(henrik, 2, {1: a, 2: b}, 1))
    assert _status(lambda: _setze(
        rs, _liste(henrik, 3, {1: getauscht, 2: b}, 1))) == 403


def test_ein_geraet_kann_sich_selbst_abmelden(relay):
    """Vor dem Verkauf eines Telefons: es unterschreibt seine eigene
    Abmeldung und steht danach nicht mehr in der Liste."""
    rs = relay
    henrik = make_user()
    a, b = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    _setze(rs, _liste(henrik, 2, {1: a, 2: b}, 1))
    l_b = _Leitung()
    _verbinde(rs, henrik, l_b, geraet=2)
    assert _setze(rs, _liste(henrik, 3, {1: a}, 2, signer_gs=b))["ok"] is True
    assert l_b.geschlossen == 4410
    # Das letzte Geraet kann nicht gehen — eine leere Liste gibt es nicht.
    assert _status(lambda: _setze(
        rs, _liste(henrik, 4, {}, 1, signer_gs=a))) == 400


def test_nicht_kanonische_listen_werden_abgewiesen(relay):
    """Unterschrieben wird EINE Schreibweise. Alles andere hiesse: zwei
    Parser koennten dieselbe Signatur verschieden lesen."""
    rs = relay
    henrik = make_user()
    a = _geraet()
    gut = _liste(henrik, 1, {1: a}, 1)
    obj = json.loads(gut.liste)

    def mit(roh):
        nachricht = LISTE_PRAEFIX_T + roh.encode("utf-8")
        return rs.GeraetelisteRequest(
            liste=roh, sig_identitaet=b64(sign(henrik["priv"], nachricht)),
            sig_geraet=b64(sign(a["priv"], nachricht)))

    mit_umlaut = dict(obj, geraete=[[1, obj["geraete"][0][1], "ü"]])
    falsche = {
        "Leerraum": json.dumps(obj, sort_keys=True),
        "doppelter Schluessel": gut.liste[:-1] + ',"v":1}',
        "unsortiert": json.dumps(
            {"v": 1, **{k: v for k, v in obj.items() if k != "v"}},
            separators=(",", ":")),
        "Umlaut roh": rs.kanonisch(mit_umlaut).replace("\\u00fc", "ü"),
        "Kommazahl": gut.liste.replace('"epoche":1', '"epoche":1.0'),
        "true statt 1": gut.liste.replace('"v":1', '"v":true'),
        "Feld zu viel": rs.kanonisch(dict(obj, x=1)),
    }
    for name, roh in falsche.items():
        assert _status(lambda: _setze(rs, mit(roh))) == 400, name
    assert _setze(rs, mit(gut.liste))["ok"] is True


def test_prekey_zeigt_nur_gelistete_geraete_und_traegt_die_liste(relay):
    rs = relay
    henrik = make_user()
    a = _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    _melde_an_mit(rs, henrik, 1, a)
    # Eine Zeile ausserhalb der Liste — gibt es nur fuer einen Augenblick,
    # hier von Hand angelegt.
    _lege_an(rs, henrik, geraet=9)

    voll = rs.get_prekey(henrik["user_id"], _Anfrage())
    knapp = rs.get_prekey(henrik["user_id"], _Anfrage(), nur_geraete=True)
    assert [g["device_id"] for g in voll["geraete"]] == [1]
    assert [g["device_id"] for g in knapp["geraete"]] == [1]
    erwartet = rs.hole_geraeteliste(henrik["user_id"], _Anfrage())
    assert voll["geraeteliste"] == erwartet == knapp["geraeteliste"]
    assert json.loads(erwartet["liste"])["epoche"] == 1

    # Gleich nach dem Zuruecksetzen hat die Adresse kein angemeldetes Geraet.
    # `?nur_geraete=1` sagt trotzdem, welche Kennungen die Liste fuehrt; das
    # volle Buendel gibt es erst, wenn sich jemand anmeldet.
    _setze(rs, _liste(henrik, 2, {42: _geraet()}, 42))
    leer = rs.get_prekey(henrik["user_id"], _Anfrage(), nur_geraete=True)
    assert leer["geraete"] == []
    assert json.loads(leer["geraeteliste"]["liste"])["epoche"] == 2
    assert _status(lambda: rs.get_prekey(henrik["user_id"], _Anfrage())) == 404


def test_die_anlage_raeumt_geraete_von_vor_der_liste_ab(relay):
    """Geraete, die sich vor der ersten Liste angemeldet hatten, stehen nicht
    darin. Sie fallen heraus und muessen beitreten — einmal."""
    rs = relay
    henrik = make_user()
    a = _geraet()
    _melde_an(rs, henrik)
    _melde_an(rs, henrik, geraet=7)
    l7 = _Leitung()
    _verbinde(rs, henrik, l7, geraet=7)
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    assert _geraete(rs, henrik["user_id"]) == [1]
    assert l7.geschlossen == 4410


def test_eine_abmeldung_waehrend_der_anmeldung_trennt_trotzdem(relay):
    """Die Luecke zwischen Vorraum und `connections`.

    Faellt die Abmeldung genau zwischen die Pruefung im Vorraum und den
    Eintrag der Leitung, findet setze_geraeteliste die Leitung noch nicht.
    Ohne die zweite Pruefung bliebe das abgemeldete Geraet verbunden und
    bekaeme seine Post zugestellt.
    """
    rs = relay
    henrik, anna = make_user(), make_user()
    a, b = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: a}, 1))
    _setze(rs, _liste(henrik, 2, {1: a, 2: b}, 1))
    _melde_an_mit(rs, henrik, 2, b)
    _puffere(rs, henrik["user_id"], anna["user_id"], n=2, geraet=2)

    def abmelden_genau_jetzt():
        neu = _liste(henrik, 3, {1: a}, 1)
        with rs.db:
            rs.db.execute("UPDATE geraetelisten SET epoche=3, liste=?"
                          " WHERE user_id=?", (neu.liste, henrik["user_id"]))

    sock = _StummerSocket(henrik["user_id"], henrik["priv"], geraet=2,
                          geraete_priv=b["priv"], bei_auth=abmelden_genau_jetzt)
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.geschlossen == 4410
    assert {"type": "abgemeldet", "epoche": 3} in sock.gesendet
    assert not any(m.get("type") == "message" for m in sock.gesendet)
    assert rs.connections == {}


# --------------------------------------------------------------------------- #
#  Relay verschweigt Epoche 3  (docs/GERAETEABMELDUNG.md §12, 18.10.2026)
# --------------------------------------------------------------------------- #
#
# Gegen einen Relay, der luegt, schuetzt die App sich selbst (Listenstempel
# Ende-zu-Ende, app/test/net/geraeteliste_verschwiegen_test.dart). Was der
# Relay dafuer beitraegt, steht hier: er nimmt die Geraeteschluessel-Signatur
# am signierten Prekey an, prueft sie gegen die Liste und gibt sie je Geraet
# aus (§12.5 a). Und ein ehrlicher Relay liefert eine neue Fassung auf allen
# drei Wegen gleich aus — darauf baut die Warnung beim Besitzer (§12.4).

PREKEY_PRAEFIX_T = b"BitDM-Prekey-v1\n"


def _spk_sig(user, geraet, gs, *, spk=None, spk_id=None):
    """Die Signatur des Geraeteschluessels am signierten Prekey, wie die App
    sie baut (geraeteliste.dart spkNachricht)."""
    b = user["bundle"]
    nachricht = PREKEY_PRAEFIX_T + (
        f"{user['user_id']}\n{geraet}\n{spk_id or b['signed_prekey_id']}\n"
        f"{spk or b['signed_prekey']}").encode()
    return b64(sign(gs["priv"], nachricht))


def _melde_an_mit_spk(rs, user, geraet, gs, spk_sig):
    kennung = None if geraet == 1 else geraet
    bundle = _bundle_mit(user, kennung)
    nonce = rs.issue_nonce(user["user_id"], kennung)
    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    return rs.register(rs.RegisterRequest(
        bundle=bundle,
        signature=b64(sign(user["priv"], nonce + inhalt)),
        geraete_signatur=b64(sign(gs["priv"], ANMELDE_PRAEFIX_T + nonce + inhalt)),
        spk_geraete_sig=spk_sig), _Anfrage())


def _echter_user():
    """make_user mit einem echten 33-Byte-Prekey — register() prueft die Form."""
    user = make_user()
    user["bundle"]["signed_prekey"] = b64(b"\x05" + os.urandom(32))
    return user


def _spk_eintraege(rs, user):
    voll = rs.get_prekey(user["user_id"], _Anfrage())
    return voll, {g["device_id"]: g.get("spk_geraete_sig") for g in voll["geraete"]}


def test_die_prekey_signatur_des_geraets_wird_gespeichert_und_ausgeliefert(relay):
    rs = relay
    henrik = _echter_user()
    handy, tablet = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    _setze(rs, _liste(henrik, 2, {1: handy, 7: tablet}, 1))

    sig7 = _spk_sig(henrik, 7, tablet)
    assert _melde_an_mit_spk(rs, henrik, 7, tablet, sig7)["ok"] is True
    # Geraet 1 meldet sich ohne an, wie eine App vor 2.0.1. Das geht noch
    # (Uebergang bis 2.0.2), und das Feld fehlt dann ganz.
    assert _melde_an_mit(rs, henrik, 1, handy)["ok"] is True

    voll, je_geraet = _spk_eintraege(rs, henrik)
    assert je_geraet == {1: None, 7: sig7}
    assert "spk_geraete_sig" not in voll, \
        "flach steht eine Kopie von geraete[0], und das hat keine"
    # Pruefbar mit genau dem, was ausgeliefert wird.
    g7 = next(g for g in voll["geraete"] if g["device_id"] == 7)
    assert rs.verify_signature(
        tablet["pub"],
        rs.spk_nachricht(henrik["user_id"], 7, g7["signed_prekey_id"],
                         g7["signed_prekey"]),
        rs.b64d(g7["spk_geraete_sig"]))


def test_eine_falsche_prekey_signatur_wird_nie_gespeichert(relay):
    """Das Buendel des Tablets unter der Kennung des Handys (§12.1 a) beginnt
    hier: das Tablet unterschreibt mit SEINEM Schluessel. Der Relay nimmt das
    nicht an — und auch keine Signatur ueber einen anderen Prekey."""
    rs = relay
    henrik = _echter_user()
    handy, tablet = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    _setze(rs, _liste(henrik, 2, {1: handy, 7: tablet}, 1))

    fremd = _spk_sig(henrik, 1, tablet)
    assert _status(lambda: _melde_an_mit_spk(rs, henrik, 1, handy, fremd)) == 403
    anderer_spk = _spk_sig(henrik, 1, handy, spk=b64(b"\x05" + os.urandom(32)))
    assert _status(lambda: _melde_an_mit_spk(rs, henrik, 1, handy, anderer_spk)) == 403
    falsche_kennung = _spk_sig(henrik, 7, handy)
    assert _status(lambda: _melde_an_mit_spk(rs, henrik, 1, handy, falsche_kennung)) == 403
    assert _status(lambda: _melde_an_mit_spk(rs, henrik, 1, handy, "kein base64!")) == 400
    assert _geraete(rs, henrik["user_id"]) == []


def test_eine_neue_anmeldung_ohne_signatur_loescht_die_alte(relay):
    """Die alte Signatur gehoert zum alten Prekey. Bliebe sie stehen, stuende
    sie neben einem neuen, zu dem sie nicht passt."""
    rs = relay
    henrik = _echter_user()
    handy = _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    sig = _spk_sig(henrik, 1, handy)  # XEdDSA ist zufaellig: einmal bauen
    _melde_an_mit_spk(rs, henrik, 1, handy, sig)
    assert _spk_eintraege(rs, henrik)[1] == {1: sig}
    _melde_an_mit(rs, henrik, 1, handy)
    assert _spk_eintraege(rs, henrik)[1] == {1: None}


def test_ohne_liste_wird_keine_prekey_signatur_gespeichert(relay):
    """Ohne Liste gibt es keinen Schluessel, gegen den sie gelten koennte."""
    rs = relay
    alt = _echter_user()
    bundle = _bundle_mit(alt)
    nonce = rs.issue_nonce(alt["user_id"], None)
    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    assert rs.register(rs.RegisterRequest(
        bundle=bundle, signature=b64(sign(alt["priv"], nonce + inhalt)),
        spk_geraete_sig=b64(os.urandom(64))), _Anfrage())["ok"] is True
    assert _spk_eintraege(rs, alt)[1] == {1: None}


def test_eine_neue_fassung_kommt_auf_allen_wegen_gleich_an(relay):
    """Der ehrliche Relay: nach Epoche 3 liefern /geraeteliste, /prekey und
    /prekey?nur_geraete=1 genau dieselbe Fassung — jedem Abrufer. Die App des
    Besitzers vergleicht damit (§12.4); ein Relay, der hier Epoche 2 zeigt,
    verschweigt die Abmeldung."""
    rs = relay
    henrik = _echter_user()
    handy, tablet = _geraet(), _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    _setze(rs, _liste(henrik, 2, {1: handy, 7: tablet}, 1))
    _melde_an_mit(rs, henrik, 1, handy)
    _melde_an_mit(rs, henrik, 7, tablet)
    drei = _liste(henrik, 3, {1: handy}, 1)
    assert _setze(rs, drei) == {"ok": True, "epoche": 3}

    erwartet = {"liste": drei.liste, "sig_identitaet": drei.sig_identitaet,
                "sig_geraet": drei.sig_geraet}
    assert rs.hole_geraeteliste(henrik["user_id"], _Anfrage()) == erwartet
    assert rs.get_prekey(henrik["user_id"], _Anfrage())["geraeteliste"] == erwartet
    knapp = rs.get_prekey(henrik["user_id"], _Anfrage(), nur_geraete=True)
    assert knapp["geraeteliste"] == erwartet
    assert [g["device_id"] for g in knapp["geraete"]] == [1]


def test_eine_datenbank_ohne_spalte_fuer_die_prekey_signatur_wird_erweitert(
        relay, tmp_path, monkeypatch):
    """Der Fall beim Aufspielen: die laufende Datenbank kennt die Spalte nicht.
    Jede Zeile steht danach unveraendert da, nur ohne Signatur."""
    rs = relay
    pfad = tmp_path / "vor_spk_sig.db"
    henrik = make_user()
    _datenbank_vor_kyber(pfad, henrik)
    conn = rs.init_db(pfad)
    try:
        spalten = {r[1] for r in conn.execute("PRAGMA table_info(identities)")}
        assert "spk_geraete_sig" in spalten
        assert conn.execute("SELECT spk_geraete_sig FROM identities").fetchall() \
            == [(None,)]
        conn.close()
        conn = rs.init_db(pfad)
        assert rs.ergaenze_spk_geraete_sig(conn) is False
        monkeypatch.setattr(rs, "db", conn)
        assert "spk_geraete_sig" not in rs.get_prekey(
            henrik["user_id"], _Anfrage())["geraete"][0]
    finally:
        conn.close()


def test_spk_nachricht_ist_die_der_app(relay):
    """DIESELBE ZEICHENKETTE steht in app/test/net/payload_listenstempel_test.dart.
    Weicht eine Seite ab, scheitert jede Anmeldung mit Signatur an 403."""
    assert relay.spk_nachricht("ABCD", 7, 42, "BQ==") == \
        b"BitDM-Prekey-v1\nABCD\n7\n42\nBQ=="


# --------------------------------------------------------------------------- #
#  Audit vom 16.10.2026, Relay-Teil  (SV-1, SV-2, KR-2, SV-3, SV-5, SV-7,
#  SV-8, SV-10; 23.10.2026)
# --------------------------------------------------------------------------- #
#
# Je Befund mindestens ein Test, der ohne die Behebung rot ist. Gegengeprueft,
# indem die Behebung testweise zurueckgenommen wurde.


# ------------------------------------------------ SV-1  Keine Summe auf dem Loop

def test_sv1_marken_einer_stunde_sind_eine_zeile(relay, monkeypatch):
    """Eine Zeile je Adresse und Stunde statt einer je Marke.

    Vorher bis zu 25 600 Zeilen je Adresse und Tag, und die Summe je Marke
    lief ueber alle davon: 76 ms auf dem Event-Loop (Audit, mess_blob_sum.py).
    Hoechstens zwei Zeilen, falls der Test genau ueber eine volle Stunde
    laeuft."""
    rs = relay
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    alice = make_user()
    _lege_an(rs, alice)
    raus = _sitzung(rs, alice, [
        {"type": "blob_marke", "kennung": c * 52, "groesse": 10} for c in "abcde"
    ])
    assert len([m for m in raus if m.get("type") == "blob_marke_ok"]) == 5
    zeilen, summe = rs.db.execute(
        "SELECT COUNT(*), SUM(groesse) FROM blob_marken WHERE user_id=?",
        (alice["user_id"],)).fetchone()
    assert zeilen <= 2, f"{zeilen} Zeilen fuer fuenf Marken"
    assert summe == 5 * rs.BLOB_MINDESTMENGE
    assert rs.blob_menge_heute(alice["user_id"]) == 5 * rs.BLOB_MINDESTMENGE


def test_sv1_keine_summe_ueber_den_ganzen_relay(relay, monkeypatch):
    """Jede Abfrage auf blob_marken im Handler betrifft genau EINE Adresse.

    Die Summe ueber den ganzen Relay lief ueber bis zu 204 800 Zeilen,
    gemessen 498 ms je Marke - synchron, also fuer alle Verbindungen."""
    rs = relay
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    alice = make_user()
    _lege_an(rs, alice)
    gesehen = []
    rs.db.set_trace_callback(gesehen.append)
    try:
        raus = _sitzung(rs, alice, [
            {"type": "blob_marke", "kennung": "a" * 52, "groesse": 10}])
    finally:
        rs.db.set_trace_callback(None)
    assert [m for m in raus if m.get("type") == "blob_marke_ok"]
    auf_marken = [s for s in gesehen if "blob_marken" in s]
    assert auf_marken, "der Test sieht die Abfragen nicht"
    assert all("user_id" in s for s in auf_marken), auf_marken


def test_sv1_alte_einzelzeilen_zaehlen_weiter(relay, monkeypatch):
    """Beim Aufspielen liegen noch Zeilen je Marke in der Tabelle. Sie zaehlen
    bis zu ihrem Ablauf mit; niemand bekommt durch das Update eine frische
    Tagesmenge geschenkt."""
    rs = relay
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    monkeypatch.setattr(rs, "BLOB_TAGESMENGE", 3 * rs.BLOB_MINDESTMENGE)
    alice = make_user()
    _lege_an(rs, alice)
    with rs.db:
        rs.db.executemany(
            "INSERT INTO blob_marken (user_id, groesse, ts) VALUES (?,?,?)",
            [(alice["user_id"], rs.BLOB_MINDESTMENGE, time.time() - 60 * i)
             for i in range(2)])
    raus = _sitzung(rs, alice, [
        {"type": "blob_marke", "kennung": c * 52, "groesse": 10} for c in "ab"])
    assert [m["kennung"][0] for m in raus if m.get("type") == "blob_marke_ok"] == ["a"]
    assert [m.get("reason") for m in raus if m.get("type") == "error"] == \
        ["Tagesmenge erschoepft"]


def test_sv1_aufgeraeumt_wird_nach_dem_fenster(relay):
    rs = relay
    jetzt = time.time()
    with rs.db:
        rs.db.executemany(
            "INSERT INTO blob_marken (user_id, groesse, ts) VALUES (?,?,?)",
            [("alt", 1, jetzt - rs.BLOB_FENSTER - 1), ("frisch", 1, jetzt - 24 * 3600 - 1)])
    rs.purge_expired()
    assert [r[0] for r in rs.db.execute("SELECT user_id FROM blob_marken")] == ["frisch"]


# ------------------------------------------------ SV-2  Tagesmenge ohne Upload

def test_sv2_marken_anderer_adressen_sperren_niemanden_aus(relay, monkeypatch):
    """Der Befund selbst: neun kostenlose Adressen holten sich je 25 GiB an
    Marken, luden nichts hoch, und der ganze Relay war 24 Stunden lang
    "ausgelastet". Die Menge des ganzen Relays zaehlt jetzt das Lager, nach
    Bytes, die wirklich ankommen (test_blob.py, test_sv2_*)."""
    rs = relay
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    alice = make_user()
    _lege_an(rs, alice)
    with rs.db:
        rs.db.executemany(
            "INSERT INTO blob_marken (user_id, groesse, ts) VALUES (?,?,?)",
            [(f"stoerer-{i}", rs.BLOB_TAGESMENGE, time.time()) for i in range(9)])
    raus = _sitzung(rs, alice, [
        {"type": "blob_marke", "kennung": "a" * 52, "groesse": 4096}])
    assert [m.get("reason") for m in raus if m.get("type") == "error"] == []
    assert [m["kennung"] for m in raus if m.get("type") == "blob_marke_ok"] == ["a" * 52]


def test_sv2_die_menge_je_adresse_bleibt(relay, monkeypatch):
    """Die Gegenprobe: die eigene Tagesmenge zaehlt weiter beim Ausstellen.
    Wer Marken verfallen laesst, verbraucht SEIN Kontingent."""
    rs = relay
    monkeypatch.setenv("BITDM_BLOB_SECRET", "x" * 48)
    alice = make_user()
    _lege_an(rs, alice)
    with rs.db:
        rs.blob_menge_anrechnen(alice["user_id"], rs.BLOB_TAGESMENGE)
    raus = _sitzung(rs, alice, [
        {"type": "blob_marke", "kennung": "a" * 52, "groesse": 4096}])
    assert [m.get("reason") for m in raus if m.get("type") == "error"] == \
        ["Tagesmenge erschoepft"]


# ------------------------------------------------ KR-2  Anmeldung mit Kontext
#
# Die Bytes stehen hier ABSICHTLICH ausgeschrieben und nicht ueber
# rs.ws_anmelde_nachricht gebaut: sonst teilten Test und Server dieselbe
# Annahme (siehe canonical_bytes oben). Dieselben Zeichen muss die App bauen.

RELAY_NAMEN_T = "relay.test,abcdefghijklmnop.onion"


def _ws_kontext(host, user_id, geraet, nonce):
    return (b"BitDM-Relay-Anmeldung-v1\n"
            + f"{host}\n{user_id}\n{geraet}\n".encode() + nonce)


def _reg_kontext(host, nonce, inhalt):
    return b"BitDM-Relay-Registrierung-v1\n" + f"{host}\n".encode() + nonce + inhalt


class _KontextSocket(_StummerSocket):
    """Beantwortet die Challenge in der NEUEN Form (KR-2).

    `relay` geht als Feld hinaus, `signiert_relay` in die signierten Bytes -
    weichen sie ab, ist es die weitergereichte Challenge eines anderen
    Relays."""

    def __init__(self, user_id, priv, *, relay, signiert_relay=None,
                 signiert_geraet=None, **kw):
        super().__init__(user_id, priv, **kw)
        self._relay = relay
        self._signiert_relay = relay if signiert_relay is None else signiert_relay
        self._kontext_geraet = signiert_geraet
        self.challenge = None

    async def send_json(self, obj):
        if obj.get("type") != "challenge":
            return await super().send_json(obj)
        self.gesendet.append(obj)
        self.challenge = obj
        nonce = base64.b64decode(obj["nonce"])
        geraet = self._kontext_geraet or self._geraet or 1
        zu = _ws_kontext(self._signiert_relay, self.query_params["user_id"],
                         geraet, nonce)
        antwort = {"signature": b64(sign(self._priv, zu))}
        if self._relay is not None:
            antwort["relay"] = self._relay
        if self._geraete_priv is not None:
            antwort["geraete_signatur"] = b64(sign(
                self._geraete_priv, ANMELDE_PRAEFIX_T + zu))
        self._antworten.insert(0, antwort)


def _angemeldet(sock):
    ergebnis = [m for m in sock.gesendet if m.get("type") == "auth_result"]
    return bool(ergebnis) and ergebnis[0]["ok"] is True


def test_kr2_die_challenge_nennt_die_namen_des_relays(relay, monkeypatch):
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", " Relay.Test , abcdefghijklmnop.onion,")
    sock = _KontextSocket(henrik["user_id"], henrik["priv"], relay="relay.test")
    asyncio.run(rs.ws_endpoint(sock))
    assert sock.challenge["relay"] == ["relay.test", "abcdefghijklmnop.onion"]
    antwort = rs.register_challenge(
        rs.ChallengeRequest(user_id=henrik["user_id"]), _Anfrage())
    assert antwort["relay"] == ["relay.test", "abcdefghijklmnop.onion"]


def test_kr2_ohne_namen_bleibt_die_challenge_wie_bisher(relay, monkeypatch):
    """Ein Relay ohne BITDM_RELAY_NAMEN schickt Byte fuer Byte die alte
    Challenge - und die App signiert dann die alte Form."""
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.delenv("BITDM_RELAY_NAMEN", raising=False)
    sock = _StummerSocket(henrik["user_id"], henrik["priv"])
    asyncio.run(rs.ws_endpoint(sock))
    assert set(sock.gesendet[0]) == {"type", "nonce"}
    assert set(rs.register_challenge(
        rs.ChallengeRequest(user_id=henrik["user_id"]), _Anfrage())) == {"nonce"}


def test_kr2_die_neue_form_meldet_an(relay, monkeypatch):
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    for name in ("relay.test", "abcdefghijklmnop.onion"):
        sock = _KontextSocket(henrik["user_id"], henrik["priv"], relay=name)
        asyncio.run(rs.ws_endpoint(sock))
        assert _angemeldet(sock), name


def test_kr2_die_challenge_eines_anderen_relays_gilt_hier_nicht(relay, monkeypatch):
    """Der Befund: Relay A reicht die Challenge von B (hier: diesem Relay) an
    das Opfer weiter. Das Opfer signiert mit dem Namen, unter dem es A
    erreicht hat - B nimmt das nicht an, unter keinem Feld."""
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    for feld in ("relay-a.test", "relay.test", None):
        sock = _KontextSocket(henrik["user_id"], henrik["priv"], relay=feld,
                              signiert_relay="relay-a.test")
        asyncio.run(rs.ws_endpoint(sock))
        assert not _angemeldet(sock), feld
        assert sock.geschlossen == 4403


def test_kr2_die_neue_form_bindet_das_geraet(relay, monkeypatch):
    """Geraet 1 steht ausdruecklich in den Bytes, auch ohne Kennung in der
    Query. Eine Signatur fuer Geraet 1 gilt nicht fuer Geraet 2."""
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1)
    _lege_an(rs, henrik, geraet=2)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    eins = _KontextSocket(henrik["user_id"], henrik["priv"], relay="relay.test")
    asyncio.run(rs.ws_endpoint(eins))
    assert _angemeldet(eins)
    fremd = _KontextSocket(henrik["user_id"], henrik["priv"], relay="relay.test",
                           geraet=2, signiert_geraet=1)
    asyncio.run(rs.ws_endpoint(fremd))
    assert not _angemeldet(fremd)
    zwei = _KontextSocket(henrik["user_id"], henrik["priv"], relay="relay.test",
                          geraet=2)
    asyncio.run(rs.ws_endpoint(zwei))
    assert _angemeldet(zwei)


def test_kr2_die_alte_form_der_app_2_0_0_gilt_weiter(relay, monkeypatch):
    """Die ausgelieferte App 2.0.0 signiert roh. Sie darf nicht ausgesperrt
    werden, auch nicht von einem Relay, der die neue Form kennt."""
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik, geraet=1)
    _lege_an(rs, henrik, geraet=3)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    monkeypatch.delenv("BITDM_ANMELDUNG_PFLICHT", raising=False)
    for geraet in (None, 3):
        sock = _StummerSocket(henrik["user_id"], henrik["priv"], geraet=geraet)
        asyncio.run(rs.ws_endpoint(sock))
        assert _angemeldet(sock), geraet
    nonce = _challenge(rs, henrik, _Anfrage())
    assert _registriere_mit(rs, henrik, nonce)["ok"] is True


def test_kr2_der_schalter_weist_die_alte_form_ab(relay, monkeypatch):
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    monkeypatch.setenv("BITDM_ANMELDUNG_PFLICHT", "1")
    alt = _StummerSocket(henrik["user_id"], henrik["priv"])
    asyncio.run(rs.ws_endpoint(alt))
    assert not _angemeldet(alt) and alt.geschlossen == 4403
    neu = _KontextSocket(henrik["user_id"], henrik["priv"], relay="relay.test")
    asyncio.run(rs.ws_endpoint(neu))
    assert _angemeldet(neu)
    nonce = _challenge(rs, henrik, _Anfrage())
    assert _status(lambda: _registriere_mit(rs, henrik, nonce)) == 403


def _registriere_kontext(rs, user, nonce, host_feld, host_signiert=None,
                         gs=None, geraet=None):
    bundle = _bundle_mit(user, geraet)
    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    zu = _reg_kontext(host_signiert or host_feld, nonce, inhalt)
    gsig = None if gs is None else b64(sign(gs["priv"], ANMELDE_PRAEFIX_T + zu))
    return rs.register(rs.RegisterRequest(
        bundle=bundle, signature=b64(sign(user["priv"], zu)),
        geraete_signatur=gsig, relay=host_feld), _Anfrage())


def test_kr2_registrierung_in_der_neuen_form(relay, monkeypatch):
    rs = relay
    henrik = _echter_user()
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    nonce = _challenge(rs, henrik, _Anfrage())
    assert _registriere_kontext(rs, henrik, nonce, "relay.test")["ok"] is True


def test_kr2_registrierung_fuer_einen_anderen_relay_gilt_nicht(relay, monkeypatch):
    rs = relay
    henrik = _echter_user()
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    nonce = _challenge(rs, henrik, _Anfrage())
    assert _status(lambda: _registriere_kontext(
        rs, henrik, nonce, "relay-a.test")) == 403
    assert _status(lambda: _registriere_kontext(
        rs, henrik, nonce, "relay.test", host_signiert="relay-a.test")) == 403
    # Das Nonce hat keiner der Versuche verbraucht.
    assert nonce in rs.offene_nonces(henrik["user_id"])


def test_kr2_registrierung_mit_geraeteliste_in_der_neuen_form(relay, monkeypatch):
    """Der Geraeteschluessel unterschreibt dieselben Bytes wie die Identitaet,
    hinter ANMELDE_PRAEFIX - in der neuen Form also die neue Nachricht."""
    rs = relay
    henrik = _echter_user()
    handy = _geraet()
    _setze(rs, _liste(henrik, 1, {1: handy}, 1))
    monkeypatch.setenv("BITDM_RELAY_NAMEN", RELAY_NAMEN_T)
    nonce = _challenge(rs, henrik, _Anfrage())
    assert _registriere_kontext(rs, henrik, nonce, "relay.test", gs=handy)["ok"] is True
    sock = _KontextSocket(henrik["user_id"], henrik["priv"], relay="relay.test",
                          geraete_priv=handy["priv"])
    asyncio.run(rs.ws_endpoint(sock))
    assert _angemeldet(sock)


def test_kr2_die_nachrichten_sind_die_der_app(relay):
    """DIESELBEN ZEICHEN muss relay_client.dart bauen. Weicht eine Seite ab,
    scheitert jede Anmeldung in der neuen Form mit 4403 bzw. 403."""
    rs = relay
    n = bytes(range(32))
    assert rs.ws_anmelde_nachricht("relay.bitdm.net", "abcd", 1, n) == \
        b"BitDM-Relay-Anmeldung-v1\nrelay.bitdm.net\nabcd\n1\n" + n
    assert rs.registrier_nachricht("relay.bitdm.net", n, b"\xff" * 32) == \
        b"BitDM-Relay-Registrierung-v1\nrelay.bitdm.net\n" + n + b"\xff" * 32


# ------------------------------------------------ SV-11  Hinweis in install.sh

def test_sv11_install_sh_verweist_auf_keine_einstellung_die_es_nicht_gibt():
    """Am Ende stand "Settings > Receiving > server address". Die App hat
    diese Einstellung seit dem 26.07.2026 nicht mehr (EIGENER-SERVER.md); wer
    einen Relay aufsetzte, suchte sie vergeblich und erfuhr nicht, warum.
    Der Relay wird beim BAUEN der App gewaehlt."""
    website = Path(__file__).resolve().parent.parent / "website"
    install = (website / "install.sh").read_text(encoding="utf-8")
    assert "Settings > Receiving" not in install
    assert "server address" not in install
    assert "--dart-define=BITDM_RELAY=https://$DOMAIN" in install
    app = Path(__file__).resolve().parent.parent / "app" / "lib" / "main.dart"
    assert "String.fromEnvironment(\n  'BITDM_RELAY'," in app.read_text(encoding="utf-8"), \
        "der Hinweis nennt einen Schalter, den die App so nicht mehr hat"


# ------------------------------------------------ SV-8  Push-Endpunkt: Port, Nutzer

def test_sv8_push_endpunkt_ohne_fremden_port_und_ohne_nutzer(relay):
    """Geprueft waren nur Schema, Host und Pfad. Ohne BITDM_PUSH_TARGET ging
    der leere POST an jeden Port der Maschine hinter push.bitdm.net."""
    rs = relay
    for gut in ("https://push.bitdm.net/upAbc_-1",
                "https://push.bitdm.net:443/upAbc",
                "https://push.bitdm.net/upAbc?up=1"):
        assert rs.push_endpunkt_gueltig(gut), gut
    for schlecht in ("https://push.bitdm.net:22/upAbc",
                     "https://push.bitdm.net:8443/upAbc",
                     "https://push.bitdm.net:99999/upAbc",
                     "https://nutzer@push.bitdm.net/upAbc",
                     "https://nutzer:geheim@push.bitdm.net/upAbc",
                     "https://:@push.bitdm.net/upAbc"):
        assert not rs.push_endpunkt_gueltig(schlecht), schlecht


# ------------------------------------------------ SV-10  Herkunft nicht aus der Kopfzeile

def test_sv10_ohne_nginx_hilft_eine_gefaelschte_kopfzeile_nichts(relay, monkeypatch):
    """Ein Relay, der versehentlich ohne nginx nach aussen lauscht: uvicorn
    glaubt X-Forwarded-For dann nicht, und der Relay darf es auch nicht.
    Vorher genuegten `X-Forwarded-For: 127.0.0.1` und `X-BitDM-Onion: 1`, und
    jede Bremse je Herkunft war aus."""
    rs = relay
    angreifer = dict(gegenueber="203.0.113.7", x_forwarded_for="127.0.0.1",
                     x_bitdm_onion="1", x_bitdm_kreis="fc00:dead:beef:4dad::2a")
    assert rs.client_ip(_Kopf(**angreifer)) == "203.0.113.7"
    assert not rs.kommt_ueber_onion(_Kopf(**angreifer))
    assert rs.limit_schluessel(_Kopf(**angreifer)) == "203.0.113.7"
    # Und die Bremse greift: ein Eimer mit einer Marke, ohne Nachfuellen.
    monkeypatch.setattr(rs, "RATE_CAPACITY", 1)
    monkeypatch.setattr(rs, "RATE_REFILL_PER_SEC", 0.0)
    rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))),
                          _Kopf(**angreifer))
    with pytest.raises(rs.HTTPException) as fehler:
        rs.register_challenge(rs.ChallengeRequest(user_id=encode_id(os.urandom(32))),
                              _Kopf(**{**angreifer, "x_forwarded_for": "198.51.100.9"}))
    assert fehler.value.status_code == 429


def test_sv10_hinter_nginx_zaehlt_was_uvicorn_eintraegt(relay):
    """Die Gegenprobe: hinter nginx steht die echte IP in `client`, so wie
    uvicorn sie aus der Kopfzeile von nginx uebernimmt."""
    rs = relay
    hinter_nginx = _Kopf(x_forwarded_for="198.51.100.20")
    assert rs.client_ip(hinter_nginx) == "198.51.100.20"
    ueber_tor = _Kopf(x_forwarded_for="127.0.0.1", x_bitdm_onion="1")
    assert rs.kommt_ueber_onion(ueber_tor)


# ------------------------------------------------ SV-5  Nonce-Herkunft je /48

def test_sv5_ein_heimanschluss_verdraengt_das_nonce_nicht(relay):
    """Der Befund: 16 /64 aus EINEM Anschluss waren 16 Herkuenfte, 128 fremde
    Nonces fuellten das Dach des Paares, und das des Opfers fiel. Je /48 ist
    der ganze Anschluss eine Herkunft und verdraengt nur sich selbst."""
    rs = relay
    opfer = make_user()
    beim_opfer = _Kopf(x_forwarded_for="198.51.100.20")
    nonce = _challenge(rs, opfer, beim_opfer)
    for netz in range(rs.NONCE_HERKUENFTE):
        stoerer = _Kopf(x_forwarded_for=f"2001:db8:7:{netz:x}::1")
        for _ in range(rs.NONCE_PLAETZE):
            _challenge(rs, opfer, stoerer)
    assert nonce in rs.offene_nonces(opfer["user_id"])
    assert _registriere_mit(rs, opfer, nonce, anfrage=beim_opfer)["ok"] is True


def test_sv5_die_bremse_zaehlt_weiter_je_64(relay):
    """Nur die Nonces zaehlen je /48. Die Bremse bliebe sonst fuer ganze
    Mobilfunknetze ein einziger Eimer."""
    rs = relay
    assert rs.nonce_herkunft(_Kopf(x_forwarded_for="2001:db8:7:3::1")) == \
        "2001:db8:7::/48"
    assert rs.limit_schluessel(_Kopf(x_forwarded_for="2001:db8:7:3::1")) == \
        "2001:db8:7:3::/64"
    assert rs.nonce_herkunft(_Kopf(x_forwarded_for="203.0.113.7")) == "203.0.113.7"


# ------------------------------------------------ SV-7  Anstoesse ohne Flut

def _mit_endpunkt(rs, user, geraet=1):
    _lege_an(rs, user, geraet=geraet)
    with rs.db:
        rs.db.execute("UPDATE identities SET push_endpoint=?"
                      " WHERE user_id=? AND device_id=?",
                      ("https://push.bitdm.net/upGeheim123", user["user_id"], geraet))


def test_sv7_ein_client_fuer_alle_anstoesse(relay, klage_frisch, monkeypatch):
    """Vorher baute JEDER Anstoss einen eigenen httpx.AsyncClient - samt
    TLS-Kontext, synchron auf dem Event-Loop (gemessen 180 ms)."""
    rs = relay
    empfaenger = make_user()
    _mit_endpunkt(rs, empfaenger)
    gebaut = []
    echt = rs.httpx.AsyncClient

    class Zaehler(echt):
        def __init__(self, *a, **kw):
            gebaut.append(1)
            super().__init__(*a, **kw)

    monkeypatch.setattr(rs.httpx, "AsyncClient", Zaehler)
    gesehen = []
    srv = _push_server(gesehen)
    try:
        monkeypatch.setattr(
            rs, "PUSH_ZIEL_BASIS", f"http://127.0.0.1:{srv.server_address[1]}")

        async def lauf():
            for _ in range(5):
                await rs.stosse_an(empfaenger["user_id"], 1)
            # getattr: so laeuft die Gegenprobe gegen den alten Stand bis zur
            # eigentlichen Frage, statt an einem fehlenden Namen zu scheitern.
            schliessen = getattr(rs, "schliesse_push_klient", None)
            if schliessen is not None:
                await schliessen()

        asyncio.run(lauf())
    finally:
        srv.shutdown()
    assert len(gesehen) == 5
    assert len(gebaut) == 1, f"{len(gebaut)} Clients fuer fuenf Anstoesse"


def test_sv7_eine_flut_an_ein_geraet_weckt_es_nicht_hundertmal(relay, monkeypatch):
    """Hoechstens ein Anstoss je Geraet unterwegs, und danach hoechstens einer
    fuer alles, was waehrenddessen kam."""
    rs = relay
    angestossen = []

    async def langsamer_anstoss(user_id, device_id):
        angestossen.append((user_id, device_id))
        await asyncio.sleep(0.05)

    monkeypatch.setattr(rs, "stosse_an", langsamer_anstoss)

    async def lauf():
        for _ in range(100):
            rs.stosse_im_hintergrund_an("empfaenger", 1)
        assert len(rs._laufende_anstoesse) == 1
        await asyncio.sleep(0.3)
        assert not rs._laufende_anstoesse and not rs._anstoss_nochmal
        # Was NACH dem Wecken kommt, bekommt wieder einen.
        rs.stosse_im_hintergrund_an("empfaenger", 1)
        await asyncio.sleep(0.1)

    asyncio.run(lauf())
    assert angestossen == [("empfaenger", 1)] * 3


def test_sv7_die_zahl_gleichzeitiger_anstoesse_ist_gedeckelt(relay, klage_frisch,
                                                            monkeypatch, capsys):
    rs = relay
    monkeypatch.setattr(rs, "PUSH_LAUFEND_MAX", 3)
    angestossen = []

    async def langsamer_anstoss(user_id, device_id):
        angestossen.append(device_id)
        await asyncio.sleep(0.05)

    monkeypatch.setattr(rs, "stosse_an", langsamer_anstoss)

    async def lauf():
        for geraet in range(10):
            rs.stosse_im_hintergrund_an("empfaenger", geraet)
        await asyncio.sleep(0.2)

    asyncio.run(lauf())
    assert sorted(angestossen) == [0, 1, 2]
    assert "Anstoesse gleichzeitig" in capsys.readouterr().out


# ------------------------------------------------ SV-3  Das Adressdach

def _neue_adresse(rs, anfrage, user=None):
    """Eine vollstaendige Registrierung einer NEUEN Adresse von `anfrage`.
    Rueckgabe: HTTP-Status (200 = angenommen)."""
    user = user or make_user()
    return _status(lambda: _registriere_mit(
        rs, user, _challenge(rs, user, anfrage), anfrage=anfrage))


def test_sv3_ein_anschluss_legt_nicht_beliebig_viele_adressen_an(relay, monkeypatch):
    """Der Befund: je /64 gezaehlt und mit der allgemeinen Bremse (rund
    34 500 am Tag) fuellte ein Heimanschluss das Dach in Minuten. Jetzt hat
    eine NEUE Adresse ihren eigenen Eimer je Anschluss (/48)."""
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_JE_TAG", 3, raising=False)
    for netz in range(3):
        assert _neue_adresse(rs, _Kopf(x_forwarded_for=f"2001:db8:9:{netz}::1")) == 200
    assert _neue_adresse(rs, _Kopf(x_forwarded_for="2001:db8:9:ff::1")) == 429
    # Ein anderer Anschluss ist davon unberuehrt.
    assert _neue_adresse(rs, _Kopf(x_forwarded_for="2001:db8:a::1")) == 200


def test_sv3_wer_schon_da_ist_kommt_weiter_durch(relay, monkeypatch):
    """Der Eimer trifft nur NEUE Adressen. Buendel erneuern und weitere
    Geraete anmelden geht wie bisher - sonst waere die Bremse fuer die
    eigenen Nutzer eines Netzes eine Abschaltung."""
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_JE_TAG", 1, raising=False)
    hier = _Kopf(x_forwarded_for="198.51.100.20")
    henrik = make_user()
    assert _neue_adresse(rs, hier, henrik) == 200
    assert _neue_adresse(rs, hier) == 429
    for _ in range(3):
        assert _status(lambda: _registriere_mit(
            rs, henrik, _challenge(rs, henrik, hier), anfrage=hier)) == 200
    assert _status(lambda: _registriere_mit(
        rs, henrik, _challenge(rs, henrik, hier, geraet=2), geraet=2,
        anfrage=hier)) == 200


def test_sv3_ueber_tor_teilen_sich_alle_circuits_ein_dach(relay, monkeypatch):
    """Ein Circuit ist billig zu wechseln, und ohne Circuit-Kennung gab es
    ueber Tor gar keine Bremse."""
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_ONION_JE_TAG", 2, raising=False)
    kreis = lambda n: _Kopf(x_forwarded_for="127.0.0.1", x_bitdm_onion="1",
                            x_bitdm_kreis=f"fc00:dead:beef:4dad::{n:x}")
    assert _neue_adresse(rs, kreis(1)) == 200
    assert _neue_adresse(rs, kreis(2)) == 200
    assert _neue_adresse(rs, kreis(3)) == 429
    ohne_kreis = _Kopf(x_forwarded_for="127.0.0.1", x_bitdm_onion="1")
    assert _neue_adresse(rs, ohne_kreis) == 429
    # Ueber das oeffentliche Netz geht es weiter.
    assert _neue_adresse(rs, _Kopf(x_forwarded_for="203.0.113.7")) == 200


def test_sv3_eine_nie_verbundene_adresse_geht_nach_zwei_tagen(relay):
    """Gehalten wurde das Dach mit einer Erneuerung im Monat, ohne sich je
    anzumelden. Eine App meldet sich direkt nach dem Registrieren per /ws an."""
    rs = relay
    nie, frisch, lebt = make_user(), make_user(), make_user()
    jetzt = time.time()
    # getattr: die Gegenprobe gegen den alten Stand laeuft so bis zur Frage.
    ttl = getattr(rs, "NIE_VERBUNDEN_TTL", 48 * 3600)
    _lege_an(rs, nie)
    _lege_an(rs, frisch)
    _lege_an(rs, lebt, last_seen=jetzt - 5 * 24 * 3600)
    with rs.db:
        rs.db.execute("UPDATE identities SET last_seen=0, updated_at=? WHERE user_id=?",
                      (jetzt - ttl - 60, nie["user_id"]))
        rs.db.execute("UPDATE identities SET last_seen=0, updated_at=? WHERE user_id=?",
                      (jetzt - ttl + 600, frisch["user_id"]))
    assert rs.raeume_vergessene_geraete() == 1
    uebrig = {r[0] for r in rs.db.execute("SELECT user_id FROM identities")}
    assert uebrig == {frisch["user_id"], lebt["user_id"]}


def test_sv3_das_dach_meldet_sich_bevor_es_voll_ist(relay, monkeypatch, capsys):
    rs = relay
    monkeypatch.setattr(rs, "IDENTITAETEN_MAX", 5)
    for i in range(5):
        assert _neue_adresse(rs, _Kopf(x_forwarded_for=f"198.51.100.{i + 1}")) == 200
    zeilen = [z for z in capsys.readouterr().out.splitlines() if "Adressdach" in z]
    assert len(zeilen) == 1, "hoechstens einmal je Stunde"
    assert "80 %" in zeilen[0] and "4 von 5" in zeilen[0]
    assert "198.51" not in zeilen[0], "keine Herkunft im Journal"


# ---------------------------------- SV-3  Die Marke kostet erst die neue Adresse
#
# Nachpruefung vom 24.10.2026: neue_adresse_ok lief VOR den Pruefungen, die
# eine Registrierung noch scheitern lassen. Jeder Fehlversuch kostete die
# ganze Herkunft eine Marke, und ein dauerhaft scheiternder Client hinter
# einer geteilten IPv4 (Carrier-Grade-NAT) hielt den Eimer fuer alle leer.

def _registriere_von(rs, user, anfrage, geraet=None, gs=None, **aenderungen):
    """Eine Registrierung ueber den echten Endpunkt, von `anfrage` aus: mit
    eigener Challenge, Aenderungen am Buendel und optional Geraeteschluessel."""
    nonce = _challenge(rs, user, anfrage, geraet)
    bundle = _bundle_mit(user, geraet, **aenderungen)
    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    gsig = None if gs is None else b64(
        sign(gs["priv"], ANMELDE_PRAEFIX_T + nonce + inhalt))
    return rs.register(rs.RegisterRequest(
        bundle=bundle, signature=b64(sign(user["priv"], nonce + inhalt)),
        geraete_signatur=gsig), anfrage)


def _falsche_kyber_signatur(rs, user, anfrage):
    teil = _kyber(user)
    teil["kyber_prekey_sig"] = b64(
        sign(os.urandom(32), base64.b64decode(teil["kyber_prekey"])))
    return _registriere_von(rs, user, anfrage, **teil)


def _ohne_geraeteschluessel(rs, user, anfrage):
    # Die App legt die Liste vor der ersten Anmeldung an: eine Adresse ohne
    # Zeile in `identities`, aber mit Liste, ist noch NEU.
    _setze(rs, _liste(user, 1, {1: _geraet()}, 1))
    return _registriere_von(rs, user, anfrage)


def _riesige_kennung(rs, user, anfrage):
    # Scheitert erst beim INSERT (OverflowError) - also NACH der Marke.
    return _registriere_von(rs, user, anfrage, registration_id=10**30)


@pytest.mark.parametrize("fehlversuch, status", [
    (_falsche_kyber_signatur, 400),
    (_ohne_geraeteschluessel, 403),
    (_riesige_kennung, 400),
], ids=["kyber", "geraeteliste", "insert"])
def test_sv3_ein_fehlversuch_kostet_keine_marke(relay, monkeypatch, fehlversuch,
                                                status):
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_JE_TAG", 1)
    hier = _Kopf(x_forwarded_for="198.51.100.30")
    for _ in range(3):
        stoerer = make_user()
        assert _status(lambda: fehlversuch(rs, stoerer, hier)) == status
    assert rs.db.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 0
    # Die eine Marke des Tages ist noch da.
    assert _neue_adresse(rs, hier) == 200
    assert _neue_adresse(rs, hier) == 429


def test_sv3_ein_volles_dach_kostet_keine_marke(relay, monkeypatch):
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_JE_TAG", 1)
    monkeypatch.setattr(rs, "IDENTITAETEN_MAX", 1)
    hier = _Kopf(x_forwarded_for="198.51.100.31")
    _lege_an(rs, make_user())
    for _ in range(3):
        assert _neue_adresse(rs, hier) == 507
    monkeypatch.setattr(rs, "IDENTITAETEN_MAX", 50_000)
    assert _neue_adresse(rs, hier) == 200
    assert _neue_adresse(rs, hier) == 429


def test_sv3_die_grenze_gilt_genau(relay, monkeypatch):
    """Genau NEUE_ADRESSEN_JE_TAG neue Adressen je Herkunft und Tag (100),
    auch mit Fehlversuchen dazwischen - nicht eine mehr, nicht eine weniger."""
    rs = relay
    # Nur die allgemeine Bremse (5 von 120 je Registrierung) aus dem Weg
    # raeumen; um die geht es hier nicht.
    monkeypatch.setattr(rs, "RATE_CAPACITY", 100_000)
    hier = _Kopf(x_forwarded_for="198.51.100.32")
    grenze = rs.NEUE_ADRESSEN_JE_TAG
    assert grenze == 100
    for i in range(grenze):
        if i % 10 == 0:
            assert _status(lambda: _falsche_kyber_signatur(
                rs, make_user(), hier)) == 400
        assert _neue_adresse(rs, hier) == 200, f"Adresse {i + 1}"
    assert _neue_adresse(rs, hier) == 429
    adressen = rs.db.execute(
        "SELECT COUNT(DISTINCT user_id) FROM identities").fetchone()[0]
    assert adressen == grenze


def test_sv3_auch_gleichzeitig_nicht_mehr_adressen_als_marken(relay, monkeypatch):
    """Pruefen und Abbuchen sind ein Schritt: zwanzig gleichzeitige
    Registrierungen bei fuenf Marken legen genau fuenf Adressen an."""
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_JE_TAG", 5)
    hier = _Kopf(x_forwarded_for="198.51.100.33")
    vorbereitet = []
    for _ in range(20):
        user = make_user()
        nonce = _challenge(rs, user, hier)
        bundle = _bundle_mit(user)
        sig = sign(user["priv"],
                   nonce + hashlib.sha256(bundle.canonical_bytes()).digest())
        vorbereitet.append(rs.RegisterRequest(bundle=bundle, signature=b64(sig)))
    start = threading.Barrier(len(vorbereitet))
    ergebnisse = []

    def lauf(anfrage):
        start.wait()
        ergebnisse.append(_status(lambda: rs.register(anfrage, hier)))

    faeden = [threading.Thread(target=lauf, args=(a,)) for a in vorbereitet]
    for f in faeden:
        f.start()
    for f in faeden:
        f.join()
    assert sorted(ergebnisse) == [200] * 5 + [429] * 15
    assert rs.db.execute(
        "SELECT COUNT(DISTINCT user_id) FROM identities").fetchone()[0] == 5


def test_sv3_eine_bekannte_adresse_zahlt_keine_marke(relay, monkeypatch):
    """Buendel erneuern und weitere Geraete anlegen kostet nichts - auch
    nicht, solange noch Marken da sind (nicht nur: geht trotz leerem Eimer)."""
    rs = relay
    monkeypatch.setattr(rs, "NEUE_ADRESSEN_JE_TAG", 2)
    hier = _Kopf(x_forwarded_for="198.51.100.34")
    henrik = make_user()
    assert _neue_adresse(rs, hier, henrik) == 200
    for _ in range(3):
        assert _status(lambda: _registriere_von(rs, henrik, hier)) == 200
    for geraet in (2, 3):
        assert _status(lambda: _registriere_von(
            rs, henrik, hier, geraet=geraet)) == 200
    # Von zwei Marken ist genau eine weg: die fuer henrik.
    assert _neue_adresse(rs, hier) == 200
    assert _neue_adresse(rs, hier) == 429


# ------------------------------- Befund 8  Relay-Namen mit Port oder Unsinn
#
# Nachpruefung vom 24.10.2026: RELAY_NAME_MUSTER liess "relay.bitdm.net:443"
# als Namen durch. Die App nennt ihren Namen ohne Port, fand sich nicht in der
# Liste und fiel still auf die alte Form zurueck - mit
# BITDM_ANMELDUNG_PFLICHT=1 waere sie ausgesperrt worden.

FALSCHE_RELAY_NAMEN_T = [
    "relay.bitdm.net:443", "abcdefghijklmnop.onion:80", "[::1]",
    "10.0.0.300", "-x.test", "a..b", "fe80::1%eth0", "relay.test.",
]


def test_relay_namen_mit_port_werden_nicht_uebernommen(relay, monkeypatch):
    rs = relay
    henrik = make_user()
    _lege_an(rs, henrik)
    monkeypatch.setenv("BITDM_RELAY_NAMEN", ",".join(
        FALSCHE_RELAY_NAMEN_T + [" Relay.Test ", "2001:DB8::1", "192.0.2.7", ""]))
    assert rs.relay_namen() == ("relay.test", "2001:db8::1", "192.0.2.7")
    # Die Challenge nennt nur die gueltigen, und wer sich mit dem Namen samt
    # Port meldet, kommt nicht durch.
    antwort = rs.register_challenge(
        rs.ChallengeRequest(user_id=henrik["user_id"]), _Anfrage())
    assert antwort["relay"] == ["relay.test", "2001:db8::1", "192.0.2.7"]
    assert rs.angemeldeter_relay("relay.bitdm.net:443") == (False, None)
    assert rs.angemeldeter_relay("relay.test") == (True, "relay.test")


def test_relay_namen_werden_beim_start_gemeldet(tmp_path, monkeypatch, capsys):
    """Ueber den echten lifespan: gemeldet werden muss es beim START, und ein
    falscher Eintrag darf den Relay nicht vom Netz nehmen."""
    from fastapi.testclient import TestClient
    import relay_server as rs

    monkeypatch.setattr(rs, "DB_PATH", tmp_path / "relay.db")
    monkeypatch.setattr(rs, "db", None, raising=False)
    monkeypatch.setattr(rs, "_queue_zeilen", 0)
    monkeypatch.setattr(rs, "_kyber_zeilen", 0)
    monkeypatch.setenv("BITDM_RELAY_NAMEN",
                       "relay.bitdm.net:443,relay.test,abcdefghijklmnop.onion")
    with TestClient(rs.app) as client:
        assert client.get("/health").status_code == 200
    zeilen = capsys.readouterr().out.splitlines()
    laut = [z for z in zeilen if z.startswith("[!]") and "BITDM_RELAY_NAMEN" in z]
    assert len(laut) == 1 and "'relay.bitdm.net:443'" in laut[0]
    gueltig = [z for z in zeilen if z.startswith("[i] Relay-Namen")]
    assert gueltig == ["[i] Relay-Namen fuer die Anmeldung mit Kontext: "
                       "relay.test, abcdefghijklmnop.onion"]


def test_ohne_relay_namen_sagt_der_start_das_auch(relay, monkeypatch, capsys):
    rs = relay
    monkeypatch.setenv("BITDM_RELAY_NAMEN", "relay.bitdm.net:443")
    rs.melde_relay_namen()
    aus = capsys.readouterr().out
    assert "[!] BITDM_RELAY_NAMEN" in aus
    assert "Keine Relay-Namen" in aus
    assert rs.relay_namen() == ()
