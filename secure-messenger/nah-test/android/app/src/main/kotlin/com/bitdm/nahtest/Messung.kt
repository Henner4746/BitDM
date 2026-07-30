package com.bitdm.nahtest

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import java.util.UUID
import kotlin.concurrent.thread

/**
 * WEGWERFCODE, zweite Runde. Beantwortet die drei Fragen, die der erste
 * Durchgang offengelassen hat und von denen der Entwurf der echten Schicht
 * abhaengt.
 *
 * ═══════════════════════════════════════════════════ WARUM DIESE DREI
 *
 * 1. WIE VIELE LEUCHTFEUER PASSEN IN EINE WERBUNG?
 *    Das Leuchtfeuer ist JE KONTAKT verschieden (leuchtfeuer.dart:
 *    `eigenesFuer` rechnet aus dem Geheimnis mit genau diesem Kontakt). Wer
 *    zwanzig Kontakte hat, muesste zwanzig verschiedene 6-Byte-Werte
 *    aussenden — eine BLE-Werbung traegt aber zu einem Zeitpunkt genau eine
 *    Nutzlast. Entweder man packt mehrere hinein oder man wechselt reihum
 *    durch. Das entscheidet, wie lange zwei Geraete brauchen, bis sie sich
 *    sehen, und wie viel Akku das kostet. Der Entwurf listet die Frage unter
 *    "Was noch offen ist" — geraten wird sie nicht.
 *
 * 2. GEHT EINE NACHRICHT UEBER BLE-GATT, OHNE SYSTEMDIALOG?
 *    Der erste Durchgang hat gemessen, dass Wi-Fi Direct beim ERSTEN Mal einen
 *    Systemdialog auf der Gegenseite zeigt. Fuer den Fall, um den es geht —
 *    kein Netz, eine Nachricht soll raus — ist das der Unterschied zwischen
 *    "kommt an" und "kommt an, wenn der andere gerade hinsieht und tippt".
 *    Eine Nachricht ist 400-700 Byte. Wenn GATT das ohne Dialog schafft, ist
 *    Wi-Fi Direct fuer NACHRICHTEN nicht noetig — fuer Anhaenge bleibt es.
 *    Das ist keine Umkehr von Henriks Entscheidung, sondern die Folge aus dem,
 *    was der erste Test gemessen hat.
 *
 * 3. WELCHE BLE-5-FAEHIGKEITEN HABEN DIE GERAETE WIRKLICH?
 *    `isLeExtendedAdvertisingSupported` und `leMaximumAdvertisingDataLength`
 *    entscheiden ueber Frage 1. Beide werden gern aus dem Datenblatt geraten
 *    und weichen in der Praxis ab.
 */
class Messung(private val context: Context, private val sag: (String) -> Unit) {

    companion object {
        /** Die Kennung fuer die Packungs-Probe. Andere als beim ersten Test,
         *  damit sich zwei Laeufe nicht in die Quere kommen. */
        val PACK_DIENST: ParcelUuid =
            ParcelUuid(UUID.fromString("0000b17e-0000-1000-8000-00805f9b34fb"))

        /** Die GATT-Probe: Dienst und das eine Merkmal darin. */
        val GATT_DIENST: UUID = UUID.fromString("0000b180-0000-1000-8000-00805f9b34fb")
        val GATT_MERKMAL: UUID = UUID.fromString("0000b181-0000-1000-8000-00805f9b34fb")

        /** Die Standardkennung fuer "Benachrichtigungen einschalten". */
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** So gross ist eine BitDM-Nachricht mit Umschlag und Polsterung. */
        const val NACHRICHT_BYTES = 700
    }

    private val bt get() = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = bt?.adapter

    // ═══════════════════════════════════════════════════════ 3) Faehigkeiten

