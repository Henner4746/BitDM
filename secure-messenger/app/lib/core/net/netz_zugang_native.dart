// Der Zweig fuer Android, Windows und Linux: genau das dart:io, das vorher in
// relay_client.dart stand. Hier darf sich nichts anders verhalten als vorher.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'netz_typen.dart';
import 'netzweg.dart';

/// Oeffnet eine WebSocket. Wirft, wenn der Handschlag scheitert — wie
/// `WebSocket.connect`.
///
/// OHNE KOMPRESSION (permessage-deflate). dart:io bietet sie von sich aus an,
/// und uvicorn nimmt an. Dann verraet die Groesse auf der Leitung, was der
/// Tarnverkehr verbergen soll: eine echte Quittung nennt eine Adresse, die auf
/// dieser Verbindung schon vorkam, und schrumpft zu einem Rueckverweis von
/// rund 20 Byte; die Quittung eines Tarnrahmens nennt 56 zufaellige Zeichen,
/// die sich nicht verdichten lassen, rund 75 Byte (QA-Bericht vom 18.11.2026,
/// T3-COVER). Unverdichtet sind beide gleich lang — so sind sie gebaut
/// (relay_client.dart `_sendeGeraeusch`, relay_server.py Rahmen `ack`). Der
/// Chiffretext ist ohnehin nicht verdichtbar; gespart wurde nur an genau den
/// Stellen, die gleich aussehen sollen.
Future<WsLeitung> wsOeffnen(Uri uri) async =>
    // Ueber Tor, wenn eingeschaltet (netzweg.dart) — sonst wie immer.
    _IoLeitung(await WebSocket.connect(uri.toString(),
        compression: CompressionOptions.compressionOff,
        customClient: Netzweg.proxy == null ? null : Netzweg.httpClient()));

class _IoLeitung implements WsLeitung {
  _IoLeitung(this._ws);

  final WebSocket _ws;

  @override
  Stream<Object?> get rahmen => _ws;

  @override
  bool get offen => _ws.readyState == WebSocket.open;

  @override
  int? get schlusscode => _ws.closeCode;

  @override
  void sende(String text) => _ws.add(text);

  @override
  Future<void> schliesse() async {
    await _ws.close();
  }
}

/// Eine HTTP-Anfrage mit optionalem JSON-Rumpf.
///
/// Wirft [NetzNichtErreichbar], wenn keine Verbindung zustande kommt (vorher:
/// SocketException, von RelayClient in genau diese Meldung uebersetzt).
Future<NetzAntwort> netzAnfrage(String methode, Uri uri, {String? json}) async {
  final client = Netzweg.httpClient();
  try {
    final req = methode == 'POST'
        ? await client.postUrl(uri)
        : await client.getUrl(uri);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(json);
    }
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return NetzAntwort(resp.statusCode, text);
  } on SocketException catch (e) {
    throw NetzNichtErreichbar(e.message);
  } finally {
    client.close();
  }
}
