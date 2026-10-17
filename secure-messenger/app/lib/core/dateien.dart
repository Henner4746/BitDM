// dateien.dart — eine Datei aussuchen und eine empfangene oeffnen.
//
// Duenne Dart-Seite zum Kanal in DateiKanal.kt. Die Begruendungen fuer das
// WIE stehen dort; hier steht das WARUM DIESER WEG.
//
// ═══════════════════════════════════ WARUM EIN EIGENER KANAL UND KEIN PAKET
//
// Es gibt Pakete dafuer (file_picker, file_selector). Beide liefern am Ende
// dasselbe: einen Pfad. Dagegen sprechen drei Dinge, die in diesem Projekt
// schon einmal Geld gekostet haben:
//
//   * Jede Abhaengigkeit ist Angriffsflaeche. google_fonts flog raus, weil es
//     zur Laufzeit nachlud; sqlite3mc ist gepinnt, weil F-Droid
//     reproduzierbare Bauten verlangt.
//   * Die App HAT schon einen Kanal (MainActivity.kt, fuer Teilen und
//     App-Oeffnen). Ein zweiter ist kein Fremdkoerper, sondern dieselbe
//     Technik noch einmal.
//   * Der eigentliche Grund: DREI GIGABYTE DUERFEN NICHT KOPIERT WERDEN.
//     Pakete geben in der Regel einen Pfad in den App-Zwischenspeicher
//     zurueck — sie kopieren also. Bei 3 GB heisst das 3 GB doppelt auf einem
//     Telefon, plus die Zeit dafuer. Der eigene Kanal reicht stattdessen
//     einen Zugang auf die ORIGINALDATEI durch.
//
// ═══════════════════════════════════════════════ UND AM PC (seit 17.10.2026)
//
// Derselbe Kanal, gebaut in den Startprogrammen: windows/runner/
// datei_kanal.cpp und linux/runner/datei_kanal.cc. Bis dahin gab es ihn dort
// nicht, und "Datei anhaengen" war am PC ein Knopf, der nichts tat. Im
// Browser gibt es ihn weiterhin nicht — dort ist der Menuepunkt abgeschaltet
// und sagt, warum ([DateiWahl.auswahlFehlt]).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Eine ausgewaehlte Datei — und der Zettel, mit dem man sie wieder loslaesst.
class GewaehlteDatei {
  const GewaehlteDatei({
    required this.pfad,
    required this.name,
    required this.groesse,
    required this.zettel,
    required this.kopiert,
  });

  /// Ein Pfad, den dart:io lesen kann.
  final String pfad;

  /// Wie die Datei heisst — aus dem Dokument, nicht aus dem Pfad. Der Pfad
  /// ist bei Android-Dokumenten eine Nummer und kein Name.
  final String name;

  final int groesse;

  /// Womit der Zugang wieder freigegeben wird. MUSS nach dem Senden an
  /// [Dateien.gibFrei] — sonst bleibt eine Dateikennung offen, und davon hat
  /// ein Prozess nur eine begrenzte Zahl.
  final String zettel;

  /// Ob die Datei fuer diesen Zugriff KOPIERT werden musste.
  ///
  /// Der Regelfall ist false: der Kanal reicht die Originaldatei durch. Bei
  /// Anbietern, die keine echte Datei liefern (Cloud-Speicher), geht das
  /// nicht — dann liegt eine Kopie im Zwischenspeicher, und die Oberflaeche
  /// darf ruhig wissen, dass gerade doppelt so viel Platz belegt ist.
  final bool kopiert;

  File get datei => File(pfad);
}

