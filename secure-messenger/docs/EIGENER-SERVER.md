# Eigener Server — was beim Bauen herauskam

Am 26.07.2026 wurde die Einstellung „eigener Relay/eigenes Lager" gebaut, im
Emulator gegen einen Server auf dem Entwicklungsrechner bewiesen und danach
**wieder aus der App entfernt**. Sie war Mittel zum Zweck: ohne sie kann kein
Testlauf einen anderen Server als den echten ansprechen.

Dieses Dokument haelt fest, was dabei funktioniert hat und was nicht — damit
der Leitfaden fuer Nutzer, wenn die Einstellung zurueckkommt, nicht wieder bei
null anfaengt.

Der Code ist nicht verloren: er steht in der Versionsgeschichte. Was gebraucht
wird, ist unten in **Was wieder gebaut werden muss** aufgezaehlt.

---

## Was ein eigener Server ueberhaupt aendert

Das ist der Satz, mit dem jeder Leitfaden anfangen muss, weil sonst die
Haelfte der Leute ihn aus dem falschen Grund liest:

> Der Relay kann die Nachrichten **nicht** lesen — der mitgelieferte kann es
> auch nicht. Was sich mit einem eigenen aendert: niemand sonst sieht mehr,
> wer wann mit wem schreibt.

Verkehrsdaten, nicht Inhalte. Wer „eigener Server" als „jetzt erst richtig
verschluesselt" liest, trifft seine Entscheidung auf falscher Grundlage.

---

## Was funktioniert hat

**Die Ableitung des Lagers aus dem Relay.**
`relay.beispiel.de` → `dateien.beispiel.de`. Wer einen Relay betreibt,
betreibt fast immer das Lager daneben; ein zweites Pflichtfeld waere Arbeit
ohne Ertrag. Ein Relay ohne `relay.`-Vorsilbe (`10.0.2.2:8080`) bleibt, wie er
ist — das ist der Fall „beides auf demselben Rechner", und genau der kam im
Test vor.

**Zwei Felder, aber nur eines noetig.** Das Lager-Feld leer zu lassen ist der
Normalfall. Es steht trotzdem da, weil es Aufbauten gibt, bei denen das Lager
woanders liegt.

**Uebernehmen per Knopf, nicht bei jedem Tastendruck.** Jede Aenderung trennt
die Verbindung und baut sie neu auf. Bei `onChanged` waeren das zwanzig
Verbindungsabbrueche waehrend des Tippens.

**`http://` erlauben.** Ohne das ist ein Relay im Heimnetz oder im Emulator
(`10.0.2.2`) gar nicht erreichbar. Die Warnung erscheint **beim Tippen**, nicht
erst nach dem Uebernehmen — wer sie hinterher liest, hat schon umgestellt.

**Leeres Feld = Standard.** Wer das Relay-Feld leert und uebernimmt, will
zurueck. Dafuer muss er nicht erst den zweiten Knopf finden.

**Unfug faellt auf den Standard zurueck, statt die App zu zerlegen.** Die
Einstellung wird beim **Oeffnen** der App gelesen. Ein Absturz an dieser
Stelle waere der schlimmste denkbare Ausgang: der Nutzer kaeme nie wieder an
den Schalter heran, um seinen Tippfehler zu berichtigen.

---

## Was nicht funktioniert hat

### 1. Die App meldete sich beim neuen Server nicht an — und sagte nichts

**Der ernsteste Fund.** Im Emulator beobachtet: nach dem Umstellen verband
sich die App mit dem neuen Relay, und der schloss die Verbindung sofort wieder
— er kannte die Adresse nicht. Zu sehen war davon **nichts**: keine
Fehlermeldung, kein roter Punkt, nur eine Verbindung, die nicht zustande kam.

Ursache: Der Vermerk „ich bin angemeldet" (`relay_prekey_count` in der
`meta`-Tabelle) galt fuer **alle** Relays gemeinsam. Die App hatte sich beim
mitgelieferten angemeldet, hielt sich damit ueberall fuer angemeldet und
uebersprang die Anmeldung beim neuen.

