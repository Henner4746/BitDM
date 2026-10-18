// payload_listenstempel_test.dart — die Listenstempel und die Art 20 auf der
// Leitung (docs/GERAETEABMELDUNG.md §12.3 und §12.5 b).
//
// Die Stempel entscheiden, wem der Kern glaubt. Ein kaputter Stempel darf
// deshalb nicht still zu "kein Stempel" werden — das waere fuer den Kern
// "Fassung vor 2.0.1" und damit ein anderer Fall.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List roh(int art, Map<String, Object?> json) {
  final inhalt = [art, ...utf8.encode(jsonEncode(json)), 0x80];
  final rest = inhalt.length % Payload.blockSize;
  return Uint8List.fromList(
      [...inhalt, ...List.filled(rest == 0 ? 0 : Payload.blockSize - rest, 0)]);
}

void main() {
  final t = DateTime.utc(2026, 10, 18, 12);
  final ms = t.millisecondsSinceEpoch;
  final lh = base64.encode(List.filled(12, 7));
  final gs = base64.encode(List.filled(64, 9));

  test('DIE ART 20 HAT IHRE FESTE NUMMER', () {
    expect(PayloadKind.geraeteliste.code, 20);
  });

  test('RUNDLAUF: Stempel und Nachweis kommen heil zurueck, alles andere bleibt',
      () {
    final p = Payload.text('m1', 'hallo', t, antwortAuf: 'm0').gestempelt(
        listenEpoche: 3, listenHash: lh, kenntEpoche: 2, sitzungsNachweis: gs);
    final z = Payload.fromBytes(p.toBytes());
    expect(z.messageId, 'm1');
    expect(z.text, 'hallo');
    expect(z.antwortAuf, 'm0');
    expect(z.sentAt, t);
    expect(z.listenEpoche, 3);
    expect(z.listenHash, lh);
    expect(z.kenntEpoche, 2);
    expect(z.sitzungsNachweis, gs);
  });

  test('OHNE STEMPEL ZEICHEN FUER ZEICHEN WIE VORHER', () {
    // Ein Relay ohne Listen: dann stempelt der Kern nichts, und eine App vor
    // 2.0.1 sieht genau die Bytes, die sie kennt.
    final p = Payload.text('m1', 'hallo', t);
    expect(p.gestempelt().toBytes(), p.toBytes());
    final z = Payload.fromBytes(p.toBytes());
    expect([z.listenEpoche, z.listenHash, z.kenntEpoche, z.sitzungsNachweis],
        everyElement(isNull));
  });

  test('ke = 0 HEISST "KEINE LISTE BEKANNT" und ist erlaubt', () {
    expect(Payload.fromBytes(roh(1, {'id': 'm', 't': ms, 'x': 'a', 'ke': 0}))
        .kenntEpoche, 0);
  });

  test('DIE LISTE ALS NACHRICHT: Rundlauf und Rohform', () {
    final liste = {'liste': '{"a":1}', 'sig_identitaet': 'x', 'sig_geraet': 'y'};
    final z = Payload.fromBytes(Payload.geraeteliste('l1', liste, t).toBytes());
    expect(z.kind, PayloadKind.geraeteliste);
    expect(z.geraetelisteRoh, liste);
    expect(Payload.text('m', '{}', t).geraetelisteRoh, isNull,
        reason: 'nur die Art 20 traegt eine Liste');
    expect(
        Payload.fromBytes(roh(20, {'id': 'l', 't': ms, 'x': '[1,2]'}))
            .geraetelisteRoh,
        isNull,
        reason: 'kein Objekt — keine Liste, aber auch kein Absturz');
  });

  test('WAS DIE GERAETESCHLUESSEL UNTERSCHREIBEN — Zeichen fuer Zeichen', () {
    // DIESELBE ZEICHENKETTE steht in server/test_relay.py
    // (test_spk_nachricht_ist_die_der_app). Weicht eine Seite ab, scheitert
    // jede Anmeldung mit Signatur an 403 — mit einer Meldung, die nicht auf
    // ein Zeilenende zeigt.
    expect(utf8.decode(spkNachricht('ABCD', 7, 42, 'BQ==')),
        'BitDM-Prekey-v1\nABCD\n7\n42\nBQ==');
    expect(
        utf8.decode(sitzungsNachricht(
          absender: 'ABCD',
          absenderGeraet: 3,
          empfaenger: 'EFGH',
          empfaengerGeraet: 1,
          basisschluessel: [5, 0, 1],
        )),
        'BitDM-Sitzung-v1\nABCD\n3\nEFGH\n1\nBQAB');
    expect(listenKurzHash('abc'), 'ungWv48Bz+pBQUDe',
        reason: 'die ersten 12 Byte von SHA-256("abc")');
  });

  group('WAS ABGEWIESEN WIRD', () {
    void abgewiesen(int art, Map<String, Object?> extra) => expect(
        () => Payload.fromBytes(
            roh(art, {'id': 'm', 't': ms, 'x': 'a', ...extra})),
        throwsA(isA<PayloadFormatException>()),
        reason: '$extra');

    test('eine Epoche, die keine ist', () {
      abgewiesen(1, {'le': 0, 'lh': lh});
      abgewiesen(1, {'le': -1, 'lh': lh});
      abgewiesen(1, {'le': '3', 'lh': lh});
      abgewiesen(1, {'le': 1.5, 'lh': lh});
      abgewiesen(1, {'le': 9007199254740993, 'lh': lh});
    });

    test('Epoche und Hash nur zusammen', () {
      abgewiesen(1, {'le': 3});
      abgewiesen(1, {'lh': lh});
    });

    test('ein Hash mit falscher Laenge oder kein base64', () {
      abgewiesen(1, {'le': 3, 'lh': base64.encode(List.filled(11, 1))});
      abgewiesen(1, {'le': 3, 'lh': base64.encode(List.filled(32, 1))});
      abgewiesen(1, {'le': 3, 'lh': '!!!!!!!!!!!!!!!!'});
      abgewiesen(1, {'le': 3, 'lh': 12});
    });

    test('eine bekannte Epoche, die keine ist', () {
      abgewiesen(1, {'ke': -1});
      abgewiesen(1, {'ke': 'zwei'});
    });

    test('ein Nachweis, der keine Signatur sein kann', () {
      abgewiesen(1, {'gs': base64.encode(List.filled(63, 1))});
      abgewiesen(1, {'gs': 'keine Signatur'});
      abgewiesen(1, {'gs': 64});
    });

    test('eine Liste ohne Inhalt', () {
      expect(() => Payload.fromBytes(roh(20, {'id': 'l', 't': ms, 'x': ''})),
          throwsA(isA<PayloadFormatException>()));
    });
  });
}
