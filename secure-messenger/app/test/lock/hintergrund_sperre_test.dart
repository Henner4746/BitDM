// hintergrund_sperre_test.dart — sperrt die App, WAEHREND sie weg ist?
//
// DIE LUECKE (Sicherheitspruefung vom 18.10.2026): die Frist wurde nur beim
// Zurueckkommen geprueft. Bei "sofort" blieben Entropie, Datenbank und
// Schluessel offen, solange die App im Hintergrund lag. Zu sehen war davon
// nichts — beim Zurueckkommen sperrte sie ja —, aber wer den Prozess lesen
// kann, las in der Zeit alles.
//
// auto_sperre_test prueft, was beim Zurueckkommen passiert. Hier geht es um
// die Zeit dazwischen.

import 'dart:async';
import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/empfang.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i));
  @override
  Future<Uint8List?> read() async => inhalt;
  @override
  Future<void> write(Uint8List e) async => inhalt = e;
  @override
  Future<void> delete() async => inhalt = null;
}

/// Der gesicherte Bereich. [halt] laesst das Lesen warten — wie ein
/// Fingerabdruck-Dialog, auf den noch niemand den Finger gelegt hat.
class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};
  Completer<void>? halt;

  @override
  Future<String?> lies(String k) async {
    final h = halt;
    if (h != null) await h.future;
    return daten[k];
  }

  @override
  Future<void> schreibe(String k, String v) async => daten[k] = v;
  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

class FakeDienst implements EmpfangsDienst {
  bool _laeuft = false;
  @override
  bool get laeuft => _laeuft;
  @override
  Future<void> starte({required String titel, required String text}) async =>
      _laeuft = true;
  @override
  Future<void> stoppe() async => _laeuft = false;
}

/// Eine Frist, die ein Test abwarten kann. Die Oberflaeche bietet nur 0, 60,
/// 300 und "nie" an; gerechnet wird mit jeder Dauer gleich.
const kurz = Duration(milliseconds: 80);

/// Lange genug, dass ein Wecker mit [kurz] sicher gelaufen ist.
Future<void> abwarten() => Future<void>.delayed(const Duration(milliseconds: 400));

