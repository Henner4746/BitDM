// models.dart — shared data models + enums for the BitDM messenger core.
//
// PURE DART (no Flutter imports) so it runs in unit tests and background
// isolates. FROZEN v1 contract: change only by agreement between
// Person A (UI) and Person B (core).

/// Delivery lifecycle of a single message.
enum MessageStatus {
  sending, // created locally, not yet handed to the network
  sent, // accepted by the relay server
  delivered, // delivered to the recipient device
  read, // recipient opened the chat (only if read receipts are on)
  failed, // permanently failed (encryption / network / no session)
}

/// v1 supports text only. Reserved for voice/image/file later.
enum MessageKind { text }

/// State of the link to the relay/key server.
enum ConnectionState { disconnected, connecting, online, error }

/// Where a contact sits in the request/accept handshake.
enum ContactState {
  outgoingPending, // we sent a request, waiting for them
  incomingPending, // they sent us a request, waiting for our accept
  active, // both sides confirmed; messaging allowed
}

/// Kinds of asynchronous contact events pushed to the UI.
enum ContactEventType { incomingRequest, requestAccepted, requestDeclined, removed }

class Message {
  final String id; // client-generated, stable, unique (e.g. UUID v4)
  final String chatId; // conversation id == the peer contact's address
  final String senderId; // author's address (== myId when isMine)
  final String text; // plaintext (already decrypted); '' for non-text kinds
  final MessageKind kind;
  final bool isMine;
  final DateTime timestamp; // UTC, authored time
  final MessageStatus status;

  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.text,
    required this.isMine,
    required this.timestamp,
    this.kind = MessageKind.text,
    this.status = MessageStatus.sent,
  });

  Message copyWith({MessageStatus? status, String? text}) => Message(
        id: id,
        chatId: chatId,
        senderId: senderId,
        text: text ?? this.text,
        kind: kind,
        isMine: isMine,
        timestamp: timestamp,
        status: status ?? this.status,
      );
}

class Contact {
  final String id; // address (derived from the peer identity public key)
  final String? displayName; // local-only nickname; the network never sees names
  final DateTime addedAt;
  final ContactState state;
  final bool verified; // true once the user compared the SafetyNumber

  const Contact({
    required this.id,
    required this.addedAt,
    this.displayName,
    this.state = ContactState.active,
    this.verified = false,
  });

  Contact copyWith({String? displayName, ContactState? state, bool? verified}) => Contact(
        id: id,
        addedAt: addedAt,
        displayName: displayName ?? this.displayName,
        state: state ?? this.state,
        verified: verified ?? this.verified,
      );
}

/// Pushed on `MessengerCore.messageStatusUpdates` when a sent message changes.
class MessageStatusUpdate {
  final String messageId;
  final String chatId;
  final MessageStatus status;
  final DateTime at;
  const MessageStatusUpdate({
    required this.messageId,
    required this.chatId,
    required this.status,
    required this.at,
  });
}

/// Pushed on `MessengerCore.contactEvents`.
class ContactEvent {
  final ContactEventType type;
  final String contactId;
  final DateTime at;
  const ContactEvent({required this.type, required this.contactId, required this.at});
}

/// Out-of-band verification material for a conversation (Signal-style).
class SafetyNumber {
  final String contactId;

  /// 60 decimal digits as one string. Display grouped (see [groups]).
  final String digits;

  /// Opaque payload the UI renders as a QR for scanning the peer in person.
  final String qrPayload;

  const SafetyNumber({required this.contactId, required this.digits, required this.qrPayload});

  /// [digits] split into 12 groups of 5 for display.
  List<String> get groups {
    final out = <String>[];
    for (var i = 0; i < digits.length; i += 5) {
      final end = i + 5 > digits.length ? digits.length : i + 5;
      out.add(digits.substring(i, end));
    }
    return out;
  }
}
