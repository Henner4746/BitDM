// ruhe_datei.dart — Anhangdateien verschluesselt auf dem Geraet ablegen.
//
// WARUM ES DAS GIBT (Pruefung vom 25.09.2026, Befund MITTEL): bis dahin war
// nur die Datenbank verschluesselt. Geholte Anhaenge, die eigene Kopie beim
// Versand und die Dateien aus einer Sicherung lagen im Klartext unter
// anhaenge/. Die Sperre der App schuetzte also die Nachrichten, aber nicht
// die Fotos und Dokumente daneben: wer an die Dateien kommt (forensisches
// Auslesen eines Android-Telefons nach dem ersten Entsperren, ein anderer
// Prozess desselben Benutzers am Rechner), las jede Datei mit.
//
// Jetzt liegt dort nur noch dieses Format. Der Schluessel stammt aus den
// zwoelf Woertern (KeyDerivation.attachmentInfo) und liegt nur im Speicher,
// solange die App entsperrt ist. Klartext entsteht erst auf Verlangen — im
// Speicher fuer Vorschaubilder, sonst als kurzlebige Datei (siehe
// RealMessengerCore.entschluesselterAnhang).
//
// ══════════════════════════════════════════════════════════════════ FORMAT
//
//   Kopf (31 Byte):
//     "BITDM-RUHE"    10 Byte  Magie — erkennt verschluesselte Dateien, auch
//                              fuer die Umstellung alter Klartextdateien
//     Fassung          1 Byte  = 1
//     Stueckgroesse    4 Byte  big endian, 1 KiB .. 16 MiB (ab Werk 1 MiB)
//     Salz            16 Byte  Zufall, je Datei
//
//   danach Stueck 0, 1, 2, ... je  Chiffretext (Stueckgroesse Byte, nur das
//   letzte darf kuerzer sein) ‖ GCM-Beglaubigung (16 Byte).
//
// SCHLUESSEL JE DATEI: HKDF-SHA256(Ablageschluessel, salt = Salz,
// info = "bitdm ruhe datei v1"). Damit haengt die Sicherheit der Nonces nicht
// daran, dass sich zufaellige Werte ueber alle Dateien eines Geraets nie
// wiederholen — jede Datei hat ihren eigenen Schluessel, und die Nonces
// duerfen einfach mitzaehlen.
//
// NONCE (12 Byte): vier Nullbytes ‖ Stuecknummer (8 Byte, big endian).
//
// BEGLAUBIGTER ZUSATZ: der ganze Kopf ‖ Stuecknummer (8 Byte) ‖ ein Byte
// "letztes Stueck" (1) oder nicht (0). Das ist die STREAM-Bauweise (Hoang,
// Reyhanitabar, Rogaway, Vizar 2015) und faengt ab:
//   * VERTAUSCHEN von Stuecken — die Nummer steckt im Zusatz und im Nonce;
//   * ABSCHNEIDEN an einer Stueckgrenze — das nun letzte Stueck wurde mit
//     "nicht letztes" verschluesselt und geht mit "letztes" nicht auf;
//   * ANHAENGEN hinter dem letzten Stueck — dann steht das echte letzte
//     nicht mehr am Ende und geht mit "nicht letztes" nicht auf;
//   * einen VERAENDERTEN KOPF (andere Stueckgroesse, anderes Salz) — er
//     steht in jedem Zusatz.
//
// Eine leere Datei ist ein einziges, leeres letztes Stueck (nur die 16 Byte
// Beglaubigung). "Kein Stueck" gibt es nicht — sonst waere eine bis auf den
// Kopf abgeschnittene Datei von einer leeren nicht zu unterscheiden.
//
// AES-256-GCM und nicht ChaCha20: dieselbe Wahl wie fuer die Stuecke im
// Lager, und damit derselbe native Weg auf Android (native_krypto.dart) —
// dort rechnet die AES-Hardware des Telefons, gemessen um den Faktor 24
// schneller als Dart. Bei einer 5-GiB-Datei ist das der Unterschied zwischen
// Sekunden und Minuten.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'native_krypto.dart';
import 'stueck_krypto.dart';

/// Eine abgelegte Datei laesst sich nicht entschluesseln.
///
/// Wie bei [StueckKaputt] EIN Fehler fuer alle Faelle — falscher Schluessel,
/// veraenderte, vertauschte oder abgeschnittene Bytes. [grund] nennt nur die
/// Stelle, nie Inhalt.
class RuheDateiKaputt implements Exception {
  const RuheDateiKaputt(this.grund);
  final String grund;
  @override
  String toString() => 'RuheDateiKaputt: $grund';
}