/// Woher eine Datei kommt und wohin eine geht.
///
/// EINE SCHNITTSTELLE UND KEINE STATISCHE KLASSE, damit sich das Ganze
/// austauschen laesst. Der Grund ist das Testen ohne Menschen:
///
/// Der Auswahldialog gehoert ANDROID, nicht BitDM. Ihn in einem Testlauf per
/// uiautomator nachzuklicken hiesse, gegen eine fremde Oberflaeche zu testen,
/// die sich mit jeder Android-Fassung und jedem Hersteller aendert — und
/// wenn sie sich aendert, wird der Test rot, ohne dass an BitDM etwas kaputt
/// ist. Das ist die schlechteste Sorte Test: einer, der aus dem falschen
/// Grund ausschlaegt.
///
/// Was BitDM gehoert, faengt DAHINTER an: bei "der Nutzer hat eine Datei mit
/// diesem Pfad, diesem Namen und dieser Groesse gewaehlt". Genau das laesst
/// sich hier einsetzen, und dann laeuft der ganze Anhang-Weg auf einem
/// Emulator durch, ohne dass jemand tippt.
///
/// Der Dialog selbst wird EINMAL von Hand geprueft, nicht bei jedem Lauf.
abstract class DateiWahl {
  const DateiWahl();

  Future<GewaehlteDatei?> waehlen();

  /// Null, wenn [waehlen] hier einen Dialog zeigen kann — sonst der Grund,
  /// als Schluessel fuer die Oberflaeche: 'anhangWeb' im Browser,
  /// 'anhangKeinDialog' auf einer Plattform ohne Kanal. Wo nicht, ist "Datei
  /// anhaengen" abgeschaltet und sagt, warum, statt auf Druck still nichts zu
  /// tun. Mit Rumpf: Attrappen in Tests bleiben unveraendert gueltig.
  String? get auswahlFehlt => null;

  Future<void> gibFrei(String zettel);
  Future<bool> oeffne(String pfad, {String? name});

  /// Legt die Datei [quelle] unter dem Vorschlag [name] dort ab, wo der
  /// Nutzer es waehlt. Rueckgabe: eine Beschreibung des Orts, oder null, wenn
  /// abgebrochen wurde.
  ///
  /// Mit Rumpf statt abstrakt: Attrappen in Tests, die davon nichts wissen,
  /// bleiben so unveraendert gueltig.
  Future<String?> speichere(String quelle, String name) async => null;
}

/// Die echte, ueber den Kanal in DateiKanal.kt (bzw. datei_kanal.cpp/.cc).
class SystemDateiWahl extends DateiWahl {
  /// [imBrowser] nur fuer Tests: kIsWeb laesst sich dort nicht umstellen.
  const SystemDateiWahl({this.imBrowser = kIsWeb});

  final bool imBrowser;

  @override
  String? get auswahlFehlt =>
      Dateien.auswahlFehltAuf(defaultTargetPlatform, imBrowser: imBrowser);

  @override
  Future<GewaehlteDatei?> waehlen() => Dateien.waehlen();
  @override
  Future<void> gibFrei(String zettel) => Dateien.gibFrei(zettel);
  @override
  Future<bool> oeffne(String pfad, {String? name}) =>
      Dateien.oeffne(pfad, name: name);
  @override
  Future<String?> speichere(String quelle, String name) =>
      Dateien.speichere(quelle, name);
}

class Dateien {
  static const _kanal = MethodChannel('bitdm/dateien');

  /// Wo es den Kanal gibt: in der Android-App und in den Startprogrammen fuer
  /// Windows und Linux. Fuer macOS und iOS gibt es kein Startprogramm.
  static const _mitKanal = {
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.linux,
  };

  /// Warum es auf [plattform] keine Dateiauswahl gibt, oder null, wenn es
  /// sie gibt (siehe [DateiWahl.auswahlFehlt]).
  ///
  /// [imBrowser] MUSS zuerst geprueft werden: im Browser auf einem Android-
  /// Telefon meldet defaultTargetPlatform android, Kanaele gibt es dort aber
  /// keine.
  static String? auswahlFehltAuf(TargetPlatform plattform,
      {bool imBrowser = kIsWeb}) {
    if (imBrowser) return 'anhangWeb';
    return _mitKanal.contains(plattform) ? null : 'anhangKeinDialog';
  }

  /// Endungen, die ein Betrachter AUSFUEHRT statt nur zeigt: HTML, SVG,
  /// Skripte. Am PC gehen sie an das Programm fuer Text. Dieselbe Liste steht
  /// fuer Android in DateiKanal.kt (AKTIVE_ENDUNGEN) — dort wird sie zu
  /// text/plain. Bei einer Aenderung beide nachziehen.
  static const _aktiveEndungen = {
    'html', 'htm', 'xhtml', 'shtml', 'svg', 'svgz', 'mht', 'mhtml', 'js',
    'xml', 'hta',
  };

