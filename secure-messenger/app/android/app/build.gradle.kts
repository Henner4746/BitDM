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
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bitdm.bitdm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
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
        }
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
