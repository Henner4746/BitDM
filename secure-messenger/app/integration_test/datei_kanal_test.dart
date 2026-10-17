// datei_kanal_test.dart — der Kanal bitdm/dateien am echten Rechner.
//
// Seit 17.10.2026. Bis dahin gab es den Kanal nur unter Android; am PC tat
// "Datei anhaengen" nichts (test/oberflaeche/anhang_knopf_test.dart erzaehlt
// die Geschichte). Die Widget-Tests pruefen die Weiche, nicht den Dialog —
// den gibt es nur im echten Programm. Dieser Lauf startet BitDM als Windows-
// bzw. Linux-Programm und bedient den Dialog des Systems von aussen:
//
//   * Windows: ein PowerShell-Skript sucht das Dialogfenster des Prozesses
//     und schreibt den Pfad per WM_SETTEXT hinein, dann "Oeffnen" per
//     WM_COMMAND. Ohne Tastatur und Maus — wer daneben am Rechner sitzt,
//     tippt nicht versehentlich in den Dialog oder der Test in sein Fenster.
//   * Linux (X11, z. B. Xvfb): xdotool, Strg+L, Pfad, Eingabe.
//
//   flutter test integration_test/datei_kanal_test.dart -d windows
//   xvfb-run -a flutter test integration_test/datei_kanal_test.dart -d linux
//
// OEFFNEN unter Linux nur mit --dart-define=BITDM_TEST_OEFFNEN=true und
// Attrappen als Standardprogrammen (siehe [_oeffnenAufLinux]). Unter Windows
// wird "oeffne" nur fuer eine fehlende Datei geprueft: ein echtes Oeffnen
// startet ein Programm auf dem Schreibtisch des Nutzers.

import 'dart:async';
import 'dart:io';

import 'package:bitdm/core/dateien.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _oeffnenPruefen = bool.fromEnvironment('BITDM_TEST_OEFFNEN');

/// Sucht ein NEUES sichtbares Dialogfenster des Prozesses und bedient es.
/// Erst danach wird der Dialog geoeffnet — die Fenster, die beim Start schon
/// da sind, zaehlen nicht.
///
/// DREI WEGE NACHEINANDER, jeder mit Zeitstempel im Protokoll: BM_CLICK an
/// den Knopf, WM_COMMAND an den Dialog, zuletzt die Eingabetaste bzw.
/// WM_CLOSE. Laut Doku "might fail" BM_CLICK, wenn der Dialog nicht das
/// aktive Fenster ist — und aktiv ist er nicht, wenn daneben jemand arbeitet.
/// Am 17.10.2026 reichte BM_CLICK in jedem Lauf; die Fehlschlaege davor lagen
/// am Start der Fernbedienung ([_Fern.bereit]), nicht am Knopfdruck.
const _fernbedienungWindows = r'''
param([int]$Prozess, [string]$Pfad = '', [switch]$Abbrechen, [int]$Sekunden = 20)
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class Fern {
  public delegate bool Zaehler(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(Zaehler z, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, Zaehler z, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  public static string Klasse(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static List<IntPtr> Dialoge(uint prozess) {
    var r = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
      if (p == prozess && IsWindowVisible(h) && Klasse(h) == "#32770") r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }
  // Das Namensfeld: Edit in der ComboBoxEx32 mit der Kennung 1148 (cmb13).
  public static IntPtr Namensfeld(IntPtr dialog) {
    IntPtr f = IntPtr.Zero;
    EnumChildWindows(dialog, (h, l) => {
      if (Klasse(h) == "ComboBoxEx32" && GetDlgCtrlID(h) == 1148) {
        EnumChildWindows(h, (k, m) => { if (Klasse(k) == "Edit") { f = k; return false; } return true; }, IntPtr.Zero);
        return false;
      }
      return true; }, IntPtr.Zero);
    return f;
  }
}
"@
function Melde([string]$t) { Write-Output ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $t) }
$vorher = [Fern]::Dialoge($Prozess)
# ERST JETZT darf der Dialog aufgehen: vorher gezaehlt, galte er als alt.
Write-Output 'bereit'
$ende = (Get-Date).AddSeconds($Sekunden)
$dialog = [IntPtr]::Zero
while ((Get-Date) -lt $ende -and $dialog -eq [IntPtr]::Zero) {
  Start-Sleep -Milliseconds 200
  foreach ($h in [Fern]::Dialoge($Prozess)) { if ($vorher -notcontains $h) { $dialog = $h } }
}
if ($dialog -eq [IntPtr]::Zero) { Melde 'kein Dialog'; exit 3 }
Melde "Dialog $dialog"
Start-Sleep -Milliseconds 700
$id = 2
$feld = [IntPtr]::Zero
if (-not $Abbrechen) {
  $feld = [Fern]::Namensfeld($dialog)
  if ($feld -eq [IntPtr]::Zero) { Melde 'kein Namensfeld'; exit 4 }
  [Fern]::SendMessage($feld, 0x000C, [IntPtr]::Zero, $Pfad) | Out-Null
  Melde "Pfad gesetzt in $feld"
  Start-Sleep -Milliseconds 300
  $id = 1
}
$knopf = [Fern]::GetDlgItem($dialog, $id)
$wege = [ordered]@{
  'BM_CLICK' = { [Fern]::PostMessage($knopf, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
  'WM_COMMAND' = { [Fern]::PostMessage($dialog, 0x0111, [IntPtr]$id, $knopf) | Out-Null }
  'Taste oder WM_CLOSE' = {
    if ($Abbrechen) { [Fern]::PostMessage($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
    else {
      [Fern]::PostMessage($feld, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001) | Out-Null
      [Fern]::PostMessage($feld, 0x0102, [IntPtr]0x0D, [IntPtr]0x001C0001) | Out-Null
      [Fern]::PostMessage($feld, 0x0101, [IntPtr]0x0D, [IntPtr]0xC01C0001) | Out-Null
    }
  }
}
foreach ($weg in $wege.Keys) {
  & $wege[$weg]
  Melde "versucht: $weg (Knopf $knopf)"
  for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 200
    if (-not [Fern]::IsWindow($dialog) -or -not [Fern]::IsWindowVisible($dialog)) { Melde "zu nach $weg"; exit 0 }
  }
}
Melde 'Dialog blieb offen'
exit 5
''';

