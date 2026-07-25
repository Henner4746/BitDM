// anhang_end_to_end_test.dart — eine Datei von einem Kern zum anderen.
//
// KEIN NACHBAU AUF BEIDEN SEITEN. Dieser Test startet relay_server.py UND
// blob_server.py als echte Prozesse und laesst zwei vollstaendige
// RealMessengerCore darueber eine Datei austauschen: eigene Seed-Phrase,
// eigene verschluesselte Datenbank, X3DH, Double Ratchet, Marke, Upload,
// Anleitung als Nachricht, Download, Zusammensetzen, Pruefsumme.
//
// DER GRUND FUER DEN AUFWAND steht in der Projektgeschichte und wiederholt
// sich hier an einer neuen Stelle: zwischen Relay und Lager liegt ein HMAC
// ueber "kennung|groesse|ablauf", ausgerechnet von zwei Programmen in zwei
// Sprachen. Weicht das Format um ein Zeichen ab, laufen Nachrichten weiter
// und nur Anhaenge scheitern — mit 403 und ohne einen Hinweis darauf, woran
// es liegt. Ein Dart-Nachbau des Lagers wuerde genau diese Stelle
// ueberspringen.
//
// Wird uebersprungen, wenn Python oder die Abhaengigkeiten fehlen — sagt das
// aber laut, statt still durchzurutschen.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/lager_client.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/lager_process.dart';
import '../support/relay_process.dart';

/// Ein Geheimspeicher im Arbeitsspeicher — auf dem Testrechner gibt es keinen
/// Android-Schluesselspeicher.
class SpeicherImKopf implements SecretStore {
  Uint8List? _inhalt;
  @override
  Future<Uint8List?> read() async => _inhalt;
  @override
  Future<void> write(Uint8List e) async => _inhalt = e;
  @override
  Future<void> delete() async => _inhalt = null;
}

Future<File> dateiMit(Directory ordner, int bytes, String name) async {
  final zufall = Random(7);
  final f = File('${ordner.path}${Platform.pathSeparator}$name');
  final s = f.openWrite();
  const block = 65536;
  for (var g = 0; g < bytes; g += block) {
    final n = min(block, bytes - g);
    s.add(Uint8List.fromList(List.generate(n, (_) => zufall.nextInt(256))));
  }
  await s.close();
  return f;
}