/// Der Klartext waere groesser als erlaubt (Vorschau im Speicher).
class RuheDateiZuGross implements Exception {
  const RuheDateiZuGross(this.grenze);
  final int grenze;
  @override
  String toString() => 'RuheDateiZuGross: mehr als $grenze Byte';
}

/// Ergebnis der Umstellung alter Klartextdateien.
class RuheUmstellung {
  const RuheUmstellung({required this.umgestellt, required this.offen});

  /// Wie viele Dateien in diesem Lauf verschluesselt wurden.
  final int umgestellt;

  /// Wie viele noch im Klartext liegen (Fehler oder Abbruch) — beim
  /// naechsten Entsperren wieder dran.
  final int offen;
}

class RuheDatei {
  RuheDatei._();

  static final Uint8List magie = Uint8List.fromList(ascii.encode('BITDM-RUHE'));
  static const int fassung = 1;
  static const int _saltLaenge = 16;
  static const int kopfLaenge = 10 + 1 + 4 + _saltLaenge;
  static const int tagLaenge = 16;

  /// Ab Werk 1 MiB je Stueck.
  ///
  /// Groesser als die 64 KiB, die man fuer so etwas oft liest, und zwar
  /// wegen des nativen Wegs: jeder Aufruf ueber den Kanal kostet einen festen
  /// Betrag, und bei 5 GiB waeren es mit 64 KiB 80 000 Aufrufe statt 5 000.
  /// Im Speicher liegt trotzdem nie mehr als ein Stueck auf einmal.
  static const int standardStueck = 1 << 20;
  static const int kleinstesStueck = 1 << 10;
  static const int groesstesStueck = 16 << 20;

  /// Endung einer halb geschriebenen Umstellung (siehe [stelleAltbestandUm]).
  static const String umstellEndung = '.ruhe-neu';

  static const String _dateiInfo = 'bitdm ruhe datei v1';

  /// Wer rechnet. Nativ auf Android, sonst Dart — bitgleich.
  static NativeStueckKrypto chiffre = NativeStueckKrypto();

  static final _zufall = Random.secure();

  // ─────────────────────────────────────────────────────────────── erkennen

  /// Ob [datei] in diesem Format vorliegt (Magie und Fassung).
  ///
  /// Nur der Kopf wird angesehen, nichts entschluesselt. Eine unlesbare
  /// oder fehlende Datei gilt als "nicht verschluesselt" — der Aufrufer
  /// merkt das beim naechsten Schritt ohnehin.
  static Future<bool> istVerschluesselt(File datei) async {
    RandomAccessFile? z;
    try {
      z = await datei.open();
      final kopf = await z.read(magie.length + 1);
      if (kopf.length < magie.length + 1) return false;
      for (var i = 0; i < magie.length; i++) {
        if (kopf[i] != magie[i]) return false;
      }
      return kopf[magie.length] == fassung;
    } on FileSystemException {
      return false;
    } finally {
      await z?.close();
    }
  }

  // ────────────────────────────────────────────────────────── verschluesseln

  /// Verschluesselt [quelle] (beliebig lang, Stueck fuer Stueck) nach [ziel].
  ///
  /// Scheitert es, ist [ziel] danach weg — keine halbe Datei, die wie eine
  /// ganze aussieht.
  static Future<void> verschluessle(
    Stream<List<int>> quelle,
    File ziel,
    Uint8List wurzel, {
    int stueck = standardStueck,
  }) async {
    final s = await RuheSchreiber.oeffne(ziel, wurzel, stueck: stueck);
    try {
      await for (final teil in quelle) {
        await s.schreibe(teil);
      }
      await s.schliesse();
    } catch (_) {
      await s.verwirf();
      rethrow;
    }
  }

  /// Verschluesselt die Datei [quelle] nach [ziel]. [quelle] bleibt unberuehrt.
  static Future<void> verschluessleDatei(File quelle, File ziel, Uint8List wurzel,
          {int stueck = standardStueck}) =>
      verschluessle(quelle.openRead(), ziel, wurzel, stueck: stueck);

  /// Legt [daten] verschluesselt unter [ziel] ab.
  static Future<void> schreibeBytes(File ziel, List<int> daten, Uint8List wurzel,
          {int stueck = standardStueck}) =>
      verschluessle(Stream.value(daten), ziel, wurzel, stueck: stueck);

  // ─────────────────────────────────────────────────────────── entschluesseln

