// pin_protocol_test.dart — der Schluesselaustausch mit dem Stick.
//
// Ohne Stick laesst sich nicht prüfen, ob ein echter Titan die Antworten
// akzeptiert. Prüfen laesst sich aber alles, was auf UNSERER Seite passiert —
// und dort sitzen die Fehler, die man am Geraet nur als "ungueltiger
// Parameter" zu sehen bekaeme.

import 'dart:typed_data';

import 'package:bitdm/core/fido/ctap_cbor.dart';
import 'package:bitdm/core/fido/pin_protocol.dart';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

Uint8List b(List<int> l) => Uint8List.fromList(l);

/// Baut den COSE-Schluessel, den ein Stick auf getKeyAgreement schickt.
final pc.ECDomainParameters kurve = pc.ECCurve_secp256r1();

pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> _neuesPaar() {
  final r = pc.FortunaRandom()
    ..seed(pc.KeyParameter(Uint8List.fromList(
        List.generate(32, (_) => Random.secure().nextInt(256)))));
  return (pc.ECKeyGenerator()
        ..init(pc.ParametersWithRandom(pc.ECKeyGeneratorParameters(kurve), r)))
      .generateKeyPair();
}

Uint8List _bytes32(BigInt n) {
  final hex = n.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList(List.generate(
      32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
}

Future<(Map<Object?, Object?>, pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey>)> stickSchluessel() async {
  final paar = _neuesPaar();
  final pub = paar.publicKey as pc.ECPublicKey;
  return (
    <Object?, Object?>{
      1: 2,
      3: -25,
      -1: 1,
      -2: _bytes32(pub.Q!.x!.toBigInteger()!),
      -3: _bytes32(pub.Q!.y!.toBigInteger()!),
    },
    paar,
  );
}

void main() {
  group('Gemeinsames Geheimnis', () {
    test('BEIDE Seiten kommen auf dasselbe', () async {
      // Der eigentliche Beweis: unser Ergebnis muss mit dem uebereinstimmen,
      // das der Stick unabhaengig ausrechnet. Kommt hier Verschiedenes heraus,
      // schlaegt spaeter jeder Befehl fehl — und die Meldung sagt nur "PIN
      // falsch", obwohl die PIN stimmt.
      final (stickCose, stickPaar) = await stickSchluessel();
      final pin = await PinProtocolV1.aushandeln(stickCose);

      // Die Gegenrechnung, wie der Stick sie machen wuerde: SEIN privater
      // Schluessel mit UNSEREM oeffentlichen.
      final unsereX = pin.eigenerCoseKey[-2]! as Uint8List;
      final unsereY = pin.eigenerCoseKey[-3]! as Uint8List;
      final unserPunkt = kurve.curve.createPoint(
          BigInt.parse(
              unsereX.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
              radix: 16),
          BigInt.parse(
              unsereY.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
              radix: 16));

      final abkommen = pc.ECDHBasicAgreement()
        ..init(stickPaar.privateKey as pc.ECPrivateKey);
      final gemeinsam =
          abkommen.calculateAgreement(pc.ECPublicKey(unserPunkt, kurve));

      final erwartet =
          const DartSha256().hashSync(_bytes32(gemeinsam)).bytes;

      expect(pin.gemeinsamesGeheimnis, erwartet,
          reason: 'beide Seiten muessen auf dasselbe Geheimnis kommen — sonst '
              'schlaegt spaeter jeder Befehl fehl, und die Meldung sagt nur '
              '"PIN falsch", obwohl die PIN stimmt');
      expect(pin.gemeinsamesGeheimnis, hasLength(32));
    });

    test('unser COSE-Schluessel hat die Felder, die der Stick erwartet',
        () async {
      final (stick, _) = await stickSchluessel();
      final pin = await PinProtocolV1.aushandeln(stick);

      expect(pin.eigenerCoseKey[1], 2, reason: 'kty: EC2');
      expect(pin.eigenerCoseKey[3], -25, reason: 'alg: ECDH-ES+HKDF-256');
      expect(pin.eigenerCoseKey[-1], 1, reason: 'crv: P-256');
      expect(pin.eigenerCoseKey[-2], hasLength(32));
      expect(pin.eigenerCoseKey[-3], hasLength(32));
    });

    test('ein Schluessel mit falscher Groesse wird abgelehnt', () async {
      expect(
          () => PinProtocolV1.aushandeln({
                -2: b(List.filled(31, 1)),
                -3: b(List.filled(32, 2)),
              }),
          throwsA(isA<FormatException>()));
    });
  });

  group('Verschluesseln', () {
    late PinProtocolV1 pin;
    setUp(() async {
      final (stick, _) = await stickSchluessel();
      pin = await PinProtocolV1.aushandeln(stick);
    });

    test('Hin und Zurueck', () async {
      final klar = b(List.generate(32, (i) => i));
      expect(await pin.entschluessele(await pin.verschluessele(klar)), klar);
    });

    test('KEINE Auffuellung — die Laenge bleibt gleich', () async {
      // DER FEHLER, DEN DAS ABFAENGT: mit PKCS7 kaeme ein ganzer Block dazu,
      // und der Stick lehnt die Anfrage ab. Ohne diesen Test faellt das erst
      // am Geraet auf, mit einer nichtssagenden Meldung.
      for (final n in [16, 32, 48, 64]) {
        final aus = await pin.verschluessele(b(List.filled(n, 7)));
        expect(aus, hasLength(n), reason: 'bei $n Byte Eingabe');
      }
    });

    test('krumme Laengen werden abgelehnt statt still aufgefuellt', () async {
      expect(() => pin.verschluessele(b(List.filled(17, 1))),
          throwsArgumentError);
      expect(() => pin.entschluessele(b(List.filled(20, 1))),
          throwsArgumentError);
    });

    test('gleiche Eingabe ergibt gleiche Ausgabe', () async {
      // Folgt aus dem Startwert aus lauter Nullen. Das ist hier richtig — die
      // Einmaligkeit kommt aus dem gemeinsamen Geheimnis, das je Sitzung neu
      // ausgehandelt wird. Der Test haelt fest, dass es Absicht ist.
      final e = b(List.filled(32, 3));
      expect(await pin.verschluessele(e), await pin.verschluessele(e));
    });

    test('zwei Sitzungen ergeben verschiedene Ausgaben', () async {
      final (stick2, _) = await stickSchluessel();
      final pin2 = await PinProtocolV1.aushandeln(stick2);
      final e = b(List.filled(32, 3));
      expect(await pin.verschluessele(e), isNot(await pin2.verschluessele(e)));
    });
  });

  group('Beglaubigen', () {
    test('sind die ERSTEN 16 Byte des HMAC, nicht alle 32', () async {
      // pinUvAuthProtocol 1 kuerzt auf 16. Fassung 2 nimmt die vollen 32; wer
      // das verwechselt, bekommt eine Ablehnung ohne Hinweis.
      final schluessel = b(List.filled(32, 0xAB));
      final daten = b(List.filled(32, 0xCD));

      final gekuerzt = await PinProtocolV1.beglaubige(schluessel, daten);
      expect(gekuerzt, hasLength(16));

      final voll = await Hmac.sha256()
          .calculateMac(daten, secretKey: SecretKey(schluessel));
      expect(gekuerzt, voll.bytes.sublist(0, 16));
    });
  });

  group('PIN', () {
    test('nur die ersten 16 Byte des Hashes gehen raus', () async {
      // Die PIM im Klartext verlaesst das Telefon nie. Der Stick speichert
      // selbst auch nicht mehr als diese 16 Byte.
      final (stick, _) = await stickSchluessel();
      final pin = await PinProtocolV1.aushandeln(stick);

      final verschluesselt = await pin.verschluesselePinHash('123456');
      expect(verschluesselt, hasLength(16));

      final zurueck = await pin.entschluessele(verschluesselt);
      final erwartet =
          const DartSha256().hashSync('123456'.codeUnits).bytes.sublist(0, 16);
      expect(zurueck, erwartet);
    });

    test('die PIN selbst taucht nirgends in den Bytes auf', () async {
      final (stick, _) = await stickSchluessel();
      final pin = await PinProtocolV1.aushandeln(stick);
      final aus = await pin.verschluesselePinHash('geheim1234');
      expect(String.fromCharCodes(aus).contains('geheim'), isFalse);
    });
  });

  group('Das Zusammenspiel mit kanonischem CBOR', () {
    test('der COSE-Schluessel wird richtig sortiert kodiert', () async {
      // Der Stick rechnet ueber genau diese Bytes. Steht ein Feld falsch,
      // stimmt sein Pruefwert nicht mit unserem ueberein.
      final (stick, _) = await stickSchluessel();
      final pin = await PinProtocolV1.aushandeln(stick);
      final bytes = CtapCbor.kodiere(pin.eigenerCoseKey);

      expect(bytes[0], 0xa5, reason: 'fuenf Felder');
      expect(bytes[1], 0x01, reason: 'kty zuerst');
      expect(bytes[3], 0x03, reason: 'dann alg');
      expect(bytes.indexOf(0x20), greaterThan(3),
          reason: 'negative Felder kommen danach');
    });
  });
}
