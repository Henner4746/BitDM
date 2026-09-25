// funk.dart — die Bluetooth-Strecke, von Dart aus gesehen.
//
// Das Gegenstueck zu NahfunkKanal.kt. Sie traegt Bytes und Geraeteadressen,
// sonst nichts: keine Schluessel, keine Kontakte, keine Entscheidung, wohin
// etwas geht. Wer wer ist, rechnet nahbereich.dart darueber.
//
// ══════════════════════════════════════════════ WARUM DIE STUECKELUNG HIER SITZT
//
// Der native Teil bekommt fertige Haeppchen und schreibt sie einzeln hinaus.
// Zerlegt und zusammengesetzt wird in Dart, mit stueckelung.dart — weil das
// die Schicht ist, die 23 Tests hat und die man ohne zwei Telefone pruefen
// kann. Dieselbe Buchfuehrung im nativen Code noch einmal zu schreiben hiesse,
// sie genau dort zu haben, wo man sie am schlechtesten prueft.
//
// ═══════════════════════════════════════════════════ DIE SACHE MIT DER MTU
//
// Wie gross ein Haeppchen sein darf, steht erst fest, wenn die Verbindung
// steht — zerlegt werden muss aber vorher. BLE laesst da keine dritte
// Moeglichkeit. Deshalb: mit einer grosszuegigen Groesse zerlegen, und wenn
// die Gegenstelle weniger kann, meldet der native Teil die nutzbare Groesse
// zurueck und es wird genau einmal neu zerlegt. Auf beiden Testgeraeten
// handelt Android 517 aus und der zweite Anlauf kommt nie vor; auf einem
// Geraet, das weniger kann, kostet er eine Verbindung.
//
// Die Alternative — von vornherein mit den 20 Byte zerlegen, die jedes Geraet
// sicher kann — haette aus zwei Schreibvorgaengen vierundsechzig gemacht.

import 'dart:async';

// Uint8List kommt hierueber mit; ein eigener Import von dart:typed_data waere
// doppelt und die Pruefung meldet ihn.
import 'package:flutter/services.dart';

import 'stueckelung.dart';
import 'wegwahl.dart' show Ausgangsfehler;

/// Ein Geraet in Reichweite, das Leuchtfeuer aussendet.
///
/// [leuchtfeuer] enthaelt ALLE Sechser aus seiner Werbung — meist vierzig,
/// von denen die allermeisten Fuellbytes sind. Das Aussortieren gehoert
/// nicht hierher.
class Gesehen {
  const Gesehen({
    required this.geraet,
    required this.rssi,
    required this.leuchtfeuer,
  });

  /// Die Bluetooth-Adresse. Android wechselt sie regelmaessig; sie taugt
  /// zum Verbinden im naechsten Moment, nicht zum Wiedererkennen ueber Tage.
  final String geraet;
  final int rssi;
  final List<Uint8List> leuchtfeuer;
}

/// Ein vollstaendig angekommener Umschlag.
class Eingegangen {
  const Eingegangen(this.geraet, this.umschlag);
  final String geraet;
  final Uint8List umschlag;
}

/// Warum die Naehe gerade nicht geht. Vier Gruende, die die Oberflaeche
/// auseinanderhalten muss — "schalte Bluetooth ein" ist etwas anderes als
/// "dieses Telefon kann es nicht".
class Funkzustand {
  const Funkzustand({
    required this.zuAlt,
    required this.vorhanden,
    required this.an,
    required this.rechte,
    required this.jeWerbung,
    this.werberVorhanden = true,
    this.erweitert = true,
  });

  /// Aelter als Android 12. Dort braeuchte eine BLE-Suche den Standortzugriff,
  /// und den will diese App nicht haben — siehe NahfunkKanal.kt.
  final bool zuAlt;
  final bool vorhanden;
  final bool an;
  final bool rechte;

