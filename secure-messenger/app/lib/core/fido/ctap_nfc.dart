// ctap_nfc.dart — mit einem FIDO2-Stick ueber NFC reden.
//
// WARUM DIREKT UND NICHT UEBER ANDROID
// Androids Credential Manager kann Passkeys, aber die Ableitungsfunktion, die
// hier gebraucht wird, laeuft dort in der Praxis ueber den Google Password
// Manager — also ueber die Play Services. Dazu verlangt ein Passkey eine
// Domain, die Android beim Anlegen online gegenpruefen will. Eine App, die
// fuer ihre eigene Bildschirmsperre ins Netz muss und ohne Google nicht
// funktioniert, waere ein Rueckschritt gegenueber dem Fingerabdruck.
//
// Direkt mit dem Stick zu sprechen umgeht beides: kein Google, kein Netz,
// keine Domain. Der Stick rechnet, und fertig.
//
// WIE DAS AUF DER LEITUNG AUSSIEHT
// Ueber NFC laeuft CTAP2 in ISO-7816-Kommandos verpackt. Der Ablauf ist
// immer derselbe:
//
//   1. SELECT auf die FIDO-Anwendung (AID A0000006472F0001)
//   2. NFCCTAP_MSG mit einem CTAP2-Befehl im Datenteil
//   3. Antwort: ein Statusbyte, danach CBOR
//
// Antworten koennen laenger sein als ein einzelnes Kommando zulaesst; dann
// meldet der Stick 0x61xx ("noch mehr da") und man holt den Rest mit
// GET RESPONSE nach. Wer das vergisst, bekommt bei laengeren Antworten
// abgeschnittene Daten und wundert sich ueber kaputtes CBOR.

import 'dart:typed_data';

import 'package:cbor/simple.dart' as cbor;

/// Fehler des Sticks, mit der Bedeutung aus der CTAP2-Spezifikation.
class CtapException implements Exception {
  final int status;
  const CtapException(this.status);

  String get bedeutung => switch (status) {
        0x00 => 'in Ordnung',
        0x11 => 'Befehl unbekannt',
        0x12 => 'Antwort passt nicht',
        0x19 => 'Der Stick arbeitet noch',
        0x27 => 'PIN wird verlangt',
        0x2E => 'PIN ist noetig, aber nicht gesetzt',
        0x2F => 'Zu viele Fehlversuche — Stick abziehen und neu ansetzen',
        0x31 => 'PIN falsch',
        0x35 => 'Diese Erweiterung kennt der Stick nicht',
        0x36 => 'Kein passender Zugang auf diesem Stick',
        _ => 'Fehler 0x${status.toRadixString(16)}',
      };

  @override
  String toString() => 'CtapException: $bedeutung';
}

/// Was ein Stick ueber sich selbst sagt.
class CtapInfo {
  final List<String> versionen;
  final List<String> erweiterungen;
  final Map<String, bool> eigenschaften;
  final Uint8List aaguid;

  const CtapInfo({
    required this.versionen,
    required this.erweiterungen,
    required this.eigenschaften,
    required this.aaguid,
  });

  /// DIE Frage, an der alles haengt.
  ///
  /// hmac-secret ist die Rechenfunktion, mit der sich aus dem Stick ein
  /// gleichbleibendes Geheimnis holen laesst. Ohne sie kann er zwar anmelden,
  /// aber nichts verschluesseln — und eine App-Sperre waere damit nicht zu
  /// bauen.
  ///
  /// Die Erweiterung ist in CTAP2 OPTIONAL. Ob ein bestimmter Stick sie kann,
  /// steht in keiner Werbung verlaesslich; er sagt es aber selbst.
  bool get kannHmacSecret => erweiterungen.contains('hmac-secret');

  /// Ob der Stick Zugaenge dauerhaft speichern kann. Fuer BitDM noetig: es
  /// gibt keinen Server, der eine Kennung vorhalten koennte.
  bool get kannResidentKey =>
      eigenschaften['rk'] == true;

