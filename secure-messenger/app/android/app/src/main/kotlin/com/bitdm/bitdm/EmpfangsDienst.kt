package com.bitdm.bitdm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
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
        startForeground(MELDUNG_ID, baueMeldung(titel, text))

        // NICHT START_STICKY: startet Android den Dienst nach einem Abschuss
        // von selbst neu, laeuft er ohne Flutter-Maschine weiter — eine
        // Benachrichtigung, hinter der nichts steht. Lieber weg als
        // vorgetaeuscht.
        return START_NOT_STICKY
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
