// lager_client.dart — reden mit dem Zwischenlager.
//
// Drei Wege, mehr gibt es dort nicht:
//
//   PUT    /ablegen/<kennung>     braucht eine Marke vom Relay
//   GET    /blob/<kennung>        braucht nichts — die Kennung IST die Erlaubnis
//   DELETE /wegwerfen/<kennung>   braucht nichts
//
// ═══════════════════════════════ DIE ADRESSE KOMMT NICHT VOM RELAY
//
// Der Relay schickt in seiner Antwort fertige Adressen mit ("ablegen",
// "holen", "wegwerfen"). Sie werden hier BEWUSST NICHT benutzt. Der Client
// kennt die Kennung — er hat sie selbst gewuerfelt — und er kennt seinen
// Lagerplatz aus der eigenen Einstellung. Mehr braucht es nicht.
//
// Wuerde er die Adressen uebernehmen, koennte ein uebernommener oder
// veraenderter Relay die Uploads auf einen fremden Rechner umlenken. Der
// Inhalt bliebe zwar verschluesselt, aber wer die Bloecke bekommt, entschiede
// dann der Server. Die Marke, die der Relay ausstellt, ist das einzige, was
// von ihm uebernommen wird — und die ist an Kennung und Groesse gebunden.
//
// ═══════════════════════════════════════ WARUM dart:io UND KEIN PAKET
//
// HttpClient kann alles, was hier gebraucht wird: stroemen statt sammeln,
// Bereichs-Anfragen, Zeitgrenzen. Ein Paket dafuer waere zusaetzliche
// Angriffsflaeche fuer eine Sache, die die Standardbibliothek beherrscht —
// und dieselbe Ueberlegung hat schon google_fonts aus dem Projekt geworfen.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../net/netzweg.dart';

class LagerException implements Exception {
  const LagerException(this.grund, {this.status});
  final String grund;
  final int? status;
  @override
  String toString() =>
      'LagerException: $grund${status == null ? '' : ' (HTTP $status)'}';
}

/// Das Lager hat keinen Platz mehr. Eigener Fehler, weil die Oberflaeche
/// darauf etwas anderes sagen muss als bei einem gewoehnlichen Fehlschlag:
/// spaeter noch einmal versuchen hilft, sofort noch einmal nicht.
class LagerVoll extends LagerException {
  const LagerVoll() : super('kein Platz mehr', status: 507);
}

/// Der Block liegt nicht (mehr) da. Nach vierzehn Tagen ist er weg, und wenn
/// der Empfaenger ihn schon geholt hat, hat er ihn selbst weggeworfen.
class LagerLeer extends LagerException {
  const LagerLeer() : super('gibt es nicht (mehr)', status: 404);
}

/// Die Erlaubnis des Relays, ein Stueck abzulegen.
class Marke {
  const Marke({
    required this.kennung,
    required this.groesse,
    required this.ablauf,
    required this.marke,
  });

  final String kennung;

  /// Die Groesse IM LAGER, also mit dem Beglaubigungsanhang. Fuer eine andere
  /// Groesse gilt die Marke nicht.
  final int groesse;

  /// Unix-Sekunden.
  final int ablauf;

  final String marke;
}

class LagerClient {
  LagerClient({
    required this.basis,
    HttpClient? httpClient,
    Duration? stille,
  })  : _eigenerClient = httpClient == null,
        _http = httpClient ?? Netzweg.httpClient(),
        stille = stille ?? const Duration(seconds: 60) {
    _http.connectionTimeout = const Duration(seconds: 20);
  }

  /// Etwa `https://dateien.bitdm.net`.
  final Uri basis;

  /// Wie lange OHNE JEDEN FORTSCHRITT gewartet wird, bevor abgebrochen wird.
  ///
  /// Ausdruecklich keine Gesamtdauer: ein Gigabyte ueber Mobilfunk darf eine
  /// Stunde brauchen. Was nicht sein darf, ist eine Verbindung, ueber die
  /// minutenlang nichts mehr kommt — die haelt sonst den ganzen Versand auf.
  final Duration stille;

  final HttpClient _http;
  final bool _eigenerClient;

  Uri _pfad(String teil, String kennung) =>
      basis.replace(path: '/$teil/$kennung');

  // ═══════════════════════════════════════════════════════════ Hochladen