  /// Wie viele Leuchtfeuer in eine Werbung passen. Gemessen: 40.
  final int jeWerbung;

  /// Ob das Geraet ueberhaupt einen BLE-Werber herausgibt.
  ///
  /// EIGENES FELD, WEIL ES ETWAS ANDERES IST ALS [vorhanden]. Das dort sagt
  /// nur, dass die Systemeigenschaft FEATURE_BLUETOOTH_LE gesetzt ist —
  /// Empfangen also geht. Aussenden ist eine zweite Faehigkeit, und auf
  /// alternativer Firmware kann sie fehlen, waehrend die erste gemeldet wird.
  ///
  /// Der Wert kam schon immer aus dem Kotlin-Teil zurueck und wurde hier
  /// weggeworfen. Am 29.07.2026 funkte ein S10 mit DerpFest nicht, waehrend
  /// ein S25 es tat — und die App hatte kein Feld, in dem der Unterschied
  /// haette stehen koennen.
  final bool werberVorhanden;

  /// Ob das Geraet erweiterte Werbung beherrscht.
  ///
  /// Die Leuchtfeuer brauchen 120 Byte, in eine klassische Werbung passen 31.
  /// Ohne erweiterte Werbung ist der Nahbereich unmoeglich — in BEIDE
  /// Richtungen: senden nicht, und empfangen auch nicht.
  final bool erweitert;

  /// Ob EMPFANGEN geht. Zum Aussenden braucht es zusaetzlich
  /// [werberVorhanden] — siehe [funktVollstaendig].
  bool get geht => !zuAlt && vorhanden && an && rechte;

  /// Ob beide Richtungen gehen. Nur so ist der Nahbereich wirklich brauchbar:
  /// wer nur hoert, wird nie gefunden.
  bool get funktVollstaendig => geht && werberVorhanden && erweitert;

  static Funkzustand vonKarte(Map<Object?, Object?> k) => Funkzustand(
        zuAlt: k['zuAlt'] == true,
        vorhanden: k['vorhanden'] == true,
        an: k['an'] == true,
        rechte: k['rechte'] == true,
        jeWerbung: (k['jeWerbung'] as int?) ?? 40,
        // FEHLT DAS FELD, WIRD "JA" ANGENOMMEN. Eine aeltere Fassung des
        // Kotlin-Teils schickt es nicht mit; daraus "kein Werber" zu machen
        // hiesse, den Nahbereich auf Geraeten abzuschalten, auf denen er
        // laeuft.
        werberVorhanden: k['werberVorhanden'] != false,
        erweitert: k['erweitert'] != false,
      );

  @override
  String toString() => 'Funkzustand(zuAlt: $zuAlt, vorhanden: $vorhanden, '
      'an: $an, rechte: $rechte, werber: $werberVorhanden, '
      'erweitert: $erweitert, jeWerbung: $jeWerbung)';
}

/// Wie eine Rechteabfrage ausgegangen ist.
///
/// DREI AUSGAENGE, NICHT ZWEI. "Abgelehnt" und "abgelehnt, und Android fragt
/// nicht mehr" sehen fuer die Oberflaeche gleich aus und verlangen
/// Verschiedenes: einmal darf man denselben Knopf noch einmal anbieten, einmal
/// waere das ein Knopf, bei dem sichtbar nichts passiert. Das ist die Sorte
/// Unterschied, die eine App entweder brauchbar oder aergerlich macht.
enum Rechtelage {
  erteilt,

  /// Abgelehnt, aber man darf wieder fragen.
  abgelehnt,

  /// Abgelehnt, und Android zeigt keinen Dialog mehr. Nur noch ueber die
  /// Systemeinstellungen.
  dauerhaftAbgelehnt,

  /// Aelter als Android 12 — es gibt hier nichts zu erteilen.
  zuAlt,
}

class FunkFehler implements Exception, Ausgangsfehler {
  const FunkFehler(this.code, this.grund);
  final String code;
  final String grund;

