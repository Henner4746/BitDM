// payload_neue_arten_test.dart — Reaktion, Bearbeitung, Widerruf und der
// Antwortbezug auf der Leitung.
//
// Alles hier kommt im Betrieb von DRAUSSEN: aus einer entschluesselten
// Nachricht, also echt von der Gegenstelle — die aber fehlerhaft oder
// boesartig sein kann. Deshalb stehen hier vor allem Faelle, die abgewiesen
// werden muessen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/net/payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// Baut Bytes von Hand, wie sie ein veraenderter Client schicken koennte.
Uint8List roh(int art, Map<String, Object?> json) {
  final inhalt = [art, ...utf8.encode(jsonEncode(json)), 0x80];
  final rest = inhalt.length % Payload.blockSize;
  return Uint8List.fromList(
      [...inhalt, ...List.filled(rest == 0 ? 0 : Payload.blockSize - rest, 0)]);
}

void main() {
  final t = DateTime.utc(2026, 9, 25, 12);
  final ms = t.millisecondsSinceEpoch;

  test('DIE NEUEN ARTEN HABEN FESTE NUMMERN', () {
    // Die Zahlen duerfen nie umgedeutet werden: eine alte App verwirft 9 bis
    // 11 als "unbekannte Art", eine neue muss sie genau so lesen.
    expect(PayloadKind.reaktion.code, 9);
    expect(PayloadKind.bearbeitung.code, 10);
    expect(PayloadKind.widerruf.code, 11);
  });

  test('RUNDLAUF: jede neue Art und der Antwortbezug kommen heil zurueck', () {
    for (final p in [
      Payload.text('m2', 'ja', t, antwortAuf: 'm1'),
      Payload.anhang('m3', '{}', t, antwortAuf: 'm1'),
      Payload.reaktion('r1', 'm1', '👍🏽', t),
      Payload.reaktion('r2', 'm1', '', t),
      Payload.bearbeitung('e1', 'm1', 'neu', t),
      Payload.widerruf('w1', 'm1', t),
    ]) {
      final zurueck = Payload.fromBytes(p.toBytes());
      expect(zurueck.kind, p.kind);
      expect(zurueck.text, p.text);
      expect(zurueck.refs, p.refs);
      expect(zurueck.antwortAuf, p.antwortAuf);
    }
  });

  test('EIN UNTAUGLICHER ANTWORTBEZUG FAELLT WEG, DIE NACHRICHT BLEIBT', () {
    final p = Payload.fromBytes(
        roh(1, {'id': 'm2', 't': ms, 'x': 'hallo', 'a': '../../etwas'}));
    expect(p.text, 'hallo');
    expect(p.antwortAuf, isNull);
  });

  group('WAS ABGEWIESEN WIRD', () {
    void abgewiesen(int art, Map<String, Object?> json) => expect(
        () => Payload.fromBytes(roh(art, {'id': 'x1', 't': ms, ...json})),
        throwsA(isA<PayloadFormatException>()));

    test('eine Reaktion ohne Ziel oder mit zwei Zielen', () {
      abgewiesen(9, {'x': '👍'});
      abgewiesen(9, {'x': '👍', 'r': ['m1', 'm2']});
    });

    test('eine Reaktion auf eine Kennung, die keine ist', () {
      abgewiesen(9, {'x': '👍', 'r': ['../m1']});
    });

    test('eine "Reaktion", die ein Aufsatz ist', () {
      abgewiesen(9, {'x': 'a' * (Payload.reaktionMaxBytes + 1), 'r': ['m1']});
      abgewiesen(9, {'x': 'zwei worte', 'r': ['m1']});
    });

    test('eine leere Bearbeitung — dafuer gibt es den Widerruf', () {
      abgewiesen(10, {'r': ['m1']});
      abgewiesen(10, {'x': '', 'r': ['m1']});
    });

    test('ein Widerruf fuer den halben Verlauf', () {
      abgewiesen(11, {'r': ['m1', 'm2', 'm3']});
    });

    test('ein Text, der keine Zeichenkette ist', () {
      abgewiesen(1, {'x': 42});
    });
  });
}
