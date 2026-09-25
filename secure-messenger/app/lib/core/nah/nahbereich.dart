// nahbereich.dart — was der Funk sieht, mit dem, was die App weiss.
//
// Die Schicht dazwischen. Unter ihr liegt funk.dart, das Bytes und
// Geraeteadressen kennt; ueber ihr liegt die Wegwahl, die von Bluetooth nichts
// wissen will. Hier treffen sich beide: aus einem Sechser wird ein Kontakt,
// aus einem Kontakt ein Geraet.
//
// ═══════════════════════════════════════════════════════ DIE VIER AUFGABEN
//
// 1. AUSSENDEN. Je Kontakt ein eigenes Leuchtfeuer (leuchtfeuer.dart sagt
//    warum). Vierzig passen in eine Werbung — gemessen, siehe
//    docs/NAHBEREICH.md. Wer mehr Kontakte hat, sendet sie reihum.
//
// 2. ERKENNEN. Der Funk liefert vierzig Sechser je Werbung, von denen die
//    allermeisten Fuellbytes sind. Die Tabelle sagt, welcher davon zu wem
//    gehoert — ein Hashzugriff, kein Rechnen.
//
// 3. BUCHFUEHREN, wer gerade in Reichweite ist. Mit Zeitstempel, denn
//    "gesehen" wird man einmal, "in Reichweite" ist man eine Weile.
//
// 4. EIN AUSGANG SEIN fuer die Wegwahl.
//
// ══════════════════════════════════════════ WAS HIER BEWUSST NICHT PASSIERT
//
// Es gibt KEINE Anwesenheitsanzeige nach aussen. Diese Klasse weiss, wer in
// Reichweite ist, und die Oberflaeche bekommt es nicht zu sehen — so steht es
// im Entwurf, und der Grund ist, dass ein Messenger ohne Telefonnummer nicht
// stattdessen Anwesenheit verraten soll. Die Angabe wird gebraucht, um einen
// Weg zu waehlen, und fuer sonst nichts.
//
// [neuInReichweite] ist kein Bruch damit, sondern derselbe Satz: sie geht an
// den Kern, damit er nachschicken kann, was liegengeblieben ist — nicht an die
// Oberflaeche. Wer sie irgendwann bis dorthin durchreicht, hat die
// Anwesenheitsanzeige gebaut, die hier ausgeschlossen ist.

import 'dart:async';
import 'dart:typed_data';

import 'funk.dart';
import 'leuchtfeuer.dart';
import 'wegwahl.dart';

/// Ein Umschlag, der ueber die Naehe hereinkam, MIT Absender.
///
/// WARUM DER ABSENDER NICHT IM UMSCHLAG STEHT
/// Beim Relay liefert der Server das Feld `from`. Hier gibt es keinen Server,
/// und die naheliegende Loesung — die eigene Adresse vor den Chiffretext
/// schreiben — waere genau der Fehler, gegen den leuchtfeuer.dart gebaut ist:
/// sie ginge unverschluesselt durch die Luft, und wer mithoert, haette die
/// dauerhafte Kennung, die das ganze Leuchtfeuer-Verfahren vermeidet.
///
/// Deshalb kommt der Absender aus der Buchfuehrung: welches Geraet hat
/// geschrieben, und wessen Leuchtfeuer haben wir von diesem Geraet gesehen.
class NahUmschlag {
  const NahUmschlag(this.von, this.umschlag);

  /// Die BitDM-Adresse des Kontakts.
  final String von;
  final Uint8List umschlag;
}

/// Ein Kontakt, den wir gerade sehen.
class InReichweite {
  InReichweite({
    required this.adresse,
    required this.geraet,
    required this.rssi,
    required this.zuletzt,
  });

  final String adresse;
  String geraet;
  int rssi;
  DateTime zuletzt;
}

