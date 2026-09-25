// teilgeheimnis_test.dart — Shamir-Teilgeheimnisse fuer die Wiederherstellung
// ueber Vertrauenskontakte.

import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/teilgeheimnis.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bip39_vectors.dart';

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

/// Alle k-elementigen Teilmengen von [liste].
List<List<T>> _teilmengen<T>(List<T> liste, int k) {
  if (k == 0) return [<T>[]];
  if (liste.length < k) return [];
  final kopf = liste.first;
  final rest = liste.sublist(1);
  return [
    for (final m in _teilmengen(rest, k - 1)) [kopf, ...m],
    ..._teilmengen(rest, k),
  ];
}

void main() {
  group('GF(256)', () {
    test('Multiplikation nach FIPS-197 Abschnitt 4.2', () {
      expect(Gf256.mul(0x57, 0x83), 0xC1);
      expect(Gf256.mul(0x57, 0x13), 0xFE);
      expect(Gf256.mul(0x57, 0x02), 0xAE);
      expect(Gf256.mul(0x57, 0x04), 0x47);
      expect(Gf256.mul(0x57, 0x08), 0x8E);
      expect(Gf256.mul(0x57, 0x10), 0x07);
    });

    test('Multiplikation ist kommutativ, 1 neutral, 0 absorbierend', () {
      for (var a = 0; a < 256; a++) {
        expect(Gf256.mul(a, 1), a);
        expect(Gf256.mul(a, 0), 0);
        for (var b = a; b < 256; b += 7) {
          expect(Gf256.mul(a, b), Gf256.mul(b, a));
        }
      }
    });

    test('Inverse: a * inv(a) = 1 fuer alle a != 0, bijektiv', () {
      final gesehen = <int>{};
      for (var a = 1; a < 256; a++) {
        final i = Gf256.inv(a);
        expect(Gf256.mul(a, i), 1, reason: 'a=$a');
        expect(Gf256.inv(i), a);
        gesehen.add(i);
      }
      expect(gesehen.length, 255);
      expect(gesehen.contains(0), isFalse);
    });

    test('bekannte Inverse (AES-S-Box-Herleitung)', () {
      expect(Gf256.inv(0x01), 0x01);
      expect(Gf256.inv(0x53), 0xCA);
      expect(Gf256.inv(0x02), 0x8D);
    });

    test('0 hat kein Inverses', () {
      expect(() => Gf256.inv(0), throwsArgumentError);
    });
  });

  group('teile / setzeZusammen', () {
    final geheimnis = _hexToBytes('000102030405060708090a0b0c0d0e0f');

    test('3 von 5: jede 3er-Auswahl ergibt das Geheimnis', () {
      final alle = teile(geheimnis, schwelle: 3, anzahl: 5);
      expect(alle.length, 5);
      expect(alle.map((t) => t.x), [1, 2, 3, 4, 5]);
      final auswahlen = _teilmengen(alle, 3);
      expect(auswahlen.length, 10);
      for (final auswahl in auswahlen) {
        expect(setzeZusammen(auswahl), geheimnis,
            reason: 'Teile ${auswahl.map((t) => t.x).toList()}');
        // Reihenfolge ist egal.
        expect(setzeZusammen(auswahl.reversed.toList()), geheimnis);
      }
    });

    test('mehr Teile als noetig funktionieren ebenfalls', () {
      final alle = teile(geheimnis, schwelle: 3, anzahl: 5);
      expect(setzeZusammen(_teilmengen(alle, 4).first), geheimnis);
      expect(setzeZusammen(alle), geheimnis);
    });

    test('Grenzfaelle 2 von 2 und 10 von 10', () {
      for (final (k, n) in [(2, 2), (2, 10), (10, 10)]) {
        final alle = teile(geheimnis, schwelle: k, anzahl: n);
        expect(setzeZusammen(alle.sublist(n - k)), geheimnis);
      }
    });

    test('weniger als k Teile werden abgelehnt (statt Datenmuell zu liefern)',
        () {
      final alle = teile(geheimnis, schwelle: 3, anzahl: 5);
      expect(
        () => setzeZusammen(alle.sublist(0, 2)),
        throwsA(isA<TeilgeheimnisException>().having(
            (e) => e.message, 'message', contains('mindestens 3'))),
      );
      expect(() => setzeZusammen([]), throwsA(isA<TeilgeheimnisException>()));
    });

    test('k-1 Teile legen das Geheimnis nicht fest', () {
      // Hintergrund zur Ablehnung oben: Zu zwei Teilen einer 3-von-5-
      // Zerlegung passt JEDES Geheimnis. Wir konstruieren einen dritten Teil,
      // der zusammen mit den zwei echten ein voellig anderes Geheimnis ergibt.
      final alle = teile(geheimnis, schwelle: 3, anzahl: 5);
      final anderes = Uint8List(16)..fillRange(0, 16, 0xAA);
      // Aus (x=1, x=2 echt) und f(0) = anderes ergibt sich ein Polynom; der
      // dritte Punkt dieses Polynoms an x=3 ist ein "gefaelschter" Teil.
      final gefaelscht = Teil(
        schwelle: 3,
        x: 3,
        gruppenId: alle.first.gruppenId,
        y: _dritterPunkt(alle[0], alle[1], anderes),
      );
      expect(setzeZusammen([alle[0], alle[1], gefaelscht]), anderes);
    });

    test('Teile aus zwei Zerlegungen werden nicht vermischt', () {
      final a = teile(geheimnis, schwelle: 2, anzahl: 3);
      final b = teile(geheimnis, schwelle: 2, anzahl: 3);
      expect(
        () => setzeZusammen([a[0], b[1]]),
        throwsA(isA<TeilgeheimnisException>().having(
            (e) => e.message, 'message', contains('verschiedenen'))),
      );
    });

    test('doppelter Teil wird abgelehnt', () {
      final alle = teile(geheimnis, schwelle: 2, anzahl: 3);
      expect(
        () => setzeZusammen([alle[1], alle[1]]),
        throwsA(isA<TeilgeheimnisException>().having(
            (e) => e.message, 'message', contains('doppelt'))),
      );
    });

    test('beschaedigter ueberzaehliger Teil faellt auf', () {
      final alle = teile(geheimnis, schwelle: 2, anzahl: 3);
      final kaputt = Teil(
        schwelle: 2,
        x: 3,
        gruppenId: alle[2].gruppenId,
        y: Uint8List.fromList(alle[2].y)..[5] ^= 0x01,
      );
      expect(
        () => setzeZusammen([alle[0], alle[1], kaputt]),
        throwsA(isA<TeilgeheimnisException>().having(
            (e) => e.message, 'message', contains('widersprechen'))),
      );
    });

    test('ungueltige Parameter', () {
      expect(() => teile(geheimnis, schwelle: 1, anzahl: 3),
          throwsArgumentError);
      expect(() => teile(geheimnis, schwelle: 4, anzahl: 3),
          throwsArgumentError);
      expect(() => teile(geheimnis, schwelle: 3, anzahl: 11),
          throwsArgumentError);
      expect(() => teile(Uint8List(0), schwelle: 2, anzahl: 3),
          throwsArgumentError);
    });

    test('einzelne Teile sehen zufaellig aus, nicht wie das Geheimnis', () {
      final alle = teile(geheimnis, schwelle: 2, anzahl: 5);
      for (final t in alle) {
        expect(t.y, isNot(equals(geheimnis)));
      }
    });
  });

  group('Textformat', () {
    // Fester Teil, damit die Tippfehler-Pruefung deterministisch ist.
    final fest = Teil(
      schwelle: 3,
      x: 2,
      gruppenId: [0xDE, 0xAD, 0xBE, 0xEF],
      y: _hexToBytes('00112233445566778899aabbccddeeff'),
    );

    test('Aufbau', () {
      final text = fest.alsText();
      expect(text, startsWith('BITDM-TEIL-1-3-2-'));
      // 20 Byte Nutzlast = 32 base32-Zeichen = 8 Viererbloecke + Pruefsumme.
      final bloecke = text.split('-').sublist(5);
      expect(bloecke.length, 9);
      expect(bloecke.every((b) => b.length == 4), isTrue);
      expect(RegExp(r'^[A-Z2-7-]+$').hasMatch(text.substring(16)), isTrue);
    });

    test('Rundreise', () {
      expect(Teil.ausText(fest.alsText()), fest);
      final alle = teile(Uint8List.fromList(List.filled(16, 7)),
          schwelle: 3, anzahl: 5);
      final zurueck = [for (final t in alle) Teil.ausText(t.alsText())];
      expect(zurueck, alle);
      expect(setzeZusammen(zurueck.sublist(2)), List.filled(16, 7));
    });

    test('toleriert Kleinschreibung, Leerzeichen, Umbrueche, Bindestriche', () {
      final text = fest.alsText();
      final ohneStriche = text.substring(17).replaceAll('-', '');
      final varianten = [
        text.toLowerCase(),
        '  $text \n',
        text.replaceAll('-', ' '),
        'bitdm teil 1 3 2 ${ohneStriche.toLowerCase()}',
        'BITDM-TEIL-1-3-2-${ohneStriche.substring(0, 7)}\n'
            '${ohneStriche.substring(7, 30)}  ${ohneStriche.substring(30)}',
        text.replaceAll('-', '--'),
      ];
      for (final v in varianten) {
        expect(Teil.ausText(v), fest, reason: v);
      }
    });

    test('Pruefsumme faengt jeden einzelnen Zeichen-Tippfehler ab', () {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      final text = fest.alsText();
      var geprueft = 0;
      for (var i = 17; i < text.length; i++) {
        if (text[i] == '-') continue;
        for (final c in alphabet.split('')) {
          if (c == text[i]) continue;
          final vertippt = text.replaceRange(i, i + 1, c);
          expect(() => Teil.ausText(vertippt),
              throwsA(isA<TeilgeheimnisException>()),
              reason: 'Stelle $i -> $c');
          geprueft++;
        }
      }
      expect(geprueft, 36 * 31);
    });

    test('Tippfehler in Schwelle oder Teilnummer faellt auf', () {
      final text = fest.alsText();
      expect(() => Teil.ausText(text.replaceFirst('-1-3-2-', '-1-4-2-')),
          throwsA(isA<TeilgeheimnisException>()));
      expect(() => Teil.ausText(text.replaceFirst('-1-3-2-', '-1-3-5-')),
          throwsA(isA<TeilgeheimnisException>()));
    });

    test('fremde oder kaputte Texte werden abgelehnt', () {
      final text = fest.alsText();
      for (final kaputt in [
        '',
        'hallo welt',
        text.replaceFirst('BITDM', 'BITXM'),
        text.replaceFirst('-1-3-2-', '-2-3-2-'),
        text.substring(0, text.length - 5), // Block fehlt
        text.replaceRange(20, 21, '0'), // kein base32-Zeichen
      ]) {
        expect(() => Teil.ausText(kaputt),
            throwsA(isA<TeilgeheimnisException>()),
            reason: kaputt);
      }
    });
  });

  group('Woerter', () {
    test('Rundreise mit BIP39-Testvektoren (12 Woerter)', () {
      final zwoelf =
          bip39TestVectors.where((v) => v.$2.split(' ').length == 12);
      expect(zwoelf, isNotEmpty);
      for (final (entropieHex, phrase, _) in zwoelf) {
        final woerter = phrase.split(' ');
        final alle = teileWoerter(woerter, schwelle: 3, anzahl: 5);
        // Die Teile enthalten genau die Entropie des Vektors.
        expect(setzeZusammen(alle.sublist(1, 4)), _hexToBytes(entropieHex));
        for (final auswahl in _teilmengen(alle, 3)) {
          expect(woerterAusTeilen(auswahl), woerter);
        }
      }
    });

    test('Rundreise ueber Text mit frisch erzeugter Phrase', () {
      final woerter = Bip39.generate();
      final texte = [
        for (final t in teileWoerter(woerter, schwelle: 2, anzahl: 3))
          t.alsText()
      ];
      expect(woerterAusTeilen([Teil.ausText(texte[2]), Teil.ausText(texte[0])]),
          woerter);
    });

    test('ungueltige Phrase wird abgelehnt', () {
      final falsch = List.filled(12, 'abandon'); // Pruefsumme falsch
      expect(() => teileWoerter(falsch, schwelle: 2, anzahl: 3),
          throwsA(isA<MnemonicException>()));
      expect(
          () => teileWoerter(List.filled(24, 'abandon'),
              schwelle: 2, anzahl: 3),
          throwsA(isA<MnemonicException>()));
    });

    test('Teile ohne 16 Byte Entropie ergeben keine Woerter', () {
      final alle = teile(Uint8List(8), schwelle: 2, anzahl: 2);
      expect(() => woerterAusTeilen(alle),
          throwsA(isA<TeilgeheimnisException>()));
    });
  });

  test('Zufallsquelle ist austauschbar (nur Tests) und deterministisch', () {
    final g = Uint8List.fromList(List.generate(16, (i) => i * 3));
    final a = teile(g, schwelle: 2, anzahl: 3, zufall: Random(42));
    final b = teile(g, schwelle: 2, anzahl: 3, zufall: Random(42));
    expect(a, b);
  });
}

/// Liefert f(3) des eindeutigen Grad-2-Polynoms durch (0, s), (x1, y1),
/// (x2, y2) — byteweise, per Lagrange ueber GF(256).
Uint8List _dritterPunkt(Teil p1, Teil p2, Uint8List s) {
  final xs = [0, p1.x, p2.x];
  const ziel = 3;
  int gewicht(int i) {
    var z = 1;
    var n = 1;
    for (var j = 0; j < 3; j++) {
      if (j == i) continue;
      z = Gf256.mul(z, ziel ^ xs[j]);
      n = Gf256.mul(n, xs[i] ^ xs[j]);
    }
    return Gf256.div(z, n);
  }

  final w = [gewicht(0), gewicht(1), gewicht(2)];
  return Uint8List.fromList([
    for (var b = 0; b < s.length; b++)
      Gf256.mul(s[b], w[0]) ^ Gf256.mul(p1.y[b], w[1]) ^ Gf256.mul(p2.y[b], w[2]),
  ]);
}
