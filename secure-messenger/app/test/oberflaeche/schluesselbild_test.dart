// schluesselbild_test.dart — das Randomart aus einem Schluessel.

import 'package:bitdm/schluesselbild.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final a = 'xajds3slalq7guxnuzsp3xt42aq2c77dhtnzy4irwcpuyxuynitxwk3v';
  final b = 'xllwgcdofmcjnkiekbzvey5uo6nlqauaklvs6arccu5cayqe4vpxs7jd';

  test('derselbe Schluessel ergibt immer dasselbe Bild', () {
    expect(Schluesselbild.alsText(a), Schluesselbild.alsText(a));
  });

  test('Schreibweise egal: Grossbuchstaben und Bindestriche wie in der Anzeige', () {
    final angezeigt = a.toUpperCase().replaceAllMapped(
        RegExp(r'.{4}'), (m) => '${m[0]}-');
    expect(Schluesselbild.alsText(angezeigt), Schluesselbild.alsText(a));
  });

  test('ein anderer Schluessel ergibt ein anderes Bild', () {
    expect(Schluesselbild.alsText(b), isNot(Schluesselbild.alsText(a)));
  });

  test('17 x 9 Felder, der Weg beginnt in der Mitte', () {
    final zeilen = Schluesselbild.alsText(a).split('\n');
    expect(zeilen, hasLength(9));
    expect(zeilen.every((z) => z.length == 17), isTrue);
    final f = Schluesselbild.felder(a);
    expect(f[4 * 17 + 8], anyOf(-1, -2), reason: 'der Start liegt nicht in der Mitte');
    expect(f.where((v) => v == -1 || v == -2), isNotEmpty);
  });
}
