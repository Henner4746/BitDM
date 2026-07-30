// native_krypto_test.dart — der Weg ueber den Kanal und zurueck.
//
// WAS HIER GEPRUEFT WIRD UND WAS NICHT
// NICHT die Verschluesselung selbst — die rechnet javax.crypto, und dass sie
// bitgleich zu Dart ist, prueft ein JVM-Test in Kotlin gegen erzeugte
// Vektoren (android/app/src/test/.../StueckchiffreTest.kt). Ein Dart-Test
// koennte dort nur eine Attrappe befragen und wuerde nichts aussagen.
//
// WOHL ABER die Entscheidung, WANN welcher Weg genommen wird. Genau da sitzen
// die Fehler, die im Betrieb wehtun:
//   * still im langsamen Weg landen, ohne dass es jemand erfaehrt
//   * bei jedem Stueck erneut in denselben Fehler laufen
//   * ein kaputtes Stueck als Kanalfehler missverstehen und deshalb dauerhaft
//     auf Dart zurueckfallen — fuer einen Fehler, der gar keiner ist

import 'dart:typed_data';

import 'package:bitdm/core/anhang/native_krypto.dart';
import 'package:bitdm/core/anhang/stueck_krypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Zaehlt mit, wer wie oft gerufen wurde.
class ZaehlendeDartKrypto extends StueckKrypto {
  ZaehlendeDartKrypto();

  final echt = const GcmStueckKrypto();
  int zu = 0, auf = 0;

