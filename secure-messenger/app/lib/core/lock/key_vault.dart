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

  /// Nur bei [UnlockFactorKind.hardwareKey]: ob das Fach MIT Nutzerpruefung
  /// (Stick-PIN) angelegt wurde.
  ///
  /// WARUM DAS IM FACH STEHEN MUSS: der Stick rechnet hmac-secret mit ZWEI
  /// verschiedenen internen Schluesseln — einem fuer Abfragen mit PIN, einem
  /// fuer Abfragen ohne (CTAP2, "CredRandomWithUV" und "...WithoutUV"). Ein
  /// Fach, das vor dem Setzen einer Stick-PIN entstand, geht also nur ohne
  /// PIN-Nachweis wieder auf, auch wenn der Stick inzwischen eine hat. Die
  /// App muss beim Oeffnen genau die Art verlangen, mit der angelegt wurde.
  ///
  /// Null bei Faechern von vor dem 25.09.2026 — dann probiert der Faktor
  /// beide Arten und schreibt das Fach danach mit dem Ergebnis neu.
  final bool? uv;

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
    this.uv,
  });

  /// Die Fassung der Zusatzdaten, mit der NEUE Faecher versiegelt werden.
  ///
  /// Fassung 1 bis 24.09.2026. Fassung 2 bindet zusaetzlich [uv] ein und —
  /// wichtiger — kennzeichnet ein Fach als "von dieser App-Fassung
  /// geschrieben". Die Kennzeichnung steht NICHT sichtbar in der Datei,
  /// sondern nur in den Zusatzdaten: wer die Datei liest, sieht einem
  /// Passwort-Fach nicht an, ob es alt oder neu ist. Das ist Absicht — sonst
  /// verriete ein altes Panik-Fach neben einem umgeschriebenen echten Fach,
  /// welches von beiden welches ist. Beim Oeffnen wird deshalb erst Fassung 2
  /// und dann Fassung 1 probiert (siehe [KeyVault.oeffneFach]); das kostet
  /// ein zweites AES-GCM, kein zweites Argon2id.
  static const int aktuelleFassung = 2;

  /// Diese Angaben werden MITVERSCHLUESSELT, ohne selbst geheim zu sein.
  ///
  /// Wer sie in der Datei aendert — etwa die Ableitung eines Passwort-Fachs
  /// abschwaecht oder die Nutzlast eines Fachs in ein anderes kopiert — macht
  /// das Fach damit unlesbar, statt sich einen Vorteil zu verschaffen.
  List<int> get aad => aadFuer(aktuelleFassung);

  /// Die Zusatzdaten einer bestimmten Fassung. Fassung 1 ist Zeichen fuer
  /// Zeichen die von vor dem 25.09.2026 — sonst gingen alte Faecher nicht
  /// mehr auf.
  List<int> aadFuer(int fassung) {
    final basis = '$id|${kind.id}|${kdf?.canonical ?? '-'}|'
        '${handle == null ? '-' : base64.encode(handle!)}';
    if (fassung <= 1) return utf8.encode('bitdm-keyslot-v1|$basis');
    return utf8.encode(
        'bitdm-keyslot-v2|$basis|${uv == null ? '-' : (uv! ? '1' : '0')}');
  }

  KeySlot mitLabel(String neu) => _kopie(label: neu);

  /// Anlagezeitpunkt tauschen. Er haengt nicht in den Zusatzdaten — er ist
  /// Anzeige, kein Schutz. Gebraucht, wenn ein Panik-Fach den Platz eines
  /// Platzhalters einnimmt (siehe vault_store.dart): es soll dann auch
  /// dessen Zeitpunkt tragen, sonst verriete der Zeitstempel den Tausch.
  KeySlot mitCreatedAt(int neu) => _kopie(createdAt: neu);

  KeySlot _kopie({String? label, int? createdAt}) => KeySlot(
        id: id,
        kind: kind,
        label: label ?? this.label,
        createdAt: createdAt ?? this.createdAt,
        nonce: nonce,
        cipherText: cipherText,
        mac: mac,
        kdf: kdf,
        handle: handle,
        uv: uv,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.id,
        'label': label,
        'createdAt': createdAt,
        if (kdf != null) 'kdf': kdf!.toJson(),
        if (handle != null) 'handle': base64.encode(handle!),
        if (uv != null) 'uv': uv,
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
      uv: j['uv'] is bool ? j['uv'] as bool : null,
      nonce: base64.decode(j['nonce']! as String),
      cipherText: base64.decode(j['cipherText']! as String),
      mac: base64.decode(j['mac']! as String),
    );
  }
}

