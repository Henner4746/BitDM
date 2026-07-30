package com.bitdm.bitdm

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Eine Datei aussuchen und eine empfangene oeffnen.
 *
 * ═══════════════════════════════ WARUM SELBST GESCHRIEBEN UND KEIN PAKET
 *
 * Es gibt Pakete dafuer. Am 26.07.2026 wurde in ihren Quelltexten
 * NACHGESEHEN, statt sie fuer gut zu halten:
 *
 *   file_picker  — FileUtils.kt, openFileStream(): kopiert die gewaehlte
 *                  Datei IMMER und BEDINGUNGSLOS in einer 8-KB-Schleife nach
 *                  cacheDir. Der zurueckgegebene Pfad zeigt auf die Kopie.
 *   file_selector — FileSelectorApiImpl.java, toFileResponse(): liest die
 *                  GANZE Datei in den Java-Heap (`new byte[size]`), ohne jede
 *                  Abschaltmoeglichkeit, und `size` kommt aus getInt() — was
 *                  oberhalb von 2 GiB gar nicht mehr stimmt.
 *
 * Bei einer 3-GB-Datei heisst das: drei Gigabyte doppelt auf dem Telefon plus
 * Kopierzeit VOR dem ersten uebertragenen Byte, im zweiten Fall ein
 * geplatzter Heap. Beides ist fuer BitDM unbrauchbar, und beides faellt bei
 * kleinen Dateien nicht auf — also erst dann, wenn es darauf ankommt.
 *
 * ═══════════════════════════ WIE MAN OHNE KOPIE AN EINE DATEI KOMMT
 *
 * Ein content://-URI ist ein Zeiger auf einen ContentProvider, keine Datei.
 * dart:io kennt ihn nicht. Der Weg fuehrt ueber den Dateideskriptor:
 *
 *   1. openFileDescriptor(uri, "r") gibt einen ParcelFileDescriptor.
 *   2. Dessen Nummer ist als /proc/self/fd/<nr> ein Pfad, den der Kern
 *      bereitstellt und den dart:io ganz gewoehnlich oeffnen kann.
 *   3. Dart oeffnet ihn und bekommt einen EIGENEN, unabhaengigen und
 *      positionierbaren Deskriptor auf dieselbe Datei. Kein Byte wird
 *      kopiert, und RandomAccessFile.setPosition() funktioniert — genau das,
 *      was der stueckweise Versand braucht.
 *   4. Danach gibt Dart den Griff zurueck und der PFD hier wird geschlossen.
 *
 * detachFd() waere der naheliegende Weg und ist der falsche: dann gehoert die
 * Nummer niemandem mehr, und wer sie nicht schliesst, verliert stillschweigend
 * Dateikennungen. Der PFD bleibt deshalb HIER in [offene] liegen, bis Dart
 * Bescheid sagt.
 *
 * ══════════════════════════════════════════════ DER FALL, DER NICHT GEHT
 *
 * Liegt die Datei bei einem Cloud-Anbieter, ist der Deskriptor eine Pipe und
 * nicht positionierbar. Das ist erkennbar — getStatSize() liefert dann -1 —
 * und wird ehrlich abgelehnt, statt heimlich drei Gigabyte in den
 * Zwischenspeicher zu schaufeln. Bei den fertigen Paketen scheitert derselbe
 * Fall genauso, nur unsichtbar.
 */
