# Aufteilung von `app/lib/main.dart`

Stand 17.10.2026, Zweig `refactor/main-dart`, Basis `feat/libsignal-offiziell`
(`e9769f9`). **Phase 1: Plan.** Umgesetzt wird erst, wenn `fix/anhangknopf-pc`
und `feat/geraeteabmeldung` in der Basis sind. Vorher läuft nichts davon.

## Stand: Phase 2 umgesetzt (17.10.2026, nachts)

Zweig `refactor/main-dart-phase2` (lokal, nicht gepusht). Basis ist
`integration/kritik-2026-10-17`: `feat/libsignal-offiziell` mit
`fix/anhangknopf-pc`, `fix/linux-schluesselbund`, `feat/geraeteabmeldung`,
`feat/hinweis-veraltete-app`, `fix/nahbereich-anleitung` und
`fix/kontaktaufbau`. Umgesetzt hat das die koordinierende Sitzung, weil die
Planungssitzung keine Nachrichten mehr bekommen konnte.

| Ergebnis | |
|---|---|
| `main.dart` | 218 Zeilen (vorher 8 665): Start, `BitApp`, Relay-Ziele, Exporte |
| `oberflaeche/home.dart` | 714 Zeilen: `Home`, aller Zustand, Lebenszyklus, `_raeumeOberflaecheAuf`, `build` |
| `oberflaeche/home/*.dart` | 21 Teile, je 86–589 Zeilen |
| Tests | nach jedem Schritt vollständig grün (1 507), am Ende 1 511 mit C1/C3/C5/C7 |
| G2 | jeder Verschiebe-Commit „rein verschoben“ laut `tool/reine_verschiebung.py` |
| G3 | `tool/namen_pruefen.py` ohne Kollision |
| G4 | im Verschiebewerkzeug geprüft; die vier Tear-off-Methoden stehen in der Klasse |

Abweichungen vom Plan:

- **Schritt 1 nach den Verschiebungen geschrieben, aber in die Basis
  committet** (`fd208f8`). C1, C3, C5 und C7 waren jeweils in einer
  Mutationsprobe rot und laufen auf dem Stand VOR (Integration) und NACH der
  Aufteilung grün. Damit ist derselbe Nachweis erbracht. C2, C4 und C6 fehlen;
  teils decken `sprachnachricht_test`, `zurueck_test` und
  `fernloeschung_ui_test` das ab.
- **Vier unbenutzte Mitglieder bleiben in der Klasse:** `ephLabel`, `nowHm`,
  `zugriffsBlock`, `_uhr`. In einer privaten Extension meldete der Analyzer
  sie als unbenutzt; toten Code zu löschen ist keine Verschiebung. Eigener
  Aufräum-Commit.
- **Neue Mitglieder seit dem Plan:** `reqErgebnis` und `_starte` in die
  Klasse, `schluesselspeicherScreen` nach `sperre.dart`, `_geraeteStil` nach
  `bausteine.dart`. Vorher stand `_geraeteStil` zwischen Kommentar und
  Methode von `_hinweisKasten` (`6aef266` stellt das richtig).
- **Schritt 27 (Felder nach Modul ordnen) ist offen.**
- **Offen am Gerät:** eine Windows-Fassung starten und Anlegen, Sperren,
  Entsperren, Chat und Einstellungen durchklicken; dazu der Emulatorlauf.

## Ausgangslage

`main.dart` hat 8 540 Zeilen. Davon sind 7 982 (Zeile 559–8540) **eine einzige
Klasse**: `_HomeState`. Sie hat 54 Instanzfelder, 16 statische Mitglieder
und 210 Methoden und Getter. Davor liegen der Start
(`main()`, Relay-Ziele), `BitApp`, `bitThema`, `Einbrennschutz` und
`_Bedienbar`.

Die App wechselt Bildschirme über das Feld `screen` und nicht über den
Navigator. Ein einziges `setState` baut alles neu. Sperrzustand,
Lebenszyklus, Dialoge, Geheimnisanzeigen und gewöhnliche Bildschirme teilen
sich denselben Zustand. Wer prüfen will, was beim Sperren vergessen wird, muss
das in derselben Datei suchen, in der auch Umfragen und Themenwechsel stehen.

