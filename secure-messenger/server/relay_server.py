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
import threading
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

# Je Absender: wie schnell EINER die Warteschlange fuellen darf.
#
# Greift wie otk_limit_ok je Adresse und nicht je IP. Die Adresse ist an dieser
# Stelle nachgewiesen (Challenge-Response beim Verbinden), die IP dagegen sagt
# nichts: hinter einer Mobilfunk-IP haengen tausende Kunden, siehe die
# Begruendung weiter oben.
MSG_CAPACITY = int(os.getenv("BITDM_MSG_BURST", 60))
MSG_REFILL_PER_SEC = float(os.getenv("BITDM_MSG_REFILL", 2.0))

# Ein Dach ueber der GANZEN Tabelle. Der Deckel darunter (QUEUE_MAX_PER_USER)
# haengt an der Adresse, die der ABSENDER aussucht — ohne ein zweites, festes
# Dach ist er beliebig oft zu haben.
#
# 200 000 Zeilen sind im schlechtesten Fall (jede Zeile am
# MAX_CIPHERTEXT_BYTES-Limit) rund 12,5 GiB. Dem stehen heute 31 Konten
# gegenueber, die zusammen hoechstens 15 500 Zeilen halten koennen — die Zahl
# trifft also keinen ehrlichen Betrieb, sondern nur die Flut. Sie gehoert an
# die Platte des jeweiligen Relays angepasst.
QUEUE_MAX_TOTAL = int(os.getenv("BITDM_QUEUE_MAX_TOTAL", 200_000))

# ── Der ZWEITE Weg auf die Platte ─────────────────────────────────────────
#
# QUEUE_MAX_TOTAL deckelt die Warteschlange. /register schrieb daneben voellig
# ungedeckelt in `identities` und `one_time_prekeys` — und schlimmer: seit die
# Warteschlange eine Existenzpruefung hat, MUSS ein Angreifer sich erst
# registrieren, um sie ueberhaupt fluten zu koennen. Der eine Riegel trieb ihn
# also genau auf das groessere Leck.
#
# Nachgestellt am 27.07.2026: eine einzige IP schob in 30 Sekunden 35
# Registrierungen zu je 837 KiB durch — 20,4 MiB Wachstum, hochgerechnet rund
# 57 GiB am Tag, ohne eine einzige Ablehnung. Und anders als die Warteschlange
# heilt das nicht von selbst: `purge_expired` ruehrt diese beiden Tabellen
# nicht an, der Platz bleibt bis zur Handarbeit belegt.
#
# ZWEI GRENZEN, weil eine allein nicht reicht:
#
# OTK_MAX_JE_BUENDEL trifft die Menge. Die App laedt 100 Einmalschluessel
# hoch; nginx laesst 256 KiB Rumpf durch, das sind rund 2900. 200 ist
# doppelt so viel wie noetig und ein Vierzehntel dessen, was heute
# durchgeht — aus 837 KiB je Registrierung werden rund 7 KiB.
#
# IDENTITAETEN_MAX trifft die Anzahl. Ohne sie bliebe die Flut moeglich, sie
# dauerte nur laenger. 50 000 Identitaeten sind mit dem Deckel darueber im
# schlechtesten Fall rund 350 MiB — bei heute 31 Konten trifft die Zahl
# keinen ehrlichen Betrieb. Sie gilt NUR fuer neue Adressen: wer schon
# registriert ist, kann sein Bundle immer erneuern, sonst waere ein volles
# Relay fuer seine eigenen Nutzer unbenutzbar.
OTK_MAX_JE_BUENDEL = int(os.getenv("BITDM_OTK_MAX", 200))
IDENTITAETEN_MAX = int(os.getenv("BITDM_IDENTITIES_MAX", 50_000))


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
BLOB_MAX_BYTES = int(os.getenv("BITDM_BLOB_MAX", 5 * 1024**3))

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
# Seit dem 26.07.2026 auf 25 GiB: bei einer Obergrenze von 5 GiB je Datei
# waeren 10 GiB genau zwei Dateien am Tag, und die zweite haette schon
# scheitern koennen, weil eine verfallene Marke ihr Kontingent behaelt.
BLOB_TAGESMENGE = int(os.getenv("BITDM_BLOB_QUOTA", 25 * 1024**3))

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

