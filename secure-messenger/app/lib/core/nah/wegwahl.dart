// wegwahl.dart — welchen Weg eine Nachricht nimmt.
//
// Es gibt zwei: ueber den Relay und ueber die Naehe. Diese Datei entscheidet,
// welchen — und sie ist absichtlich das dickste Stueck Buchfuehrung im
// Naehe-Teil, weil hier die Fehler sitzen, die man einem Messenger nicht
// verzeiht.
//
// ═══════════════════════════════════════════════════════ DIE VIER REGELN
//
// 1. RELAY ZUERST. Der gewohnte Weg bleibt der Hauptweg: vorhersagbar, und
//    die Nachricht kommt auch an, wenn der andere weggeht. Die Naehe ist die
//    Ausfallsicherung, nicht der Normalfall.
//
// 2. NIEMALS BEIDE WEGE FUER DIESELBE NACHRICHT. Das waeren zwei verschiedene
//    Verschluesselungen desselben Textes — der Empfaenger zeigte ihn zweimal
//    an, und im Double Ratchet stuenden zwei Schluesselketten nebeneinander.
//    Je Nachricht genau ein Weg, und diese Datei ist die einzige Stelle, an
//    der das entschieden wird.
//
//    UND ZWAR UEBER DEN EINZELNEN AUFRUF HINAUS. Diese Klasse lebt nur einen
//    Versand lang; eine Nachricht, die liegenbleibt, bekommt beim naechsten
//    Anlauf eine frische. Ohne Gedaechtnis waehlte die frei — gemessen: erster
//    Versuch ueber den Relay wirft, zweiter Anlauf geht ueber die Naehe
//    hinaus. Deshalb [Wegbescheid.beimRelay] hinaus und `schonBeimRelay`
//    wieder herein.
//
// 3. WER "NUR IN DER NAEHE" EINGESCHALTET HAT, bekommt keinen Relay — auch
//    nicht als Rueckfall, auch nicht "nur zum Verbinden".
//
// 4. WAS NICHT RAUSGEHT, BLEIBT LIEGEN. Nicht "gescheitert": liegengeblieben.
//    Der Unterschied ist der zwischen "die App versucht es wieder" und "du
//    musst es noch einmal tippen".
//
// ═════════════════════════════════════════════ WARUM DAS EINE EIGENE DATEI IST
//
// Weil sie ohne Funk und ohne Server vollstaendig pruefbar ist. Beide Wege
// sind hier nur Schnittstellen; ob dahinter ein WebSocket, ein Bluetooth-
// Geraet oder eine Attrappe steckt, ist ihr gleichgueltig. Die Regeln oben
// sind Aussagen ueber Buchfuehrung, nicht ueber Funktechnik — und
// Buchfuehrung prueft man am besten dort, wo nichts wackelt.

import 'dart:async';
import 'dart:typed_data';

/// Wohin eine Nachricht gegangen ist.
enum Weg {
  /// Ueber den Relay, wie gewohnt.
  relay,

  /// Ueber die Naehe, weil der Relay nicht erreichbar war.
  naehe,

  /// Gar nicht. Sie liegt und geht raus, sobald ein Weg da ist.
  liegt,
}

/// Warum es so gekommen ist. Nur fuer Protokoll und Verbindungstest —
/// die Oberflaeche zeigt den Nutzern etwas Einfacheres.
class Wegbescheid {
  const Wegbescheid(this.weg, this.grund,
      {this.beimRelay = false, this.inDerNaehe = false});

  final Weg weg;
  final String grund;

  /// Ob der Relay diesen Umschlag schon in der Hand hatte.
  ///
  /// NICHT "er ist angekommen" — das weiss niemand. RelayClient.send schreibt
  /// erst in die Leitung und wartet DANN auf die Bestaetigung; laeuft die
  /// Wartezeit ab, ist der Umschlag draussen und nur der Ack fehlt. Wer diese
  /// Angabe wegwirft, gibt dieselbe Nachricht spaeter der Naehe — und sie
  /// traegt dann ein Zeichen, das behauptet, kein Server habe je gesehen, dass
  /// hier ueberhaupt jemand schreibt.
  ///
  /// Der Aufrufer muss sie festhalten, denn diese Klasse tut es nicht: sie
  /// lebt nur einen Versand lang.
  final bool beimRelay;

