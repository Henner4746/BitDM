// ctap_hid.dart — CTAP2 ueber USB.
//
// Ein eingesteckter Sicherheitsschluessel meldet sich als HID-Geraet, wie eine
// Tastatur. Gesprochen wird in Paketen von genau 64 Byte — nicht mehr, nicht
// weniger, auch wenn nur drei Byte Inhalt drin sind.
//
// EIN BEFEHL, DER NICHT IN 64 BYTE PASST, WIRD ZERLEGT:
//
//   Erstes Paket:    KANAL(4) CMD(1) LAENGE(2) DATEN(57)
//   Folgepakete:     KANAL(4) NUMMER(1)        DATEN(59)
//
// Das oberste Bit im fuenften Byte unterscheidet beides: gesetzt heisst
// "Anfang", nicht gesetzt heisst "Fortsetzung, laufende Nummer". Wer das
// verwechselt, schickt einen Befehl, den der Stick als Fortsetzung eines nie
// begonnenen deutet — und bekommt keine Antwort, sondern Stille.
//
// DER KANAL MUSS ERST ERFRAGT WERDEN
// Vor allem anderen steht ein INIT auf dem Rundruf-Kanal 0xFFFFFFFF. Der Stick
// antwortet mit einer eigenen Kennung, und nur unter der darf danach geredet
// werden. Das ist kein Zierrat: an einem USB-Anschluss koennen mehrere
// Programme gleichzeitig mit demselben Stick sprechen, und die Kanalkennung
// haelt ihre Antworten auseinander.
//
// KEEPALIVE IST KEINE ANTWORT
// Waehrend der Stick auf eine Beruehrung oder die PIN wartet, schickt er im
// Sekundentakt 0x3B. Wer das erste davon fuer die Antwort haelt, bekommt
// Unsinn statt Daten — und zwar nur dann, wenn eine Beruehrung noetig ist,
// also genau bei den Befehlen, auf die es ankommt.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'ctap.dart';

/// Rohes Lesen und Schreiben von 64-Byte-Berichten.
///
/// Getrennt gehalten, damit die Zerlegung oben ohne echtes Geraet pruefbar
/// bleibt — sie ist der Teil, in dem die Fehler stecken.
abstract class HidGeraet {
  Future<void> schreibe(Uint8List bericht64);
  Future<Uint8List> lies({Duration frist});
  Future<void> schliesse();
}

class CtapHidTransport implements CtapTransport {
  CtapHidTransport(this._geraet, {Random? zufall})
      : _zufall = zufall ?? Random.secure();

  final HidGeraet _geraet;
  final Random _zufall;

  static const int paketGroesse = 64;
  static const int _cmdInit = 0x86; // 0x06 mit gesetztem Anfangsbit
  static const int _cmdCbor = 0x90; // 0x10 mit gesetztem Anfangsbit
  static const int _cmdKeepalive = 0xBB; // 0x3B
  static const int _cmdError = 0xBF; // 0x3F
  static const int _rundruf = 0xFFFFFFFF;

  int _kanal = _rundruf;

  @override
  String get name => 'USB';

  /// Holt eine eigene Kanalkennung. Muss vor allem anderen passieren.
  @override
  Future<void> verbinde() async {
    final nonce = Uint8List.fromList(
        List.generate(8, (_) => _zufall.nextInt(256)));

    await _schreibeNachricht(_rundruf, _cmdInit, nonce);
    final antwort = await _leseNachricht(_rundruf, _cmdInit);

    if (antwort.length < 17) {
      throw const FormatException('INIT-Antwort zu kurz');
    }
    // Der Stick spiegelt das Nonce zurueck. Stimmt es nicht, gehoert die
    // Antwort zu einer anderen Anfrage — an einem gemeinsam benutzten
    // Anschluss durchaus moeglich.
    for (var i = 0; i < 8; i++) {
      if (antwort[i] != nonce[i]) {
        throw const FormatException(
            'INIT-Antwort gehoert zu einer fremden Anfrage');
      }
    }
    _kanal = (antwort[8] << 24) | (antwort[9] << 16) | (antwort[10] << 8) | antwort[11];
  }

