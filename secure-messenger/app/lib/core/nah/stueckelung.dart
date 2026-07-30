// stueckelung.dart — einen Umschlag in Funk-Haeppchen zerlegen und drueben
// wieder zusammensetzen.
//
// WOFUER
// Ueber den Relay geht ein Umschlag in einem Stueck: WebSocket, beliebig
// grosse Rahmen, TCP sortiert und wiederholt. Ueber Funk gibt es das nicht.
// Ein BLE-Paket fasst nach der Aushandlung typischerweise 185 Byte, ohne sie
// nur 20. Ein Umschlag von 400 bis 700 Byte muss also zerfallen und drueben
// wieder eins werden.
//
// WARUM DAS EINE EIGENE SCHICHT IST
// Weil sie nicht wissen muss, WORUEBER sie geht. Dieselbe Zerlegung traegt
// ueber BLE und ueber Wi-Fi Direct; was sich unterscheidet, ist allein die
// Haeppchengroesse. Und weil sie ohne Funk vollstaendig pruefbar ist —
// nativer Code, den man nur auf zwei Telefonen ausprobieren kann, ist in
// diesem Projekt bisher die einzige Stelle gewesen, an der sich ernste Fehler
// halten konnten.
//
// ═════════════════════════════════════════════ WER HIER ETWAS EINWERFEN KANN
//
// JEDER IN REICHWEITE. Anders als beim Relay gibt es hier keine Anmeldung:
// wer funkt, funkt. Erst der Inhalt ist durch die Signal-Sitzung geschuetzt,
// nicht der Weg dorthin. Diese Schicht muss also damit rechnen, dass ihr
// jemand absichtlich Unsinn schickt — und darf sich davon weder den Speicher
// vollschreiben noch durcheinanderbringen lassen.
//
// Daraus folgen die drei Schranken weiter unten: hoechstens so viele
// Sendungen gleichzeitig, hoechstens so viele Bytes zusammen, und alles
// haelt nur eine begrenzte Zeit. Ohne sie genuegte ein Fremder, der
// angefangene Sendungen schickt und verschwindet, um die App aus dem
// Speicher zu drueckem.
//
// ═════════════════════════════════════════════════════ DER RAHMEN, 9 BYTE
//
//   0     Fassung
//   1-2   Sendungsnummer   welche Sendung
//   3-4   Stueck           das wievielte, ab 0
//   5-6   Stueckzahl       wie viele insgesamt
//   7-8   Pruefsumme       CRC-16 der GANZEN Sendung
//   9..   Nutzlast
//
// DIE PRUEFSUMME STEHT IN JEDEM STUECK und nicht nur im letzten. Das kostet
// zwei Byte je Haeppchen — bei 185 Byte also gut ein Prozent — und bringt
// zweierlei: der Empfaenger kennt das Ziel von Anfang an, und Stuecke aus
// zwei verschiedenen Sendungen mit derselben Nummer fallen sofort auf, statt
// erst am Ende als unlesbarer Umschlag.
//
// Sie ersetzt KEINE Verschluesselung und soll es nicht. Der Inhalt ist schon
// verschlusselt; die Pruefsumme trennt nur "die Funkstrecke hat es
// verdorben" von "mit der Krypto stimmt etwas nicht". Wer diese beiden Faelle
// nicht auseinanderhalten kann, sucht Tage am falschen Ende.

import 'dart:typed_data';

/// Etwas am Rahmen stimmt nicht. Das Stueck wird verworfen.
class StueckKaputt implements Exception {
  const StueckKaputt(this.grund);
  final String grund;
  @override
  String toString() => 'StueckKaputt: $grund';
}

/// Die Sendung ist zu gross oder zu zerstueckelt.
class SendungZuGross implements Exception {
  const SendungZuGross(this.grund);
  final String grund;
  @override
  String toString() => 'SendungZuGross: $grund';
}

class Rahmen {
  static const int fassung = 1;
  static const int laenge = 9;

  /// Wie viel eine Sendung hoechstens gross sein darf.
  ///
  /// Dieselben 64 KiB wie beim Relay (BITDM_MAX_CT). Eine Zahl an zwei
  /// Stellen ist eine Zahl zu viel, aber die andere steht in Python auf einem
  /// Server — hier bleibt nur, sie gleich zu halten und das hinzuschreiben.
  static const int hoechstgroesse = 64 * 1024;

  /// Wie viele Stuecke eine Sendung hoechstens hat.
  ///
  /// Ergibt sich aus der Hoechstgroesse und der kleinsten sinnvollen
  /// Nutzlast. Die Grenze steht trotzdem eigens da: sie schuetzt gegen einen
  /// Absender, der 65535 Stuecke ankuendigt und drei schickt.
  static const int hoechstStueckzahl = 4096;
}

