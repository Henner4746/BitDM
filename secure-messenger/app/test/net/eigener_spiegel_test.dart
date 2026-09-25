// eigener_spiegel_test.dart — was zwischen den EIGENEN Geraeten laeuft.
//
// Der Spiegel (§5) ist der Teil des Mehrgeraete-Umbaus, den der Nutzer sieht:
// was ich auf dem Handy schreibe, steht auf dem Tablet. Er ist zugleich der
// Teil mit den unangenehmsten Fehlermoeglichkeiten, weil ein Umschlag von der
// EIGENEN Adresse an praktisch jeder Pruefung vorbeikommt — er IST ja echt.
//
// ZWEI ECHTE GERAETE OHNE ZWEITE DATENBANK: das "Zweitgeraet" hier ist ein
// eigener libsignal-Speicher mit DERSELBEN aus den zwoelf Woertern
// abgeleiteten Identitaet und einem EIGENEN signierten Prekey — genau das, was
// ein zweites Telefon ist. Es baut eine echte X3DH-Sitzung zu uns auf und
// verschluesselt echte Umschlaege. Nachgebaut ist nur der Transport.
//
// WARUM KEIN ECHTER RELAY: alle vier Faelle brauchen einen Umschlag, den der
// Relay so nie erzeugt — einen Spiegel, der SCHON DA WAR, bevor die Regel
// dagegen im Code stand, und der jederzeit wieder eingeworfen werden kann.
// Genau das ist der Angriff; ein Relay, der sich benimmt, kann ihn nicht
// vorfuehren.
//
// ═══════════════════════════════════════════════════ MUTATIONSPROBE 01.08.2026
//
// Was bei zurueckgedrehter Behebung rot wurde, steht am jeweiligen Fall.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/rezept.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../support/relay_attrappe.dart';

/// Ein zweites Telefon derselben Person.
///
/// DIESELBE IDENTITAET AUS DENSELBEN ZWOELF WOERTERN, aber ein EIGENER
/// signierter Prekey und eine eigene registration_id — genau der Unterschied,
/// an dem der Reflexionsriegel (§12.1) ein echtes Zweitgeraet von einem
/// erfundenen unterscheidet.
class Zweitgeraet {
  Zweitgeraet._(this.kennung, this.store, this._spk, this._otk);

  final int kennung;
  final BitdmSignalStore store;
  final SignedPreKeyRecord _spk;
  final PreKeyRecord _otk;

  static Future<Zweitgeraet> aus(List<String> woerter, int kennung) async {
    final keys = await KeyDerivation.fromMnemonic(woerter);
    final id = SignalIdentityBridge.fromDerived(keys,
        registrationId: SignalIdentityBridge.newRegistrationId());
    final store = BitdmSignalStore(identity: id);
    final spk = generateSignedPreKey(id.keyPair, 4711);
    await store.storeSignedPreKey(spk.id, spk);
    final otk = generatePreKeys(9000, 1).first;
    await store.storePreKey(otk.id, otk);
    return Zweitgeraet._(kennung, store, spk, otk);
  }

  /// Die Geraetezeile, wie der Relay sie unter der eigenen Adresse fuehrt.
  Map<String, Object?> karte() => {
        'device_id': kennung,
        'registration_id': store.identity.registrationId,
        'signed_prekey_id': _spk.id,
        'signed_prekey': base64.encode(_spk.getKeyPair().publicKey.serialize()),
        'signed_prekey_sig': base64.encode(_spk.signature),
        'one_time_prekey': {
          'key_id': _otk.id,
          'public_key':
              base64.encode(_otk.getKeyPair().publicKey.serialize()),
        },
      };

  /// Ein Spiegel, verschluesselt an Geraet 1 derselben Adresse.
  ///
  /// ECHTE X3DH UND ECHTE VERSCHLUESSELUNG. Ein Test, der den Umschlag
  /// nachbaute, wuerde am `_nimmSpiegel` vorbeimessen: dorthin kommt nur, was
  /// libsignal wirklich aufbekommen hat.
  Future<Uint8List> spiegelAn(
    String eigeneAdresse,
    RelayBundleResponse geraet1,
    String chat,
    Payload innen,
  ) async {
    final ziel = SignalProtocolAddress(eigeneAdresse, 1);
    if (!await store.containsSession(ziel)) {
      await SessionBuilder.fromSignalStore(store, ziel)
          .processPreKeyBundle(PreKeyBundleBridge.fromRelay(geraet1));
    }
    final ct = await SessionCipher.fromStore(store, ziel)
        .encrypt(Payload.spiegel(chat, innen).toBytes());
    return Envelope.of(ct).toBytes();
  }
}

