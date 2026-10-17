// geraeteliste.dart — die signierte Liste der Geraete einer Identitaet.
//
// WARUM ES SIE GIBT: alle Geraete einer Adresse teilen den
// Identitaetsschluessel, er kommt aus den zwoelf Woertern. Bis 2.0.0 hatte
// deshalb kein Geraet mehr Recht als ein anderes, und abmelden liess sich
// keines — nach "Telefon verloren, auf dem neuen wiederhergestellt" bekam das
// alte weiter jede Nachricht (docs/GERAETEABMELDUNG.md). Jetzt hat jedes Geraet
// zusaetzlich einen EIGENEN, zufaelligen Geraeteschluessel, und die Adresse
// fuehrt eine Liste, unterschrieben vom Identitaetsschluessel UND vom
// Geraeteschluessel eines Mitglieds. Der Relay laesst nur gelistete Geraete
// herein, und jede Gegenstelle prueft die Liste selbst.
//
// DIESE DATEI IST DAS GEGENSTUECK ZU relay_server.py (lies_liste,
// lies_beitritt). Die kanonische Form muss Zeichen fuer Zeichen dieselbe sein:
// Python `json.dumps(x, sort_keys=True, separators=(",", ":"))`, hier dieselbe
// Reihenfolge per Einfuegung. Geprueft in test/net/geraeteliste_test.dart
// gegen Werte, die der Relay selbst erzeugt hat.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:cryptography/cryptography.dart' show SecretBox, SecretKeyData, Mac;
import 'package:libsignal/libsignal.dart';

import '../crypto/address.dart';
import '../crypto/signal_identity.dart';

/// Was die Signatur einer Liste von jeder anderen unterscheidet. Mit `\n`.
const String listePraefix = 'BitDM-Geraeteliste-v1\n';
const String beitrittPraefix = 'BitDM-Beitritt-v1\n';
const String anmeldePraefix = 'BitDM-Geraet-Anmeldung-v1\n';
const String nachweisPraefix = 'BitDM-Beitritt-Nachweis-v1\n';

/// Groesser als der Relay je zulaesst (GERAETE_MAX 5). Der Relay entscheidet
/// die echte Grenze; hier geht es nur darum, Unsinn nicht zu verarbeiten.
const int _geraeteHoechstens = 32;
const int _infoHoechstens = 512;
const int _zahlHoechstens = 9007199254740992; // 2^53, genau auch im Browser
const int _kennungHoechstens = 127; // libsignal

/// Eine Liste oder Anfrage, die nicht so aussieht, wie sie soll.
class GeraetelisteUngueltig implements Exception {
  const GeraetelisteUngueltig(this.grund);
  final String grund;
  @override
  String toString() => 'GeraetelisteUngueltig: $grund';
}

/// Wo dieses Geraet in der Liste seiner Identitaet steht.
enum ListenStand {
  /// Noch nicht gefragt — oder der Relay kennt keine Geraeteliste (alter
  /// Relay). Dann gilt alles wie vor der Geraeteabmeldung.
  unbekannt,

  /// Steht in der Liste. Der Normalfall.
  mitglied,

  /// Steht nicht darin: ein Geraet der Liste muss den Beitritt bestaetigen,
  /// oder dieses Geraet setzt zurueck ("alle anderen abmelden").
  beitrittNoetig,

  /// Hat um Beitritt gebeten und wartet auf das bestaetigende Geraet.
  wartetAufBestaetigung,

  /// Wurde abgemeldet. Die zwoelf Woerter sind von diesem Geraet entfernt.
  abgemeldet,
}

/// Ein Eintrag der Liste: Kennung, Geraeteschluessel (32 rohe Byte) und die
/// verschluesselte Info (Name, seit wann).
class GeraeteEintrag {
  const GeraeteEintrag(this.id, this.schluessel, this.info);
  final int id;
  final Uint8List schluessel;
  final String info;
}

/// Ein Geraet, so wie die Oberflaeche es zeigt.
class GeraetAnzeige {
  const GeraetAnzeige({
    required this.id,
    required this.istDieses,
    this.name,
    this.seit,
  });
  final int id;
  final bool istDieses;

