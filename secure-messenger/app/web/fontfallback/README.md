# Schrift-Ersatz für die Web-Fassung

Die Flutter-Engine sucht fehlende Zeichen unter `fontFallbackBaseUrl`
(gesetzt in `web/flutter_bootstrap.js`). Ab Werk ist das
`https://fonts.gstatic.com/s/`; hier liegen die Dateien unter denselben
Pfaden, damit die Web-Fassung nichts von Dritten lädt.

| Datei | Schrift | Quelle | Lizenz |
|---|---|---|---|
| `roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2` | Roboto (Standard der Engine) | fonts.gstatic.com, 25.09.2026 | SIL OFL 1.1 |
| `notosanssymbols/v43/rP2up3q65F…VFRkzrbQ.woff2` | Noto Sans Symbols (★, ✓ u. a.) | fonts.gstatic.com, 25.09.2026 | SIL OFL 1.1 |

Welche Dateien gebraucht werden, zeigt die Browser-Konsole: jede fehlende
meldet die CSP als blockierten Aufruf an fonts.gstatic.com bzw. als 404
hier. Pfad und Version stehen in der Flutter-Engine
(`flutter_web_sdk/lib/_engine/engine/font_fallback_data.dart`,
`canvaskit/fonts.dart`) und ändern sich mit Flutter-Updates.
