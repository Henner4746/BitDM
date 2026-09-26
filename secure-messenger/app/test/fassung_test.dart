// fassung_test.dart — die eigene Fassung und der Vergleich von Fassungen.

import 'dart:io';

import 'package:bitdm/fassung.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appFassung PASST ZUR PUBSPEC — sonst meldet sich die App selbst als veraltet', () {
    final zeile = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((z) => z.startsWith('version:'));
    final name = zeile.substring('version:'.length).trim().split('+').first;
    expect(appFassung, name,
        reason: 'pubspec.yaml sagt $name, lib/fassung.dart sagt $appFassung');
  });

  group('vergleicheFassungen', () {
    test('Zahl fuer Zahl, nicht als Text', () {
      expect(vergleicheFassungen('1.10.0', '1.9.0'), greaterThan(0));
      expect(vergleicheFassungen('1.9.0', '1.10.0'), lessThan(0));
      expect(vergleicheFassungen('2.0.0', '1.99.99'), greaterThan(0));
      expect(vergleicheFassungen('1.8.10', '1.8.3'), greaterThan(0));
    });

    test('gleich ist gleich, auch mit fehlenden Stellen und Baunummer', () {
      expect(vergleicheFassungen('1.8.3', '1.8.3'), 0);
      expect(vergleicheFassungen('1.9', '1.9.0'), 0);
      expect(vergleicheFassungen('1.8.3+19', '1.8.3'), 0);
    });

    test('eine Vorabfassung ist aelter als dieselbe ohne Zusatz', () {
      expect(vergleicheFassungen('2.0.0-beta', '2.0.0'), lessThan(0));
      expect(vergleicheFassungen('2.0.0-beta', '1.9.9'), greaterThan(0));
    });

    test('Unlesbares ist nie neuer', () {
      expect(vergleicheFassungen('neu', '1.8.3'), isNull);
      expect(istNeuereFassung('neu', eigen: '1.8.3'), isFalse);
      expect(istNeuereFassung('', eigen: '1.8.3'), isFalse);
    });

    test('istNeuereFassung', () {
      expect(istNeuereFassung('1.9.0', eigen: '1.8.3'), isTrue);
      expect(istNeuereFassung('1.8.3', eigen: '1.8.3'), isFalse);
      expect(istNeuereFassung('1.8.2', eigen: '1.8.3'), isFalse);
    });
  });
}
