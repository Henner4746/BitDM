// qr_rundlauf_test.dart — der angezeigte Code muss vom eigenen Leser lesbar
// sein.
//
// WARUM DAS DER EINZIGE TEST IST, DER HIER ETWAS AUSSAGT
// Man kann pruefen, dass der Kodierer eine Matrix liefert, und dass der Leser
// eine Matrix versteht. Beides kann stimmen, waehrend die Kette trotzdem
// reisst — an der Ruhezone, an der Polaritaet, an der Modulbreite. Deshalb
// geht dieser Test den ganzen Weg: Adresse -> Matrix -> ein Bild, wie eine
// Kamera es liefert -> Leser -> Adresse.
//
// WAS ER GEFUNDEN HAETTE
// Bis zum 26.07.2026 zeichnete die App gar keinen QR-Code, sondern ein Muster
// aus einem Hash der Adresse ("25x25 fake-but-deterministic QR" stand als
// Kommentar daneben). Jeder Scanversuch — mit BitDM oder mit einer beliebigen
// anderen App — musste scheitern. Dieser Test waere nie gruen geworden.

import 'dart:math';
import 'dart:typed_data';

import 'package:bitdm/core/qr_bild.dart';
import 'package:bitdm/core/qr_leser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Malt die Matrix in ein Graustufenbild, so wie eine Kamera es sehen wuerde.
///
/// [modul] ist die Kantenlaenge eines Moduls in Bildpunkten, [rand] die
/// Ruhezone in Modulen. [dunkel]/[hell] sind Helligkeitswerte — damit laesst
/// sich auch ein umgekehrter Code bauen und pruefen, ob er noch lesbar ist.
Uint8List male(
  List<List<bool>> feld, {
  int modul = 6,
  int rand = 4,
  int dunkel = 20,
  int hell = 235,
}) {
  final n = feld.length;
  final kante = (n + 2 * rand) * modul;
  final bild = Uint8List(kante * kante)..fillRange(0, kante * kante, hell);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (!feld[y][x]) continue;
      for (var dy = 0; dy < modul; dy++) {
        final zeile = ((y + rand) * modul + dy) * kante;
        for (var dx = 0; dx < modul; dx++) {
          bild[zeile + (x + rand) * modul + dx] = dunkel;
        }
      }
    }
  }
  return bild;
}

int kanteVon(List<List<bool>> feld, {int modul = 6, int rand = 4}) =>
    (feld.length + 2 * rand) * modul;

void main() {
  final leser = QrLeser();

  // Eine Adresse aus einem echten Lauf: 56 Zeichen Base32, Kleinbuchstaben.
  const adresse = 'muwlhp6gz5ctvhas35udstzqe3ilaay5gdceqgamn4whunuo55ji2cnf';

  group('Was die App zeigt, kann die App auch lesen', () {
    test('DER RUNDLAUF — Adresse rein, Adresse raus', () {
      final feld = QrBild.matrixVon(adresse);
      expect(feld, isNotNull, reason: 'der Kodierer liefert nichts');

      final k = kanteVon(feld!);
      final gelesen = leser.lies(male(feld), k, k, k);

      expect(gelesen, adresse);
    });

    test('auch klein: 3 Bildpunkte je Modul', () {
      // Auf einem Telefonbildschirm aus einem halben Meter Abstand ist ein
      // Modul nur wenige Bildpunkte breit.
      final feld = QrBild.matrixVon(adresse)!;
      final k = kanteVon(feld, modul: 3);
      expect(leser.lies(male(feld, modul: 3), k, k, k), adresse);
    });

    test('auch bei flauem Bild', () {
      // Bildschirmaufnahme durch eine Kamera: nie 0 und 255, sondern grau auf
      // hellgrau. Ein Leser, der auf einen festen Schwellwert setzt, faellt
      // genau hier um.
      final feld = QrBild.matrixVon(adresse)!;
      final k = kanteVon(feld);
      expect(leser.lies(male(feld, dunkel: 70, hell: 170), k, k, k), adresse);
    });

    test('mit Bildrauschen', () {
      final feld = QrBild.matrixVon(adresse)!;
      final k = kanteVon(feld);
      final bild = male(feld);
      final w = Random(7);
      for (var i = 0; i < bild.length; i++) {
        bild[i] = (bild[i] + w.nextInt(31) - 15).clamp(0, 255);
      }
      expect(leser.lies(bild, k, k, k), adresse);
    });

    test('mit aufgefuellten Zeilen, wie Android sie liefert', () {
      // Android fuellt Kamerazeilen auf eine Vielfache-von-N-Breite auf. Wer
      // bytesPerRow ignoriert, liest ein schraeg verzerrtes Bild.
      final feld = QrBild.matrixVon(adresse)!;
      final k = kanteVon(feld);
      const auffuellung = 27;
      final breit = k + auffuellung;
      final eng = male(feld);
      final bild = Uint8List(breit * k);
      for (var y = 0; y < k; y++) {
        bild.setRange(y * breit, y * breit + k, eng, y * k);
      }
      expect(leser.lies(bild, breit, k, k), adresse);
    });
  });

  group('Was die Wahl der Farben ausmacht', () {
    test('HELL AUF DUNKEL WIRD NICHT GELESEN — deshalb die helle Karte', () {
      // Kein Mangel des Lesers, sondern die Norm: ein QR-Code ist dunkel auf
      // hell. Diese Zusicherung steht hier, damit niemand die helle Karte auf
      // dem Bildschirm "Meine ID" ins dunkle Thema zurueckholt, ohne zu
      // wissen, was das kostet.
      final feld = QrBild.matrixVon(adresse)!;
      final k = kanteVon(feld);
      final umgekehrt = male(feld, dunkel: 235, hell: 20);
      expect(leser.lies(umgekehrt, k, k, k), isNull);
    });
  });

  group('Was der Kodierer aushaelt', () {
    test('jede Laenge, die vorkommen kann', () {
      for (final s in ['a', adresse, 'A' * 200]) {
        final feld = QrBild.matrixVon(s);
        expect(feld, isNotNull, reason: '${s.length} Zeichen');
        final k = kanteVon(feld!);
        expect(leser.lies(male(feld), k, k, k), s);
      }
    });

    test('leerer Inhalt gibt null statt einer Ausnahme', () {
      // Waehrend des Starts steht die eigene Adresse noch nicht fest. Ein
      // geworfener Fehler an dieser Stelle liesse den ganzen Bildschirm rot
      // werden — fuer einen Bruchteil einer Sekunde, in dem ohnehin nichts zu
      // sehen sein soll.
      expect(QrBild.matrixVon(''), isNull);
    });
  });
}
