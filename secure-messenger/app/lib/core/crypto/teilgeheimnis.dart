// teilgeheimnis.dart — Shamir-Teilgeheimnisse fuer die Wiederherstellung
// ueber Vertrauenskontakte.
//
// Idee: Die 16 Byte Entropie hinter den zwoelf Wiederherstellungswoertern
// (siehe bip39.dart) werden in [anzahl] Teile zerlegt, von denen JEDE Auswahl
// von [schwelle] Teilen das Geheimnis wieder ergibt, waehrend weniger Teile
// informationstheoretisch NICHTS darueber verraten. Die Teile gehen an
// Freunde; verliert man die Woerter, sammelt man [schwelle] Teile ein.
//
// Verfahren: Shamir's Secret Sharing ueber GF(2^8), byteweise. Fuer jedes Byte
// s des Geheimnisses wird ein Zufallspolynom f vom Grad schwelle-1 mit
// f(0) = s gewaehlt; Teil Nummer x erhaelt f(x). Zusammensetzen ist
// Lagrange-Interpolation an der Stelle 0. Koerper: GF(2^8) mit dem
// AES-Reduktionspolynom x^8 + x^4 + x^3 + x + 1 (0x11B).
//
// Textformat eines Teils (zum Aufschreiben / Einfuegen):
//
//   BITDM-TEIL-1-<k>-<x>-<Nutzlast base32, in Viererbloecken>-<Pruefsumme>
//
//   1          Formatversion
//   k          Schwelle (wie viele Teile noetig sind)
//   x          Nummer des Teils (1..anzahl)
//   Nutzlast   base32 (RFC 4648, ohne Padding) ueber
//              4 Byte Gruppenkennung ++ y-Bytes
//              Die Gruppenkennung ist pro Zerlegung zufaellig; Teile aus
//              verschiedenen Zerlegungen lassen sich so nicht vermischen.
//   Pruefsumme die ersten 4 base32-Zeichen von SHA-256 ueber die kanonische
//              Form "BITDM-TEIL-1-<k>-<x>-<Nutzlast ohne Bloecke>" (UTF-8).
//              Faengt Tippfehler ab (Fehlerrate eines zufaelligen Fehlers:
//              2^-20).
//
// Beim Einlesen werden Gross-/Kleinschreibung, Leerzeichen, Zeilenumbrueche
// und zusaetzliche Bindestriche toleriert.
//
// FASSUNG 2 (seit 25.09.2026): BITDM-TEIL-2-<k>-<x>-<Nutzlast>-<Pruefsumme>
// mit Nutzlast = 4 Byte Gruppenkennung ++ 4 Byte Fingerabdruck ++ y-Bytes.
// Der Fingerabdruck sind die ersten 4 Byte SHA-256 ueber das GEHEIMNIS.
//
// WARUM: aus genau k Teilen laesst sich immer IRGENDEIN Geheimnis
// interpolieren — auch aus einem Teil, dessen Tippfehler die Pruefsumme
// zufaellig nicht fing, oder aus einem, den jemand absichtlich veraendert hat
// (die Pruefsumme ist ungeheim, jeder kann sie neu rechnen). Die einzige
// Kontrolle danach war die 4-Bit-Pruefsumme der BIP39-Woerter: jeder
// sechzehnte falsche Satz ging als "gueltig" durch, und die App stellte eine
// FREMDE Identitaet her. Mit dem Fingerabdruck faellt ein falsches Ergebnis
// bis auf 2^-32 auf.
//
// DER PREIS: jeder Teil verraet 32 Bit eines Hashs des Geheimnisses.
// "k-1 Teile verraten nichts" gilt damit nicht mehr informationstheoretisch —
// praktisch bleibt es beim Durchprobieren von 2^128 Moeglichkeiten (16 Byte
// Entropie); der Fingerabdruck filtert dabei nur. Fuer
// Wiederherstellungswoerter ist das der richtige Tausch.
//
// Fassung 1 wird weiter gelesen (aeltere Teile liegen bei Freunden); sie hat
// keinen Fingerabdruck, und fuer sie bleibt es bei der alten Pruefung.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bip39.dart';

