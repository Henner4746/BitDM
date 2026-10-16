// envelope.dart — der Umschlag um den Chiffretext.
//
// WARUM ES DEN BRAUCHT
// libsignal erzeugt zwei verschiedene Nachrichtenarten: eine, die eine Sitzung
// eroeffnet (PreKeySignalMessage), und eine, die in einer laufenden Sitzung
// weiterschreibt (SignalMessage). Der Empfaenger muss VOR dem Entschluesseln
// wissen, welche er vor sich hat — die beiden werden unterschiedlich gelesen.
//
// In den serialisierten Bytes steht das nicht drin. libsignal traegt dort nur
// die Protokollfassung; die Art gehoert nach Signals eigenem Entwurf in den
// Umschlag der Transportschicht. Genau den fuellt diese Datei.
//
// WARUM NICHT EINFACH EIN FELD IM RELAY-PROTOKOLL
// Das waere einfacher gewesen, haette dem Server aber verraten, welche
// Nachricht eine Sitzung eroeffnet — also wann zwei Leute zum ersten Mal
// miteinander sprechen. Der Server soll ausdruecklich nur undurchsichtige
// Bloecke sehen. Zwei Bytes im Umschlag kosten nichts und halten diese Grenze
// sauber.
//
// EHRLICH DAZUGESAGT: Die zwei Bytes sind selbst NICHT verschluesselt — sie
// stehen vor dem Chiffretext. Wer den Datenstrom mitliest, sieht daran, dass
// hier eine Sitzung beginnt. Verstecken liesse sich das nur mit einer
// zusaetzlichen Verschlusselungsschicht zwischen den Geraeten, und die haette
// wieder ihr eigenes Schluesselproblem. Was hier gewonnen ist: der RELAY, also
// der Rechner, dem man am wenigsten traut, muss die Bytes nicht auswerten und
// speichert sie nicht getrennt.

import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

class EnvelopeFormatException implements Exception {
  final String grund;
  const EnvelopeFormatException(this.grund);
  @override
  String toString() => 'EnvelopeFormatException: $grund';
}

/// Aufbau: `[Fassung][Art][Chiffretext ...]`
class Envelope {
  /// Fassung des Umschlags, nicht des Signal-Protokolls.
  ///
  /// Kostet ein Byte und erspaert spaeter eine Rateaktion: kommt eine Fassung
  /// an, die diese App nicht kennt, kann sie das sagen, statt die Bytes falsch
  /// zu deuten.
  static const int currentVersion = 1;

  static const int headerLength = 2;

  final int version;

  /// Dieselben Zahlen wie libsignals [CiphertextMessageType]: 2 (`signal`,
  /// laufende Sitzung) und 3 (`preKey`, Sitzungsaufbau). Absichtlich keine
  /// eigene Nummerierung — eine Uebersetzungstabelle waere eine weitere
  /// Stelle, an der sich ein Dreher verstecken kann. Die Nummern sind seit 1.x
  /// dieselben; die offizielle libsignal (ab 2.0.0) benutzt sie genauso.
  final int messageType;

  final Uint8List ciphertext;

  const Envelope({
    required this.version,
    required this.messageType,
    required this.ciphertext,
  });

  factory Envelope.of(CiphertextMessage message) {
    final art = message.type;
    // Nur die beiden Arten einer Zweiersitzung. Sender-Key und Klartext
    // erzeugt BitDM nie; kaeme hier eine an, waere das ein Programmfehler,
    // der nicht still auf die Leitung gehen soll.
    if (art != CiphertextMessageType.signal &&
        art != CiphertextMessageType.preKey) {
      throw EnvelopeFormatException('nicht versendbare Art ${art.value}');
    }
    return Envelope(
      version: currentVersion,
      messageType: art.value,
      ciphertext: message.ciphertext,
    );
  }

  bool get startetSitzung => messageType == CiphertextMessageType.preKey.value;

  Uint8List toBytes() {
    final b = Uint8List(headerLength + ciphertext.length)
      ..[0] = version
      ..[1] = messageType
      ..setRange(headerLength, headerLength + ciphertext.length, ciphertext);
    return b;
  }

  /// Liest einen Umschlag von der Leitung.
  ///
  /// Wirft bei allem, was nicht passt. Diese Bytes kommen vom Server und
  /// koennen von einem Angreifer beliebig geformt sein — hier darf nichts
  /// durchrutschen und nichts abstuerzen.
  static Envelope fromBytes(Uint8List roh) {
    if (roh.length <= headerLength) {
      throw const EnvelopeFormatException('Umschlag ohne Inhalt');
    }
    final version = roh[0];
    if (version != currentVersion) {
      throw EnvelopeFormatException(
          'Umschlagsfassung $version ist dieser App unbekannt');
    }
    final art = roh[1];
    if (art != CiphertextMessageType.signal.value &&
        art != CiphertextMessageType.preKey.value) {
      throw EnvelopeFormatException('unbekannte Nachrichtenart $art');
    }
    return Envelope(
      version: version,
      messageType: art,
      ciphertext: Uint8List.sublistView(roh, headerLength),
    );
  }

  /// Entschluesselt den Inhalt.
  ///
  /// [von] ist das GERAET der Gegenstelle (Adresse und Geraetenummer), nicht
  /// nur die Adresse — die Sitzung gehoert zum Geraetepaar.
  ///
  /// Der Sitzungszustand aendert sich dabei — der Aufrufer MUSS danach
  /// festschreiben, BEVOR er den Klartext verarbeitet, sonst ist der Ratchet
  /// nach einem Absturz aus dem Tritt (Vertrag der Anbindung,
  /// stores/session_store.dart).
  Future<Uint8List> decrypt(SessionCipher cipher, ProtocolAddress von) async {
    // Uint8List.sublistView teilt sich den Speicher mit dem Original.
    // Eine eigenstaendige Kopie, damit das Ergebnis nicht an einem Puffer
    // haengt, den der Aufrufer noch besitzt.
    return cipher.decrypt(
      von,
      CiphertextMessage(
        type: CiphertextMessageType.fromValue(messageType),
        ciphertext: Uint8List.fromList(ciphertext),
      ),
    );
  }
}
