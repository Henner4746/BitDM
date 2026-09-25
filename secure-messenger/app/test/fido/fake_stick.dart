// fake_stick.dart — ein nachgebauter Sicherheitsschluessel.
//
// WARUM DIESER AUFWAND
// Ein echter Titan laesst sich nicht in einen Testlauf einbauen, und die
// Fehler, die hier drohen, sehen am Geraet alle gleich aus: "Ungueltiger
// Parameter". Ob das an der CBOR-Reihenfolge lag, an der Auffuellung von AES,
// an der Laenge des Pruefwerts oder an einer verwechselten Feldnummer, sagt
// der Stick nicht.
//
// Deshalb steht hier die GEGENSEITE, gebaut nach der Spezifikation und nicht
// nach dem, was der Client tut. Sie rechnet dieselben Schritte unabhaengig
// nach: eigenes ECDH, eigenes AES, eigenes HMAC. Stimmt eine Byte-Reihenfolge
// nicht, ein Pruefwert nicht oder eine Feldnummer nicht, faellt das hier auf
// und nicht erst mit dem Stick in der Hand.
//
// Wo es geht, kodiert dieser Stick mit package:cbor statt mit unserem eigenen
// Kodierer — sonst wuerde ein Fehler im Kodierer beim Lesen wieder
// herausgekuerzt und niemandem auffallen.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/fido/ctap.dart';
import 'package:cbor/cbor.dart';
import 'package:cbor/simple.dart' as einfach;
import 'package:pointycastle/export.dart' as pc;

class FakeStick implements CtapTransport {
  FakeStick({
    this.pin = '123456',
    this.kannHmacSecret = true,
    this.hatPin = true,
  }) {
    _paar = _neuesPaar();
  }

  /// Die PIN, die dieser Stick fuer richtig haelt.
  final String pin;
  final bool kannHmacSecret;

  /// Veraenderlich: ein Test kann dem Stick nachtraeglich eine PIN geben —
  /// genau der Fall "Fach angelegt, danach PIN gesetzt".
  bool hatPin;

  late final pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> _paar;

