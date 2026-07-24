> ## ⚠️ Historischer Übergabestand — überholt seit 2026-07-25
>
> Dieses Verzeichnis ist das Starter-Kit, mit dem Person A (Lennard) die Arbeit
> übergeben hat. Es bleibt als Beleg des Ausgangszustands erhalten, ist aber
> **nicht mehr maßgeblich**. Alle offenen Punkte sind inzwischen entschieden.
>
> **Maßgeblich ist [`../PLAN.md`](../PLAN.md).**
>
> Wichtigste Abweichungen:
> - **„No recovery"** unten ist **ersetzt** durch eine BIP39-Seed-Phrase (12 Wörter).
> - **Adressformat** ist entschieden: Base32, exakt 56 Zeichen, Anzeige 14×4.
> - **Auth** nutzt XEdDSA, nicht Ed25519 — libsignal-Schlüssel sind Curve25519.
> - **Lesebestätigungen / verschwindende Nachrichten** kommen in den Core, aber erst v1.1.
> - Das Interface ist **nicht mehr eingefroren** (Person A ist raus).

# DECISIONS (v1)

Locked unless renegotiated together. **OPEN** = your call, Person B.

## Scope
- **Devices:** SINGLE device per identity for v1. Keys live on one device; no
  multi-device sync / linked devices. (Multi-device later — touches the session
  model, barely touches the UI interface.)
- **Conversations:** **1:1 only** for v1. No groups. (Group ratchet later.)
- **Message types:** text only. `MessageKind` reserves room for voice/image/file.

## Identity & addressing
- **Public-key-only.** No phone number, no username, no account, no recovery.
- The address ("long number") is **deterministically derived from the identity
  public key** and carries a **checksum** so typos are caught offline.
- **OPEN — you define the canonical encoding + length.** The UI treats the
  address as an opaque `String`: it displays it (grouped) and validates it via
  `MessengerCore.isValidAddress()`. Just tell A the group size for display.
  - The Python POC (`reference/crypto/crypto_core.py`) uses
    `base32( pubkey32 || sha256(pubkey)[:2] )` lowercased (~56 chars).
  - The UI design mock shows a 32-char value grouped 8×4 (`B3XK-7QMD-…`).
  - Those **don't match** — pick the canonical one; the UI adapts to yours.

## Crypto
- Target: **Signal Protocol** — **X3DH** for session setup, **Double Ratchet**
  for forward secrecy. Library: `libsignal_protocol_dart` (confirm latest).
- Symmetric layer: **AES-256** / the ratchet's AEAD. (Note: "512-bit" is
  marketing — AES-256 is the real, correct target.)
- Private keys **never leave the device**; store in Android Keystore /
  `flutter_secure_storage`.

## Transport / server
- **Relay + key server** (`reference/server/relay_server.py`, FastAPI + WebSocket):
  stores **prekey bundles** (so you can message offline peers), relays **opaque
  ciphertext**, and queues for offline delivery. It **cannot read messages**.
- Draft auth = **Ed25519 challenge-response**; you may switch to libsignal
  identity-key signing (XEdDSA). **OPEN.**
- **Production: run behind TLS** (`wss://` + `https://`).

## Message envelope
- **OPEN — you define it.** The server is envelope-agnostic; it just moves an
  opaque base64 `ciphertext` between two addresses. Current draft on the wire:
  - client → server: `{ "type":"message", "to":"<addr>", "ciphertext":"<b64>" }`
  - server → client: `{ "type":"message", "from":"<addr>", "ciphertext":"<b64>", "ts":<float> }`
  Everything inside `ciphertext` (ratchet header, message id, kind, timestamp) is yours.

## Error model
- Methods throw ONLY for usage errors / bad input (see `errors.dart`).
- Network/connection problems are **not thrown** — they surface on
  `connectionStateChanges` and as `MessageStatus.failed`.
