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
// HEIC, AVIF UND VIDEO (MP4, MOV, 3GP) sind ISO-BMFF: Kaesten in Kaesten, und
// Verweise darauf als ABSOLUTE Dateipositionen (iloc bei Bildern, stco/co64
// bei Videos). Wer dort einen Kasten herausnimmt, verschiebt alles dahinter
// und muss jeden Verweis nachrechnen — ein Fehler, und das Video ist Rauschen.
// Darum wird hier KEIN Byte verschoben, die Datei behaelt ihre Laenge:
//
//   HEIC   die Exif-Ware (iinf-Typ "Exif") und XMP (mime-Ware mit
//   AVIF   application/rdf+xml) werden an Ort und Stelle ueberschrieben —
//          Exif mit einem leeren TIFF-Kopf, XMP mit einem leeren Paket, der
//          Rest mit Nullen bzw. Leerzeichen. Die Ausrichtung geht dabei NICHT
//          verloren: bei HEIF steht sie in den Eigenschaften irot/imir, EXIF
//          ist dort nur Beiwerk.
//   Video  moov/udta (Ort als ©xyz oder loci, ©mak, ©mod, ...), moov/meta und
//          trak/udta, trak/meta (keys/ilst, bei Apple u. a.
//          com.apple.quicktime.location.ISO6709, make, model, creationdate)
//          und XMP-uuid-Kaesten bekommen den Typ "free" und einen genullten
//          Inhalt — Leser springen darueber wie ueber Fuellmaterial. Die
//          Aufnahmezeit in mvhd, tkhd und mdhd wird auf 0 gesetzt.
//
// Was sich nicht sicher zerlegen laesst (iloc-Version > 2, Verweise in andere
// Dateien, construction_method 2, ...), bleibt unangetastet: lieber eine
// Datei mit Metadaten als eine kaputte.
//
// Andere Formate (Dokumente, Audio) gehen unveraendert hinaus, ebenso
// Ortsdaten in eigenen Spuren (etwa GoPro-GPMF als Datenspur). Das ist eine
// bekannte Grenze, keine Zusage.

import 'dart:typed_data';

/// Die Bytes ohne Metadaten — oder null, wenn es nichts zu entfernen gab
/// oder das Format nicht bekannt ist. Wirft nie: eine Datei, die sich nicht
/// zerlegen laesst, geht so hinaus, wie sie ist, statt den Versand zu stoppen.
///
/// Mit [vorOrt] werden ISO-BMFF-Dateien (HEIC, AVIF, Video) in [b] SELBST
/// geaendert und [b] zurueckgegeben, statt eine Kopie anzulegen — bei einem
/// Video von 300 MB ist das der Unterschied zwischen einer und zwei Kopien im
/// Speicher. Gibt es nichts zu tun oder ist etwas unklar, bleibt [b]
/// unberuehrt: geschrieben wird erst, wenn alles gefunden und geprueft ist.
Uint8List? ohneMetadaten(Uint8List b, {bool vorOrt = false}) {
  try {
    if (_istJpeg(b)) return _jpeg(b);
    if (_istPng(b)) return _png(b);
    if (_istWebp(b)) return _webp(b);
    if (_isoArt(b) != null) return _iso(b, vorOrt);
  } catch (_) {
    return null;
  }
  return null;
}

/// Ob die Datei ein Bild oder Video ist, dessen Metadaten hier entfernt
/// werden koennen.
bool istBereinigbar(Uint8List b) =>
    _istJpeg(b) || _istPng(b) || _istWebp(b) || _isoArt(b) != null;

/// Ob die Datei ein Video ist (MP4, MOV, 3GP, M4V). Dafuer reicht der
/// Dateianfang — die ersten paar hundert Bytes mit dem ftyp-Kasten.
bool istVideo(Uint8List b) => _isoArt(b) == _IsoArt.video;

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

// ═════════════════════════════════════════ ISO-BMFF (HEIC, AVIF, Video)

enum _IsoArt { bild, video }

const _bildMarken = {
  'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'mif1', 'mif2', 'msf1', //
  'avif', 'avis',
};
const _heicMarken = {'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx'};
const _videoMarken = {
  'isom', 'iso2', 'iso3', 'iso4', 'iso5', 'iso6', 'mp41', 'mp42', 'avc1', //
  'qt  ', 'M4V ', 'M4VH', 'M4VP',
};

