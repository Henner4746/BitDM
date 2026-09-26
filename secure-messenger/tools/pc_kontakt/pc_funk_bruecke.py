#!/usr/bin/env python3
"""pc_funk_bruecke.py — das Funkgeraet des PC-Kontakts (Windows, Bluetooth LE).

WOFUER
Das Gegenstueck zu NahfunkKanal.kt fuer den Rechner. Seit 26.09.2026: damit
wird der PC zu einem ECHTEN BitDM-Kontakt (Dart-Kern mit Signal, siehe
pc_kontakt_test.dart) und die zweite Richtung des Nahbereichs pruefbar — das
Telefon schickt von sich aus eine verschluesselte Nachricht per Bluetooth.

WIE BEIM KOTLIN-TEIL: DUMM. Hier wird nichts gerechnet, nichts entschluesselt,
nichts zusammengesetzt. Leuchtfeuer kommen fertig aus Dart, Stuecke gehen roh
nach Dart zurueck (dort sammelt der Sammler aus stueckelung.dart).

WIE WINDOWS WIRBT — UND WARUM ANDERS ALS ANDROID
Android wirbt mit EINER verbindbaren erweiterten Werbung: Kennung B17D und 120
Byte Leuchtfeuer. Windows kann erweiterte Werbung nur NICHT verbindbar. Das
Telefon verbindet sich aber genau mit der Adresse, von der es das Leuchtfeuer
sah. Deshalb hier ein verbindbarer GATT-Dienst mit der Kennung B17D, dessen
KLASSISCHE Werbung die Leuchtfeuer als Dienstdaten traegt (hoechstens drei,
18 Byte — der PC hat einen Kontakt). Das Telefon sucht mit setLegacy(false)
und sieht auch klassische Werbung. Verbindet es sich, findet es daneben den
zweiten Dienst B182 mit dem Postfach B183 — auf demselben Geraet.

PROTOKOLL (eine JSON-Zeile je Nachricht)
  stdin:  {"c":"werbe","lf":[hex,...]} | {"c":"werbeAus"} | {"c":"postfach"}
          {"c":"postfachZu"} | {"c":"suche"} | {"c":"sucheAus"} | {"c":"aus"}
          {"c":"sende","id":n,"geraet":"AA:BB:..","stuecke":[hex,...]}
  stdout: {"e":"bereit"} | {"e":"log","t":..}
          {"e":"gesehen","geraet":..,"rssi":..,"lf":[hex,...]}
          {"e":"stueck","geraet":..,"daten":hex}
          {"e":"antwort","id":n,"ok":bool,"code":..,"grund":..}
"""
from __future__ import annotations

import asyncio
import json
import re
import sys
import threading
import time

from bleak import BleakClient, BleakScanner
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattCharacteristicProperties,
    GattLocalCharacteristicParameters,
    GattProtectionLevel,
    GattServiceProvider,
    GattServiceProviderAdvertisingParameters,
    GattWriteOption,
)
from uuid import UUID as Guid  # pywinrt 3: GUIDs sind uuid.UUID
from winrt.windows.storage.streams import DataReader, DataWriter

LEUCHTFEUER = "0000b17d-0000-1000-8000-00805f9b34fb"
POST = "0000b182-0000-1000-8000-00805f9b34fb"
POSTFACH = "0000b183-0000-1000-8000-00805f9b34fb"
LF_BYTES = 6
LF_MAX = 2  # gemessen: 2 passen neben der Postfach-Werbung, bei 3 fehlen Daten (Status 4)

_ausgabe = threading.Lock()


def melde(**felder) -> None:
    with _ausgabe:
        sys.stdout.write(json.dumps(felder) + "\n")
        sys.stdout.flush()


def log(text: str) -> None:
    melde(e="log", t=text)


def puffer(daten: bytes):
    w = DataWriter()
    w.write_bytes(bytes(daten))
    return w.detach_buffer()


def aus_puffer(buf) -> bytes:
    try:
        return bytes(buf)
    except TypeError:
        r = DataReader.from_buffer(buf)
        ziel = bytearray(buf.length)
        r.read_bytes(ziel)
        return bytes(ziel)