# EINE Transaktion zur Zeit auf der geteilten Verbindung.
#
# init_db legt genau eine Verbindung mit check_same_thread=False an. FastAPI
# fuehrt /health, /register und /prekey als `def` aus, also im Threadpool; die
# WebSocket-Seite und purge_expired laufen dagegen auf dem Event-Loop —
# nachgesehen mit set_trace_callback, das fuer die einen "AnyIO worker thread"
# meldet und fuer die anderen den Loop-Thread. Der Transaktionszustand haengt
# aber an der VERBINDUNG und nicht am Aufrufer. Ohne diese Sperre nahm der
# Rollback des einen Threads die noch nicht committete Arbeit des anderen mit,
# und das COMMIT des einen machte die halbfertige Arbeit des anderen dauerhaft.
# Beide Richtungen stehen als Test in test_relay.py:
# test_fremder_rollback_holt_den_ausgegebenen_prekey_nicht_zurueck und
# test_purge_committet_keine_halbfertige_registrierung — ohne die Sperre sind
# sie rot.
#
# KEIN await INNERHALB DER SPERRE. Gibt eine Koroutine die Kontrolle ab,
# waehrend sie die Sperre haelt, bleibt die naechste Koroutine auf demselben
# Thread in acquire() stehen — dann kommt der Loop nie zur ersten zurueck, und
# auch asyncio.wait_for greift nicht mehr, weil der Loop-Thread selbst
# blockiert. test_keine_sperre_ueber_ein_await haelt die Regel fest.
#
# Lock und nicht RLock: eine versehentlich verschachtelte Sperre soll
# auffallen. Mit RLock wuerde das innere `with db:` die aeussere Transaktion
# vorzeitig committen — genau der Fehler, den diese Sperre verhindern soll.
schreibsperre = threading.Lock()


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
    with schreibsperre, db:
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


def msg_limit_ok(user_id: str) -> bool:
    """Bremse fuer das PUFFERN, je Absender.

    Anders als otk_limit_ok, das die Zieladresse schuetzt, haengt diese Bremse
    am Absender: gepuffert wird auf seine Veranlassung, und der Empfaenger, den
    er sich aussucht, kostet ihn nichts.

    Der Eintrag heisst "msg:<adresse>". Wer _buckets einmal aufraeumt, muss die
    Frist JE FAMILIE rechnen — hier ist der Eimer nach
    MSG_CAPACITY/MSG_REFILL_PER_SEC Sekunden wieder voll, bei "otk:" dauert es
    ein Vielfaches davon. Pauschal die kuerzeste Frist zu nehmen, schenkte
    einem Angreifer nach kurzer Pause einen frischen vollen Eimer.
    """
    return _take(f"msg:{user_id}", float(MSG_CAPACITY), MSG_REFILL_PER_SEC, 1.0)


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
    # max_length wirkt VOR der Signaturpruefung und vor jedem Plattenzugriff:
    # pydantic weist ein zu grosses Bundle mit 422 ab, ohne dass der Server es
    # je verarbeitet. Siehe OTK_MAX_JE_BUENDEL.
    one_time_prekeys: list[OneTimePreKey] = Field(
        default_factory=list, max_length=OTK_MAX_JE_BUENDEL)

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
    # Ohne diese Zeile stuende der Zaehler nach einem Neustart auf 0 und
    # QUEUE_MAX_TOTAL waere wirkungslos, bis die erste Stunde um ist.
    queue_zeilen_neu_zaehlen()

    async def janitor():
        while True:
            await asyncio.sleep(3600)
            try:
                purge_expired()
                queue_zeilen_neu_zaehlen()
            except sqlite3.Error as exc:
                print(f"[!] Aufraeumen fehlgeschlagen: {exc}")

    task = asyncio.create_task(janitor())
    try:
        yield
    finally:
        task.cancel()
        # Ein Worker kann noch mitten in einer Transaktion stehen; ohne die
        # Sperre bekaeme er "Cannot operate on a closed database".
        with schreibsperre:
            db.close()


app = FastAPI(title="BitDM Relay", version="1.0", lifespan=lifespan)

connections: dict[str, WebSocket] = {}

# Ob die Verbindung hinter `connections[adresse]` den Empfangsnachweis
# beherrscht.
#
# GETRENNT GEFUEHRT, weil es der ABSENDER wissen muss, nicht der Empfaenger.
# Das Flag kommt in der Anmeldung der EMPFANGENDEN Verbindung an und lag
# bisher nur als lokale Variable in deren eigenem Aufruf; der Absender, der
# gleich entscheidet, ob er live durchreicht oder erst puffert, kam nie daran.
#
# Immer zusammen mit `connections` gesetzt und geloescht — zwei Verzeichnisse,
# die auseinanderlaufen koennen, waeren schlimmer als eines mit einem Tupel.
# Ein Tupel waere sauberer, aendert aber jede Fundstelle von `connections`.
nachweisfaehig: dict[str, bool] = {}