/// Die Marken aus dem ftyp-Kasten am Dateianfang (Hauptmarke zuerst), oder
/// null, wenn die Datei nicht mit ftyp beginnt.
List<String>? _marken(Uint8List b) {
  if (b.length < 16 || String.fromCharCodes(b, 4, 8) != 'ftyp') return null;
  final laenge = ByteData.sublistView(b).getUint32(0);
  if (laenge < 16 || laenge > b.length) return null;
  final marken = [String.fromCharCodes(b, 8, 12)];
  for (var i = 16; i + 4 <= laenge; i += 4) {
    marken.add(String.fromCharCodes(b, i, i + 4));
  }
  return marken;
}

bool _istVideoMarke(String m) =>
    _videoMarken.contains(m) || m.startsWith('3gp') || m.startsWith('3g2');

_IsoArt? _isoArt(Uint8List b) {
  final marken = _marken(b);
  if (marken == null) return null;
  // Die Hauptmarke entscheidet; nur wenn sie unbekannt ist, die Liste.
  if (_bildMarken.contains(marken.first)) return _IsoArt.bild;
  if (_istVideoMarke(marken.first)) return _IsoArt.video;
  if (marken.any(_bildMarken.contains)) return _IsoArt.bild;
  if (marken.any(_istVideoMarke)) return _IsoArt.video;
  return null;
}

/// Ein Kasten: Typ, Anfang des Kopfes, Anfang des Inhalts, Ende.
class _Kasten {
  _Kasten(this.typ, this.anfang, this.inhalt, this.ende);
  final String typ;
  final int anfang;
  final int inhalt;
  final int ende;
}

/// Die Kaesten zwischen [a] und [e] — oder null, wenn einer ueber das Ende
/// hinausragt. Dann stimmt etwas nicht, und es wird nichts angefasst.
List<_Kasten>? _kaesten(Uint8List b, int a, int e) {
  final bd = ByteData.sublistView(b);
  final liste = <_Kasten>[];
  while (a + 8 <= e) {
    var laenge = bd.getUint32(a);
    var kopf = 8;
    if (laenge == 1) {
      if (a + 16 > e) return null;
      final gross = bd.getUint64(a + 8);
      if (gross > e - a) return null;
      laenge = gross;
      kopf = 16;
    } else if (laenge == 0) {
      laenge = e - a; // reicht bis zum Ende
    }
    if (laenge < kopf || a + laenge > e) return null;
    liste.add(_Kasten(String.fromCharCodes(b, a + 4, a + 8), a, a + kopf, a + laenge));
    a += laenge;
  }
  return liste;
}

/// Eine Aenderung: an [stelle] stehen danach [bytes]. Die Laenge der Datei
/// bleibt immer gleich.
typedef _Flicken = (int stelle, List<int> bytes);

const _frei = [0x66, 0x72, 0x65, 0x65]; // "free"

/// Aus dem Kasten wird Fuellmaterial: Typ "free", Inhalt genullt. Nur
/// umbenennen hiesse, Ort und Kamera als lesbaren Text mitzuschicken — ein
/// Blick mit `strings` genuegte.
List<_Flicken> _alsFrei(_Kasten k) =>
    [(k.anfang + 4, _frei), (k.inhalt, Uint8List(k.ende - k.inhalt))];

/// Die UUID, unter der Adobe XMP in ISO-BMFF ablegt.
const _xmpUuid = [
  0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
  0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
];

bool _istXmpUuid(Uint8List b, _Kasten k) {
  if (k.typ != 'uuid' || k.inhalt + 16 > k.ende) return false;
  for (var i = 0; i < 16; i++) {
    if (b[k.inhalt + i] != _xmpUuid[i]) return false;
  }
  return true;
}

