// relay_client.dart — die Verbindung zum Relay.
//
// Der Relay ist absichtlich dumm: er speichert Prekey-Bundles, reicht
// verschluesselte Umschlaege weiter und puffert sie, wenn der Empfaenger
// offline ist. Lesen kann er nichts. Diese Datei spricht mit ihm, sie
// entschluesselt selbst nichts — das macht die Schicht darueber.
//
// KEINE ZUSAETZLICHE ABHAENGIGKEIT: HTTP und WebSocket kommen aus dart:io.
// Ein Paket wie `http` waere hier zusaetzliche Angriffsflaeche fuer Arbeit,
// die das SDK schon kann.
//
// WAS DIESE SCHICHT BEWUSST NICHT TUT: sich selbst wieder verbinden. Wann ein
// Messenger nach einem Abbruch neu verbindet, ist keine Netzwerkfrage, sondern
// eine Akkufrage — und sie haengt am Vordergrunddienst und am Sparmodus, die
// es noch nicht gibt. Ein hier eingebauter Wiederverbindungsversuch wuerde
// spaeter gegen diese Entscheidungen arbeiten. Die Schicht meldet den Abbruch
// und ueberlaesst die Entscheidung nach oben.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/signal_identity.dart';
import 'relay_protocol.dart';

class RelayException implements Exception {
  final String grund;
  final int? statusCode;
  const RelayException(this.grund, {this.statusCode});
  @override
  String toString() =>
      'RelayException: $grund${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

sealed class RelayEvent {
  const RelayEvent();
}

/// Ein Umschlag fuer uns. [ciphertext] ist noch verschluesselt.
class RelayMessage extends RelayEvent {
  final String from;
  final Uint8List ciphertext;
  final DateTime at;
  const RelayMessage(
      {required this.from, required this.ciphertext, required this.at});
}

/// Der Vorrat an One-Time-Prekeys geht zur Neige.
class RelayPreKeysLow extends RelayEvent {
  final int remaining;
  const RelayPreKeysLow(this.remaining);
}

/// Der Server hat etwas bemaengelt, das keiner gesendeten Nachricht zuzuordnen
/// war.
class RelayProtocolError extends RelayEvent {
  final String reason;
  const RelayProtocolError(this.reason);
}

/// Die Verbindung ist weg. Ob und wann neu verbunden wird, entscheidet die
/// Schicht darueber.
class RelayDisconnected extends RelayEvent {
  final int? closeCode;
  const RelayDisconnected(this.closeCode);
}

class RelayClient {
  RelayClient({
    required this.baseUri,
    required this.identity,
    Duration? ackTimeout,
    Duration? handshakeTimeout,
  })  : ackTimeout = ackTimeout ?? const Duration(seconds: 20),
        handshakeTimeout = handshakeTimeout ?? const Duration(seconds: 15);

  /// Etwa `https://relay.bitdm.net` oder `http://127.0.0.1:8099`.
  final Uri baseUri;
  final SignalIdentity identity;
  final Duration ackTimeout;
  final Duration handshakeTimeout;

  final _events = StreamController<RelayEvent>.broadcast();
  final _wartendeAcks = <String, Completer<void>>{};
  final _zufall = Random();

  WebSocket? _ws;
  var _laufendeNummer = 0;

  Stream<RelayEvent> get events => _events.stream;

  bool get isConnected => _ws?.readyState == WebSocket.open;

  String get address => identity.address;

  // ════════════════════════════════════════════════════════ Registrieren

  /// Meldet das Bundle beim Relay an — mit Besitznachweis.
  ///
  /// Zwei Schritte, und der zweite ist der Grund fuer den ersten: der Server
  /// gibt ein Einmal-Nonce aus, und die Signatur geht ueber Nonce UND
  /// Bundle-Inhalt. Wuerde nur das Nonce signiert, koennte jemand eine
  /// abgefangene Signatur nehmen und ein eigenes Bundle daruntersetzen — der
  /// Server speicherte dann einen fremden Schluessel unter dieser Adresse.
  ///
  /// Rueckgabe: wie viele One-Time-Prekeys der Server jetzt vorraetig hat.
  Future<int> register(RelayPreKeyBundle bundle) async {
    if (bundle.userId != address) {
      throw RelayException('Bundle gehoert zu einer anderen Adresse');
    }

    final challenge = await _postJson('/register/challenge', {
      'user_id': address,
    });
    final nonce = base64.decode(challenge['nonce']! as String);

    final signatur = Curve.calculateSignature(
      identity.keyPair.getPrivateKey(),
      bundle.registrationChallenge(Uint8List.fromList(nonce)),
    );

    final antwort = await _postJson('/register', {
      'bundle': bundle.toJson(),
      'signature': base64.encode(signatur),
    });
    return antwort['one_time_prekeys'] as int? ?? 0;
  }

