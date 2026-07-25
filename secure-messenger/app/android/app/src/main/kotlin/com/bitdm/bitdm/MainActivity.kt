package com.bitdm.bitdm

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Setzt FLAG_SECURE fuer das Fenster.
 *
 * Die Einstellung "Screenshots blockieren" gab es in der Oberflaeche schon
 * lange — sie tat nur nichts. Ein Schalter, der Sicherheit verspricht und
 * keine liefert, ist schlimmer als gar keiner: jemand macht in dem Glauben
 * etwas, das er sonst nicht machen wuerde.
 *
 * FLAG_SECURE bewirkt dreierlei:
 *   - Screenshots und Bildschirmaufnahmen verweigert das System
 *   - in der Uebersicht zuletzt genutzter Apps erscheint statt des Inhalts
 *     eine leere Flaeche
 *   - die App laesst sich nicht auf einen externen Bildschirm spiegeln
 *
 * EHRLICH DAZUGESAGT, und die Oberflaeche sagt es auch: es hindert niemanden
 * daran, mit einem zweiten Telefon den Bildschirm abzufotografieren. Es
 * schuetzt gegen Software auf DIESEM Geraet, nicht gegen die Person davor —
 * und schon gar nicht gegen die Gegenstelle, die mitschreiben kann, was sie
 * will.
 */
class MainActivity : FlutterActivity() {

    private val kanal = "bitdm/fenster"

    override fun onCreate(savedInstanceState: Bundle?) {
        // VOR dem ersten Zeichnen setzen, nicht erst wenn Dart hochgefahren
        // ist. Sonst waere das allererste Bild — und damit die Vorschau in der
        // App-Uebersicht — ungeschuetzt. Wer die Sperre nicht will, schaltet
        // sie danach ab; die andere Richtung liesse sich nicht nachholen.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, UsbHidKanal.KANAL)
            .setMethodCallHandler(UsbHidKanal(applicationContext))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, kanal)
            .setMethodCallHandler { aufruf, ergebnis ->
                when (aufruf.method) {
                    "setzeScreenshotSperre" -> {
                        val an = aufruf.argument<Boolean>("an") ?: true
                        runOnUiThread {
                            if (an) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                        }
                        ergebnis.success(true)
                    }
                    else -> ergebnis.notImplemented()
                }
            }
    }
}
