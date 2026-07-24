// messenger_core.dart
// =====================================================================
//  THE CONTRACT between Person A (UI) and Person B (crypto/backend).
//  FROZEN v1 — change only by mutual agreement.
//
//  * Person A builds the UI against THIS interface + FakeMessengerCore.
//  * Person B implements RealMessengerCore (libsignal + WebSocket + storage).
//  * Neither edits the other's files. This file changes only together.
//
//  Import this one file to get everything (models + errors are re-exported).
// =====================================================================

import 'models.dart';

export 'models.dart';
export 'errors.dart';

/// Max UTF-8 byte length of a single text message.
const int kMaxTextBytes = 4096;

abstract class MessengerCore {
  // ------------------------------------------------------------- identity
  /// First launch: generate an identity (key pair) and open local storage.
  /// Later launches: load the existing identity. Idempotent.
  /// Returns the own [myId] address.
  /// Throws `StorageException`, `CryptoException`.
  Future<String> initialize();

  /// True after [initialize] has completed.
  bool get isInitialized;

  /// The own address ("long number") to share so others can add you.
  /// Throws `NotInitializedException` if read before [initialize] completes.
  String get myId;

  /// Cheap, OFFLINE format + checksum check of a peer address (no network).
  /// The UI calls this to validate the paste field before [addContact].
  bool isValidAddress(String address);

  // ----------------------------------------------------------- connection
  /// Open and authenticate the link to the relay/key server.
  /// Does NOT throw on network failure — progress/failure is reported via
  /// [connectionStateChanges] / [connectionState]. Throws only
  /// `NotInitializedException`.
  Future<void> connect();

  /// Close the server link. Safe to call when already disconnected.
  Future<void> disconnect();

  /// Current link state (synchronous snapshot).
  ConnectionState get connectionState;

  /// Broadcast stream of link-state transitions. Does NOT replay the current
  /// value on listen — read [connectionState] once, then listen.
  Stream<ConnectionState> get connectionStateChanges;

  // ------------------------------------------------------------- contacts
  /// All active + pending contacts, newest first.
  Future<List<Contact>> getContacts();

  /// Add a peer by address and send a contact request.
  /// Returns the new contact in `ContactState.outgoingPending`.
  /// Throws `InvalidAddressException`, `NotInitializedException`.
  Future<Contact> addContact(String address, {String? displayName});

  /// Accept an incoming request (contact in `ContactState.incomingPending`).
  /// Throws `UnknownContactException`.
  Future<void> acceptRequest(String contactId);

  /// Decline/ignore an incoming request.
  Future<void> declineRequest(String contactId);

  /// Remove a contact locally and tear down the session. Unilateral, no confirm.
  Future<void> removeContact(String contactId);

  /// Broadcast stream of contact-side events (incoming request, request
  /// accepted by peer, declined, removed). See [ContactEvent].
  Stream<ContactEvent> get contactEvents;

  // ------------------------------------------------------------- messages
  /// Local history for a conversation, oldest → newest.
  /// Throws `UnknownContactException`.
  Future<List<Message>> getMessages(String contactId, {int limit = 50, DateTime? before});

  /// Encrypt + send a text message. Returns immediately with the stored
  /// [Message] in `MessageStatus.sending`; later transitions arrive on
  /// [messageStatusUpdates]. Encryption/session setup happen internally.
  /// Throws `UnknownContactException`, `MessageTooLargeException`,
  /// `NotInitializedException`.
  Future<Message> sendMessage(String contactId, String text);

  /// Broadcast stream of newly received, already-DECRYPTED inbound messages.
  /// The core also persists them; this is the live push for the UI.
  Stream<Message> get incomingMessages;

  /// Broadcast stream of status changes for messages I sent
  /// (sending → sent → delivered → read, or → failed).
  Stream<MessageStatusUpdate> get messageStatusUpdates;

  /// Tell the core the user has opened/viewed [contactId]'s messages, so it can
  /// send a read receipt to the peer (if read receipts are enabled). No-op
  /// otherwise. Throws `UnknownContactException`.
  Future<void> markRead(String contactId);

  // --------------------------------------------------------- verification
  /// The out-of-band verification number for a contact (Signal-style).
  /// Throws `UnknownContactException`.
  Future<SafetyNumber> getSafetyNumber(String contactId);

  /// Mark a contact verified (or not) after the user compared numbers.
  Future<void> setVerified(String contactId, bool verified);

  // ------------------------------------------------------------ lifecycle
  /// Release all resources and CLOSE every stream above. The instance is
  /// unusable afterwards. Call on app shutdown.
  Future<void> dispose();
}