  /// Das Gegenstueck: dieser Umschlag ist ueber die Naehe hinausgegangen —
  /// oder es ist mehrdeutig, ob er es ist.
  ///
  /// DIESELBE MEHRDEUTIGKEIT WIE BEIM RELAY, nur mit anderer Technik. Ein
  /// Funk-Versand ist erst fertig, wenn das letzte Haeppchen bestaetigt ist;
  /// reisst die Verbindung DANACH, aber bevor die Bestaetigung ankommt, hat
  /// die Gegenstelle den Umschlag trotzdem zusammengesetzt. Wer daraufhin auf
  /// den Relay wechselt, stellt zweimal zu.
  ///
  /// Ohne dieses Feld galt Regel 2 nur in eine Richtung — nachgemessen von
  /// einem Widerlegungsagenten am 27.07.2026.
  final bool inDerNaehe;

  @override
  String toString() => '${weg.name}: $grund';
}

/// Ein Weg, ueber den ein Umschlag hinausgehen kann.
abstract class Ausgang {
  /// Ob er GERADE benutzbar ist. Darf nicht blockieren.
  bool get bereit;

  /// Schickt. Wirft, wenn es nicht geklappt hat.
  Future<void> schicke(String an, Uint8List umschlag);
}

/// Entscheidet je Nachricht, welcher Weg genommen wird.
class Wegwahl {
  Wegwahl({
    required this.relay,
    required this.naehe,
    this.nurNahbereich = false,
  });

  final Ausgang relay;
  final Ausgang naehe;

  /// Der Schalter des Nutzers. Siehe Regel 3.
  final bool nurNahbereich;

