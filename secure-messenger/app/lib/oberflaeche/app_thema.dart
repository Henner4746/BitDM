// app_thema.dart — das Thema fuer alles, was Flutter selbst zeichnet
// (Dialoge, Blaetter, Eingabefelder), und der Wert, ueber den Home es setzt.
//
// Aus main.dart herausgeloest, Zeichen fuer Zeichen (docs/MAIN-DART-AUFTEILUNG.md).

import 'package:flutter/material.dart' hide ConnectionState;
import '../data.dart';
import '../themen.dart';

/// Das Thema fuer Flutters eigene Teile — Home schreibt, [BitApp] liest.
///
/// Das Thema muss UEBER dem Navigator haengen: Dialoge und Blaetter sind
/// eigene Routen, und `showDialog(context: context)` aus Home heraus sieht nur
/// die Themen oberhalb von Home.
final ValueNotifier<Thema> anzeigeThema = ValueNotifier(bauThemen().first);

/// Das Thema fuer alles, was Flutter selbst zeichnet: Dialoge, Blaetter,
/// Textknoepfe, Eingabefelder, Kaestchen.
///
/// BIS 25.09.2026 GAB ES KEINES. Die App zeichnet ihre Bildschirme selbst
/// und merkte es deshalb nicht — aber jeder AlertDialog kam in Roboto mit
/// Material-Lila daher, mitten in einer Monoschrift-Oberflaeche (im
/// Emulatorlauf an "Neue Gruppe" aufgefallen).
ThemeData bitThema(Pal p,
    {bool dunkel = true, String? mono = 'Chivo Mono', String? text}) {
  TextStyle m(double groesse, {FontWeight dicke = FontWeight.w400, Color? farbe, double? abstand}) =>
      TextStyle(
        fontFamily: mono,
        fontVariations: [FontVariation('wght', dicke.value.toDouble())],
        fontSize: groesse,
        fontWeight: dicke,
        color: farbe,
        letterSpacing: abstand,
      );
  final schema = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: dunkel ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: p.accLight,
    onPrimary: p.onAcc,
    surface: p.surf,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    outline: p.line,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    colorScheme: schema,
    // fontFamily NUR, WENN DAS THEMA ES WILL: es findet sich in jedem Text
    // ohne eigene Schrift wieder, auch im Nachrichtentext der Blasen. Der ist
    // normalerweise in der Schrift des Systems gesetzt, weil sie sich in
    // Saetzen besser liest — nur die Terminal-Themen setzen ihn mono.
    fontFamily: text,
    scaffoldBackgroundColor: p.bg,
    dialogTheme: DialogThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
      titleTextStyle: m(15, dicke: FontWeight.w600, farbe: p.ink),
      contentTextStyle: m(13, farbe: p.muted),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accLight,
        textStyle: m(12, dicke: FontWeight.w600, abstand: 0.8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      // Derselbe Griff wie am eigenen Blatt ([sheetCard]): 36 x 3 in p.line.
      showDragHandle: true,
      dragHandleColor: p.line,
      dragHandleSize: const Size(36, 3),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: m(13, farbe: p.dim),
      labelStyle: m(13, farbe: p.muted),
      counterStyle: m(10, farbe: p.dim),
      // KEIN enabledBorder/focusedBorder: die schlagen ein `border:
      // InputBorder.none` am Feld und zogen eine Linie in die Schreibzeile.
      // Die Farben der Unterstreichung im Dialog kommen aus dem Schema.
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accLight,
      selectionColor: p.accent.withValues(alpha: 0.35),
      selectionHandleColor: p.accLight,
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: p.muted, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      fillColor: WidgetStateProperty.resolveWith(
          (z) => z.contains(WidgetState.selected) ? p.accLight : Colors.transparent),
      checkColor: WidgetStatePropertyAll(p.onAcc),
    ),
    // "Spaeter senden" fragt Tag und Uhrzeit mit Flutters eigenen Waehlern —
    // ohne diese beiden Eintraege kamen sie hell und in Roboto.
    datePickerTheme: DatePickerThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: p.surf,
      headerForegroundColor: p.ink,
      headerHeadlineStyle: m(26, dicke: FontWeight.w500, farbe: p.ink),
      headerHelpStyle: m(11, dicke: FontWeight.w600, farbe: p.dim, abstand: 1.2),
      weekdayStyle: m(12, farbe: p.dim),
      dayStyle: m(13),
      yearStyle: m(13),
      dividerColor: p.line,
      todayBorder: BorderSide(color: p.accLight),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
      cancelButtonStyle: TextButton.styleFrom(foregroundColor: p.muted),
      confirmButtonStyle: TextButton.styleFrom(foregroundColor: p.accLight),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: p.surf,
      helpTextStyle: m(11, dicke: FontWeight.w600, farbe: p.dim, abstand: 1.2),
      hourMinuteColor: p.surf2,
      hourMinuteTextColor: p.ink,
      hourMinuteTextStyle: m(40, dicke: FontWeight.w500),
      dayPeriodTextStyle: m(12, dicke: FontWeight.w600),
      dayPeriodBorderSide: BorderSide(color: p.line),
      dialBackgroundColor: p.surf2,
      dialTextStyle: m(13),
      entryModeIconColor: p.muted,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
      cancelButtonStyle: TextButton.styleFrom(foregroundColor: p.muted),
      confirmButtonStyle: TextButton.styleFrom(foregroundColor: p.accLight),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surf2,
      contentTextStyle: m(12.5, farbe: p.ink),
    ),
  );
}
