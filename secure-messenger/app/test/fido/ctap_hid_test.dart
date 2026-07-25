// ctap_hid_test.dart — die USB-Verpackung, ohne USB.
//
// Hier stecken die Fehler, die man sonst erst mit einem eingesteckten Stick
// findet — und dann nur bei bestimmten Befehlen: die Zerlegung greift erst ab
// 58 Byte, das Zusammensetzen erst ab einer laengeren Antwort, und Keepalive
// kommt nur, wenn eine Beruehrung noetig ist.
//
// Mit einem nachgestellten Geraet lassen sich genau diese Faelle gezielt
// herstellen.

import 'dart:typed_data';

import 'package:bitdm/core/fido/ctap_hid.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List b(List<int> l) => Uint8List.fromList(l);

/// Ein nachgestellter Stick am USB-Anschluss.
class FakeHid implements HidGeraet {
  FakeHid(this.antworten);

  final List<Uint8List> antworten;
  final geschrieben = <Uint8List>[];
  var _i = 0;
  var geschlossen = false;

  @override
  Future<void> schreibe(Uint8List bericht64) async {
    // Ein CTAPHID-Paket ist IMMER 64 Byte. Kuerzere nimmt kein Stick an.
    expect(bericht64.length, CtapHidTransport.paketGroesse,
        reason: 'jedes Paket muss genau 64 Byte sein');
    geschrieben.add(bericht64);
  }

  @override
  Future<Uint8List> lies({Duration frist = const Duration(seconds: 5)}) async {
    if (_i >= antworten.length) throw StateError('nichts mehr vorbereitet');
    return antworten[_i++];
  }

  @override
  Future<void> schliesse() async => geschlossen = true;
}

/// Baut ein Anfangspaket.
Uint8List anfang(int kanal, int cmd, List<int> daten, {int? laenge}) {
  final p = Uint8List(64);
  p[0] = (kanal >> 24) & 0xFF;
  p[1] = (kanal >> 16) & 0xFF;
  p[2] = (kanal >> 8) & 0xFF;
  p[3] = kanal & 0xFF;
  p[4] = cmd;
  final l = laenge ?? daten.length;
  p[5] = (l >> 8) & 0xFF;
  p[6] = l & 0xFF;
  p.setRange(7, 7 + daten.length, daten);
  return p;
}

/// Baut ein Fortsetzungspaket.
Uint8List fortsetzung(int kanal, int nummer, List<int> daten) {
  final p = Uint8List(64);
  p[0] = (kanal >> 24) & 0xFF;
  p[1] = (kanal >> 16) & 0xFF;
  p[2] = (kanal >> 8) & 0xFF;
  p[3] = kanal & 0xFF;
  p[4] = nummer & 0x7F;
  p.setRange(5, 5 + daten.length, daten);
  return p;
}

const kanal = 0x11223344;

/// Die INIT-Antwort: Nonce gespiegelt, dann die neue Kanalkennung.
Uint8List initAntwort(List<int> nonce) => anfang(
      0xFFFFFFFF,
      0x86,
      [...nonce, 0x11, 0x22, 0x33, 0x44, 2, 1, 0, 0, 0],
    );

