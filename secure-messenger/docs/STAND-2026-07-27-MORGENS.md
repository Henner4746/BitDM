# Stand am Morgen des 27.07.2026

Über Nacht gearbeitet. Kurzfassung zuerst, Belege darunter.

| | |
|---|---|
| Dart-Tests | **771 grün** (Abend vorher: 736) |
| Python-Tests | **60 grün** (Abend vorher: 55) |
| `flutter analyze` | keine Fehler, keine Warnungen in berührtem Code |
| APK | `releases/bitdm-nahbereich-2026-07-27.apk`, **auf beiden Telefonen installiert** |
| Relay | neuer Stand **läuft produktiv**, 32 Konten und 4 wartende Nachrichten unversehrt |

**Die Nähe-Funktion ist fertig gebaut und im Code durchgehend geprüft — aber sie
ist NICHT zwischen den beiden Telefonen erprobt.** Das ist die eine Sache, die
noch fehlt, und sie fehlt an einer albernen Stelle: siehe „Wo es hängt".

---

## Was jetzt in der App drin ist

Der ganze Weg steht: Bluetooth aussenden und suchen, Leuchtfeuer zuordnen,
GATT-Übertragung, Stückelung, Wegwahl beim Senden, Nah-Eingang beim Empfangen,
das Zeichen an der Nachricht, der Anwesenheitsschalter je Kontakt, und die
Oberfläche dazu.

**Relay zuerst, Nähe als Ausfallsicherung.** Zwei Schalter in den
Einstellungen, in dieser Reihenfolge: „Bluetooth benutzen" (der Weg) und „Nur
in der Nähe" (das Verbot). Ab Android 12 — darunter verlangt eine BLE-Suche
Standortzugriff, und die Berechtigung steht bewusst nirgends im Manifest.

---

## Was die Nacht gefunden und behoben hat

Drei Runden Widerlegung, jede gegen die Arbeit der vorigen.

### Runde 1 — am Relay (eingespielt)

- **Datenverlust:** eine live weitergereichte Nachricht ging ohne jede Zeile
  hinaus. Reißt die Leitung des Empfängers, existiert sie danach nirgends mehr,
  und der Absender hat sein Häkchen. Das Fenster war **zeitlich unbegrenzt**,
  weil der Server eine still gestorbene Verbindung nie bemerkt.
  → Jede Nachricht liegt jetzt erst in der Warteschlange, wird dann live
  geschickt und erst auf den Nachweis hin gelöscht. Für Gegenstellen **ohne**
  Nachweis bleibt alles beim Alten — sonst liefe ihre Warteschlange voll.
- **Ein Rahmen killte den Dienst:** der `empfangen`-Zweig baute die ganze
  Kennungsliste auf und schnitt sie erst danach ab. 16 MiB = 579 MiB Speicher,
  bei `MemoryMax=512M` also der OOM-Killer. → Vorher abschneiden, plus
  `--ws-max-size 262144` in der Unit.
- **`/register` ohne Gesamtgrenze:** gemessen 20,4 MiB in 30 Sekunden von einer
  IP, hochgerechnet 57 GiB am Tag, und `purge_expired` rührt diese Tabellen
  nie an. → Höchstens 200 Einmalschlüssel je Bündel, Dach von 50 000
  Identitäten (nur für **neue** Adressen — sonst wären die eigenen Nutzer die
  Bestraften).

### Runde 2 — am Wegwahl-Anschluss

- **Der zuletzt hinzugekommene Kontakt war für die Nähe unsichtbar.** Kontakte,
  die auf dem Empfangsweg entstehen, kamen nie in den Nahbereich. Ausgerechnet
  der, neben dem man am ehesten steht.
- **In „nur in der Nähe" gab es keinen Nachversand.** `_sendeUnversandtes`
  läuft nur aus `connect()`, und das kehrt dort sofort zurück. Eine
  liegengebliebene Nachricht blieb für immer auf „sending", auch wenn der
  Kontakt zurückkam. → Der Nahbereich meldet jetzt „jemand ist wieder da".
