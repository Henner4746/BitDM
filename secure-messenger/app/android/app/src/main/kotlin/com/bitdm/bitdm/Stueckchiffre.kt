package com.bitdm.bitdm

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM, sonst nichts.
 *
 * ═══════════════════════════════════════ WARUM DAS VOM KANAL GETRENNT IST
 *
 * Diese Datei kennt kein Android. Kein Looper, kein Handler, kein
 * MethodChannel — nur javax.crypto, das es auf der JVM genauso gibt wie auf
 * dem Telefon.
 *
 * Das ist kein Ordnungssinn, sondern die Bedingung dafuer, dass es ueberhaupt
 * geprueft werden kann: ein Einheitentest laeuft auf der JVM, und dort ist
 * `Looper.getMainLooper()` nicht vorhanden. Der erste Anlauf hatte beides in
 * einer Klasse, und alle sieben Tests fielen mit
 *
 *   Method getMainLooper in android.os.Looper not mocked
 *
 * — nicht an der Krypto, sondern daran, dass sich das Ding nicht anfassen
 * liess, ohne halb Android hochzufahren. Wer an dieser Stelle anfaengt,
 * Android nachzubauen, prueft am Ende seine Attrappe.
 *
 * ═════════════════════════════════════════════════ WARUM ES BITGLEICH IST
 *
 * `Cipher.doFinal` liefert bei AES/GCM/NoPadding CHIFFRETEXT GEFOLGT VOM
 * 16-BYTE-TAG — genau die Anordnung, die stueck_krypto.dart von Hand
 * herstellt (cipherText, dann mac.bytes). Es gibt nichts umzusortieren.
 *
 * Bewiesen wird es in KryptoKanalTest gegen Vektoren, die die DART-Fassung
 * ausgerechnet hat (app/tool/krypto_vektoren.dart).
 */
object Stueckchiffre {

    /** 128 Bit. GCMParameterSpec will BIT, nicht Byte — der Klassiker. */
    const val TAG_BITS = 128

    const val VERFAHREN = "AES/GCM/NoPadding"

    /**
     * Wer hier wirklich rechnet.
     *
     * WARUM DAS JEMAND WISSEN MUSS: `getInstance` ohne Providernamen landet
     * auf Android bei Conscrypt (Provider 1) und damit in BoringSSL — mit den
     * AES-Befehlen der CPU. BouncyCastle steht aber als Provider 3 weiterhin
     * daneben und ist reines Java. Faellt die Wahl je auf BC, bleibt das
     * Ergebnis BITGLEICH und nur die Geschwindigkeit bricht ein.
     *
     * Genau das ist die schlimmste Sorte Rueckschritt: kein Fehler, kein
     * Test wird rot, die App ist nur zwanzigmal langsamer. Der Name steht
     * deshalb im Verbindungstest.
     */
    fun anbieter(): String =
        Cipher.getInstance(VERFAHREN).provider.name

    /**
     * [modus] ist [Cipher.ENCRYPT_MODE] oder [Cipher.DECRYPT_MODE].
     *
     * Wirft, was javax.crypto wirft — insbesondere AEADBadTagException, wenn
     * der Tag oder der Zusatz nicht passt. Das ist der Fall, den die
     * Dart-Seite als "Stueck kaputt" zeigt.
     */
    fun arbeite(
        modus: Int,
        daten: ByteArray,
        schluessel: ByteArray,
        nonce: ByteArray,
        zusatz: ByteArray,
    ): ByteArray {
        require(schluessel.size == 32) { "Schluessel ${schluessel.size} Byte statt 32" }
        // 12 Byte ist der Normalfall bei GCM und der einzige, bei dem der
        // Nonce ohne Umweg genommen wird. Andere Laengen sind erlaubt, aber
        // dann rechnet GCM sie erst um — moeglicherweise anders als die
        // Dart-Fassung. Lieber ablehnen als still auseinanderlaufen.
        require(nonce.size == 12) { "Nonce ${nonce.size} Byte statt 12" }

        val cipher = Cipher.getInstance(VERFAHREN)
        cipher.init(
            modus,
            SecretKeySpec(schluessel, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        // NACH init und VOR doFinal. Vorher wirft es, nachher wirkt es nicht
        // mehr — und ein Zusatz, der nicht wirkt, faellt beim Verschluesseln
        // nicht auf, sondern erst, wenn die Gegenseite nicht entschluesseln
        // kann.
        cipher.updateAAD(zusatz)
        return cipher.doFinal(daten)
    }
}
