// nachrichten_regeln_test.dart — die Regeln fuer Bearbeiten, Widerrufen,
// Reaktionen und Suche, direkt an der Speicherschicht.
//
// WARUM HIER UND NICHT UEBER DEN RELAY: die Regeln stehen in den Abfragen von
// ChatRepository, und der gefaehrliche Fall — eine Gegenstelle, die FREMDE
// Saetze umschreibt — laesst sich ueber den echten Kern gar nicht erzeugen,
// weil der echte Kern so etwas nie verschickt. Genau deshalb muss er hier
// stehen: gegen einen veraenderten Client schuetzt nur die Empfaengerseite.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/store/chat_repository.dart';
import 'package:bitdm/core/store/encrypted_database.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const ich = 'ich';
const anna = 'anna';

void main() {
  late Directory tmp;
  late EncryptedDatabase db;
  late ChatRepository chats;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bitdm_regeln');
    final derived = await KeyDerivation.fromMnemonic(Bip39.generate());
    db = EncryptedDatabase.open('${tmp.path}/t.db', derived.databaseKey);
    chats = ChatRepository(db, SignalStoreRepository(db));
    chats.speichereKontakt(Contact(id: anna, addedAt: DateTime.now().toUtc()));
  });

  tearDown(() {
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  final t0 = DateTime.utc(2026, 9, 25, 12);

  /// Legt eine Nachricht von [von] in die Unterhaltung mit Anna.
  void lege(String id, String von, String text,
      {DateTime? am, MessageKind art = MessageKind.text}) {
    chats.speichereEigene(Message(
      id: id,
      chatId: anna,
      senderId: von,
      text: text,
      isMine: von == ich,
      timestamp: am ?? t0,
      kind: art,
    ));
  }

  Message hole(String id, String von) => chats.nachricht(anna, von, id)!;

  bool bearbeite(String id, String autor, String text, DateTime am) =>
      chats.bearbeite(anna, autor, id, text, am,
          hoechstens: kMaxBearbeitungen, frist: kBearbeitungsFrist);

  group('Bearbeiten', () {
    test('DER AUTOR BEARBEITET, UND DIE BLASE SAGT ES', () {
      lege('m1', anna, 'Hallo');
      expect(bearbeite('m1', anna, 'Hallo!', t0.add(const Duration(minutes: 1))),
          isTrue);
      final m = hole('m1', anna);
      expect(m.text, 'Hallo!');
      expect(m.bearbeitet, isTrue);
    });

    test('NIEMAND BEARBEITET FREMDE SAETZE', () {
      // Der Fall, gegen den nur diese Seite schuetzt: Anna schickt eine
      // Bearbeitung fuer MEINE Nachricht. Die Abfrage sucht mit Annas
      // Adresse als Absender — und findet meine Nachricht nicht.
      lege('m1', ich, 'Ich komme um acht');
      expect(bearbeite('m1', anna, 'Ich komme nicht', t0.add(const Duration(minutes: 1))),
          isFalse);
      expect(hole('m1', ich).text, 'Ich komme um acht');
      expect(hole('m1', ich).bearbeitet, isFalse);
    });

    test('NACH DER FRIST NICHT MEHR, GERECHNET IN DER UHR DES ABSENDERS', () {
      lege('m1', anna, 'alt');
      expect(
          bearbeite('m1', anna, 'neu',
              t0.add(kBearbeitungsFrist + const Duration(seconds: 1))),
          isFalse);
      expect(bearbeite('m1', anna, 'neu', t0.add(kBearbeitungsFrist)), isTrue);
    });

    test('EINE BEARBEITUNG VOR DEM ABSENDEN GIBT ES NICHT', () {
      lege('m1', anna, 'alt');
      expect(bearbeite('m1', anna, 'neu', t0.subtract(const Duration(seconds: 1))),
          isFalse);
    });

    test('EINE AELTERE BEARBEITUNG UEBERSCHREIBT DIE NEUERE NICHT', () {
      // Zwei Wege, vertauschte Reihenfolge: erst kommt Fassung 2 an, dann
      // Fassung 1. Stehen bleiben muss Fassung 2.
      lege('m1', anna, 'alt');
      expect(bearbeite('m1', anna, 'zwei', t0.add(const Duration(minutes: 2))), isTrue);
      expect(bearbeite('m1', anna, 'eins', t0.add(const Duration(minutes: 1))), isFalse);
      expect(hole('m1', anna).text, 'zwei');
    });

    test('HOECHSTENS ZEHNMAL', () {
      lege('m1', anna, 'x');
      for (var i = 1; i <= kMaxBearbeitungen; i++) {
        expect(bearbeite('m1', anna, 'v$i', t0.add(Duration(minutes: i))), isTrue,
            reason: 'Bearbeitung $i');
      }
      expect(bearbeite('m1', anna, 'zu viel', t0.add(const Duration(hours: 1))),
          isFalse);
      expect(hole('m1', anna).text, 'v$kMaxBearbeitungen');
    });

    test('EIN ANHANG WIRD NICHT "BEARBEITET" — SEIN TEXT IST EIN DATEINAME', () {
      lege('a1', anna, 'bild.jpg', art: MessageKind.anhang);
      expect(bearbeite('a1', anna, '../../etc', t0.add(const Duration(minutes: 1))),
          isFalse);
      expect(hole('a1', anna).text, 'bild.jpg');
    });
  });

  group('Fuer alle loeschen', () {
    test('DIE STELLE BLEIBT, DER INHALT UND DIE REAKTIONEN GEHEN', () {
      lege('m1', anna, 'Geheimnis');
      chats.setzeReaktion(anna, 'm1', ich, '👍', t0);
      final weg = chats.widerrufe(anna, anna, 'm1', t0.add(const Duration(minutes: 1)),
          frist: kWiderrufsFrist);
      expect(weg, isNotNull);
      final m = hole('m1', anna);
      expect(m.widerrufen, isTrue);
      expect(m.text, isEmpty);
      expect(chats.reaktionen(anna), isEmpty);
    });

    test('NUR DER AUTOR, NUR IN DER FRIST', () {
      lege('m1', ich, 'meins');
      expect(
          chats.widerrufe(anna, anna, 'm1', t0.add(const Duration(minutes: 1)),
              frist: kWiderrufsFrist),
          isNull,
          reason: 'Anna darf meine Nachricht nicht loeschen');
      expect(
          chats.widerrufe(anna, ich, 'm1',
              t0.add(kWiderrufsFrist + const Duration(seconds: 1)),
              frist: kWiderrufsFrist),
          isNull,
          reason: 'zu spaet');
      expect(hole('m1', ich).text, 'meins');
    });

    test('EINE ZURUECKGENOMMENE NACHRICHT WIRD NICHT NACHGESCHICKT', () {
      chats.speichereEigene(Message(
          id: 'm1',
          chatId: anna,
          senderId: ich,
          text: 'doch nicht',
          isMine: true,
          timestamp: t0,
          status: MessageStatus.sending));
      expect(chats.unversandt().map((m) => m.id), ['m1']);
      chats.widerrufe(anna, ich, 'm1', t0.add(const Duration(seconds: 5)),
          frist: kWiderrufsFrist);
      expect(chats.unversandt(), isEmpty);
    });

    test('NACH DEM WIDERRUF GIBT ES AUCH KEINE BEARBEITUNG MEHR', () {
      lege('m1', anna, 'x');
      chats.widerrufe(anna, anna, 'm1', t0.add(const Duration(minutes: 1)),
          frist: kWiderrufsFrist);
      expect(bearbeite('m1', anna, 'wieder da', t0.add(const Duration(minutes: 2))),
          isFalse);
      expect(hole('m1', anna).text, isEmpty);
    });
  });

  group('Reaktionen', () {
    test('EINE JE PERSON, DIE NEUE ERSETZT DIE ALTE, LEER NIMMT SIE ZURUECK', () {
      lege('m1', anna, 'x');
      chats.setzeReaktion(anna, 'm1', ich, '👍', t0);
      chats.setzeReaktion(anna, 'm1', anna, '😂', t0);
      chats.setzeReaktion(anna, 'm1', ich, '❤️', t0.add(const Duration(seconds: 1)));
      expect(chats.reaktionen(anna), {
        'm1': {ich: '❤️', anna: '😂'},
      });
      chats.setzeReaktion(anna, 'm1', ich, '', t0.add(const Duration(seconds: 2)));
      expect(chats.reaktionen(anna), {
        'm1': {anna: '😂'},
      });
    });

    test('EINE AELTERE REAKTION SCHLAEGT DIE NEUERE NICHT', () {
      lege('m1', anna, 'x');
      chats.setzeReaktion(anna, 'm1', anna, '❤️', t0.add(const Duration(seconds: 5)));
      expect(chats.setzeReaktion(anna, 'm1', anna, '👎', t0), isFalse);
      expect(chats.reaktionen(anna)['m1']![anna], '❤️');
    });

    test('KEINE REAKTION AUF EINE NACHRICHT, DIE ES NICHT GIBT', () {
      // Sonst fuellte eine Gegenstelle die Tabelle mit Waisen.
      expect(chats.setzeReaktion(anna, 'erfunden', anna, '👍', t0), isFalse);
      expect(chats.reaktionen(anna), isEmpty);
    });

    test('MIT DER NACHRICHT VERSCHWINDEN IHRE REAKTIONEN', () {
      lege('m1', anna, 'x');
      chats.setzeReaktion(anna, 'm1', ich, '👍', t0);
      chats.loescheNachricht(anna, anna, 'm1');
      expect(chats.reaktionen(anna), isEmpty);
    });
  });

  group('Anheften', () {
    bool hefte(String id, bool an, int sekunde) =>
        chats.hefteAn(anna, id, an, t0.add(Duration(seconds: sekunde)));
    List<String> oben() => chats
        .verlauf(anna)
        .where((m) => m.angeheftetAm != null)
        .map((m) => m.id)
        .toList();

    test('HOECHSTENS DREI, DIE VIERTE VERDRAENGT DIE AELTESTE', () {
      for (final id in ['a', 'b', 'c', 'd']) {
        lege(id, anna, id);
      }
      hefte('a', true, 1);
      hefte('b', true, 2);
      hefte('c', true, 3);
      hefte('d', true, 4);
      expect(oben()..sort(), ['b', 'c', 'd']);
    });

    test('EIN VERSPAETETES ANHEFTEN HOLT EINE GELOESTE NICHT ZURUECK', () {
      // Der Grabstein: geloest um 20, danach kommt ein Anheften von 10 an.
      lege('a', anna, 'x');
      hefte('a', true, 5);
      hefte('a', false, 20);
      expect(hefte('a', true, 10), isFalse);
      expect(oben(), isEmpty);
      // Ein NEUERES Anheften darf es wieder.
      expect(hefte('a', true, 30), isTrue);
      expect(oben(), ['a']);
    });

    test('FUER ALLE GELOESCHT HEISST AUCH NICHT MEHR ANGEHEFTET', () {
      lege('a', anna, 'x');
      hefte('a', true, 1);
      chats.widerrufe(anna, anna, 'a', t0.add(const Duration(minutes: 1)),
          frist: kWiderrufsFrist);
      expect(oben(), isEmpty);
      expect(hefte('a', true, 120), isFalse);
    });
  });

  group('Umfragen', () {
    const u = Umfrage('Pizza oder Pasta?', ['Pizza', 'Pasta', 'Beides']);
    const mehr = Umfrage('Welche Tage?', ['Mo', 'Di', 'Mi'], mehrfach: true);
    bool stimme(String id, String von, List<int> a, int sekunde) =>
        chats.setzeStimme(anna, id, von, a, t0.add(Duration(seconds: sekunde)));

    setUp(() {
      lege('u1', anna, u.alsText(), art: MessageKind.umfrage);
      lege('u2', anna, mehr.alsText(), art: MessageKind.umfrage);
    });

    test('EINE STIMME, EINE NEUERE ERSETZT SIE, LEER ZIEHT ZURUECK', () {
      expect(stimme('u1', ich, [0], 1), isTrue);
      expect(stimme('u1', anna, [1], 1), isTrue);
      expect(chats.stimmen(anna)['u1'], {ich: [0], anna: [1]});
      expect(stimme('u1', ich, [2], 2), isTrue);
      expect(chats.stimmen(anna)['u1']![ich], [2]);
      expect(stimme('u1', ich, [], 3), isTrue);
      expect(chats.stimmen(anna)['u1'], {anna: [1]});
    });

    test('WAS NICHT PASST, ZAEHLT NICHT', () {
      expect(stimme('u1', ich, [3], 1), isFalse, reason: 'Antwort 4 gibt es nicht');
      expect(stimme('u1', ich, [-1], 1), isFalse);
      expect(stimme('u1', ich, [0, 1], 1), isFalse, reason: 'Einzelwahl');
      expect(stimme('u2', ich, [0, 0], 1), isFalse, reason: 'doppelt');
      expect(stimme('m-gibts-nicht', ich, [0], 1), isFalse);
      expect(chats.stimmen(anna), isEmpty);
      // Mehrfachwahl darf mehrere.
      expect(stimme('u2', ich, [0, 2], 1), isTrue);
    });

    test('EINE AELTERE STIMME SCHLAEGT DIE NEUERE NICHT', () {
      stimme('u1', anna, [1], 10);
      expect(stimme('u1', anna, [0], 5), isFalse);
      expect(chats.stimmen(anna)['u1']![anna], [1]);
    });

    test('EINE TEXTNACHRICHT IST KEINE UMFRAGE, AUCH WENN IHR TEXT SO AUSSIEHT', () {
      lege('t1', anna, u.alsText());
      expect(stimme('t1', ich, [0], 1), isFalse);
    });

    test('MIT DER UMFRAGE GEHEN IHRE STIMMEN', () {
      stimme('u1', ich, [0], 1);
      chats.widerrufe(anna, anna, 'u1', t0.add(const Duration(minutes: 1)),
          frist: kWiderrufsFrist);
      expect(chats.stimmen(anna)['u1'], isNull);
    });

    test('WAS VON DRAUSSEN KOMMT, WIRD BEGRENZT', () {
      expect(Umfrage.lies(u.alsText())!.optionen, ['Pizza', 'Pasta', 'Beides']);
      expect(Umfrage.lies('{"f":"x","o":["a"]}'), isNull, reason: 'eine Antwort');
      expect(Umfrage.lies('{"f":"x","o":${List.filled(11, '"a"')}}'), isNull);
      expect(Umfrage.lies('{"f":"","o":["a","b"]}'), isNull);
      expect(Umfrage.lies('{"f":"${'x' * 301}","o":["a","b"]}'), isNull);
      expect(Umfrage.lies('{"f":"x","o":["a",3]}'), isNull);
      expect(Umfrage.lies('kein json'), isNull);
    });
  });

  group('Ausgang', () {
    test('ERST DRIN, NACH DEM AUSTRAGEN WEG, UND MIT DEM KONTAKT WEG', () {
      final a = chats.legeInAusgang(anna, Uint8List.fromList([1, 2, 3]));
      chats.legeInAusgang(anna, Uint8List.fromList([4]));
      expect(chats.ausgang().map((e) => e.nutzlast.toList()), [
        [1, 2, 3],
        [4],
      ]);
      chats.trageAusDemAusgang(a);
      expect(chats.ausgang().single.nutzlast.toList(), [4]);
      chats.entferneKontakt(anna);
      expect(chats.ausgang(), isEmpty);
    });
  });

  group('Suche', () {
    test('GROSS ODER KLEIN IST EGAL, AUCH BEI UMLAUTEN, NEUESTE ZUERST', () {
      lege('m1', anna, 'Übung macht den Meister', am: t0);
      lege('m2', ich, 'morgen wieder übung?', am: t0.add(const Duration(hours: 1)));
      lege('m3', anna, 'nichts damit', am: t0.add(const Duration(hours: 2)));
      expect(chats.suche('ÜBUNG').map((m) => m.id), ['m2', 'm1']);
    });

    test('PROZENT UND UNTERSTRICH SIND ZEICHEN, KEINE PLATZHALTER', () {
      lege('m1', anna, '50% Rabatt');
      lege('m2', anna, '500 Euro');
      expect(chats.suche('50%').map((m) => m.id), ['m1']);
      expect(chats.suche('_'), isEmpty);
    });

    test('GELOESCHTES UND ANHANGNAMEN WERDEN NICHT GEFUNDEN', () {
      lege('m1', anna, 'geheim');
      lege('a1', anna, 'geheim.pdf', art: MessageKind.anhang);
      chats.widerrufe(anna, anna, 'm1', t0.add(const Duration(minutes: 1)),
          frist: kWiderrufsFrist);
      expect(chats.suche('geheim'), isEmpty);
    });
  });

  group('Ordnung der Unterhaltungen', () {
    test('ANHEFTEN, ARCHIVIEREN, STUMM UEBERLEBEN DAS SPEICHERN', () {
      final k = chats.kontakt(anna)!;
      chats.speichereKontakt(k.copyWith(angeheftet: true, stumm: true));
      final wieder = chats.kontakt(anna)!;
      expect(wieder.angeheftet, isTrue);
      expect(wieder.stumm, isTrue);
      expect(wieder.archiviert, isFalse);
    });
  });
}