  /// Holt das Bundle einer Gegenstelle, um eine Sitzung aufzubauen.
  Future<RelayBundleResponse> fetchBundle(String userId) async {
    final j = await _getJson('/prekey/$userId');
    return RelayBundleResponse.fromJson(j);
  }

  // ═══════════════════════════════════════════════════════════ Verbindung

  /// Verbindet und weist sich aus.
  ///
  /// Der Server schickt zuerst ein Nonce, das mit dem Identitaetsschluessel
  /// signiert zurueckkommen muss. Erst danach werden Nachrichten zugestellt.
  Future<void> connect() async {
    if (_ws != null) throw const RelayException('bereits verbunden');

    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '$_pfadOhneSchraegstrich/ws',
      queryParameters: {'user_id': address},
    );

    final WebSocket ws;
    try {
      ws = await WebSocket.connect(wsUri.toString());
    } on Object catch (e) {
      throw RelayException('Verbindung fehlgeschlagen: $e');
    }
    _ws = ws;

    final angemeldet = Completer<void>();
    ws.listen(
      (roh) => _verarbeite(roh, angemeldet),
      onDone: () {
        final code = ws.closeCode;
        _ws = null;
        _brichAlleAcksAb('Verbindung beendet');
        if (!angemeldet.isCompleted) {
          angemeldet.completeError(
              RelayException('Verbindung vor der Anmeldung beendet '
                  '(Code $code)'));
        }
        if (!_events.isClosed) _events.add(RelayDisconnected(code));
      },
      onError: (Object e) {
        if (!angemeldet.isCompleted) {
          angemeldet.completeError(RelayException('Verbindungsfehler: $e'));
        }
      },
      cancelOnError: false,
    );

    try {
      await angemeldet.future.timeout(handshakeTimeout);
    } on TimeoutException {
      await close();
      throw const RelayException('Anmeldung hat zu lange gedauert');
    }
  }

  String get _pfadOhneSchraegstrich =>
      baseUri.path.endsWith('/')
          ? baseUri.path.substring(0, baseUri.path.length - 1)
          : baseUri.path;

  void _verarbeite(dynamic roh, Completer<void> angemeldet) {
    final Map<String, Object?> m;
    try {
      m = (jsonDecode(roh as String) as Map).cast<String, Object?>();
    } catch (_) {
      // Kein JSON — der Server ist die einzige Gegenstelle, das sollte nicht
      // vorkommen. Nicht abstuerzen, aber melden.
      _events.add(const RelayProtocolError('unlesbare Antwort'));
      return;
    }

    switch (m['type']) {
      case 'challenge':
        final nonce = base64.decode(m['nonce']! as String);
        final sig = Curve.calculateSignature(
          identity.keyPair.getPrivateKey(),
          Uint8List.fromList(nonce),
        );
        _ws?.add(jsonEncode({'signature': base64.encode(sig)}));

      case 'auth_result':
        if (m['ok'] == true) {
          if (!angemeldet.isCompleted) angemeldet.complete();
        } else if (!angemeldet.isCompleted) {
          angemeldet.completeError(
              const RelayException('der Server hat die Anmeldung abgelehnt'));
        }

      case 'message':
        _events.add(RelayMessage(
          from: m['from'] as String? ?? '',
          ciphertext:
              Uint8List.fromList(base64.decode(m['ciphertext']! as String)),
          at: DateTime.fromMillisecondsSinceEpoch(
              (((m['ts'] as num?) ?? 0) * 1000).round(),
              isUtc: true),
        ));

      case 'prekeys_low':
        _events.add(RelayPreKeysLow(m['remaining'] as int? ?? 0));

      case 'ack':
        _loeseAckAus(m['id'], null);

      case 'error':
        final grund = m['reason'] as String? ?? 'unbekannter Fehler';
        _loeseAckAus(m['id'], grund);

      default:
        _events.add(RelayProtocolError('unbekannte Nachrichtenart: '
            '${m['type']}'));
    }
  }

