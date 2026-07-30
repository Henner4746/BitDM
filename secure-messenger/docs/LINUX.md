# BitDM auf Linux

Stand: 30.07.2026. Gemessen mit Flutter 3.44.8 (`bin/cache/flutter.version.json`)
und dem Stand `app/pubspec.lock` vom selben Tag.

---

## Zuerst: welches der zwei Dinge willst du?

Es gibt zwei ganz verschiedene Sachen, die beide „BitDM auf Linux" heissen
koennten. Wer das falsche liest, richtet einen Server ein und hat danach keine
App, oder umgekehrt.

**1. Die App auf einem Linux-Rechner laufen lassen.** Ein Flutter-Desktop-Bau
gegen GTK 3. Darum geht dieses Dokument, und um sonst nichts.

**2. Den Relay auf einem Linux-Server betreiben.** Das ist schon beschrieben und
wird hier nicht wiederholt:

* `deploy/README.md` — warum der Dienst so eingerichtet ist, wie er ist
  (`IPAddressDeny=any`, kein root, nur 127.0.0.1)
* `deploy/install-relay.sh` und `website/install.sh` — die Einrichtung selbst,
  wiederholbar
* `https://bitdm.net/docs` — dieselbe Sache fuer Leute, die nicht ins Repo sehen
* `docs/EIGENER-SERVER.md` — was passiert, wenn die App auf einen eigenen Server
  zeigen soll

Der Relay braucht die App nicht und die App braucht keinen eigenen Relay. Die
Voreinstellung ist `relay.bitdm.net` — die Konstante `relayBasis` in
`app/lib/main.dart`.

> **Zu den Belegen in diesem Text:** wo eine Datei stabil ist, steht die
> Zeilennummer dabei. Fuer `app/lib/main.dart` steht sie **nicht** dabei, und
> zwar aus einem gemessenen Grund: die Datei ist waehrend des Schreibens dieses
> Dokuments von 5.078 auf 5.108 Zeilen gewachsen. Eine Nummer, die in einer
> Stunde falsch ist, ist schlechter als der Name der Sache. Gesucht wird also
> nach dem Bezeichner.

---

## Der Stand, ohne Beschoenigung: es ist nie ein Linux-Bau gelaufen

Gemessen am 30.07.2026:

* `app/build/` enthaelt `windows/`, `web/`, `native_assets/windows/` und die
  Android-Zwischenstaende — **kein** `build/linux/`. Es hat also nie jemand
  `flutter build linux` ausgefuehrt.
* `secure-messenger/releases/` enthaelt sechs `.apk` und
  `bitdm-windows-1.5.1.zip`. **Kein Linux-Paket.** Kein `.deb`, kein `.rpm`,
  kein AppImage, kein Flatpak, kein AUR-Eintrag.

Damit gibt es genau **einen** Weg, und der zweite existiert nicht:

| Weg | Zustand |
|---|---|
| Selbst bauen | Sollte gehen — die Werkzeugkette ist unten aufgelistet und nachgemessen. Nachgewiesen ist sie nicht. |
| Fertiges Paket installieren | Gibt es nicht. |

Was hier steht, ist also aus dem Bau**system** gelesen, nicht aus einem
gelungenen Bau. Wenn du der Erste bist, der es durchlaufen laesst: die Stellen,
an denen es klemmen kann, stehen unter „Was in diesem Dokument fehlt".

---

## Was der Bau wirklich braucht

Nicht abgeschrieben. Jede Zeile kommt aus einer Datei, die beim Bauen gelesen
wird, und die Datei steht dabei.

### Was Flutter selbst verlangt

Aus `C:\flutter\packages\flutter_tools\lib\src\linux\linux_doctor.dart` — das
ist derselbe Code, der `flutter doctor` seinen Linux-Abschnitt fuellt:

| Programm | Mindestfassung |
|---|---|
| `clang++` | 3.4.0 |
| `cmake` | 3.10.0 |
| `ninja` | 1.8.0 |
| `pkg-config` | 0.29.0 |

Dazu drei Bibliotheken, die `flutter doctor` ueber `pkg-config --exists`
abfragt:

    gtk+-3.0    glib-2.0    gio-2.0

