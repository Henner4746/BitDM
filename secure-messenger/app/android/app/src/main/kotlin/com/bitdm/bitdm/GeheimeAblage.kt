package com.bitdm.bitdm

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal "bitdm/ablage": die zwoelf Woerter (und Teile davon) in die
 * Zwischenablage — und nach einer Frist wieder heraus. Die Gegenstelle ist
 * lib/core/geheime_ablage.dart; dort steht, warum es den Knopf gibt.
 *
 * ALS SENSIBEL MARKIERT. Ab Android 13 zeigt das System nach jedem Kopieren
 * unten links eine Vorschau des Inhalts — bei den Woertern also die Woerter,
 * gross und lesbar, auch auf einem Bildschirm, den gerade jemand mitfilmt.
 * Mit EXTRA_IS_SENSITIVE stehen dort Punkte. Tastaturen wie Gboard lesen
 * dasselbe Merkmal und bieten den Inhalt nicht als Einfuegevorschlag an.
 * Der Schluessel steht als Text da und nicht als Konstante: die gibt es erst
 * ab API 33, das Merkmal selbst wirkt bei Tastaturen auch darunter (so
 * empfiehlt es die Android-Doku fuer aeltere Fassungen).
 *
 * DAS LEEREN GESCHIEHT HIER UND NICHT IN DART. Ab Android 10 bekommt nur die
 * App im Vordergrund die Zwischenablage zu lesen. Wer die Woerter kopiert,
 * wechselt aber gerade in eine andere App, um sie dort einzufuegen — ein
 * Dart-Zeitgeber, der nach einer Minute nachsieht, bekaeme null und liesse
 * sie stehen. Schreiben (und damit Leeren) darf die App auch im Hintergrund.
 *
 * Nach der Frist gilt deshalb:
 *   - Laesst sich die Ablage lesen (App im Vordergrund): nur leeren, wenn dort
 *     noch GENAU das steht. Was der Nutzer inzwischen kopiert hat, bleibt.
 *   - Hat die App waehrenddessen gesehen, dass etwas anderes kopiert wurde
 *     (der Waechter unten meldet das, solange sie im Vordergrund ist): nichts
 *     tun.
 *   - Sonst (Hintergrund, nichts gesehen): leeren, ohne nachzusehen. Das kann
 *     einen Text treffen, den jemand in dieser Minute in einer anderen App
 *     kopiert hat. Die Alternative waere, die Woerter liegen zu lassen, bis
 *     die App wieder vorne ist — womoeglich Stunden. Passwortmanager machen es
 *     genauso.
 *
 * Stirbt der Prozess vor Ablauf der Frist, leert niemand mehr. Ab Android 13
 * raeumt das System die Ablage nach einer Stunde selbst.
 */
class GeheimeAblage(context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "bitdm/ablage"

        /** = ClipDescription.EXTRA_IS_SENSITIVE (API 33). */
        private const val SENSIBEL = "android.content.extra.IS_SENSITIVE"

        /** Die Beschriftung des Eintrags — sichtbar in manchen Verlaeufen. */
        private const val BESCHRIFTUNG = "BitDM"
    }

    private val ablage =
        context.applicationContext.getSystemService(Context.CLIPBOARD_SERVICE)
            as ClipboardManager

    // Der Haupt-Looper und nicht die Activity: die wird beim Drehen neu
    // gebaut, und die Frist soll das ueberstehen.
    private val wecker = Handler(Looper.getMainLooper())

    /** Was zuletzt kopiert wurde, bis die Frist um ist. */
    private var inhalt: String? = null

    /** Ob seitdem nachweislich etwas anderes in der Ablage steht. */
    private var ersetzt = false

    private val raeumen = Runnable { raeume() }

    private val waechter = ClipboardManager.OnPrimaryClipChangedListener {
        // Kommt auch fuer das eigene Kopieren an. Nur wer die Ablage lesen
        // kann (Vordergrund), erfaehrt hier etwas; im Hintergrund meldet
        // Android nichts.
        val text = inhalt ?: return@OnPrimaryClipChangedListener
        val jetzt = lies()
        if (jetzt != null && jetzt != text) ersetzt = true
    }

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        when (aufruf.method) {
            "kopiere" -> {
                val text = aufruf.argument<String>("text")
                val sekunden = aufruf.argument<Int>("sekunden") ?: 60
                if (text.isNullOrEmpty()) {
                    ergebnis.success(false)
                    return
                }
                ergebnis.success(kopiere(text, sekunden.coerceIn(1, 3600)))
            }
            // Sofort, etwa wenn die Identitaet geloescht wurde.
            "raeume" -> {
                wecker.removeCallbacks(raeumen)
                raeume()
                ergebnis.success(true)
            }
            else -> ergebnis.notImplemented()
        }
    }

    private fun kopiere(text: String, sekunden: Int): Boolean {
        wecker.removeCallbacks(raeumen)
        val clip = ClipData.newPlainText(BESCHRIFTUNG, text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(SENSIBEL, true)
        }
        try {
            ablage.setPrimaryClip(clip)
        } catch (e: RuntimeException) {
            // Etwa zu gross fuer den Binder — bei zwoelf Woertern nicht, aber
            // die Dart-Seite soll eine Antwort bekommen statt einer Ausnahme.
            return false
        }
        inhalt = text
        ersetzt = false
        ablage.removePrimaryClipChangedListener(waechter)
        ablage.addPrimaryClipChangedListener(waechter)
        wecker.postDelayed(raeumen, sekunden * 1000L)
        return true
    }

    private fun raeume() {
        val text = inhalt ?: return
        inhalt = null
        ablage.removePrimaryClipChangedListener(waechter)
        if (ersetzt) return
        val jetzt = lies()
        if (jetzt != null && jetzt != text) return
        // Gleich dem Kopierten — oder nicht lesbar, weil die App im
        // Hintergrund ist. Siehe oben, warum dann trotzdem geleert wird.
        try {
            ablage.clearPrimaryClip()
        } catch (e: RuntimeException) {
            // Nichts mehr zu machen.
        }
    }

    /** Der Text in der Ablage, oder null, wenn sie leer oder nicht lesbar ist. */
    private fun lies(): String? = try {
        val clip = ablage.primaryClip
        if (clip == null || clip.itemCount == 0) null
        else clip.getItemAt(0).text?.toString() ?: ""
    } catch (e: RuntimeException) {
        null
    }
}