  void _loeseAckAus(Object? id, String? fehler) {
    // Ohne Kennung laesst sich nichts zuordnen — dann kann der Fehler nur
    // allgemein gemeldet werden.
    final c = id is String ? _wartendeAcks.remove(id) : null;
    if (c == null) {
      if (fehler != null) _events.add(RelayProtocolError(fehler));
      return;
    }
    if (fehler == null) {
      c.complete();
    } else {
      c.completeError(RelayException(fehler));
    }
  }

  void _brichAlleAcksAb(String grund) {
    for (final c in _wartendeAcks.values) {
      if (!c.isCompleted) c.completeError(RelayException(grund));
    }
    _wartendeAcks.clear();
  }

  // ════════════════════════════════════════════════════════════════ Senden

  /// Schickt einen bereits verschluesselten Umschlag an [to].
  ///
  /// Kehrt zurueck, sobald der Server bestaetigt hat — also entweder
  /// weitergeleitet (Empfaenger online) oder gepuffert (Empfaenger offline).
  /// Beides heisst: die Nachricht liegt nicht mehr nur bei uns.
  ///
  /// Die Kennung ist der Grund, warum das ueberhaupt zuverlaessig geht: ohne
  /// sie traegt die Bestaetigung nur die Zieladresse, und bei zwei Nachrichten
  /// an denselben Kontakt liesse sich nicht sagen, welche gemeint ist.
  Future<void> send(String to, Uint8List ciphertext) async {
    final ws = _ws;
    if (ws == null) throw const RelayException('nicht verbunden');

    final id = '${_laufendeNummer++}-${_zufall.nextInt(1 << 32)}';
    final warte = Completer<void>();
    _wartendeAcks[id] = warte;

    ws.add(jsonEncode({
      'type': 'message',
      'id': id,
      'to': to,
      'ciphertext': base64.encode(ciphertext),
    }));

    try {
      await warte.future.timeout(ackTimeout);
    } on TimeoutException {
      _wartendeAcks.remove(id);
      throw const RelayException('keine Bestaetigung vom Server');
    }
  }

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    _brichAlleAcksAb('Verbindung geschlossen');
    await ws?.close();
  }

  /// Gibt alle Mittel frei. Danach ist dieser Client nicht mehr verwendbar.
  Future<void> dispose() async {
    await close();
    await _events.close();
  }

  // ══════════════════════════════════════════════════════════════════ HTTP

  Future<Map<String, Object?>> _postJson(
      String pfad, Map<String, Object?> body) async {
    return _anfrage('POST', pfad, body);
  }

  Future<Map<String, Object?>> _getJson(String pfad) async {
    return _anfrage('GET', pfad, null);
  }

  Future<Map<String, Object?>> _anfrage(
      String methode, String pfad, Map<String, Object?>? body) async {
    final client = HttpClient();
    try {
      final uri = baseUri.replace(path: '$_pfadOhneSchraegstrich$pfad');
      final req = methode == 'POST'
          ? await client.postUrl(uri)
          : await client.getUrl(uri);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();

      if (resp.statusCode >= 400) {
        // Der Server schickt bei Fehlern {"detail": "..."}.
        String grund = text;
        try {
          final j = jsonDecode(text);
          if (j is Map && j['detail'] != null) grund = '${j['detail']}';
        } catch (_) {
          // Kein JSON — dann eben der Rohtext.
        }
        throw RelayException(grund, statusCode: resp.statusCode);
      }

      final j = jsonDecode(text);
      if (j is! Map) throw const RelayException('unerwartete Antwort');
      return j.cast<String, Object?>();
    } on SocketException catch (e) {
      throw RelayException('Relay nicht erreichbar: ${e.message}');
    } finally {
      client.close();
    }
  }
}
