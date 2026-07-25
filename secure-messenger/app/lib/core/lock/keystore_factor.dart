// keystore_factor.dart — der Schluesselspeicher des Geraets als Fach.
//
// DER TRICK, DEN ES HIER BRAUCHT
// Der gesicherte Bereich von Android gibt seinen Schluessel niemals heraus. Er
// verschluesselt selbst und verweigert die Arbeit, solange keine Anmeldung
// vorlag. Damit passt er nicht in ein Schluesselfach, das einen 32-Byte-
// Schluessel erwartet.
//
// Die Loesung ist eine Umdrehung: das Fach bekommt einen ZUFAELLIGEN Schluessel,
// und DIESER Schluessel wird im gesicherten Bereich abgelegt. Ohne
// Fingerabdruck gibt der Bereich ihn nicht heraus, ohne ihn bleibt das Fach zu.
// Der Schutz ist derselbe, aber jetzt liegt er in derselben Form vor wie bei
// allen anderen Faktoren — und laesst sich mit ihnen mischen.
//
// WARUM NICHT WEITER WIE BISHER
// Bisher lag die Entropie direkt im gesicherten Bereich (app_lock.dart). Das
// funktioniert, solange es genau EINEN Faktor gibt. Sobald ein zweiter
// dazukommt, geht es nicht mehr: die Entropie laege dann an zwei Stellen, und
// die schwaechere davon entscheidet. Ein Hardware-Stick waere wertlos, wenn
// daneben dieselbe Entropie ohne ihn zu haben ist.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_vault.dart';
import 'unlock_factor.dart';

/// Die kleine Menge dessen, was vom Schluesselspeicher gebraucht wird.
///
/// Als eigene Schnittstelle, weil [FlutterSecureStorage] ein Plattform-Plugin
/// ist und in Tests nicht laeuft. Ohne sie waere dieser Faktor der einzige,
/// der ungeprueft bliebe — und er ist der, auf den am Ende alle zurueckfallen.
abstract class SchluesselAblage {
  Future<String?> lies(String schluessel);
  Future<void> schreibe(String schluessel, String wert);
  Future<void> loesche(String schluessel);
}

/// Die echte Ablage, ueber [FlutterSecureStorage].
class GeraeteAblage implements SchluesselAblage {
  GeraeteAblage(this._speicher);

  final FlutterSecureStorage _speicher;

  // ═══════════════════════════════════════════════ WARUM DIE NAMENSRAEUME
  //
  // DER FEHLER, DEN SIE VERHINDERN, IST DER GEFAEHRLICHSTE IN DIESER DATEI:
  // Ohne storageNamespace benutzen ALLE Ablagen denselben Schluessel im
  // gesicherten Bereich, dieselbe Einstellungsdatei und denselben
  // Schluesselspeicher — das Paket leitet alle drei Namen aus dem
  // Namensraum ab, und ohne ihn kommt ueberall dasselbe heraus.
  //
  // Zusammen mit migrateOnAlgorithmChange heisst das: sobald die Ablage OHNE
  // Anmeldezwang etwas anfasst, schreibt sie die Daten auf einen Schluessel
  // um, der KEINE Anmeldung verlangt. Der Fingerabdruck ist damit still
  // ausgehebelt — die App fragt nicht mehr, und es sieht aus, als haette sie
  // nie gefragt. Genau so war es bis zum 25.07.2026.
  //
  // Der Namensraum der Ablage OHNE Anmeldung bleibt bewusst leer: dort liegt
  // bei vorhandenen Installationen die Entropie, und ein neuer Name hiesse,
  // dass sie nicht mehr gefunden wird.
  static const String namensraumBiometrie = 'bitdm_bio_v1';
  static const String namensraumGeraetePin = 'bitdm_pin_v1';

  /// Fingerabdruck oder Gesicht — und NUR das.
  ///
  /// strongBiometricOnly schliesst die Geraete-PIN aus. Das ist der ganze
  /// Punkt dieser Zeile: waere die PIN erlaubt, waere sie kein eigener Faktor
  /// mehr, sondern derselbe mit zwei Namen.
  ///
  /// enforceBiometrics: true verlangt, dass das Geraet ueberhaupt gesichert
  /// ist. Auf einem Telefon ohne Sperrbildschirm schlaegt das Anlegen fehl —
  /// richtig so: eine Sperre, die jeder oeffnet, waere keine.
  factory GeraeteAblage.biometrie() => GeraeteAblage(FlutterSecureStorage(
        aOptions: AndroidOptions.biometric(
          enforceBiometrics: true,
          biometricType: AndroidBiometricType.strongBiometricOnly,
          storageNamespace: namensraumBiometrie,
          migrateOnAlgorithmChange: true,
          migrateWithBackup: true,
          biometricPromptTitle: 'BitDM entsperren',
          biometricPromptSubtitle: 'Fingerabdruck oder Gesicht',
        ),
      ));

