// stick_zugang.dart — den Weg zum Stick aufbauen und wieder abbauen.
//
// Die Transporte selbst (ctap_nfc.dart, ctap_hid.dart) wissen nichts davon,
// woher sie ihre Bytes bekommen — genau deshalb lassen sie sich mit
// aufgezeichneten Antworten pruefen. Diese Datei ist die Stelle, an der es
// konkret wird: NFC-Sitzung starten, auf den Stick warten, hinterher wieder
// aufraeumen.
//
// WARUM DAS AUFRAEUMEN HIER WICHTIG IST
// Eine offene NFC-Sitzung blockiert die naechste. Wer sie nach einem
// Fehlschlag stehen laesst, bekommt beim zweiten Versuch nichts mehr — und
// der Nutzer haelt den Stick an ein Telefon, das nicht mehr zuhoert. Deshalb
// ist trenne() hier nicht leer, sondern beendet die Sitzung wirklich.

import 'dart:async';
import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import 'ctap.dart';
import 'ctap_hid.dart';
import 'ctap_nfc.dart';
import 'usb_hid_geraet.dart';

/// Wie der Stick angeschlossen ist.
enum StickWeg {
  /// Auflegen. Braucht kein Kabel, ist aber empfindlich gegen Verrutschen.
  nfc,

  /// Einstecken. Zuverlaessiger, weil der Kontakt nicht abreissen kann.
  usb,
}

class KeinStickException implements Exception {
  final String grund;
  const KeinStickException(this.grund);
  @override
  String toString() => 'KeinStickException: $grund';
}

/// Baut einen [StickOeffner], wie ihn die Schluesselfaecher erwarten.
///
/// Jeder Aufruf baut eine FRISCHE Verbindung. Das ist Absicht: zwischen zwei
/// Arbeitsschritten kann der Nutzer den Stick abgenommen haben, und eine
/// wiederverwendete Sitzung waere dann tot, ohne dass man es ihr ansieht.
Future<CtapTransport> Function() stickOeffner(
  StickWeg weg, {
  Duration frist = const Duration(seconds: 30),
}) {
  return () => switch (weg) {
        StickWeg.nfc => _ueberNfc(frist),
        StickWeg.usb => _ueberUsb(),
      };
}

Future<CtapTransport> _ueberUsb() async {
  final sticks = await UsbHidGeraet.liste();
  if (sticks.isEmpty) {
    throw const KeinStickException(
        'Kein Sicherheitsschluessel eingesteckt. Bei USB-C direkt anstecken — '
        'ueber einen Adapter erkennt Android ihn oft nicht.');
  }
  return CtapHidTransport(await UsbHidGeraet.oeffne(name: sticks.first.name));
}

Future<CtapTransport> _ueberNfc(Duration frist) async {
  if (await NfcManager.instance.checkAvailability() !=
      NfcAvailability.enabled) {
    throw const KeinStickException(
        'NFC ist aus oder nicht verfuegbar. In den Android-Einstellungen '
        'einschalten.');
  }

  final gefunden = Completer<IsoDepAndroid>();
  await NfcManager.instance.startSession(
    pollingOptions: {NfcPollingOption.iso14443},
    onDiscovered: (tag) async {
      if (gefunden.isCompleted) return;
      final iso = IsoDepAndroid.from(tag);
      if (iso == null) {
        gefunden.completeError(const KeinStickException(
            'Das ist kein Sicherheitsschluessel — die Karte spricht kein '
            'ISO-DEP.'));
        return;
      }
      gefunden.complete(iso);
    },
  );

  try {
    final iso = await gefunden.future.timeout(frist);
    return _NfcSitzung(CtapNfcTransport(iso.transceive));
  } catch (e) {
    // Bei einer Zeitueberschreitung oder einer falschen Karte muss die Sitzung
    // weg, sonst blockiert sie den naechsten Versuch.
    await NfcManager.instance.stopSession();
    if (e is TimeoutException) {
      throw const KeinStickException(
          'Kein Sicherheitsschluessel aufgelegt.');
    }
    rethrow;
  }
}

/// Ein NFC-Transport, der seine Sitzung mitnimmt.
class _NfcSitzung implements CtapTransport {
  _NfcSitzung(this._innen);

  final CtapNfcTransport _innen;

  @override
  String get name => _innen.name;

  @override
  Future<void> verbinde() => _innen.verbinde();

  @override
  Future<Uint8List> sende(Uint8List befehl) => _innen.sende(befehl);

  @override
  Future<void> trenne() async {
    await _innen.trenne();
    await NfcManager.instance.stopSession();
  }
}
