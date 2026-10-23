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
import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:libsignal/libsignal.dart' show PrivateKey;
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/core/store/signal_store.dart';

import 'signal_hilfe.dart';

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

  /// Wie [liste], aber je Adresse — hat Vorrang, wo gesetzt. Sonst gaelte
  /// dieselbe Antwort fuer die eigene Adresse und jede Gegenstelle.
  final listeJe = <String, List<int>>{};

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

  /// Jedes Buendel, das angemeldet wurde, in der Reihenfolge.
  final anmeldungen = <RelayPreKeyBundle>[];

  /// An welche Geraete das Senden fehlschlaegt. Der Fanout-Fall.
  Set<int> sendeFehlerFuerGeraet = {};

  final gesendet = <({String an, int geraet, Uint8List umschlag})>[];

  /// Jeder Versuch, auch die abgewiesenen — in [gesendet] stehen nur die
  /// angenommenen.
  final versucht = <({String an, int geraet})>[];

  /// Wie lange ein HTTP-Umlauf dauert.
  ///
  /// NICHT NULL BEI DEN REIHENFOLGE-FAELLEN. Eine Attrappe, die sofort
  /// antwortet, macht aus einem Netzumlauf eine Mikrotask — und dann
  /// entscheidet die Zahl der `await`-Stellen darueber, wer zuerst drankommt,
  /// statt der Sache nach. Der Nachversand-Fall haengt genau an dieser
  /// Reihenfolge und waere ohne die Verzoegerung ein Muenzwurf.
  Duration umlauf = Duration.zero;

  final gebaut = <RelayAttrappe>[];

  /// DIE GERAETELISTE (docs/GERAETEABMELDUNG.md). Per Vorgabe kennt diese
  /// Attrappe keine — wie ein Relay vor der Geraeteabmeldung: Abruf 404,
  /// Anlegen 404. Dann bleibt der Kern beim bisherigen Verhalten.
  ///
  /// Mit [kenntListen] fuehrt sie je Adresse eine Liste, ohne die Regeln des
  /// Relays (die prueft relay_server.py) — nur Ablage und Ausgabe.
  bool kenntListen = false;
  final listen = <String, Map<String, Object?>>{};
  final beitritte = <String, List<Map<String, Object?>>>{};

  /// DER RELAY, DER EINE ABMELDUNG VERSCHWEIGT (docs/GERAETEABMELDUNG.md
  /// §12): er nimmt jede neue Fassung an und bestaetigt sie, liefert aber
  /// weiter aus, was in [listen] steht.
  bool verschweigtListen = false;

  /// Was der Relay angenommen, aber verschwiegen hat — je Adresse die letzte.
  final verschwiegen = <String, Map<String, Object?>>{};

  /// An diese Geraete antwortet der Relay "Zielgeraet unbekannt" (§12.5 c).
  Set<int> unbekannteGeraete = {};
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

  @override
  PrivateKey? geraeteSchluessel;

  @override
  Future<Map<String, Object?>?> holeGeraeteliste(String userId) async =>
      lage.kenntListen ? lage.listen[userId] : null;

  @override
  Future<int> setzeGeraeteliste(Geraeteliste liste) async {
    if (!lage.kenntListen) {
      throw const RelayException('Not Found', statusCode: 404);
    }
    if (lage.verschweigtListen) {
      lage.verschwiegen[liste.adresse] = liste.alsJson();
    } else {
      lage.listen[liste.adresse] = liste.alsJson();
    }
    return liste.epoche;
  }

  @override
  Future<void> beantrageBeitritt(Beitrittsanfrage a) async {
    if (!lage.kenntListen) {
      throw const RelayException('Not Found', statusCode: 404);
    }
    (lage.beitritte[a.adresse] ??= []).add(a.alsJson());
  }

  @override
  Future<List<Map<String, Object?>>> holeBeitritte(String userId) async =>
      lage.beitritte[userId] ?? const [];

  /// Etwas kommt vom Relay herein — der Weg jedes Umschlags.
  void herein(RelayEvent e) => _ereignisse.add(e);

  @override
  Future<void> connect() async => verbunden = true;

  @override
  Future<int> register(RelayPreKeyBundle b) async {
    final f = lage.anmeldeFehler;
    if (f != null) throw f;
    lage.anmeldungen.add(b);
    return 100;
  }

  @override
  Future<List<int>?> geraeteliste(String userId) async {
    lage.listeAbrufe++;
    if (lage.umlauf > Duration.zero) await Future<void>.delayed(lage.umlauf);
    final f = lage.listeFehler;
    if (f != null) throw f;
    return lage.listeJe[userId] ?? lage.liste;
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
    lage.versucht.add((an: to, geraet: g));
    if (lage.sendeFehlerFuerGeraet.contains(g)) {
      throw RelayException('Zustellung an Geraet $g abgelehnt');
    }
    if (lage.unbekannteGeraete.contains(g)) {
      // Derselbe Text wie vom echten Relay (relay_server.py, Rahmen `error`).
      throw const RelayException('Zielgeraet unbekannt');
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
  Fremder._(this.identitaet, this._karten);

  final SignalIdentity identitaet;

  /// Je Geraet die Karte, die der Relay dafuer ausliefert (mit Kyber).
  final Map<int, Map<String, Object?>> _karten;

  String get adresse => identitaet.address;

  static Future<Fremder> mitGeraeten(List<int> geraete) async {
    await signalBereit();
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    // Je Geraet ein eigener Speicher: eigene signierte und Kyber-Prekeys,
    // damit der Reflexionsriegel (§12.1) den Normalfall sieht.
    final karten = <int, Map<String, Object?>>{};
    var n = 0;
    for (final g in geraete) {
      n++;
      final store = BitdmSignalStore(identity: id);
      karten[g] = await legePrekeysAb(store,
          spkId: n, kyberId: n * 10, preKeyId: n * 1000);
    }
    return Fremder._(id, karten);
  }

  Map<String, Object?> geraetekarte(int g) => {
        'device_id': g,
        ..._karten[g]!,
      };

  /// Die Antwort des Relays auf `/prekey/<adresse>` — flache Felder plus
  /// `geraete`, genau wie Spezifikation §3.3 sie beschreibt.
  Map<String, Object?> karte() {
    final ids = _karten.keys.toList()..sort();
    return {
      'user_id': adresse,
      'identity_key': base64.encode(identitaet.rawPublicKey),
      ...geraetekarte(ids.first),
      'geraete': [for (final g in ids) geraetekarte(g)],
    };
  }
}
