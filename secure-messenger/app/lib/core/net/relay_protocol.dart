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
//   identity_key              -> roh, 32 Bytes   (der Server prueft die Laenge
//                                                 und rechnet die Adresse nach)
//   signed_prekey             -> serialisiert, 33 Bytes (Typ 0x05)
//   one_time_prekeys[]        -> serialisiert, 33 Bytes (Typ 0x05)
//   kyber_prekey              -> serialisiert, 1569 Bytes (Typ 0x08, Kyber-1024)
//   one_time_kyber_prekeys[]  -> serialisiert, 1569 Bytes (Typ 0x08)
//
// Fuer den Server sind die serialisierten Schluessel undurchsichtige Bloecke;
// die Kyber-Signaturen prueft er aber (ueber die vollen 1569 Bytes mit
// Typ-Byte, wie libsignal sie signiert). Wer roh und serialisiert vertauscht,
// bekommt keinen Fehler, sondern einen Sitzungsaufbau, der still scheitert.
//
// KYBER SEIT 2.0.0 (offizielle libsignal, PQXDH). Die offizielle Bibliothek
// baut keine Sitzung ohne Kyber-Prekey mehr; ein Geraet einer alten App ohne
// diese Felder ist fuer eine neue App nicht erreichbar
// (prekey_bundle_bridge.dart `GegenstelleOhneKyberException`).

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

/// Ein Kyber-Einmalschluessel auf der Leitung.
///
/// Anders als die EC-Einmalschluessel SIGNIERT: libsignal prueft die
/// Signatur jedes Kyber-Prekeys beim Sitzungsaufbau, und der Relay prueft sie
/// schon bei der Anmeldung.
class RelayKyberPreKey {
  final int keyId;

  /// base64 der serialisierten 1569 Bytes.
  final String publicKey;

  /// base64 der 64-Byte-XEdDSA-Signatur ueber die 1569 Bytes.
  final String signature;

  const RelayKyberPreKey({
    required this.keyId,
    required this.publicKey,
    required this.signature,
  });

  Map<String, Object?> toJson() =>
      {'key_id': keyId, 'public_key': publicKey, 'signature': signature};
}

class RelayPreKeyBundle {
  final String userId;

  /// base64 der ROHEN 32 Bytes.
  final String identityKey;

  /// libsignals Nummer dieser Installation. SIE UNTERSCHEIDET KEINE GERAETE.
  ///
  /// Frueher stand hier, sie sei "die einzige Moeglichkeit zu bemerken, dass
  /// eine Gegenstelle neu aufgesetzt wurde". Das war eine Absicht, keine
  /// Umsetzung: `grep -rn "registrationId" lib/` liefert 18 Fundstellen (Feld,
  /// Konstruktor, Bundle-Uebergabe, Meta-Zugriff, getLocalRegistrationId) und
  /// KEINEN Vergleich; in libsignal_protocol_dart 0.8.2 fassen weder
  /// `session_builder.dart` noch `session_cipher.dart` sie an. Es hat also nie
  /// jemand deswegen eine Sitzung verworfen.
  ///
  /// MIT MEHREREN ERLAUBTEN GERAETEN WAERE DIESE AUSWERTUNG SCHAEDLICH: zwei
  /// Geraete derselben Adresse fuehren verschiedene Nummern, und "die Nummer
  /// hat gewechselt, also die Sitzung wegwerfen" traefe damit den Normalfall.
  /// Was Geraete unterscheidet, ist [deviceId] — und die Frage "ist da wirklich
  /// der Richtige" beantwortet nicht diese Zahl, sondern die Nachrechnung der
  /// Adresse aus dem Schluessel (signal_store.dart `_keyMatchesAddress`).
  final int registrationId;

  /// Welches Geraet dieser Adresse. Null heisst Geraet 1.
  ///
  /// NULL UND NICHT 1, und das ist der ganze Rueckwaertsvertrag: fehlt das
  /// Feld, sind die kanonischen Bytes Zeichen fuer Zeichen die von vor der
  /// Mehrgeraete-Umstellung (Spezifikation §2.1), und ein Relay, der die
  /// Erweiterung noch nicht kennt, nimmt die Anmeldung unveraendert an.
  /// Deshalb schickt Geraet 1 die Kennung NIE mit.
  final int? deviceId;

  final int signedPreKeyId;

  /// base64 der serialisierten 33 Bytes.
  final String signedPreKey;

