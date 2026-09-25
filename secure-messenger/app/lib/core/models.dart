// models.dart — shared data models + enums for the BitDM messenger core.
//
// PURE DART (no Flutter imports) so it runs in unit tests and background
// isolates. FROZEN v1 contract: change only by agreement between
// Person A (UI) and Person B (core).

import 'dart:convert';

/// Delivery lifecycle of a single message.
enum MessageStatus {
  sending, // created locally, not yet handed to the network
  sent, // accepted by the relay server
  delivered, // delivered to the recipient device
  read, // recipient opened the chat (only if read receipts are on)
  failed, // permanently failed (encryption / network / no session)
}

/// Was eine Nachricht ist.
///
/// Die Reihenfolge ist Teil des Datenbankformats — sie wird als Zahl
/// gespeichert. Neues kommt HINTEN dazu, nie dazwischen.
enum MessageKind {
  text,

  /// Ein Anhang. Im `text` steht der angezeigte Name, nicht die Anleitung —
  /// die liegt in der Tabelle `anhaenge` und ist bei einer grossen Datei rund
  /// 23 KB. Sie beim Anzeigen einer Unterhaltung mitzuschleppen waere Arbeit
  /// fuer nichts.
  anhang,

  /// Eine Umfrage. Im `text` steht [Umfrage.alsText] — Frage, Antworten und
  /// ob mehrere gewaehlt werden duerfen. Die Stimmen stehen daneben.
  umfrage,
}

/// Eine Umfrage: Frage, zwei bis zehn Antworten, Einzel- oder Mehrfachwahl.
///
/// UNVERAENDERLICH NACH DEM ABSENDEN. Die Stimmen beziehen sich auf die
/// Stellen der Antworten; eine nachtraeglich umsortierte oder umbenannte
/// Antwort liesse jede abgegebene Stimme etwas anderes bedeuten.
class Umfrage {
  const Umfrage(this.frage, this.optionen, {this.mehrfach = false});

  final String frage;
  final List<String> optionen;
  final bool mehrfach;

  static const int minOptionen = 2;
  static const int maxOptionen = 10;
  static const int maxFrage = 300;
  static const int maxOption = 120;

  String alsText() => jsonEncode({
        'f': frage,
        'o': optionen,
        if (mehrfach) 'm': true,
      });

  /// Liest eine Umfrage — oder null, wenn der Text keine taugliche ist. Er
  /// kommt von draussen: Laengen und Anzahl werden hier begrenzt, nicht erst
  /// in der Anzeige.
  static Umfrage? lies(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (j is! Map) return null;
    final f = j['f'];
    final o = j['o'];
    final m = j['m'];
    if (f is! String || f.trim().isEmpty || f.length > maxFrage) return null;
    if (o is! List || o.length < minOptionen || o.length > maxOptionen) {
      return null;
    }
    final optionen = <String>[];
    for (final x in o) {
      if (x is! String || x.trim().isEmpty || x.length > maxOption) return null;
      optionen.add(x);
    }
    if (m != null && m is! bool) return null;
    return Umfrage(f, optionen, mehrfach: m == true);
  }

  /// Ob [auswahl] eine erlaubte Stimme ist. Leer heisst "zurueckgezogen".
  bool gueltig(List<int> auswahl) =>
      auswahl.toSet().length == auswahl.length &&
      auswahl.every((i) => i >= 0 && i < optionen.length) &&
      (mehrfach || auswahl.length <= 1);
}

