// netz_typen.dart — was beide Netzweichen gemeinsam haben.
//
// Die Weiche selbst steht in netz_zugang.dart. Diese Typen liegen getrennt,
// weil BEIDE Zweige (dart:io und Browser) sie brauchen, und ein Zweig den
// anderen nie importieren darf.

/// Eine HTTP-Antwort, auf das reduziert, was RelayClient liest.
class NetzAntwort {
  const NetzAntwort(this.status, this.text);

  final int status;

  /// Der Rumpf als Text (UTF-8).
  final String text;
}

/// Die Gegenstelle war gar nicht zu erreichen — kein HTTP-Status, sondern
/// kein Weg dorthin.
///
/// Auf dem Geraet steht dahinter eine SocketException. Im Browser ist der
/// Grund GRUNDSAETZLICH nicht zu erfahren: `fetch` verwirft mit einem
/// nackten TypeError, egal ob das Netz fehlt, das Zertifikat nicht passt oder
/// der Server keine CORS-Kopfzeilen schickt — der Browser verschweigt den
/// Unterschied absichtlich.
class NetzNichtErreichbar implements Exception {
  const NetzNichtErreichbar(this.grund);

  final String grund;

  @override
  String toString() => 'NetzNichtErreichbar: $grund';
}

/// Eine offene WebSocket-Verbindung.
///
/// So schmal wie das, was RelayClient von dart:io-WebSocket tatsaechlich
/// benutzt hat: Rahmen empfangen, Text senden, Zustand und Schlusscode
/// lesen, schliessen.
abstract class WsLeitung {
  /// Die eingehenden Rahmen, wie sie kommen (Text als String). Endet, wenn
  /// die Verbindung zu ist — danach steht [schlusscode].
  Stream<Object?> get rahmen;

  /// Ob gerade offen. Das Gegenstueck zu `readyState == WebSocket.open`.
  bool get offen;

  /// Der Code, mit dem die Gegenstelle geschlossen hat, oder null.
  int? get schlusscode;

  /// Schickt einen Textrahmen. Wirft StateError, wenn die Leitung zu ist.
  void sende(String text);

  Future<void> schliesse();
}
