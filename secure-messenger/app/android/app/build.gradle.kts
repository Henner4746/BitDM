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

// Ohne diesen Abbruch erzeugt Gradle klaglos eine UNSIGNIERTE APK und Flutter
// meldet "√ Built app-release.apk" — also Erfolg fuer ein Artefakt, das sich auf
// keinem Geraet installieren laesst. Das faellt erst beim Installationsversuch
// auf, im schlimmsten Fall beim Nutzer. Darum hier hart abbrechen, und zwar nur
// wenn tatsaechlich ein Release-Artefakt gebaut wird (Debug-Builds bleiben
// unberuehrt).
gradle.taskGraph.whenReady {
    val releaseTargets = listOf("assembleRelease", "bundleRelease", "packageRelease")
    val buildsRelease = allTasks.any { task -> releaseTargets.any { task.name.equals(it, true) } }
    if (buildsRelease && !hasKeystore) {
        throw GradleException(
            "\n\n  Release-Build abgebrochen: android/key.properties fehlt.\n" +
            "  Ohne Schluesseldatei entstuende eine UNSIGNIERTE APK, die sich\n" +
            "  nicht installieren laesst.\n\n" +
            "  Vorlage kopieren und ausfuellen:  android/key.properties.example\n"
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
