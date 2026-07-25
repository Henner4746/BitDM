package com.bitdm.nahtest

import android.Manifest
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * WEGWERFCODE. Siehe NahKanal.kt.
 */
class MainActivity : FlutterActivity() {

    private lateinit var nah: NahKanal

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Alle Rechte gleich am Anfang holen. In einer echten App waere das
        // schlechter Stil — hier ist es richtig: der Test soll messen, nicht
        // eine Rechteverwaltung vorfuehren.
        val noetig = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            noetig += Manifest.permission.BLUETOOTH_SCAN
            noetig += Manifest.permission.BLUETOOTH_ADVERTISE
            noetig += Manifest.permission.BLUETOOTH_CONNECT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            noetig += Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            noetig += Manifest.permission.ACCESS_FINE_LOCATION
        }
        requestPermissions(noetig.toTypedArray(), 1)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nah = NahKanal(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NahKanal.KANAL)
            .setMethodCallHandler(nah)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NahKanal.EREIGNISSE)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, senke: EventChannel.EventSink?) =
                    nah.setzeSenke(senke)

                override fun onCancel(args: Any?) = nah.setzeSenke(null)
            })
    }
}
