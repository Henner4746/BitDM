// payload.dart — was INNERHALB der Verschluesselung steht.
//
// envelope.dart beschreibt den Umschlag, den der Relay sieht: zwei Bytes und
// ein undurchsichtiger Block. Diese Datei beschreibt den Inhalt dieses Blocks —
// den bekommt ausser den beiden Gespraechspartnern niemand zu Gesicht.
//
// Deshalb steht hier alles, was der Relay NICHT wissen soll: ob eine Nachricht
// Text ist oder eine Kontaktanfrage, ob sie gelesen wurde, wann sie verfasst
// wurde.
//
// AUFFUELLEN AUF FESTE GROESSEN
// Ohne das verraet allein die Laenge des Chiffretexts, wie lang die Nachricht
// war. Wer den Verkehr mitschneidet, koennte "ja" von "nein" nicht
// unterscheiden — aber sehr wohl eine kurze Antwort von einem langen Absatz,
// und ueber Zeit ergibt das ein Muster. Eine Lesebestaetigung waere sogar
// eindeutig an ihrer Groesse zu erkennen, obwohl sie verschluesselt ist.
//
// Das Verfahren ist Signals: hinter den Inhalt kommt ein 0x80, danach Nullen
// bis zur naechsten Blockgrenze. Beim Lesen werden die Nullen abgeschnitten,
// das 0x80 markiert das Ende. Der Preis sind im Schnitt ein paar hundert Byte
// je Nachricht; der Gewinn ist, dass alle kurzen Nachrichten gleich aussehen.

import 'dart:convert';
import 'dart:typed_data';

class PayloadFormatException implements Exception {
  final String grund;
  const PayloadFormatException(this.grund);
  @override
  String toString() => 'PayloadFormatException: $grund';
}

/// Was eine Nachricht ueberhaupt ist.
///
/// Die Zahlen sind Teil des Protokolls und duerfen sich nie aendern — sie
/// stehen im verschluesselten Inhalt und muessen von jeder Fassung der App
/// gleich gelesen werden.
enum PayloadKind {
  text(1),
  contactRequest(2),
  contactAccept(3),
  contactDecline(4),
  deliveryReceipt(5),
  readReceipt(6);

  const PayloadKind(this.code);
  final int code;

  static PayloadKind? byCode(int c) {
    for (final k in PayloadKind.values) {
      if (k.code == c) return k;
    }
    return null;
  }
}

class Payload {
  final PayloadKind kind;

  /// Kennung der Nachricht, vom Absender vergeben.
  ///
  /// Sie wandert mit, damit Bestaetigungen sich darauf beziehen koennen. Der
  /// Relay sieht sie nicht — seine eigene Kennung aus relay_client.dart ist
  /// eine andere und dient nur dazu, das ACK der richtigen Sendung zuzuordnen.
  final String messageId;

  /// Verfasszeit laut ABSENDER, in UTC.
  ///
  /// Bewusst nicht die Ankunftszeit: der Relay stempelt zwar auch, aber der
  /// Stempel des Absenders ist der, der zur Unterhaltung gehoert. Er ist
  /// naturgemaess nicht vertrauenswuerdig — die Gegenstelle kann schreiben,
  /// was sie will. Die Anzeige darf sich darauf nicht verlassen, wenn es um
  /// die Reihenfolge geht.
  final DateTime sentAt;

  /// Bei [PayloadKind.text] der Klartext, sonst leer.
  final String text;

  /// Bei den Bestaetigungen die Kennung(en), auf die sie sich beziehen.
  final List<String> refs;

  /// Wie lange die Nachricht leben soll, in Sekunden. Null heisst: bleibt.
  ///
  /// Sie reist MIT, damit auch der Empfaenger loescht. Waere es nur eine
  /// oertliche Einstellung, waere "verschwindet nach 24 Stunden" eine
  /// Halbwahrheit — beim anderen laege sie weiter.
  ///
  /// Erzwingbar ist das gegen einen veraenderten Client nicht; das ist bei
  /// keiner Umsetzung dieser Funktion irgendwo anders. Fuer jeden gewoehnlichen
  /// Client stimmt es, und die Oberflaeche sagt genau das.
  final int? ttlSeconds;

