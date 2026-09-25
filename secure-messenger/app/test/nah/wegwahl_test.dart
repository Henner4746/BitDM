// wegwahl_test.dart — welchen Weg eine Nachricht nimmt, und welchen nicht.
//
// Die wichtigste Zusage dieser Schicht ist eine NEGATIVE: niemals beide Wege
// fuer dieselbe Nachricht. Eine doppelt zugestellte Nachricht sieht der
// Empfaenger zweimal, und im Double Ratchet stuenden zwei Schluesselketten
// nebeneinander. So etwas prueft man nicht, indem man zusieht, ob es
// funktioniert — sondern indem man nachzaehlt, was NICHT passiert ist.

import 'dart:typed_data';

import 'package:bitdm/core/nah/wegwahl.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ein Ausgang, der Buch fuehrt.
class Buchfuehrend implements Ausgang {
  Buchfuehrend({this.bereit = true, this.wirft = false});

  @override
  bool bereit;

  @override
  bool bereitFuer(String an) => bereit;

  /// Ob der Versuch scheitert — nachdem er gezaehlt wurde.
  bool wirft;

  /// Was dabei geworfen wird; ohne Angabe ein mehrdeutiger Fehler.
  Object? fehler;

  final gesendet = <String>[];

  @override
  Future<void> schicke(String an, Uint8List umschlag) async {
    gesendet.add('$an:${umschlag.length}');
    if (wirft) throw fehler ?? StateError('geht gerade nicht');
  }
}

/// Wie ein Nahbereich: bereit fuer GENAU die Kontakte in [da].
class NurFuer extends Buchfuehrend {
  NurFuer(this.da) : super(bereit: da.isNotEmpty);
  final Set<String> da;
  @override
  bool bereitFuer(String an) => da.contains(an);
}

/// Ein Fehlschlag, bei dem sicher nichts hinausging (wie FunkFehler NICHT_DA).
class NichtsRaus implements Exception, Ausgangsfehler {
  @override
  bool get nichtsHinaus => true;
}

final umschlag = Uint8List.fromList(List.generate(612, (i) => i & 0xFF));

