// nahbereich_test.dart — aus einem Sechser einen Kontakt, aus einem Kontakt
// ein Geraet.
//
// Diese Schicht ist die einzige im Naheteil, die BEIDES kennt: die Kontakte
// mit ihren Schluesseln und die Bluetooth-Adressen. Genau deshalb sitzen hier
// die Fehler, die man auf zwei Telefonen sieht und im Test nicht — wenn man
// den Test nicht schreibt.
//
// Vier Sorten Fehler werden geprueft:
//   1. Jemanden erkennen, den man nicht kennt (oder umgekehrt nicht erkennen).
//   2. Jemanden fuer erreichbar halten, der laengst weg ist.
//   3. Mehr aussenden, als in eine Werbung passt — der native Teil weist das
//      ab, und dann geht gar nichts mehr hinaus.
//   4. Beim Fensterwechsel stehenbleiben. Der faellt am Schreibtisch nie auf,
//      weil kein Test 15 Minuten laeuft.

import 'dart:typed_data';

import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/funk_attrappe.dart';

class Teilnehmer {
  Teilnehmer(this.paar, this.oeffentlich, this.adresse);

  final SimpleKeyPair paar;
  final Uint8List oeffentlich;
  final String adresse;

  static Future<Teilnehmer> neu(String adresse) async {
    final paar = await X25519().newKeyPair();
    final pub = await paar.extractPublicKey();
    return Teilnehmer(paar, Uint8List.fromList(pub.bytes), adresse);
  }

  Future<Uint8List> geheimnisMit(Teilnehmer a) =>
      Leuchtfeuer.gemeinsamesGeheimnis(
          eigenerSchluessel: paar, fremderOeffentlicher: a.oeffentlich);
}