Fehlt eine davon, sagt Flutter woertlich: *„GTK 3.0 development libraries are
required for Linux development."*

`eglinfo` wird ebenfalls gesucht, aber nur als **Hinweis**, nicht als Fehler —
Flutter liest daraus Treiber- und Renderer-Angaben fuer die Diagnose. Ohne
`eglinfo` baut und laeuft die App trotzdem.

Zwei Dinge, die man oft noch erwartet, sind **nicht** noetig:

* Kein `flutter config --enable-linux-desktop`. In `features.dart:146` steht
  `Feature.fullyEnabled` — Linux-Desktop ist seit Langem der Normalzustand.
* Kein Schalter fuer Native Assets. `features.dart:197-204` traegt fuer den
  stabilen Kanal `enabledByDefault: true`. Das ist wichtig, weil sqlite3mc
  genau darueber kommt (siehe unten).

### Was dieses Projekt zusaetzlich verlangt

`app/linux/CMakeLists.txt:54-55` fordert `PkgConfig` und `gtk+-3.0` — das deckt
sich mit oben. Interessant sind die Plugins, die der Bau mitzieht.
`app/linux/flutter/generated_plugins.cmake` listet fuenf:

    flutter_secure_storage_linux   screen_retriever_linux
    url_launcher_linux             webcrypto
    window_manager

und `jni` als FFI-Plugin. Deren `linux/CMakeLists.txt` nachgelesen:

* **`flutter_secure_storage_linux` 3.0.1** fordert
  `pkg_check_modules(LIBSECRET REQUIRED IMPORTED_TARGET libsecret-1>=0.18.4)`.
  Das ist die **eine** Systembibliothek, die ueber GTK hinausgeht. Ohne sie
  bricht CMake ab, bevor ueberhaupt uebersetzt wird. Und sie ist nicht
  verzichtbar: dort liegt die Entropie, aus der die gesamte Identitaet entsteht
  (`app/lib/core/secret_store.dart`).
* **`webcrypto` 0.6.0** uebersetzt **BoringSSL mit** — `enable_language(ASM)`
  und eine ganze Quellenliste aus `third_party/boringssl/sources.cmake`. Es
  braucht also einen Assembler; der kommt mit `binutils`, das auf jeder
  Distribution ohnehin unter dem Uebersetzer liegt. `webcrypto` steht **nicht**
  in `pubspec.yaml` — es kommt transitiv ueber
  `unifiedpush → unifiedpush_linux → webpush_encryption → webcrypto`. Der
  Kommentar in `pubspec.yaml`, wonach webcrypto „wieder entfernt" wurde, meint
  die *direkte* Abhaengigkeit; im Bau ist es trotzdem drin.
* **`url_launcher_linux`, `screen_retriever_linux`, `window_manager`** linken
  nur gegen `flutter` und `PkgConfig::GTK`. Nichts Neues.

Die Kette ist es wert, aufgeschrieben zu werden, weil sie ueberrascht: von den
fuenf Plugins stammen **drei** aus etwas, das BitDM auf Linux gar nicht
benutzt. `unifiedpush_linux` 1.0.0 haengt an `window_manager` und an
`webpush_encryption`, dieses an `webcrypto`, und `window_manager` bringt
`screen_retriever` mit. Ein Push-Weg, der auf Linux abgeschaltet ist, zieht auf
diese Weise BoringSSL in den Bau. Das ist kein Fehler, aber es erklaert die
Bauzeit und den Assembler in der Liste oben.
* **`jni` 1.0.0** ruft in `src/CMakeLists.txt:20` `find_package(JNI COMPONENTS JVM)`
  **ohne** `REQUIRED`, wenn es als Flutter-Plugin gebaut wird. Ein JDK ist auf
  Linux also *nicht* Pflicht — ohne JDK wird `libjni.so` schlicht nicht
  gebaut, und BitDM ruft es auf Linux auch nirgends auf. Es steckt nur drin,
  weil `path_provider_android` es mitbringt.

Ausserdem, ausserhalb von CMake: **`git`**, weil das Flutter-SDK selbst ein
Git-Arbeitsverzeichnis ist und beim ersten Aufruf hineinsieht, und ein
Netzzugang, weil der Bau die SQLite-Bibliothek herunterlaedt.

---

## Paketnamen je Distribution

