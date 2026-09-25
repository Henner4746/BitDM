// nachtfunde_test.dart — drei Fehler, die erst die zweite Widerlegung fand.
//
// Sie standen als Wegwerf-Proben eines Agenten im Baum, der am Sitzungslimit
// starb. Alle drei waren echt und sind behoben; die Proben bleiben als Tests
// stehen, weil ein behobener Fehler ohne Test nur ein vertagter ist.
//
//   A  Nach `lock()` funkte das Telefon WEITER. `lock()` haelt den Nahbereich
//      direkt an — an der Warteschlange vorbei, absichtlich, es soll ja nicht
//      hinter einem laufenden Aufbau warten. Genau deshalb konnte das Anhalten
//      mitten in `nah.starte(...)` fallen, und der Aufbau schaltete danach
//      alles wieder ein. Ein gesperrtes Geraet, das seine Anwesenheit weiter
//      in die Gegend ruft.
//
//   B  Nach `declineRequest` lief das Leuchtfeuer fuer den Abgewiesenen
//      weiter. Von allen Kontakten ist das der, bei dem es am wenigsten
//      hingehoert.
//
//   C  Regel 2 galt nur in EINE Richtung. Was beim Relay war, durfte nicht
//      mehr ueber die Naehe — was in der Naehe war, durfte sehr wohl noch
//      ueber den Relay. Dieselbe doppelte Zustellung, gespiegelt.
//
//      SEIT 25.09.2026 UMGEKEHRT (Befund H1): die Sperre war der teurere
//      Irrtum. Eine Nachricht nach einem mehrdeutigen Funkversuch blieb fuer
//      immer liegen; eine doppelte Zustellung dagegen verwirft der Empfaenger
//      am eindeutigen Index. C prueft jetzt, dass sie ueber den Relay
//      nachgereicht wird — D und E die beiden Nachbarfaelle.

import 'dart:async';
import 'dart:io';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/funk_attrappe.dart';
import 'nahweg_test.dart' show Gegenstelle, SteuerbarerRelay, SpeicherImKopf;

