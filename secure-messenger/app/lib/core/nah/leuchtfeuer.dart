// leuchtfeuer.dart — sich in der Naehe erkennen, ohne sich zu zeigen.
//
// DIE FRAGE, DIE VOR BLUETOOTH KOMMT
// Zwei Telefone sollen einander finden, ohne Internet. Der naheliegende Weg —
// die eigene Adresse aussenden — waere fuer diese App der schlimmste denkbare:
// wer eine Adresse einmal gesehen hat, koennte damit ueberall verfolgen, wo
// dieses Telefon gerade ist. Ein Messenger ohne Telefonnummer, der statt
// dessen eine dauerhafte Funkkennung in die Gegend ruft, hat nichts gewonnen.
//
// DIE LOESUNG: EIN WERT, DEN NUR ZWEI BERECHNEN KOENNEN, UND DER WANDERT
// Fuer jeden Kontakt gibt es ein gemeinsames Geheimnis — das Ergebnis von
// X25519 aus dem eigenen privaten und dem fremden oeffentlichen
// Identitaetsschluessel. Beide Seiten kommen darauf, sonst niemand: die
// oeffentlichen Schluessel allein reichen nicht, es braucht einen der beiden
// privaten.
//
// Daraus wird ein kurzer Wert je Zeitfenster gerechnet. Wer nicht dazugehoert,
// sieht ein paar Bytes, die sich alle paar Minuten aendern und die sich mit
// nichts in Verbindung bringen lassen.
//
// WAS DAS NICHT LEISTET
// Die Bluetooth-Adresse des Geraets bleibt sichtbar. Android wechselt sie von
// selbst regelmaessig, aber wer im selben Raum steht und lange genug misst,
// kann Geraete auch daran unterscheiden. Diese Datei schuetzt die IDENTITAET,
// nicht die Anwesenheit — und die Oberflaeche sagt das auch.
//
// WARUM SO KURZ
// In eine Bluetooth-Kennung passen nur wenige Bytes. Sechs davon ergeben rund
// 280 Billionen Moeglichkeiten; bei einer Handvoll Kontakte in Reichweite ist
// eine Verwechslung ausgeschlossen. Eine Verwechslung waere ohnehin harmlos:
// danach folgt ein richtiger Schluesselaustausch, und der scheitert dann.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Wie lange ein Leuchtfeuer gilt.
///
/// KURZ GENUG, dass ein aufgezeichneter Wert nicht lange nuetzt. LANG GENUG,
/// dass zwei Telefone mit leicht verschiedenen Uhren sich noch finden — und
/// dass nicht staendig neu ausgesendet werden muss, was Akku kostet.
const Duration leuchtfeuerFenster = Duration(minutes: 15);

/// Wie viele Bytes ausgesendet werden.
const int leuchtfeuerLaenge = 6;

/// Rechnet die Leuchtfeuer aus, an denen sich zwei Geraete erkennen.
class Leuchtfeuer {
  const Leuchtfeuer._();

  static const String _kontext = 'bitdm-nearby-v1';

