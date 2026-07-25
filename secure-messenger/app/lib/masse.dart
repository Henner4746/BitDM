// masse.dart — die Masse, nach denen die Oberflaeche gebaut ist.
//
// WARUM DIESE DATEI ENTSTANDEN IST
// Beim Nachmessen am 25.07.2026 waren 14 verschiedene Schriftgroessen und 14
// verschiedene Abstaende im Umlauf. Das ist keine Skala, das ist eine Liste.
// Entstanden ist sie nicht durch Absicht, sondern dadurch, dass jede neue
// Stelle sich ihre Zahl selbst ausgedacht hat.
//
// WAS HIER NICHT PASSIERT: die vorhandenen Zahlen umschreiben. Die
// Proportionen stammen aus dem Entwurf und sind eine Gestaltungsentscheidung;
// 12,5 auf 12 zu runden waere kein Feinschliff, sondern ein anderer Entwurf.
// Diese Datei haelt fest, WAS ES GIBT, damit die naechste Stelle sich nichts
// Neues ausdenkt.
//
// DAS ANTIPPMASS IST DIE AUSNAHME. Es ist kein Geschmack, sondern eine Zahl
// aus den Android-Richtlinien: 48 dp. Alles darunter wird danebengetippt, und
// zwar nicht von ungeschickten Leuten, sondern von allen — nur unterschiedlich
// oft.

import 'package:flutter/widgets.dart';

class Masse {
  const Masse._();

  // ═══════════════════════════════════════════════════════════════ Abstaende
  //
  // Die Stufen, die der Entwurf benutzt. Wer eine neue Stelle baut, nimmt eine
  // davon — und wenn keine passt, ist meistens die Gliederung falsch und nicht
  // der Abstand.

  /// Zwischen Dingen, die zusammengehoeren (Zeile und ihre Unterzeile).
  static const double eng = 6;

  /// Zwischen benachbarten Bedienelementen.
  static const double nah = 8;

  /// Innerhalb einer Karte.
  static const double innen = 11;

  /// Zwischen zwei Abschnitten desselben Blocks.
  static const double block = 16;

  /// Zwischen zwei Gruppen. Ueber einer Ueberschrift MEHR als darunter — sonst
  /// bindet sie sich optisch an das Falsche.
  static const double gruppe = 22;

  /// Der Rand eines Bildschirms.
  static const double rand = 22;

  // ══════════════════════════════════════════════════════════════ Antippen
  //
  // 48 dp ist das Mindestmass aus den Android-Richtlinien. Nicht die sichtbare
  // Flaeche muss so gross sein — der Trefferbereich.

  static const double antippMass = 48;

  /// Legt einen ausreichend grossen Trefferbereich um etwas Kleines.
  ///
  /// Die SICHTBARE Groesse bleibt, wie sie ist. Ein Knopf, der auf 48 dp
  /// aufgeblasen wird, damit man ihn trifft, sieht aus wie ein Fehler; einer
  /// mit unsichtbarem Rand drumherum trifft man einfach.
  static Widget trefferflaeche({required Widget child, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      // opaque: auch die durchsichtigen Stellen im Rand nehmen den Tipp
      // entgegen. Ohne das waere der Rand zwar da, aber wirkungslos.
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(
          minWidth: antippMass,
          minHeight: antippMass,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