void main() {
  late Directory ordner;
  late FunkAttrappe funk;
  late Nahbereich nah;
  late RealMessengerCore kern;
  late Gegenstelle anna;
  late Map<String, Gegenstelle> gegenstellen;
  SteuerbarerRelay? relay;
  var jetzt = DateTime.utc(2026, 7, 27, 12, 0);

  Future<void> warteBis(bool Function() fertig) async {
    for (var i = 0; i < 400 && !fertig(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    jetzt = DateTime.utc(2026, 7, 27, 12, 0);
    ordner = await Directory.systemTemp.createTemp('bitdm-probe');
    funk = FunkAttrappe();
    nah = Nahbereich(funk: funk, uhr: () => jetzt);
    anna = await Gegenstelle.neu();
    gegenstellen = {anna.adresse: anna};
    relay = null;
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) => relay =
          SteuerbarerRelay(id, (wen) => (gegenstellen[wen] ?? anna).antwort),
      nahFactory: () => nah,
    );
    await kern.initialize();
    await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    await funk.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  void legeAnnaAn() => kern.ablageFuerTest
      .speichereKontakt(Contact(id: anna.adresse, addedAt: DateTime.now().toUtc()));

  Future<void> funkAn({bool nurNahbereich = false}) async {
    await kern.setPreferences(
        AppPreferences(naheAn: true, nurNahbereich: nurNahbereich));
    await kern.nahRuhtFuerTest;
  }

  Future<void> annaInReichweite() async {
    funk.sieh(Gesehen(
      geraet: 'AA:11',
      rssi: -40,
      leuchtfeuer: [
        await anna.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt)
      ],
    ));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> sitzungAufbauen() async {
    await kern.connect();
    await kern.sendMessage(anna.adresse, 'der Sitzungsaufbau');
    await warteBis(() => relay!.gesendet.isNotEmpty);
    relay!.gesendet.clear();
  }

  test('A: lock() gegen einen laufenden _richteNaheEin', () async {
    legeAnnaAn();
    await funkAn();
    expect(funk.suchtGerade, isTrue);

    final bert = await Gegenstelle.neu();
    // Der Weg des Betriebs: addContact stoesst _richteNaheEin an, OHNE zu
    // warten. Genau in diesem Fenster sperrt der Nutzer die App.
    unawaited(kern.addContact(bert.adresse));
    await kern.lock();
    await kern.nahRuhtFuerTest;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(funk.suchtGerade, isFalse,
        reason: 'nach dem Sperren darf kein Leuchtfeuer mehr laufen');
    expect(funk.postfachOffen, isFalse);
  });

  test('B: declineRequest laesst das Leuchtfeuer weiterlaufen', () async {
    kern.ablageFuerTest.speichereKontakt(Contact(
        id: anna.adresse,
        addedAt: DateTime.now().toUtc(),
        state: ContactState.incomingPending));
    await funkAn();
    expect(funk.werbungen.last, hasLength(1));

    await kern.declineRequest(anna.adresse);
    await kern.nahRuhtFuerTest;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await kern.getContacts(), isEmpty, reason: 'sie ist weg');
    await annaInReichweite();
    expect(nah.inReichweite, isEmpty,
        reason: 'eine abgesagte Kontaktanfrage darf nicht weiter erkannt '
            'werden — und fuer sie wird auch noch geleuchtet');
  });

  test('C: nach einem MEHRDEUTIGEN Funkversuch reicht der Relay nach', () async {
    legeAnnaAn();
    await funkAn();
    await sitzungAufbauen();
    await annaInReichweite();

    // Der Relay ist weg, die Naehe traegt — und scheitert. Genau wie beim
    // Relay heisst das NICHT, dass nichts drueben liegt.
    relay!.verbunden = false;
    funk.sendeFehler = const FunkFehler('FUNK', 'Ack blieb aus');
    await kern.sendMessage(anna.adresse, 'koennte schon drueben liegen');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final vorher = (await kern.getMessages(anna.adresse)).last;
    expect(vorher.status, MessageStatus.sending);
    expect(vorher.schonInDerNaehe, isTrue, reason: 'der Vermerk steht');

    // Der Relay kommt zurueck; Anna geht und kommt wieder, das stoesst den
    // Nachversand an.
    relay!.verbunden = true;
    jetzt = jetzt.add(const Duration(seconds: 91));
    await annaInReichweite();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(relay!.gesendet, hasLength(1),
        reason: 'bis 25.09.2026 blieb sie hier fuer immer liegen — Anna '
            'entdoppelt eine zweite Kopie selbst');
    expect((await kern.getMessages(anna.adresse)).last.status,
        MessageStatus.sent);
  });

  test('D: WAS SICHER NICHT HINAUSGING, bekommt keinen Vermerk', () async {
    legeAnnaAn();
    await funkAn();
    await sitzungAufbauen();
    await annaInReichweite();

    // "Nicht in Reichweite" scheitert, bevor ein Byte in der Luft ist.
    relay!.verbunden = false;
    funk.sendeFehler = const FunkFehler('BESETZT', 'an AA:11 laeuft schon etwas');
    await kern.sendMessage(anna.adresse, 'ging nie hinaus');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final m = (await kern.getMessages(anna.adresse)).last;
    expect(m.status, MessageStatus.sending);
    expect(m.schonInDerNaehe, isFalse,
        reason: 'ein Versuch ohne ein einziges gesendetes Byte ist nicht '
            'mehrdeutig');
  });

  test('D2: EIN NACHBAR IN REICHWEITE MACHT DIE NAEHE NICHT "BEREIT" FUER ANNA',
      () async {
    legeAnnaAn();
    final bert = await Gegenstelle.neu();
    gegenstellen[bert.adresse] = bert;
    kern.ablageFuerTest.speichereKontakt(
        Contact(id: bert.adresse, addedAt: DateTime.now().toUtc()));
    await funkAn();
    await sitzungAufbauen();
    // NUR BERT ist da.
    funk.sieh(Gesehen(geraet: 'BB:22', rssi: -40, leuchtfeuer: [
      await bert.leuchtfeuerFuer(BitdmAddress.decode(kern.myId), jetzt)
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(nah.inReichweite, [bert.adresse]);

    relay!.verbunden = false;
    await kern.sendMessage(anna.adresse, 'an Anna, nicht an Bert');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(funk.gesendet, isEmpty,
        reason: 'bis 25.09.2026 genuegte irgendwer in Reichweite');
    expect((await kern.getMessages(anna.adresse)).last.schonInDerNaehe, isFalse);
  });

  test('E: NUR UEBER DIE NAEHE IST VORLAEUFIG — der Relay reicht nach', () async {
    // Ein Leuchtfeuer ist oeffentlich. Wer es aufzeichnet und wieder
    // aussendet, sieht aus wie Anna in Reichweite und verschluckt, was wir
    // ihm geben. Bis 25.09.2026 stand die Nachricht danach fuer immer auf
    // "gesendet".
    legeAnnaAn();
    await funkAn();
    await sitzungAufbauen();
    await annaInReichweite();

    relay!.verbunden = false;
    await kern.sendMessage(anna.adresse, 'ueber Bluetooth');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(funk.gesendet, hasLength(1));
    var m = (await kern.getMessages(anna.adresse)).last;
    expect(m.status, MessageStatus.sent);
    expect(m.ueberNaehe, isTrue);

    // Der Relay ist wieder da, der Nachversand laeuft.
    relay!.verbunden = true;
    jetzt = jetzt.add(const Duration(seconds: 91));
    await annaInReichweite();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(relay!.gesendet, hasLength(1),
        reason: 'ohne Quittung geht sie zusaetzlich ueber den Relay');
    m = (await kern.getMessages(anna.adresse)).last;
    expect(m.status, MessageStatus.sent);
    expect(m.ueberNaehe, isFalse,
        reason: 'jetzt war ein Server beteiligt — das Zeichen faellt');

    // Und danach ist Ruhe: kein weiterer Nachtrag.
    relay!.gesendet.clear();
    jetzt = jetzt.add(const Duration(seconds: 91));
    await annaInReichweite();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(relay!.gesendet, isEmpty);
  });
}