  @override
  String toString() => 'CTAP ${versionen.join(", ")} | '
      'Erweiterungen: ${erweiterungen.isEmpty ? "keine" : erweiterungen.join(", ")} | '
      'hmac-secret: ${kannHmacSecret ? "JA" : "nein"}';
}

/// Spricht CTAP2 ueber eine ISO-DEP-Verbindung.
///
/// [sende] bekommt ein fertiges APDU und liefert die Antwort — so bleibt diese
/// Datei frei von NFC-Bibliotheken und laesst sich mit aufgezeichneten
/// Antworten pruefen.
class CtapNfc {
  CtapNfc(this.sende);

  final Future<Uint8List> Function(Uint8List apdu) sende;

  /// Die Kennung der FIDO-Anwendung. Steht so in der CTAP2-Spezifikation.
  static final Uint8List fidoAid =
      Uint8List.fromList([0xA0, 0x00, 0x00, 0x06, 0x47, 0x2F, 0x00, 0x01]);

  /// Meldet sich beim Stick an. Muss vor allem anderen passieren.
  Future<void> waehleAnwendung() async {
    final apdu = Uint8List.fromList([
      0x00, 0xA4, 0x04, 0x00, // SELECT nach Namen
      fidoAid.length,
      ...fidoAid,
      0x00, // erwartete Laenge: soviel wie kommt
    ]);
    final antwort = await sende(apdu);
    _pruefeStatuswort(antwort);
  }

  /// Fragt den Stick, was er kann. CTAP2-Befehl 0x04.
  Future<CtapInfo> holeInfo() async {
    final roh = await _sendeCtap(Uint8List.fromList([0x04]));
    final karte = cbor.cbor.decode(roh);
    if (karte is! Map) {
      throw const FormatException('authenticatorGetInfo lieferte kein CBOR-Objekt');
    }

    List<String> liste(Object? o) =>
        o is List ? o.map((e) => '$e').toList() : const [];

    final opt = karte[4];
    final eigenschaften = <String, bool>{};
    if (opt is Map) {
      opt.forEach((k, v) {
        if (v is bool) eigenschaften['$k'] = v;
      });
    }

    final aaguid = karte[3];
    return CtapInfo(
      versionen: liste(karte[1]),
      erweiterungen: liste(karte[2]),
      eigenschaften: eigenschaften,
      aaguid: aaguid is List ? Uint8List.fromList(aaguid.cast<int>()) : Uint8List(0),
    );
  }

  /// Verpackt einen CTAP2-Befehl und holt die Antwort — auch wenn sie in
  /// mehreren Stuecken kommt.
  Future<Uint8List> _sendeCtap(Uint8List inhalt) async {
    final apdu = Uint8List.fromList([
      0x80, 0x10, 0x00, 0x00, // NFCCTAP_MSG
      inhalt.length,
      ...inhalt,
      0x00,
    ]);

    var antwort = await sende(apdu);
    final teile = <int>[];

    // 0x61xx heisst: es liegt noch mehr bereit. Ohne diese Schleife bekommt
    // man bei laengeren Antworten stillschweigend abgeschnittene Daten.
    while (antwort.length >= 2 && antwort[antwort.length - 2] == 0x61) {
      teile.addAll(antwort.sublist(0, antwort.length - 2));
      final rest = antwort[antwort.length - 1];
      antwort = await sende(
          Uint8List.fromList([0x00, 0xC0, 0x00, 0x00, rest]));
    }

    _pruefeStatuswort(antwort);
    teile.addAll(antwort.sublist(0, antwort.length - 2));

    if (teile.isEmpty) throw const CtapException(0x12);

    // Das erste Byte ist der CTAP2-Status, erst danach kommt CBOR.
    final status = teile.first;
    if (status != 0x00) throw CtapException(status);
    return Uint8List.fromList(teile.sublist(1));
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
