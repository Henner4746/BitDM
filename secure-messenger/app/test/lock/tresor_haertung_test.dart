// tresor_haertung_test.dart — die Befunde der Sicherheitspruefung vom
// 25.09.2026, jeder mit dem Fall, an dem er auffiel.
//
// WICHTIG BEI JEDEM BEFUND: es gibt Nutzer, deren Faecher schon auf der
// Platte liegen. Deshalb steht neben jedem "so ist es jetzt" ein "und so
// geht ein altes Fach weiter auf". Die alten Faecher werden hier Byte fuer
// Byte so gebaut, wie die App sie bis 24.09.2026 geschrieben hat —
// Zusatzdaten Fassung 1, Passwort ueber `SecretKey(passphrase.codeUnits)`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/app_lock.dart';
import 'package:bitdm/core/lock/geraete_fach.dart';
import 'package:bitdm/core/lock/key_vault.dart';
import 'package:bitdm/core/lock/keystore_factor.dart';
import 'package:bitdm/core/lock/unlock_factor.dart';
import 'package:bitdm/core/lock/vault_store.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBasis implements SecretStore {
  Uint8List? inhalt;
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

/// Ein Faktor, der den Puffer behaelt, den er dem Tresor gibt — damit sich
/// pruefen laesst, ob der Tresor ihn beim Sperren wirklich ueberschreibt.
class MerkenderFaktor implements UnlockFactor {
  MerkenderFaktor(this.kek);
  final Uint8List kek;
  Uint8List? zuletzt;

  @override
  UnlockFactorKind get kind => UnlockFactorKind.biometric;
  @override
  String get label => 'Fingerabdruck';
  @override
  Future<KeySlot> createSlot(Uint8List secret, {required int createdAt}) =>
      KeyVault.sealSlot(
          secret: secret,
          kek: kek,
          kind: kind,
          label: label,
          createdAt: createdAt);
  @override
  Future<Uint8List> unlock(KeySlot slot) async =>
      zuletzt = await KeyVault.openSlot(slot, kek);
}

Uint8List entropie([int start = 0]) =>
    Uint8List.fromList(List.generate(16, (i) => start + i));

/// Billige Argon2id-Werte fuer von Hand gebaute Faecher. Sie stehen im Fach,
/// also benutzt die App beim Oeffnen genau diese.
Argon2Params billig([int salz = 9]) => Argon2Params(
    memory: 64,
    iterations: 1,
    parallelism: 1,
    salt: Uint8List.fromList(List.filled(16, salz)));

/// Ein Passwort-Fach, wie die App es bis 24.09.2026 schrieb.
Future<KeySlot> altesPasswortFach(String passwort, Uint8List geheimnis,
    {int salz = 9, String? id}) async {
  final p = billig(salz);
  final kek = await (await Argon2id(
              parallelism: p.parallelism,
              memory: p.memory,
              iterations: p.iterations,
              hashLength: 32)
          .deriveKey(secretKey: SecretKey(passwort.codeUnits), nonce: p.salt))
      .extractBytes();
  return KeyVault.sealSlot(
    secret: geheimnis,
    kek: Uint8List.fromList(kek),
    kind: UnlockFactorKind.passphrase,
    label: 'Passwort',
    kdf: p,
    createdAt: 1,
    id: id,
    fassung: 1,
  );
}

PassphraseFactor pw(String s) => PassphraseFactor(s, geraeteGebunden: true);

// Kyrillisch а б в г д е = U+0430..U+0435. Die unteren acht Bit sind
// 0x30..0x35, also "012345".
const kyrillisch = 'абвгде';
const gleicheUntereBytes = '012345';

const starkesPasswort = 'Kupfer-Regen-Turm-Zaun-9042';
const panikPasswort = 'Moewe-Anker-Salz-Kran-7715';