  /// Null, wenn die Info sich nicht lesen laesst (kaputt, fremd).
  final String? name;
  final DateTime? seit;
}

bool _nurAscii(String s) => s.codeUnits.every((c) => c < 128);

bool _ganzzahl(Object? w, int unten, int oben) =>
    w is int && w >= unten && w <= oben;

Uint8List _b64(Object? w, int laenge, String name) {
  if (w is! String) throw GeraetelisteUngueltig('$name fehlt');
  final Uint8List roh;
  try {
    roh = base64.decode(w);
  } on FormatException {
    throw GeraetelisteUngueltig('$name ist kein base64');
  }
  if (roh.length != laenge) {
    throw GeraetelisteUngueltig('$name muss $laenge Byte sein');
  }
  return roh;
}

String _info(Object? w) {
  if (w is! String || w.length > _infoHoechstens) {
    throw const GeraetelisteUngueltig('info ungueltig');
  }
  try {
    base64.decode(w);
  } on FormatException {
    throw const GeraetelisteUngueltig('info ist kein base64');
  }
  return w;
}

/// Die 32 rohen Byte eines oeffentlichen Schluessels — ohne Typbyte 0x05.
/// So stehen sie auf der Leitung, so prueft sie der Relay.
Uint8List rohOeffentlich(PrivateKey k) =>
    SignalIdentityBridge.rawPublicKeyOf(k.getPublicKey());

/// Prueft eine XEdDSA-Signatur gegen 32 rohe Byte. Nie ein Wurf.
bool signaturGilt(Uint8List roh32, List<int> nachricht, List<int> signatur) {
  if (roh32.length != 32 || signatur.length != 64) return false;
  try {
    final k = PublicKey.deserialize(
        bytes: [SignalIdentityBridge.curve25519Typ, ...roh32]);
    return k.verify(message: nachricht, signature: signatur);
  } catch (_) {
    return false;
  }
}

Uint8List _mit(String praefix, String roh) =>
    Uint8List.fromList(utf8.encode(praefix + roh));

Map<String, Object?> _lies(Object? roh, String name) {
  if (roh is! Map) throw GeraetelisteUngueltig('$name fehlt');
  return roh.cast<String, Object?>();
}

Object? _parse(String roh) {
  if (!_nurAscii(roh)) {
    throw const GeraetelisteUngueltig('nicht kanonisch (nur ASCII)');
  }
  try {
    return jsonDecode(roh);
  } on FormatException {
    throw const GeraetelisteUngueltig('kein JSON');
  }
}

// ═══════════════════════════════════════════════════════════ Geraeteliste

class Geraeteliste {
  const Geraeteliste._({
    required this.adresse,
    required this.epoche,
    required this.geraete,
    required this.unterzeichner,
    required this.zeit,
    required this.roh,
    required this.sigIdentitaet,
    required this.sigGeraet,
  });

  final String adresse;
  final int epoche;
  final List<GeraeteEintrag> geraete;
  final int unterzeichner;

  /// Uhr des Unterzeichners — nur zur Anzeige.
  final int zeit;

  /// Genau die unterschriebenen Zeichen.
  final String roh;
  final Uint8List sigIdentitaet;
  final Uint8List sigGeraet;

  Set<int> get kennungen => {for (final e in geraete) e.id};

  Uint8List? schluesselVon(int id) {
    for (final e in geraete) {
      if (e.id == id) return e.schluessel;
    }
    return null;
  }

  /// Steht dieses Geraet darin — mit DIESEM Schluessel? Dieselbe Kennung mit
  /// einem anderen Schluessel ist ein anderes Geraet.
  bool enthaelt(int id, Uint8List schluessel) {
    final s = schluesselVon(id);
    return s != null && _gleich(s, schluessel);
  }

  Map<String, Object?> alsJson() => {
        'liste': roh,
        'sig_identitaet': base64.encode(sigIdentitaet),
        'sig_geraet': base64.encode(sigGeraet),
      };