void main() {
  group('Kanal holen', () {
    test('INIT geht auf den Rundruf-Kanal und liefert eine eigene Kennung',
        () async {
      late List<int> nonce;
      final geraet = FakeHid([]);
      // Das Nonce steht erst fest, wenn geschrieben wurde — deshalb in zwei
      // Schritten.
      final transport = CtapHidTransport(geraet);
      geraet.antworten.add(Uint8List(64)); // Platzhalter, gleich ersetzt

      // Schreiben abfangen, Nonce lesen, passende Antwort einsetzen.
      final vorbereitet = FakeHid([]);
      final t2 = CtapHidTransport(vorbereitet);
      try {
        await vorbereitet.schreibe(Uint8List(64));
      } catch (_) {}
      // Einfacher: ueber den echten Ablauf.
      final g = _MitspielendesGeraet();
      await CtapHidTransport(g).verbinde();

      expect(g.geschrieben.first.sublist(0, 4), [0xFF, 0xFF, 0xFF, 0xFF],
          reason: 'INIT geht auf den Rundruf-Kanal');
      expect(g.geschrieben.first[4], 0x86, reason: 'CTAPHID_INIT');
      expect(g.geschrieben.first[6], 8, reason: 'acht Byte Nonce');

      // Die beiden ungenutzten Objekte nur, damit der Test lesbar bleibt.
      expect(transport.name, 'USB');
      expect(t2.name, 'USB');
      nonce = g.geschrieben.first.sublist(7, 15);
      expect(nonce, hasLength(8));
    });

    test('eine Antwort mit fremdem Nonce wird abgelehnt', () async {
      // An einem Anschluss koennen mehrere Programme gleichzeitig mit dem
      // Stick reden. Ohne diese Pruefung nimmt man die Antwort auf die Anfrage
      // eines anderen.
      final g = FakeHid([initAntwort(List.filled(8, 0x99))]);
      expect(() => CtapHidTransport(g).verbinde(),
          throwsA(isA<FormatException>()));
    });
  });

  group('Zerlegen beim Senden', () {
    test('ein kurzer Befehl passt in ein Paket', () async {
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();
      g.naechsteAntwort = [anfang(kanal, 0x90, [0x00, 0xA1])];

      await t.sende(b([0x04]));

      final p = g.geschrieben.last;
      expect(p[4], 0x90, reason: 'CTAPHID_CBOR');
      expect((p[5] << 8) | p[6], 1);
      expect(p[7], 0x04);
    });

    test('ein langer Befehl wird auf mehrere Pakete verteilt', () async {
      // DER FEHLER, DEN DAS VERHINDERT: alles ueber 57 Byte muss zerlegt
      // werden. Wer das ignoriert, kann kleine Befehle schicken und scheitert
      // erst beim Anlegen eines Zugangs — dem Befehl, auf den es ankommt.
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();
      g.naechsteAntwort = [anfang(kanal, 0x90, [0x00])];

      final lang = Uint8List.fromList(List.generate(200, (i) => i & 0xFF));
      await t.sende(lang);

      final pakete = g.geschrieben.sublist(1); // ohne INIT
      expect(pakete, hasLength(4), reason: '57 + 59 + 59 + 25');
      expect((pakete[0][5] << 8) | pakete[0][6], 200,
          reason: 'die Gesamtlaenge steht im ERSTEN Paket');
      expect(pakete[1][4], 0, reason: 'erste Fortsetzung hat Nummer 0');
      expect(pakete[2][4], 1);
      expect(pakete[3][4], 2);
      for (final p in pakete.skip(1)) {
        expect(p[4] & 0x80, 0,
            reason: 'bei Fortsetzungen darf das Anfangsbit NICHT stehen');
      }

      // Und der Inhalt kommt vollstaendig und in der richtigen Reihenfolge an.
      final wieder = <int>[
        ...pakete[0].sublist(7, 64),
        ...pakete[1].sublist(5, 64),
        ...pakete[2].sublist(5, 64),
        ...pakete[3].sublist(5, 5 + 25),
      ];
      expect(wieder, lang);
    });
  });

  group('Zusammensetzen beim Empfangen', () {
    test('eine lange Antwort wird vollstaendig gelesen', () async {
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();

      final inhalt = List.generate(150, (i) => (i * 3) & 0xFF);
      g.naechsteAntwort = [
        anfang(kanal, 0x90, inhalt.sublist(0, 57), laenge: 150),
        fortsetzung(kanal, 0, inhalt.sublist(57, 116)),
        fortsetzung(kanal, 1, inhalt.sublist(116)),
      ];

      expect(await t.sende(b([0x04])), inhalt);
    });

    test('ein fehlendes Stueck wird gemeldet statt uebersprungen', () async {
      // Stillschweigend weiterzumachen ergaebe stellenweise falsches CBOR —
      // ein Fehler, der viel spaeter und ganz woanders auffaellt.
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();
      g.naechsteAntwort = [
        anfang(kanal, 0x90, List.filled(57, 1), laenge: 150),
        fortsetzung(kanal, 1, List.filled(59, 2)), // 0 fehlt
      ];
      expect(() => t.sende(b([0x04])), throwsA(isA<FormatException>()));
    });

    test('Keepalive wird uebersprungen, nicht fuer die Antwort gehalten',
        () async {
      // Waehrend der Stick auf eine Beruehrung wartet, schickt er im
      // Sekundentakt 0x3B. Das erste davon fuer die Antwort zu halten ergaebe
      // Unsinn — und zwar nur bei Befehlen, die eine Beruehrung brauchen.
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();
      g.naechsteAntwort = [
        anfang(kanal, 0xBB, [0x02]), // "warte auf Beruehrung"
        anfang(kanal, 0xBB, [0x02]),
        anfang(kanal, 0x90, [0x00, 0xF6]),
      ];

      expect(await t.sende(b([0x04])), [0x00, 0xF6]);
    });

    test('Pakete eines fremden Kanals werden uebergangen', () async {
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();
      g.naechsteAntwort = [
        anfang(0xAABBCCDD, 0x90, [0xFF, 0xFF]), // gehoert jemand anderem
        anfang(kanal, 0x90, [0x00, 0x42]),
      ];
      expect(await t.sende(b([0x04])), [0x00, 0x42]);
    });

    test('ein CTAPHID-Fehler wird als solcher gemeldet', () async {
      final g = _MitspielendesGeraet();
      final t = CtapHidTransport(g);
      await t.verbinde();
      g.naechsteAntwort = [anfang(kanal, 0xBF, [0x01])];
      expect(() => t.sende(b([0x04])), throwsA(isA<FormatException>()));
    });
  });

  test('ohne verbinde() wird nicht gesendet', () async {
    final t = CtapHidTransport(FakeHid([]));
    expect(() => t.sende(b([0x04])), throwsStateError);
  });
}

/// Ein Stick, der beim INIT das gesendete Nonce korrekt zurueckspiegelt.
class _MitspielendesGeraet implements HidGeraet {
  final geschrieben = <Uint8List>[];
  List<Uint8List> naechsteAntwort = [];
  final _warteschlange = <Uint8List>[];

  @override
  Future<void> schreibe(Uint8List bericht64) async {
    expect(bericht64.length, 64);
    geschrieben.add(bericht64);

    // Beim INIT das Nonce spiegeln — sonst lehnt der Transport zu Recht ab.
    if (bericht64[4] == 0x86 && bericht64[0] == 0xFF) {
      _warteschlange.add(initAntwort(bericht64.sublist(7, 15)));
    } else if (_warteschlange.isEmpty) {
      _warteschlange.addAll(naechsteAntwort);
    }
  }

  @override
  Future<Uint8List> lies({Duration frist = const Duration(seconds: 5)}) async {
    if (_warteschlange.isEmpty) {
      if (naechsteAntwort.isEmpty) throw StateError('nichts vorbereitet');
      _warteschlange.addAll(naechsteAntwort);
      naechsteAntwort = [];
    }
    return _warteschlange.removeAt(0);
  }

  @override
  Future<void> schliesse() async {}
}