Die Tests sind Black-Box-Tests. 19 Testdateien und ein Integrationstest
importieren `main.dart`. Sie benutzen nur sechs Namen daraus: `BitApp`,
`Home`, `Einbrennschutz`, `anzeigeThema`, `zugriffsZeilen` und `zeilenArt`.
Alles andere läuft über die Oberfläche: Texte, `ValueKey`s, Tippen.

## Ziel und Grenze

**Es ändert sich, wo der Code steht, und nichts sonst.** Texte, Schlüssel,
Baumform der Widgets, Reihenfolge der Abläufe und Tests bleiben unverändert.
Inhaltlich angefasst wird nur dreierlei: neue Tests vor dem ersten
Verschieben (Schritt 1), ein `setState`-Override und die statischen
Mitglieder (Schritt 5, beides ohne Wirkung auf das Verhalten) und Kommentare,
die auf Zeilen in `main.dart` zeigen (letzter Schritt).

**Ehrliche Grenze.** Die Teildateien (`part`) bilden zusammen weiter *eine*
Dart-Bibliothek. Privater Zustand bleibt allen Teilen zugänglich. Der Gewinn
ist Ordnung nach Verantwortung:

- Dateien von 80 bis 680 Zeilen, jede mit einer Aufgabe.
- Die sicherheitsrelevanten Teile (Sperre, Faktoren, Notfall, Geheimnisanzeige,
  Prüfnummer) lassen sich einzeln lesen und einzeln prüfen.
- Der gesamte Zustand und seine Aufräumregeln stehen an einer Stelle.

Echte Kapselung wäre ein Umbau: eigene Widgets mit eigenem Zustand für Sperre
und Chat, die Sperrlogik in einer eigenen Steuerklasse. Damit ändert sich die
Baumform, und `fenster_abfolge_test` hält genau die fest („DIE BAUMFORM
BLEIBT …“). Das ist eine eigene Phase mit eigenem Risiko (siehe „Danach“) und
nicht Teil dieses Auftrags.

## Technik: `part`-Dateien mit `extension on _HomeState`

| Weg | Was er kostet | Urteil |
|---|---|---|
| **A** `part` + `extension _X on _HomeState` | Methoden ziehen Zeichen für Zeichen um. Die Einrückung bleibt bei zwei Leerzeichen. Die Felder bleiben in der Klasse. | **gewählt** |
| B `part` + Mixins auf gemeinsamer Basisklasse | 120 Mitglieder werden über Modulgrenzen benutzt, dazu 54 Mitglieder des Kerns (Felder, `st`, `t`). Jede Mixin bräuchte abstrakte Gegenstücke, rund 170 zusätzliche Deklarationen. Das ist keine reine Verschiebung mehr. | verworfen |
| C eigene Widgets und Bibliotheken für `_HomeState`-Teile | Ändert Zustand, Lebenszyklus, Fokus und Baumform. | erst in einer späteren Phase |

Freistehende Klassen werden dagegen echte Bibliotheken (`Einbrennschutz`,
`bitThema`/`anzeigeThema`), weil sie nichts aus `_HomeState` brauchen.

### Vier Fallen von Weg A, am 17.10.2026 nachgemessen

Gemessen mit Dart aus Flutter 3.44.8, an Probedateien außerhalb des Repos.

1. **`setState` aus einer Extension gibt eine Warnung**
   (`invalid_use_of_protected_member`). Die CI bricht bei Warnungen ab
   (`flutter analyze --no-fatal-infos`, ci.yml). **Lösung:** `_HomeState`
   überschreibt `setState` einmal, nur mit `super.setState(fn)`, und mit einem
   Kommentar, warum. Danach meldet der Analyzer nichts mehr (Probe: „No issues
   found“). Die Aufrufstellen bleiben `setState(...)`.
