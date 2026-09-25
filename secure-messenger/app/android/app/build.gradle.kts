import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
//  Signaturschluessel
//
//  key.properties liegt NICHT im Repo (siehe .gitignore) und enthaelt das
//  Passwort im Klartext. Vorlage: key.properties.example.
//
//  Warum das wichtig ist: Bis hierher wurde der Release-Build mit dem
//  Android-DEBUG-Schluessel signiert. Der ist auf jedem Rechner mit Android-SDK
//  identisch (Passwort "android"), d. h. jeder Beliebige kann eine APK bauen,
//  die Android als gueltiges Update fuer BitDM akzeptiert. Die App-Signatur ist
//  die aeusserste Vertrauensschicht — ist sie offen, nuetzt die Signal-Krypto
//  darunter nichts.
// ---------------------------------------------------------------------------
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// Ohne Pruefung erzeugt Gradle klaglos eine UNSIGNIERTE APK und Flutter meldet
// "√ Built app-release.apk" — also Erfolg fuer ein Artefakt, das sich auf keinem
// Geraet installieren laesst. Das faellt erst beim Installationsversuch auf, im
// schlimmsten Fall beim Nutzer.
//
// ABER: die erste Fassung brach IMMER ab, wenn key.properties fehlte. Damit war
// jeder F-Droid-Build unmoeglich — nicht schwierig, sondern unmoeglich. F-Droid
// baut aus einem sauberen Checkout, in dem key.properties per .gitignore gar
// nicht existieren KANN, und signiert anschliessend selbst. Der Abbruch haette
// dort bei jedem Versuch zugeschlagen, und zwar erst auf deren Buildserver.
//
// Deshalb jetzt zweistufig:
//   - key.properties vorhanden  -> pruefen und verwenden, Fehler hart melden
//   - fehlt, ohne -PbitdmRequireSigning=true -> unsigniert bauen, LAUT warnen
//   - fehlt, MIT -PbitdmRequireSigning=true  -> abbrechen (eigene Releases)
//
// Das eigene Release-Skript setzt die Eigenschaft; F-Droid tut es nicht.
val requireSigning = project.findProperty("bitdmRequireSigning") == "true"

gradle.taskGraph.whenReady {
    val releaseTargets = listOf("assembleRelease", "bundleRelease", "packageRelease")
    val buildsRelease = allTasks.any { task -> releaseTargets.any { task.name.equals(it, true) } }
    if (!buildsRelease) return@whenReady

    if (!hasKeystore) {
        if (requireSigning) {
            throw GradleException(
                "\n\n  Release-Build abgebrochen: android/key.properties fehlt,\n" +
                "  obwohl -PbitdmRequireSigning=true gesetzt ist.\n\n" +
                "  Vorlage kopieren und ausfuellen:  android/key.properties.example\n"
            )
        }
        logger.warn(
            "\n" +
            "  ============================================================\n" +
            "   ACHTUNG: android/key.properties fehlt.\n" +
            "   Es entsteht eine UNSIGNIERTE APK. Sie laesst sich NICHT\n" +
            "   installieren und ist nicht zur Weitergabe geeignet.\n" +
            "\n" +
            "   Das ist der erwartete Weg fuer reproduzierbare Builds\n" +
            "   (F-Droid signiert selbst). Fuer eigene Releases:\n" +
            "     flutter build apk --release -PbitdmRequireSigning=true\n" +
            "  ============================================================\n"
        )
        return@whenReady
    }

    // Ein vergessener Platzhalter wuerde sonst als "keystore password was
    // incorrect" durchschlagen — eine Meldung, die in die Irre fuehrt.
    val placeholder = "HIER_PASSWORT_EINTRAGEN"
    val unfilled = listOf("storePassword", "keyPassword")
        .filter { (keystoreProperties[it] as String?).isNullOrBlank() || keystoreProperties[it] == placeholder }
    if (unfilled.isNotEmpty()) {
        throw GradleException(
            "\n\n  Release-Build abgebrochen: in android/key.properties fehlt noch\n" +
            "  ein echtes Passwort bei: ${unfilled.joinToString(", ")}\n\n" +
            "  Ersetze dort $placeholder durch dein Keystore-Passwort.\n"
        )
    }

    val ks = file(keystoreProperties["storeFile"] as String)
    if (!ks.exists()) {
        throw GradleException(
            "\n\n  Release-Build abgebrochen: Keystore nicht gefunden unter\n" +
            "  ${ks.absolutePath}\n\n" +
            "  Pfad in android/key.properties pruefen (Backslashes verdoppeln).\n"
        )
    }
}