- **Regel 2 galt nur innerhalb eines Aufrufs.** Der Nachversand gab eine
  liegengebliebene Nachricht einer frischen Wegwahl, die frei wählte — sie ging
  über die Nähe raus und trug dann „DIREKT / kein Server war beteiligt",
  obwohl die Bytes im ersten Versuch schon abgeschickt waren. → Spalte
  `schon_beim_relay` (Schema v6).
- `holeAnhang` prüfte `nurNahbereich` gar nicht — ein Server-Kontakt unter
  einem Schalter, der das Gegenteil verspricht.
- Zwei Kontakte auf einem Gerät: der zweite war dauerhaft unerreichbar.

### Runde 3 — drei Funde eines Prüfers, der am Sitzungslimit starb

Er hinterließ drei Wegwerf-Proben. Alle drei scheiterten, also waren alle drei
echt. Sie stehen jetzt als `test/nah/nachtfunde_test.dart`:

- **A: Nach `lock()` funkte das Telefon weiter.** `lock()` hält den Nahbereich
  direkt an — absichtlich an der Warteschlange vorbei. Genau deshalb konnte das
  Anhalten mitten in `nah.starte(...)` fallen, und der Aufbau schaltete danach
  alles wieder ein. Ein gesperrtes Gerät, das seine Anwesenheit weiter in die
  Gegend ruft. → Prüfung nach dem Wartepunkt, wie beim Überholen in `connect()`.
- **B: Nach `declineRequest` lief das Leuchtfeuer für den Abgewiesenen weiter.**
  Von allen Kontakten der, bei dem es am wenigsten hingehört.
- **C: Regel 2 hatte keine Gegenrichtung.** Was in der Nähe mehrdeutig
  scheiterte, durfte danach über den Relay — dieselbe doppelte Zustellung,
  gespiegelt. → Spalte `schon_in_der_naehe` (Schema v7).

Alle drei Behebungen sind mit Mutationsprobe belegt: ohne sie wird der jeweilige
Test rot.

---

## Wo es hängt

### Korrektur: die Tipps gingen die ganze Zeit durch

Ich hatte hier zuerst geschrieben, das S10 nehme in BitDM keine künstlichen
Tipps an. **Das war falsch, und der Fehler lag in meinem Werkzeug.**

`baum()` rief `uiautomator dump /sdcard/ui.xml` und danach `cat` auf dieselbe
Datei. Scheitert der Dump — während einer Animation, bei einem Fensterwechsel —,
liefert `cat` stillschweigend **den Baum von vorhin**. Ich habe zehn Minuten
lang einen eingefrorenen Bildschirm angesehen und daraus geschlossen, der Tipp
täte nichts. In Wirklichkeit war das Telefon längst weitergelaufen; ein Tipp
hatte sogar einen Browser geöffnet, was ich ebenfalls nicht sah.

Dieselbe Sorte Fehler, hinter der ich die ganze Nacht her war: **eine Prüfung,
die aus dem falschen Grund gelingt.** Dass sie mir selbst passiert ist, während
ich sie bei anderen suche, gehört mit hierher.

`baum()` löscht die Datei jetzt vorher und meldet einen leeren Baum als Fehler
statt als Antwort; dazu gibt es `vordergrund()`, damit ein Tipp, der die App
verlässt, auffällt statt wie Wirkungslosigkeit auszusehen.

### Was danach übrig blieb

Mit dem reparierten Werkzeug lief B durch: Identität angelegt, Sperre
übersprungen, App auf dem Chat-Bildschirm. Der Ablauf steht jetzt an einer
anderen Stelle:

**B's Adresse ist über den UI-Baum nicht auslesbar.** Auf dem S25 stehen die
14 Vierergruppen als eigene Knoten im Baum (`ONLY FUDU SOOK …`), auf dem S10
enthält der MY-ID-Bildschirm nur fünf Elemente und keine einzige Gruppe. Ohne
B's Adresse kann A ihn nicht als Kontakt hinzufügen, und ohne Kontakt gibt es
kein Leuchtfeuer.

### Erledigt: die Beschriftung

