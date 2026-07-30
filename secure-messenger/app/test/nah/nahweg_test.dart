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
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../support/funk_attrappe.dart';

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
class Gegenstelle {
  Gegenstelle._(this.identitaet, this.store, this._preKeys, this._spk);

  final SignalIdentity identitaet;
  final BitdmSignalStore store;
  final List<PreKeyRecord> _preKeys;
  final SignedPreKeyRecord _spk;

  String get adresse => identitaet.address;
  Uint8List get oeffentlich => identitaet.rawPublicKey;

  static Future<Gegenstelle> neu() async {
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final pks = generatePreKeys(1, 3);
    for (final pk in pks) {
      await store.storePreKey(pk.id, pk);
    }
    final spk = generateSignedPreKey(id.keyPair, 1);
    await store.storeSignedPreKey(spk.id, spk);
    return Gegenstelle._(id, store, pks, spk);
  }

  /// Was der Relay auf eine Buendelanfrage antworten wuerde.
  RelayBundleResponse get antwort => antwortAus(identitaet, _spk, _preKeys[0]);

  /// Das Leuchtfeuer, das dieses Geraet gerade aussendet, damit [wir] es
  /// finden.
  ///
  /// UEBER DAS cryptography-PAKET, waehrend der Kern libsignal nimmt. Das ist
  /// Absicht: genau so laeuft es im Betrieb auch nicht auf demselben Weg, und
  /// ein Test, der beide Seiten mit derselben Bibliothek rechnen liesse, waere
  /// gegen die eine Sorte Fehler blind, die hier wirklich weh tut.
  Future<Uint8List> leuchtfeuerFuer(Uint8List wir, DateTime zeit) async {
    final paar = await X25519().newKeyPairFromSeed(
        Uint8List.fromList(identitaet.keyPair.getPrivateKey().serialize()));
    final geheim = await Leuchtfeuer.gemeinsamesGeheimnis(
        eigenerSchluessel: paar, fremderOeffentlicher: wir);
    return Leuchtfeuer.eigenesFuer(
        geheimnis: geheim, eigenerOeffentlicher: oeffentlich, zeit: zeit);
  }

  /// Baut einen Umschlag, wie ihn ein zweites Telefon ueber die Naehe schickte.
  Future<Uint8List> umschlagAn(
      String empfaenger, RelayBundleResponse seinBuendel, Payload p) async {
    final ziel = SignalProtocolAddress(empfaenger, 1);
    if (!await store.containsSession(ziel)) {
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(seinBuendel));
    }
    final ct = await SessionCipher.fromStore(store, ziel).encrypt(p.toBytes());
    return Envelope.of(ct).toBytes();
  }
}