  /// Die kanonische Zeichenkette. Schluessel in sortierter Reihenfolge, weil
  /// Python `sort_keys=True` schreibt und Dart in Einfuegereihenfolge.
  static String kanonisch({
    required String adresse,
    required int epoche,
    required List<GeraeteEintrag> geraete,
    required int unterzeichner,
    required int zeit,
  }) {
    final sortiert = [...geraete]..sort((a, b) => a.id.compareTo(b.id));
    return jsonEncode({
      'adresse': adresse,
      'epoche': epoche,
      'geraete': [
        for (final e in sortiert) [e.id, base64.encode(e.schluessel), e.info],
      ],
      'unterzeichner': unterzeichner,
      'v': 1,
      'zeit': zeit,
    });
  }

  /// Baut eine Fassung und unterschreibt sie mit beiden Schluesseln.
  static Geraeteliste unterschreibe({
    required SignalIdentity identitaet,
    required PrivateKey geraeteschluessel,
    required int epoche,
    required List<GeraeteEintrag> geraete,
    required int unterzeichner,
    int? zeit,
  }) {
    final z = zeit ?? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final roh = kanonisch(
        adresse: identitaet.address,
        epoche: epoche,
        geraete: geraete,
        unterzeichner: unterzeichner,
        zeit: z);
    final nachricht = _mit(listePraefix, roh);
    return Geraeteliste._(
      adresse: identitaet.address,
      epoche: epoche,
      geraete: [...geraete]..sort((a, b) => a.id.compareTo(b.id)),
      unterzeichner: unterzeichner,
      zeit: z,
      roh: roh,
      sigIdentitaet: identitaet.keyPair.sign(message: nachricht),
      sigGeraet: geraeteschluessel.sign(message: nachricht),
    );
  }

