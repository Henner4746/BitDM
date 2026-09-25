package com.bitdm.bitdm

import android.Manifest
import android.util.Log
import android.app.Activity
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
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Die Funkstrecke fuer "In der Naehe" — Bluetooth Low Energy.
 *
 * Was hier NICHT drin steckt, ist genauso wichtig wie das, was drin steckt:
 * kein Wissen ueber Kontakte, keine Schluessel, keine Entscheidung, wohin eine
 * Nachricht geht. Diese Datei kennt Bytes und Geraeteadressen. Wer wer ist,
 * rechnet `leuchtfeuer.dart`; welchen Weg eine Nachricht nimmt, entscheidet
 * `wegwahl.dart`; wie ein Umschlag in Haeppchen zerfaellt, macht
 * `stueckelung.dart`. Alle drei sind ohne Funk pruefbar, und genau deshalb
 * sind sie nicht hier.
 *
 * ═══════════════════════════════════ JEDE ZAHL HIER IST GEMESSEN, NICHT GERATEN
 *
 * Am 26.07.2026 auf einem Galaxy S25 Ultra und einem Galaxy S10, beide
 * Android 16. Das Protokoll steht in docs/NAHBEREICH.md. Die vier Zahlen, auf
 * denen dieser Code steht:
 *
 *   240 Byte    passen in eine erweiterte Werbung. Beide Geraete melden ueber
 *               `leMaximumAdvertisingDataLength` 1650 bzw. 1024 Byte und weisen
 *               schon 270 mit ADVERTISE_FAILED_DATA_TOO_LARGE ab. Wer der
 *               gemeldeten Zahl glaubt, baut etwas, das nirgends laeuft.
 *   40 Stueck   Leuchtfeuer sind das, bei 6 Byte je Stueck.
 *   120-157 ms  bis die Gegenseite gefunden ist.
 *   202 ms      fuer 700 Byte hin und zurueck ueber GATT, ohne Systemdialog.
 *
 * ══════════════════════════════════════════════ WARUM GATT UND NICHT WI-FI DIRECT
 *
 * Wi-Fi Direct zeigt beim ersten Verbinden zweier Geraete einen Systemdialog,
 * den die Gegenseite antippen muss (gemessen; er kommt danach nie wieder,
 * auch nicht nach einem Neustart). Fuer eine NACHRICHT waere das der
 * Unterschied zwischen "kommt an" und "kommt an, wenn der andere gerade
 * hinsieht" — und der Fall, um den es geht, ist ja gerade der, in dem kein Netz
 * da ist. GATT braucht nie einen Dialog. Fuer Anhaenge bleibt Wi-Fi Direct;
 * dort ist der einmalige Dialog zumutbar, weil man ein Video bewusst schickt.
 *
 * ═══════════════════════════════════════════════════ AB ANDROID 12, MIT ABSICHT
 *
 * Die App laeuft ab Android 9. Der Naheteil nicht: unterhalb von Android 12
 * verlangt eine BLE-Suche zwingend ACCESS_FINE_LOCATION, und diese Berechtigung
 * waere in einem Messenger, der Metadaten vermeidet, die invasivste ueberhaupt.
 * Sie steht deshalb NIRGENDS im Manifest — lieber fehlt die Funktion auf alten
 * Geraeten, als dass die App nach dem Standort fragt. Ab Android 12 traegt
 * BLUETOOTH_SCAN mit `neverForLocation` das allein.
 *
 * ════════════════════════════════════════════ WER HIER ETWAS EINWERFEN KANN
 *
 * Jeder in Reichweite. Es gibt keine Anmeldung: wer funkt, funkt, und der
 * GATT-Dienst nimmt von jedem Bytes entgegen. Geschuetzt ist erst der INHALT,
 * durch die Signal-Sitzung. Diese Datei darf sich davon weder den Speicher
 * vollschreiben noch durcheinanderbringen lassen — die Schranken dafuer sitzen
 * eine Etage hoeher im `Sammler` von stueckelung.dart, und die zwei hier
 * (Hoechstzahl gleichzeitiger Gegenstellen, Hoechstmenge je Gegenstelle) sind
 * das, was auf dieser Ebene noetig ist.
 */