`Semantics(label:)` mit `excludeSemantics: true` liegt jetzt über den
Adressgruppen (`main.dart`, `idScreen`). Das behebt einen echten Mangel und
nicht nur mein Testproblem: die Vierergruppen sind eine Lesehilfe für die
**Augen** — für einen Screenreader waren sie vierzehn zusammenhanglose
Häppchen, zwischen denen er jedes Mal neu ansetzt. Jetzt ist es eine Angabe.

Auf dem S25 lässt sich die Adresse damit sauber aus einem einzigen Knoten
lesen.

### Noch offen: B zeigt den Mittelteil nicht

Auf dem S10 fehlt im Bedienungsbaum des MY-ID-Bildschirms **alles zwischen
Kopfzeile und Navigationsleiste** — QR-Code, Adressgruppen und beide Knöpfe
(KOPIEREN, TEILEN). Sichtbar sind nur `MY ID`, der Untertitel und die drei
Reiter.

Was das ausschließt: es liegt **nicht** an der fehlenden Identität (der
Untertitel `myIdSub` erscheint nur im nicht-leeren Zweig, `idScreen` prüft das
in Zeile 1522) und **nicht** an der neuen Beschriftung (die hätte nur die
Gruppen betroffen, nicht QR und Knöpfe).

Was danach naheliegt: der `SingleChildScrollView` hat auf diesem Gerät die Höhe
null, oder der Dump greift, bevor der Inhalt gelegt ist. Beides ließe sich mit
einem Bildschirmfoto in einer Sekunde unterscheiden — **das geht hier nur
nicht, weil der Bildschirmfoto-Schutz greift** und ein schwarzes Bild liefert.
Der nächste Schritt ist deshalb: Schutz auf B einmal abschalten, hinsehen, und
danach wieder an.

Bis dahin gilt unverändert: **im Code geprüft, auf zwei Geräten nicht.**

Bis das erledigt ist, gilt: **im Code geprüft, auf zwei Geräten nicht.** Die
Funkstrecke selbst ist gestern auf genau diesen zwei Telefonen gemessen worden
(120 ms Auffindezeit, 700 Byte in 202 ms über GATT, kein Systemdialog) — was
fehlt, ist der Durchstich durch die echte App.

---

## Was ich bewusst nicht angefasst habe

- **Nichts von Runde 2 und 3 ist ausgeliefert.** Nur der Relay läuft mit dem
  neuen Stand; die App-Änderungen liegen lokal. Sicherungen auf dem VPS:
  `/root/relay_server.py.vor-27-07`, `/root/bitdm-sicherung/relay-27-07.db`,
  `/root/bitdm-relay.service.vor-27-07`.
- **`MessageStatus.failed` wird weiter nirgends gesetzt.** Regel 4 sagt
  „liegen", und mit dem Nachversand über die Nähe gibt es jetzt auch in „nur in
  der Nähe" einen Weg zurück. Ein Fehlerzustand wäre die falsche Antwort.
- **Die Karteileichen `panel.henrik.click` und `minecraft.henrik.click`** (502
  seit dem Miner-Vorfall, zeigen auf das entfernte Pelican) und
  `memory.henrik.click` (526, seit April abgeschaltet) — deine Entscheidung, ob
  weg oder auf AMP.
- **Elf mittlere und kleine Befunde** aus den Widerlegungen sind notiert, aber
  nicht behoben. Der ärgerlichste: `setzeStatus` kennt kein „nur vorwärts", der
  Nachversand kann also einen erreichten Haken zurückdrehen
  (Gelesen → Abgeschickt).

---

## Zwei Fallen, die Zeit gekostet haben

- **`scp` geht nicht auf den VPS** (kein SFTP), eine Röhre durch `ssh` schon.
  Der richtige Schlüssel ist `~/.ssh/Test`. Beim Durchprobieren der anderen
  weckt man fail2ban.
- **Release-Bau nach einem Gerätetest:** `GeneratedPluginRegistrant.java` trägt
  dann `integration_test`, das es im Release nicht gibt. `flutter pub get`
  schreibt dieselbe Datei wieder — nur `flutter clean` hilft. Steht jetzt im
  README, zusammen mit dem blockierten `build/` (`gradlew --stop`, **nicht**
  Prozesse abschießen: sonst stirbt adb mit).