def _halt(anbieter) -> None:
    # StopAdvertising wirft, wenn gar nicht geworben wird — beim Aufraeumen
    # ist das kein Fehler.
    try:
        anbieter.stop_advertising()
    except OSError:
        pass


def adresse_aus_sitzung(device_id: str) -> str:
    # "BluetoothLE#BluetoothLEac:f2:3c:d8:54:56-4c:23:a4:8c:aa:72" -> Gegenseite
    treffer = re.findall(r"([0-9a-f]{2}(?::[0-9a-f]{2}){5})", device_id.lower())
    return treffer[-1].upper() if treffer else device_id


class Bruecke:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.leucht: GattServiceProvider | None = None
        self.post: GattServiceProvider | None = None
        self.scanner: BleakScanner | None = None
        self.zuletzt_gesehen: dict[str, float] = {}
        self.sendesperre = asyncio.Lock()

    # ── Werben ────────────────────────────────────────────────────────────
    async def werbe(self, leuchtfeuer: list[bytes]) -> None:
        if self.leucht is None:
            r = await GattServiceProvider.create_async(Guid(LEUCHTFEUER))
            self.leucht = r.service_provider
        else:
            _halt(self.leucht)
        daten = b"".join(leuchtfeuer[:LF_MAX])
        p = GattServiceProviderAdvertisingParameters()
        p.is_connectable = True
        p.is_discoverable = True
        p.service_data = puffer(daten)
        self.leucht.start_advertising_with_parameters(p)
        # Der Status steht erst nach einem Moment fest (anfangs kurz 3).
        # 2 = laeuft, 4 = laeuft OHNE alle Daten (Leuchtfeuer passten nicht).
        await asyncio.sleep(1)
        log(f"wirbt mit {len(daten) // LF_BYTES} Leuchtfeuer, Status {int(self.leucht.advertisement_status)}")

    def werbe_aus(self) -> None:
        if self.leucht is not None:
            _halt(self.leucht)

    # ── Postfach ──────────────────────────────────────────────────────────
    async def postfach(self) -> None:
        if self.post is not None:
            return
        r = await GattServiceProvider.create_async(Guid(POST))
        self.post = r.service_provider
        par = GattLocalCharacteristicParameters()
        par.characteristic_properties = (
            GattCharacteristicProperties.WRITE | GattCharacteristicProperties.WRITE_WITHOUT_RESPONSE)
        par.write_protection_level = GattProtectionLevel.PLAIN
        cr = await self.post.service.create_characteristic_async(Guid(POSTFACH), par)
        merkmal = cr.characteristic
        merkmal.add_write_requested(self._schreibanfrage)
        p = GattServiceProviderAdvertisingParameters()
        p.is_connectable = True
        p.is_discoverable = True
        self.post.start_advertising_with_parameters(p)
        await asyncio.sleep(1)
        log(f"Postfach offen, Status {int(self.post.advertisement_status)}")

    def _schreibanfrage(self, sender, args) -> None:
        # Laeuft auf einem WinRT-Faden. Aufschub holen, Rest in der Schleife.
        aufschub = args.get_deferral()
        asyncio.run_coroutine_threadsafe(self._nimm(args, aufschub), self.loop)

    async def _nimm(self, args, aufschub) -> None:
        try:
            anfrage = await args.get_request_async()
            daten = aus_puffer(anfrage.value)
            wer = adresse_aus_sitzung(args.session.device_id.id)
            if anfrage.option == GattWriteOption.WRITE_WITH_RESPONSE:
                anfrage.respond()
            melde(e="stueck", geraet=wer, daten=daten.hex())
        except Exception as e:  # noqa: BLE001
            log(f"Schreibanfrage gescheitert: {type(e).__name__} {e}")
        finally:
            aufschub.complete()

    def postfach_zu(self) -> None:
        if self.post is not None:
            _halt(self.post)
            self.post = None

    # ── Suchen ────────────────────────────────────────────────────────────
    def _sah(self, geraet, adv) -> None:
        daten = {k.lower(): v for k, v in adv.service_data.items()}.get(LEUCHTFEUER)
        if not daten or len(daten) < LF_BYTES:
            return
        jetzt = time.time()
        if jetzt - self.zuletzt_gesehen.get(geraet.address, 0) < 1.5:
            return
        self.zuletzt_gesehen[geraet.address] = jetzt
        lf = [daten[i:i + LF_BYTES].hex() for i in range(0, len(daten) - LF_BYTES + 1, LF_BYTES)]
        melde(e="gesehen", geraet=geraet.address, rssi=adv.rssi, lf=lf)

    async def suche(self) -> None:
        if self.scanner is None:
            self.scanner = BleakScanner(self._sah, scanning_mode="active")
            await self.scanner.start()
            log("sucht")

    async def suche_aus(self) -> None:
        if self.scanner is not None:
            await self.scanner.stop()
            self.scanner = None

    # ── Senden ────────────────────────────────────────────────────────────
    async def sende(self, nummer: int, geraet: str, stuecke: list[bytes]) -> None:
        async with self.sendesperre:
            # Waehrend einer Verbindung nicht suchen: Windows teilt das Funkteil,
            # und der Aufbau laeuft sonst oft in die Zeitgrenze.
            suchte = self.scanner is not None
            await self.suche_aus()
            try:
                await self._sende(nummer, geraet, stuecke)
            finally:
                if suchte:
                    await self.suche()

    async def _sende(self, nummer: int, geraet: str, stuecke: list[bytes]) -> None:
        letzter = "unbekannt"
        for versuch in range(3):
            geschrieben = False
            try:
                async with BleakClient(geraet, timeout=25, winrt={"use_cached_services": False}) as c:
                    dienst = c.services.get_service(POST)
                    if not (dienst and dienst.characteristics):
                        melde(e="antwort", id=nummer, ok=False, code="VOR_SENDEN",
                              grund="kein Postfach auf der Gegenseite")
                        return
                    passt = c.mtu_size - 3
                    if max(len(s) for s in stuecke) > passt:
                        # Wie NahfunkKanal.kt: die nutzbare Groesse melden,
                        # Dart zerlegt neu.
                        melde(e="antwort", id=nummer, ok=False, code="FUNK", grund=f"ZU_GROSS:{passt}")
                        return
                    for s in stuecke:
                        geschrieben = True
                        await c.write_gatt_char(dienst.characteristics[0], s, response=True)
                melde(e="antwort", id=nummer, ok=True)
                return
            except Exception as e:  # noqa: BLE001
                letzter = f"{type(e).__name__} {e}"[:160]
                if geschrieben:
                    break  # mitten in der Sendung: mehrdeutig, nicht wiederholen
                await asyncio.sleep(2)
        melde(e="antwort", id=nummer, ok=False, code="FUNK" if geschrieben else "VOR_SENDEN", grund=letzter)

    async def aus(self) -> None:
        self.werbe_aus()
        self.postfach_zu()
        await self.suche_aus()