  /// Schickt [umschlag] an [an] und sagt, worueber.
  ///
  /// [schonBeimRelay] ist das Gedaechtnis, das diese Klasse selbst nicht hat:
  /// dieser Umschlag war schon einmal draussen und ist trotzdem
  /// liegengeblieben. Fuer ihn ist die Naehe zu — aus demselben Grund, aus dem
  /// sie es unten nach einem Fehlschlag ist.
  ///
  /// WIRFT NICHT bei einem Netzproblem. Das ist die Vertragsregel des ganzen
  /// Kerns: Netzprobleme sind Zustaende, keine Ausnahmen. Wer sie hier
  /// wuerfe, zwaenge jede aufrufende Stelle in ein try/catch, das sie nicht
  /// sinnvoll behandeln kann.
  Future<Wegbescheid> schicke(String an, Uint8List umschlag,
      {bool schonBeimRelay = false, bool schonInDerNaehe = false}) async {
    // ignore: avoid_print
    print('BitDM-Weg: waehle — nurNahbereich=$nurNahbereich '
        'nahBereit=${naehe.bereit}');
    if (nurNahbereich) {
      // REGEL 3 GEGEN REGEL 2, und Regel 2 gewinnt.
      //
      // Der Schalter sagt "kein Server", und daran aendert sich nichts: der
      // Relay wird auch hier nicht angefasst. Aber die Naehe ist fuer diesen
      // Umschlag versperrt, und damit bleibt er liegen, bis der Schalter
      // wieder aus ist. Das ist unbequem und trotzdem richtig — die
      // Alternative waere eine moeglicherweise zweite Zustellung, und die
      // sieht der Empfaenger.
      if (schonBeimRelay) {
        return const Wegbescheid(
            Weg.liegt,
            'nur in der Naehe, aber dieser Umschlag war schon beim Relay — '
            'ueber die Naehe waere er moeglicherweise zweimal draussen',
            beimRelay: true);
      }
      if (!naehe.bereit) {
        return const Wegbescheid(
            Weg.liegt, 'nur in der Naehe, und niemand ist in Reichweite');
      }
      return _versuche(naehe, an, umschlag, Weg.naehe,
          sonst: 'nur in der Naehe, und die Uebertragung ging schief',
          inDerNaehe: true);
    }

    // REGEL 2 IN DER GEGENRICHTUNG. Sie stand hier lange nur einseitig da:
    // was beim Relay war, durfte nicht mehr ueber die Naehe — was in der
    // Naehe war, durfte sehr wohl noch ueber den Relay. Dieselbe doppelte
    // Zustellung, nur gespiegelt.
    if (schonInDerNaehe) {
      return const Wegbescheid(
          Weg.liegt,
          'dieser Umschlag war schon in der Naehe unterwegs — ueber den Relay '
          'darf er deshalb nicht mehr',
          inDerNaehe: true);
    }

    // REGEL 1. Erst wenn der Relay nicht kann, kommt die Naehe.
    if (relay.bereit) {
      final ueberRelay = await _versuche(relay, an, umschlag, Weg.relay,
          sonst: 'der Relay hat abgelehnt', beimRelay: true);
      if (ueberRelay.weg == Weg.relay) return ueberRelay;

      // REGEL 2, UND HIER SITZT DIE FALLE.
      //
      // Der Relay hat GEWORFEN. Das heisst nicht, dass die Nachricht nicht
      // angekommen ist — sie kann drueben liegen, und nur die Bestaetigung
      // ist verlorengegangen. Sie jetzt zusaetzlich ueber die Naehe zu
      // schicken hiesse, sie moeglicherweise zweimal zuzustellen.
      //
      // Deshalb: nach einem gescheiterten Versuch ueber den Relay wird NICHT
      // mehr gewechselt. Die Nachricht bleibt liegen und geht beim naechsten
      // Verbinden ueber den Relay hinaus — dort greift die Wiederholung ueber
      // die Nachrichtenkennung, und der Server erkennt eine doppelte.
      return Wegbescheid(
          Weg.liegt,
          '${ueberRelay.grund} — kein Wechsel auf die Naehe, weil die '
          'Nachricht schon unterwegs sein koennte',
          beimRelay: true);
    }

    // DERSELBE SATZ, EINEN VERSUCH SPAETER. Ohne diese Zeile hielte Regel 2
    // nur, solange die Wegwahl lebt: der Relay ist inzwischen ganz weg, die
    // Naehe waere bereit, und der Umschlag ginge ein zweites Mal hinaus —
    // diesmal mit dem Zeichen "kein Server war beteiligt".
    if (schonBeimRelay) {
      return const Wegbescheid(
          Weg.liegt,
          'kein Relay — und ueber die Naehe darf dieser Umschlag nicht mehr, '
          'er war dort schon einmal',
          beimRelay: true);
    }

    if (naehe.bereit) {
      return _versuche(naehe, an, umschlag, Weg.naehe,
          sonst: 'kein Relay, und die Naehe ging schief', inDerNaehe: true);
    }

    return const Wegbescheid(Weg.liegt, 'kein Weg offen');
  }

  Future<Wegbescheid> _versuche(
    Ausgang weg,
    String an,
    Uint8List umschlag,
    Weg art, {
    required String sonst,
    bool beimRelay = false,
    bool inDerNaehe = false,
  }) async {
    try {
      await weg.schicke(an, umschlag);
      return Wegbescheid(art, 'gegangen',
          beimRelay: beimRelay, inDerNaehe: inDerNaehe);
    } catch (e) {
      // AUCH IM FEHLERFALL vermerken, und das ist der ganze Punkt: gerade der
      // gescheiterte Versuch ist der mehrdeutige.
      //
      // DER TEXT DES FEHLERS GEHOERT DAZU, nicht nur sein Typ. Am 29.07.2026
      // blieb eine Nachricht liegen, und der Bescheid sagte
      // "(PlatformException)" — was daran scheiterte, stand in der Meldung,
      // die genau hier weggeworfen wurde. Diese Zeile ist der Unterschied
      // zwischen "es geht nicht" und "es geht nicht, WEIL".
      final text = e is Exception || e is Error ? '$e' : e.runtimeType.toString();
      return Wegbescheid(Weg.liegt, '$sonst: $text',
          beimRelay: beimRelay, inDerNaehe: inDerNaehe);
    }
  }
}