    fun faehigkeiten() {
        val a = adapter
        if (a == null) {
            sag("FAEHIG: kein Bluetooth-Adapter"); return
        }
        sag("FAEHIG: erweiterte Werbung = ${a.isLeExtendedAdvertisingSupported}")
        sag("FAEHIG: groesste Werbedaten = ${a.leMaximumAdvertisingDataLength} Byte")
        sag("FAEHIG: mehrere Werbungen gleichzeitig = ${a.isMultipleAdvertisementSupported}")
        sag("FAEHIG: 2M-PHY = ${a.isLe2MPhySupported}, Coded-PHY = ${a.isLeCodedPhySupported}")
        sag("FAEHIG: periodische Werbung = ${a.isLePeriodicAdvertisingSupported}")
        sag("FAEHIG: Adresse zufaellig wechselnd = ${a.isLeAudioSupported}")

        // Die GEMELDETE Grenze. Sie stimmt nicht mit der wirklichen ueberein —
        // 100 Leuchtfeuer (600 Byte) wurden am 26.07. mit
        // ADVERTISE_FAILED_DATA_TOO_LARGE abgewiesen, obwohl hier 1650 steht.
        // Deshalb sucht `grenzeSuchen()` sie, statt sie zu glauben.
        sag("FAEHIG: gemeldete Grenze ${a.leMaximumAdvertisingDataLength} Byte " +
            "= ${(a.leMaximumAdvertisingDataLength - 8) / 6} Leuchtfeuer — " +
            "GEMELDET, nicht gemessen. 5f druecken.")

        // Bei der alten Werbung ist die Rechnung dagegen hart: 31 Byte gesamt,
        // davon 3 fuer die Flags, 4 fuer das Service-UUID-Feld (das der
        // Sucher zum Filtern braucht) und 4 fuer den Kopf der Dienstdaten.
        sag("FAEHIG: alte Werbung: 31 - 3 Flags - 4 UUID - 4 Kopf = 20 Byte " +
            "= ${20 / 6} Leuchtfeuer")
    }

    /**
     * Sucht die WIRKLICHE Obergrenze der erweiterten Werbung.
     *
     * Von oben nach unten, bis eine Groesse angenommen wird. Der Grund fuer
     * diese Messung: `leMaximumAdvertisingDataLength` meldete auf dem S25
     * 1650 Byte, und schon 600 wurden abgewiesen. Was hier herauskommt, ist
     * die Zahl, mit der die echte Schicht rechnen darf.
     */
    fun grenzeSuchen() = thread(isDaemon = true) {
        val a = adapter ?: run { sag("GRENZE: kein Adapter"); return@thread }
        val werber = a.bluetoothLeAdvertiser
            ?: run { sag("GRENZE: kein Werber"); return@thread }

        for (anzahl in intArrayOf(200, 150, 100, 80, 60, 50, 45, 40, 35, 30, 25, 20)) {
            werbungStoppen()
            Thread.sleep(150)

            val nutzlast = ByteArray(anzahl * 6)
            for (i in 0 until anzahl) {
                nutzlast[i * 6] = 0xFF.toByte()
                nutzlast[i * 6 + 1] = i.toByte()
            }
            val daten = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(PACK_DIENST)
                .addServiceData(PACK_DIENST, nutzlast)
                .build()
            val par = AdvertisingSetParameters.Builder()
                .setLegacyMode(false).setConnectable(false).setScannable(false)
                .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
                .build()

            val fertig = java.util.concurrent.CountDownLatch(1)
            var status = -99
            val rueckruf = object : AdvertisingSetCallback() {
                override fun onAdvertisingSetStarted(
                    satz: android.bluetooth.le.AdvertisingSet?, tx: Int, st: Int
                ) { status = st; fertig.countDown() }
            }
            try {
                werber.startAdvertisingSet(par, daten, null, null, null, rueckruf)
                fertig.await(2, java.util.concurrent.TimeUnit.SECONDS)
                packWerbung = rueckruf
            } catch (e: Exception) {
                status = -1
                sag("GRENZE: $anzahl (${nutzlast.size} B) — ${e.javaClass.simpleName}")
                continue
            }

            if (status == AdvertisingSetCallback.ADVERTISE_SUCCESS) {
                sag("GRENZE: --> $anzahl Leuchtfeuer (${nutzlast.size} Byte Nutzlast) " +
                    "werden ANGENOMMEN. Das ist die wirkliche Grenze.")
                werbungStoppen()
                return@thread
            }
            sag("GRENZE: $anzahl (${nutzlast.size} B) abgewiesen, Status $status")
        }
        sag("GRENZE: selbst 20 wurden abgewiesen — etwas anderes stimmt nicht.")
    }