/// Fehler beim Einlesen oder Zusammensetzen von Teilgeheimnissen.
class TeilgeheimnisException implements Exception {
  final String message;
  const TeilgeheimnisException(this.message);
  @override
  String toString() => 'TeilgeheimnisException: $message';
}

/// Arithmetik im Koerper GF(2^8) mit dem AES-Polynom 0x11B.
///
/// Bewusst ohne Log-/Exp-Tabellen: Tabellenzugriffe mit geheimen Indizes
/// verraten ueber den Cache Timing-Information. Multiplikation und Inversion
/// laufen hier mit fester Schrittzahl und ohne datenabhaengige Verzweigungen.
class Gf256 {
  Gf256._();

  /// Addition (= Subtraktion) ist XOR.
  static int add(int a, int b) => (a ^ b) & 0xFF;

  /// Multiplikation modulo 0x11B ("Russische Bauernmultiplikation").
  static int mul(int a, int b) {
    var p = 0;
    var aa = a & 0xFF;
    var bb = b & 0xFF;
    for (var i = 0; i < 8; i++) {
      // -(bit) ist 0 oder -1 (alle Bits gesetzt) -> Maske statt if.
      p ^= -(bb & 1) & aa;
      final hochbit = -((aa >> 7) & 1);
      aa = ((aa << 1) ^ (hochbit & 0x11B)) & 0xFF;
      bb >>= 1;
    }
    return p & 0xFF;
  }

  /// Multiplikatives Inverses: a^254 (weil a^255 = 1 fuer a != 0).
  ///
  /// Wirft bei 0 — die Null hat kein Inverses.
  static int inv(int a) {
    if (a & 0xFF == 0) {
      throw ArgumentError('0 hat in GF(256) kein Inverses');
    }
    // 254 = 2 + 4 + 8 + 16 + 32 + 64 + 128
    var quadrat = mul(a, a); // a^2
    var ergebnis = quadrat;
    for (var i = 0; i < 6; i++) {
      quadrat = mul(quadrat, quadrat); // a^4, a^8, ..., a^128
      ergebnis = mul(ergebnis, quadrat);
    }
    return ergebnis;
  }

  /// Division a / b.
  static int div(int a, int b) => mul(a, inv(b));
}

/// Ein einzelner Teil eines zerlegten Geheimnisses.
class Teil {
  /// Die Formatversion, die neue Zerlegungen schreiben. Siehe Kopf: Fassung
  /// 2 traegt einen Fingerabdruck des Geheimnisses, Fassung 1 nicht.
  static const int formatVersion = 2;

  /// Die aeltere Fassung, die weiter gelesen (und fuer Teile ohne
  /// Fingerabdruck weiter geschrieben) wird.
  static const int formatVersionAlt = 1;

  /// Laenge des Fingerabdrucks (Fassung 2) in Byte.
  static const int fingerabdruckLaenge = 4;

  /// Laenge der Gruppenkennung in Byte.
  static const int gruppenIdLaenge = 4;

  static const String _praefix = 'BITDM-TEIL';

  /// Wie viele Teile zum Zusammensetzen noetig sind.
  final int schwelle;

  /// Nummer des Teils, zugleich die Stuetzstelle x (1..[maxAnzahl]).
  final int x;

  /// Zufaellige Kennung der Zerlegung, zu der dieser Teil gehoert.
  final Uint8List gruppenId;

  /// Funktionswerte f(x), ein Byte pro Byte des Geheimnisses.
  final Uint8List y;

  /// Die ersten [fingerabdruckLaenge] Byte SHA-256 ueber das Geheimnis — oder
  /// null bei einem Teil der Fassung 1. Siehe Kopf der Datei.
  final Uint8List? fingerabdruck;

