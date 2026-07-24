# UI CONTRACT — lifecycle, streams, threading

How the UI uses `MessengerCore`, so that `RealMessengerCore` behaves the way the
UI expects. The UI touches **nothing else** in `lib/core/`.

> Lives here since 2026-07-25. The copy in `bitdm-core-kit/` is the original
> handoff version and is out of date — see PLAN.md §6.

## 1. Startup / call order

> **Changed 2026-07-25.** `initialize()` no longer creates an identity, and it
> returns `bool` instead of the address. Recovery phrases made the old behaviour
> wrong: the user must first choose between a new identity and restoring one.
> Creating something silently would leave a user who wanted to restore already
> holding a *different* identity. See PLAN.md §2.

```dart
final MessengerCore core = RealMessengerCore(); // or FakeMessengerCore()

// a) open storage and load an identity IF one exists — creates nothing
final hasIdentity = await core.initialize();

if (!hasIdentity) {
  // ---- onboarding: the user picks one of the two ----

  // (1) new identity — show the 12 words, make them write them down
  final phrase = await core.createIdentity();

  // (2) or restore — validate live, then hand the words over
  //     if (core.isValidRecoveryPhrase(words)) await core.restoreIdentity(words);
}

// b) SUBSCRIBE before connecting (streams are broadcast, no replay on listen)
core.incomingMessages.listen(_onIncoming);
core.messageStatusUpdates.listen(_onStatus);
core.connectionStateChanges.listen(_onConn);
core.contactEvents.listen(_onContactEvent);

// c) open the server link (never throws on network failure)
await core.connect();
```

Read the link state synchronously any time via `core.connectionState`, and the
own address via `core.myId` (throws before an identity exists).

### Recovery phrase — what the UI must convey
- **12 words**, shown **once** on creation. There is no copy anywhere else: no
  server, no backup, no reset link. Losing them loses the identity for good.
- Settings offers "show my recovery phrase" via `getRecoveryPhrase()` — put
  device authentication in front of it.
- Restoring brings back the identity, and with it the ability to be reached. It
  does **not** bring back message history, and it does not bring back running
  sessions — those rebuild themselves on the next message.
- Restoring on a second device supersedes the first ("last restore wins").
- Never log or screenshot the phrase. It *is* the account.

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
- Addresses are **56 characters**, displayed in **14 groups of 4**.

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
- Heavy crypto MAY be offloaded to background isolates internally, but the public
  surface stays main-isolate and non-blocking (it is all async already).
- All streams are **broadcast** (multiple listeners; past events are not replayed
  to late listeners).

## Quick reference — who returns what
| method                             | returns                       |
|------------------------------------|-------------------------------|
| `initialize()`                     | `Future<bool>` (identity exists?) |
| `hasIdentity` / `isInitialized`    | `bool` (sync)                 |
| `createIdentity()`                 | `Future<List<String>>` (12 words) |
| `restoreIdentity(words)`           | `Future<String>` (myId)       |
| `isValidRecoveryPhrase(words)`     | `bool` (sync, offline)        |
| `getRecoveryPhrase()`              | `Future<List<String>>`        |
| `myId`                             | `String` (sync)               |
| `isValidAddress(a)`                | `bool` (sync, offline)        |
| `connect()` / `disconnect()`       | `Future<void>`                |
| `connectionState`                  | `ConnectionState` (sync)      |
| `connectionStateChanges`           | `Stream<ConnectionState>`     |
| `getContacts()`                    | `Future<List<Contact>>`       |
| `addContact(a,{displayName})`      | `Future<Contact>`             |
| `acceptRequest/declineRequest/removeContact` | `Future<void>`      |
| `contactEvents`                    | `Stream<ContactEvent>`        |
| `getMessages(id,{limit,before})`   | `Future<List<Message>>`       |
| `sendMessage(id,text)`             | `Future<Message>`             |
| `incomingMessages`                 | `Stream<Message>`             |
| `messageStatusUpdates`             | `Stream<MessageStatusUpdate>` |
| `markRead(id)`                     | `Future<void>`                |
| `getSafetyNumber(id)`              | `Future<SafetyNumber>`        |
| `setVerified(id,bool)`             | `Future<void>`                |
| `dispose()`                        | `Future<void>`                |
