# Textvorschlag: Anhangknopf am PC (für Webseite und README)

Stand 17.10.2026, Zweig `fix/anhangknopf-pc`. Gehört zur Fassung **2.0.0**.

**Erst mit der Veröffentlichung von 2.0.0 einspielen.** Bis dahin ist der
heutige Text auf bitdm.net für die veröffentlichte 1.9.1 richtig: dort tut
„Datei anhängen“ am PC wirklich nichts.

## Worum es geht

Ein Kritiker von außen hat bemängelt, dass in BitDM am PC ein sichtbarer
Anhangknopf keinen Dateidialog öffnet; die Webseite räumte es selbst ein.
Ursache: `Dateien.waehlen()` sprach nur den Android-Kanal `bitdm/dateien` an,
fing am PC die `MissingPluginException` und gab still `null` zurück. Seit
2.0.0 tragen die Startprogramme für Windows und Linux denselben Kanal
(`app/windows/runner/datei_kanal.cpp`, `app/linux/runner/datei_kanal.cc`).
Im Browser ist der Menüpunkt ausgegraut und nennt den Grund.

| Plattform | „Datei anhängen“ | Empfangenen Anhang öffnen |
|---|---|---|
| Android | Dialog des Systems (wie bisher) | wie bisher |
| Windows | Dialog des Systems, Originaldatei, keine Kopie | erst durch die Anhangprüfung von Windows (Markierung „aus dem Internet“, Virenscanner), dann Standardprogramm; HTML/SVG/Skripte als Text |
| Linux | GTK-Dialog (in Flatpak/Snap über das Portal) | Standardprogramm; HTML/SVG/Skripte an das Programm für Text |
| Browser | ausgegraut, mit Grund | — (keine Anhänge im Browser) |

## 1. Webseite `secure-messenger/website/index.html`

Auf `main` nicht geändert. Dieselbe Zeile und derselbe Hinweis stehen auch in
den Testseiten `_test-startseite.html` und `_test-ganze-seite.html`.

### Liste „Was am PC geht“ (`<ul class="sees">`)

Die Zeile wechselt von `no` zu `yes` und rückt hinter „App-Passwort als
Sperre“, damit die grünen Zeilen zusammenstehen.

Heute:

```html
<li class="no"><span class="what de">Anhänge aussuchen und öffnen</span><span class="what en">Choosing and opening attachments</span><span class="verdict de">nur Android</span><span class="verdict en">Android only</span></li>
```

Neu:

```html
<li class="yes"><span class="what de">Anhänge aussuchen, schicken und öffnen</span><span class="what en">Choosing, sending and opening attachments</span><span class="verdict de">auch am PC</span><span class="verdict en">on the PC too</span></li>
```

### Hinweis darunter (`<p class="hint">`)

```html
<p class="hint">
  <span class="de">Ohne Push bleibt am PC die Verbindung offen, solange die
    App läuft; ein Weckdienst von außen wird dort nicht gebraucht. Den
    Anhangknopf gab es am PC schon früher, aber bis Fassung 1.9.1 öffnete er
    kein Auswahlfenster. Seit 2.0.0 öffnet er unter Windows und Linux den
    Dateidialog des Systems. Im Browser ist er ausgegraut und nennt den
    Grund.</span>
  <span class="en">Without push, the connection on the PC stays open as long
    as the app runs, so no external wake-up is needed there. The attach button
    was on the PC before, but up to version 1.9.1 it opened no file dialog.
    Since 2.0.0 it opens the system's file dialog on Windows and Linux. In the
    browser it is greyed out and says why.</span>
</p>
```

### Fundstellen-Kommentar über der Liste, Punkt 8

```
8 Anhaenge        — Kanal bitdm/dateien: Android core/dateien.dart +
                    DateiKanal.kt, Windows windows/runner/datei_kanal.cpp,
                    Linux linux/runner/datei_kanal.cc (seit 2.0.0). Im
                    Browser grau mit Grund: DateiWahl.auswahlFehlt,
                    main.dart plusMenue. Bis 1.9.1 tat der Knopf am PC
                    nichts (waehlen() fing die MissingPluginException).
```

### Was gleich bleibt

Die Web-Karte („Anhänge, Sprachnachrichten und der Nahbereich fehlen“) stimmt
weiter.

## 2. README

Auf diesem Zweig schon eingetragen, jeweils als Absatz nach der
Plattformtabelle. Mit `main` zusammen erscheint er erst, wenn der Zweig
zusammengeführt wird.

`README.md`:

> Attachments went the other way, and only in 2.0.0. Until 1.9.x "Attach file"
> was visible on the PC and did nothing: the file picker was Android-only, and
> the call failed silently. Since 2.0.0 the Windows and Linux runners carry the
> same channel (`windows/runner/datei_kanal.cpp`, `linux/runner/datei_kanal.cc`),
> so choosing, sending and opening files works there too. In the web build the
> entry is greyed out and says why.

`README.de.md`:

> Bei den Anhängen ging es andersherum, und erst mit 2.0.0. Bis 1.9.x stand
> „Datei anhängen“ am PC da und tat nichts: die Dateiauswahl gab es nur unter
> Android, und der Aufruf scheiterte still. Seit 2.0.0 tragen die
> Startprogramme für Windows und Linux denselben Kanal
> (`windows/runner/datei_kanal.cpp`, `linux/runner/datei_kanal.cc`); Dateien
> aussuchen, schicken und öffnen geht dort also auch. In der Web-Fassung ist
> der Menüpunkt ausgegraut und sagt, warum.

Achtung beim Zusammenführen: Der Zweig `docs/linux-lauf` ändert dieselben
zwei Dateien in der Nähe (Zeile „Linux“ der Plattformtabelle).

## 3. Warum der Browser ausgegraut bleibt und nicht funktioniert

Abgewogen nach „technisch stärkste Lösung“. Ein Dateidialog im Browser wäre
leicht — die App öffnet für „Sicherung einspielen“ schon ein
`<input type=file>` (`core/browser/browser_zugang_web.dart`). Aber danach käme nichts an:

- Versand, Empfang, Lager-Client und verschlüsselte Ablage sind auf `dart:io`
  gebaut (`core/anhang/anhang_versand.dart`, `anhang_empfang.dart`,
  `lager_client.dart`, `ruhe_datei.dart`). Im Browser gibt es weder Dateien
  noch einen Ordner für die Ablage; das hieße Blob-Stücke, `fetch` und
  IndexedDB/OPFS — ein eigener Umbau.
- Das Zwischenlager sendet keine CORS-Freigabe. Die gibt es nur für
  `relay.bitdm.net` (`deploy/webapp/README.md`). Eine Web-App von
  `https://bitdm.net` dürfte es also gar nicht ansprechen; das bräuchte eine
  Server-Änderung samt Ausrollen.

Ein Knopf, der eine Datei aussuchen lässt und danach scheitert, wäre
schlechter als ein grauer Knopf mit Grund. Wer Anhänge im Browser will, plant
das als eigenes Vorhaben: CORS am Zwischenlager, Anhang-Weg ohne `dart:io`,
Ablage im Browser, Öffnen als Download.

## Belege

- `app/test/oberflaeche/anhang_knopf_test.dart` — Weiche je Plattform im
  echten App-Baum (12 Fälle).
- `app/integration_test/datei_kanal_test.dart` — echter Dialog, von außen
  bedient: Windows 6/6 am PC, Linux 6/6 unter Xvfb
  (`app/tools/linux_dateikanal_lauf.sh`).
- `flutter test` komplett: Windows 1432 grün; Linux 1430 grün, 2 übersprungen.
