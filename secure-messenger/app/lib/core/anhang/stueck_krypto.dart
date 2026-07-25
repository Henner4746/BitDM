// stueck_krypto.dart — ein Stueck ver- und entschluesseln.
//
// Bewusst eine eigene, sehr schmale Datei. Der Grund steht in pubspec.yaml:
// die reine Dart-Umsetzung von AES-GCM schafft rund 12 MB/s (gemessen am
// 25.07.2026, 8 MiB in 662 ms auf dem Entwicklungsrechner). Das reicht fuer
// jede Mobilfunkstrecke — die ist langsamer —, und ueber schnelles WLAN wird
// es zur Bremse.
//
// Solange das so bleibt, ist die Antwort NICHT eine schnellere Bibliothek,
// sondern die Reihenfolge: waehrend Stueck N hochlaedt, wird N+1
// verschluesselt (siehe anhang_versand.dart). Dann zaehlt der langsamere der
// beiden Wege, nicht die Summe.
//
// Sollte eine Messung auf echten Geraeten das widerlegen, wird HIER getauscht
// — eine Klasse mit zwei Methoden. Der Rest des Anhang-Wegs merkt nichts
// davon, und die Testfaelle in stueck_krypto_test.dart gelten unveraendert
// weiter, weil sie Eigenschaften pruefen und keine Bibliothek.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ein Stueck liess sich nicht entschluesseln.
///
/// EIN EINZIGER FEHLER FUER ALLE FAELLE, und das ist Absicht: ob der
/// Schluessel falsch war, der Beglaubigungsanhang nicht stimmte oder die
/// Nummer nicht passte, geht niemanden etwas an. Wer verschiedene Fehler
/// unterscheiden kann, kann raten.
class StueckKaputt implements Exception {
  const StueckKaputt();
  @override
  String toString() => 'StueckKaputt: liess sich nicht entschluesseln';
}

abstract class StueckKrypto {
  const StueckKrypto();

  Future<Uint8List> verschluessle({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  });

  Future<Uint8List> entschluessle({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  });

  /// Der beglaubigte Zusatz: Nummer und Gesamtzahl.
  ///
  /// Er wird NICHT uebertragen — beide Seiten kennen ihn aus der Anleitung.
  /// Er wirkt trotzdem: das Lager kann unter der Kennung von Stueck 3 die
  /// Bytes von Stueck 5 ausliefern, und ohne diesen Zusatz wuerde das sauber
  /// entschluesseln und still die falsche Datei ergeben.
  static Uint8List zusatz(int nummer, int vonWievielen) =>
      Uint8List.fromList('bitdm-stueck:$nummer/$vonWievielen'.codeUnits);
}

class GcmStueckKrypto extends StueckKrypto {
  const GcmStueckKrypto();

  static final _gcm = AesGcm.with256bits();

  @override
  Future<Uint8List> verschluessle({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) async {
    final box = await _gcm.encrypt(
      klar,
      secretKey: SecretKey(schluessel),
      nonce: nonce,
      aad: StueckKrypto.zusatz(nummer, vonWievielen),
    );
    // Chiffretext und Beglaubigungsanhang hintereinander — so, wie es auch
    // im Lager liegt. Der Nonce steht NICHT davor: er reist in der Anleitung.
    final aus = Uint8List(box.cipherText.length + 16);
    aus.setAll(0, box.cipherText);
    aus.setAll(box.cipherText.length, box.mac.bytes);
    return aus;
  }

  @override
  Future<Uint8List> entschluessle({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) async {
    // Ausdruecklich, obwohl der Fall auch ohne diese Zeile richtig endet:
    // sublistView wuerde bei einer negativen Grenze eine RangeError werfen,
    // die unten in StueckKaputt landet. Sich darauf zu verlassen hiesse, die
    // Richtigkeit an das Verhalten einer fremden Bereichspruefung zu haengen.
    // Eine Mutationsprobe kann den Unterschied nicht sehen — ein Umbau schon.
    if (geheim.length < 16) throw const StueckKaputt();
    final schnitt = geheim.length - 16;
    try {
      final klar = await _gcm.decrypt(
        SecretBox(
          Uint8List.sublistView(geheim, 0, schnitt),
          nonce: nonce,
          mac: Mac(Uint8List.sublistView(geheim, schnitt)),
        ),
        secretKey: SecretKey(schluessel),
        aad: StueckKrypto.zusatz(nummer, vonWievielen),
      );
      return Uint8List.fromList(klar);
    } catch (_) {
      // Auch ein unerwarteter Fehler wird zu StueckKaputt. Sonst traegt die
      // Ausnahme, die nach oben durchschlaegt, moeglicherweise Bytes im Text.
      throw const StueckKaputt();
    }
  }
}