/// Was beim Oeffnen eines Fachs herauskommt.
class FachOeffnung {
  /// Die Nutzlast — bei BitDM die 16 Bytes Entropie (oder die Panik-Marke).
  final Uint8List geheimnis;

  /// DASSELBE Fach, neu versiegelt im aktuellen Format — oder null, wenn es
  /// schon aktuell war.
  ///
  /// Gleiche Kennung, gleicher Faktor, gleicher Fachschluessel (bzw. beim
  /// Passwort die korrigierte Ableitung, siehe unlock_factor.dart). Nur die
  /// Zusatzdaten und die Verschluesselung sind neu. Der Tresor tauscht es
  /// nach einem erfolgreichen Entsperren still aus — so wandern alte Faecher
  /// ohne eigenen Schritt des Nutzers ins neue Format.
  final KeySlot? erneuert;

  /// Ob das Fach schon in [KeySlot.aktuelleFassung] versiegelt war.
  ///
  /// Das entscheidet, ob eine FEHLENDE Pruefsumme der Einstellungen ein
  /// Angriff ist (neues Fach: ja) oder nur eine Datei von vor dem Update.
  final bool warAktuell;

  const FachOeffnung(this.geheimnis, {this.erneuert, required this.warAktuell});
}

/// Alle Faecher zusammen. Diese Datei liegt UNVERSCHLUESSELT neben der
/// Datenbank — sie muss lesbar sein, bevor irgendetwas aufgeschlossen ist.
/// Geheim ist nur die Nutzlast in den Faechern.
class KeyVault {
  /// 2 seit 25.09.2026: Pruefsumme ueber die Einstellungen ("settingsMac")
  /// und Faecher in Fassung 2 (siehe [KeySlot.aktuelleFassung]).
  ///
  /// Fassung-1-Dateien werden weiter gelesen und beim naechsten Schreiben
  /// als Fassung 2 abgelegt. Eine AELTERE App lehnt Fassung 2 mit einer
  /// klaren Meldung ab ("neuere App-Fassung") — das ist besser als Faecher,
  /// die dort ohne Erklaerung nicht mehr aufgehen.
  static const int currentVersion = 2;

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
  /// gefragt werden, und nicht manchmal. -1 heisst nie.
  final int sperrfristSekunden;

  /// Wie oft im Hintergrund nach Nachrichten gesehen wird. 0 heisst gar
  /// nicht, -1 heisst dauerhaft verbunden, -2 heisst angestossen werden.
  ///
  /// Steht hier aus demselben Grund wie die Sperrfrist: die Einstellungen
  /// liegen in der verschluesselten Datenbank, und die ist beim Sperren zu.
  final int empfangsTaktMinuten;

  /// Pruefsumme ueber [sperrfristSekunden] und [empfangsTaktMinuten].
  ///
  /// WARUM: die Datei liegt unverschluesselt, und bis 24.09.2026 konnte jedes
  /// Programm desselben Nutzers "lockDelaySeconds": -1 hineinschreiben — die
  /// App haette danach nie wieder von selbst gesperrt, ohne dass es jemand
  /// bemerkt. Die Pruefsumme haengt an einem Schluessel, der aus der
  /// Entropie abgeleitet wird, und die gibt es nur bei offenem Tresor. Wer
  /// die Datei aendert, kann sie also nicht nachrechnen; beim naechsten
  /// Entsperren faellt es auf, und beide Werte gehen auf die sichere
  /// Werkseinstellung zurueck (siehe vault_store.dart).
  ///
  /// Null bei Dateien von vor dem Update und bei Dateien ohne Faecher (dann
  /// gibt es keine Sperre, die sich aushebeln liesse, und keinen Schluessel).
  final Uint8List? einstellungsMac;