/// Bringt Leuchtfeuer, Funk und Wegwahl zusammen.
/// Was hinter der Marke steht — ein Byte, und es entscheidet alles Weitere.
///
/// WARUM UEBERHAUPT EIN TYP: ueber dieselbe Strecke gehen bald zwei Dinge, die
/// nichts miteinander zu tun haben. Ein Umschlag ist verschluesselt und setzt
/// eine Sitzung voraus; eine Buendel-Anfrage ist gerade das, was man schickt,
/// WEIL es noch keine gibt. Ohne Typbyte muesste der Empfaenger raten, und
/// raten heisst hier: eine funktionierende Sitzung mit einem Fehlversuch
/// beschaedigen.
class Nahtyp {
  /// Ein verschluesselter Umschlag. Der Weg, der am 29.07.2026 zwischen zwei
  /// echten Telefonen ohne Netz bewiesen wurde.
  static const int umschlag = 0;

  /// "Schick mir dein Schluesselbuendel." Ohne Nutzlast.
  static const int buendelAnfrage = 1;

  /// Das Buendel, als JSON in UTF-8.
  static const int buendelAntwort = 2;

  static const int laenge = 1;
}

/// Alles, was ueber die Naehe kommt und KEIN Umschlag ist.
///
/// Getrennt vom Umschlag-Strom, weil der Kern damit etwas voellig anderes tut
/// — und weil ein Umschlag-Empfaenger, der ploetzlich JSON bekaeme, es der
/// Entschluesselung vorwerfen wuerde statt hierher zu zeigen.
class NahSonderpost {
  const NahSonderpost(this.von, this.typ, this.nutzlast);

  final String von;
  final int typ;
  final Uint8List nutzlast;
}

class Nahbereich implements Ausgang {
  Nahbereich({
    required Nahfunk funk,
    DateTime Function()? uhr,
    this.vergessenNach = const Duration(seconds: 90),
    this.wechselAlle = const Duration(seconds: 4),
  })  // Der Hinweis prefer_initializing_formals laesst sich hier nicht
      // befolgen: er wollte `this._funk`, und Dart erlaubt keine benannten
      // Parameter mit Unterstrich. Das Feld privat zu lassen ist richtiger,
      // als es fuer eine Pruefregel oeffentlich zu machen.
      // ignore: prefer_initializing_formals
      : _funk = funk,
        _jetzt = uhr ?? DateTime.now;

  final Nahfunk _funk;
  final DateTime Function() _jetzt;

  /// Wie lange jemand als "in Reichweite" gilt, nachdem er zuletzt gesehen
  /// wurde.
  ///
  /// Grosszuegig, und das mit Absicht: eine Werbung geht auch mal unter,
  /// und jemanden zu frueh zu vergessen hiesse, eine Nachricht liegen zu
  /// lassen, obwohl der andere neben einem steht. Zu spaet zu vergessen kostet
  /// dagegen nur einen Verbindungsversuch, der scheitert.
  final Duration vergessenNach;

  /// Wie oft die ausgesendeten Leuchtfeuer wechseln, wenn es mehr als vierzig
  /// Kontakte gibt.
  final Duration wechselAlle;

  final _reichweite = <String, InReichweite>{};
  final _eingang = StreamController<NahUmschlag>.broadcast();

  /// Wer gerade NEU in Reichweite gekommen ist.
  ///
  /// NUR DER UEBERGANG "war weg -> ist da". Eine Werbung kommt mehrmals je
  /// Sekunde und je Geraet; wer daran etwas haengt, haengt es an einen
  /// Dauerstrom.
  ///
  /// WOZU: ohne diese Meldung erfaehrt niemand ueber dieser Schicht, dass ein
  /// Weg aufgegangen ist. Beim Relay uebernimmt das `connect`. Mit "nur in der
  /// Naehe" gibt es kein Verbinden — und damit gab es dort auch keinen
  /// Nachversand: eine Nachricht blieb auf "sending" stehen, obwohl der
  /// Empfaenger wieder danebenstand. Das ist Regel 4 aus wegwahl.dart, und sie
  /// galt in genau dem Modus nicht, in dem die Naehe der einzige Weg ist.
  final _neuDa = StreamController<String>.broadcast();

  /// Was ueber die Naehe kam und kein Umschlag war.
  final _sonderpost = StreamController<NahSonderpost>.broadcast();

  /// Buendel-Anfragen und -Antworten. Wer sie beantwortet, weiss der Kern.
  Stream<NahSonderpost> get sonderpost => _sonderpost.stream;

  List<NahKontakt> _kontakte = const [];
  LeuchtfeuerTabelle? _tabelle;

