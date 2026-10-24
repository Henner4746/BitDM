# -*- coding: utf-8 -*-
"""Das Zeichen F1 an alle Stellen schreiben, an denen App und Seite es zeigen.

Bis 32 Pixel die Kleinfassung, ab 48 das volle Anzeigefenster (siehe f1.py).
Die .ico-Dateien tragen beides: pro Groesse ein eigenes Bild.
"""
import pathlib
import sys

from PIL import Image

HIER = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HIER))
import f1  # noqa: E402

APP = HIER.parent.parent
SEITE = APP.parent / 'website'


def gross(n):
    return f1.zeichne(n)


def klein(n):
    return f1.zeichne(n, klein=True)


def ico(ziel, groessen):
    """Eine .ico, jede Groesse mit ihrer eigenen Fassung."""
    bilder = [klein(n) if n <= 32 else gross(n) for n in groessen]
    bilder[-1].save(ziel, sizes=[(n, n) for n in groessen], append_images=bilder[:-1])


res = APP / 'android/app/src/main/res'
for ordner, n in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                  ('xxhdpi', 144), ('xxxhdpi', 192)]:
    gross(n).save(res / f'mipmap-{ordner}' / 'ic_launcher.png')
print('android : 48 72 96 144 192')

ico(APP / 'windows/runner/resources/app_icon.ico', [16, 24, 32, 48, 64, 128, 256])
print('windows : .ico, 16-32 klein, 48-256 gross')

web = APP / 'web'
klein(32).save(web / 'favicon.png')
gross(192).save(web / 'icons/Icon-192.png')
gross(512).save(web / 'icons/Icon-512.png')
# Maskierbar: Chrome legt eine eigene Form darueber und schneidet bis zu 20 %
# weg. Vollflaechig dunkel hinterlegt und das Motiv eingerueckt, sonst faellt
# das Fenster dem fremden Zuschnitt zum Opfer.
for n in (192, 512):
    g = Image.new('RGBA', (n, n), f1.GRUND)
    innen = int(n * 0.74)
    z = gross(innen)
    g.paste(z, ((n - innen) // 2, (n - innen) // 2), z)
    g.save(web / f'icons/Icon-maskable-{n}.png')
print('web     : favicon 32 klein, 192, 512, maskierbar 192+512')

gross(512).save(APP / 'fastlane/metadata/android/en-US/images/icon.png')
print('fastlane: icon.png 512 (F-Droid-Eintrag)')

gross(180).save(SEITE / 'bilder/icon-180.png')
ico(SEITE / 'favicon.ico', [16, 32, 48])
# newline='\n': sonst schreibt Windows CRLF, und git meldet die Dateien bei
# jedem Lauf als geaendert.
(SEITE / 'favicon.svg').write_text(f1.svg(klein=True), encoding='utf-8', newline='\n')
(SEITE / 'bilder/bitdm-zeichen.svg').write_text(f1.svg(), encoding='utf-8', newline='\n')
print('website : bilder/icon-180.png, favicon.ico (16/32 klein, 48 gross), '
      'favicon.svg (klein), bilder/bitdm-zeichen.svg (gross)')