# Wie viele Zeilen in `queue` stehen — mitgefuehrt statt gezaehlt.
#
# WARUM NICHT EINFACH "SELECT COUNT(*) FROM queue" JE NACHRICHT: gemessen mit
# dem hier installierten SQLite 3.50.4 auf diesem Schema — 0,047 ms bei 100 000
# Zeilen, aber 2,3 ms bei 200 000, 5,0 ms bei 400 000 und 10,9 ms bei 800 000
# (der Zaehlvorgang laeuft ueber die Seiten von idx_queue_ts und wird teuer,
# sobald der Index nicht mehr in den Seitenpuffer passt). Jeder db-Aufruf in
# ws_endpoint laeuft synchron auf dem Event-Loop; diese Millisekunden treffen
# ALLE Verbindungen. Ein Riegel, der genau unter der Flut teuer wird, gegen die
# er gebaut ist, waere selbst der Angriff.
_queue_zeilen = 0


def queue_zeilen_neu_zaehlen() -> int:
    """Setzt den Zaehler gegen die Tabelle zurueck.

    Der Zaehler wird an zwei Stellen fortgeschrieben; jede davon kann
    danebenliegen, wenn eine Transaktion nicht durchgeht. Einmal je Stunde
    gegen die Wahrheit zu pruefen kostet einen Zaehlvorgang und begrenzt jeden
    Irrtum auf eine Stunde.
    """
    global _queue_zeilen
    with schreibsperre:
        _queue_zeilen = db.execute("SELECT COUNT(*) FROM queue").fetchone()[0]
    return _queue_zeilen


def queue_zeilen_aendern(delta: int) -> None:
    global _queue_zeilen
    _queue_zeilen = max(0, _queue_zeilen + delta)


@app.get("/health")
def health():
    # `queued` heisst seit dem Empfangsnachweis "wartet auf einen abwesenden
    # Empfaenger ODER auf dessen Nachweis". Der Wert liegt im Mittel etwas
    # hoeher als vorher; wer darauf eine Schwelle gesetzt hat, muss das
    # wissen.
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

    # Die Sperre liegt eine Ebene ueber `with db:` und bleibt bis hinter den
    # COUNT offen. Sonst zaehlte die Antwort einen Stand, den inzwischen ein
    # anderer Aufrufer veraendert haben kann — und der Client leitet aus dieser
    # Zahl ab, ob er Prekeys nachliefern muss.
    with schreibsperre:
        # DAS DACH, und zwar nur fuer NEUE Adressen.
        #
        # Innerhalb der Sperre, sonst kaeme zwischen Zaehlen und Einfuegen ein
        # anderer Aufrufer durch — bei einer Flut ist das kein theoretischer
        # Fall, sondern der Normalfall.
        #
        # Wer schon eingetragen ist, kommt IMMER durch: sein Bundle zu
        # erneuern belegt keinen neuen Platz, und ein volles Relay waere sonst
        # ausgerechnet fuer seine eigenen Nutzer unbenutzbar — die koennten
        # keine Prekeys mehr nachliefern und waeren nach dem Aufbrauchen des
        # Vorrats nicht mehr erreichbar.
        schon_da = db.execute(
            "SELECT 1 FROM identities WHERE user_id=?", (bundle.user_id,)
        ).fetchone() is not None
        if not schon_da:
            wie_viele = db.execute("SELECT COUNT(*) FROM identities").fetchone()[0]
            if wie_viele >= IDENTITAETEN_MAX:
                # 507, nicht 429: das ist keine Bremse, die nach einer Weile
                # nachgibt, sondern eine volle Ablage. Der Unterschied gehoert
                # in die Antwort, sonst versucht es der Client fuer immer.
                raise HTTPException(507, "Dieser Relay nimmt keine neuen "
                                         "Adressen mehr auf")
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

    # Der SELECT gehoert in dieselbe Sperre wie das DELETE darunter, damit das
    # ausgelieferte Bundle aus EINEM Zustand stammt: davor konnte er die noch
    # nicht committete Identitaet eines anderen Threads sehen.
    with schreibsperre:
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
            # Atomar ist hier nur die ANWEISUNG: DELETE ... RETURNING gibt die
            # Zeile heraus, die es selbst entfernt hat, dieselbe kann also nie
            # zweimal herausfallen. Die Transaktion darum ist eine zweite
            # Sache — sie liegt auf der geteilten Verbindung, und ohne
            # schreibsperre konnte der Rollback eines fremden Threads dieses
            # DELETE mit zuruecknehmen, waehrend der Prekey unten schon im
            # JSON stand.
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

