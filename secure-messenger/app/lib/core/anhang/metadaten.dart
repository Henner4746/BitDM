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
//   JPEG   APP1 (EXIF, XMP), APP3..APP13, APP15, COM fliegen raus. APP0 bleibt
//          NUR als JFIF (ohne das Vorschaubild, das JFIF mitfuehren darf),
//          APP14 nur als Adobe-Farbraum, APP2 nur als ICC-Profil — ohne die
//          zeigt ein Bild falsche Farben.
//          DIE AUSRICHTUNG BLEIBT: Telefone speichern Hochformat quer und
//          vermerken die Drehung in EXIF. Wer EXIF ganz entfernt, schickt jedes
//          Hochformatfoto auf der Seite liegend. Darum wird ein neuer,
//          minimaler EXIF-Block geschrieben, der nichts als die Drehung
//          enthaelt.
//          HINTER DEN BILDDATEN: die Bilddaten werden bis zu ihrem Ende (EOI)
//          durchgegangen, und dort ist Schluss. Was Telefone dahinter
//          anhaengen, faellt weg — ein zweites JPEG mit eigenem EXIF und GPS
//          (MPF: Samsung, Pixel), Samsungs SEFH/SEFT-Anhang (Aufnahmezeit,
//          Netzkennung), das MP4 eines Bewegungsfotos (Motion Photo).
//   PNG    ERLAUBNISLISTE: nur Abschnitte, die zum Bild gehoeren, bleiben
//          (IHDR, PLTE, IDAT, IEND, Farbe, Transparenz, Aufloesung, APNG).
//          Alles andere fliegt raus — Text, eXIf, tIME, C2PA (caBX) und jeder
//          Abschnitt, den hier niemand kennt.
//   WebP   ebenso: nur VP8, VP8L, VP8X, ALPH, ANIM, ANMF, ICCP bleiben, auch
//          innerhalb der Einzelbilder einer Animation. Die Kennbits im VP8X
//          werden angepasst, die RIFF-Laenge neu gesetzt.
//
// Bei allen drei gilt: was hinter dem Ende der eigentlichen Datei klebt (hinter
// EOI, IEND bzw. der RIFF-Laenge), faellt weg.
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
//          und uuid-Kaesten (XMP und Herstellereigenes) bekommen den Typ "free"
//          und einen genullten Inhalt — Leser springen darueber wie ueber
//          Fuellmaterial. Die Aufnahmezeit in mvhd, tkhd und mdhd wird auf 0
//          gesetzt.
//   Beide  vorhandene Fuellkaesten (free, skip, wide) werden genullt. Schreiber
//          lassen dort gern den alten Inhalt stehen, wenn sie Metadaten
//          "loeschen" — ein GPS-Eintrag im free-Kasten ist fuer `strings`
//          genauso lesbar wie im udta. Ausnahme: zeigt ein Verweis (iloc,
//          stco/co64) hinein, sind es Nutzdaten, und der Kasten bleibt.
//
// Was sich nicht sicher zerlegen laesst (iloc-Version > 2, Verweise in andere
// Dateien, construction_method 2, ...), bleibt unangetastet: lieber eine
// Datei mit Metadaten als eine kaputte. [bereinige] meldet diesen Fall
// ausdruecklich (Unlesbar), damit die Oberflaeche warnen kann.
//
// Andere Formate (Dokumente, Audio) gehen unveraendert hinaus, ebenso
// Ortsdaten in eigenen Spuren (etwa GoPro-GPMF als Datenspur). Das ist eine
// bekannte Grenze, keine Zusage.

import 'dart:typed_data';

// ═══════════════════════════════════════════════════════════ Schnittstelle

/// Was [bereinige] mit einer Datei gemacht hat. Vier Faelle, und die
/// Oberflaeche soll sie unterscheiden koennen — vor allem [Unlesbar]: dort
/// geht die Datei MIT ihren Metadaten hinaus, falls der Nutzer nicht
/// gewarnt wird.
///
/// ```dart
/// switch (bereinige(bytes, vorOrt: true)) {
///   case Bereinigt(:final bytes): senden(bytes);
///   case NichtsZuTun(): senden(original);        // schon sauber
///   case NichtUnterstuetzt(): senden(original);  // kein Bild/Video
///   case Unlesbar(:final grund): warnen(grund);  // Metadaten evtl. noch drin
/// }
/// ```
sealed class BereinigungsErgebnis {
  const BereinigungsErgebnis();
}

