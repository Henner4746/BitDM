// python_befehl.dart — womit die Testhilfen Python starten.
//
// `py -3` ist der Python-Starter von WINDOWS. Bis zum 14.10.2026 stand er fest
// in relay_process.dart und lager_process.dart, und auf Linux und macOS
// scheiterten deshalb 83 Tests ohne erkennbaren Grund: Process.start warf eine
// ProcessException, die Hilfe gab null zurueck, und der Test meldete "Relay
// startete nicht" statt "es gibt kein py" (Pruefung vom 14.10.2026, N5).

import 'dart:io';

/// Programm und feste Vorab-Argumente fuer Python 3.
///
/// BITDM_PYTHON ueberstimmt die Wahl, etwa fuer ein venv:
/// `BITDM_PYTHON=/pfad/zum/venv/bin/python flutter test`.
({String programm, List<String> vorab}) pythonBefehl() {
  final eigen = Platform.environment['BITDM_PYTHON'];
  if (eigen != null && eigen.isNotEmpty) {
    return (programm: eigen, vorab: const []);
  }
  if (Platform.isWindows) return (programm: 'py', vorab: const ['-3']);
  return (programm: 'python3', vorab: const []);
}

/// Startet Python mit [argumente] — dieselbe Wahl wie [pythonBefehl].
Future<Process> startePython(
  List<String> argumente, {
  Map<String, String>? environment,
}) {
  final py = pythonBefehl();
  return Process.start(py.programm, [...py.vorab, ...argumente],
      environment: environment);
}

/// Fuehrt Python mit [argumente] aus und wartet auf das Ende.
Future<ProcessResult> fuehrePythonAus(List<String> argumente) {
  final py = pythonBefehl();
  return Process.run(py.programm, [...py.vorab, ...argumente]);
}