/// Eine Gruppe: ein Name, ein Admin, bis zu [maxMitglieder] Mitglieder.
///
/// ═══════════════════════════════════════════════════ WIE GRUPPEN REISEN
///
/// OHNE GRUPPENSCHLUESSEL. Eine Gruppennachricht ist die gewoehnliche
/// Nutzlast, eingepackt mit der Gruppenkennung, und geht einzeln ueber die
/// Zweiersitzung an jedes Mitglied — so machten es Signals erste Gruppen und
/// Sessions "Closed Groups". Es gibt dafuer keine neue Kryptografie und
/// keinen Server, der die Mitglieder kennt: der Relay sieht nur Einzelpost.
///
/// DER PREIS ist ein Umschlag je Mitglied und Geraet. Der Relay bremst bei
/// 180 im Schub und 6 je Sekunde (relay_server.py MSG_CAPACITY/REFILL); bei
/// 20 Mitgliedern mit im Schnitt anderthalb Geraeten sind das rund 30 je
/// Nachricht — sechs schnell hintereinander, danach eine alle fuenf Sekunden.
/// Deshalb 20 und nicht 1000. Groessere Gruppen braeuchten Sender-Keys wie bei
/// Signal heute; das ist ein eigenes Vorhaben.
///
/// NUR DER ADMIN aendert die Mitgliederliste, jede Aenderung mit einer
/// hoeheren [version]. Austreten darf jeder selbst. Tritt der Admin aus,
/// wird das naechste Mitglied der Liste Admin ([nachfolger]).
class Gruppe {
  const Gruppe({
    required this.id,
    required this.name,
    required this.admin,
    required this.mitglieder,
    this.version = 1,
    this.aktiv = true,
    this.angeheftet = false,
    this.archiviert = false,
    this.stumm = false,
    this.fristSekunden,
  });

  final String id;
  final String name;
  final String admin;
  final List<String> mitglieder;
  final int version;

  /// Falsch, sobald man ausgetreten ist oder entfernt wurde. Der Verlauf
  /// bleibt lesbar; schreiben laesst sich nicht mehr.
  final bool aktiv;
  final bool angeheftet;
  final bool archiviert;
  final bool stumm;
  final int? fristSekunden;

  static const int maxMitglieder = 20;

  /// Wer Admin wird, wenn [admin] austritt: das Mitglied, das in der Liste
  /// nach ihm steht (am Ende wieder von vorn).
  ///
  /// OHNE NACHRICHT UND OHNE ABSTIMMUNG. Alle Mitglieder haben dieselbe Liste
  /// in derselben Reihenfolge — sie kam als ein verkuendeter Stand — und
  /// rechnen deshalb denselben Nachfolger aus. Vorher fror eine Gruppe ein,
  /// deren Admin ging: niemand konnte mehr jemanden hinzufuegen.
  static String? nachfolger(List<String> mitglieder, String admin) {
    final i = mitglieder.indexOf(admin);
    final rest = [...mitglieder]..remove(admin);
    if (rest.isEmpty) return null;
    if (i < 0) return rest.first;
    return rest[i % rest.length];
  }
  static const int maxName = 64;

  static final RegExp _kennung = RegExp(r'^g-[A-Za-z0-9_-]{22}$');

  /// Ob eine Chatkennung eine Gruppe meint. Adressen sind 56 Zeichen base32
  /// ohne Bindestrich; eine Verwechslung ist ausgeschlossen.
  static bool istGruppenId(String id) => _kennung.hasMatch(id);

  /// Was der Admin an alle Mitglieder verkuendet.
  String standText() => jsonEncode({
        'n': name,
        'a': admin,
        'm': mitglieder,
        'v': version,
      });

  /// Liest einen verkuendeten Stand — oder null, wenn er nicht taugt. Kommt
  /// von draussen: jede Adresse wird geprueft, der Admin muss Mitglied sein.
  static Gruppe? lies(String id, String text,
      {required bool Function(String) adresseTaugt}) {
    if (!istGruppenId(id)) return null;
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (j is! Map) return null;
    final n = j['n'];
    final a = j['a'];
    final m = j['m'];
    final v = j['v'];
    if (n is! String || n.trim().isEmpty || n.length > maxName) return null;
    if (a is! String || !adresseTaugt(a)) return null;
    if (v is! int || v < 1) return null;
    if (m is! List || m.length < 2 || m.length > maxMitglieder) return null;
    final mitglieder = <String>[];
    for (final x in m) {
      if (x is! String || !adresseTaugt(x) || mitglieder.contains(x)) {
        return null;
      }
      mitglieder.add(x);
    }
    if (!mitglieder.contains(a)) return null;
    return Gruppe(id: id, name: n, admin: a, mitglieder: mitglieder, version: v);
  }

