// ctap_nfc.dart — CTAP2 ueber NFC.
//
// Ueber NFC laeuft CTAP2 in ISO-7816-Kommandos verpackt:
//
//   1. SELECT auf die FIDO-Anwendung (AID A0000006472F0001)
//   2. NFCCTAP_MSG mit dem CTAP2-Befehl im Datenteil
//   3. Antwort: Statusbyte, danach CBOR, danach das Statuswort
//
// Antworten koennen laenger sein als ein einzelnes Kommando zulaesst; dann
// meldet der Stick 0x61xx ("noch mehr da") und man holt den Rest mit
// GET RESPONSE nach. Wer das vergisst, bekommt bei laengeren Antworten
// abgeschnittene Daten und wundert sich ueber kaputtes CBOR.

import 'dart:typed_data';

import 'ctap.dart';

class CtapNfcTransport implements CtapTransport {
  CtapNfcTransport(this.uebertrage);

  /// Schickt ein APDU und liefert die Antwort. Hereingereicht, damit diese
  /// Datei ohne NFC-Bibliothek auskommt und sich mit aufgezeichneten Antworten
  /// pruefen laesst.
  final Future<Uint8List> Function(Uint8List apdu) uebertrage;

  @override
  String get name => 'NFC';

  /// Die Kennung der FIDO-Anwendung. Steht so in der CTAP2-Spezifikation.
  static final Uint8List fidoAid =
      Uint8List.fromList([0xA0, 0x00, 0x00, 0x06, 0x47, 0x2F, 0x00, 0x01]);

  @override
  Future<void> verbinde() async {
    final apdu = Uint8List.fromList([
      0x00, 0xA4, 0x04, 0x00, // SELECT nach Namen
      fidoAid.length,
      ...fidoAid,
      0x00,
    ]);
    _pruefeStatuswort(await uebertrage(apdu));
  }

  @override
  Future<void> trenne() async {}

  @override
  Future<Uint8List> sende(Uint8List befehl) async {
    final apdu = Uint8List.fromList([
      0x80, 0x10, 0x00, 0x00, // NFCCTAP_MSG
      befehl.length,
      ...befehl,
      0x00,
    ]);

    var antwort = await uebertrage(apdu);
    final teile = <int>[];

    // 0x61xx heisst: es liegt noch mehr bereit. Ohne diese Schleife bekommt
    // man bei laengeren Antworten stillschweigend abgeschnittene Daten.
    while (antwort.length >= 2 && antwort[antwort.length - 2] == 0x61) {
      teile.addAll(antwort.sublist(0, antwort.length - 2));
      final rest = antwort[antwort.length - 1];
      antwort = await uebertrage(
          Uint8List.fromList([0x00, 0xC0, 0x00, 0x00, rest]));
    }

    _pruefeStatuswort(antwort);
    teile.addAll(antwort.sublist(0, antwort.length - 2));
    return Uint8List.fromList(teile);
  }

  static void _pruefeStatuswort(Uint8List antwort) {
    if (antwort.length < 2) {
      throw const FormatException('Antwort zu kurz — kein Statuswort');
    }
    final sw1 = antwort[antwort.length - 2];
    final sw2 = antwort[antwort.length - 1];
    if (sw1 == 0x90 && sw2 == 0x00) return;
    if (sw1 == 0x61) return; // "noch mehr da" ist kein Fehler
    throw FormatException(
        'Der Stick antwortete mit 0x${sw1.toRadixString(16).padLeft(2, "0")}'
        '${sw2.toRadixString(16).padLeft(2, "0")}');
  }
}
