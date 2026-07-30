# -*- coding: utf-8 -*-
"""BitDM-Symbol: Sprechblase als Umriss, B in Doto.

DIE KERBE WAR EIN AUFBAUFEHLER, kein Zeichenfehler. Zuerst hatte ich Blase und
Zipfel als zwei getrennte Formen mit `outline` gezeichnet und danach versucht,
die Kante zwischen ihnen mit einem schwarzen Strich wegzuradieren. Genau dort
klaffte die Kerbe: zwei Umrisse, die sich beruehren, haben an der Naht immer
eine.

RICHTIG IST EINE SILHOUETTE. Blase und Zipfel werden zu EINER gefuellten Form
vereinigt, dieselbe Form ein zweites Mal nach innen versetzt gezeichnet, und die
Differenz IST der Umriss. Damit kann an der Naht nichts klaffen — es gibt keine
Naht mehr.

Der innere Rand: das Rechteck exakt um die Strichbreite eingezogen und der
Eckradius um denselben Betrag verkleinert (so gehoert es sich bei abgerundeten
Rechtecken). Der Zipfel wird um den Blasenmittelpunkt skaliert — bei einer
kompakten Form ergibt das einen optisch gleichmaessigen Strich, und die
Ueberlappung mit dem inneren Rechteck haelt die Form geschlossen.
"""
import pathlib
from PIL import Image, ImageChops, ImageDraw, ImageFont

APP = pathlib.Path(r'C:\KI-Workstation\BitDM\secure-messenger\app')
S, U = 1024, 4
N = S * U
SCHWARZ = (11, 12, 18, 255)
WEISS = (243, 243, 246, 255)

BX0, BY0, BX1, BY1, RAD = 176, 206, 848, 700, 126
STRICH = 48
ZIPFEL = [(302, 636), (474, 636), (302, 852)]
CX, CY = (BX0 + BX1) / 2, (BY0 + BY1) / 2


def k(v):
    return round(v * U)


def silhouette(einzug):
    """Blase + Zipfel als eine gefuellte Maske, um [einzug] nach innen."""
    m = Image.new('L', (N, N), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(
        (k(BX0 + einzug), k(BY0 + einzug), k(BX1 - einzug), k(BY1 - einzug)),
        radius=k(max(RAD - einzug, 2)), fill=255)
    if einzug:
        sx = (BX1 - BX0 - 2 * einzug) / (BX1 - BX0)
        sy = (BY1 - BY0 - 2 * einzug) / (BY1 - BY0)
        z = [(CX + (x - CX) * sx, CY + (y - CY) * sy) for x, y in ZIPFEL]
    else:
        z = ZIPFEL
    d.polygon([(k(x), k(y)) for x, y in z], fill=255)
    return m


umriss = ImageChops.subtract(silhouette(0), silhouette(STRICH))

bild = Image.new('RGBA', (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(bild)
d.rounded_rectangle((0, 0, N - 1, N - 1), radius=k(278), fill=SCHWARZ)
bild.paste(Image.new('RGBA', (N, N), WEISS), (0, 0), umriss)

# Das B in Doto — NACH DER TINTE GESETZT, nicht nach den Schriftmassen.
#
# Erst hatte ich mit `textbbox` zentriert. Gemessen kam das B dann 19 Pixel zu
# weit links und 14 zu hoch heraus und fuellte nur 32 % der Innenbreite: Doto
# ist eine Punktmatrix-Schrift und meldet ihre Glyphenmasse ungenau, wie bei
# dieser Art Schrift ueblich.
#
# Darum: Buchstabe auf eine eigene Ebene, mit `getbbox()` auf die tatsaechliche
# Tinte beschneiden, und dieses Stueck mittig einsetzen. Unabhaengig davon, was
# die Schrift ueber sich behauptet.
ebene = Image.new('RGBA', (N, N), (0, 0, 0, 0))
ImageDraw.Draw(ebene).text(
    (k(200), k(200)), 'B',
    font=ImageFont.truetype(str(APP / 'assets/fonts/Doto.ttf'), k(470)),
    fill=WEISS)
tinte = ebene.crop(ebene.getbbox())
zx = round(CX * U - tinte.width / 2)
zy = round(CY * U - tinte.height / 2)
bild.paste(tinte, (zx, zy), tinte)
print(f'  B-Tinte {tinte.width // U}x{tinte.height // U} px, '
      f'Fuellung {100 * tinte.height / U / 398:.0f} % der Innenhoehe')

bild = bild.resize((S, S), Image.LANCZOS)
bild.save(APP / 'icon_bitdm_1024.png')
print('gezeichnet, Strichbreite', STRICH)
print('  Ecke        ', bild.getpixel((3, 3)))
print('  Blasenkante ', bild.getpixel((S // 2, round(BY0 * S / 1024) + 6)))
print('  Blaseninnen ', bild.getpixel((S // 2, round((BY0 + 90) * S / 1024))))
