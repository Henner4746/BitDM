// signal_errors.dart — eine Fassade fuer libsignals Fehlerbehandlung.
//
// Seit 2.0.0 laeuft Signals offizielle libsignal (Rust) ueber das Paket
// `libsignal`. Sie meldet JEDEN Protokollfehler als `LibSignalException` mit
// einem Code (`LibSignalErrorCode`), nicht mehr als eigene Ausnahmeklassen wie
// die Dart-Nachbildung bis 1.9.x. Diese Datei ordnet die Codes dem zu, was der
// Client TUN muss.
//
// DER EMPFANGSPFAD FAENGT WEITER IMMER `catch (e)`, NIE `on Exception`.
// Grund 1: Die Anbindung reicht Panics aus Rust als `PanicException` durch, und
// flutter_rust_bridge kann im Fehlerfall auch andere Typen werfen. Grund 2:
// Was nicht aus libsignal kommt (unser eigener Umschlag, unsere Nutzlast),
// wirft eigene Ausnahmen. Alles, was ein Angreifer frei formen kann, muss am
// Ende in [classify] landen und darf die Empfangsschleife nie beenden.

import 'package:libsignal/libsignal.dart';

/// Wie mit einem Fehlschlag beim Entschluesseln umzugehen ist.
///
/// Die Einteilung richtet sich danach, was der Client TUN muss — nicht danach,
/// welcher Code geflogen ist.
enum SignalFailure {
  /// Nachricht kam doppelt an. Kein Fehler: stillschweigend verwerfen.
  ///
  /// Passiert im Normalbetrieb, etwa wenn eine Bestaetigung verlorenging und
  /// der Absender erneut sendet.
  duplicate,

  /// Es gibt keine Sitzung fuer diese Gegenstelle.
  ///
  /// Behebbar: Prekey-Bundle holen und neu aufbauen.
  noSession,

  /// Der Identitaetsschluessel der Gegenstelle passt nicht.
  ///
  /// Bei BitDM ein Widerspruch in sich, weil die Adresse der Schluessel IST.
  /// Tritt es auf, stimmt etwas Grundlegendes nicht — nie automatisch annehmen.
  untrusted,

  /// Ein referenzierter Prekey liegt nicht mehr vor.
  ///
  /// Normal bei doppelt zugestellten Erstnachrichten: der Prekey wurde beim
  /// ersten Mal verbraucht.
  missingKey,

  /// Die Bytes ergeben keine gueltige Nachricht, oder ihre Pruefsumme stimmt
  /// nicht.
  ///
  /// Verwerfen und protokollieren. Alles, was vom Server kommt, kann so
  /// aussehen — das ist kein Ausnahmefall, sondern zu erwarten. Einen
  /// falschen MAC meldet libsignal ebenfalls als `invalidMessage`; er fuehrt
  /// ausdruecklich NICHT zu einem Neuaufbau (siehe [shouldRebuildSession]).
  unreadable,
}

/// Ordnet einen beliebigen geworfenen Wert einer Behandlung zu.
///
/// Nimmt bewusst `Object` und nicht `Exception`: siehe Kopfkommentar.
SignalFailure classify(Object error) {
  if (error is ErneutEingespielt) return SignalFailure.duplicate;
  // NICHT `untrusted`: der Schluessel kam gar nicht bis libsignal. Eine
  // Erstnachricht, deren Schluessel nicht zur behaupteten Absenderadresse
  // passt, hat der Relay geformt — daraus darf keine Kontaktanfrage werden
  // (sonst koennte er solche Anfragen fuer bekannte Kontakte erzeugen).
  if (error is FremdeIdentitaet) return SignalFailure.unreadable;
  if (error is! LibSignalException) return SignalFailure.unreadable;
  switch (error.code) {
    case LibSignalErrorCode.duplicatedMessage:
      return SignalFailure.duplicate;
    case LibSignalErrorCode.sessionNotFound:
      return SignalFailure.noSession;
    case LibSignalErrorCode.untrustedIdentity:
      return SignalFailure.untrusted;
    case LibSignalErrorCode.invalidKeyIdentifier:
      return SignalFailure.missingKey;
    default:
      return SignalFailure.unreadable;
  }
}

extension SignalFailureBehaviour on SignalFailure {
  /// Ob die Nachricht verworfen werden darf, ohne den Nutzer zu behelligen.
  bool get isSilent => this == SignalFailure.duplicate;

  /// Ob ein Neuaufbau der Sitzung die richtige Reaktion ist.
  ///
  /// Nur bei [noSession]. Bei einer unlesbaren oder gefaelschten Nachricht
  /// ausdruecklich NICHT — sonst koennte ein Angreifer durch Muellnachrichten
  /// Sitzungen zuruecksetzen lassen und damit Forward Secrecy untergraben.
  bool get shouldRebuildSession => this == SignalFailure.noSession;

  /// Ob der Nutzer es sehen muss.
  bool get needsUserAttention => this == SignalFailure.untrusted;
}

/// Eine Erstnachricht kam ein zweites Mal — erkannt am Kyber-Tripel.
///
/// libsignal hat sie entschluesselt, bevor der Speicher die Wiederholung
/// bemerken konnte (signal_store.dart, Abschnitt KyberPreKeyStore). Der
/// Empfangspfad wirft das, damit der Klartext nie verarbeitet wird; [classify]
/// behandelt es wie ein Duplikat.
class ErneutEingespielt implements Exception {
  const ErneutEingespielt();
  @override
  String toString() => 'ErneutEingespielt: Erstnachricht wiederholt';
}

/// Ein Schluessel passt nicht zu der Adresse, fuer die er gelten soll.
///
/// DER RIEGEL VOR LIBSIGNAL. Die offizielle Anbindung (libsignal 8.0.0) ruft
/// `isTrustedIdentity` nie auf und legt beim Sitzungsaufbau die Sitzung ab,
/// BEVOR `saveIdentity` laeuft (Befund vom 16.10.2026, nachgewiesen in
/// test/crypto/signal_bibliothek_test.dart). BitDMs wichtigste Eigenschaft —
/// "die Adresse IST der Schluessel, kein Server kann einen anderen
/// unterschieben" — haengt deshalb an Pruefungen VOR dem Aufruf:
/// prekey_bundle_bridge `fromRelay` fuer Buendel und real_messenger_core
/// `_nimmUmschlagJetzt` fuer Erstnachrichten. Beide werfen das hier.
class FremdeIdentitaet implements Exception {
  final String adresse;
  const FremdeIdentitaet(this.adresse);
  @override
  String toString() =>
      'FremdeIdentitaet: Schluessel passt nicht zur Adresse $adresse';
}
