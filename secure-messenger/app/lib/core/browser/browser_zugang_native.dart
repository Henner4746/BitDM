// Der Zweig fuer Android, Windows und Linux: hier gibt es nichts davon.
// Jeder Aufrufer steht hinter `kIsWeb`; ein Aufruf hier ist ein Fehler im
// Aufrufer und soll laut sein.

import 'dart:typed_data';

import '../lock/fach_ablage.dart';

FachAblage browserFachAblage(String schluessel) =>
    throw UnsupportedError('browserFachAblage gibt es nur im Browser');

Future<void> browserDownload(Uint8List daten, String name) =>
    throw UnsupportedError('browserDownload gibt es nur im Browser');

Future<Uint8List?> browserDateiLesen() =>
    throw UnsupportedError('browserDateiLesen gibt es nur im Browser');
