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
    expect(neutralerBildname(probe('mit_gps.heic'), 1), 'bild-0001.heic');
    expect(neutralerBildname(probe('mit_gps.avif'), 2), 'bild-0002.avif');
    expect(neutralerBildname(probe('mit_ort.mp4'), 0xABCD), 'video-abcd.mp4');
    expect(neutralerBildname(probe('mit_ort.mov'), 3), 'video-0003.mov');
  });

  // ═══════════════════════════════════════════════════════════ HEIC / AVIF
  //
  // mit_gps.heic und mit_gps.avif: 8 x 6 Pixel, mit pillow_heif 1.8 bzw.
  // PIL 12 erzeugt, EXIF mit GPS, Hersteller "TestCam", Modell "Geheim 3000",
  // Zeit und Ausrichtung 6 (die pillow_heif als irot ablegt); die HEIC-Probe
  // traegt zusaetzlich XMP mit Modell "XmpGeheim". Flutter kann HEIC auf dem
  // Testrechner nicht oeffnen — geprueft wird hier der Aufbau. Die bereinigten
  // Dateien wurden am 25.09.2026 einmal von Hand mit pillow_heif geoeffnet:
  // beide 8 x 6, Pixel unveraendert, EXIF leer, kein XMP mehr.

  group('HEIF', () {
    for (final name in ['mit_gps.heic', 'mit_gps.avif']) {
      test('$name: GPS, Kamera, Zeit und XMP sind weg, nur Bytes in mdat geaendert', () {
        final vorher = probe(name);
        expect(enthaelt(vorher, 'TestCam'), isTrue, reason: 'die Probe hat keine Metadaten');
        expect(istBereinigbar(vorher), isTrue);
        expect(istVideo(vorher), isFalse);
        final nachher = ohneMetadaten(vorher)!;
        for (final spur in ['TestCam', 'Geheim 3000', '2026:09:25', 'XmpGeheim', '52,31']) {
          expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
        }
        // KEIN Byte verschoben: gleiche Laenge, gleiche Kaesten, und alles
        // Geaenderte liegt in mdat — die Bilddaten dort stehen woanders.
        expect(nachher.length, vorher.length);
        expect(kaesten(nachher), kaesten(vorher));
        final (mdatAnfang, mdatEnde) = bereich(vorher, 'mdat');
        for (var i = 0; i < vorher.length; i++) {
          if (vorher[i] != nachher[i]) {
            expect(i >= mdatAnfang && i < mdatEnde, isTrue, reason: 'Byte $i ausserhalb von mdat');
          }
        }
        // Ein zweiter Durchgang findet nichts mehr.
        expect(ohneMetadaten(nachher), isNull);
      });
    }

    test('HEIC: die Exif-Ware ist ein gueltiger, leerer TIFF-Kopf', () {
      final nachher = ohneMetadaten(probe('mit_gps.heic'))!;
      expect(enthaelt(nachher, String.fromCharCodes([0, 0, 0, 0, 0x4D, 0x4D, 0, 0x2A, 0, 0, 0, 8, 0, 0])), isTrue);
      expect(enthaelt(nachher, '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>'), isTrue);
      // Die Drehung steht in irot, und die bleibt.
      expect(enthaelt(nachher, 'irot'), isTrue);
    });

    test('unbekannte iloc-Version: null, nichts wird angefasst', () {
      final kaputt = Uint8List.fromList(probe('mit_gps.heic'));
      kaputt[suche(kaputt, 'iloc') + 4] = 3; // Version 3 gibt es nicht
      expect(ohneMetadaten(kaputt), isNull);
    });

    test('abgeschnittene Datei: null, kein Absturz', () {
      final heic = probe('mit_gps.heic');
      expect(ohneMetadaten(Uint8List.sublistView(heic, 0, 300)), isNull);
    });
  });

  // ═════════════════════════════════════════════════════════════════ Video
  //
  // mit_ort.mp4 (H.264 + AAC, 32 x 24, 1 s) und mit_ort.mov (H.264, 1 s),
  // erzeugt mit ffmpeg:
  //   mp4: -movflags use_metadata_tags -metadata location=+52.5200+013.4050/
  //        -metadata make=TestCam -metadata model=Geheim -metadata
  //        creation_time=2026-09-25T12:34:56Z   -> udta/meta(keys, ilst), loci
  //   mov: dieselben Werte ohne use_metadata_tags -> udta/©mak, ©mod, ©xyz
  // Ist ffprobe da, muss das Ergebnis sich auch vollstaendig dekodieren lassen.

  group('Video', () {
    for (final name in ['mit_ort.mp4', 'mit_ort.mov']) {
      test('$name: Ort, Hersteller und Modell sind weg, kein Byte verschoben', () {
        final vorher = probe(name);
        expect(enthaelt(vorher, '+52.5200+013.4050'), isTrue, reason: 'die Probe hat keinen Ort');
        expect(istVideo(vorher), isTrue);
        expect(istBereinigbar(vorher), isTrue);
        final nachher = ohneMetadaten(vorher)!;
        for (final spur in ['+52.5200+013.4050', 'TestCam', 'Geheim', 'Lavf']) {
          expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
        }
        expect(nachher.length, vorher.length);
        // Oben dieselben Kaesten an denselben Stellen: mdat und damit jede
        // stco-Position stimmt noch.
        expect(kaesten(nachher), kaesten(vorher));
        expect(suche(nachher, 'stco'), suche(vorher, 'stco'));
        final (mdatAnfang, mdatEnde) = bereich(vorher, 'mdat');
        expect(nachher.sublist(mdatAnfang, mdatEnde), vorher.sublist(mdatAnfang, mdatEnde));
        expect(suche(nachher, 'udta'), -1, reason: 'udta ist noch da');
        // Aufnahmezeit in mvhd: 0.
        final mvhd = suche(nachher, 'mvhd');
        expect(nachher.sublist(mvhd + 8, mvhd + 16), List.filled(8, 0));
        expect(ohneMetadaten(nachher), isNull);
      });

      test('$name: das Ergebnis laesst sich noch abspielen (ffprobe/ffmpeg)', () async {
        final nachher = ohneMetadaten(probe(name))!;
        final ordner = await Directory.systemTemp.createTemp('bitdm-meta');
        try {
          final datei = File('${ordner.path}/sauber${name.substring(name.lastIndexOf('.'))}');
          await datei.writeAsBytes(nachher);
          final tags = await Process.run('ffprobe',
              ['-v', 'error', '-show_entries', 'format_tags:stream=codec_type', '-of', 'compact', datei.path]);
          expect(tags.exitCode, 0, reason: '${tags.stderr}');
          final ausgabe = '${tags.stdout}';
          expect(ausgabe, contains('codec_type=video'));
          for (final spur in ['location', 'TestCam', 'Geheim', '2026']) {
            expect(ausgabe.contains(spur), isFalse, reason: 'ffprobe sieht noch "$spur": $ausgabe');
          }
          final lauf = await Process.run('ffmpeg', ['-v', 'error', '-i', datei.path, '-f', 'null', '-']);
          expect(lauf.exitCode, 0);
          expect('${lauf.stderr}'.trim(), isEmpty, reason: 'ffmpeg meldet Fehler beim Dekodieren');
        } finally {
          await ordner.delete(recursive: true);
        }
      }, skip: ffmpegDa ? false : 'ffprobe/ffmpeg nicht installiert');
    }

    test('moov/meta, trak/udta und XMP-uuid werden zu free, stco bleibt', () {
      final xmpUuid = [
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
      ];
      final datei = Uint8List.fromList([
        ...kasten('ftyp', [...'qt  '.codeUnits, 0, 0, 0, 0, ...'qt  '.codeUnits]),
        ...kasten('mdat', List.filled(16, 0x11)),
        ...kasten('moov', [
          ...kasten('mvhd', [1, 0, 0, 0, ...List.filled(16, 0x7F), ...List.filled(20, 0)]),
          ...kasten('meta', [...kasten('keys', 'com.apple.quicktime.location.ISO6709'.codeUnits)]),
          ...kasten('trak', [
            ...kasten('udta', [...kasten('©xyz', '+52.5200+013.4050/'.codeUnits)]),
            ...kasten('stco', [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 28]),
          ]),
        ]),
        ...kasten('uuid', [...xmpUuid, ...'<x:xmpmeta>XmpGeheim</x:xmpmeta>'.codeUnits]),
      ]);
      final nachher = ohneMetadaten(datei)!;
      expect(nachher.length, datei.length);
      expect(kaesten(nachher).map((k) => k.$1).toList(), ['ftyp', 'mdat', 'moov', 'free']);
      for (final typ in ['meta', 'udta']) {
        final stelle = suche(datei, typ);
        expect(String.fromCharCodes(nachher, stelle, stelle + 4), 'free', reason: '$typ ist noch da');
      }
      for (final spur in ['ISO6709', '+52.5200', 'XmpGeheim']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      expect(suche(nachher, 'stco'), suche(datei, 'stco'));
      // mvhd Version 1: zweimal 64 Bit Zeit, beide 0.
      final mvhd = suche(nachher, 'mvhd');
      expect(nachher.sublist(mvhd + 8, mvhd + 24), List.filled(16, 0));
    });

    test('vorOrt: dieselbe Liste wird geaendert; ohne vorOrt bleibt sie heil', () {
      final original = probe('mit_ort.mp4');
      final kopie = Uint8List.fromList(original);
      final rein = ohneMetadaten(kopie)!;
      expect(identical(rein, kopie), isFalse);
      expect(kopie, original, reason: 'ohne vorOrt darf die Eingabe sich nicht aendern');
      final anOrt = ohneMetadaten(kopie, vorOrt: true)!;
      expect(identical(anOrt, kopie), isTrue);
      expect(anOrt, rein);
    });

    test('abgeschnittenes Video: null, kein Absturz', () {
      final mp4 = probe('mit_ort.mp4');
      final halb = Uint8List.sublistView(mp4, 0, mp4.length - 100);
      expect(() => ohneMetadaten(halb), returnsNormally);
      expect(ohneMetadaten(halb), isNull);
    });
  });
}

