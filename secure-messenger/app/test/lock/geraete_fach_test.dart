// geraete_fach_test.dart — der eigene Weg in den gesicherten Bereich.
//
// WARUM ES DIESE DATEI GIBT
// flutter_secure_storage baut seinen Anmeldedialog mit dem
// Application-Context und meldet sich nie an der Activity an. Auf Samsung
// erscheint dabei regelmaessig gar kein Dialog — beim Antippen passiert
// NICHTS: kein Fingerabdruck, kein Fehler, kein Hinweis. Genau so wurde es am
// 25.07.2026 auf einem S25 Ultra gemeldet.
//
// Der eigene Kanal (android/.../SchluesselfachKanal.kt) laeuft ueber die echte
// Activity. Ob der Dialog dann wirklich kommt, zeigt erst das Geraet — pruefbar
// ist hier alles davor und danach: dass die richtige Art durchgereicht wird,
// dass ein Abbruch als Abbruch ankommt und nicht als Panne, und dass ein
// fehlendes Merkmal einen Grund im Klartext liefert statt eines Codes.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/lock/geraete_fach.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ein nachgebautes Geraet.
///
/// Es "verschluesselt" durch Umdrehen der Bytes — es geht hier nicht um
/// Krypto, sondern um den Weg hin und zurueck. Die echte Rechnung macht der
/// gesicherte Bereich des Geraets und laesst sich hier nicht nachbauen.
class FakeGeraet {
  final List<String> aufrufe = [];
  final List<String?> arten = [];

  bool verfuegbar = true;
  String? grund;
  String? fehlerCode;
  String fehlerText = 'kaputt';

  Future<Object?> handle(MethodCall aufruf) async {
    aufrufe.add(aufruf.method);
    final args = (aufruf.arguments as Map).cast<String, Object?>();
    arten.add(args['art'] as String?);

    if (aufruf.method == 'verfuegbar') {
      return <String, Object?>{'ok': verfuegbar, 'grund': grund, 'code': 0};
    }
    if (fehlerCode != null) {
      throw PlatformException(code: fehlerCode!, message: fehlerText);
    }
    return switch (aufruf.method) {
      'schreibe' => _drehe(args['wert']! as Uint8List),
      'lies' => _drehe(args['wert']! as Uint8List),
      'loesche' => true,
      _ => null,
    };
  }

  static Uint8List _drehe(Uint8List b) =>
      Uint8List.fromList(b.reversed.toList());
}

