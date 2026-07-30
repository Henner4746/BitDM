// funkzustand_test.dart — was die Oberflaeche ueber den Funk weiss.
//
// Geprueft wird nicht das Aussehen, sondern die Buchfuehrung darunter: welchen
// Grund die Oberflaeche anzeigen WUERDE, und ob sie den Unterschied zwischen
// "abgelehnt" und "abgelehnt und Android fragt nicht mehr" behaelt.
//
// Genau daran haengt, ob ein Knopf erscheint, bei dem etwas passiert, oder
// einer, bei dem sichtbar nichts passiert — und das ist der Unterschied
// zwischen einer App, die man versteht, und einer, der man nicht mehr traut.

import 'package:bitdm/app_state.dart';
import 'package:bitdm/core/fake_messenger_core.dart';
import 'package:bitdm/core/nah/funk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ein Funk, der antwortet, wie der Test es vorgibt.
class FunkAttrappe implements Nahfunk {
  FunkAttrappe(this.zustandWert);

  Funkzustand? zustandWert;
  Rechtelage naechsteLage = Rechtelage.erteilt;

  /// Wenn gesetzt, wirft `zustand()`.
  FunkFehler? zustandFehler;

  int abfragen = 0;
  int rechteAbfragen = 0;
  bool einstellungenGeoeffnet = false;

  @override
  Future<Funkzustand> zustand() async {
    abfragen++;
    final f = zustandFehler;
    if (f != null) throw f;
    return zustandWert!;
  }

  @override
  Future<Rechtelage> fordereRechte() async {
    rechteAbfragen++;
    // Wie in Wirklichkeit: nach dem Erteilen sagt der Zustand etwas anderes.
    if (naechsteLage == Rechtelage.erteilt) {
      zustandWert = const Funkzustand(
          zuAlt: false, vorhanden: true, an: true, rechte: true, jeWerbung: 40);
    }
    return naechsteLage;
  }

  @override
  Future<void> oeffneEinstellungen() async => einstellungenGeoeffnet = true;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}