class DateiKanal(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "bitdm/dateien"
        const val ANFRAGE_WAEHLEN = 0x81D3

        /** Der Name im Manifest, mit ${applicationId} davor. */
        private const val PROVIDER = ".dateien"
    }

    /** Offene Deskriptoren, nach Griff. Siehe oben: NICHT detachFd(). */
    private val offene = mutableMapOf<String, ParcelFileDescriptor>()
    
    /** Kopien im Zwischenspeicher, je Zettel eine. Siehe waehlen(). */
    private val kopien = mutableMapOf<String, File>()

    /** Wo kopiert wird. Siehe waehlen(). Ein Faden, kein Pool: es wird
     *  ohnehin eine Datei nach der anderen ausgewaehlt, und zwei Kopien
     *  gleichzeitig wuerden sich nur die Platte streitig machen. */
    private val kopierfaden = java.util.concurrent.Executors
        .newSingleThreadExecutor { r ->
            Thread(r, "bitdm-datei").apply { isDaemon = true }
        }
    private val hauptfaden = android.os.Handler(android.os.Looper.getMainLooper())

    private var wartend: MethodChannel.Result? = null
    private var laufendeNummer = 0

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        when (aufruf.method) {
            "waehlen" -> waehlen(ergebnis)
            "gibFrei" -> {
                gibFrei(aufruf.argument<String>("zettel"))
                ergebnis.success(null)
            }
            "oeffne" -> ergebnis.success(
                oeffne(aufruf.argument<String>("pfad"), aufruf.argument<String>("name")))
            else -> ergebnis.notImplemented()
        }
    }

    private fun waehlen(ergebnis: MethodChannel.Result) {
        if (wartend != null) {
            // Zwei Auswahldialoge gleichzeitig gibt es nicht. Ohne diese
            // Zeile bliebe der erste Aufruf fuer immer haengen.
            ergebnis.error("laeuft", "Es ist schon eine Auswahl offen", null)
            return
        }
        wartend = ergebnis

        // ACTION_OPEN_DOCUMENT und NICHT ACTION_GET_CONTENT: letzteres darf
        // dem Aufrufer eine fluechtige Kopie geben und kennt keine dauerhafte
        // Freigabe. OPEN_DOCUMENT gibt einen langlebigen Zeiger auf das
        // Original — und genau das wird hier gebraucht.
        val absicht = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            activity.startActivityForResult(absicht, ANFRAGE_WAEHLEN)
        } catch (e: ActivityNotFoundException) {
            wartend = null
            ergebnis.error("keineAuswahl", "Kein Dateiwaehler auf diesem Geraet", null)
        }
    }

    /** Wird aus MainActivity.onActivityResult gerufen. */
    fun antwort(ergebnisCode: Int, daten: Intent?) {
        val warte = wartend ?: return
        wartend = null

        val uri = if (ergebnisCode == Activity.RESULT_OK) daten?.data else null
        if (uri == null) {
            // Abgebrochen. Kein Fehler — null heisst "der Nutzer wollte nicht".
            warte.success(null)
            return
        }

        try {
            // Ueberlebt den Prozesstod. Bei drei Gigabyte kein Luxus: der
            // Versand laeuft minutenlang, und ein fortgesetzter muss die
            // Quelle spaeter wiederfinden.
            activity.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // Nicht jeder Anbieter erlaubt das. Fuer den Versand jetzt sofort
            // reicht die fluechtige Freigabe aus dem Intent.
        }

        var name = "datei"
        var groesse = -1L
        try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    val gi = c.getColumnIndex(OpenableColumns.SIZE)
                    // getLong UND NICHT getInt. Genau daran zerbricht
                    // file_selector oberhalb von zwei Gigabyte.
                    if (gi >= 0 && !c.isNull(gi)) groesse = c.getLong(gi)
                }
            }
        } catch (_: Exception) {
            // Ein Anbieter, der keine Auskunft gibt. Groesse kommt dann aus
            // dem Deskriptor.
        }

        val pfd = try {
            activity.contentResolver.openFileDescriptor(uri, "r")
        } catch (e: Exception) {
            null
        }
        if (pfd == null) {
            warte.error("nichtLesbar", "Diese Datei laesst sich nicht oeffnen", null)
            return
        }

        // DER FALL, DER NICHT GEHT: eine Pipe. Kein positionierbarer
        // Deskriptor, also kein stueckweiser Versand — und stillschweigend
        // drei Gigabyte in den Zwischenspeicher zu kopieren ist keine
        // Loesung, sondern eine versteckte.
        val statGroesse = pfd.statSize
        if (statGroesse < 0) {
            pfd.close()
            warte.error("nichtAufDemGeraet",
                "Diese Datei liegt nicht auf dem Geraet. Lade sie erst herunter.", null)
            return
        }
        if (groesse < 0) groesse = statGroesse

        val zettel = "d${laufendeNummer++}"
        val ohneKopie = "/proc/self/fd/${pfd.fd}"

        // ═══════════ NACHSEHEN, OB DER KURZE WEG HIER WIRKLICH GEHT
        //
        // AM 26.07.2026 AUF EINEM ECHTEN GERAET GESCHEITERT:
        //   PathAccessException, /proc/self/fd/124, Permission denied (13)
        //
        // Der Grund steht nicht in der Anleitung zu SAF, ist aber logisch:
        // /proc/self/fd/<nr> zu OEFFNEN ist kein Duplizieren des Deskriptors,
        // sondern ein neues open() auf die dahinterliegende Datei — mit einer
        // neuen Rechtepruefung. Die Freigabe von SAF gilt aber dem URI, nicht
        // dem Pfad. Bei allem, was dem Medienspeicher gehoert (Download,
        // Bilder, alles ueber DocumentsUI), gehoert die Datei der Gruppe
        // media_rw, und diese App ist nicht darin. Ergebnis: EACCES.
        //
        // Wo es GEHT — Dateien im eigenen Bereich der App, manche Anbieter —
        // bleibt der kopierfreie Weg. Deshalb wird er nicht aufgegeben,
        // sondern geprueft: ein open() auf die ersten Bytes kostet nichts und
        // sagt die Wahrheit ueber genau diese Datei.
        val gehtOhneKopie = try {
            java.io.FileInputStream(ohneKopie).use { it.read() }
            true
        } catch (_: Exception) {
            false
        }

        if (gehtOhneKopie) {
            offene[zettel] = pfd
            warte.success(mapOf(
                // Der Kern oeffnet diesen Pfad und bekommt einen eigenen
                // Deskriptor. Solange der hier offen ist, zeigt er auf
                // dieselbe Datei.
                "pfad" to ohneKopie,
                "name" to name,
                "groesse" to groesse,
                "zettel" to zettel,
                "kopiert" to false,
            ))
            return
        }

        // ═══════════ SONST KOPIEREN — aus dem SCHON OFFENEN Deskriptor
        //
        // FileInputStream(pfd.fileDescriptor) oeffnet nichts neu, es liest aus
        // dem Deskriptor, den der ContentResolver hergegeben hat. Genau daran
        // scheitert der Weg oben, und genau deshalb geht dieser hier.
        //
        // DAS KOSTET, und zwar sichtbar: eine 3-GB-Datei liegt danach zweimal
        // auf dem Telefon, und das Kopieren laeuft vor dem ersten
        // uebertragenen Byte. Es ist trotzdem besser als die Alternative, denn
        // die Alternative war: geht nicht.
        // AUF EINEM EIGENEN FADEN, nicht hier.
        //
        // Diese Methode laeuft im Ergebnis eines onActivityResult, also auf
        // dem Haupt-Thread. Ein 2-GB-Video zu kopieren dauert dort Minuten,
        // in denen kein Bild gezeichnet und kein Tippen verarbeitet wird —
        // nach fuenf Sekunden zeigt Android "BitDM reagiert nicht". Tippt der
        // Nutzer dann auf "Schliessen", ist die Auswahl weg und die halbe
        // Kopie liegt im Zwischenspeicher.
        //
        // Der Fehler stammt vom 26.07.2026 und ist beim Beheben eines anderen
        // entstanden: der Rueckfall aufs Kopieren war richtig, nur am
        // falschen Ort. Ein Suchagent hat ihn noch am selben Tag gefunden.
        //
        // `warte` DARF NUR VOM HAUPT-THREAD gerufen werden — das ist eine
        // Auflage von Flutter, keine Empfehlung. Deshalb Executor fuer die
        // Arbeit, Handler fuer die Antwort, genau wie in KryptoKanal.kt.
        val ziel = File(activity.cacheDir, "anhang-$zettel.bin")
        val fd = pfd.fileDescriptor
        kopierfaden.execute {
            var fehler: String? = null
            try {
                java.io.FileInputStream(fd).use { ein ->
                    java.io.FileOutputStream(ziel).use { aus ->
                        ein.copyTo(aus, 1 shl 20)
                    }
                }
            } catch (e: Throwable) {
                // AUCH Throwable: bei einer vollen Platte kommt hier ein
                // IOException, bei einem zerrissenen Deskriptor auch anderes.
                // Was hier durchschlaegt, reisst sonst den Faden mit.
                fehler = e.javaClass.simpleName
                try { ziel.delete() } catch (_: Exception) {}
            } finally {
                // Der Deskriptor wird nach dem Kopieren nicht mehr gebraucht.
                try { pfd.close() } catch (_: Exception) {}
            }

            val grund = fehler
            hauptfaden.post {
                if (grund != null) {
                    warte.error("nichtLesbar",
                        "Diese Datei laesst sich nicht lesen ($grund)", null)
                } else {
                    kopien[zettel] = ziel
                    warte.success(mapOf(
                        "pfad" to ziel.absolutePath,
                        "name" to name,
                        "groesse" to ziel.length(),
                        "zettel" to zettel,
                        "kopiert" to true,
                    ))
                }
            }
        }
    }

    private fun gibFrei(zettel: String?) {
        val z = zettel ?: return
        offene.remove(z)?.let {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        // UND DIE KOPIE, falls es eine gab. Ohne das bliebe nach jedem
        // Anhang ein vollstaendiges Abbild im Zwischenspeicher liegen — bei
        // Videos in Gigabyte, und niemand wuesste, wovon das Telefon voll ist.
        kopien.remove(z)?.let {
            try {
                it.delete()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Reicht eine empfangene Datei an die App weiter, die sie oeffnen kann.
     *
     * Rueckgabe false, wenn keine kann — das ist eine Antwort und kein
     * Fehler, genau wie bei "oeffneApp" in MainActivity.
     */
    private fun oeffne(pfad: String?, name: String?): Boolean {
        val datei = pfad?.let { File(it) } ?: return false
        if (!datei.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(
                activity, activity.packageName + PROVIDER, datei)
            val absicht = Intent(Intent.ACTION_VIEW).apply {
                // FLAG_GRANT_READ_URI_PERMISSION ist der ganze Mechanismus:
                // die Ziel-App bekommt Leserecht auf GENAU diesen einen URI.
                // Ohne das Flag bekommt sie eine SecurityException, obwohl
                // der Provider stimmt. Ein Schreibrecht gibt es nicht — zum
                // Ansehen wird nicht geschrieben.
                setDataAndType(uri, mimeTyp(name ?: datei.name))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // Ueber den Auswahldialog: dann muss BitDM nicht wissen, welche
            // App es wird, und braucht deshalb auch keinen <queries>-Eintrag
            // im Manifest. Das passt zu der Entscheidung, QUERY_ALL_PACKAGES
            // zu vermeiden.
            activity.startActivity(Intent.createChooser(absicht, name))
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: IllegalArgumentException) {
            // "Failed to find configured root" — die Datei liegt ausserhalb
            // dessen, was res/xml/dateipfade.xml freigibt. Das waere ein
            // Fehler im Programm, kein Grund abzustuerzen.
            false
        }
    }

    private fun mimeTyp(name: String): String {
        val punkt = name.lastIndexOf('.')
        if (punkt <= 0 || punkt >= name.length - 1) return "*/*"
        val endung = name.substring(punkt + 1).lowercase()
        // Android leitet den Typ NICHT aus dem Inhalt ab. Bei "*/*" zeigt der
        // Auswahldialog alles, was in Frage kommt — das ist besser als ein
        // falscher Typ, der die richtige App ausschliesst.
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(endung) ?: "*/*"
    }

    /** Beim Beenden: was noch offen ist, schliessen und wegraeumen. */
    fun raeumeAuf() {
        kopierfaden.shutdown()
        for (pfd in offene.values) {
            try {
                pfd.close()
            } catch (_: Exception) {
            }
        }
        offene.clear()
        for (datei in kopien.values) {
            try {
                datei.delete()
            } catch (_: Exception) {
            }
        }
        kopien.clear()

        // AUCH WAS EIN ABSTURZ HINTERLASSEN HAT. Wer nur die eigene Liste
        // aufraeumt, laesst nach jedem harten Beenden eine Leiche liegen.
        try {
            activity.cacheDir.listFiles { f -> f.name.startsWith("anhang-") }
                ?.forEach { it.delete() }
        } catch (_: Exception) {
        }
    }
}