  @override
  Future<Uint8List> verschluessle({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) {
    zu++;
    return echt.verschluessle(
        klar: klar,
        schluessel: schluessel,
        nonce: nonce,
        nummer: nummer,
        vonWievielen: vonWievielen);
  }

  @override
  Future<Uint8List> entschluessle({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) {
    auf++;
    return echt.entschluessle(
        geheim: geheim,
        schluessel: schluessel,
        nonce: nonce,
        nummer: nummer,
        vonWievielen: vonWievielen);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kanal = MethodChannel('bitdm/krypto');
  final werkzeug = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final klar = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
  final schluessel = Uint8List.fromList(List.generate(32, (i) => i * 3 & 0xFF));
  final nonce = Uint8List.fromList(List.generate(12, (i) => i * 5 & 0xFF));

  /// Setzt einen Kanal ein, der sich so verhaelt wie angegeben.
  void kanalAntwortet(Future<Object?>? Function(MethodCall) tun) {
    werkzeug.setMockMethodCallHandler(kanal, tun);
  }

  tearDown(() => werkzeug.setMockMethodCallHandler(kanal, null));

  group('Wenn es den Kanal gibt', () {
    test('wird er benutzt und Dart bleibt unangetastet', () async {
      final dart = ZaehlendeDartKrypto();
      var nativGerufen = 0;
      kanalAntwortet((a) async {
        if (a.method == 'verfuegbar') return 'AndroidOpenSSL';
        nativGerufen++;
        // Der echte Kanal rechnet; hier reicht etwas Erkennbares.
        return Uint8List.fromList([1, 2, 3]);
      });

      final k = NativeStueckKrypto(rueckfall: dart);
      final aus = await k.verschluessle(
          klar: klar,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);

      expect(aus, [1, 2, 3]);
      expect(nativGerufen, 1);
      expect(dart.zu, 0, reason: 'Dart darf gar nicht erst gefragt werden');
      expect(k.imRueckfall, isNull);
    });

    test('DER ZUSATZ GEHT MIT — sonst waere die Bindung an die Stuecknummer weg',
        () async {
      // Ohne den Zusatz koennte das Lager unter der Kennung von Stueck 3 die
      // Bytes von Stueck 5 ausliefern, und es ginge sauber auf.
      Uint8List? gesehen;
      kanalAntwortet((a) async {
        if (a.method == 'verfuegbar') return 'AndroidOpenSSL';
        gesehen = (a.arguments as Map)['zusatz'] as Uint8List;
        return Uint8List(0);
      });

      await NativeStueckKrypto().verschluessle(
          klar: klar,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 3,
          vonWievielen: 6);

      expect(String.fromCharCodes(gesehen!), 'bitdm-stueck:3/6');
    });

    test('EIN KAPUTTES STUECK KIPPT DEN KANAL NICHT', () async {
      // Der wichtigste Fall dieser Datei. Ein Stueck, das nicht aufgeht, ist
      // die richtige Antwort auf verdorbene Daten — kein Grund, den schnellen
      // Weg fuer den Rest der Sitzung aufzugeben.
      //
      // Erkannt wird er am FEHLERCODE. Der Kanal schickt "KAPUTT" fuer eine
      // AEADBadTagException und "KRYPTO" fuer alles andere; die Java-Meldung
      // selbst kommt gar nicht mehr herueber.
      final dart = ZaehlendeDartKrypto();
      kanalAntwortet((a) async {
        if (a.method == 'verfuegbar') return 'AndroidOpenSSL';
        throw PlatformException(code: 'KAPUTT');
      });

      final k = NativeStueckKrypto(rueckfall: dart);
      await expectLater(
        k.entschluessle(
            geheim: klar,
            schluessel: schluessel,
            nonce: nonce,
            nummer: 0,
            vonWievielen: 1),
        throwsA(isA<StueckKaputt>()),
      );

      expect(dart.auf, 0, reason: 'nicht noch einmal langsam nachrechnen');
      expect(k.imRueckfall, isNull, reason: 'der Kanal ist in Ordnung');
    });
  });

  group('Wenn es den Kanal nicht gibt', () {
    test('rechnet Dart, und es steht irgendwo', () async {
      final dart = ZaehlendeDartKrypto();
      // Kein Handler gesetzt: genau die Lage auf einer Plattform ohne den
      // nativen Teil.
      final k = NativeStueckKrypto(rueckfall: dart);

      final geheim = await k.verschluessle(
          klar: klar,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);

      expect(dart.zu, 1);
      expect(k.imRueckfall, isNotNull);
      expect(k.imRueckfall, contains('kein nativer Kanal'));

      // Und das Ergebnis ist brauchbar, nicht nur vorhanden.
      final wieder = await k.entschluessle(
          geheim: geheim,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 0,
          vonWievielen: 1);
      expect(wieder, klar);
    });

    test('wird nicht bei jedem Stueck erneut gefragt', () async {
      var gefragt = 0;
      kanalAntwortet((a) async {
        if (a.method == 'verfuegbar') {
          gefragt++;
          return null;
        }
        return null;
      });

      final k = NativeStueckKrypto(rueckfall: ZaehlendeDartKrypto());
      for (var i = 0; i < 5; i++) {
        await k.verschluessle(
            klar: klar,
            schluessel: schluessel,
            nonce: nonce,
            nummer: i,
            vonWievielen: 5);
      }
      expect(gefragt, 1, reason: 'einmal fragen reicht');
    });
  });

  group('Wenn der Kanal mittendrin aufgibt', () {
    test('uebernimmt Dart AB DANN, ohne es erneut zu versuchen', () async {
      // Bei 32 MiB je Aufruf ist ein Speicherfehler kein hypothetischer Fall.
      // Es hundertmal zu wiederholen hiesse, hundertmal 32 MiB anzufordern.
      final dart = ZaehlendeDartKrypto();
      var nativVersuche = 0;
      kanalAntwortet((a) async {
        if (a.method == 'verfuegbar') return 'AndroidOpenSSL';
        nativVersuche++;
        throw PlatformException(code: 'KRYPTO', message: 'OutOfMemoryError');
      });

      final k = NativeStueckKrypto(rueckfall: dart);
      for (var i = 0; i < 4; i++) {
        await k.verschluessle(
            klar: klar,
            schluessel: schluessel,
            nonce: nonce,
            nummer: i,
            vonWievielen: 4);
      }

      expect(nativVersuche, 1, reason: 'einmal scheitern reicht');
      expect(dart.zu, 4);
      expect(k.imRueckfall, contains('OutOfMemoryError'));
    });

    test('und was schon nativ verschluesselt war, liest Dart weiter', () async {
      // Die Zusicherung, ohne die der Rueckfall wertlos waere: beide
      // Fassungen liefern Chiffretext gefolgt vom 16-Byte-Tag. Hier wird das
      // von der Dart-Seite aus geprueft — die Gegenrichtung prueft
      // StueckchiffreTest.kt gegen dieselben Vektoren.
      const dart = GcmStueckKrypto();
      final geheim = await dart.verschluessle(
          klar: klar,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 2,
          vonWievielen: 7);

      expect(geheim.length, klar.length + 16,
          reason: 'Chiffretext plus 16 Byte Tag, sonst nichts');

      // Ein Kanal, der genau das zurueckgibt, was javax.crypto liefert:
      // dieselben Bytes. Der Rueckfall muss sie lesen koennen.
      kanalAntwortet((a) async => a.method == 'verfuegbar' ? 'AndroidOpenSSL' : null);
      final k = NativeStueckKrypto();
      final wieder = await k.entschluessle(
          geheim: geheim,
          schluessel: schluessel,
          nonce: nonce,
          nummer: 2,
          vonWievielen: 7);
      expect(wieder, klar);
    });
  });
}