  final Uint8List pinToken =
      Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xFF));

  /// Angelegte Zugaenge: Kennung → der interne Schluessel dazu.
  ///
  /// Aus diesem einen Schluessel leitet der Stick ZWEI ab, wie CTAP2 es fuer
  /// hmac-secret vorschreibt: CredRandomWithUV (Abfrage mit PIN-Nachweis)
  /// und CredRandomWithoutUV (ohne). Siehe [_credRandom].
  final Map<String, Uint8List> zugaenge = {};

  /// Gespeicherte Zugaenge (rk: true): "rpId|Nutzerkennung" → Kennung.
  ///
  /// Wie ein echter Stick fuehrt dieser je Dienst und Nutzerkennung nur
  /// EINEN gespeicherten Zugang; ein neuer ueberschreibt den alten, und der
  /// alte ist danach nicht mehr abrufbar. Das war der Fehler bis 25.09.2026.
  final Map<String, String> gespeichert = {};

  /// Wie oft der Nutzer den Stick beruehren musste.
  int beruehrungen = 0;

  /// Wie oft eine falsche PIN kam.
  int fehlversuche = 0;

  bool verbunden = false;
  bool getrennt = false;

  /// Was zuletzt hereinkam — fuer Tests, die die Anfrage selbst prüfen wollen.
  Map<Object?, Object?>? letzteAnfrage;

  static final Uint8List aaguid =
      Uint8List.fromList(List.generate(16, (i) => 0x40 + i));

  @override
  String get name => 'nachgebaut';

  @override
  Future<void> verbinde() async => verbunden = true;

  @override
  Future<void> trenne() async => getrennt = true;

  @override
  Future<Uint8List> sende(Uint8List befehl) async {
    if (!verbunden) {
      throw StateError('Es wurde gesendet, ohne vorher zu verbinden');
    }
    final cmd = befehl.first;
    final rest = Uint8List.sublistView(befehl, 1);
    final p = rest.isEmpty
        ? const <Object?, Object?>{}
        : (einfach.cbor.decode(rest) as Map).cast<Object?, Object?>();
    letzteAnfrage = p;

    try {
      return switch (cmd) {
        0x04 => _antwort(_getInfo()),
        0x06 => _antwort(_clientPin(p)),
        0x01 => _antwort(_makeCredential(p)),
        0x02 => _antwort(_getAssertion(p)),
        _ => Uint8List.fromList([0x11]), // Befehl unbekannt
      };
    } on CtapException catch (e) {
      return Uint8List.fromList([e.status]);
    }
  }

  Uint8List _antwort(CborValue inhalt) =>
      Uint8List.fromList([0x00, ...cborEncode(inhalt)]);

  // ---------------------------------------------------------------- getInfo

  CborValue _getInfo() => CborMap({
        const CborSmallInt(1): CborList([CborString('FIDO_2_0')]),
        const CborSmallInt(2): CborList([
          CborString('credProtect'),
          if (kannHmacSecret) CborString('hmac-secret'),
        ]),
        const CborSmallInt(3): CborBytes(aaguid),
        const CborSmallInt(4): CborMap({
          CborString('rk'): const CborBool(true),
          CborString('up'): const CborBool(true),
          CborString('clientPin'): CborBool(hatPin),
        }),
      });

  // -------------------------------------------------------------- clientPIN

  CborValue _clientPin(Map<Object?, Object?> p) {
    final unterbefehl = p[2];
    switch (unterbefehl) {
      case 0x01: // getPINRetries
        return CborMap({CborSmallInt(3): CborSmallInt(8 - fehlversuche)});

      case 0x02: // getKeyAgreement
        final pub = _paar.publicKey as pc.ECPublicKey;
        return CborMap({
          const CborSmallInt(1): CborMap({
            const CborSmallInt(1): const CborSmallInt(2),
            const CborSmallInt(3): const CborSmallInt(-25),
            const CborSmallInt(-1): const CborSmallInt(1),
            CborSmallInt(-2): CborBytes(_auf32(pub.Q!.x!.toBigInteger()!)),
            CborSmallInt(-3): CborBytes(_auf32(pub.Q!.y!.toBigInteger()!)),
          }),
        });

      case 0x05: // getPINToken
        final geheimnis = _gemeinsamesGeheimnis(p[3]);
        final hashEnc = _bytes(p[6]);
        final hash = _aes(geheimnis, hashEnc, verschluesseln: false);

        final erwartet = Uint8List.fromList(
            _sha256(Uint8List.fromList(utf8.encode(pin))).sublist(0, 16));
        if (!_gleich(hash, erwartet)) {
          fehlversuche++;
          throw const CtapException(0x31); // PIN falsch
        }
        fehlversuche = 0;
        return CborMap({
          const CborSmallInt(2):
              CborBytes(_aes(geheimnis, pinToken, verschluesseln: true)),
        });

      default:
        throw const CtapException(0x22);
    }
  }

  // --------------------------------------------------------- makeCredential

  CborValue _makeCredential(Map<Object?, Object?> p) {
    final clientDataHash = _bytes(p[1]);
    _pruefeBeglaubigung(p, clientDataHash, feld: 8, protokollFeld: 9);

    final erweiterungen = p[6];
    final willHmac = erweiterungen is Map &&
        erweiterungen.entries
            .any((e) => '${e.key}' == 'hmac-secret' && e.value == true);
    if (willHmac && !kannHmacSecret) {
      throw const CtapException(0x35); // Erweiterung unbekannt
    }

    beruehrungen++;

    final kennung = Uint8List.fromList(
        List.generate(32, (_) => _zufall.nextInt(256)));
    zugaenge[base64.encode(kennung)] = Uint8List.fromList(
        List.generate(32, (_) => _zufall.nextInt(256)));

    final rpId = _rpIdAus(p[2]);
    final optionen = p[7];
    final speichern = optionen is Map &&
        optionen.entries.any((e) => '${e.key}' == 'rk' && e.value == true);
    if (speichern) {
      final nutzer = p[3];
      final nutzerId = nutzer is Map
          ? base64.encode(_bytes(nutzer.entries
              .firstWhere((e) => '${e.key}' == 'id')
              .value))
          : '';
      final platz = '$rpId|$nutzerId';
      final alt = gespeichert[platz];
      if (alt != null) zugaenge.remove(alt);
      gespeichert[platz] = base64.encode(kennung);
    }
    final authData = BytesBuilder()
      ..add(_sha256(Uint8List.fromList(utf8.encode(rpId))))
      ..addByte(0xC5) // ED | AT | UV | UP
      ..add([0, 0, 0, 1]) // Zaehler
      ..add(aaguid)
      ..add([kennung.length >> 8, kennung.length & 0xFF])
      ..add(kennung)
      // Ein Platzhalter-Schluessel: der Client liest ihn nicht, aber er muss
      // im Bytestrom stehen, sonst stimmt die Laenge nicht.
      ..add(cborEncode(CborMap({
        const CborSmallInt(1): const CborSmallInt(2),
        const CborSmallInt(3): const CborSmallInt(-7),
        const CborSmallInt(-1): const CborSmallInt(1),
        CborSmallInt(-2): CborBytes(Uint8List(32)),
        CborSmallInt(-3): CborBytes(Uint8List(32)),
      })))
      ..add(cborEncode(CborMap({
        CborString('hmac-secret'): CborBool(willHmac),
      })));

    return CborMap({
      const CborSmallInt(1): CborString('none'),
      const CborSmallInt(2): CborBytes(authData.toBytes()),
      const CborSmallInt(3): CborMap({}),
    });
  }

  // ------------------------------------------------------------ getAssertion

  CborValue _getAssertion(Map<Object?, Object?> p) {
    final rpId = '${p[1]}';
    final clientDataHash = _bytes(p[2]);
    // CTAP2.0 getAssertion: ohne PIN-Nachweis ist die Abfrage auch bei einem
    // Stick MIT PIN erlaubt — dann eben ohne Nutzerpruefung (uv = 0).
    final uv = p[6] != null;
    if (uv) _pruefeBeglaubigung(p, clientDataHash, feld: 6, protokollFeld: 7);

    // Den gemeinten Zugang aus der Liste holen.
    final liste = p[3];
    if (liste is! List || liste.isEmpty) {
      throw const CtapException(0x36); // kein passender Zugang
    }
    final erster = liste.first;
    final kennung = _bytes((erster as Map)[
        erster.keys.firstWhere((k) => '$k' == 'id')]);
    final intern = zugaenge[base64.encode(kennung)];
    if (intern == null) throw const CtapException(0x36);

    beruehrungen++;

    final erweiterungen = p[4];
    Uint8List? ausgabe;
    if (erweiterungen is Map) {
      final hmac = erweiterungen[erweiterungen.keys
          .firstWhere((k) => '$k' == 'hmac-secret', orElse: () => null)];
      if (hmac is Map) {
        final geheimnis = _gemeinsamesGeheimnis(hmac[1]);
        final salzEnc = _bytes(hmac[2]);
        final salzAuth = _bytes(hmac[3]);

        // DER PRUEFWERT, an dem eine falsche Kuerzung auffliegt.
        final erwartet =
            Uint8List.fromList(_hmac(geheimnis, salzEnc).sublist(0, 16));
        if (!_gleich(salzAuth, erwartet)) {
          throw const CtapException(0x22); // ungueltiger Parameter
        }

        final salz = _aes(geheimnis, salzEnc, verschluesseln: false);
        if (salz.length != 32 && salz.length != 64) {
          throw const CtapException(0x22);
        }
        final roh = Uint8List.fromList(_hmac(
            _credRandom(intern, uv: uv), Uint8List.sublistView(salz, 0, 32)));
        ausgabe = _aes(geheimnis, roh, verschluesseln: true);
      }
    }

    final authData = BytesBuilder()
      ..add(_sha256(Uint8List.fromList(utf8.encode(rpId))))
      ..addByte((ausgabe == null ? 0x01 : 0x81) | (uv ? 0x04 : 0))
      // ED | UV (nur mit Nachweis) | UP, KEIN AT
      ..add([0, 0, 0, 2]);
    if (ausgabe != null) {
      authData.add(cborEncode(CborMap({
        CborString('hmac-secret'): CborBytes(ausgabe),
      })));
    }

    return CborMap({
      const CborSmallInt(1): CborMap({
        CborString('id'): CborBytes(kennung),
        CborString('type'): CborString('public-key'),
      }),
      const CborSmallInt(2): CborBytes(authData.toBytes()),
      const CborSmallInt(3): CborBytes(Uint8List(64)),
    });
  }

  // ------------------------------------------------------------------ Hilfen

  /// CredRandomWithUV bzw. CredRandomWithoutUV — zwei verschiedene Schluessel
  /// je Zugang. Ohne Pruefung ist es der gespeicherte selbst, mit Pruefung
  /// ein davon abgeleiteter. So bleibt der Test "fremder Stick mit derselben
  /// Kennung" gueltig, der nur den gespeicherten Schluessel austauscht.
  static Uint8List _credRandom(Uint8List intern, {required bool uv}) => uv
      ? Uint8List.fromList(_hmac(intern, Uint8List.fromList(utf8.encode('uv'))))
      : intern;

  /// Prueft den Nachweis, dass die PIN vorlag.
  void _pruefeBeglaubigung(Map<Object?, Object?> p, Uint8List clientDataHash,
      {required int feld, required int protokollFeld}) {
    final param = p[feld];
    if (!hatPin) {
      // Ohne gesetzte PIN darf gar kein Nachweis kommen.
      if (param != null) throw const CtapException(0x22);
      return;
    }
    if (param == null) throw const CtapException(0x27); // PIN wird verlangt
    if (p[protokollFeld] != 1) throw const CtapException(0x22);
    final erwartet =
        Uint8List.fromList(_hmac(pinToken, clientDataHash).sublist(0, 16));
    if (!_gleich(_bytes(param), erwartet)) {
      throw const CtapException(0x33); // Nachweis stimmt nicht
    }
  }

  String _rpIdAus(Object? rp) {
    if (rp is! Map) throw const CtapException(0x22);
    for (final e in rp.entries) {
      if ('${e.key}' == 'id') return '${e.value}';
    }
    throw const CtapException(0x22);
  }

  /// ECDH mit dem oeffentlichen Schluessel der Gegenseite, danach SHA-256
  /// ueber die X-Koordinate — genau wie pinUvAuthProtocol 1 es vorschreibt.
  Uint8List _gemeinsamesGeheimnis(Object? cose) {
    if (cose is! Map) throw const CtapException(0x22);
    Object? feld(int n) {
      for (final e in cose.entries) {
        if (e.key == n) return e.value;
      }
      return null;
    }

    final x = _bytes(feld(-2));
    final y = _bytes(feld(-3));
    if (x.length != 32 || y.length != 32) throw const CtapException(0x22);

    final punkt = _kurve.curve.createPoint(_alsZahl(x), _alsZahl(y));
    final abkommen = pc.ECDHBasicAgreement()
      ..init(_paar.privateKey as pc.ECPrivateKey);
    final gemeinsam = abkommen.calculateAgreement(pc.ECPublicKey(punkt, _kurve));
    return Uint8List.fromList(_sha256(_auf32(gemeinsam)));
  }

  /// AES-256-CBC, Startwert aus lauter Nullen, OHNE Auffuellung.
  static Uint8List _aes(Uint8List schluessel, Uint8List daten,
      {required bool verschluesseln}) {
    if (daten.length % 16 != 0) throw const CtapException(0x22);
    final maschine = pc.CBCBlockCipher(pc.AESEngine())
      ..init(verschluesseln,
          pc.ParametersWithIV(pc.KeyParameter(schluessel), Uint8List(16)));
    final aus = Uint8List(daten.length);
    for (var i = 0; i < daten.length; i += 16) {
      maschine.processBlock(daten, i, aus, i);
    }
    return aus;
  }

  static List<int> _sha256(Uint8List d) =>
      pc.SHA256Digest().process(d).toList();

  static List<int> _hmac(Uint8List schluessel, Uint8List daten) {
    final h = pc.HMac(pc.SHA256Digest(), 64)..init(pc.KeyParameter(schluessel));
    return h.process(daten).toList();
  }

  static bool _gleich(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List _bytes(Object? o) {
    if (o is Uint8List) return o;
    if (o is List<int>) return Uint8List.fromList(o);
    throw const CtapException(0x22);
  }

  static BigInt _alsZahl(Uint8List b) => BigInt.parse(
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16);

  static Uint8List _auf32(BigInt n) {
    final hex = n.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(List.generate(
        32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
  }

  static final _kurve = pc.ECCurve_secp256r1();
  static final _zufall = Random(1234); // fest, damit Laeufe vergleichbar sind

  static pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> _neuesPaar() {
    final r = pc.FortunaRandom()
      ..seed(pc.KeyParameter(Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)))));
    return (pc.ECKeyGenerator()
          ..init(pc.ParametersWithRandom(
              pc.ECKeyGeneratorParameters(_kurve), r)))
        .generateKeyPair();
  }
}