Behoben: neben der Zahl steht jetzt eine zweite Zeile `relay_angemeldet_bei`
mit der Adresse. Fehlt sie, gilt der Vermerk fuer den aktuellen Relay — bis
dahin kannte die App nur einen einzigen, das ist keine Vermutung. Andernfalls
meldete sich mit dem naechsten Update jede bestehende Installation noch einmal
an, und jede Gegenstelle mit einem schon geholten Buendel liefe ins Leere.

**Diese Behebung ist geblieben, auch ohne die Einstellung.** Sie wird in dem
Moment gebraucht, in dem sich die Standardadresse jemals aendert.

### 2. Die Testidentitaeten landeten auf dem echten Relay

Der Weg durch das Onboarding verbindet, **bevor** man die Adresse umstellen
kann. Drei Testlaeufe hinterliessen drei Karteileichen auf `relay.bitdm.net`
(`2ul7…h3jt`, `tczz…jwkcp`, `yu72…cmy4`, alle vom 26.07.2026 zwischen 00:16
und 00:29).

Behelf im Testlauf: den Emulator mit `-dns-server 127.0.0.1` starten. Dann
scheitert jede Namensaufloesung, `10.0.2.2` ist aber eine Zahl und braucht
keine.

**Fuer den Leitfaden heisst das:** wer von Anfang an seinen eigenen Server
will, kommt mit der Einstellung in den Einstellungen zu spaet. Entweder gehoert
die Adresse ins Onboarding, oder der Leitfaden muss sagen, dass die erste
Anmeldung noch beim mitgelieferten Server landet.

### 3. Das Textfeld ist fuer Bedienhilfen unsichtbar

Ein Flutter-`TextField` taucht im `uiautomator`-Abzug **gar nicht** auf,
solange es leer ist. Steht etwas darin, erscheint es — aber in `text=` und
nicht in `content-desc`, umgekehrt zu allem anderen in dieser Oberflaeche.

Im Testlauf wird das Feld deshalb ueber die Beschriftung darueber getroffen
(rund 60 Pixel tiefer). Fuer einen blinden Nutzer heisst dasselbe: **das Feld
hat keine Beschriftung, die vorgelesen wird.** Wenn die Einstellung
zurueckkommt, gehoert ein `Semantics(label: …)` um beide Felder.

### 4. Die Tastatur verdeckt den Uebernehmen-Knopf

Nach dem Tippen steht der Knopf ausserhalb des sichtbaren Bereichs. `ESC`
(Tastencode 111) schliesst die Tastatur **nicht**, `ZURUECK` (Tastencode 4)
schon. Fuer die App heisst das: die Felder gehoeren in einen Bereich, der
mitscrollt, wenn die Tastatur aufgeht — oder der Knopf nach oben.

---

## Was der Leitfaden fuer Nutzer enthalten muss

1. **Wozu das gut ist** — der Absatz ganz oben. Verkehrsdaten, nicht Inhalte.
2. **Was man braucht**: einen Rechner mit fester Adresse, einen Namen darauf,
   ein Zertifikat. Der Relay selbst ist eine Python-Datei und ein
   systemd-Dienst; die Anleitung dafuer steht in `deploy/`.
3. **Dass alle Beteiligten denselben Relay brauchen.** Zwei Leute auf
   verschiedenen Servern koennen sich nicht schreiben. Das ist die haeufigste
   Enttaeuschung bei so einer Einstellung und gehoert in den ersten Absatz,
   nicht in eine Fussnote.
4. **Das Lager nicht vergessen.** Ohne Zwischenlager gehen Anhaenge nicht —
   und zwar mit einer Fehlermeldung, die nach einem Netzproblem aussieht.
5. **`http://` nur im eigenen Netz.** Mit der Begruendung, nicht als Verbot.
6. **Die Umzugsfalle**: alte Sitzungen laufen weiter, aber die Gegenstelle
   findet einen neuen Kontakt nur, wenn sie beim selben Relay ist.
7. **Wie man zurueckkommt** — Feld leeren, uebernehmen.

---

## Was wieder gebaut werden muss

Alles davon stand schon einmal und ist in der Versionsgeschichte zum
26.07.2026 zu finden:

