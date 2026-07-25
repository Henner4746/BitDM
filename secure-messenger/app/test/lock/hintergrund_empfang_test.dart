// hintergrund_empfang_test.dart — Empfangen, waehrend die App zu ist.
//
// DER PUNKT, UM DEN SICH ALLES DREHT
// Der Relay antwortet nur auf eine Unterschrift mit dem Identitaetsschluessel.
// Der entsteht aus der Entropie — und die liegt bei eingeschalteter Sperre in
// einem Fach, das ohne Faktor zu ist. Daraus folgt etwas, das sich nicht
// wegprogrammieren laesst: eine gesperrte App kann nichts empfangen. Auch
// nicht "nur zaehlen", auch nicht "nur benachrichtigen".
//
// Das ist keine fehlende Funktion, sondern die Kehrseite genau der Sperre, die
// gewuenscht war. Diese Tests halten fest, dass die App es auch so behandelt:
// sie startet keinen Dienst, der nichts ausrichten kann, und sie sagt es dem
// Nutzer, statt eine dauerhafte Benachrichtigung anzuzeigen, hinter der nichts
// steht.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/empfang.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
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

/// Ein Vordergrunddienst, der mitzaehlt statt zu laufen.
class FakeDienst implements EmpfangsDienst {
  int gestartet = 0;
  int gestoppt = 0;
  bool _laeuft = false;

  @override
  bool get laeuft => _laeuft;

  @override
  Future<void> starte({required String titel, required String text}) async {
    gestartet++;
    _laeuft = true;
  }

  @override
  Future<void> stoppe() async {
    gestoppt++;
    _laeuft = false;
  }
}