  /// Liest und prueft eine Fassung, wie sie vom Relay kommt
  /// (`{"liste","sig_identitaet","sig_geraet"}`). Wirft
  /// [GeraetelisteUngueltig].
  ///
  /// GEPRUEFT WIRD: Form und kanonische Schreibweise, dass die Liste zu
  /// [adresse] gehoert, die Signatur des Identitaetsschluessels dieser
  /// Adresse, und die des Unterzeichners — gegen seinen Schluessel in dieser
  /// Liste oder, wenn er sich selbst abgemeldet hat, in [vorige].
  ///
  /// MIT [vorige] UND EPOCHE GENAU +1 auch die Regel des Relays (§8.3): ein
  /// Mitglied aendert, oder jemand setzt auf sich allein zurueck. Fehlt eine
  /// Fassung dazwischen, laesst sich das nicht pruefen — dann zaehlen die
  /// Signaturen allein. Die Epoche vergleicht der Aufrufer.
  static Geraeteliste pruefe(Object? json,
      {required String adresse, Geraeteliste? vorige}) {
    final j = _lies(json, 'geraeteliste');
    final roh = j['liste'];
    if (roh is! String || roh.length > 4096) {
      throw const GeraetelisteUngueltig('liste fehlt');
    }
    final sigI = _b64(j['sig_identitaet'], 64, 'sig_identitaet');
    final sigG = _b64(j['sig_geraet'], 64, 'sig_geraet');
    final o = _lies(_parse(roh), 'liste');

    final a = o['adresse'];
    if (a is! String || a != BitdmAddress.normalize(adresse)) {
      throw const GeraetelisteUngueltig('fremde Adresse');
    }
    if (!_ganzzahl(o['v'], 1, 1)) {
      throw const GeraetelisteUngueltig('unbekannte Fassung');
    }
    if (!_ganzzahl(o['epoche'], 1, _zahlHoechstens) ||
        !_ganzzahl(o['zeit'], 0, _zahlHoechstens) ||
        !_ganzzahl(o['unterzeichner'], 1, _kennungHoechstens)) {
      throw const GeraetelisteUngueltig('Zahl ungueltig');
    }
    final roheEintraege = o['geraete'];
    if (roheEintraege is! List ||
        roheEintraege.isEmpty ||
        roheEintraege.length > _geraeteHoechstens) {
      throw const GeraetelisteUngueltig('geraete ungueltig');
    }
    final eintraege = <GeraeteEintrag>[];
    var vorher = 0;
    for (final e in roheEintraege) {
      if (e is! List || e.length != 3) {
        throw const GeraetelisteUngueltig('Eintrag ungueltig');
      }
      final id = e[0];
      if (!_ganzzahl(id, 1, _kennungHoechstens) || (id as int) <= vorher) {
        throw const GeraetelisteUngueltig('Kennungen nicht aufsteigend');
      }
      vorher = id;
      eintraege.add(GeraeteEintrag(id, _b64(e[1], 32, 'schluessel'), _info(e[2])));
    }
    final schluessel = {for (final e in eintraege) base64.encode(e.schluessel)};
    if (schluessel.length != eintraege.length) {
      throw const GeraetelisteUngueltig('Geraeteschluessel doppelt');
    }

    // KANONISCH: neu geschrieben muss dieselbe Zeichenkette herauskommen.
    // Das faengt fehlende und zusaetzliche Felder, doppelte Schluessel (die
    // jsonDecode still zusammenlegt), Leerraum und 1.0 statt 1.
    final epoche = o['epoche']! as int;
    final unterzeichner = o['unterzeichner']! as int;
    final zeit = o['zeit']! as int;
    if (kanonisch(
            adresse: a,
            epoche: epoche,
            geraete: eintraege,
            unterzeichner: unterzeichner,
            zeit: zeit) !=
        roh) {
      throw const GeraetelisteUngueltig('nicht kanonisch');
    }

    final nachricht = _mit(listePraefix, roh);
    if (!signaturGilt(BitdmAddress.decode(a), nachricht, sigI)) {
      throw const GeraetelisteUngueltig('Identitaetssignatur ungueltig');
    }
    final liste = Geraeteliste._(
      adresse: a,
      epoche: epoche,
      geraete: eintraege,
      unterzeichner: unterzeichner,
      zeit: zeit,
      roh: roh,
      sigIdentitaet: sigI,
      sigGeraet: sigG,
    );

    final eigener = liste.schluesselVon(unterzeichner);
    final ketteBekannt = vorige != null && vorige.epoche == epoche - 1;
    if (ketteBekannt) {
      // DIE REGEL DES RELAYS (§8.3): ein Mitglied aendert — mit seinem
      // Schluessel aus der vorigen Fassung, auch wenn es sich selbst abmeldet
      // —, oder jemand setzt auf sich allein zurueck.
      final alter = vorige.schluesselVon(unterzeichner);
      final mitglied =
          alter != null && (eigener == null || _gleich(eigener, alter));
      final zurueckgesetzt =
          eintraege.length == 1 && eintraege.first.id == unterzeichner;
      if (!mitglied && !zurueckgesetzt) {
        throw const GeraetelisteUngueltig(
            'nur ein Mitglied darf Geraete hinzufuegen');
      }
      if (!signaturGilt(mitglied ? alter : eigener!, nachricht, sigG)) {
        throw const GeraetelisteUngueltig('Geraetesignatur ungueltig');
      }
    } else if (eigener != null) {
      if (!signaturGilt(eigener, nachricht, sigG)) {
        throw const GeraetelisteUngueltig('Geraetesignatur ungueltig');
      }
    }
    // Sonst: der Unterzeichner hat sich selbst abgemeldet, und die Fassung
    // davor fehlt hier. Dann zaehlt die Identitaetssignatur allein — die Kette
    // hat der Relay geprueft, und faelschen koennte sie nur, wer die Woerter
    // hat; der koennte ohnehin zuruecksetzen.
    return liste;
  }
}