  /// Die eigenen Leuchtfeuer, eines je Kontakt, in derselben Reihenfolge.
  List<Uint8List> _eigene = const [];
  int _fenster = 0;
  Timer? _wechsel;
  StreamSubscription<Gesehen>? _sicht;
  StreamSubscription<Eingegangen>? _post;
  bool _laeuft = false;

  /// Umschlaege, die ueber die Naehe hereingekommen sind.
  Stream<NahUmschlag> get eingang => _eingang.stream;

  /// Meldet einen Kontakt, sobald er wieder in Reichweite ist. Siehe [_neuDa].
  Stream<String> get neuInReichweite => _neuDa.stream;

  /// Wer gerade in Reichweite ist. Nur fuer den Verbindungstest.
  List<String> get inReichweite {
    _vergiss();
    return _reichweite.keys.toList();
  }

  /// Ob der Funk WIRKLICH laeuft.
  ///
  /// Nicht "ist eingeschaltet" und nicht "wurde eingerichtet", sondern: es
  /// geht etwas auf Sendung. Der Unterschied ist keine Wortklauberei — der
  /// Fruehausstieg bei leerer Kontaktliste (siehe `starte`) kehrt VOR
  /// `_laeuft = true` um, und genau dieser Fall sah von aussen lange aus wie
  /// ein laufender Funk.
  ///
  /// Der Verbindungstest fragt hier und nicht beim Kern nach. Der Kern weiss
  /// nur, was er aufgetragen hat; ob es ausgefuehrt wurde, weiss diese
  /// Klasse.
  bool get laeuft => _laeuft;

  @override
  bool get bereit {
    _vergiss();
    return _laeuft && _reichweite.isNotEmpty;
  }

  @override
  Future<void> schicke(String an, Uint8List umschlag) async {
    _vergiss();
    // DAS EIGENE LEUCHTFEUER VORNEWEG — sechs Byte, und ohne sie kommt nichts an.
    //
    // ANDROID GIBT JEDER ROLLE EINE EIGENE ZUFALLSADRESSE. Die Adresse, unter
    // der wir werben, ist NICHT die, unter der wir eine GATT-Verbindung
    // aufbauen. Der Empfaenger kennt uns aber nur von der Werbung her —
    // gemessen am 29.07.2026: gesendet von 47:E3:CD:3C:76:54, empfangen von
    // 49:57:AC:37:64:E6, "Absender: 0 Treffer". Der Umschlag kam vollstaendig
    // an und wurde verworfen, weil niemand sagen konnte, von wem.
    //
    // Die Marke loest das, ohne etwas preiszugeben: es ist genau das
    // Leuchtfeuer, das wir fuer DIESEN Kontakt ohnehin oeffentlich aussenden.
    // Der Empfaenger schlaegt es in derselben Tabelle nach, mit der er uns
    // erkennt. Kein neues Geheimnis, keine Kennung, die laenger gilt als ein
    // Fenster — und vor allem nichts Geratenes: die Zuordnung ist so
    // beweisbar wie die Erkennung selbst.
    final i = _kontakte.indexWhere((k) => k.adresse == an);
    if (i < 0 || i >= _eigene.length) {
      throw FunkFehler('KEIN_FEUER', 'kein Leuchtfeuer fuer $an');
    }
    await _schickeRoh(an, Nahtyp.umschlag, umschlag);
  }

  /// Schickt etwas, das kein Umschlag ist — eine Buendel-Anfrage oder -Antwort.
  Future<void> schickeSonder(String an, int typ, Uint8List nutzlast) =>
      _schickeRoh(an, typ, nutzlast);

  /// Marke, Typ, Inhalt — in dieser Reihenfolge, und immer alle drei.
  Future<void> _schickeRoh(String an, int typ, Uint8List inhalt) async {
    final wer = _reichweite[an];
    if (wer == null) {
      throw FunkFehler('NICHT_DA', '$an ist nicht in Reichweite');
    }
    final i = _kontakte.indexWhere((k) => k.adresse == an);
    if (i < 0 || i >= _eigene.length) {
      throw FunkFehler('KEIN_FEUER', 'kein Leuchtfeuer fuer $an');
    }
    final marke = _eigene[i];
    final kopf = marke.length + Nahtyp.laenge;
    final fertig = Uint8List(kopf + inhalt.length)
      ..setAll(0, marke)
      ..[marke.length] = typ
      ..setAll(kopf, inhalt);
    await _funk.sende(wer.geraet, fertig);
  }

