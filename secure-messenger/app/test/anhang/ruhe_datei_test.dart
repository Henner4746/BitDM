// ruhe_datei_test.dart — das Ablageformat der Anhaenge auf dem Geraet.
//
// Geprueft werden EIGENSCHAFTEN des Formats (ruhe_datei.dart): was hinein
// geht, kommt heraus; was veraendert, abgeschnitten, verlaengert oder
// vertauscht wurde, geht nicht auf; und die Umstellung alter Klartextdateien
// ist wiederholbar und uebersteht einen Abbruch.
//
// Die meisten Faelle laufen mit der kleinsten Stueckgroesse (1 KiB): dann
// sind "mehrere Stuecke" und "genau an der Grenze" ein paar Kilobyte statt
// ein paar Megabyte, und die Eigenschaften sind dieselben.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/native_krypto.dart';
import 'package:bitdm/core/anhang/ruhe_datei.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List zaehlend(int n, [int saat = 3]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 7 + saat) % 251));

/// Eine Chiffre, die beim [abN]-ten Verschluesseln wirft — ein Absturz
/// mitten im Schreiben, ohne einen Prozess abzuschiessen.
class BrichtAb extends NativeStueckKrypto {
  BrichtAb(this.abN);
  final int abN;
  var _n = 0;
  @override
  Future<Uint8List> verschluessleRoh({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required Uint8List zusatz,
  }) {
    if (++_n >= abN) throw const FileSystemException('Akku leer');
    return super.verschluessleRoh(
        klar: klar, schluessel: schluessel, nonce: nonce, zusatz: zusatz);
  }
}