  Gruppe copyWith({
    String? name,
    String? admin,
    List<String>? mitglieder,
    int? version,
    bool? aktiv,
    bool? angeheftet,
    bool? archiviert,
    bool? stumm,
    Object? fristSekunden = _unveraendert,
  }) =>
      Gruppe(
        id: id,
        name: name ?? this.name,
        admin: admin ?? this.admin,
        mitglieder: mitglieder ?? this.mitglieder,
        version: version ?? this.version,
        aktiv: aktiv ?? this.aktiv,
        angeheftet: angeheftet ?? this.angeheftet,
        archiviert: archiviert ?? this.archiviert,
        stumm: stumm ?? this.stumm,
        fristSekunden: identical(fristSekunden, _unveraendert)
            ? this.fristSekunden
            : fristSekunden as int?,
      );
}

/// Wer in einer Umfrage was gewaehlt hat: Adresse → Stellen der Antworten.
typedef Stimmen = Map<String, List<int>>;

/// Was auf DIESEM Telefon von einem Anhang vorliegt.
///
/// Ortsgebunden: der Zustand reist nie mit. Auf einem wiederhergestellten
/// Geraet steht wieder [angekuendigt], und das ist richtig — die Datei liegt
/// dort ja auch nicht.
enum AnhangZustand {
  /// Die Anleitung ist da, geholt wurde noch nichts.
  angekuendigt,

  /// Wird gerade geholt.
  laedt,

  /// Liegt lokal, unter [AnhangEintrag.pfad].
  da,

  /// Ein Versuch ist gescheitert. Wiederholen kann helfen.
  gescheitert,

  /// Im Lager nicht mehr da — abgelaufen (14 Tage) oder schon weggeworfen.
  ///
  /// EIGENER ZUSTAND und nicht [gescheitert]: die Oberflaeche muss darauf
  /// etwas anderes sagen. "Noch einmal versuchen" waere hier eine Luege.
  weg,
}

/// Was die Oberflaeche ueber einen Anhang wissen muss, ohne die Anleitung zu
/// lesen.
class AnhangEintrag {
  const AnhangEintrag({
    required this.messageId,
    required this.chatId,
    required this.senderId,
    required this.name,
    required this.groesse,
    required this.zustand,
    this.pfad,
  });

  final String messageId;
  final String chatId;
  final String senderId;

  /// Schon gesaeubert (siehe AnhangEmpfang.sichererName) — er kam von der
  /// Gegenstelle.
  final String name;

  /// Groesse der Datei im Klartext.
  final int groesse;

  final AnhangZustand zustand;

  /// Nur bei [AnhangZustand.da] gesetzt.
  final String? pfad;

  AnhangEintrag copyWith({AnhangZustand? zustand, String? pfad}) =>
      AnhangEintrag(
        messageId: messageId,
        chatId: chatId,
        senderId: senderId,
        name: name,
        groesse: groesse,
        zustand: zustand ?? this.zustand,
        pfad: pfad ?? this.pfad,
      );
}

/// Fortschritt beim Holen oder Schicken eines Anhangs.
class AnhangFortschritt {
  const AnhangFortschritt({
    required this.messageId,
    required this.chatId,
    required this.fertigeBytes,
    required this.gesamtBytes,
  });

  final String messageId;
  final String chatId;
  final int fertigeBytes;
  final int gesamtBytes;

  double get anteil => gesamtBytes == 0 ? 0 : fertigeBytes / gesamtBytes;
}

/// State of the link to the relay/key server.
enum ConnectionState { disconnected, connecting, online, error }

/// Where a contact sits in the request/accept handshake.
enum ContactState {
  outgoingPending, // we sent a request, waiting for them
  incomingPending, // they sent us a request, waiting for our accept
  active, // both sides confirmed; messaging allowed
}

/// Kinds of asynchronous contact events pushed to the UI.
enum ContactEventType { incomingRequest, requestAccepted, requestDeclined, removed }

