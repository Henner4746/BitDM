package com.bitdm.bitdm

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Der gesicherte Bereich des Geraets, mit eigenem Anmeldedialog.
 *
 * WARUM SELBST GESCHRIEBEN UND NICHT ueber flutter_secure_storage
 * Das Paket baut seinen Dialog mit `BiometricPrompt.Builder(applicationContext)`
 * und meldet sich nie an der Activity an. Ein Anmeldedialog ohne Activity
 * erscheint auf manchen Geraeten — auf Samsung regelmaessig nicht. Dann
 * passiert beim Antippen NICHTS: kein Dialog, kein Fehler, kein Hinweis.
 * Genau so war es am 25.07.2026 auf einem S25 Ultra.
 *
 * Hier laeuft der Dialog ueber androidx.biometric und die echte Activity. Das
 * ist der von Google vorgesehene Weg, und er ist der einzige, der auf allen
 * Herstellern gleich funktioniert.
 *
 * WAS DIESER KANAL TUT
 * Er verwahrt einen 32-Byte-Fachschluessel — nicht die Identitaet. Der
 * Schluessel, mit dem verwahrt wird, entsteht im gesicherten Bereich des
 * Geraets und verlaesst ihn nie: hineingereicht werden Daten, heraus kommen
 * sie verschluesselt. Ohne Anmeldung verweigert das Geraet die Rechnung, auch
 * mit Root, auch mit der Datei in der Hand.
 *
 * ZWEI GETRENNTE SCHLUESSEL, und das ist keine Ordnungsliebe: der eine laesst
 * NUR Fingerabdruck oder Gesicht zu, der andere die Geraetesperre. Waeren es
 * dieselben, waeren es keine zwei Faktoren, sondern einer mit zwei Namen —
 * und das Entfernen des einen naehme dem anderen den Schluessel mit.
 */