  Payload({
    required this.kind,
    required this.messageId,
    required this.sentAt,
    this.text = '',
    this.refs = const [],
    this.ttlSeconds,
  });

  factory Payload.text(String messageId, String text, DateTime sentAt,
          {Duration? lebensdauer}) =>
      Payload(
        kind: PayloadKind.text,
        messageId: messageId,
        sentAt: sentAt,
        text: text,
        ttlSeconds: lebensdauer?.inSeconds,
      );

  factory Payload.control(PayloadKind kind, String messageId, DateTime sentAt,
          {List<String> refs = const []}) =>
      Payload(kind: kind, messageId: messageId, sentAt: sentAt, refs: refs);

  /// Auf welche Vielfachen aufgefuellt wird.
  ///
  /// 256 ist ein Kompromiss. Groesser verschleiert besser, kostet aber bei
  /// jeder kurzen Nachricht bares Datenvolumen — und dieselbe App soll auch im
  /// Ausland mit teurem Roaming brauchbar sein. Bei 256 fallen alle
  /// Nachrichten bis etwa 180 Zeichen in denselben Block.
  static const int blockSize = 256;

  Uint8List toBytes() {
    final json = jsonEncode({
      'id': messageId,
      't': sentAt.toUtc().millisecondsSinceEpoch,
      if (text.isNotEmpty) 'x': text,
      if (refs.isNotEmpty) 'r': refs,
      if (ttlSeconds != null) 'l': ttlSeconds,
    });
    final inhalt = <int>[kind.code, ...utf8.encode(json)];

    // Signals Auffuellung: 0x80 als Endmarke, danach Nullen.
    final mitMarke = [...inhalt, 0x80];
    final rest = mitMarke.length % blockSize;
    final fehlend = rest == 0 ? 0 : blockSize - rest;
    return Uint8List.fromList([...mitMarke, ...List.filled(fehlend, 0)]);
  }

  static Payload fromBytes(Uint8List roh) {
    // Diese Bytes stammen aus einer entschluesselten Nachricht — sie sind also
    // echt von der Gegenstelle. Aber die Gegenstelle kann selbst fehlerhaft
    // oder boesartig sein, deshalb wird alles geprueft.
    var ende = roh.length;
    while (ende > 0 && roh[ende - 1] == 0) {
      ende--;
    }
    if (ende == 0 || roh[ende - 1] != 0x80) {
      throw const PayloadFormatException('Endmarke fehlt');
    }
    ende--; // 0x80 selbst abschneiden

    if (ende < 1) throw const PayloadFormatException('leerer Inhalt');

    final kind = PayloadKind.byCode(roh[0]);
    if (kind == null) {
      // Eine kuenftige Fassung koennte neue Arten kennen. Sie zu ueberspringen
      // ist richtig — abzustuerzen waere es nicht.
      throw PayloadFormatException('unbekannte Art ${roh[0]}');
    }

    final Map<String, Object?> j;
    try {
      j = (jsonDecode(utf8.decode(roh.sublist(1, ende))) as Map)
          .cast<String, Object?>();
    } catch (e) {
      throw PayloadFormatException('unlesbarer Inhalt: $e');
    }

    final id = j['id'];
    final t = j['t'];
    if (id is! String || id.isEmpty) {
      throw const PayloadFormatException('Kennung fehlt');
    }
    if (t is! int) throw const PayloadFormatException('Zeitstempel fehlt');

    // Eine unsinnige Lebensdauer wird verworfen, nicht uebernommen: eine
    // negative liesse die Nachricht sofort verschwinden, eine absurd grosse
    // wuerde beim Rechnen ueberlaufen. Beides koennte eine boesartige
    // Gegenstelle schicken.
    final ttl = j['l'];
    final gueltigeTtl = (ttl is int && ttl > 0 && ttl <= 365 * 24 * 3600)
        ? ttl
        : null;

    return Payload(
      kind: kind,
      messageId: id,
      sentAt: DateTime.fromMillisecondsSinceEpoch(t, isUtc: true),
      text: j['x'] as String? ?? '',
      refs: ((j['r'] ?? const []) as List).map((e) => '$e').toList(),
      ttlSeconds: gueltigeTtl,
    );
  }
}
