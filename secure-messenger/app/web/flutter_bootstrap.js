{{flutter_js}}
{{flutter_build_config}}

// SCHRIFT-ERSATZ VON HIER, NICHT VON GOOGLE (seit 25.09.2026).
// Ohne diese Zeile holt die Flutter-Engine Roboto und fuer Zeichen wie ★ ✓
// "Noto Sans Symbols" von fonts.gstatic.com. Die CSP auf bitdm.net/app/
// blockt das ohnehin — dann fehlten die Zeichen, und jede Seite verriete
// Google zumindest den Versuch. Die zwei Schriften, die die App wirklich
// anfragt, liegen unter web/fontfallback/ im selben Pfadschema wie bei
// gstatic; andere (etwa Emoji) gibt es im Browser nicht.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: "fontfallback/",
  },
});