void main() {
  late Directory verzeichnis;
  late VaultSecretStore tresor;
  late FakeAblage ablage;
  late FakeDienst dienst;
  late FakeMessengerCore core;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-empfang');
    ablage = FakeAblage();
    dienst = FakeDienst();
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: FakeBasis(),
      jetzt: () => 1000,
    );
    core = FakeMessengerCore()..simulateExistingIdentity = true;
    st = AppState(core, tresor: tresor, ablagen: (_) => ablage)
      ..empfangsDienst = dienst;
    await st.boot();
  });

  tearDown(() {
    st.dispose();
    core.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Ab Werk', () {
    test('ist der Hintergrundempfang AUS', () {
      // Ein Dienst mit dauerhafter Benachrichtigung, den niemand bestellt hat,
      // waere eine Zumutung. Wer ihn will, schaltet ihn ein.
      expect(st.empfangsTakt, EmpfangsTakt.aus);
    });

    test('laeuft beim Weglegen kein Dienst', () async {
      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.gestartet, 0);
    });
  });

  group('Eingeschaltet, ohne Sperre', () {
    setUp(() async => st.setzeEmpfangsTakt(EmpfangsTakt.staendig));

    test('startet der Dienst beim Weglegen', () async {
      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.gestartet, 1);
      expect(dienst.laeuft, isTrue);
    });

    test('und endet beim Zurueckkommen', () async {
      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.gestoppt, 1);
      expect(dienst.laeuft, isFalse,
          reason: 'im Vordergrund braucht es ihn nicht — eine dauerhafte '
              'Benachrichtigung neben der offenen App waere nur Laerm');
    });

    test('Ausschalten beendet einen laufenden Dienst sofort', () async {
      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.laeuft, isTrue);

      await st.setzeEmpfangsTakt(EmpfangsTakt.aus);
      expect(dienst.laeuft, isFalse);
    });
  });

  group('DER WIDERSPRUCH: Sperre gegen Hintergrundempfang', () {
    test('mit Sperrfrist SOFORT ist Empfang unmoeglich — und die App weiss das',
        () async {
      await st.fuegeBiometrieHinzu();
      await st.setzeSperrfrist(0);
      await st.setzeEmpfangsTakt(EmpfangsTakt.staendig);

      expect(st.empfangMoeglich, isFalse,
          reason: 'die Entropie ist beim Weglegen weg, und ohne sie gibt es '
              'keinen Identitaetsschluessel — der Relay antwortet dann nicht '
              'einmal auf die Frage, ob etwas anliegt');

      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.gestartet, 0,
          reason: 'ein Dienst mit dauerhafter Benachrichtigung, der nichts '
              'ausrichten kann, ist schlimmer als keiner: er behauptet '
              'Empfangsbereitschaft, die es nicht gibt');
    });

    test('mit laengerer Sperrfrist geht es', () async {
      await st.fuegeBiometrieHinzu();
      await st.setzeSperrfrist(300);
      await st.setzeEmpfangsTakt(EmpfangsTakt.staendig);

      expect(st.empfangMoeglich, isTrue);
      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.gestartet, 1);
    });

    test('mit "nie sperren" geht es auch', () async {
      await st.fuegeBiometrieHinzu();
      await st.setzeSperrfrist(-1);
      await st.setzeEmpfangsTakt(EmpfangsTakt.staendig);

      expect(st.empfangMoeglich, isTrue);
    });

    test('eine gesperrte App startet keinen Dienst', () async {
      await st.fuegeBiometrieHinzu();
      await st.setzeSperrfrist(300);
      await st.setzeEmpfangsTakt(EmpfangsTakt.staendig);
      await st.sperreWieder();

      expect(st.gesperrt, isTrue);
      expect(st.empfangMoeglich, isFalse);

      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.gestartet, 0);
    });

    test('ohne Identitaet gibt es nichts zu empfangen', () async {
      final leer = AppState(FakeMessengerCore(), tresor: tresor)
        ..empfangsDienst = FakeDienst();
      await leer.boot();
      await leer.setzeEmpfangsTakt(EmpfangsTakt.staendig);
      expect(leer.empfangMoeglich, isFalse);
      leer.dispose();
    });
  });

  group('Der Takt bleibt erhalten', () {
    test('ueber einen Neustart hinweg', () async {
      await st.setzeEmpfangsTakt(EmpfangsTakt.viertelstunde);

      final frisch = AppState(
        FakeMessengerCore()..simulateExistingIdentity = true,
        tresor: VaultSecretStore(
            datei: vaultDateiIn(verzeichnis.path),
            basis: FakeBasis(),
            jetzt: () => 2000),
        ablagen: (_) => ablage,
      )..empfangsDienst = FakeDienst();
      await frisch.boot();

      expect(frisch.empfangsTakt, EmpfangsTakt.viertelstunde);
      frisch.dispose();
    });

    test('auch wenn danach ein Faktor dazukommt', () async {
      // Der Takt steht in derselben Datei wie die Faecher. Wer ihn vor dem
      // ersten Faktor einstellt, soll ihn danach nicht verlieren.
      await st.setzeEmpfangsTakt(EmpfangsTakt.stunde);
      await st.fuegeBiometrieHinzu();

      final v = await tresor.faecher();
      expect(v?.empfangsTaktMinuten, 60);
    });
  });

  group('Die Auswahl selbst', () {
    test('jede Stufe hat eine eigene Zahl', () {
      final zahlen = EmpfangsTakt.values.map((t) => t.minuten).toList();
      expect(zahlen.toSet(), hasLength(zahlen.length),
          reason: 'zwei Stufen mit derselben Zahl liessen sich nicht '
              'auseinanderhalten — gespeichert wird die Zahl');
    });

    test('was gespeichert wurde, kommt als dieselbe Stufe zurueck', () {
      for (final t in EmpfangsTakt.values) {
        expect(EmpfangsTakt.vonMinuten(t.minuten), t);
      }
    });

    test('eine unbekannte Zahl faellt auf AUS zurueck, nicht auf staendig', () {
      // Wichtig bei einer Fachdatei aus einer neueren Fassung: im Zweifel
      // nichts tun, statt ungefragt einen Dienst zu starten.
      expect(EmpfangsTakt.vonMinuten(999), EmpfangsTakt.aus);
    });
  });
}
