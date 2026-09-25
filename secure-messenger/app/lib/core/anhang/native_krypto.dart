// native_krypto.dart — AES-GCM ueber den Plattformkanal, mit Rueckfall.
//
// WARUM ES DAS GIBT
// GEMESSEN AM 26.07.2026, auf den Geraeten selbst, 32 MiB je Durchgang:
//
//                       Dart        nativ       Faktor
//   Galaxy S25 Ultra    12,5 MB/s   304,8 MB/s   24,3x
//   Galaxy S10 (2019)    6,4 MB/s   205,1 MB/s   32,1x
//
// Jedes ARMv8-Telefon hat AES in der Hardware; Dart kommt nicht daran. Fuer
// eine 5-GiB-Datei heisst das auf dem S10: 24 Sekunden statt 13 Minuten.
//
// DAMIT IST DIE VERSCHLUESSELUNG NICHT MEHR DER ENGPASS. Wi-Fi Direct schafft
// 20 bis 60 MB/s — ab jetzt ist der Funk die Grenze, und das ist die richtige
// Reihenfolge.
//
// ═══════════════════════════════════════════════════ DER RUECKFALL IST PFLICHT
//
// Der Kanal kann fehlen: in einem Einheitentest, auf einer anderen Plattform,
// nach einem Umbau am nativen Teil. Er kann auch mitten im Betrieb werfen —
// bei 32 MiB je Aufruf ist ein OutOfMemoryError kein hypothetischer Fall.
//
// Dann rechnet Dart. Langsam, aber richtig, und BITGLEICH: beide Fassungen
// liefern Chiffretext gefolgt vom 16-Byte-Tag. Ein Stueck, das nativ
// verschluesselt wurde, laesst sich in Dart entschluesseln und umgekehrt.
//
// Zweifach nachgewiesen, weil eine Stelle allein nicht reicht:
//   * StueckchiffreTest.kt auf der JVM gegen Vektoren, die die Dart-Fassung
//     erzeugt hat — das prueft Format und Parameter.
//   * anhang_tempo_test.dart auf dem TELEFON, wo beide Fassungen nebeneinander
//     laufen — das prueft den Anbieter, der dort wirklich rechnet (Conscrypt
//     ueber BoringSSL, nicht SunJCE wie auf der JVM).
//
// WAS NICHT PASSIEREN DARF: still im langsamen Weg landen und es niemandem
// sagen. [NativeStueckKrypto.imRueckfall] steht deshalb offen und erscheint
// im Verbindungstest.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'stueck_krypto.dart';

/// AES-256-GCM ueber `bitdm/krypto`, sonst ueber Dart.
class NativeStueckKrypto extends StueckKrypto {
  NativeStueckKrypto({
    MethodChannel? kanal,
    StueckKrypto rueckfall = const GcmStueckKrypto(),
  })  : _kanal = kanal ?? const MethodChannel('bitdm/krypto'),
        _rueckfall = rueckfall;

  final MethodChannel _kanal;
  final StueckKrypto _rueckfall;

  /// Null = noch nicht gefragt.
  bool? _nativVorhanden;

  /// Warum es nicht nativ geht. Null, solange alles gut ist.
  String? _grund;

  /// Wer auf der nativen Seite rechnet — "AndroidOpenSSL", wenn alles stimmt.
  ///
  /// Steht im Verbindungstest. Waere hier je "BC" zu lesen, rechnete
  /// BouncyCastle in reinem Java: bitgleich, aber zwanzigmal langsamer, und
  /// kein Test wuerde davon rot.
  String? anbieter;

  /// Ob gerade die langsame Dart-Fassung rechnet, und warum.
  ///
  /// Fuer den Verbindungstest. Eine App, die zehnmal langsamer geworden ist,
  /// ohne dass es irgendwo steht, ist schwerer zu untersuchen als eine, die
  /// gar nicht laeuft.
  String? get imRueckfall => _nativVorhanden == false ? (_grund ?? 'unbekannt') : null;

  Future<bool> _nativGehtNoch() async {
    final bekannt = _nativVorhanden;
    if (bekannt != null) return bekannt;
    try {
      // Die Antwort ist der Name des Anbieters, nicht nur ein Ja.
      final name = await _kanal.invokeMethod<String>('verfuegbar');
      anbieter = name;
      _nativVorhanden = name != null && name.isNotEmpty;
      if (!_nativVorhanden!) _grund = 'der Kanal meldet sich als nicht bereit';
    } on MissingPluginException {
      // Der Normalfall im Einheitentest und auf allem, was nicht Android ist.
      _nativVorhanden = false;
      _grund = 'kein nativer Kanal auf dieser Plattform';
    } catch (e) {
      _nativVorhanden = false;
      _grund = e.runtimeType.toString();
    }
    return _nativVorhanden!;
  }

  Future<Uint8List> _ruf(
    String verfahren, {
    required Uint8List daten,
    required Uint8List schluessel,
    required Uint8List nonce,
    required Uint8List zusatz,
  }) async {
    final aus = await _kanal.invokeMethod<Uint8List>(verfahren, {
      'daten': daten,
      'schluessel': schluessel,
      'nonce': nonce,
      'zusatz': zusatz,
    });
    if (aus == null) throw const StueckKaputt();
    return aus;
  }

