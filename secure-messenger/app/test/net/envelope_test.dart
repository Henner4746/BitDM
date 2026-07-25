// envelope_test.dart — der Umschlag liest Bytes, die ein Angreifer formt.
//
// Was hier durchrutscht, landet ungeprueft in libsignals Parser. Deshalb wird
// nicht das Hin und Zurueck geprueft — das ist der leichte Teil — sondern
// alles, was NICHT durchkommen darf.

import 'dart:typed_data';

import 'package:bitdm/core/net/envelope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

Uint8List bytes(List<int> l) => Uint8List.fromList(l);

void main() {
  test('Hin und Zurueck', () {
    final u = Envelope(
      version: Envelope.currentVersion,
      messageType: CiphertextMessage.whisperType,
      ciphertext: bytes([1, 2, 3, 4]),
    );
    final zurueck = Envelope.fromBytes(u.toBytes());
    expect(zurueck.version, u.version);
    expect(zurueck.messageType, u.messageType);
    expect(zurueck.ciphertext, u.ciphertext);
  });

  test('der Kopf kostet genau zwei Bytes', () {
    final u = Envelope(
      version: Envelope.currentVersion,
      messageType: CiphertextMessage.prekeyType,
      ciphertext: bytes(List.filled(100, 9)),
    );
    expect(u.toBytes(), hasLength(102));
  });

  test('die Nummern sind DIE von libsignal, keine eigenen', () {
    // Eine eigene Nummerierung waere eine weitere Stelle, an der sich ein
    // Dreher verstecken kann.
    final u = Envelope(
      version: 1,
      messageType: CiphertextMessage.prekeyType,
      ciphertext: bytes([1]),
    );
    expect(u.toBytes()[1], CiphertextMessage.prekeyType);
    expect(u.startetSitzung, isTrue);

    final v = Envelope(
      version: 1,
      messageType: CiphertextMessage.whisperType,
      ciphertext: bytes([1]),
    );
    expect(v.startetSitzung, isFalse);
  });

  group('Was NICHT durchkommen darf', () {
    test('leer', () {
      expect(() => Envelope.fromBytes(bytes([])),
          throwsA(isA<EnvelopeFormatException>()));
    });

    test('nur der Kopf, ohne Inhalt', () {
      expect(
          () => Envelope.fromBytes(
              bytes([Envelope.currentVersion, CiphertextMessage.whisperType])),
          throwsA(isA<EnvelopeFormatException>()));
    });

    test('unbekannte Umschlagsfassung', () {
      // Wichtig: NICHT einfach weiterlesen. Eine kuenftige Fassung koennte den
      // Kopf anders aufbauen, und dann waeren die Bytes falsch gedeutet statt
      // abgelehnt.
      expect(
          () => Envelope.fromBytes(
              bytes([99, CiphertextMessage.whisperType, 1, 2])),
          throwsA(isA<EnvelopeFormatException>()));
    });

    test('unbekannte Nachrichtenart', () {
      for (final art in [0, 1, 4, 5, 255]) {
        expect(
            () => Envelope.fromBytes(
                bytes([Envelope.currentVersion, art, 1, 2])),
            throwsA(isA<EnvelopeFormatException>()),
            reason: 'Art $art haette abgelehnt werden muessen');
      }
    });

    test('senderKeyType wird abgelehnt', () {
      // Gibt es in libsignal, aber nicht in BitDM — es gibt keine Gruppen.
      // Ein Umschlag, der ihn ankuendigt, kommt nicht von einem BitDM-Client.
      expect(
          () => Envelope.fromBytes(bytes(
              [Envelope.currentVersion, CiphertextMessage.senderKeyType, 1])),
          throwsA(isA<EnvelopeFormatException>()));
    });
  });

  test('fromBytes liefert eine SICHT auf den Puffer, keine Kopie', () {
    // Kein Mangel, sondern eine bewusste Ersparnis: bei jeder Nachricht eine
    // Kopie anzulegen waere Arbeit fuer nichts. Die Folge muss man aber kennen
    // — und genau deshalb kopiert Envelope.decrypt() vor dem Parsen, statt
    // libsignal auf einem Puffer arbeiten zu lassen, den der Aufrufer noch in
    // der Hand hat.
    final roh = bytes(
        [Envelope.currentVersion, CiphertextMessage.whisperType, 10, 20, 30]);
    final u = Envelope.fromBytes(roh);
    expect(u.ciphertext, [10, 20, 30]);

    roh[2] = 99;
    expect(u.ciphertext[0], 99,
        reason: 'die Sicht zeigt auf denselben Speicher — wenn dieser Test '
            'faellt, ist die Kopie in decrypt() ueberfluessig geworden');
  });
}