/// Metadaten wurden entfernt; [bytes] ist die bereinigte Datei. Mit `vorOrt`
/// ist das bei ISO-BMFF (HEIC, AVIF, Video) dieselbe Liste wie die Eingabe,
/// sonst eine neue.
final class Bereinigt extends BereinigungsErgebnis {
  const Bereinigt(this.bytes);
  final Uint8List bytes;
}

/// Das Format ist bekannt und wurde vollstaendig zerlegt, aber es gab nichts
/// zu entfernen — die Eingabe kann so hinaus, wie sie ist.
final class NichtsZuTun extends BereinigungsErgebnis {
  const NichtsZuTun();
}

/// Das Format ist bekannt (JPEG, PNG, WebP, HEIC/AVIF, Video), aber die Datei
/// liess sich nicht sicher zerlegen: kaputt, abgeschnitten, oder eine
/// Variante, die hier nicht verstanden wird. Die Eingabe ist UNVERAENDERT —
/// und kann Metadaten enthalten. [grund] ist fuer Protokolle gedacht, nicht
/// fuer den Nutzer, und enthaelt nichts aus der Datei selbst.
final class Unlesbar extends BereinigungsErgebnis {
  const Unlesbar(this.grund);
  final String grund;
}

/// Kein Format, das hier bereinigt wird (Dokumente, Audio, Unbekanntes).
final class NichtUnterstuetzt extends BereinigungsErgebnis {
  const NichtUnterstuetzt();
}

/// Entfernt die Metadaten aus [b] und sagt, wie es ausging. Wirft nie.
///
/// Mit [vorOrt] werden ISO-BMFF-Dateien (HEIC, AVIF, Video) in [b] SELBST
/// geaendert und in [Bereinigt] zurueckgegeben, statt eine Kopie anzulegen —
/// bei einem Video von 300 MB ist das der Unterschied zwischen einer und zwei
/// Kopien im Speicher. In JEDEM anderen Fall als [Bereinigt] ist [b]
/// unberuehrt: geschrieben wird erst, wenn alles gefunden und geprueft ist.
BereinigungsErgebnis bereinige(Uint8List b, {bool vorOrt = false}) {
  try {
    if (_istJpeg(b)) return _jpeg(b);
    if (_istPng(b)) return _png(b);
    if (_istWebp(b)) return _webp(b);
    if (_isoArt(b) != null) return _iso(b, vorOrt);
  } catch (e) {
    // Ein Zugriff ueber das Ende o. ae., den keine Pruefung abgefangen hat.
    return Unlesbar('Ausnahme beim Zerlegen (${e.runtimeType})');
  }
  return const NichtUnterstuetzt();
}

/// Die Bytes ohne Metadaten — oder null, wenn es nichts zu entfernen gab,
/// das Format nicht bekannt ist ODER die Datei sich nicht zerlegen liess.
/// Wirft nie: eine Datei, die sich nicht zerlegen laesst, geht so hinaus, wie
/// sie ist, statt den Versand zu stoppen.
///
/// Duenne Huelle um [bereinige] fuer Aufrufer, die die Faelle nicht
/// unterscheiden muessen. Wer den Nutzer warnen will, wenn das Bereinigen
/// scheitert, nimmt [bereinige]. [vorOrt] wie dort.
Uint8List? ohneMetadaten(Uint8List b, {bool vorOrt = false}) =>
    switch (bereinige(b, vorOrt: vorOrt)) {
      Bereinigt(:final bytes) => bytes,
      _ => null,
    };

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

