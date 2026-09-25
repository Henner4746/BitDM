// fernloeschung_test.dart — die Bremsen der Fernloeschung.
//
// Das ist die Stelle, an der ein Fehler entweder niemanden schuetzt oder
// jemandem das Telefon loescht, der es nicht wollte. Darum jede Bremse
// einzeln.

import 'package:bitdm/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final jetzt = DateTime.utc(2026, 9, 25, 12);
  const an = Fernloeschung(an: true, schwelle: 2, vertraute: ['bob', 'carl', 'dora']);

  test('ausgeschaltet: nichts', () {
    const aus = Fernloeschung(schwelle: 2, vertraute: ['bob', 'carl']);
    final f = aus.nimmAnfrage('bob', jetzt).nimmAnfrage('carl', jetzt);
    expect(f.faellig, isNull);
  });

  test('ein Fremder zaehlt nicht', () {
    final f = an.nimmAnfrage('eve', jetzt).nimmAnfrage('mallory', jetzt);
    expect(f.faellig, isNull);
    expect(f.anfragen, isEmpty);
  });

  test('einer allein reicht nie — auch zweimal nicht', () {
    final f = an.nimmAnfrage('bob', jetzt).nimmAnfrage('bob', jetzt.add(const Duration(minutes: 1)));
    expect(f.faellig, isNull);
    expect(f.anfragen.keys, ['bob']);
  });

  test('zwei verschiedene binnen 24 Stunden: Countdown von 10 Minuten', () {
    final f = an.nimmAnfrage('bob', jetzt).nimmAnfrage('carl', jetzt.add(const Duration(hours: 3)));
    expect(f.faellig, jetzt.add(const Duration(hours: 3, minutes: 10)));
  });

  test('eine Anfrage von vorgestern verfaellt', () {
    final f = an
        .nimmAnfrage('bob', jetzt)
        .nimmAnfrage('carl', jetzt.add(const Duration(hours: 25)));
    expect(f.faellig, isNull, reason: 'Bobs Anfrage war aelter als 24 Stunden');
    expect(f.anfragen.keys, ['carl']);
  });

  test('eine Schwelle unter zwei loest trotzdem nicht mit einer Anfrage aus', () {
    const eins = Fernloeschung(an: true, schwelle: 1, vertraute: ['bob']);
    expect(eins.nimmAnfrage('bob', jetzt).faellig, isNull);
  });

  test('ausgeloest bleibt ausgeloest — weitere Anfragen verschieben nichts', () {
    final f = an.nimmAnfrage('bob', jetzt).nimmAnfrage('carl', jetzt);
    final spaeter = f.nimmAnfrage('dora', jetzt.add(const Duration(minutes: 5)));
    expect(spaeter.faellig, f.faellig);
  });

  test('ueberlebt JSON', () {
    final f = an.nimmAnfrage('bob', jetzt).nimmAnfrage('carl', jetzt);
    final zurueck = Fernloeschung.ausJson(f.alsJson());
    expect(zurueck.faellig, f.faellig);
    expect(zurueck.vertraute, f.vertraute);
    expect(zurueck.schwelle, 2);
    expect(zurueck.anfragen, f.anfragen);
  });
}
