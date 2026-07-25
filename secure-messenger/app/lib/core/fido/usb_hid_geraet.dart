// usb_hid_geraet.dart â€” die Dart-Seite des USB-Kanals.
//
// Duenn mit Absicht: alles, was schiefgehen kann, steckt in der Verpackung des
// Protokolls (ctap_hid.dart), und die ist ohne Geraet pruefbar. Hier bleibt nur
// das, was ohne Android nicht geht.


import 'package:flutter/services.dart';

import 'ctap_hid.dart';

class UsbStick {
  final String name;
  final String hersteller;
  final String produkt;
  final int vendorId;
  final int productId;

  const UsbStick({
    required this.name,
    required this.hersteller,
    required this.produkt,
    required this.vendorId,
    required this.productId,
  });

  /// Was der Nutzer lesen soll. Manche Sticks melden keinen Namen â€” dann
  /// bleiben die Kennungen, mit denen sich immerhin unterscheiden laesst,
  /// welcher gemeint ist.
  String get anzeige {
    final n = [hersteller, produkt].where((s) => s.isNotEmpty).join(' ');
    if (n.isNotEmpty) return n;
    return 'USB ${vendorId.toRadixString(16).padLeft(4, '0')}:'
        '${productId.toRadixString(16).padLeft(4, '0')}';
  }
}

class UsbHidGeraet implements HidGeraet {
  static const _kanal = MethodChannel('bitdm/usb_hid');

  /// Alle eingesteckten Geraete, die nach einem FIDO-Stick aussehen.
  static Future<List<UsbStick>> liste() async {
    final roh = await _kanal.invokeListMethod<Map<Object?, Object?>>('liste');
    return (roh ?? [])
        .map((m) => UsbStick(
              name: m['name'] as String? ?? '',
              hersteller: m['hersteller'] as String? ?? '',
              produkt: m['produkt'] as String? ?? '',
              vendorId: m['vendorId'] as int? ?? 0,
              productId: m['productId'] as int? ?? 0,
            ))
        .toList();
  }

  /// Oeffnet einen Stick. Fragt beim ersten Mal die Erlaubnis des Nutzers ab â€”
  /// Android zeigt dafuer einen Systemdialog.
  static Future<UsbHidGeraet> oeffne({String? name}) async {
    await _kanal.invokeMethod<bool>('oeffne', {'name': name});
    return UsbHidGeraet();
  }

  @override
  Future<void> schreibe(Uint8List bericht64) async {
    await _kanal.invokeMethod<bool>('schreibe', {'daten': bericht64});
  }

  @override
  Future<Uint8List> lies({Duration frist = const Duration(seconds: 5)}) async {
    final b = await _kanal.invokeMethod<Uint8List>(
        'lies', {'fristMs': frist.inMilliseconds});
    if (b == null) throw const FormatException('Keine Antwort vom Stick');
    return b;
  }

  @override
  Future<void> schliesse() async {
    await _kanal.invokeMethod<bool>('schliesse');
  }
}
