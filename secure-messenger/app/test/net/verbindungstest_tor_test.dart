// verbindungstest_tor_test.dart — "Ueber Tor verbinden" an, Orbot aus.
//
// Seit 27.09.2026. Auf einem S25 stand Tor an, ohne dass Orbot lief. Der
// Verbindungstest sagte nur "keine offene Verbindung zum Relay"; der Schalter,
// der es verursachte, kam nirgends vor. Jetzt gibt es einen eigenen Schritt,
// der den Proxy mit dem SOCKS5-Gruss fragt.

import 'dart:io';

import 'package:bitdm/core/anhang/lager_client.dart';
import 'package:bitdm/core/net/netzweg.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/verbindungstest.dart';
import 'package:flutter_test/flutter_test.dart';

class _Umgebung implements TestUmgebung {
  _Umgebung(this.torProxy);

  @override
  final SocksZiel? torProxy;
  @override
  Uri get relay => Uri.parse('https://relay.example');
  @override
  Uri get lager => Uri.parse('https://dateien.example');
  @override
  String? get eigeneAdresse => 'a' * 56;
  @override
  RelayClient? get relayClient => null;
  @override
  bool get nurNahbereich => false;
  @override
  bool get naheAn => false;
  @override
  bool get naheLaeuft => false;
  @override
  int get naheKontakte => 0;
  @override
  int get naheInReichweite => 0;
  @override
  HttpClient httpClient() => HttpClient();
  @override
  LagerClient lagerClient() => LagerClient(basis: lager);
}

Future<int> _freierPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  test('TOR AN, NIEMAND AUF DEM PORT: eigener Schritt, klarer Grund, Rest uebersprungen', () async {
    final port = await _freierPort();
    final b = await Verbindungstest(_Umgebung(SocksZiel('127.0.0.1', port))).lauf();
    final tor = b.schritte.firstWhere((s) => s.schluessel == 'pruefTor');
    expect(tor.befund, Befund.schlecht);
    expect(tor.detail, contains('Orbot'));
    expect(tor.detail, contains('127.0.0.1:$port'));
    expect(tor.detail, contains('ausschalten'));
    for (final k in ['pruefRelay', 'pruefAngemeldet', 'pruefLager']) {
      expect(b.schritte.firstWhere((s) => s.schluessel == k).befund, Befund.uebersprungen);
    }
  });

  test('AUF DEM PORT LAEUFT ETWAS, ABER KEIN SOCKS5: auch schlecht', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((c) {
      c.listen((_) {
        c.add('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits);
        c.close();
      });
    });
    final b = await Verbindungstest(_Umgebung(SocksZiel('127.0.0.1', server.port))).lauf();
    final tor = b.schritte.firstWhere((s) => s.schluessel == 'pruefTor');
    expect(tor.befund, Befund.schlecht);
    expect(tor.detail, contains('kein SOCKS5'));
  });

  test('ORBOT ANTWORTET: der Schritt ist gut, weiter geht es zum Relay', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((c) {
      c.listen((d) {
        if (d.length >= 3 && d[0] == 5) c.add(const [5, 0]);
      });
    });
    final b = await Verbindungstest(_Umgebung(SocksZiel('127.0.0.1', server.port))).lauf();
    expect(b.schritte.firstWhere((s) => s.schluessel == 'pruefTor').befund, Befund.gut);
    // Der Relay ist in dieser Umgebung nicht verbunden — der naechste Schritt
    // wird also wirklich ausgefuehrt und scheitert, statt uebersprungen zu werden.
    expect(b.schritte.firstWhere((s) => s.schluessel == 'pruefRelay').befund, Befund.schlecht);
  });

  test('TOR AUS: kein Tor-Schritt', () async {
    final b = await Verbindungstest(_Umgebung(null)).lauf();
    expect(b.schritte.any((s) => s.schluessel == 'pruefTor'), isFalse);
  });
}
