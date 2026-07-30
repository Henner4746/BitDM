# -*- coding: utf-8 -*-
"""Aus icon_bitdm_1024.png alle Ziele schreiben."""
import pathlib
from PIL import Image

APP = pathlib.Path(r'C:\KI-Workstation\BitDM\secure-messenger\app')
q = Image.open(APP / 'icon_bitdm_1024.png').convert('RGBA')


def s(n):
    return q.resize((n, n), Image.LANCZOS)


res = APP / 'android/app/src/main/res'
for ordner, n in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                  ('xxhdpi', 144), ('xxxhdpi', 192)]:
    s(n).save(res / f'mipmap-{ordner}' / 'ic_launcher.png')
print('android : 48 72 96 144 192')

ico = APP / 'windows/runner/resources/app_icon.ico'
s(256).save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                        (64, 64), (128, 128), (256, 256)])
print('windows : .ico mit 7 Groessen')

web = APP / 'web'
s(32).save(web / 'favicon.png')
s(192).save(web / 'icons/Icon-192.png')
s(512).save(web / 'icons/Icon-512.png')

# Maskierbar: Chrome legt eine eigene Form darueber und schneidet bis zu 20 %
# weg. Vollflaechig dunkel hinterlegt und das Motiv eingeruecht, sonst faellt
# die Rundung dem fremden Zuschnitt zum Opfer.
for n in (192, 512):
    g = Image.new('RGBA', (n, n), (11, 12, 18, 255))
    innen = int(n * 0.74)
    k = s(innen)
    g.paste(k, ((n - innen) // 2, (n - innen) // 2), k)
    g.save(web / f'icons/Icon-maskable-{n}.png')
print('web     : favicon 32, 192, 512, maskierbar 192+512')

# Fuer die Webseite, damit der Reiter im Browser nicht leer bleibt.
s(180).save(APP.parent / 'website/bilder/icon-180.png')
print('website : bilder/icon-180.png')
