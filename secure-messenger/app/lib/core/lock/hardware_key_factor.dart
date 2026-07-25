// hardware_key_factor.dart — der Sicherheitsschluessel als Faktor.
//
// Der Stick liefert einen Schluessel, den niemand kopieren kann: man schickt
// ihm ein festes Salz, er antwortet mit HMAC(sein interner Schluessel, Salz).
// Sein interner Schluessel verlaesst ihn nie — auch nicht auf Verlangen, auch
// nicht mit dem Stick in der Hand. Deshalb ist er als Faktor staerker als
// alles, was auf dem Telefon liegt.
//
// ZWEI BERUEHRUNGEN BEIM EINRICHTEN, EINE BEIM ENTSPERREN
// Beim Einrichten legt die App erst einen Zugang an (eine Beruehrung) und holt
// dann das Geheimnis dazu (die zweite). Anders geht es nicht: das Geheimnis
// gibt es nur ueber getAssertion, und getAssertion braucht einen Zugang, den
// es vorher nicht gab.
//
// WAS PASSIERT, WENN DER STICK WEG IST
// Dann laesst sich DIESES Fach nicht mehr oeffnen. Deshalb sollte immer noch
// ein zweites Fach existieren — ein Fingerabdruck oder ein Passwort. Die
// Identitaet selbst haengt nicht daran: die zwoelf Woerter holen sie auf einem
// neuen Geraet zurueck. Verloren waeren die Nachrichten auf diesem Telefon.

import 'dart:typed_data';

import '../fido/client_pin.dart';
import '../fido/ctap.dart';
import '../fido/hmac_secret.dart';
import '../fido/pin_protocol.dart';
import 'key_vault.dart';
import 'unlock_factor.dart';

/// Oeffnet einen Weg zum Stick — per NFC oder per Kabel.
///
/// Die Wahl trifft die Oberflaeche, nicht dieser Faktor: sie weiss, ob der
/// Nutzer den Stick angelegt oder eingesteckt hat.
typedef StickOeffner = Future<CtapTransport> Function();

/// Der Stick kann nicht, was gebraucht wird.
class StickUngeeignetException implements Exception {
  final String grund;
  const StickUngeeignetException(this.grund);
  @override
  String toString() => 'StickUngeeignetException: $grund';
}

/// Der Stick verlangt eine PIN, die App hat aber keine bekommen.
class StickPinNoetigException implements Exception {
  const StickPinNoetigException();
  @override
  String toString() => 'StickPinNoetigException: dieser Stick hat eine PIN';
}

class HardwareKeyFactor extends KekUnlockFactor {
  HardwareKeyFactor({
    required this.oeffne,
    this.pin,
    this.label = 'Sicherheitsschluessel',
  });

  final StickOeffner oeffne;

  /// Die PIN DES STICKS — nicht die des Telefons und nicht die der App.
  ///
  /// Null, solange keine bekannt ist. Hat der Stick eine gesetzt, wird das zum
  /// Fehler [StickPinNoetigException]; die Oberflaeche fragt dann nach und
  /// versucht es erneut. Umgekehrt schadet eine PIN nichts, die der Stick gar
  /// nicht verlangt — sie wird dann einfach nicht benutzt.
  final String? pin;

  @override
  final String label;

  @override
  UnlockFactorKind get kind => UnlockFactorKind.hardwareKey;

  /// Legt einen Zugang auf dem Stick an und verschliesst das Geheimnis damit.
  ///
  /// Ueberschreibt die Vorlage aus [KekUnlockFactor], weil das Anlegen hier
  /// wirklich etwas anderes ist als das Oeffnen: es entsteht dabei eine
  /// Zugangskennung, die anschliessend im Fach stehen muss.
  @override
  Future<KeySlot> createSlot(Uint8List secret, {required int createdAt}) async {
    return _amStick((ctap, protokoll, token) async {
      final hmac = HmacSecret(ctap);
      final zugang = await hmac.legeZugangAn(pin: protokoll, pinToken: token);
      final kek = await hmac.holeGeheimnis(
          zugang: zugang, pin: protokoll, pinToken: token);
      return KeyVault.sealSlot(
        secret: secret,
        kek: kek,
        kind: kind,
        label: label,
        handle: zugang.credentialId,
        createdAt: createdAt,
      );
    });
  }

  @override
  Future<Uint8List> deriveKek({KeySlot? slot, Argon2Params? kdf}) async {
    final kennung = slot?.handle;
    if (kennung == null) {
      throw const VaultFormatException(
          'Stick-Fach ohne Zugangskennung — so laesst es sich nicht oeffnen');
    }
    return _amStick((ctap, protokoll, token) => HmacSecret(ctap).holeGeheimnis(
          zugang: StickZugang(kennung),
          pin: protokoll,
          pinToken: token,
        ));
  }

  /// Beim Stick sind die Gruende SICHTBAR, anders als sonst im Schluesselfach.
  ///
  /// Die Vorlage in [KekUnlockFactor] verschweigt bewusst, woran ein Fehlschlag
  /// lag — bei einem Passwort waere jede Unterscheidung ein Hinweis fuer
  /// jemanden, der Moeglichkeiten durchprobiert. Beim Stick ist es umgekehrt:
  /// er zaehlt die Fehlversuche selbst mit und sperrt sich nach acht endgueltig.
  /// Wer nicht erfaehrt, dass die PIN falsch war und wie viele Versuche noch
  /// bleiben, verbrennt sie ahnungslos — und mit dem letzten ist der Stick
  /// dauerhaft unbrauchbar. Etwas durchprobieren laesst sich hier ohnehin
  /// nicht: die Bremse sitzt im Stick, nicht in dieser App.
  @override
  Future<Uint8List> unlock(KeySlot slot) async {
    final kek = await deriveKek(slot: slot, kdf: slot.kdf);
    return KeyVault.openSlot(slot, kek);
  }

  /// Verbindung aufbauen, Faehigkeiten pruefen, PIN klaeren, danach aufraeumen.
  Future<T> _amStick<T>(
      Future<T> Function(Ctap2, PinProtocolV1, Uint8List?) arbeit) async {
    final transport = await oeffne();
    await transport.verbinde();
    try {
      final ctap = Ctap2(transport);
      final info = await ctap.holeInfo();

      if (!info.kannHmacSecret) {
        throw const StickUngeeignetException(
            'Dieser Stick kann hmac-secret nicht. Damit laesst sich kein '
            'gleichbleibendes Geheimnis aus ihm holen.');
      }

      final clientPin = ClientPin(ctap);
      if (!info.hatPin) {
        // Ohne PIN wird trotzdem ein Schluesselaustausch gebraucht: die Salze
        // laufen immer verschluesselt.
        return await arbeit(ctap, await clientPin.holeSchluesselAustausch(), null);
      }

      final eingabe = pin;
      if (eingabe == null) throw const StickPinNoetigException();
      final sitzung = await clientPin.holeToken(eingabe);
      return await arbeit(ctap, sitzung.protokoll, sitzung.token);
    } finally {
      try {
        await transport.trenne();
      } catch (_) {
        // Beim Aufraeumen ist ein Fehler belanglos — der eigentliche Fehler,
        // falls es einen gab, soll durchkommen und nicht ueberdeckt werden.
      }
    }
  }
}
