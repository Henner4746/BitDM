// klartext_ordner_test.dart — wohin ein geoeffneter Anhang entschluesselt wird
// (RealMessengerCore.klarOrdnerFuer, Sicherheitsbewertung vom 23.11.2026,
// SEC-M2).
//
// Unter Linux lag die Klartextkopie bis 23.11.2026 im Profilordner auf der
// Platte, bis zum naechsten Start der App. Jetzt liegt sie in
// $XDG_RUNTIME_DIR — tmpfs, nur fuer den Benutzer, weg beim Abmelden.

import 'dart:io';

import 'package:bitdm/core/real_messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String db;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bitdm_klar');
    db = '${tmp.path}/profil/bitdm.db';
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows gibt Handles verzoegert frei.
    }
  });

  test('LINUX MIT XDG_RUNTIME_DIR: NICHT MEHR IM PROFILORDNER', () {
    final laufzeit = Directory('${tmp.path}/run')..createSync();
    final d = RealMessengerCore.klarOrdnerFuer(db,
        linux: true, umgebung: {'XDG_RUNTIME_DIR': laufzeit.path});
    expect(d.path, startsWith(laufzeit.path));
    expect(d.path, isNot(startsWith('${tmp.path}/profil')),
        reason: 'die Klartextkopie laege wieder auf der Platte');
  });

  test('JE DATENBANK EIN EIGENER ORDNER, FUER DIESELBE IMMER DERSELBE', () {
    final laufzeit = Directory('${tmp.path}/run')..createSync();
    final um = {'XDG_RUNTIME_DIR': laufzeit.path};
    final a = RealMessengerCore.klarOrdnerFuer(db, linux: true, umgebung: um);
    final b = RealMessengerCore.klarOrdnerFuer('${tmp.path}/zwei/bitdm.db',
        linux: true, umgebung: um);
    expect(a.path, isNot(b.path), reason: 'zwei Installationen raeumten einander auf');
    expect(RealMessengerCore.klarOrdnerFuer(db, linux: true, umgebung: um).path,
        a.path, reason: 'beim naechsten Start fand das Aufraeumen nichts');
  });

  test('OHNE BRAUCHBARES XDG_RUNTIME_DIR ODER AUSSERHALB VON LINUX: WIE BISHER', () {
    final alt = '${tmp.path}/profil/anhaenge/.klar';
    expect(RealMessengerCore.klarOrdnerFuer(db, linux: true, umgebung: const {}).path,
        alt);
    expect(
        RealMessengerCore.klarOrdnerFuer(db,
            linux: true, umgebung: {'XDG_RUNTIME_DIR': '${tmp.path}/gibtsnicht'}).path,
        alt);
    // Android braucht anhaenge/ fuer den FileProvider (dateipfade.xml).
    final laufzeit = Directory('${tmp.path}/run')..createSync();
    expect(
        RealMessengerCore.klarOrdnerFuer(db,
            linux: false, umgebung: {'XDG_RUNTIME_DIR': laufzeit.path}).path,
        alt);
  });
}
