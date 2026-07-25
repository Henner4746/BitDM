package com.bitdm.bitdm

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
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
 * WARUM FlutterFragmentActivity UND NICHT FlutterActivity
 * androidx.biometric verlangt eine FragmentActivity — es haengt seinen Dialog
 * als Fragment ein. FlutterActivity ist keine. Ohne diesen Wechsel gaebe es
 * keinen Anmeldedialog, und beim Antippen passierte nichts. Genau so war es
 * am 25.07.2026.
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
class MainActivity : FlutterFragmentActivity() {

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

        // DIESER bekommt die Activity und NICHT den Application-Context. Ein
        // Anmeldedialog braucht sie; ohne sie erscheint auf manchen Geraeten
        // gar keiner, und beim Antippen passiert nichts. Siehe
        // SchluesselfachKanal.kt.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SchluesselfachKanal.KANAL)
            .setMethodCallHandler(SchluesselfachKanal(this))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EmpfangsDienst.KANAL)
            .setMethodCallHandler { aufruf, ergebnis ->
                when (aufruf.method) {
                    "starte" -> {
                        EmpfangsDienst.starte(
                            applicationContext,
                            aufruf.argument<String>("titel") ?: "BitDM",
                            aufruf.argument<String>("text") ?: "",
                        )
                        ergebnis.success(true)
                    }
                    "stoppe" -> {
                        EmpfangsDienst.stoppe(applicationContext)
                        ergebnis.success(true)
                    }
                    else -> ergebnis.notImplemented()
                }
            }

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
