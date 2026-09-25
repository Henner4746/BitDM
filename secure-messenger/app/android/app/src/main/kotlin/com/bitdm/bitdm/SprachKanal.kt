package com.bitdm.bitdm

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Sprachnachrichten aufnehmen und abspielen.
 *
 * ═══════════════════════════════ WARUM SELBST GESCHRIEBEN UND KEIN PAKET
 *
 * Aus demselben Grund wie DateiKanal.kt: ein Paket bringt Code und
 * Berechtigungen mit, die niemand hier gelesen hat. Das Aufnehmen selbst sind
 * zehn Zeilen MediaRecorder; dafuer lohnt keine fremde Abhaengigkeit, und
 * F-Droid baut ohne sie genauso.
 *
 * ═══════════════════════════════════════════════════════ WAS AUFGENOMMEN WIRD
 *
 * AAC in MPEG-4 (.m4a), einkanalig, 44,1 kHz, 32 kbit/s — Sprache, keine
 * Musik. Eine Minute sind rund 240 KB; verschickt wird die Datei ueber den
 * gewoehnlichen, verschluesselten Anhang-Weg. Aufgenommen wird NUR zwischen
 * "starte" und "stoppe", nur auf Knopfdruck, und die Datei liegt im privaten
 * Bereich der App (filesDir/sprache), den keine andere App sieht.
 */
class SprachKanal(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "bitdm/sprache"
        const val RECHTE_NUMMER = 0x5A7C
    }

    private var rekorder: MediaRecorder? = null
    private var datei: File? = null
    private var beginn = 0L
    private var spieler: MediaPlayer? = null
    private var rechteWartet: MethodChannel.Result? = null

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        when (aufruf.method) {
            // Die Dart-Seite fragt das, um den Knopf ueberhaupt zu zeigen. Auf
            // Plattformen ohne diesen Kanal kommt MissingPluginException.
            "verfuegbar" -> ergebnis.success(true)
            "rechte" -> fordereRechte(ergebnis)
            "starte" -> starte(ergebnis)
            "stoppe" -> stoppe(ergebnis)
            "verwirf" -> { verwirf(); ergebnis.success(null) }
            "spiele" -> spiele(aufruf.argument<String>("pfad"), ergebnis)
            "halt" -> { halt(); ergebnis.success(null) }
            else -> ergebnis.notImplemented()
        }
    }

    private fun darf() = ContextCompat.checkSelfPermission(
        activity, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun fordereRechte(ergebnis: MethodChannel.Result) {
        if (darf()) { ergebnis.success("ja"); return }
        if (rechteWartet != null) {
            ergebnis.error("BESETZT", "es laeuft schon eine Abfrage", null); return
        }
        rechteWartet = ergebnis
        ActivityCompat.requestPermissions(
            activity, arrayOf(Manifest.permission.RECORD_AUDIO), RECHTE_NUMMER)
    }

    /** Von MainActivity.onRequestPermissionsResult. Gibt true, wenn es uns galt. */
    fun rechteAntwort(nummer: Int, ergebnisse: IntArray): Boolean {
        if (nummer != RECHTE_NUMMER) return false
        val warte = rechteWartet ?: return true
        rechteWartet = null
        if (ergebnisse.isNotEmpty() && ergebnisse[0] == PackageManager.PERMISSION_GRANTED) {
            warte.success("ja"); return true
        }
        val darfNochFragen = ActivityCompat.shouldShowRequestPermissionRationale(
            activity, Manifest.permission.RECORD_AUDIO)
        warte.success(if (darfNochFragen) "nein" else "dauerhaft")
        return true
    }

    private fun starte(ergebnis: MethodChannel.Result) {
        if (!darf()) { ergebnis.error("RECHTE", "keine Erlaubnis fuer das Mikrofon", null); return }
        if (rekorder != null) { ergebnis.error("BESETZT", "es laeuft schon eine Aufnahme", null); return }
        val ordner = File(activity.filesDir, "sprache").apply { mkdirs() }
        val ziel = File(ordner, "aufnahme-${System.currentTimeMillis()}.m4a")
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(activity)
        } else {
            @Suppress("DEPRECATION") MediaRecorder()
        }
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(44100)
            r.setAudioEncodingBitRate(32000)
            r.setOutputFile(ziel.absolutePath)
            r.prepare()
            r.start()
        } catch (e: Exception) {
            r.release()
            ziel.delete()
            ergebnis.error("AUFNAHME", e.message, null)
            return
        }
        rekorder = r
        datei = ziel
        beginn = SystemClock.elapsedRealtime()
        ergebnis.success(true)
    }

    private fun stoppe(ergebnis: MethodChannel.Result) {
        val r = rekorder
        val d = datei
        if (r == null || d == null) { ergebnis.success(null); return }
        val dauer = SystemClock.elapsedRealtime() - beginn
        rekorder = null
        datei = null
        try {
            r.stop()
        } catch (e: RuntimeException) {
            // MediaRecorder wirft, wenn gar nichts aufgenommen wurde (zu kurz
            // gedrueckt). Dann gibt es auch nichts zu schicken.
            r.release()
            d.delete()
            ergebnis.success(null)
            return
        }
        r.release()
        ergebnis.success(mapOf("pfad" to d.absolutePath, "ms" to dauer))
    }

    private fun verwirf() {
        val r = rekorder
        rekorder = null
        try { r?.stop() } catch (_: RuntimeException) {}
        r?.release()
        datei?.delete()
        datei = null
    }

    private fun spiele(pfad: String?, ergebnis: MethodChannel.Result) {
        halt()
        if (pfad == null) { ergebnis.success(false); return }
        try {
            spieler = MediaPlayer().apply {
                setDataSource(pfad)
                setOnCompletionListener { halt() }
                prepare()
                start()
            }
            ergebnis.success(true)
        } catch (e: Exception) {
            halt()
            ergebnis.success(false)
        }
    }

    private fun halt() {
        spieler?.let {
            try { it.stop() } catch (_: IllegalStateException) {}
            it.release()
        }
        spieler = null
    }

    /** Beim Beenden: eine laufende Aufnahme verwerfen, nichts halb liegen lassen. */
    fun raeumeAuf() {
        verwirf()
        halt()
    }
}