/// Ein Buendel in der Form, in der der Relay es ausliefert.
RelayBundleResponse antwortAus(
        SignalIdentity id, SignedPreKeyRecord spk, PreKeyRecord otk) =>
    RelayBundleResponse(
      userId: id.address,
      identityKey: base64.encode(
          SignalIdentityBridge.rawPublicKeyOf(id.keyPair.getPublicKey())),
      registrationId: id.registrationId,
      signedPreKeyId: spk.id,
      signedPreKey: base64.encode(spk.getKeyPair().publicKey.serialize()),
      signedPreKeySignature: base64.encode(spk.signature),
      oneTimePreKey: RelayOneTimePreKey(
        keyId: otk.id,
        publicKey: base64.encode(otk.getKeyPair().publicKey.serialize()),
      ),
    );

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
  /// Die Karte, wie der Relay sie ausliefert. RelayBundleResponse kann sich
  /// nur lesen, nicht schreiben — das braucht nur der Test.
  Map<String, Object?> alsKarte(RelayBundleResponse a) => {
        'user_id': a.userId,
        'identity_key': a.identityKey,
        'registration_id': a.registrationId,
        'signed_prekey_id': a.signedPreKeyId,
        'signed_prekey': a.signedPreKey,
        'signed_prekey_sig': a.signedPreKeySignature,
        'one_time_prekey': a.oneTimePreKey?.toJson(),
      };

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
      final m = await letzte();
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

      final m = await letzte();
      expect(m.status, MessageStatus.sent);
      expect(m.ueberNaehe, isTrue,
          reason: 'ohne das Zeichen saehe eine Nachricht, die keinen Server '
              'gesehen hat, aus wie jede andere');
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
    test('KOMMT IN DEN NAHBEREICH — sonst findet ihn nie jemand', () async {
      // BOB FUEGT ANNA HINZU, Annas App legt Bob beim Empfangen an. Hier ist
      // die App Anna.
      //
      // Ohne diesen Schritt kennt Annas Nahbereich Bob nicht: sie sendet kein
      // Leuchtfeuer fuer ihn aus und erkennt seines nicht. Und weil das
      // Verfahren in beide Richtungen laeuft — jedes Leuchtfeuer haengt am
      // gemeinsamen Geheimnis —, findet dann auch Bob sie nicht. Ausgerechnet
      // fuer den zuletzt hinzugekommenen Kontakt, den, neben dem man am
      // ehesten steht, taete die ganze Schicht stillschweigend nichts.
      await funkAn();
      expect(funk.werbungen, isEmpty,
          reason: 'noch gibt es keinen Kontakt, fuer den zu werben waere');

      await kern.connect();
      await annaSchreibtUeberRelay('erste', 'hallo, ich bin neu');
      await warteBis(() => funk.werbungen.isNotEmpty);
      await kern.nahRuhtFuerTest;

      expect(funk.werbungen, isNotEmpty,
          reason: 'fuer den neuen Kontakt wird kein Leuchtfeuer ausgesendet — '
              'er ist im Nahbereich gar nicht angekommen');
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
      final m = await letzte();
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

    test('EINE ANFRAGE WIRD MIT DEM EIGENEN BUENDEL BEANTWORTET', () async {
      legeAnnaAn();
      await funkAn();
      await annaInReichweite();
      funk.gesendet.clear();

      funk.empfange(Eingegangen(
          'AA:11', await mitKopf(Nahtyp.buendelAnfrage, Uint8List(0))));
      await warteBis(() => funk.gesendet.isNotEmpty);

      final p = letztesPaket()!;
      expect(p.typ, Nahtyp.buendelAntwort);
      final j = (jsonDecode(utf8.decode(p.inhalt)) as Map).cast<String, Object?>();
      expect(j['user_id'], kern.myId,
          reason: 'wir schicken UNSER Buendel, nicht irgendeines');
      // Die Gegenseite muss damit wirklich eine Sitzung bauen koennen — das
      // ist der einzige Nachweis, der zaehlt. Ein wohlgeformtes JSON, das
      // libsignal ablehnt, waere gruen und wertlos.
      expect(() => PreKeyBundleBridge.fromRelay(RelayBundleResponse.fromJson(j)),
          returnsNormally);
    });

    test('JEDE ANFRAGE VERBRAUCHT EINEN EINMALSCHLUESSEL', () async {
      // Beim Relay bekommt jeder Abruf einen frischen. Ueber Funk muss
      // dieselbe Regel gelten, sonst bauen zwei Gegenstellen ihre Sitzung auf
      // demselben auf — und dann ist er fuer beide keine zusaetzliche
      // Absicherung mehr, sondern nur noch Zierde.
      legeAnnaAn();
      // Die Grenze gegen das Leerfragen steht dem hier im Weg — sie hat ihren
      // eigenen Fall darunter.
      kern.buendelAbstand = Duration.zero;
      await funkAn();
      await annaInReichweite();

      Future<int?> frageUndLiesSchluessel() async {
        funk.gesendet.clear();
        funk.empfange(Eingegangen(
            'AA:11', await mitKopf(Nahtyp.buendelAnfrage, Uint8List(0))));
        await warteBis(() => funk.gesendet.isNotEmpty);
        final j = (jsonDecode(utf8.decode(letztesPaket()!.inhalt)) as Map)
            .cast<String, Object?>();
        final otk = j['one_time_prekey'];
        return otk == null ? null : (otk as Map)['key_id'] as int;
      }

      final erster = await frageUndLiesSchluessel();
      final zweiter = await frageUndLiesSchluessel();
      expect(erster, isNotNull, reason: 'ohne Einmalschluessel keine Aussage');
      expect(zweiter, isNot(erster),
          reason: 'derselbe Schluessel zweimal — er waere fuer beide wertlos');
    });

    test('EINE ANTWORT BAUT DIE SITZUNG UND HOLT DAS WARTENDE NACH', () async {
      legeAnnaAn();
      await kern.setPreferences(const AppPreferences(naheAn: true, nurNahbereich: true));
      await funkAn();
      await annaInReichweite();

      await kern.sendMessage(anna.adresse, 'wartet auf das Buendel');
      await warteBis(() => kern.ablageFuerTest.unversandt().isNotEmpty);

      funk.gesendet.clear();
      funk.empfange(Eingegangen(
          'AA:11',
          await mitKopf(Nahtyp.buendelAntwort,
              Uint8List.fromList(utf8.encode(jsonEncode(alsKarte(anna.antwort)))))));

      // Jetzt muss ein UMSCHLAG rausgehen — die Nachricht, die wartete.
      await warteBis(() =>
          funk.gesendet.any((g) => g.umschlag[leuchtfeuerLaenge] == Nahtyp.umschlag));
      expect(kern.ablageFuerTest.unversandt(), isEmpty,
          reason: 'die Sitzung steht, es wartet nichts mehr');
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
      funk.empfange(Eingegangen(
          'AA:11',
          await mitKopf(Nahtyp.buendelAntwort,
              Uint8List.fromList(utf8.encode(jsonEncode(alsKarte(fremd.antwort)))))));
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

    test('WER ZWEIMAL HINTEREINANDER FRAGT, BEKOMMT NUR EINMAL', () async {
      // Jede Antwort verbraucht einen Einmalschluessel. Ohne Grenze koennte
      // jedes Geraet in Reichweite den Vorrat leeren, einfach indem es fragt —
      // danach bekaeme jeder neue Kontakt nur noch ein Buendel OHNE
      // Einmalschluessel, und niemand saehe, warum.
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
          reason: 'die zweite Anfrage wurde beantwortet — der Vorrat laesst '
              'sich leerfragen');
    });
  });
}

/// Das eigene Prekey-Buendel — das, was der Relay von uns ausliefern wuerde.
///
/// Ueber eine ZWEITE Ansicht auf dieselbe Datenbank, weil der Kern seinen
/// Speicher nicht herausgibt und auch nicht sollte. Gelesen wird nur.
Future<RelayBundleResponse> unserBuendel(
    RealMessengerCore kern, List<String> woerter) async {
  final keys = await KeyDerivation.fromMnemonic(woerter);
  final store = SignalStoreRepository(kern.datenbankFuerTest).openStore(keys);
  final spk = await store.loadSignedPreKey(store.state.signedPreKeys.keys.first);
  final otk = await store.loadPreKey(store.state.preKeys.keys.first);
  return antwortAus(store.identity, spk, otk);
}
