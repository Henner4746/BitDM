// verbindungs_wettlauf_test.dart — was passiert, waehrend connect() wartet.
//
// Zwischen dem Anfang und dem Ende von connect() liegen drei Wartepunkte:
// die Anmeldung, das Oeffnen der WebSocket, das Nonce. Auf einem Telefon
// dauert das zusammen leicht eine Sekunde — Zeit genug, dass der Nutzer
// etwas umlegt, die App weglegt oder das Netz wechselt.
//
// Der Ablauf in connect() weiss davon nichts. Er kommt aus dem Wartepunkt
// zurueck und macht weiter, als waere nichts gewesen. Das ist die Sorte
// Fehler, die im Betrieb selten und dann unerklaerlich auftritt: eine
// Verbindung, die niemand mehr kennt, die aber angemeldet ist und Nachrichten
// entgegennimmt.
//
// Gefunden von einem Suchagenten am 26.07.2026.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

/// Ein Relay, der beim Verbinden haengt, bis der Test ihn loslaesst.
class HaengenderRelay implements RelayClient {
  HaengenderRelay(this.identity);

  @override
  final SignalIdentity identity;

  static final gebaut = <HaengenderRelay>[];

  final losgelassen = Completer<void>();
  bool _verbunden = false;
  bool weggeraeumt = false;
  int anmeldungen = 0;

  /// Wie oft connect() ueberhaupt betreten wurde. Das ist der Moment, in dem
  /// die WebSocket aufgeht — also der erste, in dem Bytes hinausgehen.
  int verbindungsversuche = 0;

  final _ereignisse = StreamController<RelayEvent>.broadcast();

  @override
  Stream<RelayEvent> get events => _ereignisse.stream;
  @override
  bool get isConnected => _verbunden;
  @override
  String get address => identity.address;

  /// Wenn gesetzt, haengt schon die ANMELDUNG — der erste Wartepunkt.
  Completer<void>? haengtBeimAnmelden;

  /// Wenn true, wirft connect() nach dem Loslassen.
  bool wirftNachdem = false;

  @override
  Future<int> register(RelayPreKeyBundle b) async {
    anmeldungen++;
    final h = haengtBeimAnmelden;
    if (h != null) await h.future;
    return 100;
  }

  @override
  Future<void> connect() async {
    verbindungsversuche++;
    // HIER HAENGT ES. Genau der Wartepunkt, um den es geht.
    await losgelassen.future;
    if (wirftNachdem) throw const RelayException('Netz weg');
    _verbunden = true;
  }

  @override
  Future<void> send(String to, Uint8List c) async {}
  @override
  Future<void> close() async => _verbunden = false;
  @override
  Future<void> dispose() async {
    weggeraeumt = true;
    _verbunden = false;
    if (!_ereignisse.isClosed) await _ereignisse.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

void main() {
  late Directory ordner;
  late RealMessengerCore kern;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-wettlauf');
    HaengenderRelay.gebaut.clear();
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = HaengenderRelay(id);
        HaengenderRelay.gebaut.add(r);
        return r;
      },
    );
    await kern.initialize();
    await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  test('DISCONNECT WAEHREND CONNECT laesst nichts stehen', () async {
    final laeuft = kern.connect();
    await Future<void>.delayed(Duration.zero);
    final relay = HaengenderRelay.gebaut.single;

    // Der Nutzer legt um, waehrend connect() im Wartepunkt haengt.
    await kern.disconnect();
    expect(kern.connectionState, ConnectionState.disconnected);

    // Jetzt kommt der Wartepunkt zurueck.
    relay.losgelassen.complete();
    await laeuft;

    expect(kern.connectionState, ConnectionState.disconnected,
        reason: 'ein ueberholter Versuch darf den Zustand nicht mehr setzen');
    expect(relay.weggeraeumt, isTrue,
        reason: 'er muss SICH aufraeumen — sonst bleibt eine angemeldete '
            'Verbindung stehen, die niemand mehr kennt');
  });

  test('"nur in der Naehe" mitten im Verbinden bleibt gewahrt', () async {
    // Der schlimmere Fall. Der Schalter verspricht, dass NICHTS an einen
    // Server geht — aber die Pruefung darauf liegt am Anfang von connect()
    // und ist laengst vorbei, wenn der Nutzer ihn umlegt.
    final laeuft = kern.connect();
    await Future<void>.delayed(Duration.zero);
    final relay = HaengenderRelay.gebaut.single;

    await kern.setPreferences(const AppPreferences(nurNahbereich: true));

    relay.losgelassen.complete();
    await laeuft;

    expect(kern.connectionState, ConnectionState.disconnected);
    expect(relay.weggeraeumt, isTrue);
  });

