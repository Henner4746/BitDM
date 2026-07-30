// Feste Zahlen, damit eine zweite Implementierung dagegen rechnen kann.
import 'dart:typed_data';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bekannte Eingaben, bekanntes Leuchtfeuer', () async {
    final geheimnis = Uint8List.fromList(List.generate(32, (i) => i));
    final pubkey = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final lf = await Leuchtfeuer.fuerFenster(
        geheimnis: geheimnis, senderOeffentlicher: pubkey, fenster: 1983641);
    // FESTGENAGELT, damit eine zweite Implementierung dagegen rechnen kann —
    // und damit ein stiller Wechsel des Verfahrens auffaellt. Genau so ist am
    // 29.07.2026 herausgekommen, dass der Kontext als `aad` verworfen wurde:
    // Dart und Python lieferten dasselbe, obwohl Dart einen Kontext angab.
    expect(
        lf.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'ea46b452b761',
        reason: 'das Verfahren hat sich geaendert — beide Seiten muessen '
            'gleichzeitig aktualisiert werden, sonst erkennt sich niemand mehr');
  });
}
