// relay_protocol_test.dart — Dart gegen Python, nicht Dart gegen Dart.
//
// canonicalBytes() muss zeichengenau dem entsprechen, was
// PreKeyBundle.canonical_bytes() in relay_server.py erzeugt. Weicht auch nur
// die Reihenfolge zweier JSON-Schluessel ab, scheitert der Besitznachweis —
// mit der Meldung "Besitznachweis fehlgeschlagen", die auf alles Moegliche
// hindeutet, nur nicht auf JSON.
//
// Ein Test, der die Erwartung selbst in Dart ausrechnet, waere wertlos: er
// wuerde dieselbe Annahme treffen wie der geprueften Code und auch dann gruen
// bleiben, wenn beide falsch liegen. Genau so ist in diesem Projekt schon
// einmal ein halb kaputter Signaturpfad durchgerutscht.
//
// Die Vergleichswerte in canonical_fixtures.json stammen deshalb aus einem
// echten Lauf des Servers. Neu erzeugen mit:
//
//   cd secure-messenger/server
//   py -3 tools/write_canonical_fixtures.py

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/net/relay_protocol.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final datei = File('test/net/canonical_fixtures.json');

  test('die Vergleichswerte sind ueberhaupt da', () {
    expect(datei.existsSync(), isTrue,
        reason: 'ohne canonical_fixtures.json prueft diese Datei nichts');
  });

  final faelle = (jsonDecode(datei.readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  group('kanonische Bytes stimmen mit relay_server.py ueberein', () {
    for (final fall in faelle) {
      final name = fall['name'] as String;
      final b = (fall['bundle'] as Map).cast<String, Object?>();

      final bundle = RelayPreKeyBundle(
        // NULL IST HIER EINE AUSSAGE, KEINE LUECKE. Die vier alten Faelle
        // tragen `device_id: null` und muessen dieselben Bytes ergeben wie vor
        // dem Mehrgeraete-Umbau — daran haengt der Besitznachweis jedes
        // Telefons, das die alte App laeuft. Die drei neuen tragen eine
        // Kennung und pruefen, dass sie VOR `identity_key` sortiert
        // (`json.dumps(sort_keys=True)` auf der Serverseite, Dart schreibt in
        // Einfuegereihenfolge). Wer diese Zeile weglaesst, prueft die neuen
        // Faelle gegen ein Bundle ohne Kennung — und genau das tat sie bis zum
        // 01.08.2026: sechs Faelle rot, weil der Rahmen die Kennung nie
        // durchreichte.
        deviceId: b['device_id'] as int?,
        userId: b['user_id']! as String,
        identityKey: b['identity_key']! as String,
        registrationId: b['registration_id']! as int,
        signedPreKeyId: b['signed_prekey_id']! as int,
        signedPreKey: b['signed_prekey']! as String,
        signedPreKeySignature: b['signed_prekey_sig']! as String,
        oneTimePreKeys: ((b['one_time_prekeys'] ?? []) as List)
            .map((e) =>
                RelayOneTimePreKey.fromJson((e as Map).cast<String, Object?>()))
            .toList(),
      );

      test(name, () {
        expect(utf8.decode(bundle.canonicalBytes()), fall['canonical']);
      });

      test('$name — auch der SHA-256 darueber', () {
        // Signiert wird der Hash, nicht der Text. Ein Unterschied, der sich
        // im Text verstecken koennte, faellt spaetestens hier auf.
        final hash =
            const DartSha256().hashSync(bundle.canonicalBytes()).bytes;
        expect(base64.encode(hash), fall['sha256_b64']);
      });
    }
  });

  test('One-Time-Prekeys werden nach Kennung sortiert, egal wie sie ankommen',
      () {
    // Der Server sortiert sie beim Nachrechnen der Signatur. Wer sie hier in
    // Eingabereihenfolge liesse, bekaeme bei jedem zweiten Nutzer eine
    // abgelehnte Anmeldung — je nachdem, in welcher Reihenfolge die Schluessel
    // gerade erzeugt wurden.
    RelayPreKeyBundle mit(List<int> ids) => RelayPreKeyBundle(
          userId: 'x' * 56,
          identityKey: 'aWQ=',
          registrationId: 7,
          signedPreKeyId: 1,
          signedPreKey: 'c3Br',
          signedPreKeySignature: 'c2ln',
          oneTimePreKeys: ids
              .map((i) => RelayOneTimePreKey(keyId: i, publicKey: 'aw=='))
              .toList(),
        );

    expect(utf8.decode(mit([3, 1, 2]).canonicalBytes()),
        utf8.decode(mit([1, 2, 3]).canonicalBytes()));
  });

  test('das Nonce steht VOR dem Hash', () {
    // Der Server bildet nonce + sha256(bundle). Vertauscht ergaebe dieselbe
    // Laenge und faellt sonst nirgends auf.
    final bundle = RelayPreKeyBundle(
      userId: 'x' * 56,
      identityKey: 'aWQ=',
          registrationId: 7,
      signedPreKeyId: 1,
      signedPreKey: 'c3Br',
      signedPreKeySignature: 'c2ln',
    );
    final nonce = List.generate(32, (i) => i);
    final nachricht =
        bundle.registrationChallenge(Uint8List.fromList(nonce));

    expect(nachricht, hasLength(64));
    expect(nachricht.sublist(0, 32), nonce);
    expect(nachricht.sublist(32),
        const DartSha256().hashSync(bundle.canonicalBytes()).bytes);
  });

  test('ein Bundle ohne One-Time-Prekeys ist gueltig', () {
    // Kommt vor: der Vorrat kann leer sein. Ein Client, der das als Fehler
    // behandelt, waere selbst das Ziel eines Drain-Angriffs.
    final antwort = RelayBundleResponse.fromJson({
      'user_id': 'x' * 56,
      'identity_key': 'aWQ=',
      'signed_prekey_id': 1,
      'signed_prekey': 'c3Br',
      'signed_prekey_sig': 'c2ln',
      'one_time_prekey': null,
    });
    expect(antwort.oneTimePreKey, isNull);
  });
}