  test('ein zweiter Versuch macht den ersten nicht kaputt', () async {
    // Die Gegenrichtung: der ueberholte Versuch darf beim Aufraeumen NICHT
    // die inzwischen aufgebaute Verbindung des spaeteren mitnehmen.
    final erster = kern.connect();
    await Future<void>.delayed(Duration.zero);
    final alt = HaengenderRelay.gebaut.single;

    await kern.disconnect();
    final zweiter = kern.connect();
    await Future<void>.delayed(Duration.zero);
    final neu = HaengenderRelay.gebaut.last;
    expect(identical(alt, neu), isFalse);

    neu.losgelassen.complete();
    await zweiter;
    expect(kern.connectionState, ConnectionState.online);

    // Jetzt erst wacht der alte auf.
    alt.losgelassen.complete();
    await erster;

    expect(kern.connectionState, ConnectionState.online,
        reason: 'der alte Versuch darf den neuen nicht abraeumen');
    expect(neu.weggeraeumt, isFalse);
    expect(alt.weggeraeumt, isTrue);
  });

  test('AUCH WAEHREND DER ANMELDUNG, nicht erst beim Verbinden', () async {
    // Der erste Wartepunkt. Er wird gern vergessen, weil "verbinden" nach
    // dem Oeffnen der Leitung klingt — die Anmeldung geht aber vorher
    // hinaus, und sie traegt eine Signatur mit dem Identitaetsschluessel.
    HaengenderRelay? relay;
    final eigenerOrdner = await Directory.systemTemp.createTemp('bitdm-anm');
    final zweiter = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${eigenerOrdner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) => relay ??= HaengenderRelay(id)
        ..haengtBeimAnmelden = Completer<void>(),
    );
    await zweiter.initialize();
    await zweiter.createIdentity();
    final laeuft = zweiter.connect();
    await Future<void>.delayed(Duration.zero);
    await zweiter.disconnect();

    final r = relay!;
    r.haengtBeimAnmelden!.complete();
    r.losgelassen.complete();
    await laeuft;

    expect(zweiter.connectionState, ConnectionState.disconnected);
    expect(r.verbindungsversuche, 0,
        reason: 'DAS IST DER PUNKT: nach dem Ueberholen darf gar keine '
            'Leitung mehr aufgehen. Wird erst nach connect() geprueft, ist '
            'die WebSocket schon offen und das Nonce signiert — genau das, '
            'was "nur in der Naehe" ausschliesst.');

    await zweiter.dispose();
    try {
      await eigenerOrdner.delete(recursive: true);
    } catch (_) {}
  });

  test('ein ueberholter Versuch, der DANN scheitert, faerbt nichts rot',
      () async {
    // Sonst setzt ein laengst vergessener Versuch den Zustand eines anderen
    // auf "Fehler" — und die Oberflaeche zeigt einen roten Punkt, obwohl die
    // Verbindung steht.
    final erster = kern.connect();
    await Future<void>.delayed(Duration.zero);
    final alt = HaengenderRelay.gebaut.single;
    alt.wirftNachdem = true;

    await kern.disconnect();
    final zweiter = kern.connect();
    await Future<void>.delayed(Duration.zero);
    HaengenderRelay.gebaut.last.losgelassen.complete();
    await zweiter;
    expect(kern.connectionState, ConnectionState.online);

    alt.losgelassen.complete();
    await erster;

    expect(kern.connectionState, ConnectionState.online,
        reason: 'der Fehlschlag gehoert einem Versuch, den es nicht mehr gibt');
    expect(HaengenderRelay.gebaut.last.weggeraeumt, isFalse);
  });

  test('ohne Stoerung verbindet es ganz gewoehnlich', () async {
    // Die Gegenprobe. Eine Absicherung, die den Normalfall kaputtmacht,
    // waere schlimmer als der Fehler, gegen den sie gebaut ist.
    final laeuft = kern.connect();
    await Future<void>.delayed(Duration.zero);
    HaengenderRelay.gebaut.single.losgelassen.complete();
    await laeuft;

    expect(kern.connectionState, ConnectionState.online);
    expect(HaengenderRelay.gebaut.single.weggeraeumt, isFalse);
    expect(HaengenderRelay.gebaut.single.anmeldungen, 1);
  });
}
