// Der Zweig fuer den Browser: WebSocket und fetch des Browsers, ueber
// package:web. Warum es ihn gibt und was er NICHT kann, steht in
// netz_zugang.dart.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'netz_typen.dart';

/// Oeffnet eine WebSocket und wartet, bis sie offen ist.
///
/// Scheitert der Aufbau, wirft das — wie `WebSocket.connect` auf dem Geraet.
/// Einen Grund nennt der Browser dabei nicht (ein `error`-Ereignis traegt mit
/// Absicht keinen); was bleibt, ist der Schlusscode, meist 1006.
Future<WsLeitung> wsOeffnen(Uri uri) async {
  final ws = web.WebSocket(uri.toString());
  final leitung = _BrowserLeitung(ws);
  final offen = Completer<void>();

  ws.onopen = ((web.Event _) {
    if (!offen.isCompleted) offen.complete();
  }).toJS;
  ws.onmessage = ((web.MessageEvent e) {
    final daten = e.data;
    // Der Relay schickt nur Text. Alles andere reicht die Leitung roh weiter,
    // und RelayClient verwirft es als "unlesbare Antwort" — wie vorher.
    leitung._ein.add(daten.isA<JSString>() ? (daten as JSString).toDart : daten);
  }).toJS;
  ws.onerror = ((web.Event _) {
    if (!offen.isCompleted) {
      offen.completeError(
          const NetzNichtErreichbar('WebSocket liess sich nicht oeffnen'));
    }
  }).toJS;
  ws.onclose = ((web.CloseEvent e) {
    leitung._schlusscode = e.code;
    if (!offen.isCompleted) {
      offen.completeError(NetzNichtErreichbar(
          'WebSocket vor dem Oeffnen geschlossen (Code ${e.code})'));
    }
    if (!leitung._ein.isClosed) leitung._ein.close();
  }).toJS;

  await offen.future;
  return leitung;
}

class _BrowserLeitung implements WsLeitung {
  _BrowserLeitung(this._ws);

  final web.WebSocket _ws;

  // Einzelabonnement wie der Strom von dart:io-WebSocket: RelayClient hoert
  // genau einmal zu. Rahmen, die vor dem Zuhoeren kommen, puffert der
  // Controller — das Nonce kann sehr schnell da sein.
  final _ein = StreamController<Object?>();
  int? _schlusscode;

  @override
  Stream<Object?> get rahmen => _ein.stream;

  @override
  bool get offen => _ws.readyState == web.WebSocket.OPEN;

  @override
  int? get schlusscode => _schlusscode;

  @override
  void sende(String text) {
    // dart:io wirft beim Schreiben auf eine geschlossene Leitung einen
    // StateError, und RelayClient faengt genau den (bestaetigeEmpfang). Der
    // Browser wirft stattdessen eine DOMException oder schluckt es still —
    // also hier dieselbe Zusage herstellen.
    if (!offen) throw StateError('WebSocket ist nicht offen');
    _ws.send(text.toJS);
  }

  @override
  Future<void> schliesse() async {
    final zu = _ein.isClosed ? Future<void>.value() : _ein.done;
    _ws.close();
    // Wie `await ws.close()` auf dem Geraet: zurueck erst, wenn sie zu ist.
    // Mit Frist — ein Browser, der das close-Ereignis verschluckt, darf das
    // Abmelden nicht festhalten.
    await zu.timeout(const Duration(seconds: 3), onTimeout: () {});
  }
}

/// Eine HTTP-Anfrage ueber `fetch`.
///
/// OHNE Cookies und ohne Referrer: der Relay braucht beides nicht, und beides
/// wuerde sonst verraten, von welcher Seite aus BitDM laeuft.
Future<NetzAntwort> netzAnfrage(String methode, Uri uri, {String? json}) async {
  final kopf = web.Headers();
  if (json != null) kopf.append('Content-Type', 'application/json');
  final web.Response antwort;
  try {
    antwort = await web.window
        .fetch(
          uri.toString().toJS,
          web.RequestInit(
            method: methode,
            headers: kopf,
            body: json?.toJS,
            credentials: 'omit',
            referrerPolicy: 'no-referrer',
            cache: 'no-store',
          ),
        )
        .toDart;
  } catch (e) {
    // Ein TypeError, der nichts sagt — siehe NetzNichtErreichbar.
    throw const NetzNichtErreichbar('der Browser liess die Anfrage nicht zu '
        '(kein Netz, oder der Relay erlaubt diese Herkunft nicht — CORS)');
  }
  final text = (await antwort.text().toDart).toDart;
  return NetzAntwort(antwort.status, text);
}
