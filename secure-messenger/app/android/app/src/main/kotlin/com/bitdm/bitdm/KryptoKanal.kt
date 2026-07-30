package com.bitdm.bitdm

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher

/**
 * AES-256-GCM in der Hardware statt in Dart.
 *
 * ═══════════════════════════════════════════════════════ WARUM ES DAS GIBT
 *
 * Gemessen am 26.07.2026: die Dart-Fassung (package:cryptography, DartAesGcm)
 * schafft 16,6 MB/s auf einem schnellen Desktop und 5 bis 8 MB/s auf einem
 * Telefon. Wi-Fi Direct schafft 20 bis 60 MB/s. Die Verschluesselung war
 * damit der Engpass und nicht der Funk — eine 5-GB-Datei ueber die Naehe
 * waere eine Viertelstunde Rechnen fuer etwas gewesen, das der Funk in vier
 * Minuten uebertraegt.
 *
 * Jedes ARMv8-Telefon hat AES in der Hardware. javax.crypto kommt darueber an
 * sie heran, ohne dass eine Zeile Krypto neu geschrieben werden muesste.
 *
 * ══════════════════════════════════════════ WAS HIER STEHT UND WAS NICHT
 *
 * Die Rechnung selbst liegt in Stueckchiffre.kt — die Datei kennt kein
 * Android und laesst sich deshalb auf der JVM pruefen. Hier steht nur, wie
 * ein Aufruf von Dart hereinkommt, auf welchem Faden er landet und wie die
 * Antwort zurueckgeht.
 *
 * ═══════════════════════════════════════════ WARUM ES EINEN EIGENEN FADEN HAT
 *
 * Plattformkanaele werden auf dem Haupt-Thread abgearbeitet. Ein 32-MiB-Stueck
 * dauert dort auch mit Hardware noch Zehntelsekunden, und bei mehreren
 * hintereinander waere die Oberflaeche eingefroren — Android zeigt dann "App
 * reagiert nicht". Die Rechenarbeit laeuft deshalb auf einem eigenen Faden,
 * und nur die Antwort geht zurueck auf den Haupt-Thread. MethodChannel.Result
 * DARF NUR VON DORT gerufen werden; das ist keine Empfehlung, sondern eine
 * Bedingung von Flutter.
 *
 * EIN Faden und kein Pool: die Stuecke werden ohnehin nacheinander
 * verschluesselt, und ein Pool haette bei 32 MiB je Auftrag nur mehr Speicher
 * gleichzeitig belegt.
 */
class KryptoKanal : MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "bitdm/krypto"
    }

    private val faden = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bitdm-krypto").apply { isDaemon = true }
    }
    private val hauptfaden = Handler(Looper.getMainLooper())

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        when (aufruf.method) {
            // Fragt nur, ob es diesen Kanal gibt. Die Dart-Seite benutzt das,
            // um einmalig zu entscheiden, ob sie den nativen Weg nimmt —
            // statt bei jedem Stueck eine Ausnahme zu fangen.
            // Gibt den Namen des Anbieters zurueck statt nur "ja". Die
            // Dart-Seite zeigt ihn im Verbindungstest — siehe
            // Stueckchiffre.anbieter().
            "verfuegbar" -> ergebnis.success(Stueckchiffre.anbieter())

            "zu" -> rechne(aufruf, ergebnis, Cipher.ENCRYPT_MODE)
            "auf" -> rechne(aufruf, ergebnis, Cipher.DECRYPT_MODE)

            else -> ergebnis.notImplemented()
        }
    }

    private fun rechne(
        aufruf: MethodCall,
        ergebnis: MethodChannel.Result,
        modus: Int,
    ) {
        // DIE ARGUMENTE HIER LESEN, nicht im Faden: MethodCall gehoert dem
        // Haupt-Thread, und was danach passiert, arbeitet nur noch auf
        // gewoehnlichen Feldern.
        val daten = aufruf.argument<ByteArray>("daten")
        val schluessel = aufruf.argument<ByteArray>("schluessel")
        val nonce = aufruf.argument<ByteArray>("nonce")
        val zusatz = aufruf.argument<ByteArray>("zusatz")

        if (daten == null || schluessel == null || nonce == null || zusatz == null) {
            ergebnis.error("ARGUMENTE", "daten, schluessel, nonce, zusatz noetig", null)
            return
        }

        faden.execute {
            try {
                val aus = Stueckchiffre.arbeite(modus, daten, schluessel, nonce, zusatz)
                hauptfaden.post { ergebnis.success(aus) }
            } catch (e: AEADBadTagException) {
                // ZWEI FEHLERCODES, WEIL ES ZWEI ENTGEGENGESETZTE FAELLE SIND.
                //
                // Ein Stueck, das nicht aufgeht, ist die RICHTIGE Antwort auf
                // verdorbene oder vertauschte Daten — der Kanal ist dabei
                // vollkommen in Ordnung. Wer hier auf Dart zurueckfaellt,
                // rechnet dasselbe noch einmal langsam nach, bekommt dasselbe
                // Ergebnis und hat die App fuer den Rest der Sitzung
                // verlangsamt.
                //
                // Vorher stand hier ein gemeinsamer Code, und die Dart-Seite
                // unterschied die Faelle am TEXT der Java-Meldung. Ein
                // Vergleich auf einen Klassennamen in einer Zeichenkette
                // haelt genau so lange, bis jemand die Meldung anfasst.
                hauptfaden.post { ergebnis.error("KAPUTT", null, null) }
            } catch (e: Throwable) {
                // AUCH OutOfMemoryError. Bei 32 MiB Ein- und Ausgabe ist das
                // kein hypothetischer Fall, und ein Fehler, der hier
                // durchschlaegt, reisst den Faden mitsamt der App mit.
                //
                // NUR DIE ART, NICHT DIE MELDUNG. stueck_krypto.dart sagt
                // ausdruecklich, dass eine Ausnahme von hier keine Bytes
                // tragen darf — eine Java-Meldung kann Puffergroessen und
                // Bruchstuecke enthalten, und sie landet am Ende in einem
                // Fehlerbericht, den jemand weiterschickt.
                hauptfaden.post {
                    ergebnis.error("KRYPTO", e.javaClass.simpleName, null)
                }
            }
        }
    }

    fun raeumeAuf() {
        faden.shutdown()
    }
}