# WOHIN der POST tatsaechlich geht. Der Client nennt die oeffentliche Adresse;
# hinaus geht sie nicht.
#
# GRUND: die Unit sperrt jede ausgehende Verbindung (IPAddressDeny=any,
# deploy/install-relay.sh). Am 12.07.2026 wurde auf genau dieser Maschine ein
# Dienst gekapert und lud einen Miner nach — diese Sperre fuer eine
# Beschleunigung aufzumachen waere der falsche Tausch. Muss sie auch nicht:
# push.bitdm.net liegt auf demselben Rechner. Ist hier eine Basis gesetzt, wird
# deshalb nur der PFAD des GEPRUEFTEN Endpunkts uebernommen und an einen
# Zuhoerer auf dem Loopback gehaengt; 127.0.0.0/8 ist in derselben Unit ohnehin
# erlaubt. Der Host aus dem Endpunkt wird bewusst nicht benutzt.
#
# LEER ist der Vorgabewert, und das ist Absicht: der Loopback-Port des
# Push-Servers steht nirgends im Baum, und eine geratene Zahl waere ein leerer
# POST an irgendeinen fremden lokalen Dienst. Solange nichts gesetzt ist,
# bleibt es beim bisherigen Verhalten (POST an den Endpunkt selbst) — das
# betrifft Relays, die hinausduerfen; auf dem gesperrten Relay scheitert es
# weiterhin, aber seit _push_ging_daneben nicht mehr stumm.
PUSH_ZIEL_BASIS = os.getenv("BITDM_PUSH_TARGET", "").rstrip("/")


def anstoss_ziel(endpunkt: str) -> str:
    """Die Adresse, an die der leere POST wirklich geht."""
    if not PUSH_ZIEL_BASIS:
        return endpunkt
    return PUSH_ZIEL_BASIS + urllib.parse.urlsplit(endpunkt).path


# Hoechstens eine Klage je Stunde, mit Zaehler.
#
# WARUM ueberhaupt eine: die alte Fassung verschluckte jeden Fehlschlag
# wortlos. Auf dem gesperrten Relay ging seit der Einfuehrung des Anstosses
# kein einziger hinaus, und nichts zeigte es an.
# WARUM gedrosselt: der Anstoss haengt an jeder gepufferten Nachricht; ein
# kaputter Push-Server wuerde das Journal im Takt des Verkehrs fluten.
# WARUM zwei Zahlen und kein Woerterbuch je Adresse: ein Eintrag je Nutzer
# waechst unbegrenzt (dieselbe Falle wie bei _buckets/_nonces) und traegt
# nichts bei — was fehlt, ist die Tatsache, dass es klemmt, nicht bei wem.
PUSH_KLAGE_ABSTAND = float(os.getenv("BITDM_PUSH_KLAGE", 3600.0))

_push_klage_zuletzt: float | None = None
_push_fehler_seither = 0