/// Eine gueltige Anleitung, ohne dass irgendetwas im Lager liegt.
///
/// Sie muss durch `Rezept.ausText` kommen — sonst verwirft `_nimmSpiegel` den
/// Anhang, und der Fall darunter maesse gar nichts.
String beispielRezept() {
  final r = Rezept(
    name: 'urlaub.jpg',
    gesamtGroesse: 1024,
    pruefsumme: Uint8List(32),
    stuecke: [
      Stueck(
        // 52 Zeichen Base32 — die Form, die der Relay verlangt.
        kennung: 'a' * 52,
        schluessel: Uint8List(32),
        nonce: Uint8List(12),
        klarGroesse: 1024,
      ),
    ],
  );
  return r.alsText();
}

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;
  late RelayAttrappe letzterRelay;

  Future<void> warteBis(bool Function() fertig) async {
    for (var i = 0; i < 600 && !fertig(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-spiegel');
    lage = Relaylage();
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = RelayAttrappe(id, lage);
        lage.gebaut.add(r);
        return letzterRelay = r;
      },
    );
    await kern.initialize();
    woerter = await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  /// Unser eigenes Buendel — das, was der Relay von Geraet 1 ausliefern wuerde.
  ///
  /// Ueber eine ZWEITE Ansicht auf dieselbe Datenbank, weil der Kern seinen
  /// Speicher nicht herausgibt und auch nicht sollte. Gelesen wird nur.
  Future<RelayBundleResponse> eigenesBuendel() async {
    final store = SignalStoreRepository(kern.datenbankFuerTest)
        .openStore(await KeyDerivation.fromMnemonic(woerter));
    final spk =
        await store.loadSignedPreKey(store.state.signedPreKeys.keys.first);
    final otk = await store.loadPreKey(store.state.preKeys.keys.first);
    return RelayBundleResponse(
      userId: store.identity.address,
      identityKey: base64.encode(store.identity.rawPublicKey),
      registrationId: store.identity.registrationId,
      signedPreKeyId: spk.id,
      signedPreKey: base64.encode(spk.getKeyPair().publicKey.serialize()),
      signedPreKeySignature: base64.encode(spk.signature),
      oneTimePreKey: RelayOneTimePreKey(
        keyId: otk.id,
        publicKey: base64.encode(otk.getKeyPair().publicKey.serialize()),
      ),
    );
  }

  /// Die eigene Adresse mit Geraet 1 und einem echten Zweitgeraet.
  Future<Zweitgeraet> mitZweitgeraet() async {
    final eigen = await eigenesBuendel();
    final zweit = await Zweitgeraet.aus(woerter, 2);
    lage.liste = [1, 2];
    final eigeneKarte = {
      'user_id': eigen.userId,
      'identity_key': eigen.identityKey,
      'registration_id': eigen.registrationId,
      'signed_prekey_id': eigen.signedPreKeyId,
      'signed_prekey': eigen.signedPreKey,
      'signed_prekey_sig': eigen.signedPreKeySignature,
      'one_time_prekey': eigen.oneTimePreKey?.toJson(),
      'geraete': [
        {
          'device_id': 1,
          'registration_id': eigen.registrationId,
          'signed_prekey_id': eigen.signedPreKeyId,
          'signed_prekey': eigen.signedPreKey,
          'signed_prekey_sig': eigen.signedPreKeySignature,
          'one_time_prekey': eigen.oneTimePreKey?.toJson(),
        },
        zweit.karte(),
      ],
    };
    final alt = lage.buendel;
    lage.buendel = (wen) =>
        wen == kern.myId ? eigeneKarte : (alt?.call(wen) ?? const {});
    return zweit;
  }

  /// Wirft einen Umschlag ein, so wie der Relay ihn zustellt.
  void wirfEin(Uint8List umschlag, int vonGeraet) => letzterRelay.herein(
        RelayMessage(
          from: kern.myId,
          ciphertext: umschlag,
          at: DateTime.now().toUtc(),
          vonGeraet: vonGeraet,
        ),
      );

  // ═══════════════════════════════════════════════════════════════════ 5a
  group('Die Absage wird nicht gespiegelt', () {
    test('EIN CONTACTDECLINE GEHT NICHT AN DIE EIGENEN GERAETE', () async {
      // `contactDecline` ist die einzige Art, die auf dem anderen Geraet
      // etwas WEGNIMMT. Ein Umschlag, der so etwas ausloest, darf nicht
      // beliebig lange gueltig herumliegen: wer ihn irgendwann in die Hand
      // bekommt, trifft damit eine Unterhaltung, die es zum Zeitpunkt der
      // Absage noch gar nicht gab.
      //
      // MUTATION: in `_spiegelfaehig` `PayloadKind.contactDecline` von der
      //           false- in die true-Liste geschoben
      final bob = await Fremder.mitGeraeten([1]);
      await mitZweitgeraet();
      final vorher = lage.buendel!;
      lage.buendel = (wen) => wen == bob.adresse ? bob.karte() : vorher(wen);

      await kern.connect();
      await warteBis(() => kern.geraeteZahl == 2);
      // Die Sitzung zum eigenen Zweitgeraet steht erst NACH dem Buendelabruf.
      await warteBis(() => lage.buendelAbrufe > 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.incomingPending));

      // GEGENPROBE ZUERST: ein Text wird sehr wohl gespiegelt. Ohne sie bliebe
      // dieser Test auch dann gruen, wenn der Spiegel insgesamt tot waere.
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      lage.gesendet.clear();
      await kern.sendMessage(bob.adresse, 'das geht ans Tablet');
      await warteBis(() => lage.gesendet.any((g) => g.an == kern.myId));
      expect(lage.gesendet.where((g) => g.an == kern.myId).map((g) => g.geraet),
          [2],
          reason: 'ein Text MUSS an das eigene Zweitgeraet gespiegelt werden — '
              'sonst misst der Rest nichts');

      lage.gesendet.clear();
      await kern.declineRequest(bob.adresse);
      // Ein Spiegel waere auf demselben Weg laengst draussen.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // AUF DIE GERAETENUMMERN ABGEBILDET und nicht auf die Umschlaege: die
      // rote Meldung soll die Aussage tragen und nicht vierhundert Bytes
      // Chiffretext.
      expect(lage.gesendet.where((g) => g.an == kern.myId).map((g) => g.geraet),
          isEmpty,
          reason: 'eine Absage darf nicht als Spiegel beim Relay liegen '
              'bleiben — sie ist die einzige Art, die auf dem anderen Geraet '
              'etwas wegnimmt');
      expect(lage.gesendet.where((g) => g.an == bob.adresse), isNotEmpty,
          reason: 'die Absage selbst geht sehr wohl an den Kontakt');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 5b
  group('Auf eine gespiegelte Absage wird nicht gehandelt', () {
    test('EIN EINGEWORFENER CONTACTDECLINE-SPIEGEL LEGT NICHTS AN', () async {
      // DIE WICHTIGERE HAELFTE. Dass wir diese Art nicht mehr SCHICKEN, hilft
      // gegen das, was ab jetzt entsteht. Ein Spiegel, der VOR der Aenderung
      // entstand, liegt beim Relay und laesst sich jederzeit wieder einwerfen
      // — dagegen hilft nur, dass wir auf ihn nicht mehr handeln.
      //
      // WAS OHNE DEN RIEGEL WIRKLICH PASSIERT, nachgelesen statt geglaubt:
      // `_nimmSpiegel` ruft NICHT `_lehnteAb` und loescht deshalb auch nichts.
      // Der Zweig darunter setzt `zustand = ContactState.active` fuer alles,
      // was keine Kontaktanfrage ist — eine Absage legte also einen Kontakt AN
      // oder machte einen abgelehnten wieder aktiv. Das ist der Schaden, und
      // genau er wird hier gemessen.
      //
      // MUTATION: in `_nimmSpiegel` `if (p.kind == PayloadKind.contactDecline)
      //           return;` gestrichen
      final eigen = await eigenesBuendel();
      final zweit = await Zweitgeraet.aus(woerter, 2);
      lage.liste = null;
      await kern.connect();

      final bob = await Fremder.mitGeraeten([1]);
      final carl = await Fremder.mitGeraeten([1]);

      // GEGENPROBE: derselbe Weg mit einem Text legt sehr wohl an. Ohne sie
      // waere ein kaputter Einwurf nicht von einem wirksamen Riegel zu
      // unterscheiden.
      wirfEin(
          await zweit.spiegelAn(
              kern.myId,
              eigen,
              bob.adresse,
              Payload.text('m-1', 'vom Handy', DateTime.now().toUtc())),
          2);
      await warteBis(
          () => kern.ablageFuerTest.kontakt(bob.adresse) != null);
      expect(kern.ablageFuerTest.kontakt(bob.adresse), isNotNull,
          reason: 'ein Text-Spiegel MUSS ankommen und den Chat anlegen — '
              'sonst misst der Fall darunter nichts');

      wirfEin(
          await zweit.spiegelAn(
              kern.myId,
              eigen,
              carl.adresse,
              Payload.control(PayloadKind.contactDecline, 'm-2',
                  DateTime.now().toUtc())),
          2);
      // Derselbe Weg wie oben — was er bewirken wuerde, waere laengst da.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(kern.ablageFuerTest.kontakt(carl.adresse), isNull,
          reason: 'ein Spiegel, der VOR der Aenderung entstand, darf nichts '
              'mehr ausloesen — Kontakte='
              '${kern.ablageFuerTest.alleKontakte().map((k) => k.state)}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 6
  group('Der gespiegelte eigene Anhang', () {
    test('DER KNOPF FINDET IHN UEBER DIE NACHRICHTENKENNUNG', () async {
      // Hier stand `anhang(contactId, contactId, messageId)`, also fest die
      // Adresse der Gegenstelle als Absender. Ein GESPIEGELTER Anhang traegt
      // aber `sender_id = myId` (`_nimmSpiegel`): auf dem Zweitgeraet fand der
      // Nachschlag nichts, der Knopf blieb trotzdem stehen und warf bei jedem
      // Tippen — obwohl die vollstaendige Anleitung in derselben Zeile liegt.
      //
      // GEMESSEN WIRD AN DER NAHBEREICHS-SPERRE, und das ist kein Trick: sie
      // steht in `holeAnhang` DIREKT HINTER dem Nachschlag. Wer sie sieht, hat
      // den Eintrag gefunden; wer sie nicht sieht, ist vorher am StateError
      // gescheitert. Ein Test, der wirklich herunterlaedt, brauchte ein
      // Zwischenlager mit Inhalt — fuer eine Aussage ueber eine Zeile
      // Nachschlag.
      //
      // MUTATION: `chats.anhaenge(contactId)[messageId]` ->
      //           `chats.anhang(contactId, contactId, messageId)`
      final eigen = await eigenesBuendel();
      final zweit = await Zweitgeraet.aus(woerter, 2);
      lage.liste = null;
      await kern.connect();

      final bob = await Fremder.mitGeraeten([1]);
      wirfEin(
          await zweit.spiegelAn(
              kern.myId,
              eigen,
              bob.adresse,
              Payload.anhang(
                  'a-1', beispielRezept(), DateTime.now().toUtc())),
          2);
      await warteBis(() =>
          kern.ablageFuerTest.anhaenge(bob.adresse).containsKey('a-1'));

      final eintrag = kern.ablageFuerTest.anhaenge(bob.adresse)['a-1'];
      expect(eintrag, isNotNull,
          reason: 'ohne den gespiegelten Anhang misst der Rest nichts');
      expect(eintrag!.senderId, kern.myId,
          reason: 'DAS ist der Grund fuer den ganzen Fall: auf dem '
              'Zweitgeraet bin ICH der Absender, nicht die Gegenstelle');

      // Der Schalter sperrt das Holen — er steht HINTER dem Nachschlag.
      await kern.setPreferences(const AppPreferences(nurNahbereich: true));

      await expectLater(
          kern.holeAnhang(bob.adresse, 'a-1'),
          throwsA(isA<NurNahbereichException>()),
          reason: 'ein StateError "kein Anhang zu a-1" hiesse: der Nachschlag '
              'ist am Absender gescheitert, und der Knopf wirft bei jedem '
              'Tippen');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('EINE GESPIEGELTE EINMAL-ANSICHT BLEIBT EINE (Befund M2)', () async {
      // Bis 25.09.2026 liess `_nimmSpiegel` das Kennzeichen fallen: auf dem
      // Zweitgeraet war die eigene Einmal-Ansicht ein gewoehnlicher Anhang —
      // beliebig oft zu oeffnen und in jeder Sicherung.
      final eigen = await eigenesBuendel();
      final zweit = await Zweitgeraet.aus(woerter, 2);
      lage.liste = null;
      await kern.connect();

      final bob = await Fremder.mitGeraeten([1]);
      final einmal = Rezept.ausText(beispielRezept()).alsEinmal().alsText();
      wirfEin(
          await zweit.spiegelAn(kern.myId, eigen, bob.adresse,
              Payload.anhang('a-2', einmal, DateTime.now().toUtc())),
          2);
      await warteBis(() =>
          kern.ablageFuerTest.anhaenge(bob.adresse).containsKey('a-2'));
      expect(kern.ablageFuerTest.anhaenge(bob.adresse)['a-2']!.einmal, isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 9
  group('Der Nachversand nach dem Verbinden', () {
    test('WAS AUS DER FUNKSTILLE WARTET, GEHT ERST NACH DEN EIGENEN GERAETEN '
        'HINAUS', () async {
      // `_stosseNachversandAn` haengt sich an ein bereits erfuelltes Future,
      // sein `.then` ist also eine Mikrotask und laeuft VOR jedem Netzereignis.
      // Was aus der Funkstille auf `sending` liegt, ginge dann hinaus,
      // waehrend `_bekannteGeraete(myId)` noch leer ist: kein Spiegel — und
      // weil die Nachricht danach auf `sent` steht, holt ihn auch nie jemand
      // nach. Genau die Nachrichten, die beim Koppeln warteten, fehlten auf
      // dem Zweitgeraet DAUERHAFT.
      //
      // MUTATION: `unawaited(_frischeEigeneGeraeteAuf()
      //           .whenComplete(_stosseNachversandAn));` ->
      //           `unawaited(_frischeEigeneGeraeteAuf());
      //            _stosseNachversandAn();`
      final bob = await Fremder.mitGeraeten([1]);
      await mitZweitgeraet();
      final vorher = lage.buendel!;
      lage.buendel = (wen) => wen == bob.adresse ? bob.karte() : vorher(wen);

      // OHNE VERBINDUNG GESCHRIEBEN — der Zustand, aus dem der Nachversand
      // ueberhaupt entsteht.
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      final m = await kern.sendMessage(bob.adresse, 'wartet seit gestern');
      expect(kern.ablageFuerTest.unversandt().map((u) => u.id), contains(m.id),
          reason: 'ohne wartende Nachricht misst dieser Fall nichts');

      // EIN UMLAUF, DER ZEIT KOSTET. Ein Relay, der in derselben Mikrotask
      // antwortet, macht aus der Reihenfolgefrage einen Muenzwurf — und ein
      // Test, der einen Muenzwurf misst, sagt nichts.
      lage.umlauf = const Duration(milliseconds: 30);

      await kern.connect();
      await warteBis(() => lage.gesendet.any((g) => g.an == bob.adresse));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(lage.gesendet.where((g) => g.an == bob.adresse), isNotEmpty,
          reason: 'der Nachversand muss ueberhaupt laufen');
      expect(lage.gesendet.where((g) => g.an == kern.myId), isNotEmpty,
          reason: 'die wartende Nachricht muss auch das eigene Zweitgeraet '
              'erreichen — laeuft der Nachversand vor dem Auffrischen, fehlt '
              'sie dort fuer immer (§4)');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