Die Namen unterscheiden sich mehr, als man beim Lesen der Bibliotheksnamen
vermuten wuerde: dieselbe GTK-Entwicklungsfassung heisst `libgtk-3-dev`,
`gtk3-devel` und `gtk3`. Deshalb hier je Distribution und nicht als eine
Liste mit Fussnoten.

**Was in jeder Zeile fehlt und absichtlich fehlt:** `glib-2.0` und `gio-2.0`
bekommen keinen eigenen Eintrag. Sie sind Teil von GLib, und das
GTK-3-Entwicklungspaket haengt auf jeder dieser Distributionen daran — wer GTK
hat, hat sie.

### Debian, Ubuntu, Mint, Pop!\_OS und alles mit `apt`

```bash
sudo apt install clang cmake ninja-build pkg-config \
                 libgtk-3-dev libsecret-1-dev \
                 git curl ca-certificates
```

Zur Laufzeit zusaetzlich ein Schluesselbund-Dienst (Begruendung weiter unten;
auf einem GNOME- oder KDE-Arbeitsplatz ist er schon da):

```bash
sudo apt install gnome-keyring
```

Fuer die Treiberangaben in `flutter doctor` nennt Flutter selbst
`apt install mesa-utils`. **Unsicher:** auf neueren Debian- und
Ubuntu-Ausgaben ist `eglinfo` aus `mesa-utils` nach `mesa-utils-bin`
umgezogen. Welches deine Ausgabe hat, sagt `apt-file search bin/eglinfo`. Es
ist ohnehin nur ein Hinweis, kein Fehler.

**Nicht belegt:** die Flutter-Dokumentation nennt fuer Debian ausserdem
`liblzma-dev` und `libstdc++-12-dev`. Beide tauchen in der ganzen lokalen
SDK-Kopie nirgends auf — `grep -rli liblzma /c/flutter` findet **null**
Treffer, und der Doctor prueft sie nicht. Ich kann nicht belegen, wofuer sie
gebraucht werden, also stehen sie nicht in der Zeile oben. Wenn der Bau nach
`lzma.h` oder einem fehlenden `libstdc++` verlangt, sind das die beiden
Pakete — dann bitte hier ergaenzen, mit der Fehlermeldung als Beleg.

### Fedora, RHEL, CentOS Stream, Rocky, Alma — `dnf`

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config \
                 gtk3-devel libsecret-devel \
                 git curl ca-certificates
```

Zur Laufzeit: `sudo dnf install gnome-keyring`.

**Zu `pkgconf-pkg-config`:** Fedora hat `pkg-config` durch `pkgconf` ersetzt;
`pkgconf-pkg-config` ist das Paket, das den Aufruf `pkg-config` bereitstellt,
und `pkgconfig` loest ueber `Provides` darauf auf. Beides fuehrt zum Ziel, der
ausgeschriebene Name ist der verlaesslichere.

**Unsicher:** wo `eglinfo` auf Fedora liegt. Es steckte historisch in
`mesa-demos`, und dieses Paket ist zeitweise aus den Fedora-Quellen
verschwunden. Ich habe keinen belastbaren aktuellen Namen — und weil es nur den
Diagnose-Hinweis betrifft, wird hier nicht geraten. `dnf provides '*/eglinfo'`
sagt es dir.

### Arch, Manjaro, EndeavourOS — `pacman`

```bash
sudo pacman -S --needed clang cmake ninja pkgconf \
                        gtk3 libsecret \
                        git curl ca-certificates
```

Zur Laufzeit: `sudo pacman -S gnome-keyring`.

Arch trennt Kopfdateien nicht in eigene Pakete — `gtk3` und `libsecret`
**sind** die Entwicklungsfassung. Wer hier nach `gtk3-devel` sucht, findet
nichts und schliesst daraus das Falsche.

`pkgconf` ist der heutige Paketname; `pkg-config` ist ein `Provides` darauf.

**Unsicher:** ob es ein Flutter-SDK-Paket in den offiziellen Quellen gibt oder
nur im AUR. Ich habe es nicht nachgesehen. Es ist auch nicht noetig, das zu
klaeren: das SDK von Hand auspacken und in den Pfad legen funktioniert
unabhaengig davon und ist der Weg, den die Flutter-Dokumentation selbst
beschreibt.

### openSUSE Leap und Tumbleweed — `zypper`

```bash
sudo zypper install clang cmake ninja pkgconf-pkg-config \
                    gtk3-devel libsecret-devel \
                    git curl ca-certificates
