// mehrgeraete_riegel_test.dart — die Riegel des Mehrgeraete-Umbaus.
//
// Die neun Faelle hier haben eines gemeinsam: sie stehen gegen einen
// FEINDLICHEN oder KAPUTTEN RELAY. Genau deshalb laeuft hier kein echter
// relay_server.py — er tut ja das Richtige. Was geprueft werden muss, ist,
// was der Client tut, wenn die Gegenseite luegt, klemmt oder zu viel meldet;
// und das laesst sich nur mit einer Attrappe herstellen, die auf Kommando
// luegt.
//
// ALLES ANDERE IST ECHT: echter Kern, echte verschluesselte Datenbank, echtes
// libsignal, echte X3DH-Sitzungen. Nachgebaut ist nur, was HTTP und WebSocket
// waeren.
//
// ═══════════════════════════════════════════════════ MUTATIONSPROBE 01.08.2026
//
// Jeder Fall wurde gegen eine zurueckgedrehte Behebung laufen gelassen. Was
// dabei rot wurde, steht am Fall. Wer eine dieser Zeilen spaeter nicht mehr
// reproduzieren kann, hat einen Test vor sich, der nichts mehr prueft.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../support/relay_attrappe.dart';

class NahAttrappe implements Nahbereich {
  final _eingang = StreamController<NahUmschlag>.broadcast();
  final _post = StreamController<NahSonderpost>.broadcast();
  final _neuDa = StreamController<String>.broadcast();

  bool _laeuft = false;
  int starteRufe = 0;
  int haltRufe = 0;
  final sonderGesendet = <({String an, int typ, Uint8List nutzlast})>[];

  void poste(NahSonderpost p) => _post.add(p);

  @override
  Stream<NahUmschlag> get eingang => _eingang.stream;
  @override
  Stream<NahSonderpost> get sonderpost => _post.stream;
  @override
  Stream<String> get neuInReichweite => _neuDa.stream;
  @override
  bool get laeuft => _laeuft;
  @override
  bool get bereit => _laeuft;
  @override
  List<String> get inReichweite => const [];

  @override
  Future<void> starte({
    required List<NahKontakt> kontakte,
    required Uint8List eigenerOeffentlicher,
  }) async {
    starteRufe++;
    _laeuft = true;
  }

  @override
  Future<void> halt() async {
    haltRufe++;
    _laeuft = false;
  }

  @override
  Future<void> schicke(String an, Uint8List umschlag) async {}

  @override
  Future<void> schickeSonder(String an, int typ, Uint8List nutzlast) async =>
      sonderGesendet.add((an: an, typ: typ, nutzlast: nutzlast));

