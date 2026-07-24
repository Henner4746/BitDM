# UI CONTRACT — lifecycle, streams, threading

The UI (Person A) uses ONLY `MessengerCore`. Here is exactly how, so your
`RealMessengerCore` behaves the way the UI expects.

## 1. Startup / call order
```dart
final MessengerCore core = RealMessengerCore(); // or FakeMessengerCore()

// a) create/load identity + open storage
final myId = await core.initialize();

// b) SUBSCRIBE before connecting (streams are broadcast, no replay on listen)
core.incomingMessages.listen(_onIncoming);
core.messageStatusUpdates.listen(_onStatus);
core.connectionStateChanges.listen(_onConn);
core.contactEvents.listen(_onContactEvent);

// c) open the server link (never throws on network failure)
await core.connect();
```
Read the current link state synchronously any time via `core.connectionState`.

## 2. Sending a message
```dart
final msg = await core.sendMessage(contactId, text); // returns status == sending
_appendToChat(msg);
// later, _onStatus fires: sent -> delivered -> read   (or -> failed)
```

## 3. Receiving
- `incomingMessages` pushes already-DECRYPTED `Message`s. Append to the open
  chat; badge if the chat isn't on screen. The core also persisted it, so
  `getMessages()` returns it after an app restart.

## 4. Connection indicator
- `connectionStateChanges` → map `ConnectionState`
  (`connecting` / `online` / `disconnected` / `error`) to the status icon.

## 5. Contacts / requests
- Add: `await core.addContact(address)` → contact is `outgoingPending`.
  Peer acceptance later arrives as `ContactEvent(requestAccepted)`.
- Incoming request arrives as `ContactEvent(incomingRequest)` → UI shows the
  pending card → `acceptRequest(id)` / `declineRequest(id)`.
- Validate the paste field with `core.isValidAddress(text)` before enabling "Add".

## 6. Read receipts
- When the user opens a chat, the UI calls `await core.markRead(contactId)`.
- The read status of MY sent messages comes back via `messageStatusUpdates`
  (`MessageStatus.read`).

## 7. Verification (Safety Number)
- UI opens the verify screen → `final sn = await core.getSafetyNumber(contactId)`.
- Display `sn.groups` (**12 groups of 5 digits**) and render `sn.qrPayload` as a QR.
- After the user compares in person → `await core.setVerified(contactId, true)`.
  `Contact.verified` reflects the result.

## 8. Shutdown
- `await core.dispose()` — closes every stream; the instance is unusable after.

## Threading / isolates
- The core runs on the **main isolate**. All `Future`s complete and all `Stream`
  events are delivered on the **main isolate** — the UI updates state directly in
  listeners, no marshalling needed.
- You MAY offload heavy crypto to background isolates internally, but keep the
  public surface main-isolate and non-blocking (it's all async already).
- All streams are **broadcast** (multiple listeners allowed; past events are not
  replayed to late listeners).

## Quick reference — who returns what
| method                          | returns                     |
|---------------------------------|-----------------------------|
| `initialize()`                  | `Future<String>` (myId)     |
| `myId`                          | `String` (sync)             |
| `isValidAddress(a)`             | `bool` (sync, offline)      |
| `connect()` / `disconnect()`    | `Future<void>`              |
| `connectionState`               | `ConnectionState` (sync)    |
| `connectionStateChanges`        | `Stream<ConnectionState>`   |
| `getContacts()`                 | `Future<List<Contact>>`     |
| `addContact(a,{displayName})`   | `Future<Contact>`           |
| `acceptRequest/declineRequest/removeContact` | `Future<void>`  |
| `contactEvents`                 | `Stream<ContactEvent>`      |
| `getMessages(id,{limit,before})`| `Future<List<Message>>`     |
| `sendMessage(id,text)`          | `Future<Message>`           |
| `incomingMessages`              | `Stream<Message>`           |
| `messageStatusUpdates`          | `Stream<MessageStatusUpdate>` |
| `markRead(id)`                  | `Future<void>`              |
| `getSafetyNumber(id)`           | `Future<SafetyNumber>`      |
| `setVerified(id,bool)`          | `Future<void>`              |
| `dispose()`                     | `Future<void>`              |