/// [Bereinigt], wenn sich wirklich etwas geaendert hat, sonst [NichtsZuTun].
/// Der Vergleich macht das Ganze wiederholbar: eine schon bereinigte Datei
/// (mit ihrem minimalen EXIF-Block) ergibt beim zweiten Mal NichtsZuTun.
BereinigungsErgebnis _ergebnis(Uint8List vorher, Uint8List nachher) {
  if (vorher.length != nachher.length) return Bereinigt(nachher);
  for (var i = 0; i < vorher.length; i++) {
    if (vorher[i] != nachher[i]) return Bereinigt(nachher);
  }
  return const NichtsZuTun();
}

// ════════════════════════════════════════════════════════════════════ JPEG

// Aufbau: SOI, dann Abschnitte (Marke 0xFF xx, zwei Bytes Laenge, Inhalt),
// dann SOS und die entropiekodierten Bilddaten. Die haben KEINE Laenge — sie
// laufen bis zur naechsten Marke. Ein 0xFF in den Daten wird als 0xFF 0x00
// geschrieben, und 0xFF D0..D7 (RSTn) sind Neustartmarken mitten in den
// Daten; beides gehoert noch dazu. Jede andere Marke beendet den Scan.
//
// Progressive JPEGs haben MEHRERE Scans, dazwischen DHT, DQT, DRI — und
// gelegentlich APPn oder COM, die hier ebenso wegfallen wie vorn. Das EOI,
// das die Kette abschliesst, ist das Ende des Bildes; alles dahinter faellt
// weg.

Uint8List? _jfif(Uint8List daten) {
  // JFIF-Inhalt: "JFIF\0", Version (2), Einheit (1), Dichte (2 + 2), Breite
  // und Hoehe des Vorschaubilds (je 1), dann dessen Pixel. Behalten werden
  // die ersten 12 Bytes, das Vorschaubild wird auf 0 x 0 gesetzt. Andere
  // APP0-Arten (JFXX = nur Vorschaubild) fallen ganz weg.
  if (!_beginntMit(daten, 'JFIF\u0000') || daten.length < 14) return null;
  return Uint8List.fromList([0xFF, 0xE0, 0x00, 0x10, ...daten.sublist(0, 12), 0, 0]);
}

