// kontaktzustand_test.dart — Steuernachrichten gegen den eigenen
// Kontaktzustand, am echten Kern gemessen.
//
// Die Kryptografie haelt gegen den Relay: die Adresse IST der Schluessel, und
// der Kern rechnet sie bei jedem Buendel nach. Die Luecken lagen eine Ebene
// hoeher, im Zustandsautomaten der Anwendung — Steuernachrichten wurden
// ausgefuehrt, ohne zu pruefen, in welchem Verhaeltnis man zum Absender
// ueberhaupt steht:
//
//   * „Absage“ (contactDecline) loeschte die ganze Unterhaltung, aus jedem
//     Zustand und von jedem Absender.
//   * „Zusage“ (contactAccept) machte jeden nicht aktiven Kontakt aktiv, also
//     auch einen Fremden, dessen Anfrage nie angenommen wurde.
//   * Der Nahbereich nahm alle Kontakte, auch unbeantwortete Anfragen.
//
// Aufbau wie in protokoll_befunde_test.dart: jeder Absender hat einen eigenen
// libsignal-Speicher und verschluesselt echt, nachgebaut ist nur der
// Transport. Nur so laesst sich ein Umschlag gezielt einwerfen, den ein
// ordentlicher Client nie schicken wuerde.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/absender.dart';
import '../support/funk_attrappe.dart';
import '../support/relay_attrappe.dart';

/// Ein Nahbereich, der nicht funkt, aber mitschreibt, fuer WEN er starten
/// soll. Genau das ist bei PR-3 die Frage.
class MitschreibenderNahbereich extends Nahbereich {
  MitschreibenderNahbereich(Nahfunk funk) : super(funk: funk);

  final starts = <List<String>>[];

