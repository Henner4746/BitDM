// sperre_zustand_test.dart — was beim Sperren, Loeschen und Entsperren im
// Zustand bleibt und was nicht.
//
// Echter Tresor, echte Fachdatei, echtes Argon2id (wie panik_passwort_test);
// nur der Kern ist die Attrappe. Geprueft wird AppState, nicht der Kern:
// dass nach dem Sperren kein Klartext mehr in den Feldern der Oberflaeche
// steht, dass "alles loeschen" wirklich alles vergisst, und was beim
// Entsperren wieder nachgeladen wird.

import 'dart:io';

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/empfang.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:bitdm/core/sprache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt = Uint8List.fromList(List.generate(16, (i) => i + 7));
  @override
  Future<Uint8List?> read() async => inhalt;
  @override
  Future<void> write(Uint8List e) async => inhalt = e;
  @override
  Future<void> delete() async => inhalt = null;
}

class FakeAblage implements SchluesselAblage {
  final Map<String, String> daten = {};
  @override
  Future<String?> lies(String k) async => daten[k];
  @override
  Future<void> schreibe(String k, String v) async => daten[k] = v;
  @override
  Future<void> loesche(String k) async => daten.remove(k);
}

/// Ein Kern, bei dem das Senden an [scheitertAn] wirft und der mitzaehlt,
/// wie oft aufgeraeumt wurde.
class ZaehlKern extends FakeMessengerCore {
  String? scheitertAn;
  int aufgeraeumt = 0;

  @override
  Future<Message> sendMessage(String contactId, String text,
      {String? antwortAuf, DateTime? um, bool geheim = false}) {
    if (contactId == scheitertAn) throw StateError('Leitung weg');
    return super.sendMessage(contactId, text, antwortAuf: antwortAuf, um: um, geheim: geheim);
  }

  @override
  Future<int> purgeExpiredMessages() async {
    aufgeraeumt++;
    return 0;
  }
}

const echtes = 'Kupfer-Regen-Turm-Zaun-9042';
const panik = 'Moewe-Anker-Salz-Kran-7715';