```

Zur Laufzeit: `sudo zypper install gnome-keyring`.

**Unsicher:** ob das Git-Paket auf deiner Ausgabe `git` oder `git-core` heisst
— openSUSE hat beides gefuehrt, wobei `git` das Sammelpaket ist. Wenn `git`
nicht aufloest, nimm `git-core`.

Der Rest ist belegt: openSUSE benutzt dieselben `-devel`-Endungen wie Fedora
und hat pkgconf ebenfalls als `pkgconf-pkg-config`.

### Alpine — `apk`

**Hier ist eine echte Luecke, und sie liegt nicht bei den Paketnamen.**

Alpine benutzt musl als C-Bibliothek. Das Flutter-SDK bringt fertige
Binaerdateien mit, die gegen glibc gebaut sind — der Dart-Uebersetzer, das
`gen_snapshot`-Werkzeug und `libflutter_linux_gtk.so`. Flutter nennt musl
nirgends als unterstuetzte Umgebung, und `gcompat` reicht fuer das Dart-SDK
erfahrungsgemaess nicht. **Ich habe es nicht ausprobiert** — auf diesem
Rechner laeuft Windows, und wie oben steht, ist ueberhaupt noch kein
Linux-Bau gelaufen.

Die Paketnamen waeren — **und keiner davon ist hier belegt**:
`clang`, `cmake`, `samurai` (liefert `ninja`; auf neueren Ausgaben gibt es auch
`ninja-build`), `pkgconf`, `gtk+3.0-dev`, `libsecret-dev`, `git`, `curl`,
`ca-certificates`. Bei `gtk+3.0-dev` und `libsecret-dev` bin ich mir recht
sicher, bei `samurai` gegen `ninja-build` nicht. Als Befehlszeile zum Abschreiben
steht das absichtlich nicht da.

**Empfehlung, statt eine Zeile hinzuschreiben, die keiner nachlaufen kann:**
auf Alpine ein glibc-System im Container bauen (Debian- oder
Fedora-Abbild, `podman run` genuegt) und nur das fertige Bundle
herausholen. Es ist ohnehin gegen glibc gelinkt und wuerde auf dem Alpine-Wirt
dieselbe Frage aufwerfen.

### Distributionen, die hier fehlen

Void, Gentoo, NixOS, Guix, Slackware, Solus. Keine Zeile fuer sie, weil ich
keine belegen kann. Fuer NixOS und Guix waere es ausserdem keine Paketliste,
sondern eine Ausdrucksdatei — das ist ein eigener Text und kein Nachtrag.

---

## Bauen

```bash
git clone <repo>
cd secure-messenger/app

