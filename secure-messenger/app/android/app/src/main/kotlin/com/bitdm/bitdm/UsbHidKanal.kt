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
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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
                val daten = aufruf.argument<ByteArray>("daten")
                val v = verbindung
                val e = raus
                if (daten == null || v == null || e == null) {
                    ergebnis.error("zu", "Kein Geraet offen", null); return
                }
                // Immer volle 64 Byte. Ein kuerzerer Bericht wird vom Stick
                // verworfen, ohne dass jemand etwas meldet.
                val paket = ByteArray(PAKETGROESSE)
                System.arraycopy(daten, 0, paket, 0, minOf(daten.size, PAKETGROESSE))
                val n = v.bulkTransfer(e, paket, paket.size, 3000)
                if (n < 0) ergebnis.error("schreiben", "USB-Schreiben fehlgeschlagen", null)
                else ergebnis.success(true)
            }

            "lies" -> {
                val v = verbindung
                val e = rein
                if (v == null || e == null) {
                    ergebnis.error("zu", "Kein Geraet offen", null); return
                }
                val puffer = ByteArray(PAKETGROESSE)
                val frist = aufruf.argument<Int>("fristMs") ?: 5000
                val n = v.bulkTransfer(e, puffer, puffer.size, frist)
                if (n < 0) ergebnis.error("lesen", "Keine Antwort vom Stick", null)
                else ergebnis.success(puffer)
            }

            "schliesse" -> { schliesse(); ergebnis.success(true) }

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
                if (erteilt) oeffneJetzt(geraet, ergebnis)
                else ergebnis.error("verweigert", "Zugriff auf den Stick abgelehnt", null)
            }
            return
        }
        oeffneJetzt(geraet, ergebnis)
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

        val filter = IntentFilter(AKTION_ERLAUBNIS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(empfaenger, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(empfaenger, filter)
        }

        // FLAG_MUTABLE ist noetig: das System traegt das Ergebnis in den
        // Intent ein. Mit FLAG_IMMUTABLE kaeme die Antwort nie an.
        val absicht = PendingIntent.getBroadcast(
            context, 0, Intent(AKTION_ERLAUBNIS).setPackage(context.packageName),
            PendingIntent.FLAG_MUTABLE
        )
        usb.requestPermission(geraet, absicht)
    }

    private fun oeffneJetzt(geraet: UsbDevice, ergebnis: MethodChannel.Result) {
        schliesse()
        val v = usb.openDevice(geraet)
        if (v == null) {
            ergebnis.error("oeffnen", "Der Stick liess sich nicht oeffnen", null)
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
            ergebnis.success(true)
            return
        }

        v.close()
        ergebnis.error("schnittstelle", "Keine FIDO-Schnittstelle gefunden", null)
    }

    /** Beim Beenden der Activity: Schnittstelle wieder hergeben. */
    fun schliesseAlles() = schliesse()

    private fun schliesse() {
        schnittstelle?.let { verbindung?.releaseInterface(it) }
        verbindung?.close()
        verbindung = null
        schnittstelle = null
        rein = null
        raus = null
    }
}
