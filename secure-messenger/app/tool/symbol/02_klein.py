# -*- coding: utf-8 -*-
"""Kleinfassung fuer 16 bis 32 Pixel.

BEI 24 PIXELN VERSCHMELZEN DIE PUNKTE. Gemessen an der Groessenprobe: ab 48 ist
das Doto-B lesbar, darunter wird es ein Fleck, und der 48er Umriss wird bei
16 Pixeln 0,75 Pixel dick — also grau statt weiss.

Darum fuer die kleinen Groessen: dieselbe Silhouette (Blase mit Zipfel als
Umriss, damit das Symbol nicht die Form wechselt), aber kraeftiger Strich und
ein VOLLES B aus Chivo Mono statt der Punktmatrix. So bleibt bei 16 Pixeln ein
erkennbarer Buchstabe stehen.

Die .ico traegt beides: klein diese Fassung, gross die mit den Punkten.
"""
import pathlib
from PIL import Image, ImageChops, ImageDraw, ImageFont

APP = pathlib.Path(r'C:\KI-Workstation\BitDM\secure-messenger\app')
S, U = 256, 8
N = S * U
SCHWARZ = (11, 12, 18, 255)
WEISS = (243, 243, 246, 255)

# Entwurf im 256er Raster, damit die Zahlen zur Zielgroesse passen.
BX0, BY0, BX1, BY1, RAD = 30, 40, 226, 172, 30
STRICH = 20                              # deutlich dicker als 48/1024
ZIPFEL = [(64, 150), (110, 150), (64, 214)]
CX, CY = (BX0 + BX1) / 2, (BY0 + BY1) / 2


def k(v):
    return round(v * U)


def sil(ein):
    m = Image.new('L', (N, N), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((k(BX0 + ein), k(BY0 + ein), k(BX1 - ein), k(BY1 - ein)),
                        radius=k(max(RAD - ein, 2)), fill=255)
    if ein:
        sx = (BX1 - BX0 - 2 * ein) / (BX1 - BX0)
        sy = (BY1 - BY0 - 2 * ein) / (BY1 - BY0)
        z = [(CX + (x - CX) * sx, CY + (y - CY) * sy) for x, y in ZIPFEL]
    else:
        z = ZIPFEL
    d.polygon([(k(x), k(y)) for x, y in z], fill=255)
    return m


b = Image.new('RGBA', (N, N), (0, 0, 0, 0))
ImageDraw.Draw(b).rounded_rectangle((0, 0, N - 1, N - 1),
                                    radius=k(69.5), fill=SCHWARZ)
b.paste(Image.new('RGBA', (N, N), WEISS), (0, 0),
        ImageChops.subtract(sil(0), sil(STRICH)))

# Volles B, wieder nach der Tinte gesetzt statt nach den Schriftmassen.
e = Image.new('RGBA', (N, N), (0, 0, 0, 0))
ImageDraw.Draw(e).text((k(60), k(50)), 'B',
                       font=ImageFont.truetype(
                           str(APP / 'assets/fonts/ChivoMono.ttf'), k(96)),
                       fill=WEISS)
t = e.crop(e.getbbox())
b.paste(t, (round(CX * U - t.width / 2), round(CY * U - t.height / 2)), t)

b = b.resize((S, S), Image.LANCZOS)
b.save(APP / 'icon_bitdm_klein.png')
print(f'Kleinfassung {b.size}, B-Tinte {t.width // U}x{t.height // U} px im '
      f'256er Raster')
