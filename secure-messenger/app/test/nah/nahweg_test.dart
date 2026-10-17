// nahweg_test.dart — die Naehe am Nachrichtenweg, ohne ein einziges Telefon.
//
// WAS HIER GEPRUEFT WIRD, ist keine Funktechnik. Es ist die Buchfuehrung, die
// darueber entscheidet, ob eine Nachricht ankommt, zweimal ankommt oder liegen
// bleibt — und ob dabei ein Server angefasst wurde, obwohl der Nutzer das
// ausgeschlossen hat. Die vier Regeln stehen im Kopf von wegwahl.dart; hier
// stehen sie noch einmal, aber als Messung.
//
// MOEGLICH IST DAS DURCH ZWEI HAKEN im Kern: `relayFactory` und `nahFactory`.
// Dahinter haengen ein Relay, den dieser Test an- und abschalten kann, und ein
// ECHTER Nahbereich ueber einer Funk-Attrappe — nicht etwa ein nachgebauter.
// Leuchtfeuer, Tabelle, Reichweite und die Zuordnung Geraet→Kontakt laufen
// also wirklich, mit wirklichen X25519-Geheimnissen aus wirklichen Adressen.
// Nachgebaut ist nur, was Bluetooth waere.
//
// DIE GEGENSTELLE rechnet ihre Leuchtfeuer ueber das cryptography-Paket, der
// Kern seine ueber libsignal. Dass beide dasselbe herausbekommen, ist der
// Angelpunkt des ganzen Verfahrens und in schluesselbruecke_test.dart gemessen.
// Faende dieser Test hier niemanden in Reichweite, waere dort der erste Blick.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/funk_attrappe.dart';
import '../support/signal_hilfe.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _inhalt;
  @override
  Future<Uint8List?> read() async => _inhalt;
  @override
  Future<void> write(Uint8List e) async => _inhalt = e;
  @override
  Future<void> delete() async => _inhalt = null;
}

/// Ein Relay mit Schaltern: verbunden ja/nein, Senden gelingt ja/nein.
///
/// Er FUEHRT BUCH, und zwar getrennt nach dem, worauf es ankommt: was
/// hinausging, wie oft ein Buendel geholt wurde, was bestaetigt wurde. Ein
/// Zaehler fuer alles zusammen koennte nicht zeigen, dass "nur in der Naehe"
/// zwar nichts sendet, aber sehr wohl ein Buendel holt — genau der Fehler, den
/// dieser Test suchen soll.
class SteuerbarerRelay implements RelayClient {
  SteuerbarerRelay(this.identity, this.buendel);

  @override
  final SignalIdentity identity;

  /// Was auf eine Buendelanfrage geantwortet wird.
  final RelayBundleResponse Function(String) buendel;

  bool verbunden = false;
  bool sendenWirft = false;

  /// Haelt den NAECHSTEN Versand an, NACHDEM der Umschlag angekommen ist:
  /// der Relay hat ihn, aber die Bestaetigung steht noch aus. Gilt einmal.
  ///
  /// Das ist das Fenster, in dem eine Nachricht noch auf "sending" steht,
  /// obwohl sie draussen ist. Mit der offiziellen libsignal (seit 2.0.0) ist
  /// es breiter geworden, und im Gesamtlauf vom 16.10.2026 fiel ein
  /// Nachversand hinein.
  Completer<void>? sendeTor;

  final gesendet = <({String an, Uint8List umschlag})>[];
  final bestaetigt = <int>[];
  int buendelAbrufe = 0;

  final _ereignisse = StreamController<RelayEvent>.broadcast();

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;

  @override
  bool get isConnected => verbunden;

  @override
  String get address => identity.address;

  @override
  Future<void> connect() async => verbunden = true;

  @override
  Future<int> register(RelayPreKeyBundle b) async => 100;

  @override
  Future<RelayBundleResponse> fetchBundle(String userId) async {
    buendelAbrufe++;
    return buendel(userId);
  }

  @override
  Future<void> send(String to, Uint8List ciphertext) async {
    if (sendenWirft) throw const RelayException('die Leitung brach ab');
    gesendet.add((an: to, umschlag: ciphertext));
    final tor = sendeTor;
    sendeTor = null;
    if (tor != null) await tor.future;
  }

  @override
  void bestaetigeEmpfang(int q) => bestaetigt.add(q);

  /// Etwas kommt vom Relay herein. Der Weg, auf dem eine App den ERSTEN
  /// Kontakt zu jemandem bekommt, der zuerst geschrieben hat.
  void herein(RelayEvent e) => _ereignisse.add(e);

  @override
  Future<void> close() async => verbunden = false;

  @override
  Future<void> dispose() async {
    verbunden = false;
    await _ereignisse.close();
  }

  // Ein Relay ohne Mehrgeraete-Wissen antwortet `null` — daraus liest
  // `_ermittleGeraetId` "Geraet 1", also das Verhalten von vor dem Umbau.
  // Ohne diese Zeile faellt der Aufruf in `noSuchMethod`, und der Wurf
  // reisst beim Verbinden die Leitung ab.
  @override
  Future<List<int>?> geraeteliste(String userId) async => null;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

/// Eine Funk-Attrappe, die beim Werben stehenbleibt, bis der Test sie
/// weiterlaesst.
///
/// SIE HAELT DAS EINE FENSTER AUF, IN DEM "NUR IN DER NAEHE" GILT UND DER
/// RELAY NOCH DASTEHT. Sonst gibt es dieses Fenster naemlich nicht: sobald der
/// Schalter umgelegt ist, raeumt `setPreferences` die Verbindung ab, und ab da
/// ist der Relay im Kern schlicht `null`. Ein Test, der danach sendet, misst
/// eine fehlende Verbindung — er bliebe gruen, wenn man die Sperre gegen das
/// Buendel ersatzlos loeschte, denn der Ablauf endet dann in derselben
/// NotInitializedException.
///
/// `setPreferences` richtet aber ZUERST den Funk ein und trennt DANACH. Wer
/// den Funk beim Werben anhaelt, steht also genau zwischen beidem: der
/// Schalter gilt schon, die Verbindung steht noch, und ein Buendel waere zu
/// holen. Erst dort ist die Sperre das Einzige, was den Server verschont.
class GebremsterFunk extends FunkAttrappe {
  Completer<void>? _bremse;

  /// Ob gerade jemand an der Bremse haengt. Der Punkt, an dem der Test weiss,
  /// dass er im Fenster ist — `werbungen` allein sagt das nicht.
  bool stehtBeimWerben = false;

  void bremseBeimWerben() => _bremse = Completer<void>();

  void lassLaufen() {
    final b = _bremse;
    _bremse = null;
    stehtBeimWerben = false;
    b?.complete();
  }

  @override
  Future<void> werbeAn(List<Uint8List> l) async {
    await super.werbeAn(l);
    final b = _bremse;
    if (b == null) return;
    stehtBeimWerben = true;
    await b.future;
  }
}

/// Der andere am anderen Ende — mit allem, was er braucht, um mitzuspielen.
///
/// Er ist KEINE zweite App: er hat keine Datenbank und keine Oberflaeche. Was
/// er kann, ist genau das, was ein zweites Telefon von aussen betrachtet tut —
/// ein Leuchtfeuer aussenden, ein Buendel anbieten, einen Umschlag bauen.
///
/// SEIT 2.0.0 MIT KYBER: ein Einmal- und ein Last-Resort-Kyber-Prekey, wie
/// ihn `_fuelleVorratAuf` im Kern anlegt. Ohne Kyber baut die offizielle
/// libsignal keine Sitzung (PQXDH ist Pflicht).
class Gegenstelle {
  Gegenstelle._(this.identitaet, this.store, this._otk, this._spk,
      this._kyberEinmal, this._kyberLetzte);

  final SignalIdentity identitaet;
  final BitdmSignalStore store;
  final PreKeyRecord _otk;
  final SignedPreKeyRecord _spk;
  final KyberPreKeyRecord _kyberEinmal;
  final KyberPreKeyRecord _kyberLetzte;

  String get adresse => identitaet.address;
  Uint8List get oeffentlich => identitaet.rawPublicKey;

  static Future<Gegenstelle> neu() async {
    // HIER und nicht nur im Kern: nachtfunde_test baut Gegenstellen, bevor
    // irgendein Kern die native Bibliothek geladen hat.
    await signalBereit();
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final otk = neuerPreKey(1);
    await store.storePreKey(1, otk);
    final spk = neuerSpk(id.keyPair, 1);
    await store.storeSignedPreKey(1, spk);
    final letzte = neuerKyber(id.keyPair, 1);
    await store.storeLastResortKyberPreKey(1, letzte);
    final einmal = neuerKyber(id.keyPair, 2);
    await store.storeKyberPreKey(2, einmal);
    return Gegenstelle._(id, store, otk, spk, einmal, letzte);
  }

  /// Was der Relay auf eine Buendelanfrage antworten wuerde — MIT
  /// Einmalschluesseln, EC und Kyber.
  RelayBundleResponse get antwort => RelayBundleResponse.fromJson(
      karteAus(identitaet, _spk, kyber: _kyberEinmal, otk: _otk));

  /// Was dieses Geraet UEBER FUNK antworten wuerde: ohne Einmalschluessel,
  /// nur der signierte EC- und der Last-Resort-Kyber-Prekey — genau die Karte
  /// aus `_schickeBuendelUeberFunk` (Audit PR-4).
  Map<String, Object?> funkKarte() =>
      karteAus(identitaet, _spk, kyber: _kyberLetzte);

  /// Das Leuchtfeuer, das dieses Geraet gerade aussendet, damit [wir] es
  /// finden.
  ///
  /// UEBER DAS cryptography-PAKET, waehrend der Kern libsignal nimmt. Das ist
  /// Absicht: genau so laeuft es im Betrieb auch nicht auf demselben Weg, und
  /// ein Test, der beide Seiten mit derselben Bibliothek rechnen liesse, waere
  /// gegen die eine Sorte Fehler blind, die hier wirklich weh tut.
  Future<Uint8List> leuchtfeuerFuer(Uint8List wir, DateTime zeit) async {
    final paar = await X25519().newKeyPairFromSeed(identitaet.keyPair.privateKey);
    final geheim = await Leuchtfeuer.gemeinsamesGeheimnis(
        eigenerSchluessel: paar, fremderOeffentlicher: wir);
    return Leuchtfeuer.eigenesFuer(
        geheimnis: geheim, eigenerOeffentlicher: oeffentlich, zeit: zeit);
  }

