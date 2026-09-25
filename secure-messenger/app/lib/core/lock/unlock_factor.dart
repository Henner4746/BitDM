// unlock_factor.dart — die Faktoren, mit denen sich ein Fach oeffnen laesst.
//
// Es gibt zwei Bauarten, und die Schnittstelle muss beide tragen:
//
//   1. Der Faktor LIEFERT einen Schluessel. Ein Passwort, durch Argon2id
//      geschickt; ein FIDO2-Stick, der auf eine Aufgabe antwortet. Diese Sorte
//      erbt von [KekUnlockFactor] und muss nur den Schluessel besorgen.
//
//   2. Der Faktor GIBT SEINEN SCHLUESSEL NIE HERAUS. Der Schluesselspeicher
//      von Android ist so gebaut: der Schluessel entsteht im gesicherten
//      Bereich des Geraets und verlaesst ihn nie: man reicht Daten hinein und
//      bekommt sie verschluesselt zurueck. Genau das macht ihn stark —
//      auslesen laesst sich nichts, und der gesicherte Bereich verweigert die
//      Arbeit, solange der Fingerabdruck nicht vorlag. Diese Sorte setzt
//      [UnlockFactor] direkt um.
//
// Deshalb sitzt die Schnittstelle bei "Fach anlegen" und "Fach oeffnen" und
// nicht bei "Schluessel liefern". Waere es umgekehrt, liesse sich der
// Schluesselspeicher gar nicht anbinden — und damit der beste verfuegbare
// Schutz nicht nutzen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_vault.dart';

/// Wird geworfen, wenn ein Passwort zu schwach ist, um allein zu tragen.
class WeakPassphraseException implements Exception {
  final int geschaetzteBits;
  final int verlangteBits;
  const WeakPassphraseException(this.geschaetzteBits, this.verlangteBits);
  @override
  String toString() => 'WeakPassphraseException: geschaetzt rund '
      '$geschaetzteBits Bit, verlangt sind $verlangteBits';
}

abstract class UnlockFactor {
  UnlockFactorKind get kind;

  /// Was der Nutzer spaeter in der Liste seiner Faktoren sieht.
  String get label;

  /// Verschliesst [secret] in einem neuen Fach.
  Future<KeySlot> createSlot(Uint8List secret, {required int createdAt});

  /// Oeffnet [slot] und gibt das Geheimnis zurueck.
  ///
  /// Wirft [UnlockFailedException], wenn es nicht passt — ohne zu verraten,
  /// woran es lag.
  Future<Uint8List> unlock(KeySlot slot);
}

/// Faktoren, die beim Oeffnen ein altes Fach gleich neu versiegeln koennen.
///
/// Eine EIGENE Schnittstelle und kein weiteres Pflichtstueck von
/// [UnlockFactor]: sonst muesste jeder nachgebaute Faktor in den Tests sie
/// mitbringen. Der Tresor fragt mit `is` nach und faellt sonst auf
/// [UnlockFactor.unlock] zurueck — dann bleibt das Fach eben, wie es ist.
///
/// Moeglich ist das Neuversiegeln ohne Zutun des Nutzers, weil jeder Faktor
/// seinen Fachschluessel beim Oeffnen ohnehin in der Hand hat: das Passwort
/// laeuft durch Argon2id, der Stick hat geantwortet, der Schluesselspeicher
/// hat nach dem Fingerabdruck herausgegeben. Keine zweite Abfrage noetig.
abstract class ErneuerndesOeffnen {
  Future<FachOeffnung> oeffne(KeySlot slot);
}

/// Faktoren, die einen Schluessel liefern koennen.
abstract class KekUnlockFactor implements UnlockFactor, ErneuerndesOeffnen {
  /// Besorgt den 32-Byte-Schluessel fuer dieses Fach.
  ///
  /// [slot] ist beim Anlegen noch nicht vorhanden; dann steckt alles Noetige
  /// in [kdf].
  Future<Uint8List> deriveKek({KeySlot? slot, Argon2Params? kdf});

  /// Die Einstellungen fuer ein NEUES Fach. Ohne Ableitung: null.
  Argon2Params? neueKdfParams() => null;

  @override
  Future<KeySlot> createSlot(Uint8List secret, {required int createdAt}) async {
    final kdf = neueKdfParams();
    final kek = await deriveKek(kdf: kdf);
    return KeyVault.sealSlot(
      secret: secret,
      kek: kek,
      kind: kind,
      label: label,
      kdf: kdf,
      createdAt: createdAt,
    );
  }

  @override
  Future<Uint8List> unlock(KeySlot slot) async => (await oeffne(slot)).geheimnis;

