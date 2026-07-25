// push_test.dart — angestossen werden, ohne Google.
//
// WAS HIER GEPRUEFT WIRD
// Der Weg des Endpunkts: der Verteiler auf dem Telefon nennt ihn, die App
// prueft ihn, der Relay bekommt ihn. Zwei Stellen darin sind heikel:
//
//   1. Ein Endpunkt auf einem FREMDEN Server darf nicht durchgereicht werden.
//      Der Relay lehnte ihn zwar ohnehin ab — aber dann stuende in der App
//      "Push ist an", waehrend nie ein Anstoss kaeme.
//
//   2. Der Endpunkt KANN SICH AENDERN. ntfy vergibt nach einer
//      Neuinstallation ein neues Thema. Wer den alten beim Relay stehen
//      laesst, wird nie wieder angestossen und merkt es nicht.
//
// Der Verteiler selbst laesst sich hier nicht nachbauen — er ist eine andere
// App auf demselben Telefon. Geprueft wird alles davor und danach.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/empfang.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/push.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i));
  @override
  Future<Uint8List?> read() async => inhalt;
  @override
  Future<void> write(Uint8List e) async => inhalt = e;
  @override
  Future<void> delete() async => inhalt = null;
}

class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};
  @override
  Future<String?> lies(String k) async => daten[k];
  @override
  Future<void> schreibe(String k, String v) async => daten[k] = v;
  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

void main() {
  group('Welche Endpunkte angenommen werden', () {
    test('der eigene Push-Server, ja', () {
      expect(
          PushAnbindung.eigenerServer('https://push.bitdm.net/upAbc123_-xyz'),
          isTrue);
    });

    test('ein FREMDER Server, nein', () {
      // Der Relay lehnt ihn ohnehin ab — aber dann stuende in der App "Push
      // ist an", waehrend nie ein Anstoss kaeme. Hier faellt es frueher auf,
      // und die Meldung kann sagen, warum.
      expect(PushAnbindung.eigenerServer('https://evil.example.com/upAbc123'),
          isFalse);
    });

    test('ohne TLS, nein', () {
      expect(PushAnbindung.eigenerServer('http://push.bitdm.net/upAbc123'),
          isFalse);
    });

    test('ein anderer Pfad auf dem eigenen Server, nein', () {
      expect(
          PushAnbindung.eigenerServer('https://push.bitdm.net/admin'), isFalse);
    });

    test('Unsinn, nein', () {
      for (final u in ['', 'nicht mal eine Adresse', 'ftp://x/upA']) {
        expect(PushAnbindung.eigenerServer(u), isFalse, reason: 'bei "$u"');
      }
    });
  });

  group('Der Weg des Endpunkts', () {
    late Directory verzeichnis;
    late FakeMessengerCore core;
    late AppState st;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('bitdm/fenster'), (_) async => null);
    });

    setUp(() async {
      verzeichnis = Directory.systemTemp.createTempSync('bitdm-push');
      core = FakeMessengerCore()..simulateExistingIdentity = true;
      st = AppState(
        core,
        tresor: VaultSecretStore(
            datei: vaultDateiIn(verzeichnis.path),
            basis: FakeBasis(),
            jetzt: () => 1000),
        ablagen: (_) => FakeAblage(),
      )..empfangsDienst = null;
      await st.boot();
    });

    tearDown(() {
      st.dispose();
      core.dispose();
      try {
        verzeichnis.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('DER DURCHGANG: genannt, geprueft, beim Relay eingetragen', () async {
      await st.nimmPushEndpunkt('https://push.bitdm.net/upAbc123');

      expect(st.pushEndpunkt, 'https://push.bitdm.net/upAbc123');
      expect(core.pushEndpunkt, 'https://push.bitdm.net/upAbc123',
          reason: 'ohne diesen Schritt weiss der Relay nicht, wohin er '
              'anstossen soll — und Push ist wirkungslos, ohne dass es '
              'auffaellt');
    });

    test('ein fremder Endpunkt kommt NICHT beim Relay an', () async {
      await st.nimmPushEndpunkt('https://evil.example.com/upAbc123');

      expect(st.pushEndpunkt, isNull);
      expect(core.pushEndpunkt, isNull);
      expect(st.letzterFehler, contains('fremdem Server'));
    });

    test('ein NEUER Endpunkt ersetzt den alten', () async {
      // ntfy vergibt nach einer Neuinstallation ein neues Thema. Bliebe der
      // alte stehen, kaeme nie wieder ein Anstoss — und niemand merkte es.
      await st.nimmPushEndpunkt('https://push.bitdm.net/upAlt');
      await st.nimmPushEndpunkt('https://push.bitdm.net/upNeu');

      expect(core.pushEndpunkt, 'https://push.bitdm.net/upNeu');
    });
  });

  group('Die Auswahl', () {
    test('Anstoss ist eine eigene Stufe mit eigener Zahl', () {
      expect(EmpfangsTakt.push.minuten, -2);
      final zahlen = EmpfangsTakt.values.map((t) => t.minuten).toList();
      expect(zahlen.toSet(), hasLength(zahlen.length));
    });

    test('Anstoss braucht KEINEN laufenden Dienst', () {
      // Das ist der ganze Vorteil: kein Vordergrunddienst, keine dauerhafte
      // Benachrichtigung, kein Akkuverbrauch.
      expect(EmpfangsTakt.push.angestossen, isTrue);
      expect(EmpfangsTakt.push.dauerhaft, isFalse);
      expect(EmpfangsTakt.push.imTakt, isFalse);
    });

    test('gespeichert und wieder gelesen ergibt dieselbe Stufe', () {
      expect(EmpfangsTakt.vonMinuten(-2), EmpfangsTakt.push);
    });
  });
}
