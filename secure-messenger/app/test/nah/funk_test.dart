// funk_test.dart — die Bluetooth-Huelle ohne Bluetooth.
//
// Was hier geprueft wird, ist nicht die Funkstrecke — die ist auf zwei
// Telefonen gemessen (docs/NAHBEREICH.md). Geprueft wird die Buchfuehrung
// drumherum, und die ist der Teil, in dem Fehler ueberleben: welches Haeppchen
// zu welcher Gegenstelle gehoert, was beim Abbruch passiert, und ob der
// zweite Anlauf mit kleinerer Haeppchengroesse wirklich stattfindet.
//
// Alle vier Faelle hier koennen im Betrieb eintreten und keiner davon faellt
// beim Ausprobieren auf einem Schreibtisch auf.

import 'dart:typed_data';

import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/nah/stueckelung.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kanal = MethodChannel('bitdm/nahfunk');
  const ereignisse = 'bitdm/nahfunk_ereignisse';
  final bote = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Die Aufrufe, die bei Kotlin angekommen waeren.
  late List<MethodCall> gerufen;

  /// Was der naechste `sende`-Aufruf tun soll. Null = gelingen.
  PlatformException? sendeFehler;

  late Nahfunk funk;

  /// Schiebt ein Ereignis den Weg hoch, den auch der native Teil nimmt.
  Future<void> ereignis(Map<String, Object?> e) async {
    await bote.handlePlatformMessage(
      ereignisse,
      const StandardMethodCodec().encodeSuccessEnvelope(e),
      (_) {},
    );
  }

  setUp(() {
    gerufen = [];
    sendeFehler = null;
    bote.setMockMethodCallHandler(kanal, (call) async {
      gerufen.add(call);
      if (call.method == 'sende') {
        final f = sendeFehler;
        sendeFehler = null;
        if (f != null) throw f;
      }
      if (call.method == 'zustand') {
        return <Object?, Object?>{
          'zuAlt': false, 'vorhanden': true, 'an': true,
          'rechte': true, 'jeWerbung': 40,
        };
      }
      return true;
    });
    // Der Ereignisstrom: die Anmeldung bestaetigen, damit horcheAuf() traegt.
    bote.setMockMessageHandler(ereignisse, (_) async =>
        const StandardMethodCodec().encodeSuccessEnvelope(null));
    funk = Nahfunk();
    funk.horcheAuf();
  });

  tearDown(() async {
    bote.setMockMethodCallHandler(kanal, null);
    bote.setMockMessageHandler(ereignisse, null);
    await funk.dispose();
  });

  Uint8List sechser(int n) => Uint8List.fromList(List.filled(6, n));

  group('Was der Funk sieht', () {
    test('ein Fund wird durchgereicht, mit allen Sechsern', () async {
      final gesehen = funk.gesehen.first;
      await ereignis({
        'art': 'gesehen',
        'geraet': 'AA:BB:CC:DD:EE:FF',
        'rssi': -42,
        'leuchtfeuer': [sechser(1), sechser(2)],
      });
      final g = await gesehen;
      expect(g.geraet, 'AA:BB:CC:DD:EE:FF');
      expect(g.rssi, -42);
      expect(g.leuchtfeuer, hasLength(2));
    });

    test('was nicht sechs Byte hat, faellt heraus', () async {
      // Der native Teil zerlegt die Werbung in Sechser; ein Rest am Ende
      // waere keiner. Ihn durchzulassen hiesse, in der Tabelle nach etwas zu
      // suchen, das dort nie stehen kann.
      final gesehen = funk.gesehen.first;
      await ereignis({
        'art': 'gesehen',
        'geraet': 'A',
        'rssi': -1,
        'leuchtfeuer': [sechser(1), Uint8List.fromList([1, 2, 3])],
      });
      expect((await gesehen).leuchtfeuer, hasLength(1));
    });
  });

  group('Haeppchen zusammensetzen', () {
    test('eine Sendung in zwei Stuecken kommt als EINS an', () async {
      final umschlag = Uint8List.fromList(List.generate(300, (i) => i % 251));
      final stuecke =
          zerlege(umschlag, sendungsnummer: 7, nutzlastJeStueck: 200);
      expect(stuecke, hasLength(2));

      final kommt = funk.eingang.first;
      for (final s in stuecke) {
        await ereignis({'art': 'stueck', 'geraet': 'A', 'daten': s});
      }
      final e = await kommt;
      expect(e.geraet, 'A');
      expect(e.umschlag, umschlag);
    });

    test('ZWEI GEGENSTELLEN MIT DERSELBEN SENDUNGSNUMMER vermischen sich nicht',
        () async {
      // Die Nummern werden unabhaengig voneinander gewaehlt — dass zwei
      // Geraete dieselbe benutzen, ist kein Sonderfall, sondern bei 65536
      // Moeglichkeiten und zwei Gespraechen Alltag. Ein gemeinsamer Sammler
      // machte daraus einen Umschlag, der bei libsignal als Krypto-Fehler
      // ankaeme.
      final a = Uint8List.fromList(List.filled(300, 0xAA));
      final b = Uint8List.fromList(List.filled(300, 0xBB));
      final sa = zerlege(a, sendungsnummer: 7, nutzlastJeStueck: 200);
      final sb = zerlege(b, sendungsnummer: 7, nutzlastJeStueck: 200);

      final eingaenge = <Eingegangen>[];
      final abo = funk.eingang.listen(eingaenge.add);

      // Verschraenkt, wie es im Funk auch kaeme.
      await ereignis({'art': 'stueck', 'geraet': 'A', 'daten': sa[0]});
      await ereignis({'art': 'stueck', 'geraet': 'B', 'daten': sb[0]});
      await ereignis({'art': 'stueck', 'geraet': 'B', 'daten': sb[1]});
      await ereignis({'art': 'stueck', 'geraet': 'A', 'daten': sa[1]});
      await Future<void>.delayed(Duration.zero);
      await abo.cancel();

      expect(eingaenge, hasLength(2));
      expect(eingaenge.firstWhere((e) => e.geraet == 'A').umschlag, a);
      expect(eingaenge.firstWhere((e) => e.geraet == 'B').umschlag, b);
    });

    test('trennt sich eine Gegenstelle, ist ihr Angefangenes weg', () async {
      final u = Uint8List.fromList(List.filled(300, 1));
      final s = zerlege(u, sendungsnummer: 3, nutzlastJeStueck: 200);

      final eingaenge = <Eingegangen>[];
      final abo = funk.eingang.listen(eingaenge.add);

      await ereignis({'art': 'stueck', 'geraet': 'A', 'daten': s[0]});
      await ereignis({'art': 'gegenstelle', 'geraet': 'A', 'verbunden': false});
      // Das zweite Stueck kommt nach dem Trennen — es gehoert zu einer
      // Sendung, die es nicht mehr gibt, und darf keine halbe ergeben.
      await ereignis({'art': 'stueck', 'geraet': 'A', 'daten': s[1]});
      await Future<void>.delayed(Duration.zero);
      await abo.cancel();

      expect(eingaenge, isEmpty,
          reason: 'aus einem Rest darf kein Umschlag werden');
    });

    test('ein verdorbenes Haeppchen schreibt der Gegenstelle nichts an',
        () async {
      // Im Funk ist das Alltag. Wer daraufhin die Gegenstelle abschreibt,
      // macht aus einem Aussetzer einen Abbruch.
      final pannen = <String>[];
      final abo = funk.pannen.listen(pannen.add);
      await ereignis({
        'art': 'stueck', 'geraet': 'A',
        'daten': Uint8List.fromList([9, 9, 9]),  // zu kurz fuer einen Rahmen
      });
      await Future<void>.delayed(Duration.zero);
      await abo.cancel();
      expect(pannen.single, contains('verworfen'));

      // Und danach geht es normal weiter.
      final u = Uint8List.fromList(List.filled(50, 7));
      final s = zerlege(u, sendungsnummer: 1, nutzlastJeStueck: 200);
      final kommt = funk.eingang.first;
      await ereignis({'art': 'stueck', 'geraet': 'A', 'daten': s.single});
      expect((await kommt).umschlag, u);
    });
  });

  group('Senden', () {
    test('zerlegt und schickt in einem Zug', () async {
      await funk.sende('A', Uint8List.fromList(List.filled(300, 1)));
      final call = gerufen.singleWhere((c) => c.method == 'sende');
      expect(call.arguments['geraet'], 'A');
      expect(call.arguments['stuecke'], hasLength(1),
          reason: '300 Byte passen in ein Haeppchen von 500');
    });

    test('EIN ZU KLEINES MTU FUEHRT ZU GENAU EINEM ZWEITEN ANLAUF', () async {
      // Wie gross ein Haeppchen sein darf, steht erst nach dem Verbinden
      // fest. Der native Teil meldet die nutzbare Groesse zurueck, statt
      // stillschweigend abzuschneiden — abgeschnitten fiele es drueben als
      // Pruefsummenfehler auf und saehe nach einer verdorbenen Funkstrecke
      // aus.
      sendeFehler = PlatformException(code: 'FUNK', message: 'ZU_GROSS:100');
      await funk.sende('A', Uint8List.fromList(List.filled(300, 1)));

      final versuche = gerufen.where((c) => c.method == 'sende').toList();
      expect(versuche, hasLength(2));
      expect(versuche[0].arguments['stuecke'], hasLength(1));
      expect(versuche[1].arguments['stuecke'], hasLength(4),
          reason: '300 Byte bei 91 Byte Nutzlast je Stueck');
    });

    test('und beim naechsten Mal wird gleich richtig zerlegt', () async {
      sendeFehler = PlatformException(code: 'FUNK', message: 'ZU_GROSS:100');
      await funk.sende('A', Uint8List.fromList(List.filled(300, 1)));
      gerufen.clear();

      await funk.sende('A', Uint8List.fromList(List.filled(300, 1)));
      final versuche = gerufen.where((c) => c.method == 'sende').toList();
      expect(versuche, hasLength(1),
          reason: 'denselben Fehlschlag ein zweites Mal zu erzeugen waere '
              'eine verschenkte Verbindung');
      expect(versuche.single.arguments['stuecke'], hasLength(4));
    });

    test('das gemerkte Mass gilt je Geraet, nicht fuer alle', () async {
      sendeFehler = PlatformException(code: 'FUNK', message: 'ZU_GROSS:100');
      await funk.sende('A', Uint8List.fromList(List.filled(300, 1)));
      gerufen.clear();

      await funk.sende('B', Uint8List.fromList(List.filled(300, 1)));
      expect(gerufen.single.arguments['stuecke'], hasLength(1),
          reason: 'B hat nie etwas von einem kleinen MTU gesagt');
    });

    test('ein echter Fehler wird durchgereicht, nicht verschluckt', () async {
      sendeFehler = PlatformException(code: 'FUNK', message: 'weg');
      await expectLater(
        funk.sende('A', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FunkFehler>()),
      );
    });
  });

  test('der Zustand kommt vollstaendig an', () async {
    final z = await funk.zustand();
    expect(z.geht, isTrue);
    expect(z.jeWerbung, 40);
  });
}