void main() {
  late Teilnehmer ich;
  late Teilnehmer anna;
  late Teilnehmer bert;
  late Teilnehmer fremder;
  late FunkAttrappe funk;
  late Nahbereich nah;

  /// Die Uhr des Tests. Ohne sie liefe kein Fenster- und kein Fristtest.
  var jetzt = DateTime.utc(2026, 7, 26, 12, 0);

  Future<NahKontakt> kontakt(Teilnehmer t) async => NahKontakt(
        adresse: t.adresse,
        identitaet: t.oeffentlich,
        geheimnis: await ich.geheimnisMit(t),
      );

  /// Das Leuchtfeuer, das [t] gerade aussendet, damit WIR ihn finden.
  Future<Uint8List> seinesFuerUns(Teilnehmer t) async => Leuchtfeuer.eigenesFuer(
        geheimnis: await t.geheimnisMit(ich),
        eigenerOeffentlicher: t.oeffentlich,
        zeit: jetzt,
      );

  setUp(() async {
    jetzt = DateTime.utc(2026, 7, 26, 12, 0);
    ich = await Teilnehmer.neu('ICH');
    anna = await Teilnehmer.neu('ANNA');
    bert = await Teilnehmer.neu('BERT');
    fremder = await Teilnehmer.neu('FREMD');
    funk = FunkAttrappe();
    nah = Nahbereich(
      funk: funk,
      uhr: () => jetzt,
      vergessenNach: const Duration(seconds: 90),
      wechselAlle: const Duration(milliseconds: 20),
    );
  });

  tearDown(() async {
    await nah.dispose();
    await funk.dispose();
  });

  Future<void> starte(List<Teilnehmer> kontakte) async {
    await nah.starte(
      kontakte: [for (final k in kontakte) await kontakt(k)],
      eigenerOeffentlicher: ich.oeffentlich,
    );
  }

  Uint8List fuellbyte(int n) => Uint8List.fromList(List.filled(6, n));

  group('Erkennen', () {
    test('das Leuchtfeuer eines Kontakts wird ihm zugeordnet', () async {
      await starte([anna, bert]);
      funk.sieh(Gesehen(
        geraet: 'AA:11',
        rssi: -40,
        // So kommt es wirklich an: ein echtes Leuchtfeuer zwischen
        // neununddreissig Fuellbytes.
        leuchtfeuer: [
          fuellbyte(1), await seinesFuerUns(anna), fuellbyte(2),
        ],
      ));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, ['ANNA']);
    });

    test('EIN FREMDER BLEIBT UNSICHTBAR', () async {
      // Nicht "wird ignoriert", sondern: es gibt gar nichts zu erkennen. Das
      // gemeinsame Geheimnis fehlt, also steht sein Leuchtfeuer in keiner
      // Tabelle. Genau das ist der Grund, warum nicht die Adresse ausgesendet
      // wird.
      await starte([anna]);
      funk.sieh(Gesehen(
        geraet: 'FF:FF',
        rssi: -40,
        leuchtfeuer: [await seinesFuerUns(fremder)],
      ));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, isEmpty);
    });

    test('reine Fuellbytes ergeben niemanden', () async {
      await starte([anna, bert]);
      funk.sieh(Gesehen(
        geraet: 'AA:11', rssi: -40,
        leuchtfeuer: [for (var i = 0; i < 40; i++) fuellbyte(i)],
      ));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, isEmpty);
    });

    test('wechselt jemand die Bluetooth-Adresse, folgt der Eintrag', () async {
      // Android wechselt die Adresse regelmaessig. Wer stattdessen einen
      // zweiten Eintrag anlegte, schickte spaeter an eine Adresse, die es
      // nicht mehr gibt.
      await starte([anna]);
      final l = await seinesFuerUns(anna);
      funk.sieh(Gesehen(geraet: 'AA:11', rssi: -40, leuchtfeuer: [l]));
      await Future<void>.delayed(Duration.zero);
      funk.sieh(Gesehen(geraet: 'BB:22', rssi: -50, leuchtfeuer: [l]));
      await Future<void>.delayed(Duration.zero);

      expect(nah.inReichweite, ['ANNA']);
      await nah.schicke('ANNA', Uint8List.fromList([1]));
      expect(funk.gesendet.single.geraet, 'BB:22');
    });
  });

  group('In Reichweite bleiben', () {
    test('nach der Frist ist jemand nicht mehr da', () async {
      await starte([anna]);
      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);
      expect(nah.bereit, isTrue);

      jetzt = jetzt.add(const Duration(seconds: 91));
      expect(nah.bereit, isFalse);
      expect(nah.inReichweite, isEmpty);
    });

    test('bereit ist falsch, bevor ueberhaupt jemand gesehen wurde', () async {
      await starte([anna]);
      expect(nah.bereit, isFalse);
    });

    test('an jemanden, der nicht da ist, wird nicht geschickt', () async {
      await starte([anna]);
      await expectLater(
        nah.schicke('ANNA', Uint8List.fromList([1])),
        throwsA(isA<FunkFehler>()),
      );
      expect(funk.gesendet, isEmpty);
    });

    test('nach dem Halten ist niemand mehr in Reichweite', () async {
      await starte([anna]);
      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);
      await nah.halt();
      expect(nah.bereit, isFalse);
      expect(funk.allesAusGerufen, isTrue);
    });
  });

  group('Aussenden', () {
    test('je Kontakt ein eigenes Leuchtfeuer', () async {
      await starte([anna, bert]);
      expect(funk.werbungen.single, hasLength(2));
      // Und sie sind verschieden — ein gemeinsames koennte jeder Kontakt
      // weitergeben.
      final w = funk.werbungen.single;
      expect(w[0], isNot(w[1]));
    });

    test('OHNE KONTAKTE WIRD NICHT GEFUNKT', () async {
      // Eine Werbung aus reinen Fuellbytes waere Funkverkehr ohne jeden
      // Zweck — Akku und Anwesenheit fuer nichts.
      await starte([]);
      expect(funk.werbungen, isEmpty);
      expect(funk.suchtGerade, isFalse);
      expect(funk.postfachOffen, isFalse);
    });

    test('MEHR ALS VIERZIG KONTAKTE gehen reihum hinaus', () async {
      // 240 Byte je Werbung sind gemessen (docs/NAHBEREICH.md). Wer mehr
      // schickt, bekommt ADVERTISE_FAILED_DATA_TOO_LARGE und sendet dann gar
      // nichts mehr — die Funktion faellt vollstaendig aus, nicht teilweise.
      final viele = <Teilnehmer>[];
      for (var i = 0; i < 45; i++) {
        viele.add(await Teilnehmer.neu('K$i'));
      }
      await starte(viele);

      expect(funk.werbungen.single, hasLength(40),
          reason: 'nie mehr als in eine Werbung passt');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(funk.werbungen.length, greaterThan(1),
          reason: 'die restlichen fuenf muessen auch drankommen');
      for (final w in funk.werbungen) {
        expect(w, hasLength(40));
      }
    });

    test('beim Fensterwechsel wird neu gerechnet und neu ausgesendet',
        () async {
      await starte([anna]);
      final vorher = funk.werbungen.single.single;

      jetzt = jetzt.add(const Duration(minutes: 16));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(funk.werbungen.length, greaterThan(1),
          reason: 'mit einem veralteten Leuchtfeuer findet einen niemand mehr');
      expect(funk.werbungen.last.single, isNot(vorher));
    });

    test('AN DER FENSTERGRENZE VERLIERT MAN NIEMANDEN', () async {
      // Der Fall, den eine ueberlebende Mutation aufgedeckt hat.
      //
      // Die Tabelle deckt drei Fenster ab (f-1, f, f+1) — genau damit zwei
      // Telefone mit leicht verschiedenen Uhren sich an der Grenze nicht
      // verlieren. Wer beim Zuordnen auf genaue Gleichheit des Fensters
      // besteht, wirft sie trotzdem weg, sobald die Grenze ueberschritten ist,
      // und erkennt bis zum naechsten Takt niemanden. Alle 15 Minuten eine
      // blinde Luecke, die am Schreibtisch nie auffaellt.
      //
      // Der Takt ist hier absichtlich lang: sonst baute er die Tabelle sofort
      // neu und der Test prueft nichts.
      final langsam = Nahbereich(
        funk: funk,
        uhr: () => jetzt,
        wechselAlle: const Duration(minutes: 10),
      );
      await langsam.starte(
        kontakte: [await kontakt(anna)],
        eigenerOeffentlicher: ich.oeffentlich,
      );

      jetzt = jetzt.add(const Duration(minutes: 16)); // ein Fenster weiter
      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);

      expect(langsam.inReichweite, ['ANNA'],
          reason: 'die Tabelle deckt dieses Fenster noch ab');
      await langsam.dispose();
    });

    test('zwei Fenster spaeter aber nicht mehr', () async {
      // Die Gegenprobe. Ohne Grenze wuerde ein aufgezeichnetes Leuchtfeuer
      // beliebig lange gelten.
      final langsam = Nahbereich(
        funk: funk,
        uhr: () => jetzt,
        wechselAlle: const Duration(minutes: 10),
      );
      await langsam.starte(
        kontakte: [await kontakt(anna)],
        eigenerOeffentlicher: ich.oeffentlich,
      );
      final altes = await seinesFuerUns(anna);

      jetzt = jetzt.add(const Duration(minutes: 31)); // zwei Fenster weiter
      funk.sieh(Gesehen(geraet: 'AA:11', rssi: -40, leuchtfeuer: [altes]));
      await Future<void>.delayed(Duration.zero);

      expect(langsam.inReichweite, isEmpty);
      await langsam.dispose();
    });

    test('nach dem Fensterwechsel wird auch RICHTIG erkannt', () async {
      // Die Gegenprobe zur Tabelle: sie muss mitwandern, sonst sendet man
      // zwar neu aus, findet aber niemanden mehr.
      await starte([anna]);
      jetzt = jetzt.add(const Duration(minutes: 16));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, ['ANNA']);
    });
  });

  group('Hereinkommende Umschlaege', () {
    test('ein Umschlag wird MIT ABSENDER durchgereicht', () async {
      // Der Absender steht NICHT im Umschlag — das waere eine dauerhafte
      // Kennung im Klartext durch die Luft. Er kommt aus der Buchfuehrung:
      // von diesem Geraet haben wir Annas Leuchtfeuer gesehen, also ist Anna
      // es, die schreibt.
      await starte([anna]);
      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);

      final kommt = nah.eingang.first;
      funk.empfange(Eingegangen('AA:11', Uint8List.fromList([1, 2, 3])));
      final u = await kommt;
      expect(u.von, 'ANNA');
      expect(u.umschlag, Uint8List.fromList([1, 2, 3]));
    });

    test('VON EINEM UNBEKANNTEN GERAET KOMMT NICHTS DURCH', () async {
      // Ohne Absender liesse sich nichts entschluesseln — der Sitzungs-
      // schluessel haengt an der Gegenstelle. Zu raten waere schlimmer als
      // wegzuwerfen: jeder Versuch mit dem falschen Kontakt rueckte dessen
      // Ratchet weiter und beschaedigte eine Sitzung, die funktioniert.
      await starte([anna]);
      var kam = 0;
      final abo = nah.eingang.listen((_) => kam++);
      funk.empfange(Eingegangen('ZZ:99', Uint8List.fromList([1, 2, 3])));
      await Future<void>.delayed(Duration.zero);
      expect(kam, 0);
      await abo.cancel();
    });

    test('ZWEI KONTAKTE AUF EINEM GERAET: der Umschlag wird verworfen',
        () async {
      // DER SCHADEN WAERE NICHT DIE VERLORENE NACHRICHT, sondern die kaputte
      // Sitzung. Wer hier den erstbesten Kontakt nimmt, macht den Umschlag mit
      // dem falschen Sitzungsschluessel auf: die Entschluesselung scheitert
      // ohnehin, aber angefasst wurde der Ratchet des ANDEREN — und der hat
      // mit dieser Nachricht nichts zu tun. Dieselbe Ueberlegung wie beim
      // unbekannten Geraet, nur einen Schritt weiter.
      await starte([anna, bert]);
      funk.sieh(Gesehen(geraet: 'AA:11', rssi: -40, leuchtfeuer: [
        await seinesFuerUns(anna),
        await seinesFuerUns(bert),
      ]));
      await Future<void>.delayed(Duration.zero);
      expect(nah.inReichweite, ['ANNA', 'BERT'],
          reason: 'beide sind erfasst — sonst prueft der Test darunter nichts');

      var kam = 0;
      final abo = nah.eingang.listen((_) => kam++);
      funk.empfange(Eingegangen('AA:11', Uint8List.fromList([1, 2, 3])));
      await Future<void>.delayed(Duration.zero);
      expect(kam, 0, reason: 'einer von beiden waere geraten');
      await abo.cancel();
    });

    test('...und trotzdem laesst sich an BEIDE senden', () async {
      // DIE GEGENPROBE, und sie ist der Grund, warum `_sah` kein break
      // enthaelt. Beim Senden steht die Adresse fest und das Geraet wird zu
      // ihr gesucht — das ist eindeutig. Nur die Gegenrichtung ist es nicht.
      // Wer den zweiten Kontakt gar nicht erst eintruege, machte ihn
      // unerreichbar, statt eine Nachricht von ihm zu verwerfen.
      await starte([anna, bert]);
      funk.sieh(Gesehen(geraet: 'AA:11', rssi: -40, leuchtfeuer: [
        await seinesFuerUns(anna),
        await seinesFuerUns(bert),
      ]));
      await Future<void>.delayed(Duration.zero);

      await nah.schicke('ANNA', Uint8List.fromList([1]));
      await nah.schicke('BERT', Uint8List.fromList([2]));
      expect(funk.gesendet, hasLength(2));
      expect(funk.gesendet.every((g) => g.geraet == 'AA:11'), isTrue);
    });

    test('nach der Frist bleibt der Absender trotzdem bekannt', () async {
      // Wer gerade schreibt, ist offensichtlich da. Die Frist beantwortet die
      // Frage "kann ich dorthin senden" — hier ist die Frage eine andere, und
      // wer sie mit derselben Frist beantwortet, verliert eine Nachricht, die
      // schon angekommen ist.
      await starte([anna]);
      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);

      jetzt = jetzt.add(const Duration(seconds: 91));
      final kommt = nah.eingang.first;
      funk.empfange(Eingegangen('AA:11', Uint8List.fromList([9])));
      expect((await kommt).von, 'ANNA');
    });
  });

  group('Wer neu in Reichweite kommt', () {
    test('wird EINMAL gemeldet, nicht bei jeder Werbung', () async {
      // Eine Werbung kommt mehrmals je Sekunde und je Geraet. Wer daran den
      // Nachversand haengt, haengt ihn an einen Dauerstrom — und schickt
      // dieselbe Liste im Sekundentakt noch einmal durch.
      await starte([anna]);
      final gemeldet = <String>[];
      final abo = nah.neuInReichweite.listen(gemeldet.add);

      final l = await seinesFuerUns(anna);
      for (var i = 0; i < 5; i++) {
        funk.sieh(Gesehen(geraet: 'AA:11', rssi: -40, leuchtfeuer: [l]));
        await Future<void>.delayed(Duration.zero);
      }

      expect(gemeldet, ['ANNA']);
      await abo.cancel();
    });

    test('WAR SIE WEG UND KOMMT WIEDER, wird sie erneut gemeldet', () async {
      // Der eigentliche Zweck. Ohne diesen Uebergang erfaehrt niemand ueber
      // dieser Schicht, dass ein Weg aufgegangen ist — und mit "nur in der
      // Naehe" gibt es sonst nichts, was einen Nachversand anstiesse.
      await starte([anna]);
      final gemeldet = <String>[];
      final abo = nah.neuInReichweite.listen(gemeldet.add);

      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);

      jetzt = jetzt.add(const Duration(seconds: 91)); // sie war weg
      funk.sieh(Gesehen(
          geraet: 'AA:11', rssi: -40, leuchtfeuer: [await seinesFuerUns(anna)]));
      await Future<void>.delayed(Duration.zero);

      expect(gemeldet, ['ANNA', 'ANNA']);
      await abo.cancel();
    });
  });

  test('das Postfach steht offen, sobald es laeuft', () async {
    await starte([anna]);
    expect(funk.postfachOffen, isTrue);
    expect(funk.suchtGerade, isTrue);
  });
}
