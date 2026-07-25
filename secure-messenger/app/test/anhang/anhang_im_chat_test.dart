// anhang_im_chat_test.dart — der Anhang im Verlauf.
//
// Bis zum 25.07.2026 war der Transport gebaut und der Chat wusste nichts
// davon: ein empfangener Anhang landete NIRGENDS. Diese Datei haelt fest, was
// beim Anschliessen wirklich zaehlt — und das ist fast alles Buchhaltung, die
// nur auffaellt, wenn sie fehlt:
//
//   * Anleitung und Nachricht in EINER Transaktion. Auseinander ist entweder
//     die Nachricht da und der Anhang unauffindbar, oder eine Anleitung ohne
//     Nachricht, die niemand je sieht.
//   * Eine DOPPELT zugestellte Nachricht darf einen schon geholten Anhang
//     nicht auf "angekuendigt" zuruecksetzen.
//   * Verfallene Nachrichten und entfernte Kontakte muessen die DATEIEN
//     mitnehmen — sonst ist die Verfallsfrist eine Halbwahrheit.
//   * Ein "laedt", das einen App-Neustart ueberlebt, ist ein Fortschritt,
//     hinter dem nichts mehr laeuft.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/chat_repository.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const einChat = 'aaaa';
const ichSelbst = 'meineadresse';

Message nachricht(String id,
        {String chatId = einChat,
        String senderId = einChat,
        bool isMine = false,
        MessageKind kind = MessageKind.anhang,
        String text = 'urlaub.zip'}) =>
    Message(
      id: id,
      chatId: chatId,
      senderId: senderId,
      text: text,
      kind: kind,
      isMine: isMine,
      timestamp: DateTime.utc(2026, 7, 25),
      status: MessageStatus.delivered,
    );

AnhangEintrag eintrag(String id,
        {String chatId = einChat,
        String senderId = einChat,
        AnhangZustand zustand = AnhangZustand.angekuendigt,
        String? pfad,
        int groesse = 12345}) =>
    AnhangEintrag(
      messageId: id,
      chatId: chatId,
      senderId: senderId,
      name: 'urlaub.zip',
      groesse: groesse,
      zustand: zustand,
      pfad: pfad,
    );

