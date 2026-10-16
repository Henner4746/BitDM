#!/usr/bin/env bash
# Signals libsignal fuer die Android-APK aus der Quelle bauen, statt der
# vorgebauten Bibliotheken, die der Build-Hook des Dart-Pakets `libsignal`
# sonst von GitHub laedt.
#
# WARUM: Die Anbindung (djx-y-z/libsignal_dart) hat einen einzigen Betreuer.
# Ihr Hook prueft die Archive gegen eine Pruefsummendatei aus DEMSELBEN
# GitHub-Release. Das faengt kaputte Downloads ab, aber kein ausgetauschtes
# Release, denn wer das eine aendern kann, aendert auch das andere. Und F-Droid
# verlangt den Bau aus der Quelle ohnehin. Gebaut wird genau der rust/-Ordner,
# den `flutter pub get --enforce-lockfile` mit der Pruefsumme aus pubspec.lock
# geholt hat. Er ist gleich dem Stand am Tag libsignal_frb-7.0.0 upstream.
#
# WIE DIE BIBLIOTHEK ZUM HOOK KOMMT: Der Hook von libsignal 8.0.0 hat dafuer
# keinen Schalter. Einen lokalen Bau nimmt er nur aus rust/target/release/ und
# nur, wenn Ziel und Rechner gleich sind, fuer Android also nie. Eine
# Umgebungsvariable kaeme gar nicht an: hooks_runner reicht nur PATH, HOME,
# ANDROID_* und wenige andere an den Hook durch. Deshalb aendert
# libsignal-hook-quellbau.patch den Hook: Android nimmt nur noch
# rust/target/<triple>/release/liblibsignal_frb.so und bricht ab, wenn sie
# fehlt. Ein Rueckfall auf den Download ist damit ausgeschlossen.
#
# Aufruf aus dem F-Droid-Rezept, im Ordner secure-messenger/app, nach
# `flutter pub get` und vor `flutter build apk`:
#   bash ../fdroid/libsignal-quellbau.sh <Pfad des Srclibs rustup>
# Braucht PUB_CACHE, ANDROID_NDK_HOME (setzt `fdroid build` aus `ndk:`), protoc
# und einen C-Compiler fuer den Rechner selbst (Bau-Skripte der Crates), beides
# aus dem sudo-Block des Rezepts.
set -euo pipefail

# FESTE FASSUNGEN. Wer eine davon hebt, misst die Bitgleichheit neu
# (Workflow „Android (F-Droid-Bau)“ mit gegenprobe).
RUSTUP_FASSUNG=1.29.1
RUST_FASSUNG=1.99.1
RUST_COMMIT=58cf8f9c35b355199727627d07ae34a4e2846d67
CARGO_NDK_FASSUNG=4.1.2
# Debian trixie liefert protobuf-compiler 3.21.12-11+deb13u1. Geprueft wird die
# Fassung von protoc selbst; ein Sicherheits-Update von Debian bricht den Bau
# also nicht, ein Sprung auf ein anderes protoc schon.
PROTOC_FASSUNG=3.21.12
NDK_FASSUNG=28.2.13676358 # r28c, wie `ndk:` im Rezept
ANDROID_API=28            # = minSdk in android/app/build.gradle.kts
PAKET_FASSUNG=8.0.0       # libsignal in pubspec.lock
CRATE_FASSUNG=7.0.0       # rust/Cargo.toml des Pakets
HOOK_SHA256=23e12134c37a59dc920170ad72f258c6f87cb09be19cebf26264f81334e8f591
HOOK_GEPATCHT_SHA256=5e711b1369e2e0c2eafcd14505b716aefd493e0fe49e60dfc3d11309e43860a4
ZIELE=(aarch64-linux-android armv7-linux-androideabi)

fehler() {
  echo "libsignal-quellbau: $*" >&2
  exit 1
}

RUSTUP_SRCLIB=${1:-}
[ -n "$RUSTUP_SRCLIB" ] || fehler "Aufruf: libsignal-quellbau.sh <Pfad des Srclibs rustup>"
[ -f "$RUSTUP_SRCLIB/rustup-init.sh" ] || fehler "$RUSTUP_SRCLIB/rustup-init.sh fehlt"
[ -n "${PUB_CACHE:-}" ] || fehler "PUB_CACHE ist nicht gesetzt"
[ -n "${ANDROID_NDK_HOME:-}" ] || fehler "ANDROID_NDK_HOME ist nicht gesetzt (ndk: im Rezept)"
[ -f pubspec.lock ] || fehler "nicht im Ordner secure-messenger/app aufgerufen"
HIER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PAKET=$PUB_CACHE/hosted/pub.dev/libsignal-$PAKET_FASSUNG
HOOK=$PAKET/hook/build.dart