2. **Tear-offs von Extension-Methoden sind jedes Mal neue Objekte.**
   `a.f == a.f` ergibt dann `false`, bei Klassenmethoden `true`. Ein
   `removeListener(_aktualisiere)` entfernte damit still nichts. Ebenso
   verglich `dispose` vergeblich `st.frageOhneBereinigung == _frageMetadaten`.
   **Deshalb bleiben in der Klasse:** `_aktualisiere`, `_fokusNachfassen`,
   `_frageMetadaten`, `_wechselTakt`. Das sind alle vier, die in
   `addListener`/`removeListener` oder einem `==` stehen (per grep
   vollständig erfasst).
3. **In einer Extension gewinnt ein gleichnamiger Top-Level-Name gegen das
   Klassenmitglied.** Das gilt auch für importierte Namen, und es passiert
   still, wenn die Signatur passt. In der Probe lieferte `t('x')` in der
   Klasse das Mitglied, in der Extension die Top-Level-Funktion. **Heute gibt
   es keine einzige Kollision.** Geprüft sind alle 280 Mitgliedsnamen gegen
   die Top-Level-Namen in `lib/`, Flutter, `path_provider`, `url_launcher`,
   `dart:core` und `dart:async`. Die Prüfung wird Pflicht vor jedem Schritt
   (Gate G3), weil ein neuer Import das ändern kann.
4. **Statische Mitglieder der Klasse sind in einer Extension nicht
   unqualifiziert erreichbar.** Das ist ein Compilerfehler, also wenigstens
   laut. **Lösung:** Die 16 statischen Mitglieder werden einmal in einem
   eigenen Schritt zu Top-Level-Deklarationen (gleicher Name, ohne `static`).
   Danach ziehen sie mit ihrem Modul um.

Außerdem bleiben in der Klasse: alle `@override`s (`initState`, `dispose`,
`didChangeAppLifecycleState`, `build`), weil Extensions nichts überschreiben
können, und alle Felder, weil Extensions keine haben können.

## Zielaufbau

```
app/lib/
  main.dart                     ~220  Start: Tresor, Kern, AppState, Push, runApp;
                                      BitApp; Relay-Ziele (BITDM_RELAY …)
  oberflaeche/
    app_thema.dart              ~135  anzeigeThema, bitThema          (eigene Bibliothek)
    einbrennschutz.dart          ~80  Einbrennschutz                  (eigene Bibliothek)
    home.dart                   ~680  Home, _HomeState: ALLER Zustand, Lebenszyklus,
                                      Sperr-/Lösch-Aufräumen, build, part-Liste
    home/
      bedienbar.dart             ~80  _Bedienbar, _aktivierung
      rahmen.dart               ~250  Fenster, Telefonbreite, Schreibtischgerüst
      tastatur.dart             ~225  Tastenfang, Fokus, Strg+Eingabe, Hauptknopf
      navigation.dart           ~240  go, Zurück-Ziele, Reiter, buildScreen, buildNav
      thema.dart                ~175  Palette, Schriften, Themenwechsel, Wandern
      bausteine.dart            ~540  Knöpfe, Karten, Hinweiskästen, Zeit-/Fristtexte
      sperre.dart               ~355  Sperrbildschirm, Entsperren, frische Anmeldung,
                                      Geheimnisabfrage, Stick-PIN
      zugriff.dart              ~590  Faktoren einrichten/entfernen, Sperrfrist,
                                      Zugriffsbildschirm, zugriffsZeilen, zeilenArt
      notfall.dart              ~340  Panik-Passwort, Alles löschen, Fernlöschung, Codewort
      identitaet.dart           ~500  Anlegen, zwölf Wörter, Identität, Adresse kopieren
      wiederherstellung.dart    ~320  Wiederherstellen, Teilgeheimnisse
      verschluesselung.dart     ~140  Schloss-Blatt: Prüfnummer, Frist, Anwesenheit
      chatliste.dart            ~550  Liste, Filter, Suche, Anfragen, Update-Karte
      kontakt_neu.dart          ~150  Hinzufügen, QR-Scan
      gruppen.dart              ~420  Gruppen, Verteiler, Zustellung
      unterhaltung.dart         ~535  Chatbildschirm, Eingabe, Senden, Planen, Bildlauf
      nachricht.dart            ~345  Blase, Reaktionen, Nachrichtenmenü, Widerruf
      befehle.dart              ~325  /-Befehle, Erwähnungen, Plus-Menü, Umfragen
      anhaenge.dart             ~480  Anhänge, Bilder, Einmal-Ansicht, Sprachaufnahme
      einstellungen.dart        ~515  Einstellungsbildschirm, Empfangstakt, Ruhezeit,
                                      Push-Hilfe
      nahbereich.dart           ~455  Nahbereich-Block, Funkrechte, Nah-Hilfe,
                                      Verbindungstest
```