  @override
  Future<FachOeffnung> oeffne(KeySlot slot) async =>
      KeyVault.oeffneUndErneuere(slot, await _kekOhneGrund(slot));

  /// Besorgt den Schluessel und verschweigt, woran es scheiterte.
  Future<Uint8List> _kekOhneGrund(KeySlot slot) async {
    try {
      return await deriveKek(slot: slot, kdf: slot.kdf);
    } catch (_) {
      // Auch ein Fehlschlag beim Beschaffen des Schluessels — etwa ein Stick,
      // der nicht anliegt — darf sich nach aussen nicht von einem falschen
      // Schluessel unterscheiden.
      throw const UnlockFailedException();
    }
  }
}

/// Ein Passwort dieser App, durch Argon2id gehaertet.
class PassphraseFactor extends KekUnlockFactor {
  PassphraseFactor(
    this.passphrase, {
    this.label = 'Passwort',
    required this.geraeteGebunden,
  });

  final String passphrase;

  @override
  final String label;

  /// Ob ueber diesem Fach noch der gesicherte Bereich des Geraets liegt.
  ///
  /// Das entscheidet, wie stark das Passwort sein muss. Mit Geraetebindung
  /// kann niemand die Moeglichkeiten in Ruhe durchprobieren — jeder Versuch
  /// muss durch den gesicherten Bereich, und der zaehlt mit und bremst. Eine
  /// sechsstellige PIN reicht dann.
  ///
  /// OHNE Geraetebindung — auf dem Rechner, oder auf einem Telefon ohne
  /// gesicherte Bildschirmsperre — kann jemand mit der Datei in der Hand so
  /// viele Versuche machen, wie er will, und zwar auf eigener Hardware.
  /// Argon2id verteuert jeden Versuch, gemessen auf rund 160 ms; bei einer
  /// sechsstelligen PIN sind das trotzdem nur eine Million Versuche. Deshalb
  /// muss das Passwort dann selbst genug hergeben.
  final bool geraeteGebunden;

  @override
  UnlockFactorKind get kind => UnlockFactorKind.passphrase;

  /// Verlangte Staerke ohne Geraetebindung.
  static const int minimumBitsOhneGeraet = 60;

  @override
  Argon2Params? neueKdfParams() {
    if (!geraeteGebunden) {
      final bits = schaetzeBits(passphrase);
      if (bits < minimumBitsOhneGeraet) {
        throw WeakPassphraseException(bits, minimumBitsOhneGeraet);
      }
    }
    return Argon2Params.owasp();
  }

  /// Leitet den Fachschluessel aus den UTF-8-BYTES des Passworts ab.
  ///
  /// BIS 24.09.2026 STAND HIER `SecretKey(passphrase.codeUnits)`. codeUnits
  /// sind UTF-16-Einheiten, also Zahlen bis 65535 — Argon2id nimmt aber
  /// Bytes und behielt von jeder Einheit nur die unteren acht Bit. "абв"
  /// (U+0430..U+0432) wurde damit zu denselben Bytes wie "012": zwei
  /// verschiedene Passwoerter, ein Schluessel. Wer kyrillisch, griechisch
  /// oder mit Emoji tippte, hatte weit weniger Passwortraum als gedacht.
  ///
  /// Fuer reines ASCII sind beide Wege Byte fuer Byte gleich; fuer alles
  /// andere nicht. Deshalb gibt es [_leiteAltAb] noch — siehe [oeffne].
  @override
  Future<Uint8List> deriveKek({KeySlot? slot, Argon2Params? kdf}) =>
      _argon2(kdf ?? slot?.kdf, SecretKey(utf8.encode(passphrase)));

  /// Die Ableitung von vor dem 25.09.2026, UNVERAENDERT — nur damit alte
  /// Faecher noch aufgehen. Neue Faecher entstehen damit nie.
  Future<Uint8List> _leiteAltAb(Argon2Params? p) =>
      _argon2(p, SecretKey(passphrase.codeUnits));

  static Future<Uint8List> _argon2(Argon2Params? p, SecretKey eingabe) async {
    if (p == null) {
      throw const VaultFormatException('Passwort-Fach ohne Ableitung');
    }
    final schluessel = await Argon2id(
      parallelism: p.parallelism,
      memory: p.memory,
      iterations: p.iterations,
      hashLength: 32,
    ).deriveKey(
      secretKey: eingabe,
      nonce: p.salt,
    );
    return Uint8List.fromList(await schluessel.extractBytes());
  }

  /// Ob die alte Ableitung etwas anderes ergaebe als die neue.
  bool get _ausserhalbAscii => passphrase.codeUnits.any((c) => c > 0x7F);

