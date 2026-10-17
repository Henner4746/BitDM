// geraeteliste_test.dart — die Geraeteliste zwischen App und Relay.
//
// DIE VERGLEICHSWERTE KOMMEN VOM RELAY (server/tools/
// write_geraeteliste_fixtures.py): Listen und eine Beitrittsanfrage, die
// relay_server.py selbst geschrieben, unterschrieben und gelesen hat. Ein
// Test, der beides in Dart ausrechnet, bliebe gruen, wenn beide Seiten
// dieselbe falsche Annahme treffen — etwa ueber die Schreibweise der Liste.
//
// Was hier NICHT steht, weil es nur gegen den echten Relay geht: dass der
// Relay die Listen der App annimmt und durchsetzt. Das pruefen
// geraeteabmeldung_test.dart (App gegen relay_server.py) und test_relay.py.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/signal_hilfe.dart';

Map<String, Object?> _fixtures() => (jsonDecode(
        File('test/net/geraeteliste_fixtures.json').readAsStringSync()) as Map)
    .cast<String, Object?>();

Map<String, Object?> _karte(Object? o) => (o! as Map).cast<String, Object?>();

/// Eine Kopie von [karte] mit anderer `liste` — die Signaturen bleiben.
Map<String, Object?> _mitListe(Map<String, Object?> karte, String liste) =>
    {...karte, 'liste': liste};

Future<SignalIdentity> _identitaet() async {
  final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
  return SignalIdentityBridge.fromDerived(keys,
      registrationId: SignalIdentityBridge.newRegistrationId());
}