Die Zeilenzahlen sind am Stand `e9769f9` gemessen, mit Kommentaren. Nach dem
Zusammenführen der beiden Zweige ändern sie sich etwas.

`main.dart` exportiert weiter genau die sechs Namen, die Tests und
`integration_test` benutzen:

```dart
export 'oberflaeche/home.dart' show Home, zugriffsZeilen, zeilenArt;
export 'oberflaeche/app_thema.dart' show anzeigeThema, bitThema;
export 'oberflaeche/einbrennschutz.dart';
```

### Zuordnung der Mitglieder

Die vollständige Liste liegt als Skript bei (siehe „Werkzeuge“). Kurzform,
was bewusst wohin kommt:

| Modul | Mitglieder (Auswahl) | Sicherheitsbezug |
|---|---|---|
| `home.dart` | alle Felder, `initState`, `dispose`, `didChangeAppLifecycleState`, `_aktualisiere`, `_raeumeOberflaecheAuf`, `_setzeMeldetexte`, `build` (Screenshot-Schutz der zwölf Wörter), `t`, `setState`-Override, die vier Tear-off-Methoden | **hoch**: was beim Sperren, Löschen und Verdecken passiert |
| `sperre.dart` | `gesperrtScreen`, `_versucheEntsperren`, `frischBestaetigt`, `_mitStickPin`, `_frageGeheimnis`, `_stickMeldung`, `_wegKnopf` | **hoch**: Entsperren und frische Anmeldung |
| `zugriff.dart` | `methodAct`, `_richteKeystoreEin`, `_entferneFaktor`, `_setzeSperrfrist`, `_passwortAnlegen`, `_stickAnlegen`, `secureScreen`, `methodRow`, `enrollModal`, `passwortModal`, `stickModal` | **hoch**: Faktoren und Sperrfrist |
| `notfall.dart` | `_richtePanikPasswortEin`, `panicModal`, `doWipe`, `fernBanner`, `_richteFernloeschungEin`, `_richteCodewortEin`, `_entferneCodewort` | **hoch**: zerstörende Wege |
| `identitaet.dart` | `doCreate`, `onboardScreen`, `phraseScreen`, `idScreen`, `_zeigeWoerter`, `_kopiereGeheim` + `ablageFrist` | **hoch**: zeigt Geheimnisse |
| `wiederherstellung.dart` | `_stelleWieder`, `wiederherstellenScreen`, `_erzeugeTeile`, `_sendeTeil` | **hoch**: zeigt und nimmt Geheimnisse |
| `verschluesselung.dart` | `encSheet`, `_ladePruefnummer`, Frist und Anwesenheit je Unterhaltung | mittel: Prüfnummer |
| `anhaenge.dart` | Einmal-Ansicht, Bildanzeige, Aufnahme (`_verwirfAufnahme`), Anhangwahl | mittel: Einmal-Ansicht, Mikrofon |
| übrige | Darstellung, Navigation, Listen, Einstellungen | niedrig |

`frischBestaetigt` ist das Tor vor jeder folgenreichen Handlung. Es wird aus
fünf Modulen gerufen: `zugriff`, `notfall`, `identitaet`,
`wiederherstellung`, `einstellungen`. Wer die Sperre prüft, liest `home.dart`,
`sperre.dart` und `zugriff.dart` und sucht in den übrigen nach
`frischBestaetigt`.

### Abhängigkeiten