void main() {
  late Directory verzeichnis;
  late FakeBasis basis;
  late FakeAblage ablage;
  late int uhr;

  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  setUp(() {
    verzeichnis = Directory.systemTemp.createTempSync('bitdm-haertung');
    basis = FakeBasis()..inhalt = entropie();
    ablage = FakeAblage();
    uhr = 1000;
  });

  tearDown(() {
    try {
      verzeichnis.deleteSync(recursive: true);
    } catch (_) {}
  });

  File datei() => vaultDateiIn(verzeichnis.path);
  VaultSecretStore tresor() => VaultSecretStore(
      datei: datei(),
      basis: basis,
      jetzt: () => uhr,
      geraeteAufraeumen: () async {});
  KeyVault aufPlatte() => KeyVault.fromJsonString(datei().readAsStringSync());
  void legeAb(KeyVault v) => datei().writeAsStringSync(v.toJsonString());
  KeystoreFactor finger() => KeystoreFactor(ablage: ablage);

  // ═══════════════════════════════════════════════════ Befund 11: UTF-8

  group('Befund 11: Passwoerter ausserhalb von ASCII', () {
    test('DER FEHLER, NACHGESTELLT: alt waren "абвгде" und "012345" gleich',
        () async {
      // Beweist, dass der Nachbau des alten Fachs den Fehler wirklich hat —
      // sonst pruefte der Rest nichts.
      final alt = await altesPasswortFach(kyrillisch, entropie());
      final kek = await (await Argon2id(
                  parallelism: 1, memory: 64, iterations: 1, hashLength: 32)
              .deriveKey(
                  secretKey: SecretKey(gleicheUntereBytes.codeUnits),
                  nonce: alt.kdf!.salt))
          .extractBytes();
      expect(await KeyVault.openSlot(alt, Uint8List.fromList(kek)),
          entropie());
    });

    test('ein NEUES Fach unterscheidet die beiden', () async {
      final slot = await pw(kyrillisch).createSlot(entropie(), createdAt: 1);
      expect(await pw(kyrillisch).unlock(slot), entropie());
      await expectLater(pw(gleicheUntereBytes).unlock(slot),
          throwsA(isA<UnlockFailedException>()));
    });

    test('ein ALTES Fach geht mit dem echten Passwort auf und wird umgeschrieben',
        () async {
      final alt = await altesPasswortFach(kyrillisch, entropie());
      final o = await pw(kyrillisch).oeffne(alt);
      expect(o.geheimnis, entropie());
      expect(o.warAktuell, isFalse);
      final neu = o.erneuert!;
      expect(neu.id, alt.id, reason: 'Verweise auf das Fach bleiben gueltig');
      expect(neu.kdf!.canonical, alt.kdf!.canonical);
      // Danach: nur noch das echte Passwort.
      expect(await pw(kyrillisch).unlock(neu), entropie());
      await expectLater(pw(gleicheUntereBytes).unlock(neu),
          throwsA(isA<UnlockFailedException>()));
    });

    test('ueber den Tresor: nach dem ersten Entsperren ist die Luecke zu',
        () async {
      basis.inhalt = null;
      legeAb(KeyVault(
          version: 1,
          slots: [await altesPasswortFach(kyrillisch, entropie())]));

      expect(await tresor().entsperreMit(pw(kyrillisch)), entropie());

      final spaeter = tresor();
      await expectLater(spaeter.entsperreMit(pw(gleicheUntereBytes)),
          throwsA(isA<UnlockFailedException>()));
      expect(await tresor().entsperreMit(pw(kyrillisch)), entropie());
    });

    test('reines ASCII: alt und neu sind dieselben Bytes — nur neu versiegelt',
        () async {
      final alt = await altesPasswortFach(starkesPasswort, entropie());
      final o = await pw(starkesPasswort).oeffne(alt);
      expect(o.geheimnis, entropie());
      final neu = o.erneuert!;
      expect(await KeyVault.oeffneFach(neu, await pw(starkesPasswort)
              .deriveKek(slot: neu)),
          isA<(Uint8List, int)>().having((r) => r.$2, 'Fassung', 2));
    });

    test('Umlaute (Latin-1) aus alten Faechern gehen weiter auf', () async {
      const deutsch = 'Grüße-aus-Köln-Straße';
      final alt = await altesPasswortFach(deutsch, entropie());
      final o = await pw(deutsch).oeffne(alt);
      expect(o.geheimnis, entropie());
      expect(await pw(deutsch).unlock(o.erneuert!), entropie());
    });

    test('ein altes PANIK-Fach loest weiter aus, auch mit Nicht-ASCII',
        () async {
      basis.inhalt = null;
      legeAb(KeyVault(version: 1, slots: [
        await altesPasswortFach(starkesPasswort, entropie(), salz: 1),
        await altesPasswortFach('паника-7715', VaultSecretStore.panikMarke,
            salz: 2),
      ]));
      await expectLater(tresor().entsperreMit(pw('паника-7715')),
          throwsA(isA<PanikAusgeloestException>()));
    });
  });

  // ═══════════════════════════════════════ Befund 10: Panik unsichtbar

  group('Befund 10: das Panik-Passwort ist nicht zu erkennen', () {
    test('mit EINEM Passwort stehen ZWEI Passwort-Faecher in der Datei',
        () async {
      final t = tresor();
      await t.fuegeHinzu(pw(starkesPasswort));

      final platte = aufPlatte().slotsOf(UnlockFactorKind.passphrase);
      expect(platte, hasLength(2),
          reason: 'sonst verraeten zwei Faecher ein Panik-Passwort');
      final a = platte[0].toJson()..remove('id')..remove('createdAt');
      final b = platte[1].toJson()..remove('id')..remove('createdAt');
      expect(a.keys.toSet(), b.keys.toSet());
      expect(a['label'], b['label']);
      expect((a['kdf'] as Map)['memory'], (b['kdf'] as Map)['memory']);
      expect((a['cipherText'] as String).length,
          (b['cipherText'] as String).length);
      expect(platte[0].createdAt, platte[1].createdAt,
          reason: 'zusammen angelegt, wie ein Panik-Fach, das den Platz '
              'uebernimmt');

      // Offen sieht die Oberflaeche nur den echten Faktor ...
      expect((await t.faecher())!.slots, hasLength(1));
      // ... zu (nach dem Neustart) zwei Passwort-Faecher, wie beim Panik-Fach.
      expect((await tresor().faecher())!.slots, hasLength(2));
    });

    test('das echte Passwort oeffnet, der Platzhalter oeffnet nichts',
        () async {
      await tresor().fuegeHinzu(pw(starkesPasswort));
      expect(await tresor().entsperreMit(pw(starkesPasswort)), entropie());
      await expectLater(tresor().entsperreMit(pw('ein ganz anderes Wort 1')),
          throwsA(isA<UnlockFailedException>()));
    });

    test('das Panik-Fach nimmt Platz und Zeitpunkt des Platzhalters ein',
        () async {
      final t = tresor();
      await t.fuegeHinzu(finger());
      await t.fuegeHinzu(pw(starkesPasswort));
      final vorher = aufPlatte().slots;
      expect(vorher, hasLength(3));

      final panik = await t.fuegePanikHinzu(pw(panikPasswort));
      final nachher = aufPlatte().slots;
      expect(nachher, hasLength(3), reason: 'die Zahl darf sich nicht aendern');
      expect(nachher[2].id, panik.id);
      expect(nachher[2].createdAt, vorher[2].createdAt);
      expect(nachher[0].id, vorher[0].id);
      expect(nachher[1].id, vorher[1].id);

      await expectLater(tresor().entsperreMit(pw(panikPasswort)),
          throwsA(isA<PanikAusgeloestException>()));
      expect(await tresor().entsperreMit(pw(starkesPasswort)), entropie());
    });

    test('ohne Panik-Passwort rueckt wieder ein Platzhalter nach', () async {
      final t = tresor();
      await t.fuegeHinzu(pw(starkesPasswort));
      final panik = await t.fuegePanikHinzu(pw(panikPasswort));
      await t.entferne(panik.id);

      final platte = aufPlatte().slotsOf(UnlockFactorKind.passphrase);
      expect(platte, hasLength(2));
      expect(platte.any((s) => s.id == panik.id), isFalse);
      expect((await t.faecher())!.slots, hasLength(1));
    });

    test('Fingerabdruck + Panik sieht aus wie Fingerabdruck + Passwort',
        () async {
      final t = tresor();
      await t.fuegeHinzu(finger());
      await t.fuegePanikHinzu(pw(panikPasswort));
      expect(aufPlatte().slotsOf(UnlockFactorKind.passphrase), hasLength(2));
    });

    test('ALTE NUTZER: der Platzhalter kommt beim ersten Entsperren dazu',
        () async {
      basis.inhalt = null;
      legeAb(KeyVault(
          version: 1,
          slots: [await altesPasswortFach(starkesPasswort, entropie())]));
      final t = tresor();
      await t.entsperreMit(pw(starkesPasswort));
      expect(aufPlatte().slotsOf(UnlockFactorKind.passphrase), hasLength(2));
      expect((await t.faecher())!.slots, hasLength(1));
    });

    test('Panik-Loeschen nimmt ALLE Fachschluessel im Geraet mit', () async {
      final aufrufe = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('bitdm/schluesselfach'),
              (c) async {
        aufrufe.add('${c.method}:${(c.arguments as Map)['art']}');
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('bitdm/schluesselfach'), null));

      // Zwei Reste, auch einer, der in keiner Fachdatei mehr steht.
      for (final n in ['bitdm_slot_kek_abc.bin', 'bitdm_slot_kek_alt.bin']) {
        File('${verzeichnis.path}${Platform.pathSeparator}$n')
            .writeAsBytesSync([1, 2, 3]);
      }
      final fremd = File('${verzeichnis.path}${Platform.pathSeparator}'
          'bitdm.db')
        ..writeAsBytesSync([9]);

      final t = VaultSecretStore(datei: datei(), basis: basis, jetzt: () => 1);
      await t.fuegeHinzu(finger());
      await t.delete();

      final rest = verzeichnis
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .where((n) => n.startsWith(KeystoreFactor.schluesselPraefix));
      expect(rest, isEmpty);
      expect(fremd.existsSync(), isTrue,
          reason: 'nur die Fachschluessel, nicht was sonst im Ordner liegt');
      expect(aufrufe, containsAll(['loesche:biometrie', 'loesche:geraetesperre']));
    });

    test('ohne Kanal (Rechner) wirft das Aufraeumen nicht', () async {
      await GeraeteFach.loescheAlles(
          verzeichnis: verzeichnis.path,
          kanal: const MethodChannel('gibt-es-nicht'));
    });
  });

  // ═════════════════════════════════════ Befund 14: Einstellungen

  group('Befund 14: Sperrfrist und Takt lassen sich nicht unterschieben', () {
    Future<VaultSecretStore> eingerichtet() async {
      final t = tresor();
      await t.fuegeHinzu(finger());
      return t;
    }

    test('DER ANGRIFF: "nie sperren" in die Datei geschrieben', () async {
      final t = await eingerichtet();
      await t.setzeSperrfrist(60);
      legeAb(aufPlatte().mitSperrfrist(-1)); // Pruefsumme passt nicht mehr

      final frisch = tresor();
      expect((await frisch.faecher())!.sperrfristSekunden, 0,
          reason: 'zu: -1 wird nicht geglaubt');
      await frisch.entsperreMit(finger());
      expect((await frisch.faecher())!.sperrfristSekunden, 0,
          reason: 'offen: die Pruefsumme passt nicht — zurueck auf sofort');
      expect(aufPlatte().sperrfristSekunden, 0);
      expect(await aufPlatte().einstellungenEcht(entropie()), isTrue);
    });

    test('auch ein GUELTIGER untergeschobener Wert faellt auf', () async {
      final t = await eingerichtet();
      await t.setzeEmpfangsTakt(60);
      legeAb(aufPlatte().mitSperrfrist(300).mitEmpfangsTakt(-1));

      final frisch = tresor();
      await frisch.entsperreMit(finger());
      final v = (await frisch.faecher())!;
      expect(v.sperrfristSekunden, 0);
      expect(v.empfangsTaktMinuten, KeyVault.empfangsTaktAbWerk);
    });

    test('eine entfernte Pruefsumme zaehlt wie eine falsche', () async {
      final t = await eingerichtet();
      await t.setzeSperrfrist(300);
      legeAb(aufPlatte().mitEinstellungsMac(null));
      final frisch = tresor();
      await frisch.entsperreMit(finger());
      expect((await frisch.faecher())!.sperrfristSekunden, 0);
    });

    test('ein echtes "nie" ueberlebt Neustart und Entsperren', () async {
      final t = await eingerichtet();
      await t.setzeSperrfrist(-1);
      final frisch = tresor();
      await frisch.entsperreMit(finger());
      expect((await frisch.faecher())!.sperrfristSekunden, -1);
    });

    test('Unsinn wird als sichere Voreinstellung gelesen', () {
      final v = KeyVault.fromJsonString(jsonEncode({
        'version': 2,
        'lockDelaySeconds': -5,
        'backgroundPollMinutes': 99999,
        'slots': [],
      }));
      expect(v.sperrfristSekunden, 0);
      expect(v.empfangsTaktMinuten, KeyVault.empfangsTaktAbWerk);
      expect(
          KeyVault.fromJsonString(
                  '{"version":1,"lockDelaySeconds":604800,"slots":[]}')
              .sperrfristSekunden,
          0);
    });

    test('die App selbst kann keinen Unsinn setzen', () async {
      final t = await eingerichtet();
      await expectLater(t.setzeSperrfrist(-7), throwsArgumentError);
      await expectLater(t.setzeSperrfrist(999999), throwsArgumentError);
      await expectLater(t.setzeEmpfangsTakt(-3), throwsArgumentError);
    });

    test('mit Faechern verlangt der Takt einen offenen Tresor', () async {
      await eingerichtet();
      await expectLater(
          tresor().setzeEmpfangsTakt(60), throwsA(isA<LockedException>()));
    });

    test('ALTE DATEI: Werte werden einmal uebernommen und dann geschuetzt',
        () async {
      basis.inhalt = null;
      legeAb(KeyVault(
          version: 1,
          sperrfristSekunden: 300,
          empfangsTaktMinuten: 60,
          slots: [await altesPasswortFach(starkesPasswort, entropie())]));
      final t = tresor();
      await t.entsperreMit(pw(starkesPasswort));
      final v = aufPlatte();
      expect(v.version, KeyVault.currentVersion);
      expect(v.sperrfristSekunden, 300,
          reason: 'eine Datei von vor dem Update hat keine Pruefsumme — das '
              'ist kein Angriff');
      expect(v.empfangsTaktMinuten, 60);
      expect(await v.einstellungenEcht(entropie()), isTrue);
    });

    test('Umbenennen laesst den Empfangstakt stehen', () async {
      final t = await eingerichtet();
      await t.setzeEmpfangsTakt(60);
      final slot = aufPlatte().slots.single;
      await t.benenneUm(slot.id, 'linker Daumen');
      expect(aufPlatte().empfangsTaktMinuten, 60,
          reason: 'bis 25.09.2026 ging er hier still auf 15 zurueck');
      expect(aufPlatte().slots.single.label, 'linker Daumen');
      expect(await aufPlatte().einstellungenEcht(entropie()), isTrue);
    });
  });

  // ═══════════════════════════════════════════ Befund 15: Speicher

  group('Befund 15: die offene Entropie', () {
    test('read() gibt eine Kopie heraus', () async {
      final t = tresor();
      await t.fuegeHinzu(finger());
      final a = (await t.read())!;
      a.fillRange(0, a.length, 0xFF);
      expect(await t.read(), entropie());
    });

    test('Sperren UEBERSCHREIBT den Puffer', () async {
      final faktor = MerkenderFaktor(Uint8List.fromList(List.filled(32, 7)));
      final t = tresor();
      await t.fuegeHinzu(faktor);
      final frisch = tresor();
      await frisch.entsperreMit(faktor);
      final puffer = faktor.zuletzt!;
      expect(puffer, entropie());

      frisch.sperre();
      expect(puffer.every((b) => b == 0), isTrue,
          reason: 'sonst liegt die Entropie im Speicher, waehrend die App '
              '"gesperrt" zeigt');
      await expectLater(frisch.read(), throwsA(isA<LockedException>()));
    });

    test('auch das Loeschen ueberschreibt', () async {
      final faktor = MerkenderFaktor(Uint8List.fromList(List.filled(32, 7)));
      await tresor().fuegeHinzu(faktor);
      final frisch = tresor();
      await frisch.entsperreMit(faktor);
      await frisch.delete();
      expect(faktor.zuletzt!.every((b) => b == 0), isTrue);
    });

    test('die Basis bekommt beim letzten Fach eine eigene Kopie', () async {
      final t = tresor();
      await t.fuegeHinzu(finger());
      await t.entferne(aufPlatte().slots.single.id,
          nachweis: await t.weiseNach(finger()));
      t.sperre();
      expect(basis.inhalt, entropie(),
          reason: 'Sperren darf die zurueckgelegte Entropie nicht nullen');
    });
  });

  // ═══════════════════════════════ Befund 6: letztes Fach nur mit Nachweis

  group('Befund 6: die Sperre abschalten verlangt einen frischen Faktor', () {
    late VaultSecretStore t;
    late String fach;

    setUp(() async {
      t = tresor();
      await t.fuegeHinzu(pw(starkesPasswort));
      fach = (await t.faecher())!.slots.single.id;
    });

    test('ohne Nachweis: abgelehnt, und nichts hat sich geaendert', () async {
      await expectLater(
          t.entferne(fach), throwsA(isA<NachweisNoetigException>()));
      expect(basis.inhalt, isNull);
      expect(await t.hatFaecher(), isTrue);
    });

    test('mit Nachweis: geht, und der Platzhalter geht mit', () async {
      final n = await t.weiseNach(pw(starkesPasswort));
      await t.entferne(fach, nachweis: n);
      expect(basis.inhalt, entropie());
      expect(aufPlatte().slots, isEmpty);
    });

    test('ein Nachweis gilt nur einmal', () async {
      final n = await t.weiseNach(pw(starkesPasswort));
      await t.fuegeHinzu(finger());
      final fingerFach = aufPlatte()
          .slots
          .firstWhere((s) => s.kind == UnlockFactorKind.biometric)
          .id;
      await t.entferne(fach); // nicht das letzte: kein Nachweis noetig
      await t.entferne(fingerFach, nachweis: n);
      expect(await t.hatFaecher(), isFalse);

      await t.fuegeHinzu(finger());
      await expectLater(
          t.entferne(aufPlatte().slots.single.id, nachweis: n),
          throwsA(isA<NachweisNoetigException>()));
    });

    test('ein Nachweis verfaellt nach zwei Minuten', () async {
      final n = await t.weiseNach(pw(starkesPasswort));
      uhr += VaultSecretStore.nachweisGueltigkeit.inMilliseconds + 1;
      await expectLater(t.entferne(fach, nachweis: n),
          throwsA(isA<NachweisNoetigException>()));
    });

    test('ein Nachweis verfaellt mit dem Sperren', () async {
      final n = await t.weiseNach(pw(starkesPasswort));
      t.sperre();
      await t.entsperreMit(pw(starkesPasswort));
      await expectLater(t.entferne(fach, nachweis: n),
          throwsA(isA<NachweisNoetigException>()));
    });

    test('ein Nachweis eines ANDEREN Tresors gilt nicht', () async {
      final anderer = tresor();
      await anderer.entsperreMit(pw(starkesPasswort));
      final n = await anderer.weiseNach(pw(starkesPasswort));
      await expectLater(t.entferne(fach, nachweis: n),
          throwsA(isA<NachweisNoetigException>()));
    });

    test('ein falsches Passwort bringt keinen Nachweis', () async {
      await expectLater(t.weiseNach(pw('ein anderes Passwort 12345')),
          throwsA(isA<UnlockFailedException>()));
    });

    test('bei zugem Tresor gibt es keinen Nachweis', () async {
      await expectLater(tresor().weiseNach(pw(starkesPasswort)),
          throwsA(isA<LockedException>()));
    });

    test('das Panik-Passwort loest auch hier aus', () async {
      await t.fuegePanikHinzu(pw(panikPasswort));
      await expectLater(t.weiseNach(pw(panikPasswort)),
          throwsA(isA<PanikAusgeloestException>()));
    });
  });
}
