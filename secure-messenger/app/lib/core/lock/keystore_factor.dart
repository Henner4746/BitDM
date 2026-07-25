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

import 'key_vault.dart';
import 'unlock_factor.dart';

/// Die kleine Menge dessen, was vom Schluesselspeicher gebraucht wird.
///
/// Als eigene Schnittstelle, weil dahinter ein Plattform-Kanal steckt, der in
/// Tests nicht laeuft. Ohne sie waere dieser Faktor der einzige, der
/// ungeprueft bliebe — und er ist der, auf den am Ende alle zurueckfallen.
///
/// Die echte Umsetzung steht in geraete_fach.dart.
abstract class SchluesselAblage {
  Future<String?> lies(String schluessel);
  Future<void> schreibe(String schluessel, String wert);
  Future<void> loesche(String schluessel);
}

/// Fingerabdruck, Gesicht, Geraete-PIN oder Muster — was das Geraet anbietet.
class KeystoreFactor implements UnlockFactor {
  KeystoreFactor({
    required this.ablage,
    this.kind = UnlockFactorKind.biometric,
    this.label = 'Geraetesperre',
  });

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