BereinigungsErgebnis _jpeg(Uint8List b) {
  final aus = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 2;
  var inBildern = false; // ob der erste Scan (SOS) schon kam
  int? drehung;
  var drehungGeschrieben = false;

  void schreibeDrehung() {
    if (drehung == null || drehung == 1 || drehungGeschrieben) return;
    aus.add(_minimalesExif(drehung));
    drehungGeschrieben = true;
  }

  // Die Datei hoert auf, bevor das EOI kommt — ein abgebrochener Download,
  // eine halb geschriebene Kameradatei. Nach dem ersten Scan ist das ein Bild
  // mit grauem unterem Rand, und die Metadaten davor sind schon heraus:
  // abschliessen und weiter. Davor gibt es keine Bilddaten, die man retten
  // koennte.
  BereinigungsErgebnis abgeschnitten() {
    if (!inBildern) return const Unlesbar('JPEG endet vor den Bilddaten');
    aus.add(const [0xFF, 0xD9]);
    return _ergebnis(b, aus.toBytes());
  }

  while (true) {
    // Fuellbytes (0xFF 0xFF ...) vor einer Marke ueberspringen.
    while (i + 1 < b.length && b[i] == 0xFF && b[i + 1] == 0xFF) {
      i++;
    }
    if (i + 2 > b.length) return abgeschnitten();
    if (b[i] != 0xFF) return const Unlesbar('JPEG: Abschnitt ohne Marke');
    final marke = b[i + 1];
    if (marke == 0xD9) {
      // Das Ende des Bildes. Was dahinter kommt, wird NICHT mitgenommen.
      aus.add(const [0xFF, 0xD9]);
      break;
    }
    if (marke == 0x00 || marke == 0xD8) {
      return const Unlesbar('JPEG: Marke an unerwarteter Stelle');
    }
    if ((marke >= 0xD0 && marke <= 0xD7) || marke == 0x01) {
      // RSTn und TEM haben keinen Inhalt.
      aus.add([0xFF, marke]);
      i += 2;
      continue;
    }
    if (i + 4 > b.length) return abgeschnitten();
    final laenge = (b[i + 2] << 8) | b[i + 3];
    final ende = i + 2 + laenge;
    if (laenge < 2) return const Unlesbar('JPEG: Abschnittslaenge unter 2');
    if (ende > b.length) return abgeschnitten();
    final abschnitt = Uint8List.sublistView(b, i, ende);
    final daten = Uint8List.sublistView(b, i + 4, ende);

    if (marke == 0xDA) {
      // SOS: der Kopf hat eine Laenge, die Bilddaten dahinter nicht.
      if (!inBildern) schreibeDrehung();
      inBildern = true;
      aus.add(abschnitt);
      var p = ende;
      while (true) {
        p = b.indexOf(0xFF, p);
        if (p < 0 || p + 1 >= b.length) {
          p = b.length; // Datei endet in den Bilddaten
          break;
        }
        final n = b[p + 1];
        if (n == 0x00 || (n >= 0xD0 && n <= 0xD7)) {
          p += 2; // 0xFF 0x00 oder RSTn: gehoert zu den Daten
          continue;
        }
        break; // eine echte Marke (oder Fuellbytes davor)
      }
      aus.add(Uint8List.sublistView(b, ende, p));
      i = p;
      continue;
    }

    // Was vor dem ersten Scan gebraucht wird, ist zwischen den Scans
    // bedeutungslos: dort fallen ALLE APPn und COM weg.
    Uint8List? behalten = abschnitt;
    if (marke == 0xE0) {
      behalten = inBildern ? null : _jfif(daten);
    } else if (marke == 0xE1) {
      behalten = null;
      if (!inBildern) drehung ??= _drehungAusExif(daten);
    } else if (marke == 0xE2) {
      if (inBildern || !_beginntMit(daten, 'ICC_PROFILE')) behalten = null;
    } else if (marke == 0xEE) {
      if (inBildern || !_beginntMit(daten, 'Adobe')) behalten = null;
    } else if ((marke >= 0xE3 && marke <= 0xEF) || marke == 0xFE) {
      behalten = null;
    }
    if (behalten != null) {
      aus.add(behalten);
      // Direkt hinter JFIF — dort, wo ein Leser EXIF erwartet.
      if (marke == 0xE0) schreibeDrehung();
    }
    i = ende;
  }
  return _ergebnis(b, aus.toBytes());
}

bool _beginntMit(Uint8List d, String text) {
  if (d.length < text.length) return false;
  for (var k = 0; k < text.length; k++) {
    if (d[k] != text.codeUnitAt(k)) return false;
  }
  return true;
}

/// Liest die Ausrichtung (Tag 0x0112) aus einem EXIF-Abschnitt, oder null.
/// Ein kaputtes EXIF ergibt null statt einer Ausnahme: das EXIF faellt ohnehin
/// weg, und die Datei soll deswegen nicht als unlesbar gelten.
int? _drehungAusExif(Uint8List d) {
  try {
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
  } catch (_) {
    return null;
  }
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

/// Die Abschnitte, die bleiben. ERLAUBNISLISTE statt Sperrliste: PNG erlaubt
/// beliebige eigene Abschnitte, und jede neue Metadaten-Art (C2PA als caBX,
/// Herstellereigenes) waere an einer Sperrliste vorbeigegangen.
///
/// Bild: IHDR, PLTE, IDAT, IEND. Transparenz und Hintergrund: tRNS, bKGD.
/// Farbe: gAMA, cHRM, sRGB, iCCP, sBIT, dazu cICP, mDCV, cLLI (HDR — reine
/// Zahlen fester Laenge, ohne sie waeren HDR-Bilder zu blass). Aufloesung:
/// pHYs (nur DPI). Animation (APNG): acTL, fcTL, fdAT.
const _pngErlaubt = {
  'IHDR', 'PLTE', 'IDAT', 'IEND', //
  'tRNS', 'bKGD',
  'gAMA', 'cHRM', 'sRGB', 'iCCP', 'sBIT', 'cICP', 'mDCV', 'cLLI',
  'pHYs',
  'acTL', 'fcTL', 'fdAT',
};

bool _istBuchstabe(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

BereinigungsErgebnis _png(Uint8List b) {
  final aus = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 8));
  final bd = ByteData.sublistView(b);
  var i = 8;
  var erstes = true;
  while (true) {
    // Ohne IEND ist die Datei abgeschnitten oder etwas stimmt nicht.
    if (i + 12 > b.length) return const Unlesbar('PNG: kein IEND');
    final laenge = bd.getUint32(i);
    final ende = i + 12 + laenge;
    if (laenge > 0x7FFFFFFF || ende > b.length) {
      return const Unlesbar('PNG: Abschnitt ragt ueber das Dateiende');
    }
    for (var k = i + 4; k < i + 8; k++) {
      if (!_istBuchstabe(b[k])) return const Unlesbar('PNG: ungueltiger Abschnittstyp');
    }
    final typ = String.fromCharCodes(b, i + 4, i + 8);
    if (erstes && typ != 'IHDR') return const Unlesbar('PNG: IHDR fehlt am Anfang');
    erstes = false;
    // Abschnitte werden unveraendert samt Pruefsumme uebernommen.
    if (_pngErlaubt.contains(typ)) aus.add(Uint8List.sublistView(b, i, ende));
    i = ende;
    if (typ == 'IEND') break; // was dahinter klebt, faellt weg
  }
  return _ergebnis(b, aus.toBytes());
}

