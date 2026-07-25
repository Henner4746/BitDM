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

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

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

  /// Dieselben Zahlen wie [CiphertextMessage.whisperType] (2, laufende
  /// Sitzung) und [CiphertextMessage.prekeyType] (3, Sitzungsaufbau).
  /// Absichtlich keine eigene Nummerierung — eine Uebersetzungstabelle waere
  /// eine weitere Stelle, an der sich ein Dreher verstecken kann.
  final int messageType;

  final Uint8List ciphertext;

  const Envelope({
    required this.version,
    required this.messageType,
    required this.ciphertext,
  });

  factory Envelope.of(CiphertextMessage message) => Envelope(
        version: currentVersion,
        messageType: message.getType(),
        ciphertext: message.serialize(),
      );

  bool get startetSitzung => messageType == CiphertextMessage.prekeyType;

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
    if (art != CiphertextMessage.whisperType &&
        art != CiphertextMessage.prekeyType) {
      throw EnvelopeFormatException('unbekannte Nachrichtenart $art');
    }
    return Envelope(
      version: version,
      messageType: art,
      ciphertext: Uint8List.sublistView(roh, headerLength),
    );
  }

  /// Entschluesselt den Inhalt mit der passenden Lesart.
  ///
  /// Der Sitzungszustand aendert sich dabei — der Aufrufer MUSS danach
  /// festschreiben, sonst ist der Ratchet nach einem Absturz aus dem Tritt.
  Future<Uint8List> decrypt(SessionCipher cipher) async {
    // Uint8List.sublistView teilt sich den Speicher mit dem Original.
    // libsignal parst hier weiter, deshalb eine eigenstaendige Kopie — sonst
    // haengt das Ergebnis an einem Puffer, den der Aufrufer noch besitzt.
    final bytes = Uint8List.fromList(ciphertext);
    return startetSitzung
        ? cipher.decrypt(PreKeySignalMessage(bytes))
        : cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
  }
}