def _push_ging_daneben(grund: str) -> None:
    """Meldet, dass ein Anstoss nicht ankam — hoechstens einmal je Stunde.

    IN DER MELDUNG STEHT WEDER ADRESSE NOCH ENDPUNKT. Der Endpunkt ist eine
    dauerhafte Geraetekennung (siehe den Kommentar an der Spalte in init_db),
    die Adresse der Empfaenger — beides aufzuschreiben waere genau die
    Aufzeichnung, die deploy/README.md unter "Was NICHT protokolliert wird"
    ausschliesst.
    """
    global _push_klage_zuletzt, _push_fehler_seither
    _push_fehler_seither += 1
    jetzt = time.monotonic()
    # None und nicht 0.0 als Startwert: time.monotonic() kann kurz nach dem
    # Hochfahren nahe null liegen, dann verschluckte 0.0 die erste Meldung.
    if (_push_klage_zuletzt is not None
            and jetzt - _push_klage_zuletzt < PUSH_KLAGE_ABSTAND):
        return
    print(f"[!] Anstoss geht nicht raus ({_push_fehler_seither} "
          f"Fehlversuche seit der letzten Meldung): {grund}")
    _push_klage_zuletzt = jetzt
    _push_fehler_seither = 0


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
    # Dieser Lesezugriff steht bewusst OHNE schreibsperre da: stosse_an ist
    # async und hat unten ein await — die Sperre bis dorthin zu halten, waere
    # genau der Deadlock, vor dem der Kommentar an schreibsperre warnt.
    # Schlimmstenfalls sieht er einen Endpunkt, der gleich ueberschrieben wird;
    # daraus wird ein leerer POST an die vorige Adresse.
    row = db.execute(
        "SELECT push_endpoint FROM identities WHERE user_id=?", (user_id,)
    ).fetchone()
    if row is None or not row[0]:
        return
    try:
        async with httpx.AsyncClient(timeout=PUSH_TIMEOUT) as client:
            # NICHT follow_redirects=True. httpx folgt ab Werk nicht; ein
            # Umzug wuerde den POST sonst an einen beliebigen Host tragen und
            # den Host-Pin aus PUSH_ERLAUBTE_HOSTS aushebeln.
            antwort = await client.post(anstoss_ziel(row[0]), content=b"")
    except Exception as exc:
        # Ein Anstoss, der nicht ankommt, ist kein Fehler des Absenders — die
        # Nachricht liegt in der Warteschlange und wird beim naechsten Start
        # der App zugestellt. Gemeldet wird er trotzdem: sonst faellt ein
        # dauerhaft kaputter Push-Server niemandem auf.
        _push_ging_daneben(f"{type(exc).__name__}: {exc}")
        return
    # httpx wirft bei 4xx/5xx NICHT von sich aus. Ohne diese Zeile bliebe ein
    # antwortender, aber ablehnender Push-Server genauso unsichtbar wie vorher
    # der gesperrte Connect.
    if antwort.status_code >= 400:
        _push_ging_daneben(f"HTTP {antwort.status_code}")


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

    # Ob die Gegenseite den Empfangsnachweis beherrscht. Steht im SELBEN
    # Rahmen wie die Signatur, weil er ohnehin kommen muss und weil die
    # Antwort damit VOR der ersten Zustellung vorliegt. Wer das Feld nicht
    # kennt, bekommt unveraendert das bisherige Verhalten -- ein Server, der
    # auf einen Nachweis wartet, den ein altes Telefon nie schickt, waere
    # schlimmer als der Verlust, den das hier behebt.
    #
    # isinstance und nicht einfach reply.get: `reply` ist irgendein
    # JSON-Wert. Dass die Zeilen darueber damit durchkommen, liegt nur am
    # `except Exception` um b64d herum.
    nachweis = isinstance(reply, dict) and reply.get("empfangsnachweis") is True

    # Der Rueckspiegel ist reine Diagnose — aeltere Clients lesen aus
    # auth_result nur `ok` und ignorieren alles andere. Er macht im Test die
    # Frage "hat der Server mich verstanden" ueberhaupt beantwortbar; ein
    # neuer Client, der das Flag versehentlich nicht setzt, sieht die `q`
    # trotzdem und faellt sonst nirgends auf.
    await ws.send_json({"type": "auth_result", "ok": True,
                        "empfangsnachweis": nachweis})

    # Nur eine aktive Verbindung je Adresse: eine neue verdraengt die alte.
    old = connections.get(user_id)
    if old is not None:
        # Breit gefangen, mit Absicht: was hier schiefgeht, betrifft eine
        # Verbindung, die ohnehin endet — die NEUE darf nicht daran haengen.
        # `except RuntimeError` war zu eng. Schiebt der Server der alten
        # Verbindung gerade noch ihren Rueckstand hinterher, schreiben zwei
        # Aufgaben auf dasselbe Protokoll; was close() dann wirft, haengt
        # daran, welche WebSocket-Umsetzung uvicorn gerade gewaehlt hat
        # (websockets oder wsproto). Eine Typenliste waere an eine Fassung
        # gebunden — und jeder Wurf, der hier durchkaeme, risse die neue
        # Verbindung mit, bevor sie ueberhaupt in `connections` steht: der
        # Nutzer bliebe stumm, bis er die App neu startet.
        # asyncio.CancelledError erbt von BaseException und wird davon NICHT
        # verschluckt, ein Herunterfahren bleibt also sauber.
        try:
            await old.close(code=4409)
        except Exception:
            pass

    # AB HIER GEHOEREN EINTRAGEN UND AUFRAEUMEN ZUSAMMEN. Jeder Weg aus dieser
    # Funktion muss durch das `finally` ganz unten, sonst bleibt ein toter
    # Socket in `connections` stehen — und dann schreibt jeder Absender an
    # diese Adresse in den toten Socket, statt zu puffern: seine Nachricht ist
    # weder zugestellt noch gepuffert, sein `ack` bleibt aus, und seine eigene
    # Verbindung stirbt gleich mit. Das `try:` steht deshalb HIER und nicht
    # erst vor der Hauptschleife: die Nachzustellung ist genau die Stelle, an
    # der es reisst, weil dort der ganze Rueckstand durch den Socket geht.
    connections[user_id] = ws
    nachweisfaehig[user_id] = nachweis
    try:
        # ---- wartende Nachrichten zustellen ----
        rows = db.execute(
            "SELECT id, sender, ciphertext, ts FROM queue WHERE recipient=? ORDER BY id",
            (user_id,)
        ).fetchall()
        zugestellt: list[int] = []
        for row_id, sender, ciphertext, ts in rows:
            await ws.send_json({
                "type": "message",
                "from": sender,
                "ciphertext": b64e(ciphertext),
                "ts": ts,
                # Die Kennung der Warteschlangenzeile. Nur gepufferte
                # Nachrichten tragen sie -- live weitergereichte haben keine
                # Zeile, die man bestaetigen koennte. Sie geht auch an
                # Clients hinaus, die damit nichts anfangen: ein unbekanntes
                # Feld kostet sie nichts, und zwei Zustellwege waeren zwei
                # Gelegenheiten, einen davon falsch zu machen.
                "q": row_id,
            })
            zugestellt.append(row_id)

        # HIER LAG DER VERLUST: geloescht wurde, sobald der Rahmen im
        # Schreibpuffer stand. `send_json` wartet nur, bis der Puffer ihn
        # angenommen hat (websockets: write_frame -> transport.write ->
        # drain, und drain kehrt unterhalb der 64-KiB-Wassermarke sofort
        # zurueck). Reisst die Strecke danach ab, ist die Nachricht weg und
        # der Absender hat sein ack seit Tagen.
        #
        # Wer den Nachweis beherrscht, bekommt die Zeilen aufgehoben, bis er
        # meldet, dass sie bei ihm liegen. Meldet er nie, bleiben sie bis
        # QUEUE_TTL_SECONDS liegen und werden noch einmal zugestellt --
        # doppelt ist harmlos (die Ratchet-Schicht verwirft sie still),
        # verloren nicht.
        if zugestellt and not nachweis:
            with schreibsperre, db:
                db.executemany("DELETE FROM queue WHERE id=?",
                               [(i,) for i in zugestellt])
            queue_zeilen_aendern(-len(zugestellt))

        otk_left = db.execute(
            "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=?", (user_id,)
        ).fetchone()[0]
        if otk_left < OTK_LOW_WATERMARK:
            await ws.send_json({"type": "prekeys_low", "remaining": otk_left})

        # ---- Hauptschleife: Umschlaege weiterleiten ----
        while True:
            data = await ws.receive_json()

            # ── Empfangsnachweis ──────────────────────────────────────────
            #
            # Das Gegenstueck zum "q" oben. Der Client schickt es ERST,
            # nachdem er die Nachricht dauerhaft abgelegt hat; vorher waere
            # der Verlust nur von der Leitung in die App verschoben.
            #
            # KEINE ANTWORT DARAUF. Der Client koennte mit ihr nichts
            # anfangen: ueberlebt die Zeile, kommt sie beim naechsten
            # Verbinden noch einmal und wird dort als Doppelgaenger
            # verworfen.
            #
            # AUCH NICHT AUF msg_limit_ok GEBUCHT: die Bremse dort zaehlt
            # Nachrichten, die auf die Platte gehen. Wer viel bestaetigt, hat
            # viel bekommen -- ihn dafuer zu drosseln hiesse, ausgerechnet
            # den Nachweis zu verhindern, an dem das Loeschen haengt.
            if data.get("type") == "empfangen":
                ids = data.get("ids")
                if isinstance(ids, list):
                    # ABSCHNEIDEN VOR DEM AUFBAUEN, nicht danach.
                    #
                    # Hier stand `eigene[:QUEUE_MAX_PER_USER]` erst hinter der
                    # Listenkomposition. Die lief damit ueber die VOLLE Liste,
                    # und weil dieser Zweig ausdruecklich von jeder Bremse
                    # ausgenommen ist, war das eine offene Tuer: ein einziger
                    # Rahmen von 16 MiB (uvicorns Vorgabe) enthaelt 8,4
                    # Millionen Kennungen, der Aufbau belegte gemessen 579 MiB
                    # und blockierte den Event-Loop 2,1 s am Stueck. Die Unit
                    # hat MemoryMax=512M -- der Dienst wurde vom cgroup-OOM
                    # erschlagen und riss alle Verbindungen mit.
                    #
                    # Gemessen am 27.07.2026 von einem Widerlegungsagenten,
                    # gegen den echten ws_endpoint mit angemeldetem Client.
                    #
                    # Mehr Zeilen als QUEUE_MAX_PER_USER kann eine Adresse nie
                    # offen haben; alles darueber ist Muell und wird gar nicht
                    # erst angesehen.
                    ids = ids[:QUEUE_MAX_PER_USER]

                    # `AND recipient=?` ist nicht Sorgfalt, sondern noetig:
                    # die Kennungen sind fortlaufend und damit zu erraten.
                    # Ohne die Bedingung koennte jeder Angemeldete fremde
                    # Warteschlangen leeren. bool ist in Python ein int --
                    # deshalb die zweite Pruefung, wie schon bei der Groesse
                    # der Blob-Marke.
                    eigene = [(i, user_id) for i in ids
                              if isinstance(i, int) and not isinstance(i, bool)]
                    if eigene:
                        with schreibsperre, db:
                            cur = db.executemany(
                                "DELETE FROM queue WHERE id=? AND recipient=?",
                                eigene)
                        # rowcount summiert bei executemany ueber alle
                        # Durchlaeufe; erraten Kennungen treffen nichts und
                        # zaehlen deshalb auch nicht mit.
                        queue_zeilen_aendern(-max(0, cur.rowcount))
                continue

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
                    with schreibsperre, db:
                        db.execute(
                            "UPDATE identities SET push_endpoint=NULL WHERE user_id=?",
                            (user_id,),
                        )
                    await ws.send_json({"type": "push_ok", "set": False})
                elif push_endpunkt_gueltig(endpunkt):
                    with schreibsperre, db:
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

                # Das await bleibt AUSSERHALB der Sperre — siehe die
                # Begruendung bei schreibsperre.
                with schreibsperre, db:
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
                # KANONISIEREN, nicht nur pruefen. decode_id nimmt Leerzeichen,
                # Bindestriche und Grossschreibung an, zugestellt wird danach
                # aber woertlich: connections.get(to) unten und recipient beim
                # INSERT. Ohne diese Zeile quittiert der Server eine
                # Schreibweise, die er nie zustellen kann.
                to = encode_id(decode_id(to))
            except ValueError:
                await ws.send_json({"type": "error", "reason": "Zieladresse ungueltig", **ref})
                continue

            # Gibt es diese Adresse ueberhaupt? Ohne diese Frage nimmt die
            # Warteschlange 32 Zufallsbytes mit selbst gerechneter Pruefsumme
            # genauso an wie einen echten Empfaenger — und der Deckel darunter
            # zaehlt je Empfaenger, also nie mit.
            #
            # DAS MACHT KEIN VERZEICHNIS AUF: es gibt schon zwei, beide ohne
            # Anmeldung. GET /prekey/<adresse> antwortet 404 statt 200, und
            # /ws?user_id=<adresse> schickt sofort "erst /register aufrufen" —
            # letzteres voellig ungebremst. Wer Adressen durchprobiert, nimmt
            # den billigeren Weg. Hier zu schweigen kostete nur die
            # Ehrlichkeit des `ack`.
            if db.execute("SELECT 1 FROM identities WHERE user_id=?",
                          (to,)).fetchone() is None:
                await ws.send_json(
                    {"type": "error", "reason": "Zieladresse unbekannt", **ref})
                continue

            target = connections.get(to)
            if target is not None and nachweisfaehig.get(to):
                # ERST IN DIE WARTESCHLANGE, DANN LIVE SCHICKEN.
                #
                # Vorher ging eine live weitergereichte Nachricht ohne jede
                # Zeile hinaus, und `await target.send_json(...)` sagt nur,
                # dass der Rahmen im Schreibpuffer der ANDEREN Verbindung
                # liegt — nicht, dass er angekommen ist. Reisst deren Leitung
                # in diesem Moment, existiert die Nachricht danach nirgends
                # mehr, und der Absender hat sein `ack` bekommen.
                #
                # Das Fenster war ZEITLICH UNBEGRENZT: der Server bemerkt eine
                # still gestorbene Verbindung nie (kein Lebenszeichen, keine
                # Frist auf receive_json). Solange der tote Eintrag steht,
                # nimmt JEDER Absender an diese Adresse diesen Weg.
                # Nachgestellt am 27.07.2026 mit `transport.abort()`:
                # Absender bekam sein ack, die Warteschlange war leer, der
                # Empfaenger bekam beim Neuverbinden nichts.
                #
                # DER PREIS ist ein Schreib- und ein Loeschvorgang je
                # Nachricht auf dem heissen Weg, und QUEUE_MAX_PER_USER gilt
                # jetzt auch fuer verbundene Empfaenger. Beides ist zu
                # verkraften: ein verbundener Client bestaetigt in
                # Millisekunden, 500 unbestaetigte Nachrichten erreicht er
                # dabei nie. Eine verlorene Nachricht ist nicht zu verkraften.
                #
                # NUR fuer Gegenstellen, die den Nachweis beherrschen. Bei
                # einem alten Client bliebe die Zeile ewig liegen und seine
                # Warteschlange liefe voll — das waere schlimmer als der
                # Verlust, den es behebt. Der bekommt unveraendert den Weg
                # darunter.
                if not msg_limit_ok(user_id):
                    await ws.send_json(
                        {"type": "error", "reason": "zu viele Nachrichten",
                         "to": to, **ref})
                    continue
                if _queue_zeilen >= QUEUE_MAX_TOTAL:
                    await ws.send_json(
                        {"type": "error", "reason": "Warteschlange voll",
                         "to": to, **ref})
                    continue
                offen = db.execute(
                    "SELECT COUNT(*) FROM queue WHERE recipient=?", (to,)
                ).fetchone()[0]
                if offen >= QUEUE_MAX_PER_USER:
                    await ws.send_json(
                        {"type": "error", "reason": "Warteschlange voll",
                         "to": to, **ref})
                    continue

                with schreibsperre, db:
                    cur = db.execute(
                        "INSERT INTO queue (recipient, sender, ciphertext, ts)"
                        " VALUES (?,?,?,?)",
                        (to, user_id, ciphertext, time.time()),
                    )
                queue_zeilen_aendern(+1)
                zeile = cur.lastrowid

                # Das `q` ist der ganze Unterschied: damit weiss der
                # Empfaenger, WAS er bestaetigen soll. Ohne es koennte er die
                # Zeile nie loeschen lassen.
                await target.send_json({
                    "type": "message",
                    "from": user_id,
                    "ciphertext": raw_ct,
                    "ts": time.time(),
                    "q": zeile,
                })
                # Das `ack` an den ABSENDER heisst weiterhin "der Server hat
                # sie" — und das stimmt jetzt auch, denn sie liegt auf der
                # Platte. Ein `ack` erst nach dem Nachweis des Empfaengers
                # waere etwas anderes (eine Zustellbestaetigung) und gehoert
                # nicht hierher.
                await ws.send_json({"type": "ack", "to": to, **ref})
                continue

            if target is not None:
                # Eine Gegenstelle OHNE Empfangsnachweis. Unveraendert der
                # alte Weg, mit allem, was daran haengt: kein "q", keine
                # Zeile, und bei einem Abriss in genau diesem Moment ist die
                # Nachricht weg. Schlechter als oben, aber besser als eine
                # Warteschlange, die sich bei ihr nie leert — sie kennt den
                # Nachweis ja nicht und wuerde ihn nie schicken.
                await target.send_json({
                    "type": "message",
                    "from": user_id,
                    "ciphertext": raw_ct,
                    "ts": time.time(),
                })
                await ws.send_json({"type": "ack", "to": to, **ref})
                continue

            # Empfaenger offline -> puffern, aber gedeckelt.
            #
            # DIE BREMSE STEHT ERST HIER, nicht oben am Zweiganfang: nur dieser
            # Weg schreibt auf die Platte. Eine laufende Unterhaltung
            # (Empfaenger verbunden, der Zweig darueber) reicht nur durch und
            # bleibt unberuehrt.
            if not msg_limit_ok(user_id):
                await ws.send_json(
                    {"type": "error", "reason": "zu viele Nachrichten", "to": to, **ref})
                continue

            if _queue_zeilen >= QUEUE_MAX_TOTAL:
                # Bewusst derselbe Wortlaut wie beim Deckel je Empfaenger: der
                # Absender soll nichts Neues lernen muessen, und aeltere
                # Clients kennen diesen `reason` schon.
                await ws.send_json(
                    {"type": "error", "reason": "Warteschlange voll", "to": to, **ref})
                continue

            queued = db.execute(
                "SELECT COUNT(*) FROM queue WHERE recipient=?", (to,)
            ).fetchone()[0]
            if queued >= QUEUE_MAX_PER_USER:
                await ws.send_json({"type": "error", "reason": "Warteschlange voll", "to": to, **ref})
                continue

            # Zwischen den beiden Zaehlungen oben und diesem INSERT steht kein
            # await, und in `queue` schreibt sonst nur purge_expired — das
            # laeuft ebenfalls auf dem Event-Loop. Es kann sich also nichts
            # dazwischenschieben; die Sperre schuetzt hier gegen die Threads
            # der HTTP-Endpunkte, nicht gegen einen zweiten Absender.
            with schreibsperre, db:
                db.execute(
                    "INSERT INTO queue (recipient, sender, ciphertext, ts) VALUES (?,?,?,?)",
                    (to, user_id, ciphertext, time.time()),
                )
            # NACH dem with-Block: ein sqlite3.Error darin verlaesst die
            # Schleife ungefangen, dann darf der Zaehler nicht hochgelaufen
            # sein.
            queue_zeilen_aendern(+1)
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
            # Nur zusammen mit dem Eintrag, und nur wenn er UNS gehoert: hat
            # sich inzwischen eine neuere Verbindung derselben Adresse
            # eingetragen, wuerde ein Loeschen hier ihre Faehigkeit
            # wegnehmen — und der naechste Absender fiele fuer sie auf den
            # alten, verlustbehafteten Weg zurueck.
            nachweisfaehig.pop(user_id, None)
