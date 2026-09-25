// ruhezeit_test.dart — das Fenster der Ruhezeiten, auch ueber Mitternacht.

import 'package:bitdm/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime um(int h, int m) => DateTime(2026, 9, 25, h, m);

void main() {
  test('aus heisst nie', () {
    expect(const AppPreferences().inRuhezeit(um(3, 0)), isFalse);
  });

  test('22:00 bis 07:00 geht ueber Mitternacht', () {
    const p = AppPreferences(ruheAn: true);
    expect(p.inRuhezeit(um(22, 0)), isTrue);
    expect(p.inRuhezeit(um(23, 59)), isTrue);
    expect(p.inRuhezeit(um(0, 0)), isTrue);
    expect(p.inRuhezeit(um(6, 59)), isTrue);
    expect(p.inRuhezeit(um(7, 0)), isFalse, reason: 'das Ende gehoert nicht mehr dazu');
    expect(p.inRuhezeit(um(12, 0)), isFalse);
    expect(p.inRuhezeit(um(21, 59)), isFalse);
  });

  test('ein Fenster am Tag: 13:00 bis 14:30', () {
    const p = AppPreferences(ruheAn: true, ruheVon: 13 * 60, ruheBis: 14 * 60 + 30);
    expect(p.inRuhezeit(um(13, 0)), isTrue);
    expect(p.inRuhezeit(um(14, 29)), isTrue);
    expect(p.inRuhezeit(um(14, 30)), isFalse);
    expect(p.inRuhezeit(um(12, 59)), isFalse);
  });

  test('gleicher Anfang und gleiches Ende ist kein Fenster', () {
    const p = AppPreferences(ruheAn: true, ruheVon: 600, ruheBis: 600);
    expect(p.inRuhezeit(um(10, 0)), isFalse);
  });
}
