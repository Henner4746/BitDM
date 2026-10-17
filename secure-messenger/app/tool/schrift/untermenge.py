# -*- coding: utf-8 -*-
"""Die zwei Ersatzschriften der Oberflaeche neu schneiden.

WOZU. Chivo Mono, Doto und die Roboto des Browsers haben keine Glyphen fuer
die Zeichen, die die App selbst setzt: ✓ ◷ (Zustellstatus), ★ (Filter, Stern
an der Nachricht), ● ○ ◌ ◍ ◎ (Chiffre der Material-Themen), ⇉ ≡ ∿ → ≈. Im
Browser holte die Flutter-Engine sie deshalb zur Laufzeit nach, und wo die
Datei fehlte, versuchte sie es bei jedem neuen Layout erneut (16.10.2026: im
offenen Chat alle zwei Sekunden eine 404). Diese Untermengen liegen in der App
selbst und stehen in `symbolSchriften` (lib/themen.dart) als
fontFamilyFallback.

NUR DIESE ZEICHEN, KEINE EMOJI. ❤ und 👍 gaebe es in Noto Sans Symbols 2 auch,
aber eine Ersatzschrift kommt vor den Emoji des Systems: die Reaktionen waeren
dann auf Android schwarz-weiss statt bunt.

Aufruf (fonttools ist nur hierfuer noetig, nicht fuer den Bau der App):

    py -m pip install fonttools
    py tool/schrift/untermenge.py <ordner mit den zwei Quelldateien>

Quellen, beide SIL OFL 1.1, ohne reservierte Namen (17.10.2026):

    github.com/google/fonts/raw/main/ofl/notosanssymbols2/NotoSansSymbols2-Regular.ttf
      Version 2.008, SHA-256 7d5fb73b7ca67a6798101741f5d280a3d016a56a197afcd4199dbb57b4b82a21
    github.com/google/fonts/raw/main/ofl/notosansmath/NotoSansMath-Regular.ttf
      Version 3.000, SHA-256 3f495fe933c06786e4d5f6d86b8ee70b6753a68ee3b9d87528726de0f6e2c47d

Kommt ein Zeichen dazu: hier eintragen, neu schneiden, und
test/oberflaeche/schriftzeichen_test.dart wird wieder gruen.
"""
import hashlib
import pathlib
import sys

from fontTools import subset

APP = pathlib.Path(__file__).resolve().parents[2]

SCHNITTE = [
    # (Quelle, erwartete SHA-256, Ziel, Zeichen)
    ('NotoSansSymbols2-Regular.ttf',
     '7d5fb73b7ca67a6798101741f5d280a3d016a56a197afcd4199dbb57b4b82a21',
     'NotoSansSymbols2-BitDM.ttf',
     '✓◷★●○◌◍◎'),
    ('NotoSansMath-Regular.ttf',
     '3f495fe933c06786e4d5f6d86b8ee70b6753a68ee3b9d87528726de0f6e2c47d',
     'NotoSansMath-BitDM.ttf',
     '⇉≡∿→≈'),
]


def schneide(quelle: pathlib.Path, ziel: pathlib.Path, zeichen: str) -> None:
    opt = subset.Options()
    # Copyright (0) und Lizenz (13, 14) muessen mit: die OFL verlangt, dass
    # der Hinweis jede veraenderte Fassung begleitet.
    opt.name_IDs = ['*']
    opt.name_languages = ['*']
    opt.name_legacy = True
    opt.notdef_outline = True
    # Die Formelsatz-Tabelle braucht hier niemand, sie waere der groesste Teil.
    opt.drop_tables += ['MATH']
    # Die TrueType-Hinting-Programme machten zwei Drittel der Datei aus. Skia
    # rendert Flutter-Text mit leichtem Hinting und fragt sie nicht ab.
    opt.hinting = False
    schrift = subset.load_font(str(quelle), opt)
    s = subset.Subsetter(opt)
    s.populate(unicodes=[ord(z) for z in zeichen])
    s.subset(schrift)
    subset.save_font(schrift, str(ziel), opt)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    ordner = pathlib.Path(sys.argv[1])
    for name, sha, ziel, zeichen in SCHNITTE:
        quelle = ordner / name
        ist = hashlib.sha256(quelle.read_bytes()).hexdigest()
        if ist != sha:
            print(f'ACHTUNG {name}: andere Fassung als beim letzten Schnitt '
                  f'({ist}). Ergebnis pruefen, SHA-256 hier nachtragen.')
        pfad = APP / 'assets' / 'fonts' / ziel
        schneide(quelle, pfad, zeichen)
        print(f'{pfad.relative_to(APP)}: {pfad.stat().st_size} Bytes, {zeichen}')


if __name__ == '__main__':
    main()
