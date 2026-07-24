"""
crypto_core.py  --  Herzstueck des Messengers (Proof of Concept)
================================================================

Genau das Modell, das CREO / Session benutzen: KEINE Handynummer, KEIN Username.
Deine Identitaet IST ein kryptografischer Schluessel. Die "lange Nummer", die du
teilst, um hinzugefuegt zu werden, ist einfach dein oeffentlicher Schluessel.

Ablauf
------
1. App-Start:  Es wird EINMALIG ein X25519-Schluesselpaar erzeugt und auf dem
               Geraet gespeichert. Der private Teil verlaesst das Handy NIE.
2. Deine ID:   = dein oeffentlicher Schluessel (32 Byte), lesbar kodiert + Pruefsumme.
               Das ist die "lange Nummer" zum Weitergeben.
3. Hinzufuegen: Kontakt = du fuegst jemanden ueber SEINE ID hinzu.
4. Schreiben:  Nachricht wird Ende-zu-Ende verschluesselt.
               ECDH(mein_privat, dein_oeffentlich) -> HKDF -> 32-Byte-Schluessel
               -> AES-256-GCM (verschluesselt UND faelschungssicher).

Der Server (spaeter) sieht nur Zeichensalat. Er kann Nachrichten NICHT lesen.

Hinweis Sicherheit: Das hier ist bewusst simpel gehalten (statisches ECDH).
Fuer die echte App ist der naechste Schritt "Double Ratchet" (Signal-Protokoll)
fuer Forward Secrecy -- siehe README, Roadmap.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    PrivateFormat,
    NoEncryption,
)


# --------------------------------------------------------------------------- #
#  ID-Kodierung:  32-Byte-Schluessel  <->  lesbare "lange Nummer"
# --------------------------------------------------------------------------- #

def encode_id(public_key_bytes: bytes) -> str:
    """32-Byte-Public-Key -> lange ID mit 2-Byte-Pruefsumme (gegen Vertipper)."""
    checksum = hashlib.sha256(public_key_bytes).digest()[:2]
    raw = public_key_bytes + checksum
    # Base32 = nur A-Z2-7, gut abtippbar/vorlesbar. Kleinbuchstaben, ohne '='.
    return base64.b32encode(raw).decode("ascii").rstrip("=").lower()


def decode_id(contact_id: str) -> bytes:
    """Lange ID -> 32-Byte-Public-Key. Wirft Fehler bei kaputter Pruefsumme."""
    s = contact_id.strip().replace(" ", "").upper()
    s += "=" * ((8 - len(s) % 8) % 8)          # Base32-Padding wieder anhaengen
    raw = base64.b32decode(s)
    public_key_bytes, checksum = raw[:32], raw[32:34]
    if hashlib.sha256(public_key_bytes).digest()[:2] != checksum:
        raise ValueError("Ungueltige ID (Pruefsumme stimmt nicht -- vertippt?)")
    return public_key_bytes


def pretty_id(contact_id: str, group: int = 8) -> str:
    """Nur fuer die Anzeige: in Bloecke gruppieren, z.B. 'abcd1234 efgh5678 ...'."""
    return " ".join(contact_id[i:i + group] for i in range(0, len(contact_id), group))


# --------------------------------------------------------------------------- #
#  Identitaet:  wird einmal erzeugt und lokal gespeichert
# --------------------------------------------------------------------------- #

class Identity:
    def __init__(self, private_key: X25519PrivateKey):
        self._priv = private_key
        self._pub = private_key.public_key()

    # ---- Erzeugen / Laden / Speichern ----
    @classmethod
    def create(cls) -> "Identity":
        return cls(X25519PrivateKey.generate())

    @classmethod
    def load(cls, path: str) -> "Identity":
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        priv_bytes = base64.b64decode(data["private_key"])
        return cls(X25519PrivateKey.from_private_bytes(priv_bytes))

    def save(self, path: str) -> None:
        priv_bytes = self._priv.private_bytes(
            Encoding.Raw, PrivateFormat.Raw, NoEncryption()
        )
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"private_key": base64.b64encode(priv_bytes).decode()}, f)
        # TODO echte App: privaten Schluessel per Android Keystore / Geraete-PIN schuetzen

    # ---- oeffentliche Identitaet ----
    @property
    def public_key_bytes(self) -> bytes:
        return self._pub.public_bytes(Encoding.Raw, PublicFormat.Raw)

    @property
    def public_id(self) -> str:
        """Die 'lange Nummer', die du weitergibst, um hinzugefuegt zu werden."""
        return encode_id(self.public_key_bytes)

    # ---- gemeinsamen Schluessel mit einem Kontakt ableiten ----
    def _shared_key(self, contact_public_key_bytes: bytes) -> bytes:
        peer_pub = X25519PublicKey.from_public_bytes(contact_public_key_bytes)
        shared = self._priv.exchange(peer_pub)                 # ECDH
        return HKDF(
            algorithm=hashes.SHA256(), length=32, salt=None,
            info=b"secure-messenger v1 message key",
        ).derive(shared)


# --------------------------------------------------------------------------- #
#  Nachricht ver-/entschluesseln  (AES-256-GCM)
# --------------------------------------------------------------------------- #

def encrypt_message(sender: Identity, recipient_id: str, plaintext: str) -> str:
    """Klartext -> Base64-Token, das gefahrlos ueber den Server geschickt wird."""
    recipient_pub = decode_id(recipient_id)
    key = sender._shared_key(recipient_pub)
    nonce = os.urandom(12)                                     # pro Nachricht neu!
    # AAD bindet die Nachricht an beide Teilnehmer (verhindert Umleiten)
    aad = b"|".join(sorted([sender.public_key_bytes, recipient_pub]))
    ciphertext = AESGCM(key).encrypt(nonce, plaintext.encode("utf-8"), aad)
    return base64.b64encode(nonce + ciphertext).decode("ascii")


def decrypt_message(recipient: Identity, sender_id: str, token: str) -> str:
    """Base64-Token vom Server -> Klartext. Faelschung/Manipulation = Fehler."""
    sender_pub = decode_id(sender_id)
    key = recipient._shared_key(sender_pub)
    raw = base64.b64decode(token)
    nonce, ciphertext = raw[:12], raw[12:]
    aad = b"|".join(sorted([sender_pub, recipient.public_key_bytes]))
    plaintext = AESGCM(key).decrypt(nonce, ciphertext, aad)   # prueft auch Echtheit
    return plaintext.decode("utf-8")


# --------------------------------------------------------------------------- #
#  Demo:  Alice und Bob schreiben sich -- ohne Nummer, ohne Username
# --------------------------------------------------------------------------- #

if __name__ == "__main__":
    print("=== 1. Zwei Nutzer erzeugen (wie beim ersten App-Start) ===\n")
    alice = Identity.create()
    bob = Identity.create()

    print("Alice ID (ihre 'lange Nummer'):")
    print("   " + pretty_id(alice.public_id) + "\n")
    print("Bob ID (seine 'lange Nummer'):")
    print("   " + pretty_id(bob.public_id) + "\n")

    print("=== 2. Alice fuegt Bob ueber seine ID hinzu und schreibt ihm ===\n")
    klartext = "Hey Bob, keiner kann das hier mitlesen. 🔒👋"
    token = encrypt_message(alice, bob.public_id, klartext)
    print("Was Alice tippt :", klartext)
    print("Was der SERVER sieht (nur das!):")
    print("   " + pretty_id(token, 16) + "\n")

    print("=== 3. Bob entschluesselt mit Alice' ID ===\n")
    entschluesselt = decrypt_message(bob, alice.public_id, token)
    print("Was Bob liest    :", entschluesselt)
    print("Roundtrip ok     :", entschluesselt == klartext, "\n")

    print("=== 4. Manipulierte Nachricht wird erkannt ===\n")
    manipuliert = bytearray(base64.b64decode(token))
    manipuliert[-1] ^= 0x01                                    # ein Bit kippen
    try:
        decrypt_message(bob, alice.public_id, base64.b64encode(bytes(manipuliert)).decode())
        print("FEHLER: Manipulation NICHT erkannt (sollte nie passieren)")
    except Exception as e:
        print("Manipulation erkannt & abgelehnt:", type(e).__name__)
