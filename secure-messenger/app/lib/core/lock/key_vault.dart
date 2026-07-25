// key_vault.dart — die Schluesselfaecher der App-Sperre.
//
// Ohne Sperre gilt heute: wer das entsperrte Telefon in der Hand haelt, oeffnet
// BitDM und liest alles. Das soll sich aendern — aber nicht durch eine
// Bildschirmabfrage. Eine Abfrage im Stil von "Fingerabdruck erkannt, App auf"
// waere wertlos: der Datenbankschluessel laege weiterhin greifbar auf dem
// Geraet, und wer die Datei direkt liest, kaeme an der Abfrage vorbei.
//
// Deshalb ist die Sperre hier rechnerisch. Das Geheimnis — bei BitDM die 16
// Bytes Entropie, aus denen Seed-Phrase, Identitaet und Datenbankschluessel
// entstehen — liegt NUR verschluesselt auf der Platte. Wer den Faktor nicht
// hat, hat kein Geheimnis, sondern Rauschen.
//
// Der Aufbau folgt den Key-Slots einer Festplattenverschluesselung: mehrere
// Faecher, jedes fuer einen anderen Faktor, jedes mit derselben Nutzlast. Wer
// einen Faktor hinzufuegt oder entfernt, laesst die anderen unberuehrt. Und es
// gibt kein Hauptpasswort, das alle Faecher auf einmal oeffnet — genau darum
// ist die Sperre nicht umgehbar.
//
// WAS DIESE SPERRE NICHT LEISTET, UND ZWAR MIT ABSICHT: Sie schuetzt DIESES
// GERAET. Gehen alle Faktoren verloren, sind die Nachrichten auf diesem
// Telefon verloren. Die Identitaet nicht — die zwoelf Woerter holen sie auf
// einem neuen Geraet zurueck. Waere es anders, waere ein verlorener
// Hardware-Schluessel gleichbedeutend mit einer verlorenen Identitaet, und das
// ist bei einem Messenger ohne Server ein endgueltiger Verlust.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Womit sich ein Fach oeffnen laesst.
enum UnlockFactorKind {
  /// Fingerabdruck oder Gesicht, ueber den Schluesselspeicher des Geraets.
  biometric,

  /// Die Geraete-PIN oder das Geraetemuster, ebenfalls ueber den
  /// Schluesselspeicher.
  deviceCredential,

  /// Ein eigenes Passwort dieser App.
  passphrase,

  /// Ein FIDO2-Stick ueber NFC oder USB-C.
  hardwareKey,
}

extension UnlockFactorKindName on UnlockFactorKind {
  String get id => switch (this) {
        UnlockFactorKind.biometric => 'biometric',
        UnlockFactorKind.deviceCredential => 'device_credential',
        UnlockFactorKind.passphrase => 'passphrase',
        UnlockFactorKind.hardwareKey => 'hardware_key',
      };