  /// Die Fehler, bei denen sicher KEIN Byte beim Empfaenger ankam — sie
  /// scheitern vor dem ersten Schreibvorgang (in Dart, oder im nativen Teil
  /// vor `connectGatt`; siehe NahfunkKanal.kt `sende`).
  static const _vorDemSenden = {
    'NICHT_DA', // nahbereich.dart: nicht in Reichweite
    'KEIN_FEUER', // nahbereich.dart: kein Leuchtfeuer fuer diesen Kontakt
    'ZERLEGEN', // sende(): Umschlag liess sich nicht zerlegen
    'ZU_GROSS', // sende(): Umschlag zu gross fuer den Funk
    'RECHT', // Bluetooth-Recht fehlt
    'FORM', // unbrauchbare Angaben
    'BESETZT', // an dieses Geraet laeuft schon etwas
    'ZU_ALT', // Android zu alt fuer die Naehe
    'VOR_SENDEN', // NahfunkKanal.kt fertig(): vor dem ersten Haeppchen gescheitert
  };

  /// Siehe [Ausgangsfehler]. "FUNK" mit `ZU_GROSS:<n>` ist die MTU-Auskunft
  /// nach dem Verbinden, aber vor dem ersten Haeppchen — auch dort ging
  /// nichts hinaus. Jeder andere "FUNK"-Fehler kann mitten in der Sendung
  /// gekommen sein und bleibt mehrdeutig.
  @override
  bool get nichtsHinaus =>
      _vorDemSenden.contains(code) ||
      (code == 'FUNK' && grund.startsWith('ZU_GROSS:'));

  @override
  String toString() => 'FunkFehler($code): $grund';
}

/// Die Bluetooth-Strecke.
class Nahfunk {
  Nahfunk({MethodChannel? kanal, EventChannel? ereignisse})
      : _kanal = kanal ?? const MethodChannel('bitdm/nahfunk'),
        _ereignisse =
            ereignisse ?? const EventChannel('bitdm/nahfunk_ereignisse');

  final MethodChannel _kanal;
  final EventChannel _ereignisse;

  final _gesehen = StreamController<Gesehen>.broadcast();
  final _eingang = StreamController<Eingegangen>.broadcast();
  final _pannen = StreamController<String>.broadcast();

  /// Ein Sammler JE GEGENSTELLE. Zwei Geraete wuerfeln ihre Sendungsnummern
  /// unabhaengig voneinander; ein gemeinsamer Sammler machte daraus einen
  /// unlesbaren Umschlag. Steht so auch in stueckelung.dart.
  final _sammler = <String, Sammler>{};

  StreamSubscription<dynamic>? _abo;

  Stream<Gesehen> get gesehen => _gesehen.stream;
  Stream<Eingegangen> get eingang => _eingang.stream;

  /// Was schiefging, ohne dass ein Aufruf fehlschlug — eine abgebrochene
  /// Suche etwa. Fuer den Verbindungstest, nicht fuer die Oberflaeche.
  Stream<String> get pannen => _pannen.stream;

  /// Womit zerlegt wird, bevor die MTU bekannt ist. 500 Byte Nutzlast passen
  /// in die 514, die Android auf beiden Testgeraeten aushandelt.
  static const int _erstesMass = 500;

  /// Die zuletzt von einer Gegenstelle gemeldete nutzbare Groesse. Beim
  /// naechsten Mal wird gleich damit zerlegt, statt denselben Fehlschlag zu
  /// wiederholen.
  final _mass = <String, int>{};