class Message {
  final String id; // client-generated, stable, unique (e.g. UUID v4)
  final String chatId; // conversation id == the peer contact's address
  final String senderId; // author's address (== myId when isMine)
  final String text; // plaintext (already decrypted); '' for non-text kinds
  final MessageKind kind;
  final bool isMine;
  final DateTime timestamp; // UTC, authored time
  final MessageStatus status;

  /// Diese Nachricht ging direkt von Geraet zu Geraet, ohne Server.
  ///
  /// Sie bekommt dafuer ein Zeichen in der Unterhaltung. Das ist die EINZIGE
  /// Stelle, an der die Naehe sichtbar wird — es gibt bewusst keine Anzeige,
  /// wer gerade in Reichweite ist (siehe docs/NAHBEREICH.md). Der Unterschied
  /// ist wichtig: hier steht, wie eine Nachricht gegangen IST; eine
  /// Anwesenheitsanzeige verriete, wo jemand gerade IST.
  final bool ueberNaehe;

  /// Dieser Umschlag war schon einmal beim Relay — und ist trotzdem
  /// liegengeblieben.
  ///
  /// NICHT dasselbe wie "zugestellt": RelayClient.send schreibt erst in die
  /// Leitung und wartet dann auf die Bestaetigung. Laeuft die Wartezeit ab,
  /// ist der Umschlag draussen und nur der Ack fehlt. Deshalb darf dieselbe
  /// Nachricht danach nicht mehr ueber die Naehe — sie kaeme sonst
  /// moeglicherweise zweimal an, und sie truege das Zeichen [ueberNaehe],
  /// dessen Zusage "kein Server war beteiligt" dann nicht mehr stimmte.
  ///
  /// Das Gegenstueck zu [ueberNaehe]: dort steht, welchen Weg sie GENOMMEN
  /// hat, hier, welcher ihr verschlossen ist.
  final bool schonBeimRelay;

  /// Und dasselbe fuer den anderen Weg.
  ///
  /// Zwei Felder statt eines, obwohl sie dieselbe Sache in zwei Richtungen
  /// sagen: welcher Weg VERSCHLOSSEN ist, haengt daran, welcher schon
  /// benutzt wurde, und beide koennen mehrdeutig scheitern. Ein einzelnes
  /// "schon versucht" wuesste nicht, WELCHER — und liesse dann beide zu oder
  /// keinen.
  final bool schonInDerNaehe;

  /// Die Kennung der Nachricht, auf die diese antwortet — oder null.
  ///
  /// Nur die Kennung: was dort stand, schlaegt die Oberflaeche im EIGENEN
  /// Verlauf nach (siehe Payload.antwortAuf, warum kein Zitat mitreist).
  final String? antwortAuf;

  /// Der Text wurde nach dem Absenden geaendert. Die Blase sagt es dazu —
  /// eine stille Aenderung waere ein umgeschriebener Verlauf.
  final bool bearbeitet;

  /// "Fuer alle geloescht": der Inhalt ist weg, die Stelle bleibt.
  ///
  /// EINE LEERSTELLE STATT EINES LOCHS, wie bei Signal: verschwaende die
  /// Blase ganz, stuenden die Antworten darauf ohne Bezug da, und niemand
  /// saehe, dass hier etwas war.
  final bool widerrufen;

  /// Seit wann oben angeheftet — oder null. Hoechstens drei je Unterhaltung.
  final DateTime? angeheftetAm;