  @override
  Future<void> dispose() async {
    await _eingang.close();
    await _post.close();
    await _neuDa.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

void main() {
  late Directory ordner;
  late SpeicherImKopf tresor;
  late Relaylage lage;
  late NahAttrappe nah;
  late RealMessengerCore kern;
  late List<String> woerter;

  Future<void> warteBis(bool Function() fertig) async {
    for (var i = 0; i < 600 && !fertig(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-riegel');
    tresor = SpeicherImKopf();
    lage = Relaylage();
    nah = NahAttrappe();
    kern = RealMessengerCore(
      secretStore: tresor,
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = RelayAttrappe(id, lage);
        lage.gebaut.add(r);
        return r;
      },
      nahFactory: () => nah,
    );
    await kern.initialize();
    woerter = await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    await nah.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  /// Eine ZWEITE Ansicht auf dieselbe Datenbank.
  ///
  /// Der Kern gibt seinen Schluesselspeicher nicht heraus und soll es auch
  /// nicht. Gelesen wird nur — was hier herauskommt, ist genau das, was der
  /// Relay von uns ausgeliefert bekaeme.
  Future<BitdmSignalStore> eigenerSpeicher() async =>
      SignalStoreRepository(kern.datenbankFuerTest)
          .openStore(await KeyDerivation.fromMnemonic(woerter));

  /// Mit welchen (Adresse, Geraet) es eine Sitzung gibt.
  ///
  /// AUS DER DATENBANK UND NICHT AUS DEM SPEICHER DES KERNS: eine Sitzung, die
  /// nur im Arbeitsspeicher stuende, waere nach dem naechsten Start weg — und
  /// eine, die geschrieben wurde, ist da. Gefragt ist die geschriebene.
  List<String> sitzungen() => kern.datenbankFuerTest.raw
      .select('SELECT address FROM sessions')
      .map((r) => r['address']! as String)
      .toList()
    ..sort();

  // ═══════════════════════════════════════════════════════════════════ 1
  group('Der Reflexionsriegel (§12.1)', () {
    test(
        'EIN ERFUNDENES EIGENES GERAET MIT UNSEREM EIGENEN PREKEY BEKOMMT '
        'KEINE SITZUNG', () async {
      // DER WICHTIGSTE FALL DIESER DATEI.
      //
      // Ein feindlicher Relay behauptet unter UNSERER Adresse ein Geraet 7 und
      // legt dort UNSER EIGENES signiertes Prekey-Paar hinein, kopiert aus
      // unserer echten Zeile. Alles Weitere haelt von selbst: die Signatur des
      // Prekeys ist echt (wir haben sie erzeugt), und `isTrustedIdentity`
      // rechnet die Adresse aus dem Schluessel nach — bei der EIGENEN Adresse
      // passt der eigene Schluessel per Konstruktion.
      //
      // Danach stuende eine Sitzung mit uns selbst. Sie ist der Einstieg:
      // `_bekannteGeraete(myId)` waere nichtleer, jede Nachricht spiegelte an
      // dieses Phantom, und der Relay koennte diese Spiegel beliebig oft
      // zurueckwerfen — wir entschluesseln unsere eigenen Bytes, weil DH
      // symmetrisch ist und der Identitaetsschluessel auf beiden Seiten
      // derselbe.
      //
      // MUTATION: `_istEigenesBuendel` -> `async => false`
      final ich = await eigenerSpeicher();
      final meinSpk =
          await ich.loadSignedPreKey(ich.state.signedPreKeys.keys.first);
      final meinOtk = await ich.loadPreKey(ich.state.preKeys.keys.first);

      // ZWEI ECHTE ANDERE GERAETE derselben Adresse: dieselbe Identitaet aus
      // denselben zwoelf Woertern, aber je ein EIGENER signierter Prekey. So
      // sieht ein zweites Telefon wirklich aus — jede Installation wuerfelt
      // ihren eigenen (libsignal `key_helper.dart`).
      //
      // SIE MUESSEN MIT IM SPIEL SEIN, sonst prueft dieser Test nichts: waere
      // `_bauSitzungen` insgesamt kaputt, entstuende auch keine Phantomsitzung
      // und die Zusicherung unten bliebe gruen. Die legitimen Geraete sind die
      // Gegenprobe.
      //
      // Dieses Geraet ist uebrigens WEDER 1 NOCH 2: die Liste unten ist
      // nichtleer, also wuerfelt `_ermittleGeraetId` eine Kennung ab 2 (§1).
      // Beide anderen sind damit fremde Geraete.
      final erstSpk = generateSignedPreKey(ich.identity.keyPair, 76);
      final zweitSpk = generateSignedPreKey(ich.identity.keyPair, 77);

      Map<String, Object?> geraet(int id, SignedPreKeyRecord spk) => {
            'device_id': id,
            'registration_id': ich.identity.registrationId,
            'signed_prekey_id': spk.id,
            'signed_prekey':
                base64.encode(spk.getKeyPair().publicKey.serialize()),
            'signed_prekey_sig': base64.encode(spk.signature),
            'one_time_prekey': {
              'key_id': meinOtk.id,
              'public_key':
                  base64.encode(meinOtk.getKeyPair().publicKey.serialize()),
            },
          };

      lage.liste = [1, 2, 7];
      lage.buendel = (wen) => {
            'user_id': kern.myId,
            'identity_key': base64.encode(ich.identity.rawPublicKey),
            ...geraet(1, meinSpk),
            'geraete': [
              geraet(1, erstSpk),
              geraet(2, zweitSpk),
              // DAS PHANTOM: eigene Bytes unter fremder Nummer.
              geraet(7, meinSpk),
            ],
          };

      await kern.connect();
      // `_frischeEigeneGeraeteAuf` laeuft unawaited weiter — gewartet wird auf
      // sein Ergebnis, nicht auf eine Uhr.
      await warteBis(() => sitzungen().length >= 2);

      expect(sitzungen(), containsAll(['${kern.myId}:1', '${kern.myId}:2']),
          reason: 'die ECHTEN anderen Geraete muessen eine Sitzung bekommen — '
              'ohne diese Haelfte saegte der Test seinen eigenen Ast ab');
      expect(sitzungen(), isNot(contains('${kern.myId}:7')),
          reason: 'unser eigenes Schluesselmaterial unter einer fremden '
              'Geraetenummer ist NIE legitim: jede Installation wuerfelt '
              'ihren eigenen signierten Prekey (§12.1) — Sitzungen='
              '${sitzungen()}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 2
  group('Die eigene Geraetekennung', () {
    test('EIN 502 BRENNT DIE KENNUNG NICHT AUF 1 EIN', () async {
      // [_setzeGeraetId] schreibt in `meta`, und danach fragt niemand mehr.
      // Wer aus einer Zeitueberschreitung, einem 429 oder einem 502 die 1
      // macht, hat sie FUER IMMER gemacht — auf einem Zweitgeraet heissen dann
      // beide Geraete 1, sie ueberschreiben sich beim Relay die Zeile,
      // loeschen sich die Einmalschluessel und rasten bei jeder Gegenstelle
      // dieselbe Sitzung weiter. Der stille, dauerhafte Verlust aus §10.
      //
      // MUTATION: in `_ermittleGeraetId` `if (e.statusCode != 404) rethrow;`
      //           gestrichen
      lage.listeFehler =
          const RelayException('Bad Gateway', statusCode: 502);

      await kern.connect();

      // DIESE ZUSICHERUNG ZUERST, und das ist kein Geschmack: sie ist die
      // Regel. Stuende die ueber den Verbindungszustand davor, faellt bei
      // einer zurueckgedrehten Behebung SIE, und die rote Meldung spraeche vom
      // Zustand statt von der gebrannten Kennung.
      expect(kern.datenbankFuerTest.meta('device_id'), isNull,
          reason: 'DAS IST DER PUNKT: nichts in `meta`. Vertagen ist heilbar, '
              'Brennen nicht');
      expect(kern.connectionState, ConnectionState.error,
          reason: 'ein Transportfehler ist keine Antwort — der Versuch muss '
              'scheitern, statt sich eine Kennung auszudenken');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('NACH DEM FEHLSCHLAG WIRD BEIM NAECHSTEN VERSUCH NEU GEFRAGT',
        () async {
      // Die zweite Haelfte derselben Regel, und ohne sie waere die erste
      // wertlos: eine Kennung, die nie ermittelt wird, ist genauso kaputt wie
      // eine falsch gebrannte.
      lage.listeFehler =
          const RelayException('zu viele Anfragen', statusCode: 429);
      await kern.connect();
      final nachDemFehlschlag = lage.listeAbrufe;

      // Der Relay ist wieder da und meldet ein bestehendes Geraet 1.
      lage.listeFehler = null;
      lage.liste = [1];
      await kern.connect();

      final gebrannt = kern.datenbankFuerTest.meta('device_id');
      // KEINE FESTE ZAHL, sondern ein Zuwachs: nach einem gelungenen Verbinden
      // fragt `_frischeEigeneGeraeteAuf` dieselbe Liste noch einmal fuer die
      // eigenen Geraete (real_messenger_core:514). Diese Frage gehoert einem
      // anderen Fall; sie hier festzunageln hiesse, diesen Test rot werden zu
      // lassen, wenn dort etwas geaendert wird, das ihn nichts angeht.
      expect(lage.listeAbrufe, greaterThan(nachDemFehlschlag),
          reason: 'die Frage muss noch einmal gestellt werden — sonst bleibt '
              'die Kennung auf ewig unbestimmt');
      expect(gebrannt, isNotNull);
      expect(gebrannt, isNot('1'),
          reason: 'die Adresse hat schon ein Geraet 1 — dieses hier ist das '
              'zweite und braucht eine eigene Kennung (§1)');
      expect(int.parse(gebrannt!), greaterThanOrEqualTo(2));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 3
  group('Der Nahbereich gehoert Geraet 1', () {
    test('EIN ZWEITGERAET FUNKT NICHT', () async {
      // Der Umschlag des Nahbereichs fuehrt kein Absendergeraet
      // (envelope.dart). Funkte ein Zweitgeraet mit, landete SEIN
      // Schluesselmaterial bei der Gegenstelle unter "adresse:1" — und weil
      // `_bauSitzungen` eine bestehende Sitzung nie ersetzt, bliebe es dort
      // fuer immer. Alles, was die Gegenstelle danach an Geraet 1 schickt,
      // waere fuer Geraet 1 unlesbar.
      //
      // MUTATION: `_setzeNaheAuf` `if (store == null || !_prefs.naheAn ||
      //           !_darfFunken)` -> ohne `!_darfFunken`
      await kern.setPreferences(const AppPreferences(naheAn: true));
      await kern.nahRuhtFuerTest;
      expect(nah.laeuft, isTrue,
          reason: 'als Geraet 1 laeuft der Funk — sonst misst der Rest nichts');

      lage.liste = [1];
      await kern.connect();
      await kern.nahRuhtFuerTest;

      expect(nah.laeuft, isFalse,
          reason: 'sobald die Kennung nicht 1 ist, muss der Funk aus sein '
              '(starte=${nah.starteRufe} halt=${nah.haltRufe})');

      // Und er kommt auch nicht durch die Hintertuer wieder: ein neuer Kontakt
      // stoesst das Aufsetzen erneut an.
      await kern.setPreferences(const AppPreferences(naheAn: true));
      await kern.nahRuhtFuerTest;
      expect(nah.laeuft, isFalse,
          reason: 'auch ein erneutes Aufsetzen darf ihn nicht anwerfen');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('EIN ZWEITGERAET BEANTWORTET KEINE BUENDELANFRAGE UEBER FUNK',
        () async {
      // Die zweite Haelfte, und sie muss eigens dastehen: die Karte, die
      // `_schickeBuendelUeberFunk` verschickt, hat kein `device_id`-Feld — die
      // Gegenseite legt sie unter "adresse:1" ab. Antwortete ein Zweitgeraet,
      // vergiftete sein Schluesselmaterial dort dauerhaft die Sitzung zu
      // Geraet 1.
      //
      // MUTATION: `_schickeBuendelUeberFunk` `if (nah == null ||
      //           !_darfFunken) return;` -> ohne `!_darfFunken`
      final fremd = await Fremder.mitGeraeten([1]);
      // Die Grenze gegen das Leerfragen steht der zweiten Anfrage im Weg; sie
      // hat ihren eigenen Fall in nahweg_test.dart.
      kern.buendelAbstand = Duration.zero;
      await kern.setPreferences(const AppPreferences(naheAn: true));
      await kern.nahRuhtFuerTest;

      // ALS GERAET 1 WIRD GEANTWORTET. Ohne diese Haelfte bliebe der Test auch
      // dann gruen, wenn der ganze Antwortweg tot waere.
      nah.poste(NahSonderpost(
          fremd.adresse, Nahtyp.buendelAnfrage, Uint8List(0)));
      await warteBis(() => nah.sonderGesendet.isNotEmpty);
      expect(nah.sonderGesendet.single.typ, Nahtyp.buendelAntwort,
          reason: 'Geraet 1 muss antworten — sonst kommt BitDM ohne Internet '
              'nie ins Gespraech');

      lage.liste = [1];
      await kern.connect();
      await kern.nahRuhtFuerTest;
      nah.sonderGesendet.clear();

      nah.poste(NahSonderpost(
          fremd.adresse, Nahtyp.buendelAnfrage, Uint8List(0)));
      // Eine Antwort waere laengst da — der Weg dorthin ist derselbe wie oben.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(nah.sonderGesendet, isEmpty,
          reason: 'ein Zweitgeraet, das sein Buendel ueber Funk herausgibt, '
              'vergiftet bei der Gegenstelle dauerhaft die Sitzung zu '
              'Geraet 1 — gesendet=${nah.sonderGesendet.map((s) => s.typ)}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 4
  group('Das Fanout', () {
    test('SCHLAEGT EIN GERAET FEHL, BLEIBT DIE NACHRICHT AUF SENDING',
        () async {
      // Hier stand "sobald EIN Geraet angenommen hat, ist sie draussen". Das
      // traegt nicht: ein Fehlschlag je Geraet war damit unsichtbar — der
      // Gesamtbescheid wurde `relay`, `_versucheZuSenden` setzte
      // MessageStatus.sent, und `unversandt()` sieht nur `sending`. Das
      // uebersprungene Geraet bekam die Nachricht NIE, ohne Fehler und ohne
      // Spur.
      //
      // MIT EINER ATTRAPPE UND NICHT MIT DEM ECHTEN RELAY, und das ist eine
      // Aussage ueber den Fall, nicht ueber die Bequemlichkeit: der echte
      // relay_server.py nimmt fuer ein eingetragenes, aber nicht verbundenes
      // Geraet eine Warteschlangenzeile an und bestaetigt — er erzeugt gar
      // keinen Fehlschlag je Geraet. Um einen herzustellen, muesste man ihm
      // eine Geraetezeile unter den Fuessen wegloeschen. Was hier geprueft
      // wird, ist ohnehin reine Buchfuehrung des Clients.
      //
      // MUTATION: `final weg = einesLiegt ? Weg.liegt : ...` -> ohne den
      //           `einesLiegt`-Zweig
      final bob = await Fremder.mitGeraeten([1, 2]);
      lage.buendel = (wen) => bob.karte();
      lage.liste = null;
      await kern.connect();

      await kern.addContact(bob.adresse);
      await warteBis(() => lage.gesendet.isNotEmpty);
      // Der Kontakt muss aktiv sein, sonst weist `sendMessage` ab.
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));

      // Geraet 2 nimmt nichts mehr an. Geraet 1 sehr wohl.
      lage.sendeFehlerFuerGeraet = {2};
      lage.gesendet.clear();
      final m = await kern.sendMessage(bob.adresse, 'an beide Geraete');
      await warteBis(() => lage.gesendet.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(lage.gesendet.map((g) => g.geraet), contains(1),
          reason: 'Geraet 1 hat sie bekommen — der Fehlschlag ist ein '
              'Fehlschlag JE GERAET, kein Totalausfall');
      expect(kern.ablageFuerTest.unversandt().map((u) => u.id), contains(m.id),
          reason: 'ein uebersprungenes Geraet muss sichtbar bleiben: nur was '
              'auf `sending` steht, holt `unversandt()` wieder — sonst bekommt '
              'es die Nachricht NIE (§10)');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ═══════════════════════════════════════════════════════════════════ 8
  group('Der Stempel der Geraetepruefung', () {
    test('EIN GESCHEITERTER BUENDELABRUF GILT NICHT SECHS STUNDEN LANG',
        () async {
      // `setzeGeraeteGeprueft` steht HINTER dem Sitzungsaufbau. Stempelte man
      // davor, gaelte die Frage sechs Stunden als beantwortet, obwohl die
      // Antwort nie kam — das neue Geraet der Gegenstelle bliebe so lange
      // unbeliefert (Spezifikation §4).
      //
      // MUTATION: in `_sendePayload` die Zeile `_chats?.setzeGeraeteGeprueft(
      //           an, ...)` VOR `ziele = await _bauSitzungen(...)` gezogen
      final bob = await Fremder.mitGeraeten([1]);
      lage.liste = null;
      lage.buendel = (wen) => bob.karte();
      await kern.connect();

      lage.buendelFehler =
          const RelayException('zu viele Anfragen', statusCode: 429);
      await kern.addContact(bob.adresse);
      await warteBis(() => lage.buendelAbrufe > 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(kern.ablageFuerTest.geraeteGeprueft(bob.adresse), 0,
          reason: 'nichts wurde geprueft, also darf auch nichts als geprueft '
              'gelten');

      // GEGENPROBE: geht der Abruf durch, wird sehr wohl gestempelt. Ohne sie
      // bliebe der Test auch dann gruen, wenn gar nicht mehr gestempelt wird.
      lage.buendelFehler = null;
      await kern.acceptRequest(bob.adresse);
      await warteBis(() => kern.ablageFuerTest.geraeteGeprueft(bob.adresse) > 0);
      expect(kern.ablageFuerTest.geraeteGeprueft(bob.adresse), greaterThan(0),
          reason: 'ein gelungener Abruf MUSS stempeln — sonst kostete jede '
              'Nutzlast einen eigenen /prekey-Umlauf');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ══════════════════════════════════════════════════════════════════ 11
  group('Der Deckel auf die Geraeteliste', () {
    test('EIN RELAY MIT ACHT GERAETEN BEKOMMT NUR FUENF VERSCHLUESSELUNGEN',
        () async {
      // `alleGeraete` kommt vom Relay und ist fremde Eingabe wie jede andere.
      // Ohne Deckel liefert ein feindlicher Relay 2000 Geraetezeilen, und der
      // Client baut zu jeder eine Sitzung und verschluesselt jede Nachricht
      // dagegen — eine Nutzernachricht waere beliebig teuer.
      //
      // AUFSTEIGEND GESCHNITTEN, weil der Relay so ausliefert (§3.3) und weil
      // Geraet 1 dadurch nie herausfaellt: ein Client ohne die Erweiterung
      // koennte diese Adresse sonst gar nicht mehr erreichen.
      //
      // MUTATION: in `_bauSitzungen` `alle.length <= geraeteMax ? alle :
      //           (...).take(geraeteMax)` -> `alle`
      final viele = await Fremder.mitGeraeten([1, 2, 3, 4, 5, 6, 7, 8]);
      lage.liste = null;
      lage.buendel = (wen) => viele.karte();
      await kern.connect();

      await kern.addContact(viele.adresse);
      await warteBis(() => lage.gesendet.length >= RealMessengerCore.geraeteMax);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(RealMessengerCore.geraeteMax, 5,
          reason: 'die Zahl unten ist nachgerechnet, nicht geraten');
      expect((lage.gesendet.map((g) => g.geraet).toSet().toList()..sort()),
          [1, 2, 3, 4, 5],
          reason: 'genau die fuenf niedrigsten Kennungen — nicht mehr, und '
              'Geraet 1 nie ausgelassen (§6)');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ══════════════════════════════════════════════════════════════════ 12
  group('Die Adresse hat schon genug Geraete (507)', () {
    test('EIN 507 IST KEIN FUNKLOCH, SONDERN EIN EIGENER ZUSTAND', () async {
      // Der Relay hat 507 statt 429 gerade deswegen gewaehlt: "das ist keine
      // Bremse, die nachgibt". Ohne diese Unterscheidung sieht die App wie ein
      // Funkloch aus — dauerhaft "keine Verbindung" — und der
      // Wiederverbindungszeitgeber (app_state `_planeWiederverbindung`) laeuft
      // bis in alle Ewigkeit gegen eine Antwort, die sich nie aendert.
      //
      // MUTATION: `_abgewiesen = fehler is RelayException &&
      //           fehler.statusCode == 507;` -> `_abgewiesen = false;`
      lage.anmeldeFehler = const RelayException(
          'Adresse hat schon genug Geraete',
          statusCode: 507);

      await kern.connect();

      expect(kern.connectionState, ConnectionState.error);
      expect(kern.abgewiesen, isTrue,
          reason: 'nur an dieser Zahl haengt der Text "Geraete voll" statt '
              '"keine Verbindung" (main.dart connGeraeteVoll)');

      // GEGENPROBE: ein gewoehnlicher Netzfehler darf sie NICHT setzen —
      // sonst haette die Unterscheidung keine Seite.
      lage.anmeldeFehler = const RelayException('Relay nicht erreichbar');
      await kern.connect();
      expect(kern.connectionState, ConnectionState.error);
      expect(kern.abgewiesen, isFalse,
          reason: 'ein Funkloch gibt nach, eine volle Adresse nicht');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