Uint8List? _iso(Uint8List b, bool vorOrt) {
  final oben = _kaesten(b, 0, b.length);
  if (oben == null) return null;
  final flicken = <_Flicken>[];
  for (final k in oben) {
    if (k.typ == 'meta') {
      final f = _heifWaren(b, k);
      if (f == null) return null;
      flicken.addAll(f);
    } else if (k.typ == 'moov') {
      final f = _moov(b, k);
      if (f == null) return null;
      flicken.addAll(f);
    } else if (_istXmpUuid(b, k)) {
      flicken.addAll(_alsFrei(k));
    }
  }
  // Nur, was wirklich etwas aendert: eine schon bereinigte Datei ergibt null.
  flicken.removeWhere((f) {
    for (var i = 0; i < f.$2.length; i++) {
      if (b[f.$1 + i] != f.$2[i]) return false;
    }
    return true;
  });
  if (flicken.isEmpty) return null;
  final aus = vorOrt ? b : Uint8List.fromList(b);
  for (final (stelle, bytes) in flicken) {
    aus.setRange(stelle, stelle + bytes.length, bytes);
  }
  return aus;
}

// ── Video: umbenennen statt entfernen

/// Die Aenderungen fuer moov — oder null, wenn der Kasten kaputt ist.
List<_Flicken>? _moov(Uint8List b, _Kasten moov) {
  final kinder = _kaesten(b, moov.inhalt, moov.ende);
  if (kinder == null) return null;
  final flicken = <_Flicken>[];
  for (final k in kinder) {
    if (k.typ == 'udta' || k.typ == 'meta' || _istXmpUuid(b, k)) {
      flicken.addAll(_alsFrei(k));
    } else if (k.typ == 'mvhd') {
      flicken.addAll(_ohneZeit(b, k));
    } else if (k.typ == 'trak') {
      final spur = _kaesten(b, k.inhalt, k.ende);
      if (spur == null) return null;
      for (final s in spur) {
        if (s.typ == 'udta' || s.typ == 'meta' || _istXmpUuid(b, s)) {
          flicken.addAll(_alsFrei(s));
        } else if (s.typ == 'tkhd') {
          flicken.addAll(_ohneZeit(b, s));
        } else if (s.typ == 'mdia') {
          final medien = _kaesten(b, s.inhalt, s.ende);
          if (medien == null) return null;
          for (final m in medien) {
            if (m.typ == 'mdhd') flicken.addAll(_ohneZeit(b, m));
          }
        }
      }
    }
  }
  return flicken;
}

/// Erstellungs- und Aenderungszeit in mvhd, tkhd, mdhd auf 0 (= 1904). Sie
/// stehen direkt hinter Version und Kennbits: zweimal 32 Bit bei Version 0,
/// zweimal 64 Bit bei Version 1.
List<_Flicken> _ohneZeit(Uint8List b, _Kasten k) {
  if (k.inhalt + 4 > k.ende) return const [];
  final laenge = b[k.inhalt] == 1 ? 16 : 8;
  if (k.inhalt + 4 + laenge > k.ende) return const [];
  return [(k.inhalt + 4, List<int>.filled(laenge, 0))];
}

// ── HEIF: Waren an Ort und Stelle ueberschreiben

/// Die Aenderungen fuer die Exif- und XMP-Waren eines HEIF-meta-Kastens —
/// oder null, wenn sich eine davon nicht sicher finden laesst.
List<_Flicken>? _heifWaren(Uint8List b, _Kasten meta) {
  // meta ist ein "Voll-Kasten": vier Bytes Version und Kennbits vorneweg.
  final kinder = _kaesten(b, meta.inhalt + 4, meta.ende);
  if (kinder == null) return null;
  _Kasten? iinf, iloc, idat;
  for (final k in kinder) {
    if (k.typ == 'iinf') iinf = k;
    if (k.typ == 'iloc') iloc = k;
    if (k.typ == 'idat') idat = k;
  }
  if (iinf == null) return const [];
  final ziele = _metadatenWaren(b, iinf);
  if (ziele == null) return null;
  if (ziele.isEmpty) return const [];
  if (iloc == null) return null;
  final orte = _warenOrte(b, iloc, idat, ziele.keys.toSet());
  if (orte == null) return null;
  final flicken = <_Flicken>[];
  for (final MapEntry(key: id, value: istExif) in ziele.entries) {
    final stuecke = orte[id];
    if (stuecke == null) return null; // Ware ohne Ort: lieber nichts anfassen
    final gesamt = stuecke.fold<int>(0, (s, t) => s + t.$2);
    final ersatz = istExif ? _leeresHeifExif(gesamt) : _leeresXmp(gesamt);
    var pos = 0;
    for (final (stelle, laenge) in stuecke) {
      flicken.add((stelle, Uint8List.sublistView(ersatz, pos, pos + laenge)));
      pos += laenge;
    }
  }
  return flicken;
}