  /// Faengt an, sich zu zeigen und zu suchen.
  ///
  /// [eigenerOeffentlicher] ist der eigene Identitaetsschluessel, 32 Byte ohne
  /// Typbyte — er geht in jedes ausgesendete Leuchtfeuer ein, damit sich die
  /// Richtung nicht vertauschen laesst.
  Future<void> starte({
    required List<NahKontakt> kontakte,
    required Uint8List eigenerOeffentlicher,
  }) async {
    await halt();
    if (kontakte.isEmpty) {
      // Ohne Kontakte gibt es nichts auszusenden und niemanden zu finden.
      // Trotzdem zu senden hiesse, eine Werbung aus reinen Fuellbytes in die
      // Gegend zu rufen — Funkverkehr ohne jeden Zweck.
      return;
    }
    _kontakte = kontakte;
    _eigenerOeffentlicher = eigenerOeffentlicher;

    _funk.horcheAuf();
    await _baueFuerJetzt();

    _sicht = _funk.gesehen.listen(_sah);
    _post = _funk.eingang.listen(_kamAn);

    await _funk.postfachAuf();
    await _funk.sucheAn();
    _laeuft = true;

    _wechsel = Timer.periodic(wechselAlle, (_) => _tick());
  }

  Uint8List _eigenerOeffentlicher = Uint8List(0);
  int _wechselStand = 0;

  Future<void> halt() async {
    _wechsel?.cancel();
    _wechsel = null;
    await _sicht?.cancel();
    _sicht = null;
    await _post?.cancel();
    _post = null;
    _reichweite.clear();
    if (_laeuft) {
      _laeuft = false;
      try {
        await _funk.allesAus();
      } on FunkFehler {
        // Beim Abschalten ist ein Fehlschlag kein Fehler: entweder es war
        // ohnehin schon aus, oder Bluetooth ist inzwischen abgeschaltet.
      }
    }
  }

  /// Rechnet Tabelle und eigene Leuchtfeuer fuer das laufende Zeitfenster.
  Future<void> _baueFuerJetzt() async {
    final zeit = _jetzt();
    _fenster = Leuchtfeuer.fensterFuer(zeit);
    _tabelle = await LeuchtfeuerTabelle.baue(_kontakte, zeit);
    _eigene = [
      for (final k in _kontakte)
        await Leuchtfeuer.eigenesFuer(
          geheimnis: k.geheimnis,
          eigenerOeffentlicher: _eigenerOeffentlicher,
          zeit: zeit,
        )
    ];
    _wechselStand = 0;
    await _sendeStand();
  }

  /// Sendet den gerade an der Reihe befindlichen Satz aus.
  Future<void> _sendeStand() async {
    if (_eigene.isEmpty) return;
    final von = _wechselStand;
    final bis = (von + _jeWerbung).clamp(0, _eigene.length);
    var satz = _eigene.sublist(von, bis);
    // Am Ende der Liste mit dem Anfang auffuellen, statt eine halbleere
    // Werbung zu senden: sonst waere der letzte Satz kleiner, und die
    // Kontakte darin haetten eine kuerzere Sendezeit als die anderen.
    if (satz.length < _jeWerbung && _eigene.length > _jeWerbung) {
      satz = [...satz, ..._eigene.take(_jeWerbung - satz.length)];
    }
    try {
      await _funk.werbeAn(satz);
    } on FunkFehler catch (e) {
      _eingangPanne('Aussenden ging nicht: ${e.grund}');
    }
  }

  static const int _jeWerbung = 40;

  void _tick() {
    // Fensterwechsel geht vor: mit einer veralteten Tabelle findet man
    // niemanden mehr, und man wird auch nicht mehr gefunden.
    if (Leuchtfeuer.fensterFuer(_jetzt()) != _fenster) {
      unawaited(_baueFuerJetzt());
      return;
    }
    if (_eigene.length <= _jeWerbung) return;
    _wechselStand = (_wechselStand + _jeWerbung) % _eigene.length;
    unawaited(_sendeStand());
  }

