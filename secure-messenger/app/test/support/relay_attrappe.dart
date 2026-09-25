// relay_attrappe.dart — ein Relay, der auf Kommando luegt.
//
// Sie steht hier und nicht in einer der beiden Testdateien, weil zwei Tests
// dasselbe Gegenstueck brauchen — und zwei Attrappen fuer dieselbe
// Schnittstelle waeren zwei Stellen, an denen sich das Verhalten
// auseinanderentwickeln kann, ohne dass es jemandem auffaellt. Dieselbe
// Begruendung wie bei funk_attrappe.dart.
//
// WOFUER SIE DA IST: der echte relay_server.py tut das Richtige. Was die
// Mehrgeraete-Riegel abwehren, ist aber gerade ein Relay, der LUEGT — er
// erfindet Geraete, meldet zweitausend statt fuenf, gibt unser eigenes
// Schluesselmaterial unter fremder Nummer zurueck oder klemmt mitten in der
// Kennungsfrage. Das laesst sich nur mit einer Gegenstelle herstellen, die
// genau das auf Kommando tut.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

/// Was der Relay gerade behauptet — und was er dabei zu sehen bekommen hat.
///
/// EIGENES OBJEKT UND NICHT AM CLIENT: `connect()` baut fuer JEDEN Versuch
/// einen frischen RelayClient (real_messenger_core `_neuerRelay`). Ein Zaehler
/// am Client selbst finge beim zweiten Verbinden wieder bei null an — und
/// genau ueber zwei Verbindungsversuche hinweg wird gemessen, ob eine Frage
/// wirklich noch einmal gestellt wird.
class Relaylage {
  /// Antwort auf `?nur_geraete=1`. Null heisst "dieser Relay kennt die Frage
  /// nicht" — das Verhalten von vor dem Umbau.
  List<int>? liste;

  /// Wenn gesetzt, wirft die Geraeteliste, statt zu antworten.
  RelayException? listeFehler;
  int listeAbrufe = 0;

  /// Was auf eine Buendelanfrage geantwortet wird — als Karte in der Form, in
  /// der der Relay sie ausliefert. Null heisst: es gibt kein Buendel.
  Map<String, Object?> Function(String)? buendel;
  Object? buendelFehler;
  int buendelAbrufe = 0;

  /// Wenn gesetzt, wirft die Anmeldung.
  Object? anmeldeFehler;

  /// An welche Geraete das Senden fehlschlaegt. Der Fanout-Fall.
  Set<int> sendeFehlerFuerGeraet = {};

  final gesendet = <({String an, int geraet, Uint8List umschlag})>[];

  /// Wie lange ein HTTP-Umlauf dauert.
  ///
  /// NICHT NULL BEI DEN REIHENFOLGE-FAELLEN. Eine Attrappe, die sofort
  /// antwortet, macht aus einem Netzumlauf eine Mikrotask — und dann
  /// entscheidet die Zahl der `await`-Stellen darueber, wer zuerst drankommt,
  /// statt der Sache nach. Der Nachversand-Fall haengt genau an dieser
  /// Reihenfolge und waere ohne die Verzoegerung ein Muenzwurf.
  Duration umlauf = Duration.zero;

  final gebaut = <RelayAttrappe>[];
}

class RelayAttrappe implements RelayClient {
  RelayAttrappe(this.identity, this.lage);

  @override
  final SignalIdentity identity;
  final Relaylage lage;

  bool verbunden = false;

  final _ereignisse = StreamController<RelayEvent>.broadcast();

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;
  @override
  bool get isConnected => verbunden;
  @override
  String get address => identity.address;
  @override
  int? geraeteKennung;

  /// Etwas kommt vom Relay herein — der Weg jedes Umschlags.
  void herein(RelayEvent e) => _ereignisse.add(e);

  @override
  Future<void> connect() async => verbunden = true;

  @override
  Future<int> register(RelayPreKeyBundle b) async {
    final f = lage.anmeldeFehler;
    if (f != null) throw f;
    return 100;
  }

