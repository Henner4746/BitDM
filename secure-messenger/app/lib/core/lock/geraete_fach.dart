// geraete_fach.dart — der gesicherte Bereich des Geraets, ueber eigenen Kanal.
//
// WARUM NICHT flutter_secure_storage
// Das Paket baut seinen Anmeldedialog mit dem Application-Context und meldet
// sich nie an der Activity an. Auf manchen Geraeten — auf Samsung
// regelmaessig — erscheint dabei GAR KEIN Dialog. Beim Antippen passiert dann
// nichts: kein Fingerabdruck, kein Fehler, kein Hinweis. Genau so war es am
// 25.07.2026 auf einem S25 Ultra.
//
// Ausserdem leitet das Paket KeyStore-Alias, Einstellungsdatei und
// Schluesselspeicher alle drei aus EINEM Namensraum ab. Zwei Ablagen ohne
// eigene Namensraeume teilen sich damit den Schluessel — und die
// eingeschaltete Migration schreibt die Daten stillschweigend auf einen
// Schluessel ohne Anmeldezwang um. Die Anmeldung faellt weg, ohne dass es
// jemandem auffaellt.
//
// Der eigene Kanal (android/.../SchluesselfachKanal.kt) macht beides richtig:
// Dialog ueber die Activity, ein eigener Schluessel je Art.
//
// WAS HIER GESPEICHERT WIRD
// Ein 32-Byte-Fachschluessel, nicht die Identitaet. Er liegt verschluesselt in
// einer gewoehnlichen Datei; der Schluessel dazu entsteht im gesicherten
// Bereich und verlaesst ihn nie. Ohne Anmeldung verweigert das Geraet die
// Rechnung — auch mit Root, auch mit der Datei in der Hand.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'keystore_factor.dart';

/// Welche Anmeldung das Fach verlangt.
enum GeraeteArt {
  /// Nur Fingerabdruck oder Gesicht. Die Geraete-PIN ist ausgeschlossen —
  /// sonst waeren es keine zwei Faktoren, sondern einer mit zwei Namen.
  biometrie('biometrie'),

  /// PIN, Muster oder Passwort des Telefons.
  geraetesperre('geraetesperre');

  const GeraeteArt(this.kennung);
  final String kennung;
}

/// Was das Geraet ueber eine Anmeldeart sagt.
class GeraeteStand {
  final bool ok;

  /// Im Klartext, was fehlt. Null, wenn alles da ist.
  final String? grund;

  const GeraeteStand(this.ok, this.grund);
}

/// Wird geworfen, wenn die Anmeldung nicht klappte.
class AnmeldungFehlgeschlagen implements Exception {
  final String grund;

  /// Ob der Nutzer selbst abgebrochen hat. Dann ist es kein Fehler, sondern
  /// eine Entscheidung — und die Oberflaeche soll keine rote Meldung zeigen.
  final bool abgebrochen;

  const AnmeldungFehlgeschlagen(this.grund, {this.abgebrochen = false});

  @override
  String toString() => 'AnmeldungFehlgeschlagen: $grund';
}

/// Wird geworfen, wenn diese Anmeldeart auf diesem Geraet nicht geht.
class GeraetKannNicht implements Exception {
  final String grund;
  const GeraetKannNicht(this.grund);
  @override
  String toString() => 'GeraetKannNicht: $grund';
}

/// Der gesicherte Bereich, ueber den eigenen Kanal.
class GeraeteFach implements SchluesselAblage {
  GeraeteFach(this.art, {required this.verzeichnis, MethodChannel? kanal})
      : _kanal = kanal ?? const MethodChannel('bitdm/schluesselfach');

  final GeraeteArt art;

  /// Wo die verschluesselten Fachschluessel liegen. Neben der Fachdatei.
  final String verzeichnis;

  final MethodChannel _kanal;

  File _datei(String schluessel) =>
      File('$verzeichnis${Platform.pathSeparator}$schluessel.bin');

  /// Fragt das Geraet, ob diese Anmeldeart ueberhaupt geht.
  ///
  /// VORHER fragen, nicht hinterher: sonst tippt der Nutzer, und dann kommt
  /// ein Dialog, der nie erscheint.
  Future<GeraeteStand> verfuegbar() async {
    try {
      final antwort = await _kanal.invokeMapMethod<String, Object?>(
          'verfuegbar', {'art': art.kennung});
      return GeraeteStand(
          antwort?['ok'] == true, antwort?['grund'] as String?);
    } on PlatformException catch (e) {
      return GeraeteStand(false, e.message);
    } on MissingPluginException {
      return const GeraeteStand(
          false, 'Diese Fassung der App kennt den Schluesselspeicher nicht.');
    }
  }

  @override
  Future<void> schreibe(String schluessel, String wert) async {
    final geheim = await _rufe('schreibe', Uint8List.fromList(utf8.encode(wert)));
    await _datei(schluessel).writeAsBytes(geheim, flush: true);
  }

  @override
  Future<String?> lies(String schluessel) async {
    final datei = _datei(schluessel);
    if (!datei.existsSync()) return null;
    final klar = await _rufe('lies', await datei.readAsBytes());
    return utf8.decode(klar);
  }

  @override
  Future<void> loesche(String schluessel) async {
    try {
      final datei = _datei(schluessel);
      if (datei.existsSync()) datei.deleteSync();
    } catch (_) {
      // Die Datei bleibt vielleicht liegen. Ohne den Schluessel im gesicherten
      // Bereich ist sie wertlos, und der geht gleich mit.
    }
    try {
      await _kanal.invokeMethod<bool>('loesche', {'art': art.kennung});
    } catch (_) {
      // Auch hier: ein Rest schadet nicht, ein Abbruch des Aufraeumens schon.
    }
  }

  Future<Uint8List> _rufe(String methode, Uint8List daten) async {
    try {
      final antwort = await _kanal.invokeMethod<Uint8List>(
          methode, {'art': art.kennung, 'wert': daten});
      if (antwort == null) {
        throw const AnmeldungFehlgeschlagen('Das Geraet lieferte nichts');
      }
      return antwort;
    } on PlatformException catch (e) {
      final text = e.message ?? e.code;
      throw switch (e.code) {
        'NICHT_VERFUEGBAR' => GeraetKannNicht(text),
        'ABGEBROCHEN' => AnmeldungFehlgeschlagen(text, abgebrochen: true),
        _ => AnmeldungFehlgeschlagen(text),
      };
    } on MissingPluginException {
      throw const GeraetKannNicht(
          'Diese Fassung der App kennt den Schluesselspeicher nicht.');
    }
  }
}