  /// base64 der 64-Byte-XEdDSA-Signatur.
  final String signedPreKeySignature;

  final List<RelayOneTimePreKey> oneTimePreKeys;

  /// Der LAST-RESORT-Kyber-Prekey: wird ausgegeben, wenn die
  /// Kyber-Einmalschluessel aufgebraucht sind.
  ///
  /// NULL NUR IN TESTS UND BEI ALTEN APPS. Die App ab 2.0.0 setzt ihn immer
  /// (prekey_bundle_bridge.dart). Null heisst: die Kyber-Felder fehlen im
  /// Rumpf UND in den kanonischen Bytes — Zeichen fuer Zeichen die Bytes von
  /// vor 2.0.0 (MEHRGERAETE.md §15, mit relay_server.py vereinbart).
  final int? kyberPreKeyId;

  /// base64 der serialisierten 1569 Bytes.
  final String? kyberPreKey;

  /// base64 der 64-Byte-XEdDSA-Signatur.
  final String? kyberPreKeySignature;

  final List<RelayKyberPreKey> oneTimeKyberPreKeys;

  const RelayPreKeyBundle({
    required this.userId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.kyberPreKeyId,
    this.kyberPreKey,
    this.kyberPreKeySignature,
    this.oneTimePreKeys = const [],
    this.oneTimeKyberPreKeys = const [],
    this.deviceId,
  });