  /// AB WERK: alle 15 Minuten.
  ///
  /// Stand bis zum 25.07.2026 auf "aus", mit der Begruendung, ein Dienst mit
  /// dauerhafter Benachrichtigung, den niemand bestellt hat, sei eine
  /// Zumutung. Die Ueberlegung war einseitig: wer einen Messenger
  /// installiert, will Nachrichten bekommen. Keine zu bekommen, bis man eine
  /// Einstellung findet, von der man nichts weiss, ist die groessere
  /// Zumutung — und sieht aus wie eine kaputte App.
  ///
  /// 15 Minuten und nicht "staendig": es soll von selbst funktionieren, aber
  /// nicht von selbst am meisten kosten.
  static const int empfangsTaktAbWerk = 15;

  /// Die laengste erlaubte Sperrfrist. Die Oberflaeche bietet 0, 60, 300 und
  /// "nie" (-1) an; eine Stunde laesst Luft fuer eine weitere Stufe. Was
  /// darueber liegt, kommt nicht aus der App und wird als "sofort" gelesen.
  static const int maxSperrfristSekunden = 3600;

  /// Der laengste erlaubte Empfangstakt: ein Tag. Kleiner als -2 gibt es
  /// nicht (siehe [empfangsTaktMinuten]).
  static const int maxEmpfangsTaktMinuten = 1440;

  const KeyVault({
    this.version = currentVersion,
    required this.slots,
    this.sperrfristSekunden = 0,
    this.empfangsTaktMinuten = empfangsTaktAbWerk,
    this.einstellungsMac,
  });

  /// Ob eine Sperrfrist von der App stammen kann.
  static bool sperrfristGueltig(int s) =>
      s == -1 || (s >= 0 && s <= maxSperrfristSekunden);

  /// Ob ein Empfangstakt von der App stammen kann.
  static bool empfangsTaktGueltig(int m) =>
      m >= -2 && m <= maxEmpfangsTaktMinuten;

  bool get isEmpty => slots.isEmpty;

  Duration get sperrfrist => Duration(seconds: sperrfristSekunden);

  /// Die EINE Stelle, an der kopiert wird.
  ///
  /// Bis 25.09.2026 baute jede Aenderung ihr eigenes KeyVault(...) und
  /// zaehlte die Felder selbst auf — benenneUm vergass dabei den
  /// Empfangstakt, und wer ein Fach umbenannte, stand danach still wieder
  /// auf 15 Minuten. Mit einer Kopierstelle kann das keinem Feld mehr
  /// passieren. [einstellungsMac] wird bewusst mitgenommen: ob sie noch
  /// stimmt, entscheidet der Tresor beim Schreiben.
  KeyVault _kopie({
    List<KeySlot>? slots,
    int? sperrfristSekunden,
    int? empfangsTaktMinuten,
    Uint8List? einstellungsMac,
    bool ohneMac = false,
    int? version,
  }) =>
      KeyVault(
        version: version ?? this.version,
        slots: slots ?? this.slots,
        sperrfristSekunden: sperrfristSekunden ?? this.sperrfristSekunden,
        empfangsTaktMinuten: empfangsTaktMinuten ?? this.empfangsTaktMinuten,
        einstellungsMac:
            ohneMac ? null : (einstellungsMac ?? this.einstellungsMac),
      );

  KeyVault mitSperrfrist(int sekunden) =>
      _kopie(sperrfristSekunden: sekunden);

  KeyVault mitEmpfangsTakt(int minuten) =>
      _kopie(empfangsTaktMinuten: minuten);

  /// Andere Faecher, alles andere bleibt.
  KeyVault mitSlots(List<KeySlot> neu) => _kopie(slots: neu);

