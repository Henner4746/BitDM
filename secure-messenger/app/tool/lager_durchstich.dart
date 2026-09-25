// lager_durchstich.dart — den Anhang-Weg von diesem Rechner aus gehen.
//
// WOFUER: Henrik meldet "Anhänge gehen nicht", und die App sagt dazu nur
// "That did not go through". Der Weg hat fuenf Glieder — Verbindung,
// Anmeldung, Marke, Hochladen, Herunterladen —, und von aussen sieht man
// keines davon.
//
// Dieses Skript geht denselben Weg mit demselben Code wie die App, nur ohne
// Telefon. Was schiefgeht, steht danach als Ausnahme da und muss nicht
// erraten werden.
//
// ES LEGT EINE IDENTITAET AN. Sie landet beim echten Relay und gehoert
// hinterher geloescht — die Adresse steht am Ende der Ausgabe.
//
//   flutter test tool/lager_durchstich.dart
//
// Als Test und nicht als `dart run`: der Kern zieht ueber seine Abhaengigkeiten
// package:flutter herein, und das kann nur die Flutter-Werkzeugkette bauen.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/anhang/lager_client.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

class ImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

void sag(String s) => stdout.writeln(s);

void main() {
  test('Anhang-Weg gegen die echten Server', durchstich, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> durchstich() async {
  final ordner = await Directory.systemTemp.createTemp('bitdm-durchstich');
  final kern = RealMessengerCore(
    secretStore: ImKopf(),
    databasePath: '${ordner.path}${Platform.pathSeparator}d.db',
    relayUri: Uri.parse('https://relay.bitdm.net'),
  );

  var fehler = 0;
  try {
    await kern.initialize();
    await kern.createIdentity();
    sag('Identitaet   ${kern.myId}');
    sag('Relay        ${kern.relayUri}');
    sag('Lager        ${kern.lagerUri}');

    sag('');
    sag('1) verbinden ...');
    await kern.connect();
    sag('   Zustand: ${kern.connectionState}');
    if (kern.connectionState != ConnectionState.online) {
      sag('   ABBRUCH: nicht online');
      return;
    }

    sag('2) Marke holen ...');
    final zufall = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final kennung =
        List.generate(52, (_) => alphabet[zufall.nextInt(32)]).join();
    final probe =
        Uint8List.fromList(List<int>.generate(64, (_) => zufall.nextInt(256)));

    // Ein Messwerkzeug, kein App-Code: es braucht den Test-Einstieg.
    // ignore: invalid_use_of_visible_for_testing_member
    final marke = await kern.markeFuerTest(kennung, probe.length);
    sag('   ok, gueltig bis ${DateTime.fromMillisecondsSinceEpoch(marke.ablauf * 1000)}');

    final lager = LagerClient(basis: kern.lagerUri);
    try {
      sag('3) hochladen (${probe.length} Byte) ...');
      await lager.lege(
        Marke(
          kennung: marke.kennung,
          groesse: marke.groesse,
          ablauf: marke.ablauf,
          marke: marke.marke,
        ),
        probe,
      );
      sag('   ok');

      sag('4) herunterladen ...');
      final zurueck = await lager.hole(kennung, erwarteteGroesse: probe.length);
      sag('   ${zurueck.length} Byte zurueck');

      var gleich = zurueck.length == probe.length;
      for (var i = 0; gleich && i < probe.length; i++) {
        if (zurueck[i] != probe[i]) gleich = false;
      }
      sag(gleich ? '   INHALT STIMMT' : '   INHALT WEICHT AB');
      if (!gleich) fehler++;

      sag('5) wegwerfen ...');
      await lager.wirfWeg(kennung);
      sag('   ok');
    } finally {
      lager.schliesse();
    }

    sag('');
    sag(fehler == 0 ? 'DURCHSTICH GESCHAFFT' : 'MIT $fehler FEHLERN');
  } catch (e, s) {
    fehler++;
    sag('');
    sag('GESCHEITERT: ${e.runtimeType}');
    sag('  $e');
    sag(s.toString().split('\n').take(8).join('\n'));
  } finally {
    sag('');
    sag('AUFRAEUMEN: diese Adresse gehoert vom Relay geloescht:');
    try {
      sag('  ${kern.myId}');
    } catch (_) {}
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
    expect(fehler, 0, reason: 'siehe Ausgabe oben');
  }
}