  void _sah(Gesehen g) {
    final t = _tabelle;
    if (t == null) {
      return;
    }
    final zeit = _jetzt();

    // AUFRAEUMEN VOR DEM EINTRAGEN, anders als in `_kamAn`.
    //
    // Hier wird nebenbei die Frage beantwortet "war der eben noch weg". Wer
    // einen abgelaufenen Eintrag stehen laesst, beantwortet sie mit nein:
    // derselbe Kontakt taucht nach zehn Minuten wieder auf, sein alter Eintrag
    // wird nur aufgefrischt, und der Uebergang faellt unter den Tisch. Genau
    // daran haengt der Nachversand.
    _vergiss();

    // EIN FENSTER LAG IST ERLAUBT, und das ist wichtiger, als es aussieht.
    //
    // Die Tabelle enthaelt die Leuchtfeuer fuer DREI Fenster: das vorige, das
    // laufende und das naechste (leuchtfeuer.dart, `fensterUmZeit`). Eine im
    // Fenster f gebaute Tabelle stimmt also auch noch in f+1. Wer hier auf
    // `giltNoch` besteht — genaue Gleichheit —, wirft sie schon beim
    // Ueberschreiten der Grenze weg und erkennt bis zum naechsten Takt
    // niemanden mehr. Das waere alle 15 Minuten eine blinde Luecke: genau der
    // Fehler, gegen den das Vor- und Rueckfenster ueberhaupt gebaut wurde,
    // und einer, der sich am Schreibtisch nie zeigt.
    //
    // Zwei Fenster Lag sind dagegen wirklich vorbei. Nachschlagen wuerde dann
    // nichts mehr finden — schaden koennte es nur, indem ein aufgezeichnetes
    // altes Leuchtfeuer laenger gilt, als es soll. Deshalb die Grenze.
    //
    // Nachgebaut wird hier nichts: das ist eine Rechnung je Kontakt und liefe
    // bei jedem Bluetooth-Fund. Dafuer ist der Takt da.
    if (Leuchtfeuer.fensterFuer(zeit) > t.gebautFuer + 1) {
      return;
    }

    for (final l in g.leuchtfeuer) {
      final wer = t.wer(l);
      if (wer == null) continue;
      final da = _reichweite[wer];
      if (da == null) {
        _reichweite[wer] =
            InReichweite(adresse: wer, geraet: g.geraet, rssi: g.rssi, zuletzt: zeit);
        // ERST EINTRAGEN, DANN MELDEN: wer auf die Meldung hin sofort sendet,
        // muss den Eintrag schon vorfinden.
        if (!_neuDa.isClosed) _neuDa.add(wer);
      } else {
        da.geraet = g.geraet;
        da.rssi = g.rssi;
        da.zuletzt = zeit;
      }
      // KEIN break, UND WAS DAS FUER ZWEI KONTAKTE AUF EINEM GERAET HEISST.
      //
      // Zwei Treffer aus derselben Werbung heissen: zwei Kontakte teilen sich
      // ein Telefon. Beide werden eingetragen, und fuers SENDEN ist das auch
      // richtig — dort steht die Adresse fest und das Geraet wird zu ihr
      // gesucht, das ist eindeutig.
      //
      // Fuers EMPFANGEN gilt das Gegenteil: aus dem Geraet allein laesst sich
      // dann nicht sagen, wer geschrieben hat. Diese Richtung entscheidet
      // `_werIstAn`, und sie entscheidet dort mit gar nicht.
    }
  }

