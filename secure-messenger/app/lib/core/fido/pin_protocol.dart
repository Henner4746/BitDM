// pin_protocol.dart — der Schluesselaustausch mit dem Stick.
//
// WARUM ES DEN UEBERHAUPT BRAUCHT
// Zwischen Telefon und Stick liegt bei NFC die Luft und bei USB ein Kabel, an
// dem auch andere Programme lauschen koennen. Deshalb wandern PIN und
// Rechenergebnisse nicht im Klartext: beide Seiten einigen sich zuerst auf ein
// gemeinsames Geheimnis und verschluesseln damit.
//
// DER ABLAUF (pinUvAuthProtocol 1)
//   1. Der Stick nennt seinen oeffentlichen Schluessel (P-256).
//   2. Wir erzeugen ein eigenes Paar, rechnen ECDH und nehmen SHA-256 ueber
//      die X-Koordinate. Das ist das gemeinsame Geheimnis.
//   3. Die PIN wird als SHA-256(PIN)[0..15] verschluesselt hingeschickt; der
//      Stick antwortet mit einem verschluesselten Token.
//   4. Dieses Token beglaubigt danach jeden Befehl — per HMAC ueber die Daten.
//
// EINE STELLE, DIE LEICHT FALSCH GEHT
// AES laeuft hier OHNE Auffuellung und mit einem Startwert aus lauter Nullen.
// Das ist in CTAP2 so festgelegt und sieht nach einem Fehler aus, ist aber
// keiner: alle Eingaben sind Vielfache von 16 Byte, und die Einmaligkeit kommt
// aus dem gemeinsamen Geheimnis, das bei jeder Sitzung neu ausgehandelt wird.
// Wer hier PKCS7 einschaltet, haengt einen Block an, und der Stick lehnt ab.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:pointycastle/export.dart' as pc;

class PinProtocolV1 {
  PinProtocolV1._(this.gemeinsamesGeheimnis, this.eigenerCoseKey);

  /// 32 Byte. Verschluesselt alles, was zwischen Telefon und Stick laeuft.
  final Uint8List gemeinsamesGeheimnis;

  /// Unser oeffentlicher Schluessel im COSE-Format — der Stick braucht ihn,
  /// um dasselbe Geheimnis auszurechnen.
  final Map<int, Object> eigenerCoseKey;

  /// P-256 kommt von pointycastle, NICHT von package:cryptography.
  ///
  /// Dessen reine Dart-Umsetzung von ECDH wirft UnimplementedError — sie
  /// funktioniert nur dort, wo eine native Gegenstelle danebensteht. Auf dem
  /// Telefon waere das genauso gescheitert wie im Test; aufgefallen ist es nur,
  /// weil der Test es zuerst versucht hat.
  ///
  /// pointycastle ist ueber libsignal ohnehin schon eingebunden und rechnet in
  /// reinem Dart — auf jeder Plattform gleich.
  static final pc.ECDomainParameters _kurve = pc.ECCurve_secp256r1();

  /// Rohes AES-256-CBC: kein MAC, keine Auffuellung.
  static AesCbc get _rohesAes => AesCbc.with256bits(
        macAlgorithm: MacAlgorithm.empty,
        paddingAlgorithm: PaddingAlgorithm.zero,
      );

  /// Handelt das gemeinsame Geheimnis mit dem oeffentlichen Schluessel des
  /// Sticks aus.
  ///
  /// [stickCose] ist die COSE-Karte aus authenticatorClientPIN/getKeyAgreement:
  /// Feld -2 ist die X-, Feld -3 die Y-Koordinate, je 32 Byte.
  static Future<PinProtocolV1> aushandeln(
      Map<Object?, Object?> stickCose) async {
    final x = _bytes(stickCose[-2]);
    final y = _bytes(stickCose[-3]);
    if (x.length != 32 || y.length != 32) {
      throw const FormatException(
          'Der Stick nannte einen Schluessel mit falscher Groesse');
    }

    final erzeuger = pc.ECKeyGenerator()
      ..init(pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(_kurve), _zufallsquelle()));
    final paar = erzeuger.generateKeyPair();
    final eigenPriv = paar.privateKey;
    final eigenPub = paar.publicKey;

    // Den Punkt des Sticks aus seinen Koordinaten zusammensetzen.
    final stickPunkt = _kurve.curve.createPoint(_alsZahl(x), _alsZahl(y));

    final abkommen = pc.ECDHBasicAgreement()..init(eigenPriv);
    final gemeinsam =
        abkommen.calculateAgreement(pc.ECPublicKey(stickPunkt, _kurve));

