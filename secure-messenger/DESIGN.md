# Design

<!-- impeccable:design-schema 1 -->

## Visual World — „Nocturne"

Die Welt existiert bereits: festgelegt im lauffähigen Prototyp
(`prototype/index.html`) und in der Flutter-App (`app/lib/data.dart`,
`app/lib/main.dart`). Sie wird **geerbt, nicht neu erfunden**. Dieses Dokument
hält sie fest, damit neue Flächen sie treffen können.

Der Charakter ist **Signaltechnik, nicht App-Marketing**: sehr dunkler Grund,
ein einziger violetter Akzent, eingebrannt wirkende Versal-Beschriftungen und
eine Punktmatrix-Anzeigeschrift. Das ist kein Zufall — es passt zu einem
Produkt, dessen Kernaussage lautet: hier ist ein Schlüssel, kein Konto.

## Palette

| Rolle | Wert | Verwendung |
|---|---|---|
| Grund | `#0b0c12` | Seitenhintergrund, Gehäuse |
| Fläche | `#161826` | Module, Panels, erhöhte Flächen |
| Linie | `#3f424d` | Hairlines, Bezelkanten, Trennungen |
| Akzent hell | `#d2cefd` | Anzeigetext, aktive Zustände |
| Akzent | `#b5abfc` | Primäre Akzente, Anzeigeglühen |
| Akzent mittel | `#9184d9` | Sekundäre Akzente, Beschriftungen |
| Akzent dunkel | `#5d5294` | Ungezündete Anzeigen, Rahmen |
| Akzent tief | `#423a6a` | Anzeigenraster im Ruhezustand |
| Text hell | `#f3f5fe` | Überschriften |
| Text | `#cfd3e5` | Lauftext |
| Text gedämpft | `#9397ab` | Beschriftungen, Sekundäres |

**Farbstrategie: Restrained** — Neutrale plus **ein** Akzent. Violett trägt
Anzeigen und Zustände; es wird nie zur Fläche. Die Zurückhaltung ist Teil der
Aussage: ein Gerät leuchtet dort, wo es etwas anzeigt, und sonst nirgends.

Dunkel ist hier keine Kategoriegewohnheit, sondern folgt der Nutzungsszene: ein
Messenger wird abends am Telefon gelesen, und die Welt ist die einer Gerätefront,
deren Anzeigen nur im Dunkeln lesbar sind.

## Typografie

- **Doto** — Punktmatrix, versal, 700, `letter-spacing: 0.02em`.
  Ausschließlich für **Anzeigen und Überschriften**. Sie ist der Grund, warum
  die Welt nach Gerät aussieht; sie darf nie zu Lauftext werden.
- **Chivo Mono** — 400/500/600, 10–13px für eingebrannte Beschriftungen mit
  `letter-spacing: 0.08em`–`0.16em`, versal. Größer und ungesperrt für Lauftext.
- Beide unter SIL Open Font License, **lokal eingebettet**. Die Seite lädt
  keine Schriften von Dritten — dieselbe Regel wie in der App, aus demselben Grund.

Sperrungen sind gestaffelt und tragen Bedeutung: 0.16em für die kleinsten
Plattenbeschriftungen, 0.12em für Modulbezeichnungen, 0.08em für Zustände.

## Form

- Radien: **8px** (Standard), **4px** (kleine Steuerelemente), **14px** (Module),
  **99px** (Pillen, Statusleuchten).
- Hairlines `1px` in `#3f424d`. Rahmen sind Bezelkanten, keine Kartenränder.
- Tiefe entsteht durch **Versatz und weiche Streuung**, nie durch farbige Höfe
  ohne Versatz.

## Grammatik der Frontplatte

Neue Flächen erben diese Sprache:

- **Module** statt Karten. Ein Modul trägt eine eingebrannte Bezeichnung an der
  Kante, nicht eine Überschrift in der Mitte. Verschachtelte Module gibt es nicht.
- **Anzeigen** zeigen echten Zustand. Eine Anzeige, die nichts misst, ist Zierrat
  und gehört entfernt.
- **Statusleuchten** haben zwei ehrliche Zustände: gezündet und dunkel. Eine
  dunkle Leuchte ist eine Aussage, keine Entschuldigung.
- **Beschriftungen** sitzen über oder neben dem, was sie benennen, versal und
  gesperrt — wie im Siebdruck auf einer echten Platte.

## Bewegung

Ein einziger komponierter Moment je Fläche, nicht verstreute Effekte.
Exponentielles Auslaufen aus einem bereits sichtbaren Zustand — Inhalt ist nie
erst durch Bewegung vorhanden. `prefers-reduced-motion` wird respektiert und
schaltet auf den Endzustand.

## Grenzen

- Keine Verläufe im Text. Betonung kommt aus Gewicht und Größe.
- Kein Glas- oder Weichzeichnereffekt als Dekoration.
- Keine Fremdanfragen: keine Schriften, keine Skripte, keine Zählpixel von
  Dritten. Eine Datenschutz-Seite, die ihre Besucher verfolgt, widerlegt sich
  selbst — das ist eine Gestaltungsregel, keine bloße Betriebsentscheidung.
- Kontraste erfüllen WCAG AA: Lauftext ≥ 4.5:1, große Schrift ≥ 3:1.
  Die gedämpften Töne der Palette sind auf kleinen Größen zu prüfen.