  /// Das gemeinsame Geheimnis mit einem Kontakt.
  ///
  /// X25519 aus dem eigenen privaten und seinem oeffentlichen
  /// Identitaetsschluessel. Es aendert sich nie — die Identitaeten aendern
  /// sich nicht — und wird deshalb nur einmal je Kontakt gerechnet.
  static Future<Uint8List> gemeinsamesGeheimnis({
    required SimpleKeyPair eigenerSchluessel,
    required Uint8List fremderOeffentlicher,
  }) async {
    if (fremderOeffentlicher.length != 32) {
      throw ArgumentError('Ein Identitaetsschluessel hat 32 Bytes, hier sind '
          'es ${fremderOeffentlicher.length}');
    }
    final geheim = await X25519().sharedSecretKey(
      keyPair: eigenerSchluessel,
      remotePublicKey:
          SimplePublicKey(fremderOeffentlicher, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await geheim.extractBytes());
  }

  /// Das Leuchtfeuer fuer ein Zeitfenster.
  ///
  /// Die RICHTUNG steckt mit drin: was A aussendet, ist nicht, was B
  /// aussendet. Sonst koennte jemand das Leuchtfeuer von A aufzeichnen und
  /// damit vorgeben, B zu sein — ohne irgendeinen Schluessel zu besitzen.
  static Future<Uint8List> fuerFenster({
    required Uint8List geheimnis,
    required Uint8List senderOeffentlicher,
    required int fenster,
  }) async {
    final mac = await Hmac.sha256().calculateMac(
      [
        ...senderOeffentlicher,
        ..._alsAchtBytes(fenster),
      ],
      secretKey: SecretKey(geheimnis),
      aad: _kontext.codeUnits,
    );
    return Uint8List.fromList(mac.bytes.sublist(0, leuchtfeuerLaenge));
  }

  /// Welches Zeitfenster gerade gilt.
  static int fensterFuer(DateTime zeit) =>
      zeit.toUtc().millisecondsSinceEpoch ~/
          leuchtfeuerFenster.inMilliseconds;

  /// Die Fenster, die beim Suchen geprueft werden.
  ///
  /// DREI, NICHT EINS. Zwei Telefone haben nie exakt dieselbe Uhr, und genau
  /// an der Fenstergrenze rechnet das eine schon das naechste, waehrend das
  /// andere noch beim vorigen ist. Ohne das Vor- und das Zurueckfenster
  /// wuerden sich zwei Geraete alle 15 Minuten fuer kurze Zeit nicht mehr
  /// sehen — ein Fehler, der sich am Schreibtisch nie zeigt und beim Nutzer
  /// als "geht manchmal nicht" ankommt.
  static List<int> fensterUmZeit(DateTime zeit) {
    final f = fensterFuer(zeit);
    return [f - 1, f, f + 1];
  }

  /// Alle Leuchtfeuer, an denen dieser Kontakt gerade zu erkennen waere.
  static Future<List<Uint8List>> erwarteteVon({
    required Uint8List geheimnis,
    required Uint8List seinOeffentlicher,
    required DateTime zeit,
  }) async {
    final aus = <Uint8List>[];
    for (final f in fensterUmZeit(zeit)) {
      aus.add(await fuerFenster(
          geheimnis: geheimnis,
          senderOeffentlicher: seinOeffentlicher,
          fenster: f));
    }
    return aus;
  }

  /// Was gerade ausgesendet wird, damit dieser Kontakt einen findet.
  ///
  /// Je Kontakt ein eigener Wert: einen gemeinsamen fuer alle koennte jeder
  /// Kontakt weitergeben, und damit koennten Fremde einen wiedererkennen.
  static Future<Uint8List> eigenesFuer({
    required Uint8List geheimnis,
    required Uint8List eigenerOeffentlicher,
    required DateTime zeit,
  }) =>
      fuerFenster(
        geheimnis: geheimnis,
        senderOeffentlicher: eigenerOeffentlicher,
        fenster: fensterFuer(zeit),
      );

  static Uint8List _alsAchtBytes(int n) {
    final b = Uint8List(8);
    var rest = n;
    for (var i = 7; i >= 0; i--) {
      b[i] = rest & 0xFF;
      rest >>= 8;
    }
    return b;
  }
}

/// Ein Kontakt, wie er zum Suchen gebraucht wird.
class NahKontakt {
  final String adresse;

  /// Sein oeffentlicher Identitaetsschluessel, 32 Bytes ohne Typbyte.
  final Uint8List identitaet;

  /// X25519 mit dem eigenen privaten Schluessel. Einmal gerechnet, dann
  /// behalten — die Identitaeten aendern sich nicht.
  final Uint8List geheimnis;

  const NahKontakt({
    required this.adresse,
    required this.identitaet,
    required this.geheimnis,
  });
}

/// Ordnet gesehene Leuchtfeuer den Kontakten zu.
///
/// Die Tabelle wird im Voraus gefuellt und beim Fensterwechsel erneuert. Beim
/// Suchen selbst wird nur nachgeschlagen — das laeuft bei jedem
/// Bluetooth-Fund und darf nichts rechnen.
class LeuchtfeuerTabelle {
  LeuchtfeuerTabelle._(this._zuKontakt, this.gebautFuer);

  final Map<String, String> _zuKontakt;

  /// Fuer welches Zeitfenster die Tabelle gebaut wurde.
  final int gebautFuer;

  static Future<LeuchtfeuerTabelle> baue(
      List<NahKontakt> kontakte, DateTime zeit) async {
    final tabelle = <String, String>{};
    for (final k in kontakte) {
      final erwartet = await Leuchtfeuer.erwarteteVon(
          geheimnis: k.geheimnis, seinOeffentlicher: k.identitaet, zeit: zeit);
      for (final l in erwartet) {
        tabelle[_hex(l)] = k.adresse;
      }
    }
    return LeuchtfeuerTabelle._(tabelle, Leuchtfeuer.fensterFuer(zeit));
  }

  /// Wessen Leuchtfeuer das ist — oder null, wenn es niemanden angeht.
  String? wer(Uint8List gesehen) => _zuKontakt[_hex(gesehen)];

  /// Ob die Tabelle noch zum aktuellen Zeitfenster passt.
  bool giltNoch(DateTime zeit) => Leuchtfeuer.fensterFuer(zeit) == gebautFuer;

  int get anzahl => _zuKontakt.length;

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
