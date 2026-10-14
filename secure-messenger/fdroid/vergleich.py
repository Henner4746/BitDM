"""Vergleicht zwei APKs Eintrag fuer Eintrag, ohne die Signaturdateien.

Aufruf: python3 vergleich.py a.apk b.apk
Exit 0 = alle Inhalte gleich (nur Signatur darf abweichen).
"""
import hashlib
import sys
import zipfile

SIGNATUR = ("META-INF/MANIFEST.MF",)


def ist_signatur(name: str) -> bool:
    if name in SIGNATUR:
        return True
    return name.startswith("META-INF/") and name.rsplit(".", 1)[-1].upper() in {
        "SF", "RSA", "DSA", "EC"}


def inhalt(pfad):
    with zipfile.ZipFile(pfad) as z:
        return {i.filename: (hashlib.sha256(z.read(i)).hexdigest(), i.compress_type)
                for i in z.infolist() if not ist_signatur(i.filename)}


a, b = inhalt(sys.argv[1]), inhalt(sys.argv[2])
nur_a = sorted(set(a) - set(b))
nur_b = sorted(set(b) - set(a))
anders = sorted(n for n in set(a) & set(b) if a[n][0] != b[n][0])
methode = sorted(n for n in set(a) & set(b) if a[n][1] != b[n][1])
print(f"Eintraege: {len(a)} / {len(b)}")
for titel, liste in (("nur in A", nur_a), ("nur in B", nur_b),
                     ("Inhalt verschieden", anders), ("Kompression verschieden", methode)):
    print(f"{titel}: {len(liste)}")
    for n in liste[:40]:
        print("   ", n)
sys.exit(0 if not (nur_a or nur_b or anders or methode) else 1)
