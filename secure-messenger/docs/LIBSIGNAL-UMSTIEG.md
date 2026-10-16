# Umstieg auf Signals offizielle libsignal

Stand 16.10.2026, Zweig `feat/libsignal-offiziell` (aufgesetzt auf `fix/audit-2026-10-16`).

## Entscheidung

BitDM ersetzt `libsignal_protocol_dart` 0.8.2, die Dart-Nachbildung von Mixin, durch Signals offizielle Rust-Bibliothek. Eingebunden wird sie über das Dart-Paket `libsignal` 8.0.0 (flutter_rust_bridge, AGPL-3.0, Quelle https://github.com/djx-y-z/libsignal_dart). Das Paket bindet libsignal 0.105.0 ein.

Gründe:
- Das Audit vom 16.10.2026 fand zwei hohe Befunde in der Zustandsverwaltung der Nachbildung (LS-1, LS-2), dazu LS-3: kein Post-Quanten-Schutz.
- F-Droid hat BitDM unter anderem wegen dieser Bibliothek abgelehnt.

**Keine Wahlmöglichkeit für Nutzer, kein Rückweg.** Zwei Bibliotheken nebeneinander öffneten einen Downgrade-Angriff über den Relay und spalteten das Netz. Die neue Fassung kann nur noch die offizielle Bibliothek.

## Machbarkeit (Versuch vom 16.10.2026)

Versuch: `BitDM-audit-arbeit/werkzeuge/libsignal_spike/bin/spike.dart`, reines Dart mit den geprüften Binärdateien des Pakets für Windows x64.

| Frage | Ergebnis |
|---|---|
| Gleiche Adresse aus denselben 12 Wörtern? | **ja**, 20 von 20 Seeds byte-gleich. `PrivateKey.deserialize(geklammerter Schlüssel)` → `getPublicKey().serialize()` = `0x05 ‖ 32 Byte`, dieselben 32 Byte wie heute. |
| Prüft der Relay die neuen Signaturen? | **ja**, `relay_server.verify_signature` nimmt 40 von 40 an, davon 20 mit gesetztem Vorzeichenbit, und lehnt eine Signatur über eine falsche Nachricht ab. Die Anmeldung braucht keine Server-Änderung. |
| PQXDH-Sitzung | **läuft.** Erste Nachricht Typ 3 (1 758 Byte statt bisher rund 200), Antwort Typ 2. Das sind dieselben Typnummern wie in BitDMs Umschlag. Replay wird abgewiesen, `SessionRecord` übersteht Speichern und Einlesen. |
| Ohne Kyber? | **unmöglich**: `PreKeyBundle` verlangt die Kyber-Felder. Eine falsche Kyber-Signatur führt zu `invalidSignature`. Ein Zurückstufen ist damit ausgeschlossen. |

## Was sich ändert

### App (`secure-messenger/app`)
- **Abhängigkeit:** `libsignal: 8.0.0` fest gepinnt. `libsignal_protocol_dart` und die gepatchte Kopie in `third_party/` fliegen raus. `LibSignal.init()` beim Start und in den Test-Vorbauten.
- **Betroffene Dateien (9):** `crypto/signal_identity.dart`, `crypto/signal_errors.dart`, `net/envelope.dart`, `net/prekey_bundle_bridge.dart`, `net/relay_protocol.dart`, `net/relay_client.dart`, `store/signal_store.dart`, `store/signal_store_repository.dart`, `real_messenger_core.dart`. Dazu 16 Testdateien.
- **Speicher:**
  - Ein neuer Kyber-Prekey-Speicher. Je Schlüssel wird gemerkt, ob es ein Einmal- oder ein Last-Resort-Schlüssel ist.
  - Einmal-Schlüssel werden bei `markKyberPreKeyUsed` verbraucht und danach nicht mehr ausgegeben.
  - Für den Last-Resort-Schlüssel wird das Tripel `(kyberPreKeyId, signedPreKeyId, baseKey)` gespeichert. Ein wiederholtes Tripel heißt: Diese Prekey-Nachricht kam schon einmal. Sie wird nach dem Entschlüsseln verworfen. Das ist der Schutz, den LS-1 in der Nachbildung vermisste.
  - Alle Schreibvorgänge sind dauerhaft, bevor der Klartext verarbeitet wird.
- **Prekeys:**
  - Ein signierter EC-Prekey und ein signierter Last-Resort-Kyber-Prekey, beide **mit Erneuerung** (behebt LS-4).
  - Dazu ein Vorrat an Einmal-EC-Prekeys und Einmal-Kyber-Prekeys.
- **Umschlag:** Das Format bleibt (`[Fassung, Typ, Chiffretext]`). Statt `PreKeySignalMessage`/`SignalMessage` geht künftig `CiphertextMessage(type, ciphertext)` an `SessionCipher.decrypt`.

### Bestandsdaten (einmalig beim ersten Start der neuen Fassung)
- Identität und Adresse bleiben, Chats, Kontakte und Anhänge auch.
- Alte Sitzungen und Prekeys sind in einem anderen Format gespeichert und werden gelöscht. Neue Prekeys einschließlich Kyber werden erzeugt und beim Relay neu angemeldet.
- Mit jedem Kontakt entsteht beim nächsten Senden eine neue PQXDH-Sitzung. Im Chat erscheint ein Hinweis „Verschlüsselung erneuert“.

### Relay (`secure-messenger/server`)
- **Schema:**
  - `identities` bekommt je Gerät `kyber_prekey_id`, `kyber_prekey` und `kyber_prekey_sig` (Last-Resort).
  - Eine neue Tabelle `one_time_kyber_prekeys`, wie `one_time_prekeys`.
- **Endpunkte:**
  - `/register` nimmt die Kyber-Teile an und prüft ihre Signatur mit `verify_signature`.
  - `/prekey/{user_id}` gibt sie aus, je Gerät einen Einmal-Kyber-Schlüssel, sonst den Last-Resort-Schlüssel.
  - Größenprüfung: Ein Kyber-1024-Schlüssel hat 1 569 Byte mit Typbyte.
- **Mindestfassung:** Ab dem Stichtag lehnt der Relay Anmeldungen ohne Kyber ab. Alte Apps sehen den Update-Hinweis (`BITDM_NEUESTE_FASSUNG`).
- **Lager:** Die Bremsen für das Leersaugen von Prekeys gelten für Kyber-Einmalschlüssel genauso.

### Nahbereich (Bluetooth)
- Das Bündel über Funk trägt künftig den Last-Resort-Kyber-Schlüssel und den signierten EC-Prekey, aber **keine Einmalschlüssel mehr**. Damit sind keine Einmalschlüssel mehr gleichzeitig beim Relay und im Funk unterwegs (behebt PR-4).
- Das Bündel wird größer (≈ 2,5 KB). Die Stückelung trägt bis 64 KiB.

### Bau und Plattformen
- **Android, Windows, Linux:** Die Binärdateien lädt der Build-Hook des Pakets und prüft sie per SHA-256.
- **Web:** Das WASM-Modul liegt in `web/pkg/`. Die CSP (`script-src 'self' 'wasm-unsafe-eval'`) erlaubt das bereits. Es geht nur der normale Web-Build, nicht `--wasm`.
- **F-Droid-Verzeichnis und Reproduzierbarkeit:** Die Rust-Bibliothek wird im Workflow aus der Quelle gebaut (Rust-Toolchain und `protoc`). Die Bitgleichheit wird danach neu gemessen.
- **Größe:** Die APK wird je ABI um einige MB größer. Das wird gemessen und notiert.

## Reihenfolge

1. App-Kern auf libsignal umstellen, Speicher mit Kyber-Prekeys, Tests grün.
2. Relay: Schema, `/register`, `/prekey`, Tests grün.
3. Migration der Bestandsdaten mit Test (alte Datenbank → neue Fassung, Chats bleiben).
4. Nahbereich-Bündel, PR-4.
5. Bau: Web (`web/pkg`), CI aus der Quelle, Reproduzierbarkeit, Größen.
6. Durchstich: zwei Emulatoren, Relay lokal, Web im Browser, Windows.
7. Veröffentlichung, **nur mit Henriks Ja**: zuerst der Relay (versteht beides), dann die App als 2.0.0, dann der Stichtag.

## Risiken
- **Die Anbindung hat einen einzigen Betreuer.** Deshalb gilt die feste Fassung, der Bau aus der Quelle für Veröffentlichungen und eine einmalige Durchsicht des dünnen Anbindungscodes (`rust/src/api`).
- **Der Ablauf lässt sich nicht gegen Wiederholung absichern:** Laut Paket kann `markKyberPreKeyUsed` die Entschlüsselung nicht abbrechen. BitDM muss das Ergebnis danach prüfen und die Nachricht verwerfen. Dafür kommt ein Test aus dem LS-1-Nachweis.
- **Web:** Ein Panic in einem asynchronen Aufruf kehrt laut Paket nie zurück. Die Aufrufe brauchen daher eine Frist.
