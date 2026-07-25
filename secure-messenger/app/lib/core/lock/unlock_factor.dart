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

/// Faktoren, die einen Schluessel liefern koennen.
abstract class KekUnlockFactor implements UnlockFactor {
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
  Future<Uint8List> unlock(KeySlot slot) async {
    final Uint8List kek;
    try {
      kek = await deriveKek(slot: slot, kdf: slot.kdf);
    } catch (_) {
      // Auch ein Fehlschlag beim Beschaffen des Schluessels — etwa ein Stick,
      // der nicht anliegt — darf sich nach aussen nicht von einem falschen
      // Schluessel unterscheiden.
      throw const UnlockFailedException();
    }
    return KeyVault.openSlot(slot, kek);
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

  @override
  Future<Uint8List> deriveKek({KeySlot? slot, Argon2Params? kdf}) async {
    final p = kdf ?? slot?.kdf;
    if (p == null) {
      throw const VaultFormatException('Passwort-Fach ohne Ableitung');
    }
    final schluessel = await Argon2id(
      parallelism: p.parallelism,
      memory: p.memory,
      iterations: p.iterations,
      hashLength: 32,
    ).deriveKey(
      secretKey: SecretKey(passphrase.codeUnits),
      nonce: p.salt,
    );
    return Uint8List.fromList(await schluessel.extractBytes());
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
