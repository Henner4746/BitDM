// rezept.dart — die Anleitung, aus der ein Anhang wieder zusammenwaechst.
//
// EIN ANHANG REIST IN ZWEI TEILEN.
// Die Bytes liegen im Zwischenlager (dateien.bitdm.net), in Stuecken,
// verschluesselt. Diese Datei beschreibt den zweiten Teil: eine kurze
// Anleitung, die als GEWOEHNLICHE NACHRICHT durch die Signal-Sitzung geht —
// mit derselben Verschluesselung wie jeder Text, ueber denselben Relay.
//
// Damit hat das Lager alles, was es zum Ausliefern braucht, und nichts, was es
// zum Lesen braeuchte. Es kennt Groesse und Zeitpunkt. Den Schluessel sieht
// es nie, weil der Schluessel niemals dort vorbeikommt.
//
// ═══════════════════════════════════════════════ WARUM JE STUECK EIN SCHLUESSEL
//
// Nicht aus Uebervorsicht, sondern um eine ganze Fehlerklasse abzuschaffen:
// AES-GCM ist gebrochen, sobald ein Schluessel zweimal mit demselben Nonce
// benutzt wird — nicht "etwas schwaecher", sondern gebrochen, der Schluessel
// laesst sich aus zwei solchen Bloecken herausrechnen. Bei EINEM Schluessel
// fuer die ganze Datei muesste ein Zaehler ueber alle Stuecke sauber gefuehrt
// werden, ueber Abbrueche und Wiederaufnahmen hinweg. Bei einem eigenen
// Zufallsschluessel je Stueck gibt es nichts zu zaehlen.
//
// Der Preis: 44 Zeichen je Stueck in der Anleitung. Bei 16-MiB-Stuecken sind
// das fuer 3 GiB etwa 23 KB — der Umschlag darf 64 KiB.
//
// ══════════════════════════════════════════ WARUM DIE NUMMER MITVERSCHLUESSELT
//
// Jedes Stueck fuer sich ist mit GCM beglaubigt; faelschen kann das Lager
// nichts. Aber es koennte VERTAUSCHEN: unter der Kennung von Stueck 3 die
// Bytes von Stueck 5 ausliefern. Jedes Stueck fuer sich wuerde sauber
// entschluesseln, und die zusammengesetzte Datei waere still falsch.
//
// Deshalb steht die Nummer — und wie viele es insgesamt sind — im
// beglaubigten Zusatz (AAD). Ein vertauschtes Stueck entschluesselt dann gar
// nicht mehr, statt falsch.

import 'dart:convert';
import 'dart:typed_data';

class RezeptFormatException implements Exception {
  final String grund;
  const RezeptFormatException(this.grund);
  @override
  String toString() => 'RezeptFormatException: $grund';
}

/// Ein Stueck: wo es liegt, womit es aufgeht, wie gross es ist.
class Stueck {
  const Stueck({
    required this.kennung,
    required this.schluessel,
    required this.nonce,
    required this.klarGroesse,
  });

  /// 52 Zeichen Base32 — die Adresse im Lager UND zugleich die Erlaubnis,
  /// es zu holen. Wer sie hat, darf; wer sie nicht hat, findet sie nicht.
  final String kennung;

  /// 32 Byte. Wird genau einmal benutzt, fuer genau dieses Stueck.
  final Uint8List schluessel;

  /// 12 Byte.
  ///
  /// Bei einem Schluessel, der nur ein einziges Mal vorkommt, waere auch ein
  /// fester Nonce sicher. Er steht trotzdem drin: sollte je jemand Schluessel
  /// wiederverwenden — beim Fortsetzen, beim Umbau, aus Versehen —, faengt ein
  /// zufaelliger Nonce das ab. 16 Zeichen je Stueck sind der Preis dafuer,
  /// dass ein kuenftiger Fehler nicht gleich alles mitnimmt.
  final Uint8List nonce;

  /// Groesse VOR der Verschluesselung. Im Lager liegt sie um 16 Byte groesser
  /// (der GCM-Beglaubigungsanhang).
  final int klarGroesse;

  int get lagerGroesse => klarGroesse + 16;

  Map<String, Object?> alsJson() => {
        'k': kennung,
        's': base64.encode(schluessel),
        'n': base64.encode(nonce),
        'g': klarGroesse,
      };

  static Stueck ausJson(Map<String, Object?> j) {
    final k = j['k'];
    final s = j['s'];
    final n = j['n'];
    final g = j['g'];
    if (k is! String || !_kennungMuster.hasMatch(k)) {
      throw const RezeptFormatException('Kennung ungueltig');
    }
    if (g is! int || g <= 0) {
      throw const RezeptFormatException('Stueckgroesse ungueltig');
    }
    final Uint8List schluessel, nonce;
    try {
      schluessel = base64.decode(s! as String);
      nonce = base64.decode(n! as String);
    } catch (_) {
      throw const RezeptFormatException('Schluessel oder Nonce unlesbar');
    }
    // Die Laengen NICHT der Gegenstelle ueberlassen. Ein 1-Byte-Schluessel
    // wuerde weiter unten irgendwo scheitern — hier scheitert er dort, wo man
    // beim Lesen nachsieht.
    if (schluessel.length != 32) {
      throw const RezeptFormatException('Schluessel ist nicht 32 Byte');
    }
    if (nonce.length != 12) {
      throw const RezeptFormatException('Nonce ist nicht 12 Byte');
    }
    return Stueck(
        kennung: k, schluessel: schluessel, nonce: nonce, klarGroesse: g);
  }

