package com.bitdm.nahtest

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import kotlin.concurrent.thread

/**
 * WEGWERFCODE. Misst, ob und wie die Nahverbindung auf echten Geraeten
 * funktioniert — und wird danach geloescht.
 *
 * Er beantwortet fuenf Fragen, die sich nicht aus der Dokumentation
 * beantworten lassen und die man nicht raten darf:
 *
 *   1. Wird ein BLE-Advertisement mit 6 Byte Nutzlast von der Gegenseite
 *      gesehen, und wie schnell?
 *   2. Baut Wi-Fi Direct eine Verbindung auf, und wie lange dauert das?
 *   3. Erscheint dabei ein Systemdialog, den die Gegenseite bestaetigen muss?
 *      (Das beantwortet der Mensch vor dem Geraet, nicht dieser Code.)
 *   4. Reisst die bestehende WLAN-Verbindung ab?
 *   5. Wie schnell sind ein paar hundert Byte drueben?
 *
 * Absichtlich ohne jede Abstraktion, ohne Fehlerbehandlung, die etwas
 * repariert, und ohne Ruecksicht auf Wiederverwendbarkeit. Alles, was hier
 * schoen waere, waere verschwendet.
 */
class NahKanal(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "nahtest/kanal"
        const val EREIGNISSE = "nahtest/ereignisse"

        /** Die Kennung, nach der gefiltert wird. Frei gewaehlt. */
        val DIENST: ParcelUuid =
            ParcelUuid(UUID.fromString("0000b17d-0000-1000-8000-00805f9b34fb"))

        /** Der Port fuer die Wi-Fi-Direct-Probe. */
        const val PORT = 8988
    }

    private var senke: EventChannel.EventSink? = null
    private val hauptfaden = Handler(Looper.getMainLooper())

    fun setzeSenke(s: EventChannel.EventSink?) {
        senke = s
    }

    /** Eine Zeile ins Protokoll der Oberflaeche. */
    private fun sag(text: String) {
        hauptfaden.post { senke?.success(text) }
    }

    // ═════════════════════════════════════════════════════════════════ BLE

    private var werbung: AdvertiseCallback? = null
    private var suche: ScanCallback? = null
    private var sucheBegonnen = 0L
    private val gesehen = mutableMapOf<String, Long>()

    private fun darf(vararg rechte: String) = rechte.all {
        ContextCompat.checkSelfPermission(context, it) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun bleWerben(code: Int, ergebnis: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !darf(Manifest.permission.BLUETOOTH_ADVERTISE)) {
            ergebnis.error("RECHT", "BLUETOOTH_ADVERTISE fehlt", null); return
        }
        val bt = context.getSystemService(BluetoothManager::class.java)
        val werber = bt?.adapter?.bluetoothLeAdvertiser
        if (werber == null) {
            ergebnis.error("BLE", "Kein BLE-Werber — Bluetooth aus?", null); return
        }

        bleWerbungStoppen()

        // 6 Byte, genau so viel wie das Leuchtfeuer spaeter braucht. Die
        // ersten zwei tragen den Code, damit sich zwei Testlaeufe im selben
        // Raum nicht verwechseln.
        val nutzlast = byteArrayOf(
            (code shr 8).toByte(), code.toByte(),
            0x42, 0x69, 0x74, 0x44,
        )

        val einstellungen = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()

        val daten = AdvertiseData.Builder()
            .setIncludeDeviceName(false) // Der Geraetename waere eine Kennung.
            .addServiceUuid(DIENST)
            .addServiceData(DIENST, nutzlast)
            .build()

        val rueckruf = object : AdvertiseCallback() {
            override fun onStartSuccess(s: AdvertiseSettings) {
                sag("BLE: Aussenden laeuft (Code ${"%04d".format(code)}, 6 Byte)")
            }

            override fun onStartFailure(fehler: Int) {
                sag("BLE: Aussenden FEHLGESCHLAGEN, Code $fehler" +
                    when (fehler) {
                        ADVERTISE_FAILED_DATA_TOO_LARGE -> " (Nutzlast zu gross)"
                        ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> " (zu viele Werber)"
                        ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> " (Geraet kann es nicht)"
                        else -> ""
                    })
            }
        }
        werbung = rueckruf
        werber.startAdvertising(einstellungen, daten, rueckruf)
        ergebnis.success(true)
    }

    private fun bleWerbungStoppen() {
        val bt = context.getSystemService(BluetoothManager::class.java)
        werbung?.let {
            try {
                bt?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(it)
            } catch (_: Exception) {}
        }
        werbung = null
    }

    private fun bleSuchen(ergebnis: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !darf(Manifest.permission.BLUETOOTH_SCAN)) {
            ergebnis.error("RECHT", "BLUETOOTH_SCAN fehlt", null); return
        }
        val bt = context.getSystemService(BluetoothManager::class.java)
        val sucher = bt?.adapter?.bluetoothLeScanner
        if (sucher == null) {
            ergebnis.error("BLE", "Kein BLE-Sucher — Bluetooth aus?", null); return
        }

        bleSucheStoppen()
        gesehen.clear()
        sucheBegonnen = System.currentTimeMillis()

        // Nach der Kennung filtern: das laesst die Hardware aussortieren und
        // ist der Unterschied zwischen "kostet Akku" und "kostet viel Akku".
        val filter = listOf(ScanFilter.Builder().setServiceUuid(DIENST).build())
        val einstellungen = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val rueckruf = object : ScanCallback() {
            override fun onScanResult(typ: Int, treffer: ScanResult) {
                val adresse = treffer.device.address
                val daten = treffer.scanRecord?.getServiceData(DIENST)
                val code = if (daten != null && daten.size >= 2) {
                    ((daten[0].toInt() and 0xFF) shl 8) or (daten[1].toInt() and 0xFF)
                } else -1

                if (gesehen.containsKey(adresse)) return
                val dauer = System.currentTimeMillis() - sucheBegonnen
                gesehen[adresse] = dauer
                sag("BLE: GEFUNDEN nach ${dauer} ms — Code ${"%04d".format(code)}, " +
                    "${treffer.rssi} dBm, ${daten?.size ?: 0} Byte Nutzlast")
            }

            override fun onScanFailed(fehler: Int) {
                sag("BLE: Suche FEHLGESCHLAGEN, Code $fehler")
            }
        }
        suche = rueckruf
        sucher.startScan(filter, einstellungen, rueckruf)
        sag("BLE: Suche laeuft, filtert auf die Kennung")
        ergebnis.success(true)
    }

    private fun bleSucheStoppen() {
        val bt = context.getSystemService(BluetoothManager::class.java)
        suche?.let {
            try {
                bt?.adapter?.bluetoothLeScanner?.stopScan(it)
            } catch (_: Exception) {}
        }
        suche = null
    }

    // ═══════════════════════════════════════════════════════ Wi-Fi Direct

    private var p2p: WifiP2pManager? = null
    private var kanal: WifiP2pManager.Channel? = null
    private var empfaenger: BroadcastReceiver? = null
    private var verbindenBegonnen = 0L
    private val gefundene = mutableListOf<WifiP2pDevice>()

    /** Was das normale WLAN gerade macht — vor und nach dem Verbinden. */
    private fun wlanZustand(): String {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val netz = cm?.activeNetwork
        val faehig = cm?.getNetworkCapabilities(netz)
        val wifi = faehig?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val internet =
            faehig?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val validiert =
            faehig?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        val wm = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager
        return "WLAN an: ${wm?.isWifiEnabled}, aktives Netz ist WLAN: $wifi, " +
            "Internet: $internet, geprueft: $validiert"
    }

    private fun p2pStart(ergebnis: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !darf(Manifest.permission.NEARBY_WIFI_DEVICES)) {
            ergebnis.error("RECHT", "NEARBY_WIFI_DEVICES fehlt", null); return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU &&
            !darf(Manifest.permission.ACCESS_FINE_LOCATION)) {
            ergebnis.error("RECHT", "ACCESS_FINE_LOCATION fehlt", null); return
        }

        sag("WLAN vorher — ${wlanZustand()}")

        val m = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (m == null) {
            ergebnis.error("P2P", "Wi-Fi Direct nicht verfuegbar", null); return
        }
        p2p = m
        kanal = m.initialize(context, Looper.getMainLooper(), null)

        empfaenger = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                when (i?.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        try {
                            m.requestPeers(kanal) { liste ->
                                gefundene.clear()
                                gefundene.addAll(liste.deviceList)
                                sag("P2P: ${liste.deviceList.size} Geraet(e): " +
                                    liste.deviceList.joinToString { d ->
                                        "${d.deviceName} (${zustandName(d.status)})"
                                    })
                            }
                        } catch (e: SecurityException) {
                            sag("P2P: requestPeers verweigert — ${e.message}")
                        }
                    }

                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        try {
                            m.requestConnectionInfo(kanal) { info -> verbunden(info) }
                        } catch (e: SecurityException) {
                            sag("P2P: requestConnectionInfo verweigert")
                        }
                    }

                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val an = i.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1) ==
                            WifiP2pManager.WIFI_P2P_STATE_ENABLED
                        sag("P2P: Wi-Fi Direct ist ${if (an) "an" else "AUS"}")
                    }
                }
            }
        }
        context.registerReceiver(empfaenger, IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        })

        try {
            m.discoverPeers(kanal, melder("discoverPeers"))
        } catch (e: SecurityException) {
            sag("P2P: discoverPeers verweigert — ${e.message}")
        }
        ergebnis.success(true)
    }

    private fun zustandName(z: Int) = when (z) {
        WifiP2pDevice.AVAILABLE -> "frei"
        WifiP2pDevice.INVITED -> "eingeladen"
        WifiP2pDevice.CONNECTED -> "verbunden"
        WifiP2pDevice.FAILED -> "fehlgeschlagen"
        WifiP2pDevice.UNAVAILABLE -> "nicht verfuegbar"
        else -> "?"
    }

    private fun melder(was: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() = sag("P2P: $was angenommen")
        override fun onFailure(grund: Int) = sag("P2P: $was ABGELEHNT, Grund $grund" +
            when (grund) {
                WifiP2pManager.P2P_UNSUPPORTED -> " (Geraet kann kein Wi-Fi Direct)"
                WifiP2pManager.BUSY -> " (beschaeftigt)"
                WifiP2pManager.ERROR -> " (allgemeiner Fehler)"
                else -> ""
            })
    }

    private fun p2pVerbinden(index: Int, ergebnis: MethodChannel.Result) {
        val m = p2p
        val k = kanal
        if (m == null || k == null || index >= gefundene.size) {
            ergebnis.error("P2P", "Kein Geraet an Position $index", null); return
        }
        val geraet = gefundene[index]
        verbindenBegonnen = System.currentTimeMillis()
        sag("P2P: verbinde mit ${geraet.deviceName} …")
        sag("   >>> JETZT AUFS ANDERE TELEFON SEHEN: kommt dort ein Dialog? <<<")

        val einstellung = WifiP2pConfig().apply {
            deviceAddress = geraet.deviceAddress
            // 0 = wir wollen NICHT unbedingt Gruppenbesitzer sein. Ueberlaesst
            // die Wahl dem System; genau das ist die Aushandlung, die
            // erfahrungsgemaess dauert.
            groupOwnerIntent = 0
        }
        try {
            m.connect(k, einstellung, melder("connect"))
        } catch (e: SecurityException) {
            sag("P2P: connect verweigert — ${e.message}")
        }
        ergebnis.success(true)
    }

    private fun verbunden(info: WifiP2pInfo) {
        if (!info.groupFormed) {
            sag("P2P: Gruppe (noch) nicht gebildet")
            return
        }
        val dauer = System.currentTimeMillis() - verbindenBegonnen
        sag("P2P: VERBUNDEN nach ${dauer} ms — " +
            if (info.isGroupOwner) "ich bin Gruppenbesitzer"
            else "Gruppenbesitzer ist ${info.groupOwnerAddress?.hostAddress}")
        sag("WLAN nachher — ${wlanZustand()}")

        if (info.isGroupOwner) {
            lauschen()
        } else {
            info.groupOwnerAddress?.hostAddress?.let { senden(it) }
        }
    }

    /** Gruppenbesitzer: nimmt die Probe entgegen und schickt sie zurueck. */
    private fun lauschen() = thread(isDaemon = true) {
        try {
            ServerSocket(PORT).use { server ->
                server.soTimeout = 60_000
                sag("Socket: warte auf Port $PORT …")
                server.accept().use { s ->
                    val ein = DataInputStream(s.getInputStream())
                    val laenge = ein.readInt()
                    val puffer = ByteArray(laenge)
                    ein.readFully(puffer)
                    sag("Socket: $laenge Byte empfangen, schicke zurueck")
                    val aus = DataOutputStream(s.getOutputStream())
                    aus.writeInt(laenge)
                    aus.write(puffer)
                    aus.flush()
                }
            }
        } catch (e: Exception) {
            sag("Socket (Besitzer): ${e.javaClass.simpleName} ${e.message}")
        }
    }

    /** Der andere: schickt 500 Byte hin und misst, wann sie zurueckkommen. */
    private fun senden(host: String) = thread(isDaemon = true) {
        // Kurz warten: der Gruppenbesitzer braucht einen Moment, bis sein
        // Socket steht. Ohne das schlaegt der erste Versuch immer fehl.
        Thread.sleep(1500)
        val nutzlast = ByteArray(500) { (it % 251).toByte() }
        repeat(3) { runde ->
            try {
                val begonnen = System.nanoTime()
                Socket().use { s ->
                    s.connect(InetSocketAddress(host, PORT), 10_000)
                    val aus = DataOutputStream(s.getOutputStream())
                    aus.writeInt(nutzlast.size)
                    aus.write(nutzlast)
                    aus.flush()

                    val ein = DataInputStream(s.getInputStream())
                    val laenge = ein.readInt()
                    val zurueck = ByteArray(laenge)
                    ein.readFully(zurueck)

                    val ms = (System.nanoTime() - begonnen) / 1_000_000.0
                    val gleich = zurueck.contentEquals(nutzlast)
                    sag("Socket: Runde ${runde + 1} — 500 Byte hin und zurueck in " +
                        "%.1f ms, Inhalt %s".format(ms, if (gleich) "gleich" else "VERAENDERT"))
                }
            } catch (e: Exception) {
                sag("Socket: Runde ${runde + 1} fehlgeschlagen — " +
                    "${e.javaClass.simpleName} ${e.message}")
            }
            Thread.sleep(500)
        }
        sag("Fertig. Alles abgeschaltet lassen? Dann 'Alles stoppen'.")
    }

    private fun allesStoppen() {
        bleWerbungStoppen()
        bleSucheStoppen()
        try {
            p2p?.let { m -> kanal?.let { k -> m.removeGroup(k, melder("removeGroup")) } }
        } catch (_: Exception) {}
        try {
            empfaenger?.let { context.unregisterReceiver(it) }
        } catch (_: Exception) {}
        empfaenger = null
        sag("Alles gestoppt. WLAN — ${wlanZustand()}")
    }

    // ═══════════════════════════════════════════════════════════════ Kanal

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        when (aufruf.method) {
            "bleWerben" -> bleWerben(aufruf.argument<Int>("code") ?: 0, ergebnis)
            "bleSuchen" -> bleSuchen(ergebnis)
            "p2pStart" -> p2pStart(ergebnis)
            "p2pVerbinden" ->
                p2pVerbinden(aufruf.argument<Int>("index") ?: 0, ergebnis)
            "wlanZustand" -> {
                sag("WLAN — ${wlanZustand()}")
                ergebnis.success(true)
            }
            "stopp" -> {
                allesStoppen()
                ergebnis.success(true)
            }
            else -> ergebnis.notImplemented()
        }
    }
}