Alle Teile hängen am Kern (Felder, `st`, `t`). Fast alle hängen an `thema`
(`p`, `mono`, `doto`) und `bausteine`. Sonst sind es wenige Querbezüge
zwischen Fachmodulen, gezählt am Stand `e9769f9`:

- `sperre` braucht aus Fachmodulen nur `zugriff` (`_faktorGehtHier`).
- `zugriff` braucht `sperre` (`frischBestaetigt`, `_mitStickPin`,
  `_stickMeldung`, `_wegKnopf`).
- `notfall`, `identitaet` und `wiederherstellung` brauchen `sperre`
  (`frischBestaetigt`).
- `navigation.buildScreen` ruft jeden Bildschirm, `einstellungen` ruft
  `notfall`, `zugriff`, `identitaet` und `wiederherstellung`.

Weil alle Teile zu einer Bibliothek gehören, gibt es keine Importreihenfolge
und keine Zyklen, die aufzulösen wären. Die Reihenfolge der Schritte richtet
sich nach dem Risiko und nach der Prüfbarkeit, nicht nach Abhängigkeiten.

## Verhalten absichern

### Was schon abgedeckt ist

- `sperre_oberflaeche_test`: Sperren schließt fremde Dialoge, die zwölf
  Wörter nur nach frischer Anmeldung und unter Screenshot-Schutz,
  Stick-PIN-Wiederholung, Panik-Satz, Codewort nur nach frischer Anmeldung.
- `sperre_zustand_test`: was der AppState beim Sperren und Löschen vergisst,
  frische Anmeldung, Einmal-Ansicht während der Sperre, „Verdeckt“ auf
  Zustandsebene.
- `vier_faktoren_test`: Faktoren getrennt, `zeilenArt`/`zugriffsZeilen`.
- `zurueck_test`: Zurück-Geste auf Liste, Einstellungen, Chat.
- `fenster_abfolge_test`: Tastenfang, Fokus, Escape, Baumform im Fenster.
- `fernloeschung_ui_test`, `sprachnachricht_test`, `themen_test`,
  `autoscroll_test`, `nachricht_menue_test`, `befehle_test` und weitere
  Oberflächentests.

### Lücken: Charakterisierungstests vor dem ersten Verschieben

Kein Test schickt der Oberfläche einen Lebenszyklus-Wechsel. Kein Test prüft,
was `_raeumeOberflaecheAuf` mit den *eigenen* Überlagerungen und Feldern macht
oder was nach dem Abbau von `Home` am AppState hängen bleibt. Genau das ist der
Teil, auf den der Kritiker zeigt. Neue Datei
`test/oberflaeche/home_lebenszyklus_test.dart`, grün am **unveränderten**
Code:

| Nr. | Test | hält fest |
|---|---|---|
| C1 | VERDECKEN SPERRT, EIN SYSTEMDIALOG NICHT | Passwort-Faktor, Sperrfrist 0. `inactive` → `resumed` lässt die App offen (Fingerabdruck-Dialog-Fall). `inactive` → `hidden` → `paused` → … → `resumed` sperrt. Gefahren über `tester.binding.handleAppLifecycleStateChanged` in echter Reihenfolge. |
| C2 | VERDECKEN BEENDET EINE LAUFENDE AUFNAHME | Kanal `bitdm/sprache` wie in `sprachnachricht_test`. Nach `paused` bekommt der Kanal `verwirf` und kein `stoppe`. Es geht nichts hinaus, die Aufnahmeanzeige ist weg. |
| C3 | SPERREN RÄUMT AUCH DIE EIGENEN ÜBERLAGERUNGEN AUF | Passwortblatt offen, Felder gefüllt, Suche gefüllt, Schloss-Blatt offen → sperren → entsperren: kein Blatt, alle Felder leer, Prüfnummer vergessen. |
| C4 | GESPERRT BEENDET DIE ZURÜCK-GESTE HÖCHSTENS | Gesperrt: `zurueckWaechter.canPop == true`. Escape im Fenster öffnet nichts. |
| C5 | NACH DEM ABBAU HÄNGT HOME NICHT MEHR AM ZUSTAND | `pumpWidget(SizedBox())` → `st.frageOhneBereinigung == null` und `st.hasListeners == false`. Dafür wird `@protected` im Test mit Begründung erlaubt. |
| C6 | LÖSCHEN VON AUSSEN SETZT FILTER UND ARCHIV ZURÜCK | Filter „ungelesen“ und Archiv an → `st.allesLoeschen()` ohne Knopf → Anfang. Neue Identität → Filter „alle“, kein Archiv. |
| C7 | SPRACHWECHSEL ERREICHT DIE BENACHRICHTIGUNGSTEXTE | Sprache `de` → `st.einNeuText` ist deutsch. |

