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
import 'package:bitdm/core/net/prekey_bundle_bridge.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

/// Dieselbe Karte, wie sie eine App VOR 2.0.0 beim Relay hinterlaesst: ohne
/// die Kyber-Felder — flach und in jedem Eintrag von `geraete`.
///
/// Der echte relay_server.py laesst die vier Felder bei einem solchen Geraet
/// GANZ weg (nicht als null, siehe `/prekey`), genau das bildet das hier nach.
Map<String, Object?> alsAlteApp(Map<String, Object?> karte) {
  const kyberFelder = [
    'kyber_prekey_id',
    'kyber_prekey',
    'kyber_prekey_sig',
    'kyber_einmal',
  ];
  final neu = Map.of(karte)..removeWhere((k, _) => kyberFelder.contains(k));
  final geraete = neu['geraete'];
  if (geraete is List) {
    neu['geraete'] = [
      for (final g in geraete)
        Map.of((g as Map).cast<String, Object?>())
          ..removeWhere((k, _) => kyberFelder.contains(k)),
    ];
  }
  return neu;
}

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
  bool bereitFuer(String an) => _laeuft;
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
      //
      // DIESER KERN IST GERAET 1 — seit 16.10.2026, vorher war er "weder 1
      // noch 2" (eine gewuerfelte Kennung). Die offizielle libsignal nimmt in
      // `ProtocolAddress` nur Kennungen 1..127 an, `_ermittleGeraetId`
      // wuerfelt aber bis 2^31; ein Kern mit gewuerfelter Kennung baut deshalb
      // derzeit GAR KEINE Sitzung, und dieser Fall waere aus dem falschen Grund
      // gruen (keine Phantomsitzung, weil gar keine). Der Befund hat seinen
      // eigenen Fall darunter ("DIE GERAETEKENNUNG PASST IN LIBSIGNALS
      // BEREICH"). Hier geht es um den Riegel: erst als Geraet 1 angemeldet,
      // dann meldet der Relay die weiteren Geraete.
      lage.liste = null;
      await kern.connect();
      expect(kern.geraetId, 1);
      await kern.disconnect();

      final ich = await eigenerSpeicher();
      final meinSpk = (await ich.loadSignedPreKey(
          ich.state.signedPreKeys.keys.reduce((a, b) => a > b ? a : b)))!;
      final meinOtk = (await ich.loadPreKey(ich.state.preKeys.keys.first))!;
      final meinKyber = (await ich.loadKyberPreKey(ich.letzteRettungId!))!;

      // ZWEI ECHTE ANDERE GERAETE derselben Adresse: dieselbe Identitaet aus
      // denselben zwoelf Woertern, aber je ein EIGENER signierter Prekey (und
      // eigener Kyber-Prekey). So sieht ein zweites Telefon wirklich aus —
      // jede Installation wuerfelt ihren eigenen (`_fuelleVorratAuf`).
      //
      // SIE MUESSEN MIT IM SPIEL SEIN, sonst prueft dieser Test nichts: waere
      // `_bauSitzungen` insgesamt kaputt, entstuende auch keine Phantomsitzung
      // und die Zusicherung unten bliebe gruen. Die legitimen Geraete sind die
      // Gegenprobe.
      final zweitSpk = neuerSpk(ich.identity.keyPair, 76);
      final drittSpk = neuerSpk(ich.identity.keyPair, 77);
      final zweitKyber = neuerKyber(ich.identity.keyPair, 76);
      final drittKyber = neuerKyber(ich.identity.keyPair, 77);

      Map<String, Object?> geraet(
              int id, SignedPreKeyRecord spk, KyberPreKeyRecord kyber) =>
          {
            'device_id': id,
            'registration_id': ich.identity.registrationId,
            'signed_prekey_id': spk.id(),
            'signed_prekey': base64.encode(spk.publicKey()),
            'signed_prekey_sig': base64.encode(spk.signature()),
            'one_time_prekey': {
              'key_id': meinOtk.id(),
              'public_key': base64.encode(meinOtk.publicKey()),
            },
            'kyber_prekey_id': kyber.id(),
            'kyber_prekey': base64.encode(kyber.getPublicKey().serialize()),
            'kyber_prekey_sig': base64.encode(kyber.signature()),
          };

      lage.liste = [1, 2, 3, 7];
      lage.buendel = (wen) => {
            'user_id': kern.myId,
            'identity_key': base64.encode(ich.identity.rawPublicKey),
            ...geraet(1, meinSpk, meinKyber),
            'geraete': [
              // Unsere echte Zeile — die faellt schon an der Kennung heraus.
              geraet(1, meinSpk, meinKyber),
              geraet(2, zweitSpk, zweitKyber),
              geraet(3, drittSpk, drittKyber),
              // DAS PHANTOM: eigene Bytes unter fremder Nummer.
              geraet(7, meinSpk, meinKyber),
            ],
          };

      await kern.connect();
      // `_frischeEigeneGeraeteAuf` laeuft unawaited weiter — gewartet wird auf
      // sein Ergebnis, nicht auf eine Uhr.
      await warteBis(() => sitzungen().length >= 2);

      expect(sitzungen(), containsAll(['${kern.myId}:2', '${kern.myId}:3']),
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

    test('DIE GERAETEKENNUNG PASST IN LIBSIGNALS BEREICH (1..127)', () async {
      // BEFUND VOM 16.10.2026, beim Umstieg auf die offizielle libsignal.
      //
      // `ProtocolAddress` der offiziellen libsignal (0.105) nimmt nur
      // Geraetekennungen 1..127 und wirft sonst: "Invalid device ID: …
      // (must be 1-127)". `_neueGeraetId` wuerfelt aber aus 2..2^31−1 — im
      // Bereich landet es mit 126 zu 2^31. Ein Zweitgeraet kann damit WEDER
      // verschluesseln NOCH entschluesseln: `_eigeneAdresse` wirft bei jedem
      // `_chiffre` und jedem `_sitzungsBauer`. Die Dart-Nachbildung kannte
      // diese Grenze nicht, deshalb fiel es bis 1.9.x nie auf.
      //
      // ZWEI MESSUNGEN: die Zahl und ihre Wirkung. Die Zahl allein waere eine
      // Behauptung ueber libsignal; dass ein Zweitgeraet wirklich schreiben
      // kann, ist das, worauf es ankommt.
      final bob = await Fremder.mitGeraeten([1]);
      lage.liste = [1];
      lage.buendel = (wen) => wen == bob.adresse ? bob.karte() : const {};
      await kern.connect();

      final gebrannt = int.parse(kern.datenbankFuerTest.meta('device_id')!);
      expect(gebrannt, inInclusiveRange(2, 127),
          reason: 'libsignal nimmt nur 1..127 — mit der Kennung $gebrannt kann '
              'dieses Zweitgeraet nichts ver- oder entschluesseln '
              '(real_messenger_core `_neueGeraetId`)');

      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      await kern.sendMessage(bob.adresse, 'vom Zweitgeraet');
      await warteBis(() => lage.gesendet.any((g) => g.an == bob.adresse));
      expect(lage.gesendet.where((g) => g.an == bob.adresse), isNotEmpty,
          reason: 'ein Zweitgeraet muss schreiben koennen');
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

  // ══════════════════════════════════════════════════════════════════ 4b
  group('Geraete einer alten App (ohne Kyber)', () {
    // SEIT 2.0.0 baut die App nur noch PQXDH-Sitzungen. Ein Geraet, dessen
    // Buendel beim Relay keine Kyber-Felder traegt, laeuft mit einer App vor
    // 2.0.0 — mit ihm gibt es keine Sitzung, und einen Rueckweg auf X3DH gibt
    // es bewusst nicht (docs/LIBSIGNAL-UMSTIEG.md: kein Downgrade).
    //
    // WIE DER KERN DAMIT UMGEHT (`_bauSitzungen`, Stand 16.10.2026): ein
    // solches Geraet wird UEBERSPRUNGEN; die anderen Geraete derselben
    // Adresse bekommen ihre Sitzung trotzdem. Nur wenn KEIN Geraet Kyber hat,
    // wirft `_bauSitzungen` die GegenstelleOhneKyberException weiter.
    //
    // Die beiden Faelle hier nageln genau das fest — und dazu, was danach mit
    // der Ausnahme passiert.

    test('EIN GERAET OHNE KYBER WIRD UEBERSPRUNGEN — DIE ANDEREN BEKOMMEN SIE',
        () async {
      // Bob hat ein neues Telefon (Geraet 1, mit Kyber) und ein altes Tablet
      // (Geraet 2, App vor 2.0.0). Bis zur Behebung in `_bauSitzungen` warf
      // das Tablet die Ausnahme mitten in der Schleife: Bob bekam GAR NICHTS,
      // auch nicht auf dem Telefon, das laengst aktualisiert war.
      final bob = await Fremder.mitGeraeten([1, 2]);
      final karte = bob.karte()
        ..['geraete'] = [
          bob.geraetekarte(1),
          alsAlteApp(bob.geraetekarte(2)),
        ];
      lage.buendel = (wen) => karte;
      lage.liste = null;
      await kern.connect();

      // DIE VORAUSSETZUNG: das Tablet ist wirklich eines ohne Kyber.
      expect(
          () => PreKeyBundleBridge.fromRelay(
              RelayBundleResponse.fromJson(karte).alleGeraete[1],
              deviceId: 2),
          throwsA(isA<GegenstelleOhneKyberException>()
              .having((e) => e.adresse, 'adresse', bob.adresse)
              .having((e) => e.geraet, 'geraet', 2)));

      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      final m = await kern.sendMessage(bob.adresse, 'an das neue Telefon');
      await warteBis(() => lage.gesendet.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // ALS MENGE: der Nachversand aus `connect()` kann dieselbe Nachricht
      // ein zweites Mal an Geraet 1 schicken (er laeuft unawaited hinter dem
      // Verbinden her). Gefragt ist hier, WELCHE Geraete etwas bekommen.
      expect(lage.gesendet.map((g) => g.geraet).toSet(), {1},
          reason: 'das Telefon mit neuer App bekommt die Nachricht, das '
              'Tablet ohne Kyber nicht — und es haelt das Telefon nicht auf');
      expect(sitzungen(), contains('${bob.adresse}:1'));
      expect(sitzungen(), isNot(contains('${bob.adresse}:2')),
          reason: 'ohne Kyber darf keine Sitzung entstehen, auch keine '
              'schwaechere');
      // IST-VERHALTEN: das uebersprungene Geraet zaehlt NICHT als
      // Fehlschlag. Die Nachricht steht auf "gesendet", obwohl das Tablet sie
      // nie bekommt — anders als ein Geraet, dessen Zustellung scheitert
      // (Fall "SCHLAEGT EIN GERAET FEHL" darueber). Das ist gewollt: sonst
      // bliebe JEDE Nachricht an Bob fuer immer auf "sending", bis er das
      // Tablet aktualisiert.
      expect(kern.ablageFuerTest.unversandt().map((u) => u.id),
          isNot(contains(m.id)));
      // Und die Geraeteliste gilt als geprueft: das Tablet wird erst nach dem
      // Fenster (`geraeteFenster`) wieder angefragt — wer dann aktualisiert
      // hat, bekommt ab da seine Sitzung.
      expect(kern.ablageFuerTest.geraeteGeprueft(bob.adresse), greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('EIN GERAET MIT KENNUNG UEBER 127 (aus 1.9.x) HAELT DIE ANDEREN NICHT '
        'AUF', () async {
      // DER ZWEITE BEFUND ZUR GERAETEKENNUNG, von der anderen Seite.
      //
      // Jedes Zweitgeraet, das sich unter 1.9.x angemeldet hat, traegt eine
      // gewuerfelte Kennung bis 2^31 (`_neueGeraetId`). Die offizielle
      // libsignal nimmt in `ProtocolAddress` nur 1..127. In `_bauSitzungen`
      // steht `ProtocolAddress(name: an, deviceId: b.deviceId)` VOR jeder
      // Pruefung und ohne Fang: die LibSignalException (invalidArgument)
      // bricht die Schleife ab, und Bob bekommt GAR NICHTS — auch nicht auf
      // Geraet 1, das laengst aktualisiert ist. Dasselbe Muster wie beim
      // Geraet ohne Kyber darueber, nur ohne die Behebung.
      //
      // Hier mit Kyber auf beiden Geraeten, damit der Fall wirklich nur die
      // Kennung misst. ROT, bis lib/ das behebt (Schlussbericht 16.10.2026).
      final bob = await Fremder.mitGeraeten([1, 70935140]);
      lage.buendel = (wen) => bob.karte();
      lage.liste = null;
      await kern.connect();

      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      await kern.sendMessage(bob.adresse, 'an Bobs Telefon');
      await warteBis(() => lage.gesendet.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(lage.gesendet.map((g) => g.geraet).toSet(), contains(1),
          reason: 'ein Geraet mit einer Kennung, die libsignal nicht nimmt, '
              'darf den Versand an Bobs uebrige Geraete nicht verhindern');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('HAT KEIN GERAET KYBER, BLEIBT DIE NACHRICHT LIEGEN — UND ZWAR STILL',
        () async {
      // Die Adresse hat nur Geraete mit alter App. Hier kommt
      // GegenstelleOhneKyberException aus `_bauSitzungen` heraus, durch
      // `_sendePayload` hindurch — und landet in `_versucheZuSenden` im
      // allgemeinen `catch (_)`. DAS IST DAS IST-VERHALTEN, festgehalten:
      //
      //  - `sendMessage` wirft nicht; die Nachricht bleibt auf "sending".
      //  - Es entsteht keine Sitzung, und nichts geht an den Relay.
      //  - Die Geraeteliste gilt NICHT als geprueft.
      //  - Jeder Nachversand (jedes Verbinden) holt das Buendel erneut — und
      //    zieht damit beim Relay jedes Mal einen EC-Einmalschluessel des
      //    alten Geraets.
      //  - Die Oberflaeche erfaehrt davon NICHTS. Die Ausnahme sagt "die
      //    Gegenstelle muss aktualisieren" (prekey_bundle_bridge.dart), aber
      //    kein Weg reicht das nach oben durch. Befund, siehe Schlussbericht
      //    vom 16.10.2026.
      final alt = await Fremder.mitGeraeten([1, 2]);
      final karte = alsAlteApp(alt.karte());
      lage.buendel = (wen) => karte;
      lage.liste = null;
      await kern.connect();

      // DIE VORAUSSETZUNG: dieses Buendel IST eines ohne Kyber.
      expect(
          () => PreKeyBundleBridge.fromRelay(RelayBundleResponse.fromJson(karte)),
          throwsA(isA<GegenstelleOhneKyberException>()
              .having((e) => e.adresse, 'adresse', alt.adresse)));

      kern.ablageFuerTest.speichereKontakt(Contact(
          id: alt.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      final m = await kern.sendMessage(alt.adresse, 'kommt nicht an');
      await warteBis(() => lage.buendelAbrufe > 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(lage.buendelAbrufe, greaterThan(0),
          reason: 'ohne Buendelabruf misst der Fall nicht die alte App');
      expect(lage.gesendet, isEmpty,
          reason: 'mit keinem Geraet gibt es eine Sitzung, also nichts zu '
              'verschluesseln');
      expect(sitzungen().where((s) => s.startsWith(alt.adresse)), isEmpty);
      expect(kern.ablageFuerTest.unversandt().map((u) => u.id), contains(m.id),
          reason: 'liegengeblieben, nicht verloren — sobald die Gegenstelle '
              'aktualisiert, geht sie beim naechsten Nachversand hinaus');
      expect(kern.ablageFuerTest.geraeteGeprueft(alt.adresse), 0);

      // UND BEIM NAECHSTEN VERBINDEN DASSELBE NOCH EINMAL.
      final abrufe = lage.buendelAbrufe;
      await kern.disconnect();
      await kern.connect();
      await warteBis(() => lage.buendelAbrufe > abrufe);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(lage.buendelAbrufe, greaterThan(abrufe),
          reason: 'IST-VERHALTEN: der Nachversand fragt bei jedem Verbinden '
              'erneut nach dem Buendel');
      expect(lage.gesendet, isEmpty);
      expect(kern.ablageFuerTest.unversandt().map((u) => u.id), contains(m.id));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ══════════════════════════════════════════════════════════════════ 4c
  group('Ein untergeschobener Schluessel (die Adresse IST der Schluessel)', () {
    test('EIN FREMDES BUENDEL UNTER BOBS ADRESSE GIBT KEINE SITZUNG — AUCH '
        'NICHT BEIM NAECHSTEN VERSUCH', () async {
      // DIE ZUSAGE, AUF DER BITDM STEHT (signal_store.dart
      // `isTrustedIdentity`): ein Relay, der unter Bobs Adresse einen
      // fremden Schluessel ausliefert, faellt beim ALLERERSTEN Kontakt auf,
      // ohne Sicherheitsnummernvergleich — die Adresse wird aus dem Schluessel
      // gebildet.
      //
      // BEFUND VOM 16.10.2026: die Anbindung der offiziellen libsignal ruft
      // `isTrustedIdentity` gar nicht. Sie prueft Vertrauen ueber
      // `getIdentity` (beim ersten Kontakt null, also "vertraut") und ruft
      // danach `saveIdentity` — und erst DAS wirft bei BitDM
      // (AddressKeyMismatchException). Ein Wurf im Rueckruf wird in Rust zur
      // PanicException, und die Sitzung mit Mallorys Schluesseln liegt da
      // schon im Speicher. Ohne Gegenmittel scheiterte nur der erste Versand;
      // der NACHVERSAND faende eine Sitzung zu "Bob" und verschluesselte an
      // Mallory (gegen libsignal direkt gemessen: Mallory liest den Text).
      //
      // BEHOBEN IM KERN: `PreKeyBundleBridge.fromRelay` prueft, dass der
      // Schluessel die Adresse im Buendel ergibt, `_bauSitzungen`, dass das
      // die angefragte Adresse ist (beides FremdeIdentitaet), und ein
      // Schnappschuss raeumt jeden halben Aufbau wieder ab. Dieser Fall
      // nagelt die WIRKUNG fest — ueber zwei Versuche: der erste misst den
      // Aufbau, der zweite das, was davon uebrig bleibt.
      final bob = await Fremder.mitGeraeten([1]);
      final mallory = await Fremder.mitGeraeten([1]);
      // DER RELAY LUEGT: unter Bobs Adresse liefert er Mallorys Buendel aus,
      // samt Mallorys Identitaetsschluessel.
      lage.buendel = (wen) => {...mallory.karte(), 'user_id': bob.adresse};
      lage.liste = null;
      await kern.connect();

      kern.ablageFuerTest.speichereKontakt(Contact(
          id: bob.adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));
      final m = await kern.sendMessage(bob.adresse, 'nur fuer Bob');
      await warteBis(() => lage.buendelAbrufe > 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(lage.buendelAbrufe, greaterThan(0),
          reason: 'ohne Buendelabruf misst der Fall nichts');
      expect(lage.gesendet.where((g) => g.an == bob.adresse), isEmpty,
          reason: 'der erste Versuch darf nichts hinausschicken');

      // DER NACHVERSAND beim naechsten Verbinden.
      await kern.disconnect();
      await kern.connect();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(lage.gesendet.where((g) => g.an == bob.adresse), isEmpty,
          reason: 'was hier hinausgeht, ist mit MALLORYS Schluesseln '
              'verschluesselt — der Relay liest Bobs Post mit');
      expect(kern.ablageFuerTest.unversandt().map((u) => u.id), contains(m.id),
          reason: 'die Nachricht bleibt liegen, bis ein echtes Buendel kommt');
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