// ════════════════════════════════════════════════════════════════════ WebP

/// Die Abschnitte, die bleiben — ebenfalls eine Erlaubnisliste. EXIF, "XMP "
/// und alles Unbekannte fallen weg.
const _webpErlaubt = {'VP8 ', 'VP8L', 'VP8X', 'ALPH', 'ANIM', 'ANMF', 'ICCP'};

/// Innerhalb eines Einzelbilds (ANMF) einer Animation. Die Norm erlaubt dort
/// "unbekannte Abschnitte" — genug Platz fuer Metadaten.
const _webpBildErlaubt = {'ALPH', 'VP8 ', 'VP8L'};

/// Die Abschnitte zwischen [a] und [e], soweit in [erlaubt], als fertige
/// Bytes (Kopf, Inhalt, Fuellbyte bei ungerader Laenge) — oder null, wenn
/// einer ueber [e] hinausragt. ANMF wird dabei selbst gefiltert und seine
/// Laenge neu gesetzt.
List<(String, Uint8List)>? _webpAbschnitte(
    Uint8List b, int a, int e, Set<String> erlaubt) {
  final bd = ByteData.sublistView(b);
  final liste = <(String, Uint8List)>[];
  while (a < e) {
    if (a + 8 > e) return null;
    final typ = String.fromCharCodes(b, a, a + 4);
    final laenge = bd.getUint32(a + 4, Endian.little);
    if (a + 8 + laenge > e) return null;
    // Das Fuellbyte darf am Ende fehlen (manche Schreiber lassen es weg);
    // in der Ausgabe steht es immer.
    final naechster = a + 8 + laenge + (laenge & 1);
    if (erlaubt.contains(typ)) {
      if (typ == 'ANMF') {
        // 16 Bytes Rahmen (Lage, Groesse, Dauer, Kennbits), dann Abschnitte.
        if (laenge < 16) return null;
        final innen = _webpAbschnitte(b, a + 24, a + 8 + laenge, _webpBildErlaubt);
        if (innen == null) return null;
        final inhalt = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, a + 8, a + 24));
        for (final (_, t) in innen) {
          inhalt.add(t);
        }
        liste.add((typ, _webpAbschnitt('ANMF', inhalt.toBytes())));
      } else {
        liste.add((typ, _webpAbschnitt(typ, Uint8List.sublistView(b, a + 8, a + 8 + laenge))));
      }
    }
    a = naechster;
  }
  return liste;
}

/// Ein WebP-Abschnitt: Typ, Laenge (little endian), Inhalt, Fuellbyte.
Uint8List _webpAbschnitt(String typ, Uint8List inhalt) {
  final aus = Uint8List(8 + inhalt.length + (inhalt.length & 1));
  aus.setRange(0, 4, typ.codeUnits);
  ByteData.sublistView(aus).setUint32(4, inhalt.length, Endian.little);
  aus.setRange(8, 8 + inhalt.length, inhalt);
  return aus;
}

