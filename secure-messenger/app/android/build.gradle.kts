allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// DAMIT `gradlew :app:testDebugUnitTest` DURCHLAEUFT.
//
// Das Kamera-Plugin (camera_android_camerax) bricht beim Uebersetzen der
// Debug-Fassung ab:
//
//   Typannotationen @org.jspecify.annotations.NonNull koennen nicht an
//   SurfaceRequest.mSurfaceRecreationCompleter angehaengt werden:
//   Klassendatei fuer androidx.concurrent.futures.CallbackToFutureAdapter
//   nicht gefunden
//
// javac braucht die Klasse, um eine Typannotation aufzuloesen, bekommt sie
// aber nicht in den Klassenpfad — camera-core fuehrt concurrent-futures nur
// als `compileOnly`. Beim Bauen der RELEASE-APK faellt es nicht auf, weil dort
// anders uebersetzt wird; die Einheitentests gibt es aber nur fuer debug.
//
// Ohne diese Zeilen liesse sich der JVM-Test zu KryptoKanal nicht ausfuehren —
// und damit die einzige Pruefung, die die native Verschluesselung gegen die
// Vektoren der Dart-Fassung stellt.
subprojects {
    if (name == "camera_android_camerax") {
        afterEvaluate {
            dependencies.add("compileOnly", "androidx.concurrent:concurrent-futures:1.2.0")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
