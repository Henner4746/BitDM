package com.bitdm.bitdm

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher

/**
 * Prueft die native Verschluesselung gegen das, was DART ausrechnet.
 *
 * WAS DIESER TEST BEWEIST — UND WAS NICHT
 * Beide Seiten muessen bitgleich rechnen, sonst kann die eine nicht lesen, was
 * die andere geschrieben hat. Das faellt sonst erst auf einem Geraet auf, in
 * einer Lage, in der niemand mehr einen Debugger hat — und es sieht dort aus
 * wie ein Krypto-Fehler, nicht wie eine Formatabweichung.
 *
 * ABER: hier laeuft SunJCE, auf Android laeuft Conscrypt ueber BoringSSL. Was
 * dieser Test zeigt, ist die Uebereinstimmung mit den VEKTOREN und dem FORMAT
 * — also dass Tag-Lage, AAD-Behandlung und Parameter stimmen. Dass auch der
 * Anbieter auf dem Geraet dasselbe rechnet, zeigt er NICHT.
 *
 * Das prueft integration_test/anhang_tempo_test.dart auf dem Telefon selbst:
 * dort laufen native und Dart-Fassung nebeneinander und muessen Byte fuer Byte
 * dasselbe liefern. Am 26.07.2026 auf einem Galaxy S25 Ultra und einem S10
 * bestaetigt.
 *
 * Die Vektoren in Vektoren.kt hat die Dart-Fassung erzeugt
 * (app/tool/krypto_vektoren.dart). Hier laeuft javax.crypto dagegen.
 *
 * LAEUFT AUF DER JVM, ohne Geraet und ohne Emulator:
 *   cd app/android && gradlew :app:testDebugUnitTest
 *
 * Geprueft wird Stueckchiffre und NICHT KryptoKanal: der Kanal fasst
 * Looper und Handler an, und die gibt es auf der JVM nicht. Genau dafuer sind
 * die beiden getrennt.
 */
class StueckchiffreTest {

    private fun ausHex(s: String): ByteArray =
        ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun zusatz(nummer: Int, zahl: Int): ByteArray =
        "bitdm-stueck:$nummer/$zahl".toByteArray(Charsets.US_ASCII)

    @Test
    fun `verschluesselt bitgleich zur Dart-Fassung`() {
        for (v in VEKTOREN) {
            val aus = Stueckchiffre.arbeite(
                Cipher.ENCRYPT_MODE,
                ausHex(v.klar),
                ausHex(v.schluessel),
                ausHex(v.nonce),
                zusatz(v.nummer, v.zahl),
            )
            assertArrayEquals(
                "Stueck ${v.nummer}, ${v.klar.length / 2} Byte Klartext",
                ausHex(v.geheim),
                aus,
            )
        }
    }

    @Test
    fun `entschluesselt, was Dart verschluesselt hat`() {
        for (v in VEKTOREN) {
            val aus = Stueckchiffre.arbeite(
                Cipher.DECRYPT_MODE,
                ausHex(v.geheim),
                ausHex(v.schluessel),
                ausHex(v.nonce),
                zusatz(v.nummer, v.zahl),
            )
            assertArrayEquals("Stueck ${v.nummer}", ausHex(v.klar), aus)
        }
    }

    @Test
    fun `der Tag haengt hinten und ist 16 Byte lang`() {
        // Die Annahme, auf der die Bitgleichheit beruht. Sie steht als
        // eigener Test da, weil sie sonst nur in einem Kommentar behauptet
        // waere — und ein Kommentar faellt nicht um, wenn er falsch wird.
        for (v in VEKTOREN) {
            assertEquals(
                "Aufschlag bei Stueck ${v.nummer}",
                16,
                (v.geheim.length - v.klar.length) / 2,
            )
        }
    }

    @Test
    fun `ein veraenderter Zusatz laesst das Entschluesseln scheitern`() {
        // Das ist die Sicherheitszusage hinter dem AAD: das Lager darf unter
        // der Kennung von Stueck 3 nicht die Bytes von Stueck 5 ausliefern.
        // Ohne diese Bindung ginge das sauber auf und ergaebe still die
        // falsche Datei.
        val v = VEKTOREN.first { it.klar.isNotEmpty() }
        assertThrows(AEADBadTagException::class.java) {
            Stueckchiffre.arbeite(
                Cipher.DECRYPT_MODE,
                ausHex(v.geheim),
                ausHex(v.schluessel),
                ausHex(v.nonce),
                zusatz(v.nummer + 1, v.zahl),
            )
        }
    }

    @Test
    fun `ein gekipptes Bit laesst das Entschluesseln scheitern`() {
        val v = VEKTOREN.first { it.klar.length / 2 >= 16 }
        val kaputt = ausHex(v.geheim)
        kaputt[0] = (kaputt[0].toInt() xor 1).toByte()
        assertThrows(AEADBadTagException::class.java) {
            Stueckchiffre.arbeite(
                Cipher.DECRYPT_MODE,
                kaputt,
                ausHex(v.schluessel),
                ausHex(v.nonce),
                zusatz(v.nummer, v.zahl),
            )
        }
    }

    @Test
    fun `derselbe Klartext mit anderem Schluessel ergibt etwas anderes`() {
        // Klingt selbstverstaendlich und ist die Probe darauf, dass der
        // Schluessel ueberhaupt ankommt. Ein Aufruf, der ihn stillschweigend
        // verwirft, faellt sonst nirgends auf.
        val v = VEKTOREN.first { it.klar.length / 2 >= 16 }
        val andererSchluessel = ausHex(v.schluessel).copyOf()
        andererSchluessel[0] = (andererSchluessel[0].toInt() xor 0xFF).toByte()
        val aus = Stueckchiffre.arbeite(
            Cipher.ENCRYPT_MODE,
            ausHex(v.klar),
            andererSchluessel,
            ausHex(v.nonce),
            zusatz(v.nummer, v.zahl),
        )
        assertNotEquals(v.geheim, aus.joinToString("") { "%02x".format(it) })
    }

    @Test
    fun `ein grosses Stueck geht in einem Rutsch durch`() {
        // 32 MiB ist die Stueckgroesse im Betrieb. Wenn javax.crypto damit ein
        // Problem haette — Speicher, interne Grenzen —, dann hier und nicht
        // erst auf dem Telefon.
        val gross = ByteArray(32 * 1024 * 1024) { (it * 31 and 0xFF).toByte() }
        val schluessel = ByteArray(32) { it.toByte() }
        val nonce = ByteArray(12) { (it * 7).toByte() }
        val aad = zusatz(0, 1)

        val geheim = Stueckchiffre.arbeite(Cipher.ENCRYPT_MODE, gross, schluessel, nonce, aad)
        assertEquals(gross.size + 16, geheim.size)

        val wieder = Stueckchiffre.arbeite(Cipher.DECRYPT_MODE, geheim, schluessel, nonce, aad)
        assertArrayEquals(gross, wieder)
    }
}