void main() {
  late Relay? relay;
  late Lager? lager;
  late Directory ordner;

  setUpAll(() async {
    lager = await Lager.starten();
    relay = await Relay.starten(blobGeheimnis: Lager.geheimnis);
  });

  tearDownAll(() async {
    await relay?.beenden();
    await lager?.beenden();
  });

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-e2e-anhang');
  });

  tearDown(() async {
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  test('Relay UND Lager laufen — sonst sagen die folgenden Tests nichts aus',
      () {
    expect(relay, isNotNull,
        reason: 'relay_server.py liess sich nicht starten (Python? uvicorn?)');
    expect(lager, isNotNull,
        reason: 'blob_server.py liess sich nicht starten');
  });

  group('ueber Relay UND Lager', () {
    late RealMessengerCore alice;
    late RealMessengerCore bob;

    /// Ein Kern mit eigener Identitaet und eigener Datenbank.
    ///
    /// Das Lager wird ueberschrieben: [RealMessengerCore.lagerAdresse] leitet
    /// im Betrieb relay.bitdm.net → dateien.bitdm.net ab, und hier laufen
    /// beide auf 127.0.0.1 mit verschiedenen Ports.
    Future<RealMessengerCore> kern(String name) async {
      final k = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}$name.db',
        relayUri: relay!.uri,
        lagerUri: lager!.uri,
      );
      await k.initialize();
      await k.createIdentity();
      await k.connect();
      return k;
    }

    setUp(() async {
      if (relay == null || lager == null) return;
      alice = await kern('alice');
      bob = await kern('bob');

      // EINE RICHTUNG NACH DER ANDEREN, und jeder Schritt abgewartet.
      //
      // Der erste Entwurf liess BEIDE Seiten gleichzeitig addContact und
      // acceptRequest aufrufen. Das ist der Kreuzungsfall: zwei
      // PreKeySignalMessages unterwegs, zwei halbfertige Sitzungen, und in
      // etwa jedem dritten Lauf ein "kein Prekey mit der Nummer 1" — der
      // Einmal-Prekey war schon verbraucht, als die zweite Nachricht ankam.
      //
      // Das ist kein Fehler im Anhang-Weg, sondern einer im Testaufbau: so
      // laeuft es in der App nie. Dort schickt einer eine Anfrage und der
      // andere nimmt sie an.
      final anfrageBeiBob = bob.contactEvents
          .firstWhere((e) => e.type == ContactEventType.incomingRequest);
      await alice.addContact(bob.myId);
      await anfrageBeiBob.timeout(const Duration(seconds: 20));

      final zusageBeiAlice = alice.contactEvents
          .firstWhere((e) => e.type == ContactEventType.requestAccepted);
      await bob.acceptRequest(alice.myId);
      await zusageBeiAlice.timeout(const Duration(seconds: 20));
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
    });

    test('DER DURCHSTICH: Alice schickt eine Datei, Bob holt sie', () async {
      if (relay == null || lager == null) return;
      final quelle = await dateiMit(ordner, 300000, 'urlaub.zip');
      final vorher = await quelle.readAsBytes();

      final angekommen = bob.incomingMessages.first;
      final gesendet = await alice.sendeAnhang(bob.myId, quelle);

      expect(gesendet.kind, MessageKind.anhang);
      expect(gesendet.text, 'urlaub.zip');
      expect(await lager!.anzahlBloecke(), greaterThan(0),
          reason: 'die Stuecke muessen wirklich im Lager liegen');

      // Bei Bob ist der Anhang ANGEKUENDIGT, nicht da. Ihn ungefragt zu holen
      // waere ein Griff in fremdes Datenvolumen.
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));
      expect(beiBob.kind, MessageKind.anhang);
      expect(beiBob.text, 'urlaub.zip');

      final vorm = (await bob.getAnhaenge(alice.myId))[beiBob.id]!;
      expect(vorm.zustand, AnhangZustand.angekuendigt);
      expect(vorm.groesse, 300000);
      expect(vorm.pfad, isNull);

      // Jetzt holen.
      final fertig = await bob.holeAnhang(alice.myId, beiBob.id);
      expect(fertig.zustand, AnhangZustand.da);
      expect(await File(fertig.pfad!).readAsBytes(), vorher,
          reason: 'bytegleich, ueber zwei Kerne, zwei Server und die '
              'Signal-Sitzung dazwischen');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('nach dem Holen ist das Lager wieder leer', () async {
      if (relay == null || lager == null) return;
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 50000, 'klein.bin'));
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));

      await bob.holeAnhang(alice.myId, beiBob.id);

      // Wegwerfen laeuft ohne Warten — kurz Zeit lassen.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await lager!.anzahlBloecke(), 0,
          reason: 'was abgeholt ist, hat im Lager nichts mehr verloren');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('ZWEIMAL HOLEN GEHT NICHT SCHIEF', () async {
      if (relay == null || lager == null) return;
      // Nach dem ersten Holen sind die Bloecke weg. Ein zweiter Aufruf darf
      // deshalb NICHT noch einmal ins Lager greifen — er muss die Datei
      // zurueckgeben, die schon dasteht.
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 50000, 'klein.bin'));
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));

      final erst = await bob.holeAnhang(alice.myId, beiBob.id);
      await Future<void>.delayed(const Duration(seconds: 1));
      final nochmal = await bob.holeAnhang(alice.myId, beiBob.id);

      expect(nochmal.zustand, AnhangZustand.da);
      expect(nochmal.pfad, erst.pfad);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('DER FORTSCHRITT KOMMT WAEHRENDDESSEN, nicht erst am Schluss',
        () async {
      if (relay == null || lager == null) return;
      final staende = <AnhangFortschritt>[];
      final abo = alice.anhangFortschritt.listen(staende.add);

      await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 400000, 'gross.bin'));
      await abo.cancel();

      expect(staende, isNotEmpty);
      expect(staende.last.fertigeBytes, 400000);
      expect(staende.last.anteil, 1.0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EINE VERFALLENE NACHRICHT NIMMT IHRE DATEI MIT', () async {
      if (relay == null || lager == null) return;
      // Der Punkt, an dem die Verfallsfrist steht oder faellt. Verschwindet
      // die Nachricht aus der Unterhaltung und die zwei Gigabyte bleiben im
      // Speicher des Telefons, ist die Zusage gebrochen — und wer glaubt,
      // seine Nachrichten verschwinden, schreibt Dinge, die er sonst nicht
      // schriebe.
      //
      // Geprueft wird auf BOBS Seite: die Lebensdauer reist vom Absender mit,
      // und die geholte Datei ist die, die wirklich Platz belegt.
      await alice.setPreferences(
          const AppPreferences(messageLifetime: Duration(seconds: 1)));

      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 40000, 'verfaellt.bin'));
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));

      final geholt = await bob.holeAnhang(alice.myId, beiBob.id);
      final datei = File(geholt.pfad!);
      expect(await datei.exists(), isTrue);

      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await bob.purgeExpiredMessages(), greaterThan(0));

      expect(await datei.exists(), isFalse,
          reason: 'die Datei muss mit der Nachricht verschwinden, nicht nur '
              'ihr Eintrag in der Datenbank');
      expect(await bob.getAnhaenge(alice.myId), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EIN GELOESCHTER BLOCK MELDET SICH ALS "WEG", nicht als Fehler',
        () async {
      if (relay == null || lager == null) return;
      // Nach vierzehn Tagen raeumt die Kehrmaschine auf. Die Oberflaeche muss
      // darauf etwas anderes sagen als bei einem Netzfehler — "noch einmal
      // versuchen" waere hier eine Luege.
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 50000, 'klein.bin'));
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));

      // Von Hand wegraeumen, so wie es die Kehrmaschine taete.
      for (final f in lager!.verzeichnis.listSync()) {
        if (f is File) f.deleteSync();
      }

      await expectLater(bob.holeAnhang(alice.myId, beiBob.id),
          throwsA(isA<LagerLeer>()));
      final e = (await bob.getAnhaenge(alice.myId))[beiBob.id]!;
      expect(e.zustand, AnhangZustand.weg);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
