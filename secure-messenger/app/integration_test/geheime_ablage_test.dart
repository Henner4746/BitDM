// geheime_ablage_test.dart — der Kanal bitdm/ablage im echten Programm.
//
// Seit 09.11.2026, mit dem Kopierknopf fuer die zwoelf Woerter. Die
// Widget-Tests (test/core/geheime_ablage_test.dart,
// test/oberflaeche/woerter_kopieren_test.dart) pruefen die Dart-Seite gegen
// Attrappen; was die Gegenstellen mit der ECHTEN Zwischenablage tun, sieht man
// nur hier:
//
//   * Linux (X11, z. B. Xvfb): mit xclip von aussen gelesen — der Text, das
//     Ziel "x-kde-passwordManagerHint" mit "secret", und dass "leere" die
//     Ablage freigibt.
//   * Windows: mit PowerShell gelesen — der Text und die drei Formate, die
//     Verlauf (Win+V) und Cloud-Zwischenablage ausschliessen.
//   * Android: Rundweg und das Leeren nach der Frist, das GeheimeAblage.kt
//     selbst erledigt. Ob die Vorschau Punkte zeigt (EXTRA_IS_SENSITIVE),
//     liest keine App; das sieht man nur auf dem Bildschirm.
//
// Kopiert wird ein Probetext, nie Woerter.
//
//   xvfb-run -a flutter test integration_test/geheime_ablage_test.dart -d linux
//   flutter test integration_test/geheime_ablage_test.dart -d windows
//   flutter test integration_test/geheime_ablage_test.dart -d <android-geraet>

import 'dart:io';

import 'package:bitdm/core/geheime_ablage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _probe = 'bitdm probe ablage äöü';

Future<String?> _lies() async =>
    (await Clipboard.getData(Clipboard.kTextPlain))?.text;

/// Wartet in echter Zeit, bis [bedingung] gilt — hoechstens [frist].
Future<bool> _bis(Future<bool> Function() bedingung,
    {Duration frist = const Duration(seconds: 15)}) async {
  final ende = DateTime.now().add(frist);
  while (DateTime.now().isBefore(ende)) {
    if (await bedingung()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return bedingung();
}

// ---- Linux ----------------------------------------------------------------

Future<String> _xclip(List<String> argumente) async {
  final r = await Process.run(
      'xclip', ['-o', '-selection', 'clipboard', ...argumente]);
  return r.exitCode == 0 ? (r.stdout as String) : '';
}

// ---- Windows --------------------------------------------------------------

/// Liest die Formate der Ablage. Eine Zeile je Wert, "name=wert".
const _formateWindows = r'''
Add-Type -AssemblyName System.Windows.Forms
$d = [System.Windows.Forms.Clipboard]::GetDataObject()
if ($d -eq $null) { 'leer=1'; exit }
foreach ($f in 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
  $s = $d.GetData($f)
  if ($s -is [System.IO.MemoryStream]) {
    "$f=" + [System.BitConverter]::ToUInt32($s.ToArray(), 0)
  } else { "$f=fehlt" }
}
'Exclude=' + $d.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing')
'Text=' + $d.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText)
''';

Future<Map<String, String>> _formate() async {
  final r = await Process.run('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-STA', '-Command', _formateWindows]);
  final werte = <String, String>{};
  for (final zeile in (r.stdout as String).split(RegExp(r'\r?\n'))) {
    final i = zeile.indexOf('=');
    if (i > 0) werte[zeile.substring(0, i).trim()] = zeile.substring(i + 1).trim();
  }
  return werte;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final linux = !kIsWeb && Platform.isLinux;
  final windows = !kIsWeb && Platform.isWindows;
  final android = !kIsWeb && Platform.isAndroid;

  tearDown(GeheimeAblage.vergiss);

  test('die Gegenstelle ist da und kopiert', () async {
    const kanal = MethodChannel('bitdm/ablage');
    final ok = await kanal.invokeMethod<bool>(
        'kopiere', {'text': _probe, 'sekunden': 60});
    expect(ok, isTrue, reason: 'bitdm/ablage antwortet nicht');
    expect(await _lies(), _probe);
    // Diesen Aufruf hat GeheimeAblage nicht gesehen — von Hand wegraeumen.
    if (android) {
      await kanal.invokeMethod<bool>('raeume');
    } else {
      await kanal.invokeMethod<bool>('leere');
    }
  });

  test('Linux: Text und KDE-Hinweis von aussen lesbar, leere gibt frei',
      () async {
    expect(await GeheimeAblage.kopiere(_probe), isTrue);
    final ziele = await _xclip(['-t', 'TARGETS']);
    expect(ziele, contains('x-kde-passwordManagerHint'));
    expect(ziele, contains('UTF8_STRING'));
    expect(await _xclip(['-t', 'x-kde-passwordManagerHint']), 'secret');
    expect(await _xclip(['-t', 'UTF8_STRING']), _probe);

    await GeheimeAblage.raeumeJetzt();
    expect(await _xclip(['-t', 'TARGETS']),
        isNot(contains('x-kde-passwordManagerHint')));
    expect(await _xclip(['-t', 'UTF8_STRING']), isEmpty);
  }, skip: !linux);

  test('Linux: was jemand anderes kopiert hat, bleibt', () async {
    expect(await GeheimeAblage.kopiere(_probe), isTrue);
    // Ein anderes Programm uebernimmt die Ablage. -quiet haelt xclip im
    // Vordergrund, bis es beendet wird; es liefert so oft wie gefragt.
    final fremd = await Process.start(
        'xclip', ['-i', '-selection', 'clipboard', '-quiet']);
    fremd.stdin.write('fremder text');
    await fremd.stdin.close();
    expect(await _bis(() async => await _lies() == 'fremder text'), isTrue);

    await GeheimeAblage.raeumeJetzt();
    expect(await _lies(), 'fremder text');
    fremd.kill();
  }, skip: !linux);

  test('Windows: Text, nicht im Verlauf, nicht in der Cloud', () async {
    expect(await GeheimeAblage.kopiere(_probe), isTrue);
    expect(await _lies(), _probe);
    final f = await _formate();
    expect(f['CanIncludeInClipboardHistory'], '0', reason: '$f');
    expect(f['CanUploadToCloudClipboard'], '0', reason: '$f');
    expect(f['Exclude'], 'True', reason: '$f');
    expect(f['Text'], 'True', reason: '$f');

    await GeheimeAblage.raeumeJetzt();
    expect(await _lies(), anyOf(isNull, isEmpty));
  }, skip: !windows);

  test('Android: nach der Frist leert GeheimeAblage.kt selbst', () async {
    expect(
        await GeheimeAblage.kopiere(_probe, frist: const Duration(seconds: 2)),
        isTrue);
    expect(await _lies(), _probe);
    expect(await _bis(() async => (await _lies() ?? '').isEmpty), isTrue,
        reason: 'nach der Frist stand der Probetext noch da');
  }, skip: !android);

  test('Android: was inzwischen kopiert wurde, bleibt', () async {
    expect(
        await GeheimeAblage.kopiere(_probe, frist: const Duration(seconds: 2)),
        isTrue);
    await Clipboard.setData(const ClipboardData(text: 'fremder text'));
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(await _lies(), 'fremder text');
  }, skip: !android);

  test('Android: raeumeJetzt leert sofort', () async {
    expect(await GeheimeAblage.kopiere(_probe), isTrue);
    expect(await _lies(), _probe);
    await GeheimeAblage.raeumeJetzt();
    expect(await _bis(() async => (await _lies() ?? '').isEmpty), isTrue);
  }, skip: !android);
}