flutter doctor -v          # der Abschnitt "Linux toolchain" muss gruen sein
flutter pub get
flutter build linux --release
```

Das Ergebnis landet in

    build/linux/<arch>/release/bundle/

`<arch>` ist `x64`, `arm64` oder `riscv64` — nachgelesen in
`flutter_tools/lib/src/build_info.dart:979-985`, wo der Pfad aus
`targetPlatform.simpleName` zusammengesetzt wird. Ohne Angabe ist es die
Architektur des Rechners, auf dem gebaut wird.

Starten:

```bash
./build/linux/x64/release/bundle/bitdm
```

`bitdm` ist der Name, weil `linux/CMakeLists.txt:7` `BINARY_NAME "bitdm"`
setzt. Das Verzeichnis ist verschiebbar: `CMAKE_INSTALL_RPATH` steht auf
`$ORIGIN/lib` (Zeile 17), die Bibliotheken werden also relativ zur ausfuehrbaren
Datei gefunden und nicht ueber einen festen Pfad.

Die Fensterleiste zeigt `bitdm` (`linux/runner/my_application.cc:48`), die
Anwendungskennung ist `com.bitdm.bitdm` (`linux/CMakeLists.txt:10`). Das
Startfenster ist 1280x720 (`my_application.cc:55`). Unter GNOME setzt der Runner
eine GTK-Header-Bar, unter anderen Fenstermanagern auf X11 eine gewoehnliche
Titelleiste — die Unterscheidung steht in `my_application.cc:35-53` und ist die
unveraenderte Flutter-Vorlage.

Wohin die Daten kommen: `~/.local/share/com.bitdm.bitdm/`. Das ist
`$XDG_DATA_HOME` plus der GTK-Anwendungskennung, die `path_provider_linux`
2.2.2 zur Laufzeit ueber `g_application_get_application_id` aus
`libgio-2.0.so.0` liest (`lib/src/get_application_id_real.dart`). Dort liegt
die verschluesselte Datenbank.

Es gibt **keine** `.desktop`-Datei und **kein** Symbol in `app/linux/`. Fuer
einen Bau und einen Start aus der Kommandozeile braucht es beides nicht; fuer
einen Eintrag im Anwendungsmenue schon. Absichtlich nicht dazuerfunden, solange
niemand ein Paket baut — eine `.desktop`-Datei, die auf einen Pfad zeigt, den
kein Paket anlegt, ist eine Datei, die nur so aussieht, als waere sie fertig.

---

## Die verschluesselte Datenbank: woher sqlite3mc auf Linux kommt

BitDM benutzt nicht das SQLite des Systems, sondern
**SQLite3MultipleCiphers** — dasselbe SQLite, ergaenzt um Verschluesselung der
ganzen Datei. Mit gewoehnlichem SQLite waere `PRAGMA key` still wirkungslos und
die Datenbank laege im Klartext auf der Platte. Gewaehlt wird das in
`app/pubspec.yaml`:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc
```

Was daraus auf Linux folgt, gelesen in
`sqlite3-3.5.0/hook/build.dart` und `lib/src/hook/`:

Der Bau-Hook **laedt eine fertige Bibliothek herunter**, er uebersetzt sie
nicht. Fuer x86-64 ist das

    https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.0/libsqlite3mc.x64.linux.so

und die Datei wird gegen den SHA-256-Wert geprueft, der in
`lib/src/hook/asset_hashes.dart:51` steht:

    e2c0a7ad08a29cc8c1621f641fd3025e81ae30300e8c1f8deb650c9da836f6e3

Weicht sie ab, bricht der Bau ab. Das ist die gleiche Lage wie auf Android und
Windows und in `pubspec.yaml` als offener Punkt fuer F-Droid vermerkt.

Danach legt Flutter die Datei als Native Asset unter
`build/native_assets/linux/` ab, und `linux/CMakeLists.txt:110-113` kopiert
dieses Verzeichnis ins Bundle nach `lib/`. Auf diesem Rechner nachgesehen: der
Windows-Zweig hat dort `build/native_assets/windows/sqlite3mc.dll` mit
**2.129.920 Byte**. Auf Linux ist der zu erwartende Name `libsqlite3mc.so` —
**nachgemessen ist er nicht**, weil noch kein Linux-Bau gelaufen ist. Auf der
Dart-Seite ist nichts zu tun: `app/lib/core/store/sqlite_zugang_native.dart`
verlaesst sich darauf, dass `ffi.sqlite3` beim ersten Zugriff selbst nachlaedt.

**Welche Architekturen gehen** (aus `lib/src/hook/assets.dart:186-192`):
`x64`, `arm64`, `arm`, `riscv64`.

**Was ausdruecklich nicht geht:** 32-Bit-x86. `assets.dart:88-95` schliesst
`linux` + `ia32` + `sqlite3mc` aus, mit der Begruendung, dass sich sqlite3mc
fuer i686 nicht bauen laesst. Auf einem 32-Bit-x86-Linux gibt es BitDM also
nicht — nicht, weil es niemand versucht hat, sondern weil die
Verschluesselungsschicht dort nicht existiert.

Es braucht dafuer **keinen** zusaetzlichen Schalter am Bau-Befehl: Native
Assets sind auf dem stabilen Kanal standardmaessig an
(`features.dart:197-204`). Es braucht aber **Netzzugang beim ersten Bau**. Der
Hook laedt nicht jedes Mal: `description.dart:207-219` sieht erst nach, ob die
Datei im geteilten Ausgabeverzeichnis schon liegt und ob ihr Hash stimmt, und
laedt nur sonst. Ein Bau ganz ohne Netz waere darueber machbar — wie genau, ist
hier nicht erprobt und sollte niemand aus diesem Absatz ableiten.

