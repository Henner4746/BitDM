// relay_wechsel_test.dart — wenn die App auf einen anderen Relay zeigt.
//
// WORUM ES GEHT: Die App merkt sich, dass sie sich angemeldet hat, damit sie
// es nicht bei jedem Verbinden wiederholt. Eine Anmeldung ersetzt beim Relay
// SAEMTLICHE One-Time-Prekeys durch die uebergebenen — wer sie ohne Not
// wiederholt, laesst jede Gegenstelle mit einem schon geholten Buendel ins
// Leere laufen.
//
// Der Vermerk galt zunaechst fuer JEDEN Server. Am 26.07.2026 im Emulator
// beobachtet: nach einem Wechsel der Adresse kam die App beim neuen Server
// als Unbekannte an, und der schloss die Verbindung sofort wieder. Sichtbar
// war davon nichts — kein Fehler, keine Meldung, nur eine Verbindung, die
// nicht zustande kam. Siehe docs/EIGENER-SERVER.md.
//
// Heute ist die Adresse fest eingebaut, also passiert das erst, wenn sie sich
// mit einer neuen Fassung der App aendert. Genau dann darf es nicht passieren.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _inhalt;
  @override
  Future<Uint8List?> read() async => _inhalt;
  @override
  Future<void> write(Uint8List e) async => _inhalt = e;
  @override
  Future<void> delete() async => _inhalt = null;
}

/// Ein Relay, der Buch fuehrt, wer sich bei ihm angemeldet hat.
///
/// Die Anmeldung GELINGT, und erst die Verbindung danach scheitert. Andernfalls
/// kaeme der Kern nie bis zu der Stelle, an der er sich den Vermerk notiert —
/// und der Test pruefte etwas anderes als gedacht.
class MerktSichDieAdresse implements RelayClient {
  MerktSichDieAdresse(this.uri, this.identity);

  final Uri uri;
  @override
  final SignalIdentity identity;

  static final angemeldetBei = <String>[];

  final _ereignisse = StreamController<RelayEvent>.broadcast();

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;
  @override
  bool get isConnected => false;
  @override
  String get address => identity.address;
  @override
  Future<void> connect() async => throw const RelayException('kein Netz');
  @override
  Future<int> register(RelayPreKeyBundle b) async {
    angemeldetBei.add(uri.toString());
    return 100;
  }

  @override
  Future<void> send(String to, Uint8List c) async =>
      throw const RelayException('kein Netz');
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async => _ereignisse.close();
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

void main() {
  late Directory ordner;
  late SpeicherImKopf speicher;
  late String db;

  final alt = Uri.parse('https://relay.bitdm.net');
  final neu = Uri.parse('https://relay2.bitdm.net');

  /// Ein Kern auf derselben Datenbank und demselben Geheimnis — also
  /// dieselbe Installation, nur eine andere Fassung der App.
  RealMessengerCore kern(Uri relay) => RealMessengerCore(
        secretStore: speicher,
        databasePath: db,
        relayUri: relay,
        relayFactory: MerktSichDieAdresse.new,
      );

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-wechsel');
    db = '${ordner.path}${Platform.pathSeparator}t.db';
    speicher = SpeicherImKopf();
    MerktSichDieAdresse.angemeldetBei.clear();

    final erster = kern(alt);
    await erster.initialize();
    await erster.createIdentity();
    await erster.connect();
    await erster.dispose();
  });

  tearDown(() async {
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  test('beim ersten Start meldet sie sich an', () {
    expect(MerktSichDieAdresse.angemeldetBei, [alt.toString()]);
  });

  test('beim zweiten Start NICHT noch einmal', () async {
    // Die Gegenprobe zum Test darunter. Ohne sie koennte der Vermerk kaputt
    // sein, und der Wechsel-Test bestuende trotzdem.
    final wieder = kern(alt);
    await wieder.initialize();
    await wieder.connect();
    await wieder.dispose();

    expect(MerktSichDieAdresse.angemeldetBei, [alt.toString()],
        reason: 'eine zweite Anmeldung wuerfe alle Prekeys beim Server weg');
  });

  test('BEI EINER ANDEREN ADRESSE SEHR WOHL', () async {
    final umgezogen = kern(neu);
    await umgezogen.initialize();
    await umgezogen.connect();
    await umgezogen.dispose();

    expect(MerktSichDieAdresse.angemeldetBei, [alt.toString(), neu.toString()],
        reason: 'sonst kommt sie beim neuen Server als Unbekannte an — und '
            'zwar lautlos');
  });

  test('und danach beim neuen auch nur einmal', () async {
    for (var i = 0; i < 2; i++) {
      final k = kern(neu);
      await k.initialize();
      await k.connect();
      await k.dispose();
    }
    expect(MerktSichDieAdresse.angemeldetBei, [alt.toString(), neu.toString()]);
  });

  test('eine Installation OHNE Vermerk gilt als hier angemeldet', () async {
    // ALT-INSTALLATIONEN. Vor dem 26.07.2026 stand nur die Zahl der Prekeys
    // in der Datenbank, nicht der Server dazu. Wuerde ein fehlender Eintrag
    // als "woanders" gelesen, meldete sich mit dem naechsten Update JEDE
    // bestehende Installation noch einmal an.
    final k = kern(alt);
    await k.initialize();
    k.datenbankFuerTest.transaction((raw) => raw.execute(
        "DELETE FROM meta WHERE key = 'relay_angemeldet_bei'"));
    await k.connect();
    await k.dispose();

    expect(MerktSichDieAdresse.angemeldetBei, [alt.toString()],
        reason: 'ohne Eintrag ist es dieser Relay — bis dahin gab es nur '
            'einen einzigen');
  });
}