const _fernbedienungLinux = r'''
PROZESS=$1; MODUS=$2; PFAD=${3:-}
vorher=" $(xdotool search --onlyvisible --pid "$PROZESS" 2>/dev/null | tr '\n' ' ') "
echo bereit
dialog=
for i in $(seq 1 150); do
  for w in $(xdotool search --onlyvisible --pid "$PROZESS" 2>/dev/null); do
    case "$vorher" in *" $w "*) ;; *) dialog=$w ;; esac
  done
  [ -n "$dialog" ] && break
  sleep 0.2
done
[ -z "$dialog" ] && { echo "kein Dialog"; exit 3; }
sleep 1
xdotool windowfocus --sync "$dialog"
if [ "$MODUS" = abbrechen ]; then
  xdotool key --clearmodifiers Escape
else
  xdotool key --clearmodifiers ctrl+l
  sleep 0.4
  xdotool type --delay 20 "$PFAD"
  sleep 0.4
  xdotool key --clearmodifiers Return
fi
''';

late Directory _ordner;
late File _skript;

/// Eine laufende Fernbedienung samt allem, was sie sagt.
class _Fern {
  _Fern(this._p) {
    _p.stdout.transform(const SystemEncoding().decoder).listen((teil) {
      _log.write(teil);
      if (!_bereit.isCompleted && _log.toString().contains('bereit')) {
        _bereit.complete();
      }
    });
    _p.stderr.transform(const SystemEncoding().decoder).listen(_log.write);
  }

  final Process _p;
  final _log = StringBuffer();
  final _bereit = Completer<void>();

  /// Die Fernbedienung hat sich gemerkt, welche Fenster schon da sind.
  ///
  /// ERST DANACH darf der Dialog aufgehen. Am 17.10.2026 brauchte PowerShell
  /// fuer Add-Type laenger als BitDM fuer den Dialog: der zaehlte dann zu den
  /// alten Fenstern, und die Fernbedienung wartete vergeblich ("kein Dialog").
  Future<void> get bereit => _bereit.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail('Fernbedienung nicht bereit:\n$_log'));

  /// Wartet auf [aufruf], hoechstens 25 Sekunden. Sonst blieb der Dialog
  /// offen — und statt der stummen Zeitgrenze des Tests steht dann da, was
  /// die Fernbedienung versucht hat.
  Future<T> waehrend<T>(Future<T> aufruf) => aufruf.timeout(
      const Duration(seconds: 25),
      onTimeout: () => fail('Der Dialog blieb offen. Fernbedienung:\n$_log'));

  Future<void> fertig() async {
    final code = await _p.exitCode.timeout(const Duration(seconds: 40));
    debugPrint('Fernbedienung:\n$_log');
    expect(code, 0, reason: 'Fernbedienung:\n$_log');
  }
}

