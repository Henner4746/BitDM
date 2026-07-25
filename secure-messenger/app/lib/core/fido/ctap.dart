// ctap.dart — CTAP2, unabhaengig davon, wie der Stick angeschlossen ist.
//
// Ein Sicherheitsschluessel spricht ueber NFC und ueber USB DASSELBE Protokoll,
// aber in voellig verschiedener Verpackung:
//
//   NFC:  ISO-7816-Kommandos, der CTAP-Befehl steckt im Datenteil eines APDU
//   USB:  CTAPHID, 64-Byte-Pakete mit eigener Kanalkennung und Fragmentierung
//
// Diese Datei kennt nur den Inhalt: einen CBOR-Befehl rein, eine CBOR-Antwort
// raus. Das Verpacken machen die Transporte daneben. So gibt es die
// eigentliche Protokolllogik genau einmal, statt zweimal fast gleich — und
// fast gleich ist die Sorte Verdopplung, bei der ein Fehler nur in einer der
// beiden Haelften behoben wird.

import 'dart:typed_data';

import 'package:cbor/simple.dart' as cbor;

/// Ein Weg zum Stick. Bekommt einen CTAP2-Befehl, liefert die Antwort —
/// beides OHNE die Verpackung des jeweiligen Transports.
abstract class CtapTransport {
  /// Antwort einschliesslich des fuehrenden Statusbytes.
  Future<Uint8List> sende(Uint8List befehl);

  /// Meldet sich beim Stick an, falls der Transport das braucht.
  Future<void> verbinde();

  Future<void> trenne();

  /// Fuer Meldungen an den Nutzer: "per NFC" oder "per Kabel".
  String get name;
}

/// Fehler des Sticks, mit der Bedeutung aus der CTAP2-Spezifikation.
class CtapException implements Exception {
  final int status;
  const CtapException(this.status);

  String get bedeutung => switch (status) {
        0x00 => 'in Ordnung',
        0x11 => 'Befehl unbekannt',
        0x12 => 'Antwort passt nicht',
        0x19 => 'Der Stick arbeitet noch',
        0x22 => 'Ungueltiger Parameter',
        0x27 => 'PIN wird verlangt',
        0x2E => 'PIN ist noetig, aber nicht gesetzt',
        0x2F => 'Zu viele Fehlversuche — Stick abziehen und neu ansetzen',
        0x30 => 'PIN gesperrt — Stick aus- und wieder einstecken',
        0x31 => 'PIN falsch',
        0x33 => 'PIN zu oft falsch — Stick neu ansetzen',
        0x34 => 'Zu viele Fehlversuche seit dem Einstecken',
        0x35 => 'Diese Erweiterung kennt der Stick nicht',
        0x36 => 'Kein passender Zugang auf diesem Stick',
        _ => 'Fehler 0x${status.toRadixString(16).padLeft(2, "0")}',
      };

  /// Ob es sich lohnt, den Nutzer noch einmal probieren zu lassen.
  bool get erneutVersuchen => status == 0x31 || status == 0x34;

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
  /// aber nichts verschluesseln — eine App-Sperre waere damit nicht zu bauen.
  /// Die Erweiterung ist in CTAP2 OPTIONAL und steht in keiner
  /// Produktbeschreibung.
  bool get kannHmacSecret => erweiterungen.contains('hmac-secret');

  /// Ob der Stick Zugaenge dauerhaft speichern kann. Fuer BitDM noetig: es
  /// gibt keinen Server, der eine Kennung vorhalten koennte.
  bool get kannResidentKey => eigenschaften['rk'] == true;

  /// Ob auf dem Stick eine PIN GESETZT ist.
  ///
  /// In CTAP2 bedeutet das Feld dreierlei: fehlt es, kann der Stick keine PIN;
  /// steht false, kann er sie, hat aber keine; steht true, ist eine gesetzt.
  /// Nur im letzten Fall wird sie bei jeder Abfrage verlangt.
  bool get hatPin => eigenschaften['clientPin'] == true;

  @override
  String toString() => 'CTAP ${versionen.join(", ")} | '
      'hmac-secret: ${kannHmacSecret ? "ja" : "nein"} | '
      'PIN: ${hatPin ? "gesetzt" : "keine"}';
}

class Ctap2 {
  Ctap2(this.transport);

  final CtapTransport transport;

  /// Fragt den Stick, was er kann. Befehl 0x04.
  ///
  /// Der einzige Befehl, der weder eine PIN noch eine Beruehrung verlangt und
  /// nichts veraendert — deshalb der richtige, um zu prüfen, ob ein Stick
  /// ueberhaupt taugt.
  Future<CtapInfo> holeInfo() async {
    final roh = await _befehl(Uint8List.fromList([0x04]));
    final karte = cbor.cbor.decode(roh);
    if (karte is! Map) {
      throw const FormatException(
          'authenticatorGetInfo lieferte kein CBOR-Objekt');
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
      aaguid:
          aaguid is List ? Uint8List.fromList(aaguid.cast<int>()) : Uint8List(0),
    );
  }

  /// Schickt einen Befehl mit Parametern und liefert die Antwortkarte.
  ///
  /// Der Befehlscode steht als erstes Byte VOR dem CBOR — das ist die
  /// CTAP2-Rahmung, unabhaengig vom Transport.
  Future<Map<Object?, Object?>> befehl(int code, Uint8List parameter) async {
    final roh = await _befehl(
        Uint8List.fromList([code, ...parameter]));
    if (roh.isEmpty) return const {};
    final karte = cbor.cbor.decode(roh);
    if (karte is! Map) {
      throw const FormatException('Antwort ist keine CBOR-Karte');
    }
    return karte;
  }

  /// Schickt einen Befehl und trennt Status von Inhalt.
  Future<Uint8List> _befehl(Uint8List inhalt) async {
    final antwort = await transport.sende(inhalt);
    if (antwort.isEmpty) throw const CtapException(0x12);

    // Das erste Byte ist der CTAP2-Status, erst danach kommt CBOR.
    final status = antwort.first;
    if (status != 0x00) throw CtapException(status);
    return Uint8List.sublistView(antwort, 1);
  }
}