  /// Der Klartext von [quelle], Stueck fuer Stueck.
  ///
  /// Jedes Stueck wird erst herausgegeben, NACHDEM es beglaubigt ist. Ein
  /// Fehler ([RuheDateiKaputt]) kann trotzdem erst spaeter kommen — wer
  /// schreibt, muss das Ergebnis dann verwerfen (so wie
  /// [entschluessleDatei]).
  static Stream<Uint8List> lies(File quelle, Uint8List wurzel) async* {
    final z = await quelle.open();
    try {
      final laenge = await z.length();
      final kopf = await z.read(kopfLaenge);
      if (kopf.length != kopfLaenge) throw const RuheDateiKaputt('kein Kopf');
      for (var i = 0; i < magie.length; i++) {
        if (kopf[i] != magie[i]) throw const RuheDateiKaputt('keine Ablagedatei');
      }
      if (kopf[magie.length] != fassung) {
        throw const RuheDateiKaputt('unbekannte Fassung');
      }
      final stueck = ByteData.sublistView(kopf).getUint32(magie.length + 1);
      if (stueck < kleinstesStueck || stueck > groesstesStueck) {
        throw const RuheDateiKaputt('Stueckgroesse');
      }
      final salz = Uint8List.sublistView(kopf, kopfLaenge - _saltLaenge);
      final schluessel = await _dateiSchluessel(wurzel, salz);

      var pos = kopfLaenge;
      var nummer = 0;
      while (true) {
        final rest = laenge - pos;
        final block = min(rest, stueck + tagLaenge);
        // Weniger als eine Beglaubigung: abgeschnitten. Das trifft auch eine
        // Datei, die nach dem Kopf ganz endet — selbst eine leere Datei hat
        // ein (leeres) letztes Stueck.
        if (block < tagLaenge) throw const RuheDateiKaputt('abgeschnitten');
        final geheim = await z.read(block);
        if (geheim.length != block) throw const RuheDateiKaputt('abgeschnitten');
        pos += block;
        final letztes = pos == laenge;
        final Uint8List klar;
        try {
          klar = await chiffre.entschluessleRoh(
            geheim: geheim,
            schluessel: schluessel,
            nonce: _nonce(nummer),
            zusatz: _zusatz(kopf, nummer, letztes),
          );
        } on StueckKaputt {
          throw RuheDateiKaputt('Stueck ${nummer + 1} geht nicht auf');
        }
        yield klar;
        if (letztes) return;
        nummer++;
      }
    } finally {
      await z.close();
    }
  }

