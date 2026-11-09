// geheime_ablage.dart — Geheimes in die Zwischenablage, und wieder heraus.
//
// Fuer die zwoelf Woerter und die Teilgeheimnisse daraus. Die Gegenstellen
// heissen ueberall "bitdm/ablage": GeheimeAblage.kt (Android),
// windows/runner/geheime_ablage.cpp und linux/runner/geheime_ablage.cc.
//
// WARUM ES EINEN KOPIERKNOPF FUER DIE WOERTER UEBERHAUPT GIBT (09.11.2026):
// wer sie in einen Passwortmanager legen will, tippte bis dahin zwoelf Woerter
// ab — oder fotografierte sie, und genau das soll niemand tun. Kopieren ist
// der kleinere Schaden, wenn es so passiert, wie es hier passiert:
//
//   * ANDROID markiert den Inhalt als sensibel
//     (ClipDescription.EXTRA_IS_SENSITIVE). Die Vorschau unten links ab
//     Android 13 zeigt dann Punkte statt der Woerter, und Tastaturen wie
//     Gboard bieten ihn nicht als Einfuegevorschlag an.
//   * WINDOWS nimmt ihn aus dem Verlauf (Win+V) und aus der Synchronisation
//     ueber das Microsoft-Konto heraus — dieselben Formate, die
//     Passwortmanager setzen.
//   * LINUX setzt den Hinweis, den KDE (Klipper) und andere
//     Zwischenablage-Verlaeufe als "Passwort, nicht merken" lesen.
//   * UEBERALL wird die Ablage nach der Frist wieder geleert — aber nur, wenn
//     dort noch GENAU das steht. Was der Nutzer inzwischen selbst kopiert hat,
//     bleibt.
//
// IM BROWSER geht davon nur das Kopieren. Lesen loest dort eine Rueckfrage des
// Browsers aus (Chrome fragt nach der Erlaubnis, Firefox und Safari zeigen
// einen "Einfuegen"-Knopf), und Schreiben ohne Tippen des Nutzers lassen
// Firefox und Safari gar nicht zu, Chrome nur, solange der Reiter den Fokus
// hat. Deshalb wird dort nach der Frist ohne Vergleich geleert, wo es geht,
// und die Oberflaeche sagt, dass es nicht verlaesslich ist ([leertSicher]).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GeheimeAblage {
  GeheimeAblage._();

  static const MethodChannel _kanal = MethodChannel('bitdm/ablage');

  /// So lange duerfen die zwoelf Woerter in der Zwischenablage stehen.
  ///
  /// Lang genug, um in einen Passwortmanager zu wechseln und dort einzufuegen,
  /// kurz genug, dass sie nicht bis zum Abend herumliegen.
  static const Duration frist = Duration(seconds: 60);

  /// Ob die App die Ablage nach der Frist zuverlaessig leeren kann. Im
  /// Browser nicht (siehe oben); dort soll die Oberflaeche das nicht
  /// versprechen.
  static bool get leertSicher => !kIsWeb;

  /// ANDROID RAEUMT SELBST AUF, sobald die Gegenstelle das Kopieren
  /// uebernommen hat. Ab Android 10 liest nur die App im Vordergrund die
  /// Zwischenablage — ein Zeitgeber hier, der nach einer Minute im
  /// Hintergrund nachsieht, bekaeme null und liesse die Woerter stehen.
  /// GeheimeAblage.kt weiss, wie es damit umgeht.
  static bool get _raeumtNativ =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Timer? _wecker;
  static String? _inhalt;
  static bool _nativAktiv = false;

  /// Legt [text] in die Zwischenablage und leert sie nach [frist] wieder,
  /// wenn dort dann noch [text] steht.
  ///
  /// Ein neuer Aufruf ersetzt den alten: es wird immer nur das zuletzt
  /// Kopierte beobachtet.
  ///
  /// Rueckgabe: ob kopiert wurde. Wirft nie.
  static Future<bool> kopiere(String text,
      {Duration frist = GeheimeAblage.frist}) async {
    _wecker?.cancel();
    _wecker = null;
    _inhalt = null;
    _nativAktiv = false;

    var nativ = false;
    try {
      nativ = await _kanal.invokeMethod<bool>(
              'kopiere', {'text': text, 'sekunden': frist.inSeconds}) ==
          true;
    } on MissingPluginException {
      // Kein Gegenstueck — im Browser und im Test. Dann wie jede andere App.
    } on PlatformException {
      // Ebenso: lieber ohne Zusatzschutz kopieren als gar nicht.
    }
    if (!nativ) {
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        return false;
      }
    }
    if (nativ && _raeumtNativ) {
      _nativAktiv = true;
      return true;
    }
    _inhalt = text;
    _wecker = Timer(frist, () => unawaited(_raeume()));
    return true;
  }

  /// Leert die Ablage SOFORT, wenn dort noch das zuletzt Kopierte steht —
  /// etwa wenn die Identitaet geloescht wurde. Wirft nie.
  static Future<void> raeumeJetzt() async {
    _wecker?.cancel();
    _wecker = null;
    if (_nativAktiv) {
      _nativAktiv = false;
      try {
        await _kanal.invokeMethod<bool>('raeume');
      } catch (_) {
        // Ohne Gegenstelle gibt es auch nichts, was sie haette raeumen koennen.
      }
      return;
    }
    await _raeume();
  }

  /// Ob nach der Frist noch etwas ansteht. Nur fuer Tests.
  @visibleForTesting
  static bool get wartet => _wecker != null || _nativAktiv;

  /// Vergisst alles, ohne die Ablage anzufassen. Nur fuer Tests.
  @visibleForTesting
  static void vergiss() {
    _wecker?.cancel();
    _wecker = null;
    _inhalt = null;
    _nativAktiv = false;
  }

  static Future<void> _raeume() async {
    final text = _inhalt;
    _inhalt = null;
    _wecker = null;
    if (text == null) return;
    try {
      if (!kIsWeb) {
        final jetzt = await Clipboard.getData(Clipboard.kTextPlain);
        if (jetzt?.text != text) return;
        // Die Gegenstelle leert die Ablage ganz. Clipboard.setData('') legte
        // auf Windows einen leeren Eintrag in den Verlauf.
        if (await _leereNativ()) return;
      }
      await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {
      // Keine Zwischenablage, oder der Browser laesst es nicht zu — dann
      // gibt es nichts mehr, was diese App tun koennte.
    }
  }

  static Future<bool> _leereNativ() async {
    try {
      return await _kanal.invokeMethod<bool>('leere') == true;
    } catch (_) {
      return false;
    }
  }
}