void main() {
  late Directory verzeichnis;
  late VaultSecretStore tresor;
  late FakeAblage ablage;
  late FakeMessengerCore core;
  late FakeDienst dienst;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-hgsperre');
    ablage = FakeAblage();
    dienst = FakeDienst();
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: FakeBasis(),
      jetzt: () => 1000,
    );
    core = FakeMessengerCore()..simulateExistingIdentity = true;
    st = AppState(core, tresor: tresor, ablagen: (_) => ablage)
      ..empfangsDienst = dienst;
    await st.boot();
    await st.fuegeBiometrieHinzu();
    expect(tresor.istOffen, isTrue);
  });

  tearDown(() {
    st.dispose();
    core.dispose();
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Stellt eine Frist ein (wie die Oberflaeche) und kuerzt sie dann auf
  /// [kurz], damit der Test nicht eine Minute wartet.
  Future<void> mitFrist() async {
    await st.setzeSperrfrist(60);
    st.sperrfrist = kurz;
  }

  group('Bei "sofort"', () {
    test('DER FALL: der Tresor ist zu, sobald die App weg ist', () async {
      st.vordergrund(false);

      expect(tresor.istOffen, isFalse,
          reason: 'bis 18.10.2026 blieb er offen, bis die App wiederkam');
      expect(st.gesperrt, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(core.isInitialized, isFalse,
          reason: 'die Datenbank muss wirklich zu sein');
    });

    test('kommt sie zurueck, waehrend die Datenbank noch zugeht, fasst nichts '
        'den Kern an', () async {
      // Ohne `gesperrt` gleich zu Beginn von sperreWieder raeumte
      // `vordergrund(true)` abgelaufene Nachrichten auf — gegen einen Kern,
      // der gerade zuging (NotInitializedException).
      st.vordergrund(false);
      st.vordergrund(true);
      await Future<void>.delayed(Duration.zero);
      expect(st.gesperrt, isTrue);
      expect(await st.entsperreMitBiometrie(), isTrue);
    });
  });

  group('Mit Frist', () {
    test('offen, bis die Frist um ist — dann zu, auch ohne Zurueckkommen',
        () async {
      await mitFrist();
      st.vordergrund(false);
      expect(tresor.istOffen, isTrue,
          reason: 'eine kurze Abwesenheit darf nichts kosten');

      await abwarten();
      expect(tresor.istOffen, isFalse);
      expect(st.gesperrt, isTrue);
      expect(core.isInitialized, isFalse);
    });

    test('kommt sie vorher zurueck, sperrt der Wecker nicht nachtraeglich',
        () async {
      await mitFrist();
      st.vordergrund(false);
      st.vordergrund(true);
      await abwarten();
      expect(st.gesperrt, isFalse);
      expect(tresor.istOffen, isTrue);
    });

    test('DER HINTERGRUNDEMPFANG VERLAENGERT DIE FRIST NICHT', () async {
      // Entschieden am 18.10.2026 (app_state.dart, "Sperren im Hintergrund"):
      // die Einstellung sagt "wie lange die App im Hintergrund offen bleiben
      // darf" — und so lange bleibt sie offen, nicht laenger.
      await mitFrist();
      await st.setzeEmpfangsTakt(EmpfangsTakt.staendig);
      expect(st.empfangEndetMitFrist, isTrue,
          reason: 'die Einstellungen sollen das dazusagen');

      st.vordergrund(false);
      await Future<void>.delayed(Duration.zero);
      expect(dienst.laeuft, isTrue, reason: 'bis zur Frist wird empfangen');

      await abwarten();
      expect(tresor.istOffen, isFalse);
      expect(dienst.laeuft, isFalse,
          reason: 'ein Dienst mit "Empfangsbereit" neben einer gesperrten App '
              'behauptet etwas, das nicht stimmt');
    });

    test('"nie" bleibt offen', () async {
      await st.setzeSperrfrist(-1);
      expect(st.empfangEndetMitFrist, isFalse);
      st.vordergrund(false);
      await abwarten();
      expect(tresor.istOffen, isTrue);
      expect(st.gesperrt, isFalse);
    });
  });

  group('Die Ausnahmen haben eine Obergrenze', () {
    test('ein laufender Faktor schiebt auf — aber nicht endlos', () async {
      // Bei der USB-Freigabe oder der Geraete-PIN geht die App in den
      // Hintergrund, waehrend der Faktor laeuft. Bleibt der Dialog liegen,
      // sperrt sie nach [systemDialogHoechstens].
      st.systemDialogHoechstens = kurz;
      ablage.halt = Completer<void>();
      final bestaetigt = st.bestaetigeMitBiometrie();
      await Future<void>.delayed(Duration.zero);

      st.vordergrund(false);
      expect(tresor.istOffen, isTrue,
          reason: 'sonst liesse sich ein Stick bei "sofort" nie einrichten');

      await abwarten();
      expect(tresor.istOffen, isFalse);

      ablage.halt!.complete();
      expect(await bestaetigt, isFalse,
          reason: 'ein Nachweis aus der Zeit vor dem Sperren gilt nicht');
    });

    test('endet der Faktor im Hintergrund, gilt wieder die Frist', () async {
      // Dieselbe Rechnung wie beim Zurueckkommen: dort zaehlt der Faktor auch
      // nur, solange er laeuft.
      ablage.halt = Completer<void>();
      final bestaetigt = st.bestaetigeMitBiometrie();
      await Future<void>.delayed(Duration.zero);
      st.vordergrund(false);
      expect(tresor.istOffen, isTrue);

      ablage.halt!.complete();
      await bestaetigt;
      expect(tresor.istOffen, isFalse);
    });

    test('die eigene Dateiwahl, offen liegen gelassen', () async {
      st.systemDialogHoechstens = kurz;
      final waehler = Completer<String>();
      final ergebnis = st.imSystemDialog(() async {
        st.vordergrund(false); // Android legt den Waehler vor die App
        return waehler.future;
      });
      await Future<void>.delayed(Duration.zero);
      expect(tresor.istOffen, isTrue,
          reason: 'die selbst geoeffnete Dateiwahl sperrt nicht sofort');

      await abwarten();
      expect(tresor.istOffen, isFalse);
      waehler.complete('datei');
      expect(await ergebnis, 'datei');
    });
  });
}
