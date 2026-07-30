package com.bitdm.bitdm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Haelt die App am Leben, solange sie im Hintergrund empfangen soll.
 *
 * WAS DIESER DIENST TUT — UND VOR ALLEM, WAS NICHT
 * Er empfaengt selbst gar nichts. Er sorgt nur dafuer, dass Android den
 * Prozess nicht abraeumt; die Verbindung zum Relay haelt weiterhin derselbe
 * Dart-Code, der es auch im Vordergrund tut. Das ist Absicht: eine zweite,
 * eigene Empfangslogik in Kotlin waere dieselbe Arbeit noch einmal — und jede
 * Abweichung zwischen beiden waere ein Fehler, der nur im Hintergrund
 * auftritt und deshalb schwer zu finden ist.
 *
 * WARUM ES OHNE IHN NICHT GEHT
 * Android beendet den Prozess einer Anwendung im Hintergrund, sobald Speicher
 * gebraucht wird — oft schon nach Minuten. Ein Vordergrunddienst ist der
 * einzige unterstuetzte Weg, das zu verhindern, und er verlangt eine
 * dauerhaft sichtbare Benachrichtigung. Das ist kein Schoenheitsfehler,
 * sondern Absicht des Systems: eine App, die im Hintergrund laeuft, soll
 * sichtbar sein.
 *
 * WAS IN DER BENACHRICHTIGUNG STEHT
 * Nur, dass BitDM empfangsbereit ist. KEINE Absender, KEINE Anzahl, KEIN
 * Inhalt — die stuenden auf einem gesperrten Bildschirm fuer jeden lesbar da.
 * Wer eine neue Nachricht hat, bekommt eine eigene Meldung ueber den anderen
 * Kanal, und die zeigt der Nutzer selbst frei.
 */
class EmpfangsDienst : Service() {

    companion object {
        const val KANAL = "bitdm/empfang"

        /**
         * Der Draht zu Dart. Von MainActivity gesetzt, von dort auch wieder
         * genullt.
         *
         * WARUM STATISCH: der Dienst ist ein eigenes Android-Bauteil und
         * bekommt die Flutter-Maschine nicht in die Hand. Ein Weg zurueck
         * braucht er trotzdem — sonst kann er nicht sagen, dass er aufgibt,
         * und die Oberflaeche behauptet weiter "empfangsbereit".
         *
         * WARUM DAS HIER GEFAEHRLICH WAERE, wenn man es vergisst: ein
         * statischer Verweis auf einen MethodChannel haelt die
         * Flutter-Maschine und damit die ganze Activity am Leben. Deshalb
         * setzt MainActivity ihn in onDestroy ausdruecklich auf null; siehe
         * dort.
         */
        @Volatile
        var melder: MethodChannel? = null

        private const val KANAL_ID = "bitdm_empfang"
        private const val MELDUNG_ID = 4711

        const val AKTION_START = "com.bitdm.bitdm.EMPFANG_START"
        const val AKTION_STOPP = "com.bitdm.bitdm.EMPFANG_STOPP"

        /** Was unter dem Titel steht. Von Dart gesetzt, damit die Sprache stimmt. */
        const val EXTRA_TITEL = "titel"
        const val EXTRA_TEXT = "text"

        fun starte(context: Context, titel: String, text: String) {
            val absicht = Intent(context, EmpfangsDienst::class.java).apply {
                action = AKTION_START
                putExtra(EXTRA_TITEL, titel)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(absicht)
            } else {
                context.startService(absicht)
            }
        }

        fun stoppe(context: Context) {
            context.stopService(Intent(context, EmpfangsDienst::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == AKTION_STOPP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val titel = intent?.getStringExtra(EXTRA_TITEL) ?: "BitDM"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Empfangsbereit"
        legeKanalAn()

        // IN try/catch, seit Android 12 unvermeidlich.
        //
        // startForeground wirft ForegroundServiceStartNotAllowedException,
        // wenn der Dienst aus dem Hintergrund heraus gestartet werden soll und
        // die App gerade keine Erlaubnis dafuer hat — etwa nach einem
        // abgelaufenen Zeitfenster oder wenn der Nutzer die App eingeschraenkt
        // hat. Ungefangen ist das kein Fehlschlag, sondern ein Prozessabbruch.
        try {
            startForeground(MELDUNG_ID, baueMeldung(titel, text))
        } catch (e: Exception) {
            sagDart("nichtErlaubt", e.javaClass.simpleName)
            stopSelf()
            return START_NOT_STICKY
        }

        // NICHT START_STICKY: startet Android den Dienst nach einem Abschuss
        // von selbst neu, laeuft er ohne Flutter-Maschine weiter — eine
        // Benachrichtigung, hinter der nichts steht. Lieber weg als
        // vorgetaeuscht.
        return START_NOT_STICKY
    }

    /**
     * Ab Android 15 ist nach sechs Stunden Schluss.
     *
     * Ein Vordergrunddienst vom Typ `dataSync` darf seit API 35 hoechstens
     * sechs Stunden je 24-Stunden-Fenster laufen. Danach ruft das System
     * onTimeout — und wer darauf nicht mit stopSelf antwortet, bekommt wenige
     * Sekunden spaeter ein ANR: "A foreground service of type dataSync did
     * not stop within its timeout".
     *
     * DAS IST EINE GRENZE UND KEIN FEHLER, und sie gehoert offen benannt:
     * "staendig empfangen" heisst auf Android 15 und neuer "sechs Stunden am
     * Tag empfangen". Wer es rund um die Uhr braucht, nimmt den
     * Anstoss-Verteiler — der kostet keine Laufzeit, weil dabei gar nichts
     * laeuft.
     *
     * Dart bekommt Bescheid, damit die Oberflaeche den Takt sichtbar
     * zuruecknimmt. Still zu verstummen waere das Schlimmste: der Nutzer
     * glaubte weiter, er sei empfangsbereit.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        sagDart("zeitAbgelaufen", null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    /** Eine Meldung an Dart ueber den bestehenden Kanal. */
    private fun sagDart(was: String, grund: String?) {
        try {
            melder?.invokeMethod(was, grund)
        } catch (_: Exception) {
            // Kein Kanal, weil Flutter schon weg ist. Dann gibt es auch
            // niemanden mehr, dem es etwas nuetzen wuerde.
        }
    }

    private fun legeKanalAn() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(KANAL_ID) != null) return

        val kanal = NotificationChannel(
            KANAL_ID,
            "Empfangsbereitschaft",
            // NIEDRIG: kein Ton, kein Vibrieren, kein Einblenden. Diese
            // Meldung steht dauerhaft da und darf nicht stoeren; die
            // eigentlichen Nachrichten kommen ueber einen anderen Kanal.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Zeigt an, dass BitDM im Hintergrund empfangsbereit ist."
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(kanal)
    }

    private fun baueMeldung(titel: String, text: String): Notification {
        val oeffnen = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val bauer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, KANAL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return bauer
            .setContentTitle(titel)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(oeffnen)
            .setOngoing(true)
            // Auf dem Sperrbildschirm nur der Kanalname, kein Text. Selbst
            // "Empfangsbereit" verraet noch, dass jemand diese App benutzt.
            .setVisibility(Notification.VISIBILITY_SECRET)
            .build()
    }
}
