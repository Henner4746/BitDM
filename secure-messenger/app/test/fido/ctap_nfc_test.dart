// ctap_nfc_test.dart — der Umgang mit dem Stick, ohne Stick.
//
// Geprueft wird die Verpackung: dass die richtigen Kommandos rausgehen, dass
// stueckweise Antworten wieder zusammengesetzt werden und dass Fehler des
// Sticks als solche ankommen. Ob ein bestimmter Stick hmac-secret kann, sagt
// nur er selbst — dafuer gibt es den Bildschirm in der App.

import 'dart:typed_data';

import 'package:bitdm/core/fido/ctap.dart';
import 'package:bitdm/core/fido/ctap_nfc.dart';
import 'package:cbor/simple.dart' as cbor;
import 'package:flutter_test/flutter_test.dart';

Uint8List b(List<int> l) => Uint8List.fromList(l);

/// Ein nachgestellter Stick, der vorbereitete Antworten liefert.
class FakeStick {
  FakeStick(this.antworten);
  final List<Uint8List> antworten;
  final gesendet = <Uint8List>[];
  var _i = 0;

  Future<Uint8List> sende(Uint8List apdu) async {
    gesendet.add(apdu);
    return antworten[_i++];
  }
}

/// Baut die Antwort auf authenticatorGetInfo, wie ein echter Stick sie schickt:
/// CTAP-Status 0x00, dann CBOR, dann das Statuswort 0x9000.
Uint8List getInfoAntwort({required List<String> erweiterungen}) {
  final inhalt = cbor.cbor.encode({
    1: ['FIDO_2_0', 'FIDO_2_1'],
    2: erweiterungen,
    3: List<int>.filled(16, 0xAB),
    4: {'rk': true, 'up': true, 'clientPin': false},
  });
  return b([0x00, ...inhalt, 0x90, 0x00]);
}

void main() {
  group('Anwendung waehlen', () {
    test('schickt SELECT mit der FIDO-Kennung', () async {
      final stick = FakeStick([b([0x90, 0x00])]);
      await CtapNfcTransport(stick.sende).verbinde();

      final apdu = stick.gesendet.single;
      expect(apdu.sublist(0, 4), [0x00, 0xA4, 0x04, 0x00]);
      expect(apdu[4], 8, reason: 'die Kennung ist acht Bytes lang');
      expect(apdu.sublist(5, 13), CtapNfcTransport.fidoAid);
    });

    test('meldet ein Statuswort, das nicht 9000 ist', () async {
      // 6A82 = "Anwendung nicht gefunden". Kommt, wenn man ein Telefon oder
      // eine Bezahlkarte statt eines Sticks anhaelt.
      final stick = FakeStick([b([0x6A, 0x82])]);
      expect(() => CtapNfcTransport(stick.sende).verbinde(),
          throwsA(isA<FormatException>()));
    });
  });

  group('Was kann der Stick', () {
    test('liest Fassungen, Erweiterungen und Eigenschaften', () async {
      final stick = FakeStick([
        getInfoAntwort(erweiterungen: ['credProtect', 'hmac-secret'])
      ]);
      final info = await Ctap2(CtapNfcTransport(stick.sende)).holeInfo();

      expect(info.versionen, ['FIDO_2_0', 'FIDO_2_1']);
      expect(info.erweiterungen, contains('hmac-secret'));
      expect(info.kannHmacSecret, isTrue);
      expect(info.kannResidentKey, isTrue);
      expect(info.aaguid, hasLength(16));
    });

    test('OHNE hmac-secret ist die App-Sperre nicht zu bauen', () async {
      // Der Fall, den es zu erkennen gilt: ein Stick, der zwar anmelden kann,
      // aber nichts berechnet. Er darf nicht als tauglich durchgehen.
      final stick = FakeStick([getInfoAntwort(erweiterungen: ['credProtect'])]);
      final info = await Ctap2(CtapNfcTransport(stick.sende)).holeInfo();
      expect(info.kannHmacSecret, isFalse);
    });

    test('schickt den Befehl 0x04 im richtigen Rahmen', () async {
      final stick = FakeStick([getInfoAntwort(erweiterungen: [])]);
      await Ctap2(CtapNfcTransport(stick.sende)).holeInfo();

      final apdu = stick.gesendet.single;
      expect(apdu.sublist(0, 4), [0x80, 0x10, 0x00, 0x00],
          reason: 'NFCCTAP_MSG');
      expect(apdu[4], 1, reason: 'ein Byte Inhalt');
      expect(apdu[5], 0x04, reason: 'authenticatorGetInfo');
    });
  });

  group('Stueckweise Antworten', () {
    test('werden vollstaendig zusammengesetzt', () async {
      // DER FEHLER, DEN DIESER TEST VERHINDERT: 0x61xx heisst "es liegt noch
      // mehr bereit". Wer das ignoriert, bekommt abgeschnittenes CBOR — und
      // zwar erst bei laengeren Antworten, also genau dann, wenn ein Stick
      // viele Erweiterungen kann.
      final voll = getInfoAntwort(
          erweiterungen: ['credProtect', 'hmac-secret', 'largeBlobKey']);
      final nutzlast = voll.sublist(0, voll.length - 2);
      final schnitt = nutzlast.length ~/ 2;

      final stick = FakeStick([
        b([...nutzlast.sublist(0, schnitt), 0x61, 0x20]),
        b([...nutzlast.sublist(schnitt), 0x90, 0x00]),
      ]);

      final info = await Ctap2(CtapNfcTransport(stick.sende)).holeInfo();
      expect(info.kannHmacSecret, isTrue);
      expect(stick.gesendet, hasLength(2));
      expect(stick.gesendet[1].sublist(0, 4), [0x00, 0xC0, 0x00, 0x00],
          reason: 'GET RESPONSE holt den Rest');
    });
  });

  group('Fehler des Sticks', () {
    test('kommen mit ihrer Bedeutung an', () async {
      for (final fall in {
        0x2F: 'Fehlversuche',
        0x31: 'falsch',
        0x35: 'Erweiterung',
        0x36: 'Zugang',
      }.entries) {
        final stick = FakeStick([b([fall.key, 0x90, 0x00])]);
        try {
          await Ctap2(CtapNfcTransport(stick.sende)).holeInfo();
          fail('haette werfen muessen bei 0x${fall.key.toRadixString(16)}');
        } on CtapException catch (e) {
          expect(e.status, fall.key);
          expect(e.bedeutung, contains(fall.value));
        }
      }
    });

    test('eine leere Antwort wird nicht als Erfolg gedeutet', () async {
      final stick = FakeStick([b([0x90, 0x00])]);
      expect(() => Ctap2(CtapNfcTransport(stick.sende)).holeInfo(),
          throwsA(isA<CtapException>()));
    });
  });
}