Funkzustand zustand({
  bool zuAlt = false,
  bool vorhanden = true,
  bool an = true,
  bool rechte = true,
}) =>
    Funkzustand(
        zuAlt: zuAlt,
        vorhanden: vorhanden,
        an: an,
        rechte: rechte,
        jeWerbung: 40);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState st;

  setUp(() async {
    // `setzeEinstellungen` legt die Bildschirmfoto-Sperre um, und die geht
    // ueber einen Plattformkanal. Ohne Attrappe scheitert hier jeder Test,
    // der eine Einstellung anfasst — mit einer Meldung, die nach Bindung
    // klingt und nichts mit dem Fall zu tun hat.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('bitdm/fenster'), (_) async => true);
    st = AppState(FakeMessengerCore());
    await st.boot();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bitdm/fenster'), null);
    st.dispose();
  });

  group('Ohne Funk', () {
    test('bleibt alles ruhig statt zu werfen', () async {
      // Auf einem Geraet ohne Bluetooth und in jedem Test ohne
      // Plattformkanaele ist `funk` null. Eine App, die daran haengenbleibt,
      // waere wegen einer Ausfallsicherung unbenutzbar.
      await expectLater(st.pruefeFunk(), completes);
      expect(st.funkzustand, isNull);
      expect(await st.erlaubeFunk(), isFalse);
      await expectLater(st.oeffneSystemeinstellungen(), completes);
    });
  });

  group('Zustand holen', () {
    test('wird uebernommen', () async {
      st.funk = FunkAttrappe(zustand());
      await st.pruefeFunk();
      expect(st.funkzustand!.geht, isTrue);
      expect(st.funkzustand!.jeWerbung, 40);
    });

    test('JEDES MAL neu, nicht einmal gemerkt', () async {
      // Bluetooth laesst sich ausserhalb der App umschalten. Eine gemerkte
      // Antwort waere spaetestens beim zweiten Hinsehen falsch.
      final f = FunkAttrappe(zustand());
      st.funk = f;
      await st.pruefeFunk();
      await st.pruefeFunk();
      expect(f.abfragen, 2);
    });

    test('ein Fehler laesst den Zustand leer statt falsch', () async {
      final f = FunkAttrappe(zustand())
        ..zustandFehler = const FunkFehler('FUNK', 'weg');
      st.funk = f;
      await st.pruefeFunk();
      expect(st.funkzustand, isNull,
          reason: 'lieber nichts anzeigen als etwas Falsches');
    });

    test('geht ist falsch, sobald EIN Grund dagegen spricht', () async {
      for (final z in [
        zustand(zuAlt: true),
        zustand(vorhanden: false),
        zustand(an: false),
        zustand(rechte: false),
      ]) {
        st.funk = FunkAttrappe(z);
        await st.pruefeFunk();
        expect(st.funkzustand!.geht, isFalse);
      }
    });
  });

  group('Rechte', () {
    test('erteilt: der Zustand wird gleich mit aufgefrischt', () async {
      final f = FunkAttrappe(zustand(rechte: false))
        ..naechsteLage = Rechtelage.erteilt;
      st.funk = f;
      await st.pruefeFunk();
      expect(st.funkzustand!.geht, isFalse);

      expect(await st.erlaubeFunk(), isTrue);
      expect(st.funkzustand!.geht, isTrue,
          reason: 'sonst zeigt die Oberflaeche nach dem Erlauben weiter, dass '
              'die Berechtigung fehlt');
      expect(st.rechteEndgueltigWeg, isFalse);
    });

    test('abgelehnt: man darf wieder fragen', () async {
      st.funk = FunkAttrappe(zustand(rechte: false))
        ..naechsteLage = Rechtelage.abgelehnt;
      expect(await st.erlaubeFunk(), isFalse);
      expect(st.rechteEndgueltigWeg, isFalse,
          reason: 'der Knopf "Erlauben" muss bleiben');
    });

    test('DAUERHAFT ABGELEHNT ist etwas anderes als abgelehnt', () async {
      // Der Unterschied, an dem die Oberflaeche haengt: hier hilft nur noch
      // der Weg ueber die Systemeinstellungen. Wer weiter "Erlauben" anbietet,
      // baut einen Knopf, bei dem sichtbar nichts passiert.
      st.funk = FunkAttrappe(zustand(rechte: false))
        ..naechsteLage = Rechtelage.dauerhaftAbgelehnt;
      expect(await st.erlaubeFunk(), isFalse);
      expect(st.rechteEndgueltigWeg, isTrue);
    });

    test('und der Merker geht wieder weg, wenn es doch klappt', () async {
      // Sonst bliebe der Weg in die Systemeinstellungen fuer immer stehen —
      // auch nachdem der Nutzer dort war und es erteilt hat.
      final f = FunkAttrappe(zustand(rechte: false))
        ..naechsteLage = Rechtelage.dauerhaftAbgelehnt;
      st.funk = f;
      await st.erlaubeFunk();
      expect(st.rechteEndgueltigWeg, isTrue);

      f.naechsteLage = Rechtelage.erteilt;
      expect(await st.erlaubeFunk(), isTrue);
      expect(st.rechteEndgueltigWeg, isFalse);
    });

    test('zu alt zaehlt nicht als dauerhaft abgelehnt', () async {
      // Es gibt dort nichts zu erlauben. Ein Verweis auf die
      // Systemeinstellungen waere ein Weg ins Leere.
      st.funk = FunkAttrappe(zustand(zuAlt: true))
        ..naechsteLage = Rechtelage.zuAlt;
      expect(await st.erlaubeFunk(), isFalse);
      expect(st.rechteEndgueltigWeg, isFalse);
    });
  });

  group('Die Einstellung selbst', () {
    test('naheAn ist ab Werk aus', () {
      expect(st.einstellungen.naheAn, isFalse);
    });

    test('und laesst sich unabhaengig von nurNahbereich setzen', () async {
      // Zwei Schalter, nicht einer. Waeren sie gekoppelt, gaebe es entweder
      // keine Ausfallsicherung ohne Spurlos-Modus oder umgekehrt.
      await st.setzeEinstellungen(st.einstellungen.copyWith(naheAn: true));
      expect(st.einstellungen.naheAn, isTrue);
      expect(st.einstellungen.nurNahbereich, isFalse);

      await st.setzeEinstellungen(
          st.einstellungen.copyWith(nurNahbereich: true));
      expect(st.einstellungen.naheAn, isTrue,
          reason: 'der eine darf den anderen nicht mitziehen');
    });
  });

  test('der Umschalter meldet sich bei der Oberflaeche', () async {
    // Ohne notifyListeners bliebe die Anzeige stehen, bis der Nutzer sonst
    // etwas anfasst — und der Grund, warum es nicht geht, waere veraltet.
    st.funk = FunkAttrappe(zustand());
    var gemeldet = 0;
    st.addListener(() => gemeldet++);
    await st.pruefeFunk();
    expect(gemeldet, greaterThan(0));
  });
}
