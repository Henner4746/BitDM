# Eigener Stand von `libsignal_protocol_dart`

Dieser Ordner ist **keine** Fassung von pub.dev, sondern ein eigener,
gepatchter Stand. Die App bindet ihn über `dependency_overrides` in
`secure-messenger/app/pubspec.yaml` ein.

| | |
|---|---|
| Vorlage | `libsignal_protocol_dart` 0.8.2 von pub.dev (MixinNetwork) |
| Prüfsumme der Vorlage | `3ed4455f09c7299934a6b9ca0028daff87940d446142056e1ec25997de0e41bf` |
| Fassung hier | `0.8.2+bitdm.1` |
| Lizenz | GPL-3.0, wie die Vorlage (`LICENSE` unverändert). Mit der AGPL-3.0 von BitDM vereinbar, GPLv3 §13. |
| Angelegt | 16.10.2026 |

Die Vorlage ist eine **Portierung des Signal-Protokolls nach Dart von
Mixin, nicht Signals eigene, geprüfte libsignal**. Sie hat kein
veröffentlichtes Audit. Diese Korrekturen beheben gefundene Fehler; geprüft
ist die Bibliothek damit nicht. Mittelfristig ist der Wechsel auf Signals
offizielle libsignal (Rust, über FFI) vorgesehen — das löst zugleich den
fehlenden Post-Quanten-Schlüsseltausch.

## Warum ein eigener Stand und kein Upstream-Update

Die Fehler unten stecken in der veröffentlichten 0.8.2, und 0.8.2 ist die
neueste Fassung auf pub.dev. Upstream wird sporadisch gepflegt (zwei
Betreuende, leeres CHANGELOG, kein `SECURITY.md`). Gemeldet werden die Fehler
dort, sobald die Korrekturen ausgeliefert sind; bis dahin hängt die
Vertraulichkeit der App an diesem Ordner.

## Die Änderungen

Fünf Dateien, zusammen etwa 20 Zeilen Code. Jede Stelle trägt im Quelltext
einen Kommentar, der mit `BITDM` beginnt. Jede Änderung hat einen Test in
`secure-messenger/app/test/crypto/signal_bibliothek_test.dart`, und jeder
dieser Tests war gegen die unveränderte 0.8.2 rot.

### 1. `lib/src/protocol/pre_key_signal_message.dart` — Fassung der Erstnachricht prüfen

Das obere Nibble des ersten Bytes ist die Protokollfassung. Es wird von
keinem MAC gedeckt, die Duplikaterkennung in `SessionBuilder.processV3` hängt
aber daran. Ohne Prüfung genügt es, das Byte von `0x33` auf `0x43` zu setzen,
damit die Bibliothek eine bestehende Sitzung nicht wiedererkennt, aus
denselben Eingaben eine zweite Anfangssitzung baut, die laufende dafür
archiviert und die Erstnachricht ein zweites Mal entschlüsselt. Danach kann
die Gegenstelle nichts mehr lesen, was dieses Gerät sendet.

Jetzt wird wie in `SignalMessage.fromSerialized` geprüft: kleiner als die
aktuelle Fassung → `LegacyMessageException`, größer → `InvalidMessageException`.
Die offizielle libsignal lehnt beides beim Parsen ab.

### 2. `lib/src/state/session_state.dart` — tiefe Kopie

`SessionState.fromSessionState` kopierte nur die Hülle; beide Objekte zeigten
auf dasselbe Protobuf-Objekt. `SessionCipher._decrypt` benutzt diese „Kopie“
als Arbeitsfassung für einen Entschlüsselungsversuch, und ein Versuch legt
neuen Wurzelschlüssel, neue Sendekette und übersprungene Nachrichtenschlüssel
an, **bevor** der MAC geprüft ist. Ein Fehlversuch verbog damit den echten
Zustand. Jetzt wird `deepCopy()` benutzt, wie Java und Rust es tun.

### 3. `lib/src/session_cipher.dart` — befördertes Archiv-Element lösen

`previousStates.remove(promotedState)` lief ins Leere: `promotedState` ist ein
neues Objekt und stand nicht in der Liste. Der erfolgreiche archivierte
Zustand blieb deshalb im Archiv stehen, während er zugleich zur aktiven
Sitzung wurde — mit noch unverbrauchten Nachrichtenschlüsseln. Sobald die
aktive Sitzung einen wiederholten alten Umschlag nicht mehr als Duplikat
erkennt (nach fünf Ratchet-Schritten), entschlüsselt ihn dieser Eintrag
erneut, wird wieder zur aktiven Sitzung, und Nachrichtenschlüssel samt IV
werden ein zweites Mal benutzt. Jetzt wird das ursprüngliche Element
festgehalten und nach erfolgreichem Entschlüsseln mit `unlink()` gelöst.