  @override
  Future<void> starte({
    required List<NahKontakt> kontakte,
    required Uint8List eigenerOeffentlicher,
  }) async {
    starts.add(kontakte.map((k) => k.adresse).toList());
    // Nicht an die Oberklasse weitergeben: die wuerde Timer aufziehen und
    // Stroeme abonnieren. Geprueft wird hier die Auswahl, nicht das Funken.
  }
}

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;
  late ZaehlRelay relay;
  late MitschreibenderNahbereich nah;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 5)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return fertig();
  }

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-kontaktzustand');
    lage = Relaylage();
    nah = MitschreibenderNahbereich(FunkAttrappe());
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = ZaehlRelay(id, lage);
        lage.gebaut.add(r);
        return relay = r;
      },
      nahFactory: () => nah,
    );
    kern.quittungsVerzug = () => Duration.zero;
    await kern.initialize();
    woerter = await kern.createIdentity();
    await kern.connect();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  /// Das eigene Buendel des Kerns, frisch aus der Datei.
  Future<RelayBundleResponse> buendel() async {
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

  final buendelJe = <String, RelayBundleResponse>{};

  /// Schickt [p] von [a] an den Kern, wie der Relay es zustellen wuerde.
  Future<void> wirfEin(Absender a, Payload p, {int? q}) async {
    final b = buendelJe[a.adresse] ??= await buendel();
    relay.herein(RelayMessage(
        from: a.adresse,
        ciphertext: await a.an(kern.myId, b, p),
        at: DateTime.now().toUtc(),
        q: q));
  }

  void kontakt(Absender a, ContactState zustand) =>
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: a.adresse, addedAt: DateTime.now().toUtc(), state: zustand));

  DateTime jetzt() => DateTime.now().toUtc();

  /// Wartet, bis die Ablage [n] Kontakte kennt.
  Future<bool> warteBisKontakte(int n) async {
    final ende = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(ende)) {
      if ((await kern.getContacts()).length >= n) return true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  Payload absage() =>
      Payload.control(PayloadKind.contactDecline, 'ab-1', jetzt());
  Payload zusage() =>
      Payload.control(PayloadKind.contactAccept, 'zu-1', jetzt());

  // ══════════════════════════════════════════════════════════════════ PR-1
  group('PR-1: eine Absage loescht nur die eigene offene Anfrage', () {
    test('EIN AKTIVER KONTAKT LOESCHT MIT EINER ABSAGE NICHTS', () async {
      // Der Befund in einem Satz: entferneKontakt loescht in einer
      // Transaktion Nachrichten BEIDER Seiten, Anhaenge, Reaktionen, Stimmen,
      // den Ausgang, den Kontakt und seine Stimme bei der Fernloeschung. Ein
      // angenommener Kontakt konnte das jederzeit mit einer einzigen
      // Steuernachricht ausloesen — ohne Frist, ohne Zutun des Opfers, und
      // ausdruecklich auch fuer dessen EIGENE Nachrichten.
      final a = await Absender.neu();
      kontakt(a, ContactState.active);
      await wirfEin(a, Payload.text('von-ihm-1', 'belegt etwas', jetzt()),
          q: 61);
      expect(await warteBis(() => relay.bestaetigt.contains(61)), isTrue);
      await kern.sendMessage(a.adresse, 'und meine Antwort');
      expect(await kern.getMessages(a.adresse), hasLength(2));

      await wirfEin(a, absage(), q: 62);
      expect(await warteBis(() => relay.bestaetigt.contains(62)), isTrue,
          reason: 'verworfen heisst nicht: liegengelassen');

      expect(await kern.getMessages(a.adresse), hasLength(2),
          reason: 'der Verlauf beider Seiten muss stehen bleiben');
      final kontakte = await kern.getContacts();
      expect(kontakte.map((k) => k.id), contains(a.adresse),
          reason: 'und der Kontakt selbst auch');
      expect(kontakte.firstWhere((k) => k.id == a.adresse).state,
          ContactState.active);
    });

    test('EIN FREMDER MIT OFFENER ANFRAGE LOESCHT MIT EINER ABSAGE NICHTS',
        () async {
      // Sein eigener Zustand bei mir ist incomingPending. Eine Absage von ihm
      // ist bedeutungslos — ich habe ihn nie gefragt.
      final a = await Absender.neu();
      await wirfEin(
          a,
          Payload.control(PayloadKind.contactRequest, 'anfrage-1', jetzt()),
          q: 63);
      expect(await warteBis(() => relay.bestaetigt.contains(63)), isTrue);
      expect(await warteBisKontakte(1), isTrue);

      await wirfEin(a, absage(), q: 64);
      expect(await warteBis(() => relay.bestaetigt.contains(64)), isTrue);

      final kontakte = await kern.getContacts();
      expect(kontakte.map((k) => k.id), contains(a.adresse),
          reason: 'eine fremde Absage darf meine Anfrageliste nicht aufraeumen');
      expect(kontakte.firstWhere((k) => k.id == a.adresse).state,
          ContactState.incomingPending);
    });

    test('AUF MEINE EIGENE ANFRAGE WIRKT DIE ABSAGE', () async {
      // Die Gegenprobe: dafuer ist die Nachricht gedacht, und das muss
      // weiter gehen.
      final a = await Absender.neu();
      kontakt(a, ContactState.outgoingPending);

      final abgelehnt = kern.contactEvents
          .firstWhere((e) => e.type == ContactEventType.requestDeclined);
      await wirfEin(a, absage(), q: 65);
      expect(await warteBis(() => relay.bestaetigt.contains(65)), isTrue);
      await abgelehnt.timeout(const Duration(seconds: 5));

      expect((await kern.getContacts()).map((k) => k.id),
          isNot(contains(a.adresse)),
          reason: 'die eigene offene Anfrage ist damit erledigt');
    });
  });

  // ══════════════════════════════════════════════════════════════════ PR-2
  group('PR-2: eine Zusage macht nur aus der eigenen Anfrage einen Kontakt',
      () {
    test('EIN FREMDER MACHT SICH NICHT SELBST ZUM AKTIVEN KONTAKT', () async {
      // Der ganze Angriff: erst eine Anfrage, gleich danach eine Zusage. Die
      // Anfrage legt den Kontakt als incomingPending an, die Zusage hob ihn
      // auf active — und damit war die Einwilligung des Nutzers umgangen. Als
      // aktiver Kontakt bekommt er Lesebestaetigungen, erscheint als
      // gewoehnlicher Chat statt als Anfrage und kann das Opfer in beliebige
      // Gruppen stecken.
      final a = await Absender.neu();
      await wirfEin(
          a,
          Payload.control(PayloadKind.contactRequest, 'anfrage-2', jetzt()),
          q: 66);
      expect(await warteBis(() => relay.bestaetigt.contains(66)), isTrue);
      expect(await warteBisKontakte(1), isTrue);

      await wirfEin(a, zusage(), q: 67);
      expect(await warteBis(() => relay.bestaetigt.contains(67)), isTrue);

      final kontakte = await kern.getContacts();
      expect(kontakte.firstWhere((k) => k.id == a.adresse).state,
          ContactState.incomingPending,
          reason: 'der Uebergang incomingPending → active gehoert allein dem '
              'Nutzer');
    });

    test('AUF MEINE EIGENE ANFRAGE WIRKT DIE ZUSAGE', () async {
      final a = await Absender.neu();
      kontakt(a, ContactState.outgoingPending);

      final angenommen = kern.contactEvents
          .firstWhere((e) => e.type == ContactEventType.requestAccepted);
      await wirfEin(a, zusage(), q: 68);
      expect(await warteBis(() => relay.bestaetigt.contains(68)), isTrue);
      await angenommen.timeout(const Duration(seconds: 5));

      expect(
          (await kern.getContacts())
              .firstWhere((k) => k.id == a.adresse)
              .state,
          ContactState.active);
    });
  });

  // ══════════════════════════════════════════════════════════════════ PR-3
  group('PR-3: der Nahbereich laeuft nur fuer aktive Kontakte', () {
    test('EINE NACHRICHT EINES FREMDEN SCHALTET IHN NICHT AUF DIE '
        'LEUCHTFEUER', () async {
      // `zeigtAnwesenheit` steht bei einem neuen Kontakt auf true, und ein
      // Eingang von einem Unbekannten legt einen Kontakt incomingPending an.
      // Damit genuegte eine einzige Nachricht, und das Geraet sendete ein
      // Leuchtfeuer, das der Absender selbst ausrechnen kann — er erkennt das
      // Opfer danach in Funkreichweite wieder, ohne dass die Anfrage je
      // angenommen wurde.
      final fremd = await Absender.neu();
      final freund = await Absender.neu();
      kontakt(freund, ContactState.active);
      await kern.setPreferences(
          (await kern.getPreferences()).copyWith(naheAn: true));
      expect(await warteBis(() => nah.starts.isNotEmpty), isTrue,
          reason: 'mit einem aktiven Kontakt laeuft der Nahbereich');
      expect(nah.starts.last, [freund.adresse]);

      await wirfEin(fremd, Payload.text('fremd-1', 'hallo', jetzt()), q: 69);
      expect(await warteBis(() => relay.bestaetigt.contains(69)), isTrue);
      expect(await warteBisKontakte(2), isTrue,
          reason: 'der Eingang legt den Fremden als Anfrage ab');
      await kern.nahRuhtFuerTest;

      for (final start in nah.starts) {
        expect(start, isNot(contains(fremd.adresse)),
            reason: 'ein Fremder mit offener Anfrage gehoert nicht in den '
                'Nahbereich');
      }
    });

    test('NACH DER ANNAHME IST ER DABEI', () async {
      // Die Gegenprobe: die Einwilligung des Nutzers schaltet ihn frei.
      final a = await Absender.neu();
      await kern.setPreferences(
          (await kern.getPreferences()).copyWith(naheAn: true));
      await wirfEin(
          a,
          Payload.control(PayloadKind.contactRequest, 'anfrage-3', jetzt()),
          q: 70);
      expect(await warteBis(() => relay.bestaetigt.contains(70)), isTrue);
      expect(await warteBisKontakte(1), isTrue);

      await kern.acceptRequest(a.adresse);
      await kern.nahRuhtFuerTest;

      expect(await warteBis(() => nah.starts.isNotEmpty), isTrue);
      expect(nah.starts.last, [a.adresse]);
    });
  });
}