  @override
  Future<List<int>?> geraeteliste(String userId) async {
    lage.listeAbrufe++;
    if (lage.umlauf > Duration.zero) await Future<void>.delayed(lage.umlauf);
    final f = lage.listeFehler;
    if (f != null) throw f;
    return lage.liste;
  }

  @override
  Future<RelayBundleResponse> fetchBundle(String userId) async {
    lage.buendelAbrufe++;
    if (lage.umlauf > Duration.zero) await Future<void>.delayed(lage.umlauf);
    final f = lage.buendelFehler;
    if (f != null) throw f;
    final karte = lage.buendel?.call(userId);
    if (karte == null || karte.isEmpty) {
      throw const RelayException('kein Buendel', statusCode: 404);
    }
    return RelayBundleResponse.fromJson(karte);
  }

  @override
  Future<void> send(String to, Uint8List ciphertext) =>
      sendeAnGeraet(to, null, ciphertext);

  @override
  Future<void> sendeAnGeraet(String to, int? geraet, Uint8List c) async {
    // KEIN `to_device` HEISST GERAET 1 (Spezifikation §3) — dieselbe Regel wie
    // auf der Leitung, sonst zaehlte dieser Buchhalter anders als der Server.
    final g = geraet ?? 1;
    if (lage.sendeFehlerFuerGeraet.contains(g)) {
      throw RelayException('Zustellung an Geraet $g abgelehnt');
    }
    lage.gesendet.add((an: to, geraet: g, umschlag: c));
  }

  @override
  void bestaetigeEmpfang(int q) {}

  @override
  void setzePushEndpunkt(String? e) {}

  @override
  Future<void> close() async => verbunden = false;

  @override
  Future<void> dispose() async {
    verbunden = false;
    if (!_ereignisse.isClosed) await _ereignisse.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

/// Eine fremde Adresse mit beliebig vielen Geraeten, jedes mit eigenem
/// Schluesselmaterial.
///
/// EIGENE SIGNIERTE PREKEYS JE GERAET, und das ist keine Sorgfalt um ihrer
/// selbst willen: `_bauSitzungen` baut je Geraet eine eigene X3DH-Sitzung, und
/// zwei Geraete mit denselben Bytes waeren genau der Fall, den der
/// Reflexionsriegel (§12.1) abweist. Hier soll der Normalfall herauskommen.
class Fremder {
  Fremder._(this.identitaet, this._spk, this._otk);

  final SignalIdentity identitaet;
  final Map<int, SignedPreKeyRecord> _spk;
  final Map<int, PreKeyRecord> _otk;

  String get adresse => identitaet.address;

  static Future<Fremder> mitGeraeten(List<int> geraete) async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final spk = <int, SignedPreKeyRecord>{};
    final otk = <int, PreKeyRecord>{};
    var n = 0;
    for (final g in geraete) {
      n++;
      spk[g] = generateSignedPreKey(id.keyPair, n);
      otk[g] = generatePreKeys(n * 1000, 1).first;
    }
    return Fremder._(id, spk, otk);
  }

  Map<String, Object?> geraetekarte(int g) => {
        'device_id': g,
        'registration_id': identitaet.registrationId,
        'signed_prekey_id': _spk[g]!.id,
        'signed_prekey':
            base64.encode(_spk[g]!.getKeyPair().publicKey.serialize()),
        'signed_prekey_sig': base64.encode(_spk[g]!.signature),
        'one_time_prekey': {
          'key_id': _otk[g]!.id,
          'public_key':
              base64.encode(_otk[g]!.getKeyPair().publicKey.serialize()),
        },
      };

  /// Die Antwort des Relays auf `/prekey/<adresse>` — flache Felder plus
  /// `geraete`, genau wie Spezifikation §3.3 sie beschreibt.
  Map<String, Object?> karte() {
    final ids = _spk.keys.toList()..sort();
    return {
      'user_id': adresse,
      'identity_key': base64.encode(SignalIdentityBridge.rawPublicKeyOf(
          identitaet.keyPair.getPublicKey())),
      ...geraetekarte(ids.first),
      'geraete': [for (final g in ids) geraetekarte(g)],
    };
  }
}
