// pc_funk.dart — die Bluetooth-Strecke des PC-Kontakts.
//
// Seit 26.09.2026. Ersetzt fuer den Rechner, was auf Android NahfunkKanal.kt
// ueber den Plattformkanal tut: [Nahfunk] wird beerbt, und statt Kotlin
// antwortet die Python-Bruecke tools/pc_kontakt/pc_funk_bruecke.py (Windows,
// bleak + WinRT). ALLES DARUEBER IST DER ECHTE KERN — Nahbereich, Wegwahl,
// Leuchtfeuer, Stueckelung, Signal. Genau das soll der PC-Kontakt beweisen.
//
// Uebernommen von [Nahfunk]: dieselbe Stueckelung (zerlege/Sammler) und
// dieselbe Antwort auf eine zu kleine MTU (FunkFehler 'FUNK' mit
// 'ZU_GROSS:<n>', dann einmal neu zerlegen).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/nah/funk.dart';
import 'package:bitdm/core/nah/stueckelung.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _bytes(String h) =>
    Uint8List.fromList([for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// Der laufende Python-Prozess.
class FunkBruecke {
  FunkBruecke._(this._p);

  final Process _p;
  final _ereignisse = StreamController<Map<String, Object?>>.broadcast();
  final _bereit = Completer<void>();
  void Function(String)? protokoll;

  Stream<Map<String, Object?>> get ereignisse => _ereignisse.stream;

  static Future<FunkBruecke> starte(String skript, {void Function(String)? protokoll}) async {
    final p = await Process.start('py', ['-u', skript]);
    final b = FunkBruecke._(p)..protokoll = protokoll;
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((zeile) {
      Map<String, Object?> m;
      try {
        m = (jsonDecode(zeile) as Map).cast<String, Object?>();
      } catch (_) {
        b.protokoll?.call('bruecke: $zeile');
        return;
      }
      if (m['e'] == 'bereit' && !b._bereit.isCompleted) b._bereit.complete();
      if (m['e'] == 'log') b.protokoll?.call('bruecke: ${m['t']}');
      b._ereignisse.add(m);
    });
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (z) => b.protokoll?.call('bruecke (stderr): $z'));
    await b._bereit.future.timeout(const Duration(seconds: 30));
    return b;
  }

  void befehl(Map<String, Object?> m) => _p.stdin.writeln(jsonEncode(m));

  Future<void> beende() async {
    befehl({'c': 'aus'});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _p.stdin.close();
    _p.kill();
  }
}

class PcFunk extends Nahfunk {
  PcFunk(this._b, {this.protokoll});

  final FunkBruecke _b;
  final void Function(String)? protokoll;

  final _g = StreamController<Gesehen>.broadcast();
  final _e = StreamController<Eingegangen>.broadcast();
  final _p = StreamController<String>.broadcast();
  final _sammler = <String, Sammler>{};
  final _offen = <int, Completer<Map<String, Object?>>>{};
  StreamSubscription<Map<String, Object?>>? _abo;
  var _nummer = 0;
  var _sendung = 0;

  /// Womit zuerst zerlegt wird. Windows handelt meist 247 aus (244 nutzbar);
  /// meldet die Bruecke weniger, wird einmal neu zerlegt — wie in [Nahfunk].
  final _mass = <String, int>{};
  static const int _erstesMass = 200;

  @override
  Stream<Gesehen> get gesehen => _g.stream;
  @override
  Stream<Eingegangen> get eingang => _e.stream;
  @override
  Stream<String> get pannen => _p.stream;

  @override
  Future<Funkzustand> zustand() async => const Funkzustand(
      zuAlt: false, vorhanden: true, an: true, rechte: true, jeWerbung: 2);

  @override
  Future<Rechtelage> fordereRechte() async => Rechtelage.erteilt;

  @override
  void horcheAuf() {
    _abo ??= _b.ereignisse.listen(_nimm);
  }

  void _nimm(Map<String, Object?> m) {
    switch (m['e']) {
      case 'gesehen':
        _g.add(Gesehen(
          geraet: m['geraet'] as String? ?? '',
          rssi: (m['rssi'] as num?)?.toInt() ?? 0,
          leuchtfeuer: [for (final h in (m['lf'] as List? ?? const [])) _bytes(h as String)],
        ));
      case 'stueck':
        final wer = m['geraet'] as String? ?? '';
        final daten = _bytes(m['daten'] as String? ?? '');
        protokoll?.call('funk: ${daten.length} Byte von $wer');
        final s = _sammler.putIfAbsent(wer, Sammler.new);
        try {
          final fertig = s.nimm(daten);
          if (fertig != null) {
            protokoll?.call('funk: UMSCHLAG KOMPLETT, ${fertig.length} Byte von $wer');
            _e.add(Eingegangen(wer, fertig));
          }
        } on StueckKaputt catch (e) {
          _p.add('Stueck von $wer verworfen: ${e.grund}');
        } on SendungZuGross catch (e) {
          _p.add('Sendung von $wer abgewiesen: ${e.grund}');
          _sammler.remove(wer);
        }
      case 'antwort':
        _offen.remove((m['id'] as num).toInt())?.complete(m);
    }
  }

  @override
  Future<void> werbeAn(List<Uint8List> leuchtfeuer) async =>
      _b.befehl({'c': 'werbe', 'lf': [for (final l in leuchtfeuer) _hex(l)]});
  @override
  Future<void> werbeAus() async => _b.befehl({'c': 'werbeAus'});
  @override
  Future<void> sucheAn() async => _b.befehl({'c': 'suche'});
  @override
  Future<void> sucheAus() async => _b.befehl({'c': 'sucheAus'});
  @override
  Future<void> postfachAuf() async => _b.befehl({'c': 'postfach'});
  @override
  Future<void> postfachZu() async => _b.befehl({'c': 'postfachZu'});
  @override
  Future<void> allesAus() async => _b.befehl({'c': 'aus'});

  @override
  Future<void> sende(String geraet, Uint8List umschlag) async {
    final sendung = _sendung = (_sendung + 1) & 0xFFFF;
    var mass = _mass[geraet] ?? _erstesMass;
    for (var versuch = 0; versuch < 2; versuch++) {
      final stuecke = zerlege(umschlag,
          sendungsnummer: sendung, nutzlastJeStueck: mass - Rahmen.laenge);
      final id = ++_nummer;
      final warte = Completer<Map<String, Object?>>();
      _offen[id] = warte;
      protokoll?.call('funk: sende ${umschlag.length} Byte in ${stuecke.length} Stuecken an $geraet');
      _b.befehl({'c': 'sende', 'id': id, 'geraet': geraet, 'stuecke': [for (final s in stuecke) _hex(s)]});
      final a = await warte.future.timeout(const Duration(seconds: 90),
          onTimeout: () => {'ok': false, 'code': 'FUNK', 'grund': 'keine Antwort der Bruecke'});
      if (a['ok'] == true) {
        _mass[geraet] = mass;
        return;
      }
      final grund = a['grund'] as String? ?? '';
      final m = RegExp(r'^ZU_GROSS:(\d+)$').firstMatch(grund);
      if (m != null && versuch == 0) {
        mass = int.parse(m.group(1)!).clamp(Nahfunk.kleinstesMass, Nahfunk.groesstesMass);
        continue;
      }
      throw FunkFehler(a['code'] as String? ?? 'FUNK', grund);
    }
  }

  @override
  Future<void> dispose() async {
    await _abo?.cancel();
  }
}
