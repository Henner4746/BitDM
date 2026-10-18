{{flutter_js}}
{{flutter_build_config}}

// SCHRIFT-ERSATZ VON HIER, NICHT VON GOOGLE (seit 25.09.2026).
// Ohne diese Zeile holt die Flutter-Engine Roboto und fuer jedes Zeichen, das
// keine geladene Schrift hat, eine Noto-Schrift von fonts.gstatic.com. Die
// CSP auf bitdm.net/app/ blockt das ohnehin — dann fehlten die Zeichen, und
// jede Seite verriete Google zumindest den Versuch. Roboto und Teile der
// Noto-Symbolschriften liegen unter web/fontfallback/ im selben Pfadschema
// wie bei gstatic; andere (etwa Emoji) gibt es im Browser nicht. Die eigenen
// Sonderzeichen (✓ ◷ ★ …) bringt die App seit 17.10.2026 selbst mit, siehe
// symbolSchriften in lib/themen.dart.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: "fontfallback/",
  },
});
