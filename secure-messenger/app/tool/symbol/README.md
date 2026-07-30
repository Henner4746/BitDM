# Das App-Symbol neu bauen

Reihenfolge, sonst fehlt die Vorlage:

```bash
py tool/symbol/01_gross.py       # icon_bitdm_1024.png  — Blase + Doto-B
py tool/symbol/02_klein.py       # icon_bitdm_klein.png — kraeftiger, volles B
py tool/symbol/03_verteilen.py   # Android, Web, Webseite
```

Danach die `.ico` gemischt schreiben — klein bis 32, Punktmatrix ab 48:

```python
gr = Image.open('icon_bitdm_1024.png'); kl = Image.open('icon_bitdm_klein.png')
t = [kl.resize((n, n)) for n in (16, 24, 32)] + \
    [gr.resize((n, n)) for n in (48, 64, 128, 256)]
t[-1].save('windows/runner/resources/app_icon.ico',
           sizes=[x.size for x in t], append_images=t[:-1])
```

**Warum zwei Fassungen.** Gemessen an einer Groessenprobe: das Doto-B ist ab
48 Pixeln lesbar, darunter verschmelzen die Punkte, und der Umriss wird bei 16
Pixeln 0,75 Pixel dick — also grau statt weiss. Eine `.ico` darf pro Groesse
ein eigenes Bild tragen, also traegt sie klein die kraeftige Fassung.

**Was NICHT nochmal probiert werden muss** (alles am 30.07.2026 gebaut und
verworfen): den gefalteten Rhombus der ersten Vorlage nachzuzeichnen — die
Facetten werden bei 48 Pixeln Brei; Kreise mit Rechteck-Schnitt fuer die Drei —
das beisst ein quadratisches Loch in die Form; `textbbox` zum Zentrieren von
Doto — die Schrift meldet ihre Glyphenmasse ungenau, das B sass 19 Pixel zu
weit links. Zentriert wird nach `getbbox()` der gezeichneten Tinte.