**Mutationsprobe (wird nicht committet).** Jeder neue Test muss einmal rot
gewesen sein:

- `_frageMetadaten` und `_aktualisiere` testweise in eine Extension ziehen:
  C5 muss rot werden.
- `inactive` testweise in den Zweig von `paused` legen: C1 muss rot werden.
- Eine Zeile aus `_raeumeOberflaecheAuf` auskommentieren: C3 muss rot werden.

Bleibt ein Test grün, ist er zu schwach und wird nachgeschärft, bevor es
weitergeht.

### Gates nach jedem Schritt

| Gate | Prüfung |
|---|---|
| G1 | `flutter analyze --no-fatal-infos` ohne Befund, genau wie die CI |
| G2 | **Reine Verschiebung:** Jede hinzugefügte Zeile ist eine entfernte Zeile, zeichengleich, und umgekehrt. Ausgenommen sind nur Gerüstzeilen: `import`, `export`, `part`, `part of`, `extension _X on _HomeState {`, die schließende `}`, der Dateikopf-Kommentar einer neuen Datei und Leerzeilen. Geprüft mit `tool/reine_verschiebung.py <commit>`. Gilt für jeden Schritt außer 0, 1, 2, 5 und 28. |
| G3 | **Namen:** Kein verschobenes Mitglied heißt wie ein Top-Level-Name der Bibliothek oder ihrer Importe oder wie ein geerbtes Mitglied von `State`, `WidgetsBindingObserver` und `TickerProviderStateMixin`. |
| G4 | **Identität:** Die vier Tear-off-Methoden stehen weiter in der Klasse. `addListener`/`removeListener`/`==` mit Methodennamen kommen nur mit ihnen vor. |
| G5 | `C:\flutter\bin\flutter.bat test`, **vollständig grün**. Vorher in einem eigenen Befehl prüfen, ob gespielt wird (BeamNG, `javaw` …). Wenn ja, läuft der Testlauf auf dem Mini-PC (CT 107, Ablauf in der Mini-PC-Übergabe, Nachtrag 17.10.). |

Kein `dart format` auf verschobene Dateien: es würde die Zeichengleichheit
brechen, und G2 sähe dann jede Zeile als neu.

## Schritte (Phase 2)

Jeder Schritt ist ein Commit, jeder einzeln grün.