---

## Was BitDM auf Linux nicht kann, und warum

Das ist **keine Unfertigkeit**. In `app/lib/main.dart` gibt es genau zwei
Plattformweichen, und eine von ihnen ist dafuer da:

```dart
static bool get _nurAufAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
```

Dahinter steht alles, was vollstaendig in Kotlin liegt.
`android/app/src/main/kotlin/com/bitdm/bitdm/` hat acht Dateien; auf Linux
existiert keine Gegenseite dazu, und ein Aufruf ohne Gegenseite endet in einer
`MissingPluginException`. Die Weiche verbirgt die Bedienelemente lieber, als
Knoepfe zu zeigen, die mit einem Fehler antworten.

Der Grund fuer die Weiche steht als Datum im Code, im Kommentar ueber
`_faktorGehtHier`: am 30.07.2026 bot der erste Windows-Bau vier Sperrfaktoren
an, von denen drei nicht funktionieren konnten — und einer sagte „the PIN,
pattern or password of this phone" auf einem PC.

Die zweite Weiche, `_imFenster`, zaehlt Windows, Linux, macOS und das Web
zusammen und regelt nur die Optik: Fensterbreite statt Telefonbreite,
Strg+Eingabe zum Senden, Tastaturfokus. Linux ist dort gleichberechtigt dabei.

### Der Nahbereich — gar nicht

Der ganze Nahbereich haengt an `bitdm/nahfunk` und
`bitdm/nahfunk_ereignisse` (`lib/core/nah/funk.dart:166` und `168`), und die
Gegenseite ist `NahfunkKanal.kt`. Bluetooth-Werben, Bluetooth-Lauschen,
Uebertragung ueber Wi-Fi Direct — nichts davon hat auf Linux eine Umsetzung in
diesem Projekt. Details zum Verfahren: `docs/NAHBEREICH.md`.

Nachbaubar waere es auf Linux im Prinzip (BlueZ ueber D-Bus kann werben und
lauschen), aber es waere eine zweite Umsetzung desselben Protokolls und keine
Konfigurationsfrage.

### Drei der vier Sperrfaktoren — nur das App-Passwort bleibt

Die Faktoren sind `['bio', 'devpin', 'hw', 'pw']` — die Konstante
`zugriffsZeilen` in `main.dart` —, und sichtbar bleibt:

```dart
bool _faktorGehtHier(String k) => k == 'pw' || _nurAufAndroid;
```

* **`bio`** (Biometrie) und **`devpin`** (Geraetesperre) kommen aus
  `bitdm/schluesselfach` → `SchluesselfachKanal.kt`. Das ist der
  Android-Keystore mit hardwaregebundenen Schluesseln. Ein Fingerabdruckleser
  am Linux-Rechner ist etwas anderes als ein Schluessel, den ein Secure
  Element nur nach Biometrie freigibt — deshalb ist das keine Portierung
  weniger Zeilen.
* **`hw`** (Sicherheitsschluessel) braucht `bitdm/usb_hid` →
  `UsbHidKanal.kt` und NFC ueber `nfc_manager` 4.2.1, das nur Android und iOS
  umsetzt.
* **`pw`** (App-Passwort) ist reines Dart und laeuft ueberall — auf Linux ist es
  der einzige Faktor.

### Push — die Weiche verbirgt es, aber nicht so einfach wie erwartet

Hier ist eine Angabe zu korrigieren, die man leicht abschreibt.
„UnifiedPush ist Android" ist **nicht ganz richtig**: `pubspec.lock` enthaelt
`unifiedpush_linux` 1.0.0, und das Paket hat eine Linux-Umsetzung. Was gemessen
stimmt, ist Folgendes:

* `unifiedpush` 6.2.0 nennt in seiner eigenen `pubspec.yaml` unter
  `platforms:` nur `android: default_package: unifiedpush_android`. Fuer Linux
  ist nichts festgeschrieben.
