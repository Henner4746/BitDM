// metadaten.dart — Metadaten aus Bildern entfernen, bevor sie das Geraet
// verlassen.
//
// WAS DRINSTEHT. Ein Foto vom Telefon traegt EXIF mit: Ort (GPS auf wenige
// Meter), Aufnahmezeit, Hersteller und Modell der Kamera, oft eine
// Seriennummer und ein Vorschaubild — das bei bearbeiteten Bildern noch den
// UNBEARBEITETEN Ausschnitt zeigen kann. Ein Messenger, der Inhalte
// verschluesselt und dann die Wohnadresse im Anhang mitschickt, verspricht
// etwas, das er nicht haelt. Signal entfernt EXIF ebenfalls; SimpleX
// neutralisiert seit 6.3 zusaetzlich die Dateinamen.
//
// WIE. Ohne Neukodierung — die kostete Qualitaet, Zeit und eine Abhaengigkeit.
// Die Formate sind Ketten aus Abschnitten, und die Metadaten sind eigene
// Abschnitte, die sich herausnehmen lassen, ohne die Bilddaten anzufassen:
//
//   JPEG   APP1 (EXIF, XMP), APP3..APP13, APP15, COM fliegen raus. APP0
//          (JFIF), APP14 (Adobe-Farbraum) und APP2 NUR als ICC-Profil
//          bleiben — ohne die zeigt ein Bild falsche Farben.
//          DIE AUSRICHTUNG BLEIBT: Telefone speichern Hochformat quer und
//          vermerken die Drehung in EXIF. Wer EXIF ganz entfernt, schickt jedes
//          Hochformatfoto auf der Seite liegend. Darum wird ein neuer,
//          minimaler EXIF-Block geschrieben, der nichts als die Drehung
//          enthaelt.
//   PNG    eXIf, tEXt, zTXt, iTXt, tIME fliegen raus.
//   WebP   die Abschnitte EXIF und "XMP " fliegen raus, die Kennbits im VP8X
//          werden geloescht, die RIFF-Laenge neu gesetzt.
//
// Andere Formate (HEIC, Video, Dokumente) gehen unveraendert hinaus. Das ist
// eine bekannte Grenze, keine Zusage.

import 'dart:typed_data';

/// Die Bytes ohne Metadaten — oder null, wenn es nichts zu entfernen gab
/// oder das Format nicht bekannt ist. Wirft nie: eine Datei, die sich nicht
/// zerlegen laesst, geht so hinaus, wie sie ist, statt den Versand zu stoppen.
Uint8List? ohneMetadaten(Uint8List b) {
  try {
    if (_istJpeg(b)) return _jpeg(b);
    if (_istPng(b)) return _png(b);
    if (_istWebp(b)) return _webp(b);
  } catch (_) {
    return null;
  }
  return null;
}

/// Ob die Datei ein Bild ist, dessen Metadaten hier entfernt werden koennen.
bool istBereinigbar(Uint8List b) => _istJpeg(b) || _istPng(b) || _istWebp(b);

bool _istJpeg(Uint8List b) => b.length > 4 && b[0] == 0xFF && b[1] == 0xD8;
bool _istPng(Uint8List b) =>
    b.length > 8 &&
    b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
    b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A;
bool _istWebp(Uint8List b) =>
    b.length > 16 &&
    String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
    String.fromCharCodes(b.sublist(8, 12)) == 'WEBP';

// ════════════════════════════════════════════════════════════════════ JPEG

Uint8List? _jpeg(Uint8List b) {
  final aus = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  var entfernt = false;
  int? drehung;
  var drehungGeschrieben = false;

  void schreibeDrehung() {
    if (drehung == null || drehung == 1 || drehungGeschrieben) return;
    aus.add(_minimalesExif(drehung));
    drehungGeschrieben = true;
  }

  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null; // kein Abschnittsanfang: lieber nichts anfassen
    var marke = b[i + 1];
    // Fuellbytes (0xFF 0xFF ...) ueberspringen.
    while (marke == 0xFF && i + 2 < b.length) {
      i++;
      marke = b[i + 1];
    }
    if (marke == 0xDA) {
      // Beginn der Bilddaten: ab hier alles unveraendert.
      schreibeDrehung();
      aus.add(Uint8List.sublistView(b, i));
      break;
    }
    if (marke == 0xD9) {
      aus.add([0xFF, 0xD9]);
      break;
    }
    if ((marke >= 0xD0 && marke <= 0xD7) || marke == 0x01) {
      aus.add([0xFF, marke]);
      i += 2;
      continue;
    }
    final laenge = (b[i + 2] << 8) | b[i + 3];
    final ende = i + 2 + laenge;
    if (laenge < 2 || ende > b.length) return null;
    final abschnitt = Uint8List.sublistView(b, i, ende);
    final daten = Uint8List.sublistView(b, i + 4, ende);

    var behalten = true;
    if (marke == 0xE1) {
      behalten = false;
      drehung ??= _drehungAusExif(daten);
    } else if (marke == 0xE2) {
      behalten = _beginntMit(daten, 'ICC_PROFILE');
    } else if ((marke >= 0xE3 && marke <= 0xED) || marke == 0xEF || marke == 0xFE) {
      behalten = false;
    }
    if (behalten) {
      aus.add(abschnitt);
      // Direkt hinter JFIF — dort, wo ein Leser EXIF erwartet.
      if (marke == 0xE0) schreibeDrehung();
    } else {
      entfernt = true;
    }
    i = ende;
  }
  if (!entfernt) return null;
  return aus.toBytes();
}

