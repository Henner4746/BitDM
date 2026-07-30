// funk_attrappe.dart — ein Funk, der nichts funkt und alles mitschreibt.
//
// Sie stand zuerst in nahbereich_test.dart. Seit auch der Kern gegen den
// Nahbereich geprueft wird, brauchen zwei Tests dasselbe Gegenstueck — und zwei
// Attrappen fuer dieselbe Schnittstelle waeren zwei Stellen, an denen sich das
// Verhalten auseinanderentwickeln kann, ohne dass es jemandem auffaellt.

import 'dart:async';
import 'dart:typed_data';

import 'package:bitdm/core/nah/funk.dart';

class FunkAttrappe implements Nahfunk {
  final _gesehen = StreamController<Gesehen>.broadcast();
  final _eingang = StreamController<Eingegangen>.broadcast();

  final werbungen = <List<Uint8List>>[];
  final gesendet = <({String geraet, Uint8List umschlag})>[];
  bool postfachOffen = false;
  bool suchtGerade = false;
  bool allesAusGerufen = false;

  /// Wenn gesetzt, wirft das naechste `sende`.
  FunkFehler? sendeFehler;

  @override
  Stream<Gesehen> get gesehen => _gesehen.stream;
  @override
  Stream<Eingegangen> get eingang => _eingang.stream;
  @override
  Stream<String> get pannen => const Stream.empty();

  void sieh(Gesehen g) => _gesehen.add(g);
  void empfange(Eingegangen e) => _eingang.add(e);

  @override
  void horcheAuf() {}
  @override
  Future<void> werbeAn(List<Uint8List> l) async => werbungen.add(l);
  @override
  Future<void> werbeAus() async {}
  @override
  Future<void> sucheAn() async => suchtGerade = true;
  @override
  Future<void> sucheAus() async => suchtGerade = false;
  @override
  Future<void> postfachAuf() async => postfachOffen = true;
  @override
  Future<void> postfachZu() async => postfachOffen = false;

  @override
  Future<void> sende(String geraet, Uint8List umschlag) async {
    final f = sendeFehler;
    sendeFehler = null;
    if (f != null) throw f;
    gesendet.add((geraet: geraet, umschlag: umschlag));
  }

  @override
  Future<void> allesAus() async {
    allesAusGerufen = true;
    postfachOffen = false;
    suchtGerade = false;
  }

  @override
  Future<void> dispose() async {
    await _gesehen.close();
    await _eingang.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} wird hier nicht gebraucht');
}