  void _kamAn(Eingegangen e) {
    // KEIN _vergiss() DAVOR, und das ist keine Nachlaessigkeit.
    //
    // Die Frist beantwortet die Frage "kann ich dorthin senden". Hier ist die
    // Frage eine andere: jemand HAT geschrieben, das Geraet war also eben noch
    // da. Wer erst aufraeumte, wuerfe unter Umstaenden genau den Eintrag weg,
    // den er im naechsten Schritt braucht — 90 Sekunden ohne Werbung, dann
    // eine Nachricht, und der Absender waere nicht mehr zuzuordnen.
    // ZUERST DIE MARKE, DANN DIE GERAETEADRESSE.
    //
    // Die Marke ist die verlaessliche Quelle: sie kommt aus demselben
    // Geheimnis wie die Erkennung. Die Geraeteadresse bleibt als Rueckfall
    // fuer den Fall, dass die Marke aus einem Fenster stammt, das die Tabelle
    // gerade nicht mehr fuehrt.
    //
    // DIE MARKE WIRD IN BEIDEN FAELLEN ABGESCHNITTEN. Sie gehoert zum
    // Protokoll und steht immer davor; wer sie stehen liesse, reichte sechs
    // Byte Muell vor dem Chiffrat weiter, und das Entschluesseln scheiterte
    // mit einer Meldung, die auf die Krypto zeigt statt hierher.
    const kopf = leuchtfeuerLaenge + Nahtyp.laenge;
    final t = _tabelle;
    if (e.umschlag.length >= kopf && t != null) {
      final marke = Uint8List.sublistView(e.umschlag, 0, leuchtfeuerLaenge);
      final ausMarke = t.wer(marke);
      if (ausMarke != null) {
        final typ = e.umschlag[leuchtfeuerLaenge];
        final rest = Uint8List.sublistView(e.umschlag, kopf);
        if (typ == Nahtyp.umschlag) {
          _eingang.add(NahUmschlag(ausMarke, rest));
        } else {
          // ALLES ANDERE GEHT IN EINEN EIGENEN STROM. Ein unbekannter Typ
          // wird durchgereicht statt verworfen: entscheiden soll die Ebene,
          // die weiss, was sie kennt — hier wuesste man nur, dass es neu ist.
          _sonderpost.add(NahSonderpost(ausMarke, typ, rest));
        }
        return;
      }
    }

    final wer = _werIstAn(e.geraet);
    if (wer.length != 1) {
      // Ohne EINDEUTIGEN Absender laesst sich nichts entschluesseln: der
      // Sitzungsschluessel haengt an der Gegenstelle. Raten kommt nicht in
      // Frage — jeder Versuch mit dem falschen Kontakt rueckte dessen Ratchet
      // weiter und beschaedigte eine funktionierende Sitzung.
      _eingangPanne(wer.isEmpty
          ? 'Umschlag von unbekanntem Geraet ${e.geraet} verworfen'
          : 'Umschlag von ${e.geraet} verworfen: dahinter stehen '
              '${wer.length} Kontakte, und einer davon waere geraten');
      return;
    }
    // AUCH HIER DEN GANZEN KOPF ABSCHNEIDEN — Marke UND Typ. Beim ersten
    // Einbau hatte ich nur die Marke bedacht; das eine uebrige Byte landete
    // vor dem Chiffrat und liess das Entschluesseln scheitern, mit einer
    // Meldung, die auf die Krypto zeigte statt hierher.
    _eingang.add(NahUmschlag(
        wer.single,
        e.umschlag.length >= kopf
            ? Uint8List.sublistView(e.umschlag, kopf)
            : e.umschlag));
  }

  /// Wessen Geraet das ist — aus dem, was zuletzt gesehen wurde.
  ///
  /// EINE LISTE UND KEIN EINZELNER, weil es zwei sein koennen: zwei Kontakte
  /// auf einem Telefon sind selten, aber `_sah` traegt beide ein, und fuer das
  /// Senden ist das richtig. Den erstbesten zurueckzugeben hiesse, den
  /// Umschlag des einen dem anderen zuzuschreiben — die Entschluesselung
  /// scheitert, und angefasst wurde der Ratchet des FALSCHEN Kontakts. Eine
  /// heile Sitzung waere kaputt fuer eine Nachricht, die ohnehin nicht lesbar
  /// war.
  List<String> _werIstAn(String geraet) => [
        for (final v in _reichweite.values)
          if (v.geraet == geraet) v.adresse,
      ];

  void _vergiss() {
    final grenze = _jetzt().subtract(vergessenNach);
    _reichweite.removeWhere((_, v) => v.zuletzt.isBefore(grenze));
  }

  void _eingangPanne(String s) {
    // Absichtlich kein Werfen: die Naehe ist die Ausfallsicherung. Wenn sie
    // nicht geht, soll die App weiterlaufen, nicht stehenbleiben.
    assert(() {
      // ignore: avoid_print
      print('[Naehe] $s');
      return true;
    }());
  }

  Future<void> dispose() async {
    await halt();
    await _eingang.close();
    await _neuDa.close();
    await _sonderpost.close();
  }
}
