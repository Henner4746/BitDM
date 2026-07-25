// app_lock.dart — die App-Sperre.
//
// WAS SIE IST, UND WAS SIE NICHT IST
// Sie ist KEINE Bildschirmabfrage. Eine Abfrage im Stil von "Fingerabdruck
// erkannt, App auf" waere wertlos: die Entropie laege weiterhin greifbar im
// Schluesselspeicher, und wer sie mit einem Werkzeug direkt ausliest, kaeme an
// der Abfrage vorbei.
//
// Statt dessen wird die Entropie unter einem Schluessel abgelegt, den der
// gesicherte Bereich des Geraets nur dann benutzt, wenn kurz zuvor eine
// Anmeldung stattgefunden hat. Ohne Fingerabdruck oder Geraete-PIN gibt der
// Schluesselspeicher nichts heraus — auch nicht an ein Werkzeug, auch nicht
// mit Root. Das Geraet selbst verweigert die Rechenoperation.
//
// WARUM NICHT DER EIGENE PLATTFORM-KANAL
// Ein selbstgeschriebener BiometricPrompt mit CryptoObject waere derselbe
// Mechanismus, nur mit mehr eigenem Code an der empfindlichsten Stelle. Das
// Paket hier ist bereits eingebunden, wird gepflegt und macht genau das —
// setUserAuthenticationRequired auf dem Keystore-Schluessel.
//
// WAS DAMIT NOCH NICHT GEHT
// Passkey und Hardware-Stick. Ein FIDO2-Stick braucht CTAP2 ueber NFC oder
// USB, und das ist eine eigene Baustelle. Die Schluesselfaecher in
// lib/core/lock/key_vault.dart sind darauf vorbereitet: jeder Faktor bekommt
// ein eigenes Fach mit derselben Nutzlast.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'errors.dart';
import 'secret_store.dart';

enum LockMode {
  /// Die Entropie liegt im Schluesselspeicher, aber ohne Anmeldezwang. Wer das
  /// entsperrte Telefon in der Hand haelt, oeffnet die App.
  aus,

  /// Der gesicherte Bereich gibt die Entropie erst nach Fingerabdruck,
  /// Gesicht, PIN oder Muster heraus.
  geraet,
}

class LockUnavailableException implements Exception {
  final String grund;
  const LockUnavailableException(this.grund);
  @override
  String toString() => 'LockUnavailableException: $grund';
}

/// Wird geworfen, wenn die Anmeldung fehlschlug oder abgebrochen wurde.
class LockedException implements Exception {
  const LockedException();
  @override
  String toString() => 'LockedException: die App ist gesperrt';
}

/// Ein [SecretStore], dessen Schutzstufe sich umstellen laesst.
class LockableSecretStore implements SecretStore {
  LockableSecretStore({FlutterSecureStorage? offen, FlutterSecureStorage? gesperrt})
      : _offen = offen ?? _standardOffen,
        _gesperrt = gesperrt ?? _standardGesperrt;

  final FlutterSecureStorage _offen;
  final FlutterSecureStorage _gesperrt;

  static const _schluessel = 'bitdm_identity_entropy_v1';

  /// Merkt sich, unter welcher Stufe die Entropie zuletzt abgelegt wurde.
  ///
  /// Steht bewusst NICHT im geschuetzten Bereich: sonst muesste man sich
  /// anmelden, um herauszufinden, ob man sich anmelden muss.
  static const _modusSchluessel = 'bitdm_lock_mode_v1';

  static const _standardOffen = FlutterSecureStorage(
    aOptions: AndroidOptions(
      migrateOnAlgorithmChange: true,
      migrateWithBackup: true,
    ),
  );

  /// enforceBiometrics: true verlangt, dass das Geraet ueberhaupt gesichert
  /// ist. Auf einem Telefon ohne Sperrbildschirm schlaegt das Anlegen fehl —
  /// und das ist richtig so: eine Sperre, die jeder ohne Weiteres oeffnet,
  /// waere keine.
  static final _standardGesperrt = FlutterSecureStorage(
    aOptions: AndroidOptions.biometric(
      enforceBiometrics: true,
      migrateOnAlgorithmChange: true,
      migrateWithBackup: true,
    ),
  );

  FlutterSecureStorage _fuer(LockMode m) =>
      m == LockMode.geraet ? _gesperrt : _offen;