/// Ware-Nummer -> true fuer Exif, false fuer XMP. Null, wenn iinf kaputt ist.
Map<int, bool>? _metadatenWaren(Uint8List b, _Kasten iinf) {
  final bd = ByteData.sublistView(b);
  var i = iinf.inhalt;
  if (i + 4 > iinf.ende) return null;
  final version = b[i];
  i += 4;
  i += version == 0 ? 2 : 4; // Anzahl — die Kaesten dahinter zaehlen selbst
  if (i > iinf.ende) return null;
  final eintraege = _kaesten(b, i, iinf.ende);
  if (eintraege == null) return null;
  final ziele = <int, bool>{};
  for (final e in eintraege) {
    if (e.typ != 'infe' || e.inhalt + 4 > e.ende) continue;
    final v = b[e.inhalt];
    var p = e.inhalt + 4;
    int id;
    String typ = '';
    if (v >= 2) {
      if (p + (v == 2 ? 2 : 4) + 6 > e.ende) return null;
      id = v == 2 ? bd.getUint16(p) : bd.getUint32(p);
      p += (v == 2 ? 2 : 4) + 2; // Nummer, Schutz
      typ = String.fromCharCodes(b, p, p + 4);
      p += 4;
    } else {
      if (p + 4 > e.ende) return null;
      id = bd.getUint16(p);
      p += 4;
    }
    final (_, nachName) = _zeichenkette(b, p, e.ende); // Name der Ware
    if (typ == 'Exif') {
      ziele[id] = true;
    } else if (typ == 'mime' || v < 2) {
      final (inhaltsTyp, _) = _zeichenkette(b, nachName, e.ende);
      if (inhaltsTyp == 'application/rdf+xml') ziele[id] = false;
    }
  }
  return ziele;
}

/// Eine nullterminierte Zeichenkette ab [a] und die Stelle dahinter.
(String, int) _zeichenkette(Uint8List b, int a, int e) {
  var i = a;
  while (i < e && b[i] != 0) {
    i++;
  }
  return (String.fromCharCodes(b, a, i), i < e ? i + 1 : e);
}

/// Wo die Waren [ids] liegen: Ware-Nummer -> Stuecke (Stelle, Laenge), als
/// absolute Positionen in der Datei. Null bei allem, was hier nicht sicher
/// verstanden wird.
Map<int, List<(int, int)>>? _warenOrte(
    Uint8List b, _Kasten iloc, _Kasten? idat, Set<int> ids) {
  final bd = ByteData.sublistView(b);
  final e = iloc.ende;
  var i = iloc.inhalt;
  if (i + 8 > e) return null;
  final version = b[i];
  if (version > 2) return null;
  i += 4;
  final versatzGroesse = b[i] >> 4;
  final laengenGroesse = b[i] & 0x0F;
  final basisGroesse = b[i + 1] >> 4;
  final indexGroesse = version == 0 ? 0 : b[i + 1] & 0x0F;
  i += 2;
  for (final g in [versatzGroesse, laengenGroesse, basisGroesse, indexGroesse]) {
    if (g != 0 && g != 4 && g != 8) return null;
  }

  int? lies(int groesse) {
    if (i + groesse > e) return null;
    final wert = switch (groesse) {
      0 => 0,
      2 => bd.getUint16(i),
      4 => bd.getUint32(i),
      _ => bd.getUint64(i),
    };
    i += groesse;
    return wert;
  }

  final anzahl = lies(version < 2 ? 2 : 4);
  if (anzahl == null) return null;
  final orte = <int, List<(int, int)>>{};
  for (var n = 0; n < anzahl; n++) {
    final id = lies(version < 2 ? 2 : 4);
    if (id == null) return null;
    var bauart = 0;
    if (version >= 1) {
      final w = lies(2);
      if (w == null) return null;
      bauart = w & 0x0F;
    }
    final quelle = lies(2); // data_reference_index: 0 = diese Datei
    final basis = lies(basisGroesse);
    final stueckZahl = lies(2);
    if (quelle == null || basis == null || stueckZahl == null) return null;
    final stuecke = <(int, int)>[];
    for (var s = 0; s < stueckZahl; s++) {
      if (indexGroesse > 0 && lies(indexGroesse) == null) return null;
      final versatz = lies(versatzGroesse);
      final laenge = lies(laengenGroesse);
      if (versatz == null || laenge == null) return null;
      stuecke.add((versatz, laenge));
    }
    if (!ids.contains(id)) continue;
    if (quelle != 0) return null;
    // Bauart 0: Stellen in der Datei. Bauart 1: im idat-Kasten. Bauart 2
    // (aus anderen Waren zusammengesetzt) wird hier nicht verstanden.
    final int anfang, ende;
    if (bauart == 0) {
      anfang = 0;
      ende = b.length;
    } else if (bauart == 1 && idat != null) {
      anfang = idat.inhalt;
      ende = idat.ende;
    } else {
      return null;
    }
    final absolut = <(int, int)>[];
    for (final (versatz, laenge) in stuecke) {
      final stelle = anfang + basis + versatz;
      // Laenge 0 heisst: bis zum Ende. Nur bei einem einzigen Stueck sinnvoll.
      final l = laenge == 0 ? ende - stelle : laenge;
      if (laenge == 0 && stueckZahl != 1) return null;
      if (stelle < anfang || l < 0 || stelle + l > ende) return null;
      absolut.add((stelle, l));
    }
    orte[id] = absolut;
  }
  return orte;
}