  /// Entschluesselt [quelle] nach [ziel] (Klartext!). Scheitert es, ist
  /// [ziel] danach weg.
  static Future<void> entschluessleDatei(File quelle, File ziel, Uint8List wurzel) async {
    final z = await ziel.open(mode: FileMode.writeOnly);
    try {
      await for (final klar in lies(quelle, wurzel)) {
        await z.writeFrom(klar);
      }
      await z.close();
    } catch (_) {
      try {
        await z.close();
      } catch (_) {}
      try {
        await ziel.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Der ganze Klartext im Speicher — fuer Vorschaubilder und die Sicherung.
  ///
  /// [grenze]: mehr Klartext wird nicht gelesen, sondern mit
  /// [RuheDateiZuGross] abgelehnt — frueh, am Dateiumfang, statt nach dem
  /// Entschluesseln von Gigabytes.
  static Future<Uint8List> entschluessleInSpeicher(File quelle, Uint8List wurzel,
      {int? grenze}) async {
    if (grenze != null) {
      // Wie viel Klartext mindestens drinsteckt: selbst bei der kleinsten
      // erlaubten Stueckgroesse sind nur 16 von je 1040 Byte Beglaubigung.
      final roh = await quelle.length() - kopfLaenge;
      final mindestens = roh * kleinstesStueck ~/ (kleinstesStueck + tagLaenge) - tagLaenge;
      if (mindestens > grenze) throw RuheDateiZuGross(grenze);
    }
    final b = BytesBuilder(copy: false);
    await for (final klar in lies(quelle, wurzel)) {
      b.add(klar);
      if (grenze != null && b.length > grenze) throw RuheDateiZuGross(grenze);
    }
    return b.takeBytes();
  }

  // ──────────────────────────────────────────────────────────── Umstellung

  /// Verschluesselt alte Klartextdateien in [ordner] an Ort und Stelle.
  ///
  /// Fuer Installationen von vor dem 25.09.2026: dort liegen die Anhaenge im
  /// Klartext, und ihre Pfade stehen so in der Datenbank. DER PFAD BLEIBT
  /// DERSELBE — deshalb muss an der Datenbank nichts geaendert werden, und
  /// es gibt keinen Zustand, in dem Datei und Eintrag auseinanderlaufen.
  ///
  /// JE DATEI ABSTURZSICHER:
  ///   1. verschluesselt nach `<name>.ruhe-neu` schreiben (samt flush),
  ///   2. per rename ueber das Original legen — atomar, auf Android wie am
  ///      Rechner. Es gibt keinen Augenblick, in dem die Datei fehlt.
  /// Bricht es in Schritt 1 ab, liegt das Original unveraendert da und die
  /// Nebendatei wird beim naechsten Lauf weggeraeumt. Nach Schritt 2 traegt
  /// die Datei die Magie — und der naechste Lauf laesst sie aus. Der
  /// Fortschritt steht damit in den Dateien selbst; mehrfach laufen schadet
  /// nicht.
  ///
  /// Nur Dateien DIREKT im Ordner (nicht der Klartext-Unterordner). Eine
  /// alte Nebendatei ".teil" eines abgebrochenen Empfangs im Klartext wird
  /// geloescht, sobald sie alt genug ist, dass kein Empfang mehr in sie
  /// schreibt. [abbrechen] wird vor jeder Datei gefragt (Sperre).
  static Future<RuheUmstellung> stelleAltbestandUm(
    Directory ordner,
    Uint8List wurzel, {
    bool Function()? abbrechen,
    int stueck = standardStueck,
  }) async {
    if (!await ordner.exists()) return const RuheUmstellung(umgestellt: 0, offen: 0);
    final dateien = <File>[];
    await for (final e in ordner.list(followLinks: false)) {
      if (e is File) dateien.add(e);
    }
    // Reste eines abgebrochenen Laufs zuerst — sie sind nie das Original.
    for (final f in dateien.where((f) => f.path.endsWith(umstellEndung))) {
      try {
        await f.delete();
      } on FileSystemException {
        // naechster Lauf
      }
    }
    var umgestellt = 0;
    var offen = 0;
    final jetzt = DateTime.now();
    for (final f in dateien) {
      final p = f.path;
      if (p.endsWith(umstellEndung)) continue;
      if (abbrechen?.call() ?? false) {
        offen++;
        continue;
      }
      if (await istVerschluesselt(f)) continue;
      if (p.endsWith('.teil')) {
        // Ein halber Empfang der alten Fassung, im Klartext. Neue Empfaenge
        // schreiben den Kopf sofort — eine ".teil" ohne Magie, die seit zehn
        // Minuten niemand angefasst hat, ist verwaist.
        try {
          if (jetzt.difference(await f.lastModified()) > const Duration(minutes: 10)) {
            await f.delete();
          }
        } on FileSystemException {
          // naechster Lauf
        }
        continue;
      }
      final neu = File('$p$umstellEndung');
      try {
        await verschluessleDatei(f, neu, wurzel, stueck: stueck);
        // Inzwischen geloescht (Einmal-Ansicht angesehen, Nachricht
        // verfallen)? Dann nicht wieder hinlegen.
        if (!await f.exists()) {
          await neu.delete();
          continue;
        }
        await neu.rename(p);
        umgestellt++;
      } catch (_) {
        offen++;
        try {
          if (await neu.exists()) await neu.delete();
        } catch (_) {}
      }
    }
    return RuheUmstellung(umgestellt: umgestellt, offen: offen);
  }

  // ────────────────────────────────────────────────────────────── intern

  static Future<Uint8List> _dateiSchluessel(Uint8List wurzel, List<int> salz) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final k = await hkdf.deriveKey(
      // EINE KOPIE: sperrt die App waehrend einer laufenden Arbeit, wird der
      // Schluessel im Kern mit Nullen ueberschrieben — was hier schon
      // abgeleitet ist, soll davon nicht halb betroffen sein.
      secretKey: SecretKey(Uint8List.fromList(wurzel)),
      nonce: salz,
      info: utf8.encode(_dateiInfo),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  static Uint8List _nonce(int nummer) {
    final n = Uint8List(12);
    _schreibe64(n, 4, nummer);
    return n;
  }

  static Uint8List _zusatz(Uint8List kopf, int nummer, bool letztes) {
    final z = Uint8List(kopfLaenge + 8 + 1);
    z.setAll(0, kopf);
    _schreibe64(z, kopfLaenge, nummer);
    z[kopfLaenge + 8] = letztes ? 1 : 0;
    return z;
  }

  /// 64 Bit big endian, ohne ByteData.setUint64 (das es im Browser nicht
  /// gibt — dort laeuft dieser Weg zwar nicht, uebersetzt wird er aber).
  static void _schreibe64(Uint8List ziel, int ab, int wert) {
    final hoch = wert ~/ 0x100000000;
    final tief = wert % 0x100000000;
    for (var i = 0; i < 4; i++) {
      ziel[ab + 3 - i] = (hoch >> (8 * i)) & 0xFF;
      ziel[ab + 7 - i] = (tief >> (8 * i)) & 0xFF;
    }
  }

  static Uint8List _neuerKopf(int stueck) {
    final k = Uint8List(kopfLaenge);
    k.setAll(0, magie);
    k[magie.length] = fassung;
    ByteData.sublistView(k).setUint32(magie.length + 1, stueck);
    for (var i = kopfLaenge - _saltLaenge; i < kopfLaenge; i++) {
      k[i] = _zufall.nextInt(256);
    }
    return k;
  }
}

/// Schreibt eine Ablagedatei Stueck fuer Stueck — fuer Quellen, deren Ende
/// man erst kennt, wenn es da ist (der Empfang aus dem Lager).
///
/// DAS LETZTE STUECK WIRD ZURUECKGEHALTEN: ein volles Stueck geht erst
/// hinaus, wenn danach noch etwas kommt. Nur so weiss der Schreiber, welches
/// das letzte ist — auch dann, wenn die Datei genau an einer Stueckgrenze
/// endet (dann ist das letzte Stueck voll) oder leer ist (dann ist es leer).
class RuheSchreiber {
  RuheSchreiber._(this.ziel, this._z, this._kopf, this._schluessel, int stueck)
      : _puffer = Uint8List(stueck);

  final File ziel;
  final RandomAccessFile _z;
  final Uint8List _kopf;
  final Uint8List _schluessel;
  final Uint8List _puffer;
  var _fuell = 0;
  var _nummer = 0;
  var _zu = false;

  /// Legt [ziel] an (ueberschreibt!) und schreibt den Kopf sofort — eine
  /// angefangene Datei traegt damit von Anfang an die Magie (siehe die
  /// ".teil"-Regel in [RuheDatei.stelleAltbestandUm]).
  static Future<RuheSchreiber> oeffne(File ziel, Uint8List wurzel,
      {int stueck = RuheDatei.standardStueck}) async {
    if (stueck < RuheDatei.kleinstesStueck || stueck > RuheDatei.groesstesStueck) {
      throw ArgumentError.value(stueck, 'stueck');
    }
    final kopf = RuheDatei._neuerKopf(stueck);
    final schluessel = await RuheDatei._dateiSchluessel(
        wurzel, Uint8List.sublistView(kopf, RuheDatei.kopfLaenge - RuheDatei._saltLaenge));
    final z = await ziel.open(mode: FileMode.writeOnly);
    try {
      await z.writeFrom(kopf);
    } catch (_) {
      await z.close();
      rethrow;
    }
    return RuheSchreiber._(ziel, z, kopf, schluessel, stueck);
  }

  Future<void> schreibe(List<int> daten) async {
    if (_zu) throw StateError('schon geschlossen');
    var pos = 0;
    while (pos < daten.length) {
      // Erst JETZT hinaus: es kommt nachweislich noch etwas dahinter.
      if (_fuell == _puffer.length) await _gibAus(letztes: false);
      final n = min(_puffer.length - _fuell, daten.length - pos);
      _puffer.setRange(_fuell, _fuell + n, daten, pos);
      _fuell += n;
      pos += n;
    }
  }

  /// Letztes Stueck hinaus, auf den Datentraeger, zu.
  Future<void> schliesse() async {
    if (_zu) return;
    await _gibAus(letztes: true);
    _zu = true;
    await _z.flush();
    await _z.close();
    _puffer.fillRange(0, _puffer.length, 0);
  }

  /// Bricht ab: zu und weg.
  Future<void> verwirf() async {
    if (!_zu) {
      _zu = true;
      try {
        await _z.close();
      } catch (_) {}
    }
    _puffer.fillRange(0, _puffer.length, 0);
    try {
      if (await ziel.exists()) await ziel.delete();
    } catch (_) {}
  }

  Future<void> _gibAus({required bool letztes}) async {
    final geheim = await RuheDatei.chiffre.verschluessleRoh(
      // Eine Kopie des Ausschnitts: der Puffer wird gleich wieder befuellt,
      // und der native Weg liest seine Eingabe erst spaeter aus.
      klar: Uint8List.fromList(Uint8List.sublistView(_puffer, 0, _fuell)),
      schluessel: _schluessel,
      nonce: RuheDatei._nonce(_nummer),
      zusatz: RuheDatei._zusatz(_kopf, _nummer, letztes),
    );
    await _z.writeFrom(geheim);
    _nummer++;
    _fuell = 0;
  }
}
