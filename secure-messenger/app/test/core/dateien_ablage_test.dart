// dateien_ablage_test.dart — wohin "Sicherung erstellen" am Rechner schreibt
// (Dateien.ablageOrdner, QA-Bericht vom 18.11.2026, T1-BAK-001).
//
// Unter Linux ohne `xdg-user-dir` gibt getDownloadsDirectory null, und
// getApplicationDocumentsDirectory wirft MissingPlatformDirectoryException.
// Bis 22.11.2026 flog die Ausnahme bis zum Knopf: kein Fehler, keine Datei.

import 'dart:io';

import 'package:bitdm/core/dateien.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bitdm_ablage'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  test('OHNE xdg-user-dir: weiter zum naechsten Ordner statt still abzubrechen',
      () async {
    final heim = Directory('${tmp.path}/heim')..createSync();
    final d = await Dateien.ablageOrdner([
      () async => null, // getDownloadsDirectory ohne xdg-user-dir
      () async => throw MissingPlatformDirectoryException(
          'Unable to get application documents directory'),
      () async => heim,
    ]);
    expect(d.path, heim.path);
  });

  test('EIN GENANNTER, ABER FEHLENDER ORDNER WIRD ANGELEGT', () async {
    // xdg nennt ~/Downloads, angelegt wurde es nie: File.copy scheiterte.
    final fehlt = Directory('${tmp.path}/Downloads');
    expect(fehlt.existsSync(), isFalse);
    final d = await Dateien.ablageOrdner([() async => fehlt]);
    expect(d.path, fehlt.path);
    expect(fehlt.existsSync(), isTrue);
  });

  test('DER ERSTE, DER TAUGT, GEWINNT', () async {
    final a = Directory('${tmp.path}/a')..createSync();
    final b = Directory('${tmp.path}/b')..createSync();
    final d = await Dateien.ablageOrdner([() async => a, () async => b]);
    expect(d.path, a.path);
  });

  test('TAUGT KEINER, KOMMT EIN FEHLER — DEN ZEIGT DIE OBERFLAECHE', () async {
    await expectLater(
        Dateien.ablageOrdner([
          () async => null,
          () async => throw MissingPlatformDirectoryException('weg'),
        ]),
        throwsA(isA<FileSystemException>()));
  });
}
