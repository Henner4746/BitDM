# Das BitDM-Zeichen bauen

Seit 24.10.2026 gilt Entwurf **F1, „Anzeigefenster“**: ein Displayfenster auf
der Gerätefront, darin eine Punktmatrix, und DM leuchtet in Violett. Henrik hat
es aus sechs Entwürfen und sechs Varianten gewählt. Es löst die Sprechblase mit
dem B ab (`65fd2dc`), die schwarz-weiß war und neben dem Favicon ein zweites
Zeichen bildete.

```bash
py tool/symbol/verteilen.py
```

schreibt alles neu, aus einer einzigen Vorlage in `f1.py`:

| Ziel | Fassung |
|---|---|
| Android `mipmap-*/ic_launcher.png` (48–192) | groß |
| Windows `app_icon.ico` | 16–32 klein, 48–256 groß |
| Web-App `web/favicon.png` (32) | klein |
| Web-App `web/icons/Icon-*.png`, maskierbar | groß |
| F-Droid `fastlane/.../images/icon.png` (512) | groß |
| Website `bilder/icon-180.png`, `bilder/bitdm-zeichen.svg` | groß |
| Website `favicon.ico` | 16/32 klein, 48 groß |
| Website `favicon.svg` | klein |

**Warum zwei Fassungen.** Unter 48 Pixeln werden Fensterrahmen und
unbeleuchtete Punkte zu grauem Brei, bei 16 Pixeln wäre ein Punkt 0,7 Pixel
breit. Die Kleinfassung zeigt dasselbe DM ohne Fenster und Raster, mit Punkten,
die fast aneinanderstoßen. So bleibt es bei 16 Pixeln eine lesbare Pixelschrift.
Dieselbe Grenze galt schon für das alte Zeichen; damals gemessen an einer
Größenprobe, jetzt erneut nachgesehen.

**Maße.** Alles steht im 108er Raster eines Android-Symbols: Kachelradius 24,
Fenster 10/22 bis 98/86 mit Radius 10, Raster 13 × 9 Punkte im Abstand 6,4. DM
sitzt eine Zelle eingerückt auf demselben Raster, die leuchtenden Punkte liegen
also genau über unbeleuchteten. Farben aus `DESIGN.md`: Grund `#0b0c12`, Linie
`#3f424d`, Akzent `#b5abfc`, aus `#1f1d31`.
