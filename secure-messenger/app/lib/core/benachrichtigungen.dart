// benachrichtigungen.dart — Hinweise auf neue Nachrichten.
//
// WAS IN EINER BENACHRICHTIGUNG STEHT, UND WAS NICHT
//
// Nichts vom Inhalt. Keine Vorschau, kein Absender im Klartext.
//
// Das ist keine Bequemlichkeitsentscheidung. Eine Benachrichtigung erscheint
// auf dem GESPERRTEN Bildschirm — sie ist die einzige Stelle, an der eine
// Nachricht ohne jede Anmeldung sichtbar wird. Wer neben dem Telefon steht,
// liest sie mit; wer es findet, sieht sie ohne Entsperren. Bei einer App, die
// eine Bildschirmsperre und verschluesselte Datenbanken hat, waere eine
// Textvorschau das offene Fenster in einem sonst verschlossenen Haus.
//
// Dazu kommt: die Nachricht kommt VERSCHLUESSELT an. Sie fuer die
// Benachrichtigung zu entschluesseln, hiesse den Ratchet weiterzudrehen und
// den Klartext auszurechnen — an einer Stelle, wo er hinterher nur angezeigt
// und weggeworfen wird.
//
// Es steht also nur da, DASS etwas da ist. Wer es war und was drinsteht,
// erfaehrt man nach dem Entsperren.
//
// KEIN GOOGLE
// flutter_local_notifications nutzt die Systemschnittstellen von Android,
// nicht Firebase. Kein Push-Dienst, kein Konto, keine Kennung, die
// irgendwohin gemeldet wird.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Benachrichtigungen {
  Benachrichtigungen._();
  static final Benachrichtigungen instanz = Benachrichtigungen._();

  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;

  /// Ein einziger Kanal. Mehrere waeren nur dann sinnvoll, wenn sie sich
  /// unterschiedlich stumm schalten liessen — und dafuer muessten sie
  /// unterschiedliche Dinge ankuendigen.
  static const _kanalId = 'bitdm_nachrichten';

  static const _kanal = AndroidNotificationChannel(
    _kanalId,
    'Nachrichten',
    description: 'Hinweis, dass eine neue Nachricht da ist. Ohne Inhalt.',
    importance: Importance.high,
  );

  Future<void> starte() async {
    if (_bereit) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_kanal);
      _bereit = true;
    } catch (_) {
      // Auf dem Rechner gibt es das Plugin nicht. Kein Grund, die App
      // deswegen nicht zu starten.
      _bereit = false;
    }
  }

  /// Fragt die Erlaubnis an. Ab Android 13 noetig.
  ///
  /// BEWUSST NICHT BEIM START: eine App, die vor dem ersten Bildschirm nach
  /// Benachrichtigungen fragt, bekommt meistens ein Nein. Gefragt wird, wenn
  /// die erste Unterhaltung zustande kommt — dann ist klar, wofuer.
  Future<bool> frageErlaubnis() async {
    if (!_bereit) return false;
    try {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Meldet, dass etwas angekommen ist — ohne zu sagen, was oder von wem.
  ///
  /// [anzahl] ist die Zahl noch nicht gelesener Nachrichten. Mehrere
  /// Meldungen zu stapeln waere schlechter: jede einzelne verriete einen
  /// Zeitpunkt, und aus Zeitpunkten laesst sich ein Gespraechsverlauf
  /// ablesen, auch ohne Inhalt.
  Future<void> zeigeNeueNachricht({required int anzahl, required String text}) async {
    if (!_bereit) return;
    try {
      await _plugin.show(
        // Immer dieselbe Kennung: die neue Meldung ersetzt die alte, statt
        // sich zu stapeln. Jede einzelne verriete sonst einen Zeitpunkt, und
        // aus Zeitpunkten laesst sich ein Gespraechsverlauf ablesen.
        id: 1,
        title: 'BitDM',
        body: text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _kanalId,
            'Nachrichten',
            importance: Importance.high,
            priority: Priority.high,
            // Auf dem Sperrbildschirm gar nichts zeigen. Das ist die
            // eigentliche Entscheidung dieser Datei.
            visibility: NotificationVisibility.secret,
            // Keine Vorschau, kein Absender — also auch keine Gruppierung
            // nach Gespraech, die wieder verriete, mit wem.
            showWhen: false,
            category: AndroidNotificationCategory.message,
          ),
        ),
      );
      if (kDebugMode) {
        // ignore: avoid_print
        print('Benachrichtigung: $anzahl neue');
      }
    } catch (_) {
      // Verweigerte Erlaubnis oder fehlendes Plugin. Kein Fehler, der
      // irgendwen aufhalten sollte.
    }
  }

  Future<void> raeumeAuf() async {
    if (!_bereit) return;
    try {
      await _plugin.cancel(id: 1);
    } catch (_) {}
  }

  /// Die Warnung vor einer Fernloeschung — mit EIGENER Kennung (2). Bis
  /// 25.09.2026 teilte sie sich die 1 mit den Nachrichten: die naechste
  /// Nachricht ersetzte sie, und [raeumeAuf] beim Oeffnen der App nahm sie
  /// weg, obwohl der Countdown weiterlief. Der Text ist neutral (siehe
  /// AppState.fernWarnText); auch diese Meldung ist auf dem Sperrbildschirm
  /// unsichtbar.
  Future<void> zeigeWarnung({required String text}) async {
    if (!_bereit) return;
    try {
      await _plugin.show(
        id: 2,
        title: 'BitDM',
        body: text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _kanalId,
            'Nachrichten',
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.secret,
            showWhen: false,
            ongoing: true,
          ),
        ),
      );
    } catch (_) {}
  }

  /// Nimmt die Warnung weg — beim Abbruch der Fernloeschung und danach.
  Future<void> nimmWarnungWeg() async {
    if (!_bereit) return;
    try {
      await _plugin.cancel(id: 2);
    } catch (_) {}
  }
}
