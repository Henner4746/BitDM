package com.bitdm.bitdm

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Setzt FLAG_SECURE fuer das Fenster.
 *
 * Die Einstellung "Screenshots blockieren" gab es in der Oberflaeche schon
 * lange — sie tat nur nichts. Ein Schalter, der Sicherheit verspricht und
 * keine liefert, ist schlimmer als gar keiner: jemand macht in dem Glauben
 * etwas, das er sonst nicht machen wuerde.
 *
 * WARUM FlutterFragmentActivity UND NICHT FlutterActivity
 * androidx.biometric verlangt eine FragmentActivity — es haengt seinen Dialog
 * als Fragment ein. FlutterActivity ist keine. Ohne diesen Wechsel gaebe es
 * keinen Anmeldedialog, und beim Antippen passierte nichts. Genau so war es
 * am 25.07.2026.
 *
 * FLAG_SECURE bewirkt dreierlei:
 *   - Screenshots und Bildschirmaufnahmen verweigert das System
 *   - in der Uebersicht zuletzt genutzter Apps erscheint statt des Inhalts
 *     eine leere Flaeche
 *   - die App laesst sich nicht auf einen externen Bildschirm spiegeln
 *
 * EHRLICH DAZUGESAGT, und die Oberflaeche sagt es auch: es hindert niemanden
 * daran, mit einem zweiten Telefon den Bildschirm abzufotografieren. Es
 * schuetzt gegen Software auf DIESEM Geraet, nicht gegen die Person davor —
 * und schon gar nicht gegen die Gegenstelle, die mitschreiben kann, was sie
 * will.
 */
class MainActivity : FlutterFragmentActivity() {

    private val kanal = "bitdm/fenster"

    private var dateiKanal: DateiKanal? = null
    private var kryptoKanal: KryptoKanal? = null
    private var nahfunk: NahfunkKanal? = null
    private var sprache: SprachKanal? = null
    private val usbKanal by lazy { UsbHidKanal(applicationContext) }

    /**
     * Die Antwort des Dateiwaehlers.
     *
     * Ueber onActivityResult und NICHT ueber registerForActivityResult: das
     * muesste vor onStart angemeldet werden, und der Aufruf kommt spaeter —
     * naemlich dann, wenn jemand auf das Pluszeichen tippt.
     */
    @Deprecated("onActivityResult ist abgeloest, passt hier aber zum Ablauf")
    override fun onActivityResult(anfrage: Int, ergebnis: Int, daten: Intent?) {
        super.onActivityResult(anfrage, ergebnis, daten)
        if (anfrage == DateiKanal.ANFRAGE_WAEHLEN) {
            dateiKanal?.antwort(ergebnis, daten)
        }
        if (anfrage == DateiKanal.ANFRAGE_SPEICHERN) {
            dateiKanal?.gespeichert(ergebnis, daten)
        }
    }

    /**
     * Der Rueckweg der Rechteabfrage.
     *
     * Ohne ihn bleibt der Aufruf in Dart FUER IMMER haengen: `fordereRechte`
     * gibt ein Future zurueck, das nur hier aufgeloest wird. Die Oberflaeche
     * saehe dann dauerhaft "wird gefragt", waehrend der Dialog laengst
     * weggetippt ist.
     */
    override fun onRequestPermissionsResult(
        nummer: Int, rechte: Array<out String>, ergebnisse: IntArray
    ) {
        if (nahfunk?.rechteAntwort(nummer, ergebnisse) == true) return
        if (sprache?.rechteAntwort(nummer, ergebnisse) == true) return
        super.onRequestPermissionsResult(nummer, rechte, ergebnisse)
    }

    override fun onStop() {
        super.onStop()
        // Nicht mehr sichtbar: das Mikrofon aus. Siehe SprachKanal.beimVerlassen.
        sprache?.beimVerlassen()
    }

