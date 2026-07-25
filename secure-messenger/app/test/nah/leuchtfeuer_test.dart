// leuchtfeuer_test.dart — erkennen sich zwei Geraete, ohne sich zu zeigen?
//
// Zwei Eigenschaften muessen gleichzeitig gelten, und sie ziehen in
// entgegengesetzte Richtungen:
//
//   ERKENNEN: A muss B zuverlaessig finden, auch wenn die Uhren nicht genau
//   gleich gehen. Ein Aussetzer alle 15 Minuten waere ein Fehler, der sich am
//   Schreibtisch nie zeigt und beim Nutzer als "geht manchmal nicht" ankommt.
//
//   NICHT ZEIGEN: wer nicht dazugehoert, darf aus dem Ausgesendeten weder die
//   Identitaet ablesen noch dasselbe Geraet spaeter wiedererkennen. Sonst
//   haette eine App ohne Telefonnummer statt dessen eine Funkkennung, die
//   ueberallhin mitgeht.

import 'dart:typed_data';

import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ein Geraet mit eigenem Identitaetsschluessel.
class Teilnehmer {
  Teilnehmer(this.name, this.paar, this.oeffentlich);

  final String name;
  final SimpleKeyPair paar;
  final Uint8List oeffentlich;

  static Future<Teilnehmer> neu(String name) async {
    final paar = await X25519().newKeyPair();
    final pub = await paar.extractPublicKey();
    return Teilnehmer(name, paar, Uint8List.fromList(pub.bytes));
  }

  Future<Uint8List> geheimnisMit(Teilnehmer anderer) =>
      Leuchtfeuer.gemeinsamesGeheimnis(
          eigenerSchluessel: paar, fremderOeffentlicher: anderer.oeffentlich);
}

