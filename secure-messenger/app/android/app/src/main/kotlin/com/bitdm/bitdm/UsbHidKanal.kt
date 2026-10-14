package com.bitdm.bitdm

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Rohes Lesen und Schreiben mit einem eingesteckten Sicherheitsschluessel.
 *
 * Die Verpackung des Protokolls (CTAPHID) liegt bewusst in Dart und ist dort
 * ohne Geraet pruefbar. Hier steht nur, was ohne Android nicht geht: das
 * Geraet finden, die Erlaubnis holen, 64 Byte hin und 64 Byte zurueck.
 *
 * WIE EIN FIDO-STICK ERKANNT WIRD
 * Er meldet sich als HID-Geraet — wie eine Tastatur. Unterscheiden laesst er
 * sich an seinen Endpunkten: FIDO verlangt genau zwei Interrupt-Endpunkte mit
 * je 64 Byte Paketgroesse, einen in jede Richtung. Eine Tastatur hat nur einen
 * und kleinere Pakete.
 *
 * Sauberer waere, den Report-Deskriptor auszulesen und auf die FIDO-Kennung
 * 0xF1D0 zu pruefen. Android gibt den Deskriptor aber nicht ohne Weiteres
 * heraus, und die Endpunkt-Erkennung ist das, was auch andere Umsetzungen
 * benutzen.
 *
 * WO GEARBEITET WIRD
 * Flutter ruft onMethodCall auf dem Hauptfaden auf. Bis zum 14.10.2026 lief
 * `bulkTransfer` genau dort — und das blockiert bis zu seiner Frist: 3 s beim
 * Schreiben, beim Lesen so lange, wie Dart verlangt (5 s Vorgabe). In der Zeit
 * zeichnete die App nichts und nahm keine Eingabe an; ab 5 s meldet Android
 * "App reagiert nicht" (Pruefung vom 14.10.2026, B1; zuerst gefunden am
 * 26.07.2026).
 *
 * Jetzt laeuft ALLES, was die Verbindung anfasst — oeffnen, schreiben, lesen,
 * schliessen —, auf EINEM eigenen Faden, und nur die Antwort geht zurueck auf
 * den Hauptfaden (dort muss sie hin, das verlangt Flutter). Ein Faden und kein
 * Pool: CTAPHID ist Frage und Antwort in fester Reihenfolge, zwei
 * Uebertragungen gleichzeitig wuerden die Pakete vertauschen. Und weil nur
 * dieser Faden die Felder unten schreibt, kann kein Schliessen einer laufenden
 * Uebertragung die Verbindung unter den Fuessen wegziehen.
 */