    override fun onDestroy() {
        // Offene Dateikennungen schliessen. Davon hat ein Prozess nur eine
        // begrenzte Zahl, und ein abgebrochener Versand hinterlaesst sonst
        // eine.
        dateiKanal?.raeumeAuf()
        // Eine laufende Aufnahme darf das Schliessen nicht ueberleben.
        sprache?.raeumeAuf()
        // Der Rechenfaden der Verschluesselung. Er ist als Daemon angelegt und
        // haelt den Prozess nicht auf, aber ihn stehen zu lassen waere ein
        // Leck bei jedem Neuaufbau der Activity — und die wird bei jedem
        // Drehen des Geraets neu gebaut.
        kryptoKanal?.raeumeAuf()
        // Der Stick. Ohne das bleibt die USB-Schnittstelle beansprucht, und
        // beim naechsten Start meldet das Oeffnen, sie sei belegt — von der
        // eigenen App, die es nicht mehr gibt.
        usbKanal.schliesseAlles()
        // Werbung, Suche und der GATT-Dienst laufen im Bluetooth-Stapel des
        // Systems weiter, wenn man sie nicht abmeldet — die App ist dann weg
        // und das Telefon funkt trotzdem. Das kostet Akku und verraet
        // Anwesenheit, ohne dass irgendjemand etwas davon hat.
        nahfunk?.raeumeAuf()
        // Den statischen Draht kappen. Ein MethodChannel haelt die
        // Flutter-Maschine, und die haelt diese Activity — ihn stehen zu
        // lassen waere ein Leck, das genau so gross ist wie die ganze App.
        EmpfangsDienst.melder = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // VOR dem ersten Zeichnen setzen, nicht erst wenn Dart hochgefahren
        // ist. Sonst waere das allererste Bild — und damit die Vorschau in der
        // App-Uebersicht — ungeschuetzt. Wer die Sperre nicht will, schaltet
        // sie danach ab; die andere Richtung liesse sich nicht nachholen.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // AUF EINER EIGENEN WARTESCHLANGE, nicht auf dem Haupt-Thread.
        //
        // `lies` wartet mit bulkTransfer bis zu fuenf Sekunden auf eine
        // Antwort des Sticks. Beruehrt der Nutzer ihn nicht oder zieht ihn
        // ab, laeuft diese Frist ganz ab — auf dem Haupt-Thread sind das
        // fuenf Sekunden Stillstand am Stueck, und Android zeigt "BitDM
        // reagiert nicht". Beim Einrichten eines Sticks passiert das zweimal
        // hintereinander.
        //
        // makeBackgroundTaskQueue liefert eine SERIELLE Warteschlange. Das
        // ist keine Nebensache: mit einem Stick spielt man Frage und Antwort,
        // und zwei gleichzeitige bulkTransfer auf demselben Endpunkt wuerden
        // sich die Pakete gegenseitig wegnehmen. Auf dieser Warteschlange
        // darf `result` auch von dort gerufen werden — die Auflage gilt nur
        // fuer den Haupt-Thread.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UsbHidKanal.KANAL,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue())
            .setMethodCallHandler(usbKanal)

        // DIESER bekommt die Activity und NICHT den Application-Context. Ein
        // Anmeldedialog braucht sie; ohne sie erscheint auf manchen Geraeten
        // gar keiner, und beim Antippen passiert nichts. Siehe
        // SchluesselfachKanal.kt.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SchluesselfachKanal.KANAL)
            .setMethodCallHandler(SchluesselfachKanal(this))

        // Auch dieser bekommt die Activity: startActivityForResult gibt es
        // auf dem Application-Context nicht, und ein Auswahldialog ohne
        // Activity waere keiner.
        // AES in der Hardware statt in Dart. Siehe KryptoKanal.kt: 16,6 MB/s
        // gegen rund 90. Faellt der Kanal aus, rechnet Dart weiter — die
        // Dart-Seite merkt es und sagt es im Verbindungstest.
        kryptoKanal = KryptoKanal()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KryptoKanal.KANAL)
            .setMethodCallHandler(kryptoKanal)

        dateiKanal = DateiKanal(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DateiKanal.KANAL)
            .setMethodCallHandler(dateiKanal)

        // "In der Naehe". Auf einer eigenen Warteschlange, nicht auf dem
        // Haupt-Thread: startScan und openGattServer gehen ueber den
        // Bluetooth-Dienst, und ein Binder-Aufruf zu einem beschaeftigten
        // Systemdienst kann hundert Millisekunden dauern. Die Warteschlange
        // ist seriell — an- und abschalten duerfen sich nicht ueberholen.
        //
        // Die Ereignisse gehen den umgekehrten Weg und muessen es NICHT: der
        // Kanal legt sie selbst auf den Haupt-Thread, weil die BLE-Rueckrufe
        // von einem Binder-Thread kommen und ein EventSink das nicht mag.
        // Die Activity, NICHT der Anwendungs-Context: ohne sie erscheint bei
        // der Rechteabfrage kein Dialog. Fuer die Funkarbeit selbst nimmt der
        // Kanal intern wieder den Anwendungs-Context — sonst haetten Werbung
        // und GATT-Dienst die Lebensdauer eines Bildschirms.
        // Sprachnachrichten. Die Activity, weil die Rechteabfrage fuer das
        // Mikrofon einen Dialog braucht. Siehe SprachKanal.kt.
        sprache = SprachKanal(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SprachKanal.KANAL)
            .setMethodCallHandler(sprache)