  /// Das kleinste Mass, das angenommen wird: 20 Byte, die ATT-Nutzlast der
  /// Standard-MTU von 23, die JEDES BLE-Geraet kann.
  ///
  /// WARUM EINE UNTERGRENZE: `ZU_GROSS:<n>` kommt aus dem nativen Teil und
  /// letztlich von der Gegenstelle. Bis 25.09.2026 wurde jedes n uebernommen
  /// — bei n <= 9 bliebe nach dem Rahmen keine Nutzlast, `zerlege` warf bei
  /// JEDEM weiteren Versand an dieses Geraet, und weil das Mass gemerkt wird,
  /// war dieser Weg bis zum Neustart zu. Ein kleines, aber gueltiges Mass ist
  /// dagegen nie falsch, nur langsam.
  static const int kleinstesMass = 20;

  /// Und das groesste: 512 ist die hoechste Laenge eines ATT-Werts.
  static const int groesstesMass = 512;

  var _sendungsnummer = 0;

  Future<Funkzustand> zustand() async {
    final k = await _kanal.invokeMethod<Map<Object?, Object?>>('zustand');
    return Funkzustand.vonKarte(k ?? const {});
  }

  /// Fragt die Bluetooth-Rechte ab und wartet, bis der Nutzer geantwortet hat.
  Future<Rechtelage> fordereRechte() async {
    final s = await _kanal.invokeMethod<String>('fordereRechte');
    return switch (s) {
      'ja' => Rechtelage.erteilt,
      'nein' => Rechtelage.abgelehnt,
      'dauerhaft' => Rechtelage.dauerhaftAbgelehnt,
      _ => Rechtelage.zuAlt,
    };
  }

  /// Die Systemeinstellungen dieser App. Der einzige Weg zurueck, wenn
  /// Android nicht mehr fragt.
  Future<void> oeffneEinstellungen() => _rufe('oeffneEinstellungen');

  /// Faengt an zuzuhoeren. Muss vor allem anderen laufen.
  void horcheAuf() {
    _abo ??= _ereignisse.receiveBroadcastStream().listen(
      _nimmEreignis,
      onError: (Object e) => _pannen.add('Ereignisstrom: $e'),
    );
  }

  void _nimmEreignis(dynamic roh) {
    if (roh is! Map) return;
    switch (roh['art']) {
      case 'gesehen':
        final liste = (roh['leuchtfeuer'] as List?) ?? const [];
        _gesehen.add(Gesehen(
          geraet: roh['geraet'] as String? ?? '',
          rssi: (roh['rssi'] as int?) ?? 0,
          leuchtfeuer: [
            for (final l in liste)
              if (l is Uint8List && l.length == 6) l
          ],
        ));
      case 'stueck':
        _nimmStueck(roh['geraet'] as String? ?? '', roh['daten']);
      case 'gegenstelle':
        // Trennt sich eine Gegenstelle, ist alles Angefangene von ihr wertlos.
        // Es stehenzulassen hiesse, auf einen Rest zu warten, der nie kommt —
        // die Frist im Sammler faenge es zwar auch ab, aber erst nach 30
        // Sekunden und mit belegtem Speicher bis dahin.
        if (roh['verbunden'] != true) {
          _sammler.remove(roh['geraet'] as String? ?? '');
        }
      case 'fehler':
        _pannen.add('${roh['wo']}: Status ${roh['status']} ${roh['grund'] ?? ''}');
    }
  }

  void _nimmStueck(String geraet, Object? daten) {
    if (daten is! Uint8List || geraet.isEmpty) return;
    final s = _sammler.putIfAbsent(geraet, Sammler.new);
    try {
      final fertig = s.nimm(daten);
      if (fertig != null) _eingang.add(Eingegangen(geraet, fertig));
    } on StueckKaputt catch (e) {
      // KEIN Grund, die Gegenstelle abzuschreiben. Ein verdorbenes Haeppchen
      // ist im Funk Alltag; der Absender wiederholt die Sendung.
      _pannen.add('Stueck von $geraet verworfen: ${e.grund}');
    } on SendungZuGross catch (e) {
      _pannen.add('Sendung von $geraet abgewiesen: ${e.grund}');
      _sammler.remove(geraet);
    }
  }

