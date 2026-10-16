// flutter_test_config.dart — laeuft vor JEDER Testdatei (flutter_test sucht
// diese Datei im Testordner und ruft `testExecutable` statt `main` direkt).
//
// Seit 2.0.0 rechnet BitDM ueber Signals offizielle libsignal (Rust, ueber
// flutter_rust_bridge). Die native Bibliothek muss geladen sein, bevor
// irgendein Schluessel angefasst wird. Der Kern tut das beim Oeffnen
// (real_messenger_core `LibSignal.init()`); viele Tests bauen aber Identitaeten
// oder Buendel, ohne einen Kern zu oeffnen, und scheiterten dann mit "Bad
// state: flutter_rust_bridge has not been initialized". Hier einmal fuer alle —
// ein zweiter Aufruf je Isolate tut nichts.

import 'dart:async';

import 'package:libsignal/libsignal.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await LibSignal.init();
  await testMain();
}
