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
- **Android, Release und F-Droid:** Die Bibliothek wird aus der Quelle gebaut, im F-Droid-Rezept selbst. Damit baut F-Droids Server sie genauso. Stand 16.10.2026 auf Zweig `feat/libsignal-quellbau`, Einzelheiten unten.
- **Windows, Linux und Android-Bauten am eigenen Rechner:** Die Binärdateien lädt weiter der Build-Hook des Pakets. Er prüft sie gegen eine Prüfsummendatei aus demselben GitHub-Release, und das schützt nicht gegen ein ausgetauschtes Release (Befund unten). Für die Linux-Pakete aus `linux.yml` ist das noch offen.
- **Web:** Das WASM-Modul legt der Build-Hook in `web/pkg/` an (in `.gitignore`, Prüfsummen in `deploy/webapp/README.md`). Die CSP bleibt `script-src 'self' 'wasm-unsafe-eval'`, ohne `'unsafe-eval'`; dafür sorgt `web/libsignal_ohne_eval.js` (siehe „Web-Fassung“ unten). Es geht nur der normale Web-Build, nicht `--wasm`.
- **Größe:** Die APK wird um gut 4 MB größer, etwa 2,5 MB für arm64-v8a und 1,7 MB für armeabi-v7a. Gemessen ist das an den vorgebauten Bibliotheken upstream (6,30 und 4,54 MB, gestrippt 2,54 und 1,71 MB). In der APK liegen sie gestrippt und unkomprimiert. Die Werte des eigenen Baus schreibt der Workflow je ABI in die Zusammenfassung.

#### Der Build-Hook von `libsignal` 8.0.0 (Befund vom 16.10.2026)

Untersucht ist `hook/build.dart` aus dem pub-Cache (sha256 `23e12134…f591`). Die Datei ist gleich dem Tag `v8.0.0` upstream. `rust/` im Paket ist gleich dem Tag `libsignal_frb-7.0.0`, aus dem die Binärdateien stammen. Es fehlt nur `.cargo/config.toml`, und die gilt nur für WASM.

| Frage | Antwort | Fundstelle |
|---|---|---|
| Woher kommen die Binärdateien? | Aus dem GitHub-Release `libsignal_frb-<Crate-Fassung>`. Die Fassung kommt aus `rust/Cargo.toml` (7.0.0), nicht aus der Paketfassung 8.0.0. Ein Archiv je Ziel, z. B. `libsignal_frb-7.0.0-android-arm64-v8a.tar.gz`. | `main`, Z. 203–247; `_readVersion`, Z. 273; `_resolveAssetInfo`, Z. 629 |
| Wogegen wird geprüft? | Gegen `libsignal_frb-7.0.0-checksums.sha256` aus **demselben** Release. Das fängt kaputte Downloads ab. Wer das Release austauschen kann, tauscht aber beide Dateien. | `_resolveExpectedChecksum`, Z. 907; `_downloadChecksums`, Z. 957 |
| Nimmt er einen lokalen Bau? | Nur aus `rust/target/release/`, mit Stempel `.crate-version`, und nur wenn Ziel und Rechner gleich sind. Für Android also nie. Probe: Mit dem unveränderten Hook und einer fertigen `.so` in `rust/target/aarch64-linux-android/release/` lädt er trotzdem herunter (`7.0.0-android-arm64-v8a/.download-complete`). | `_findLocalBuild`, Z. 586–597; Stempelprüfung Z. 157–175 |
| Gibt es einen Schalter? | Nur `LIBSIGNAL_ALLOW_UNVERIFIED_DOWNLOAD`, und der lockert die Prüfung nur. Unter `flutter build` kommt er nicht einmal an: hooks_runner 1.1.1 (Flutter 3.44.8) gibt Hooks nur eine feste Liste von Umgebungsvariablen weiter, nämlich PATH, HOME, ANDROID_HOME, ANDROID_NDK*, LIBCLANG_PATH, TEMP/TMP, Proxy-Variablen sowie CCACHE_* und NIX_*. Eine Umgebungsvariable als Weiche scheidet damit aus. | Hook Z. 892; `hooks_runner` `build_runner.dart`, Z. 588–622 |
| Und `.skip_libsignal_hook`? | Schaltet den Hook ganz ab. Dann registriert er gar keine Bibliothek. Upstream braucht die Datei nur intern für `make`. | Z. 121–132 |
| Die README? | Verspricht, der Hook nehme einen Bau aus `make build` „automatically“. Das gilt nur für den Rechner selbst. `make build-android` (Makefile upstream) legt die Android-Bibliotheken nach `rust/target/<triple>/release/`, also genau dorthin, wo der Hook nie nachsieht. Einen Stempel schreibt es auch nicht. Der Quellbau für Android ist upstream beschrieben, aber nicht angeschlossen. | README Z. 145–147 und 551–600 |

Folge: Ohne Eingriff in den Hook geht es nicht. Verworfen ist, den Download-Cache des Hooks vorzubelegen (`.dart_tool/hooks_runner/shared/libsignal/build/7.0.0-android-*/` mit `.download-complete`). Das hinge am inneren Aufbau von hooks_runner, und änderte der sich, lüde der Hook still wieder herunter.

#### Wie der Quellbau läuft

