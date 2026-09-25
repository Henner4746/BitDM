// fach_ablage.dart — wo die Fachdatei liegt.
//
// Bis 25.09.2026 war das fest eine Datei (dart:io File) neben der Datenbank.
// Im Browser gibt es keine Dateien: `File.existsSync()` wirft dort
// UnsupportedError (dart-sdk/lib/_internal/js_runtime/lib/io_patch.dart), und
// damit ging im Browser weder eine Sperre einzurichten noch — schlimmer —
// ueberhaupt eine Identitaet anzulegen, denn `VaultSecretStore.write` fragt
// zuerst nach den Faechern.
//
// Diese Schnittstelle ist deshalb so schmal wie das, was VaultSecretStore
// tatsaechlich mit der Datei tut: nachsehen, lesen, als Ganzes ersetzen,
// loeschen. Die Browser-Fassung steht in core/browser/browser_zugang_web.dart
// (localStorage).

import 'dart:io';

abstract class FachAblage {
  /// Ob es die Fachdatei gibt.
  bool existiert();

  /// Der ganze Inhalt.
  Future<String> lies();

  /// Ersetzt den Inhalt als Ganzes. Ein Abbruch mittendrin darf KEINEN halben
  /// Inhalt zuruecklassen — sonst ein Tresor, den niemand mehr oeffnet.
  Future<void> schreibe(String inhalt);

  /// Entfernt sie. Wirft nicht, wenn es sie nicht gibt.
  void loesche();
}

/// Die Fachdatei auf der Platte — das Verhalten von vor der Schnittstelle.
class DateiFachAblage implements FachAblage {
  DateiFachAblage(this.datei);

  final File datei;

  @override
  bool existiert() => datei.existsSync();

  @override
  Future<String> lies() => datei.readAsString();

  @override
  Future<void> schreibe(String inhalt) async {
    // Ueber eine Nebendatei und dann umbenennen: ein Absturz mitten im
    // Schreiben liesse sonst eine halbe Datei zurueck — und damit einen
    // Tresor, den niemand mehr oeffnet.
    final neben = File('${datei.path}.neu');
    await neben.writeAsString(inhalt, flush: true);
    await neben.rename(datei.path);
  }

  @override
  void loesche() {
    if (datei.existsSync()) datei.deleteSync();
  }
}
