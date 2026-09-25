// browser_zugang.dart — was nur der Browser kann, hinter einer Weiche.
//
// Drei Dinge, die es auf dem Geraet anders (oder gar nicht) braucht:
//   * die Fachdatei der App-Sperre in localStorage statt auf der Platte
//     ([browserFachAblage]);
//   * eine Sicherung als Download anbieten ([browserDownload]) — es gibt
//     keinen "Speichern unter"-Kanal und kein Download-Verzeichnis;
//   * eine Sicherung aus einer gewaehlten Datei lesen ([browserDateiLesen]) —
//     die Dateiauswahl laeuft sonst ueber den Plattformkanal bitdm/dateien.
//
// Auf dem Geraet werfen alle drei UnsupportedError: sie werden dort nie
// aufgerufen, jeder Aufrufer steht hinter `kIsWeb`.
//
// dart.library.io als Schluessel — Begruendung in store/sqlite_zugang.dart.
export 'browser_zugang_web.dart' if (dart.library.io) 'browser_zugang_native.dart';