  /// Baut einen Umschlag, wie ihn ein zweites Telefon ueber die Naehe schickte.
  Future<Uint8List> umschlagAn(
      String empfaenger, RelayBundleResponse seinBuendel, Payload p) async {
    final ziel = adr(empfaenger);
    if (!await store.containsSession(ziel)) {
      await bauerVon(store)
          .processPreKeyBundle(ziel, PreKeyBundleBridge.fromRelay(seinBuendel));
    }
    final ct = await chiffreVon(store).encrypt(ziel, p.toBytes());
    return Envelope.of(ct).toBytes();
  }
}

/// Ein Buendel in der Form, in der der Relay (oder der Funk) es ausliefert.
///
/// [otk] fehlt beim Funk-Buendel — dort gehen seit 2.0.0 keine
/// Einmalschluessel mehr hinaus. [kyber] ist Pflicht: ohne ihn gibt es keine
/// Sitzung.
Map<String, Object?> karteAus(
  SignalIdentity id,
  SignedPreKeyRecord spk, {
  required KyberPreKeyRecord kyber,
  PreKeyRecord? otk,
}) =>
    {
      'user_id': id.address,
      'identity_key': base64.encode(id.rawPublicKey),
      'registration_id': id.registrationId,
      'signed_prekey_id': spk.id(),
      'signed_prekey': base64.encode(spk.publicKey()),
      'signed_prekey_sig': base64.encode(spk.signature()),
      'one_time_prekey': otk == null
          ? null
          : {'key_id': otk.id(), 'public_key': base64.encode(otk.publicKey())},
      'kyber_prekey_id': kyber.id(),
      'kyber_prekey': base64.encode(kyber.getPublicKey().serialize()),
      'kyber_prekey_sig': base64.encode(kyber.signature()),
    };

/// Dieselbe Karte ohne die Kyber-Felder — so sieht ein Buendel einer App vor
/// 2.0.0 aus.
Map<String, Object?> ohneKyber(Map<String, Object?> karte) => Map.of(karte)
  ..remove('kyber_prekey_id')
  ..remove('kyber_prekey')
  ..remove('kyber_prekey_sig');

void main() {
  late Directory ordner;
  late SpeicherImKopf tresor;
  late String dbPfad;
  late GebremsterFunk funk;
  late Nahbereich nah;
  late RealMessengerCore kern;
  late Gegenstelle anna;
  late List<String> woerter;

  /// Wessen Buendel der Relay ausliefern kann, nach Adresse.
  ///
  /// NICHT EINFACH IMMER ANNAS: der Speicher rechnet nach, ob der
  /// Identitaetsschluessel zu der Adresse gehoert, fuer die das Buendel kommt
  /// (signal_store.dart, `isTrustedIdentity` — die Adresse IST der
  /// Schluessel). Ein Buendel mit dem falschen Schluessel fliegt als
  /// UntrustedIdentityException heraus, und ein Test, der ein Buendel holen
  /// LAESST, um zu sehen, was danach passiert, kaeme nie bis dahin.
  late Map<String, Gegenstelle> gegenstellen;

  /// Wie viele Relay-Clients ueberhaupt entstanden sind. Der einzige Nachweis,
  /// der "kein Server" wirklich belegt — ein Zaehler auf `send` allein wuerde
  /// die Anmeldung und das Buendel uebersehen.
  var relaysGebaut = 0;
  SteuerbarerRelay? relay;

  /// Die Uhr des Tests. Ohne sie rechnete die Gegenstelle ihr Leuchtfeuer
  /// womoeglich in einem anderen Zeitfenster als der Kern das erwartete, und
  /// der Test waere alle 15 Minuten einmal rot.
  ///
  /// Sie laesst sich vorstellen, aber nur um Minuten: die Fenster sind 15
  /// Minuten lang, und wer darueber hinausspringt, prueft nebenbei den
  /// Fensterwechsel mit. Gebraucht wird das Vorstellen, um jemanden aus der
  /// Reichweite fallen zu lassen und wiederkommen zu lassen.
  var jetzt = DateTime.utc(2026, 7, 27, 12, 0);

  Future<void> warteBis(bool Function() fertig) async {
    for (var i = 0; i < 400 && !fertig(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    jetzt = DateTime.utc(2026, 7, 27, 12, 0);
    ordner = await Directory.systemTemp.createTemp('bitdm-nahweg');
    tresor = SpeicherImKopf();
    dbPfad = '${ordner.path}${Platform.pathSeparator}t.db';
    funk = GebremsterFunk();
    nah = Nahbereich(funk: funk, uhr: () => jetzt);
    anna = await Gegenstelle.neu();
    gegenstellen = {anna.adresse: anna};
    relaysGebaut = 0;
    relay = null;

    kern = RealMessengerCore(
      secretStore: tresor,
      databasePath: dbPfad,
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        relaysGebaut++;
        return relay =
            SteuerbarerRelay(id, (wen) => (gegenstellen[wen] ?? anna).antwort);
      },
      nahFactory: () => nah,
    );
    await kern.initialize();
    woerter = await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    await funk.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  /// Legt Anna als Kontakt an, OHNE etwas zu verschicken.
  ///
  /// Ueber `addContact` ginge sofort eine Kontaktanfrage hinaus, und in einem
  /// Test, der zaehlt, was hinausgeht, waere das eine Sendung, die nicht zur
  /// Sache gehoert.
  void legeAnnaAn() => kern.ablageFuerTest.speichereKontakt(
      Contact(id: anna.adresse, addedAt: DateTime.now().toUtc()));

  /// Legt eine ZWEITE Gegenstelle an, mit der es keine Sitzung gibt.
  ///
  /// Die erste Nachricht an sie braucht deshalb wirklich ein Buendel vom
  /// Relay — der Fall, um den es beim Schalter "nur in der Naehe" geht. Ihr
  /// Buendel wird dabei gleich beim Relay hinterlegt; ohne das kaeme statt
  /// des gemessenen Ablaufs eine UntrustedIdentityException heraus.
  Future<Gegenstelle> legeBertAn() async {
    final bert = await Gegenstelle.neu();
    gegenstellen[bert.adresse] = bert;
    kern.ablageFuerTest.speichereKontakt(
        Contact(id: bert.adresse, addedAt: DateTime.now().toUtc()));
    return bert;
  }

  /// Schaltet den Funk ein und wartet, bis er steht.
  Future<void> funkAn({bool nurNahbereich = false}) async {
    await kern.setPreferences(
        AppPreferences(naheAn: true, nurNahbereich: nurNahbereich));
    await kern.nahRuhtFuerTest;
  }

  /// Anna taucht in Reichweite auf.
  /// Setzt Annas Leuchtfeuer vor den Umschlag — so, wie es das echte Geraet tut.
  ///
  /// OHNE DIE MARKE KOMMT NICHTS AN, und das ist kein Testdetail: Android
  /// benutzt fuer die ausgehende GATT-Verbindung eine ANDERE Zufallsadresse
  /// als fuer die Werbung. Der Empfaenger kann den Absender deshalb nicht am
  /// Geraet erkennen — gemessen am 29.07.2026 auf zwei echten Telefonen, der
  /// Umschlag kam vollstaendig an und wurde verworfen.
  ///
  /// Es ist dasselbe Leuchtfeuer, das Anna ohnehin aussendet (siehe
  /// annaInReichweite). Genau deshalb verraet es nichts.
  ///
  /// Baut ein Paket beliebigen Typs, wie _schickeRoh es baut.
  Future<Uint8List> mitKopf(int typ, Uint8List inhalt) async {
    final marke =
        await anna.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt);
    final kopf = marke.length + Nahtyp.laenge;
    return Uint8List(kopf + inhalt.length)
      ..setAll(0, marke)
      ..[marke.length] = typ
      ..setAll(kopf, inhalt);
  }

  /// Welchen Typ das zuletzt Gesendete trug, und was drinstand.
  ({int typ, Uint8List inhalt})? letztesPaket() {
    if (funk.gesendet.isEmpty) return null;
    final r = funk.gesendet.last.umschlag;
    const kopf = leuchtfeuerLaenge + Nahtyp.laenge;
    if (r.length < kopf) return null;
    return (typ: r[leuchtfeuerLaenge], inhalt: Uint8List.sublistView(r, kopf));
  }

  Future<Uint8List> mitMarke(Uint8List umschlag) async {
    final marke =
        await anna.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt);
    // Marke, dann Typbyte, dann Inhalt — genau wie _schickeRoh es baut.
    final kopf = marke.length + Nahtyp.laenge;
    return Uint8List(kopf + umschlag.length)
      ..setAll(0, marke)
      ..[marke.length] = Nahtyp.umschlag
      ..setAll(kopf, umschlag);
  }

  Future<void> annaInReichweite() async {
    funk.sieh(Gesehen(
      geraet: 'AA:11',
      rssi: -40,
      leuchtfeuer: [await anna.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt)],
    ));
    await Future<void>.delayed(Duration.zero);
    expect(nah.inReichweite, [anna.adresse],
        reason: 'ohne Anna in Reichweite prueft der Test darunter nichts');
  }

  /// Sorgt fuer eine Sitzung mit Anna — ueber den Relay, wie im Betrieb.
  ///
  /// Danach braucht kein Weg mehr einen Server: das ist die Voraussetzung
  /// dafuer, dass die Naehe ueberhaupt etwas tragen kann.
  Future<void> sitzungAufbauen() async {
    await kern.connect();
    expect(kern.connectionState, ConnectionState.online);
    await kern.sendMessage(anna.adresse, 'der Sitzungsaufbau');
    await warteBis(() => relay!.gesendet.isNotEmpty);
    relay!.gesendet.clear();
  }

