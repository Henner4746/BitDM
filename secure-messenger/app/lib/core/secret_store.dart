// secret_store.dart — wo die Entropie liegt, aus der alles entsteht.
//
// 16 Bytes. Daraus werden die zwoelf Woerter, der Identitaetsschluessel, die
// Adresse und der Datenbankschluessel. Wer sie hat, IST der Nutzer.
//
// WARUM DIE ENTROPIE UND NICHT DER SEED
// Aus der Entropie lassen sich die zwoelf Woerter wieder herleiten, aus dem
// Seed nicht — BIP39 fuehrt die Woerter durch PBKDF2, und das laesst sich nicht
// umkehren. Wuerde nur der Seed gespeichert, koennte die App die Phrase in den
// Einstellungen nie wieder anzeigen. Der Seed wird beim Entsperren neu
// gerechnet; das kostet 2048 PBKDF2-Durchgaenge, also wenige Millisekunden,
// einmal je Start.
//
// WARUM EINE SCHNITTSTELLE UND NICHT DIREKT DAS PAKET
// Zwei Gruende. Erstens laeuft ein Plattform-Plugin in `flutter test` nicht —
// ohne diese Trennung waere der gesamte Kern nicht pruefbar. Zweitens soll
// spaeter die App-Sperre aus lib/core/lock/ an diese Stelle treten: dann liegt
// die Entropie nicht mehr im Schluesselspeicher des Geraets, sondern in einem
// Fach hinter Fingerabdruck oder Hardware-Stick. Der Kern merkt davon nichts.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'errors.dart';

abstract class SecretStore {
  /// Die gespeicherte Entropie, oder null, wenn es noch keine Identitaet gibt.
  Future<Uint8List?> read();

  /// Legt die Entropie ab. Ueberschreibt eine vorhandene.
  Future<void> write(Uint8List entropy);

  /// Loescht sie. Danach ist die Identitaet ohne die zwoelf Woerter weg.
  Future<void> delete();
}

/// Der Schluesselspeicher des Geraets.
class DeviceSecretStore implements SecretStore {
  DeviceSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                // BEIDE Schalter sind hier nicht optional.
                //
                // Das Paket wechselt zwischen Fassungen die Verfahren, mit
                // denen es verschluesselt. Ohne Migration liesse ein Update die
                // vorhandenen Daten unlesbar — bei einer App, deren einziger
                // Inhalt die Identitaet ist, hiesse das: die gesamte
                // Nutzerbasis ausgesperrt, mit einem Update, das sonst nichts
                // tut. Die Sicherung dazu haelt den Fall ab, dass die App
                // waehrend der Migration abgeschossen wird.
                migrateOnAlgorithmChange: true,
                migrateWithBackup: true,
              ),
            );

  final FlutterSecureStorage _storage;

  static const _schluessel = 'bitdm_identity_entropy_v1';

  @override
  Future<Uint8List?> read() async {
    try {
      final b64 = await _storage.read(key: _schluessel);
      if (b64 == null) return null;
      final bytes = base64.decode(b64);
      if (bytes.length != 16) {
        throw const StorageException(
            'die gespeicherte Identitaet hat die falsche Groesse');
      }
      return bytes;
    } on StorageException {
      rethrow;
    } catch (e) {
      // Die Meldung des Plugins koennte den Wert enthalten. Sie darf nicht
      // weitergereicht werden.
      throw StorageException(
          'Schluesselspeicher nicht lesbar (${e.runtimeType})');
    }
  }

  @override
  Future<void> write(Uint8List entropy) async {
    if (entropy.length != 16) {
      throw ArgumentError('Entropie muss 16 Bytes haben, hat ${entropy.length}');
    }
    try {
      await _storage.write(key: _schluessel, value: base64.encode(entropy));
    } catch (e) {
      throw StorageException(
          'Schluesselspeicher nicht beschreibbar (${e.runtimeType})');
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _storage.delete(key: _schluessel);
    } catch (e) {
      throw StorageException(
          'Schluesselspeicher nicht loeschbar (${e.runtimeType})');
    }
  }

}

/// Haelt die Entropie im Arbeitsspeicher — nach dem Neustart ist sie weg.
///
/// Fuer Tests, UND im Browser als Grundspeicher, solange kein App-Passwort
/// eingerichtet ist. Warum dort nicht der Schluesselspeicher des Pakets:
/// siehe main.dart bei `basis:`.
class InMemorySecretStore implements SecretStore {
  Uint8List? _wert;

  InMemorySecretStore([Uint8List? anfang]) : _wert = anfang;

  @override
  Future<Uint8List?> read() async => _wert;

  @override
  Future<void> write(Uint8List entropy) async {
    if (entropy.length != 16) {
      throw ArgumentError('Entropie muss 16 Bytes haben');
    }
    _wert = Uint8List.fromList(entropy);
  }

  @override
  Future<void> delete() async => _wert = null;
}