void main() {
  late Directory verzeichnis;
  late VaultSecretStore tresor;
  late ZaehlKern kern;
  late AppState st;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  setUp(() async {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-sperre');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => verzeichnis.path);
    tresor = VaultSecretStore(
      datei: vaultDateiIn(verzeichnis.path),
      basis: FakeBasis(),
      jetzt: () => 1000,
    );
    final ablage = FakeAblage();
    kern = ZaehlKern()..simulateExistingIdentity = true;
    st = AppState(kern, tresor: tresor, ablagen: (_) => ablage);
    await st.boot();
  });

  tearDown(() {
    st.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  String ersterKontakt() => st.aktiveKontakte.first.id;

  test('SPERREN VERGISST STERNE, ANHAENGE, SUCHE, VERTEILER UND UNGELESENE', () async {
    await st.fuegePasswortHinzu(echtes);
    final c = ersterKontakt();
    await st.unterhaltungOeffnen(c);
    await st.setzeStern(c, st.verlaufVon(c).first.id, true);
    await st.suche('file');
    await st.legeVerteilerAn('Liste', [c]);
    st.ungelesen[c] = 3;
    expect(st.sterne, isNotEmpty);
    expect(st.suchTreffer, isNotEmpty);
    expect(st.verteiler, isNotEmpty);

    await st.sperreWieder();

    expect(st.gesperrt, isTrue);
    expect(st.sterne, isEmpty, reason: 'markierte Nachrichten (Klartext) blieben stehen');
    expect(st.suchText, isEmpty);
    expect(st.suchTreffer, isEmpty);
    expect(st.anhaenge, isEmpty);
    expect(st.verteiler, isEmpty);
    expect(st.ungelesen, isEmpty);
  });

  test('NACH DEM ENTSPERREN IST DIE OFFENE UNTERHALTUNG GANZ DA, NICHT NUR DIE VORSCHAU', () async {
    await st.fuegePasswortHinzu(echtes);
    final c = ersterKontakt();
    await st.unterhaltungOeffnen(c);
    st.offeneUnterhaltung = c;
    final ganz = st.verlaufVon(c).length;
    expect(ganz, greaterThan(1));

    await st.sperreWieder();
    expect(await st.entsperreMitPasswort(echtes), isTrue);

    expect(st.verlaufVon(c).length, ganz,
        reason: 'nach dem Entsperren stand im offenen Chat nur die letzte Nachricht');
  });

  test('ALLES LOESCHEN VERGISST AUCH EINSTELLUNGEN, STERNE UND VERTEILER', () async {
    final c = ersterKontakt();
    await st.unterhaltungOeffnen(c);
    await st.setzeStern(c, st.verlaufVon(c).first.id, true);
    await st.legeVerteilerAn('Liste', [c]);
    await st.suche('file');
    await st.setzeEinstellungen(st.einstellungen.copyWith(thema: 'phosphor', readReceipts: false));

    await st.allesLoeschen();

    expect(st.hatIdentitaet, isFalse);
    expect(st.gesperrt, isFalse);
    expect(st.sterne, isEmpty);
    expect(st.verteiler, isEmpty);
    expect(st.suchText, isEmpty);
    expect(st.suchTreffer, isEmpty);
    expect(st.reaktionen, isEmpty);
    expect(st.einstellungen.thema, const AppPreferences().thema,
        reason: 'die Einstellungen der alten Identitaet blieben stehen');
    expect(st.einstellungen.readReceipts, const AppPreferences().readReceipts);
  });

  group('Frisch bestaetigen', () {
    test('ohne Faktor braucht es keine Anmeldung', () {
      expect(st.brauchtFrischeAnmeldung, isFalse);
    });

    test('das richtige Passwort bestaetigt, ohne neu zu entsperren', () async {
      await st.fuegePasswortHinzu(echtes);
      expect(st.brauchtFrischeAnmeldung, isTrue);
      final kontakteVorher = st.kontakte.length;
      expect(await st.bestaetigeMitPasswort(echtes), isTrue);
      expect(st.gesperrt, isFalse);
      expect(st.kontakte.length, kontakteVorher);
    });

    test('ein falsches Passwort bestaetigt nicht', () async {
      await st.fuegePasswortHinzu(echtes);
      expect(await st.bestaetigeMitPasswort('Falsch-Falsch-Falsch-0000'), isFalse);
      expect(st.hatIdentitaet, isTrue);
    });

    test('der LETZTE Faktor geht nur mit dem Beleg einer frischen Anmeldung', () async {
      await st.fuegePasswortHinzu(echtes);
      final slot = st.sichtbareFaktoren.single.id;
      await expectLater(st.entferneFaktor(slot), throwsA(isA<NachweisNoetigException>()),
          reason: 'die Sperre liess sich ohne Ausweis abschalten');
      expect(await st.bestaetigeMitPasswort(echtes), isTrue);
      await st.entferneFaktor(slot);
      expect(st.faktoren, isEmpty);
    });

    test('das Panik-Passwort loescht auch hier', () async {
      await st.fuegePasswortHinzu(echtes);
      await st.setzePanikPasswort(panik);
      expect(await st.bestaetigeMitPasswort(panik), isFalse);
      expect(st.hatIdentitaet, isFalse);
    });
  });

  test('EINMAL-ANSICHT WAEHREND DER SPERRE: DIE DATEI GEHT SOFORT, DER EINTRAG NACH DEM ENTSPERREN', () async {
    await st.fuegePasswortHinzu(echtes);
    final c = ersterKontakt();
    final quelle = File('${verzeichnis.path}/bild.bin')..writeAsBytesSync(List.filled(64, 3));
    final m = await kern.sendeAnhang(c, quelle, name: 'bild.jpg', einmal: true);
    final angesehen = File('${verzeichnis.path}/angesehen.bin')..writeAsBytesSync(List.filled(64, 4));

    await st.sperreWieder();
    await st.verbraucheEinmal(c, m.id, pfad: angesehen.path);
    expect(angesehen.existsSync(), isFalse,
        reason: 'die angesehene Einmal-Datei blieb liegen, weil der Kern zu war');

    expect(await st.entsperreMitPasswort(echtes), isTrue);
    final eintrag = (await kern.getAnhaenge(c))[m.id]!;
    expect(eintrag.zustand, AnhangZustand.verbraucht,
        reason: 'der Verbrauch wurde nach dem Entsperren nicht nachgeholt');
  });

  group('Sprachnachricht', () {
    test('die Aufnahme ist nach dem Versand weg', () async {
      final c = ersterKontakt();
      final aufnahme = File('${verzeichnis.path}/aufnahme.m4a')
        ..writeAsBytesSync(List.filled(2048, 1));
      await st.sendeSprachnachricht(c, Aufnahme(aufnahme.path, const Duration(seconds: 3)));
      expect(aufnahme.existsSync(), isFalse, reason: 'die Aufnahme lag unverschluesselt weiter');
      expect(st.verlaufVon(c).any((x) => sprachName.hasMatch(x.text)), isTrue);
    });

    test('auch wenn der Versand scheitert', () async {
      final aufnahme = File('${verzeichnis.path}/aufnahme.m4a')
        ..writeAsBytesSync(List.filled(2048, 1));
      await st.sendeSprachnachricht(
          'unbekannt-unbekannt-unbekannt', Aufnahme(aufnahme.path, const Duration(seconds: 3)));
      expect(st.letzterFehler, isNotNull);
      expect(aufnahme.existsSync(), isFalse);
    });
  });

  test('VERTEILER: EIN FEHLSCHLAG BRICHT NICHT AB UND WIRD GEZAEHLT', () async {
    final ids = st.aktiveKontakte.map((k) => k.id).toList();
    expect(ids.length, greaterThanOrEqualTo(2));
    kern.scheitertAn = ids.first;
    await st.legeVerteilerAn('Liste', ids);
    final r = await st.sendeAnVerteiler(st.verteiler.single.id, 'Hallo');
    expect(r.fehlgeschlagen, 1);
    expect(r.gesendet, ids.length - 1, reason: 'nach dem ersten Fehler ging nichts mehr');
  });

  test('FALSCHE ADRESSE, DANN RICHTIGE: DIE ALTE MELDUNG VERSCHWINDET', () async {
    expect(await st.kontaktHinzufuegen('zu-kurz'), isFalse);
    expect(st.letzterFehler, 'adresseUngueltig');
    expect(await st.kontaktHinzufuegen('abcdefghijklmnopqrstuvwxyz0123456789'), isTrue);
    expect(st.letzterFehler, isNull);
  });

  test('VERSCHWINDEN IM VORDERGRUND: ES WIRD ZUR FAELLIGKEIT AUFGERAEUMT', () async {
    final vorher = kern.aufgeraeumt;
    var faellig = DateTime.now().add(const Duration(milliseconds: 50));
    st.verfallsQuelle = () => faellig;
    // Irgendeine Nachricht stellt den Wecker neu.
    await st.senden(ersterKontakt(), 'mit Frist');
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    expect(kern.aufgeraeumt, greaterThan(vorher),
        reason: 'bei offener App wurde nie aufgeraeumt');
    faellig = DateTime.now().add(const Duration(days: 1));
  });

  group('Metadaten', () {
    // FF D8 und danach kein Abschnitt: ein JPEG, das sich nicht zerlegen laesst.
    Uint8List kaputtesJpeg() =>
        Uint8List.fromList([0xFF, 0xD8, 0x12, 0x34, ...List.filled(300, 0x55)]);

    test('laesst sich ein Bild nicht bereinigen, geht es ohne Rueckfrage NICHT hinaus', () async {
      final c = ersterKontakt();
      await st.unterhaltungOeffnen(c);
      final vorher = st.verlaufVon(c).length;
      final f = File('${verzeichnis.path}/IMG_20260925_1200.jpg')..writeAsBytesSync(kaputtesJpeg());
      await st.anhangSenden(c, f, name: 'IMG_20260925_1200.jpg');
      expect(st.letzterFehler, 'metaNichtEntfernt');
      expect(st.verlaufVon(c).length, vorher, reason: 'still mit Metadaten verschickt');
    });

    test('mit Rueckfrage: Nein schickt nichts, Ja schickt unter neutralem Namen', () async {
      final c = ersterKontakt();
      await st.unterhaltungOeffnen(c);
      final gruende = <String>[];
      var antwort = false;
      st.frageOhneBereinigung = (g) async {
        gruende.add(g);
        return antwort;
      };
      final f = File('${verzeichnis.path}/IMG_20260925_1200.jpg')..writeAsBytesSync(kaputtesJpeg());
      final vorher = st.verlaufVon(c).length;
      await st.anhangSenden(c, f, name: 'IMG_20260925_1200.jpg');
      expect(gruende, ['metaFehler']);
      expect(st.verlaufVon(c).length, vorher);
      expect(st.letzterFehler, isNull, reason: 'ein Nein ist kein Fehler');

      antwort = true;
      await st.anhangSenden(c, f, name: 'IMG_20260925_1200.jpg');
      final letzte = st.verlaufVon(c).last;
      expect(letzte.text, matches(RegExp(r'^bild-[0-9a-f]{4}\.jpg$')),
          reason: 'der Originalname (Telefon, Sekunde) ging mit');
    });

    test('ein Bild mit Ortsdaten geht bereinigt und unter neutralem Namen', () async {
      final c = ersterKontakt();
      await st.unterhaltungOeffnen(c);
      final f = File('${verzeichnis.path}/PXL_20260925_123456.jpg')
        ..writeAsBytesSync(File('test/anhang/proben/mit_gps.jpg').readAsBytesSync());
      await st.anhangSenden(c, f, name: 'PXL_20260925_123456.jpg');
      expect(st.letzterFehler, isNull);
      expect(st.verlaufVon(c).last.text, matches(RegExp(r'^bild-[0-9a-f]{4}\.jpg$')));
    });

    test('zu gross zum Bereinigen: der Nutzer wird gefragt', () async {
      final c = ersterKontakt();
      final gruende = <String>[];
      st.frageOhneBereinigung = (g) async {
        gruende.add(g);
        return false;
      };
      final f = File('${verzeichnis.path}/gross.jpg');
      final zugriff = f.openSync(mode: FileMode.write);
      zugriff.writeFromSync([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10]);
      zugriff.truncateSync(AppState.bildGrenze + 1024);
      zugriff.closeSync();
      await st.anhangSenden(c, f, name: 'gross.jpg');
      expect(gruende, ['metaZuGross']);
    });
  });

  group('Fernloeschung', () {
    test('schon faellig beim Start: Nachfrist, keine Verbindung, Abbruch verbindet', () async {
      final k = FakeMessengerCore()..simulateExistingIdentity = true;
      await k.setzeFernloeschung(Fernloeschung(
          an: true,
          vertraute: const ['a', 'b'],
          faellig: DateTime.now().toUtc().subtract(const Duration(minutes: 5))));
      final s = AppState(k);
      addTearDown(s.dispose);
      await s.boot();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(s.hatIdentitaet, isTrue, reason: 'beim Oeffnen sofort geloescht');
      expect(s.fernFrist, isNotNull);
      expect(s.fernFrist!.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 50))), isTrue);
      expect(k.connectionState, ConnectionState.disconnected,
          reason: 'mit faelliger Fernloeschung ging die App ins Netz');

      await s.brichFernloeschungAb();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(s.fernFrist, isNull);
      expect(k.connectionState, ConnectionState.online);
    });
  });

  group('Verdeckt', () {
    Future<AppState> mitDienst(FakeMessengerCore k, {required bool leitungBleibt}) async {
      const kanal = MethodChannel('test/empfang');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kanal, (_) async => true);
      final s = AppState(k)
        ..empfangsDienst = EmpfangsDienst(kanal: kanal)
        ..verbindungImHintergrund = leitungBleibt;
      await s.boot();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(k.connectionState, ConnectionState.online);
      return s;
    }

    test('am Rechner und im Browser bleibt die Leitung stehen', () async {
      final k = FakeMessengerCore()..simulateExistingIdentity = true;
      final s = await mitDienst(k, leitungBleibt: true);
      addTearDown(s.dispose);
      s.vordergrund(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(k.connectionState, ConnectionState.online,
          reason: 'ein verdecktes Fenster trennte die Verbindung');
    });

    test('auf Android uebernimmt der Hintergrundempfang und trennt', () async {
      final k = FakeMessengerCore()..simulateExistingIdentity = true;
      final s = await mitDienst(k, leitungBleibt: false);
      addTearDown(s.dispose);
      s.vordergrund(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(k.connectionState, ConnectionState.disconnected);
    });
  });
}
