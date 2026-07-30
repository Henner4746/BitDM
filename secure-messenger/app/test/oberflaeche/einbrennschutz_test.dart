// einbrennschutz_test.dart — bewegt sich das Bild wirklich?
//
// WARUM DAS EINEN TEST BRAUCHT
//
// Der Einbrennschutz ist die Sorte Merkmal, die still aufhoeren kann zu
// wirken, ohne dass es jemand merkt: er soll ja gerade unsichtbar sein. Faellt
// der Takt aus — ein vergessenes `mounted`, ein Timer, der nie startet, ein
// Transform, das beim Umbau verlorengeht —, sieht die App exakt genauso aus
// wie vorher. Nur altert der Bildschirm darunter weiter.
//
// Gemerkt wuerde es erst an einem Geraet mit eingebrannter Reiterleiste, und
// dann ist es nicht mehr zu beheben.

import 'package:bitdm/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Wo der Inhalt gerade steht.
  Offset stelle(WidgetTester tester) {
    final m = tester
        .widget<Transform>(find.byType(Transform).first)
        .transform
        .getTranslation();
    return Offset(m.x, m.y);
  }

  testWidgets('DAS BILD STEHT NICHT STILL', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Einbrennschutz(child: SizedBox(width: 100, height: 100)),
    ));

    final anfang = stelle(tester);

    // Ein Takt ist 40 Sekunden. Nach einem muss sich etwas geaendert haben.
    await tester.pump(const Duration(seconds: 41));
    final danach = stelle(tester);

    expect(danach, isNot(anfang),
        reason: 'nach einem Takt steht der Inhalt noch an derselben Stelle — '
            'der Schutz wirkt nicht, und man saehe es der App nicht an');
  });

  testWidgets('aber es wandert nicht davon', (tester) async {
    // Die Gegenprobe, und sie ist keine Formsache: ein Schutz, der in eine
    // Richtung laeuft, schoebe die Oberflaeche mit der Zeit aus dem Bild.
    await tester.pumpWidget(const MaterialApp(
      home: Einbrennschutz(child: SizedBox(width: 100, height: 100)),
    ));

    var groesste = 0.0;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 41));
      final o = stelle(tester);
      groesste = [groesste, o.dx.abs(), o.dy.abs()]
          .reduce((a, b) => a > b ? a : b);
    }

    expect(groesste, lessThanOrEqualTo(3),
        reason: 'der Versatz waechst — nach ein paar Stunden waere die '
            'Oberflaeche sichtbar verschoben');
  });

  testWidgets('und es kehrt an jede Stelle zurueck', (tester) async {
    // Sonst waere die Alterung nur verlagert statt verteilt: eine Stellung,
    // die haeufiger drankommt als die anderen, brennt genauso ein — nur
    // langsamer.
    await tester.pumpWidget(const MaterialApp(
      home: Einbrennschutz(child: SizedBox(width: 100, height: 100)),
    ));

    final gesehen = <Offset>{stelle(tester)};
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 41));
      gesehen.add(stelle(tester));
    }

    expect(gesehen.length, greaterThanOrEqualTo(4),
        reason: 'der Inhalt pendelt zwischen zu wenigen Stellungen — das '
            'verteilt die Alterung kaum');
  });
}