| Nr. | Inhalt | Art | Gates |
|---|---|---|---|
| 0 | Basis prüfen: `fix/anhangknopf-pc`, `feat/geraeteabmeldung`, `fix/kontaktaufbau` und `fix/nahbereich-anleitung` sind in `feat/libsignal-offiziell` (Henrik führt zusammen; geprüft mit `git merge-base --is-ancestor`). `refactor/main-dart` auf die neue Basis setzen. Zuordnungsskript neu laufen lassen, neue Mitglieder (Geräteabmeldung, Anhangknopf) zuordnen und diesen Plan nachtragen. | Doku | – |
| 1 | Charakterisierungstests C1–C7 und Mutationsprobe | Test | G1, G5 |
| 2 | `tool/reine_verschiebung.py` und `tool/namen_pruefen.py` (G2/G3 als Skript) | Werkzeug | G1 |
| 3 | `Einbrennschutz` nach `oberflaeche/einbrennschutz.dart`, `anzeigeThema` und `bitThema` nach `oberflaeche/app_thema.dart`. `main.dart` exportiert sie. | Verschiebung + Import/Export | G1–G5 |
| 4 | `Home`, `_HomeState`, `zugriffsZeilen`, `zeilenArt`, `_Bedienbar` und `_aktivierung` nach `oberflaeche/home.dart`. In `main.dart` bleiben Start, `BitApp` und Relay-Ziele. `home.dart` bekommt genau die Importe, die es braucht; der Analyzer meldet sonst `unused_import`. | Verschiebung + Import/Export | G1–G5 |
| 5 | **Vorbereitung, der einzige Schritt mit Eingriff in Zeilen:** (a) `setState`-Override mit Kommentar, (b) die 16 statischen Mitglieder werden Top-Level-Deklarationen: `static` fällt weg, zwei Leerzeichen Einrückung weniger, Kommentare ziehen mit. Rund 160 Zeilen, einzeln lesbar. | Vorbereitung | G1, G3–G5 |
| 6 | `home/bedienbar.dart` | Verschiebung | G1–G5 |
| 7 | `home/rahmen.dart` (mit ihren Top-Level-Konstanten) | Verschiebung | G1–G5 |
| 8 | `home/thema.dart` | Verschiebung | G1–G5 |
| 9 | `home/bausteine.dart` | Verschiebung | G1–G5 |
| 10 | `home/sperre.dart` | Verschiebung, **Sicherheit** | G1–G5 |
| 11 | `home/zugriff.dart` (mit `zugriffsZeilen`, `zeilenArt`) | Verschiebung, **Sicherheit** | G1–G5 |
| 12 | `home/notfall.dart` | Verschiebung, **Sicherheit** | G1–G5 |
| 13 | `home/identitaet.dart` | Verschiebung, **Sicherheit** | G1–G5 |
| 14 | `home/wiederherstellung.dart` | Verschiebung, **Sicherheit** | G1–G5 |
| 15 | `home/verschluesselung.dart` | Verschiebung | G1–G5 |
| 16 | `home/chatliste.dart` | Verschiebung | G1–G5 |
| 17 | `home/kontakt_neu.dart` | Verschiebung | G1–G5 |
| 18 | `home/gruppen.dart` | Verschiebung | G1–G5 |
| 19 | `home/unterhaltung.dart` | Verschiebung | G1–G5 |
| 20 | `home/nachricht.dart` | Verschiebung | G1–G5 |
| 21 | `home/befehle.dart` | Verschiebung | G1–G5 |
| 22 | `home/anhaenge.dart` | Verschiebung | G1–G5 |
| 23 | `home/einstellungen.dart` | Verschiebung | G1–G5 |
| 24 | `home/nahbereich.dart` | Verschiebung | G1–G5 |
| 25 | `home/tastatur.dart` | Verschiebung | G1–G5 |
| 26 | `home/navigation.dart` | Verschiebung | G1–G5 |
| 27 | Felder in `_HomeState` nach Modul ordnen, mit Abschnittsüberschriften. Die Felder, die Geheimnisse halten (`pwCtl`, `pwCtl2`, `stickPinCtl`, `phraseCtl`), stehen dann zusammen neben `_raeumeOberflaecheAuf`. Nur Umordnung in der Datei. Die Initialisierer hängen nicht voneinander ab; der einzige abhängige, `_thema`, ist `late`. | Verschiebung in der Datei | G1–G5 |
| 28 | Doku: Layout in `README.md` und `README.de.md` (neu gemessene Zahlen), `DESIGN.md` (Verweis auf `main.dart`), Kommentare mit `main.dart:<Zeile>` in `lib/` und Testkommentare, die auf `main.dart` zeigen. Nur Kommentare und Text. Datierte Befund-Dokumente (`BEFUNDE-2026-07-26.md`, `MEHRGERAETE.md`) bleiben unverändert. Zum Schluss „Stand“ in diesem Dokument. | Doku | G1, G5 |

Danach einmal am Gerät: eine Windows-Fassung starten und die Abläufe Anlegen,
Sperren, Entsperren, Chat und Einstellungen durchklicken. Dazu der
Emulatorlauf (`tools/emulator_lauf.ps1`), wenn der PC frei ist. Unit- und
Widget-Tests sehen keinen echten Lebenszyklus.

