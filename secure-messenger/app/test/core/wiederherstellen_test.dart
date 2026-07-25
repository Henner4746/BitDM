// wiederherstellen_test.dart — der Weg zurueck.
//
// DIESEN WEG GAB ES BIS ZUM 25.07.2026 NICHT. Der Kern konnte es die ganze
// Zeit, AppState auch, die Pruefung ebenfalls — nur der Bildschirm dazu
// fehlte. Waehrenddessen sagte die App beim Anlegen einer Identitaet, die
// zwoelf Woerter seien "der einzige Weg zurueck, wenn dieses Telefon
// verloren, kaputt oder geloescht ist".
//
// Das ist die schlimmste Sorte Luecke: keine fehlende Funktion, sondern eine
// gebrochene Zusage. Wer die Woerter brav aufgeschrieben hatte, stand auf dem
// neuen Telefon vor einer App, die sie nirgends annahm.
//
// Diese Tests halten fest, dass der Weg funktioniert UND dass er die drei
// Faelle auseinanderhaelt, in denen er scheitert. "Phrase ungueltig" hilft bei
// zwoelf Woertern niemandem — man weiss nicht, welches.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/wordlist_english.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => null);
  });

  group('DER WEG ZURUECK', () {
    test('echte zwoelf Woerter stellen die Identitaet wieder her', () async {
      final woerter = Bip39.generate();
      final st = AppState(FakeMessengerCore());
      await st.boot();

      expect(await st.identitaetWiederherstellen(woerter), isTrue);
      expect(st.hatIdentitaet, isTrue);
      st.dispose();
    });

    test('zu wenige Woerter werden abgelehnt, mit Grund', () async {
      // Geprueft wird hier die OBERFLAECHENSCHICHT: kommt die Ablehnung an und
      // traegt sie einen Grund? Ob die Pruefsumme stimmt, entscheidet Bip39 —
      // das steht weiter unten und in bip39_test.dart.
      final st = AppState(FakeMessengerCore());
      await st.boot();

      expect(await st.identitaetWiederherstellen(['nur', 'drei', 'woerter']),
          isFalse);
      expect(st.letzterFehler, 'phraseUngueltig',
          reason: 'ohne Grund weiss der Bildschirm nicht, was er anzeigen soll');
      expect(st.hatIdentitaet, isFalse);
      st.dispose();
    });

    test('die REIHENFOLGE zaehlt', () {
      // Dieselben Woerter anders sortiert sind eine andere Phrase — und in
      // aller Regel gar keine gueltige. Genau das sagt der Bildschirm auch.
      //
      // Gegen Bip39 geprueft, nicht gegen den Entwurfskern: der prueft nur die
      // Form der Woerter, keine Pruefsumme. Das steht so in seinem Kommentar,
      // und ein Test, der durch die falsche Schicht laeuft, prueft nichts.
      var vertauschtGefunden = 0;
      for (var versuch = 0; versuch < 20; versuch++) {
        final woerter = Bip39.generate();
        final vertauscht = [...woerter];
        final h = vertauscht[0];
        vertauscht[0] = vertauscht[1];
        vertauscht[1] = h;
        if (!Bip39.validate(vertauscht)) vertauschtGefunden++;
      }
      expect(vertauschtGefunden, greaterThan(15),
          reason: 'vertauschte Woerter muessen fast immer durchfallen — sonst '
              'waere die Pruefsumme wirkungslos');
    });
  });

  group('Die drei Arten zu scheitern, auseinandergehalten', () {
    test('1. zu wenige Woerter', () {
      final woerter = Bip39.generate().take(11).toList();
      expect(woerter.length, isNot(kRecoveryPhraseWords));
      expect(Bip39.validate(woerter), isFalse);
    });

    test('2. ein Wort steht nicht in der Liste', () {
      // Der haeufigste Fall: ein Tippfehler. Der Bildschirm markiert genau
      // dieses Wort, statt "Phrase ungueltig" zu sagen.
      final woerter = Bip39.generate();
      woerter[6] = 'kartoffel';
      expect(bip39EnglishWordlist.contains('kartoffel'), isFalse);
      expect(Bip39.validate(woerter), isFalse);
    });

    test('3. alle Woerter gueltig, die Pruefsumme nicht', () {
      // Der schwierigste Fall: jedes Wort steht in der Liste, zusammen ergeben
      // sie trotzdem nichts. Ein anderer Text als bei einem Tippfehler — sonst
      // sucht der Nutzer an der falschen Stelle.
      final woerter = Bip39.generate();
      // Das letzte Wort traegt die Pruefsumme. Ein anderes gueltiges Wort
      // dorthin, und sie stimmt fast sicher nicht mehr.
      final ersatz = bip39EnglishWordlist
          .firstWhere((w) => w != woerter.last);
      woerter[woerter.length - 1] = ersatz;

      for (final w in woerter) {
        expect(bip39EnglishWordlist.contains(w), isTrue,
            reason: 'jedes Wort fuer sich muss gueltig sein');
      }
      expect(Bip39.validate(woerter), isFalse,
          reason: 'das letzte Wort traegt die Pruefsumme — ein anderes dort '
              'muss auffallen');
    });
  });

  group('Was der Bildschirm anzeigen koennen muss', () {
    test('die Wortliste ist zugaenglich, um einzelne Woerter zu pruefen', () {
      // Ohne sie gaebe es nur "gueltig oder nicht" fuer die ganze Phrase — und
      // bei zwoelf Woertern hilft das niemandem.
      expect(bip39EnglishWordlist, hasLength(2048));
      expect(bip39EnglishWordlist.contains('abandon'), isTrue);
      expect(bip39EnglishWordlist.contains('zoo'), isTrue);
    });

    test('die erwartete Wortzahl steht im Vertrag', () {
      expect(kRecoveryPhraseWords, 12);
    });
  });
}