  /// Ob [name] auf eine Endung aus [_aktiveEndungen] endet.
  @visibleForTesting
  static bool aktiverInhalt(String name) {
    final punkt = name.lastIndexOf('.');
    if (punkt < 0 || punkt >= name.length - 1) return false;
    return _aktiveEndungen.contains(name.substring(punkt + 1).toLowerCase());
  }

  /// Oeffnet die Dateiauswahl des Systems. Null, wenn abgebrochen wurde.
  ///
  /// KEINE BERECHTIGUNG NOETIG. Das Storage Access Framework fragt den Nutzer
  /// selbst, und er waehlt genau eine Datei — die App bekommt Zugang zu ihr
  /// und zu nichts sonst. Eine Berechtigung wie READ_EXTERNAL_STORAGE waere
  /// der Zugriff auf ALLES, fuer den Gegenwert einer einzigen Datei.
  static Future<GewaehlteDatei?> waehlen() async {
    try {
      final a = await _kanal.invokeMapMethod<String, Object?>('waehlen');
      if (a == null) return null;
      return GewaehlteDatei(
        pfad: a['pfad']! as String,
        name: a['name']! as String,
        groesse: a['groesse']! as int,
        zettel: a['zettel']! as String,
        kopiert: a['kopiert'] as bool? ?? false,
      );
    } on MissingPluginException {
      // Im Browser und in Widget-Tests. Die Oberflaeche fragt vorher
      // [DateiWahl.auswahlFehlt] und bietet die Auswahl dort gar nicht an.
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Speichert eine Datei an einem Ort nach Wahl des Nutzers.
  ///
  /// ANDROID: der "Speichern unter"-Dialog des Systems (ACTION_CREATE_DOCUMENT)
  /// — wieder ohne Berechtigung, der Nutzer waehlt genau diesen einen Ort.
  /// AM RECHNER beantworten die Startprogramme 'speichern' nicht (das kommt
  /// als MissingPluginException an); die Datei landet dann im
  /// Download-Ordner, und die Rueckgabe sagt, wo.
  static Future<String?> speichere(String quelle, String name) async {
    try {
      final ok = await _kanal
          .invokeMethod<bool>('speichern', {'pfad': quelle, 'name': name});
      return ok == true ? name : null;
    } on MissingPluginException {
      final ordner = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final ziel = '${ordner.path}${Platform.pathSeparator}$name';
      await File(quelle).copy(ziel);
      return ziel;
    } on PlatformException {
      return null;
    }
  }

  /// Gibt den Zugang wieder frei. Wirft nie.
  static Future<void> gibFrei(String zettel) async {
    try {
      await _kanal.invokeMethod<void>('gibFrei', {'zettel': zettel});
    } catch (_) {
      // absichtlich still
    }
  }

  /// Reicht eine empfangene Datei an die App weiter, die sie oeffnen kann.
  ///
  /// Ueber einen FileProvider: die Datei liegt im privaten Bereich von BitDM,
  /// und ohne ihn koennte keine andere App sie sehen. Der Provider gibt
  /// genau diese eine Datei frei, genau fuer diesen einen Aufruf.
  ///
  /// Rueckgabe: false, wenn keine App sie oeffnen kann. Das ist kein Fehler,
  /// sondern eine Antwort — und die Oberflaeche kann dann sagen, dass nichts
  /// da ist, statt einen leeren Dialog zu zeigen.
  ///
  /// AM PC geht die Datei durch die Anhangpruefung des Systems (Windows) und
  /// aktive Inhalte als Text auf ('alsText'); Android entscheidet das selbst
  /// und uebergeht den Schalter.
  static Future<bool> oeffne(String pfad, {String? name}) async {
    try {
      return await _kanal.invokeMethod<bool>('oeffne', {
            'pfad': pfad,
            'name': name,
            // Beide: der Name kommt vom Absender, die Endung auf der Platte
            // entscheidet, welches Programm Windows nimmt.
            'alsText': aktiverInhalt(pfad) || aktiverInhalt(name ?? ''),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
