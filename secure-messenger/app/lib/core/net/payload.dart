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

import '../crypto/address.dart';

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
  readReceipt(6),

  /// Ein Anhang. Im Text steht die Anleitung (lib/core/anhang/rezept.dart) —
  /// wo die Stuecke liegen und womit sie aufgehen.
  ///
  /// DIE BYTES SELBST GEHEN HIER NICHT DURCH. Der Relay laesst 64 KiB
  /// Chiffretext durch, und selbst wenn er mehr liesse, gehoerte eine
  /// 3-GB-Datei nicht in eine SQLite-Warteschlange. Was hier reist, ist eine
  /// Anleitung von ein paar Kilobyte — mit den Schluesseln darin, die der
  /// Lagerplatz deshalb nie zu sehen bekommt.
  anhang(7),

  /// Ein Spiegel an die EIGENEN anderen Geraete: was hier drinsteckt, hat
  /// dieses Geraet gerade an jemand anderen geschickt.
  ///
  /// CODE 8 UND KEINE ERWEITERUNG VON 1 (Spezifikation §5.1). Die Zahlen
  /// duerfen nie umgedeutet werden — der Kommentar dieses Enums sagt es
  /// selbst —, und eine alte App muss den Spiegel VERWERFEN und nicht als
  /// verstuemmelten Text anzeigen. Genau das tut sie: [PayloadKind.byCode]
  /// liefert null, [Payload.fromBytes] wirft 'unbekannte Art 8', und der
  /// Eingang verwirft still (real_messenger_core `_behandleEingangsfehler`).
  ///
  /// Im Feld `c` steht der Ziel-Chat, in `x` die base64-kodierten
  /// VOLLSTAENDIGEN inneren Bytes. Kein zweites Format: was die Gegenstelle
  /// bekommen hat und was das eigene Zweitgeraet sieht, sind dieselben Bytes.
  spiegel(8),

  /// Eine Reaktion auf eine Nachricht: in `r` steht GENAU EINE Kennung, in
  /// `x` das Zeichen. Ein leeres `x` nimmt die eigene Reaktion zurueck.
  ///
  /// Je Person und Nachricht hoechstens EINE Reaktion, wie bei Signal. Eine
  /// neue ersetzt die alte — deshalb ist die Art wiederholbar, ohne dass
  /// daraus zwei werden, und darf ueber den Ausgang nachgeschickt werden.
  reaktion(9),

  /// Neuer Text fuer eine EIGENE, schon verschickte Textnachricht. `r` nennt
  /// sie, `x` ist der neue Text.
  ///
  /// Der Empfaenger nimmt sie nur fuer Nachrichten, deren Absender derselbe
  /// ist wie der der Bearbeitung — niemand bearbeitet fremde Saetze.
  bearbeitung(10),

  /// "Fuer alle loeschen": `r` nennt eine EIGENE Nachricht. Beim Empfaenger
  /// bleibt eine Leerstelle mit dem Vermerk, dass hier etwas geloescht wurde.
  ///
  /// Wie bei Signal nach bestem Bemuehen: ein veraenderter Client kann sie
  /// ignorieren, und wer vorher ein Bildschirmfoto gemacht hat, hat es.
  widerruf(11),

  /// "Tippt gerade": `x` ist '1' beim Anfangen und leer beim Aufhoeren.
  ///
  /// FLUECHTIG in jeder Hinsicht: nie gespeichert, nie gespiegelt, nie im
  /// Ausgang, nur an einen Relay, der fluechtige Rahmen kennt — und nur, wenn
  /// BEIDE Seiten die Anzeige eingeschaltet haben (wie bei Signal: wer sie
  /// aus hat, sendet keine und sieht keine).
  tippt(12),

  /// Eine Nachricht oben anheften (`x` = '1') oder loesen (`x` leer). `r`
  /// nennt sie. Beide Seiten duerfen jede Nachricht der Unterhaltung
  /// anheften, wie bei Signal im Einzelchat.
  anheften(13),

  /// Eine Umfrage. `x` ist Umfrage.alsText (lib/core/models.dart). Lebt
  /// und reist wie eine Textnachricht: mit Frist, mit Antwortbezug.
  umfrage(14),

  /// Eine Stimme: `r` nennt die Umfrage, `x` ist die Auswahl als JSON-Liste
  /// der Stellen, `[]` zieht sie zurueck.
  stimme(15),

  /// Eine Nachricht in einer Gruppe: `g` ist die Gruppenkennung, `x` die
  /// base64-kodierten VOLLSTAENDIGEN inneren Bytes — genau wie beim Spiegel.
  /// Innen steht eine gewoehnliche Art (Text, Anhang, Reaktion, ...).
  gruppe(16),

  /// Der Admin verkuendet den Stand einer Gruppe: `g` die Kennung, `x` der
  /// Stand (Gruppe.standText). Wer ihn nicht vom Admin bekommt, verwirft ihn.
  gruppenStand(17),

  /// Der Absender tritt aus der Gruppe `g` aus.
  gruppenAustritt(18);

  const PayloadKind(this.code);
  final int code;

  static PayloadKind? byCode(int c) {
    for (final k in PayloadKind.values) {
      if (k.code == c) return k;
    }
    return null;
  }
}

