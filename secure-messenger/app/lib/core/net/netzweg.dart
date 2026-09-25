// netzweg.dart — alle Verbindungen zu Relay und Zwischenlager, wahlweise ueber
// Tor (SOCKS5, zum Beispiel Orbot auf 127.0.0.1:9050).
//
// WOZU. Der Relay sieht die IP-Adresse jedes Geraets, das sich verbindet —
// nicht, was es schreibt, aber wann und von wo. Ueber Tor sieht er nur einen
// Tor-Ausgang (oder bei einer .onion-Adresse gar keinen), und der Tor-Knoten
// sieht nur verschluesselte Daten fuer relay.bitdm.net.
//
// WIE. Dart's HttpClient kennt keinen SOCKS-Proxy, aber eine
// `connectionFactory`: jede Verbindung, auch die des WebSockets (ueber
// `customClient`), geht durch diese eine Stelle. Hier wird sie durch SOCKS5
// gefuehrt — mit dem HOSTNAMEN, nicht mit einer vorher aufgeloesten Adresse:
// sonst fragte das Telefon den Namen beim eigenen DNS-Server an, und der
// wuesste, wer BitDM benutzt (DNS-Leck). Bei https macht diese Stelle auch das
// TLS selbst, denn mit einer eigenen connectionFactory nimmt HttpClient den
// Socket so, wie er kommt (dart-sdk lib/_http/http_impl.dart).
//
// AUF DER EBENE DES ROHSOCKETS: fuer TLS nimmt [RawSecureSocket.secure] das
// laufende Abo und schon gelesene Bytes offiziell entgegen. Mit dem Socket
// von dart:io ging das nicht — ein beendetes Abo schliesst dort die Leitung
// (im Test: "Connection terminated during handshake").
//
// Der Nahbereich (Bluetooth) ist davon nicht beruehrt: er braucht kein Netz.

import 'dart:async';
import 'dart:convert' show Encoding, utf8;
import 'dart:io';
import 'dart:typed_data';

/// Wohin die SOCKS5-Verbindungen gehen.
class SocksZiel {
  const SocksZiel(this.host, this.port);
  final String host;
  final int port;
}

class SocksException implements Exception {
  const SocksException(this.grund);
  final String grund;
  @override
  String toString() => 'SocksException: $grund';
}

class Netzweg {
  /// Der Proxy, oder null = direkt. Gesetzt vom Kern aus den Einstellungen.
  static SocksZiel? proxy;

  /// Ein HttpClient, der dem aktuellen Weg folgt.
  static HttpClient httpClient() {
    final c = HttpClient();
    final p = proxy;
    if (p == null) return c;
    c.findProxy = (_) => 'DIRECT';
    c.connectionFactory = (uri, _, _) async {
      final sicher = uri.scheme == 'https' || uri.scheme == 'wss';
      final port = uri.hasPort ? uri.port : (sicher ? 443 : 80);
      final aufbau = verbinde(p, uri.host, port, tls: sicher);
      return ConnectionTask.fromSocket(aufbau, () {});
    };
    return c;
  }

  /// Baut eine SOCKS5-Verbindung zu [host]:[port] auf (RFC 1928, ohne
  /// Anmeldung, Adressart 3 = Domainname) und legt bei [tls] TLS darueber.
  static Future<Socket> verbinde(SocksZiel p, String host, int port,
      {bool tls = false, Duration frist = const Duration(seconds: 45)}) async {
    final roh = await RawSocket.connect(p.host, p.port, timeout: const Duration(seconds: 10));
    final leser = _RohLeser(roh);
    try {
      // Begruessung: Version 5, ein Verfahren, "keine Anmeldung".
      _schreibeGanz(roh, [5, 1, 0]);
      final wahl = await leser.lies(2).timeout(frist);
      if (wahl[0] != 5 || wahl[1] != 0) {
        throw SocksException('Proxy lehnt ab (Verfahren ${wahl[1]})');
      }
      final name = host.codeUnits;
      if (name.isEmpty || name.length > 255) throw const SocksException('Hostname ungueltig');
      _schreibeGanz(roh, [5, 1, 0, 3, name.length, ...name, port >> 8, port & 0xFF]);
      final kopf = await leser.lies(4).timeout(frist);
      if (kopf[0] != 5) throw const SocksException('keine SOCKS5-Antwort');
      if (kopf[1] != 0) throw SocksException('Verbindung abgelehnt (Code ${kopf[1]})');
      // Die gebundene Adresse am Ende der Antwort wird gelesen und verworfen.
      final rest = switch (kopf[3]) {
        1 => 4 + 2,
        4 => 16 + 2,
        3 => (await leser.lies(1).timeout(frist))[0] + 2,
        _ => throw const SocksException('unbekannte Adressart'),
      };
      await leser.lies(rest).timeout(frist);
      final vorab = leser.nimmRest();
      if (!tls) return RohSocket(roh, abo: leser.abo, vorab: vorab);
      // Nach seiner Antwort schickt ein SOCKS-Proxy nichts, bis der Client
      // spricht; stuende hier doch etwas, ginge es beim TLS-Anfang verloren.
      if (vorab.isNotEmpty) throw const SocksException('Daten nach dem Handschlag');

      final sicher = await RawSecureSocket.secure(roh, host: host, subscription: leser.abo);
      return RohSocket(sicher);
    } catch (_) {
      roh.close();
      rethrow;
    }
  }

