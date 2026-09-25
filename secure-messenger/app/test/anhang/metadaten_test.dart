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
    // Ein zweiter Durchgang findet nur noch den minimalen Block: der bleibt,
    // und es gibt nichts mehr zu tun.
    expect(ohneMetadaten(sauber), isNull);
    expect(bereinige(sauber), isA<NichtsZuTun>());
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
      expect(bereinige(halb), isA<Unlesbar>());
    });
  });

  // ═══════════════════════════════════════════════ Schnittstelle bereinige
  //
  // Die Oberflaeche muss unterscheiden koennen, ob es nichts zu tun gab oder
  // ob das Bereinigen gescheitert ist — im zweiten Fall geht die Datei MIT
  // Metadaten hinaus, und der Nutzer soll davon wissen.

  group('bereinige', () {
    test('die vier Faelle', () {
      expect(bereinige(probe('mit_gps.jpg')), isA<Bereinigt>());
      expect(bereinige(ohneMetadaten(probe('mit_gps.jpg'))!), isA<NichtsZuTun>());
      expect(bereinige(Uint8List.fromList('%PDF-1.7 hallo'.codeUnits)), isA<NichtUnterstuetzt>());
      expect(bereinige(Uint8List(0)), isA<NichtUnterstuetzt>());
      final kaputt = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 1, 2]);
      expect(bereinige(kaputt), isA<Unlesbar>());
      expect(ohneMetadaten(kaputt), isNull, reason: 'die alte Huelle bleibt bei null');
    });

    test('Unlesbar: auch bei vorOrt bleibt die Eingabe unberuehrt', () {
      final kaputt = Uint8List.fromList(probe('mit_gps.heic'));
      kaputt[suche(kaputt, 'iloc') + 4] = 3; // Version 3 gibt es nicht
      final vorher = Uint8List.fromList(kaputt);
      final e = bereinige(kaputt, vorOrt: true);
      expect(e, isA<Unlesbar>());
      expect((e as Unlesbar).grund, isNotEmpty);
      expect(kaputt, vorher);
    });

    test('abgeschnittenes PNG und WebP: Unlesbar', () {
      final png = probe('mit_text.png');
      expect(bereinige(Uint8List.sublistView(png, 0, png.length - 20)), isA<Unlesbar>());
      final webp = probe('mit_exif.webp');
      expect(bereinige(Uint8List.sublistView(webp, 0, webp.length - 20)), isA<Unlesbar>());
    });

    test('Bereinigt traegt dieselben Bytes wie ohneMetadaten', () {
      for (final name in ['mit_gps.jpg', 'mit_text.png', 'mit_exif.webp', 'mit_gps.heic', 'mit_ort.mp4']) {
        final e = bereinige(probe(name));
        expect(e, isA<Bereinigt>(), reason: name);
        expect((e as Bereinigt).bytes, ohneMetadaten(probe(name)), reason: name);
      }
    });
  });

  // ═════════════════════════════════════════════════ JPEG hinter den Daten
  //
  // progressiv_gps.jpg (48 x 32, progressiv, 10 Scans) und neustart_gps.jpg
  // (48 x 32, Neustartmarken nach jedem Block, dadurch auch 0xFF 0x00 in den
  // Daten) sind echte Kodiererausgabe, mit PIL 12.2 erzeugt, beide mit EXIF
  // samt GPS und Hersteller "ProgCam" bzw. "RstCam". Wie Telefone an ein Foto
  // etwas anhaengen, wird hier nachgebaut — die Anhaenge selbst sind im
  // Aufbau echt (ein ganzes JPEG, ein ganzes MP4).

  group('JPEG-Anhaenge und Scans', () {
    final primaer = probe('mit_gps.jpg');
    final primaerSauber = ohneMetadaten(primaer)!;

    test('zweites JPEG mit GPS hinter EOI (MPF): weg, das erste bleibt heil', () {
      // Wie bei Samsung und Pixel: APP2 "MPF" im ersten Bild verweist auf ein
      // zweites, vollstaendiges JPEG mit eigenem EXIF hinter dem EOI.
      final mpf = jpegAbschnitt(0xE2, [...'MPF'.codeUnits, 0, ...'MM'.codeUnits, 0, 0x2A, 0, 0, 0, 8]);
      final mitMpf = mitAbschnitt(primaer, 1, mpf); // hinter JFIF
      final vorher = Uint8List.fromList([...mitMpf, ...probe('progressiv_gps.jpg')]);
      expect(enthaelt(vorher, 'ProgCam'), isTrue);
      final nachher = ohneMetadaten(vorher)!;
      for (final spur in ['ProgCam', 'TestCam', 'MPF']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      jpegMarken(nachher); // Aufbau gueltig, EOI am Ende
      expect(nachher, primaerSauber, reason: 'genau das bereinigte erste Bild, nichts dahinter');
    });

    test('Samsung-Anhang (SEFH/SEFT) hinter EOI: weg', () {
      final sef = [
        ...'Image_UTC_Data'.codeUnits, ...'1727260496000'.codeUnits,
        ...'MCC_Data'.codeUnits, ...'262'.codeUnits,
        ...'SEFH'.codeUnits, 1, 0, 0, 0, 2, 0, 0, 0, ...'SEFT'.codeUnits,
      ];
      final nachher = ohneMetadaten(Uint8List.fromList([...primaer, ...sef]))!;
      for (final spur in ['Image_UTC_Data', '1727260496000', 'MCC_Data', 'SEFH', 'SEFT']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      expect(nachher, primaerSauber);
    });

    test('Bewegungsfoto: angehaengtes MP4 mit Ort ist weg', () {
      final vorher = Uint8List.fromList([...primaer, ...probe('mit_ort.mp4')]);
      expect(enthaelt(vorher, '+52.5200+013.4050'), isTrue);
      final nachher = ohneMetadaten(vorher)!;
      for (final spur in ['+52.5200+013.4050', 'ftyp', 'moov', 'mdat']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      expect(nachher, primaerSauber);
    });

    test('progressiv: APP1 und COM zwischen den Scans sind weg, alle Scans bleiben', () async {
      final original = probe('progressiv_gps.jpg');
      final scans = jpegMarken(original).where((m) => m.$1 == 0xDA).toList();
      expect(scans.length, greaterThan(2), reason: 'die Probe ist nicht progressiv');
      // Vor den zweiten Scan: ein XMP-Block mit Ort und ein Kommentar.
      final xmp = jpegAbschnitt(0xE1, [
        ...'http://ns.adobe.com/xap/1.0/'.codeUnits, 0,
        ...'<x:xmpmeta><GPSLatitude>48,8.2N</GPSLatitude></x:xmpmeta>'.codeUnits,
      ]);
      final com = jpegAbschnitt(0xFE, 'Kommentar zwischen Scans'.codeUnits);
      var vorher = mitAbschnittVor(original, scans[1].$2, com);
      vorher = mitAbschnittVor(vorher, scans[1].$2, xmp);
      final nachher = ohneMetadaten(vorher)!;
      for (final spur in ['ProgCam', 'Geheim 3000', 'GPSLatitude', 'Kommentar zwischen Scans', 'xap/1.0']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      final marken = jpegMarken(nachher);
      expect(marken.where((m) => m.$1 == 0xDA).length, scans.length);
      expect(marken.where((m) => (m.$1 >= 0xE1 && m.$1 <= 0xEF) || m.$1 == 0xFE), isEmpty);
      // Pixelgenau dasselbe Bild wie vorher.
      expect(await pixel(nachher), await pixel(original));
    });

    test('Neustartmarken und 0xFF00 in den Daten: Bilddaten bitgleich', () async {
      final original = probe('neustart_gps.jpg');
      final vorherMarken = jpegMarken(original);
      final rst = vorherMarken.where((m) => m.$1 >= 0xD0 && m.$1 <= 0xD7).length;
      expect(rst, greaterThan(0), reason: 'die Probe hat keine Neustartmarken');
      final nachher = ohneMetadaten(original)!;
      expect(enthaelt(nachher, 'RstCam'), isFalse);
      final nachherMarken = jpegMarken(nachher);
      expect(nachherMarken.where((m) => m.$1 >= 0xD0 && m.$1 <= 0xD7).length, rst);
      // Vom ersten SOS bis zum Ende: Byte fuer Byte gleich.
      final sosVorher = vorherMarken.firstWhere((m) => m.$1 == 0xDA).$2;
      final sosNachher = nachherMarken.firstWhere((m) => m.$1 == 0xDA).$2;
      expect(nachher.sublist(sosNachher), original.sublist(sosVorher));
      expect(await pixel(nachher), await pixel(original));
    });

    test('progressiv ohne Zusaetze: EXIF weg, Bild pixelgenau gleich', () async {
      final original = probe('progressiv_gps.jpg');
      final nachher = ohneMetadaten(original)!;
      expect(enthaelt(nachher, 'ProgCam'), isFalse);
      jpegMarken(nachher);
      expect(await pixel(nachher), await pixel(original));
      expect(bereinige(nachher), isA<NichtsZuTun>());
    });

    test('abgeschnitten mitten im Scan: EXIF weg, mit EOI abgeschlossen', () {
      final original = probe('progressiv_gps.jpg');
      final scans = jpegMarken(original).where((m) => m.$1 == 0xDA).toList();
      final halb = Uint8List.sublistView(original, 0, scans[3].$2 + 40);
      final nachher = ohneMetadaten(halb)!;
      expect(enthaelt(nachher, 'ProgCam'), isFalse);
      jpegMarken(nachher);
    });

    test('abgeschnitten vor den Bilddaten: Unlesbar', () {
      final original = probe('progressiv_gps.jpg');
      final scans = jpegMarken(original).where((m) => m.$1 == 0xDA).toList();
      expect(bereinige(Uint8List.sublistView(original, 0, scans.first.$2 - 3)), isA<Unlesbar>());
    });

    test('JFIF mit Vorschaubild: das Vorschaubild ist weg, JFIF bleibt', () async {
      // JFIF darf ein unkomprimiertes Vorschaubild tragen, hier 2 x 1 Pixel
      // (6 Bytes RGB) — die Buchstaben sind nur zum Wiederfinden.
      final original = probe('neustart_gps.jpg');
      final ohneApp0 = Uint8List.fromList([0xFF, 0xD8, ...original.sublist(jpegMarken(original)[1].$2)]);
      final jfif = jpegAbschnitt(0xE0, [
        ...'JFIF'.codeUnits, 0, 1, 1, 0, 0, 1, 0, 1, 2, 1, //
        ...'VORSCH'.codeUnits,
      ]);
      final vorher = mitAbschnitt(ohneApp0, 0, jfif);
      final nachher = ohneMetadaten(vorher)!;
      expect(enthaelt(nachher, 'VORSCH'), isFalse);
      expect(enthaelt(nachher, String.fromCharCodes([0xFF, 0xE0, 0, 16, ...'JFIF'.codeUnits])), isTrue);
      jpegMarken(nachher);
      expect(await pixel(nachher), await pixel(original));
    });
  });

  // ══════════════════════════════════════════════════ PNG Erlaubnisliste

  group('PNG Erlaubnisliste', () {
    test('caBX, tIME, eXIf, Unbekanntes und Anhang hinter IEND sind weg; CRCs stimmen', () async {
      final original = probe('mit_text.png');
      final ihdrEnde = 8 + 12 + pngAbschnitte(original).first.$2.length;
      final ohneAnhang = [
        ...original.sublist(0, ihdrEnde),
        ...pngAbschnitt('gAMA', [0, 0, 0xB1, 0x8F]),
        ...pngAbschnitt('pHYs', [0, 0, 0x0B, 0x13, 0, 0, 0x0B, 0x13, 1]),
        ...pngAbschnitt('caBX', 'c2pa Signatur Henrik-Handy'.codeUnits),
        ...pngAbschnitt('tIME', [0x07, 0xEA, 9, 25, 12, 34, 56]),
        ...pngAbschnitt('eXIf', [...'MM'.codeUnits, 0, 0x2A, ...'GPS 48.1372'.codeUnits]),
        ...pngAbschnitt('prVt', 'Standort 48.1372 11.5756'.codeUnits),
        ...original.sublist(ihdrEnde),
      ];
      pngAbschnitte(Uint8List.fromList(ohneAnhang)); // die praeparierte Probe ist gueltig
      final vorher = Uint8List.fromList([...ohneAnhang, ...'Geheimer Anhang hinter IEND'.codeUnits]);
      final nachher = ohneMetadaten(vorher)!;
      for (final spur in ['c2pa', 'Henrik', '48.1372', 'Geheimer Anhang', 'caBX', 'tIME', 'eXIf', 'prVt']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      final typen = pngAbschnitte(nachher).map((t) => t.$1).toList();
      expect(typen.first, 'IHDR');
      expect(typen.last, 'IEND');
      expect(typen, containsAll(['gAMA', 'pHYs', 'IDAT']));
      expect(typen.toSet().difference({'IHDR', 'gAMA', 'pHYs', 'IDAT', 'IEND', 'PLTE', 'tRNS', 'sRGB'}), isEmpty);
      expect(await oeffne(nachher), (8, 6));
      expect(bereinige(nachher), isA<NichtsZuTun>());
    });
  });

  // ═════════════════════════════════════════════════ WebP Erlaubnisliste
  //
  // animiert.webp: 2 Einzelbilder 8 x 6, verlustfrei, mit EXIF ("AnimCam"),
  // mit PIL 12.2 erzeugt.

  group('WebP Erlaubnisliste', () {
    test('unbekannter Abschnitt und Anhang hinter RIFF sind weg, VP8X stimmt', () async {
      final original = probe('mit_exif.webp');
      final vorher = riff([
        ...original.sublist(12),
        ...riffAbschnitt('ZZZZ', 'Standort 48.1372 11.5756 X'.codeUnits), // ungerade Laenge
        ...riffAbschnitt('XMP ', '<x:xmpmeta>XmpGeheim</x:xmpmeta>'.codeUnits),
      ], anhang: 'Geheimer Anhang'.codeUnits);
      final nachher = ohneMetadaten(vorher)!;
      for (final spur in ['48.1372', 'ZZZZ', 'XmpGeheim', 'TestCam', 'Geheimer Anhang']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      final teile = webpAbschnitte(nachher);
      expect(teile.map((t) => t.$1), ['VP8X', 'VP8L']);
      expect(teile.first.$2[0] & 0x2C, 0, reason: 'ICC/EXIF/XMP-Kennbits stehen noch');
      expect(await oeffne(nachher), (8, 6));
      expect(bereinige(nachher), isA<NichtsZuTun>());
    });

    test('Animation: Unbekanntes IM Einzelbild ist weg, beide Bilder bleiben', () async {
      final original = probe('animiert.webp');
      expect(enthaelt(original, 'AnimCam'), isTrue);
      // Einen unbekannten Abschnitt in das erste ANMF schieben.
      final teile = webpAbschnitte(original);
      final erstes = teile.indexWhere((t) => t.$1 == 'ANMF');
      final neu = <int>[];
      for (var k = 0; k < teile.length; k++) {
        var inhalt = teile[k].$2;
        if (k == erstes) {
          inhalt = Uint8List.fromList([...inhalt, ...riffAbschnitt('GEHM', 'Standort 48.1372'.codeUnits)]);
        }
        neu.addAll(riffAbschnitt(teile[k].$1, inhalt));
      }
      final vorher = riff(neu);
      expect(await bildZahl(vorher), 2, reason: 'die praeparierte Probe selbst oeffnet sich');
      final nachher = ohneMetadaten(vorher)!;
      for (final spur in ['AnimCam', '48.1372', 'GEHM']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      expect(webpAbschnitte(nachher).map((t) => t.$1), ['VP8X', 'ANIM', 'ANMF', 'ANMF']);
      expect(await bildZahl(nachher), 2);
    });
  });

  // ═════════════════════════════════════════════ ISO-BMFF Fuellkaesten
  //
  // Schreiber, die Metadaten "loeschen", machen oft nur einen free-Kasten
  // daraus und lassen den Inhalt stehen.

  group('ISO-BMFF Fuellkaesten', () {
    List<int> stcoAuf(int stelle) => [0, 0, 0, 0, 0, 0, 0, 1, ...be32(stelle)];
    final ftyp = kasten('ftyp', [...'isom'.codeUnits, 0, 0, 2, 0, ...'isom'.codeUnits]);

    test('free/skip mit GPS und fremde uuid werden genullt, Baum bleibt gueltig', () {
      final frei = kasten('free', '+48.1300+011.5700/ alter Ort'.codeUnits);
      final mdatAnfang = ftyp.length + frei.length;
      final datei = Uint8List.fromList([
        ...ftyp,
        ...frei,
        ...kasten('mdat', List.filled(32, 0x11)),
        ...kasten('moov', [
          ...kasten('mvhd', [0, 0, 0, 0, ...List.filled(96, 0)]),
          ...kasten('free', 'GPS +48.13 im moov'.codeUnits),
          ...kasten('trak', [
            ...kasten('tkhd', [0, 0, 0, 0, ...List.filled(80, 0)]),
            ...kasten('mdia', [
              ...kasten('minf', [
                ...kasten('stbl', [
                  ...kasten('stco', stcoAuf(mdatAnfang + 8)),
                  ...kasten('skip', 'Standort 48.13 im stbl'.codeUnits),
                ]),
              ]),
            ]),
          ]),
        ]),
        ...kasten('uuid', [...List.filled(16, 0x42), ...'PROF Seriennummer 48.13'.codeUnits]),
        ...kasten('wide', []),
      ]);
      final nachher = ohneMetadaten(datei)!;
      expect(nachher.length, datei.length);
      for (final spur in ['48.13', 'alter Ort', 'Seriennummer', 'PROF']) {
        expect(enthaelt(nachher, spur), isFalse, reason: '"$spur" steht noch in der Datei');
      }
      expect(kaesten(nachher).map((k) => k.$1).toList(), ['ftyp', 'free', 'mdat', 'moov', 'free', 'wide']);
      // Der ganze Baum: dieselben Kaesten an denselben Stellen, nur die uuid
      // heisst jetzt free.
      expect(baum(nachher), [for (final k in baum(datei)) k.$1 == 'uuid' ? ('free', k.$2, k.$3) : k]);
      final (mdA, mdE) = bereich(datei, 'mdat');
      expect(nachher.sublist(mdA, mdE), datei.sublist(mdA, mdE));
      expect(bereinige(nachher), isA<NichtsZuTun>());
    });

    test('free, auf den stco zeigt, sind Nutzdaten und bleiben', () {
      final datei = Uint8List.fromList([
        ...ftyp,
        ...kasten('free', 'NUTZDATEN'.codeUnits),
        ...kasten('moov', [
          ...kasten('trak', [
            ...kasten('mdia', [
              ...kasten('minf', [
                ...kasten('stbl', [...kasten('stco', stcoAuf(ftyp.length + 8))]),
              ]),
            ]),
          ]),
        ]),
      ]);
      expect(bereinige(datei), isA<NichtsZuTun>());
    });

    test('echtes MP4 mit angehaengtem free voller GPS: genullt, spielbar', () async {
      final vorher = Uint8List.fromList([
        ...probe('mit_ort.mp4'),
        ...kasten('free', '+48.1372+011.5756/ com.apple.quicktime.location'.codeUnits),
      ]);
      final nachher = ohneMetadaten(vorher)!;
      expect(nachher.length, vorher.length);
      expect(enthaelt(nachher, '+48.1372'), isFalse);
      expect(baum(nachher).map((k) => (k.$2, k.$3)), baum(vorher).map((k) => (k.$2, k.$3)));
      if (!ffmpegDa) return;
      final ordner = await Directory.systemTemp.createTemp('bitdm-meta');
      try {
        final datei = File('${ordner.path}/sauber.mp4')..writeAsBytesSync(nachher);
        final lauf = await Process.run('ffmpeg', ['-v', 'error', '-i', datei.path, '-f', 'null', '-']);
        expect(lauf.exitCode, 0);
        expect('${lauf.stderr}'.trim(), isEmpty);
      } finally {
        await ordner.delete(recursive: true);
      }
    });

    test('HEIC mit free voller GPS: genullt, Baum unveraendert', () {
      final vorher = Uint8List.fromList([
        ...probe('mit_gps.heic'),
        ...kasten('free', 'GPSLatitude 48.1372 aus dem alten EXIF'.codeUnits),
      ]);
      final nachher = ohneMetadaten(vorher)!;
      expect(enthaelt(nachher, '48.1372'), isFalse);
      expect(enthaelt(nachher, 'TestCam'), isFalse);
      expect(baum(nachher), baum(vorher));
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

List<int> be32(int n) => [n >> 24, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];

/// Der ganze Kastenbaum als (Typ, Anfang, Laenge), in Behaelter hinein. Prueft
/// dabei, dass jeder Kasten in seinen Behaelter passt und die Kinder ihn
/// lueckenlos fuellen — sonst schlaegt der Test fehl.
List<(String, int, int)> baum(Uint8List b) {
  const behaelter = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'dinf', 'edts', 'iprp', 'ipco'};
  final bd = ByteData.sublistView(b);
  final liste = <(String, int, int)>[];
  void ebene(int a, int e, bool oben) {
    while (a < e) {
      expect(a + 8, lessThanOrEqualTo(e), reason: 'Kastenkopf bei $a ragt ueber das Ende');
      final l = bd.getUint32(a);
      expect(l, greaterThanOrEqualTo(8), reason: 'Kasten bei $a zu kurz');
      expect(a + l, lessThanOrEqualTo(e), reason: 'Kasten bei $a ragt ueber seinen Behaelter');
      final typ = String.fromCharCodes(b, a + 4, a + 8);
      liste.add((typ, a, l));
      if (behaelter.contains(typ)) ebene(a + 8, a + l, false);
      if (oben && typ == 'meta') ebene(a + 12, a + l, false);
      a += l;
    }
  }

  ebene(0, b.length, true);
  return liste;
}

// ── JPEG

/// Prueft den Aufbau eines JPEG streng: SOI, Abschnitte mit gueltiger
/// Laenge, Scans bis zur naechsten echten Marke, EOI als LETZTE zwei Bytes.
/// Gibt die Marken hinter SOI als (Marke, Stelle) zurueck, einschliesslich
/// der Neustartmarken in den Scans.
List<(int, int)> jpegMarken(Uint8List b) {
  expect(b.sublist(0, 2), [0xFF, 0xD8], reason: 'kein SOI am Anfang');
  final marken = <(int, int)>[];
  var i = 2;
  while (true) {
    expect(i + 2, lessThanOrEqualTo(b.length), reason: 'Datei endet ohne EOI');
    expect(b[i], 0xFF, reason: 'keine Marke bei $i');
    final m = b[i + 1];
    expect(m, isNot(anyOf(0x00, 0xFF, 0xD8)), reason: 'ungueltige Marke bei $i');
    marken.add((m, i));
    if (m == 0xD9) {
      expect(i + 2, b.length, reason: 'Bytes hinter EOI');
      return marken;
    }
    final l = (b[i + 2] << 8) | b[i + 3];
    expect(l, greaterThanOrEqualTo(2));
    i += 2 + l;
    expect(i, lessThanOrEqualTo(b.length), reason: 'Abschnitt ragt ueber das Ende');
    if (m != 0xDA) continue;
    // Bilddaten: 0xFF 0x00 und RSTn gehoeren dazu.
    while (true) {
      expect(i + 1, lessThan(b.length), reason: 'Scan endet ohne Marke');
      if (b[i] != 0xFF) {
        i++;
      } else if (b[i + 1] == 0x00) {
        i += 2;
      } else if (b[i + 1] >= 0xD0 && b[i + 1] <= 0xD7) {
        marken.add((b[i + 1], i));
        i += 2;
      } else {
        break;
      }
    }
  }
}

/// Ein JPEG-Abschnitt: Marke, Laenge, Inhalt.
List<int> jpegAbschnitt(int marke, List<int> inhalt) {
  final n = inhalt.length + 2;
  return [0xFF, marke, n >> 8, n & 0xFF, ...inhalt];
}

/// [abschnitt] vor die [n]-te Marke hinter SOI eingefuegt.
Uint8List mitAbschnitt(Uint8List b, int n, List<int> abschnitt) =>
    mitAbschnittVor(b, jpegMarken(b)[n].$2, abschnitt);

Uint8List mitAbschnittVor(Uint8List b, int stelle, List<int> abschnitt) =>
    Uint8List.fromList([...b.sublist(0, stelle), ...abschnitt, ...b.sublist(stelle)]);

/// Das dekodierte Bild als RGBA-Pixel.
Future<Uint8List> pixel(Uint8List b) async {
  final codec = await ui.instantiateImageCodec(b);
  final bild = (await codec.getNextFrame()).image;
  final daten = await bild.toByteData(format: ui.ImageByteFormat.rawRgba);
  return daten!.buffer.asUint8List();
}

/// Wie viele Einzelbilder der Dekoder in der Datei findet.
Future<int> bildZahl(Uint8List b) async {
  final codec = await ui.instantiateImageCodec(b);
  for (var k = 0; k < codec.frameCount; k++) {
    await codec.getNextFrame(); // jedes Bild muss sich auch dekodieren lassen
  }
  return codec.frameCount;
}

// ── PNG

final List<int> _crcTafel = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int crc32(List<int> d) {
  var c = 0xFFFFFFFF;
  for (final x in d) {
    c = _crcTafel[(c ^ x) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Ein PNG-Abschnitt mit richtiger Pruefsumme.
List<int> pngAbschnitt(String typ, List<int> inhalt) =>
    [...be32(inhalt.length), ...typ.codeUnits, ...inhalt, ...be32(crc32([...typ.codeUnits, ...inhalt]))];

/// Die Abschnitte eines PNG als (Typ, Inhalt). Prueft Signatur, jede
/// Pruefsumme und dass IEND genau am Dateiende steht.
List<(String, Uint8List)> pngAbschnitte(Uint8List b) {
  expect(b.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final bd = ByteData.sublistView(b);
  final liste = <(String, Uint8List)>[];
  var i = 8;
  while (true) {
    expect(i + 12, lessThanOrEqualTo(b.length), reason: 'PNG endet ohne IEND');
    final l = bd.getUint32(i);
    final typ = String.fromCharCodes(b, i + 4, i + 8);
    final inhalt = b.sublist(i + 8, i + 8 + l);
    expect(bd.getUint32(i + 8 + l), crc32(b.sublist(i + 4, i + 8 + l)), reason: 'Pruefsumme von $typ falsch');
    liste.add((typ, inhalt));
    i += 12 + l;
    if (typ == 'IEND') break;
  }
  expect(i, b.length, reason: 'Bytes hinter IEND');
  return liste;
}

// ── WebP

/// Ein RIFF-Abschnitt samt Fuellbyte.
List<int> riffAbschnitt(String typ, List<int> inhalt) => [
      ...typ.codeUnits,
      inhalt.length & 0xFF, (inhalt.length >> 8) & 0xFF, (inhalt.length >> 16) & 0xFF, inhalt.length >> 24,
      ...inhalt,
      if (inhalt.length.isOdd) 0,
    ];

/// Eine WebP-Datei aus Abschnitten; [anhang] klebt HINTER der RIFF-Laenge.
Uint8List riff(List<int> abschnitte, {List<int> anhang = const []}) {
  final n = abschnitte.length + 4;
  return Uint8List.fromList([
    ...'RIFF'.codeUnits, n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, n >> 24, //
    ...'WEBP'.codeUnits, ...abschnitte, ...anhang,
  ]);
}

/// Die Abschnitte einer WebP-Datei als (Typ, Inhalt ohne Fuellbyte). Prueft,
/// dass die RIFF-Laenge genau zur Datei passt.
List<(String, Uint8List)> webpAbschnitte(Uint8List b) {
  final bd = ByteData.sublistView(b);
  expect(String.fromCharCodes(b, 0, 4), 'RIFF');
  expect(String.fromCharCodes(b, 8, 12), 'WEBP');
  expect(bd.getUint32(4, Endian.little) + 8, b.length, reason: 'RIFF-Laenge passt nicht');
  final liste = <(String, Uint8List)>[];
  var i = 12;
  while (i < b.length) {
    final l = bd.getUint32(i + 4, Endian.little);
    expect(i + 8 + l, lessThanOrEqualTo(b.length));
    liste.add((String.fromCharCodes(b, i, i + 4), b.sublist(i + 8, i + 8 + l)));
    i += 8 + l + (l & 1);
  }
  expect(i, b.length);
  return liste;
}