bool _gleich(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

// ═══════════════════════════════════════════════════════════ Beitritt

/// Der Code, den das bestaetigende Geraet anzeigt (§8.5): 10 Zufallsbyte,
/// angezeigt als 16 Zeichen Base32 in vier Gruppen.
///
/// ER VERLAESST DAS GERAET NIE, auch nicht zum Relay. Daran haengt alles: wer
/// die Woerter hat, kann jede Anfrage nachbauen — aber keine mit einem
/// Nachweis, der zu einem Code passt, den er nie gesehen hat.
class Beitrittscode {
  Beitrittscode._();

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static Uint8List neu() {
    final z = Random.secure();
    return Uint8List.fromList(List.generate(10, (_) => z.nextInt(256)));
  }

  /// `ABCD-EFGH-IJKL-MNOP`.
  static String zeige(Uint8List code) {
    final sb = StringBuffer();
    var puffer = 0, bits = 0;
    for (final b in code) {
      puffer = (puffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_alphabet[(puffer >> bits) & 31]);
      }
    }
    final s = sb.toString();
    return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4)].join('-');
  }

  /// Liest einen eingetippten Code — Gross- und Kleinschreibung, Bindestriche
  /// und Leerraum egal; 0 und 1 (kommen im Alphabet nicht vor) gelten als O
  /// und I. Null, wenn es keiner ist.
  static Uint8List? lies(String eingabe) {
    final s = eingabe
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]'), '')
        .replaceAll('0', 'O')
        .replaceAll('1', 'I');
    if (s.length != 16) return null;
    var puffer = 0, bits = 0;
    final out = <int>[];
    for (final c in s.split('')) {
      final w = _alphabet.indexOf(c);
      if (w < 0) return null;
      puffer = ((puffer << 5) | w) & 0xFFFF;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((puffer >> bits) & 0xFF);
      }
    }
    return Uint8List.fromList(out);
  }
}

class Beitrittsanfrage {
  const Beitrittsanfrage._({
    required this.adresse,
    required this.deviceId,
    required this.schluessel,
    required this.info,
    required this.nachweis,
    required this.zeit,
    required this.roh,
    required this.sigIdentitaet,
    required this.sigGeraet,
  });

  final String adresse;
  final int deviceId;
  final Uint8List schluessel;
  final String info;
  final Uint8List nachweis;
  final int zeit;
  final String roh;
  final Uint8List sigIdentitaet;
  final Uint8List sigGeraet;

  GeraeteEintrag get eintrag => GeraeteEintrag(deviceId, schluessel, info);

  Map<String, Object?> alsJson() => {
        'anfrage': roh,
        'sig_identitaet': base64.encode(sigIdentitaet),
        'sig_geraet': base64.encode(sigGeraet),
      };