void main() {
  late Map<String, Object?> f;
  late String adresse;

  setUpAll(() async {
    await signalBereit();
    f = _fixtures();
    adresse = f['adresse']! as String;
  });

  group('Listen vom Relay', () {
    test('Python unterschreibt, Dart prueft — alle drei Faelle', () {
      final l1 = Geraeteliste.pruefe(f['liste_1'], adresse: adresse);
      expect(l1.epoche, 1);
      expect(l1.kennungen, {1});
      expect(l1.enthaelt(1, base64.decode(f['geraet_1']! as String)), isTrue);

      // Ein Mitglied fuegt hinzu — mit der vorigen Fassung, also auch gegen
      // die Regel des Relays geprueft.
      final l2 = Geraeteliste.pruefe(f['liste_2_mitglied_fuegt_hinzu'],
          adresse: adresse, vorige: l1);
      expect(l2.kennungen, {1, 37});

      // Selbstabmeldung: der Unterzeichner steht nicht mehr darin, sein
      // Schluessel kommt aus der vorigen Fassung.
      final l3 = Geraeteliste.pruefe(f['liste_3_selbst_abgemeldet'],
          adresse: adresse, vorige: l2);
      expect(l3.kennungen, {1});
      expect(l3.unterzeichner, 37);
      // Ohne die vorige Fassung zaehlt die Identitaetssignatur allein.
      expect(
          Geraeteliste.pruefe(f['liste_3_selbst_abgemeldet'], adresse: adresse)
              .epoche,
          3);
    });

    test('DIESELBE SCHREIBWEISE: Dart schreibt Zeichen fuer Zeichen, was der '
        'Relay schrieb', () {
      final l2 = Geraeteliste.pruefe(f['liste_2_mitglied_fuegt_hinzu'],
          adresse: adresse);
      final neu = Geraeteliste.kanonisch(
        adresse: adresse,
        epoche: 2,
        // Absichtlich in falscher Reihenfolge: sortiert wird beim Schreiben.
        geraete: [l2.geraete[1], l2.geraete[0]],
        unterzeichner: 1,
        zeit: 1760700100,
      );
      expect(neu, _karte(f['liste_2_mitglied_fuegt_hinzu'])['liste']);
    });

    test('JEDE VERAENDERUNG FAELLT AUF', () {
      final echt = _karte(f['liste_2_mitglied_fuegt_hinzu']);
      final roh = echt['liste']! as String;
      final faelle = <String, Map<String, Object?>>{
        'anderes Geraet': _mitListe(echt, roh.replaceFirst('[37,', '[38,')),
        'Leerraum': _mitListe(echt, roh.replaceFirst(',"v"', ', "v"')),
        'doppelter Schluessel':
            _mitListe(echt, '${roh.substring(0, roh.length - 1)},"v":1}'),
        'Kommazahl': _mitListe(echt, roh.replaceFirst('"epoche":2', '"epoche":2.0')),
        'Umlaut': _mitListe(echt, roh.replaceFirst('"zeit"', '"zeït"')),
        'Signaturen vertauscht': {
          ...echt,
          'sig_identitaet': echt['sig_geraet'],
          'sig_geraet': echt['sig_identitaet'],
        },
      };
      for (final e in faelle.entries) {
        expect(() => Geraeteliste.pruefe(e.value, adresse: adresse),
            throwsA(isA<GeraetelisteUngueltig>()),
            reason: e.key);
      }
    });

    test('EINE LISTE GEHOERT GENAU EINER ADRESSE', () async {
      final fremd = await _identitaet();
      expect(() => Geraeteliste.pruefe(f['liste_1'], adresse: fremd.address),
          throwsA(isA<GeraetelisteUngueltig>()));
    });
  });

  group('Listen aus der App', () {
    test('Dart unterschreibt und prueft', () async {
      final id = await _identitaet();
      final gs = PrivateKey.generate();
      final l = Geraeteliste.unterschreibe(
        identitaet: id,
        geraeteschluessel: gs,
        epoche: 1,
        geraete: [GeraeteEintrag(5, rohOeffentlich(gs), '')],
        unterzeichner: 5,
      );
      final gelesen = Geraeteliste.pruefe(l.alsJson(), adresse: id.address);
      expect(gelesen.roh, l.roh);
      expect(gelesen.enthaelt(5, rohOeffentlich(gs)), isTrue);
      expect(gelesen.enthaelt(5, rohOeffentlich(PrivateKey.generate())), isFalse,
          reason: 'dieselbe Kennung mit anderem Schluessel ist ein anderes Geraet');
    });

    test('WER NICHT DRINSTEHT, KANN NIEMANDEN MITNEHMEN — auch nicht mit den '
        'Woertern', () async {
      // Genau die Regel, mit der ein Dieb mit den Woertern still dazukaeme:
      // er unterschreibt mit dem Identitaetsschluessel und seinem eigenen
      // Geraeteschluessel eine Fassung, die ihn NEBEN den echten Geraeten
      // auffuehrt. Der Relay lehnt das ab (test_relay.py); die App erkennt
      // es auch selbst, sobald sie die Fassung davor kennt.
      final id = await _identitaet();
      final echt = PrivateKey.generate();
      final dieb = PrivateKey.generate();
      final eins = Geraeteliste.unterschreibe(
        identitaet: id,
        geraeteschluessel: echt,
        epoche: 1,
        geraete: [GeraeteEintrag(1, rohOeffentlich(echt), '')],
        unterzeichner: 1,
      );
      final mitDieb = Geraeteliste.unterschreibe(
        identitaet: id,
        geraeteschluessel: dieb,
        epoche: 2,
        geraete: [
          GeraeteEintrag(1, rohOeffentlich(echt), ''),
          GeraeteEintrag(9, rohOeffentlich(dieb), ''),
        ],
        unterzeichner: 9,
      );
      expect(
          () => Geraeteliste.pruefe(mitDieb.alsJson(),
              adresse: id.address, vorige: eins),
          throwsA(isA<GeraetelisteUngueltig>()));

      // Was er darf: zuruecksetzen, mit sich allein. Das ist laut — das
      // echte Geraet faellt dabei heraus.
      final allein = Geraeteliste.unterschreibe(
        identitaet: id,
        geraeteschluessel: dieb,
        epoche: 2,
        geraete: [GeraeteEintrag(9, rohOeffentlich(dieb), '')],
        unterzeichner: 9,
      );
      final gelesen = Geraeteliste.pruefe(allein.alsJson(),
          adresse: id.address, vorige: eins);
      expect(gelesen.enthaelt(1, rohOeffentlich(echt)), isFalse);
    });

    test('OHNE DEN IDENTITAETSSCHLUESSEL GEHT NICHTS', () async {
      // Was ein Relay versuchen koennte: eine Liste fuer eine fremde Adresse
      // mit einer eigenen Identitaet unterschreiben.
      final opfer = await _identitaet();
      final relay = await _identitaet();
      final gs = PrivateKey.generate();
      final l = Geraeteliste.unterschreibe(
        identitaet: relay,
        geraeteschluessel: gs,
        epoche: 7,
        geraete: [GeraeteEintrag(1, rohOeffentlich(gs), '')],
        unterzeichner: 1,
      );
      final roh = l.roh.replaceFirst(relay.address, opfer.address);
      expect(
          () => Geraeteliste.pruefe(
              {...l.alsJson(), 'liste': roh}, adresse: opfer.address),
          throwsA(isA<GeraetelisteUngueltig>()));
    });
  });

  group('Beitritt', () {
    test('die Anfrage des Relays prueft, und nur der richtige Code passt', () {
      final a = Beitrittsanfrage.pruefe(f['beitritt'], adresse: adresse);
      expect(a.deviceId, 37);
      final code = base64.decode(f['beitritt_code']! as String);
      expect(a.passtZu(Uint8List.fromList(code)), isTrue);
      final falsch = Uint8List.fromList(code)..[0] ^= 1;
      expect(a.passtZu(falsch), isFalse);
      expect(base64.encode(a.nachweis), f['nachweis']);
    });

    test('der Code wird angezeigt wie Base32 nach RFC 4648 und zurueckgelesen',
        () {
      final code = Uint8List.fromList(base64.decode(f['beitritt_code']! as String));
      final angezeigt = f['beitritt_code_angezeigt']! as String;
      expect(Beitrittscode.zeige(code), angezeigt);
      expect(Beitrittscode.lies(angezeigt), code);
      // Abgetippt: klein, ohne Striche, mit Leerzeichen — und 0/1 statt O/I.
      final schlampig = angezeigt
          .toLowerCase()
          .replaceAll('-', ' ')
          .replaceAll('o', '0')
          .replaceAll('i', '1');
      expect(Beitrittscode.lies(schlampig), code);
      expect(Beitrittscode.lies('ABCD-EFGH-IJKL'), isNull);
      expect(Beitrittscode.lies('ABCD-EFGH-IJKL-MNO8'), isNull);
      final neu = Beitrittscode.neu();
      expect(Beitrittscode.lies(Beitrittscode.zeige(neu)), neu);
    });

    test('eine Anfrage aus der App prueft — und eine mit fremder Signatur nicht',
        () async {
      final id = await _identitaet();
      final gs = PrivateKey.generate();
      final code = Beitrittscode.neu();
      final a = Beitrittsanfrage.unterschreibe(
          identitaet: id, geraeteschluessel: gs, deviceId: 12, info: '', code: code);
      final gelesen = Beitrittsanfrage.pruefe(a.alsJson(), adresse: id.address);
      expect(gelesen.passtZu(code), isTrue);

      final andere = Beitrittsanfrage.unterschreibe(
          identitaet: id,
          geraeteschluessel: PrivateKey.generate(),
          deviceId: 12,
          info: '',
          code: code);
      expect(
          () => Beitrittsanfrage.pruefe(
              {...a.alsJson(), 'sig_geraet': andere.alsJson()['sig_geraet']},
              adresse: id.address),
          throwsA(isA<GeraetelisteUngueltig>()));
    });
  });

  group('Info je Geraet', () {
    test('liest sich mit dem richtigen Schluessel, mit jedem anderen nicht', () {
      final s = Uint8List.fromList(List.generate(32, (i) => i));
      final info = GeraeteInfo('Android',
              DateTime.fromMillisecondsSinceEpoch(1760700000000, isUtc: true))
          .verschluessle(s);
      final zurueck = GeraeteInfo.entschluessle(s, info)!;
      expect(zurueck.name, 'Android');
      expect(zurueck.seit.millisecondsSinceEpoch, 1760700000000);
      final fremd = Uint8List.fromList(List.generate(32, (i) => i + 1));
      expect(GeraeteInfo.entschluessle(fremd, info), isNull);
      expect(GeraeteInfo.entschluessle(s, ''), isNull);
    });
  });
}
