#!/usr/bin/env python3
"""reine_verschiebung.py — belegt, dass ein Commit Code nur VERSCHIEBT.

Gate G2 der Aufteilung von main.dart (docs/MAIN-DART-AUFTEILUNG.md): Jede
hinzugefuegte Zeile ist eine entfernte Zeile, zeichengleich, und umgekehrt.
Ausgenommen sind nur Geruestzeilen:
  import / export / part / part of / library (samt show/hide-Fortsetzung),
  extension _X on _HomeState {   und die schliessende }
  der Kopfkommentar einer NEUEN Datei (die // -Zeilen vor dem ersten Code)
  Leerzeilen.

Aufruf (im Ordner secure-messenger/app oder darueber):
  python tool/reine_verschiebung.py <commit>
  python tool/reine_verschiebung.py <von>..<bis>

Ausgang 0, wenn rein verschoben; sonst 1 mit den Zeilen, die nur auf einer
Seite stehen.
"""
import collections
import re
import subprocess
import sys

GERUEST = re.compile(
    r"^(import |export |part |part of |library |extension _\w+ on _HomeState \{$|\}$"
    # Fortsetzungszeilen mehrzeiliger import-/export-Direktiven
    r"|\s+(show|hide|as|deferred) )")


def diff(bereich):
    if ".." in bereich:
        args = [bereich]
    else:
        args = [f"{bereich}^", bereich]
    return subprocess.run(
        ["git", "diff", "-U0", "--no-color", "--no-renames", *args, "--", "*.dart"],
        capture_output=True, text=True, encoding="utf-8", check=True).stdout


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    weg, neu = collections.Counter(), collections.Counter()
    neue_datei, im_kopf = False, False
    for z in diff(sys.argv[1]).split("\n"):
        if z.startswith("diff --git"):
            neue_datei, im_kopf = False, False
            continue
        if z.startswith("new file mode"):
            neue_datei, im_kopf = True, True
            continue
        if z.startswith(("---", "+++", "@@", "index ", "deleted file", "old mode", "new mode")):
            continue
        if not z or z[0] not in "+-":
            continue
        inhalt = z[1:]
        if z[0] == "+" and im_kopf:
            if inhalt.startswith("//") or not inhalt.strip():
                continue
            im_kopf = False
        if not inhalt.strip() or GERUEST.match(inhalt):
            continue
        (neu if z[0] == "+" else weg)[inhalt] += 1
    nur_neu = neu - weg
    nur_weg = weg - neu
    if not nur_neu and not nur_weg:
        print(f"rein verschoben: {sum(neu.values())} Zeilen")
        return 0
    for titel, menge in (("NUR HINZUGEFUEGT", nur_neu), ("NUR ENTFERNT", nur_weg)):
        if menge:
            print(f"{titel} ({sum(menge.values())}):")
            for zeile, n in list(menge.items())[:40]:
                print(f"  {n}x  {zeile[:140]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