/// Zerlegt eine Sendung in Haeppchen.
///
/// [nutzlastJeStueck] ist die Groesse OHNE Rahmen — also das, was der
/// Transport an Nutzlast durchlaesst, minus [Rahmen.laenge]. Diese Rechnung
/// gehoert dem Aufrufer, weil nur er die ausgehandelte Paketgroesse kennt.
List<Uint8List> zerlege(
  Uint8List sendung, {
  required int sendungsnummer,
  required int nutzlastJeStueck,
}) {
  if (sendung.isEmpty) {
    throw const StueckKaputt('eine leere Sendung gibt es nicht');
  }
  if (sendung.length > Rahmen.hoechstgroesse) {
    throw SendungZuGross(
        '${sendung.length} Byte, erlaubt sind ${Rahmen.hoechstgroesse}');
  }
  if (nutzlastJeStueck < 1) {
    throw const StueckKaputt('Nutzlast je Stueck muss mindestens 1 sein');
  }
  if (sendungsnummer < 0 || sendungsnummer > 0xFFFF) {
    throw const StueckKaputt('Sendungsnummer passt nicht in zwei Byte');
  }

  final zahl = (sendung.length + nutzlastJeStueck - 1) ~/ nutzlastJeStueck;
  if (zahl > Rahmen.hoechstStueckzahl) {
    throw SendungZuGross(
        '$zahl Stuecke, erlaubt sind ${Rahmen.hoechstStueckzahl}');
  }

  final summe = crc16(sendung);
  final stuecke = <Uint8List>[];
  for (var i = 0; i < zahl; i++) {
    final von = i * nutzlastJeStueck;
    final bis = (von + nutzlastJeStueck).clamp(0, sendung.length);
    final stueck = Uint8List(Rahmen.laenge + (bis - von));
    final sicht = ByteData.sublistView(stueck);
    stueck[0] = Rahmen.fassung;
    sicht.setUint16(1, sendungsnummer);
    sicht.setUint16(3, i);
    sicht.setUint16(5, zahl);
    sicht.setUint16(7, summe);
    stueck.setRange(Rahmen.laenge, stueck.length, sendung, von);
    stuecke.add(stueck);
  }
  return stuecke;
}

/// Ein aufgetrenntes Stueck, so wie es vom Funk kommt.
class Stueck {
  const Stueck({
    required this.sendungsnummer,
    required this.nummer,
    required this.zahl,
    required this.summe,
    required this.nutzlast,
  });

  final int sendungsnummer;
  final int nummer;
  final int zahl;
  final int summe;
  final Uint8List nutzlast;

  /// Liest den Rahmen. Wirft [StueckKaputt], wenn etwas nicht stimmen KANN —
  /// nicht, wenn es nur nicht passt: ein Stueck mit einer unbekannten
  /// Sendungsnummer ist voellig in Ordnung.
  static Stueck lies(Uint8List roh) {
    if (roh.length < Rahmen.laenge) {
      throw StueckKaputt('${roh.length} Byte, der Rahmen allein braucht '
          '${Rahmen.laenge}');
    }
    if (roh[0] != Rahmen.fassung) {
      throw StueckKaputt('Fassung ${roh[0]}, erwartet ${Rahmen.fassung}');
    }
    final s = ByteData.sublistView(roh);
    final zahl = s.getUint16(5);
    final nummer = s.getUint16(3);
    if (zahl == 0) throw const StueckKaputt('Stueckzahl 0');
    if (zahl > Rahmen.hoechstStueckzahl) {
      throw StueckKaputt('$zahl Stuecke angekuendigt, erlaubt sind '
          '${Rahmen.hoechstStueckzahl}');
    }
    if (nummer >= zahl) {
      throw StueckKaputt('Stueck $nummer von $zahl');
    }
    final nutzlast = Uint8List.sublistView(roh, Rahmen.laenge);
    if (nutzlast.isEmpty) throw const StueckKaputt('Stueck ohne Nutzlast');
    return Stueck(
      sendungsnummer: s.getUint16(1),
      nummer: nummer,
      zahl: zahl,
      summe: s.getUint16(7),
      nutzlast: nutzlast,
    );
  }
}

/// Sammelt Stuecke, bis eine Sendung vollstaendig ist.
///
/// EIN SAMMLER JE GEGENSTELLE. Zwei Geraete koennen dieselbe Sendungsnummer
/// benutzen — sie wuerfeln sie ja nur —, und ein gemeinsamer Sammler machte
/// daraus einen unlesbaren Umschlag.
class Sammler {
  Sammler({
    this.hoechstZahlOffen = 4,
    this.hoechstBytesOffen = 3 * Rahmen.hoechstgroesse,
    this.haltbarkeit = const Duration(seconds: 30),
    DateTime Function()? uhr,
  }) : _jetzt = uhr ?? DateTime.now;

