// notizen_status_test.dart — ein Status, der VOR seiner Nachricht eintrifft.
//
// Bei den Notizen gibt es keinen Empfaenger: der Kern setzt "sent" noch
// innerhalb von `sendMessage`, also bevor AppState die Nachricht in den
// Verlauf haengt. Bis 25.09.2026 verpuffte dieses Ereignis, und jede Notiz
// stand bis zum Neuoeffnen der Unterhaltung auf ◷ (gefunden im Emulatorlauf).

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState st;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  test('eine Notiz steht nach dem Senden auf "sent", nicht auf ◷', () async {
    await st.boot();
    await st.identitaetAnlegen();
    final id = await st.notizenOeffnen();

    await st.senden(id, 'Einkaufsliste Milch');
    await Future<void>.delayed(Duration.zero);

    final notiz = st.verlaufVon(id).last;
    expect(notiz.text, 'Einkaufsliste Milch');
    expect(notiz.status, MessageStatus.sent,
        reason: 'der vorausgelaufene Status ging verloren');
  });
  neustartTests();
}

// NACH EINEM NEUSTART: Gruppen und Vorschauen muessen ohne Zutun da sein.
// Bis 25.09.2026 lud der Start nur die Kontakte — die Gruppen fehlten in der
// Liste, und jede Zeile sagte "Neuer Kontakt" (Emulatorlauf).
void neustartTests() {
  test('nach dem Start stehen Gruppen und letzte Nachrichten schon da', () async {
    final core = FakeMessengerCore()..simulateExistingIdentity = true;
    await core.initialize();
    final kontakt = (await core.getContacts()).first.id;
    await core.legeGruppeAn('Wanderung', [kontakt]);

    final st = AppState(core);
    addTearDown(st.dispose);
    await st.boot();

    expect(st.gruppen.map((g) => g.name), ['Wanderung'],
        reason: 'die Gruppe fehlt nach dem Neustart');
    expect(st.verlaufVon(kontakt), isNotEmpty,
        reason: 'ohne Vorschau steht "Neuer Kontakt" in der Zeile');
    expect(st.verlaufVon(kontakt), hasLength(1),
        reason: 'fuer die Vorschau reicht die letzte Nachricht');
  });
}