# --- Stimmen die Pins mit dem Quellstand ueberein?
grep -A7 '^  libsignal:$' pubspec.lock | grep -qx "    version: \"$PAKET_FASSUNG\"" ||
  fehler "pubspec.lock nennt nicht libsignal $PAKET_FASSUNG; Pins in diesem Skript nachziehen"
[ -d "$PAKET/rust" ] || fehler "$PAKET/rust fehlt (vorher flutter pub get)"
crate=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$PAKET/rust/Cargo.toml" | head -n1)
[ "$crate" = "$CRATE_FASSUNG" ] || fehler "rust/Cargo.toml hat $crate, erwartet $CRATE_FASSUNG"
grep -qx "Pkg.Revision = $NDK_FASSUNG" "$ANDROID_NDK_HOME/source.properties" ||
  fehler "NDK in $ANDROID_NDK_HOME ist nicht $NDK_FASSUNG"
[ "$(protoc --version)" = "libprotoc $PROTOC_FASSUNG" ] ||
  fehler "protoc ist $(protoc --version), erwartet $PROTOC_FASSUNG"

# --- Hook umstellen, nur ausgehend von der geprueften Fassung.
case "$(sha256sum < "$HOOK" | cut -d' ' -f1)" in
  "$HOOK_SHA256") patch --batch --forward -p1 -d "$PAKET" < "$HIER/libsignal-hook-quellbau.patch" ;;
  "$HOOK_GEPATCHT_SHA256") echo "hook/build.dart ist schon umgestellt" ;;
  *) fehler "hook/build.dart ist weder die gepruefte noch die umgestellte Fassung" ;;
esac
[ "$(sha256sum < "$HOOK" | cut -d' ' -f1)" = "$HOOK_GEPATCHT_SHA256" ] ||
  fehler "hook/build.dart nach dem Patch unerwartet"

# --- Rust. rustup-init.sh aus dem Srclib laedt rustup-init in genau dieser
# Fassung (RUSTUP_VERSION), rustup prueft die Teile der Toolchain gegen deren
# Manifest, und am Ende muss rustc den erwarteten Commit nennen.
export CARGO_HOME=$HOME/.cargo RUSTUP_HOME=$HOME/.rustup
RUSTUP_VERSION=$RUSTUP_FASSUNG sh "$RUSTUP_SRCLIB/rustup-init.sh" -y --no-modify-path \
  --profile minimal --default-toolchain "$RUST_FASSUNG"
export PATH=$CARGO_HOME/bin:$PATH RUSTUP_TOOLCHAIN=$RUST_FASSUNG
rustup target add "${ZIELE[@]}"
rustc -vV | grep -qx "commit-hash: $RUST_COMMIT" || fehler "rustc ist nicht $RUST_FASSUNG ($RUST_COMMIT)"
cargo install --locked cargo-ndk --version "$CARGO_NDK_FASSUNG"

# --- Bauen.
# Pfade aus Paket, Cargo und rustup kommen sonst als Panic-Orte in die
# Bibliothek; umgeschrieben haengt das Ergebnis nicht am Bauordner. Die
# Build-ID (sha1 ueber die fertige Datei) erkennt die Bibliothek in der APK
# wieder, auch nachdem Gradle sie beim Packen noch einmal gestrippt hat
# (elf_pruefen.py). Von selbst setzt hier keiner eine: Die Bibliotheken
# upstream (cargo-ndk, NDK r26d) haben keine.
RS=$'\x1f'
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$PAKET=/libsignal-$PAKET_FASSUNG$RS--remap-path-prefix=$CARGO_HOME=/cargo$RS--remap-path-prefix=$RUSTUP_HOME=/rustup$RS-Clink-arg=-Wl,--build-id=sha1"
for ziel in "${ZIELE[@]}"; do
  export "CFLAGS_${ziel//-/_}=-ffile-prefix-map=$CARGO_HOME=/cargo"
done
cd "$PAKET/rust"
cargo fetch --locked
for ziel in "${ZIELE[@]}"; do
  cargo ndk --target "$ziel" --platform "$ANDROID_API" build --release --locked
  # Der Stempel, den der Hook verlangt (wie `make build` upstream).
  printf '%s\n' "$CRATE_FASSUNG" > "target/$ziel/release/.crate-version"
done

# Zwischenstaende weg, sie belegen auf dem GitHub-Runner sonst Gigabytes. Der
# Hook braucht nur die .so und den Stempel.
rm -rf target/release
for ziel in "${ZIELE[@]}"; do
  rm -rf "target/$ziel/release/"{build,deps,.fingerprint,incremental,examples}
  rm -f "target/$ziel/release/liblibsignal_frb."{a,rlib,d}
done

python3 -I "$HIER/elf_pruefen.py" target/*/release/liblibsignal_frb.so
