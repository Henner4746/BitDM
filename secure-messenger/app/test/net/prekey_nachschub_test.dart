// prekey_nachschub_test.dart — wie die Einmalschluessel zum Relay kommen.
//
// Zwei Fehler, die beim Gesamtlauf vom 16.10.2026 auffielen, und ihre
// Behebung:
//
// 1. DIE SCHLEIFE. Der Relay meldet `prekeys_low` unter 20 Kyber-
//    Einmalschluesseln; die App fuellte erst unter 5 nach und meldete sich bei
//    jedem Verbinden ergebnislos neu an, bis die Anmeldebremse des Relays
//    griff. Jetzt erzeugt `prekeys_low` IMMER einen frischen Satz.
// 2. DAS ERNEUTE HOCHLADEN. Jede Anmeldung lud ALLE lokalen Einmalschluessel
//    hoch, auch schon ausgegebene. Der Relay gab einen Schluessel dann ein
//    zweites Mal aus, und die Erstnachricht des Zweiten scheiterte. Jetzt geht
//    nur hin, was der Relay noch nie hatte.

import 'dart:io';

import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/relay_attrappe.dart';

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late RelayAttrappe relay;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 5)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return fertig();
  }

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-nachschub');
    lage = Relaylage();
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) => relay = RelayAttrappe(id, lage),
    );
    await kern.initialize();
    await kern.createIdentity();
    await kern.connect();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  Set<int> ec(int i) =>
      lage.anmeldungen[i].oneTimePreKeys.map((k) => k.keyId).toSet();
  Set<int> ky(int i) =>
      lage.anmeldungen[i].oneTimeKyberPreKeys.map((k) => k.keyId).toSet();

  test('die erste Anmeldung bringt den vollen Satz, mit Kyber', () {
    expect(lage.anmeldungen, hasLength(1));
    expect(ec(0), hasLength(RealMessengerCore.preKeyVorrat));
    expect(ky(0), hasLength(RealMessengerCore.kyberVorrat));
    expect(lage.anmeldungen.single.kyberPreKey, isNotNull);
    expect(ky(0), isNot(contains(lage.anmeldungen.single.kyberPreKeyId)),
        reason: 'der Last-Resort-Schluessel steht unter den Einmalschluesseln');
  });

  test('prekeys_low: GENAU EINE Neuanmeldung, und nur mit NEUEN Schluesseln',
      () async {
    relay.herein(const RelayPreKeysLow(3));
    expect(await warteBis(() => lage.anmeldungen.length >= 2), isTrue,
        reason: 'auf prekeys_low kam keine Neuanmeldung');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(lage.anmeldungen, hasLength(2),
        reason: 'eine Meldung, mehrere Anmeldungen — die Schleife');

    expect(ec(1), hasLength(RealMessengerCore.preKeyVorrat));
    expect(ky(1), hasLength(RealMessengerCore.kyberVorrat));
    expect(ec(1).intersection(ec(0)), isEmpty,
        reason: 'ein EC-Einmalschluessel ging ein zweites Mal zum Relay — '
            'er koennte dort schon ausgegeben sein');
    expect(ky(1).intersection(ky(0)), isEmpty,
        reason: 'ein Kyber-Einmalschluessel ging ein zweites Mal zum Relay');
  });

  test('neu verbinden ohne Aenderung meldet NICHT erneut an', () async {
    await kern.disconnect();
    await kern.connect();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(lage.anmeldungen, hasLength(1),
        reason: 'ohne neue Schluessel und ohne Erneuerung gibt es nichts, '
            'was eine Anmeldung richten koennte');
  });

  test('der lokale Bestand waechst nicht ohne Grenze', () async {
    for (var i = 0; i < 8; i++) {
      relay.herein(const RelayPreKeysLow(0));
      expect(await warteBis(() => lage.anmeldungen.length >= i + 2), isTrue);
    }
    final store = kern.signalStoreFuerTest;
    expect(store.preKeyCount,
        lessThanOrEqualTo(RealMessengerCore.preKeyHoechstzahl));
    expect(store.kyberEinmalCount,
        lessThanOrEqualTo(RealMessengerCore.kyberHoechstzahl));
    expect(store.letzteRettungId, isNotNull,
        reason: 'die Begrenzung hat den Last-Resort-Schluessel mitgenommen');
  });
}
