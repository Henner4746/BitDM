// push.dart — angestossen werden, ohne dauernd zu lauschen.
//
// WARUM UnifiedPush UND NICHT GOOGLE
// Der uebliche Weg waere Firebase. Dann saehe Google zu jeder Nachricht den
// Zeitpunkt und die Haeufigkeit — bei einer App ohne Telefonnummer und ohne
// Konto waere das die einzige Metadatenspur, die sie sonst nirgends
// hinterlaesst. Ausserdem waeren Play Services Pflicht, und F-Droid,
// GrapheneOS und /e/OS fielen weg.
//
// Bei UnifiedPush waehlt der Nutzer selbst, wer verteilt. Bei BitDM ist das
// push.bitdm.net — derselbe Betreiber, der ohnehin den Relay hat. Es kommt
// also kein Dritter dazu.
//
// WAS DABEI UEBERTRAGEN WIRD: NICHTS
// Der Anstoss ist leer. Kein Absender, kein Inhalt, keine Anzahl. Die App
// verbindet sich daraufhin selbst zum Relay und holt die Nachricht dort ab,
// verschluesselt wie immer. Ein Absender im Anstoss stuende unverschluesselt
// auf dem Sperrbildschirm und im Protokoll jedes Servers dazwischen.
//
// WAS ES BRAUCHT
// Einen Verteiler auf dem Telefon — bei ntfy ist das die ntfy-App. Ohne einen
// solchen gibt es kein UnifiedPush; das ist keine Einschraenkung dieser App,
// sondern die Bauart des Verfahrens. Die Oberflaeche sagt es auch.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';

/// Wo BitDM angestossen wird.
///
/// Ueberschreibbar beim Bauen:
///   flutter build apk --dart-define=BITDM_PUSH=https://push.example.org
const String pushBasis = String.fromEnvironment(
  'BITDM_PUSH',
  defaultValue: 'https://push.bitdm.net',
);

/// Woran es liegt, wenn Push nicht geht.
enum PushHindernis {
  /// Kein Verteiler auf dem Telefon. Ohne einen gibt es kein UnifiedPush.
  keinVerteiler,

  /// Der Verteiler hat die Anmeldung abgelehnt.
  abgelehnt,

  /// Der Verteiler nennt einen Endpunkt auf einem fremden Server.
  ///
  /// Dann wuerde der Relay ihn ohnehin ablehnen — er nimmt nur eigene
  /// Push-Server an, sonst waere er ein Werkzeug, mit dem sich beliebige
  /// fremde Server anschreiben lassen.
  fremderServer,
}

class PushException implements Exception {
  final PushHindernis grund;
  final String? text;
  const PushException(this.grund, [this.text]);

  @override
  String toString() => 'PushException: $grund${text == null ? '' : ' ($text)'}';
}

/// Die Anbindung an den Verteiler auf dem Telefon.
class PushAnbindung {
  PushAnbindung({
    required this.beiEndpunkt,
    required this.beiAnstoss,
    required this.beiAbmeldung,
  });

  /// Wird gerufen, wenn ein Endpunkt feststeht — beim Einrichten und immer
  /// dann, wenn der Verteiler ihn von sich aus wechselt.
  ///
  /// DASS ER SICH AENDERN KANN, ist der Grund, warum das ein Rueckruf ist und
  /// keine einmalige Abfrage: ntfy vergibt bei einer Neuinstallation ein neues
  /// Thema. Wer den alten Endpunkt beim Relay stehen laesst, wird nie wieder
  /// angestossen und merkt es nicht.
  final void Function(String endpunkt) beiEndpunkt;

  /// Wird gerufen, wenn ein Anstoss ankommt. Der Inhalt ist leer und wird
  /// bewusst nicht durchgereicht.
  final void Function() beiAnstoss;

  /// Der Verteiler hat die Anmeldung beendet — etwa weil die ntfy-App
  /// deinstalliert wurde.
  final void Function() beiAbmeldung;

  var _bereit = false;

  /// Meldet die Rueckrufe an. Muss vor allem anderen laufen, und zwar bei
  /// JEDEM App-Start: ein Anstoss kann kommen, bevor der Nutzer irgendetwas
  /// getan hat.
  Future<void> starte() async {
    if (_bereit) return;
    await UnifiedPush.initialize(
      onNewEndpoint: (endpunkt, _) => beiEndpunkt(endpunkt.url),
      onRegistrationFailed: (_, __) {},
      onUnregistered: (_) => beiAbmeldung(),
      onMessage: (_, __) => beiAnstoss(),
    );
    _bereit = true;
  }

  /// Welche Verteiler auf diesem Telefon installiert sind.
  Future<List<String>> verteiler() async {
    try {
      return await UnifiedPush.getDistributors();
    } catch (_) {
      return const [];
    }
  }

  /// Welcher gerade benutzt wird.
  Future<String?> aktuellerVerteiler() async {
    try {
      return await UnifiedPush.getDistributor();
    } catch (_) {
      return null;
    }
  }

  /// Meldet BitDM beim Verteiler an.
  ///
  /// Der Endpunkt kommt NICHT von hier zurueck, sondern spaeter ueber
  /// [beiEndpunkt] — der Verteiler fragt dafuer erst seinen Server.
  Future<void> melde({String? verteilerName}) async {
    await starte();

    final name = verteilerName ?? await aktuellerVerteiler();
    if (name == null) {
      final vorhandene = await verteiler();
      if (vorhandene.isEmpty) {
        throw const PushException(PushHindernis.keinVerteiler);
      }
      // Nur EINER da: den nehmen, statt eine Auswahl mit einem Eintrag zu
      // zeigen. Sind es mehrere, muss der Nutzer waehlen — die Oberflaeche
      // fragt dann.
      if (vorhandene.length > 1) {
        throw const PushException(PushHindernis.keinVerteiler);
      }
      await UnifiedPush.saveDistributor(vorhandene.single);
    } else {
      await UnifiedPush.saveDistributor(name);
    }

    try {
      await UnifiedPush.register();
    } catch (e) {
      throw PushException(PushHindernis.abgelehnt, '$e');
    }
  }

  /// Meldet BitDM wieder ab. Danach kommt kein Anstoss mehr.
  Future<void> melde_ab() async {
    try {
      await UnifiedPush.unregister();
    } catch (e) {
      // Ein Verteiler, der schon weg ist, kann nichts mehr abmelden. Der
      // Endpunkt beim Relay wird ohnehin getrennt geloescht.
      if (kDebugMode) debugPrint('Abmelden am Verteiler: $e');
    }
  }

  /// Ob dieser Endpunkt auf dem eigenen Push-Server liegt.
  ///
  /// GEPRUEFT WIRD SCHON HIER, obwohl der Relay es noch einmal tut. Nicht aus
  /// Misstrauen gegen den Verteiler, sondern damit die Meldung stimmt: der
  /// Relay antwortet nur mit "ungueltig", die App kann sagen, WARUM.
  static bool eigenerServer(String endpunkt) {
    final erlaubt = Uri.tryParse(pushBasis);
    final ist = Uri.tryParse(endpunkt);
    if (erlaubt == null || ist == null) return false;
    return ist.scheme == 'https' &&
        ist.host == erlaubt.host &&
        ist.path.startsWith('/up');
  }
}
