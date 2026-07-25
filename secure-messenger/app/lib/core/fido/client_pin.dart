// client_pin.dart — die PIN des Sticks.
//
// WARUM DAS SEIN MUSS
// Auf dem Titan ist eine PIN gesetzt (clientPin: true). Ab da verlangt der
// Stick bei jedem Befehl, der etwas Vertrauliches tut, einen Nachweis, dass
// die PIN vorlag. Ohne diesen Nachweis antwortet er mit 0x27 "PIN wird
// verlangt" — und zwar unabhaengig davon, wie richtig alles andere ist.
//
// DIE PIN VERLAESST DAS TELEFON NIE IM KLARTEXT
// Uebertragen werden die ersten 16 Byte ihres SHA-256, und auch die nur
// verschluesselt mit dem gemeinsamen Geheimnis aus pin_protocol.dart. Zurueck
// kommt ein Token, ebenfalls verschluesselt. Dieses Token gilt, solange der
// Stick anliegt, und beglaubigt danach jeden Befehl.
//
// WAS DER STICK MITZAEHLT
// Er hat zwei Zaehler: acht Versuche insgesamt, und drei seit dem letzten
// Einstecken. Sind die drei aufgebraucht, muss der Stick ab- und wieder
// angesetzt werden; sind die acht aufgebraucht, ist er dauerhaft gesperrt und
// alle Zugaenge darauf sind verloren. Deshalb wird der verbleibende Stand hier
// mitgefuehrt und der Nutzer gewarnt, statt ihn blind weiterprobieren zu
// lassen.

import 'dart:typed_data';

import 'ctap.dart';
import 'ctap_cbor.dart';
import 'pin_protocol.dart';

/// Ein gueltiges PIN-Token samt der Sitzung, zu der es gehoert.
///
/// Beides gehoert zusammen: das Token ist mit dem gemeinsamen Geheimnis DIESER
/// Sitzung verschluesselt zurueckgekommen. Ein Token aus einer anderen Sitzung
/// waere wertlos.
class PinSitzung {
  final PinProtocolV1 protokoll;
  final Uint8List token;

  const PinSitzung(this.protokoll, this.token);
}

/// Wird geworfen, wenn die PIN nicht stimmte.
///
/// Anders als beim Schluesselfach ist hier eine genaue Meldung richtig: der
/// Stick zaehlt selbst mit und sperrt sich. Wer nicht erfaehrt, wie viele
/// Versuche noch bleiben, brennt sie ahnungslos auf.
class PinFalschException implements Exception {
  /// Verbleibende Versuche insgesamt, soweit der Stick sie nennt.
  final int? verbleibend;
  const PinFalschException(this.verbleibend);

  @override
  String toString() => verbleibend == null
      ? 'PinFalschException: PIN falsch'
      : 'PinFalschException: PIN falsch, noch $verbleibend Versuche';
}

class ClientPin {
  ClientPin(this.ctap);

  final Ctap2 ctap;

  static const int _befehlClientPin = 0x06;
  static const int _unterGetRetries = 0x01;
  static const int _unterGetKeyAgreement = 0x02;
  static const int _unterGetPinToken = 0x05;

  /// Wie viele Versuche der Stick noch zulaesst, bevor er sich sperrt.
  Future<int?> verbleibendeVersuche() async {
    final antwort = await ctap.befehl(
        _befehlClientPin,
        CtapCbor.kodiere(<int, Object>{
          1: 1, // pinUvAuthProtocol
          2: _unterGetRetries,
        }));
    final n = antwort[3];
    return n is int ? n : null;
  }

  /// Handelt nur das gemeinsame Geheimnis aus, ohne PIN.
  ///
  /// Wird auch dann gebraucht, wenn auf dem Stick GAR KEINE PIN gesetzt ist:
  /// die Salze der hmac-secret-Erweiterung laufen immer verschluesselt, PIN
  /// hin oder her.
  Future<PinProtocolV1> holeSchluesselAustausch() async {
    final antwort = await ctap.befehl(
        _befehlClientPin,
        CtapCbor.kodiere(<int, Object>{
          1: 1, // pinUvAuthProtocol
          2: _unterGetKeyAgreement,
        }));
    final stickCose = antwort[1];
    if (stickCose is! Map) {
      throw const FormatException('Der Stick nannte keinen Schluessel');
    }
    return PinProtocolV1.aushandeln(stickCose);
  }

  /// Handelt das gemeinsame Geheimnis aus und holt damit das PIN-Token.
  ///
  /// Ein Schritt, weil beides nur zusammen brauchbar ist: das Token kommt mit
  /// genau diesem Geheimnis verschluesselt zurueck.
  Future<PinSitzung> holeToken(String pin) async {
    final protokoll = await holeSchluesselAustausch();
    final pinHashEnc = await protokoll.verschluesselePinHash(pin);

    final Map<Object?, Object?> tokenAntwort;
    try {
      tokenAntwort = await ctap.befehl(
          _befehlClientPin,
          CtapCbor.kodiere(<int, Object>{
            1: 1,
            2: _unterGetPinToken,
            3: protokoll.eigenerCoseKey,
            6: pinHashEnc,
          }));
    } on CtapException catch (e) {
      // 0x31 PIN falsch, 0x34 zu viele Fehlversuche seit dem Einstecken,
      // 0x33 danach ist der Stick fuer diese Sitzung dicht.
      if (e.status == 0x31 || e.status == 0x33 || e.status == 0x34) {
        int? rest;
        try {
          rest = await verbleibendeVersuche();
        } catch (_) {
          // Wenn selbst das nicht mehr geht, bleibt die Zahl eben unbekannt.
        }
        throw PinFalschException(rest);
      }
      rethrow;
    }

    final tokenEnc = tokenAntwort[2];
    if (tokenEnc is! List<int>) {
      throw const FormatException('Der Stick lieferte kein Token');
    }
    final token = await protokoll.entschluessele(Uint8List.fromList(tokenEnc));
    return PinSitzung(protokoll, token);
  }
}
