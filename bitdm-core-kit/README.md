# BitDM — Core Starter Kit (for Person B)

The **handoff surface** between the UI (Person A) and the crypto/backend (you).
Everything you need to start `RealMessengerCore` is here: the frozen interface,
data models, error types, a working fake (behaviour reference), the project
structure, the decisions, and the exact UI lifecycle contract.

## What you build
`app/lib/core/real_messenger_core.dart` — a class
`RealMessengerCore implements MessengerCore` backed by:
- **libsignal** (X3DH session setup + Double Ratchet),
- a **WebSocket client** to the relay (+ REST for prekey bundles),
- **encrypted local storage** (Android Keystore + message DB).

Everything the UI needs is defined in `lib/core/messenger_core.dart`. Nothing
else in the UI calls into your code.

## Where the files go (into the existing Flutter app `app/`)
| file in this ZIP                     | copy to            | owner |
|--------------------------------------|--------------------|-------|
| `lib/core/messenger_core.dart`       | `app/lib/core/`    | [AB] frozen |
| `lib/core/models.dart`               | `app/lib/core/`    | [AB] frozen |
| `lib/core/errors.dart`               | `app/lib/core/`    | [AB] frozen |
| `lib/core/fake_messenger_core.dart`  | `app/lib/core/`    | [AB] reference |
| `lib/core/real_messenger_core.dart`  | `app/lib/core/`    | **[B] you create** |

Full ownership map in `tree.txt`.

## Toolchain / build
- **Flutter 3.44.8** (stable), **Dart 3.12.2**
- Target: **Android** (min/target SDK from Flutter defaults; INTERNET permission already set)
- From `app/`:
  - `flutter pub get`
  - run on a device/emulator: `flutter run`
  - build the APK: `flutter build apk --release`
  - static check: `flutter analyze`  ← the kit files pass with **0 issues**

The interface, models, errors and fake are **pure Dart** (no Flutter import),
so you can unit-test `RealMessengerCore` against them with `dart test`, no device.

## Read these next
1. `DECISIONS.md`   — what's locked, what's OPEN for you.
2. `UI_CONTRACT.md` — call order, streams, safety-number format, threading.
3. `NOTES.md`       — assumptions A made + open questions for you.
4. `reference/`     — the existing Python relay/key-server draft + crypto POC (yours to own).
