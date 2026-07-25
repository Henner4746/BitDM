"""Erzeugt die Vergleichswerte fuer test/net/relay_protocol_test.dart.

Der Dart-Client muss die Bytes des Besitznachweises zeichengenau so bilden wie
dieser Server. Ein Dart-Test, der die Erwartung selbst in Dart ausrechnet,
wuerde dieselbe Annahme treffen wie der geprueften Code und auch dann gruen
bleiben, wenn beide falsch liegen. Deshalb kommen die Vergleichswerte aus einem
echten Lauf DIESES Servers.

Aufruf aus dem Verzeichnis secure-messenger/server:

    py -3 tools/write_canonical_fixtures.py
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from relay_server import OneTimePreKey, PreKeyBundle  # noqa: E402

ZIEL = Path(__file__).resolve().parents[2] / "app" / "test" / "net" / "canonical_fixtures.json"


def faelle() -> list[tuple[str, PreKeyBundle]]:
    return [
        ("ohne Prekeys", PreKeyBundle(
            user_id="a" * 56, identity_key="SWRLZXk=", registration_id=1234, signed_prekey_id=1,
            signed_prekey="U1BL", signed_prekey_sig="U2ln", one_time_prekeys=[])),

        ("ein Prekey", PreKeyBundle(
            user_id="b" * 56, identity_key="SWRLZXky", registration_id=1, signed_prekey_id=42,
            signed_prekey="U1BLMg==", signed_prekey_sig="U2lnMg==",
            one_time_prekeys=[OneTimePreKey(key_id=7, public_key="T1RLNw==")])),

        # Wichtigster Fall: der Server sortiert die Prekeys, bevor er signiert.
        # Ein Client, der sie in Eingabereihenfolge laesst, bekaeme je nach
        # Zufall eine abgelehnte Anmeldung.
        ("Prekeys VERKEHRT herum uebergeben", PreKeyBundle(
            user_id="c" * 56, identity_key="a2V5Mw==", registration_id=16380, signed_prekey_id=999,
            signed_prekey="c3Ay", signed_prekey_sig="c2lnMw==",
            one_time_prekeys=[
                OneTimePreKey(key_id=30, public_key="ZHJlaXNzaWc="),
                OneTimePreKey(key_id=2, public_key="endlaQ=="),
                OneTimePreKey(key_id=11, public_key="ZWxm"),
            ])),

        # Echte Laengen: 32-Byte-Identitaet, 33-Byte-Prekeys mit Typ-Byte,
        # 64-Byte-Signatur. Faengt Fehler ab, die nur bei bestimmten
        # Base64-Fuellzeichen auftreten.
        ("grosse Zahlen und volle Base64-Laengen", PreKeyBundle(
            user_id="d" * 56,
            identity_key=base64.b64encode(bytes(range(32))).decode(),
            registration_id=0,
            signed_prekey_id=16777215,
            signed_prekey=base64.b64encode(bytes([5] + list(range(32)))).decode(),
            signed_prekey_sig=base64.b64encode(bytes(range(64))).decode(),
            one_time_prekeys=[
                OneTimePreKey(key_id=i,
                              public_key=base64.b64encode(bytes([5] + [i] * 32)).decode())
                for i in (100, 1, 50)
            ])),
    ]


def main() -> None:
    raus = []
    for name, bundle in faelle():
        cb = bundle.canonical_bytes()
        raus.append({
            "name": name,
            "bundle": json.loads(bundle.model_dump_json()),
            "canonical": cb.decode(),
            "sha256_b64": base64.b64encode(hashlib.sha256(cb).digest()).decode(),
        })

    ZIEL.parent.mkdir(parents=True, exist_ok=True)
    ZIEL.write_text(json.dumps(raus, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(raus)} Vergleichswerte -> {ZIEL}")


if __name__ == "__main__":
    main()
