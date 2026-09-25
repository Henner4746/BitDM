// spiegel_meldet_nicht_test.dart — was das Tablet NICHT tut.
//
// Seit dem Spiegel (§5) traegt `incomingMessages` auch das, was man selbst auf
// dem ANDEREN Geraet geschrieben hat: `_nimmSpiegel` legt es mit
// `isMine: true` ab und wirft es in denselben Strom. Ohne die Bedingung in
// app_state meldete das Tablet "eine neue Nachricht" fuer JEDEN Satz, den man
// gerade auf dem Handy tippt — und zaehlte ihn als ungelesen.
//
// ═══════════════════════════════════ WARUM AM TEXT UND NICHT AN DER MELDUNG
//
// `Benachrichtigungen.instanz` ist ein Einzelstueck mit einem Plugin dahinter.
// Ausserhalb eines Telefons scheitert sein `starte()`, `_bereit` bleibt false,
// und `zeigeNeueNachricht` kehrt in der ersten Zeile um — die Meldung selbst
// ist also gar nicht messbar, ohne lib/ anzufassen.
//
// MESSBAR IST DER ZAEHLER, und zwar ueber `mehrereNeuText`: der Text wird
// AUSGERECHNET, bevor die Meldung wegfaellt, und die Funktion dahinter ist
// von aussen setzbar (app_state.dart:440 — sie ist es, weil der Kern die
// Sprache des Nutzers nicht kennt). Also erst eine fremde Nachricht, damit
// der Zaehler auf 1 steht; ab der zweiten ungelesenen liefe `mehrereNeuText`.
// Laeuft sie fuer einen eigenen Spiegel, ist die Bedingung weg.

import 'dart:async';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ein Kern, dessen Eingangsstrom der Test in der Hand hat.
///
/// NUR DER STROM IST ERSETZT. Alles andere — Kontakte, Verbindung, Anhaenge —
/// kommt weiter von FakeMessengerCore; AppState braucht es beim Hochfahren.
/// Ein eigener Nachbau des ganzen Kerns waere eine zweite Fassung derselben
/// Sache, und die eine, die irgendwann nicht mehr stimmt.
class SpiegelKern extends FakeMessengerCore {
  final _strom = StreamController<Message>.broadcast();

  @override
  Stream<Message> get incomingMessages => _strom.stream;

  void herein(Message m) => _strom.add(m);

  @override
  Future<void> dispose() async {
    await _strom.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpiegelKern kern;
  late AppState st;
  late List<int> gezaehlt;

  Message nachricht({required bool meine, required String text}) => Message(
        id: text,
        chatId: 'chat',
        senderId: meine ? 'ich' : 'chat',
        text: text,
        isMine: meine,
        timestamp: DateTime.now().toUtc(),
        status: meine ? MessageStatus.sent : MessageStatus.delivered,
      );

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    kern = SpiegelKern()..simulateExistingIdentity = true;
    gezaehlt = [];
    st = AppState(kern)
      ..empfangsDienst = null
      ..mehrereNeuText = (n) {
        gezaehlt.add(n);
        return '$n neue Nachrichten';
      };
    await st.boot();
    // Nur wer NICHT hinsieht, bekommt eine Meldung. Im Vordergrund waere
    // dieser Test von vornherein stumm und saegte seinen eigenen Ast ab.
    st.vordergrund(false);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
    await kern.dispose();
  });

  test('EIN GESPIEGELTER EIGENER SATZ MELDET SICH NICHT UND ZAEHLT NICHT',
      () async {
    // MUTATION: in app_state `if (!_imVordergrund && !m.isMine)` ->
    //           `if (!_imVordergrund)`
    //
    // GEGENPROBE ZUERST: eine fremde Nachricht bringt den Zaehler auf 1. Bei 1
    // steht `einNeuText` — ein fester String, kein Haken. Ab der zweiten
    // ungelesenen liefe `mehrereNeuText`, und genau daran haengt die Messung.
    kern.herein(nachricht(meine: false, text: 'von Anna'));
    await Future<void>.delayed(Duration.zero);
    expect(st.verlaeufe['chat']?.map((m) => m.text), ['von Anna'],
        reason: 'der Strom muss ueberhaupt ankommen — sonst misst der Rest '
            'nichts');
    expect(gezaehlt, isEmpty, reason: 'die erste ungelesene ist "1 neu"');

    // UND JETZT DER SPIEGEL: was ich selbst auf dem Handy geschrieben habe.
    kern.herein(nachricht(meine: true, text: 'vom Handy'));
    await Future<void>.delayed(Duration.zero);

    expect(st.verlaeufe['chat']?.map((m) => m.text), ['von Anna', 'vom Handy'],
        reason: 'er MUSS im Verlauf landen — das ist ja der Sinn des Spiegels; '
            'nur melden darf er sich nicht');
    expect(gezaehlt, isEmpty,
        reason: 'eine eigene Nachricht ist keine ungelesene: sonst meldete '
            'das Tablet jeden Satz, den man gerade auf dem Handy tippt — '
            'gezaehlt=$gezaehlt');

    // Und eine weitere FREMDE zaehlt sehr wohl weiter. Ohne diese Haelfte
    // bliebe der Test auch dann gruen, wenn gar nicht mehr gezaehlt wird.
    kern.herein(nachricht(meine: false, text: 'noch was von Anna'));
    await Future<void>.delayed(Duration.zero);
    expect(gezaehlt, [2],
        reason: 'der Zaehler steht bei zwei fremden auf 2 — der eigene Spiegel '
            'dazwischen hat ihn nicht hochgesetzt');
  });
}
