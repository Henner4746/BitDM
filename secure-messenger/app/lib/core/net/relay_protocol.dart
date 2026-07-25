// relay_protocol.dart — das Format auf der Leitung.
//
// Diese Datei ist absichtlich frei von Netzwerkcode. Sie beschreibt nur, wie
// ein Prekey-Bundle aussieht und welche Bytes signiert werden — beides muss
// mit relay_server.py auf das Byte genau uebereinstimmen, sonst weist der
// Server jede Anmeldung ab.
//
// EIN STOLPERSTEIN, DER SICH DURCH DAS GANZE PROJEKT ZIEHT
// libsignal serialisiert oeffentliche Schluessel MIT einem vorangestellten
// Typ-Byte 0x05, also 33 Bytes. Die Adresse und die Signaturpruefung des
// Servers brauchen aber die ROHEN 32 Bytes. Deshalb gilt hier:
//
//   identity_key        -> roh, 32 Bytes   (der Server prueft die Laenge und
//                                           rechnet die Adresse daraus nach)
//   signed_prekey       -> serialisiert, 33 Bytes
//   one_time_prekeys[]  -> serialisiert, 33 Bytes
//
// Fuer den Server sind die letzten beiden undurchsichtige Bloecke; er reicht
// sie nur durch. Der Client gibt sie in dieser Form weiter, weil
// Curve.decodePoint sie so wieder einliest. Wer das vertauscht, bekommt keinen
// Fehler, sondern einen Sitzungsaufbau, der spaeter still scheitert.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

class RelayOneTimePreKey {
  final int keyId;

  /// base64 der serialisierten 33 Bytes.
  final String publicKey;

  const RelayOneTimePreKey({required this.keyId, required this.publicKey});

  Map<String, Object?> toJson() => {'key_id': keyId, 'public_key': publicKey};

  static RelayOneTimePreKey fromJson(Map<String, Object?> j) =>
      RelayOneTimePreKey(
        keyId: j['key_id']! as int,
        publicKey: j['public_key']! as String,
      );
}

class RelayPreKeyBundle {
  final String userId;

  /// base64 der ROHEN 32 Bytes.
  final String identityKey;

  /// Bezeichnet das GERAET, nicht die Identitaet.
  ///
  /// Bei BitDM ist das die einzige Moeglichkeit zu bemerken, dass eine
  /// Gegenstelle neu aufgesetzt wurde: der Identitaetsschluessel kommt aus der
  /// Seed-Phrase und bleibt derselbe, die Adresse damit auch. Wechselt die
  /// Nummer, sitzt am anderen Ende ein anderes Geraet.
  final int registrationId;

  final int signedPreKeyId;

  /// base64 der serialisierten 33 Bytes.
  final String signedPreKey;

  /// base64 der 64-Byte-XEdDSA-Signatur.
  final String signedPreKeySignature;

  final List<RelayOneTimePreKey> oneTimePreKeys;

  const RelayPreKeyBundle({
    required this.userId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.oneTimePreKeys = const [],
  });

  Map<String, Object?> toJson() => {
        'user_id': userId,
        'identity_key': identityKey,
        'registration_id': registrationId,
        'signed_prekey_id': signedPreKeyId,
        'signed_prekey': signedPreKey,
        'signed_prekey_sig': signedPreKeySignature,
        'one_time_prekeys': oneTimePreKeys.map((k) => k.toJson()).toList(),
      };

  /// Die Bytes, ueber die der Besitznachweis signiert wird.
  ///
  /// MUSS Zeichen fuer Zeichen dem entsprechen, was
  /// PreKeyBundle.canonical_bytes() in relay_server.py erzeugt. Python nutzt
  /// dort `json.dumps(..., sort_keys=True, separators=(",", ":"))`:
  ///
  ///   - Schluessel alphabetisch sortiert
  ///   - keine Leerzeichen nach ':' und ','
  ///   - One-Time-Prekeys als [id, schluessel]-Paare, nach id sortiert
  ///
  /// Dart schreibt JSON in Einfuegereihenfolge und ebenfalls ohne Leerzeichen.
  /// Die Reihenfolge unten ist deshalb NICHT Geschmack, sondern die
  /// alphabetische Sortierung von Hand nachgezogen. Ein umgestelltes Feld
  /// bricht die Anmeldung — und zwar mit "Besitznachweis fehlgeschlagen",
  /// einer Meldung, die auf alles Moegliche hindeutet, nur nicht auf die
  /// Reihenfolge von JSON-Schluesseln.
  ///
  /// Genau deshalb prueft der Test diese Bytes gegen Python, statt gegen eine
  /// zweite Dart-Umsetzung derselben Annahme.
  Uint8List canonicalBytes() {
    final otk = [...oneTimePreKeys]..sort((a, b) => a.keyId.compareTo(b.keyId));
    final payload = <String, Object?>{
      'identity_key': identityKey,
      'one_time_prekeys': otk.map((k) => [k.keyId, k.publicKey]).toList(),
      'registration_id': registrationId,
      'signed_prekey': signedPreKey,
      'signed_prekey_id': signedPreKeyId,
      'signed_prekey_sig': signedPreKeySignature,
      'user_id': userId,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  /// Nonce ‖ SHA-256(kanonisches Bundle) — die Nachricht des Besitznachweises.
  ///
  /// Warum nicht nur das Nonce: dann koennte jemand eine abgefangene gueltige
  /// Signatur nehmen und ein EIGENES Bundle daruntersetzen. Der Server wuerde
  /// den fremden Schluessel als den des Opfers speichern.
  Uint8List registrationChallenge(Uint8List nonce) {
    final hash = const DartSha256().hashSync(canonicalBytes()).bytes;
    return Uint8List.fromList([...nonce, ...hash]);
  }
}

/// Was der Server auf `GET /prekey/{adresse}` zurueckgibt.
///
/// [oneTimePreKey] ist null, wenn der Vorrat leer ist ODER die Ratenbegrenzung
/// gegriffen hat. Beides ist KEIN Fehler: X3DH funktioniert auch ohne, nur
/// etwas schwaecher. Ein Client, der hier abbricht, waere selbst das Ziel des
/// Drain-Angriffs — der Angreifer muesste nur den Vorrat leeren, um jemanden
/// unerreichbar zu machen.
class RelayBundleResponse {
  final String userId;
  final String identityKey;
  final int registrationId;
  final int signedPreKeyId;
  final String signedPreKey;
  final String signedPreKeySignature;
  final RelayOneTimePreKey? oneTimePreKey;

  const RelayBundleResponse({
    required this.userId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.oneTimePreKey,
  });

  static RelayBundleResponse fromJson(Map<String, Object?> j) {
    final otk = j['one_time_prekey'];
    return RelayBundleResponse(
      userId: j['user_id']! as String,
      identityKey: j['identity_key']! as String,
      registrationId: j['registration_id'] as int? ?? 0,
      signedPreKeyId: j['signed_prekey_id']! as int,
      signedPreKey: j['signed_prekey']! as String,
      signedPreKeySignature: j['signed_prekey_sig']! as String,
      oneTimePreKey: otk == null
          ? null
          : RelayOneTimePreKey.fromJson((otk as Map).cast<String, Object?>()),
    );
  }
}