BereinigungsErgebnis _webp(Uint8List b) {
  final riff = ByteData.sublistView(b).getUint32(4, Endian.little);
  // Die RIFF-Laenge zaehlt ab Byte 8. Was dahinter steht, gehoert nicht zur
  // Datei und faellt weg.
  final dateiEnde = 8 + riff;
  if (riff < 4 || dateiEnde > b.length) {
    return const Unlesbar('WebP: RIFF-Laenge passt nicht zur Datei');
  }
  final teile = _webpAbschnitte(b, 12, dateiEnde, _webpErlaubt);
  if (teile == null) return const Unlesbar('WebP: Abschnitt ragt ueber das Ende');
  final hatIcc = teile.any((t) => t.$1 == 'ICCP');
  for (final (typ, t) in teile) {
    // Im VP8X stehen Kennbits fuer ICC (0x20), EXIF (0x08) und XMP (0x04).
    // Stehen sie noch, suchen Leser nach Abschnitten, die es nicht mehr gibt.
    // Alpha (0x10) und Animation (0x02) bleiben — die Abschnitte dazu auch.
    if (typ == 'VP8X' && t.length > 8) {
      t[8] &= ~0x0C;
      if (!hatIcc) t[8] &= ~0x20;
    }
  }
  final koerper = BytesBuilder(copy: false);
  for (final (_, t) in teile) {
    koerper.add(t);
  }
  final inhalt = koerper.toBytes();
  final kopf = ByteData(12)
    ..setUint8(0, 0x52)..setUint8(1, 0x49)..setUint8(2, 0x46)..setUint8(3, 0x46) // RIFF
    ..setUint32(4, inhalt.length + 4, Endian.little)
    ..setUint8(8, 0x57)..setUint8(9, 0x45)..setUint8(10, 0x42)..setUint8(11, 0x50); // WEBP
  final aus = (BytesBuilder(copy: false)
        ..add(kopf.buffer.asUint8List())
        ..add(inhalt))
      .toBytes();
  return _ergebnis(b, aus);
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

/// Fuellkaesten. Ihr Inhalt hat keine Bedeutung — und genau deshalb steht
/// dort oft, was ein Schreiber beim "Loeschen" einfach stehen liess.
const _fuellTypen = {'free', 'skip', 'wide'};

/// Kaesten, die nur Kaesten enthalten und in denen Fuellkaesten vorkommen.
/// moof/traf (fragmentierte Videos) bleiben aussen vor: dort zeigen
/// Verweise relativ zum Fragment, und das wird hier nicht nachgerechnet.
const _behaelter = {
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'dinf', 'edts', 'mvex', //
  'iprp', 'ipco',
};

/// Alle Fuellkaesten in [kaesten] und den Behaeltern darin. Der HEIF-meta-
/// Kasten der obersten Ebene zaehlt als Behaelter (mit vier Bytes Version
/// und Kennbits vorneweg). Was sich nicht zerlegen laesst, wird uebergangen:
/// dort wird dann eben nichts genullt.
void _fuellkaesten(Uint8List b, List<_Kasten> kaesten, List<_Kasten> funde,
    {bool oben = false}) {
  for (final k in kaesten) {
    List<_Kasten>? kinder;
    if (_fuellTypen.contains(k.typ)) {
      funde.add(k);
    } else if (_behaelter.contains(k.typ)) {
      kinder = _kaesten(b, k.inhalt, k.ende);
    } else if (oben && k.typ == 'meta' && k.inhalt + 4 <= k.ende) {
      kinder = _kaesten(b, k.inhalt + 4, k.ende);
    }
    if (kinder != null) _fuellkaesten(b, kinder, funde);
  }
}

BereinigungsErgebnis _iso(Uint8List b, bool vorOrt) {
  final oben = _kaesten(b, 0, b.length);
  if (oben == null) return const Unlesbar('ISO-BMFF: Kastenlaengen stimmen nicht');
  final flicken = <_Flicken>[];
  // Bereiche, auf die Verweise zeigen (iloc, stco/co64): dort liegen
  // Nutzdaten, auch wenn der Kasten "free" heisst. null = nicht bekannt.
  List<(int, int)>? belegt = [];
  for (final k in oben) {
    if (k.typ == 'meta') {
      final f = _heifWaren(b, k);
      if (f == null) return const Unlesbar('HEIF: Metadaten-Waren nicht sicher auffindbar');
      flicken.addAll(f);
      final orte = _heifBelegt(b, k);
      if (orte == null) {
        belegt = null;
      } else {
        belegt?.addAll(orte);
      }
    } else if (k.typ == 'moov') {
      final f = _moov(b, k);
      if (f == null) return const Unlesbar('Video: moov-Kasten kaputt');
      flicken.addAll(f);
      final stellen = _stueckStellen(b, k);
      if (stellen == null) {
        belegt = null;
      } else {
        belegt?.addAll(stellen.map((s) => (s, s + 1)));
      }
    }
  }

  bool nutzdaten(_Kasten k) =>
      belegt != null && belegt.any((r) => r.$1 < k.ende && r.$2 > k.inhalt);

  for (final k in oben) {
    // XMP (Adobe) oder Herstellereigenes (Sony, Canon, 360-Grad-Angaben):
    // zum Abspielen oder Anzeigen braucht es nichts davon — ausser ein
    // Verweis zeigt hinein.
    if (k.typ == 'uuid' && !nutzdaten(k)) flicken.addAll(_alsFrei(k));
  }

  final fuellung = <_Kasten>[];
  _fuellkaesten(b, oben, fuellung, oben: true);
  for (final k in fuellung) {
    if (belegt == null) {
      // Die Verweise liessen sich nicht vollstaendig lesen. Ist der Kasten
      // leer, ist das egal; steht etwas drin, laesst sich nicht sagen, ob
      // es Nutzdaten sind — dann lieber melden als raten.
      for (var i = k.inhalt; i < k.ende; i++) {
        if (b[i] != 0) return const Unlesbar('ISO-BMFF: Fuellkasten mit Inhalt, Verweise unklar');
      }
      continue;
    }
    if (nutzdaten(k)) continue;
    flicken.add((k.inhalt, Uint8List(k.ende - k.inhalt)));
  }

  // Nur, was wirklich etwas aendert: eine schon bereinigte Datei ergibt
  // NichtsZuTun.
  flicken.removeWhere((f) {
    for (var i = 0; i < f.$2.length; i++) {
      if (b[f.$1 + i] != f.$2[i]) return false;
    }
    return true;
  });
  if (flicken.isEmpty) return const NichtsZuTun();
  final aus = vorOrt ? b : Uint8List.fromList(b);
  for (final (stelle, bytes) in flicken) {
    aus.setRange(stelle, stelle + bytes.length, bytes);
  }
  return Bereinigt(aus);
}

// ── Video: umbenennen statt entfernen

/// Die Aenderungen fuer moov — oder null, wenn der Kasten kaputt ist.
List<_Flicken>? _moov(Uint8List b, _Kasten moov) {
  final kinder = _kaesten(b, moov.inhalt, moov.ende);
  if (kinder == null) return null;
  final flicken = <_Flicken>[];
  for (final k in kinder) {
    if (k.typ == 'udta' || k.typ == 'meta' || k.typ == 'uuid') {
      flicken.addAll(_alsFrei(k));
    } else if (k.typ == 'mvhd') {
      flicken.addAll(_ohneZeit(b, k));
    } else if (k.typ == 'trak') {
      final spur = _kaesten(b, k.inhalt, k.ende);
      if (spur == null) return null;
      for (final s in spur) {
        if (s.typ == 'udta' || s.typ == 'meta' || s.typ == 'uuid') {
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

/// Wo die Stuecke (chunks) aller Spuren beginnen, laut stco/co64 — als
/// absolute Dateipositionen. Null, wenn sich eine Tabelle nicht lesen laesst.
List<int>? _stueckStellen(Uint8List b, _Kasten moov) {
  final bd = ByteData.sublistView(b);
  final stellen = <int>[];
  List<_Kasten>? kinder(_Kasten k) => _kaesten(b, k.inhalt, k.ende);
  final spuren = kinder(moov);
  if (spuren == null) return null;
  for (final trak in spuren.where((k) => k.typ == 'trak')) {
    for (final mdia in (kinder(trak) ?? const <_Kasten>[]).where((k) => k.typ == 'mdia')) {
      final minfs = kinder(mdia);
      if (minfs == null) return null;
      for (final minf in minfs.where((k) => k.typ == 'minf')) {
        final stbls = kinder(minf);
        if (stbls == null) return null;
        for (final stbl in stbls.where((k) => k.typ == 'stbl')) {
          final tabellen = kinder(stbl);
          if (tabellen == null) return null;
          for (final t in tabellen) {
            if (t.typ != 'stco' && t.typ != 'co64') continue;
            // Voll-Kasten: Version/Kennbits (4), Anzahl (4), dann Eintraege.
            final breite = t.typ == 'stco' ? 4 : 8;
            if (t.inhalt + 8 > t.ende) return null;
            final anzahl = bd.getUint32(t.inhalt + 4);
            if (t.inhalt + 8 + anzahl * breite > t.ende) return null;
            for (var n = 0; n < anzahl; n++) {
              final p = t.inhalt + 8 + n * breite;
              stellen.add(breite == 4 ? bd.getUint32(p) : bd.getUint64(p));
            }
          }
        }
      }
    }
  }
  return stellen;
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

/// Die Kinder eines HEIF-meta-Kastens und darin iinf, iloc, idat — oder null,
/// wenn meta kaputt ist.
({_Kasten? iinf, _Kasten? iloc, _Kasten? idat})? _metaTeile(Uint8List b, _Kasten meta) {
  // meta ist ein "Voll-Kasten": vier Bytes Version und Kennbits vorneweg.
  final kinder = _kaesten(b, meta.inhalt + 4, meta.ende);
  if (kinder == null) return null;
  _Kasten? iinf, iloc, idat;
  for (final k in kinder) {
    if (k.typ == 'iinf') iinf = k;
    if (k.typ == 'iloc') iloc = k;
    if (k.typ == 'idat') idat = k;
  }
  return (iinf: iinf, iloc: iloc, idat: idat);
}

/// Die Aenderungen fuer die Exif- und XMP-Waren eines HEIF-meta-Kastens —
/// oder null, wenn sich eine davon nicht sicher finden laesst.
List<_Flicken>? _heifWaren(Uint8List b, _Kasten meta) {
  final teile = _metaTeile(b, meta);
  if (teile == null) return null;
  final (:iinf, :iloc, :idat) = teile;
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

/// Alle Dateibereiche, auf die iloc zeigt (Bauart 0), als (Anfang, Ende).
/// Null, wenn iloc sich nicht lesen laesst. Ohne iloc: keine.
List<(int, int)>? _heifBelegt(Uint8List b, _Kasten meta) {
  final teile = _metaTeile(b, meta);
  if (teile == null) return null;
  if (teile.iloc == null) return const [];
  final orte = _warenOrte(b, teile.iloc!, null, const {}, alle: true);
  if (orte == null) return null;
  return [
    for (final stuecke in orte.values)
      for (final (stelle, laenge) in stuecke) (stelle, stelle + laenge),
  ];
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
///
/// Mit [alle] zaehlen alle Waren, deren Daten direkt in der Datei stehen
/// (Bauart 0); was in idat, in anderen Waren oder anderen Dateien liegt,
/// wird dann uebergangen statt abgelehnt — gefragt ist nur, welche Bytes der
/// Datei belegt sind.
Map<int, List<(int, int)>>? _warenOrte(
    Uint8List b, _Kasten iloc, _Kasten? idat, Set<int> ids, {bool alle = false}) {
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
    if (alle) {
      if (quelle != 0 || bauart != 0) continue;
    } else {
      if (!ids.contains(id)) continue;
      if (quelle != 0) return null;
    }
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