  /// Die Sperre des Geraets: PIN, Muster oder Passwort.
  ///
  /// Der Rueckfall, wenn der Finger nass ist, verletzt oder nicht erkannt
  /// wird — und auf Telefonen ohne Fingerabdrucksensor der einzige Weg.
  factory GeraeteAblage.geraetePin() => GeraeteAblage(FlutterSecureStorage(
        aOptions: AndroidOptions.biometric(
          enforceBiometrics: true,
          biometricType: AndroidBiometricType.biometricOrDeviceCredential,
          storageNamespace: namensraumGeraetePin,
          migrateOnAlgorithmChange: true,
          migrateWithBackup: true,
          biometricPromptTitle: 'BitDM entsperren',
          biometricPromptSubtitle: 'Geraetesperre',
        ),
      ));

  @override
  Future<String?> lies(String schluessel) => _speicher.read(key: schluessel);

  @override
  Future<void> schreibe(String schluessel, String wert) =>
      _speicher.write(key: schluessel, value: wert);

  @override
  Future<void> loesche(String schluessel) =>
      _speicher.delete(key: schluessel);
}

/// Fingerabdruck, Gesicht, Geraete-PIN oder Muster — was das Geraet anbietet.
class KeystoreFactor implements UnlockFactor {
  KeystoreFactor({
    required this.ablage,
    this.kind = UnlockFactorKind.biometric,
    this.label = 'Geraetesperre',
  });

  /// Der Fingerabdruck-Faktor, fertig verdrahtet.
  factory KeystoreFactor.biometrie({String label = 'Fingerabdruck'}) =>
      KeystoreFactor(
        ablage: GeraeteAblage.biometrie(),
        kind: UnlockFactorKind.biometric,
        label: label,
      );

  /// Der Geraetesperren-Faktor, fertig verdrahtet.
  factory KeystoreFactor.geraetePin({String label = 'Geraete-PIN'}) =>
      KeystoreFactor(
        ablage: GeraeteAblage.geraetePin(),
        kind: UnlockFactorKind.deviceCredential,
        label: label,
      );

  final SchluesselAblage ablage;

  @override
  final UnlockFactorKind kind;

  @override
  final String label;

  /// Unter welchem Namen der Fachschluessel im gesicherten Bereich liegt.
  static String schluesselFuer(String slotId) => 'bitdm_slot_kek_$slotId';

  @override
  Future<KeySlot> createSlot(Uint8List secret, {required int createdAt}) async {
    final slotId = base64Url.encode(zufallsBytes(12));
    final kek = zufallsBytes(32);

    // ZUERST ablegen, dann versiegeln. Andersherum bliebe bei einem Fehlschlag
    // ein Fach zurueck, dessen Schluessel nirgends steht — ein Fach, das nie
    // wieder aufgeht und das die Oberflaeche trotzdem als Faktor anzeigt.
    await ablage.schreibe(schluesselFuer(slotId), base64.encode(kek));

    try {
      return await KeyVault.sealSlot(
        secret: secret,
        kek: kek,
        kind: kind,
        label: label,
        createdAt: createdAt,
        id: slotId,
      );
    } catch (_) {
      await _leiseLoeschen(slotId);
      rethrow;
    }
  }

  @override
  Future<Uint8List> unlock(KeySlot slot) async {
    final Uint8List kek;
    try {
      final b64 = await ablage.lies(schluesselFuer(slot.id));
      if (b64 == null) throw const UnlockFailedException();
      kek = base64.decode(b64);
    } on UnlockFailedException {
      rethrow;
    } catch (_) {
      // Fast immer: die Anmeldung wurde abgebrochen oder schlug fehl. Von
      // aussen soll das nicht von einem falschen Schluessel zu unterscheiden
      // sein.
      throw const UnlockFailedException();
    }
    return KeyVault.openSlot(slot, kek);
  }

  /// Raeumt den Fachschluessel weg, wenn das Fach entfernt wird.
  ///
  /// Ohne diesen Schritt bliebe im gesicherten Bereich ein Eintrag liegen, der
  /// zu nichts mehr gehoert — und beim Panik-Loeschen ist "fast alles weg"
  /// nichts wert.
  Future<void> entferne(String slotId) => _leiseLoeschen(slotId);

  Future<void> _leiseLoeschen(String slotId) async {
    try {
      await ablage.loesche(schluesselFuer(slotId));
    } catch (_) {
      // Bei eingeschalteter Anmeldung verlangt schon das Loeschen eine
      // Anmeldung. Bricht sie ab, bleibt der Eintrag liegen — das Fach ist
      // trotzdem weg und damit unbrauchbar.
    }
  }
}
