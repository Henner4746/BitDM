#!/usr/bin/env python3
"""pc_postfach_probe.py — der PC als fremde Gegenstelle fuer BitDMs Nahbereich.

WOFUER
Ersetzt den ESP32-Pruefstand (Bluetooth 4.2) durch den Rechner, auf dem wir
arbeiten: der hat hier Bluetooth 5.4 (MediaTek RZ616) und sieht deshalb auch
die ERWEITERTE Werbung, in der BitDM seine Leuchtfeuer schickt — der ESP32
sah sie nie. Seit 26.09.2026; damit wurde der Fehler aus 1.8.3 gefunden und
auf einem Galaxy S25 Ultra gegengeprueft (Postfach verwarf nach 10 s Stille).

WAS ES TUT
  scan              BitDM-Werbungen in Reichweite zeigen (Leuchtfeuer, Post)
  schreib [--still N]
                    ins Postfach des Telefons schreiben — auf Wunsch erst nach
                    N Sekunden Stille. Auf dem Telefon mitlesen:
                    adb logcat -s BitDM-Funk:*   ("postfach: 16 Byte ... empfangen")

VORAUSSETZUNGEN
  py -m pip install bleak
  BitDM auf dem Telefon OFFEN und entsperrt, "Bluetooth benutzen" an.
  WICHTIG: Ist das Telefon mit dem PC GEKOPPELT (auch als LE-Geraet unter dem
  Bluetooth-Namen des Telefons), haengt Windows am alten Schluessel und jede
  Verbindung laeuft in eine Zeitueberschreitung. Kopplung entfernen.

Der Rahmen ist derselbe Buendel-Anfrage-Rahmen wie im ESP32-Pruefstand
(schreib2.txt) — genug, um den Weg bis in BitDM zu beweisen; eine echte
verschluesselte Nachricht ist das nicht.
"""
from __future__ import annotations

import argparse
import asyncio
import time

from bleak import BleakClient, BleakScanner

LEUCHTFEUER = "0000b17d-0000-1000-8000-00805f9b34fb"
POST = "0000b182-0000-1000-8000-00805f9b34fb"
PAKET = bytes.fromhex("014242000000016121631bfe72c4b801")


def _hat(adv, uuid: str) -> bool:
    return uuid in [u.lower() for u in adv.service_uuids] or uuid in {
        k.lower() for k in adv.service_data
    }


async def scan(sekunden: float) -> None:
    gesehen: dict[tuple[str, str], int] = {}

    def rueckruf(geraet, adv) -> None:
        for uuid, art in ((LEUCHTFEUER, "Leuchtfeuer"), (POST, "Postwerbung")):
            if _hat(adv, uuid) and (geraet.address, art) not in gesehen:
                daten = {k.lower(): v for k, v in adv.service_data.items()}.get(uuid, b"")
                gesehen[(geraet.address, art)] = adv.rssi
                print(f"{art:12} {geraet.address}  RSSI {adv.rssi} dBm  {len(daten)} Byte Dienstdaten")

    async with BleakScanner(rueckruf, scanning_mode="active"):
        await asyncio.sleep(sekunden)
    print(len(gesehen), "BitDM-Werbungen gesehen")


async def schreib(still: float, versuche: int) -> bool:
    for versuch in range(versuche):
        try:
            ziel = await BleakScanner.find_device_by_filter(
                lambda d, a: _hat(a, POST), timeout=12)
            if ziel is None:
                print("keine Postwerbung — ist BitDM offen und entsperrt?")
                return False
            # Frische Dienstliste: nach einem Neustart der App passt die
            # zwischengespeicherte von Windows nicht mehr.
            async with BleakClient(ziel, timeout=40, winrt={"use_cached_services": False}) as c:
                dienst = c.services.get_service(POST)
                if not (dienst and dienst.characteristics):
                    print(f"Versuch {versuch + 1}: kein Postfach im Dienstverzeichnis")
                    continue
                if still:
                    print(f"verbunden, schweige {still:.0f} s")
                    anfang = time.time()
                    while time.time() - anfang < still:
                        await asyncio.sleep(1)
                        if not c.is_connected:
                            break
                    if not c.is_connected:
                        print("  Verbindung waehrend der Stille verloren")
                        continue
                await c.write_gatt_char(dienst.characteristics[0], PAKET, response=True)
                print(f"geschrieben: {len(PAKET)} Byte, vom Telefon quittiert")
                await asyncio.sleep(1.5)
                return True
        except Exception as e:  # noqa: BLE001 — Windows-BLE wirft vieles
            print(f"Versuch {versuch + 1}: {type(e).__name__} {e}"[:120])
        await asyncio.sleep(4)
    return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    unter = p.add_subparsers(dest="befehl", required=True)
    s = unter.add_parser("scan")
    s.add_argument("--sekunden", type=float, default=12)
    w = unter.add_parser("schreib")
    w.add_argument("--still", type=float, default=0, help="Sekunden Stille vor dem Schreiben")
    w.add_argument("--versuche", type=int, default=4)
    a = p.parse_args()
    if a.befehl == "scan":
        asyncio.run(scan(a.sekunden))
        return 0
    return 0 if asyncio.run(schreib(a.still, a.versuche)) else 1


if __name__ == "__main__":
    raise SystemExit(main())