**Aufbau einer Teildatei** (Schritt 6 ff.):

```dart
// sperre.dart — Sperrbildschirm, Entsperren und frische Anmeldung.
//
// Teil von home.dart (part). Der Zustand (lockFehler, pwCtl, stickPinCtl …)
// steht in _HomeState; was beim Sperren vergessen wird, regelt
// _raeumeOberflaecheAuf dort.
part of '../home.dart';

extension _Sperre on _HomeState {
  <Mitglieder, zeichengleich aus home.dart>
}
```

## Nachweis für Gegenleser

- `git show --color-moved=dimmed-zebra --color-moved-ws=no <commit>` zeigt
  einen Verschiebe-Commit fast ganz als verschoben. Neu sind nur die
  Gerüstzeilen.
- `python tool/reine_verschiebung.py <commit>` bestätigt das maschinell. Es
  läuft auch über eine Spanne (`<von>..<bis>`).
- `git blame -C -C oberflaeche/home/sperre.dart` führt jede Zeile auf ihren
  ursprünglichen Commit in `main.dart` zurück.
- Inhaltlich geändert wird nur in Schritt 1 (neue Tests), 5
  (`setState`-Override, statische Mitglieder) und 28 (Kommentare und Doku).

## Was vor Phase 2 zu entscheiden ist

1. **Zwei weitere Zweige ändern `main.dart` und sind nicht in der Basis:**
   - `fix/kontaktaufbau` (`b7eb341`, +56/−20): `sendReq`, `addScreen`,
     Nahbereich-Block, ein neues Feld.
   - `fix/nahbereich-anleitung` (`2887796`, +7/−5): `nahHilfeScreen`.

   Kommen sie nach der Aufteilung, kann git den Verschiebungen nicht folgen,
   und die Änderungen müssen von Hand in die neuen Dateien.
   **Entschieden (Henrik, 17.10.2026):** Beide kommen vor Phase 2 mit in die
   Basis, zusammen mit `fix/anhangknopf-pc` und `feat/geraeteabmeldung`.
   Schritt 0 prüft, dass alle vier drin sind.
2. **Keine parallele Arbeit an der Oberfläche während Phase 2.** Jeder Zweig,
   der in der Zeit `main.dart` ändert, bekommt dieselben Konflikte. Am besten
   läuft Phase 2 in einem Zug.
3. **Die Prüfskripte kommen ins Repo** (`app/tool/`, wie `tool/symbol/`),
   damit ein Gegenleser G2 und G3 selbst laufen lassen kann. Wer sie nicht
   öffentlich will, sagt es; dann bleiben sie lokal.

## Danach (nicht Teil dieses Auftrags)

Echte Kapselung, Schritt für Schritt, jeweils mit eigenem Plan:

- Die Sperrlogik (`_versucheEntsperren`, `frischBestaetigt`, `_mitStickPin`)
  wandert in eine Steuerklasse ohne `BuildContext`. Dann lässt sie sich ohne
  Widget-Test prüfen.
- `gesperrtScreen` wird ein eigenes Widget mit eigenem Zustand. Die
  Baumform-Tests im Fenster werden dafür bewusst angepasst.
- `settingsScreen` (385 Zeilen in einer Methode) und `chatScreen` (300) werden
  in Abschnitte zerlegt.

## Werkzeuge der Planung

Die Zahlen oben stammen aus drei Skripten, abgelegt im gemeinsamen
Notizordner der Sitzungen (`maindart-aufteilung/`):

- `glieder.py` erfasst die Mitglieder von `_HomeState`, ihre Zeilenbereiche
  samt Kommentarblock und die Bezüge zwischen ihnen. Kommentare und
  Zeichenketten sind dabei herausgefiltert.
- `module.py` enthält die Zuordnung Mitglied → Modul, misst die Größen und
  zählt die Querbezüge.
- `kollision.py` prüft Gate G3 gegen `lib/` und die Pakete.

In Schritt 0 laufen sie auf der zusammengeführten Basis neu, in Schritt 2
werden G2 und G3 daraus zu den Werkzeugen im Repo.
