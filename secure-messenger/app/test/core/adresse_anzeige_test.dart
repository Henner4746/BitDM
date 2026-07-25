// adresse_anzeige_test.dart — dass Anzeige, Beispiel und Zwischenablage
// dasselbe Format haben.
//
// ZWEI FEHLER, DIE HIER FESTGENAGELT WERDEN, WAREN AM 25.07.2026 ECHT:
//
//   1. Beim Einlesen eines QR-Codes lief `RegExp(r'[s-]')` ueber die Adresse.
//      Das ist eine Zeichenklasse aus 's' und '-', nicht "Leerraum oder
//      Strich". Aus jeder gescannten Adresse fiel damit der BUCHSTABE s
//      heraus — und Adressen sind Base32 in Kleinbuchstaben, s kommt in fast
//      jeder vor. Das Ergebnis scheiterte an der Pruefsumme, und es sah aus,
//      als taugte der QR-Code nicht.
//
//   2. Das Beispiel im Eingabefeld zeigte Striche, die Zwischenablage lieferte
//      die rohe Adresse ohne. Wer kopierte und einfuegte, hielt das
//      Eingefuegte fuer falsch.
//
// Beide sind die Sorte Fehler, die kein Test der Krypto findet: alles rechnet
// richtig, und trotzdem kommt der Nutzer nicht ans Ziel.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/crypto/address.dart';
import 'package:flutter_test/flutter_test.dart';

/// Eine Adresse, die den Buchstaben s enthaelt — also fast jede.
const mitS = 'b3xk7qmd2ftv9sln4hrw6jyc8pzb5nkq7wdm3xrs';

void main() {
  group('DER FEHLER: das falsche Zeichenklassen-Regex', () {
    test('[s-] entfernt den Buchstaben s — [\\s\\-] nicht', () {
      // Der Beweis, dass die beiden Schreibweisen etwas voellig Verschiedenes
      // bedeuten. Wer das einmal gesehen hat, verwechselt es nicht wieder.
      expect(mitS.replaceAll(RegExp(r'[s-]'), ''), isNot(mitS),
          reason: 'die falsche Fassung frisst Buchstaben');
      expect(mitS.replaceAll(RegExp(r'[\s\-]'), ''), mitS,
          reason: 'die richtige laesst die Adresse in Ruhe');
    });

    test('normalize laesst jeden Buchstaben stehen', () {
      // So wird es jetzt gemacht: nicht selbst herumschneiden, sondern die
      // Funktion nehmen, die es kann.
      expect(BitdmAddress.normalize(mitS), mitS);
      expect(BitdmAddress.normalize(adresseFormatiert(mitS)), mitS,
          reason: 'auch die Fassung mit Strichen muss zurueckfuehren');
    });

    test('mit Leerraum und Strichen durcheinander', () {
      expect(BitdmAddress.normalize(' B3XK-7QMD 2FTV-9SLN\n'),
          'b3xk7qmd2ftv9sln');
    });
  });

  group('Anzeige, Beispiel und Zwischenablage sind dasselbe Format', () {
    test('das Beispiel sieht aus wie eine formatierte Adresse', () {
      // Ohne diesen Test darf jemand das Beispiel wieder von Hand hinschreiben
      // — und genau daran ist es schon einmal auseinandergelaufen.
      final ohnePunkte = beispielAdresse.replaceAll('…', '');
      expect(ohnePunkte, contains('-'));
      expect(ohnePunkte, ohnePunkte.toUpperCase(),
          reason: 'die App zeigt Adressen in Grossbuchstaben');
      expect(adresseFormatiert(BitdmAddress.normalize(ohnePunkte)), ohnePunkte,
          reason: 'das Beispiel muss durch dieselbe Funktion gehen wie alles '
              'andere, sonst laeuft es wieder auseinander');
    });

    test('Vierergruppen mit Strichen', () {
      expect(adresseFormatiert('b3xk7qmd2ftv'), 'B3XK-7QMD-2FTV');
    });

    test('formatiert und wieder zurueck ergibt das Original', () {
      expect(BitdmAddress.normalize(adresseFormatiert(mitS)), mitS);
    });
  });
}
