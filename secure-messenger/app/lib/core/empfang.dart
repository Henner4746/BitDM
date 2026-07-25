// empfang.dart — Nachrichten empfangen, waehrend die App zu ist.
//
// WARUM DAS UEBERHAUPT EINE FRAGE IST
// Android beendet den Prozess einer Anwendung im Hintergrund, sobald Speicher
// gebraucht wird. Ohne Zutun kommen Nachrichten deshalb erst an, wenn jemand
// die App wieder oeffnet. Der einzige unterstuetzte Weg dagegen ist ein
// Vordergrunddienst — und der verlangt eine dauerhaft sichtbare
// Benachrichtigung.
//
// WAS BITDM NICHT TUT, UND WARUM
// Andere Messenger benutzen Push ueber Google (FCM). Das waere sparsamer und
// zuverlaessiger — aber Google saehe dann bei jeder Nachricht, WANN dieses
// Geraet eine bekommt. In einer App ohne Telefonnummer und ohne Konto waere
// das der Widerspruch zum ganzen Vorhaben. Deshalb der eigene Dienst, mit
// allem, was daran unbequem ist.
//
// ═══════════════════════════════════════════════ DIE HARTE EINSCHRAENKUNG
//
// Der Relay laesst niemanden mitlesen, der sich nicht ausweist: er schickt
// eine Zufallszahl, die mit dem Identitaetsschluessel unterschrieben werden
// muss. Dieser Schluessel entsteht aus der Entropie — und die liegt bei
// eingeschalteter App-Sperre in einem Fach, das ohne Fingerabdruck, Stick
// oder Passwort zu ist.
//
// Daraus folgt etwas, das sich nicht wegprogrammieren laesst: SOLANGE DIE APP
// GESPERRT IST, KANN SIE NICHTS EMPFANGEN. Auch nicht "nur zaehlen", auch
// nicht "nur benachrichtigen" — schon die Frage an den Relay verlangt die
// Unterschrift.
//
// Das ist keine fehlende Funktion, sondern die Kehrseite genau der Sperre,
// die gewuenscht war. Wer beides will, muss sich entscheiden, und die
// Oberflaeche sagt das auch.

import 'dart:async';

import 'package:flutter/services.dart';

/// Wie oft im Hintergrund nach Nachrichten gesehen wird.
enum EmpfangsTakt {
  /// Nur beim Oeffnen der App. Kein Dienst, keine Benachrichtigung, kein
  /// Akkuverbrauch. Ab Werk eingestellt.
  aus(0),

  /// Dauerhaft verbunden. Nachrichten kommen in dem Moment an, in dem sie
  /// gesendet werden.
  staendig(-1),

  /// Alle 15 Minuten kurz verbinden und abholen.
  viertelstunde(15),

  /// Stuendlich.
  stunde(60),

  /// Alle vier Stunden. Fuer alle, denen es reicht, ein paarmal am Tag zu
  /// sehen, ob etwas da ist.
  vierStunden(240);

  const EmpfangsTakt(this.minuten);

  /// -1 heisst dauerhaft, 0 heisst aus.
  final int minuten;

  static EmpfangsTakt vonMinuten(int m) {
    for (final t in EmpfangsTakt.values) {
      if (t.minuten == m) return t;
    }
    return EmpfangsTakt.aus;
  }

  bool get an => this != EmpfangsTakt.aus;
  bool get dauerhaft => this == EmpfangsTakt.staendig;

  Duration get abstand => Duration(minutes: minuten < 0 ? 0 : minuten);
}

/// Der Vordergrunddienst auf der Android-Seite.
class EmpfangsDienst {
  EmpfangsDienst({MethodChannel? kanal})
      : _kanal = kanal ?? const MethodChannel('bitdm/empfang');

  final MethodChannel _kanal;

  bool _laeuft = false;
  bool get laeuft => _laeuft;

  /// Startet den Dienst. Der Text steht dauerhaft in der Benachrichtigung.
  ///
  /// Bewusst OHNE Absender und ohne Anzahl: die stuenden auf einem gesperrten
  /// Bildschirm fuer jeden lesbar da.
  Future<void> starte({required String titel, required String text}) async {
    try {
      await _kanal.invokeMethod<bool>('starte', {'titel': titel, 'text': text});
      _laeuft = true;
    } on PlatformException {
      // Ein fehlgeschlagener Dienst darf die App nicht anhalten. Sie
      // funktioniert dann wie vorher: Nachrichten kommen beim Oeffnen.
      _laeuft = false;
    } on MissingPluginException {
      _laeuft = false;
    }
  }

  Future<void> stoppe() async {
    try {
      await _kanal.invokeMethod<bool>('stoppe');
    } catch (_) {
      // Auch hier: ein Fehler beim Aufraeumen darf nichts blockieren.
    }
    _laeuft = false;
  }
}
