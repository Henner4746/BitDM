// protokoll_befunde_test.dart — die Befunde vom 25.09.2026 an Ablage,
// Modellen und Lesern, ohne Netz.
//
// Was einen echten Umschlag braucht, steht in test/net/protokoll_befunde_test.
// Hier: die Regeln, die in ChatRepository, Gruppe, Fernloeschung, Payload und
// Rezept selbst sitzen — dort, wo sie jeder Aufrufer bekommt.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/rezept.dart';
import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/core/store/chat_repository.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

const ich = 'ich';
const du = 'du';

Message eigene(String id, {MessageKind art = MessageKind.text}) => Message(
      id: id,
      chatId: du,
      senderId: ich,
      text: 'x',
      kind: art,
      isMine: true,
      timestamp: DateTime.now().toUtc(),
      status: MessageStatus.sending,
    );

Uint8List handNutzlast(int art, Map<String, Object?> json) {
  final inhalt = [art, ...utf8.encode(jsonEncode(json)), 0x80];
  final fehlend = (256 - inhalt.length % 256) % 256;
  return Uint8List.fromList([...inhalt, ...List.filled(fehlend, 0)]);
}

void main() {
  late Directory ordner;
  late String pfad;
  late Uint8List dbSchluessel;
  late EncryptedDatabase db;
  late ChatRepository chats;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-befunde-ablage');
    pfad = '${ordner.path}${Platform.pathSeparator}t.db';
    dbSchluessel =
        (await KeyDerivation.fromMnemonic(Bip39.generate())).databaseKey;
    db = EncryptedDatabase.open(pfad, dbSchluessel);
    chats = ChatRepository(db, SignalStoreRepository(db));
    chats.speichereKontakt(Contact(id: du, addedAt: DateTime.utc(2026, 9, 1)));
  });

  tearDown(() async {
    try {
      db.close();
    } catch (_) {}
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  // ═══════════════════════════════════════════════════════════════════ C13
  test('C13: VERSCHWINDENDE NACHRICHTEN GEHEN NICHT IN DIE SICHERUNG', () {
    chats.speichereEigene(eigene('bleibt'));
    chats.speichereEigene(eigene('geht'), lebensdauer: const Duration(hours: 1));
    chats.speichereEigene(eigene('anhang-geht', art: MessageKind.anhang),
        lebensdauer: const Duration(hours: 1),
        anhang: const AnhangEintrag(
            messageId: 'anhang-geht',
            chatId: du,
            senderId: ich,
            name: 'a.bin',
            groesse: 1,
            zustand: AnhangZustand.da,
            pfad: '/x'),
        rezept: '{"v":1}');
    chats.setzeReaktion(du, 'geht', du, ':)', DateTime.now().toUtc());

    final inhalt = chats.sicherungsInhalt();
    final ids = [for (final m in inhalt['nachrichten']! as List) (m as Map)['id']];
    expect(ids, ['bleibt'],
        reason: 'bis 25.09.2026 lebten sie in der Sicherungsdatei weiter');
    expect(inhalt['anhaenge'], isEmpty);
    expect(inhalt['reaktionen'], isEmpty);
    expect(chats.anhaengeFuerSicherung(1 << 30), isEmpty);
  });

  // ═══════════════════════════════════════════════════════════════════ M2
  test('M2: EINE ANGESEHENE EINMAL-ANSICHT VERLIERT IHRE ANLEITUNG', () {
    chats.speichereEigene(
        Message(
            id: 'e-1',
            chatId: du,
            senderId: du,
            text: 'foto.jpg',
            kind: MessageKind.anhang,
            isMine: false,
            timestamp: DateTime.now().toUtc()),
        anhang: const AnhangEintrag(
            messageId: 'e-1',
            chatId: du,
            senderId: du,
            name: 'foto.jpg',
            groesse: 1,
            zustand: AnhangZustand.da,
            pfad: '/tmp/foto.jpg',
            einmal: true),
        rezept: '{"v":1,"geheim":"schluessel"}');
    expect(chats.verbraucheAnhang(du, 'e-1'), '/tmp/foto.jpg');
    expect(chats.rezeptText(du, du, 'e-1'), isEmpty,
        reason: 'mit der Anleitung liess sich die Datei erneut holen');
    expect(chats.anhang(du, du, 'e-1')!.zustand, AnhangZustand.verbraucht);
  });

  // ═══════════════════════════════════════════════════════════════════ C4
  test('C4: ENTFERNEN NIMMT DAS LOESCHRECHT MIT — in derselben Transaktion',
      () {
    chats.speichereFernloeschung(Fernloeschung(
        an: true,
        schwelle: 2,
        vertraute: const [du, 'andere'],
        anfragen: {du: DateTime.now().millisecondsSinceEpoch}));
    chats.entferneKontakt(du);
    final f = chats.fernloeschung();
    expect(f.vertraute, ['andere']);
    expect(f.anfragen, isEmpty);
    expect(f.an, isTrue, reason: 'der Rest der Einstellung bleibt');
  });

  // ═══════════════════════════════════════════════════════════════════ C5
  group('C5: das Fenster zaehlt ab dem Absender', () {
    final jetzt = DateTime.utc(2026, 9, 25, 12);
    const f = Fernloeschung(an: true, schwelle: 2, vertraute: ['bob', 'carl']);

    test('eine drei Tage alte Anfrage zaehlt nicht', () {
      final n = f.nimmAnfrage('bob', jetzt,
          gesendet: jetzt.subtract(const Duration(days: 3)));
      expect(n.anfragen, isEmpty);
    });

    test('zwei Anfragen, die 30 Stunden auseinanderliegen, loesen nicht aus',
        () {
      // Die erste kam spaet an (lag beim Relay), die zweite frisch.
      final n = f
          .nimmAnfrage('bob', jetzt,
              gesendet: jetzt.subtract(const Duration(hours: 23)))
          .nimmAnfrage('carl', jetzt.add(const Duration(hours: 7)),
              gesendet: jetzt.add(const Duration(hours: 7)));
      expect(n.faellig, isNull,
          reason: 'bob bat vor 30 Stunden — das Fenster ist 24');
    });

    test('eine vorausdatierte Anfrage zaehlt nicht', () {
      final n = f.nimmAnfrage('bob', jetzt,
          gesendet: jetzt.add(const Duration(hours: 1)));
      expect(n.anfragen, isEmpty);
    });

    test('leichtes Vorgehen der Uhr wird auf jetzt gekappt', () {
      final n = f.nimmAnfrage('bob', jetzt,
          gesendet: jetzt.add(const Duration(minutes: 3)));
      expect(n.anfragen['bob'], jetzt.millisecondsSinceEpoch);
    });
  });

  // ═══════════════════════════════════════════════════════════════════ L5
  test('L5: DIE FRIST BEIM VERFASSEN STEHT AN DER NACHRICHT', () {
    chats.speichereEigene(eigene('mit'), lebensdauer: const Duration(minutes: 5));
    chats.speichereEigene(eigene('ohne'));
    final u = {for (final m in chats.unversandt()) m.id: m};
    expect(u['mit']!.fristSekunden, 300);
    expect(u['ohne']!.fristSekunden, 0);
  });

  // ═══════════════════════════════════════════════════════════════════ M5
  test('M5: NUR UEBER DIE NAEHE GEGANGEN = VORLAEUFIG, bis zur Quittung', () {
    chats.speichereEigene(eigene('funk'));
    chats.setzeStatus(du, ich, 'funk', MessageStatus.sent, ueberNaehe: true);
    chats.speichereEigene(eigene('relay'));
    chats.setzeStatus(du, ich, 'relay', MessageStatus.sent, ueberNaehe: false);

    expect(chats.unversandt(), isEmpty);
    expect(chats.unversandt(mitVorlaeufigen: true).map((m) => m.id), ['funk']);

    chats.setzeStatus(du, ich, 'funk', MessageStatus.delivered);
    expect(chats.unversandt(mitVorlaeufigen: true), isEmpty,
        reason: 'mit der Quittung ist sie nicht mehr vorlaeufig');
  });

  // ═══════════════════════════════════════════════════════════════════ M1
  test('M1: EINE KENNUNG GEHOERT IM CHAT GENAU EINEM ABSENDER', () {
    chats.speichereEigene(eigene('k-1'));
    expect(chats.kennungFremdBelegt(du, 'k-1', du), isTrue);
    expect(chats.kennungFremdBelegt(du, 'k-1', ich), isFalse);
    expect(chats.kennungFremdBelegt(du, 'k-2', du), isFalse);
  });

  // ═══════════════════════════════════════════════════════ Gruppe.lies (L4)
  group('Gruppe.lies', () {
    const gid = 'g-DDDDDDDDDDDDDDDDDDDDDD';
    final a = BitdmAddress.encode(Uint8List(32));
    final b = BitdmAddress.encode(Uint8List(32)..[0] = 1);

    String stand({required String admin, required List<String> m, int v = 1}) =>
        jsonEncode({'n': 'G', 'a': admin, 'm': m, 'v': v});

    Gruppe? lies(String text) =>
        Gruppe.lies(gid, text, adresseTaugt: BitdmAddress.isValid);

    test('die Normalform geht durch', () {
      expect(lies(stand(admin: a, m: [a, b])), isNotNull);
    });

    test('L4: GROSSSCHREIBUNG ODER BINDESTRICHE WERDEN ABGEWIESEN', () {
      expect(lies(stand(admin: a, m: [a, b.toUpperCase()])), isNull,
          reason: 'dieselbe Person unter zwei Schreibweisen in der Liste');
      expect(lies(stand(admin: a, m: [a, BitdmAddress.format(b)])), isNull);
      expect(lies(stand(admin: a.toUpperCase(), m: [a.toUpperCase(), b])),
          isNull);
    });

    test('M3: EINE FASSUNG JENSEITS VON 2^31 WIRD ABGEWIESEN', () {
      expect(lies(stand(admin: a, m: [a, b], v: Gruppe.maxVersion)), isNotNull);
      expect(lies(stand(admin: a, m: [a, b], v: Gruppe.maxVersion + 1)), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════ L1
  group('L1: jeder Lesefehler ist ein Formatfehler', () {
    test('Payload: "r" ohne Liste', () {
      expect(
          () => Payload.fromBytes(handNutzlast(PayloadKind.reaktion.code,
              {'id': 'a', 't': 1, 'x': ':)', 'r': 5})),
          throwsA(isA<PayloadFormatException>()));
    });

    test('Payload: Zeitstempel ausserhalb von DateTime', () {
      expect(
          () => Payload.fromBytes(handNutzlast(
              PayloadKind.text.code, {'id': 'a', 't': 9e15.toInt(), 'x': 'x'})),
          throwsA(isA<PayloadFormatException>()));
    });

    test('Rezept: ein Stueck, das kein Objekt ist', () {
      expect(
          () => Rezept.ausText(
              '{"v":1,"n":"x","g":1,"p":"${base64.encode(Uint8List(32))}","st":[1]}'),
          throwsA(isA<RezeptFormatException>()));
      expect(() => Rezept.ausText('{"v":1,"st":[{"k":5}],"g":1}'),
          throwsA(isA<RezeptFormatException>()));
    });
  });

  // ══════════════════════════════════════════════════════════ Schema 14
  test('SCHEMA 14: eine Datenbank auf Stand 13 bekommt beide Spalten', () {
    db.raw.execute('ALTER TABLE messages DROP COLUMN frist');
    db.raw.execute('ALTER TABLE gruppen DROP COLUMN verlassen');
    db.raw.execute("UPDATE meta SET value = '13' WHERE key = 'schema_version'");
    db.close();

    db = EncryptedDatabase.open(pfad, dbSchluessel);
    chats = ChatRepository(db, SignalStoreRepository(db));
    expect(db.meta('schema_version'), '${EncryptedDatabase.schemaVersion}');
    bool hat(String t, String s) =>
        db.raw.select('PRAGMA table_info($t)').any((r) => r['name'] == s);
    expect(hat('messages', 'frist'), isTrue);
    expect(hat('gruppen', 'verlassen'), isTrue);
    chats.speichereGruppe(const Gruppe(
        id: 'g-EEEEEEEEEEEEEEEEEEEEEE',
        name: 'G',
        admin: 'x',
        mitglieder: ['x', 'y'],
        verlassen: true));
    expect(chats.gruppe('g-EEEEEEEEEEEEEEEEEEEEEE')!.verlassen, isTrue);
  });

  // ═══════════════════════════════════════════════════ M2 am echten Kern
  test('M2: EINE ANGESEHENE EINMAL-ANSICHT WIRD NICHT NOCH EINMAL GEHOLT',
      () async {
    final kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}k.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
    );
    addTearDown(kern.dispose);
    await kern.initialize();
    await kern.createIdentity();
    final gegen = BitdmAddress.encode(Uint8List(32)..[5] = 9);
    kern.ablageFuerTest
        .speichereKontakt(Contact(id: gegen, addedAt: DateTime.now().toUtc()));
    kern.ablageFuerTest.speichereEigene(
        Message(
            id: 'e-2',
            chatId: gegen,
            senderId: gegen,
            text: 'foto.jpg',
            kind: MessageKind.anhang,
            isMine: false,
            timestamp: DateTime.now().toUtc()),
        anhang: AnhangEintrag(
            messageId: 'e-2',
            chatId: gegen,
            senderId: gegen,
            name: 'foto.jpg',
            groesse: 1,
            zustand: AnhangZustand.angekuendigt,
            einmal: true),
        rezept: '{"v":1}');
    await kern.verbraucheEinmal(gegen, 'e-2');
    await expectLater(kern.holeAnhang(gegen, 'e-2'), throwsStateError,
        reason: 'bis 25.09.2026 holte der naechste Aufruf die Datei neu');
  });
}
