// formatierung_test.dart — *fett*, _kursiv_, ~durch~, `fest`, ||Spoiler||.
//
// Die Haelfte der Faelle prueft, was NICHT formatiert werden darf: eine
// Rechnung, ein Dateiname, ein einzelnes Sternchen. Ein Formatierer, der zu
// gierig ist, verstuemmelt gewoehnliche Saetze — das faellt mehr auf als
// eine fehlende Auszeichnung.

import 'package:bitdm/formatierung.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> z(String s) =>
    Formatierung.zerlege(s).map((a) => a.toString()).toList();

void main() {
  group('was formatiert wird', () {
    test('die fuenf Arten', () {
      expect(z('*fett*'), ['fett|fett']);
      expect(z('_kursiv_'), ['kursiv|kursiv']);
      expect(z('~weg~'), ['weg|durch']);
      expect(z('`code`'), ['code|fest']);
      expect(z('||geheim||'), ['geheim|spoiler']);
    });

    test('mitten im Satz, mit Satzzeichen danach', () {
      expect(z('Das ist *wichtig*, oder?'),
          ['Das ist ', 'wichtig|fett', ', oder?']);
    });

    test('verschachtelt', () {
      expect(z('*fett _und kursiv_*'), ['fett |fett', 'und kursiv|fett|kursiv']);
    });

    test('in festem Text wird nichts weiter ausgewertet', () {
      expect(z('`a*b*c`'), ['a*b*c|fest']);
    });
  });

  group('was NICHT formatiert wird', () {
    test('eine Rechnung', () => expect(z('2*3*4'), ['2*3*4']));
    test('ein Dateiname', () => expect(z('datei_name_neu.txt'), ['datei_name_neu.txt']));
    test('ein einzelnes Zeichen', () => expect(z('5 * 3'), ['5 * 3']));
    test('leer dazwischen', () => expect(z('**'), ['**']));
    test('Leerzeichen am Rand', () => expect(z('* nicht *'), ['* nicht *']));
    test('ungeschlossen', () => expect(z('*offen'), ['*offen']));
  });

  test('tausend Schichten laufen nicht ueber', () {
    final s = '${'*_~' * 1000}x${'~_*' * 1000}';
    expect(() => Formatierung.zerlege(s), returnsNormally);
  });

  testWidgets('ein Spoiler ist verdeckt, bis man ihn antippt', (tester) async {
    const verdeckt = Color(0xFF123456);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FormatierterText('Der Moerder ist ||der Gaertner||',
            stil: TextStyle(color: Colors.white),
            festStil: TextStyle(),
            verdeckt: verdeckt),
      ),
    ));
    TextSpan spoiler() {
      final rich = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
      return rich.children!.cast<TextSpan>().firstWhere((s) => s.text == 'der Gaertner');
    }

    expect(spoiler().style!.color, verdeckt, reason: 'der Spoiler ist lesbar');
    await tester.tap(find.byType(Text));
    await tester.pump();
    expect(spoiler().style!.color, isNot(verdeckt));
  });
}