  /// Wie viele angefangene Sendungen gleichzeitig offen sein duerfen.
  final int hoechstZahlOffen;

  /// Wie viele Bytes alle offenen Sendungen zusammen belegen duerfen.
  final int hoechstBytesOffen;

  /// Wie lange eine angefangene Sendung auf ihren Rest wartet.
  ///
  /// Wer aus der Reichweite laeuft, laesst eine halbe Sendung zurueck. Ohne
  /// Frist blieben die fuer immer liegen.
  final Duration haltbarkeit;

  final DateTime Function() _jetzt;
  final _offen = <int, _Angefangen>{};

  /// Was gerade an angefangenen Sendungen im Speicher liegt.
  int get offeneSendungen => _offen.length;
  int get offeneBytes =>
      _offen.values.fold(0, (a, b) => a + b.belegt);

  /// Nimmt ein Stueck an. Gibt die fertige Sendung zurueck, sobald sie
  /// vollstaendig ist — sonst null.
  ///
  /// Wirft [StueckKaputt] nur bei einem Rahmen, der nicht sein kann. Alles
  /// andere — verspaetet, doppelt, unbekannt — ist kein Fehler, sondern
  /// Alltag im Funk.
  Uint8List? nimm(Uint8List roh) {
    final st = Stueck.lies(roh);
    _raeumeAb();

    var a = _offen[st.sendungsnummer];

    // EINE SENDUNG, DIE SICH SELBST WIDERSPRICHT, wird verworfen und neu
    // begonnen. Das passiert, wenn eine Gegenstelle dieselbe Nummer erneut
    // benutzt — nach einem Neustart etwa. Die alten Stuecke stehenzulassen
    // hiesse, die neue Sendung nie vollstaendig zu bekommen.
    if (a != null && (a.zahl != st.zahl || a.summe != st.summe)) {
      _offen.remove(st.sendungsnummer);
      a = null;
    }

    if (a == null) {
      if (_offen.length >= hoechstZahlOffen) {
        // DIE AELTESTE weicht, nicht die neue. Sonst koennte ein Fremder mit
        // vier angefangenen Sendungen jede echte blockieren.
        final aeltester = _offen.entries
            .reduce((x, y) => x.value.begonnen.isBefore(y.value.begonnen) ? x : y)
            .key;
        _offen.remove(aeltester);
      }
      a = _Angefangen(zahl: st.zahl, summe: st.summe, begonnen: _jetzt());
      _offen[st.sendungsnummer] = a;
    }

    // Doppelte Stuecke sind im Funk normal — eine Wiederholung nach einem
    // Aussetzer. Sie duerfen nichts veraendern.
    if (a.teile.containsKey(st.nummer)) return null;

    if (offeneBytes + st.nutzlast.length > hoechstBytesOffen) {
      _offen.remove(st.sendungsnummer);
      throw const SendungZuGross('zu viele angefangene Sendungen im Speicher');
    }

    a.teile[st.nummer] = Uint8List.fromList(st.nutzlast);
    if (a.teile.length < a.zahl) return null;

    final fertig = a.zusammen();
    _offen.remove(st.sendungsnummer);

    if (crc16(fertig) != a.summe) {
      // NICHT STILL VERWERFEN und nicht durchreichen: durchgereicht landete
      // es bei libsignal und saehe dort aus wie ein Krypto-Fehler.
      throw const StueckKaputt('Pruefsumme der Sendung stimmt nicht');
    }
    return fertig;
  }

  /// Wirft weg, was zu lange wartet.
  void _raeumeAb() {
    final grenze = _jetzt().subtract(haltbarkeit);
    _offen.removeWhere((_, a) => a.begonnen.isBefore(grenze));
  }

  void leere() => _offen.clear();
}

class _Angefangen {
  _Angefangen({required this.zahl, required this.summe, required this.begonnen});

  final int zahl;
  final int summe;
  final DateTime begonnen;
  final teile = <int, Uint8List>{};

  int get belegt => teile.values.fold(0, (a, b) => a + b.length);

  Uint8List zusammen() {
    final aus = Uint8List(belegt);
    var pos = 0;
    for (var i = 0; i < zahl; i++) {
      final t = teile[i]!;
      aus.setRange(pos, pos + t.length, t);
      pos += t.length;
    }
    return aus;
  }
}

/// CRC-16/CCITT-FALSE.
///
/// Kein Sicherheitsmerkmal — dafuer ist die Signal-Sitzung da. Es geht darum,
/// eine verdorbene Funkstrecke von einem Krypto-Fehler zu unterscheiden.
int crc16(Uint8List daten) {
  var crc = 0xFFFF;
  for (final b in daten) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}
