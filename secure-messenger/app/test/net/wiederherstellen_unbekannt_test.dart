// wiederherstellen_unbekannt_test.dart — nach dem Wiederherstellen sagt die
// App, wenn der Relay zu den Woertern kein Geraet kennt (Sicherheitsbewertung
// vom 23.11.2026, SEC-H2).
//
// Die 12 Woerter haben nur vier Bit Pruefsumme. Etwa jede sechzehnte
// Verwechslung eines Wortes geht durch und ergibt still eine andere, leere
// Identitaet. Eine staerkere Pruefsumme passte nicht mehr zu den Woertern,
// die es schon gibt; der Relay weiss aber, ob unter einer Adresse je ein
// Geraet war.

import 'dart:io';

import 'package:bitdm/core/crypto/bip39.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/nutzer.dart';
import '../support/relay_process.dart';

void main() {
  Relay? relay;
  late Directory tmp;
  var n = 0;

  setUpAll(() async => relay = await Relay.starten());
  tearDownAll(() async => relay?.beenden());
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_woerter'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  Future<Nutzer> leer(String name) async {
    final u = Nutzer(name, '${tmp.path}/${name}_${n++}.db', relay!.uri);
    addTearDown(u.aufraeumen);
    await u.starten();
    return u;
  }

  test('Relay laeuft — sonst sagt hier nichts etwas aus', () {
    expect(relay, isNotNull);
  });

  test('WOERTER, ZU DENEN ES NIE EIN GERAET GAB: DER HINWEIS STEHT DA', () async {
    // Gueltige Woerter, die niemand je benutzt hat — genau das, was ein
    // durchgerutschter Tippfehler ergibt.
    final u = await leer('vertippt');
    await u.core.restoreIdentity(Bip39.generate());
    await u.core.connect();
    expect(u.core.wiederhergestelltUnbekannt, isTrue,
        reason: 'eine leere, fremde Identitaet entstand ohne jedes Wort');

    // "Die Woerter stimmen": weg, und zwar dauerhaft.
    u.core.vergissWiederhergestelltUnbekannt();
    expect(u.core.wiederhergestelltUnbekannt, isFalse);
    await u.neustart();
    await u.core.connect();
    expect(u.core.wiederhergestelltUnbekannt, isFalse);
  });

  test('DIE ECHTEN WOERTER EINER BENUTZTEN IDENTITAET: KEIN HINWEIS', () async {
    final alt = await leer('alt');
    final woerter = await alt.core.createIdentity();
    await alt.core.connect();

    final neu = await leer('neu');
    await neu.core.restoreIdentity(woerter);
    await neu.core.connect();
    expect(neu.core.wiederhergestelltUnbekannt, isFalse,
        reason: 'der Relay kennt ein Geraet dieser Identitaet');
  });

  test('EINE NEU ANGELEGTE IDENTITAET IST KEINE WIEDERHERSTELLUNG', () async {
    final u = await leer('frisch');
    await u.core.createIdentity();
    await u.core.connect();
    expect(u.core.wiederhergestelltUnbekannt, isFalse);
  });
}
