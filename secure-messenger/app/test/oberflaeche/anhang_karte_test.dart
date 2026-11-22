// anhang_karte_test.dart — die Karte "Wird geschickt" waehrend eines Versands
// (QA-Bericht vom 18.11.2026, T2-5GB).
//
// Zwei Fehler an derselben Karte: der Balken las unter einer Kennung, unter
// der nie ein Fortschritt stand (er blieb bei 0, bei fuenf Gigabyte eine
// Viertelstunde lang), und es gab keinen Knopf zum Abbrechen.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/anhang/anhang_versand.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late FakeMessengerCore kern;
  late AppState st;
  late String an;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bitdm_karte');
    kern = FakeMessengerCore();
    st = AppState(kern);
    await st.boot();
    await st.identitaetAnlegen();
    an = (await kern.getContacts())
        .firstWhere((k) => k.state == ContactState.active)
        .id;
  });

  tearDown(() {
    st.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File datei() => File('${tmp.path}/daten.bin')..writeAsBytesSync(List.filled(4096, 7));

  test('DER BALKEN DER KARTE BEWEGT SICH', () async {
    final gesehen = <double>[];
    void schau() {
      final k = st.schwebendeKennung;
      final f = k == null ? null : st.fortschritt[k];
      if (f != null) gesehen.add(f.anteil);
    }

    st.addListener(schau);
    await st.anhangSenden(an, datei(), name: 'daten.bin');
    st.removeListener(schau);
    expect(gesehen, isNotEmpty,
        reason: 'die Karte sah nie einen Fortschritt — bis 22.11.2026 blieb '
            'der Balken leer');
    expect(gesehen.last, greaterThan(0));
    expect(st.schwebendeKennung, isNull);
    expect(st.fortschritt, isEmpty, reason: 'nach dem Versand bleibt nichts stehen');
  });

  test('ABBRECHEN: nichts im Verlauf, keine Fehlermeldung', () async {
    final vorher = st.verlaufVon(an).length;
    st.addListener(() {
      final k = st.schwebendeKennung;
      if (k != null && st.fortschritt[k] != null) st.brichAnhangAb();
    });
    await st.anhangSenden(an, datei(), name: 'daten.bin');
    expect(st.verlaufVon(an), hasLength(vorher),
        reason: 'der abgebrochene Anhang steht trotzdem im Verlauf');
    expect(st.letzterFehler, isNull);
    expect(st.schwebendeKennung, isNull, reason: 'die Karte bleibt stehen');
  });

  test('ZU GROSS: SOFORT GESAGT, OHNE KARTE', () async {
    final karten = <String?>[];
    st.addListener(() => karten.add(st.schwebendeKennung));
    await st.anhangSenden(an, datei(),
        name: 'riesig.bin', groesse: AnhangVersand.hoechstGroesse + 1);
    expect(st.letzterFehler, startsWith('anhangZuGross:'));
    expect(karten.whereType<String>(), isEmpty,
        reason: 'fuer eine Datei, die nie hinausgeht, erschien die Karte');
  });
}