void main() {
  late Directory ordner;
  late EncryptedDatabase db;
  late ChatRepository chats;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-chat');
    final abgeleitet = await KeyDerivation.fromMnemonic(Bip39.generate());
    db = EncryptedDatabase.open(
        '${ordner.path}${Platform.pathSeparator}t.db', abgeleitet.databaseKey);
    chats = ChatRepository(db, SignalStoreRepository(db));
    chats.speichereKontakt(
        Contact(id: einChat, addedAt: DateTime.utc(2026, 7, 1)));
  });

  tearDown(() async {
    db.close();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  group('Die Anleitung liegt bei der Nachricht', () {
    test('gespeichert und wiedergefunden', () {
      chats.speichereEigene(nachricht('m1', isMine: true, senderId: ichSelbst),
          anhang: eintrag('m1',
              senderId: ichSelbst, zustand: AnhangZustand.da, pfad: '/x/y.zip'),
          rezept: '{"v":1}');

      final a = chats.anhang(einChat, ichSelbst, 'm1')!;
      expect(a.name, 'urlaub.zip');
      expect(a.groesse, 12345);
      expect(a.zustand, AnhangZustand.da);
      expect(a.pfad, '/x/y.zip');
      expect(chats.rezeptText(einChat, ichSelbst, 'm1'), '{"v":1}');
    });

    test('DIE ANLEITUNG STEHT NICHT IM VERLAUF', () {
      // Sie ist bei einer grossen Datei rund 23 KB und wird beim Anzeigen nie
      // gebraucht. Im Verlauf steht der Name.
      chats.speichereEigene(nachricht('m1', isMine: true, senderId: ichSelbst),
          anhang: eintrag('m1', senderId: ichSelbst), rezept: '{"v":1}');

      expect(chats.verlauf(einChat).single.text, 'urlaub.zip');
      expect(chats.verlauf(einChat).single.kind, MessageKind.anhang);
    });

    test('alle Anhaenge einer Unterhaltung in EINER Abfrage', () {
      for (var i = 0; i < 3; i++) {
        chats.speichereEigene(
            nachricht('m$i', isMine: true, senderId: ichSelbst),
            anhang: eintrag('m$i', senderId: ichSelbst),
            rezept: '{"v":1}');
      }
      expect(chats.anhaenge(einChat), hasLength(3));
      expect(chats.anhaenge(einChat).keys, containsAll(['m0', 'm1', 'm2']));
    });

    test('eine Nachricht ohne Anhang legt auch keinen an', () {
      chats.speichereEigene(nachricht('m1',
          isMine: true, senderId: ichSelbst, kind: MessageKind.text));
      expect(chats.anhaenge(einChat), isEmpty);
    });
  });

  group('Zustaende', () {
    setUp(() {
      chats.speichereEigene(nachricht('m1', isMine: true, senderId: ichSelbst),
          anhang: eintrag('m1', senderId: ichSelbst), rezept: '{"v":1}');
    });

    test('vom Ankuendigen bis zum Dasein', () {
      chats.setzeAnhangZustand(
          einChat, ichSelbst, 'm1', AnhangZustand.laedt);
      expect(chats.anhang(einChat, ichSelbst, 'm1')!.zustand,
          AnhangZustand.laedt);

      chats.setzeAnhangZustand(einChat, ichSelbst, 'm1', AnhangZustand.da,
          pfad: '/heruntergeladen/urlaub.zip');
      final a = chats.anhang(einChat, ichSelbst, 'm1')!;
      expect(a.zustand, AnhangZustand.da);
      expect(a.pfad, '/heruntergeladen/urlaub.zip');
    });

    test('der Pfad bleibt, wenn kein neuer kommt', () {
      chats.setzeAnhangZustand(einChat, ichSelbst, 'm1', AnhangZustand.da,
          pfad: '/da/x.zip');
      chats.setzeAnhangZustand(
          einChat, ichSelbst, 'm1', AnhangZustand.gescheitert);
      expect(chats.anhang(einChat, ichSelbst, 'm1')!.pfad, '/da/x.zip');
    });

    test('EIN HAENGENDES "LAEDT" UEBERLEBT DEN NEUSTART NICHT', () {
      // Wird die App waehrend eines Downloads weggewischt, bliebe der Zustand
      // sonst fuer immer auf "laedt" — und die Oberflaeche zeigte einen
      // Fortschritt, hinter dem nichts mehr laeuft.
      chats.setzeAnhangZustand(einChat, ichSelbst, 'm1', AnhangZustand.laedt);

      expect(chats.raeumeHaengendeAnhaengeAuf(), 1);
      expect(chats.anhang(einChat, ichSelbst, 'm1')!.zustand,
          AnhangZustand.gescheitert);
    });

    test('und laesst alles andere in Ruhe', () {
      chats.setzeAnhangZustand(einChat, ichSelbst, 'm1', AnhangZustand.da,
          pfad: '/da/x.zip');
      expect(chats.raeumeHaengendeAnhaengeAuf(), 0);
      expect(chats.anhang(einChat, ichSelbst, 'm1')!.zustand,
          AnhangZustand.da);
    });
  });

  group('DOPPELT ZUGESTELLT', () {
    test('setzt einen schon geholten Anhang NICHT zurueck', () async {
      // Der Fall, den man beim Bauen uebersieht: der Relay stellt eine
      // Nachricht ein zweites Mal zu. Ohne diese Vorsicht faellt der Zustand
      // auf "angekuendigt" zurueck, die Datei liegt da, und die Oberflaeche
      // bietet an, drei Gigabyte noch einmal zu holen.
      final store = SignalStoreRepository(db)
          .openStore(await KeyDerivation.fromMnemonic(Bip39.generate()));

      chats.speichereEmpfangen(nachricht('m1'), store,
          anhang: eintrag('m1'), rezept: '{"v":1}');
      chats.setzeAnhangZustand(einChat, einChat, 'm1', AnhangZustand.da,
          pfad: '/da/x.zip');

      final nochmal = chats.speichereEmpfangen(nachricht('m1'), store,
          anhang: eintrag('m1'), rezept: '{"v":1}');

      expect(nochmal, isFalse, reason: 'die Nachricht war schon da');
      final a = chats.anhang(einChat, einChat, 'm1')!;
      expect(a.zustand, AnhangZustand.da);
      expect(a.pfad, '/da/x.zip');
    });
  });

  group('WAS VERSCHWINDET, MUSS AUCH AUF DER PLATTE VERSCHWINDEN', () {
    test('eine verfallene Nachricht gibt ihre Datei heraus', () async {
      // Ohne das waere die Verfallsfrist eine Halbwahrheit: die Nachricht
      // waere aus der Unterhaltung weg, und die zwei Gigabyte laegen weiter
      // im Speicher des Telefons.
      final datei =
          File('${ordner.path}${Platform.pathSeparator}anhang.bin');
      await datei.writeAsBytes(Uint8List(10));

      chats.speichereEigene(nachricht('m1', isMine: true, senderId: ichSelbst),
          lebensdauer: const Duration(milliseconds: 1),
          anhang: eintrag('m1',
              senderId: ichSelbst,
              zustand: AnhangZustand.da,
              pfad: datei.path),
          rezept: '{"v":1}');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      final weg = chats.loescheAbgelaufene();

      expect(weg.nachrichten, 1);
      expect(weg.dateien, [datei.path],
          reason: 'der Aufrufer muss wissen, was er von der Platte raeumen '
              'soll — diese Schicht fasst nur die Datenbank an');
      expect(chats.anhaenge(einChat), isEmpty);
    });

    test('ein entfernter Kontakt gibt seine Dateien heraus', () {
      chats.speichereEigene(nachricht('m1', isMine: true, senderId: ichSelbst),
          anhang: eintrag('m1',
              senderId: ichSelbst,
              zustand: AnhangZustand.da,
              pfad: '/da/eins.zip'),
          rezept: '{"v":1}');
      chats.speichereEigene(nachricht('m2', isMine: true, senderId: ichSelbst),
          anhang: eintrag('m2',
              senderId: ichSelbst,
              zustand: AnhangZustand.da,
              pfad: '/da/zwei.zip'),
          rezept: '{"v":1}');

      final weg = chats.entferneKontakt(einChat);

      expect(weg.dateien, containsAll(['/da/eins.zip', '/da/zwei.zip']));
      expect(chats.anhaenge(einChat), isEmpty);
    });

    test('ein Anhang, der nie geholt wurde, hat keine Datei zu melden', () {
      chats.speichereEigene(nachricht('m1', isMine: true, senderId: ichSelbst),
          anhang: eintrag('m1', senderId: ichSelbst), rezept: '{"v":1}');

      expect(chats.entferneKontakt(einChat).dateien, isEmpty);
    });
  });

  group('Die Adresse des Lagers', () {
    test('wird aus der Relay-Adresse abgeleitet', () {
      expect(
          RealMessengerCore.lagerAdresse(Uri.parse('https://relay.bitdm.net')),
          Uri.parse('https://dateien.bitdm.net'));
    });

    test('und im Test bleibt sie, wie sie ist', () {
      // Dort laeuft beides auf demselben Rechner.
      final lokal = Uri.parse('http://127.0.0.1:8099');
      expect(RealMessengerCore.lagerAdresse(lokal), lokal);
    });

    test('ein fremder Name wird NICHT zu einem Lager umgebaut', () {
      // Wer relay.bitdm.net gegen etwas anderes tauscht, soll nicht
      // stillschweigend auch ein anderes Lager bekommen.
      final fremd = Uri.parse('https://beispiel.de/relay');
      expect(RealMessengerCore.lagerAdresse(fremd), fremd);
    });
  });
}