final bool ffmpegDa = () {
  try {
    return Process.runSync('ffprobe', ['-version']).exitCode == 0 &&
        Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

/// Erste Stelle des Textes (bei Kastentypen: 4 Bytes hinter dem Anfang des
/// Kastens), oder -1.
int suche(Uint8List b, String text) {
  final t = text.codeUnits;
  outer:
  for (var i = 0; i + t.length <= b.length; i++) {
    for (var k = 0; k < t.length; k++) {
      if (b[i + k] != t[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Die Kaesten der obersten Ebene als (Typ, Anfang, Laenge).
List<(String, int, int)> kaesten(Uint8List b) {
  final bd = ByteData.sublistView(b);
  final liste = <(String, int, int)>[];
  var a = 0;
  while (a + 8 <= b.length) {
    final laenge = bd.getUint32(a);
    liste.add((String.fromCharCodes(b, a + 4, a + 8), a, laenge));
    if (laenge < 8) break;
    a += laenge;
  }
  return liste;
}

/// Anfang und Ende des ersten Kastens [typ] der obersten Ebene.
(int, int) bereich(Uint8List b, String typ) {
  final k = kaesten(b).firstWhere((k) => k.$1 == typ);
  return (k.$2, k.$2 + k.$3);
}

/// Ein ISO-BMFF-Kasten mit 32-Bit-Laenge.
List<int> kasten(String typ, List<int> inhalt) {
  final n = inhalt.length + 8;
  return [n >> 24, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF, ...typ.codeUnits, ...inhalt];
}
