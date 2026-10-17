"""Erzeugt die Vergleichswerte fuer app/test/net/geraeteliste_test.dart.

Die App muss Geraetelisten und Beitrittsanfragen Zeichen fuer Zeichen so
schreiben, wie dieser Server sie liest (relay_server.lies_liste,
lies_beitritt), und Signaturen annehmen, die mit derselben XEdDSA entstanden
sind, mit der der Server prueft. Ein Dart-Test, der beides selbst in Dart
ausrechnet, bliebe auch dann gruen, wenn beide Seiten dieselbe falsche Annahme
treffen. Deshalb kommen die Werte aus einem Lauf DIESES Servers.

Aufruf aus secure-messenger/server:

    py -3 tools/write_geraeteliste_fixtures.py

Die Schluessel sind fest (aus SHA-256 fester Woerter), die Signaturen nicht
zwingend: die Datei darf sich bei einem neuen Lauf in den Signaturen aendern,
nie in den kanonischen Zeichenketten.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from xeddsa.bindings import (ed25519_priv_sign, priv_force_sign,  # noqa: E402
                             priv_to_curve25519_pub)

import relay_server as rs  # noqa: E402

ZIEL = Path(__file__).resolve().parents[2] / "app" / "test" / "net" / "geraeteliste_fixtures.json"


def schluessel(wort: str) -> tuple[bytes, bytes]:
    priv = hashlib.sha256(wort.encode()).digest()
    return priv, priv_to_curve25519_pub(priv)


def sign(priv: bytes, msg: bytes) -> bytes:
    return ed25519_priv_sign(priv_force_sign(priv, False), msg)


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def liste(ik_priv, adresse, epoche, geraete, unterzeichner, signer_gs, zeit):
    roh = rs.kanonisch({
        "adresse": adresse, "epoche": epoche,
        "geraete": [[k, b64(pub), info] for k, (pub, info) in sorted(geraete.items())],
        "unterzeichner": unterzeichner, "v": 1, "zeit": zeit})
    nachricht = rs.LISTE_PRAEFIX + roh.encode()
    antwort = {"liste": roh, "sig_identitaet": b64(sign(ik_priv, nachricht)),
               "sig_geraet": b64(sign(signer_gs, nachricht))}
    # Gegenprobe mit dem Server selbst: was er nicht liest, gehoert nicht in
    # die Vergleichswerte.
    rs.lies_liste(antwort["liste"], antwort["sig_identitaet"], antwort["sig_geraet"])
    return antwort


def main() -> None:
    ik_priv, ik_pub = schluessel("bitdm-fixture-identitaet")
    adresse = rs.encode_id(ik_pub)
    gs1_priv, gs1 = schluessel("bitdm-fixture-geraet-1")
    gs2_priv, gs2 = schluessel("bitdm-fixture-geraet-37")
    info = b64(b"kein echter Name, nur Rauschen fuer den Test")

    a = liste(ik_priv, adresse, 1, {1: (gs1, "")}, 1, gs1_priv, 1760700000)
    b = liste(ik_priv, adresse, 2, {1: (gs1, ""), 37: (gs2, info)}, 1, gs1_priv,
              1760700100)
    # Selbstabmeldung: der Unterzeichner (37) steht nicht mehr darin.
    c = liste(ik_priv, adresse, 3, {1: (gs1, "")}, 37, gs2_priv, 1760700200)

    code = bytes(range(1, 11))
    nachweis = hmac.new(
        code, f"BitDM-Beitritt-Nachweis-v1\n{adresse}\n37\n{b64(gs2)}".encode(),
        hashlib.sha256).digest()
    anfrage = rs.kanonisch({
        "adresse": adresse, "device_id": 37, "info": info,
        "nachweis": b64(nachweis), "schluessel": b64(gs2), "v": 1,
        "zeit": 1760700050})
    nachricht = rs.BEITRITT_PRAEFIX + anfrage.encode()
    beitritt = {"anfrage": anfrage, "sig_identitaet": b64(sign(ik_priv, nachricht)),
                "sig_geraet": b64(sign(gs2_priv, nachricht))}
    rs.lies_beitritt(beitritt["anfrage"], beitritt["sig_identitaet"],
                     beitritt["sig_geraet"])

    daten = {
        "_hinweis": "Erzeugt von server/tools/write_geraeteliste_fixtures.py",
        "adresse": adresse,
        "geraet_1": b64(gs1),
        "geraet_37": b64(gs2),
        "info_37": info,
        "liste_1": a,
        "liste_2_mitglied_fuegt_hinzu": b,
        "liste_3_selbst_abgemeldet": c,
        "beitritt": beitritt,
        "beitritt_code": b64(code),
        # Wie der Code angezeigt wird: Base32 nach RFC 4648, vier Gruppen.
        "beitritt_code_angezeigt": "-".join(
            base64.b32encode(code).decode()[i:i + 4] for i in range(0, 16, 4)),
        "nachweis": b64(nachweis),
    }
    ZIEL.write_text(json.dumps(daten, indent=2, ensure_ascii=True) + "\n",
                    encoding="utf-8")
    print(f"geschrieben: {ZIEL}")


if __name__ == "__main__":
    main()
