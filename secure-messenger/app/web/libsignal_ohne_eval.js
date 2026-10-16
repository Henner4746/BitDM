// libsignal_ohne_eval.js — laedt libsignal im Browser, ohne dass die CSP
// 'unsafe-eval' erlauben muss.
//
// WARUM ES DAS GIBT
// Seit 2.0.0 rechnet BitDM ueber Signals libsignal, im Browser als WASM ueber
// flutter_rust_bridge 2.13.0. Dessen Lader haengt `pkg/libsignal_frb.js` als
// Skript ein und macht danach den Namen der Anbindung global sichtbar mit
//
//     new Function("window.wasm_bindgen = wasm_bindgen").call()
//
// (frb_dart lib/src/wasm_module/_web.dart, ueber jsEval). Das ist eval. Die CSP
// von bitdm.net/app/ erlaubt 'wasm-unsafe-eval', aber kein 'unsafe-eval', und
// das soll so bleiben. Ohne dieses Skript blieb die Web-App beim Anlegen der
// Identitaet stehen (gemessen am 16.10.2026 unter der Produktions-CSP).
// Upstream offen: https://github.com/fzyzcjy/flutter_rust_bridge/issues/3477
//
// WAS ES TUT
// Es ersetzt den globalen Function-Konstruktor durch einen, der GENAU DIESEN
// EINEN konstanten Text ohne eval erledigt: Er gibt eine fertige Funktion
// zurueck, die `wasm_bindgen` (ein `let` im Skriptbereich von
// libsignal_frb.js, darum nicht auf window) nach window kopiert. Jeder andere
// Aufruf geht unveraendert an den echten Konstruktor, und den verbietet die
// CSP weiterhin. Es kommt also kein Weg hinzu, Text als Code auszufuehren.
//
// WER ES ANFASST
// test/web/libsignal_ohne_eval_test.dart prueft, dass der Text hier und der in
// flutter_rust_bridge uebereinstimmen. Aendert eine neue Fassung den Ladeweg,
// wird der Test rot, bevor die Web-App im Browser stehen bleibt.
(function () {
  'use strict';
  var Echt = globalThis.Function;
  var ERWARTET = 'window.wasm_bindgen = wasm_bindgen';

  function OhneEval() {
    if (arguments.length === 1 && arguments[0] === ERWARTET) {
      return function () {
        // eslint-disable-next-line no-undef
        globalThis.wasm_bindgen = wasm_bindgen;
      };
    }
    return new.target
      ? Reflect.construct(Echt, arguments)
      : Echt.apply(this, arguments);
  }

  // `x instanceof Function` und `Function.prototype` bleiben, wie sie waren.
  OhneEval.prototype = Echt.prototype;
  globalThis.Function = OhneEval;
})();