- **Rezept** `fdroid/com.bitdm.bitdm.yml`: Der sudo-Block installiert zusätzlich `gcc libc6-dev protobuf-compiler`. Der C-Compiler ist für die Bau-Skripte der Crates auf dem Rechner selbst, das F-Droid-Image hat keinen. Dazu kommt das Srclib `rustup@1.29.1`. In `build:` läuft vor `flutter build apk` der Aufruf `bash ../fdroid/libsignal-quellbau.sh $$rustup$$`. Der Bau liegt damit hinter dem Scanner, also löscht `scandelete` nichts davon.
- **`fdroid/libsignal-quellbau.sh`:**
  - Prüft zuerst die Pins gegen den Quellstand: `pubspec.lock` (libsignal 8.0.0), Crate 7.0.0, NDK und protoc.
  - Patcht den Hook, aber nur ausgehend vom geprüften Hash. Danach muss der Hash der umgestellten Fassung herauskommen.
  - Installiert Rust und prüft den Commit von rustc. Danach `cargo install --locked cargo-ndk`.
  - Baut `aarch64-linux-android` und `armv7-linux-androideabi` mit `--platform 28` (= minSdk) und `--locked`.
  - Schreibt Panic-Pfade von Paket, Cargo und rustup auf feste Präfixe um und setzt eine Build-ID.
  - Schreibt den Stempel `.crate-version` und räumt die Zwischenstände weg.
- **`fdroid/libsignal-hook-quellbau.patch`:** Für Android nimmt der Hook nur noch `rust/target/<triple>/release/liblibsignal_frb.so`, mit der Stempelprüfung von upstream. Fehlt die Datei, bricht der Bau ab. Ein Rückfall auf den Download ist ausgeschlossen. Probe mit `testCodeBuildHook` gegen den umgestellten Hook, 5 von 5 Fällen grün:
  - arm64 mit Bau wird genommen, ohne Download-Cache.
  - armv7 ohne Bau bricht ab.
  - Ein falscher Stempel bricht ab.
  - Ein fehlender Stempel bricht ab.
  - x86_64 bricht ab, statt herunterzuladen.
- **Workflow** `android-fdroid.yml`:
  - Legt die Srclib-Beschreibung bereit (`fdroid/srclibs/rustup.yml`, Kopie aus fdroiddata).
  - Neuer Schritt „libsignal aus der Quelle“. Er vergleicht die Bibliothek in der fertigen APK per Build-ID mit dem Quellbau (`fdroid/elf_pruefen.py`). Gradle strippt beim Packen noch einmal, deshalb taugt der Dateivergleich nicht. Er prüft auch die 16-KiB-Ausrichtung für arm64, verlangt, dass kein Download-Cache des Hooks existiert, und schreibt die Größen je ABI in die Zusammenfassung.
  - Neue Eingabe `gegenprobe`: Von Hand gestartet, baut der Workflow zweimal auf getrennten Runnern, und der Auftrag `vergleichen` verlangt bitgleiche APKs. Beglaubigt wird nur der erste Bau.

| Werkzeug | Fassung | Woher, wie geprüft |
|---|---|---|
| Rust | 1.99.1 (`58cf8f9c35b3…`) | rustup, Profil minimal. Die Teile prüft rustup gegen ihr Manifest, den Commit prüft `rustc -vV`. |
| rustup | 1.29.1 | Srclib aus fdroiddata, Binärdatei über `RUSTUP_VERSION`. Die `Prepare`-Zeile des Srclibs greift ab 1.29 nicht mehr, daher die Variable. |
| cargo-ndk | 4.1.2 | `cargo install --locked` von crates.io, wie upstream |
| protoc | 3.21.12 | Debian trixie `protobuf-compiler` (3.21.12-11+deb13u1). Geprüft wird die protoc-Fassung, nicht das Debian-Paket. |
| NDK | r28c (28.2.13676358) | `ndk:` im Rezept, `source.properties` geprüft |
| libsignal | Paket 8.0.0, Crate 7.0.0, Signal v0.105.0 (`4beb029d…`) | Prüfsumme in `pubspec.lock`, `Cargo.lock` mit `--locked` |

Upstream baut anders: rustc 1.99.0, NDK r26d, `--platform 24`, ohne Build-ID. Die eigenen Bibliotheken sind deshalb nicht byte-gleich mit den vorgebauten, und das ist auch nicht das Ziel. Ziel ist, dass zwei Bauten derselben Quelle gleich sind, bei uns und bei F-Droid.

#### Bitgleichheit: Stand

- **Im F-Droid-Image: noch nicht gemessen.** Dafür muss der Zweig auf GitHub liegen. Dann den Workflow „Android (F-Droid-Bau)“ von Hand mit `gegenprobe` starten: Er baut zweimal und vergleicht selbst. Der Push braucht Henriks Ja.
- **Vorab am Windows-Rechner** (nicht das F-Droid-Image, nur Rust-Teil): siehe Nachtrag unten, sobald gelaufen.
- Bekannte Risiken für die Gleichheit sind Pfade und Werkzeugfassungen. Pfade schreibt das Skript um, und F-Droid baut ohnehin im selben Pfad (`/home/vagrant/build/com.bitdm.bitdm`). Die Werkzeuge sind oben gepinnt.
- **Laufzeit:** F-Droid bricht einen Bau nach 2 Stunden ab (Standard `timeout`). Der Rust-Teil kommt zum bisherigen Bau dazu. Liegt der GitHub-Lauf deutlich über einer Stunde, im Rezept `timeout:` setzen.

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