  /// Ersetzt das Fach mit derselben Kennung an SEINER Stelle.
  KeyVault mitErsetztemSlot(KeySlot neu) =>
      _kopie(slots: [for (final s in slots) s.id == neu.id ? neu : s]);

  /// Neue Pruefsumme (oder keine, bei null).
  KeyVault mitEinstellungsMac(Uint8List? mac) =>
      mac == null ? _kopie(ohneMac: true) : _kopie(einstellungsMac: mac);

  /// Dieselben Angaben in der aktuellen Dateifassung.
  KeyVault inAktuellerFassung() => _kopie(version: currentVersion);

  /// Rechnet die Pruefsumme der Einstellungen mit dem Schluessel, der aus
  /// [geheimnis] (der Entropie) folgt.
  ///
  /// Zwei Schritte HMAC-SHA256: erst ein eigener Schluessel nur fuer diesen
  /// Zweck, dann die Pruefsumme damit. So wird die Entropie nicht direkt als
  /// Pruefsummen-Schluessel benutzt, und eine Pruefsumme verraet nichts
  /// ueber sie.
  Future<Uint8List> berechneEinstellungsMac(Uint8List geheimnis) async {
    final hmac = Hmac.sha256();
    final schluessel = await hmac.calculateMac(
        utf8.encode('bitdm-vault-settings-key-v1'),
        secretKey: SecretKey(geheimnis));
    final mac = await hmac.calculateMac(
        utf8.encode(
            'bitdm-vault-settings-v1|$sperrfristSekunden|$empfangsTaktMinuten'),
        secretKey: SecretKey(schluessel.bytes));
    return Uint8List.fromList(mac.bytes);
  }