* `unifiedpush_linux` 1.0.0 meldet sich mit `implements: unifiedpush` und
  `platforms: linux: dartPluginClass: UnifiedPushLinux` — also ohne native
  Registrierung. Passend dazu steht es **nicht** in
  `app/linux/flutter/generated_plugin_registrant.cc`; die fuenf, die dort
  stehen, sind oben aufgezaehlt.
* Die Push-Oberflaeche in BitDM steht hinter `_nurAufAndroid` und ist auf Linux
  gar nicht zu sehen.

Praktisch heisst das: **BitDM benutzt Push auf Linux nicht**, und keine Zeile
davon ist auf Linux erprobt. Ob `unifiedpush_linux` grundsaetzlich tragen
wuerde, ist eine offene Frage und keine beantwortete. Fuer den Desktop ist sie
auch weniger dringend als auf dem Telefon: der Anstoss existiert, damit die App
nicht dauernd lauschen muss und damit der Akku haelt (`lib/core/push.dart`).
Ein Rechner mit offenem Fenster hat dieses Problem nicht.

### Empfang im Hintergrund — nein

`bitdm/empfang` (`lib/core/empfang.dart:92`) ist ein
Android-Vordergrunddienst mit dauerhafter Benachrichtigung
(`EmpfangsDienst.kt`). Auf Linux gibt es das nicht. Die App empfaengt, solange
sie offen ist, und sonst nicht.

### Benachrichtigungen — heute nein, und das ist eine echte kleine Luecke

`flutter_local_notifications_linux` 8.0.1 steckt in `pubspec.lock` und ist
reines Dart ueber D-Bus. Es koennte also gehen. Es geht aber nicht, weil
`lib/core/benachrichtigungen.dart:52-56` beim `initialize()` nur

```dart
InitializationSettings(
  android: AndroidInitializationSettings('@mipmap/ic_launcher'),
)
```

uebergibt — ohne `linux:`-Eintrag. Der Aufruf landet im `catch` daneben,
`_bereit` bleibt `false`, und die App startet einfach ohne Benachrichtigungen.
Kein Absturz, aber auch kein Hinweis auf eine neue Nachricht. Das liesse sich
mit einer `LinuxInitializationSettings` beheben, im Unterschied zu allem
anderen in diesem Abschnitt.

### Anhaenge — verschluesseln ja, aussuchen und oeffnen nein

Die Dateiauswahl laeuft ueber `bitdm/dateien` → `DateiKanal.kt`
(`lib/core/dateien.dart:103`). Auf Linux antwortet der Kanal mit
`MissingPluginException`, und die Dart-Seite gibt dann `null` zurueck — der
Kommentar dort sagt es so: *„Auf dem Entwicklungsrechner gibt es diesen Kanal
nicht."* Es kann also keine Datei zum Senden ausgewaehlt werden, und
`Dateien.oeffne` fuer eine empfangene Datei gibt `false`.

Die **Verschluesselung** der Anhaenge laeuft dagegen weiter:
`lib/core/anhang/native_krypto.dart` benutzt `bitdm/krypto`, wenn es da ist,
und rechnet sonst in Dart — bitgleich, nur langsamer. `NativeStueckKrypto.imRueckfall`
sagt offen, dass der langsame Weg genommen wird, und erscheint im
Verbindungstest. Wie langsam es auf Linux ist, ist **nicht gemessen**. Die
vorhandenen Zahlen sagen darueber nichts — sie stehen im Kommentar zu
`webcrypto` in `pubspec.yaml` (12 MB/s auf dem Entwicklungsrechner unter
Windows; 8,0 MB/s verschluesseln und 5,3 MB/s entschluesseln auf einem Galaxy
S25 Ultra, gemessen mit `integration_test/anhang_tempo_test.dart`).

### QR-Code — zeigen ja, scannen nein

Den eigenen Code zeichnet `lib/core/qr_bild.dart` in reinem Dart ueber `zxing2`
— das laeuft auf Linux. Das **Einlesen** braucht die Kamera, und `camera`
0.12.0+2 hat in `pubspec.lock` nur `camera_android_camerax`,
`camera_avfoundation` und `camera_web` — keine Linux-Umsetzung. Der
Scan-Knopf steht deshalb hinter `_nurAufAndroid` (`if (_nurAufAndroid)
smallBtn(t('scan'), _scanneQr)` im Kontaktbildschirm).
Adressen werden auf Linux getippt oder eingefuegt; sie sind 56 Zeichen lang und
tragen eine 3-Byte-Pruefsumme, ein Tippfehler faellt also auf.