  /// Wann diese eigene Nachricht hinausgehen soll, wenn sie geplant ist. Nach
  /// dem Zeitpunkt ist es nur noch ein Vermerk — der Status sagt, ob sie
  /// draussen ist.
  final DateTime? geplantFuer;

  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.text,
    required this.isMine,
    required this.timestamp,
    this.kind = MessageKind.text,
    this.status = MessageStatus.sent,
    this.ueberNaehe = false,
    this.schonBeimRelay = false,
    this.schonInDerNaehe = false,
    this.antwortAuf,
    this.bearbeitet = false,
    this.widerrufen = false,
    this.angeheftetAm,
    this.geplantFuer,
  });

  Message copyWith(
          {MessageStatus? status,
          String? text,
          bool? ueberNaehe,
          bool? bearbeitet,
          bool? widerrufen}) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: senderId,
        text: text ?? this.text,
        kind: kind,
        isMine: isMine,
        timestamp: timestamp,
        status: status ?? this.status,
        ueberNaehe: ueberNaehe ?? this.ueberNaehe,
        schonBeimRelay: schonBeimRelay,
        schonInDerNaehe: schonInDerNaehe,
        antwortAuf: antwortAuf,
        bearbeitet: bearbeitet ?? this.bearbeitet,
        widerrufen: widerrufen ?? this.widerrufen,
        angeheftetAm: angeheftetAm,
        geplantFuer: geplantFuer,
      );
}

/// "Tippt gerade" in einer Unterhaltung, oder "hat aufgehoert".
class TippMeldung {
  const TippMeldung(this.chatId, this.tippt);
  final String chatId;
  final bool tippt;
}

/// Wer auf eine Nachricht wie reagiert hat: Adresse → Zeichen.
typedef Reaktionen = Map<String, String>;

class Contact {
  final String id; // address (derived from the peer identity public key)
  final String? displayName; // local-only nickname; the network never sees names
  final DateTime addedAt;
  final ContactState state;
  final bool verified; // true once the user compared the SafetyNumber

  /// Ob diesem Kontakt gegenueber die eigene Anwesenheit gezeigt wird.
  ///
  /// Standard an, je Kontakt abschaltbar. Der Grund ist konkret: wer jemanden
  /// in den Kontakten hat, dem er nicht mehr begegnen will, verriete ihm sonst
  /// jedes Mal seine Anwesenheit, wenn beide im selben Cafe sitzen. Ein
  /// Messenger ohne Telefonnummer, der stattdessen Anwesenheit verraet, haette
  /// an der falschen Stelle gespart.
  ///
  /// Praktisch heisst "aus": fuer diesen Kontakt wird KEIN Leuchtfeuer
  /// ausgesendet und keines von ihm erwartet. Beides zusammen — sonst
  /// wuerde man ihn zwar nicht mehr finden, ihm aber weiter zeigen, wo man
  /// ist. Nachrichten an ihn nehmen dann immer den Relay.
  final bool zeigtAnwesenheit;

  /// Oben in der Liste festgehalten, unabhaengig von der letzten Nachricht.
  ///
  /// Wie Anwesenheit und Name nur auf DIESEM Geraet: der Relay erfaehrt
  /// nichts, und die Gegenstelle auch nicht.
  final bool angeheftet;

  /// Aus der Hauptliste genommen, ohne etwas zu loeschen. Eine neue Nachricht
  /// holt die Unterhaltung NICHT von selbst zurueck — wer archiviert, will
  /// Ruhe, und Signal macht es genauso, sobald die Unterhaltung stumm ist.
  final bool archiviert;

  /// Keine Benachrichtigung fuer diese Unterhaltung. Die Nachrichten kommen
  /// trotzdem an und werden gezaehlt; nur das Telefon schweigt.
  final bool stumm;

  /// Eigene Loeschfrist fuer DIESE Unterhaltung, in Sekunden.
  ///
  /// null folgt der Grundeinstellung, 0 heisst "hier nie", alles andere ist
  /// die Frist. Sie gilt fuer das, was ICH hier schreibe — die Frist reist
  /// mit jeder Nachricht mit, und die Gegenstelle richtet sich danach (siehe
  /// Payload.ttlSeconds). Was sie schreibt, loescht sich nach IHRER Wahl.
  final int? fristSekunden;

  const Contact({
    required this.id,
    required this.addedAt,
    this.displayName,
    this.state = ContactState.active,
    this.verified = false,
    this.zeigtAnwesenheit = true,
    this.angeheftet = false,
    this.archiviert = false,
    this.stumm = false,
    this.fristSekunden,
  });