  /// Ob [einstellungsMac] zu den Einstellungen passt. False, wenn sie fehlt.
  Future<bool> einstellungenEcht(Uint8List geheimnis) async {
    final vorhanden = einstellungsMac;
    if (vorhanden == null) return false;
    return gleichInKonstanterZeit(
        vorhanden, await berechneEinstellungsMac(geheimnis));
  }

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
        if (einstellungsMac != null)
          'settingsMac': base64.encode(einstellungsMac!),
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
    //
    // STRENG GEPRUEFT, NICHT BLIND UEBERNOMMEN: was nicht aus der App stammen
    // kann (etwa -5 oder eine Woche), wird als die sichere Voreinstellung
    // gelesen. Ob ein GUELTIGER Wert auch echt ist, klaert erst die
    // Pruefsumme beim Entsperren — siehe [einstellungsMac].
    final frist = roh['lockDelaySeconds'];
    final takt = roh['backgroundPollMinutes'];
    final mac = roh['settingsMac'];
    Uint8List? macBytes;
    if (mac is String) {
      try {
        macBytes = base64.decode(mac);
      } on FormatException {
        // Eine unlesbare Pruefsumme ist wie eine falsche: beim Entsperren
        // gehen die Einstellungen auf die Voreinstellung zurueck.
        macBytes = Uint8List(0);
      }
    }
    return KeyVault(
      version: version,
      sperrfristSekunden: frist is int && sperrfristGueltig(frist) ? frist : 0,
      empfangsTaktMinuten: takt is int && empfangsTaktGueltig(takt)
          ? takt
          : empfangsTaktAbWerk,
      einstellungsMac: macBytes,
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
  ///
  /// [fassung] ist nur fuer Tests, die ein Fach von vor dem Update nachbauen
  /// muessen. Die App selbst versiegelt immer in [KeySlot.aktuelleFassung].
  static Future<KeySlot> sealSlot({
    required Uint8List secret,
    required Uint8List kek,
    required UnlockFactorKind kind,
    required String label,
    Argon2Params? kdf,
    Uint8List? handle,
    bool? uv,
    required int createdAt,
    String? id,
    int fassung = KeySlot.aktuelleFassung,
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
      uv: uv,
      nonce: Uint8List(0),
      cipherText: Uint8List(0),
      mac: Uint8List(0),
    );

    final box = await AesGcm.with256bits().encrypt(
      secret,
      secretKey: SecretKey(kek),
      aad: vorlage.aadFuer(fassung),
    );

    return KeySlot(
      id: slotId,
      kind: kind,
      label: label,
      createdAt: createdAt,
      kdf: kdf,
      handle: handle,
      uv: uv,
      nonce: Uint8List.fromList(box.nonce),
      cipherText: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Oeffnet ein Fach mit dem Schluessel, den ein Faktor geliefert hat.
  static Future<Uint8List> openSlot(KeySlot slot, Uint8List kek) async =>
      (await oeffneFach(slot, kek)).$1;

  /// Wie [openSlot], sagt aber zusaetzlich, in welcher Fassung das Fach
  /// versiegelt war.
  ///
  /// Erst die aktuelle, dann Fassung 1. Beide Versuche kosten nur AES-GCM
  /// mit demselben Schluessel; gegen einen falschen Schluessel hilft der
  /// zweite Versuch nicht, denn auch er prueft das Authentifizierungs-Tag.
  static Future<(Uint8List, int)> oeffneFach(
      KeySlot slot, Uint8List kek) async {
    if (kek.length != 32) throw const UnlockFailedException();
    for (final fassung in const [KeySlot.aktuelleFassung, 1]) {
      try {
        final klar = await AesGcm.with256bits().decrypt(
          SecretBox(slot.cipherText, nonce: slot.nonce, mac: Mac(slot.mac)),
          secretKey: SecretKey(kek),
          aad: slot.aadFuer(fassung),
        );
        return (Uint8List.fromList(klar), fassung);
      } catch (_) {
        // Alles unter einen Fehler: falscher Schluessel, veraenderte
        // Zusatzdaten und beschaedigte Datei sollen von aussen nicht
        // unterscheidbar sein.
      }
    }
    throw const UnlockFailedException();
  }

  /// Oeffnet [slot] mit [kek] und versiegelt es — falls noch in Fassung 1,
  /// falls ein [neuerKek] gebraucht wird oder falls sich [uv] aendert — gleich
  /// neu.
  ///
  /// Das neue Fach behaelt Kennung, Art, Beschriftung, Anlagezeit, Ableitung
  /// und Zugangskennung. Nur so bleiben die Verweise darauf gueltig: der
  /// Fachschluessel im Schluesselspeicher haengt an der Kennung, das
  /// Panik-Fach in den Einstellungen ebenso.
  static Future<FachOeffnung> oeffneUndErneuere(KeySlot slot, Uint8List kek,
      {Uint8List? neuerKek, bool? uv}) async {
    final (geheimnis, fassung) = await oeffneFach(slot, kek);
    final aktuell = fassung >= KeySlot.aktuelleFassung;
    final umschreiben = !aktuell || neuerKek != null || uv != slot.uv;
    return FachOeffnung(
      geheimnis,
      warAktuell: aktuell,
      erneuert: umschreiben
          ? await versiegleNeu(slot, geheimnis, neuerKek ?? kek, uv: uv)
          : null,
    );
  }

  /// Dasselbe Fach, neu versiegelt in der aktuellen Fassung.
  static Future<KeySlot> versiegleNeu(
          KeySlot alt, Uint8List geheimnis, Uint8List kek, {bool? uv}) =>
      sealSlot(
        secret: geheimnis,
        kek: kek,
        kind: alt.kind,
        label: alt.label,
        kdf: alt.kdf,
        handle: alt.handle,
        uv: uv,
        createdAt: alt.createdAt,
        id: alt.id,
      );

  KeyVault mitSlot(KeySlot slot) => _kopie(slots: [...slots, slot]);

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
    return _kopie(slots: slots.where((s) => s.id != id).toList());
  }
}

/// Vergleicht zwei Bytefolgen, ohne am ersten Unterschied auszusteigen.
bool gleichInKonstanterZeit(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var unterschied = 0;
  for (var i = 0; i < a.length; i++) {
    unterschied |= a[i] ^ b[i];
  }
  return unterschied == 0;
}

final _zufall = Random.secure();

Uint8List zufallsBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _zufall.nextInt(256);
  }
  return b;
}
