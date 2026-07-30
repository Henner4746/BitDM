// schalter_test.dart — der Schalter muss halten, auch wenn der Funk nicht kann.
//
// WARUM DAS EIN EIGENER TEST IST
//
// Am 28.07.2026 liess sich "Bluetooth benutzen" auf ZWEI echten Telefonen
// nicht mehr einschalten. Er sprang kommentarlos zurueck, kein Hinweis, kein
// Protokolleintrag. Der Verbindungstest zeigte den Nahbereich gar nicht erst
// an — weil er nur erscheint, wenn `naheAn` wahr ist, und das wurde es nie.
//
// Der Fehler war NICHT im Schalter. Er war zwei Schichten tiefer:
// `setPreferences` wartete auf das Einrichten des Funks, und `_richteNaheEin`
// haengt an einer Kette (`_nahLauf.then(...)`). Wirft ein Glied, gilt zweierlei:
//
//   1. Der Fehler fliegt bis in `AppState.setzeEinstellungen` und die Zeile
//      `einstellungen = neu` wird nie erreicht — die Einstellung ist zwar
//      gespeichert, die Oberflaeche weiss es nur nicht.
//   2. Das Future der Kette bleibt DAUERHAFT im Fehler. `.then` darauf
//      scheitert sofort mit. Ab da richtet sich der Funk nie wieder ein, fuer
//      die ganze Laufzeit der App.
//
// Beides zusammen ergibt einen Schalter, der aussieht, als taete er nichts.
//
// Die Lehre, die hier festgeschrieben wird: EINE EINSTELLUNG DARF NIE AN
// IHRER FOLGE HAENGEN. Der Nutzer sagt, was er will; ob es klappt, ist eine
// zweite Frage und gehoert in die Diagnose, nicht in den Schalter.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/funk_attrappe.dart';

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

/// Ein Nahbereich, dessen `starte` wirft — wie auf einem Geraet, auf dem der
/// Bluetooth-Stapel gerade nicht mitspielt.
class BockigerNahbereich extends Nahbereich {
  BockigerNahbereich(FunkAttrappe funk) : super(funk: funk);

  bool bockt = true;
  int versuche = 0;

  @override
  Future<void> starte({
    required List<NahKontakt> kontakte,
    required Uint8List eigenerOeffentlicher,
  }) async {
    versuche++;
    if (bockt) throw StateError('Bluetooth mag heute nicht');
    return super.starte(
        kontakte: kontakte, eigenerOeffentlicher: eigenerOeffentlicher);
  }
}

void main() {
  late Directory ordner;
  late RealMessengerCore kern;
  late FunkAttrappe funk;
  late BockigerNahbereich nah;

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-schalter');
    funk = FunkAttrappe();
    nah = BockigerNahbereich(funk);
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      nahFactory: () => nah,
    );
    await kern.initialize();
    await kern.createIdentity();
  });

  tearDown(() async {
    await kern.dispose();
    await funk.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  test('DER SCHALTER HAELT, AUCH WENN DER FUNK NICHT KANN', () async {
    await expectLater(
      kern.setPreferences(const AppPreferences(naheAn: true)),
      completes,
      reason: 'ein Fehler im Funk darf nicht bis zum Speichern der '
          'Einstellung durchschlagen — sonst springt der Schalter zurueck, '
          'und der Nutzer erfaehrt nie, warum',
    );
    expect((await kern.getPreferences()).naheAn, isTrue);
  });

  test('und er ueberlebt einen Neustart', () async {
    // Die Gegenprobe zum Speichern: haette `setPreferences` vor dem Schreiben
    // abgebrochen, faende man hier wieder false.
    await kern.setPreferences(const AppPreferences(naheAn: true));
    expect((await kern.getPreferences()).naheAn, isTrue);
  });

  test('EIN FEHLSCHLAG VERGIFTET DIE KETTE NICHT', () async {
    // Der zweite, schlimmere Teil. `_richteNaheEin` haengt an einer Kette aus
    // `.then`; ein gescheitertes Future darin scheitert fuer immer weiter.
    // Ohne `catchError` richtet sich der Funk nach EINEM Fehlschlag nie wieder
    // ein — auch dann nicht, wenn Bluetooth laengst wieder geht.
    await kern.setPreferences(const AppPreferences(naheAn: true));
    final nachErstem = nah.versuche;
    expect(nachErstem, greaterThan(0), reason: 'es wurde gar nicht versucht');

    // Jetzt geht es wieder, und ein neuer Anlass kommt.
    nah.bockt = false;
    await kern.setPreferences(const AppPreferences(naheAn: false));
    await kern.setPreferences(const AppPreferences(naheAn: true));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(nah.versuche, greaterThan(nachErstem),
        reason: 'nach dem Fehlschlag wurde nie wieder versucht — die Kette '
            'ist im Fehler haengengeblieben');
  });

  test('und der Verbindungstest sagt dann die Wahrheit', () async {
    // Der Schalter steht auf an, der Funk laeuft nicht. GENAU DAS muss die
    // Diagnose zeigen — nicht "OK", und nicht gar nichts.
    await kern.setPreferences(const AppPreferences(naheAn: true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(nah.laeuft, isFalse);

    nah.bockt = false;
    await kern.setPreferences(const AppPreferences(naheAn: false));
    await kern.setPreferences(const AppPreferences(naheAn: true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Ohne Kontakte bleibt er auch jetzt aus — richtig so, und der Test haelt
    // fest, dass das ein ANDERER Zustand ist als "hat geworfen".
    expect(nah.laeuft, isFalse);
    expect(nah.versuche, greaterThan(1));
  });
}