  Future<Message> letzte() async =>
      (await kern.getMessages(anna.adresse)).last;

  /// Anna schreibt UEBER DEN RELAY. Der Weg, auf dem eine App jemanden
  /// kennenlernt, der zuerst geschrieben hat — und der einzige, der ohne
  /// vorherigen Nahbereich funktioniert.
  ///
  /// [q] ist die Kennung der Zeile in der Warteschlange des Relays. Ohne sie
  /// gibt es nichts zu bestaetigen — ein Umschlag ohne Zeile bekommt keinen
  /// Nachweis, genau wie einer aus der Luft.
  Future<void> annaSchreibtUeberRelay(String id, String text, {int? q}) async {
    final p = Payload.text(id, text, jetzt);
    relay!.herein(RelayMessage(
      from: anna.adresse,
      ciphertext:
          await anna.umschlagAn(kern.myId, await unserBuendel(kern, woerter), p),
      at: jetzt,
      q: q,
    ));
  }

  group('Welchen Weg eine Nachricht nimmt', () {
    test('RELAY ZUERST, auch wenn Anna direkt neben einem steht', () async {
      // Regel 1. Der gewohnte Weg bleibt der Hauptweg — er kommt auch an, wenn
      // Anna gleich weggeht. Die Naehe ist die Ausfallsicherung, nicht der
      // Normalfall.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();

      await kern.sendMessage(anna.adresse, 'ueber den Server');
      await warteBis(() => relay!.gesendet.isNotEmpty);

      expect(relay!.gesendet, hasLength(1));
      expect(funk.gesendet, isEmpty,
          reason: 'zwei Wege fuer dieselbe Nachricht waeren zwei '
              'Verschluesselungen desselben Textes');
      // DER STATUS KOMMT NACH DEM VERSAND, nicht mit ihm: erst geht der
      // Umschlag hinaus, dann wird "gesendet" festgeschrieben. Mit der
      // offiziellen libsignal (seit 2.0.0) dauert das einen Moment laenger,
      // und ein sofortiges Nachsehen fand im Gesamtlauf vom 16.10.2026
      // manchmal noch "wird gesendet".
      var m = await letzte();
      for (var i = 0; i < 300 && m.status != MessageStatus.sent; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        m = await letzte();
      }
      expect(m.status, MessageStatus.sent);
      expect(m.ueberNaehe, isFalse);
    });

    test('IST DER RELAY WEG, traegt die Naehe — und das Zeichen steht dran',
        () async {
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();

      // Die Leitung bricht ab. Der Client steht noch da, aber er traegt nichts
      // mehr — genau der Zustand, fuer den die Naehe gebaut ist.
      relay!.verbunden = false;

      await kern.sendMessage(anna.adresse, 'von Telefon zu Telefon');
      await warteBis(() => funk.gesendet.isNotEmpty);

      expect(funk.gesendet, hasLength(1));
      expect(funk.gesendet.single.geraet, 'AA:11');
      expect(relay!.gesendet, isEmpty);

      // DER STATUS KOMMT NACH DEM VERSAND, nicht mit ihm: erst geht der
      // Umschlag hinaus, dann wird "gesendet" festgeschrieben. Mit der
      // offiziellen libsignal (seit 2.0.0) dauert das einen Moment laenger,
      // und ein sofortiges Nachsehen fand im Gesamtlauf vom 16.10.2026
      // manchmal noch "wird gesendet".
      var m = await letzte();
      for (var i = 0; i < 300 && m.status != MessageStatus.sent; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        m = await letzte();
      }
      expect(m.status, MessageStatus.sent);
      expect(m.ueberNaehe, isTrue,
          reason: 'ohne das Zeichen saehe eine Nachricht, die keinen Server '
              'gesehen hat, aus wie jede andere');
    });

    test('WAEHREND SIE NOCH HINAUSGEHT, schickt der Nachversand sie nicht '
        'ein zweites Mal', () async {
      // Gefunden im Gesamtlauf vom 16.10.2026: Der erste Versand laeuft
      // unabgewartet, und die Nachricht steht bis zu seinem Ende auf
      // "sending". Kommt in diesem Fenster jemand in Reichweite (oder steht
      // die Verbindung wieder), liest der Nachversand dieselbe Nachricht aus
      // der Liste und schickt sie noch einmal. Beim Empfaenger kaeme sie
      // zweimal an, als zwei Verschluesselungen desselben Textes.
      legeAnnaAn();
      await funkAn();
      await kern.connect();

      final tor = relay!.sendeTor = Completer<void>();
      await kern.sendMessage(anna.adresse, 'nur einmal');
      await warteBis(() => relay!.gesendet.isNotEmpty);
      expect(relay!.gesendet, hasLength(1));

      // Anna taucht auf, solange der Relay noch nicht bestaetigt hat. Das
      // stoesst den Nachversand an.
      await annaInReichweite();
      await kern.nachversandRuhtFuerTest;
      expect(relay!.gesendet, hasLength(1),
          reason: 'der Nachversand schickte eine Nachricht, deren erster '
              'Versand noch lief');
      expect(funk.gesendet, isEmpty);

      tor.complete();
      var m = await letzte();
      for (var i = 0; i < 300 && m.status != MessageStatus.sent; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        m = await letzte();
      }
      expect(m.status, MessageStatus.sent);
      // Der uebersprungene Anlauf wird nachgeholt, findet aber nichts mehr.
      await kern.nachversandRuhtFuerTest;
      expect(relay!.gesendet, hasLength(1));
      expect(funk.gesendet, isEmpty);
    });

    test('REGEL 2: wirft der Relay, bleibt sie LIEGEN — kein Wechsel',
        () async {
      // DIE GEFAEHRLICHSTE STELLE IM GANZEN NAHEBEREICH.
      //
      // Der Relay hat geworfen. Das heisst NICHT, dass die Nachricht nicht
      // angekommen ist — sie kann drueben liegen und nur die Bestaetigung ist
      // verlorengegangen. Sie jetzt zusaetzlich ueber die Naehe zu schicken
      // hiesse, sie moeglicherweise zweimal zuzustellen: zwei Blasen beim
      // Empfaenger und zwei Schluesselketten im Double Ratchet.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();

      relay!.sendenWirft = true;

      await kern.sendMessage(anna.adresse, 'darf nicht doppelt ankommen');
      // Ein Moment, in dem der Wechsel haette stattfinden koennen.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(funk.gesendet, isEmpty,
          reason: 'nach einem gescheiterten Relay-Versuch darf NICHTS mehr '
              'ueber die Naehe gehen');
      final m = await letzte();
      expect(m.status, MessageStatus.sending,
          reason: 'liegengeblieben, nicht gescheitert — die App holt das beim '
              'naechsten Verbinden selbst nach');
      expect(m.ueberNaehe, isFalse);
    });
  });

  group('Wer auf dem Empfangsweg dazukommt', () {
    test('KOMMT ERST MIT DER ANNAHME IN DEN NAHBEREICH, nicht schon mit '
        'seiner Nachricht', () async {
      // GEAENDERT AM 16.10.2026. Bis dahin pruefte dieser Test das
      // Gegenteil: dass ein beim Empfangen angelegter Kontakt sofort im
      // Nahbereich landet, mit der Begruendung „sonst findet ihn nie jemand“.
      // Das Verfahren laeuft in beide Richtungen, jedes Leuchtfeuer haengt am
      // gemeinsamen Geheimnis — wer selbst keines aussendet, wird auch nicht
      // gefunden.
      //
      // Die Begruendung stimmt, die Grenze lag falsch. Ein Eingang legt den
      // Absender als `incomingPending` an, und das kann JEDER, der die
      // Adresse kennt. Eine einzige Nachricht genuegte damit, um das
      // Leuchtfeuer fuer einen Fremden einzuschalten — und ausrechnen kann er
      // es selbst, aus seinem eigenen Schluessel und der oeffentlichen
      // Adresse des Empfaengers. Er erkennt das Opfer danach in
      // Funkreichweite wieder, ohne dass dessen Nutzer je etwas angenommen
      // hat; bei einer ignorierten Anfrage dauerhaft. Das widerspricht
      // data.dart („nur wer dich als Kontakt hat, erkennt, dass du es bist“)
      // und NAHBEREICH.md („Fremde sind unsichtbar — von Bauart“).
      //
      // Jetzt gilt: mit der Annahme, nicht mit der Nachricht. Der Kontakt,
      // neben dem man am ehesten steht, ist danach weiter dabei — nur eben
      // nach der Einwilligung. Wer diese Grenze verschiebt, macht diesen Test
      // rot und muss die beiden Texte mit aendern.
      await funkAn();
      expect(funk.werbungen, isEmpty,
          reason: 'noch gibt es keinen Kontakt, fuer den zu werben waere');

      await kern.connect();
      await annaSchreibtUeberRelay('erste', 'hallo, ich bin neu');
      await warteBis(
          () => kern.ablageFuerTest.verlauf(anna.adresse).isNotEmpty);
      await kern.nahRuhtFuerTest;

      expect(kern.ablageFuerTest.kontakt(anna.adresse)?.state,
          ContactState.incomingPending,
          reason: 'ohne diesen Zustand prueft der Test darunter nichts');
      expect(funk.werbungen, isEmpty,
          reason: 'eine offene Anfrage darf kein Leuchtfeuer ausloesen');

      // DIE ANNAHME SCHALTET IHN FREI, und zwar sofort — nicht erst beim
      // naechsten anderen Anlass.
      await kern.acceptRequest(anna.adresse);
      await warteBis(() => funk.werbungen.isNotEmpty);
      await kern.nahRuhtFuerTest;

      expect(funk.werbungen, isNotEmpty,
          reason: 'nach der Annahme wird fuer sie geworben');
      expect(funk.werbungen.last, hasLength(1));
      // Und die Gegenprobe in der anderen Richtung: ihr Leuchtfeuer steht
      // jetzt auch in der Tabelle.
      await annaInReichweite();
    });

    test('aber NICHT bei jeder Nachricht neu', () async {
      // Neu aufsetzen heisst anhalten und wieder anfangen. Wer in Reichweite
      // ist, ist danach unbekannt, und der Funk geht bei jeder Zeile eines
      // lebhaften Gespraechs aus und wieder an. Die Bedingung ist deshalb
      // nicht "eine Nachricht kam", sondern "die Kontaktliste ist eine
      // andere".
      legeAnnaAn();
      await funkAn();
      await kern.connect();
      await annaInReichweite();
      final werbungen = funk.werbungen.length;

      for (var i = 0; i < 3; i++) {
        await annaSchreibtUeberRelay('m$i', 'noch was $i');
      }
      await warteBis(
          () => kern.ablageFuerTest.verlauf(anna.adresse).length >= 3);
      await kern.nahRuhtFuerTest;

      expect(funk.werbungen.length, werbungen,
          reason: 'die Kontaktliste ist dieselbe geblieben');
      expect(nah.inReichweite, [anna.adresse],
          reason: 'sie stand die ganze Zeit daneben');
    });
  });

  group('Nur in der Naehe', () {
    test('NIEMALS EIN SERVER, auch nicht fuer ein Buendel', () async {
      // Der Schalter verspricht, dass NICHTS an einen Server geht. Die erste
      // Nachricht an einen neuen Kontakt braucht aber ein Prekey-Buendel, und
      // das liegt beim Relay. Die einzige ehrliche Antwort darauf ist: die
      // Nachricht bleibt liegen.
      //
      // GEMESSEN IST DAS NUR, WENN EIN RELAY DASTEHT, DER ANTWORTEN WUERDE.
      // Diese Zusicherung stand hier schon einmal, und sie hat nichts
      // gemessen: der Test verband nie, der Kern hatte gar keinen Relay, und
      // der Ablauf endete in einer NotInitializedException. Die Sperre liess
      // sich ersatzlos loeschen, ohne dass ein einziger Test rot wurde.
      //
      // Deshalb hier der umgekehrte Aufbau: erst verbinden, dann den Schalter
      // umlegen — und den Kern in dem Moment festhalten, in dem der Schalter
      // schon gilt und die Verbindung noch steht (siehe [GebremsterFunk]).
      // BERT ist der neue Kontakt: mit ihm gibt es keine Sitzung, seine
      // Nachricht braucht also wirklich ein Buendel.
      legeAnnaAn();
      final bert = await legeBertAn();
      await sitzungAufbauen();
      final abrufeVorher = relay!.buendelAbrufe;

      funk.bremseBeimWerben();
      final umlegen = kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: true));
      await warteBis(() => funk.stehtBeimWerben);
      expect(funk.stehtBeimWerben, isTrue,
          reason: 'ohne die Bremse ist die Verbindung schon abgeraeumt, und '
              'der Test misst wieder nur einen fehlenden Relay');
      expect(kern.connectionState, ConnectionState.online,
          reason: 'der Relay steht noch — er koennte ein Buendel liefern');

      await kern.sendMessage(bert.adresse, 'ohne Sitzung geht es nicht');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(relay!.buendelAbrufe, abrufeVorher,
          reason: 'der Schalter sagt "kein Server", und ein Buendel zu holen '
              'waere eine Anfrage an genau den');
      expect(relay!.gesendet, isEmpty);
      expect(funk.gesendet, isEmpty,
          reason: 'ohne Sitzung gibt es keinen Chiffretext zu tragen');
      expect((await kern.getMessages(bert.adresse)).single.status,
          MessageStatus.sending);

      funk.lassLaufen();
      await umlegen;
      expect(relaysGebaut, 1,
          reason: 'der eine aus dem Sitzungsaufbau — und kein zweiter');
    });

    test('DIE GEGENPROBE: ohne den Schalter wird an derselben Stelle geholt',
        () async {
      // Derselbe Aufbau, nur der Schalter bleibt aus. Ohne sie stuende der
      // Test darueber wieder da, wo er herkam: gruen, weil an dieser Stelle
      // ueberhaupt kein Buendel zu holen gewesen waere.
      legeAnnaAn();
      final bert = await legeBertAn();
      await sitzungAufbauen();
      final abrufeVorher = relay!.buendelAbrufe;

      funk.bremseBeimWerben();
      final umlegen = kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: false));
      await warteBis(() => funk.stehtBeimWerben);

      await kern.sendMessage(bert.adresse, 'die darf ueber den Server');
      await warteBis(() => relay!.gesendet.isNotEmpty);

      expect(relay!.buendelAbrufe, abrufeVorher + 1,
          reason: 'genau hier haette der Schalter etwas zu verhindern');
      expect(relay!.gesendet, hasLength(1));

      funk.lassLaufen();
      await umlegen;
    });

    test('mit bestehender Sitzung geht sie sehr wohl — und ohne Server',
        () async {
      // DIE GEGENPROBE. Ohne sie koennte der Test darueber auch dann bestehen,
      // wenn "nur in der Naehe" schlicht gar nichts sendet.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();
      final abrufeVorher = relay!.buendelAbrufe;

      await kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: true));
      await kern.nahRuhtFuerTest;

      await kern.sendMessage(anna.adresse, 'nur ueber die Luft');
      await warteBis(() => funk.gesendet.isNotEmpty);

      expect(funk.gesendet, hasLength(1));
      expect(relaysGebaut, 1,
          reason: 'der eine aus dem Sitzungsaufbau — und kein zweiter');
      expect(relay!.buendelAbrufe, abrufeVorher);
      expect((await letzte()).ueberNaehe, isTrue);
    });

    test('EIN NEUER KONTAKT ENTSTEHT NICHT UEBER FUNK — die Anfrage wartet '
        'auf den Relay', () async {
      // AN DIESEM TEST HAENGT DIE ANLEITUNG (data.dart: nearStep1,
      // nearOnlyWarnRadio, nearGuideBackBody): "werdet vorher Kontakte, mit
      // Internet". Das Schluesselbuendel reist zwar ueber Funk (Gruppe "Das
      // Schluesselbuendel ueber Funk"), die Kontaktanfrage aber nicht — sie
      // wird nur aus connect() nachgeschickt, und mit "nur in der Naehe" gibt
      // es kein Verbinden. Bis 15.10.2026 versprach nearOnlyWarnRadio das
      // Gegenteil. Wer die Anfrage ueber Funk baut, macht diesen Test rot und
      // muss die Texte mit aendern.
      await funkAn(nurNahbereich: true);
      final bert = await Gegenstelle.neu();
      gegenstellen[bert.adresse] = bert;

      await kern.addContact(bert.adresse);
      await kern.nahRuhtFuerTest;

      // Bert steht daneben und hat uns seinerseits schon aufgenommen — sonst
      // saehe ihn der Funk gar nicht. Der guenstigste Fall also.
      funk.sieh(Gesehen(
          geraet: 'BB:22',
          rssi: -40,
          leuchtfeuer: [
            await bert.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt)
          ]));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, contains(bert.adresse),
          reason: 'ohne Bert in Reichweite prueft der Test darunter nichts');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(funk.gesendet, isEmpty,
          reason: 'etwas ging ueber Funk an Bert — dann stimmt die Anleitung '
              'nicht mehr');
      expect(relaysGebaut, 0, reason: 'und an einen Server schon gar nicht');
      expect((await kern.getContacts()).single.state,
          ContactState.outgoingPending,
          reason: 'die Oberflaeche zeigt ihn als ausstehende Anfrage, und '
              'schreiben laesst sie erst nach der Bestaetigung (reqSentNote)');

      // DIE GEGENPROBE, und zugleich das Versprechen von nearGuideBackBody:
      // Schalter aus, und die Anfrage geht ueber den Relay hinaus.
      await kern.setPreferences(const AppPreferences(naheAn: true));
      await warteBis(
          () => relay?.gesendet.any((g) => g.an == bert.adresse) ?? false);
      expect(relay!.gesendet.where((g) => g.an == bert.adresse), hasLength(1),
          reason: 'nach dem Ausschalten muss die Anfrage von selbst hinaus');
    });
  });

  group('Was liegenblieb, geht nach', () {
    test('KOMMT ANNA ZURUECK, geht es hinaus — auch ohne jeden Server',
        () async {
      // REGEL 4 IN DEM MODUS, IN DEM DIE NAEHE DER EINZIGE WEG IST.
      //
      // "Liegen" heisst: die App versucht es wieder. Angestossen wurde der
      // Nachversand aber nur von connect(), und mit "nur in der Naehe" gibt
      // es kein Verbinden — die Nachricht blieb fuer immer auf "sending"
      // stehen, auch wenn der Empfaenger wieder danebenstand. Von Hand
      // nachhelfen konnte niemand: MessageStatus.failed wird nirgends
      // gesetzt, es gibt also auch keinen Knopf.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: true));
      await kern.nahRuhtFuerTest;

      // Anna ist NICHT in Reichweite.
      await kern.sendMessage(anna.adresse, 'wartet auf sie');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(funk.gesendet, isEmpty);
      expect((await letzte()).status, MessageStatus.sending);

      await annaInReichweite();
      await warteBis(() => funk.gesendet.isNotEmpty);

      expect(funk.gesendet, hasLength(1));
      // DER STATUS KOMMT NACH DEM VERSAND, nicht mit ihm: erst geht der
      // Umschlag hinaus, dann wird "gesendet" festgeschrieben. Mit der
      // offiziellen libsignal (seit 2.0.0) dauert das einen Moment laenger,
      // und ein sofortiges Nachsehen fand im Gesamtlauf vom 16.10.2026
      // manchmal noch "wird gesendet".
      var m = await letzte();
      for (var i = 0; i < 300 && m.status != MessageStatus.sent; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        m = await letzte();
      }
      expect(m.status, MessageStatus.sent);
      expect(m.ueberNaehe, isTrue);
    });

    test('ZWEI, DIE GLEICHZEITIG AUFTAUCHEN, schicken nichts doppelt',
        () async {
      // Jeder von beiden stoesst einen Nachversand an. Laufen die beiden
      // ineinander, lesen sie dieselbe Liste — die Nachricht steht noch auf
      // "sending", weil der erste Lauf an seinem ersten Wartepunkt haengt —
      // und schicken sie beide. Dann waere dieselbe Nachricht zweimal ueber
      // die Luft, mit zwei Verschluesselungen desselben Textes.
      final bert = await Gegenstelle.neu();
      legeAnnaAn();
      kern.ablageFuerTest.speichereKontakt(
          Contact(id: bert.adresse, addedAt: DateTime.now().toUtc()));
      await funkAn();
      await sitzungAufbauen();
      await kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: true));
      await kern.nahRuhtFuerTest;

      await kern.sendMessage(anna.adresse, 'genau einmal');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(funk.gesendet, isEmpty);

      // Beide in derselben Werbung, von zwei verschiedenen Geraeten — ohne
      // einen Wartepunkt dazwischen, sonst waere der Wettlauf entschaerft.
      final wir = BitdmAddress.decode(kern.myId);
      funk.sieh(Gesehen(
          geraet: 'AA:11',
          rssi: -40,
          leuchtfeuer: [await anna.leuchtfeuerFuer(wir, jetzt)]));
      funk.sieh(Gesehen(
          geraet: 'BB:22',
          rssi: -40,
          leuchtfeuer: [await bert.leuchtfeuerFuer(wir, jetzt)]));

      await warteBis(() => funk.gesendet.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(funk.gesendet, hasLength(1),
          reason: 'zwei Anstoesse, aber nur eine Nachricht');
    });

    test('WAS SCHON BEIM RELAY WAR, geht auch spaeter nicht ueber die Naehe',
        () async {
      // REGEL 2 UEBER DEN EINZELNEN VERSANDVERSUCH HINAUS.
      //
      // Der erste Versuch ueber den Relay hat geworfen — und das heisst
      // NICHT, dass die Nachricht nicht drueben liegt: RelayClient.send
      // schreibt erst in die Leitung und wartet dann auf die Bestaetigung.
      // Ein abgelaufener Ack heisst "raus, Bestaetigung verloren".
      //
      // Ohne Gedaechtnis bekommt der naechste Anlauf eine frische Wegwahl,
      // die frei waehlt. Dann ist dieselbe Nachricht ueber zwei Wege
      // draussen, und sie traegt das Zeichen "DIRECT" — dessen Zusage
      // lautet, kein Server habe auch nur gesehen, dass hier jemand
      // schreibt.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();

      relay!.sendenWirft = true;
      await kern.sendMessage(anna.adresse, 'koennte schon drueben liegen');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(funk.gesendet, isEmpty, reason: 'so weit hielt Regel 2 schon');
      expect((await letzte()).status, MessageStatus.sending);

      // Jetzt faellt die Leitung ganz aus, Anna geht und kommt wieder — der
      // Nachversand greift die Nachricht auf.
      relay!.verbunden = false;
      jetzt = jetzt.add(const Duration(seconds: 91));
      await annaInReichweite();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(funk.gesendet, isEmpty,
          reason: 'dieselbe Nachricht ueber zwei Wege — genau das verbietet '
              'Regel 2');
      final m = await letzte();
      expect(m.status, MessageStatus.sending);
      expect(m.ueberNaehe, isFalse,
          reason: '"kein Server war beteiligt" waere schlicht unwahr');
    });

    test('DIE GEGENPROBE: was nie beim Relay war, darf sehr wohl', () async {
      // Ohne sie koennte der Test darueber auch dann bestehen, wenn der
      // Nachversand ueber die Naehe gar nicht funktioniert. Derselbe Ablauf,
      // nur ohne den gescheiterten Relay-Versuch.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();

      // Die Leitung faellt aus, BEVOR etwas versucht wurde: der Relay ist
      // nicht mehr `bereit`, also fasst die Wegwahl ihn nicht an.
      relay!.verbunden = false;
      await kern.sendMessage(anna.adresse, 'die war nie drueben');
      await warteBis(() => funk.gesendet.isNotEmpty);

      expect(funk.gesendet, hasLength(1));
      expect((await letzte()).ueberNaehe, isTrue);
    });

    test('und der Vermerk ueberlebt einen Neustart', () async {
      // Er MUSS auf der Platte stehen: gelesen wird er von `unversandt()`,
      // und das ist genau die Abfrage, die nach einem Neustart aus der Datei
      // holt, was liegengeblieben ist. Ein Vermerk im Arbeitsspeicher fehlte
      // in dem einen Fall, fuer den es ihn gibt.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      relay!.sendenWirft = true;
      await kern.sendMessage(anna.adresse, 'einmal draussen gewesen');
      await warteBis(
          () => kern.ablageFuerTest.unversandt().isNotEmpty &&
              kern.ablageFuerTest.unversandt().single.schonBeimRelay);

      expect(kern.ablageFuerTest.unversandt().single.schonBeimRelay, isTrue);
    });
  });

  group('Was hereinkommt', () {
    test('ein Umschlag ueber die Naehe landet im Verlauf, mit Zeichen',
        () async {
      // KEIN RELAY IN DIESEM TEST. Der Kern verbindet nie; wenn die Nachricht
      // trotzdem im Verlauf steht, kann sie nur ueber die Luft gekommen sein.
      legeAnnaAn();
      await funkAn();
      await annaInReichweite();

      final p = Payload.text('nachricht-1', 'von draussen', jetzt);
      final umschlag =
          await anna.umschlagAn(kern.myId, await unserBuendel(kern, woerter), p);

      final eingang = <Message>[];
      final abo = kern.incomingMessages.listen(eingang.add);
      funk.empfange(Eingegangen('AA:11', await mitMarke(umschlag)));
      await warteBis(() => eingang.isNotEmpty);
      await abo.cancel();

      expect(eingang, hasLength(1));
      expect(eingang.single.text, 'von draussen');

      final verlauf = await kern.getMessages(anna.adresse);
      expect(verlauf.single.text, 'von draussen');
      expect(verlauf.single.ueberNaehe, isTrue);
      expect(relaysGebaut, 0,
          reason: 'ein Umschlag aus der Luft darf keinen Server anfassen');
    });

    test('bestaetigt wird dabei NICHTS — es gibt keine Zeile', () async {
      // Der Nachweis loescht eine Zeile in der Warteschlange des Relays. Fuer
      // einen Umschlag aus der Luft gibt es keine; einen Nachweis dafuer zu
      // schicken hiesse, dem Relay etwas ueber eine Nachricht zu erzaehlen,
      // von der er nie erfahren hat.
      //
      // ZWEI MESSUNGEN, WEIL EINE ABWESENHEIT ALLEIN NICHTS SAGT. Dass nichts
      // bestaetigt wurde, ist auch dann wahr, wenn die Nachricht ueberhaupt
      // nicht angekommen ist und wenn ueberhaupt nie etwas bestaetigt wird.
      // Beides muss ausgeschlossen sein, sonst steht hier eine Zusicherung,
      // die aus dem falschen Grund haelt: der Nah-Eingang liess sich
      // abschalten, ohne dass dieser Test rot wurde.
      legeAnnaAn();
      await funkAn();
      await sitzungAufbauen();
      await annaInReichweite();
      final vorher = relay!.bestaetigt.length;

      final p = Payload.text('nachricht-2', 'still', jetzt);
      final umschlag =
          await anna.umschlagAn(kern.myId, await unserBuendel(kern, woerter), p);
      funk.empfange(Eingegangen('AA:11', await mitMarke(umschlag)));
      await warteBis(
          () => (kern.ablageFuerTest.verlauf(anna.adresse).length) > 1);

      // ERSTENS: sie IST durchgelaufen. Ohne diese Zeile prueft die naechste
      // nur, dass ein Ablauf, der gar nicht stattgefunden hat, nichts
      // bestaetigt hat.
      expect((await letzte()).text, 'still',
          reason: 'der Umschlag aus der Luft ist nicht im Verlauf gelandet — '
              'was danach kommt, misst nichts');
      expect(relay!.bestaetigt, hasLength(vorher));

      // ZWEITENS DIE GEGENPROBE: derselbe Weg durch dieselbe Buchfuehrung,
      // nur mit einer Zeile beim Relay. Ohne sie bliebe der Test auch dann
      // gruen, wenn gar nichts mehr bestaetigt wuerde.
      await annaSchreibtUeberRelay('nachricht-3', 'ueber den Server', q: 77);
      await warteBis(() => relay!.bestaetigt.length > vorher);

      expect(relay!.bestaetigt.skip(vorher), [77],
          reason: 'wo es eine Zeile gibt, wird sie sehr wohl bestaetigt');
    });
  });

  group('Wer nicht mitmacht', () {
    test('ein Kontakt mit abgeschalteter Anwesenheit ist NICHT im Nahbereich',
        () async {
      // Beides zusammen: kein Leuchtfeuer fuer ihn, und keines von ihm
      // erwartet. Nur das eine hiesse, ihn nicht mehr zu finden, ihm aber
      // weiter zu zeigen, wo man ist.
      legeAnnaAn();
      await funkAn();
      expect(funk.werbungen.last, hasLength(1),
          reason: 'mit Anwesenheit wird fuer sie geworben');

      await kern.setContactPresence(anna.adresse, false);
      await kern.nahRuhtFuerTest;

      expect(funk.werbungen.last, hasLength(1),
          reason: 'es kam keine neue Werbung dazu — es gibt niemanden mehr, '
              'fuer den geworben wuerde');
      funk.sieh(Gesehen(
        geraet: 'AA:11',
        rssi: -40,
        leuchtfeuer: [
          await anna.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt)
        ],
      ));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, isEmpty,
          reason: 'ihr Leuchtfeuer steht in keiner Tabelle mehr');
    });

    test('OHNE DEN SCHALTER LAEUFT DER FUNK GAR NICHT', () async {
      // MIT EINEM KONTAKT, DER UEBER DIE APP HEREINKOMMT — sonst misst dieser
      // Test den Schalter nicht.
      //
      // `legeAnnaAn` schreibt an der App vorbei in die Ablage, und niemand
      // richtet daraufhin den Nahbereich ein. Der Kern haette ihn dann zuletzt
      // beim Oeffnen angesehen, mit leerer Kontaktliste — und ohne Kontakte
      // faengt der Funk ohnehin nicht an (nahbereich.dart, `starte`). Gemessen
      // waere dann die leere Liste und nicht der Schalter: streicht man
      // `!_prefs.naheAn` aus `_setzeNaheAuf`, bleibt so ein Test gruen.
      //
      // `addContact` ist der Weg, den ein Kontakt im Betrieb nimmt, und er
      // richtet den Nahbereich neu ein. Die Kontaktanfrage, die dabei
      // hinausgeht, findet keinen Weg und bleibt liegen — hier stoert sie
      // nicht, gezaehlt wird in diesem Test nichts Ausgehendes.
      await kern.addContact(anna.adresse);
      await kern.nahRuhtFuerTest;

      expect(funk.werbungen, isEmpty);
      expect(funk.suchtGerade, isFalse);
      expect(funk.postfachOffen, isFalse);
      expect(nah.bereit, isFalse);

      // UND ES WIRD AUCH NICHT HINGEHOERT. Nur nicht zu senden hiesse, sich
      // still zu verhalten und trotzdem mitzuschreiben, wer vorbeikommt.
      funk.sieh(Gesehen(
        geraet: 'AA:11',
        rssi: -40,
        leuchtfeuer: [
          await anna.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt)
        ],
      ));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, isEmpty);

      // DIE GEGENPROBE, an derselben Kontaktliste: der Schalter ist das
      // Einzige, was sich aendert.
      await funkAn();
      expect(funk.werbungen, hasLength(1));
      expect(funk.suchtGerade, isTrue);
      expect(funk.postfachOffen, isTrue);
      await annaInReichweite();
      expect(nah.bereit, isTrue);
    });

    test('und dann traegt die Naehe auch nichts, wenn der Relay ausfaellt',
        () async {
      // Die Wirkung des Schalters, nicht nur sein Zustand. Ohne diesen Test
      // koennte der Funk stillstehen und die Wegwahl trotzdem ueber ihn
      // schicken.
      legeAnnaAn();
      await sitzungAufbauen();
      relay!.verbunden = false;

      await kern.sendMessage(anna.adresse, 'bleibt hier');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(funk.gesendet, isEmpty);
      expect((await letzte()).status, MessageStatus.sending);
    });
  });

  group('Das Schluesselbuendel ueber Funk', () {
    // WOFUER DIESE GRUPPE DA IST
    //
    // Mit "nur in der Naehe" blieb die ERSTE Nachricht an einen neuen Kontakt
    // fuer immer liegen: eine Sitzung braucht das Buendel der Gegenseite, und
    // das holte die App ausschliesslich vom Relay. Ein Messenger, der ohne
    // Internet arbeiten soll, kam ohne Internet nie ins Gespraech.
    //
    // Der Weg darueber ist neu und war beim Schreiben dieser Zeilen durch
    // NICHTS abgedeckt — die Sammlung waere gruen geblieben, wenn er gar
    // nichts taete. Genau davor warnt der Rest dieser Datei an drei Stellen.

    test('OHNE SITZUNG GEHT EINE ANFRAGE RAUS, statt liegenzubleiben',
        () async {
      // MIT BERT UND NICHT MIT ANNA, und das ist der ganze Punkt: mit Anna
      // besteht an dieser Stelle laengst eine Sitzung, und dann ist der
      // Anfragezweig zu Recht nicht der richtige. Der Test lief deshalb
      // zuerst ins Leere und stand eine Weile auf `skip` — `legeBertAn` gibt
      // es genau fuer diesen Fall und ich hatte es uebersehen.
      final bert = await legeBertAn();
      await funkAn(nurNahbereich: true);
      final wir = BitdmAddress.decode(kern.myId);
      funk.sieh(Gesehen(
          geraet: 'BB:22',
          rssi: -40,
          leuchtfeuer: [await bert.leuchtfeuerFuer(wir, jetzt)]));
      await Future<void>.delayed(Duration.zero);
      funk.gesendet.clear();

      await kern.sendMessage(bert.adresse, 'die allererste');
      await warteBis(() => funk.gesendet.isNotEmpty);

      final r = funk.gesendet.last.umschlag;
      expect(r.length, greaterThanOrEqualTo(leuchtfeuerLaenge + Nahtyp.laenge));
      expect(r[leuchtfeuerLaenge], Nahtyp.buendelAnfrage,
          reason: 'ohne Anfrage kann die Gegenseite nichts schicken, und die '
              'Nachricht bliebe fuer immer stehen — genau der Zustand, in dem '
              'BitDM ohne Internet gar nicht erst ins Gespraech kam');
      expect(r.length, leuchtfeuerLaenge + Nahtyp.laenge,
          reason: 'eine Anfrage traegt nichts ausser Marke und Typ');

      // Und die Nachricht selbst wartet weiter, statt verlorenzugehen.
      expect(kern.ablageFuerTest.unversandt(), isNotEmpty,
          reason: 'die Nachricht muss liegenbleiben, bis das Buendel da ist');
    });

    /// Fragt ueber Funk nach unserem Buendel und gibt die Antwort als Karte.
    Future<Map<String, Object?>> frageNachBuendel() async {
      funk.gesendet.clear();
      funk.empfange(Eingegangen(
          'AA:11', await mitKopf(Nahtyp.buendelAnfrage, Uint8List(0))));
      await warteBis(() => funk.gesendet.isNotEmpty);
      final p = letztesPaket()!;
      expect(p.typ, Nahtyp.buendelAntwort);
      return (jsonDecode(utf8.decode(p.inhalt)) as Map).cast<String, Object?>();
    }

    /// Eine Buendel-Antwort, die von Anna ueber Funk hereinkommt.
    Future<void> annaAntwortet(Map<String, Object?> karte) async =>
        funk.empfange(Eingegangen(
            'AA:11',
            await mitKopf(Nahtyp.buendelAntwort,
                Uint8List.fromList(utf8.encode(jsonEncode(karte))))));

    test('EINE ANFRAGE WIRD MIT DEM EIGENEN BUENDEL BEANTWORTET', () async {
      legeAnnaAn();
      await funkAn();
      await annaInReichweite();

      final j = await frageNachBuendel();
      expect(j['user_id'], kern.myId,
          reason: 'wir schicken UNSER Buendel, nicht irgendeines');
      // Die Gegenseite muss damit wirklich eine Sitzung bauen koennen — das
      // ist der einzige Nachweis, der zaehlt. Ein wohlgeformtes JSON, das
      // libsignal ablehnt, waere gruen und wertlos. Seit 2.0.0 steckt darin
      // auch: die Kyber-Felder sind da — sonst wuerfe `fromRelay`
      // GegenstelleOhneKyberException.
      expect(() => PreKeyBundleBridge.fromRelay(RelayBundleResponse.fromJson(j)),
          returnsNormally);
    });

    test('KEINE ANFRAGE VERBRAUCHT EINEN EINMALSCHLUESSEL (Audit PR-4)',
        () async {
      // UMGEDREHT AM 16.10.2026. Bis dahin stand hier "JEDE ANFRAGE
      // VERBRAUCHT EINEN EINMALSCHLUESSEL", mit der Begruendung, ueber Funk
      // muesse dieselbe Regel gelten wie beim Relay.
      //
      // Genau das war der Fehler (Audit PR-4): der Einmalschluessel ging ueber
      // Funk hinaus und wurde LOKAL verbraucht — beim Relay lag er aber weiter
      // und wurde dort ein zweites Mal ausgegeben. Baute ein zweiter Kontakt
      // seine Sitzung darauf, fand das Telefon den privaten Teil nicht mehr,
      // und dessen Erstnachricht ging still verloren. Einmalschluessel gibt es
      // deshalb nur noch an EINER Stelle: beim Relay.
      //
      // Ueber Funk gehen nur noch der signierte EC-Prekey und der
      // Last-Resort-Kyber-Prekey hinaus — beides darf mehrfach benutzt
      // werden. Gegen eine erneut eingespielte Erstnachricht schuetzt die
      // Tripel-Liste des Kyber-Speichers (signal_store.dart).
      legeAnnaAn();
      // Die Grenze gegen das wiederholte Fragen steht dem hier im Weg — sie
      // hat ihren eigenen Fall darunter.
      kern.buendelAbstand = Duration.zero;
      await funkAn();
      await annaInReichweite();
      final vorher = await eigenerSpeicher(kern, woerter);

      final erste = await frageNachBuendel();
      final zweite = await frageNachBuendel();

      for (final j in [erste, zweite]) {
        expect(j['one_time_prekey'], isNull,
            reason: 'ein EC-Einmalschluessel ueber Funk ist PR-4: derselbe '
                'liegt beim Relay und wird dort noch einmal ausgegeben');
        expect(j.containsKey('one_time_kyber_prekeys'), isFalse);
        expect(j['kyber_prekey_id'], vorher.letzteRettungId,
            reason: 'ueber Funk geht der LAST-RESORT-Kyber-Prekey, kein '
                'Kyber-Einmalschluessel');
      }
      expect(zweite['signed_prekey_id'], erste['signed_prekey_id']);
      expect(zweite['kyber_prekey_id'], erste['kyber_prekey_id'],
          reason: 'zwei Antworten, dasselbe Buendel — es gibt nichts mehr, '
              'was eine Anfrage verbrauchen koennte');

      // UND AUF DER PLATTE IST AUCH NICHTS WEG. Bis 1.9.x wurde hier je
      // Anfrage ein Einmalschluessel geloescht und festgeschrieben.
      final nachher = await eigenerSpeicher(kern, woerter);
      expect(nachher.preKeyCount, vorher.preKeyCount,
          reason: 'ein lokal verbrauchter EC-Einmalschluessel, der beim Relay '
              'noch liegt, ist genau der Verlust aus PR-4');
      expect(nachher.kyberEinmalCount, vorher.kyberEinmalCount);
    });

    test('DAS FUNK-BUENDEL OHNE EINMALSCHLUESSEL BAUT TROTZDEM EINE SITZUNG',
        () async {
      // DIE GEGENPROBE ZU PR-4. Ein Buendel ohne Einmalschluessel ist nur dann
      // die richtige Antwort, wenn man damit auch wirklich ins Gespraech kommt
      // — sonst haette die Behebung den Funkweg einfach abgeschaltet.
      //
      // DER GANZE WEG, nicht nur `fromRelay`: Anna baut aus der Funkkarte eine
      // PQXDH-Sitzung, schickt ueber die Naehe eine Erstnachricht, und der
      // Kern entschluesselt sie — allein mit dem signierten EC-Prekey und dem
      // Last-Resort-Kyber-Prekey.
      legeAnnaAn();
      await funkAn();
      await annaInReichweite();
      final vorher = await eigenerSpeicher(kern, woerter);

      final j = await frageNachBuendel();
      expect(j['one_time_prekey'], isNull,
          reason: 'ohne diese Voraussetzung prueft der Rest nicht den Fall '
              '"ohne Einmalschluessel"');

      final p = Payload.text('ueber-funk-1', 'mit dem Funk-Buendel', jetzt);
      final umschlag =
          await anna.umschlagAn(kern.myId, RelayBundleResponse.fromJson(j), p);
      expect(Envelope.fromBytes(umschlag).startetSitzung, isTrue,
          reason: 'die erste Nachricht muss die Sitzung eroeffnen (Typ 3)');

      final eingang = <Message>[];
      final abo = kern.incomingMessages.listen(eingang.add);
      funk.empfange(Eingegangen('AA:11', await mitMarke(umschlag)));
      await warteBis(() => eingang.isNotEmpty);
      await abo.cancel();

      expect(eingang.map((m) => m.text), ['mit dem Funk-Buendel'],
          reason: 'der Kern muss eine Sitzung ohne Einmalschluessel annehmen — '
              'sonst kaeme ohne Internet niemand mehr ins Gespraech');
      expect((await letzte()).ueberNaehe, isTrue);
      expect(relaysGebaut, 0, reason: 'und dabei war kein Server beteiligt');

      // UND DABEI WURDE KEIN EINMALSCHLUESSEL ANGEFASST — der beim Relay
      // gehoert weiter dem, der ihn dort abholt.
      final nachher = await eigenerSpeicher(kern, woerter);
      expect(nachher.preKeyCount, vorher.preKeyCount);
      expect(nachher.kyberEinmalCount, vorher.kyberEinmalCount);
      expect(nachher.letzteRettungId, vorher.letzteRettungId,
          reason: 'der Last-Resort-Schluessel bleibt — er ist zum '
              'Mehrfachgebrauch da');
    });

    test('EINE ANTWORT BAUT DIE SITZUNG UND HOLT DAS WARTENDE NACH', () async {
      // "NUR IN DER NAEHE" IN EINEM SCHRITT. Hier stand bis 16.10.2026
      // `setPreferences(nurNahbereich: true)` und danach `funkAn()` — das
      // setzt den Schalter aber wieder auf AUS, und das Ausschalten verbindet
      // den Kern mit dem Relay. Die Nachricht ging dann ueber den Server
      // hinaus, `unversandt()` war leer, und der Test blieb gruen, ohne dass
      // je ein Funk-Buendel eine Sitzung gebaut haette (er wartete nur seine
      // zwei Sekunden auf einen Umschlag ab, der nie kam). Aufgefallen beim
      // Fall "OHNE KYBER" darunter, der denselben Aufbau hatte.
      legeAnnaAn();
      await funkAn(nurNahbereich: true);
      await annaInReichweite();

      await kern.sendMessage(anna.adresse, 'wartet auf das Buendel');
      await warteBis(() => kern.ablageFuerTest.unversandt().isNotEmpty);
      expect(kern.ablageFuerTest.unversandt(), isNotEmpty,
          reason: 'ohne wartende Nachricht prueft der Rest nichts');

      funk.gesendet.clear();
      // Die Karte, die Annas Telefon ueber Funk schickt: ohne Einmalschluessel.
      await annaAntwortet(anna.funkKarte());

      // Jetzt muss ein UMSCHLAG rausgehen — die Nachricht, die wartete.
      await warteBis(() =>
          funk.gesendet.any((g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag));
      expect(kern.ablageFuerTest.unversandt(), isEmpty,
          reason: 'die Sitzung steht, es wartet nichts mehr');
      expect(relaysGebaut, 0,
          reason: 'die Nachricht muss UEBER FUNK hinaus, nicht ueber einen '
              'Server, der hier gar nicht gefragt werden darf');
    });

    test('EIN BUENDEL MIT FREMDER ADRESSE WIRD ABGELEHNT', () async {
      // Die Marke sagt, WER geschickt hat; das Buendel behauptet, WEM es
      // gehoert. Wer das nicht vergleicht, baut auf Zuruf eine Sitzung mit
      // einer fremden Identitaet — und verschluesselt danach an den Falschen.
      legeAnnaAn();
      await funkAn();
      await annaInReichweite();

      final fremd = await Gegenstelle.neu();
      funk.gesendet.clear();
      await annaAntwortet(fremd.funkKarte());
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // UEBER DAS VERHALTEN GEPRUEFT, nicht ueber einen Testhaken: gaebe es
      // eine Sitzung, ginge diese Nachricht sofort als Umschlag raus. Sie
      // bleibt liegen, also gibt es keine.
      funk.gesendet.clear();
      await kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: true));
      await kern.sendMessage(anna.adresse, 'geht das jetzt?');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
          funk.gesendet
              .any((g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag),
          isFalse,
          reason: 'ein Buendel, das jemand anderem gehoert, darf keine '
              'Sitzung mit Anna begruenden');
    });

    test('EIN FUNK-BUENDEL OHNE KYBER (alte App) BAUT KEINE SITZUNG', () async {
      // Eine App vor 2.0.0 antwortet ohne Kyber-Felder. Die offizielle
      // libsignal baut daraus keine Sitzung (PQXDH ist Pflicht), und einen
      // Rueckweg auf X3DH gibt es bewusst nicht (docs/LIBSIGNAL-UMSTIEG.md:
      // kein Downgrade). `fromRelay` wirft GegenstelleOhneKyberException,
      // `_verarbeiteSonderpost` faengt sie.
      //
      // GEMESSEN WIRD ZWEIERLEI: es entsteht keine Sitzung (die Nachricht
      // bleibt liegen), und der Funk lebt danach weiter — die Gegenprobe mit
      // der richtigen Karte baut die Sitzung sehr wohl. Ohne die Gegenprobe
      // bliebe der Test auch dann gruen, wenn der Wurf den ganzen Empfang
      // lahmgelegt haette.
      //
      // DAZU DER VERMERK AM KONTAKT (seit 17.10.2026): nach der Karte ohne
      // Kyber traegt Anna [Contact.brauchtNeuereApp], nach der richtigen
      // nicht mehr. Ohne ihn stuende die Nachricht im Modus "nur in der Naehe"
      // stumm auf "wird gesendet", obwohl Anna daneben steht.
      legeAnnaAn();
      await funkAn(nurNahbereich: true);
      await annaInReichweite();
      await kern.sendMessage(anna.adresse, 'wartet auf ein brauchbares Buendel');
      await warteBis(() => kern.ablageFuerTest.unversandt().isNotEmpty);

      expect(
          () => PreKeyBundleBridge.fromRelay(
              RelayBundleResponse.fromJson(ohneKyber(anna.funkKarte()))),
          throwsA(isA<GegenstelleOhneKyberException>()),
          reason: 'die Voraussetzung: ohne Kyber gibt es kein Buendel');

      funk.gesendet.clear();
      await annaAntwortet(ohneKyber(anna.funkKarte()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
          funk.gesendet
              .any((g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag),
          isFalse,
          reason: 'ohne Kyber darf keine Sitzung entstehen — auch keine '
              'schwaechere');
      expect(kern.ablageFuerTest.unversandt(), isNotEmpty);
      expect(kern.ablageFuerTest.kontakt(anna.adresse)!.brauchtNeuereApp,
          isTrue,
          reason: 'der Chat soll sagen, dass Anna aktualisieren muss');

      // DIE GEGENPROBE: dieselbe Gegenstelle mit Kyber kommt durch.
      await annaAntwortet(anna.funkKarte());
      await warteBis(() =>
          funk.gesendet.any((g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag));
      expect(kern.ablageFuerTest.unversandt(), isEmpty,
          reason: 'nach dem gescheiterten Buendel muss der Funkweg weiter '
              'tragen');
      expect(kern.ablageFuerTest.kontakt(anna.adresse)!.brauchtNeuereApp,
          isFalse,
          reason: 'mit der Sitzung stimmt der Hinweis nicht mehr');
      expect(relaysGebaut, 0);
    });

    test('WER ZWEIMAL HINTEREINANDER FRAGT, BEKOMMT NUR EINMAL', () async {
      // DIE BEGRUENDUNG HAT SICH SEIT 2.0.0 GEAENDERT, die Grenze nicht.
      //
      // Bis 1.9.x verbrauchte jede Antwort einen Einmalschluessel, und ohne
      // Grenze liess sich der Vorrat leerfragen. Das gibt es nicht mehr (Fall
      // "KEINE ANFRAGE VERBRAUCHT ..." darueber). Geblieben ist die Last: die
      // Antwort traegt jetzt einen Kyber-1024-Schluessel und ist rund 2,5 KB
      // gross, in Stuecken ueber eine Bluetooth-Verbindung. Ohne Grenze
      // koennte jeder erkannte Kontakt in Reichweite das Telefon mit Fragen
      // dauerhaft funken lassen — Akku und Sendezeit fuer nichts.
      legeAnnaAn();
      await funkAn();
      await annaInReichweite();

      funk.gesendet.clear();
      funk.empfange(Eingegangen(
          'AA:11', await mitKopf(Nahtyp.buendelAnfrage, Uint8List(0))));
      await warteBis(() => funk.gesendet.isNotEmpty);
      final nachDerErsten = funk.gesendet.length;

      funk.empfange(Eingegangen(
          'AA:11', await mitKopf(Nahtyp.buendelAnfrage, Uint8List(0))));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(funk.gesendet.length, nachDerErsten,
          reason: 'die zweite Anfrage wurde beantwortet — jeder in Reichweite '
              'koennte das Telefon dauerhaft funken lassen');
    });
  });

  group('Anfrage und Zusage', () {
    // WOFUER DIESE GRUPPE DA IST
    //
    // Die Zusage war die einzige Steuernutzlast, die nach einem Fehlschlag
    // weg war: Quittungen, Reaktionen und Bearbeitungen warten im Ausgang,
    // Kontaktanfragen schickt connect() nach — eine Zusage ging einmal
    // hinaus oder nie. Und Anna, die eine Gegenstelle ist und kein Kern, kann
    // hier auch schicken, was eine ehrliche App nie schickt.

    /// Anna schickt eine beliebige Nutzlast ueber den Relay.
    Future<void> annaSchickt(Payload p) async {
      relay!.herein(RelayMessage(
        from: anna.adresse,
        ciphertext:
            await anna.umschlagAn(kern.myId, await unserBuendel(kern, woerter), p),
        at: jetzt,
      ));
    }

    Payload steuerung(PayloadKind art) =>
        Payload.control(art, 'steuer-${art.name}', jetzt);

    ContactState? annasZustand() =>
        kern.ablageFuerTest.kontakt(anna.adresse)?.state;

    /// Was ueber Funk an Anna hinausging, mit IHREM Schluessel geoeffnet.
    ///
    /// Erst das Oeffnen belegt etwas: ein Umschlag, der hinausgeht, kann
    /// genauso gut eine Quittung sein.
    Future<Payload> oeffneAlsAnna(Uint8List paket) async {
      const kopf = leuchtfeuerLaenge + Nahtyp.laenge;
      expect(paket[leuchtfeuerLaenge], Nahtyp.umschlag);
      final klar = await Envelope.fromBytes(Uint8List.sublistView(paket, kopf))
          .decrypt(chiffreVon(anna.store), adr(kern.myId));
      return Payload.fromBytes(klar);
    }

    test('DIE ZUSAGE WARTET IM AUSGANG und geht ueber Funk, sobald Anna da ist',
        () async {
      // Annas Anfrage kam ueber den Relay; angenommen wird mit "nur in der
      // Naehe", waehrend sie nicht in Reichweite ist. Bis 15.10.2026 ging
      // die Zusage dabei einmal ins Leere und war weg: Anna stand fuer immer
      // auf "ausstehend", und ihre wiederholte Anfrage traf bei uns auf einen
      // Kontakt, der schon aktiv war — und wurde verworfen.
      await funkAn();
      await kern.connect();
      await annaSchickt(steuerung(PayloadKind.contactRequest));
      await warteBis(() => annasZustand() != null);
      expect(annasZustand(), ContactState.incomingPending);

      await kern.setPreferences(
          const AppPreferences(naheAn: true, nurNahbereich: true));
      await kern.nahRuhtFuerTest;
      funk.gesendet.clear();

      await kern.acceptRequest(anna.adresse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(funk.gesendet, isEmpty,
          reason: 'Anna ist nicht in Reichweite — sonst prueft der Test '
              'darunter nichts');
      expect(annasZustand(), ContactState.active);

      await annaInReichweite();
      await warteBis(() => funk.gesendet.any(
          (g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag));
      final umschlaege = funk.gesendet
          .where((g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag)
          .toList();
      expect(umschlaege, isNotEmpty,
          reason: 'die Zusage ging verloren: Anna wartet fuer immer, obwohl '
              'sie danebensteht');
      final p = await oeffneAlsAnna(umschlaege.first.umschlag);
      expect(p.kind, PayloadKind.contactAccept);
      expect(relaysGebaut, 1,
          reason: 'der eine vom Verbinden — die Zusage selbst fragt keinen '
              'Server');
    });

    test('KREUZT ANNAS ANFRAGE UNSERE, sind wir Kontakte — und sie erfaehrt es',
        () async {
      // Der gegenseitige Fall von einer Seite aus betrachtet. Beide Haelften
      // zaehlen: aktiv werden, OHNE auf Annas Zusage zu warten, und Anna
      // zusagen, falls unsere Anfrage bei ihr nie ankam. Zwischen zwei
      // echten Kernen (real_core_test "GEGENSEITIG HINZUGEFUEGT") faellt
      // jede Haelfte allein nicht auf — dort tut die jeweils andere Seite den
      // fehlenden Schritt.
      await kern.connect();
      await kern.addContact(anna.adresse);
      await warteBis(() => relay!.gesendet.isNotEmpty);
      relay!.gesendet.clear();

      await annaSchickt(steuerung(PayloadKind.contactRequest));
      await warteBis(() => annasZustand() == ContactState.active);
      expect(annasZustand(), ContactState.active,
          reason: 'beide wollen den Kontakt, und wir warten trotzdem');

      await warteBis(() => relay!.gesendet.isNotEmpty);
      expect(relay!.gesendet, hasLength(1),
          reason: 'Anna erfaehrt nie, dass wir zugestimmt haben');
      final klar = await Envelope.fromBytes(relay!.gesendet.single.umschlag)
          .decrypt(chiffreVon(anna.store), adr(kern.myId));
      expect(Payload.fromBytes(klar).kind, PayloadKind.contactAccept);
    });

    test('NUR DIE LETZTE ANTWORT GEHT HINAUS', () async {
      // Abgelehnt, waehrend der Relay nichts annahm; Anna fragt erneut, und
      // diesmal wird angenommen. Warteten beide Antworten, ginge die Absage
      // zuerst hinaus — Anna entfernte uns, und die Zusage danach traefe auf
      // nichts mehr.
      await kern.connect();
      await annaSchickt(steuerung(PayloadKind.contactRequest));
      await warteBis(() => annasZustand() != null);

      relay!.sendenWirft = true;
      await kern.declineRequest(anna.adresse);
      expect(annasZustand(), isNull);

      await annaSchickt(steuerung(PayloadKind.contactRequest));
      await warteBis(() => annasZustand() != null);
      await kern.acceptRequest(anna.adresse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
          [
            for (final a in kern.ablageFuerTest.ausgang())
              Payload.fromBytes(a.nutzlast).kind
          ],
          [PayloadKind.contactAccept]);

      // Der Relay traegt wieder: genau die Zusage geht hinaus.
      await kern.disconnect();
      await kern.connect();
      await warteBis(() => relay!.gesendet.isNotEmpty);
      expect(relay!.gesendet, hasLength(1));
      final klar = await Envelope.fromBytes(relay!.gesendet.single.umschlag)
          .decrypt(chiffreVon(anna.store), adr(kern.myId));
      expect(Payload.fromBytes(klar).kind, PayloadKind.contactAccept);
      expect(kern.ablageFuerTest.ausgang(), isEmpty);
    });

    test('EINE ZUSAGE, UM DIE NIEMAND GEBETEN HAT, macht niemanden zum Kontakt',
        () async {
      // Anna fragt an und sagt sich gleich selbst zu. Eine ehrliche App tut
      // das nie — eine veraenderte schon, und dann stand sie ohne jedes
      // Zutun des Nutzers als bestaetigter Kontakt in der Chatliste.
      await kern.connect();
      await annaSchickt(steuerung(PayloadKind.contactRequest));
      await warteBis(() => annasZustand() != null);

      await annaSchickt(steuerung(PayloadKind.contactAccept));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(annasZustand(), ContactState.incomingPending,
          reason: 'die Entscheidung ueber eine Anfrage liegt beim Nutzer, '
              'nicht beim Absender');
    });

    test('EINE ABSAGE VON EINEM BESTAETIGTEN KONTAKT loescht nichts', () async {
      // Eine Absage beantwortet eine Anfrage. Kam sie von einem Kontakt, der
      // laengst bestaetigt war, loeschte sie trotzdem den Kontakt und den
      // ganzen Verlauf auf DIESEM Telefon — auf Zuruf der Gegenseite.
      legeAnnaAn();
      await kern.connect();
      await annaSchreibtUeberRelay('m1', 'das soll bleiben');
      await warteBis(() =>
          kern.ablageFuerTest.verlauf(anna.adresse).isNotEmpty);
      expect(kern.ablageFuerTest.verlauf(anna.adresse), hasLength(1));

      await annaSchickt(steuerung(PayloadKind.contactDecline));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(annasZustand(), ContactState.active,
          reason: 'einen Kontakt entfernt jeder nur fuer sich');
      expect(kern.ablageFuerTest.verlauf(anna.adresse).single.text,
          'das soll bleiben');
    });
  });
}

/// Eine ZWEITE Ansicht auf die Datenbank des Kerns.
///
/// Der Kern gibt seinen Speicher nicht heraus und sollte es auch nicht.
/// Gelesen wird nur — und zwar das, was FESTGESCHRIEBEN ist. Genau darauf
/// kommt es bei PR-4 an: ein Einmalschluessel, der nur im Arbeitsspeicher
/// fehlte, waere nach dem naechsten Start wieder da.
Future<BitdmSignalStore> eigenerSpeicher(
        RealMessengerCore kern, List<String> woerter) async =>
    SignalStoreRepository(kern.datenbankFuerTest)
        .openStore(await KeyDerivation.fromMnemonic(woerter));

/// Das eigene Prekey-Buendel — das, was der Relay von uns ausliefern wuerde.
///
/// MIT EINMALSCHLUESSELN, EC und Kyber, wie beim Relay (signal_hilfe.dart
/// `buendelAusSpeicher`). Den Kyber-Einmalschluessel verbraucht der Kern beim
/// Entschluesseln (`markKyberPreKeyUsed`); weil hier jedes Mal frisch aus der
/// Datenbank gelesen wird, kommt danach der naechste.
Future<RelayBundleResponse> unserBuendel(
        RealMessengerCore kern, List<String> woerter) async =>
    buendelAusSpeicher(await eigenerSpeicher(kern, woerter));