android {
    namespace = "com.bitdm.bitdm"

    // F-DROID: kein Abhaengigkeitsblock in der APK. Den verschluesselt das
    // Android-Gradle-Plugin mit einem Schluessel von Google, und F-Droid nimmt
    // eine APK mit einem Block, den niemand ausser Google lesen kann, nicht an.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // MUSS STEHEN BLEIBEN, obwohl es seit minSdk 28 nichts mehr TUT.
        //
        // Der urspruengliche Grund ist weg: java.time gibt es ab Android 8
        // nativ, und flutter_local_notifications benutzt genau vier Klassen
        // daraus. Bei minSdk 28 schreibt der Compiler also nichts mehr um.
        //
        // Trotzdem darf die Zeile NICHT weg, und der Grund hat mit minSdk
        // nichts zu tun: flutter_local_notifications setzt in seinem eigenen
        // build.gradle coreLibraryDesugaringEnabled true, und AGP schreibt das
        // in die AAR-Metadaten des Pakets. CheckAarMetadataWorkAction prueft
        // beim Bauen, ob die App es AUCH gesetzt hat, und bricht sonst ab mit
        // "requires core library desugaring to be enabled". In der Bedingung
        // steht kein minSdk.
        //
        // Wer also nur diesen Kommentar liest und die Zeile fuer erledigt
        // haelt, bricht den Bau — mit einer Meldung, die niemand mit minSdk in
        // Verbindung bringt. Sie faellt erst weg, wenn
        // flutter_local_notifications wegfaellt.
        //
        // Reine Uebersetzungshilfe des Android-Werkzeugkastens, kein Dienst
        // und keine Verbindung nach draussen — der Google-freie Anspruch
        // dieser App bleibt unberuehrt.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bitdm.bitdm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ANDROID 9 (API 28), NICHT Flutters Standard 24.
        //
        // Angehoben am 26.07.2026, und zwar wegen der App-Sperre. Was damit
        // fuer JEDE Installation gilt statt nur fuer die meisten:
        //
        //   ab 26  Vordergrunddienst und Benachrichtigungskanaele ohne
        //          Versionsweiche (startForegroundService, NotificationChannel)
        //   ab 28  setUnlockedDeviceRequired: der Fachschluessel ist NUR bei
        //          entsperrtem Geraet benutzbar. Das ist der Grund fuer 28
        //          statt 26 — bei einer App, deren ganzer Sinn dieser
        //          Schluessel ist, war das die letzte Zusicherung, die noch
        //          von der Android-Fassung abhing.
        //
        // WAS AUCH BEI 28 NOCH ABHAENGT und deshalb weiter abgefragt wird:
        // setUserAuthenticationParameters und DEVICE_CREDENTIAL allein gibt es
        // erst ab 30, FLAG_MUTABLE ab 31. Diese Weichen bleiben stehen.
        //
        // Kein Plugin steht dem im Weg — der hoechste Wert unter allen
        // eingebundenen ist 24.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (hasKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
            // Kein Rueckfall auf den Debug-Schluessel. Fehlt key.properties,
            // bleibt der Build UNSIGNIERT und schlaegt sichtbar fehl — besser
            // als eine scheinbar fertige Release-APK mit dem oeffentlich
            // bekannten Debug-Schluessel, die niemandem auffaellt.

            // F-DROID / REPRODUZIERBAR: keine Versionsverwaltungs-Angaben in der
            // APK. Gebaut aus einem git-Checkout stuende dort die Commit-
            // Kennung, gebaut aus einem entpackten Stand "NO_SUPPORTED_VCS" —
            // und schon waeren zwei Bauten desselben Quellstands verschieden.
            vcsInfo {
                include = false
            }
        }

        // HIER STAND EIN applicationIdSuffix = ".dev" FUER DEN TESTBAU.
        //
        // Es ist wieder raus, weil Henrik die App ohnehin immer vollstaendig
        // neu installiert. Zwei Symbole nebeneinander waeren dann kein Schutz,
        // sondern nur zwei Symbole — und der Testbau wuerde beim Anstoss-
        // Verteiler unter einer zweiten Kennung auftauchen, die niemand
        // aufraeumt.
        //
        // Wer das je wieder braucht: applicationIdSuffix = ".dev" hier hinein
        // und den Namen ueber src/debug/res/values/strings.xml setzen (NICHT
        // ueber resValue — das braeuchte buildFeatures.resValues).
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Googles Tink kommt zweimal herein, und die beiden Fassungen vertragen sich
// nicht: unifiedpush_android zieht `tink` (die Fassung fuer gewoehnliches
// Java), flutter_secure_storage `tink-android`. Beide enthalten dieselben
// Klassennamen, und der Bau bricht mit "Duplicate class" ab.
//
// Herausgeworfen wird die JAVA-Fassung. `tink-android` ist die fuer Android
// gedachte und deckt dieselben Klassen ab.
//
// WOFUER TINK UEBERHAUPT DA IST: UnifiedPush kann verschluesselte Nutzlasten
// im Anstoss uebertragen. BitDM benutzt das NICHT — der Anstoss ist leer, die
// Nachricht holt die App danach beim Relay ab. Selbst wenn dieser Weg brechen
// wuerde, faellt in dieser App nichts aus.
configurations.all {
    exclude(group = "com.google.crypto.tink", module = "tink")
}

dependencies {
    // Die Umschreibhilfe fuer java.time bei minSdk 24. Gehoert zum
    // Android-Werkzeugkasten und laeuft ausschliesslich beim Uebersetzen.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // Der Anmeldedialog fuer Fingerabdruck, Gesicht und Geraetesperre.
    //
    // WARUM NICHT ueber flutter_secure_storage: das Paket baut seinen Dialog
    // mit dem Application-Context und meldet sich nie an der Activity an. Auf
    // Samsung erscheint dabei regelmaessig gar kein Dialog — und beim
    // Antippen passiert dann NICHTS. Diese Bibliothek ist der von Google
    // vorgesehene Weg und braucht eine echte FragmentActivity, die es hier
    // gibt. Siehe SchluesselfachKanal.kt.
    implementation("androidx.biometric:biometric:1.1.0")

    // NUR FUER DIE JVM-TESTS, nicht in der App.
    //
    // Sie pruefen KryptoKanal gegen Vektoren, die die Dart-Fassung erzeugt hat
    // (app/tool/krypto_vektoren.dart). Das geht auf der JVM, weil javax.crypto
    // dort dasselbe AES/GCM/NoPadding kennt wie auf Android — und ist damit
    // die Antwort auf die Frage, wie man nativen Krypto-Code ueberhaupt
    // pruefen kann, ohne bei jedem Lauf ein Telefon zu brauchen.
    //
    //   gradlew :app:testDebugUnitTest
    testImplementation("junit:junit:4.13.2")
}
