# -*- coding: utf-8 -*-
"""Das BitDM-Zeichen seit 24.10.2026: Entwurf F1, "Anzeigefenster".

Ein Displayfenster auf der Geraetefront, darin eine Punktmatrix. Die meisten
Punkte sind aus, DM leuchtet. Henrik hat es aus sechs Entwuerfen gewaehlt; es
loest die Sprechblase mit dem B ab (65fd2dc), die schwarz-weiss war, das
Violett der App nicht kannte und neben dem Favicon (fuenf Punkte) ein zweites
Zeichen war.

ALLES STEHT IM 108er RASTER, dem Mass eines Android-Symbols. Daraus rechnen
Pixelbilder und SVG dieselbe Form, damit es nur EINE Vorlage gibt.

ZWEI FASSUNGEN, wie schon beim alten Zeichen gemessen: unter 48 Pixeln werden
Fensterrahmen (1,5 Einheiten) und die unbeleuchteten Punkte zu grauem Brei, bei
16 Pixeln waere ein Punkt 0,7 Pixel breit. Darum bis 32 Pixel `klein`: dasselbe
DM, ohne Fenster und Raster, die Punkte so gross, dass sie fast aneinander
stossen. Das bleibt bei 16 Pixeln ein lesbares DM in Pixelschrift.
"""
from PIL import Image, ImageDraw

GRUND = (11, 12, 18, 255)      # #0b0c12, Seitenhintergrund (DESIGN.md)
LINIE = (63, 66, 77, 255)      # #3f424d, Hairline/Bezelkante
AUS = (31, 29, 49, 255)        # #1f1d31, unbeleuchteter Punkt
AN = (181, 171, 252, 255)      # #b5abfc, Akzent: die Anzeige leuchtet

D = ['xxxx.', 'x...x', 'x...x', 'x...x', 'x...x', 'x...x', 'xxxx.']
M = ['x...x', 'xx.xx', 'x.x.x', 'x.x.x', 'x...x', 'x...x', 'x...x']
DM = [d + '.' + m for d, m in zip(D, M)]          # 11 Spalten, 7 Zeilen

KACHEL_RADIUS = 24
# gross: Fenster, 13 x 9 Raster, DM eine Zelle eingerueckt
FENSTER = (10, 22, 98, 86)
FENSTER_RADIUS, FENSTER_STRICH = 10, 1.5
RASTER = dict(abstand=6.4, x0=15.6, y0=28.4, spalten=13, zeilen=9, r_aus=2.2, r_an=2.4)
# klein: nur DM, gross gesetzt
KLEIN = dict(abstand=8.2, x0=13.0, y0=29.4, r=3.6)


def _hex(farbe):
    return '#%02x%02x%02x' % farbe[:3]


def _punkte(zeilen, abstand, x0, y0):
    """Mittelpunkte der leuchtenden Punkte in Rastereinheiten."""
    for y, zeile in enumerate(zeilen):
        for x, c in enumerate(zeile):
            if c == 'x':
                yield x0 + x * abstand, y0 + y * abstand


def zeichne(n, klein=False, ueberabtastung=4):
    """Das Zeichen als RGBA-Bild n x n, mit durchsichtigen Ecken."""
    s = n * ueberabtastung
    k = s / 108
    bild = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(bild)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=round(KACHEL_RADIUS * k), fill=GRUND)

    def kreis(cx, cy, r, farbe):
        d.ellipse(((cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k), fill=farbe)

    if klein:
        for cx, cy in _punkte(DM, KLEIN['abstand'], KLEIN['x0'], KLEIN['y0']):
            kreis(cx, cy, KLEIN['r'], AN)
    else:
        x0, y0, x1, y1 = FENSTER
        d.rounded_rectangle((x0 * k, y0 * k, x1 * k, y1 * k), radius=round(FENSTER_RADIUS * k),
                            outline=LINIE, width=max(1, round(FENSTER_STRICH * k)))
        a = RASTER['abstand']
        for y in range(RASTER['zeilen']):
            for x in range(RASTER['spalten']):
                kreis(RASTER['x0'] + x * a, RASTER['y0'] + y * a, RASTER['r_aus'], AUS)
        # DM sitzt eine Zelle eingerueckt auf demselben Raster: die leuchtenden
        # Punkte liegen genau ueber unbeleuchteten.
        for cx, cy in _punkte(DM, a, RASTER['x0'] + a, RASTER['y0'] + a):
            kreis(cx, cy, RASTER['r_an'], AN)
    return bild.resize((n, n), Image.LANCZOS)


def svg(klein=False):
    """Dasselbe Zeichen als SVG im 108er Raster."""
    teile = [f'<rect width="108" height="108" rx="{KACHEL_RADIUS}" fill="{_hex(GRUND)}"/>']
    if klein:
        teile += [f'<circle cx="{cx:g}" cy="{cy:g}" r="{KLEIN["r"]:g}"/>'
                  for cx, cy in _punkte(DM, KLEIN['abstand'], KLEIN['x0'], KLEIN['y0'])]
        punkte = f'<g fill="{_hex(AN)}">' + ''.join(teile[1:]) + '</g>'
        teile = teile[:1] + [punkte]
    else:
        x0, y0, x1, y1 = FENSTER
        teile.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" '
                     f'rx="{FENSTER_RADIUS}" fill="none" stroke="{_hex(LINIE)}" '
                     f'stroke-width="{FENSTER_STRICH}"/>')
        a = RASTER['abstand']
        aus = ''.join(f'<circle cx="{RASTER["x0"] + x * a:.1f}" cy="{RASTER["y0"] + y * a:.1f}" '
                      f'r="{RASTER["r_aus"]}"/>'
                      for y in range(RASTER['zeilen']) for x in range(RASTER['spalten']))
        an = ''.join(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{RASTER["r_an"]}"/>'
                     for cx, cy in _punkte(DM, a, RASTER['x0'] + a, RASTER['y0'] + a))
        teile += [f'<g fill="{_hex(AUS)}">{aus}</g>', f'<g fill="{_hex(AN)}">{an}</g>']
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">'
            + ''.join(teile) + '</svg>\n')