    // In pinUvAuthProtocol 1 ist das Geheimnis SHA-256 ueber die X-Koordinate
    // des gemeinsamen Punktes — nicht der Punkt selbst.
    final roh = _auf32Bytes(gemeinsam);
    final geheimnis =
        Uint8List.fromList(const DartSha256().hashSync(roh).bytes);

    return PinProtocolV1._(geheimnis, {
      1: 2, // kty: EC2
      3: -25, // alg: ECDH-ES + HKDF-256
      -1: 1, // crv: P-256
      -2: _auf32Bytes(eigenPub.Q!.x!.toBigInteger()!),
      -3: _auf32Bytes(eigenPub.Q!.y!.toBigInteger()!),
    });
  }

  /// Verschluesselt. Die Laenge muss ein Vielfaches von 16 sein.
  Future<Uint8List> verschluessele(Uint8List klar) async {
    if (klar.length % 16 != 0) {
      throw ArgumentError('CTAP2 verschluesselt nur Vielfache von 16 Byte');
    }
    final box = await _rohesAes.encrypt(
      klar,
      secretKey: SecretKey(gemeinsamesGeheimnis),
      nonce: Uint8List(16), // Startwert aus lauter Nullen — so festgelegt
    );
    return Uint8List.fromList(box.cipherText);
  }

  Future<Uint8List> entschluessele(Uint8List geheim) async {
    if (geheim.length % 16 != 0) {
      throw ArgumentError('CTAP2 entschluesselt nur Vielfache von 16 Byte');
    }
    final klar = await _rohesAes.decrypt(
      SecretBox(geheim, nonce: Uint8List(16), mac: Mac.empty),
      secretKey: SecretKey(gemeinsamesGeheimnis),
    );
    return Uint8List.fromList(klar);
  }

  /// Beglaubigt Daten mit einem Schluessel — die ersten 16 Byte des HMAC.
  ///
  /// Auf 16 gekuerzt, weil pinUvAuthProtocol 1 es so verlangt. Fassung 2 nimmt
  /// die vollen 32; wer das verwechselt, bekommt eine Ablehnung ohne Hinweis.
  static Future<Uint8List> beglaubige(
      Uint8List schluessel, Uint8List daten) async {
    final mac = await Hmac.sha256()
        .calculateMac(daten, secretKey: SecretKey(schluessel));
    return Uint8List.fromList(mac.bytes.sublist(0, 16));
  }

  /// Der Pruefwert, mit dem ein Befehl beim Stick beglaubigt wird.
  Future<Uint8List> pinUvAuthParam(Uint8List pinToken, Uint8List daten) =>
      beglaubige(pinToken, daten);

  /// Die verschluesselte PIN, wie getPINToken sie erwartet.
  ///
  /// Uebertragen werden nur die ersten 16 Byte des SHA-256 der PIN — der Stick
  /// speichert selbst auch nicht mehr. Die PIN im Klartext verlaesst das
  /// Telefon nie.
  Future<Uint8List> verschluesselePinHash(String pin) async {
    final voll = const DartSha256().hashSync(utf8.encode(pin)).bytes;
    return verschluessele(Uint8List.fromList(voll.sublist(0, 16)));
  }

  static Uint8List _bytes(Object? o) {
    if (o is Uint8List) return o;
    if (o is List<int>) return Uint8List.fromList(o);
    throw const FormatException('erwartete Bytes');
  }

  static BigInt _alsZahl(Uint8List b) => BigInt.parse(
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16);

  /// Bringt eine Zahl auf genau 32 Byte.
  ///
  /// EINE FALLE, DIE FAST IMMER GUTGEHT: eine Koordinate kann mit einem
  /// Nullbyte beginnen. Die Zahlendarstellung laesst es weg, und man bekommt
  /// 31 Byte statt 32. Der Stick erwartet aber immer genau 32 — und ein zu
  /// kurzer Wert ergibt ein anderes gemeinsames Geheimnis.
  ///
  /// Das trifft etwa jeden 256. Schluessel. Ohne diese Auffuellung haette die
  /// Sperre also meistens funktioniert und gelegentlich nicht, ohne
  /// erkennbaren Grund.
  static Uint8List _auf32Bytes(BigInt n) {
    var hex = n.toRadixString(16);
    if (hex.length > 64) throw StateError('Koordinate zu gross fuer P-256');
    hex = hex.padLeft(64, '0');
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static pc.SecureRandom _zufallsquelle() {
    final r = pc.FortunaRandom();
    final saat =
        Uint8List.fromList(List.generate(32, (_) => _systemZufall.nextInt(256)));
    r.seed(pc.KeyParameter(saat));
    return r;
  }

  static final _systemZufall = Random.secure();
}