  /// HMAC-SHA256 mit dem Code ueber Adresse, Kennung und Geraeteschluessel.
  static Uint8List rechneNachweis(
      Uint8List code, String adresse, int deviceId, Uint8List schluessel) {
    final mac = DartHmac.sha256().calculateMacSync(
      utf8.encode('$nachweisPraefix$adresse\n$deviceId\n${base64.encode(schluessel)}'),
      secretKeyData: SecretKeyData(code),
      nonce: const [],
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Passt der Nachweis zu [code]? In konstanter Zeit.
  bool passtZu(Uint8List code) =>
      _gleich(rechneNachweis(code, adresse, deviceId, schluessel), nachweis);

  static String _kanonisch(String adresse, int deviceId, String info,
          Uint8List nachweis, Uint8List schluessel, int zeit) =>
      jsonEncode({
        'adresse': adresse,
        'device_id': deviceId,
        'info': info,
        'nachweis': base64.encode(nachweis),
        'schluessel': base64.encode(schluessel),
        'v': 1,
        'zeit': zeit,
      });

  static Beitrittsanfrage unterschreibe({
    required SignalIdentity identitaet,
    required PrivateKey geraeteschluessel,
    required int deviceId,
    required String info,
    required Uint8List code,
    int? zeit,
  }) {
    final z = zeit ?? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final s = rohOeffentlich(geraeteschluessel);
    final n = rechneNachweis(code, identitaet.address, deviceId, s);
    final roh = _kanonisch(identitaet.address, deviceId, info, n, s, z);
    final nachricht = _mit(beitrittPraefix, roh);
    return Beitrittsanfrage._(
      adresse: identitaet.address,
      deviceId: deviceId,
      schluessel: s,
      info: info,
      nachweis: n,
      zeit: z,
      roh: roh,
      sigIdentitaet: identitaet.keyPair.sign(message: nachricht),
      sigGeraet: geraeteschluessel.sign(message: nachricht),
    );
  }

  /// Liest und prueft eine Anfrage vom Relay — Form, kanonisch, Adresse und
  /// BEIDE Signaturen. Ob der Nachweis passt, sagt erst [passtZu].
  static Beitrittsanfrage pruefe(Object? json, {required String adresse}) {
    final j = _lies(json, 'beitritt');
    final roh = j['anfrage'];
    if (roh is! String || roh.length > 2048) {
      throw const GeraetelisteUngueltig('anfrage fehlt');
    }
    final sigI = _b64(j['sig_identitaet'], 64, 'sig_identitaet');
    final sigG = _b64(j['sig_geraet'], 64, 'sig_geraet');
    final o = _lies(_parse(roh), 'anfrage');
    final a = o['adresse'];
    if (a is! String || a != BitdmAddress.normalize(adresse)) {
      throw const GeraetelisteUngueltig('fremde Adresse');
    }
    if (!_ganzzahl(o['v'], 1, 1) ||
        !_ganzzahl(o['device_id'], 1, _kennungHoechstens) ||
        !_ganzzahl(o['zeit'], 0, _zahlHoechstens)) {
      throw const GeraetelisteUngueltig('Zahl ungueltig');
    }
    final deviceId = o['device_id']! as int;
    final zeit = o['zeit']! as int;
    final info = _info(o['info']);
    final nachweis = _b64(o['nachweis'], 32, 'nachweis');
    final schluessel = _b64(o['schluessel'], 32, 'schluessel');
    if (_kanonisch(a, deviceId, info, nachweis, schluessel, zeit) != roh) {
      throw const GeraetelisteUngueltig('nicht kanonisch');
    }
    final nachricht = _mit(beitrittPraefix, roh);
    if (!signaturGilt(BitdmAddress.decode(a), nachricht, sigI) ||
        !signaturGilt(schluessel, nachricht, sigG)) {
      throw const GeraetelisteUngueltig('Signatur ungueltig');
    }
    return Beitrittsanfrage._(
      adresse: a,
      deviceId: deviceId,
      schluessel: schluessel,
      info: info,
      nachweis: nachweis,
      zeit: zeit,
      roh: roh,
      sigIdentitaet: sigI,
      sigGeraet: sigG,
    );
  }
}

// ═══════════════════════════════════════════════════════════ Info je Geraet

/// Name und Einrichtungszeit eines Geraets, verschluesselt in der Liste.
///
/// Der Relay sieht nur Rauschen; jedes Geraet mit den Woertern liest es
/// (Schluessel aus KeyDerivation `deviceInfoKey`). AES-256-GCM mit
/// Zufallsnonce: `base64(nonce(12) ‖ Chiffrat ‖ Tag(16))`.
class GeraeteInfo {
  const GeraeteInfo(this.name, this.seit);
  final String name;
  final DateTime seit;

  static final _aes = DartAesGcm.with256bits();

  String verschluessle(Uint8List schluessel) {
    final klar = utf8.encode(jsonEncode({
      'n': name.length > 60 ? name.substring(0, 60) : name,
      's': seit.toUtc().millisecondsSinceEpoch ~/ 1000,
    }));
    final box = _aes.encryptSync(klar,
        secretKeyData: SecretKeyData(schluessel),
        nonce: _aes.newNonce());
    return base64.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Null, wenn es sich nicht lesen laesst — fremder Schluessel, leer, kaputt.
  static GeraeteInfo? entschluessle(Uint8List schluessel, String info) {
    try {
      final roh = base64.decode(info);
      if (roh.length < 12 + 16) return null;
      final box = SecretBox(roh.sublist(12, roh.length - 16),
          nonce: roh.sublist(0, 12), mac: Mac(roh.sublist(roh.length - 16)));
      final j = (jsonDecode(utf8.decode(
              _aes.decryptSync(box, secretKeyData: SecretKeyData(schluessel))))
          as Map).cast<String, Object?>();
      final n = j['n'];
      final s = j['s'];
      if (n is! String || s is! int) return null;
      return GeraeteInfo(
          n, DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true));
    } catch (_) {
      return null;
    }
  }
}