  Contact copyWith({
    String? displayName,
    ContactState? state,
    bool? verified,
    bool? zeigtAnwesenheit,
    bool? angeheftet,
    bool? archiviert,
    bool? stumm,
    // Ein Waechter statt `int?`: null ist hier ein gueltiger neuer Wert
    // ("folgt der Grundeinstellung") und muss sich von "nicht angegeben"
    // unterscheiden lassen.
    Object? fristSekunden = _unveraendert,
  }) =>
      Contact(
        id: id,
        addedAt: addedAt,
        displayName: displayName ?? this.displayName,
        state: state ?? this.state,
        verified: verified ?? this.verified,
        zeigtAnwesenheit: zeigtAnwesenheit ?? this.zeigtAnwesenheit,
        angeheftet: angeheftet ?? this.angeheftet,
        archiviert: archiviert ?? this.archiviert,
        stumm: stumm ?? this.stumm,
        fristSekunden: identical(fristSekunden, _unveraendert)
            ? this.fristSekunden
            : fristSekunden as int?,
      );
}

const Object _unveraendert = Object();

/// Pushed on `MessengerCore.messageStatusUpdates` when a sent message changes.
class MessageStatusUpdate {
  final String messageId;
  final String chatId;
  final MessageStatus status;
  final DateTime at;
  const MessageStatusUpdate({
    required this.messageId,
    required this.chatId,
    required this.status,
    required this.at,
  });
}

/// Pushed on `MessengerCore.contactEvents`.
class ContactEvent {
  final ContactEventType type;
  final String contactId;
  final DateTime at;
  const ContactEvent({required this.type, required this.contactId, required this.at});
}

/// User-visible settings that the CORE actually enforces.
///
/// Added 2026-07-25. Until then these three switches lived only in the UI and
/// changed nothing at all — the app claimed messages would disappear after 24
/// hours, that screenshots were blocked and that read receipts could be turned
/// off, and none of it was true. A promise the software does not keep is worse
/// than a missing feature: someone writes something they otherwise would not.
class AppPreferences {
  /// Send a receipt when the user opens a conversation.
  ///
  /// Off means the peer sees "delivered" but never "read". They cannot tell
  /// the difference between "switched off" and "not opened yet" — which is
  /// exactly the point.
  final bool readReceipts;

  /// How long a message survives, on BOTH devices. `null` = forever.
  ///
  /// The lifetime travels inside the encrypted payload, so the recipient
  /// applies it too. It is not enforceable against a modified client — no
  /// implementation of this anywhere is — but it is honest for every ordinary
  /// one, and the UI says so.
  final Duration? messageLifetime;

  /// Ask Android to keep this app out of screenshots and the recents preview.
  final bool blockScreenshots;

  /// Nur ueber die Naehe. KEIN Server, auch nicht zum Verbinden.
  ///
  /// Was dieser Schalter WIRKLICH TUT, und das ist der ganze Punkt: die App
  /// baut gar keine Verbindung zum Relay auf. Kein Anmelden, kein Abholen,
  /// kein Anstoss-Endpunkt, kein Zwischenlager. Auf der Leitung ist nichts
  /// zu sehen, weil nichts gesendet wird.
  ///
  /// OHNE [naheAn] BLEIBEN NACHRICHTEN LIEGEN. Dieser Schalter verbietet nur
  /// den Server; er baut keinen zweiten Weg. Wer beides will, braucht beide —
  /// und die Oberflaeche sagt das, statt still nichts zuzustellen.
  ///
  /// Ausdruecklich KEIN Flugmodus-Ersatz: andere Apps sind davon unberuehrt.
  /// Dieser Schalter spricht nur fuer BitDM.
  final bool nurNahbereich;