  Teil({
    required this.schwelle,
    required this.x,
    required List<int> gruppenId,
    required List<int> y,
    List<int>? fingerabdruck,
  })  : gruppenId = Uint8List.fromList(gruppenId),
        y = Uint8List.fromList(y),
        fingerabdruck =
            fingerabdruck == null ? null : Uint8List.fromList(fingerabdruck) {
    if (this.fingerabdruck != null &&
        this.fingerabdruck!.length != fingerabdruckLaenge) {
      throw TeilgeheimnisException(
          'Fingerabdruck muss $fingerabdruckLaenge Byte lang sein');
    }
    if (schwelle < minSchwelle || schwelle > maxAnzahl) {
      throw TeilgeheimnisException(
          'Schwelle muss zwischen $minSchwelle und $maxAnzahl liegen, '
          'war $schwelle');
    }
    if (x < 1 || x > maxAnzahl) {
      throw TeilgeheimnisException(
          'Teilnummer muss zwischen 1 und $maxAnzahl liegen, war $x');
    }
    if (this.gruppenId.length != gruppenIdLaenge) {
      throw TeilgeheimnisException(
          'Gruppenkennung muss $gruppenIdLaenge Byte lang sein');
    }
    if (this.y.isEmpty) {
      throw const TeilgeheimnisException('Teil enthaelt keine Daten');
    }
  }

  /// Textform zum Aufschreiben / Weitergeben.
  ///
  /// Beispiel: `BITDM-TEIL-1-3-2-ABCD-EFGH-...-WXYZ-QRST`
  ///
  /// Ein Teil MIT Fingerabdruck wird als Fassung 2 geschrieben, einer ohne als
  /// Fassung 1 — so bleibt ein alter Teil beim Zurueckschreiben bitgleich.
  String alsText() {
    final fp = fingerabdruck;
    final version = fp == null ? formatVersionAlt : formatVersion;
    final nutzlast =
        _base32Kodieren(Uint8List.fromList([...gruppenId, ...?fp, ...y]));
    final pruefsumme = _pruefsumme(version, schwelle, x, nutzlast);
    final bloecke = <String>[
      for (var i = 0; i < nutzlast.length; i += 4)
        nutzlast.substring(i, min(i + 4, nutzlast.length)),
    ];
    return '$_praefix-$version-$schwelle-$x-${bloecke.join('-')}-'
        '$pruefsumme';
  }