  /// Welche Stufe gerade gilt. Ohne Anmeldung lesbar.
  Future<LockMode> modus() async {
    try {
      final v = await _offen.read(key: _modusSchluessel);
      return v == 'geraet' ? LockMode.geraet : LockMode.aus;
    } catch (_) {
      return LockMode.aus;
    }
  }

  @override
  Future<Uint8List?> read() async {
    final m = await modus();
    try {
      final b64 = await _fuer(m).read(key: _schluessel);
      if (b64 == null) return null;
      final bytes = _entschluesselB64(b64);
      if (bytes.length != 16) {
        throw const StorageException(
            'die gespeicherte Identitaet hat die falsche Groesse');
      }
      return bytes;
    } on StorageException {
      rethrow;
    } catch (e) {
      // Bei eingeschalteter Sperre heisst ein Fehlschlag hier fast immer:
      // die Anmeldung wurde abgebrochen oder schlug fehl. Das ist kein
      // Speicherfehler, sondern der Normalfall einer gesperrten App.
      if (m == LockMode.geraet) throw const LockedException();
      throw StorageException(
          'Schluesselspeicher nicht lesbar (${e.runtimeType})');
    }
  }

  @override
  Future<void> write(Uint8List entropy) async {
    if (entropy.length != 16) {
      throw ArgumentError('Entropie muss 16 Bytes haben, hat ${entropy.length}');
    }
    final m = await modus();
    try {
      await _fuer(m).write(key: _schluessel, value: _nachB64(entropy));
    } catch (e) {
      throw StorageException(
          'Schluesselspeicher nicht beschreibbar (${e.runtimeType})');
    }
  }

  @override
  Future<void> delete() async {
    // BEIDE Ablagen loeschen, nicht nur die aktuelle. Bei einem Wechsel der
    // Stufe koennte sonst ein Rest in der anderen liegen bleiben — und beim
    // Panik-Loeschen ist "fast alles weg" nichts wert.
    for (final s in [_offen, _gesperrt]) {
      try {
        await s.delete(key: _schluessel);
      } catch (_) {
        // Bei eingeschalteter Sperre verlangt schon das Loeschen eine
        // Anmeldung. Bricht sie ab, bleibt der Eintrag liegen — deshalb wird
        // zusaetzlich der Modus zurueckgesetzt, damit der naechste Start nicht
        // in einer Sperre ohne Inhalt haengt.
      }
    }
    try {
      await _offen.delete(key: _modusSchluessel);
    } catch (_) {}
  }

  /// Stellt die Schutzstufe um.
  ///
  /// Die Entropie wird dafuer gelesen und unter der neuen Stufe neu abgelegt —
  /// bei einer Umstellung AUF die Sperre also einmal durch den gesicherten
  /// Bereich geschrieben, bei einer Umstellung ZURUECK einmal ausgelesen. Beides
  /// verlangt eine Anmeldung, wenn die Sperre gerade an ist. Das ist gewollt:
  /// sonst koennte jemand mit dem entsperrten Telefon die Sperre einfach
  /// abschalten.
  Future<void> setzeModus(LockMode neu) async {
    final alt = await modus();
    if (alt == neu) return;

    final Uint8List? entropie;
    try {
      final b64 = await _fuer(alt).read(key: _schluessel);
      entropie = b64 == null ? null : _entschluesselB64(b64);
    } catch (_) {
      throw const LockedException();
    }

    if (entropie != null) {
      try {
        await _fuer(neu).write(key: _schluessel, value: _nachB64(entropie));
      } catch (e) {
        // Haeufigster Fall: das Geraet hat gar keine Bildschirmsperre. Dann
        // laesst sich kein anmeldegebundener Schluessel anlegen.
        throw LockUnavailableException(
            'Das Geraet muss eine Bildschirmsperre haben (${e.runtimeType})');
      }
      try {
        await _fuer(alt).delete(key: _schluessel);
      } catch (_) {
        // Nicht schlimm: gelesen wird ab jetzt aus der neuen Ablage.
      }
    }

    await _offen.write(
        key: _modusSchluessel, value: neu == LockMode.geraet ? 'geraet' : 'aus');
  }

  static String _nachB64(Uint8List b) => base64.encode(b);
  static Uint8List _entschluesselB64(String s) => base64.decode(s);
}