  Map<String, Object?> toJson() => {
        if (deviceId != null) 'device_id': deviceId,
        'user_id': userId,
        'identity_key': identityKey,
        'registration_id': registrationId,
        'signed_prekey_id': signedPreKeyId,
        'signed_prekey': signedPreKey,
        'signed_prekey_sig': signedPreKeySignature,
        'one_time_prekeys': oneTimePreKeys.map((k) => k.toJson()).toList(),
        if (kyberPreKey != null) ...{
          'kyber_prekey_id': kyberPreKeyId,
          'kyber_prekey': kyberPreKey,
          'kyber_prekey_sig': kyberPreKeySignature,
          'one_time_kyber_prekeys':
              oneTimeKyberPreKeys.map((k) => k.toJson()).toList(),
        },
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
    final kyberOtk = [...oneTimeKyberPreKeys]
      ..sort((a, b) => a.keyId.compareTo(b.keyId));
    final payload = <String, Object?>{
      // 'd' KOMMT VOR 'i' — deshalb steht die Geraetekennung ganz vorne, und
      // deshalb nur dann, wenn es sie gibt: `json.dumps(..., sort_keys=True)`
      // auf der Serverseite laesst ein fehlendes Feld einfach weg, und Dart
      // schreibt in Einfuegereihenfolge. Nur so sind die Bytes eines Geraets
      // ohne Kennung Byte fuer Byte die von vorher.
      //
      // WARUM DIE KENNUNG UEBERHAUPT MITSIGNIERT WIRD: stuende sie nur im
      // Rumpf, koennte ein Weiterleitender sie aendern und dieselbe Signatur
      // weiterverwenden. Die Registrierung landete unter fremder
      // Geraetenummer und loeschte dort die Einmalschluessel des echten
      // Geraets — dieselbe Luecke, die relay_server.py fuer registration_id
      // schon beschreibt.
      if (deviceId != null) 'device_id': deviceId,
      'identity_key': identityKey,
      // KYBER WIRD MITSIGNIERT (seit 2.0.0). Sonst koennte ein
      // Weiterleitender die Kyber-Felder austauschen und den Einmalvorrat des
      // Geraets mit Muell ueberschreiben — libsignal wuerde die falschen
      // Signaturen zwar beim Sitzungsaufbau ablehnen, aber dann waere niemand
      // mehr erreichbar. Reihenfolge: 'k' vor 'o', und 'kyber_prekey' vor
      // 'kyber_prekey_id' vor 'kyber_prekey_sig' (kuerzerer Praefix zuerst),
      // genau wie Pythons sort_keys. 'one_time_kyber_prekeys' vor
      // 'one_time_prekeys' ('k' < 'p'). Mit relay_server.py vereinbart.
      if (kyberPreKey != null) ...{
        'kyber_prekey': kyberPreKey,
        'kyber_prekey_id': kyberPreKeyId,
        'kyber_prekey_sig': kyberPreKeySignature,
        'one_time_kyber_prekeys':
            kyberOtk.map((k) => [k.keyId, k.publicKey, k.signature]).toList(),
      },
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

  /// Der Kyber-Prekey dieses Geraets: ein Einmalschluessel, wenn der Relay
  /// noch einen hatte, sonst der Last-Resort-Schluessel. Null bei einem
  /// Geraet mit alter App (ohne Kyber) — mit dem kann die offizielle
  /// libsignal keine Sitzung aufbauen.
  final int? kyberPreKeyId;
  final String? kyberPreKey;
  final String? kyberPreKeySignature;

  /// Welches Geraet dieser Adresse dieses Buendel gehoert.
  final int deviceId;

  /// Die Signatur des GERAETESCHLUESSELS am signierten Prekey, base64
  /// (docs/GERAETEABMELDUNG.md §12.5 a), UNGEPRUEFT. Null bei einem Geraet
  /// mit App vor 2.0.1 oder einem Relay, der das Feld nicht kennt.
  final String? spkGeraeteSig;

  /// Die WEITEREN Geraete derselben Adresse, jedes mit eigenem Buendel.
  ///
  /// Leer bei einem Relay, der die Erweiterung nicht kennt — dann gibt es
  /// genau ein Geraet und das sind die flachen Felder oben. [alleGeraete]
  /// macht daraus einen Fall statt zweier.
  final List<RelayBundleResponse> geraete;

  /// Die signierte Geraeteliste der Adresse, wie der Relay sie mitschickt
  /// (`{"liste","sig_identitaet","sig_geraet"}`), UNGEPRUEFT. Null bei einer
  /// Adresse ohne Liste oder einem Relay, der keine kennt. Pruefen tut der
  /// Kern mit `Geraeteliste.pruefe` (docs/GERAETEABMELDUNG.md §8.7).
  final Map<String, Object?>? geraeteliste;

  const RelayBundleResponse({
    required this.userId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.oneTimePreKey,
    this.kyberPreKeyId,
    this.kyberPreKey,
    this.kyberPreKeySignature,
    this.deviceId = 1,
    this.geraete = const [],
    this.geraeteliste,
    this.spkGeraeteSig,
  });

  /// Alle Geraete der Adresse, immer mindestens eines.
  ///
  /// Die flachen Felder sind laut Spezifikation §3.3 eine KOPIE von
  /// `geraete[0]` — steht die Liste da, waere ihre zusaetzliche Auswertung ein
  /// doppelter Sitzungsaufbau mit demselben Geraet. Deshalb entweder die Liste
  /// oder die flachen Felder, nie beides.
  List<RelayBundleResponse> get alleGeraete =>
      geraete.isEmpty ? <RelayBundleResponse>[this] : geraete;

  static RelayBundleResponse fromJson(Map<String, Object?> j) {
    final otk = j['one_time_prekey'];
    final rohGeraete = j['geraete'];
    final rohListe = j['geraeteliste'];
    return RelayBundleResponse(
      geraeteliste: rohListe is Map ? rohListe.cast<String, Object?>() : null,
      userId: j['user_id']! as String,
      identityKey: j['identity_key']! as String,
      registrationId: j['registration_id'] as int? ?? 0,
      signedPreKeyId: j['signed_prekey_id']! as int,
      signedPreKey: j['signed_prekey']! as String,
      signedPreKeySignature: j['signed_prekey_sig']! as String,
      oneTimePreKey: otk == null
          ? null
          : RelayOneTimePreKey.fromJson((otk as Map).cast<String, Object?>()),
      kyberPreKeyId: j['kyber_prekey_id'] as int?,
      kyberPreKey: j['kyber_prekey'] as String?,
      kyberPreKeySignature: j['kyber_prekey_sig'] as String?,
      deviceId: j['device_id'] as int? ?? 1,
      spkGeraeteSig: j['spk_geraete_sig'] as String?,
      geraete: rohGeraete is! List
          ? const []
          : [
              for (final g in rohGeraete)
                // ADRESSE UND IDENTITAETSSCHLUESSEL STEHEN NUR OBEN, einmal je
                // Antwort: alle Geraete einer Adresse teilen sich beides — das
                // ist die Voraussetzung des ganzen Vorhabens (zwoelf Woerter =
                // eine Identitaet). Je Geraet stehen nur die Sitzungsschluessel
                // da.
                fromJson({
                  'user_id': j['user_id'],
                  'identity_key': j['identity_key'],
                  ...(g as Map).cast<String, Object?>(),
                }),
            ],
    );
  }
}