  static void _schreibeGanz(RawSocket s, List<int> daten) {
    var ab = 0;
    while (ab < daten.length) {
      ab += s.write(daten, ab);
    }
  }
}

/// Liest genau n Bytes aus den Ereignissen eines Rohsockets.
class _RohLeser {
  _RohLeser(this._s) {
    abo = _s.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = _s.read();
        if (d != null) _puffer.addAll(d);
      } else if (e == RawSocketEvent.readClosed || e == RawSocketEvent.closed) {
        _zu = true;
      }
      _pruefe();
    }, onError: (Object e) => _warten?.completeError(e));
  }

  final RawSocket _s;
  late final StreamSubscription<RawSocketEvent> abo;
  final _puffer = <int>[];
  bool _zu = false;
  Completer<List<int>>? _warten;
  int _brauche = 0;

  Future<List<int>> lies(int n) {
    _brauche = n;
    _warten = Completer<List<int>>();
    _pruefe();
    return _warten!.future;
  }

  List<int> nimmRest() {
    final aus = List<int>.of(_puffer);
    _puffer.clear();
    return aus;
  }

  void _pruefe() {
    final w = _warten;
    if (w == null || w.isCompleted) return;
    if (_puffer.length >= _brauche) {
      final aus = _puffer.sublist(0, _brauche);
      _puffer.removeRange(0, _brauche);
      w.complete(aus);
    } else if (_zu) {
      w.completeError(const SocksException('Proxy hat die Verbindung geschlossen'));
    }
  }
}

/// Ein [Socket] ueber einem Rohsocket (auch einem [RawSecureSocket]) — was
/// HttpClient und WebSocket von einer Verbindung brauchen: ein Strom von
/// Bytes hinein, ein IOSink hinaus.
class RohSocket extends StreamView<Uint8List> implements Socket {
  RohSocket._(this._roh, this._ctl) : super(_ctl.stream);

  factory RohSocket(RawSocket roh,
      {StreamSubscription<RawSocketEvent>? abo, List<int> vorab = const []}) {
    final ctl = StreamController<Uint8List>();
    final s = RohSocket._(roh, ctl);
    s._starte(abo, vorab);
    return s;
  }

  final RawSocket _roh;
  final StreamController<Uint8List> _ctl;
  final _offen = <int>[];
  final _fertig = Completer<void>();
  Completer<void>? _geleert;
  bool _schliessen = false;
  late StreamSubscription<RawSocketEvent> _abo;

  void _starte(StreamSubscription<RawSocketEvent>? abo, List<int> vorab) {
    void bei(RawSocketEvent e) {
      switch (e) {
        case RawSocketEvent.read:
          final d = _roh.read();
          if (d != null && !_ctl.isClosed) _ctl.add(d);
        case RawSocketEvent.write:
          _leere();
        case RawSocketEvent.readClosed:
        case RawSocketEvent.closed:
          if (!_ctl.isClosed) _ctl.close();
          if (!_fertig.isCompleted) _fertig.complete();
      }
    }

    if (vorab.isNotEmpty) _ctl.add(Uint8List.fromList(vorab));
    if (abo != null) {
      _abo = abo
        ..onData(bei)
        ..onError((Object e) => _ctl.addError(e));
      abo.resume();
    } else {
      _abo = _roh.listen(bei, onError: (Object e) => _ctl.addError(e));
    }
    _ctl.onPause = _abo.pause;
    _ctl.onResume = _abo.resume;
    _ctl.onCancel = () => _abo.cancel();
  }

  void _leere() {
    while (_offen.isNotEmpty) {
      final n = _roh.write(_offen);
      if (n <= 0) break;
      _offen.removeRange(0, n);
    }
    if (_offen.isEmpty) {
      _roh.writeEventsEnabled = false;
      _geleert?.complete();
      _geleert = null;
      if (_schliessen) _roh.shutdown(SocketDirection.send);
    } else {
      _roh.writeEventsEnabled = true;
    }
  }

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    _offen.addAll(data);
    _leere();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _ctl.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() {
    if (_offen.isEmpty) return Future.value();
    return (_geleert ??= Completer<void>()).future;
  }

  @override
  Future<void> close() async {
    _schliessen = true;
    await flush();
    _roh.shutdown(SocketDirection.send);
    return _fertig.future;
  }

  @override
  void destroy() {
    _roh.close();
    if (!_ctl.isClosed) _ctl.close();
    if (!_fertig.isCompleted) _fertig.complete();
  }

  @override
  Future<void> get done => _fertig.future;
  @override
  void write(Object? object) => add(encoding.encode('$object'));
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  InternetAddress get address => _roh.address;
  @override
  int get port => _roh.port;
  @override
  InternetAddress get remoteAddress => _roh.remoteAddress;
  @override
  int get remotePort => _roh.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) => _roh.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _roh.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _roh.setRawOption(option);
}