void main() {
  late Buchfuehrend relay;
  late Buchfuehrend naehe;

  setUp(() {
    relay = Buchfuehrend();
    naehe = Buchfuehrend();
  });

  Wegwahl wahl({bool nurNah = false}) =>
      Wegwahl(relay: relay, naehe: naehe, nurNahbereich: nurNah);

  group('Relay zuerst', () {
    test('wenn er kann, geht es ueber ihn', () async {
      final b = await wahl().schicke('abc', umschlag);
      expect(b.weg, Weg.relay);
      expect(relay.gesendet, ['abc:612']);
      expect(naehe.gesendet, isEmpty,
          reason: 'die Naehe darf gar nicht erst angefasst werden');
    });

    test('auch wenn die Naehe bereit waere', () async {
      naehe.bereit = true;
      final b = await wahl().schicke('abc', umschlag);
      expect(b.weg, Weg.relay);
      expect(naehe.gesendet, isEmpty);
    });
  });

  group('Die Naehe als Ausfallsicherung', () {
    test('kein Relay, aber jemand in Reichweite', () async {
      relay.bereit = false;
      final b = await wahl().schicke('abc', umschlag);
      expect(b.weg, Weg.naehe);
      expect(naehe.gesendet, ['abc:612']);
      expect(relay.gesendet, isEmpty);
    });

    test('kein Weg offen: die Nachricht LIEGT, sie scheitert nicht', () async {
      // Der Unterschied ist der zwischen "die App versucht es wieder" und
      // "du musst es noch einmal tippen".
      relay.bereit = false;
      naehe.bereit = false;
      final b = await wahl().schicke('abc', umschlag);
      expect(b.weg, Weg.liegt);
      expect(relay.gesendet, isEmpty);
      expect(naehe.gesendet, isEmpty);
    });
  });

  group('NIEMALS BEIDE WEGE', () {
    test('nach einem gescheiterten Relay wird NICHT auf die Naehe gewechselt',
        () async {
      // DIE FALLE, und der Grund fuer diese ganze Datei.
      //
      // Der Relay hat geworfen — aber das heisst nicht, dass die Nachricht
      // nicht angekommen ist. Sie kann drueben liegen und nur die
      // Bestaetigung verlorengegangen sein. Sie jetzt zusaetzlich ueber die
      // Naehe zu schicken hiesse, sie moeglicherweise zweimal zuzustellen.
      relay.wirft = true;
      naehe.bereit = true;

      final b = await wahl().schicke('abc', umschlag);

      expect(b.weg, Weg.liegt);
      expect(relay.gesendet, ['abc:612'], reason: 'einmal versucht');
      expect(naehe.gesendet, isEmpty,
          reason: 'DIE NAEHE DARF JETZT NICHT MEHR — die Nachricht koennte '
              'schon unterwegs sein');
    });

    test('und der Bescheid sagt auch, warum', () async {
      relay.wirft = true;
      final b = await wahl().schicke('abc', umschlag);
      expect(b.grund, contains('schon unterwegs sein koennte'));
    });

    test('scheitert die Naehe, wird nicht auf den Relay gewechselt', () async {
      // Die Gegenrichtung. Sie kommt seltener vor, ist aber derselbe Fehler.
      relay.bereit = false;
      naehe.wirft = true;

      final b = await wahl().schicke('abc', umschlag);

      expect(b.weg, Weg.liegt);
      expect(naehe.gesendet, ['abc:612']);
      expect(relay.gesendet, isEmpty);
    });

    test('WAS SCHON BEIM RELAY WAR, geht auch beim naechsten Anlauf nicht '
        'ueber die Naehe', () async {
      // REGEL 2 UEBER DIESEN AUFRUF HINAUS. Diese Klasse lebt nur einen
      // Versand lang; der naechste Anlauf bekommt eine frische und waehlte
      // ohne diese Angabe wieder frei. Dass der Relay inzwischen ganz weg ist,
      // aendert nichts daran, dass der Umschlag drueben liegen kann.
      relay.bereit = false;
      naehe.bereit = true;

      final b = await wahl().schicke('abc', umschlag, schonBeimRelay: true);

      expect(b.weg, Weg.liegt);
      expect(naehe.gesendet, isEmpty);
      expect(b.beimRelay, isTrue, reason: 'und er bleibt vermerkt');
    });

    test('auch "nur in der Naehe" hebt das nicht auf', () async {
      // Der Schalter aendert nichts daran, dass der Umschlag drueben liegen
      // kann. Er bleibt liegen, bis der Relay wieder erreichbar ist — und der
      // Relay wird trotzdem nicht angefasst.
      naehe.bereit = true;
      relay.bereit = true;

      final b =
          await wahl(nurNah: true).schicke('abc', umschlag, schonBeimRelay: true);

      expect(b.weg, Weg.liegt);
      expect(naehe.gesendet, isEmpty);
      expect(relay.gesendet, isEmpty,
          reason: 'der Schalter gilt auch hier: NICHTS an einen Server');
    });

    test('ueber den Relay darf sie sehr wohl noch einmal', () async {
      // Die Gegenprobe. Der Vermerk sperrt EINEN Weg, nicht die Nachricht:
      // dort greift die Wiederholung ueber die Nachrichtenkennung, und der
      // Server erkennt eine doppelte.
      relay.bereit = true;
      final b = await wahl().schicke('abc', umschlag, schonBeimRelay: true);
      expect(b.weg, Weg.relay);
      expect(relay.gesendet, ['abc:612']);
    });

    test('der Bescheid sagt, dass der Relay ihn hatte', () async {
      // Ohne diese Angabe kann der Aufrufer nichts festhalten, und beim
      // naechsten Anlauf faengt alles wieder bei null an.
      relay.wirft = true;
      final b = await wahl().schicke('abc', umschlag);
      expect(b.beimRelay, isTrue);

      relay.bereit = false;
      naehe.bereit = true;
      final ohne = await wahl().schicke('abc', umschlag);
      expect(ohne.weg, Weg.naehe);
      expect(ohne.beimRelay, isFalse,
          reason: 'sonst waere jede Nachricht fuer immer vom Funk gesperrt');
    });

    test('bei hundert Nachrichten geht keine zweimal', () async {
      // Die Probe aufs Ganze. Jede Nachricht darf hoechstens einen Eintrag
      // hinterlassen, egal in welcher Lage.
      final lagen = [
        [true, true, false, false],
        [true, true, true, false],
        [false, true, false, false],
        [false, true, false, true],
        [false, false, false, false],
        [true, false, true, false],
      ];
      for (var n = 0; n < 100; n++) {
        final l = lagen[n % lagen.length];
        relay = Buchfuehrend(bereit: l[0], wirft: l[2]);
        naehe = Buchfuehrend(bereit: l[1], wirft: l[3]);
        await wahl().schicke('abc', umschlag);
        expect(relay.gesendet.length + naehe.gesendet.length,
            lessThanOrEqualTo(1),
            reason: 'Lage $l: hoechstens ein Weg je Nachricht');
      }
    });
  });

  group('Nur in der Naehe', () {
    test('der Relay wird nicht einmal gefragt', () async {
      relay.bereit = true;
      final b = await wahl(nurNah: true).schicke('abc', umschlag);
      expect(b.weg, Weg.naehe);
      expect(relay.gesendet, isEmpty);
    });

    test('und wenn niemand da ist, bleibt es liegen — ohne Relay', () async {
      naehe.bereit = false;
      relay.bereit = true;
      final b = await wahl(nurNah: true).schicke('abc', umschlag);
      expect(b.weg, Weg.liegt);
      expect(relay.gesendet, isEmpty,
          reason: 'der Schalter verspricht, dass NICHTS an einen Server geht');
      expect(b.grund, contains('nur in der Naehe'));
    });

    test('auch ein Fehlschlag in der Naehe fuehrt nicht zum Relay', () async {
      naehe.wirft = true;
      relay.bereit = true;
      final b = await wahl(nurNah: true).schicke('abc', umschlag);
      expect(b.weg, Weg.liegt);
      expect(relay.gesendet, isEmpty);
    });
  });

  group('Was nicht geworfen wird', () {
    test('ein Netzfehler kommt als Zustand zurueck, nicht als Ausnahme',
        () async {
      // Vertragsregel des ganzen Kerns. Wer sie hier bricht, zwingt jede
      // aufrufende Stelle in ein try/catch, das sie nicht behandeln kann.
      relay.wirft = true;
      naehe.wirft = true;
      await expectLater(wahl().schicke('abc', umschlag), completes);
    });
  });

  group('Seit 25.09.2026 (Befund H1)', () {
    test('BEREIT HEISST: DIESER EMPFAENGER ist in Reichweite, nicht irgendwer',
        () async {
      // Ein Nachbar in Reichweite genuegte frueher, und die Nachricht an
      // jemand ganz anderen ging "ueber die Naehe" — und scheiterte dort.
      relay.bereit = false;
      final nah = NurFuer({'nachbar'});
      final b = await Wegwahl(relay: relay, naehe: nah).schicke('abc', umschlag);
      expect(b.weg, Weg.liegt);
      expect(nah.gesendet, isEmpty);
      expect(b.inDerNaehe, isFalse,
          reason: 'es wurde gar nichts versucht — also ist nichts mehrdeutig');

      final an = await Wegwahl(relay: relay, naehe: nah).schicke('nachbar', umschlag);
      expect(an.weg, Weg.naehe);
    });

    test('WAS SICHER NICHT HINAUSGING, setzt keinen Vermerk', () async {
      relay.bereit = false;
      naehe.wirft = true;
      naehe.fehler = NichtsRaus();
      final b = await wahl().schicke('abc', umschlag);
      expect(b.weg, Weg.liegt);
      expect(b.inDerNaehe, isFalse,
          reason: 'NICHT_DA und Verwandte sperrten die Nachricht bisher fuer '
              'immer fuer den Relay');
    });

    test('ein mehrdeutiger Fehlschlag setzt ihn weiterhin', () async {
      relay.bereit = false;
      naehe.wirft = true;
      final b = await wahl().schicke('abc', umschlag);
      expect(b.inDerNaehe, isTrue);
    });

    test('WAS IN DER NAEHE WAR, DARF UEBER DEN RELAY — der Empfaenger entdoppelt',
        () async {
      // Bis 25.09.2026 blieb eine solche Nachricht fuer immer liegen.
      relay.bereit = true;
      final b = await wahl().schicke('abc', umschlag, schonInDerNaehe: true);
      expect(b.weg, Weg.relay);
      expect(relay.gesendet, ['abc:612']);
      expect(b.inDerNaehe, isTrue, reason: 'der Vermerk geht nicht verloren');
    });
  });
}