  @override
  Future<Uint8List> verschluessle({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) async {
    if (await _nativGehtNoch()) {
      try {
        return await _ruf('zu',
            daten: klar,
            schluessel: schluessel,
            nonce: nonce,
            zusatz: StueckKrypto.zusatz(nummer, vonWievielen));
      } catch (e) {
        // AB JETZT DART, und zwar dauerhaft. Es bei jedem Stueck erneut zu
        // versuchen hiesse, bei einem Speicherproblem hundertmal
        // hintereinander 32 MiB anzufordern und hundertmal zu scheitern.
        _nativVorhanden = false;
        _grund = 'beim Verschluesseln: ${_kurz(e)}';
      }
    }
    return _rueckfall.verschluessle(
      klar: klar,
      schluessel: schluessel,
      nonce: nonce,
      nummer: nummer,
      vonWievielen: vonWievielen,
    );
  }

  @override
  Future<Uint8List> entschluessle({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required int nummer,
    required int vonWievielen,
  }) async {
    if (await _nativGehtNoch()) {
      try {
        return await _ruf('auf',
            daten: geheim,
            schluessel: schluessel,
            nonce: nonce,
            zusatz: StueckKrypto.zusatz(nummer, vonWievielen));
      } on PlatformException catch (e) {
        // HIER WIRD UNTERSCHIEDEN, und das ist der Kern dieser Methode.
        //
        // Ein Stueck, das nicht aufgeht, ist KEIN Grund, den Kanal
        // aufzugeben: es ist die richtige Antwort auf verdorbene oder
        // vertauschte Daten. Wer hier auf Dart zurueckfaellt, rechnet
        // dasselbe noch einmal langsam nach, bekommt dasselbe Ergebnis und
        // hat die App fuer den Rest der Sitzung verlangsamt — wegen eines
        // Fehlers, der gar keiner ist.
        //
        // AM CODE UND NICHT AM TEXT. Hier stand einmal ein
        // `message.contains('AEADBadTagException')`; das haelt genau so
        // lange, bis jemand auf der Kotlin-Seite die Meldung anfasst — und
        // dann faellt es nicht auf, sondern die App wird nur still langsam.
        if (e.code == 'KAPUTT') throw const StueckKaputt();
        _nativVorhanden = false;
        _grund = 'beim Entschluesseln: ${_kurz(e)}';
      } catch (e) {
        _nativVorhanden = false;
        _grund = 'beim Entschluesseln: ${_kurz(e)}';
      }
    }
    return _rueckfall.entschluessle(
      geheim: geheim,
      schluessel: schluessel,
      nonce: nonce,
      nummer: nummer,
      vonWievielen: vonWievielen,
    );
  }

  /// AES-256-GCM mit frei gewaehltem Zusatz, nativ mit Rueckfall auf Dart.
  ///
  /// Fuer die verschluesselte Ablage auf dem Geraet (ruhe_datei.dart): dort
  /// traegt der Zusatz Dateikopf, Stuecknummer und das Kennzeichen "letztes
  /// Stueck" — nicht die Form aus [StueckKrypto.zusatz]. Der Kanal nimmt den
  /// Zusatz ohnehin als rohe Bytes (KryptoKanal.kt), deshalb geht es ueber
  /// denselben Weg und dieselbe Hardware-Beschleunigung.
  ///
  /// DER RUECKFALL IST HIER IMMER DART (GcmStueckKrypto.zuRoh), nicht der
  /// hereingereichte [_rueckfall]: der kennt nur die Stueck-Form.
  Future<Uint8List> verschluessleRoh({
    required Uint8List klar,
    required Uint8List schluessel,
    required Uint8List nonce,
    required Uint8List zusatz,
  }) async {
    if (await _nativGehtNoch()) {
      try {
        return await _ruf('zu',
            daten: klar, schluessel: schluessel, nonce: nonce, zusatz: zusatz);
      } catch (e) {
        // Wie oben: ab jetzt dauerhaft Dart.
        _nativVorhanden = false;
        _grund = 'beim Verschluesseln: ${_kurz(e)}';
      }
    }
    return GcmStueckKrypto.zuRoh(
        klar: klar, schluessel: schluessel, nonce: nonce, zusatz: zusatz);
  }

  /// Gegenstueck zu [verschluessleRoh]. Wirft [StueckKaputt], wenn die Bytes
  /// nicht aufgehen — und faellt dann NICHT auf Dart zurueck (siehe
  /// [entschluessle]).
  Future<Uint8List> entschluessleRoh({
    required Uint8List geheim,
    required Uint8List schluessel,
    required Uint8List nonce,
    required Uint8List zusatz,
  }) async {
    if (await _nativGehtNoch()) {
      try {
        return await _ruf('auf',
            daten: geheim, schluessel: schluessel, nonce: nonce, zusatz: zusatz);
      } on PlatformException catch (e) {
        if (e.code == 'KAPUTT') throw const StueckKaputt();
        _nativVorhanden = false;
        _grund = 'beim Entschluesseln: ${_kurz(e)}';
      } catch (e) {
        _nativVorhanden = false;
        _grund = 'beim Entschluesseln: ${_kurz(e)}';
      }
    }
    return GcmStueckKrypto.aufRoh(
        geheim: geheim, schluessel: schluessel, nonce: nonce, zusatz: zusatz);
  }

  static String _kurz(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    return e.runtimeType.toString();
  }
}