### Screenshot-Sperre — ohne Wirkung, und sie sagt es

`bitdm/fenster` gibt es auf Linux nicht. `Fenster.screenshotSperre` faengt die
`MissingPluginException` und gibt `false` zurueck
(`lib/core/fenster.dart:24-34`) — die Oberflaeche zeigt dann keinen Haken. Das
ist Absicht: ein Haken, hinter dem nichts steht, waere schlimmer als eine
fehlende Einstellung.

---

## Was zur Laufzeit da sein muss, nicht nur zum Bauen

**Ein Schluesselbund-Dienst.** `flutter_secure_storage` spricht auf Linux ueber
libsecret mit einem Dienst, der `org.freedesktop.secrets` anbietet — in der
Regel `gnome-keyring-daemon`, alternativ KWallet oder KeePassXC mit
eingeschaltetem Secret-Service. Auf einem GNOME- oder KDE-Arbeitsplatz laeuft
er ohnehin. **Auf einem nackten Fenstermanager, in einem Container oder ueber
SSH mit X-Weiterleitung laeuft er nicht**, und dann findet BitDM die Entropie
nicht, aus der die Identitaet entsteht. libsecret selbst installiert zu haben,
genuegt dafuer nicht — die Bibliothek ist der Anrufer, nicht die Gegenseite.
Wie sich das genau aeussert, ist auf Linux nicht erprobt.

**`ca-certificates`.** Die Verbindung zu `relay.bitdm.net` und zu
`dateien.bitdm.net` laeuft ueber TLS, und `dart:io` prueft dabei gegen den
Wurzelspeicher des Systems. Auf einem Arbeitsplatz-System ist er da; in einem
minimalen Container oft nicht, und dann scheitert jede Verbindung mit einem
Zertifikatsfehler, der wie ein Netzproblem aussieht.

**OpenGL beziehungsweise EGL.** Flutter zeichnet auf Linux ueber GL. Eine
Mesa-Installation mit funktionierendem Treiber ist Voraussetzung; unter
`llvmpipe` ohne Grafikbeschleunigung zeichnet es, aber langsam.

---

## Was in diesem Dokument fehlt

Damit der naechste nicht dasselbe zweimal herausfindet:

1. **Es ist kein Linux-Bau gelaufen.** Alles oben ist aus dem Bausystem
   gelesen. Der erste Mensch, der `flutter build linux --release` durchbekommt,
   sollte hier die Fassung eintragen, die Ausgabe des Doctors und die Groesse
   des Bundles — mit Datum, wie ueberall in diesem Projekt.
2. **`liblzma-dev` und `libstdc++-*-dev`** sind unbelegt. Siehe den
   Debian-Abschnitt.
3. **Wo `eglinfo` liegt**, ist auf Debian-Neufassungen und auf Fedora unklar.
   Betrifft nur die Diagnose.
4. **Alpine und musl** sind vermutlich aussichtslos, aber nicht widerlegt.
5. **Void, Gentoo, NixOS, Guix, Slackware, Solus** haben keine Zeile.
6. **Der Schluesselbund** ist auf Linux nicht erprobt. Was BitDM anzeigt, wenn
   kein Secret-Service-Dienst laeuft, weiss ich nicht.
7. **Kein Paket, keine `.desktop`-Datei, kein Symbol.** Wer das bauen will,
   fange bei `linux/CMakeLists.txt:78-128` an — die Installationsregeln legen
   das Bundle schon relocatable ab, das ist die halbe Arbeit fuer ein
   AppImage oder ein Flatpak.

Und zwei Punkte, die nicht in diesem Dokument fehlen, sondern in der App:

* `benachrichtigungen.dart` uebergibt keine `LinuxInitializationSettings`. Das
  ist die einzige der Linux-Luecken oben, die sich mit wenigen Zeilen schliessen
  laesst.
* Ob `unifiedpush_linux` 1.0.0 ueberhaupt traegt, ist ungeprueft. Solange es
  ungeprueft ist, gehoert Push auf Linux hinter die Weiche, wo es heute steht.