    // ═════════════════════════════════════════ 1) Wie viele passen hinein

    private var packWerbung: AdvertisingSetCallback? = null

    /**
     * Sendet [anzahl] erfundene 6-Byte-Leuchtfeuer in EINER Werbung aus.
     *
     * Die Werte sind `ff` gefolgt von der laufenden Nummer und vier Nullen —
     * damit die Gegenseite abzaehlen kann, welche angekommen sind und ob eines
     * unterwegs abgeschnitten wurde. Echte Leuchtfeuer waeren
     * Zufallszahlen und man saehe nicht, WELCHES fehlt.
     */
    fun werbenGepackt(anzahl: Int, alteArt: Boolean) {
        val a = adapter ?: run { sag("PACK: kein Adapter"); return }
        val werber = a.bluetoothLeAdvertiser
            ?: run { sag("PACK: kein Werber — Bluetooth aus?"); return }

        werbungStoppen()

        val nutzlast = ByteArray(anzahl * 6)
        for (i in 0 until anzahl) {
            nutzlast[i * 6] = 0xFF.toByte()
            nutzlast[i * 6 + 1] = i.toByte()
        }

        // BEIDES, und das ist kein Versehen: `addServiceData` traegt die
        // Nutzlast, aber `ScanFilter.setServiceUuid` auf der Gegenseite prueft
        // das SERVICE-UUID-Feld — ein anderes Element der Werbung. Fehlt es,
        // laeuft die Suche und findet nie etwas, ohne Fehler und ohne Hinweis.
        // Genau so am 26.07. im ersten Anlauf passiert; die vier Byte, die es
        // zusaetzlich kostet, sind dagegen nichts.
        val daten = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(PACK_DIENST)
            .addServiceData(PACK_DIENST, nutzlast)
            .build()

        val einstellungen = AdvertisingSetParameters.Builder()
            .setLegacyMode(alteArt)
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
            .build()

        val rueckruf = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(
                satz: android.bluetooth.le.AdvertisingSet?, tx: Int, status: Int
            ) {
                if (status == ADVERTISE_SUCCESS) {
                    sag("PACK: sende $anzahl Leuchtfeuer (${nutzlast.size} Byte) " +
                        "in EINER ${if (alteArt) "alten" else "erweiterten"} Werbung, " +
                        "Sendeleistung $tx dBm")
                } else {
                    sag("PACK: FEHLGESCHLAGEN, Status $status" + when (status) {
                        ADVERTISE_FAILED_DATA_TOO_LARGE -> " (Nutzlast zu gross — " +
                            "genau die Grenze, die wir suchen)"
                        ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> " (Geraet kann das nicht)"
                        ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> " (zu viele Werber)"
                        ADVERTISE_FAILED_INTERNAL_ERROR -> " (interner Fehler)"
                        else -> ""
                    })
                }
            }
        }
        packWerbung = rueckruf
        try {
            werber.startAdvertisingSet(einstellungen, daten, null, null, null, rueckruf)
        } catch (e: Exception) {
            sag("PACK: startAdvertisingSet warf ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private var packSuche: ScanCallback? = null
    private var packBegonnen = 0L
    private val packGesehen = mutableSetOf<String>()

    /**
     * Sucht die gepackte Werbung und zaehlt, wie viele Leuchtfeuer ankamen.
     *
     * `setLegacy(false)` IST DER PUNKT. Ohne das sieht der Sucher
     * ausschliesslich alte Werbungen — erweiterte fehlen dann vollstaendig,
     * ohne Fehler und ohne Hinweis. Das ist dieselbe Sorte stiller Fehlschlag
     * wie das fehlende `neverForLocation` im ersten Durchgang.
     */
    fun suchenGepackt(allePhy: Boolean = true) {
        val a = adapter ?: run { sag("PACK: kein Adapter"); return }
        val sucher = a.bluetoothLeScanner
            ?: run { sag("PACK: kein Sucher"); return }

        sucheStoppen()
        packGesehen.clear()
        packBegonnen = System.currentTimeMillis()

        val filter = listOf(ScanFilter.Builder().setServiceUuid(PACK_DIENST).build())
        // PHY_LE_ALL_SUPPORTED gegen PHY_LE_1M — das ist die Messung.
        //
        // Der erste Durchgang am 26.07. fand die Gegenseite nach 52 bzw.
        // 133 ms, dieser hier nach ueber 4000 ms, und zwar bei ALTER wie bei
        // erweiterter Werbung gleichermassen. Es liegt also nicht an der Art
        // der Werbung. Der einzige weitere Unterschied ist diese Zeile: wer
        // auf allen PHYs sucht, sucht auch auf Coded PHY, und der Empfaenger
        // muss seine Zeit zwischen den Traegern aufteilen.
        val einstellungen = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setLegacy(false)
            .setPhy(if (allePhy) ScanSettings.PHY_LE_ALL_SUPPORTED
                    else android.bluetooth.BluetoothDevice.PHY_LE_1M)
            .build()

        val rueckruf = object : ScanCallback() {
            override fun onScanResult(typ: Int, treffer: ScanResult) {
                val daten = treffer.scanRecord?.getServiceData(PACK_DIENST) ?: return
                val schluessel = "${treffer.device.address}/${daten.size}"
                if (!packGesehen.add(schluessel)) return

                val ms = System.currentTimeMillis() - packBegonnen
                val stuecke = daten.size / 6
                // Nachzaehlen, ob die laufenden Nummern lueckenlos sind. Ein
                // abgeschnittenes Paket faellt sonst nicht auf.
                var lueckenlos = true
                for (i in 0 until stuecke) {
                    if (daten[i * 6] != 0xFF.toByte() || daten[i * 6 + 1] != i.toByte()) {
                        lueckenlos = false; break
                    }
                }
                sag("PACK: nach ${ms} ms — ${daten.size} Byte = $stuecke Leuchtfeuer, " +
                    "Nummern ${if (lueckenlos) "lueckenlos" else "LUECKENHAFT"}, " +
                    "${treffer.rssi} dBm, ${if (treffer.isLegacy) "alte" else "erweiterte"} Werbung")
            }

            override fun onScanFailed(fehler: Int) {
                sag("PACK: Suche fehlgeschlagen, Code $fehler")
            }
        }
        packSuche = rueckruf
        sucher.startScan(filter, einstellungen, rueckruf)
        sag("PACK: suche auf ${if (allePhy) "ALLEN PHYs" else "nur 1M-PHY"} " +
            "(erweiterte Werbung eingeschlossen) …")
    }

    // ══════════════════════════════════════════ 2) Nachricht ueber GATT

    private var server: BluetoothGattServer? = null
    private var merkmal: BluetoothGattCharacteristic? = null
    private var gattWerbung: AdvertisingSetCallback? = null

    /** Die Gegenstelle: nimmt die Nachricht an und schickt sie zurueck. */
    fun gattServer() {
        val m = bt ?: run { sag("GATT: kein BluetoothManager"); return }

        gattServerStoppen()

        val eingang = StringBuilder()
        val puffer = java.io.ByteArrayOutputStream()
        var erwartet = -1
        var begonnen = 0L

        val rueckruf = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(
                geraet: BluetoothDevice?, status: Int, neu: Int
            ) {
                sag("GATT-Server: ${geraet?.address} " +
                    if (neu == BluetoothProfile.STATE_CONNECTED) "verbunden" else "getrennt")
                if (neu == BluetoothProfile.STATE_CONNECTED) {
                    puffer.reset(); erwartet = -1; begonnen = System.nanoTime()
                }
            }

            override fun onMtuChanged(geraet: BluetoothDevice?, mtu: Int) {
                sag("GATT-Server: MTU jetzt $mtu (Nutzlast je Schreibvorgang ${mtu - 3})")
            }

            override fun onCharacteristicWriteRequest(
                geraet: BluetoothDevice?, id: Int,
                merk: BluetoothGattCharacteristic?, teilweise: Boolean,
                antwortNoetig: Boolean, versatz: Int, wert: ByteArray?
            ) {
                if (wert == null) return
                if (erwartet < 0 && wert.size >= 4) {
                    erwartet = ((wert[0].toInt() and 0xFF) shl 24) or
                        ((wert[1].toInt() and 0xFF) shl 16) or
                        ((wert[2].toInt() and 0xFF) shl 8) or
                        (wert[3].toInt() and 0xFF)
                    puffer.write(wert, 4, wert.size - 4)
                } else {
                    puffer.write(wert)
                }
                if (antwortNoetig) {
                    server?.sendResponse(geraet, id, BluetoothGatt.GATT_SUCCESS, versatz, null)
                }

                if (erwartet in 0..puffer.size()) {
                    val ms = (System.nanoTime() - begonnen) / 1_000_000.0
                    sag("GATT-Server: %d Byte vollstaendig nach %.1f ms — schicke zurueck"
                        .format(puffer.size(), ms))
                    val alles = puffer.toByteArray()
                    puffer.reset(); erwartet = -1

                    // Auch Benachrichtigungen duerfen nur EINZELN offen sein —
                    // dieselbe Falle wie beim Schreiben. Die naechste geht erst
                    // in onNotificationSent hinaus.
                    ziel = geraet
                    rueck = alles.toList().chunked(180) { it.toByteArray() }
                    rueckAn = 0
                    sendeNaechsteBenachrichtigung()
                }
            }

            private var ziel: BluetoothDevice? = null
            private var rueck: List<ByteArray> = emptyList()
            private var rueckAn = 0

            private fun sendeNaechsteBenachrichtigung() {
                val g = ziel ?: return
                val c = merkmal ?: return
                if (rueckAn >= rueck.size) return
                val teil = rueck[rueckAn]
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        server?.notifyCharacteristicChanged(g, c, false, teil)
                    } else {
                        @Suppress("DEPRECATION")
                        run {
                            c.value = teil
                            server?.notifyCharacteristicChanged(g, c, false)
                        }
                    }
                } catch (_: SecurityException) {}
            }

            override fun onNotificationSent(geraet: BluetoothDevice?, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    sag("GATT-Server: Benachrichtigung $rueckAn fehlgeschlagen ($status)")
                    return
                }
                rueckAn++
                sendeNaechsteBenachrichtigung()
            }

