# Schrift-Ersatz für die Web-Fassung

Die Flutter-Engine sucht fehlende Zeichen unter `fontFallbackBaseUrl`
(gesetzt in `web/flutter_bootstrap.js`). Ab Werk ist das
`https://fonts.gstatic.com/s/`; hier liegen die Dateien unter denselben
Pfaden, damit die Web-Fassung nichts von Dritten lädt.

| Datei | Schrift | Quelle | Lizenz |
|---|---|---|---|
| `roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2` | Roboto (Standard der Engine) | fonts.gstatic.com, 25.09.2026 | SIL OFL 1.1 |
| `notosanssymbols/v43/rP2up3q65F…VFRkzrbQ.woff2` | Noto Sans Symbols (Umlaute und Satzzeichen in der Systemschrift, s. u.) | fonts.gstatic.com, 25.09.2026 | SIL OFL 1.1 |
| `notosanssymbols2/v24/I_uyMoGduATTei9eI8daxVHDyfisHr71-vrgfE71.woff2` | Noto Sans Symbols 2, Stück 3 (Geometrie, Pfeile, Dingbats: ↯ ⌖ ☺ …) | fonts.gstatic.com, 17.10.2026, 382 716 Bytes | SIL OFL 1.1 |

## Die eigenen Zeichen der App kommen nicht von hier

✓ ◷ ★ ● ○ ◌ ◍ ◎ ⇉ ≡ ∿ → ≈ stehen seit 17.10.2026 als kleine Untermengen in
der App selbst (`assets/fonts/*-BitDM.ttf`, `symbolSchriften` in
`lib/themen.dart`). Vorher holte die Engine sie hier ab. Stück 3 fehlte, und
weil die Engine einen gescheiterten Abruf nicht als endgültig verbucht,
fragte sie bei jedem neuen Layout erneut: im offenen Chat alle zwei Sekunden
eine 404 (16.10.2026, ausgelöst von ✓ und ◷ am Zustellstatus).

## Wofür die Dateien hier noch da sind

**Noto Sans Symbols** lädt fast jede Sitzung, und zwar wegen „ä“, „–“ oder
„…“, nicht wegen Symbolen. Text in der Systemschrift (Nachrichten, die
Material-Themen) steht im Browser in einer Familie, die CanvasKit nicht kennt
(unter Windows „Segoe UI“ aus Flutters Typography).
Für die Prüfung, ob nachgeladen werden muss, zählt Roboto nicht mit, also
gilt jedes Zeichen ab U+00A0 als fehlend. Bei Gleichstand wählt die Engine
Noto Sans Symbols. Gezeichnet wird danach trotzdem mit Roboto.

**Stück 3** ist für Text, den Kontakte schicken. Fehlt ein Zeichen aus
diesem Block allein, wählt die Engine Stück 3 bei knapp drei Vierteln der
Zeichen. Beim Rest bevorzugt sie bei Gleichstand Noto Sans SC (■ □ ▪ ⇦ …)
oder einen Teil von Noto Color Emoji (✈ ⌚ ☕ …), und beide liegen hier nicht.
Fehlen mehrere Zeichen zugleich, gewinnt die Schrift, die die meisten
abdeckt, bei Symbolen meist Stück 3. Was hier fehlt (Emoji, Kyrillisch,
CJK …), erscheint als Kästchen und löst dieselbe Schleife aus.

## Wenn Flutter aktualisiert wird

Pfad und Version stehen in der Flutter-Engine
(`flutter_web_sdk/lib/_engine/engine/font_fallback_data.dart`,
`canvaskit/fonts.dart`) und ändern sich mit Flutter-Updates. Dann schlägt
`test/oberflaeche/schriftzeichen_test.dart` an, sofern auf dem Rechner ein
Web-Bau liegt: „kennt diese Engine nicht mehr“ für eine Datei hier, oder
eine Liste von Zeichen, deren Datei hier fehlt. Die neue Datei unter dem
neuen Pfad holen und die Zeile oben anpassen.

Welche Datei die Engine für ein Zeichen will, steht ebenfalls in
`font_fallback_data.dart`: `encodedFontSetRanges` ordnet jedem Bereich eine
Schriftmenge zu, die Kommentare nennen sie im Klartext. Gewählt wird in
`font_fallbacks.dart` (`_selectFont`): erst die Schrift, die die meisten
fehlenden Zeichen abdeckt, bei Gleichstand Noto Sans Symbols, dann
Noto Sans SC, sonst die mit dem kleinsten Index. Im Browser zeigt die
Konsole jede fehlende Datei als 404 bzw. als CSP-Verstoß gegen
fonts.gstatic.com. Auf bitdm.net antwortet nginx wegen `try_files` statt
mit 404 mit der `index.html`. Auch daran scheitert die Engine und fragt
erneut.
