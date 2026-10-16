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
- **Web:** Das WASM-Modul legt der Build-Hook in `web/pkg/` an (in `.gitignore`, Prüfsummen in `deploy/webapp/README.md`). Die CSP bleibt `script-src 'self' 'wasm-unsafe-eval'`, ohne `'unsafe-eval'`; dafür sorgt `web/libsignal_ohne_eval.js` (siehe „Web-Fassung“ unten). Es geht nur der normale Web-Build, nicht `--wasm`.
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

## Web-Fassung (16.10.2026)

**Befund:** Der Lader von flutter_rust_bridge 2.13.0 macht die WASM-Anbindung mit `new Function("window.wasm_bindgen = wasm_bindgen")` global sichtbar. Das ist `eval`, und die CSP von bitdm.net/app/ verbietet es. Die Web-App blieb beim Anlegen der Identität stehen. Upstream ist das offen: fzyzcjy/flutter_rust_bridge#3477.

**Behebung:** `web/libsignal_ohne_eval.js` läuft vor `flutter_bootstrap.js` und erledigt genau diesen einen konstanten Text ohne `eval`; jeder andere `Function`-Aufruf geht unverändert an den echten Konstruktor, den die CSP weiter verbietet. `test/web/libsignal_ohne_eval_test.dart` prüft an den Quellen der aufgelösten Pakete, dass der Text gleich bleibt und keine weitere `eval`-Stelle dazukommt (mutationsgeprüft). Die zweite `eval` in der WASM-Anbindung gehört zum Worker-Pool, den libsignal nicht einbaut; sie wird nie aufgerufen.

**Durchstich:** zwei Web-Clients mit der Produktions-CSP und getrennter Herkunft gegen einen lokalen Relay mit `BITDM_KYBER_PFLICHT=1`. Anmeldung mit Kyber, Kontaktanfrage (PQXDH), Annahme, Nachricht und Antwort liefen durch, mit Lesebestätigung.

## Durchstich Android (17.10.2026)

Zwei Emulatoren (Android 15, x86_64) auf dem Mini-PC (CT 107), Release-APK nur für x86_64 mit `BITDM_RELAY=http://10.0.2.2:8611`, Relay aus `server/tools/testaufbau.py` mit `BITDM_KYBER_PFLICHT=1`, Emulatoren ohne DNS. `tools/durchstich_zwei_geraete.ps1 -Weiter -Lokal -ZielA … -ZielB …` lief in 128 s durch: zwei Identitäten, Kontaktanfrage (PQXDH), Annahme, Nachricht A → B, Antwort B → A. Beide Anmeldungen nahm der Relay unter Kyber-Pflicht an. Die APK enthält `liblibsignal_frb.so` für x86_64; auf ARM-Geräten steht der Lauf noch aus.

## Befunde beim Umbau (16.10.2026)

Die Tests gegen die neue Bibliothek haben zwei schwere Eigenheiten der Anbindung und zwei Fehler im Kern gezeigt. Alle vier sind behoben und mit Tests belegt.

1. **Die Anbindung ruft `isTrustedIdentity` nie auf.** Beim Sitzungsaufbau legt sie die Sitzung ab, BEVOR `saveIdentity` laeuft. BitDMs Pruefung „Schluessel ergibt Adresse“ kam damit zu spaet: Ein feindlicher Relay haette unter einer fremden Adresse sein eigenes Buendel ausliefern und mitlesen koennen. Das Bibliotheksverhalten ist in `test/crypto/signal_bibliothek_test.dart` festgehalten, Gruppe „BEFUND 16.10.2026“. Gegenmittel, jedes einzeln getestet:
   - **Riegel vor libsignal:** `PreKeyBundleBridge.fromRelay` verlangt, dass der Schluessel die `userId` ergibt. `_bauSitzungen` verlangt, dass `userId` die angefragte Adresse ist. `_nimmUmschlagJetzt` rechnet bei jeder Erstnachricht die Absenderadresse aus deren Schluessel nach. Alle drei werfen `FremdeIdentitaet`.
   - **Schnappschuss** um jeden Sitzungsaufbau: Bei einem Fehler bleibt nichts im Speicher.
   - **`getIdentity` liefert immer den Schluessel der Adresse**, auch fuer unbekannte Adressen. Damit lehnt libsignal einen fremden Schluessel selbst mit `untrustedIdentity` ab, und zwar bevor eine Sitzung entsteht. `saveIdentity` wirft nicht mehr, denn ein Wurf aus einem Rueckruf wird zur Panic im Rust-Faden, und im Browser kehrt der Aufruf danach nie zurueck.
   - **Mutationsprobe:** Ohne Riegel und ohne Schnappschuss wird `test/net/fremde_identitaet_test.dart` rot („eine Sitzung mit Mallorys Schluesseln steht unter Doras Adresse“).
2. **Geraetekennungen nur von 1 bis 127.** `ProtocolAddress` in libsignal 0.105 wirft ausserhalb dieses Bereichs. BitDM vergab fuer Zweitgeraete Zufallszahlen bis 2^31, jedes Zweitgeraet waere also stumm gewesen.
   - Neue Kennungen kommen jetzt aus 2..127.
   - Bestehende Zweitgeraete mit groesserer Kennung ziehen beim ersten Verbinden um und melden sich neu an.
   - Geraete der Gegenstelle ausserhalb des Bereichs werden beim Senden uebersprungen.
   - Der Relay lehnt Anmeldungen MIT Kyber und einer Kennung ueber 127 ab.
3. **Einmalschlüssel gingen doppelt zum Relay.** Jede Anmeldung lud alle lokalen Einmalschlüssel hoch, auch solche, die der Relay schon ausgegeben hatte. Er gab sie dann ein zweites Mal aus, und die Erstnachricht des Zweiten scheiterte. Dazu meldete der Relay `prekeys_low` unter 20 Kyber-Schlüsseln, die App füllte erst unter 5 nach und meldete sich bei jedem Verbinden ergebnislos neu an.
   - Die App merkt sich, bis zu welcher Nummer sie gemeldet hat, und lädt nur Neues hoch. Den vollen Bestand bekommt nur ein Relay, der sie nicht kennt.
   - `prekeys_low` erzeugt immer einen frischen Satz. Lokal bleiben höchstens 400 EC- und 100 Kyber-Einmalschlüssel.
   - Belegt in `test/net/prekey_nachschub_test.dart`.
4. **Doppelversand im Nachversand.** `sendMessage` sendet unabgewartet, und bis zum Ende steht die Nachricht auf „sending“. Kam in diesem Fenster jemand in Reichweite oder verband sich der Relay neu, schickte der Nachversand sie ein zweites Mal. Der Fehler ist älter als der Umstieg, aber mit der Rust-Anbindung wurde das Fenster breit genug, um im Gesamtlauf aufzufallen.
   - Jetzt gilt ein Sendeversuch je Nachricht und je Ausgangseintrag zur Zeit. Was der Nachversand deshalb überspringt, holt er nach, sobald der laufende Versuch endet.
   - Belegt in `test/nah/nahweg_test.dart`, „WAEHREND SIE NOCH HINAUSGEHT“. Gegen den alten Kern zeigt der Test zwei Umschläge.

**Offen:** Hat ein Kontakt nur Geraete mit alter App, bleibt die Nachricht auf „wird gesendet“. Die Oberflaeche sagt noch nicht, dass der Kontakt aktualisieren muss. Dafuer braucht der Kontakt ein eigenes Feld.