  /// Sendet die eigenen Leuchtfeuer aus.
  ///
  /// Hoechstens [Funkzustand.jeWerbung] Stueck — wer mehr Kontakte hat, muss
  /// reihum wechseln. Das entscheidet nicht diese Schicht.
  Future<void> werbeAn(List<Uint8List> leuchtfeuer) =>
      _rufe('werbeAn', {'leuchtfeuer': leuchtfeuer});

  Future<void> werbeAus() => _rufe('werbeAus');
  Future<void> sucheAn() => _rufe('sucheAn');
  Future<void> sucheAus() => _rufe('sucheAus');

  /// Oeffnet das Postfach, damit andere etwas hineinlegen koennen.
  Future<void> postfachAuf() => _rufe('postfachAuf');
  Future<void> postfachZu() => _rufe('postfachZu');

  /// Schickt einen Umschlag an ein Geraet in Reichweite.
  ///
  /// Wirft [FunkFehler], wenn es nicht geklappt hat. Der Aufrufer — die
  /// Wegwahl — macht daraus einen Zustand, keine Ausnahme.
  Future<void> sende(String geraet, Uint8List umschlag) async {
    final nummer = _sendungsnummer = (_sendungsnummer + 1) & 0xFFFF;
    var mass = _mass[geraet] ?? _erstesMass;

    for (var versuch = 0; versuch < 2; versuch++) {
      final List<Uint8List> stuecke;
      try {
        stuecke = zerlege(umschlag,
            sendungsnummer: nummer, nutzlastJeStueck: mass - Rahmen.laenge);
      } on StueckKaputt catch (e) {
        // Der Vertrag dieser Methode ist FunkFehler — die Wegwahl macht daraus
        // "liegt". Ein roher StueckKaputt waere derselbe Zustand mit einem
        // Namen, den oben niemand erwartet.
        throw FunkFehler('ZERLEGEN', e.grund);
      } on SendungZuGross catch (e) {
        throw FunkFehler('ZU_GROSS', e.grund);
      }
      try {
        await _kanal.invokeMethod<bool>(
            'sende', {'geraet': geraet, 'stuecke': stuecke});
        _mass[geraet] = mass;
        return;
      } on PlatformException catch (e) {
        // "ZU_GROSS:<zahl>" ist kein Fehlschlag, sondern eine Auskunft: die
        // Gegenstelle hat eine kleinere MTU ausgehandelt, als angenommen.
        final m = RegExp(r'^ZU_GROSS:(\d+)$').firstMatch(e.message ?? '');
        if (m != null && versuch == 0) {
          // tryParse: "\d+" passt auch auf eine Zahl, die kein int mehr ist.
          final gemeldet = int.tryParse(m.group(1)!);
          // Eine "Auskunft", die nicht kleiner ist als das, was eben zu gross
          // war, hilft nicht weiter — ein zweiter Anlauf damit scheiterte
          // genauso.
          if (gemeldet == null || gemeldet >= mass) {
            throw FunkFehler(e.code, e.message ?? 'ohne Angabe');
          }
          mass = gemeldet.clamp(kleinstesMass, groesstesMass);
          _mass[geraet] = mass;
          continue;
        }
        throw FunkFehler(e.code, e.message ?? 'ohne Angabe');
      }
    }
    throw const FunkFehler('FUNK', 'auch der zweite Anlauf ging nicht');
  }

  Future<void> allesAus() async {
    await _rufe('allesAus');
    _sammler.clear();
  }

  Future<void> _rufe(String was, [Map<String, Object?>? mit]) async {
    try {
      await _kanal.invokeMethod<Object?>(was, mit);
    } on PlatformException catch (e) {
      throw FunkFehler(e.code, e.message ?? 'ohne Angabe');
    }
  }

  Future<void> dispose() async {
    await _abo?.cancel();
    _abo = null;
    await _gesehen.close();
    await _eingang.close();
    await _pannen.close();
  }
}