  /// Legt ein fertig verschluesseltes Stueck ab.
  ///
  /// [geheim] muss GENAU so gross sein wie in der Marke angekuendigt — der
  /// Dienst zaehlt beim Schreiben mit und bricht sonst ab.
  Future<void> lege(Marke m, Uint8List geheim,
      {void Function(int)? fortschritt}) async {
    if (geheim.length != m.groesse) {
      // Nicht erst den Server sagen lassen, was hier schon feststeht. Ein
      // 413 nach drei Gigabyte ist eine teure Art, einen Rechenfehler zu
      // bemerken.
      throw LagerException(
          'Stueck ist ${geheim.length} Byte, die Marke gilt fuer ${m.groesse}');
    }

    final anfrage = await _http
        .openUrl('PUT', _pfad('ablegen', m.kennung))
        .timeout(stille, onTimeout: () => throw const LagerException(
            'das Lager antwortet nicht'));

    anfrage.headers
      ..set('X-Bitdm-Size', '${m.groesse}')
      ..set('X-Bitdm-Expires', '${m.ablauf}')
      ..set('X-Bitdm-Token', m.marke)
      ..contentLength = m.groesse;

    // In Haeppchen schreiben, nicht in einem Stueck: so kommt der Fortschritt
    // laufend an, und der Speicher bleibt beieinander. Auf der anderen Seite
    // steht `proxy_request_buffering off` — die Bytes gehen also wirklich
    // durch bis auf die Platte, waehrend hier noch geschrieben wird.
    const haeppchen = 256 * 1024;
    for (var pos = 0; pos < geheim.length; pos += haeppchen) {
      final bis = (pos + haeppchen).clamp(0, geheim.length);
      anfrage.add(Uint8List.sublistView(geheim, pos, bis));
      await anfrage.flush().timeout(stille,
          onTimeout: () => throw const LagerException('Uebertragung steht'));
      fortschritt?.call(bis);
    }

    final antwort = await anfrage.close().timeout(stille,
        onTimeout: () => throw const LagerException('keine Antwort'));
    await antwort.drain<void>();

    if (antwort.statusCode == 507) throw const LagerVoll();
    if (antwort.statusCode != 200) {
      throw LagerException('Ablegen abgelehnt', status: antwort.statusCode);
    }
  }

  // ═════════════════════════════════════════════════════════ Herunterladen

  /// Holt ein Stueck. [abByte] setzt eine abgebrochene Uebertragung fort.
  ///
  /// Das Fortsetzen ist der Grund, warum nginx den Download direkt macht:
  /// Bereichs-Anfragen kann es von sich aus. Ohne sie faengt jedes Funkloch
  /// das Stueck von vorne an.
  Future<Uint8List> hole(
    String kennung, {
    required int erwarteteGroesse,
    int abByte = 0,
    void Function(int)? fortschritt,
  }) async {
    final anfrage = await _http
        .openUrl('GET', _pfad('blob', kennung))
        .timeout(stille, onTimeout: () => throw const LagerException(
            'das Lager antwortet nicht'));
    if (abByte > 0) {
      anfrage.headers.set(HttpHeaders.rangeHeader, 'bytes=$abByte-');
    }

    final antwort = await anfrage.close().timeout(stille,
        onTimeout: () => throw const LagerException('keine Antwort'));

    if (antwort.statusCode == 404) {
      await antwort.drain<void>();
      throw const LagerLeer();
    }
    final erwartet = abByte > 0 ? 206 : 200;
    if (antwort.statusCode != erwartet) {
      await antwort.drain<void>();
      throw LagerException('Holen abgelehnt', status: antwort.statusCode);
    }

    // Der Platz wird VORHER reserviert, in genau der Groesse aus der
    // Anleitung. Ein Server, der mehr schickt, als angekuendigt war, laeuft
    // damit nicht in den Speicher, sondern in einen Fehler.
    final ziel = Uint8List(erwarteteGroesse - abByte);
    var geschrieben = 0;

    await for (final stueck in antwort.timeout(stille,
        onTimeout: (s) => s.addError(
            const LagerException('Uebertragung steht')))) {
      if (geschrieben + stueck.length > ziel.length) {
        throw const LagerException('mehr Daten als angekuendigt');
      }
      ziel.setAll(geschrieben, stueck);
      geschrieben += stueck.length;
      fortschritt?.call(geschrieben);
    }

    if (geschrieben != ziel.length) {
      // Eine abgeschnittene Uebertragung. Der Aufrufer kann mit
      // abByte + geschrieben fortsetzen — deshalb steht die Zahl im Fehler.
      throw LagerException(
          'nur $geschrieben von ${ziel.length} Byte angekommen');
    }
    return ziel;
  }

  // ══════════════════════════════════════════════════════════ Wegwerfen

  /// Wirft ein Stueck weg. Fehler werden VERSCHLUCKT.
  ///
  /// Das ist Absicht: Wegwerfen ist Aufraeumen, kein Arbeitsschritt. Ist es
  /// schon weg, ist das Ziel erreicht; klemmt das Netz, holt es die
  /// Kehrmaschine des Lagers nach vierzehn Tagen. Einen Empfang deshalb
  /// scheitern zu lassen, waere das Gegenteil von hilfreich.
  Future<void> wirfWeg(String kennung) async {
    try {
      final anfrage = await _http.openUrl('DELETE', _pfad('wegwerfen', kennung));
      final antwort = await anfrage.close().timeout(const Duration(seconds: 15));
      await antwort.drain<void>();
    } catch (_) {
      // absichtlich still
    }
  }

  void schliesse() {
    if (_eigenerClient) _http.close(force: true);
  }
}