class UsbHidKanal(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "bitdm/usb_hid"
        private const val AKTION_ERLAUBNIS = "com.bitdm.bitdm.USB_ERLAUBNIS"
        private const val PAKETGROESSE = 64
    }

    private val usb: UsbManager
        get() = context.getSystemService(Context.USB_SERVICE) as UsbManager

    private var verbindung: UsbDeviceConnection? = null
    private var schnittstelle: UsbInterface? = null
    private var rein: UsbEndpoint? = null
    private var raus: UsbEndpoint? = null

    private var erlaubnisEmpfaenger: BroadcastReceiver? = null

    /** Der eine Faden fuer alles, was die Verbindung anfasst. Siehe oben. */
    private val usbFaden = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bitdm-usb").apply { isDaemon = true }
    }
    private val hauptfaden = Handler(Looper.getMainLooper())

    /** Arbeit auf den USB-Faden, Antwort zurueck auf den Hauptfaden. */
    private fun imUsbFaden(ergebnis: MethodChannel.Result, arbeit: (Antwort) -> Unit) {
        val antwort = Antwort(ergebnis)
        try {
            usbFaden.execute {
                try {
                    arbeit(antwort)
                } catch (e: Exception) {
                    // Nichts darf den Faden mit einer offenen Antwort verlassen:
                    // Dart wartete sonst fuer immer auf ein Ergebnis.
                    antwort.fehler("usb", e.message ?: e.javaClass.simpleName)
                }
            }
        } catch (_: RejectedExecutionException) {
            // Nach schliesseAlles(): die Activity ist weg.
            antwort.fehler("zu", "Kanal geschlossen")
        }
    }

    /** Antwortet genau einmal, und immer auf dem Hauptfaden. */
    private inner class Antwort(private val ergebnis: MethodChannel.Result) {
        private var fertig = false
        private fun einmal(block: () -> Unit) {
            hauptfaden.post {
                if (!fertig) {
                    fertig = true
                    block()
                }
            }
        }
        fun ok(wert: Any?) = einmal { ergebnis.success(wert) }
        fun fehler(code: String, text: String) = einmal { ergebnis.error(code, text, null) }
    }

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        when (aufruf.method) {
            "liste" -> ergebnis.success(findeSticks().map {
                mapOf(
                    "name" to it.deviceName,
                    "hersteller" to (it.manufacturerName ?: ""),
                    "produkt" to (it.productName ?: ""),
                    "vendorId" to it.vendorId,
                    "productId" to it.productId,
                )
            })

            "oeffne" -> oeffne(aufruf.argument<String>("name"), ergebnis)

            "schreibe" -> {
                // Die Argumente HIER lesen, auf dem Hauptfaden: der Aufruf
                // gehoert Flutter und gilt nur waehrend onMethodCall.
                val daten = aufruf.argument<ByteArray>("daten")
                imUsbFaden(ergebnis) { antwort ->
                    val v = verbindung
                    val e = raus
                    if (daten == null || v == null || e == null) {
                        antwort.fehler("zu", "Kein Geraet offen")
                    } else {
                        // Immer volle 64 Byte. Ein kuerzerer Bericht wird vom
                        // Stick verworfen, ohne dass jemand etwas meldet.
                        val paket = ByteArray(PAKETGROESSE)
                        System.arraycopy(daten, 0, paket, 0, minOf(daten.size, PAKETGROESSE))
                        val n = v.bulkTransfer(e, paket, paket.size, 3000)
                        if (n < 0) antwort.fehler("schreiben", "USB-Schreiben fehlgeschlagen")
                        else antwort.ok(true)
                    }
                }
            }

            "lies" -> {
                val frist = aufruf.argument<Int>("fristMs") ?: 5000
                imUsbFaden(ergebnis) { antwort ->
                    val v = verbindung
                    val e = rein
                    if (v == null || e == null) {
                        antwort.fehler("zu", "Kein Geraet offen")
                    } else {
                        val puffer = ByteArray(PAKETGROESSE)
                        val n = v.bulkTransfer(e, puffer, puffer.size, frist)
                        if (n < 0) antwort.fehler("lesen", "Keine Antwort vom Stick")
                        else antwort.ok(puffer)
                    }
                }
            }

            "schliesse" -> imUsbFaden(ergebnis) { antwort ->
                schliesse()
                antwort.ok(true)
            }

            else -> ergebnis.notImplemented()
        }
    }

    /** Alle angeschlossenen Geraete, die nach einem FIDO-Stick aussehen. */
    private fun findeSticks(): List<UsbDevice> =
        usb.deviceList.values.filter { geraet ->
            (0 until geraet.interfaceCount).any { i ->
                val s = geraet.getInterface(i)
                s.interfaceClass == UsbConstants.USB_CLASS_HID && hatFidoEndpunkte(s)
            }
        }

    private fun hatFidoEndpunkte(s: UsbInterface): Boolean {
        var hatRein = false
        var hatRaus = false
        for (i in 0 until s.endpointCount) {
            val e = s.getEndpoint(i)
            if (e.type != UsbConstants.USB_ENDPOINT_XFER_INT) continue
            if (e.maxPacketSize != PAKETGROESSE) continue
            if (e.direction == UsbConstants.USB_DIR_IN) hatRein = true else hatRaus = true
        }
        return hatRein && hatRaus
    }

    private fun oeffne(name: String?, ergebnis: MethodChannel.Result) {
        val geraet = findeSticks().firstOrNull { name == null || it.deviceName == name }
        if (geraet == null) {
            ergebnis.error("nichtGefunden", "Kein Sicherheitsschluessel eingesteckt", null)
            return
        }

        if (!usb.hasPermission(geraet)) {
            frageErlaubnis(geraet) { erteilt ->
                // DEM EXTRA NICHT GLAUBEN, sondern beim System nachfragen: der
                // Broadcast kam bis 25.09.2026 unter Android 13 von jeder App
                // an, und ein gefaelschtes "erteilt" liess openDevice mit einer
                // SecurityException auf dem Hauptfaden abstuerzen.
                if (erteilt && usb.hasPermission(geraet)) {
                    imUsbFaden(ergebnis) { antwort -> oeffneJetzt(geraet, antwort) }
                } else {
                    ergebnis.error("verweigert", "Zugriff auf den Stick abgelehnt", null)
                }
            }
            return
        }
        imUsbFaden(ergebnis) { antwort -> oeffneJetzt(geraet, antwort) }
    }

    private fun frageErlaubnis(geraet: UsbDevice, fertig: (Boolean) -> Unit) {
        erlaubnisEmpfaenger?.let { runCatching { context.unregisterReceiver(it) } }

        val empfaenger = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.action != AKTION_ERLAUBNIS) return
                runCatching { context.unregisterReceiver(this) }
                erlaubnisEmpfaenger = null
                fertig(i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        erlaubnisEmpfaenger = empfaenger

        // NICHT EXPORTIERT AUF ALLEN FASSUNGEN. ContextCompat setzt unter
        // Android 13 eine app-eigene Berechtigung auf den Empfaenger — vorher
        // konnte jede andere App ihn mit einem erfundenen Ergebnis ausloesen.
        ContextCompat.registerReceiver(
            context, empfaenger, IntentFilter(AKTION_ERLAUBNIS),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )

        // FLAG_MUTABLE ist noetig: das System traegt das Ergebnis in den
        // Intent ein. Mit FLAG_IMMUTABLE kaeme die Antwort nie an.
        val absicht = PendingIntent.getBroadcast(
            context, 0, Intent(AKTION_ERLAUBNIS).setPackage(context.packageName),
            PendingIntent.FLAG_MUTABLE
        )
        usb.requestPermission(geraet, absicht)
    }

    /** Nur auf dem USB-Faden aufrufen. */
    private fun oeffneJetzt(geraet: UsbDevice, antwort: Antwort) {
        schliesse()
        val v = try {
            usb.openDevice(geraet)
        } catch (e: SecurityException) {
            null
        }
        if (v == null) {
            antwort.fehler("oeffnen", "Der Stick liess sich nicht oeffnen")
            return
        }

        for (i in 0 until geraet.interfaceCount) {
            val s = geraet.getInterface(i)
            if (s.interfaceClass != UsbConstants.USB_CLASS_HID || !hatFidoEndpunkte(s)) continue

            // force=true: Android bindet HID-Geraete selbst ein. Ohne das
            // Entreissen bekommt die App die Schnittstelle nicht.
            if (!v.claimInterface(s, true)) continue

            for (e in 0 until s.endpointCount) {
                val ep = s.getEndpoint(e)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_INT) continue
                if (ep.direction == UsbConstants.USB_DIR_IN) rein = ep else raus = ep
            }
            verbindung = v
            schnittstelle = s
            antwort.ok(true)
            return
        }

        v.close()
        antwort.fehler("schnittstelle", "Keine FIDO-Schnittstelle gefunden")
    }

    /**
     * Beim Beenden der Activity: Schnittstelle wieder hergeben.
     *
     * Ueber den USB-Faden, damit eine laufende Uebertragung erst zu Ende geht
     * (hoechstens ihre Frist) und ihr niemand die Verbindung wegschliesst.
     * Danach nimmt der Faden nichts mehr an und endet von selbst.
     */
    fun schliesseAlles() {
        erlaubnisEmpfaenger?.let { runCatching { context.unregisterReceiver(it) } }
        erlaubnisEmpfaenger = null
        try {
            usbFaden.execute { schliesse() }
        } catch (_: RejectedExecutionException) {
            // Schon geschlossen.
        }
        usbFaden.shutdown()
    }

    /** Nur auf dem USB-Faden aufrufen. */
    private fun schliesse() {
        schnittstelle?.let { verbindung?.releaseInterface(it) }
        verbindung?.close()
        verbindung = null
        schnittstelle = null
        rein = null
        raus = null
    }
}