  static final _kennungMuster = RegExp(r'^[a-z2-7]{52}$');
}

/// Die ganze Anleitung.
class Rezept {
  const Rezept({
    required this.name,
    required this.gesamtGroesse,
    required this.pruefsumme,
    required this.stuecke,
  });

  /// Der ANGEZEIGTE Name, nicht der gespeicherte.
  ///
  /// Er kommt von der Gegenstelle und ist damit nichts, worauf man baut. Wer
  /// ihn ungeprueft als Dateinamen nimmt, laedt sich "../../irgendwas" ein.
  /// Das Saeubern passiert beim Speichern, nicht hier — hier steht, was
  /// geschickt wurde.
  final String name;

  final int gesamtGroesse;

  /// SHA-256 ueber die ganze Datei im Klartext.
  ///
  /// Jedes Stueck ist einzeln beglaubigt; diese Summe ist trotzdem nicht
  /// ueberfluessig. Sie faengt das ab, was auf Stueck-Ebene niemand merkt:
  /// eine Anleitung, der ein Stueck fehlt, oder eine, in der die Groessen
  /// nicht zur Datei passen. Sie wird nach dem Zusammensetzen geprueft.
  final Uint8List pruefsumme;

  final List<Stueck> stuecke;

  /// Wie viel im Lager belegt wird — inklusive der Beglaubigungsanhaenge.
  /// Das ist die Zahl, fuer die Marken gebraucht werden, nicht
  /// [gesamtGroesse].
  int get lagerGroesse =>
      stuecke.fold(0, (summe, s) => summe + s.lagerGroesse);

  String alsText() => jsonEncode({
        'v': 1,
        'n': name,
        'g': gesamtGroesse,
        'p': base64.encode(pruefsumme),
        'st': stuecke.map((s) => s.alsJson()).toList(),
      });

  static Rezept ausText(String text) {
    final Map<String, Object?> j;
    try {
      j = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (e) {
      throw RezeptFormatException('unlesbare Anleitung: $e');
    }

    // Eine kuenftige Fassung koennte ein anderes Format schicken. Dann ist
    // "kenne ich nicht" die richtige Antwort — nicht der Versuch, es trotzdem
    // zu lesen.
    if (j['v'] != 1) {
      throw RezeptFormatException('unbekannte Fassung ${j['v']}');
    }

    final roh = j['st'];
    if (roh is! List || roh.isEmpty) {
      throw const RezeptFormatException('keine Stuecke');
    }
    if (roh.length > hoechstStueckzahl) {
      // Sonst laesst sich mit einer kurzen Nachricht eine sehr lange Arbeit
      // ausloesen.
      throw const RezeptFormatException('zu viele Stuecke');
    }
    final stuecke = roh
        .map((e) => Stueck.ausJson((e as Map).cast<String, Object?>()))
        .toList();

    final g = j['g'];
    if (g is! int || g <= 0) {
      throw const RezeptFormatException('Gesamtgroesse ungueltig');
    }

    // DIE STUECKE MUESSEN DIE DATEI ERGEBEN. Ohne diese Zeile koennte eine
    // Anleitung 3 GB ankuendigen und drei Stuecke zu je 1 KB auffuehren — die
    // Oberflaeche zeigte "3 GB", der Fortschritt bliebe stehen, und niemand
    // wuesste, warum.
    final summe = stuecke.fold(0, (a, s) => a + s.klarGroesse);
    if (summe != g) {
      throw RezeptFormatException(
          'Stuecke ergeben $summe Byte, angekuendigt sind $g');
    }

    // Doppelte Kennungen: zwei Stuecke wuerden dieselben Bytes holen. Das
    // faellt sonst erst beim Zusammensetzen auf, und auch nur ueber die
    // Pruefsumme.
    if (stuecke.map((s) => s.kennung).toSet().length != stuecke.length) {
      throw const RezeptFormatException('doppelte Kennung');
    }

    final Uint8List pruefsumme;
    try {
      pruefsumme = base64.decode(j['p']! as String);
    } catch (_) {
      throw const RezeptFormatException('Pruefsumme unlesbar');
    }
    if (pruefsumme.length != 32) {
      throw const RezeptFormatException('Pruefsumme ist nicht 32 Byte');
    }

    final name = j['n'];
    if (name is! String || name.isEmpty || name.length > 255) {
      throw const RezeptFormatException('Name fehlt oder ist zu lang');
    }

    return Rezept(
      name: name,
      gesamtGroesse: g,
      pruefsumme: pruefsumme,
      stuecke: stuecke,
    );
  }

  /// Mehr Stuecke passen nicht in einen Umschlag.
  ///
  /// Der Relay laesst 64 KiB Chiffretext durch; ein Stueck kostet in der
  /// Anleitung rund 130 Byte. 256 Stuecke sind gut 33 KB und lassen Luft fuer
  /// Name, Auffuellung und den Aufschlag der Verschluesselung.
  static const int hoechstStueckzahl = 256;
}