        nahfunk = NahfunkKanal(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NahfunkKanal.KANAL,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue())
            .setMethodCallHandler(nahfunk)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, NahfunkKanal.EREIGNISSE)
            .setStreamHandler(nahfunk)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EmpfangsDienst.KANAL)
            .setMethodCallHandler { aufruf, ergebnis ->

        // DER RUECKWEG. Der Dienst laeuft als eigenes Android-Bauteil und
        // kommt sonst nicht an Dart heran — er muss aber sagen koennen, dass
        // er aufgibt (ab Android 15 nach sechs Stunden, siehe
        // EmpfangsDienst.onTimeout). Ohne diesen Draht verstummt der Empfang
        // still, und die Oberflaeche behauptet weiter, sie sei bereit.
        EmpfangsDienst.melder = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, EmpfangsDienst.KANAL)
                when (aufruf.method) {
                    "starte" -> {
                        EmpfangsDienst.starte(
                            applicationContext,
                            aufruf.argument<String>("titel") ?: "BitDM",
                            aufruf.argument<String>("text") ?: "",
                        )
                        ergebnis.success(true)
                    }
                    "stoppe" -> {
                        EmpfangsDienst.stoppe(applicationContext)
                        ergebnis.success(true)
                    }
                    else -> ergebnis.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, kanal)
            .setMethodCallHandler { aufruf, ergebnis ->
                when (aufruf.method) {
                    "setzeScreenshotSperre" -> {
                        val an = aufruf.argument<Boolean>("an") ?: true
                        runOnUiThread {
                            if (an) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                        }
                        ergebnis.success(true)
                    }
                    // Reicht Text an den Teilen-Dialog des Systems weiter.
                    //
                    // Der Knopf "Teilen" bei der eigenen Adresse hatte bis zum
                    // 25.07.2026 ein leeres onTap — er sah aus wie ein Knopf,
                    // liess sich druecken und tat nichts.
                    //
                    // Ueber den Systemdialog und NICHT ueber ein Paket: es
                    // geht um einen einzigen Intent, und die Adresse ist
                    // ohnehin oeffentlich. Eine Abhaengigkeit dafuer waere
                    // mehr Angriffsflaeche als Nutzen.
                    // Die Akzentfarbe des Systems — fuer das Thema "Material".
                    // Ab Android 12 leitet das System sie aus dem Hintergrund-
                    // bild ab (Material You). Darunter gibt es keine, und die
                    // App nimmt ihre eigene Grundfarbe. Kein Paket dafuer: es
                    // ist eine Zeile, und jede Abhaengigkeit ist Angriffsflaeche.
                    "systemAkzent" -> {
                        if (android.os.Build.VERSION.SDK_INT >= 31) {
                            ergebnis.success(getColor(android.R.color.system_accent1_500))
                        } else {
                            ergebnis.success(null)
                        }
                    }
                    "teile" -> {
                        val text = aufruf.argument<String>("text")
                        if (text.isNullOrEmpty()) {
                            ergebnis.success(false)
                        } else {
                            val absicht = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                            }
                            startActivity(Intent.createChooser(
                                absicht, aufruf.argument<String>("titel")))
                            ergebnis.success(true)
                        }
                    }

                    // Oeffnet eine andere App, wenn sie da ist.
                    //
                    // Fuer die Anleitung zum Anstoss-Verteiler: "ntfy oeffnen"
                    // als Knopf statt als Satz. Ein Link in den App-Laden
                    // hilft nicht, wenn die App schon installiert ist — und
                    // genau dann braucht man sie.
                    //
                    // Gibt false zurueck, statt zu werfen: dass eine fremde
                    // App fehlt, ist kein Fehler, sondern eine Antwort.
                    "oeffneApp" -> {
                        val paket = aufruf.argument<String>("paket")
                        val absicht = paket?.let {
                            packageManager.getLaunchIntentForPackage(it)
                        }
                        if (absicht == null) {
                            ergebnis.success(false)
                        } else {
                            startActivity(absicht)
                            ergebnis.success(true)
                        }
                    }
                    else -> ergebnis.notImplemented()
                }
            }
    }
}