/// Startet die Fernbedienung; sie wartet auf den Dialog, der gleich aufgeht.
Future<_Fern> _bediene({String? pfad, bool abbrechen = false}) async {
  final fern = _Fern(Platform.isWindows
      ? await Process.start('powershell.exe', [
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', _skript.path,
          '-Prozess', '$pid',
          if (abbrechen) '-Abbrechen' else ...['-Pfad', pfad!],
        ])
      : await Process.start('bash',
          [_skript.path, '$pid', abbrechen ? 'abbrechen' : 'waehlen', ?pfad]));
  await fern.bereit;
  return fern;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _ordner = await Directory.systemTemp.createTemp('bitdm-dateikanal');
    _skript = File('${_ordner.path}${Platform.pathSeparator}'
        '${Platform.isWindows ? 'fern.ps1' : 'fern.sh'}');
    // Reines ASCII: PowerShell 5 liest ein Skript ohne BOM als ANSI. Der Pfad
    // mit Umlaut kommt ueber die Befehlszeile, die ist UTF-16.
    await _skript.writeAsString(
        Platform.isWindows ? _fernbedienungWindows : _fernbedienungLinux);
  });
  tearDownAll(() async {
    try {
      await _ordner.delete(recursive: true);
    } catch (_) {}
  });

  test('WAEHLEN: der Dialog geht auf, die Originaldatei kommt zurueck',
      () async {
    // Unter Windows mit Umlaut und Leerzeichen: der Pfad geht als UTF-16
    // hinein und muss als UTF-8 heil herauskommen. xdotool tippt unter Xvfb
    // nur verlaesslich ASCII.
    final name = Platform.isWindows ? 'Prüfbericht ä 1.bin' : 'pruefbericht-1.bin';
    final inhalt = List.generate(123457, (i) => i % 251);
    final datei = File('${_ordner.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync(inhalt);

    final fern = await _bediene(pfad: datei.path);
    final gewaehlt = await fern.waehrend(Dateien.waehlen());
    await fern.fertig();

    expect(gewaehlt, isNotNull, reason: 'kein Ergebnis — der alte Zustand');
    expect(gewaehlt!.name, name);
    expect(gewaehlt.groesse, inhalt.length);
    expect(gewaehlt.kopiert, isFalse);
    expect(gewaehlt.zettel, isEmpty);
    // DIE ORIGINALDATEI, keine Kopie: derselbe Pfad, dieselben Bytes.
    expect(File(gewaehlt.pfad).absolute.path.toLowerCase(),
        datei.absolute.path.toLowerCase());
    expect(await gewaehlt.datei.readAsBytes(), inhalt);
    await Dateien.gibFrei(gewaehlt.zettel); // wirft nicht, tut nichts
  });

  test('ABBRECHEN gibt null, ohne Fehler', () async {
    final fern = await _bediene(abbrechen: true);
    expect(await fern.waehrend(Dateien.waehlen()), isNull);
    await fern.fertig();
  });

  test('ZWEI DIALOGE GLEICHZEITIG gibt es nicht', () async {
    const kanal = MethodChannel('bitdm/dateien');
    final fern = await _bediene(abbrechen: true);
    final erster = kanal.invokeMethod<Object?>('waehlen');
    // Warten, bis der erste Dialog offen ist, dann der zweite Aufruf.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await expectLater(kanal.invokeMethod<Object?>('waehlen'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'laeuft')));
    expect(await fern.waehrend(erster), isNull);
    await fern.fertig();
  });

  test('SPEICHERN beantwortet der Kanal am PC nicht — dateien.dart nimmt '
      'dann den Download-Ordner', () async {
    await expectLater(
        const MethodChannel('bitdm/dateien').invokeMethod<bool>('speichern'),
        throwsA(isA<MissingPluginException>()));
  });

  test('OEFFNEN einer fehlenden Datei sagt false', () async {
    expect(
        await Dateien.oeffne('${_ordner.path}${Platform.pathSeparator}gibtsnicht.pdf'),
        isFalse);
  });

  if (Platform.isLinux && _oeffnenPruefen) {
    test('OEFFNEN: das Standardprogramm bekommt die Datei, HTML als Text',
        _oeffnenAufLinux);
  }
  if (Platform.isWindows && _oeffnenPruefen) {
    test('OEFFNEN: erst die Anhangpruefung von Windows — die Datei traegt '
        'danach die Markierung "aus dem Internet"', _oeffnenAufWindows);
  }
}