  @override
  Future<Uint8List> sende(Uint8List befehl) async {
    if (_kanal == _rundruf) {
      throw StateError('verbinde() muss zuerst laufen');
    }
    await _schreibeNachricht(_kanal, _cmdCbor, befehl);
    return _leseNachricht(_kanal, _cmdCbor);
  }

  @override
  Future<void> trenne() => _geraet.schliesse();

  // ────────────────────────────────────────────────────────── Zerlegen

  Future<void> _schreibeNachricht(int kanal, int cmd, Uint8List daten) async {
    if (daten.length > 7609) {
      // 57 + 128 * 59 — mehr passt in die Nummerierung nicht hinein.
      throw ArgumentError('Befehl zu lang fuer CTAPHID');
    }

    final erstes = Uint8List(paketGroesse);
    _schreibeKanal(erstes, kanal);
    erstes[4] = cmd;
    erstes[5] = (daten.length >> 8) & 0xFF;
    erstes[6] = daten.length & 0xFF;
    final imErsten = min(57, daten.length);
    erstes.setRange(7, 7 + imErsten, daten);
    await _geraet.schreibe(erstes);

    var offen = daten.length - imErsten;
    var pos = imErsten;
    var nummer = 0;
    while (offen > 0) {
      final p = Uint8List(paketGroesse);
      _schreibeKanal(p, kanal);
      // Anfangsbit NICHT gesetzt — das macht daraus eine Fortsetzung.
      p[4] = nummer & 0x7F;
      final jetzt = min(59, offen);
      p.setRange(5, 5 + jetzt, daten.sublist(pos, pos + jetzt));
      await _geraet.schreibe(p);
      pos += jetzt;
      offen -= jetzt;
      nummer++;
    }
  }

  Future<Uint8List> _leseNachricht(int kanal, int erwarteterCmd) async {
    Uint8List paket;

    // Warten, solange der Stick nur "ich arbeite noch" sagt. Das kommt,
    // waehrend er auf eine Beruehrung oder die PIN wartet — also Sekunden bis
    // zu einer halben Minute.
    final frist = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      paket = await _geraet.lies(frist: const Duration(seconds: 5));
      if (paket.length < 7) {
        throw const FormatException('Paket zu kurz');
      }
      if (_leseKanal(paket) != kanal) continue; // gehoert jemand anderem
      if (paket[4] == _cmdKeepalive) {
        if (DateTime.now().isAfter(frist)) {
          throw const FormatException('Der Stick antwortet nicht');
        }
        continue;
      }
      break;
    }

    if (paket[4] == _cmdError) {
      final code = paket.length > 7 ? paket[7] : 0x7F;
      throw FormatException(
          'CTAPHID-Fehler 0x${code.toRadixString(16).padLeft(2, "0")}');
    }
    if (paket[4] != erwarteterCmd) {
      throw FormatException(
          'unerwartete Antwortart 0x${paket[4].toRadixString(16)}');
    }

    final laenge = (paket[5] << 8) | paket[6];
    final daten = <int>[];
    daten.addAll(paket.sublist(7, min(paketGroesse, 7 + laenge)));

    var nummer = 0;
    while (daten.length < laenge) {
      final p = await _geraet.lies(frist: const Duration(seconds: 5));
      if (p.length < 5) throw const FormatException('Fortsetzung zu kurz');
      if (_leseKanal(p) != kanal) continue;
      if ((p[4] & 0x80) != 0) {
        throw const FormatException(
            'Anfang statt Fortsetzung — Antwort durcheinander');
      }
      if ((p[4] & 0x7F) != nummer) {
        // Ein fehlendes Stueck still zu ueberspringen waere schlimmer als
        // abzubrechen: das Ergebnis waere stellenweise falsches CBOR.
        throw FormatException(
            'Fortsetzung ${p[4] & 0x7F} statt $nummer — ein Paket fehlt');
      }
      final rest = laenge - daten.length;
      daten.addAll(p.sublist(5, min(paketGroesse, 5 + rest)));
      nummer++;
    }

    return Uint8List.fromList(daten);
  }

  static void _schreibeKanal(Uint8List p, int kanal) {
    p[0] = (kanal >> 24) & 0xFF;
    p[1] = (kanal >> 16) & 0xFF;
    p[2] = (kanal >> 8) & 0xFF;
    p[3] = kanal & 0xFF;
  }

  static int _leseKanal(Uint8List p) =>
      (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
}
