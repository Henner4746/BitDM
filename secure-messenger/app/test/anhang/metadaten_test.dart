// metadaten_test.dart — GPS, Kamera und Kommentare verlassen das Geraet nicht.
//
// Die Proben sind echte Bilder, mit PIL erzeugt (test/anhang/proben): ein
// JPEG mit GPS, Hersteller, Modell, Zeit, Ausrichtung 6 und Kommentar, ein PNG
// mit Textabschnitten, ein WebP mit EXIF. Geprueft wird zweierlei — dass die
// Metadaten weg sind, UND dass das Ergebnis sich noch als Bild oeffnen laesst.
// Ein Entferner, der die Datei kaputt macht, waere schlimmer als keiner.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bitdm/core/anhang/metadaten.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List probe(String name) => File('test/anhang/proben/$name').readAsBytesSync();

bool enthaelt(Uint8List b, String text) {
  final t = text.codeUnits;
  outer:
  for (var i = 0; i + t.length <= b.length; i++) {
    for (var k = 0; k < t.length; k++) {
      if (b[i + k] != t[k]) continue outer;
    }
    return true;
  }
  return false;
}

Future<(int, int)> oeffne(Uint8List b) async {
  final codec = await ui.instantiateImageCodec(b);
  final bild = (await codec.getNextFrame()).image;
  return (bild.width, bild.height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('JPEG: GPS, Kamera, Zeit und Kommentar sind weg', () {
    final vorher = probe('mit_gps.jpg');
    expect(enthaelt(vorher, 'TestCam'), isTrue, reason: 'die Probe hat keine Metadaten');
    final nachher = ohneMetadaten(vorher)!;
    for (final spur in ['TestCam', 'Geheim 3000', '2026:09:25', 'Kommentar mit Ort']) {
      expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
    }
    expect(nachher.length, lessThan(vorher.length));
  });

  test('JPEG: die Ausrichtung bleibt, sonst laege jedes Hochformat quer', () {
    final nachher = ohneMetadaten(probe('mit_gps.jpg'))!;
    // Der minimale EXIF-Block: "Exif\0\0MM\0*", ein Eintrag 0x0112 = 6.
    expect(enthaelt(nachher, 'Exif'), isTrue);
    expect(enthaelt(nachher, String.fromCharCodes([0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1, 0, 6])), isTrue,
        reason: 'die Drehung 6 fehlt');
  });

  test('JPEG: das Ergebnis ist noch ein Bild', () async {
    final nachher = ohneMetadaten(probe('mit_gps.jpg'))!;
    final (b, h) = await oeffne(nachher);
    expect(b * h, 48, reason: '8 x 6 Pixel, egal wie gedreht');
  });

  test('PNG: Textabschnitte sind weg, das Bild bleibt', () async {
    final vorher = probe('mit_text.png');
    expect(enthaelt(vorher, 'Henrik Geheim'), isTrue);
    final nachher = ohneMetadaten(vorher)!;
    expect(enthaelt(nachher, 'Henrik Geheim'), isFalse);
    expect(enthaelt(nachher, '52.52'), isFalse);
    expect(await oeffne(nachher), (8, 6));
  });

  test('WebP: EXIF ist weg, das Bild bleibt', () async {
    final vorher = probe('mit_exif.webp');
    expect(enthaelt(vorher, 'TestCam'), isTrue);
    final nachher = ohneMetadaten(vorher)!;
    expect(enthaelt(nachher, 'TestCam'), isFalse);
    expect(await oeffne(nachher), (8, 6));
  });

  test('ohne Metadaten oder unbekannt: null, die Datei geht unveraendert', () {
    final sauber = ohneMetadaten(probe('mit_gps.jpg'))!;
    // Ein zweiter Durchgang findet nur noch den minimalen Block: der bleibt.
    expect(ohneMetadaten(Uint8List.fromList('%PDF-1.7 hallo'.codeUnits)), isNull);
    expect(ohneMetadaten(Uint8List(0)), isNull);
    expect(istBereinigbar(sauber), isTrue);
  });

  test('kaputte Datei: kein Absturz', () {
    final kaputt = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 1, 2]);
    expect(() => ohneMetadaten(kaputt), returnsNormally);
  });

  test('neutraler Name verraet weder Telefon noch Zeit', () {
    expect(neutralerBildname(probe('mit_gps.jpg'), 0xBEEF), 'bild-beef.jpg');
    expect(neutralerBildname(probe('mit_text.png'), 7), 'bild-0007.png');
  });
}