  /// Oeffnet ein Fach — auch eines, das noch mit der alten Ableitung
  /// verschlossen wurde — und schreibt es dann mit der neuen neu.
  ///
  /// DER ABLAUF:
  ///   1. Neue Ableitung (UTF-8). Passt sie, ist alles gut; ein Fach in
  ///      Fassung 1 wird dabei nur neu versiegelt, mit demselben Schluessel.
  ///   2. Nur wenn das Passwort Zeichen ausserhalb von ASCII enthaelt: die
  ///      alte Ableitung. Passt SIE, war es ein altes Fach — es wird mit dem
  ///      Schluessel aus Schritt 1 neu versiegelt. Danach oeffnet es nur
  ///      noch das richtige Passwort, und "012" nicht mehr das Fach von
  ///      "абв".
  ///
  /// Fuer reines ASCII gibt es Schritt 2 nicht: beide Ableitungen sind dann
  /// gleich, ein zweiter Versuch waere doppelte Arbeit fuer nichts. Damit ist
  /// der Uebergang fuer ASCII-Passwoerter trivial sicher.
  ///
  /// NICHT SICHTBAR IN DER DATEI: ob ein Fach schon umgeschrieben wurde,
  /// steht nirgends im Klartext. Stuende es dort, verriete ein altes
  /// Panik-Fach neben einem umgeschriebenen echten Fach, welches welches ist
  /// — das Panik-Fach wird ja nie mit seinem Passwort geoeffnet und bliebe
  /// fuer immer alt. So sehen beide gleich aus, und beide werden beim
  /// Entsperren gleich behandelt.
  ///
  /// EHRLICHE EINSCHRAENKUNG: solange ein altes Fach eines Nicht-ASCII-
  /// Passworts noch nicht umgeschrieben ist, oeffnet es weiterhin auch ein
  /// Passwort mit denselben unteren Bytes. Das ist der Zustand von vorher,
  /// nicht schlechter; er endet mit dem ersten Entsperren durch das echte
  /// Passwort.
  @override
  Future<FachOeffnung> oeffne(KeySlot slot) async {
    final neu = await _kekOhneGrund(slot);
    try {
      return await KeyVault.oeffneUndErneuere(slot, neu);
    } on UnlockFailedException {
      if (!_ausserhalbAscii) rethrow;
    }
    final Uint8List alt;
    try {
      alt = await _leiteAltAb(slot.kdf);
    } catch (_) {
      throw const UnlockFailedException();
    }
    final (geheimnis, _) = await KeyVault.oeffneFach(slot, alt);
    return FachOeffnung(
      geheimnis,
      warAktuell: false,
      erneuert: await KeyVault.versiegleNeu(slot, geheimnis, neu),
    );
  }

  /// Grobe Schaetzung der Staerke: Zeichenvorrat hoch Laenge.
  ///
  /// EHRLICHE EINSCHRAENKUNG: Die Schaetzung unterstellt, dass die Zeichen
  /// zufaellig gewaehlt wurden. Bei "Passwort123" liegt sie deutlich zu hoch —
  /// so ein Passwort steht in jeder Wortliste und faellt in Sekunden, egal was
  /// hier herauskommt. Sie ist also eine Untergrenze fuer die LAENGE und kein
  /// Urteil ueber die Qualitaet. Genau deshalb ist die Schwelle hoch gesetzt:
  /// sie soll die Faelle abfangen, in denen jemand ohne Geraetebindung eine
  /// vierstellige PIN eintippt.
  static int schaetzeBits(String s) {
    if (s.isEmpty) return 0;
    var vorrat = 0;
    if (s.contains(RegExp(r'[a-z]'))) vorrat += 26;
    if (s.contains(RegExp(r'[A-Z]'))) vorrat += 26;
    if (s.contains(RegExp(r'[0-9]'))) vorrat += 10;
    if (s.contains(RegExp(r'[^a-zA-Z0-9]'))) vorrat += 33;
    if (vorrat <= 1) return 0;
    // log2(vorrat) * laenge, ohne dart:math importieren zu muessen waere es
    // umstaendlich — hier ist es die Klarheit wert.
    return (s.length * (_log2(vorrat.toDouble()))).floor();
  }

  static double _log2(double x) {
    // ln(x) / ln(2)
    var ergebnis = 0.0;
    var rest = x;
    while (rest >= 2) {
      rest /= 2;
      ergebnis += 1;
    }
    // Linearer Anteil zwischen zwei Zweierpotenzen — fuer eine Schaetzung
    // genau genug.
    return ergebnis + (rest - 1);
  }
}