async def hauptschleife() -> None:
    loop = asyncio.get_running_loop()
    b = Bruecke(loop)
    befehle: asyncio.Queue[str | None] = asyncio.Queue()

    def lies_stdin() -> None:
        for zeile in sys.stdin:
            loop.call_soon_threadsafe(befehle.put_nowait, zeile)
        loop.call_soon_threadsafe(befehle.put_nowait, None)

    threading.Thread(target=lies_stdin, daemon=True).start()
    melde(e="bereit")
    while True:
        zeile = await befehle.get()
        if zeile is None:
            await b.aus()
            return
        try:
            m = json.loads(zeile)
            c = m.get("c")
            if c == "werbe":
                await b.werbe([bytes.fromhex(x) for x in m.get("lf", [])])
            elif c == "werbeAus":
                b.werbe_aus()
            elif c == "postfach":
                await b.postfach()
            elif c == "postfachZu":
                b.postfach_zu()
            elif c == "suche":
                await b.suche()
            elif c == "sucheAus":
                await b.suche_aus()
            elif c == "sende":
                asyncio.create_task(b.sende(int(m["id"]), m["geraet"],
                                            [bytes.fromhex(x) for x in m["stuecke"]]))
            elif c == "aus":
                await b.aus()
        except Exception as e:  # noqa: BLE001
            log(f"Befehl {zeile.strip()[:60]} gescheitert: {type(e).__name__} {e}")


if __name__ == "__main__":
    asyncio.run(hauptschleife())