/// Ersatz fuer eine HEIF-Exif-Ware gleicher Laenge: vier Bytes Versatz zum
/// TIFF-Kopf (0), dann ein TIFF mit leerem Verzeichnis, dann Nullen.
Uint8List _leeresHeifExif(int laenge) {
  final aus = Uint8List(laenge);
  const kopf = [
    0x00, 0x00, 0x00, 0x00, // TIFF-Kopf folgt direkt
    0x4D, 0x4D, 0x00, 0x2A, // "MM", 42
    0x00, 0x00, 0x00, 0x08, // erstes Verzeichnis ab Byte 8
    0x00, 0x00, // kein Eintrag
    0x00, 0x00, 0x00, 0x00, // kein weiteres Verzeichnis
  ];
  if (laenge >= kopf.length) aus.setRange(0, kopf.length, kopf);
  return aus;
}

/// Ersatz fuer eine XMP-Ware gleicher Laenge: ein leeres Paket, aufgefuellt
/// mit Leerzeichen (die darf XML am Ende haben).
Uint8List _leeresXmp(int laenge) {
  final aus = Uint8List(laenge)..fillRange(0, laenge, 0x20);
  const leer = '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>';
  if (laenge >= leer.length) aus.setRange(0, leer.length, leer.codeUnits);
  return aus;
}

// ═══════════════════════════════════════════════════════════════════ Namen

/// Ein neutraler Dateiname fuer ein Bild oder Video, dessen Metadaten
/// entfernt wurden.
///
/// "PXL_20260925_123456.jpg" verraet das Telefon (PXL = Pixel) und die
/// Sekunde der Aufnahme; "IMG-20260925-WA0003.jpg" sogar, woher es kam.
/// Videos heissen "video-xxxx.mp4" (bzw. .mov, .3gp, .m4v).
String neutralerBildname(Uint8List b, int zufall) {
  final nummer = (zufall % 0x10000).toRadixString(16).padLeft(4, '0');
  if (_isoArt(b) == _IsoArt.video) return 'video-$nummer.${_videoEndung(b)}';
  final endung = _istJpeg(b)
      ? 'jpg'
      : _istPng(b)
          ? 'png'
          : _istWebp(b)
              ? 'webp'
              : _bildEndung(b);
  return 'bild-$nummer.$endung';
}

String _bildEndung(Uint8List b) {
  final marken = _marken(b) ?? const [];
  final avif = marken.contains('avif') || marken.contains('avis');
  return avif && !marken.any(_heicMarken.contains) ? 'avif' : 'heic';
}

String _videoEndung(Uint8List b) {
  final haupt = _marken(b)!.first;
  if (haupt == 'qt  ') return 'mov';
  if (haupt.startsWith('3gp')) return '3gp';
  if (haupt.startsWith('3g2')) return '3g2';
  if (haupt.startsWith('M4V')) return 'm4v';
  return 'mp4';
}
