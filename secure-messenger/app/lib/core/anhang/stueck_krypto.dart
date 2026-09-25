// stueck_krypto.dart — ein Stueck ver- und entschluesseln.
//
// Bewusst eine eigene, sehr schmale Datei — weil hier eine Zahl haengt, die
// sich aendern koennte.
//
// GEMESSEN AUF DEM ECHTEN GERAET (integration_test/anhang_tempo_test.dart,
// Galaxy S25 Ultra, Android 16, 25.07.2026):
//
//     verschluesseln  8,0 MB/s      entschluesseln  5,3 MB/s
//
// Auf dem Entwicklungsrechner waren es 12 MB/s. Das Telefon ist also
// LANGSAMER, nicht schneller — und Entschluesseln noch einmal deutlich
// langsamer als Verschluesseln. Wer die Entscheidung nur auf der
// Desktop-Zahl aufgebaut haette, haette sich um ein Drittel vertan.
//
// Was das bedeutet:
//   * Ueber Mobilfunk ist es egal: die Leitung ist langsamer als 8 MB/s, und
//     Verschluesseln laeuft parallel zum Uebertragen (anhang_versand.dart).
//   * Ueber schnelles WLAN ist es die Bremse.
//   * Drei Gigabyte kosten 6,4 Minuten reine Rechenzeit beim Senden und rund
//     zehn beim Empfangen.
//
// DESHALB IST DAS HIER EINE SCHNITTSTELLE UND KEINE FUNKTION. Wird eines
// Tages eine native Umsetzung eingebunden (webcrypto/BoringSSL, oder ein
// Kotlin-Kanal auf javax.crypto), wird genau diese Klasse getauscht. Der Rest
// des Anhang-Wegs merkt nichts davon, und die Testfaelle in
// stueck_krypto_test.dart gelten unveraendert weiter — sie pruefen
// Eigenschaften und keine Bibliothek.

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
  }) =>
      zuRoh(
        klar: klar,
        schluessel: schluessel,
        nonce: nonce,
        zusatz: StueckKrypto.zusatz(nummer, vonWievielen),
      );

  @override
  Future<Uint8List> entschluessle({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) =>
      aufRoh(
        geheim: geheim,
        schluessel: schluessel,
        nonce: nonce,
        zusatz: StueckKrypto.zusatz(nummer, vonWievielen),
      );

  /// AES-256-GCM mit frei gewaehltem beglaubigtem Zusatz.
  ///
  /// Der Kern beider Methoden oben — und seit der verschluesselten Ablage
  /// auf dem Geraet (ruhe_datei.dart) auch von dort benutzt, deren Zusatz
  /// anders aussieht als der eines Stuecks im Lager. Ausgabe wie immer:
  /// Chiffretext, dahinter der 16-Byte-Beglaubigungsanhang.
  static Future<Uint8List> zuRoh({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required Uint8List zusatz,
  }) async {
    final box = await _gcm.encrypt(
      klar,
      secretKey: SecretKey(schluessel),
      nonce: nonce,
      aad: zusatz,
    );
    // Chiffretext und Beglaubigungsanhang hintereinander — so, wie es auch
    // im Lager liegt. Der Nonce steht NICHT davor: er reist in der Anleitung.
    final aus = Uint8List(box.cipherText.length + 16);
    aus.setAll(0, box.cipherText);
    aus.setAll(box.cipherText.length, box.mac.bytes);
    return aus;
  }

  /// Gegenstueck zu [zuRoh]. Wirft bei JEDEM Fehler [StueckKaputt].
  static Future<Uint8List> aufRoh({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required Uint8List zusatz,
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
        aad: zusatz,
      );
      return Uint8List.fromList(klar);
    } catch (_) {
      // Auch ein unerwarteter Fehler wird zu StueckKaputt. Sonst traegt die
      // Ausnahme, die nach oben durchschlaegt, moeglicherweise Bytes im Text.
      throw const StueckKaputt();
    }
  }
}