void main() {
  late Directory verzeichnis;
  late FakeGeraet geraet;
  late GeraeteFach fach;

  const kanal = MethodChannel('bitdm/test-schluesselfach');

  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  setUp(() {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-fach');
    geraet = FakeGeraet();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kanal, geraet.handle);
    fach = GeraeteFach(GeraeteArt.biometrie,
        verzeichnis: verzeichnis.path, kanal: kanal);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kanal, null);
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Hin und zurueck', () {
    test('was geschrieben wurde, kommt wieder heraus', () async {
      await fach.schreibe('kek', 'geheim-1234');
      expect(await fach.lies('kek'), 'geheim-1234');
    });

    test('was nie geschrieben wurde, ist null — kein Fehler', () async {
      expect(await fach.lies('gibtsnicht'), isNull);
      expect(geraet.aufrufe, isEmpty,
          reason: 'ohne Datei gibt es nichts zu entschluesseln — dafuer soll '
              'kein Anmeldedialog erscheinen');
    });

    test('der Klartext steht NICHT in der Datei', () async {
      await fach.schreibe('kek', 'geheim-1234');
      final dateien = verzeichnis.listSync().whereType<File>();
      for (final d in dateien) {
        expect(utf8.decode(d.readAsBytesSync(), allowMalformed: true),
            isNot(contains('geheim-1234')));
      }
    });
  });

  group('Die Art wird durchgereicht', () {
    test('Biometrie und Geraetesperre kommen unterschiedlich an', () async {
      await fach.schreibe('a', 'x');
      expect(geraet.arten, everyElement('biometrie'));

      final pin = GeraeteFach(GeraeteArt.geraetesperre,
          verzeichnis: verzeichnis.path, kanal: kanal);
      geraet.arten.clear();
      await pin.schreibe('b', 'y');
      expect(geraet.arten, everyElement('geraetesperre'),
          reason: 'sonst benutzen beide denselben Schluessel im Geraet — und '
              'es waeren keine zwei Faktoren, sondern einer mit zwei Namen');
    });
  });

  group('Was schiefgehen kann', () {
    test('VORHER gefragt: ohne Fingerabdruck gibt es einen Grund im Klartext',
        () async {
      geraet
        ..verfuegbar = false
        ..grund = 'Es ist kein Fingerabdruck hinterlegt.';

      final stand = await fach.verfuegbar();
      expect(stand.ok, isFalse);
      expect(stand.grund, 'Es ist kein Fingerabdruck hinterlegt.',
          reason: 'ohne diesen Text steht der Nutzer vor einer Zeile, die '
              'nichts tut, und erfaehrt nie warum');
    });

    test('ein Abbruch ist ein Abbruch, keine Panne', () async {
      // Wichtig fuer die Oberflaeche: wer selbst abbricht, soll keine rote
      // Fehlermeldung sehen. Das ist eine Entscheidung, kein Fehler.
      geraet
        ..fehlerCode = 'ABGEBROCHEN'
        ..fehlerText = 'Vom Nutzer abgebrochen';

      await expectLater(
          fach.schreibe('kek', 'x'),
          throwsA(isA<AnmeldungFehlgeschlagen>()
              .having((e) => e.abgebrochen, 'abgebrochen', isTrue)));
    });

    test('ein fehlendes Merkmal meldet sich als solches', () async {
      geraet
        ..fehlerCode = 'NICHT_VERFUEGBAR'
        ..fehlerText = 'Keine Bildschirmsperre eingerichtet';

      await expectLater(fach.schreibe('kek', 'x'),
          throwsA(isA<GeraetKannNicht>()));
    });

    test('ein sonstiger Fehler kommt mit Text an, nicht stumm', () async {
      // DER FEHLER, DEN DAS ABFAENGT: eine Meldung, die unterwegs verloren
      // geht. Am 25.07.2026 landeten Fehler in einer Variablen, die der
      // Bildschirm nie anzeigte — und das Antippen sah aus wie nichts.
      geraet
        ..fehlerCode = 'ANMELDUNG'
        ..fehlerText = 'Zu viele Fehlversuche';

      await expectLater(
          fach.schreibe('kek', 'x'),
          throwsA(isA<AnmeldungFehlgeschlagen>()
              .having((e) => e.grund, 'grund', 'Zu viele Fehlversuche')
              .having((e) => e.abgebrochen, 'abgebrochen', isFalse)));
    });

    test('eine App ohne den Kanal sagt das, statt zu haengen', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kanal, null);
      expect((await fach.verfuegbar()).ok, isFalse);
      await expectLater(
          fach.schreibe('kek', 'x'), throwsA(isA<GeraetKannNicht>()));
    });
  });

  group('Aufraeumen', () {
    test('Loeschen nimmt Datei UND Schluessel im Geraet mit', () async {
      await fach.schreibe('kek', 'x');
      expect(verzeichnis.listSync(), isNotEmpty);

      await fach.loesche('kek');

      expect(verzeichnis.listSync(), isEmpty);
      expect(geraet.aufrufe, contains('loesche'),
          reason: 'ein Schluessel im gesicherten Bereich, der zu nichts mehr '
              'gehoert, ist beim Panik-Loeschen genau das, was uebrig bleiben '
              'wuerde');
    });

    test('Loeschen verlangt KEINE Anmeldung', () async {
      await fach.schreibe('kek', 'x');
      geraet
        ..fehlerCode = 'ANMELDUNG'
        ..fehlerText = 'abgebrochen';

      // Darf NICHT werfen: einen Schluessel wegzuwerfen macht Daten unlesbar,
      // es liest keine. Waere eine Anmeldung noetig, koennte ein abgebrochener
      // Fingerabdruck das Aufraeumen verhindern.
      await fach.loesche('kek');
      expect(verzeichnis.listSync(), isEmpty);
    });
  });
}