  /// Bluetooth benutzen, um Kontakte in Reichweite zu erreichen.
  ///
  /// ZWEI SCHALTER, NICHT EINER, und der Unterschied ist keine Spitzfindigkeit:
  ///
  ///   [naheAn]         — "nimm auch den Nahweg, wenn der Relay nicht geht".
  ///                      Ausfallsicherung. Der Relay bleibt der Hauptweg.
  ///   [nurNahbereich]  — "nimm NIEMALS einen Server". Eine Einschraenkung,
  ///                      kein Weg.
  ///
  /// Sie liessen sich zu einem zusammenlegen, und dann haette man entweder
  /// eine Ausfallsicherung, die niemand ohne Funk haben kann, oder einen
  /// Spurlos-Modus, den man nicht ohne Bluetooth bekommt. Beides waere falsch.
  ///
  /// STANDARD AUS. Funk kostet Akku und zeigt Anwesenheit — das schaltet man
  /// ein, wenn man es will, nicht ungefragt.
  final bool naheAn;

  /// Bei einer neuen Nachricht ans Ende der Unterhaltung springen.
  ///
  /// STANDARD AN, anders als die beiden Schalter darueber. Die sind aus, weil
  /// sie etwas kosten (Akku, Zustellbarkeit); dieser kostet nichts und ist das,
  /// was jeder von einem Messenger erwartet.
  ///
  /// WAS ER NICHT TUT: den Leser wegreissen. Wer nach oben gescrollt hat und
  /// alte Nachrichten liest, bleibt dort — sonst waere jede eingehende
  /// Nachricht ein Sprung mitten im Satz. Nur wer ohnehin unten steht, wird
  /// mitgenommen. Eigene Nachrichten springen immer, denn wer schreibt, will
  /// sehen, was er geschrieben hat.
  final bool autoScroll;

  /// "Tippt gerade" zeigen und senden. Ab Werk AUS — wie die
  /// Lesebestaetigungen: beides verraet, wann jemand die App offen hat.
  final bool tippAnzeige;

  /// Die Kennung des PANIK-FACHS in der Fachdatei, oder null.
  ///
  /// STEHT HIER, IN DER VERSCHLUESSELTEN DATENBANK, und nicht in der
  /// Fachdatei: dort saehe jeder, welches der Passwort-Faecher das Panik-Fach
  /// ist. Hier ist es nur lesbar, wenn die App schon offen ist — und dann
  /// braucht die Oberflaeche es, um es aus der Liste der Faktoren zu nehmen.
  final String? panikFach;

  const AppPreferences({
    this.readReceipts = true,
    this.messageLifetime,
    this.blockScreenshots = true,
    this.nurNahbereich = false,
    this.naheAn = false,
    this.autoScroll = true,
    this.tippAnzeige = false,
    this.panikFach,
  });

  AppPreferences copyWith({
    bool? readReceipts,
    Duration? messageLifetime,
    bool loescheLebensdauer = false,
    bool? blockScreenshots,
    bool? nurNahbereich,
    bool? naheAn,
    bool? autoScroll,
    bool? tippAnzeige,
    String? panikFach,
    bool loeschePanikFach = false,
  }) =>
      AppPreferences(
        readReceipts: readReceipts ?? this.readReceipts,
        messageLifetime:
            loescheLebensdauer ? null : (messageLifetime ?? this.messageLifetime),
        blockScreenshots: blockScreenshots ?? this.blockScreenshots,
        nurNahbereich: nurNahbereich ?? this.nurNahbereich,
        naheAn: naheAn ?? this.naheAn,
        autoScroll: autoScroll ?? this.autoScroll,
        tippAnzeige: tippAnzeige ?? this.tippAnzeige,
        panikFach: loeschePanikFach ? null : (panikFach ?? this.panikFach),
      );
}

/// Out-of-band verification material for a conversation (Signal-style).
class SafetyNumber {
  final String contactId;

  /// 60 decimal digits as one string. Display grouped (see [groups]).
  final String digits;

  /// Opaque payload the UI renders as a QR for scanning the peer in person.
  final String qrPayload;

  const SafetyNumber({required this.contactId, required this.digits, required this.qrPayload});

  /// [digits] split into 12 groups of 5 for display.
  List<String> get groups {
    final out = <String>[];
    for (var i = 0; i < digits.length; i += 5) {
      final end = i + 5 > digits.length ? digits.length : i + 5;
      out.add(digits.substring(i, end));
    }
    return out;
  }
}