/// Oeffnet eine Datei mit einer Endung, fuer die es kein Programm gibt. Davor
/// muss IAttachmentExecute die Markierung geschrieben haben (Zone.Identifier,
/// ZoneId=3 = Internet) — an ihr haengen die Rueckfrage bei Programmen, die
/// geschuetzte Ansicht in Office und SmartScreen.
///
/// Windows zeigt danach "Wie soll die Datei geoeffnet werden?". Diesen Dialog
/// schliesst der Test selbst, aber nur einen, der nach seinem Start aufging.
Future<void> _oeffnenAufWindows() async {
  final probe = File('${_ordner.path}\\probe.bitdmprobe')
    ..writeAsStringSync('probe');
  // DIE STARTZEIT KOMMT VON HIER und nicht aus dem Skript: PowerShell braucht
  // zum Starten laenger, als Windows fuer "App auswaehlen" — am 17.10.2026
  // war das Fenster aelter als die im Skript gemessene Zeit und blieb stehen.
  final seit = DateTime.now()
      .toUtc()
      .subtract(const Duration(seconds: 1))
      .toIso8601String();
  final schliesser = await Process.start('powershell.exe', [
    '-NoProfile', '-Command',
    "\$seit = [DateTime]::Parse('$seit'); "
        r'$ende = (Get-Date).AddSeconds(15); '
        r'while ((Get-Date) -lt $ende) { '
        r'$p = Get-Process OpenWith -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt $seit }; '
        r'if ($p) { Start-Sleep -Milliseconds 800; $p | Stop-Process -Force; "geschlossen"; exit 0 }; '
        r'Start-Sleep -Milliseconds 200 }; "kein Oeffnen-mit"',
  ]);
  final ging = await Dateien.oeffne(probe.path, name: 'probe.bitdmprobe');
  final zone = File('${probe.path}:Zone.Identifier');
  expect(zone.existsSync(), isTrue,
      reason: 'keine Herkunftsmarkierung — die Anhangpruefung lief nicht');
  expect(zone.readAsStringSync(), contains('ZoneId=3'));
  final aus = await schliesser.stdout
      .transform(const SystemEncoding().decoder)
      .join()
      .timeout(const Duration(seconds: 20));
  debugPrint('oeffne: $ging, $aus');
  // "App auswaehlen" ist erschienen: ShellExecuteExW wurde erreicht, und fuer
  // eine Endung ohne Programm ist das die richtige Antwort von Windows.
  expect(ging, isTrue);
  expect(aus, contains('geschlossen'));
}

/// Erwartet drei Attrappen als Standardprogramme (XDG_CONFIG_HOME/
/// mimeapps.list), die je eine Zeile nach BITDM_TEST_PROTOKOLL schreiben:
///   application/pdf → `pdf PFAD`
///   text/plain      → `text PFAD`
///   text/html       → `browser PFAD` — darf NIE vorkommen
/// Eingerichtet von tools/linux_dateikanal_lauf.sh.
Future<void> _oeffnenAufLinux() async {
  final wohin = Platform.environment['BITDM_TEST_PROTOKOLL'];
  expect(wohin, isNotNull, reason: 'BITDM_TEST_PROTOKOLL fehlt');
  final protokoll = File(wohin!);
  if (protokoll.existsSync()) protokoll.deleteSync();
  final pdf = File('${_ordner.path}/brief.pdf')..writeAsStringSync('%PDF-1.4\n');
  final html = File('${_ordner.path}/rechnung.html')
    ..writeAsStringSync('<script>alert(1)</script>');

  expect(await Dateien.oeffne(pdf.path, name: 'brief.pdf'), isTrue);
  expect(await Dateien.oeffne(html.path, name: 'rechnung.html'), isTrue);
  for (var i = 0; i < 50 && (!protokoll.existsSync() ||
      protokoll.readAsLinesSync().length < 2); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final zeilen = protokoll.readAsLinesSync();
  expect(zeilen, contains('pdf ${pdf.path}'));
  // HTML NICHT an den Browser, sondern an das Programm fuer Text.
  expect(zeilen, contains('text ${html.path}'));
  expect(zeilen.where((z) => z.startsWith('browser')), isEmpty);
}