bool _beginntMit(Uint8List d, String text) {
  if (d.length < text.length) return false;
  for (var k = 0; k < text.length; k++) {
    if (d[k] != text.codeUnitAt(k)) return false;
  }
  return true;
}

/// Liest die Ausrichtung (Tag 0x0112) aus einem EXIF-Abschnitt, oder null.
int? _drehungAusExif(Uint8List d) {
  if (!_beginntMit(d, 'Exif') || d.length < 14) return null;
  final t = Uint8List.sublistView(d, 6); // TIFF-Kopf
  final klein = t[0] == 0x49 && t[1] == 0x49; // "II" = little endian
  final gross = t[0] == 0x4D && t[1] == 0x4D; // "MM"
  if (!klein && !gross) return null;
  final bd = ByteData.sublistView(t);
  final e = klein ? Endian.little : Endian.big;
  final ifd = bd.getUint32(4, e);
  if (ifd + 2 > t.length) return null;
  final anzahl = bd.getUint16(ifd, e);
  for (var k = 0; k < anzahl; k++) {
    final eintrag = ifd + 2 + k * 12;
    if (eintrag + 12 > t.length) return null;
    if (bd.getUint16(eintrag, e) == 0x0112) {
      final wert = bd.getUint16(eintrag + 8, e);
      return (wert >= 1 && wert <= 8) ? wert : null;
    }
  }
  return null;
}

/// Ein EXIF-Abschnitt, der NUR die Ausrichtung enthaelt.
Uint8List _minimalesExif(int drehung) {
  final tiff = <int>[
    0x4D, 0x4D, 0x00, 0x2A, // "MM", 42
    0x00, 0x00, 0x00, 0x08, // erstes Verzeichnis ab Byte 8
    0x00, 0x01, // ein Eintrag
    0x01, 0x12, 0x00, 0x03, // Tag 0x0112 (Ausrichtung), Typ SHORT
    0x00, 0x00, 0x00, 0x01, // Anzahl 1
    0x00, drehung, 0x00, 0x00, // Wert
    0x00, 0x00, 0x00, 0x00, // kein weiteres Verzeichnis
  ];
  final daten = [...'Exif'.codeUnits, 0, 0, ...tiff];
  final laenge = daten.length + 2;
  return Uint8List.fromList([0xFF, 0xE1, laenge >> 8, laenge & 0xFF, ...daten]);
}

// ═════════════════════════════════════════════════════════════════════ PNG

const _pngWeg = {'eXIf', 'tEXt', 'zTXt', 'iTXt', 'tIME'};

Uint8List? _png(Uint8List b) {
  final aus = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 8));
  final bd = ByteData.sublistView(b);
  var i = 8;
  var entfernt = false;
  while (i + 12 <= b.length) {
    final laenge = bd.getUint32(i);
    final typ = String.fromCharCodes(b.sublist(i + 4, i + 8));
    final ende = i + 12 + laenge;
    if (ende > b.length) return null;
    if (_pngWeg.contains(typ)) {
      entfernt = true;
    } else {
      aus.add(Uint8List.sublistView(b, i, ende));
    }
    i = ende;
    if (typ == 'IEND') break;
  }
  if (!entfernt) return null;
  return aus.toBytes();
}

// ════════════════════════════════════════════════════════════════════ WebP

Uint8List? _webp(Uint8List b) {
  final bd = ByteData.sublistView(b);
  final teile = <Uint8List>[];
  var i = 12;
  var entfernt = false;
  while (i + 8 <= b.length) {
    final typ = String.fromCharCodes(b.sublist(i, i + 4));
    final laenge = bd.getUint32(i + 4, Endian.little);
    final ende = i + 8 + laenge + (laenge.isOdd ? 1 : 0);
    if (ende > b.length) return null;
    if (typ == 'EXIF' || typ == 'XMP ') {
      entfernt = true;
    } else {
      final kopie = Uint8List.fromList(b.sublist(i, ende));
      // Im VP8X stehen Kennbits fuer EXIF (0x08) und XMP (0x04). Stehen sie
      // noch, suchen Leser nach Abschnitten, die es nicht mehr gibt.
      if (typ == 'VP8X' && kopie.length > 8) kopie[8] &= ~0x0C;
      teile.add(kopie);
    }
    i = ende;
  }
  if (!entfernt) return null;
  final koerper = BytesBuilder(copy: false);
  for (final t in teile) {
    koerper.add(t);
  }
  final inhalt = koerper.toBytes();
  final kopf = ByteData(12)
    ..setUint8(0, 0x52)..setUint8(1, 0x49)..setUint8(2, 0x46)..setUint8(3, 0x46) // RIFF
    ..setUint32(4, inhalt.length + 4, Endian.little)
    ..setUint8(8, 0x57)..setUint8(9, 0x45)..setUint8(10, 0x42)..setUint8(11, 0x50); // WEBP
  return (BytesBuilder(copy: false)
        ..add(kopf.buffer.asUint8List())
        ..add(inhalt))
      .toBytes();
}

/// Ein neutraler Dateiname fuer ein Bild, dessen Metadaten entfernt wurden.
///
/// "PXL_20260925_123456.jpg" verraet das Telefon (PXL = Pixel) und die
/// Sekunde der Aufnahme; "IMG-20260925-WA0003.jpg" sogar, woher es kam.
String neutralerBildname(Uint8List b, int zufall) {
  final endung = _istJpeg(b) ? 'jpg' : _istPng(b) ? 'png' : 'webp';
  return 'bild-${(zufall % 0x10000).toRadixString(16).padLeft(4, '0')}.$endung';
}