void main() {
  late Teilnehmer anna;
  late Teilnehmer bert;
  late Teilnehmer fremder;

  setUp(() async {
    anna = await Teilnehmer.neu('Anna');
    bert = await Teilnehmer.neu('Bert');
    fremder = await Teilnehmer.neu('Fremder');
  });

  group('Das gemeinsame Geheimnis', () {
    test('BEIDE Seiten kommen auf dasselbe', () async {
      // Der Kern: aus dem eigenen privaten und dem fremden oeffentlichen
      // Schluessel kommt auf beiden Seiten derselbe Wert heraus.
      expect(await anna.geheimnisMit(bert), await bert.geheimnisMit(anna));
    });

    test('ein Dritter kommt NICHT darauf', () async {
      // Der Fremde kennt beide oeffentlichen Schluessel — die sind oeffentlich.
      // Ohne einen der privaten nuetzt ihm das nichts.
      final annaBert = await anna.geheimnisMit(bert);
      expect(await fremder.geheimnisMit(anna), isNot(annaBert));
      expect(await fremder.geheimnisMit(bert), isNot(annaBert));
    });

    test('ein Schluessel falscher Groesse wird abgelehnt', () async {
      await expectLater(
          Leuchtfeuer.gemeinsamesGeheimnis(
              eigenerSchluessel: anna.paar,
              fremderOeffentlicher: Uint8List(31)),
          throwsArgumentError);
    });
  });

  group('Erkennen', () {
    test('DER DURCHGANG: Anna findet Bert', () async {
      final geheimnis = await bert.geheimnisMit(anna);
      final jetzt = DateTime.utc(2026, 7, 25, 16, 30);

      // Was Bert aussendet.
      final gesendet = await Leuchtfeuer.eigenesFuer(
          geheimnis: geheimnis,
          eigenerOeffentlicher: bert.oeffentlich,
          zeit: jetzt);

      // Wonach Anna sucht.
      final tabelle = await LeuchtfeuerTabelle.baue([
        NahKontakt(
            adresse: 'bert',
            identitaet: bert.oeffentlich,
            geheimnis: await anna.geheimnisMit(bert)),
      ], jetzt);

      expect(tabelle.wer(gesendet), 'bert');
    });

    test('auch wenn die Uhren auseinanderlaufen', () async {
      // Bert sendet nach seiner Uhr, Anna sucht nach ihrer — zehn Minuten
      // spaeter, also womoeglich im naechsten Fenster.
      final jetzt = DateTime.utc(2026, 7, 25, 16, 14, 30);
      final gesendet = await Leuchtfeuer.eigenesFuer(
          geheimnis: await bert.geheimnisMit(anna),
          eigenerOeffentlicher: bert.oeffentlich,
          zeit: jetzt);

      final tabelle = await LeuchtfeuerTabelle.baue([
        NahKontakt(
            adresse: 'bert',
            identitaet: bert.oeffentlich,
            geheimnis: await anna.geheimnisMit(bert)),
      ], jetzt.add(const Duration(minutes: 10)));

      expect(tabelle.wer(gesendet), 'bert',
          reason: 'ohne Vor- und Rueckfenster verlieren sich zwei Geraete alle '
              '15 Minuten kurz aus den Augen — und beim Nutzer kommt das als '
              '"geht manchmal nicht" an');
    });

    test('ein Fremder wird nicht erkannt', () async {
      final gesendet = await Leuchtfeuer.eigenesFuer(
          geheimnis: await fremder.geheimnisMit(bert),
          eigenerOeffentlicher: fremder.oeffentlich,
          zeit: DateTime.utc(2026, 7, 25, 16, 30));

      final tabelle = await LeuchtfeuerTabelle.baue([
        NahKontakt(
            adresse: 'bert',
            identitaet: bert.oeffentlich,
            geheimnis: await anna.geheimnisMit(bert)),
      ], DateTime.utc(2026, 7, 25, 16, 30));

      expect(tabelle.wer(gesendet), isNull);
    });

    test('mehrere Kontakte lassen sich auseinanderhalten', () async {
      final jetzt = DateTime.utc(2026, 7, 25, 16, 30);
      final carla = await Teilnehmer.neu('Carla');

      final tabelle = await LeuchtfeuerTabelle.baue([
        NahKontakt(
            adresse: 'bert',
            identitaet: bert.oeffentlich,
            geheimnis: await anna.geheimnisMit(bert)),
        NahKontakt(
            adresse: 'carla',
            identitaet: carla.oeffentlich,
            geheimnis: await anna.geheimnisMit(carla)),
      ], jetzt);

      expect(
          tabelle.wer(await Leuchtfeuer.eigenesFuer(
              geheimnis: await bert.geheimnisMit(anna),
              eigenerOeffentlicher: bert.oeffentlich,
              zeit: jetzt)),
          'bert');
      expect(
          tabelle.wer(await Leuchtfeuer.eigenesFuer(
              geheimnis: await carla.geheimnisMit(anna),
              eigenerOeffentlicher: carla.oeffentlich,
              zeit: jetzt)),
          'carla');
    });
  });

  group('Nicht zeigen', () {
    test('DER WERT WANDERT — kein Wiedererkennen ueber die Zeit', () async {
      // WENN DIESER TEST FEHLT, ist die ganze Datei sinnlos: ein fester Wert
      // waere eine dauerhafte Funkkennung, und die App haette statt einer
      // Telefonnummer etwas Schlimmeres.
      final geheimnis = await bert.geheimnisMit(anna);
      final gesehen = <String>{};

      for (var i = 0; i < 8; i++) {
        final l = await Leuchtfeuer.eigenesFuer(
            geheimnis: geheimnis,
            eigenerOeffentlicher: bert.oeffentlich,
            zeit: DateTime.utc(2026, 7, 25, 0, 0)
                .add(leuchtfeuerFenster * i));
        gesehen.add(l.toString());
      }
      expect(gesehen, hasLength(8),
          reason: 'jedes Zeitfenster muss einen anderen Wert ergeben');
    });

    test('die Identitaet steckt NICHT drin', () async {
      final l = await Leuchtfeuer.eigenesFuer(
          geheimnis: await bert.geheimnisMit(anna),
          eigenerOeffentlicher: bert.oeffentlich,
          zeit: DateTime.utc(2026, 7, 25, 16, 30));

      // Kein Stueck des oeffentlichen Schluessels darf im Ausgesendeten
      // auftauchen.
      for (var i = 0; i + leuchtfeuerLaenge <= 32; i++) {
        expect(l, isNot(bert.oeffentlich.sublist(i, i + leuchtfeuerLaenge)));
      }
    });

    test('je Kontakt ein eigener Wert', () async {
      // Ein gemeinsamer Wert fuer alle koennte von einem Kontakt weitergegeben
      // werden — und damit koennten Fremde einen wiedererkennen.
      final jetzt = DateTime.utc(2026, 7, 25, 16, 30);
      final carla = await Teilnehmer.neu('Carla');

      final anBert = await Leuchtfeuer.eigenesFuer(
          geheimnis: await anna.geheimnisMit(bert),
          eigenerOeffentlicher: anna.oeffentlich,
          zeit: jetzt);
      final anCarla = await Leuchtfeuer.eigenesFuer(
          geheimnis: await anna.geheimnisMit(carla),
          eigenerOeffentlicher: anna.oeffentlich,
          zeit: jetzt);

      expect(anBert, isNot(anCarla));
    });

    test('die RICHTUNG zaehlt: was Anna sendet, sendet Bert nicht', () async {
      // Ohne diesen Unterschied liesse sich Annas Leuchtfeuer aufzeichnen und
      // damit vorgeben, Bert zu sein — ganz ohne Schluessel.
      final geheimnis = await anna.geheimnisMit(bert);
      final jetzt = DateTime.utc(2026, 7, 25, 16, 30);

      final vonAnna = await Leuchtfeuer.eigenesFuer(
          geheimnis: geheimnis,
          eigenerOeffentlicher: anna.oeffentlich,
          zeit: jetzt);
      final vonBert = await Leuchtfeuer.eigenesFuer(
          geheimnis: geheimnis,
          eigenerOeffentlicher: bert.oeffentlich,
          zeit: jetzt);

      expect(vonAnna, isNot(vonBert));
    });

    test('passt in eine Bluetooth-Kennung', () async {
      final l = await Leuchtfeuer.eigenesFuer(
          geheimnis: await bert.geheimnisMit(anna),
          eigenerOeffentlicher: bert.oeffentlich,
          zeit: DateTime.utc(2026, 7, 25, 16, 30));
      expect(l, hasLength(6),
          reason: 'in eine Bluetooth-Kennung passen nur wenige Bytes');
    });
  });

  group('Die Tabelle', () {
    test('merkt, wenn das Zeitfenster abgelaufen ist', () async {
      final jetzt = DateTime.utc(2026, 7, 25, 16, 0);
      final tabelle = await LeuchtfeuerTabelle.baue([
        NahKontakt(
            adresse: 'bert',
            identitaet: bert.oeffentlich,
            geheimnis: await anna.geheimnisMit(bert)),
      ], jetzt);

      expect(tabelle.giltNoch(jetzt.add(const Duration(minutes: 5))), isTrue);
      expect(tabelle.giltNoch(jetzt.add(const Duration(minutes: 20))), isFalse,
          reason: 'sonst sucht die App nach Werten, die niemand mehr sendet');
    });

    test('haelt drei Fenster je Kontakt bereit', () async {
      final tabelle = await LeuchtfeuerTabelle.baue([
        NahKontakt(
            adresse: 'bert',
            identitaet: bert.oeffentlich,
            geheimnis: await anna.geheimnisMit(bert)),
      ], DateTime.utc(2026, 7, 25, 16, 30));
      expect(tabelle.anzahl, 3);
    });

    test('ohne Kontakte ist sie leer und findet nichts', () async {
      final tabelle =
          await LeuchtfeuerTabelle.baue([], DateTime.utc(2026, 7, 25));
      expect(tabelle.anzahl, 0);
      expect(tabelle.wer(Uint8List(6)), isNull);
    });
  });
}
