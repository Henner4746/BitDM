"""Stueckliste (SBOM) der Dart-Pakete aus pubspec.lock, als CycloneDX 1.5 JSON.

Aufruf (aus secure-messenger/app):
    python3 tool/sbom_pub.py pubspec.lock sbom-pub.cdx.json

WOZU: Snyk prueft Dart-Pakete nicht direkt (`snyk test` kennt pub nicht), wohl
aber eine Stueckliste mit Kennungen `pkg:pub/<name>@<fassung>`
(`snyk sbom test --experimental`). Der in der Snyk-Doku genannte Weg ueber das
Dart-Paket `sbom` hiesse, im Pruefschritt ein weiteres Fremdpaket auszufuehren;
pubspec.lock enthaelt ohnehin alles Noetige. Darum dieses Skript, ohne
Abhaengigkeiten: es liest das feste Format von pubspec.lock zeilenweise.

Aufgenommen werden Pakete mit `source: hosted` (pub.dev). SDK-Pakete
(flutter, flutter_test ...) haben keine pub-Fassung, Pfad- und Git-Pakete
keine Kennung bei pub.dev; sie werden gezaehlt und gemeldet, nicht verschwiegen.
"""
import json
import sys
import uuid
from datetime import datetime, timezone


def lies_lock(pfad):
    pakete, aktuell, im_block = {}, None, False
    for zeile in open(pfad, encoding="utf-8"):
        roh = zeile.rstrip("\n")
        if roh.startswith("packages:"):
            im_block = True
            continue
        if im_block and roh and not roh.startswith(" "):
            break  # naechster Abschnitt (sdks:)
        if not im_block or not roh.strip():
            continue
        einzug = len(roh) - len(roh.lstrip(" "))
        text = roh.strip()
        if einzug == 2 and text.endswith(":"):
            aktuell = text[:-1].strip('"')
            pakete[aktuell] = {}
        elif einzug == 4 and aktuell and ":" in text:
            schluessel, wert = text.split(":", 1)
            pakete[aktuell][schluessel.strip()] = wert.strip().strip('"')
    return pakete


def main(lock, ziel):
    pakete = lies_lock(lock)
    komponenten, ausgelassen = [], {}
    for name in sorted(pakete):
        p = pakete[name]
        quelle, fassung = p.get("source"), p.get("version")
        if quelle != "hosted" or not fassung:
            ausgelassen[quelle or "?"] = ausgelassen.get(quelle or "?", 0) + 1
            continue
        purl = f"pkg:pub/{name}@{fassung}"
        komponenten.append({
            "type": "library",
            "bom-ref": purl,
            "name": name,
            "version": fassung,
            "purl": purl,
            "scope": "required" if p.get("dependency", "").startswith("direct") else "optional",
        })
    if not komponenten:
        print("keine gehosteten Pakete in", lock, file=sys.stderr)
        return 1
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {"type": "application", "name": "bitdm", "bom-ref": "bitdm"},
            "tools": {"components": [{"type": "application", "name": "sbom_pub.py"}]},
        },
        "components": komponenten,
        "dependencies": [{"ref": "bitdm", "dependsOn": [k["bom-ref"] for k in komponenten]}],
    }
    with open(ziel, "w", encoding="utf-8") as f:
        json.dump(sbom, f, indent=2)
    rest = ", ".join(f"{n} {q}" for q, n in sorted(ausgelassen.items())) or "keine"
    print(f"{len(komponenten)} Pakete von pub.dev nach {ziel}; ausgelassen: {rest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