  /// Liest einen Teil aus seiner Textform.
  ///
  /// Toleriert Kleinschreibung, Leerzeichen/Zeilenumbrueche und beliebige
  /// Bindestriche innerhalb der Nutzlast. Wirft [TeilgeheimnisException] bei
  /// falschem Aufbau, ungueltigen Zeichen oder falscher Pruefsumme.
  factory Teil.ausText(String text) {
    final token = text
        .toUpperCase()
        .split(RegExp(r'[\s\-_]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (token.length < 6 || token[0] != 'BITDM' || token[1] != 'TEIL') {
      throw const TeilgeheimnisException(
          'kein BitDM-Teil — der Text muss mit "BITDM-TEIL" beginnen');
    }
    final version = int.tryParse(token[2]);
    if (version != formatVersion && version != formatVersionAlt) {
      throw TeilgeheimnisException(
          'unbekannte Formatversion "${token[2]}" — App aktualisieren?');
    }
    final schwelle = int.tryParse(token[3]);
    final x = int.tryParse(token[4]);
    if (schwelle == null || x == null) {
      throw const TeilgeheimnisException(
          'Schwelle oder Teilnummer ist keine Zahl — vertippt?');
    }

    // Alles nach der Teilnummer ist Nutzlast + 4 Zeichen Pruefsumme; die
    // Blockeinteilung ist egal.
    final rest = token.sublist(5).join();
    if (rest.length <= 4) {
      throw const TeilgeheimnisException('Teil ist unvollstaendig');
    }
    final nutzlast = rest.substring(0, rest.length - 4);
    final pruefsumme = rest.substring(rest.length - 4);

    // Die Fassung geht in die Pruefsumme ein: eine "1" statt einer "2" (oder
    // umgekehrt) ist ein Tippfehler wie jeder andere und faellt hier auf.
    if (_pruefsumme(version!, schwelle, x, nutzlast) != pruefsumme) {
      throw const TeilgeheimnisException(
          'Pruefsumme stimmt nicht — der Teil ist vertippt oder unvollstaendig');
    }

    final bytes = _base32Dekodieren(nutzlast);
    final kopf =
        gruppenIdLaenge + (version == formatVersion ? fingerabdruckLaenge : 0);
    if (bytes.length <= kopf) {
      throw const TeilgeheimnisException('Teil enthaelt keine Daten');
    }
    return Teil(
      schwelle: schwelle,
      x: x,
      gruppenId: bytes.sublist(0, gruppenIdLaenge),
      fingerabdruck:
          version == formatVersion ? bytes.sublist(gruppenIdLaenge, kopf) : null,
      y: bytes.sublist(kopf),
    );
  }

  static String _pruefsumme(int version, int schwelle, int x, String nutzlast) {
    final kanonisch = '$_praefix-$version-$schwelle-$x-$nutzlast';
    final hash = Sha256().toSync().hashSync(utf8.encode(kanonisch)).bytes;
    return _base32Kodieren(Uint8List.fromList(hash)).substring(0, 4);
  }

  @override
  bool operator ==(Object other) =>
      other is Teil &&
      other.schwelle == schwelle &&
      other.x == x &&
      _gleich(other.gruppenId, gruppenId) &&
      _gleich(other.y, y) &&
      (other.fingerabdruck == null) == (fingerabdruck == null) &&
      (fingerabdruck == null || _gleich(other.fingerabdruck!, fingerabdruck!));

  @override
  int get hashCode =>
      Object.hash(schwelle, x, Object.hashAll(gruppenId), Object.hashAll(y));

  @override
  String toString() => 'Teil($x von mind. $schwelle)'; // bewusst ohne y
}

/// Kleinste erlaubte Schwelle.
const int minSchwelle = 2;

/// Groesste erlaubte Anzahl Teile (und damit auch Schwelle).
const int maxAnzahl = 10;

/// Zerlegt [geheimnis] in [anzahl] Teile, von denen je [schwelle] genuegen.
///
/// Es gilt 2 <= schwelle <= anzahl <= 10. [zufall] existiert nur fuer Tests;
/// im Betrieb NIE setzen, dann kommt [Random.secure] zum Einsatz.
List<Teil> teile(
  Uint8List geheimnis, {
  required int schwelle,
  required int anzahl,
  Random? zufall,
}) {
  if (geheimnis.isEmpty) {
    throw ArgumentError.value(geheimnis, 'geheimnis', 'darf nicht leer sein');
  }
  if (schwelle < minSchwelle || schwelle > anzahl || anzahl > maxAnzahl) {
    throw ArgumentError(
        'es muss $minSchwelle <= schwelle <= anzahl <= $maxAnzahl gelten '
        '(schwelle=$schwelle, anzahl=$anzahl)');
  }
  final rng = zufall ?? Random.secure();
  final gruppenId = Uint8List.fromList(
      List<int>.generate(Teil.gruppenIdLaenge, (_) => rng.nextInt(256)));

  final ys = List<Uint8List>.generate(
      anzahl, (_) => Uint8List(geheimnis.length));
  final koeffizienten = Uint8List(schwelle);
  for (var i = 0; i < geheimnis.length; i++) {
    koeffizienten[0] = geheimnis[i];
    for (var j = 1; j < schwelle; j++) {
      koeffizienten[j] = rng.nextInt(256);
    }
    for (var t = 0; t < anzahl; t++) {
      ys[t][i] = _auswerten(koeffizienten, t + 1);
    }
  }
  koeffizienten.fillRange(0, koeffizienten.length, 0);

  final fp = _fingerabdruckVon(geheimnis);
  return [
    for (var t = 0; t < anzahl; t++)
      Teil(
          schwelle: schwelle,
          x: t + 1,
          gruppenId: gruppenId,
          y: ys[t],
          fingerabdruck: fp),
  ];
}

/// Die ersten [Teil.fingerabdruckLaenge] Byte SHA-256 ueber [geheimnis].
Uint8List _fingerabdruckVon(Uint8List geheimnis) => Uint8List.fromList(Sha256()
    .toSync()
    .hashSync(geheimnis)
    .bytes
    .sublist(0, Teil.fingerabdruckLaenge));

/// Setzt das Geheimnis aus [teile] wieder zusammen.
///
/// Die Schwelle steht in jedem Teil; weniger Teile als noetig werden
/// abgelehnt (Shamir wuerde sonst stillschweigend ein falsches Geheimnis
/// liefern). Werden mehr Teile als noetig uebergeben, muessen auch die
/// ueberzaehligen zum selben Polynom passen — ein beschaedigter Teil faellt
/// so auf. Wirft [TeilgeheimnisException] bei leerer Liste, gemischten
/// Zerlegungen, doppelten Teilen, zu wenigen Teilen oder Widerspruechen.
///
/// TRAEGT EIN TEIL EINEN FINGERABDRUCK (Fassung 2), wird das Ergebnis
/// dagegen geprueft — die einzige Kontrolle, die auch bei GENAU k Teilen
/// greift, wo es keine ueberzaehligen zum Gegenpruefen gibt.
Uint8List setzeZusammen(List<Teil> teile) {
  if (teile.isEmpty) {
    throw const TeilgeheimnisException('keine Teile angegeben');
  }
  final erster = teile.first;
  for (final t in teile) {
    if (!_gleich(t.gruppenId, erster.gruppenId)) {
      throw const TeilgeheimnisException(
          'die Teile stammen aus verschiedenen Zerlegungen');
    }
    if (t.schwelle != erster.schwelle || t.y.length != erster.y.length) {
      throw const TeilgeheimnisException(
          'die Teile passen nicht zueinander (Schwelle oder Laenge weicht ab)');
    }
  }
  final nummern = <int>{};
  for (final t in teile) {
    if (!nummern.add(t.x)) {
      throw TeilgeheimnisException('Teil ${t.x} ist doppelt angegeben');
    }
  }
  // Alle vorhandenen Fingerabdruecke muessen gleich sein. Verschiedene
  // koennen nicht aus derselben Zerlegung stammen — einer ist beschaedigt.
  Uint8List? fp;
  for (final t in teile) {
    final f = t.fingerabdruck;
    if (f == null) continue;
    if (fp != null && !_gleich(fp, f)) {
      throw const TeilgeheimnisException(
          'die Teile widersprechen sich — mindestens einer ist beschaedigt');
    }
    fp = f;
  }
  final schwelle = erster.schwelle;
  if (teile.length < schwelle) {
    throw TeilgeheimnisException(
        'es werden mindestens $schwelle Teile gebraucht, '
        'angegeben sind ${teile.length}');
  }

  final basis = teile.sublist(0, schwelle);
  final extra = teile.sublist(schwelle);
  final xs = [for (final t in basis) t.x];
  final laenge = erster.y.length;

  // Lagrange-Gewichte fuer die Auswertung an 0 und an jeder Extra-Stelle
  // haengen nur von den x ab, nicht vom Byte — einmal berechnen.
  final gewichteNull = _lagrangeGewichte(xs, 0);
  final gewichteExtra = [for (final t in extra) _lagrangeGewichte(xs, t.x)];

  final geheimnis = Uint8List(laenge);
  for (var i = 0; i < laenge; i++) {
    geheimnis[i] = _interpolieren(basis, gewichteNull, i);
    for (var e = 0; e < extra.length; e++) {
      if (_interpolieren(basis, gewichteExtra[e], i) != extra[e].y[i]) {
        geheimnis.fillRange(0, laenge, 0);
        throw TeilgeheimnisException(
            'die Teile widersprechen sich — mindestens einer ist beschaedigt '
            '(auffaellig: Teil ${extra[e].x})');
      }
    }
  }
  if (fp != null && !_gleich(_fingerabdruckVon(geheimnis), fp)) {
    geheimnis.fillRange(0, laenge, 0);
    throw const TeilgeheimnisException(
        'das zusammengesetzte Geheimnis passt nicht zum Fingerabdruck — '
        'mindestens ein Teil ist beschaedigt oder veraendert');
  }
  return geheimnis;
}

/// Zerlegt die zwoelf Wiederherstellungswoerter (genauer: deren 16 Byte
/// Entropie) in [anzahl] Teile mit Schwelle [schwelle].
///
/// Wirft [MnemonicException], wenn die Woerter keine gueltige BitDM-Phrase
/// sind.
List<Teil> teileWoerter(
  List<String> woerter, {
  required int schwelle,
  required int anzahl,
}) {
  if (woerter.length != Bip39.wordCount) {
    throw MnemonicException(
        'erwartet ${Bip39.wordCount} Woerter, erhalten ${woerter.length}');
  }
  final entropie = Bip39.mnemonicToEntropy(woerter);
  try {
    return teile(entropie, schwelle: schwelle, anzahl: anzahl);
  } finally {
    entropie.fillRange(0, entropie.length, 0);
  }
}

/// Setzt aus [teile] die zwoelf Wiederherstellungswoerter wieder zusammen.
List<String> woerterAusTeilen(List<Teil> teile) {
  final entropie = setzeZusammen(teile);
  try {
    if (entropie.length != 16) {
      throw TeilgeheimnisException(
          'die Teile enthalten keine Wiederherstellungswoerter '
          '(${entropie.length} statt 16 Byte)');
    }
    return Bip39.entropyToMnemonic(entropie);
  } finally {
    entropie.fillRange(0, entropie.length, 0);
  }
}

// ------------------------------------------------------------------ intern

/// Horner-Schema: f(x) = k0 + k1*x + ... ueber GF(256).
int _auswerten(Uint8List koeffizienten, int x) {
  var ergebnis = 0;
  for (var j = koeffizienten.length - 1; j >= 0; j--) {
    ergebnis = Gf256.add(Gf256.mul(ergebnis, x), koeffizienten[j]);
  }
  return ergebnis;
}

/// Lagrange-Basisgewichte l_i(stelle) = prod_{j!=i} (stelle - x_j)/(x_i - x_j).
List<int> _lagrangeGewichte(List<int> xs, int stelle) => [
      for (var i = 0; i < xs.length; i++)
        () {
          var zaehler = 1;
          var nenner = 1;
          for (var j = 0; j < xs.length; j++) {
            if (j == i) continue;
            zaehler = Gf256.mul(zaehler, Gf256.add(stelle, xs[j]));
            nenner = Gf256.mul(nenner, Gf256.add(xs[i], xs[j]));
          }
          return Gf256.div(zaehler, nenner);
        }(),
    ];

int _interpolieren(List<Teil> basis, List<int> gewichte, int byteIndex) {
  var summe = 0;
  for (var i = 0; i < basis.length; i++) {
    summe = Gf256.add(summe, Gf256.mul(basis[i].y[byteIndex], gewichte[i]));
  }
  return summe;
}

bool _gleich(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// base32 nach RFC 4648, ohne Padding.
String _base32Kodieren(Uint8List bytes) {
  final aus = StringBuffer();
  var puffer = 0;
  var bits = 0;
  for (final b in bytes) {
    puffer = (puffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      aus.write(_base32Alphabet[(puffer >> bits) & 0x1F]);
    }
    puffer &= (1 << bits) - 1;
  }
  if (bits > 0) {
    aus.write(_base32Alphabet[(puffer << (5 - bits)) & 0x1F]);
  }
  return aus.toString();
}

/// Strenges base32-Dekodieren: ungueltige Zeichen, unmoegliche Laengen und
/// gesetzte Fuellbits werden abgelehnt.
Uint8List _base32Dekodieren(String text) {
  final byteAnzahl = text.length * 5 ~/ 8;
  if ((byteAnzahl * 8 + 4) ~/ 5 != text.length) {
    throw const TeilgeheimnisException('Teil hat eine ungueltige Laenge');
  }
  final aus = Uint8List(byteAnzahl);
  var puffer = 0;
  var bits = 0;
  var pos = 0;
  for (var i = 0; i < text.length; i++) {
    final wert = _base32Alphabet.indexOf(text[i]);
    if (wert < 0) {
      throw TeilgeheimnisException(
          'ungueltiges Zeichen "${text[i]}" im Teil — erlaubt sind A-Z und 2-7');
    }
    puffer = (puffer << 5) | wert;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      aus[pos++] = (puffer >> bits) & 0xFF;
      puffer &= (1 << bits) - 1;
    }
  }
  if (puffer != 0) {
    throw const TeilgeheimnisException('Teil ist beschaedigt (Fuellbits)');
  }
  return aus;
}