void main() {
  const k = RuheDatei.kleinstesStueck; // 1024
  final schluessel = zaehlend(32, 11);
  final fremd = zaehlend(32, 12);
  late Directory ordner;
  var n = 0;

  File datei(String name) => File('${ordner.path}${Platform.pathSeparator}$name');

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-ruhe');
  });

  tearDown(() async {
    RuheDatei.chiffre = NativeStueckKrypto();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> zu(Uint8List klar, {int stueck = k, Uint8List? s}) async {
    final f = datei('geheim${n++}');
    await RuheDatei.schreibeBytes(f, klar, s ?? schluessel, stueck: stueck);
    return f;
  }

  Future<Uint8List> auf(File f, {Uint8List? s}) =>
      RuheDatei.entschluessleInSpeicher(f, s ?? schluessel);

  Matcher kaputt() => throwsA(isA<RuheDateiKaputt>());

  group('hin und zurueck', () {
    for (final (name, laenge) in [
      ('leer', 0),
      ('ein Byte', 1),
      ('klein', 100),
      ('genau ein Stueck', k),
      ('ein Stueck und ein Byte', k + 1),
      ('genau an der Grenze, drei Stuecke', 3 * k),
      ('mehrere Stuecke, krumm', 5 * k + 123),
    ]) {
      test('$name ($laenge Byte)', () async {
        final klar = zaehlend(laenge);
        final f = await zu(klar);
        expect(await auf(f), klar);
        // Kopf + je Stueck eine Beglaubigung; auch "leer" hat ein Stueck.
        final stuecke = laenge == 0 ? 1 : (laenge + k - 1) ~/ k;
        expect(await f.length(),
            RuheDatei.kopfLaenge + laenge + stuecke * RuheDatei.tagLaenge);
      });
    }

    test('ab Werk (1 MiB je Stueck), ueber eine Stueckgrenze', () async {
      final klar = zaehlend(RuheDatei.standardStueck + 4321);
      final f = datei('werk');
      await RuheDatei.schreibeBytes(f, klar, schluessel);
      expect(await auf(f), klar);
    });

    test('byteweise geschrieben ergibt dasselbe wie am Stueck', () async {
      // Der Schreiber haelt das letzte Stueck zurueck, bis klar ist, dass
      // noch etwas kommt — die Aufteilung der Eingabe darf daran nichts
      // aendern.
      final klar = zaehlend(2 * k + 17);
      final f = datei('byteweise');
      final s = await RuheSchreiber.oeffne(f, schluessel, stueck: k);
      for (final b in klar) {
        await s.schreibe([b]);
      }
      await s.schliesse();
      expect(await auf(f), klar);
    });

    test('Datei zu Datei, und der Klartext steht nicht darin', () async {
      final klar = zaehlend(3 * k + 5);
      final quelle = datei('quelle')..writeAsBytesSync(klar);
      final geheim = datei('geheim');
      final zurueck = datei('zurueck');
      await RuheDatei.verschluessleDatei(quelle, geheim, schluessel, stueck: k);
      await RuheDatei.entschluessleDatei(geheim, zurueck, schluessel);
      expect(await zurueck.readAsBytes(), klar);
      expect(await quelle.readAsBytes(), klar, reason: 'die Quelle blieb nicht unberuehrt');

      final roh = await geheim.readAsBytes();
      final probe = klar.sublist(k, k + 24);
      var gefunden = false;
      for (var i = 0; i + probe.length <= roh.length && !gefunden; i++) {
        var j = 0;
        while (j < probe.length && roh[i + j] == probe[j]) {
          j++;
        }
        gefunden = j == probe.length;
      }
      expect(gefunden, isFalse, reason: 'Klartext in der Ablagedatei');
    });

    test('zweimal dasselbe ergibt verschiedene Dateien (Salz je Datei)', () async {
      final klar = zaehlend(500);
      final a = await (await zu(klar)).readAsBytes();
      final b = await (await zu(klar)).readAsBytes();
      expect(a, isNot(equals(b)));
    });

    test('der Kopf wird erkannt, Klartext nicht', () async {
      final f = await zu(zaehlend(10));
      expect(await RuheDatei.istVerschluesselt(f), isTrue);
      expect(await RuheDatei.istVerschluesselt(datei('klar')..writeAsBytesSync(zaehlend(100))),
          isFalse);
      expect(await RuheDatei.istVerschluesselt(datei('kurz')..writeAsBytesSync([66, 73])),
          isFalse);
      expect(await RuheDatei.istVerschluesselt(datei('gibtsnicht')), isFalse);
    });
  });

  group('was nicht aufgehen darf', () {
    late Uint8List klar;
    late File f;
    late Uint8List roh;
    const kopf = RuheDatei.kopfLaenge;
    const block = k + RuheDatei.tagLaenge;

    setUp(() async {
      klar = zaehlend(3 * k + 200); // drei volle Stuecke und ein kurzes
      f = await zu(klar);
      roh = await f.readAsBytes();
    });

    Future<File> mit(List<int> bytes) async => datei('verdorben${n++}')..writeAsBytesSync(bytes);

    test('ein veraendertes Byte im Chiffretext', () async {
      final b = Uint8List.fromList(roh)..[kopf + block + 5] ^= 1;
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('ein veraendertes Byte in der Beglaubigung', () async {
      final b = Uint8List.fromList(roh)..[roh.length - 1] ^= 0x80;
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('ein veraendertes Byte im Salz des Kopfs', () async {
      final b = Uint8List.fromList(roh)..[kopf - 1] ^= 1;
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('eine andere Stueckgroesse im Kopf', () async {
      // 1024 → 2048: bleibt im erlaubten Bereich, der Kopf steht aber im
      // beglaubigten Zusatz jedes Stuecks.
      final b = Uint8List.fromList(roh)..[RuheDatei.magie.length + 3] = 0x08;
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('eine unbekannte Fassung', () async {
      final b = Uint8List.fromList(roh)..[RuheDatei.magie.length] = 2;
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('abgeschnitten an einer Stueckgrenze (das letzte Stueck fehlt)', () async {
      // Der gefaehrlichste Fall: alle uebrigen Stuecke sind einwandfrei. Nur
      // das Kennzeichen "letztes Stueck" verraet, dass etwas fehlt.
      await expectLater(auf(await mit(roh.sublist(0, kopf + 3 * block))), kaputt());
      await expectLater(auf(await mit(roh.sublist(0, kopf + block))), kaputt());
    });

    test('abgeschnitten mitten im Stueck', () async {
      await expectLater(auf(await mit(roh.sublist(0, roh.length - 7))), kaputt());
    });

    test('nur noch der Kopf, oder nicht einmal der', () async {
      await expectLater(auf(await mit(roh.sublist(0, kopf))), kaputt());
      await expectLater(auf(await mit(roh.sublist(0, kopf - 1))), kaputt());
      await expectLater(auf(await mit(roh.sublist(0, kopf + 10))), kaputt());
    });

    test('auch eine LEERE Datei laesst sich nicht auf den Kopf kuerzen', () async {
      final leer = await (await zu(Uint8List(0))).readAsBytes();
      expect(leer.length, kopf + RuheDatei.tagLaenge);
      await expectLater(auf(await mit(leer.sublist(0, kopf))), kaputt());
    });

    test('etwas hinten angehaengt', () async {
      await expectLater(auf(await mit([...roh, 0])), kaputt());
      await expectLater(
          auf(await mit([...roh, ...roh.sublist(kopf, kopf + block)])), kaputt());
    });

    test('zwei Stuecke vertauscht', () async {
      final b = Uint8List.fromList(roh);
      b.setRange(kopf, kopf + block, roh, kopf + block);
      b.setRange(kopf + block, kopf + 2 * block, roh, kopf);
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('ein Stueck aus einer anderen Datei desselben Schluessels', () async {
      final andere = await (await zu(zaehlend(3 * k + 200, 9))).readAsBytes();
      final b = Uint8List.fromList(roh)
        ..setRange(kopf + block, kopf + 2 * block, andere, kopf + block);
      await expectLater(auf(await mit(b)), kaputt());
    });

    test('der falsche Schluessel', () async {
      await expectLater(auf(f, s: fremd), kaputt());
    });

    test('scheitert das Entschluesseln in eine Datei, bleibt keine halbe liegen', () async {
      final b = Uint8List.fromList(roh)..[roh.length - 1] ^= 1; // erst am Ende kaputt
      final ziel = datei('halb');
      await expectLater(
          RuheDatei.entschluessleDatei(await mit(b), ziel, schluessel), kaputt());
      expect(ziel.existsSync(), isFalse);
    });

    test('die Grenze im Speicher wird eingehalten', () async {
      await expectLater(RuheDatei.entschluessleInSpeicher(f, schluessel, grenze: 1000),
          throwsA(isA<RuheDateiZuGross>()));
      expect(await RuheDatei.entschluessleInSpeicher(f, schluessel, grenze: klar.length),
          klar);
    });
  });

  group('Schreiben bricht ab', () {
    test('keine halbe Datei am Ziel', () async {
      RuheDatei.chiffre = BrichtAb(2);
      final ziel = datei('abbruch');
      await expectLater(
          RuheDatei.schreibeBytes(ziel, zaehlend(3 * k), schluessel, stueck: k),
          throwsA(isA<FileSystemException>()));
      expect(ziel.existsSync(), isFalse);
    });
  });

  group('Umstellung alter Klartextdateien', () {
    late Directory anhaenge;

    setUp(() async {
      anhaenge = await Directory('${ordner.path}/anhaenge').create();
    });

    File imOrdner(String name) => File('${anhaenge.path}/$name');

    test('Klartext wird verschluesselt — am selben Pfad, mit demselben Inhalt', () async {
      final a = zaehlend(5 * k + 3, 1);
      final b = zaehlend(0);
      imOrdner('x_foto.jpg').writeAsBytesSync(a);
      imOrdner('y_leer.txt').writeAsBytesSync(b);

      final r = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(r.umgestellt, 2);
      expect(r.offen, 0);
      expect(await RuheDatei.istVerschluesselt(imOrdner('x_foto.jpg')), isTrue);
      expect(await auf(imOrdner('x_foto.jpg')), a);
      expect(await auf(imOrdner('y_leer.txt')), b);
      expect(anhaenge.listSync().map((e) => e.uri.pathSegments.last).toSet(),
          {'x_foto.jpg', 'y_leer.txt'},
          reason: 'es duerfen keine Nebendateien liegenbleiben');
    });

    test('ein zweiter Lauf aendert nichts (wiederholbar)', () async {
      final a = zaehlend(2 * k, 2);
      imOrdner('x').writeAsBytesSync(a);
      await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      final einmal = imOrdner('x').readAsBytesSync();

      final r = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(r.umgestellt, 0);
      expect(r.offen, 0);
      expect(imOrdner('x').readAsBytesSync(), einmal,
          reason: 'eine schon verschluesselte Datei wurde noch einmal angefasst');
      expect(await auf(imOrdner('x')), a);
    });

    test('Absturz beim Schreiben: das Original bleibt, der naechste Lauf holt es nach', () async {
      final a = zaehlend(4 * k, 4);
      imOrdner('x').writeAsBytesSync(a);

      RuheDatei.chiffre = BrichtAb(3);
      final erst = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(erst.umgestellt, 0);
      expect(erst.offen, 1);
      expect(imOrdner('x').readAsBytesSync(), a, reason: 'das Original ist beschaedigt');

      RuheDatei.chiffre = NativeStueckKrypto();
      final dann = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(dann.umgestellt, 1);
      expect(await auf(imOrdner('x')), a);
    });

    test('Reste eines abgeschossenen Laufs werden weggeraeumt', () async {
      // So sieht es aus, wenn der Prozess zwischen Schreiben und Umbenennen
      // starb: das Original im Klartext, daneben eine halbe Nebendatei.
      final a = zaehlend(3 * k, 5);
      imOrdner('x').writeAsBytesSync(a);
      imOrdner('x${RuheDatei.umstellEndung}').writeAsBytesSync(zaehlend(700, 6));
      // Und eine Nebendatei, deren Original schon umgestellt ist.
      await RuheDatei.schreibeBytes(imOrdner('y'), a, schluessel, stueck: k);
      imOrdner('y${RuheDatei.umstellEndung}').writeAsBytesSync(zaehlend(50));

      final r = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(r.umgestellt, 1);
      expect(await auf(imOrdner('x')), a);
      expect(await auf(imOrdner('y')), a);
      expect(anhaenge.listSync().where((e) => e.path.endsWith(RuheDatei.umstellEndung)),
          isEmpty);
    });

    test('der Klartext-Unterordner und neue Empfaenge bleiben unberuehrt', () async {
      final klarOrdner = await Directory('${anhaenge.path}/.klar').create();
      final kopie = File('${klarOrdner.path}/kopie.jpg')..writeAsBytesSync(zaehlend(10));
      // Ein laufender Empfang der neuen Fassung (traegt den Kopf von Anfang an).
      final teil = imOrdner('z.teil');
      await RuheDatei.schreibeBytes(teil, zaehlend(10), schluessel, stueck: k);
      final teilVorher = teil.readAsBytesSync();

      final r = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(r.umgestellt, 0);
      expect(kopie.readAsBytesSync(), zaehlend(10));
      expect(teil.readAsBytesSync(), teilVorher);
    });

    test('eine alte Klartext-Nebendatei eines abgebrochenen Empfangs geht, eine frische bleibt', () async {
      final alt = imOrdner('alt.teil')..writeAsBytesSync(zaehlend(100));
      alt.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      final frisch = imOrdner('frisch.teil')..writeAsBytesSync(zaehlend(100));

      await RuheDatei.stelleAltbestandUm(anhaenge, schluessel, stueck: k);
      expect(alt.existsSync(), isFalse, reason: 'halber Klartext blieb liegen');
      expect(frisch.existsSync(), isTrue,
          reason: 'in eine frische Nebendatei koennte gerade noch geschrieben werden');
    });

    test('abgebrochen (gesperrt): nichts wird angefasst, alles bleibt offen', () async {
      imOrdner('x').writeAsBytesSync(zaehlend(100));
      imOrdner('y').writeAsBytesSync(zaehlend(100));
      final r = await RuheDatei.stelleAltbestandUm(anhaenge, schluessel,
          stueck: k, abbrechen: () => true);
      expect(r.umgestellt, 0);
      expect(r.offen, 2);
      expect(imOrdner('x').readAsBytesSync(), zaehlend(100));
    });

    test('kein Ordner, keine Arbeit', () async {
      final r = await RuheDatei.stelleAltbestandUm(
          Directory('${ordner.path}/gibtsnicht'), schluessel);
      expect(r.umgestellt, 0);
      expect(r.offen, 0);
    });
  });
}
