// signal_errors.dart — eine Fassade fuer libsignals Fehlerbehandlung.
//
// Zwei Eigenheiten der Bibliothek machen diese Datei noetig. Beide sind
// nachgeprueft, nicht vermutet.
//
// ERSTENS: vier Ausnahmen sind nicht aus der Paketwurzel erreichbar.
//   lib/libsignal_protocol_dart.dart exportiert 52 Dateien, aber weder
//   invalid_message_exception.dart noch invalid_mac_exception.dart, und von
//   fingerprint/ nur die vier nuetzlichen Klassen ohne deren beide Ausnahmen.
//   Ohne Implementierungsimport liesse sich also nicht einmal unterscheiden,
//   ob eine Nachricht kaputt ist oder ihre Signatur nicht stimmt.
//
// ZWEITENS: libsignal wirft an drei Stellen AssertionError, nicht Exception.
//   state/pre_key_record.dart:32, ratchet/ratcheting_session.dart:83 und :115
//   verpacken interne Fehler als `throw AssertionError(e)`. AssertionError
//   erbt von Error, NICHT von Exception. Ein Empfangspfad mit `on Exception`
//   wuerde daran vorbeigreifen und die App abstuerzen lassen — bei einer
//   Nachricht, die ein Angreifer frei formen kann.
//   Deshalb faengt der Empfangspfad IMMER `catch (e)`, nie `on Exception`.
//   Dasselbe gilt fuer InvalidProtocolBufferException aus dem protobuf-Paket:
//   protocol/pre_key_signal_message.dart faengt nur InvalidKeyException und
//   LegacyMessageException ab und laesst den Rest durch.

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
// ignore: implementation_imports
import 'package:libsignal_protocol_dart/src/invalid_mac_exception.dart';
// ignore: implementation_imports
import 'package:libsignal_protocol_dart/src/invalid_message_exception.dart';

export 'package:libsignal_protocol_dart/src/invalid_mac_exception.dart';
export 'package:libsignal_protocol_dart/src/invalid_message_exception.dart';

/// Wie mit einem Fehlschlag beim Entschluesseln umzugehen ist.
///
/// Die Einteilung richtet sich danach, was der Client TUN muss — nicht danach,
/// welche Klasse geflogen ist.
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

  /// Die Nachricht ist echt adressiert, aber ihre Pruefsumme stimmt nicht.
  ///
  /// BEWUSST von [noSession] getrennt, obwohl beides "kann nicht
  /// entschluesseln" bedeutet. Der Unterschied entscheidet ueber die Reaktion:
  /// bei noSession ist ein Neuaufbau richtig, hier waere er falsch. Ein
  /// kaputter MAC heisst, dass jemand die Nachricht veraendert hat oder der
  /// Ratchet-Zustand auseinanderlaeuft — automatisch neu aufzubauen wuerde
  /// einem Angreifer erlauben, durch Muellnachrichten Sitzungen zuruecksetzen
  /// zu lassen.
  badMac,

  /// Der Identitaetsschluessel der Gegenstelle weicht vom gespeicherten ab.
  ///
  /// Bei BitDM ein Widerspruch in sich, weil die Adresse der Schluessel IST.
  /// Tritt es auf, stimmt etwas Grundlegendes nicht — nie automatisch annehmen.
  untrusted,

  /// Ein referenzierter Prekey liegt nicht mehr vor.
  ///
  /// Normal bei doppelt zugestellten Erstnachrichten: der Prekey wurde beim
  /// ersten Mal verbraucht.
  missingKey,

  /// Die Bytes ergeben keine gueltige Nachricht.
  ///
  /// Verwerfen und protokollieren. Alles, was vom Server kommt, kann so
  /// aussehen — das ist kein Ausnahmefall, sondern zu erwarten.
  unreadable,

  /// Unerwartet. Verwerfen, protokollieren, Sitzung NICHT anfassen.
  fatal,
}

/// Ordnet einen beliebigen geworfenen Wert einer Behandlung zu.
///
/// Nimmt bewusst `Object` und nicht `Exception`: siehe Kopfkommentar.
SignalFailure classify(Object error) {
  if (error is DuplicateMessageException) return SignalFailure.duplicate;
  if (error is NoSessionException) return SignalFailure.noSession;
  if (error is InvalidMacException) return SignalFailure.badMac;
  if (error is UntrustedIdentityException) return SignalFailure.untrusted;
  if (error is InvalidKeyIdException) return SignalFailure.missingKey;
  if (error is InvalidMessageException) return SignalFailure.unreadable;
  if (error is InvalidKeyException) return SignalFailure.unreadable;
  if (error is LegacyMessageException) return SignalFailure.unreadable;

  // AssertionError kommt aus libsignals Innerem (pre_key_record.dart:32,
  // ratcheting_session.dart:83/115). Sie erbt von Error, wird also von
  // `on Exception` nicht erfasst — hier landet sie trotzdem, weil classify
  // Object nimmt.
  if (error is AssertionError) return SignalFailure.unreadable;

  // Alles Uebrige, u. a. InvalidProtocolBufferException aus dem
  // protobuf-Paket, das pre_key_signal_message.dart durchreicht.
  return SignalFailure.unreadable;
}

extension SignalFailureBehaviour on SignalFailure {
  /// Ob die Nachricht verworfen werden darf, ohne den Nutzer zu behelligen.
  bool get isSilent => this == SignalFailure.duplicate;

  /// Ob ein Neuaufbau der Sitzung die richtige Reaktion ist.
  ///
  /// Nur bei [noSession]. Bei [badMac] ausdruecklich NICHT — sonst koennte
  /// ein Angreifer durch gefaelschte Nachrichten Sitzungen zuruecksetzen
  /// lassen und damit Forward Secrecy untergraben.
  bool get shouldRebuildSession => this == SignalFailure.noSession;

  /// Ob der Nutzer es sehen muss.
  bool get needsUserAttention => this == SignalFailure.untrusted;
}
