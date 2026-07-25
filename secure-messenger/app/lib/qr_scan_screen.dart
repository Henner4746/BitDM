// qr_scan_screen.dart — Adresse per QR einlesen.
//
// Eine BitDM-Adresse hat 56 Zeichen. Abtippen ist fehleranfaellig, und die
// Pruefsumme faengt zwar Tippfehler ab, aber erst nachdem man sich geaergert
// hat. Der eigentliche Gewinn liegt woanders: ein QR-Code, den man im
// persoenlichen Gespraech abliest, geht durch keinen Kanal, den jemand
// veraendern koennte. Das ist der sicherste Weg, eine Adresse auszutauschen.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'core/qr_leser.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({
    super.key,
    required this.titel,
    required this.hinweis,
    required this.keineKamera,
    required this.abbrechen,
    required this.istGueltig,
  });

  final String titel;
  final String hinweis;
  final String keineKamera;
  final String abbrechen;

  /// Prueft, ob das Gelesene ueberhaupt eine BitDM-Adresse ist.
  ///
  /// Ohne das wuerde jeder beliebige QR-Code — eine WLAN-Konfiguration, eine
  /// Speisekarte — als Adresse zurueckgereicht und erst spaeter abgelehnt.
  final bool Function(String) istGueltig;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  CameraController? _kamera;
  final _leser = QrLeser();
  bool _amLesen = false;
  bool _fertig = false;
  String? _fehler;

  @override
  void initState() {
    super.initState();
    unawaited(_starte());
  }

  Future<void> _starte() async {
    try {
      final kameras = await availableCameras();
      if (kameras.isEmpty) {
        if (mounted) setState(() => _fehler = widget.keineKamera);
        return;
      }
      final hinten = kameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => kameras.first,
      );

      // Niedrige Aufloesung ist hier BESSER: ein QR-Code ist auch bei 640x480
      // gut lesbar, und jedes Bild wird in Dart durchgerechnet. Volle
      // Aufloesung wuerde nur Akku kosten und die Erkennung verlangsamen.
      //
      // enableAudio: false — diese App hat keinen Grund, je ein Mikrofon
      // anzufassen, und ohne das Flag fordert der Kameratreiber es mit an.
      final ctl = CameraController(
        hinten,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await ctl.initialize();
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() => _kamera = ctl);
      await ctl.startImageStream(_pruefeBild);
    } on CameraException catch (e) {
      // Auch eine verweigerte Berechtigung landet hier. Kein Absturz, ein
      // Hinweis.
      if (mounted) {
        setState(() => _fehler = '${widget.keineKamera}\n\n${e.description ?? e.code}');
      }
    }
  }

  void _pruefeBild(CameraImage bild) {
    // Nur ein Bild gleichzeitig. Ohne diese Sperre stapeln sich die Aufrufe,
    // weil die Kamera schneller liefert als Dart rechnet.
    if (_amLesen || _fertig) return;
    _amLesen = true;

    try {
      final y = bild.planes.first;
      final text = _leser.lies(
          y.bytes, y.bytesPerRow, bild.width, bild.height);

      if (text != null && widget.istGueltig(text)) {
        _fertig = true;
        // Kamera sofort anhalten, sonst laufen noch Bilder ein, waehrend die
        // Seite schon zugeht.
        unawaited(_kamera?.stopImageStream());
        if (mounted) Navigator.of(context).pop(text);
      }
    } finally {
      _amLesen = false;
    }
  }

  @override
  void dispose() {
    unawaited(_kamera?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          if (_kamera != null)
            Center(child: CameraPreview(_kamera!))
          else if (_fehler != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(_fehler!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.6)),
              ),
            )
          else
            const Center(
                child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 1, color: Colors.white24))),

          // Sucherrahmen. Rein zur Orientierung — gelesen wird das ganze Bild,
          // weil ein Ausschnitt nur eine weitere Fehlerquelle waere.
          if (_kamera != null)
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white38),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),

          Positioned(
            left: 0, right: 0, top: 16,
            child: Text(widget.titel.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, letterSpacing: 1.8)),
          ),
          Positioned(
            left: 24, right: 24, bottom: 84,
            child: Text(widget.hinweis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.6)),
          ),
          Positioned(
            left: 24, right: 24, bottom: 24,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white38),
                ),
                child: Text(widget.abbrechen.toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 12, letterSpacing: 1.2)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