### 4. `lib/src/session_builder.dart` — `processV3` abwarten

`process()` rief `processV3` ohne `await` auf und speicherte die Identität der
Gegenstelle davor. Scheiterte `processV3`, hing niemand an dem Future: Dart
meldete den Fehler zusätzlich als unbehandelt an die Zone, an jedem
`try`/`catch` des Aufrufers vorbei. Dasselbe galt für das Future
`ourSignedPreKey`. Jetzt wird beides sofort abgewartet, und die Identität
wird erst nach erfolgreichem Aufbau gespeichert. Nebeneffekt, gewollt: eine
unbekannte Nummer des signierten Prekeys scheitert, bevor
`archiveCurrentState` die laufende Sitzung beiseitelegt.

### 5. `lib/src/protocol/*.dart` — Fehlerarten beim Parsen

Kaputte Nachrichten ergaben `RangeError` (erbt von `Error`, nicht von
`Exception`), `InvalidProtocolBufferException` und eine nackte `Exception` aus
`ByteUtil.split`, deren Meldung die ganze Eingabe als Hex enthielt. Ein
Aufrufer mit `on InvalidMessageException` greift daran vorbei. Jetzt melden
beide Parser alles als `InvalidMessageException`, mit knappen Meldungen ohne
Inhalt der Nachricht.

### Außerdem: Ordner entschlackt

`pubspec.yaml` trägt `version: 0.8.2+bitdm.1` statt `0.8.2`, damit der eigene
Stand in `pubspec.lock` sichtbar ist und niemand ihn für die
Veröffentlichung von pub.dev hält. Die Entwicklungs-Abhängigkeit
`very_good_analysis` ist entfernt, und `analysis_options.yaml` bindet sie
nicht mehr ein: ein reines Analyse-Paket, das der Bau sonst mitziehen müsste.

## Wie man die Änderungen nachprüft

```bash
# 1. Die Vorlage daneben legen und vergleichen.
#    (Der Pfad ist der Pub-Cache; unter Linux ~/.pub-cache/hosted/pub.dev/)
diff -r "$LOCALAPPDATA/Pub/Cache/hosted/pub.dev/libsignal_protocol_dart-0.8.2" .

# 2. Die Tests zu den Änderungen, aus secure-messenger/app/:
flutter test test/crypto/signal_bibliothek_test.dart

# 3. Die Tests, die die Bibliothek selbst mitbringt, aus diesem Ordner:
dart pub get --offline && dart test
```

Erwartet: der Vergleich zeigt genau die fünf Dateien oben (plus
`pubspec.yaml` und `analysis_options.yaml`), und beide Testläufe sind grün.

## Noch offen in dieser Bibliothek

Gefunden, aber hier **nicht** behoben:

- **Keine Serialisierung.** `SessionCipher.sessionLock` wird nirgends benutzt
  (in Java: `synchronized`). Zwei gleichzeitige Aufrufe für dieselbe
  Gegenstelle rechnen auf demselben Stand. BitDM serialisiert den Empfang je
  Gegenstelle selbst; der Versand ist heute nur zufällig geschützt, weil
  `BitdmSignalStore` innen synchron ist. **Der Speicher darf nicht asynchron
  werden, solange es die Sperre nicht gibt.**
- **`Curve.verifySignature` verändert seine Eingaben** (`ecc/ed25519.dart`:
  `publicKey[31] &= 0x7F`) und lässt zwei Schreibweisen desselben Schlüssels
  zu. Upstream im `master` behoben, aber nicht veröffentlicht. BitDM ist nicht
  betroffen, weil die Adressprüfung die rohen 32 Byte nutzt.
- **Kein PQXDH und kein Post-Quanten-Ratchet.** Nur X3DH, Sitzungsfassung 3.
  Das ist der Stand von vor 2023 und nur durch den Wechsel auf die offizielle
  libsignal zu lösen.
- **Der signierte Prekey wird nicht erneuert.** Das ist Aufgabe der App, nicht
  der Bibliothek.
- **`InMemoryIdentityKeyStore.getIdentity`** wirft bei einer unbekannten
  Adresse (`trustedKeys[address]!`) statt `null` zu liefern. Betrifft nur die
  mitgelieferten Testspeicher; BitDM hat einen eigenen.