class NahfunkKanal(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    /**
     * Fuer alles ausser der Rechteabfrage der Anwendungs-Context.
     *
     * Ein GATT-Dienst und eine BLE-Werbung ueberleben eine gedrehte Activity;
     * haengte man sie an die Activity, haetten sie deren Lebensdauer und der
     * Bluetooth-Stapel hielte eine Referenz auf eine, die es nicht mehr gibt.
     * `requestPermissions` dagegen GEHT nur mit einer Activity — ohne sie
     * erscheint kein Dialog.
     */
    private val context: Context get() = activity.applicationContext

    companion object {
        const val KANAL = "bitdm/nahfunk"
        const val EREIGNISSE = "bitdm/nahfunk_ereignisse"

        /** Nummer fuer die Rechteabfrage. Frei gewaehlt, muss nur eindeutig
         *  innerhalb der Activity sein. */
        const val RECHTE_NUMMER = 4711

        /** Die drei, ohne die nichts geht. Alle drei ab Android 12. */
        val NOETIG = arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
        )

        /** Unter dieser Kennung werden die Leuchtfeuer ausgesendet. */
        val LEUCHTFEUER: ParcelUuid =
            ParcelUuid(UUID.fromString("0000b17d-0000-1000-8000-00805f9b34fb"))

        /** Der GATT-Dienst, ueber den die Umschlaege gehen. */
        val POST: UUID = UUID.fromString("0000b182-0000-1000-8000-00805f9b34fb")
        val POSTFACH: UUID = UUID.fromString("0000b183-0000-1000-8000-00805f9b34fb")

        /** Die Normkennung fuer "Benachrichtigungen einschalten". */
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /**
         * Wie gross die Werbung IMMER ist — gemessene Obergrenze.
         *
         * Immer, nicht hoechstens. Wer nur so viel aussendet, wie er
         * Leuchtfeuer hat, verraet ueber die Laenge der Werbung, wie viele
         * Kontakte er hat. Das ist genau die Sorte Angabe, die diese App
         * vermeidet, und Auffuellen kostet nichts.
         */
        // 240 WAREN ES, SOLANGE DIE WERBUNG NICHT VERBINDBAR WAR.
        //
        // Seit sie verbindbar ist (siehe leuchtPar), gilt eine engere Grenze,
        // und sie ist bei jedem Hersteller anders. Gemessen am 29.07.2026:
        //   S10 mit DerpFest   nimmt 240 an  (status=0)
        //   S25 Ultra, Samsung lehnt 240 ab  (status=4, INTERNAL_ERROR)
        //
        // Die Werbung des S25 startete daraufhin gar nicht — es war unsichtbar,
        // waehrend es selbst noch alles sah. Ein einseitiger Ausfall, der von
        // aussen wie ein Empfangsproblem aussieht.
        //
        // 120 ist der Wert, der auf beiden laeuft. Er kostet die Haelfte der
        // Kontakte je Werbung (20 statt 40); mehr braucht hier niemand, und
        // die Zahl laesst sich anheben, sobald sie auf mehr Geraeten gemessen
        // ist. Geraten wird sie nicht: der Rueckruf sagt es mit status != 0.
        const val WERBUNG_BYTES = 120

        const val LEUCHTFEUER_BYTES = 6

        /** Wie viele Leuchtfeuer damit in eine Werbung passen. */
        const val JE_WERBUNG = WERBUNG_BYTES / LEUCHTFEUER_BYTES  // 40

        /** Hoechstens so viele Gegenstellen gleichzeitig am GATT-Dienst. */
        const val GEGENSTELLEN_MAX = 4

        /** Hoechstens so viel darf EINE Gegenstelle unangefordert schicken,
         *  bevor sie getrennt wird. Zwei volle Umschlaege plus Rahmen. */
        const val JE_GEGENSTELLE_MAX = 150 * 1024

        /** Wer in dieser Frist nach dem Verbinden nichts schreibt, fliegt. Ohne
         *  das hielten vier stumme Gegenstellen alle Plaetze besetzt — vier
         *  billige Funkplatinen, und kein echter Kontakt kaeme mehr durch. */
        const val STUMM_MS = 10_000L

        /** Wer die Grenze ueberschreitet, bleibt so lange draussen — auch nach
         *  dem Neuverbinden. Bis 25.09.2026 setzte das Trennen den Zaehler auf
         *  null, und das Vollschreiben ging von vorn los. */
        const val SPERRE_MS = 10 * 60_000L

        /** Obergrenze je Adresse und Minute, ueber Verbindungen hinweg. */
        const val JE_MINUTE_MAX = 600 * 1024
    }

    private val hauptfaden = Handler(Looper.getMainLooper())
    private var senke: EventChannel.EventSink? = null
    private val zufall = SecureRandom()

    private val bt get() = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = bt?.adapter

    override fun onListen(argument: Any?, ereignisse: EventChannel.EventSink?) {
        senke = ereignisse
    }

    override fun onCancel(argument: Any?) {
        senke = null
    }

    /** Ein Ereignis nach Dart. Immer ueber den Haupt-Thread — ein EventSink
     *  darf von nirgendwo sonst bedient werden, und die BLE-Rueckrufe kommen
     *  auf dem Binder-Thread. */
    private fun melde(art: String, mehr: Map<String, Any?> = emptyMap()) {
        val ereignis = HashMap<String, Any?>(mehr)
        ereignis["art"] = art
        hauptfaden.post { senke?.success(ereignis) }
    }

    private fun darf(vararg rechte: String) = rechte.all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    // ══════════════════════════════════════════════════════════════ Rechte

    private var rechteWartet: MethodChannel.Result? = null

    /**
     * Fragt die drei Bluetooth-Rechte ab.
     *
     * DER RUECKGABEWERT UNTERSCHEIDET DREI FAELLE, nicht zwei — und das ist
     * der Punkt, an dem so eine Abfrage sonst unbrauchbar wird:
     *
     *   "ja"       — erteilt.
     *   "nein"     — abgelehnt, aber man darf wieder fragen.
     *   "dauerhaft"— abgelehnt und Android zeigt keinen Dialog mehr. Hier hilft
     *                nur noch der Weg ueber die Systemeinstellungen, und die
     *                Oberflaeche muss das sagen, statt einen Knopf anzubieten,
     *                bei dem sichtbar nichts passiert.
     *
     * Unterschieden wird an `shouldShowRequestPermissionRationale`: NACH einer
     * Ablehnung ist es true, solange man wieder fragen darf, und false, wenn
     * Android dichtgemacht hat.
     */
    private fun fordereRechte(ergebnis: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            ergebnis.success("zuAlt"); return
        }
        if (darf(*NOETIG)) {
            ergebnis.success("ja"); return
        }
        if (rechteWartet != null) {
            ergebnis.error("BESETZT", "es laeuft schon eine Abfrage", null); return
        }
        rechteWartet = ergebnis
        // requestPermissions gehoert auf den Haupt-Thread; dieser Kanal laeuft
        // auf einer eigenen Warteschlange.
        hauptfaden.post {
            ActivityCompat.requestPermissions(activity, NOETIG, RECHTE_NUMMER)
        }
    }

    /** Von MainActivity.onRequestPermissionsResult. Gibt true, wenn es uns galt. */
    fun rechteAntwort(nummer: Int, ergebnisse: IntArray): Boolean {
        if (nummer != RECHTE_NUMMER) return false
        val warte = rechteWartet ?: return true
        rechteWartet = null

        val alleDa = ergebnisse.isNotEmpty() &&
            ergebnisse.all { it == PackageManager.PERMISSION_GRANTED }
        if (alleDa) {
            warte.success("ja"); return true
        }
        val darfNochFragen = NOETIG.any {
            ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
        }
        warte.success(if (darfNochFragen) "nein" else "dauerhaft")
        return true
    }

    /** Oeffnet die Systemeinstellungen dieser App — der einzige Weg zurueck,
     *  wenn Android nicht mehr fragt. */
    private fun oeffneEinstellungen(ergebnis: MethodChannel.Result) {
        try {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", activity.packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
            ergebnis.success(true)
        } catch (e: Exception) {
            ergebnis.error("EINSTELLUNGEN", e.javaClass.simpleName, null)
        }
    }

    /**
     * Ob der Naheteil auf diesem Geraet ueberhaupt in Frage kommt.
     *
     * Vier Gruende, warum nicht, und alle vier muessen unterscheidbar sein:
     * die Oberflaeche sagt bei "Bluetooth ist aus" etwas anderes als bei
     * "dieses Telefon kann es nicht".
     */
    private fun zustand(): Map<String, Any?> {
        val a = adapter
        // INS PROTOKOLL, NICHT NUR ZURUECK.
        //
        // Am 29.07.2026 funkte ein S10 mit DerpFest nicht, ein S25 schon —
        // und es gab keinen Weg, diese sechs Werte von einem Geraet zu
        // erfahren, auf dem der Schalter aus bleibt. Genau dann braucht man
        // sie. Die Zeile enthaelt nichts Persoenliches: nur Faehigkeiten des
        // Geraets.
        Log.i("BitDM-Funk", "zustand: sdk=${Build.VERSION.SDK_INT}" +
            " adapter=${a != null}" +
            " ble=${context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)}" +
            " an=${a?.isEnabled == true}" +
            " werber=${a?.bluetoothLeAdvertiser != null}" +
            " erweitert=${a?.isLeExtendedAdvertisingSupported}" +
            " maxWerbung=${a?.leMaximumAdvertisingDataLength}" +
            " rechte=${darf(Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT)}")
        return mapOf(
            "zuAlt" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.S),
            "vorhanden" to (a != null &&
                context.packageManager.hasSystemFeature(
                    PackageManager.FEATURE_BLUETOOTH_LE)),
            "an" to (a?.isEnabled == true),
            "rechte" to darf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT),
            "werberVorhanden" to (a?.bluetoothLeAdvertiser != null),
            // OHNE ERWEITERTE WERBUNG GEHT DER NAHBEREICH NICHT.
            //
            // Die Leuchtfeuer brauchen 120 Byte; in eine klassische Werbung
            // passen 31. Ein Geraet mit BLE 4.2 kann sie weder senden noch
            // EMPFANGEN — gemessen am 29.07.2026 mit einem ESP32: er sah die
            // klassische Postwerbung des S25, die erweiterte Leuchtwerbung
            // nie.
            //
            // Der Wert stand bisher nur in der Protokollzeile und wurde nicht
            // zurueckgegeben. Damit ginge auf so einem Geraet der Schalter an,
            // die Werbung scheiterte still, und der Nutzer saehe "Funk laeuft",
            // waehrend er fuer niemanden sichtbar ist.
            "erweitert" to (a?.isLeExtendedAdvertisingSupported ?: false),
            "jeWerbung" to JE_WERBUNG,
        )
    }

    // ════════════════════════════════════════════════════════════ Aussenden

    private var leuchtwerbung: AdvertisingSetCallback? = null
    private var postwerbung: AdvertisingSetCallback? = null

    /**
     * Sendet die eigenen Leuchtfeuer aus.
     *
     * ZWEI WERBUNGEN, und das hat einen Grund. Die erste traegt die
     * Leuchtfeuer und ist erweitert und nicht verbindbar — nur so passen
     * 240 Byte hinein. Die zweite ist eine gewoehnliche, verbindbare Werbung
     * mit nichts als der Kennung des Postdienstes; sie ist es, ueber die eine
     * Gegenstelle uns spaeter erreicht. Beide Geraete koennen mehrere
     * Werbungen gleichzeitig (gemessen), und in eine einzige bekaeme man
     * beides nicht: verbindbare Werbungen duerfen nicht so gross sein.
     */
    private fun werbeAn(leuchtfeuer: List<ByteArray>, ergebnis: MethodChannel.Result) {
        if (!darf(Manifest.permission.BLUETOOTH_ADVERTISE)) {
            ergebnis.error("RECHT", "BLUETOOTH_ADVERTISE fehlt", null); return
        }
        val werber = adapter?.bluetoothLeAdvertiser
            ?: run {
                Log.w("BitDM-Funk", "werbeAn: KEIN WERBER — bluetoothLeAdvertiser ist null")
                ergebnis.error("FUNK", "kein Werber — Bluetooth aus?", null); return
            }
        Log.i("BitDM-Funk", "werbeAn: ${leuchtfeuer.size} Leuchtfeuer")

        werbeAus()

        if (leuchtfeuer.any { it.size != LEUCHTFEUER_BYTES }) {
            ergebnis.error("FORM",
                "jedes Leuchtfeuer hat $LEUCHTFEUER_BYTES Byte", null); return
        }
        if (leuchtfeuer.size > JE_WERBUNG) {
            ergebnis.error("FORM",
                "hoechstens $JE_WERBUNG Leuchtfeuer je Werbung, hier " +
                    "${leuchtfeuer.size} — der Aufrufer muss reihum wechseln", null)
            return
        }

        // Auffuellen auf die volle Laenge. Die Fuellbytes sind echter Zufall
        // und damit von einem Leuchtfeuer nicht zu unterscheiden — das ist der
        // Sinn. Dass ein Fuellbyte-Sechser zufaellig auf einen Kontakt der
        // Gegenseite passt, hat eine Wahrscheinlichkeit von 40/2^48; und
        // selbst dann faellt es beim Schluesselaustausch auf.
        val nutzlast = ByteArray(WERBUNG_BYTES)
        zufall.nextBytes(nutzlast)
        for ((i, l) in leuchtfeuer.withIndex()) {
            System.arraycopy(l, 0, nutzlast, i * LEUCHTFEUER_BYTES, LEUCHTFEUER_BYTES)
        }

        // Die Kennung MUSS zusaetzlich als eigenes Feld hinein, nicht nur als
        // Kopf der Dienstdaten: der Sucher filtert mit
        // ScanFilter.setServiceUuid darauf. Fehlt es, laeuft seine Suche und
        // findet nie etwas — ohne Fehler, ohne Hinweis. Am 26.07. genau so
        // passiert.
        val daten = AdvertiseData.Builder()
            .setIncludeDeviceName(false)   // Der Geraetename waere eine Kennung.
            .addServiceUuid(LEUCHTFEUER)
            .addServiceData(LEUCHTFEUER, nutzlast)
            .build()

        // VERBINDBAR, UND DAS IST DER GANZE UNTERSCHIED.
        //
        // Sie stand auf `setConnectable(false)`, weil die verbindbare Rolle
        // die Postwerbung weiter unten uebernehmen sollte. Das kann nicht
        // funktionieren, und am 29.07.2026 hat es das auch nicht:
        //
        // ANDROID GIBT JEDER WERBUNG IHRE EIGENE ZUFALLSADRESSE. Der Scanner
        // filtert auf LEUCHTFEUER (weiter unten, ScanFilter), sieht also nur
        // diese hier und merkt sich IHRE Adresse. Verbinden wollte er dann zu
        // einem Sender, der Verbindungen gar nicht annimmt — gemessen:
        // "GATT 63:D7:AE:FF:5F:52: status=147" nach genau zehn Sekunden
        // Zeitueberschreitung. Alles davor war in Ordnung: beide Geraete
        // werben, beide suchen, beide ordnen das Leuchtfeuer dem richtigen
        // Kontakt zu. Es scheiterte an einer Adresse, die nie zuhoerte.
        //
        // Der alte Kommentar sagte, verbindbare Werbungen duerften nicht so
        // gross sein. Das gilt fuer KLASSISCHE Werbung — 31 Byte. Erweiterte
        // verbindbare Werbung traegt rund 250, und 240 sind es hier.
        // Ob es im Einzelfall passt, sagt der Rueckruf unten mit einem
        // Status ungleich 0; geraten wird das nicht.
        val leuchtPar = AdvertisingSetParameters.Builder()
            .setLegacyMode(false)
            .setConnectable(true)
            // Verbindbar und scannbar zugleich geht bei erweiterter Werbung
            // nicht — und scannbar braucht sie nicht: alles, was zaehlt,
            // steht schon in der Werbung selbst.
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
            .build()

        val l = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(satz: AdvertisingSet?, tx: Int, status: Int) {
                Log.i("BitDM-Funk", "leuchtwerbung gestartet: status=$status tx=$tx satz=${satz != null}")
                if (status == ADVERTISE_SUCCESS) {
                    melde("werbung", mapOf(
                        "leuchtfeuer" to leuchtfeuer.size, "bytes" to WERBUNG_BYTES))
                } else {
                    melde("fehler", mapOf("wo" to "leuchtwerbung", "status" to status))
                }
            }
        }
        leuchtwerbung = l

        val postDaten = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(POST))
            .build()
        val postPar = AdvertisingSetParameters.Builder()
            .setLegacyMode(true)       // verbindbar, und von allem gefunden
            .setConnectable(true)
            .setScannable(true)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
            .build()
        val p = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(satz: AdvertisingSet?, tx: Int, status: Int) {
                Log.i("BitDM-Funk", "postwerbung gestartet: status=$status")
                if (status != ADVERTISE_SUCCESS) {
                    melde("fehler", mapOf("wo" to "postwerbung", "status" to status))
                }
            }
        }
        postwerbung = p

        try {
            werber.startAdvertisingSet(leuchtPar, daten, null, null, null, l)
            werber.startAdvertisingSet(postPar, postDaten, null, null, null, p)
            ergebnis.success(true)
        } catch (e: Exception) {
            werbeAus()
            ergebnis.error("FUNK", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }

    private fun werbeAus() {
        val w = adapter?.bluetoothLeAdvertiser
        leuchtwerbung?.let { try { w?.stopAdvertisingSet(it) } catch (_: Exception) {} }
        postwerbung?.let { try { w?.stopAdvertisingSet(it) } catch (_: Exception) {} }
        leuchtwerbung = null
        postwerbung = null
    }

    // ═════════════════════════════════════════════════════════════════ Suchen

    private var suche: ScanCallback? = null

    /**
     * Sucht fremde Leuchtfeuer und meldet JEDEN Sechser einzeln nach Dart.
     *
     * Diese Schicht schlaegt bewusst nichts nach. Welcher Sechser zu welchem
     * Kontakt gehoert, weiss allein die `LeuchtfeuerTabelle` in Dart — und die
     * haengt an Schluesseln, die in nativem Code nichts zu suchen haben. Hier
     * werden 40 Sechser weitergereicht, von denen die meisten Fuellbytes sind;
     * das Nachschlagen ist ein Hashzugriff und kostet nichts.
     */
    private fun sucheAn(ergebnis: MethodChannel.Result) {
        if (!darf(Manifest.permission.BLUETOOTH_SCAN)) {
            ergebnis.error("RECHT", "BLUETOOTH_SCAN fehlt", null); return
        }
        val sucher = adapter?.bluetoothLeScanner
            ?: run { ergebnis.error("FUNK", "kein Sucher — Bluetooth aus?", null); return }

        sucheAus()

        val filter = listOf(ScanFilter.Builder().setServiceUuid(LEUCHTFEUER).build())

        // setLegacy(false) heisst NICHT "keine alten Werbungen", sondern
        // "alte UND neue". Die Vorgabe ist true und liefert ausschliesslich
        // alte — unsere erweiterte Leuchtwerbung faehrt daran vorbei, ohne
        // dass irgendetwas einen Fehler meldet.
        val einstellungen = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .setLegacy(false)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()

        val s = object : ScanCallback() {
            override fun onScanResult(typ: Int, treffer: ScanResult) {
                val daten = treffer.scanRecord?.getServiceData(LEUCHTFEUER)
                if (daten == null) {
                    return
                }
                if (daten.size < LEUCHTFEUER_BYTES) return

                val sechser = ArrayList<ByteArray>(daten.size / LEUCHTFEUER_BYTES)
                var i = 0
                while (i + LEUCHTFEUER_BYTES <= daten.size) {
                    sechser.add(daten.copyOfRange(i, i + LEUCHTFEUER_BYTES))
                    i += LEUCHTFEUER_BYTES
                }
                melde("gesehen", mapOf(
                    "geraet" to treffer.device.address,
                    "rssi" to treffer.rssi,
                    "leuchtfeuer" to sechser,
                ))
            }

            override fun onScanFailed(fehler: Int) {
                Log.w("BitDM-Funk", "SUCHE FEHLGESCHLAGEN: status=$fehler")
                melde("fehler", mapOf("wo" to "suche", "status" to fehler))
            }
        }
        suche = s
        try {
            Log.i("BitDM-Funk", "suche startet: ${filter.size} Filter")
            sucher.startScan(filter, einstellungen, s)
            ergebnis.success(true)
        } catch (e: Exception) {
            suche = null
            ergebnis.error("FUNK", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }

    private fun sucheAus() {
        suche?.let { try { adapter?.bluetoothLeScanner?.stopScan(it) } catch (_: Exception) {} }
        suche = null
    }

    // ══════════════════════════════════════════════════════════ Postfach

    private var server: BluetoothGattServer? = null
    private var postfach: BluetoothGattCharacteristic? = null

    /** Wie viel jede Gegenstelle bisher geschickt hat — gegen Vollschreiben.
     *  NUR ANGENOMMENE Verbindungen stehen hier; wer abgewiesen wurde, darf
     *  auch nicht schreiben. */
    private val angekommen = ConcurrentHashMap<String, Int>()

    /** Adresse -> bis wann (elapsedRealtime) sie abgewiesen wird. */
    private val gesperrt = ConcurrentHashMap<String, Long>()

    /** Adresse -> [Bytes, Beginn der Minute] — ueberlebt das Trennen. */
    private val minutenKonto = ConcurrentHashMap<String, LongArray>()

    private fun sperre(g: BluetoothDevice, adr: String, grund: String) {
        gesperrt[adr] = SystemClock.elapsedRealtime() + SPERRE_MS
        angekommen.remove(adr)
        melde("fehler", mapOf("wo" to "postfach", "geraet" to adr, "grund" to grund))
        try { server?.cancelConnection(g) } catch (_: SecurityException) {}
    }

    private fun istGesperrt(adr: String): Boolean {
        val bis = gesperrt[adr] ?: return false
        if (SystemClock.elapsedRealtime() < bis) return true
        gesperrt.remove(adr)
        return false
    }

    /** Haelt die beiden Buecher klein: abgelaufene Sperren und alte Minuten weg. */
    private fun raeumeKontenAuf() {
        val jetzt = SystemClock.elapsedRealtime()
        gesperrt.entries.removeIf { it.value <= jetzt }
        minutenKonto.entries.removeIf { jetzt - it.value[1] > 60_000L }
    }

    /**
     * Oeffnet das Postfach: einen GATT-Dienst, in den jeder in Reichweite
     * Haeppchen legen kann.
     *
     * Jedes Haeppchen geht unveraendert nach Dart. Zusammengesetzt wird es dort
     * vom `Sammler`, der die Pruefsumme kennt, doppelte Stuecke vertraegt und
     * angefangene Sendungen nach einer Frist wegwirft. Das hier nachzubauen
     * hiesse, dieselbe Buchfuehrung ein zweites Mal zu schreiben — an der
     * Stelle, an der man sie am schlechtesten pruefen kann.
     */
    private fun postfachAuf(ergebnis: MethodChannel.Result) {
        if (!darf(Manifest.permission.BLUETOOTH_CONNECT)) {
            ergebnis.error("RECHT", "BLUETOOTH_CONNECT fehlt", null); return
        }
        val m = bt ?: run { ergebnis.error("FUNK", "kein BluetoothManager", null); return }

        Log.i("BitDM-Funk", "postfach wird geoeffnet")
        postfachZu()
        angekommen.clear()

        val rueckruf = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(g: BluetoothDevice?, status: Int, neu: Int) {
                val adr = g?.address ?: return
                if (neu == BluetoothProfile.STATE_CONNECTED) {
                    raeumeKontenAuf()
                    if (istGesperrt(adr) || angekommen.size >= GEGENSTELLEN_MAX) {
                        // Mehr als eine Handvoll gleichzeitig ist kein
                        // Normalfall, sondern jemand, der etwas versucht.
                        try { server?.cancelConnection(g) } catch (_: SecurityException) {}
                        return
                    }
                    angekommen[adr] = 0
                    // Stumm verbunden = Platz besetzt. Nach der Frist raus,
                    // wenn bis dahin kein einziges Byte kam.
                    hauptfaden.postDelayed({
                        if (angekommen[adr] == 0) {
                            angekommen.remove(adr)
                            try { server?.cancelConnection(g) } catch (_: SecurityException) {}
                        }
                    }, STUMM_MS)
                } else {
                    angekommen.remove(adr)
                }
                Log.i("BitDM-Funk", "postfach: Gegenstelle $adr neu=$neu status=$status")
                melde("gegenstelle", mapOf("geraet" to adr,
                    "verbunden" to (neu == BluetoothProfile.STATE_CONNECTED)))
            }

            override fun onCharacteristicWriteRequest(
                g: BluetoothDevice?, id: Int, merk: BluetoothGattCharacteristic?,
                teilweise: Boolean, antwortNoetig: Boolean, versatz: Int, wert: ByteArray?
            ) {
                if (antwortNoetig) {
                    try {
                        server?.sendResponse(g, id, BluetoothGatt.GATT_SUCCESS, versatz, null)
                    } catch (_: SecurityException) {}
                }
                val adr = g?.address ?: return
                if (wert == null || wert.isEmpty()) return
                // Abgewiesen oder gesperrt: nichts annehmen. Bis 25.09.2026
                // nahm das Postfach auch von einer Verbindung, die es gerade
                // wegen Ueberfuellung getrennt hatte (die Trennung ist
                // asynchron), und zaehlte dabei von null.
                val stand = angekommen[adr] ?: return
                if (istGesperrt(adr)) return

                val jetzt = SystemClock.elapsedRealtime()
                val konto = minutenKonto.getOrPut(adr) { longArrayOf(0L, jetzt) }
                if (jetzt - konto[1] > 60_000L) { konto[0] = 0L; konto[1] = jetzt }
                konto[0] += wert.size.toLong()

                val bisher = stand + wert.size
                if (bisher > JE_GEGENSTELLE_MAX || konto[0] > JE_MINUTE_MAX) {
                    sperre(g, adr, "zu viel geschickt")
                    return
                }
                angekommen[adr] = bisher

                Log.i("BitDM-Funk", "postfach: ${wert.size} Byte von $adr empfangen")
                melde("stueck", mapOf("geraet" to adr, "daten" to wert))
            }

            override fun onDescriptorWriteRequest(
                g: BluetoothDevice?, id: Int, besch: BluetoothGattDescriptor?,
                teilweise: Boolean, antwortNoetig: Boolean, versatz: Int, wert: ByteArray?
            ) {
                if (antwortNoetig) {
                    try {
                        server?.sendResponse(g, id, BluetoothGatt.GATT_SUCCESS, versatz, null)
                    } catch (_: SecurityException) {}
                }
            }
        }

        try {
            val s = m.openGattServer(context, rueckruf)
                ?: run { ergebnis.error("FUNK", "GATT-Dienst nicht zu oeffnen", null); return }
            val dienst = BluetoothGattService(POST, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val c = BluetoothGattCharacteristic(
                POSTFACH,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            c.addDescriptor(BluetoothGattDescriptor(CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE))
            dienst.addCharacteristic(c)
            s.addService(dienst)
            server = s
            postfach = c
            ergebnis.success(true)
        } catch (e: SecurityException) {
            ergebnis.error("RECHT", "GATT-Dienst verweigert", null)
        }
    }

    private fun postfachZu() {
        try { server?.close() } catch (_: Exception) {}
        server = null
        postfach = null
        angekommen.clear()
    }

    // ══════════════════════════════════════════════════════════════ Senden

    /** Eine offene Sendung an eine Gegenstelle. */
    private class Zustellung(
        val geraet: String,
        val stuecke: List<ByteArray>,
        val ergebnis: MethodChannel.Result,
    ) {
        var gatt: BluetoothGatt? = null
        var merkmal: BluetoothGattCharacteristic? = null
        var an = 0
        var erledigt = false
        /** Ob schon ein Haeppchen an den Funk ging — auch ein unbestaetigtes. */
        var geschrieben = false
    }

    private val laufend = ConcurrentHashMap<String, Zustellung>()

    /**
     * Wie gross ein Haeppchen sein darf. Wird vor dem Zerlegen abgefragt.
     *
     * Sie steht erst nach der MTU-Aushandlung fest, und die geht erst nach dem
     * Verbinden. Deshalb ist das ein eigener Schritt: Dart fragt, bekommt die
     * Zahl, zerlegt damit und schickt. Eine feste Zahl zu raten hiesse, auf
     * jedem Geraet entweder Platz zu verschenken oder abgewiesen zu werden.
     */
    private fun sende(
        geraetAdresse: String, stuecke: List<ByteArray>, ergebnis: MethodChannel.Result
    ) {
        if (!darf(Manifest.permission.BLUETOOTH_CONNECT)) {
            ergebnis.error("RECHT", "BLUETOOTH_CONNECT fehlt", null); return
        }
        if (stuecke.isEmpty()) {
            ergebnis.error("FORM", "nichts zu senden", null); return
        }
        if (laufend.containsKey(geraetAdresse)) {
            ergebnis.error("BESETZT", "an $geraetAdresse laeuft schon etwas", null); return
        }
        val geraet = try {
            adapter?.getRemoteDevice(geraetAdresse)
        } catch (e: IllegalArgumentException) {
            null
        } ?: run { ergebnis.error("FORM", "unbekannte Geraeteadresse", null); return }

        Log.i("BitDM-Funk", "sende an $geraetAdresse: ${stuecke.size} Haeppchen")
        val z = Zustellung(geraetAdresse, stuecke, ergebnis)
        laufend[geraetAdresse] = z

        val rueckruf = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, neu: Int) {
                Log.i("BitDM-Funk", "GATT ${z.geraet}: status=$status neu=$neu")
                if (neu == BluetoothProfile.STATE_CONNECTED) {
                    try { g.requestMtu(517) } catch (_: SecurityException) { fertig(z, false, "Recht") }
                } else {
                    // Auch der geordnete Abschluss landet hier. `fertig` ist
                    // gegen Doppelaufruf gesichert, sonst meldete jede
                    // Zustellung zweimal.
                    fertig(z, z.an >= z.stuecke.size, "Verbindung zu ($status)")
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                // DIE STUECKE SIND SCHON ZERLEGT, die MTU steht erst jetzt
                // fest. Das ist die Reihenfolge, die BLE vorgibt, und sie
                // laesst genau zwei Moeglichkeiten: eine Groesse raten, die
                // ueberall passt (dann verschenkt man auf jedem modernen
                // Geraet das Zwanzigfache), oder pruefen und den Aufrufer neu
                // zerlegen lassen.
                //
                // Hier wird geprueft. Der Fehler traegt die nutzbare Groesse
                // mit, damit Dart genau einmal nachbessern kann statt zu
                // raten. Stillschweigend abzuschneiden waere das Schlimmste:
                // die Pruefsumme im Rahmen schluege drueben an, und der Fehler
                // saehe nach einer verdorbenen Funkstrecke aus.
                val passt = mtu - 3
                val groesstes = z.stuecke.maxOf { it.size }
                if (groesstes > passt) {
                    fertig(z, false, "ZU_GROSS:$passt")
                    return
                }
                try { g.discoverServices() } catch (_: SecurityException) { fertig(z, false, "Recht") }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val c = g.getService(POST)?.getCharacteristic(POSTFACH)
                if (c == null) {
                    fertig(z, false, "kein Postfach auf der Gegenseite"); return
                }
                z.merkmal = c
                schreibeNaechstes(z)
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fertig(z, false, "Haeppchen ${z.an} abgelehnt ($status)"); return
                }
                z.an++
                if (z.an >= z.stuecke.size) fertig(z, true, "") else schreibeNaechstes(z)
            }
        }

        try {
            z.gatt = geraet.connectGatt(context, false, rueckruf, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            fertig(z, false, "connectGatt verweigert")
        }
    }

    /**
     * EIN Schreibvorgang, dann warten.
     *
     * BLE laesst immer nur eine GATT-Operation offen. Wer die Haeppchen in
     * einer Schleife mit einer Pause dazwischen hinausschreibt, bekommt keinen
     * Fehler — `writeCharacteristic` gibt nur `false` zurueck, und die
     * Gegenstelle bekommt NICHTS. Am 26.07. genau so gemessen: 704 Byte
     * "hinausgeschrieben", drueben null Byte angekommen. Das naechste Haeppchen
     * geht deshalb erst in `onCharacteristicWrite` des vorigen hinaus.
     */
    private fun schreibeNaechstes(z: Zustellung) {
        val g = z.gatt ?: return
        val c = z.merkmal ?: return
        if (z.an >= z.stuecke.size) return
        val teil = z.stuecke[z.an]
        z.geschrieben = true
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
            if (!ok) fertig(z, false, "Haeppchen ${z.an} wurde nicht angenommen")
        } catch (e: SecurityException) {
            fertig(z, false, "Schreiben verweigert")
        }
    }

    /** Schliesst eine Zustellung ab — genau einmal. */
    private fun fertig(z: Zustellung, gelungen: Boolean, grund: String) {
        if (z.erledigt) return
        Log.i("BitDM-Funk", "zustellung ${z.geraet} fertig: gelungen=$gelungen $grund")
        z.erledigt = true
        laufend.remove(z.geraet)
        try { z.gatt?.disconnect() } catch (_: SecurityException) {}
        try { z.gatt?.close() } catch (_: SecurityException) {}
        z.gatt = null
        // Die Antwort geht ueber den Haupt-Thread: `result` darf nicht von
        // einem Binder-Thread aus gerufen werden, und genau von dort kommen
        // alle GATT-Rueckrufe.
        // VOR_SENDEN (seit 25.09.2026): scheiterte es, bevor auch nur ein
        // Haeppchen an den Funk ging (kein Postfach drueben, connectGatt
        // verweigert, Verbindung schon beim Aufbau weg), ist sicher nichts
        // angekommen. Dart (FunkFehler.nichtsHinaus) merkt sich die Naehe dann
        // nicht als "versucht" — sonst blieb die Nachricht haengen.
        val code = if (!gelungen && !z.geschrieben) "VOR_SENDEN" else "FUNK"
        hauptfaden.post {
            if (gelungen) z.ergebnis.success(true)
            else z.ergebnis.error(code, grund, null)
        }
    }

    // ═══════════════════════════════════════════════════════════════ Kanal

    fun raeumeAuf() {
        werbeAus()
        sucheAus()
        postfachZu()
        for (z in laufend.values.toList()) fertig(z, false, "App wird beendet")
        laufend.clear()
        senke = null
    }

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        // Unterhalb von Android 12 gibt es den Naheteil nicht. Der Grund steht
        // oben im Klassenkommentar: er kaeme sonst mit ACCESS_FINE_LOCATION.
        // Drei Aufrufe kommen trotzdem durch: die Oberflaeche muss auch auf
        // einem alten Geraet sagen KOENNEN, warum es nicht geht — und zwar
        // aus derselben Quelle, statt es sich selbst auszurechnen.
        val immerErlaubt =
            aufruf.method in setOf("zustand", "fordereRechte", "oeffneEinstellungen")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && !immerErlaubt) {
            ergebnis.error("ZU_ALT", "Die Naehe braucht Android 12 oder neuer", null)
            return
        }
        when (aufruf.method) {
            "zustand" -> ergebnis.success(zustand())
            "fordereRechte" -> fordereRechte(ergebnis)
            "oeffneEinstellungen" -> oeffneEinstellungen(ergebnis)

            "werbeAn" -> {
                @Suppress("UNCHECKED_CAST")
                val l = aufruf.argument<List<ByteArray>>("leuchtfeuer") ?: emptyList()
                werbeAn(l, ergebnis)
            }
            "werbeAus" -> { werbeAus(); ergebnis.success(true) }

            "sucheAn" -> sucheAn(ergebnis)
            "sucheAus" -> { sucheAus(); ergebnis.success(true) }

            "postfachAuf" -> postfachAuf(ergebnis)
            "postfachZu" -> { postfachZu(); ergebnis.success(true) }

            "sende" -> {
                val g = aufruf.argument<String>("geraet")
                @Suppress("UNCHECKED_CAST")
                val st = aufruf.argument<List<ByteArray>>("stuecke")
                if (g == null || st == null) {
                    ergebnis.error("FORM", "geraet und stuecke sind Pflicht", null)
                } else {
                    sende(g, st, ergebnis)
                }
            }

            "allesAus" -> { raeumeAuf(); ergebnis.success(true) }

            else -> ergebnis.notImplemented()
        }
    }
}
