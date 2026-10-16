"""Prueft gebaute Android-Bibliotheken (ELF) und vergleicht ihre Build-IDs.

Aufruf: python3 -I elf_pruefen.py [--gleich] datei.so ...

Fuer jede Datei: Groesse, sha256, Architektur, Build-ID und die Ausrichtung
der LOAD-Segmente. Exit 1, wenn eine Datei keine Build-ID hat oder eine
64-Bit-Bibliothek nicht auf 16 KiB ausgerichtet ist (Android 15+, Seiten mit
16 KiB). Mit --gleich zusaetzlich: alle Dateien muessen dieselbe Build-ID
haben.

WOZU DIE BUILD-ID: Die Bibliothek in der APK ist nicht byte-gleich mit der,
die cargo gebaut hat — Gradle strippt Native-Bibliotheken beim Packen noch
einmal. Die Build-ID ist ein Hash, den der Linker ueber die Bibliothek bildet
und in eine eigene Notiz schreibt; das Strippen laesst sie stehen. Gleiche
Build-ID heisst: das ist die Bibliothek aus diesem Quellbau und keine
heruntergeladene.
"""
import hashlib
import struct
import sys

MASCHINEN = {40: "arm", 183: "aarch64", 62: "x86_64", 3: "x86"}
PT_LOAD, PT_NOTE = 1, 4
NT_GNU_BUILD_ID = 3


def lies(pfad):
    with open(pfad, "rb") as f:
        daten = f.read()
    if daten[:4] != b"\x7fELF":
        raise ValueError("keine ELF-Datei")
    bits = {1: 32, 2: 64}[daten[4]]
    ende = {1: "<", 2: ">"}[daten[5]]
    maschine = struct.unpack_from(ende + "H", daten, 18)[0]
    if bits == 64:
        phoff = struct.unpack_from(ende + "Q", daten, 32)[0]
        phentsize, phnum = struct.unpack_from(ende + "HH", daten, 54)
    else:
        phoff = struct.unpack_from(ende + "I", daten, 28)[0]
        phentsize, phnum = struct.unpack_from(ende + "HH", daten, 42)

    ausrichtung, build_id = [], None
    for i in range(phnum):
        kopf = phoff + i * phentsize
        if bits == 64:
            typ, _, offset, _, _, groesse, _, align = struct.unpack_from(
                ende + "IIQQQQQQ", daten, kopf)
        else:
            typ, offset, _, _, groesse, _, _, align = struct.unpack_from(
                ende + "IIIIIIII", daten, kopf)
        if typ == PT_LOAD:
            ausrichtung.append(align)
        elif typ == PT_NOTE:
            pos, schluss = offset, offset + groesse
            while pos + 12 <= schluss:
                namesz, descsz, ntyp = struct.unpack_from(ende + "III", daten, pos)
                name_pos = pos + 12
                desc_pos = name_pos + ((namesz + 3) & ~3)
                name = daten[name_pos:name_pos + namesz]
                if ntyp == NT_GNU_BUILD_ID and name == b"GNU\x00":
                    build_id = daten[desc_pos:desc_pos + descsz].hex()
                pos = desc_pos + ((descsz + 3) & ~3)
    return {
        "groesse": len(daten),
        "sha256": hashlib.sha256(daten).hexdigest(),
        "bits": bits,
        "maschine": MASCHINEN.get(maschine, str(maschine)),
        "ausrichtung": min(ausrichtung) if ausrichtung else 0,
        "build_id": build_id,
    }


def main(argv):
    gleich = "--gleich" in argv
    dateien = [a for a in argv if a != "--gleich"]
    if not dateien:
        print(__doc__)
        return 2
    fehler, ids = [], set()
    for pfad in dateien:
        try:
            e = lies(pfad)
        except (OSError, ValueError, KeyError, struct.error) as grund:
            fehler.append(f"{pfad}: {grund}")
            continue
        print(f"{pfad}\n    {e['groesse']} Byte, sha256 {e['sha256']}\n"
              f"    {e['maschine']} ({e['bits']} Bit), LOAD-Ausrichtung "
              f"{e['ausrichtung']:#x}, Build-ID {e['build_id']}")
        if not e["build_id"]:
            fehler.append(f"{pfad}: keine Build-ID")
        if e["bits"] == 64 and e["ausrichtung"] < 0x4000:
            fehler.append(f"{pfad}: nicht auf 16 KiB ausgerichtet")
        ids.add(e["build_id"])
    if gleich and len(ids) != 1:
        fehler.append(f"verschiedene Build-IDs: {sorted(map(str, ids))}")
    for f in fehler:
        print("FEHLER:", f, file=sys.stderr)
    return 1 if fehler else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
