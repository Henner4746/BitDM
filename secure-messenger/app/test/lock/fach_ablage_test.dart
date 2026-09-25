// fach_ablage_test.dart — die Fachdatei ohne Datei, so wie im Browser.
//
// Im Browser liegt die Fachdatei in localStorage (core/browser/
// browser_zugang_web.dart) und die Entropie ohne Passwort nur im
// Arbeitsspeicher (main.dart bei `basis:`). localStorage laeuft in
// `flutter test` nicht; nachgebaut ist deshalb genau das, was
// VaultSecretStore davon sieht: eine FachAblage, die einen String haelt. Was
// hier geprueft wird, ist der Ablauf, auf den sich die Browser-Fassung
// verlaesst — Passwort einrichten, "Neuladen" (neue Instanzen, der
// Arbeitsspeicher ist leer), mit dem Passwort wieder aufschliessen.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/app_lock.dart';
import 'package:bitdm/core/lock/fach_ablage.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// localStorage, im Speicher nachgebaut: ein Wert, als Ganzes ersetzt.
class SpeicherAblage implements FachAblage {
  String? wert;
  var geschrieben = 0;

  @override
  bool existiert() => wert != null;

  @override
  Future<String> lies() async => wert!;

  @override
  Future<void> schreibe(String inhalt) async {
    wert = inhalt;
    geschrieben++;
  }

  @override
  void loesche() => wert = null;
}

void main() {
  final entropie = Uint8List.fromList(List<int>.generate(16, (i) => i + 40));
  const passwort = 'ein ziemlich langes Passwort mit Zahlen 12345';
  PassphraseFactor pw([String p = passwort]) =>
      PassphraseFactor(p, geraeteGebunden: false);

  test('ohne Passwort ist die Identitaet nach dem Neuladen weg', () async {
    final ablage = SpeicherAblage();
    final vorher = VaultSecretStore(
        ablage: ablage, basis: InMemorySecretStore(), jetzt: () => 1);
    await vorher.write(entropie);
    expect(await vorher.read(), entropie);
    // Nichts geschrieben: ohne Faktor gibt es keine Fachdatei.
    expect(ablage.existiert(), isFalse);

    // "Neuladen": neuer Arbeitsspeicher, dieselbe Ablage.
    final nachher = VaultSecretStore(
        ablage: ablage, basis: InMemorySecretStore(), jetzt: () => 2);
    expect(await nachher.read(), isNull);
  });

  test('mit Passwort ueberlebt sie das Neuladen — und nur mit dem Passwort',
      () async {
    final ablage = SpeicherAblage();
    final basis = InMemorySecretStore();
    final vorher = VaultSecretStore(ablage: ablage, basis: basis, jetzt: () => 1);
    await vorher.write(entropie);
    await vorher.fuegeHinzu(pw());

    // Die Entropie hat den Grundspeicher verlassen, die Ablage enthaelt sie
    // nicht im Klartext.
    expect(await basis.read(), isNull);
    expect(ablage.wert, isNotNull);
    expect(ablage.wert!.contains(String.fromCharCodes(entropie)), isFalse);

    final nachher = VaultSecretStore(
        ablage: ablage, basis: InMemorySecretStore(), jetzt: () => 2);
    await expectLater(nachher.read(), throwsA(isA<LockedException>()));
    await expectLater(nachher.entsperreMit(pw('ein anderes langes Passwort 67890')),
        throwsA(isA<UnlockFailedException>()));
    expect(await nachher.entsperreMit(pw()), entropie);
    expect(await nachher.read(), entropie);
  });

  test('delete raeumt die Ablage ab', () async {
    final ablage = SpeicherAblage();
    final t = VaultSecretStore(
        ablage: ablage, basis: InMemorySecretStore(), jetzt: () => 1);
    await t.write(entropie);
    await t.fuegeHinzu(pw());
    await t.delete();
    expect(ablage.existiert(), isFalse);
  });

  test('die Datei-Ablage verhaelt sich wie vorher: ersetzt als Ganzes',
      () async {
    final ordner = Directory.systemTemp.createTempSync('bitdm_fach');
    addTearDown(() => ordner.deleteSync(recursive: true));
    final ablage = DateiFachAblage(vaultDateiIn(ordner.path));
    expect(ablage.existiert(), isFalse);
    await ablage.schreibe('eins');
    await ablage.schreibe('zwei');
    expect(await ablage.lies(), 'zwei');
    // Keine Nebendatei bleibt liegen.
    expect(File('${ablage.datei.path}.neu').existsSync(), isFalse);
    ablage.loesche();
    expect(ablage.existiert(), isFalse);
    ablage.loesche(); // wirft nicht, wenn es sie nicht gibt
  });
}