class SchluesselfachKanal(private val activity: FragmentActivity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val KANAL = "bitdm/schluesselfach"

        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val UMFORMUNG = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128

        /** Nur Fingerabdruck oder Gesicht. Die Geraete-PIN ist ausgeschlossen. */
        const val ART_BIOMETRIE = "biometrie"

        /** PIN, Muster oder Passwort des Telefons. */
        const val ART_GERAETESPERRE = "geraetesperre"

        private fun alias(art: String) = "bitdm.fach.$art.v1"
    }

    override fun onMethodCall(aufruf: MethodCall, ergebnis: MethodChannel.Result) {
        val art = aufruf.argument<String>("art") ?: ART_BIOMETRIE
        when (aufruf.method) {
            "verfuegbar" -> ergebnis.success(pruefeVerfuegbar(art))

            "schreibe" -> {
                val klar = aufruf.argument<ByteArray>("wert")
                if (klar == null) {
                    ergebnis.error("ARG", "wert fehlt", null); return
                }
                verschluessele(art, klar, ergebnis)
            }

            "lies" -> {
                val geheim = aufruf.argument<ByteArray>("wert")
                if (geheim == null) {
                    ergebnis.error("ARG", "wert fehlt", null); return
                }
                entschluessele(art, geheim, ergebnis)
            }

            // Loeschen verlangt KEINE Anmeldung. Das ist Absicht: einen
            // Schluessel wegzuwerfen macht Daten unlesbar, es liest keine.
            // Waere eine Anmeldung noetig, koennte ein abgebrochener
            // Fingerabdruck das Aufraeumen verhindern — und beim
            // Panik-Loeschen ist "fast alles weg" nichts wert.
            "loesche" -> {
                try {
                    val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
                    ks.deleteEntry(alias(art))
                    ergebnis.success(true)
                } catch (e: Exception) {
                    ergebnis.error("LOESCHEN", e.message, null)
                }
            }

            else -> ergebnis.notImplemented()
        }
    }

    // ═══════════════════════════════════════════════════════════ Verfuegbarkeit

    /**
     * Ob sich mit dieser Art ueberhaupt etwas einrichten laesst.
     *
     * Gefragt wird VORHER, damit der Nutzer nicht erst tippt und dann in einen
     * Dialog laeuft, der nie kommt. Die Rueckgabe nennt den Grund, statt nur
     * "geht nicht" zu sagen.
     */
    private fun pruefeVerfuegbar(art: String): Map<String, Any?> {
        val manager = BiometricManager.from(activity)
        val erlaubt = authenticatoren(art)
        val stand = manager.canAuthenticate(erlaubt)

        // EINE ZUSAGE, DIE UNTER ANDROID 11 NICHT EINZUHALTEN WAERE.
        //
        // Gefunden am 26.07.2026 beim Nachrechnen der minSdk-Anhebung. Auf
        // 28 und 29 meldet canAuthenticate() fuer die Geraetesperre
        // BIOMETRIC_SUCCESS, sobald Fingerabdruck UND Bildschirmsperre
        // eingerichtet sind — denn dort muss BIOMETRIC_STRONG mit abgefragt
        // werden, DEVICE_CREDENTIAL allein gibt es erst ab 30.
        //
        // Der Schluessel selbst wird auf 28/29 aber mit
        // setUserAuthenticationValidityDurationSeconds(-1) angelegt, und ein
        // solcher Schluessel laesst sich dort AUSSCHLIESSLICH mit Biometrie
        // entsperren, nie mit der PIN. Die App boete also eine Anmeldeart an,
        // die zusagt zu funktionieren und dann wirft.
        //
        // Lieber hier ehrlich nein sagen als spaeter unerklaerlich scheitern.
        if (art == ART_GERAETESPERRE &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
            stand == BiometricManager.BIOMETRIC_SUCCESS
        ) {
            return mapOf(
                "ok" to false,
                "code" to BiometricManager.BIOMETRIC_ERROR_UNSUPPORTED,
                "grund" to "Erst ab Android 11. Davor laesst sich ein Fach, " +
                    "das bei jeder Benutzung nachfragt, nur mit dem " +
                    "Fingerabdruck oeffnen — nicht mit der PIN.",
            )
        }

        return mapOf(
            "ok" to (stand == BiometricManager.BIOMETRIC_SUCCESS),
            "code" to stand,
            "grund" to when (stand) {
                BiometricManager.BIOMETRIC_SUCCESS -> null
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE ->
                    "Dieses Telefon hat dafuer keine Hardware."
                BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE ->
                    "Die Hardware ist gerade nicht verfuegbar. Spaeter noch einmal versuchen."
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED ->
                    if (art == ART_BIOMETRIE)
                        "Es ist kein Fingerabdruck und kein Gesicht hinterlegt. In den Android-Einstellungen zuerst einrichten."
                    else
                        "Dieses Telefon hat keine Bildschirmsperre. In den Android-Einstellungen zuerst eine PIN, ein Muster oder ein Passwort einrichten."
                BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED ->
                    "Android verlangt zuerst ein Sicherheitsupdate."
                BiometricManager.BIOMETRIC_ERROR_UNSUPPORTED ->
                    "Diese Android-Fassung unterstuetzt das nicht."
                else -> "Nicht verfuegbar (Code $stand)."
            },
        )
    }

    private fun authenticatoren(art: String): Int = when (art) {
        ART_GERAETESPERRE ->
            // DEVICE_CREDENTIAL allein ist erst ab Android 11 zulaessig; davor
            // muss BIOMETRIC_STRONG dabeistehen.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            else
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
        else -> BiometricManager.Authenticators.BIOMETRIC_STRONG
    }

    // ══════════════════════════════════════════════════════════════ Schluessel

    /**
     * Holt den Schluessel oder legt ihn an.
     *
     * setUserAuthenticationParameters(0, ...) heisst: JEDE Benutzung verlangt
     * eine frische Anmeldung. Mit einer Frist groesser null wuerde statt dessen
     * das letzte Entsperren des Bildschirms zaehlen — und die Sperre waere
     * genau das, was sie nicht sein soll: eine Abfrage, die meistens
     * durchwinkt.
     */
    private fun holeOderLege(art: String): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getKey(alias(art), null) as? SecretKey)?.let { return it }

        val bauer = KeyGenParameterSpec.Builder(
            alias(art),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val typen = if (art == ART_GERAETESPERRE) {
                KeyProperties.AUTH_DEVICE_CREDENTIAL
            } else {
                KeyProperties.AUTH_BIOMETRIC_STRONG
            }
            bauer.setUserAuthenticationParameters(0, typen)
        } else {
            @Suppress("DEPRECATION")
            bauer.setUserAuthenticationValidityDurationSeconds(-1)
        }

        if (art == ART_BIOMETRIE) {
            // Ein neu hinzugefuegter Fingerabdruck macht diesen Schluessel
            // ungueltig. Das ist gewollt: sonst koennte jemand, der das
            // entsperrte Telefon kurz in der Hand hat, seinen eigenen Finger
            // hinterlegen und damit BitDM oeffnen.
            //
            // NICHT bei der Geraetesperre: dort waere die Bindung an die
            // Biometrie sinnlos, und ein Wechsel der PIN soll das Fach nicht
            // zerstoeren.
            bauer.setInvalidatedByBiometricEnrollment(true)
        }

        // OHNE ABFRAGE, seit minSdk 28 (siehe build.gradle.kts). Das war der
        // Grund fuer die Anhebung von 24: der Fachschluessel ist nur bei
        // ENTSPERRTEM Geraet benutzbar, und diese Zusicherung gilt jetzt fuer
        // jede Installation statt fuer die meisten.
        bauer.setUnlockedDeviceRequired(true)

        val erzeuger = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        erzeuger.init(bauer.build())
        return erzeuger.generateKey()
    }

    // ══════════════════════════════════════════════════════════════ Anmeldung

    private fun verschluessele(
        art: String, klar: ByteArray, ergebnis: MethodChannel.Result) {
        arbeite(art, null, ergebnis) { cipher ->
            // Der Startwert wird vom gesicherten Bereich vorgegeben und muss
            // mitgespeichert werden — sonst laesst sich nichts mehr lesen.
            cipher.iv + cipher.doFinal(klar)
        }
    }

    private fun entschluessele(
        art: String, geheim: ByteArray, ergebnis: MethodChannel.Result) {
        if (geheim.size <= 12) {
            ergebnis.error("FORMAT", "Der gespeicherte Wert ist zu kurz", null)
            return
        }
        val iv = geheim.copyOfRange(0, 12)
        val rest = geheim.copyOfRange(12, geheim.size)
        arbeite(art, iv, ergebnis) { cipher -> cipher.doFinal(rest) }
    }

    /**
     * Zeigt den Anmeldedialog und rechnet danach.
     *
     * Der Dialog laeuft ueber die Activity — nicht ueber den
     * Application-Context. Das ist der ganze Grund, warum diese Datei
     * existiert.
     */
    private fun arbeite(
        art: String,
        iv: ByteArray?,
        ergebnis: MethodChannel.Result,
        rechne: (Cipher) -> ByteArray,
    ) {
        val stand = pruefeVerfuegbar(art)
        if (stand["ok"] != true) {
            ergebnis.error("NICHT_VERFUEGBAR", stand["grund"] as? String, null)
            return
        }

        val cipher: Cipher
        try {
            val schluessel = holeOderLege(art)
            cipher = Cipher.getInstance(UMFORMUNG)
            if (iv == null) {
                cipher.init(Cipher.ENCRYPT_MODE, schluessel)
            } else {
                cipher.init(
                    Cipher.DECRYPT_MODE, schluessel, GCMParameterSpec(TAG_BITS, iv))
            }
        } catch (e: android.security.keystore.KeyPermanentlyInvalidatedException) {
            // Der Fingerabdruck wurde geaendert. Der Schluessel ist damit
            // unwiederbringlich weg — ein klarer Fehler ist besser als ein
            // stiller Fehlschlag bei jeder Anmeldung.
            ergebnis.error(
                "SCHLUESSEL_UNGUELTIG",
                "Die hinterlegten Fingerabdruecke haben sich geaendert. Dieses Fach laesst sich nicht mehr oeffnen.",
                null)
            return
        } catch (e: Exception) {
            ergebnis.error("SCHLUESSEL", e.message ?: "${e.javaClass.simpleName}", null)
            return
        }

        var beantwortet = false
        fun einmal(block: () -> Unit) {
            if (beantwortet) return
            beantwortet = true
            block()
        }

        val rueckruf = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(
                result: BiometricPrompt.AuthenticationResult) {
                val c = result.cryptoObject?.cipher
                einmal {
                    if (c == null) {
                        ergebnis.error("KEIN_CIPHER",
                            "Die Anmeldung lieferte keinen Rechenkontext", null)
                    } else {
                        try {
                            ergebnis.success(rechne(c))
                        } catch (e: Exception) {
                            ergebnis.error("RECHNEN",
                                e.message ?: "${e.javaClass.simpleName}", null)
                        }
                    }
                }
            }

            override fun onAuthenticationError(code: Int, text: CharSequence) {
                einmal {
                    ergebnis.error(
                        if (code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                            code == BiometricPrompt.ERROR_USER_CANCELED ||
                            code == BiometricPrompt.ERROR_CANCELED)
                            "ABGEBROCHEN" else "ANMELDUNG",
                        text.toString(),
                        code)
                }
            }

            // onAuthenticationFailed heisst: EIN Versuch ging daneben. Der
            // Dialog bleibt offen und der Nutzer darf es noch einmal
            // probieren — hier darf nichts beantwortet werden.
        }

        val prompt = BiometricPrompt(
            activity, ContextCompat.getMainExecutor(activity), rueckruf)

        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("BitDM entsperren")
            .setSubtitle(
                if (art == ART_GERAETESPERRE) "Geraetesperre dieses Telefons"
                else "Fingerabdruck oder Gesicht")
            .setAllowedAuthenticators(authenticatoren(art))
            .apply {
                // Ein Abbrechen-Knopf ist nur erlaubt, wenn die Geraetesperre
                // NICHT als Rueckfall zugelassen ist — sonst lehnt Android die
                // Anfrage ab. Bei der Geraetesperre bringt der Systemdialog
                // seinen eigenen mit.
                if (art == ART_BIOMETRIE) setNegativeButtonText("Abbrechen")
            }
            .build()

        activity.runOnUiThread {
            try {
                prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
            } catch (e: Exception) {
                einmal {
                    ergebnis.error("DIALOG",
                        e.message ?: "${e.javaClass.simpleName}", null)
                }
            }
        }
    }
}