            override fun onDescriptorWriteRequest(
                geraet: BluetoothDevice?, id: Int, besch: BluetoothGattDescriptor?,
                teilweise: Boolean, antwortNoetig: Boolean, versatz: Int, wert: ByteArray?
            ) {
                if (antwortNoetig) {
                    server?.sendResponse(geraet, id, BluetoothGatt.GATT_SUCCESS, versatz, null)
                }
                sag("GATT-Server: Gegenstelle hat Benachrichtigungen eingeschaltet")
            }
        }

        try {
            val s = m.openGattServer(context, rueckruf)
            val dienst = BluetoothGattService(GATT_DIENST,
                BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val c = BluetoothGattCharacteristic(
                GATT_MERKMAL,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            c.addDescriptor(BluetoothGattDescriptor(CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE))
            dienst.addCharacteristic(c)
            s.addService(dienst)
            server = s
            merkmal = c
            sag("GATT-Server: laeuft, warte auf Verbindung")
        } catch (e: SecurityException) {
            sag("GATT-Server: verweigert — BLUETOOTH_CONNECT fehlt?"); return
        }

        // Verbindbar werben, damit die Gegenseite uns ueberhaupt findet.
        val werber = adapter?.bluetoothLeAdvertiser ?: return
        val daten = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(GATT_DIENST))
            .build()
        val par = AdvertisingSetParameters.Builder()
            .setLegacyMode(true)      // verbindbar + weitest kompatibel
            .setConnectable(true)
            .setScannable(true)
            .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
            .build()
        val wr = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(
                satz: android.bluetooth.le.AdvertisingSet?, tx: Int, status: Int
            ) {
                sag(if (status == ADVERTISE_SUCCESS) "GATT-Server: werbe verbindbar"
                    else "GATT-Server: Werbung fehlgeschlagen, Status $status")
            }
        }
        gattWerbung = wr
        try {
            werber.startAdvertisingSet(par, daten, null, null, null, wr)
        } catch (e: Exception) {
            sag("GATT-Server: Werbung warf ${e.javaClass.simpleName}")
        }
    }

    private var gattSuche: ScanCallback? = null
    private var gatt: BluetoothGatt? = null

    /**
     * Die andere Seite: findet den Server, verbindet, schickt [NACHRICHT_BYTES]
     * Byte und misst, wann sie zurueckkommen.
     *
     * DAS IST DIE MESSUNG, AUF DIE ES ANKOMMT: kommt hier kein Systemdialog
     * und ist die Zeit ertraeglich, braucht eine NACHRICHT kein Wi-Fi Direct.
     */
    fun gattSenden() {
        val a = adapter ?: run { sag("GATT: kein Adapter"); return }
        val sucher = a.bluetoothLeScanner ?: run { sag("GATT: kein Sucher"); return }

        val filter = listOf(ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(GATT_DIENST)).build())
        val einst = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

        val gefunden = java.util.concurrent.atomic.AtomicBoolean(false)
        val gesucht = System.currentTimeMillis()

        val rueckruf = object : ScanCallback() {
            override fun onScanResult(typ: Int, treffer: ScanResult) {
                if (!gefunden.compareAndSet(false, true)) return
                sag("GATT: Server gefunden nach ${System.currentTimeMillis() - gesucht} ms " +
                    "(${treffer.rssi} dBm) — verbinde")
                try { sucher.stopScan(this) } catch (_: Exception) {}
                verbinde(treffer.device)
            }

            override fun onScanFailed(fehler: Int) {
                sag("GATT: Suche fehlgeschlagen, Code $fehler")
            }
        }
        gattSuche = rueckruf
        sucher.startScan(filter, einst, rueckruf)
        sag("GATT: suche den Server …")
    }

    private fun verbinde(geraet: BluetoothDevice) {
        val nutzlast = ByteArray(NACHRICHT_BYTES) { (it % 251).toByte() }
        val zurueck = java.io.ByteArrayOutputStream()
        var begonnen = 0L
        var verbundenAb = 0L

        val rueckruf = object : BluetoothGattCallback() {
            /** Die ausgehandelte MTU. Bestimmt, wie gross ein Haeppchen sein
             *  darf; vor der Aushandlung sind es die 23 Byte der Norm. */
            private var mtuJetzt = 23

            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, neu: Int) {
                if (neu == BluetoothProfile.STATE_CONNECTED) {
                    verbundenAb = System.nanoTime()
                    sag("GATT: verbunden — frage groessere MTU an")
                    try { g.requestMtu(517) } catch (_: SecurityException) {}
                } else {
                    sag("GATT: getrennt (Status $status)")
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                mtuJetzt = mtu
                sag("GATT: MTU = $mtu — suche Dienste")
                try { g.discoverServices() } catch (_: SecurityException) {}
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val c = g.getService(GATT_DIENST)?.getCharacteristic(GATT_MERKMAL)
                if (c == null) { sag("GATT: Merkmal nicht gefunden"); return }
                try {
                    g.setCharacteristicNotification(c, true)
                    val d = c.getDescriptor(CCCD)
                    if (d != null) {
                        @Suppress("DEPRECATION")
                        run {
                            d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                            g.writeDescriptor(d)
                        }
                    } else {
                        schicke(g, c)
                    }
                } catch (_: SecurityException) {}
            }

            override fun onDescriptorWrite(
                g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int
            ) {
                val c = g.getService(GATT_DIENST)?.getCharacteristic(GATT_MERKMAL) ?: return
                schicke(g, c)
            }

            /** Die Haeppchen, in die die Nachricht zerfaellt, und wo wir stehen. */
            private var haeppchen: List<ByteArray> = emptyList()
            private var naechstes = 0

            private fun schicke(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
                begonnen = System.nanoTime()
                zurueck.reset()

                // Vier Byte Laenge voran, damit die Gegenstelle weiss, wann sie
                // vollstaendig ist.
                val alles = ByteArray(4 + nutzlast.size)
                alles[0] = (nutzlast.size shr 24).toByte()
                alles[1] = (nutzlast.size shr 16).toByte()
                alles[2] = (nutzlast.size shr 8).toByte()
                alles[3] = nutzlast.size.toByte()
                System.arraycopy(nutzlast, 0, alles, 4, nutzlast.size)

                // Ein Haeppchen darf MTU minus 3 Byte gross sein (drei Byte
                // gehen fuer den ATT-Kopf ab). Bei MTU 517 sind das 514 — die
                // ganze Nachricht passt damit in zwei Schreibvorgaenge.
                val groesse = (mtuJetzt - 3).coerceIn(20, 512)
                haeppchen = alles.toList().chunked(groesse) { it.toByteArray() }
                naechstes = 0
                sag("GATT: ${alles.size} Byte in ${haeppchen.size} Haeppchen " +
                    "a hoechstens $groesse Byte")
                schreibeNaechstes(g, c)
            }

            /**
             * EIN Schreibvorgang, dann warten.
             *
             * Das ist der Punkt, an dem der erste Versuch gescheitert ist: die
             * Haeppchen gingen in einer Schleife mit Thread.sleep(12) hinaus,
             * und die Gegenstelle bekam KEIN EINZIGES. BLE laesst immer nur
             * eine GATT-Operation offen; jede weitere wird abgewiesen, und
             * `writeCharacteristic` sagt das nur ueber seinen Rueckgabewert,
             * den man leicht uebersieht. Richtig ist, das naechste Haeppchen
             * erst in `onCharacteristicWrite` des vorigen loszuschicken.
             */
            private fun schreibeNaechstes(
                g: BluetoothGatt, c: BluetoothGattCharacteristic
            ) {
                if (naechstes >= haeppchen.size) {
                    sag("GATT: alle Haeppchen bestaetigt hinausgegangen")
                    return
                }
                val teil = haeppchen[naechstes]
                try {
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        g.writeCharacteristic(c, teil,
                            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                            BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        run {
                            c.value = teil
                            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                            g.writeCharacteristic(c)
                        }
                    }
                    if (!ok) sag("GATT: Haeppchen $naechstes wurde ABGEWIESEN")
                } catch (_: SecurityException) {
                    sag("GATT: Schreiben verweigert")
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    sag("GATT: Haeppchen $naechstes fehlgeschlagen, Status $status")
                    return
                }
                naechstes++
                schreibeNaechstes(g, c)
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicChanged(
                g: BluetoothGatt, c: BluetoothGattCharacteristic
            ) {
                @Suppress("DEPRECATION")
                val teil = c.value ?: return
                zurueck.write(teil)
                if (zurueck.size() >= nutzlast.size) {
                    val ms = (System.nanoTime() - begonnen) / 1_000_000.0
                    val gesamt = (System.nanoTime() - verbundenAb) / 1_000_000.0
                    val gleich = zurueck.toByteArray()
                        .copyOfRange(0, nutzlast.size).contentEquals(nutzlast)
                    sag(("GATT: ERGEBNIS — %d Byte hin und zurueck in %.1f ms " +
                        "(ab Verbindung %.1f ms), Inhalt %s")
                        .format(nutzlast.size, ms, gesamt,
                            if (gleich) "gleich" else "VERAENDERT"))
                    sag("GATT: --> ${if (gleich) "eine Nachricht geht ueber GATT" else "FEHLER"}" +
                        " — und es kam KEIN Systemdialog, oder?")
                }
            }
        }
        try {
            gatt = geraet.connectGatt(context, false, rueckruf,
                BluetoothDevice.TRANSPORT_LE)
        } catch (_: SecurityException) {
            sag("GATT: connectGatt verweigert")
        }
    }

    // ═══════════════════════════════════════════════════════════ Aufraeumen

    private fun werbungStoppen() {
        packWerbung?.let {
            try { adapter?.bluetoothLeAdvertiser?.stopAdvertisingSet(it) } catch (_: Exception) {}
        }
        packWerbung = null
    }

    private fun sucheStoppen() {
        packSuche?.let {
            try { adapter?.bluetoothLeScanner?.stopScan(it) } catch (_: Exception) {}
        }
        packSuche = null
    }

    private fun gattServerStoppen() {
        try { server?.close() } catch (_: Exception) {}
        server = null
        merkmal = null
        gattWerbung?.let {
            try { adapter?.bluetoothLeAdvertiser?.stopAdvertisingSet(it) } catch (_: Exception) {}
        }
        gattWerbung = null
    }

    fun allesStoppen() {
        werbungStoppen()
        sucheStoppen()
        gattServerStoppen()
        gattSuche?.let {
            try { adapter?.bluetoothLeScanner?.stopScan(it) } catch (_: Exception) {}
        }
        gattSuche = null
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
        sag("Messung: alles gestoppt")
    }
}
