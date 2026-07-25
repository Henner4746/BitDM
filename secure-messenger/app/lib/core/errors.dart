// errors.dart — exception hierarchy the MessengerCore contract throws.
//
// RULE: methods throw only for programmer/usage errors and bad input.
// Transient network/connection problems are NOT thrown — they surface on
// `MessengerCore.connectionStateChanges` and as `MessageStatus.failed`.

class MessengerException implements Exception {
  final String message;
  final Object? cause;
  const MessengerException(this.message, [this.cause]);
  @override
  String toString() => '$runtimeType: $message${cause == null ? '' : ' ($cause)'}';
}

/// A method needing an identity was called before `initialize()` completed.
class NotInitializedException extends MessengerException {
  const NotInitializedException([super.message = 'call initialize() first']);
}

/// The given address is malformed or fails its checksum. Thrown by
/// `addContact()`. Use `isValidAddress()` to pre-check in the UI.
class InvalidAddressException extends MessengerException {
  final String address;
  const InvalidAddressException(this.address) : super('invalid address: $address');
}

/// The given recovery phrase is not a valid BIP39 phrase — unknown word,
/// wrong word count, or failed checksum. Thrown by `restoreIdentity()`.
/// Use `isValidRecoveryPhrase()` to pre-check in the UI.
///
/// Deliberately carries NO copy of the phrase: an exception message tends to
/// end up in logs and crash reports, and this one would be the user's identity.
class InvalidRecoveryPhraseException extends MessengerException {
  const InvalidRecoveryPhraseException(
      [super.message = 'invalid recovery phrase']);
}

/// Referenced a contact/chat id that is not a known contact.
class UnknownContactException extends MessengerException {
  final String contactId;
  const UnknownContactException(this.contactId) : super('unknown contact: $contactId');
}

/// Message text exceeds `kMaxTextBytes` (UTF-8).
class MessageTooLargeException extends MessengerException {
  final int bytes;
  final int maxBytes;
  const MessageTooLargeException(this.bytes, this.maxBytes)
      : super('message too large: $bytes > $maxBytes bytes');
}

/// Local encrypted storage failed (open/read/write).
class StorageException extends MessengerException {
  const StorageException(super.message, [super.cause]);
}

/// Cryptographic failure (key setup, session). A single message that fails to
/// decrypt should surface as `MessageStatus.failed`, NOT throw.
class CryptoException extends MessengerException {
  const CryptoException(super.message, [super.cause]);
}

/// Der Nutzer hat "nur in der Naehe" eingeschaltet, und diese Sache braucht
/// einen Server.
///
/// EIGENE AUSNAHME und kein RelayException: die Oberflaeche muss darauf etwas
/// anderes sagen. "Keine Verbindung — versuch es noch einmal" waere hier
/// falsch; es liegt nicht am Netz, sondern an einer Entscheidung, die der
/// Nutzer selbst getroffen hat und selbst zuruecknehmen kann.
class NurNahbereichException extends MessengerException {
  const NurNahbereichException()
      : super('nur in der Naehe: dafuer braeuchte es einen Server');
}