/// Wie eine Nachrichtenkennung aussehen darf. Siehe [Payload.fromBytes].
final _kennungTaugt = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Wie eine Gruppenkennung aussehen darf — dieselbe Regel wie Gruppe.istGruppenId.
final _gruppeTaugt = RegExp(r'^g-[A-Za-z0-9_-]{22}$');

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

  /// Nur bei [PayloadKind.spiegel]: die Adresse der Gegenstelle, also der Chat,
  /// in den die innere Nachricht gehoert.
  ///
  /// Bei allen anderen Arten ist der Chat die Absenderadresse und braucht
  /// deshalb kein Feld. Beim Spiegel ist der Absender ich selbst — ohne diese
  /// Angabe wuesste das zweite Geraet nicht, mit WEM die Unterhaltung lief.
  final String? chatId;

  /// Bei Text und Anhang: die Kennung der Nachricht, auf die geantwortet wird.
  ///
  /// NUR DIE KENNUNG, NICHT DAS ZITAT. Signal schickt einen Auszug mit; hier
  /// sucht der Empfaenger die Nachricht in seinem eigenen Verlauf. Ein
  /// mitgeschicktes Zitat koennte der Absender frei erfinden — er legte dem
  /// anderen Worte in den Mund, die in dessen Verlauf nie standen. Ist die
  /// Nachricht dort nicht (mehr) da, zeigt die Blase das ehrlich an.
  ///
  /// Eine alte App kennt das Feld nicht und zeigt den Text ohne Bezug — genau
  /// das richtige Verhalten fuer eine Erweiterung.
  final String? antwortAuf;

  /// Bei den drei Gruppenarten: welche Gruppe.
  final String? gruppe;

  Payload({
    required this.kind,
    required this.messageId,
    required this.sentAt,
    this.text = '',
    this.refs = const [],
    this.ttlSeconds,
    this.chatId,
    this.antwortAuf,
    this.gruppe,
  });

  factory Payload.text(String messageId, String text, DateTime sentAt,
          {Duration? lebensdauer, String? antwortAuf}) =>
      Payload(
        kind: PayloadKind.text,
        messageId: messageId,
        sentAt: sentAt,
        text: text,
        ttlSeconds: lebensdauer?.inSeconds,
        antwortAuf: antwortAuf,
      );

  /// Eine Reaktion auf [ziel]. Leeres [zeichen] nimmt sie zurueck.
  factory Payload.reaktion(
          String messageId, String ziel, String zeichen, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.reaktion,
        messageId: messageId,
        sentAt: sentAt,
        text: zeichen,
        refs: [ziel],
      );

  /// Neuer Text fuer die eigene Nachricht [ziel].
  factory Payload.bearbeitung(
          String messageId, String ziel, String neuerText, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.bearbeitung,
        messageId: messageId,
        sentAt: sentAt,
        text: neuerText,
        refs: [ziel],
      );

  /// Die eigene Nachricht [ziel] fuer alle loeschen.
  factory Payload.widerruf(String messageId, String ziel, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.widerruf,
        messageId: messageId,
        sentAt: sentAt,
        refs: [ziel],
      );

  factory Payload.umfrage(String messageId, String text, DateTime sentAt,
          {Duration? lebensdauer, String? antwortAuf}) =>
      Payload(
        kind: PayloadKind.umfrage,
        messageId: messageId,
        sentAt: sentAt,
        text: text,
        ttlSeconds: lebensdauer?.inSeconds,
        antwortAuf: antwortAuf,
      );

  factory Payload.stimme(
          String messageId, String umfrage, List<int> auswahl, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.stimme,
        messageId: messageId,
        sentAt: sentAt,
        text: jsonEncode(auswahl),
        refs: [umfrage],
      );

  /// Die Auswahl einer Stimme — oder null, wenn sie keine Liste kleiner
  /// ganzer Zahlen ist. Ob sie zur Umfrage PASST, prueft erst der Speicher.
  List<int>? get auswahl {
    try {
      final j = jsonDecode(text);
      if (j is! List || j.length > 10 || j.any((e) => e is! int)) return null;
      return j.cast<int>();
    } on FormatException {
      return null;
    }
  }

  /// [ziel] oben anheften ([an]) oder loesen.
  factory Payload.anheften(
          String messageId, String ziel, bool an, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.anheften,
        messageId: messageId,
        sentAt: sentAt,
        text: an ? '1' : '',
        refs: [ziel],
      );

  /// "Tippt gerade" ([an]) oder "hat aufgehoert".
  factory Payload.tippt(String messageId, bool an, DateTime sentAt) => Payload(
        kind: PayloadKind.tippt,
        messageId: messageId,
        sentAt: sentAt,
        text: an ? '1' : '',
      );

  /// Die groesste Reaktion in Bytes. Ein Emoji mit Hautton und
  /// Verbindungszeichen (Familie, Flagge) braucht bis gut 30 Byte; 64 laesst
  /// Luft und verhindert, dass jemand einen Aufsatz als "Reaktion" schickt.
  static const int reaktionMaxBytes = 64;

  factory Payload.control(PayloadKind kind, String messageId, DateTime sentAt,
          {List<String> refs = const []}) =>
      Payload(kind: kind, messageId: messageId, sentAt: sentAt, refs: refs);

  /// Ein Anhang: im Text steht die Anleitung, nicht die Datei.
  ///
  /// Sie ist laenger als eine gewoehnliche Nachricht — bei 256 Stuecken gut
  /// 33 KB. Der Relay laesst 64 KiB durch; darueber wuerde er den Umschlag
  /// abweisen, und zwar NACHDEM die ganze Datei schon im Lager liegt. Die
  /// Stueckzahl ist deshalb in rezept.dart begrenzt, nicht hier.
  factory Payload.anhang(String messageId, String rezept, DateTime sentAt,
          {Duration? lebensdauer, String? antwortAuf}) =>
      Payload(
        kind: PayloadKind.anhang,
        messageId: messageId,
        sentAt: sentAt,
        text: rezept,
        ttlSeconds: lebensdauer?.inSeconds,
        antwortAuf: antwortAuf,
      );

  /// Verpackt [innen] fuer die Gruppe [gruppe] — dieselbe Huelle wie der
  /// Spiegel, dieselbe Kennung und Zeit wie innen (die Entdoppelung beim
  /// Empfaenger haengt daran).
  factory Payload.inGruppe(String gruppe, Payload innen) => Payload(
        kind: PayloadKind.gruppe,
        messageId: innen.messageId,
        sentAt: innen.sentAt,
        gruppe: gruppe,
        text: base64.encode(innen.toBytes()),
      );

  factory Payload.gruppenStand(
          String messageId, String gruppe, String stand, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.gruppenStand,
        messageId: messageId,
        sentAt: sentAt,
        gruppe: gruppe,
        text: stand,
      );

  factory Payload.gruppenAustritt(
          String messageId, String gruppe, DateTime sentAt) =>
      Payload(
        kind: PayloadKind.gruppenAustritt,
        messageId: messageId,
        sentAt: sentAt,
        gruppe: gruppe,
      );

  /// Verpackt [innen] als Spiegel fuer die eigenen anderen Geraete.
  ///
  /// Kennung und Zeitstempel werden UNVERAENDERT uebernommen: der eindeutige
  /// Index auf messages(chat_id, sender_id, id) ist die Entdoppelung
  /// (encrypted_database.dart:355), und die traegt nur, wenn der Spiegel
  /// dieselbe Kennung fuehrt wie das Original. Der Nachversand schickt
  /// dieselbe Nutzlast noch einmal und spiegelt damit auch noch einmal.
  ///
  /// KOSTEN, GERECHNET: base64 macht aus n Bytes ceil(n/3)*4. Eine
  /// einbloeckige Textnachricht (256 B) wird zu 344 B
  /// (`py -c "import math;print(math.ceil(256/3)*4)"` -> 344) plus Rahmen,
  /// also zwei Bloecke. Ein Anhang-Rezept von 23 KB wird zu rund 31 KB
  /// (`py -c "import math;print(math.ceil(23*1024/3)*4/1024)"` -> 30.67 KiB) —
  /// weit unter den 64 KiB, die der Relay durchlaesst.
  factory Payload.spiegel(String chatId, Payload innen) => Payload(
        kind: PayloadKind.spiegel,
        messageId: innen.messageId,
        sentAt: innen.sentAt,
        chatId: chatId,
        text: base64.encode(innen.toBytes()),
      );

  /// Die innere Nutzlast eines Spiegels — genau die Bytes, die die
  /// Gegenstelle bekommen hat.
  ///
  /// Wirft [PayloadFormatException] wie jede andere Auswertung von draussen:
  /// dass die aeussere Huelle entschluesselbar war, sagt nichts ueber ihren
  /// Inhalt.
  Payload get innere {
    if (kind != PayloadKind.spiegel && kind != PayloadKind.gruppe) {
      throw const PayloadFormatException('keine Huelle');
    }
    final Uint8List roh;
    try {
      roh = base64.decode(text);
    } on FormatException catch (e) {
      throw PayloadFormatException('Spiegelinhalt ist kein base64: $e');
    }
    return Payload.fromBytes(roh);
  }

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
      if (chatId != null) 'c': chatId,
      if (text.isNotEmpty) 'x': text,
      if (refs.isNotEmpty) 'r': refs,
      if (ttlSeconds != null) 'l': ttlSeconds,
      if (antwortAuf != null) 'a': antwortAuf,
      if (gruppe != null) 'g': gruppe,
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
    // DIE KENNUNG KOMMT VON DRAUSSEN und landet spaeter in einem DATEINAMEN:
    // real_messenger_core baut den Zielpfad eines Anhangs als
    // "<ordner>/<kennung>_<name>". Eine Kennung "../evil" schreibt die Datei
    // damit AUSSERHALB des Anhangordners — mit Bytes, die die Gegenstelle
    // bestimmt, an einem Ort, den sie bestimmt. Eine zweite Bauart
    // ("../anhaenge/<schon vergebene Kennung>") umgeht sogar den eindeutigen
    // Index und ueberschreibt eine Datei, die der Nutzer schon geoeffnet hat.
    //
    // HIER GEPRUEFT UND NICHT ERST DORT: das ist die Stelle, an der alles
    // Fremde ankommt, und daneben stehen schon die Pruefungen fuer Zeitstempel
    // und Lebensdauer. Wer es erst beim Dateinamen abfaengt, muss daran bei
    // jeder kuenftigen Verwendung erneut denken.
    //
    // Das Muster ist das der eigenen Kennungen: _neueId() liefert base64Url
    // ohne Polster. Was nicht so aussieht, ist keine, die diese App vergeben
    // haben koennte.
    if (id is! String || !_kennungTaugt.hasMatch(id)) {
      throw const PayloadFormatException('Kennung fehlt oder taugt nicht');
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

    // DER ZIEL-CHAT EINES SPIEGELS WIRD GEPRUEFT WIE ALLES VON DRAUSSEN.
    //
    // Er landet als `chat_id` in der Datenbank und damit in der
    // Unterhaltungsliste. Eine erfundene Zeichenkette legte dort eine
    // Unterhaltung an, die zu keiner Adresse gehoert und die niemand wieder
    // loswird. `BitdmAddress.decode` prueft Alphabet, Laenge und Pruefsumme —
    // dieselbe Pruefung, die die Kennung oben bekommt.
    //
    // NUR DAS EIGENE ZWEITGERAET kann ueberhaupt so weit kommen (die aeussere
    // Huelle muss ueber eine Sitzung mit dem eigenen Identitaetsschluessel
    // gelaufen sein), aber das entbindet nicht vom Pruefen: es koennte eine
    // aeltere oder fehlerhafte Fassung derselben App sein.
    final c = j['c'];
    if (kind == PayloadKind.spiegel && c is! String) {
      throw const PayloadFormatException('Spiegel ohne Ziel-Chat');
    }
    if (c != null) {
      if (c is! String) {
        throw const PayloadFormatException('Ziel-Chat ist keine Zeichenkette');
      }
      try {
        BitdmAddress.decode(c);
      } catch (e) {
        throw PayloadFormatException('Ziel-Chat taugt nicht: $e');
      }
    }

    // DER BEZUG EINER ANTWORT wird gefragt, NICHT geglaubt: er ist eine
    // Kennung von draussen wie `id` oben, und er wird spaeter in Abfragen
    // gegen den eigenen Verlauf benutzt. Was nicht wie eine Kennung aussieht,
    // faellt still weg — die Nachricht selbst bleibt lesbar, nur ohne Bezug.
    final a = j['a'];
    final antwort = (a is String && _kennungTaugt.hasMatch(a)) ? a : null;

    final text = j['x'];
    if (text != null && text is! String) {
      throw const PayloadFormatException('Text ist keine Zeichenkette');
    }
    final refs = ((j['r'] ?? const []) as List).map((e) => '$e').toList();

    // DIE DREI ARTEN, DIE AUF EINE NACHRICHT ZEIGEN, zeigen auf GENAU EINE.
    // Eine Liste wuerde bedeuten, dass eine einzige Nutzlast den halben
    // Verlauf umschreiben oder leeren kann — und gepruefte Einzelfaelle sind
    // leichter zu denken als eine Schleife ueber fremde Eingaben.
    if (kind == PayloadKind.reaktion ||
        kind == PayloadKind.bearbeitung ||
        kind == PayloadKind.widerruf ||
        kind == PayloadKind.anheften ||
        kind == PayloadKind.stimme) {
      if (refs.length != 1 || !_kennungTaugt.hasMatch(refs.single)) {
        throw PayloadFormatException('${kind.name} ohne gueltiges Ziel');
      }
    }
    if (kind == PayloadKind.reaktion) {
      final z = (text as String?) ?? '';
      if (utf8.encode(z).length > reaktionMaxBytes ||
          z.contains(RegExp(r'[\s\x00-\x1F]'))) {
        throw const PayloadFormatException('Reaktion taugt nicht');
      }
    }
    if (kind == PayloadKind.bearbeitung && ((text as String?) ?? '').isEmpty) {
      // Eine leere Bearbeitung waere ein Loeschen durch die Hintertuer — dafuer
      // gibt es [PayloadKind.widerruf], mit seinem eigenen Vermerk.
      throw const PayloadFormatException('leere Bearbeitung');
    }

    // DIE GRUPPENKENNUNG wird geprueft wie jede Kennung von draussen: sie wird
    // zur `chat_id` im Verlauf. Bei den Gruppenarten ist sie Pflicht, bei
    // allen anderen hat sie nichts verloren.
    final g = j['g'];
    final istGruppenArt = kind == PayloadKind.gruppe ||
        kind == PayloadKind.gruppenStand ||
        kind == PayloadKind.gruppenAustritt;
    if (istGruppenArt && (g is! String || !_gruppeTaugt.hasMatch(g))) {
      throw const PayloadFormatException('Gruppenkennung fehlt oder taugt nicht');
    }

    return Payload(
      gruppe: istGruppenArt ? g as String : null,
      kind: kind,
      messageId: id,
      sentAt: DateTime.fromMillisecondsSinceEpoch(t, isUtc: true),
      text: (text as String?) ?? '',
      refs: refs,
      ttlSeconds: gueltigeTtl,
      chatId: c as String?,
      antwortAuf: antwort,
    );
  }
}