  static UnlockFactorKind? byId(String id) {
    for (final k in UnlockFactorKind.values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// Einstellungen der langsamen Ableitung fuer Passwort-Faecher.
///
/// Sie stehen IM Fach und nicht im Programmcode. Nur so lassen sie sich spaeter
/// anheben, ohne bestehende Faecher unlesbar zu machen: jedes Fach wird mit den
/// Werten geoeffnet, mit denen es angelegt wurde.
class Argon2Params {
  /// Arbeitsspeicher in Kilobyte-Bloecken.
  final int memory;
  final int iterations;
  final int parallelism;
  final Uint8List salt;

  const Argon2Params({
    required this.memory,
    required this.iterations,
    required this.parallelism,
    required this.salt,
  });

  /// Die Empfehlung des OWASP fuer Argon2id.
  ///
  /// Gemessen rund 160 ms auf einem Arbeitsplatzrechner; auf einem schwachen
  /// Telefon ist knapp eine Sekunde zu erwarten. Das ist der Preis fuer ein
  /// Entsperren und gleichzeitig die Bremse fuer jeden, der Passwoerter
  /// durchprobiert.
  factory Argon2Params.owasp({Uint8List? salt}) => Argon2Params(
        memory: 19456,
        iterations: 2,
        parallelism: 1,
        salt: salt ?? zufallsBytes(16),
      );

  Map<String, Object?> toJson() => {
        'algorithm': 'argon2id',
        'memory': memory,
        'iterations': iterations,
        'parallelism': parallelism,
        'salt': base64.encode(salt),
      };

  static Argon2Params fromJson(Map<String, Object?> j) {
    final algo = j['algorithm'];
    if (algo != 'argon2id') {
      throw VaultFormatException('unbekannte Ableitung: $algo');
    }
    return Argon2Params(
      memory: j['memory']! as int,
      iterations: j['iterations']! as int,
      parallelism: j['parallelism']! as int,
      salt: base64.decode(j['salt']! as String),
    );
  }

  /// Fuer die mitverschluesselten Zusatzdaten — muss eindeutig und stabil sein.
  String get canonical =>
      'argon2id:$memory:$iterations:$parallelism:${base64.encode(salt)}';
}

class VaultFormatException implements Exception {
  final String grund;
  const VaultFormatException(this.grund);
  @override
  String toString() => 'VaultFormatException: $grund';
}

/// Wird geworfen, wenn ein Fach sich mit dem angebotenen Schluessel nicht
/// oeffnen laesst.
///
/// Bewusst OHNE Angabe, woran es lag. Ein Fehler, der zwischen "falsches
/// Passwort" und "beschaedigtes Fach" unterscheidet, waere ein Hinweis fuer
/// jeden, der Passwoerter durchprobiert.
class UnlockFailedException implements Exception {
  const UnlockFailedException();
  @override
  String toString() => 'UnlockFailedException: das Fach liess sich nicht '
      'oeffnen';
}

/// Ein einzelnes Fach: dieselbe Nutzlast, verschlossen mit einem Faktor.
class KeySlot {
  final String id;
  final UnlockFactorKind kind;

  /// Was der Nutzer sieht, etwa "Fingerabdruck" oder "gelber Stick".
  /// Absichtlich NICHT Teil der Zusatzdaten — Umbenennen soll das Fach nicht
  /// unbrauchbar machen, und ein umbenanntes Fach ist kein Angriff.
  final String label;

  final int createdAt;

  /// Nur bei [UnlockFactorKind.passphrase] belegt.
  final Argon2Params? kdf;

  /// Was der Faktor braucht, um sich wiederzufinden — und was dabei kein
  /// Geheimnis ist.
  ///
  /// Bei einem Hardware-Stick ist das die Kennung des Zugangs, den er beim
  /// Einrichten angelegt hat. Sie steht ohnehin auf dem Stick; hier liegt sie,
  /// damit die App beim Entsperren sagen kann, WELCHEN Zugang sie meint.
  ///
  /// Wer sie in der Datei aendert, macht das Fach unbrauchbar — sie haengt in
  /// den Zusatzdaten. Das ist gewollt: ein untergeschobener Zugang wuerde sonst
  /// stillschweigend mitgenommen.
  final Uint8List? handle;

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  const KeySlot({
    required this.id,
    required this.kind,
    required this.label,
    required this.createdAt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    this.kdf,
    this.handle,
  });

  /// Diese Angaben werden MITVERSCHLUESSELT, ohne selbst geheim zu sein.
  ///
  /// Wer sie in der Datei aendert — etwa die Ableitung eines Passwort-Fachs
  /// abschwaecht oder die Nutzlast eines Fachs in ein anderes kopiert — macht
  /// das Fach damit unlesbar, statt sich einen Vorteil zu verschaffen.
  List<int> get aad => utf8.encode('bitdm-keyslot-v1|$id|${kind.id}|'
      '${kdf?.canonical ?? '-'}|${handle == null ? '-' : base64.encode(handle!)}');

  KeySlot mitLabel(String neu) => KeySlot(
        id: id,
        kind: kind,
        label: neu,
        createdAt: createdAt,
        nonce: nonce,
        cipherText: cipherText,
        mac: mac,
        kdf: kdf,
        handle: handle,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.id,
        'label': label,
        'createdAt': createdAt,
        if (kdf != null) 'kdf': kdf!.toJson(),
        if (handle != null) 'handle': base64.encode(handle!),
        'nonce': base64.encode(nonce),
        'cipherText': base64.encode(cipherText),
        'mac': base64.encode(mac),
      };

  static KeySlot fromJson(Map<String, Object?> j) {
    final kind = UnlockFactorKindName.byId(j['kind'] as String? ?? '');
    if (kind == null) {
      throw VaultFormatException('unbekannter Faktor: ${j['kind']}');
    }
    final kdfJson = j['kdf'];
    final handle = j['handle'];
    return KeySlot(
      id: j['id']! as String,
      kind: kind,
      label: j['label'] as String? ?? '',
      createdAt: j['createdAt'] as int? ?? 0,
      kdf: kdfJson == null
          ? null
          : Argon2Params.fromJson((kdfJson as Map).cast<String, Object?>()),
      handle: handle == null ? null : base64.decode(handle as String),
      nonce: base64.decode(j['nonce']! as String),
      cipherText: base64.decode(j['cipherText']! as String),
      mac: base64.decode(j['mac']! as String),
    );
  }
}

/// Alle Faecher zusammen. Diese Datei liegt UNVERSCHLUESSELT neben der
/// Datenbank — sie muss lesbar sein, bevor irgendetwas aufgeschlossen ist.
/// Geheim ist nur die Nutzlast in den Faechern.
class KeyVault {
  static const int currentVersion = 1;

  final int version;
  final List<KeySlot> slots;

  /// Nach wie vielen Sekunden im Hintergrund die App wieder verriegelt.
  ///
  /// STEHT HIER UND NICHT IN DEN EINSTELLUNGEN, und das ist keine
  /// Bequemlichkeit: die Einstellungen liegen IN der verschluesselten
  /// Datenbank. Beim Sperren wird sie geschlossen — die Frist waere dann
  /// genau in dem Moment nicht lesbar, in dem sie gebraucht wird.
  ///
  /// 0 heisst sofort. Das ist der Standard: wer eine Sperre einrichtet, will
  /// gefragt werden, und nicht manchmal.
  final int sperrfristSekunden;

  /// Wie oft im Hintergrund nach Nachrichten gesehen wird. 0 heisst gar
  /// nicht, -1 heisst dauerhaft verbunden.
  ///
  /// Steht hier aus demselben Grund wie die Sperrfrist: die Einstellungen
  /// liegen in der verschluesselten Datenbank, und die ist beim Sperren zu.
  final int empfangsTaktMinuten;

  const KeyVault({
    this.version = currentVersion,
    required this.slots,
    this.sperrfristSekunden = 0,
    this.empfangsTaktMinuten = 0,
  });

  bool get isEmpty => slots.isEmpty;

  Duration get sperrfrist => Duration(seconds: sperrfristSekunden);

  KeyVault mitSperrfrist(int sekunden) => KeyVault(
        version: version,
        slots: slots,
        sperrfristSekunden: sekunden,
        empfangsTaktMinuten: empfangsTaktMinuten,
      );

  KeyVault mitEmpfangsTakt(int minuten) => KeyVault(
        version: version,
        slots: slots,
        sperrfristSekunden: sperrfristSekunden,
        empfangsTaktMinuten: minuten,
      );

  KeySlot? slotById(String id) {
    for (final s in slots) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<KeySlot> slotsOf(UnlockFactorKind kind) =>
      slots.where((s) => s.kind == kind).toList();

  String toJsonString() => const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'lockDelaySeconds': sperrfristSekunden,
        'backgroundPollMinutes': empfangsTaktMinuten,
        'slots': slots.map((s) => s.toJson()).toList(),
      });

  static KeyVault fromJsonString(String text) {
    final Object? roh;
    try {
      roh = jsonDecode(text);
    } on FormatException catch (e) {
      throw VaultFormatException('kein gueltiges JSON: ${e.message}');
    }
    if (roh is! Map) throw const VaultFormatException('kein Objekt');
    final version = roh['version'];
    if (version is! int) throw const VaultFormatException('Fassung fehlt');
    if (version > currentVersion) {
      throw VaultFormatException('Faecher stammen aus einer neueren '
          'App-Fassung ($version, diese App kennt $currentVersion)');
    }
    final slots = roh['slots'];
    if (slots is! List) throw const VaultFormatException('slots fehlt');
    // Fehlt die Frist, ist das kein Fehler: Faecher aus einer aelteren
    // Fassung haben sie nicht. Sofort zu sperren ist dann die sichere Annahme.
    final frist = roh['lockDelaySeconds'];
    return KeyVault(
      version: version,
      sperrfristSekunden: frist is int ? frist : 0,
      empfangsTaktMinuten:
          roh['backgroundPollMinutes'] is int ? roh['backgroundPollMinutes'] as int : 0,
      slots: slots
          .map((e) => KeySlot.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }

  /// Legt ein Fach an, das mit [kek] verschlossen ist.
  ///
  /// [kek] ist der Schluessel, den der Faktor liefert — bei einem Passwort das
  /// Ergebnis von Argon2id, bei einem Hardware-Stick dessen Antwort. Faktoren,
  /// die ihren Schluessel gar nicht herausgeben koennen (der Schluesselspeicher
  /// von Android gibt ihn nicht heraus, er verschluesselt selbst), bringen ihre
  /// eigene Umsetzung mit; siehe unlock_factor.dart.
  static Future<KeySlot> sealSlot({
    required Uint8List secret,
    required Uint8List kek,
    required UnlockFactorKind kind,
    required String label,
    Argon2Params? kdf,
    Uint8List? handle,
    required int createdAt,
    String? id,
  }) async {
    if (kek.length != 32) {
      throw ArgumentError('Fachschluessel muss 32 Bytes haben, '
          'hat ${kek.length}');
    }
    final slotId = id ?? base64Url.encode(zufallsBytes(12));
    // Ein leeres Fach zum Berechnen der Zusatzdaten — sie haengen nur an
    // Angaben, die schon feststehen.
    final vorlage = KeySlot(
      id: slotId,
      kind: kind,
      label: label,
      createdAt: createdAt,
      kdf: kdf,
      handle: handle,
      nonce: Uint8List(0),
      cipherText: Uint8List(0),
      mac: Uint8List(0),
    );

    final box = await AesGcm.with256bits().encrypt(
      secret,
      secretKey: SecretKey(kek),
      aad: vorlage.aad,
    );

    return KeySlot(
      id: slotId,
      kind: kind,
      label: label,
      createdAt: createdAt,
      kdf: kdf,
      handle: handle,
      nonce: Uint8List.fromList(box.nonce),
      cipherText: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Oeffnet ein Fach mit dem Schluessel, den ein Faktor geliefert hat.
  static Future<Uint8List> openSlot(KeySlot slot, Uint8List kek) async {
    if (kek.length != 32) throw const UnlockFailedException();
    try {
      final klar = await AesGcm.with256bits().decrypt(
        SecretBox(slot.cipherText, nonce: slot.nonce, mac: Mac(slot.mac)),
        secretKey: SecretKey(kek),
        aad: slot.aad,
      );
      return Uint8List.fromList(klar);
    } catch (_) {
      // Alles unter einen Fehler: falscher Schluessel, veraenderte Zusatzdaten
      // und beschaedigte Datei sollen von aussen nicht unterscheidbar sein.
      throw const UnlockFailedException();
    }
  }

  KeyVault mitSlot(KeySlot slot) =>
      KeyVault(
          version: version,
          sperrfristSekunden: sperrfristSekunden,
          empfangsTaktMinuten: empfangsTaktMinuten,
          slots: [...slots, slot]);

  /// Entfernt ein Fach.
  ///
  /// Das LETZTE Fach laesst sich nicht entfernen. Sonst bliebe eine Datenbank
  /// zurueck, deren Schluessel niemand mehr hat — und die App wuerde das
  /// klaglos zulassen.
  KeyVault ohneSlot(String id) {
    if (slotById(id) == null) {
      throw ArgumentError('kein Fach mit der Kennung $id');
    }
    if (slots.length <= 1) {
      throw StateError('das letzte Fach laesst sich nicht entfernen — sonst '
          'waere die Datenbank fuer immer verschlossen');
    }
    return KeyVault(
      version: version,
      sperrfristSekunden: sperrfristSekunden,
      empfangsTaktMinuten: empfangsTaktMinuten,
      slots: slots.where((s) => s.id != id).toList(),
    );
  }
}

final _zufall = Random.secure();

Uint8List zufallsBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _zufall.nextInt(256);
  }
  return b;
}
