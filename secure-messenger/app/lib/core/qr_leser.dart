// qr_leser.dart — QR-Codes aus Kamerabildern lesen, ohne eine Zeile Google.
//
// WARUM NICHT DAS UEBLICHE PAKET
// mobile_scanner ist der naheliegende Weg und nutzt auf Android Googles MLKit
// — entweder als eingebauten Binaerblob oder ueber die Google Play Services.
// In einer App, die google_fonts entfernt hat, damit Google nicht einmal die
// IP beim Kaltstart erfaehrt, waere das ein Selbstwiderspruch. Und es macht
// eine Aufnahme bei F-Droid unmoeglich, wo nichts Proprietaeres hinein darf.
//
// Statt dessen: die offizielle camera (Flutter-Team, CameraX also androidx —
// keine Play Services) und zxing2, ein reiner Dart-Port von ZXing.
//
// DIE Y-EBENE IST SCHON HELLIGKEIT
// Android liefert Kamerabilder als YUV420. Die erste Ebene, Y, ist genau der
// Helligkeitswert je Bildpunkt — also das, was ein QR-Leser braucht. Eine
// Umwandlung nach RGB und zurueck waere reine Rechenarbeit fuer nichts, und
// bei 30 Bildern je Sekunde waere sie auf einem Telefon spuerbar. Deshalb
// diese kleine Klasse: sie reicht die Y-Bytes durch.
//
// zxing2 bringt fuer diesen Fall zwar PlanarYUVLuminanceSource mit, exportiert
// sie aber nicht.

import 'dart:typed_data';

import 'package:zxing2/qrcode.dart';

/// Sieht die Y-Ebene eines YUV420-Bildes als Helligkeitsbild.
class _YEbene extends LuminanceSource {
  _YEbene(this._bytes, this._zeilenbreite, int width, int height)
      : super(width, height);

  final Uint8List _bytes;

  /// Android fuellt Zeilen oft auf eine Vielfache-von-N-Breite auf. Wer das
  /// ignoriert, liest ein schraeg verzerrtes Bild und findet nie einen Code.
  final int _zeilenbreite;

  @override
  Int8List getRow(int y, Int8List? row) {
    final ziel = (row == null || row.length < width) ? Int8List(width) : row;
    final start = y * _zeilenbreite;
    for (var x = 0; x < width; x++) {
      // ZXing rechnet mit vorzeichenbehafteten Bytes; 0..255 wird zu -128..127.
      ziel[x] = _bytes[start + x] - 128;
    }
    return ziel;
  }

  @override
  Int8List getMatrix() {
    final out = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      final quelle = y * _zeilenbreite;
      final ziel = y * width;
      for (var x = 0; x < width; x++) {
        out[ziel + x] = _bytes[quelle + x] - 128;
      }
    }
    return out;
  }
}

class QrLeser {
  final _leser = QRCodeReader();

  /// Sucht einen QR-Code in einem Kamerabild.
  ///
  /// [yEbene] sind die rohen Y-Bytes, [zeilenbreite] deren tatsaechliche
  /// Schrittweite je Zeile (bytesPerRow der Ebene).
  ///
  /// Gibt null zurueck, wenn keiner drin ist — das ist der Normalfall bei fast
  /// jedem Bild und KEIN Fehler. Deshalb wird hier auch nichts geworfen: bei
  /// 30 Bildern je Sekunde waeren Ausnahmen als Steuerfluss teuer und laut.
  String? lies(Uint8List yEbene, int zeilenbreite, int breite, int hoehe) {
    try {
      final quelle = _YEbene(yEbene, zeilenbreite, breite, hoehe);
      // HybridBinarizer ist bei ungleichmaessiger Beleuchtung deutlich besser
      // als der einfache Histogramm-Ansatz — und ein Handy, das schraeg auf
      // einen Bildschirm gehalten wird, ist genau dieser Fall.
      final bitmap = BinaryBitmap(HybridBinarizer(quelle));
      return _leser.decode(bitmap).text;
    } catch (_) {
      // NotFoundException, ChecksumException, FormatReaderException — alle
      // heissen dasselbe: in diesem Bild war nichts Lesbares.
      return null;
    }
  }
}
