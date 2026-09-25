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
import 'package:bitdm/core/anhang/ruhe_datei.dart';
import 'package:bitdm/core/errors.dart';
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

/// Ob [nadel] irgendwo in [heu] vorkommt.
bool enthaelt(Uint8List heu, List<int> nadel) {
  outer:
  for (var i = 0; i + nadel.length <= heu.length; i++) {
    for (var j = 0; j < nadel.length; j++) {
      if (heu[i + j] != nadel[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Die Datei unter anhaenge/ ist im Ablageformat und verraet nichts vom
/// Klartext [klar] — weder den Anfang noch ein Stueck aus der Mitte.
Future<void> erwarteVerschluesselt(String pfad, Uint8List klar) async {
  final roh = await File(pfad).readAsBytes();
  expect(await RuheDatei.istVerschluesselt(File(pfad)), isTrue,
      reason: 'der Anhang liegt nicht im Ablageformat');
  expect(enthaelt(roh, klar.sublist(0, 32)), isFalse,
      reason: 'der Anfang des Klartexts steht in der Datei');
  final mitte = klar.length ~/ 2;
  expect(enthaelt(roh, klar.sublist(mitte, mitte + 32)), isFalse,
      reason: 'ein Stueck Klartext aus der Mitte steht in der Datei');
}

void main() {
  // KEIN `late` AUF EINEM NULLBAREN FELD. Die beiden widersprechen sich:
  // `?` sagt "darf null sein", `late` sagt "wird vor dem Lesen zugewiesen".
  // Wirft `starten()` im setUpAll, bleibt das Feld unzugewiesen, und schon
  // `relay?.beenden()` im tearDownAll wirft LateError — der `?.`-Test kommt
  // erst NACH dem Lesen. Damit stirbt auch das Aufraeumen darunter, und der
  // Lager-Prozess bleibt liegen. Ohne `late` ist der Startwert null, der
  // Abbau laeuft durch, und die ECHTE Fehlermeldung aus setUpAll bleibt
  // sichtbar statt von einem LateError verdeckt zu werden.
  Relay? relay;
  Lager? lager;
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

      // SEIT 25.09.2026 VERSCHLUESSELT ABGELEGT: unter anhaenge/ liegt kein
      // Klartext — der kommt nur ueber die Entschluesselung heraus.
      await erwarteVerschluesselt(fertig.pfad!, vorher);
      final klar = await bob.entschluesselterAnhang(alice.myId, beiBob.id);
      expect(await klar.readAsBytes(), vorher,
          reason: 'bytegleich, ueber zwei Kerne, zwei Server und die '
              'Signal-Sitzung dazwischen');
      expect(klar.path, isNot(fertig.pfad));
      expect(klar.parent.path, endsWith('.klar'),
          reason: 'die Klartextkopie gehoert in den privaten Unterordner');
      expect(await bob.anhangInhalt(alice.myId, beiBob.id), vorher);

      // Freigeben loescht die Kopie, nicht den Anhang.
      await bob.gibAnhangFrei(klar);
      expect(klar.existsSync(), isFalse);
      expect(File(fertig.pfad!).existsSync(), isTrue);

      // NACH DEM SPERREN IST JEDE KLARTEXTKOPIE WEG — auch eine, die nie
      // freigegeben wurde —, und ohne Entsperren gibt es keine neue.
      final vergessen = await bob.entschluesselterAnhang(alice.myId, beiBob.id);
      expect(vergessen.existsSync(), isTrue);
      await bob.lock();
      expect(vergessen.existsSync(), isFalse,
          reason: 'die Klartextkopie ueberlebte das Sperren');
      await expectLater(bob.entschluesselterAnhang(alice.myId, beiBob.id),
          throwsA(isA<NotInitializedException>()));

      // Und nach dem Entsperren geht es wieder — derselbe Schluessel aus
      // denselben Woertern.
      expect(await bob.initialize(), isTrue);
      final wieder = await bob.entschluesselterAnhang(alice.myId, beiBob.id);
      expect(await wieder.readAsBytes(), vorher);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('UMSTELLUNG: ein alter Klartextanhang wird beim Entsperren verschluesselt', () async {
      if (relay == null || lager == null) return;
      final quelle = await dateiMit(ordner, 150000, 'alt.bin');
      final vorher = await quelle.readAsBytes();
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(bob.myId, quelle);
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));
      final geholt = await bob.holeAnhang(alice.myId, beiBob.id);

      // Den Zustand einer alten Fassung herstellen: die Datei im Klartext,
      // derselbe Pfad in der Datenbank.
      await File(geholt.pfad!).writeAsBytes(vorher, flush: true);
      expect(await RuheDatei.istVerschluesselt(File(geholt.pfad!)), isFalse);
      // Bis zur Umstellung gibt es den Klartext unveraendert heraus.
      expect(await bob.anhangInhalt(alice.myId, beiBob.id), vorher);

      await bob.lock();
      expect(await bob.initialize(), isTrue);
      final r = await bob.anhangUmstellung;
      expect(r.umgestellt, 1);
      expect(r.offen, 0);

      await erwarteVerschluesselt(geholt.pfad!, vorher);
      final klar = await bob.entschluesselterAnhang(alice.myId, beiBob.id);
      expect(await klar.readAsBytes(), vorher);
      expect(Directory(File(geholt.pfad!).parent.path)
              .listSync()
              .where((e) => e.path.endsWith(RuheDatei.umstellEndung)),
          isEmpty,
          reason: 'eine Nebendatei der Umstellung blieb liegen');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EINMAL-ANSICHT: Bob sieht sie einmal, danach ist sie weg', () async {
      if (relay == null || lager == null) return;
      final angekommen = bob.incomingMessages.first;
      final gesendet = await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 40000, 'foto.jpg'), einmal: true);

      // Der Absender behaelt keine Kopie.
      final beiAlice = (await alice.getAnhaenge(bob.myId))[gesendet.id]!;
      expect(beiAlice.einmal, isTrue);
      expect(beiAlice.pfad, isNull, reason: 'die Einmal-Ansicht liegt beim Absender');

      final beiBob = await angekommen.timeout(const Duration(seconds: 20));
      final vorm = (await bob.getAnhaenge(alice.myId))[beiBob.id]!;
      expect(vorm.einmal, isTrue, reason: 'das Kennzeichen kam nicht an');

      final geholt = await bob.holeAnhang(alice.myId, beiBob.id);
      final datei = File(geholt.pfad!);
      expect(datei.existsSync(), isTrue);

      await bob.verbraucheEinmal(alice.myId, beiBob.id);
      final danach = (await bob.getAnhaenge(alice.myId))[beiBob.id]!;
      expect(danach.zustand, AnhangZustand.verbraucht);
      expect(danach.pfad, isNull);
      expect(datei.existsSync(), isFalse, reason: 'die Datei liegt nach dem Ansehen noch da');

      // Und sie steht nicht in der Sicherung.
      final sicherung = String.fromCharCodes(await bob.erstelleSicherung());
      expect(sicherung.contains('foto.jpg'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EIN GEWOEHNLICHER EIGENER ANHANG BLEIBT OEFFENBAR', () async {
      if (relay == null || lager == null) return;
      // Bis 25.09.2026 zeigte der Pfad auf die Quelle — beim Dateiwaehler eine
      // Dateikennung, die nach dem Versand zu ist.
      final quelle = await dateiMit(ordner, 20000, 'notiz.txt');
      final angekommen = bob.incomingMessages.first;
      final gesendet = await alice.sendeAnhang(bob.myId, quelle);
      // Bob holt ab — sonst bliebe der Block im gemeinsamen Lager liegen und
      // der naechste Test zaehlte ihn mit.
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));
      await bob.holeAnhang(alice.myId, beiBob.id);
      await Future<void>.delayed(const Duration(seconds: 1));
      final vorher = await quelle.readAsBytes();
      await quelle.delete();
      final eigen = (await alice.getAnhaenge(bob.myId))[gesendet.id]!;
      expect(eigen.pfad, isNotNull);
      expect(File(eigen.pfad!).existsSync(), isTrue,
          reason: 'ohne eigene Kopie verschwindet der Anhang mit der Quelle');
      // Die eigene Kopie ist verschluesselt — und oeffnet sich trotzdem.
      await erwarteVerschluesselt(eigen.pfad!, vorher);
      final klar = await alice.entschluesselterAnhang(bob.myId, gesendet.id);
      expect(await klar.readAsBytes(), vorher);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('SICHERUNG MIT DATEIEN: auf dem neuen Telefon ist der Anhang wieder da', () async {
      if (relay == null || lager == null) return;
      final quelle = await dateiMit(ordner, 30000, 'plan.pdf');
      final vorher = await quelle.readAsBytes();
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(bob.myId, quelle);
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));
      await bob.holeAnhang(alice.myId, beiBob.id);

      final ohne = await bob.erstelleSicherung();
      final mit = await bob.erstelleSicherung(mitDateien: true);
      expect(mit.length, greaterThan(ohne.length + 30000),
          reason: 'die Datei steckt nicht in der Sicherung');

      // Das neue Telefon: dieselben Woerter, frische Datenbank.
      final woerter = await bob.getRecoveryPhrase();
      final neu = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}bob-neu.db',
        relayUri: relay!.uri,
        lagerUri: lager!.uri,
      );
      addTearDown(neu.dispose);
      await neu.initialize();
      await neu.restoreIdentity(woerter);
      await neu.spieleSicherungEin(mit);
      final dort = (await neu.getAnhaenge(alice.myId))[beiBob.id]!;
      expect(dort.zustand, AnhangZustand.da, reason: 'der Anhang ist nicht wieder da');
      // Auch eingespielt liegt er verschluesselt da.
      await erwarteVerschluesselt(dort.pfad!, vorher);
      final klar = await neu.entschluesselterAnhang(alice.myId, beiBob.id);
      expect(await klar.readAsBytes(), vorher);
    }, timeout: const Timeout(Duration(minutes: 3)));

    // BIS 25.09.2026 HIESS DER TEST "nach dem Holen ist das Lager wieder
    // leer" — und genau das war der Fehler: wer zuerst holte, nahm die Bloecke
    // allen anderen weg (Zweitgeraete, Spiegel des Absenders, Gruppen).
    test('NACH DEM HOLEN BLEIBT ES FUER DIE ANDEREN GERAETE LIEGEN', () async {
      if (relay == null || lager == null) return;
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(
          bob.myId, await dateiMit(ordner, 50000, 'klein.bin'));
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));

      await bob.holeAnhang(alice.myId, beiBob.id);

      // Ein Wegwerfen liefe ohne Warten — kurz Zeit lassen, sonst bewiese
      // der Test nichts.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await lager!.anzahlBloecke(), greaterThan(0),
          reason: 'das erste Geraet hat die Bloecke fuer alle anderen geloescht');
    }, timeout: const Timeout(Duration(minutes: 3)));

    // EMULATORLAUF 25.09.2026: ein Anhang, dessen Datei fehlt, zeigte
    // "Oeffnen" und scheiterte dann mit "liess sich nicht entschluesseln" —
    // bei jedem Tippen wieder. Jetzt: klare Ausnahme, und der Zustand wird
    // berichtigt, damit man ihn neu holen kann.
    test('FEHLT DIE LOKALE DATEI, WIRD DER ANHANG WIEDER HOLBAR', () async {
      if (relay == null || lager == null) return;
      final angekommen = bob.incomingMessages.first;
      await alice.sendeAnhang(bob.myId, await dateiMit(ordner, 5000, 'weg.bin'));
      final beiBob = await angekommen.timeout(const Duration(seconds: 20));
      final geholt = await bob.holeAnhang(alice.myId, beiBob.id);
      await File(geholt.pfad!).delete();

      await expectLater(bob.entschluesselterAnhang(alice.myId, beiBob.id),
          throwsA(isA<AnhangFehltException>()));
      final jetzt = (await bob.getAnhaenge(alice.myId))[beiBob.id]!;
      expect(jetzt.zustand, AnhangZustand.angekuendigt,
          reason: 'ein empfangener Anhang ohne Datei muss neu holbar sein');

      final nochmal = await bob.holeAnhang(alice.myId, beiBob.id);
      expect(nochmal.zustand, AnhangZustand.da);
      final klar = await bob.entschluesselterAnhang(alice.myId, beiBob.id);
      expect(await klar.length(), 5000);
      await bob.gibAnhangFrei(klar);
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
      final klar = await bob.entschluesselterAnhang(alice.myId, beiBob.id);

      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await bob.purgeExpiredMessages(), greaterThan(0));

      expect(await datei.exists(), isFalse,
          reason: 'die Datei muss mit der Nachricht verschwinden, nicht nur '
              'ihr Eintrag in der Datenbank');
      expect(await klar.exists(), isFalse,
          reason: 'die entschluesselte Kopie blieb nach dem Verfall liegen');
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