| Stelle | Was |
|---|---|
| `lib/core/models.dart` | `AppPreferences.relayAdresse`, `.lagerAdresse`, `adresseTaugt()`, die `loesche…`-Schalter in `copyWith` |
| `lib/core/store/chat_repository.dart` | Ablage unter `pref_relay_adresse` / `pref_lager_adresse` |
| `lib/core/real_messenger_core.dart` | `aktiverRelay`, `aktivesLager`, Neuverbinden bei Aenderung |
| `lib/main.dart` | der Abschnitt zwischen `EIGENER SERVER (Anfang)` und `(Ende)` |
| `lib/data.dart` | die `ownServer*`-Texte in beiden Sprachen |

**Was NICHT wieder gebaut werden muss**, weil es geblieben ist:

- der Vermerk je Relay (`relay_angemeldet_bei`) — Punkt 1 oben
- `test/core/relay_wechsel_test.dart` — 5 Faelle, drei Mutationen geprueft;
  sichert die Anmeldung je Server ab, ohne dass es die Einstellung braucht
- `server/tools/testaufbau.py` — Relay und Lager auf dem eigenen Rechner
- `tools/geraet.ps1` — ein Emulator, bedienbar
- `tools/emulator_lauf.ps1` — ein Geraet, von der Installation bis zur Adresse
- `tools/durchstich_zwei_geraete.ps1` — zwei Geraete, bis zur zugestellten
  Nachricht

**Und was beim naechsten Mal anders sein sollte:**

- `Semantics(label:)` um die Felder (Punkt 3)
- die Adresse schon im Onboarding erreichbar (Punkt 2)
- die Felder mitscrollend, wenn die Tastatur aufgeht (Punkt 4)


---

## Nachtrag 26.07.2026: der Durchstich zwischen zwei Geraeten

`tools/durchstich_zwei_geraete.ps1` laeuft. Zwei Emulatoren, zwei
Installationen, Kontaktanfrage, Bestaetigung, Nachricht, Zustellquittung —
**134 Sekunden vom kalten Rechner bis zur gelesenen Nachricht auf dem zweiten
Geraet.** Der Weg lief ueber den echten `relay.bitdm.net`, weil es ohne die
Einstellung nicht anders geht; jeder Lauf hinterlaesst dort zwei
Karteileichen, deren Adressen am Ende des Berichts stehen.

Damit ist auch die letzte offene Frage aus der Werkzeugliste beantwortet: zwei
Emulatoren gleichzeitig gehen. Sie belegen zusammen rund 11 GB.

**Was dabei noch aufgefallen ist:**

- **Die Benachrichtigungsfreigabe schiebt sich vor die App.** In dem Moment,
  in dem die Kontaktanfrage ankommt, fragt Android danach — mit einem
  Systemdialog, der die Flutter-Oberflaeche vollstaendig verdeckt. Der Abzug
  zeigt dann 13 Knoten von `com.google.android.permissioncontroller` und kein
  einziges `content-desc`, was aussieht, als waere die App abgestuerzt. Behoben
  durch `pm grant … POST_NOTIFICATIONS` direkt nach der Installation.
- **Die Tastatur verschiebt den SEND-Knopf um tausend Pixel nach oben.** Wer
  ihn vor der Eingabe sucht und danach antippt, trifft die untere Leiste. Der
  Text bleibt im Feld stehen, und nichts sieht nach einem Fehler aus. Dieselbe
  Falle wie beim Uebernehmen-Knopf oben (Punkt 4) — sie ist offenbar die
  Regel und nicht die Ausnahme.
- **Der Bildschirm ADD CONTACT zeigt die Adresse des Gegenuebers ebenfalls**
  (unter PENDING). Wer dort nach der Unterhaltung sucht, findet sie, tippt auf
  einen nicht klickbaren Knoten und schreibt anschliessend ins Adressfeld. Erst
  zurueck zur Liste, dann suchen.
- **Ein zweiter AVD entsteht ohne `avdmanager`**, indem man `config.ini`,
  `userdata.img`, `encryptionkey.img` und `cache.img` kopiert und die
  `.ini` daneben anpasst. `userdata-qemu.img.qcow2` (2,8 GB) und `snapshots`
  (4 GB) NICHT mitkopieren — der Emulator legt sich beides frisch an, und
  genau das will man: ein sauberes zweites Geraet statt eines Abzugs des
  ersten.
