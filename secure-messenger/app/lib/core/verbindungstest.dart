// verbindungstest.dart — die Kette einzeln durchgehen und sagen, wo sie reisst.
//
// WOFUER
// "That did not go through. Check the connection and try again." Dieser Satz
// stand am 26.07.2026 auf Henriks Bildschirm, und er ist wahr und nutzlos
// zugleich: er nennt kein Glied der Kette. Zwischen "abgeschickt" und
// "angekommen" liegen Netz, Namensaufloesung, TLS, WebSocket, Anmeldung beim
// Relay, Marke fuers Zwischenlager, Hochladen, Herunterladen. Faellt eines
// davon aus, sieht der Nutzer immer denselben Satz.
//
// Dieser Test geht jedes Glied EINZELN durch und sagt beim ersten, das haelt
// nicht, was es soll. Er raet nicht: er tut jeweils genau das, was der Betrieb
// auch tut.
//
// DER ANHANG-TEIL LAEDT WIRKLICH HOCH — ein paar Byte, und wirft sie danach
// wieder weg. Nur so faellt auf, wenn das Lager Marken annimmt, aber keine
// Daten; oder wenn nginx den Weg kennt und der Dienst dahinter nicht.
//
// WAS ER NICHT TUT: Zustaende erfinden. Wo etwas noch nicht gebaut ist — die
// Zustellung ueber die Naehe — sagt er das, statt es als Fehler auszugeben.
// Ein Testbericht, der Ungebautes rot anzeigt, treibt Leute dazu, an ihrem
// Telefon herumzustellen.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'anhang/lager_client.dart';
import 'net/relay_client.dart';

/// Wie ein Schritt ausgegangen ist.
enum Befund {
  /// Tut, was er soll.
  gut,

  /// Tut es nicht. Der Grund steht dabei.
  schlecht,

  /// Nicht geprueft, weil ein Schritt davor schon gescheitert ist.
  uebersprungen,

  /// Geprueft, und das Ergebnis ist weder gut noch schlecht — etwa eine
  /// Einstellung, die der Nutzer bewusst so gewaehlt hat.
  hinweis,
}

class Schritt {
  const Schritt(this.schluessel, this.befund, {this.detail, this.dauer});

  /// Uebersetzungsschluessel des Namens. KEIN fertiger Satz: die Sprache
  /// waehlt die Oberflaeche.
  final String schluessel;
  final Befund befund;

  /// Was genau passiert ist — technisch, unuebersetzt, zum Weitergeben.
  ///
  /// Darf eine Fehlermeldung enthalten, aber NIEMALS eine Blob-Kennung oder
  /// eine Adresse: der Bericht wird abfotografiert und weitergereicht.
  final String? detail;

  final Duration? dauer;

  Schritt gescheitert(String d) =>
      Schritt(schluessel, Befund.schlecht, detail: d, dauer: dauer);
}

/// Das Ergebnis eines ganzen Durchlaufs.
class Testbericht {
  const Testbericht(this.schritte);

  final List<Schritt> schritte;

  bool get allesGut => schritte.every((s) => s.befund != Befund.schlecht);

  /// Der erste Schritt, der nicht hielt — das ist der, den man beheben muss.
  Schritt? get ersterFehler =>
      schritte.cast<Schritt?>().firstWhere((s) => s!.befund == Befund.schlecht,
          orElse: () => null);
}

/// Was der Test von aussen braucht.
///
/// Als Schnittstelle und nicht als fester Bezug auf den Kern: so laesst sich
/// jeder einzelne Schritt im Test zum Scheitern bringen, ohne einen Server zu
/// betreiben.
abstract class TestUmgebung {
  Uri get relay;
  Uri get lager;

  /// Die eigene Adresse, oder null, wenn es noch keine gibt.
  String? get eigeneAdresse;

  /// Der verbundene Relay, oder null.
  RelayClient? get relayClient;

  /// Ob der Nutzer "nur in der Naehe" eingeschaltet hat.
  bool get nurNahbereich;

  /// Ob der Nutzer den Funk eingeschaltet hat.
  bool get naheAn;

  /// Ob der Funk WIRKLICH laeuft — nicht, ob er laufen soll.
  ///
  /// Der Unterschied ist der ganze Sinn dieses Schritts. Am 27.07.2026 stand
  /// auf einem von zwei Telefonen der Schalter auf an, und es funkte
  /// trotzdem nicht: der Nahbereich war mit einer leeren Kontaktliste
  /// aufgesetzt worden und hat danach nie neu aufgesetzt. Von aussen war das
  /// nicht zu sehen — die Einstellung sagte "an", das Geraet schwieg, und der
  /// Verbindungstest kannte den Funk gar nicht.
  bool get naheLaeuft;

  /// Wie viele Kontakte am Funk teilnehmen (Anwesenheit nicht abgeschaltet).
  int get naheKontakte;

  /// Wie viele davon gerade in Reichweite sind.
  int get naheInReichweite;

  /// Ein HTTP-Client fuer die einfachen Abfragen.
  HttpClient httpClient();

  /// Ein Lager-Client auf [lager].
  LagerClient lagerClient();
}

class Verbindungstest {
  Verbindungstest(this.umgebung, {this.zeitgrenze = const Duration(seconds: 12)});

  final TestUmgebung umgebung;
  final Duration zeitgrenze;

  static final _zufall = Random.secure();

  /// Laeuft die Kette durch. Meldet jeden Schritt einzeln ueber [beiSchritt],
  /// damit die Oberflaeche mitwaechst, statt am Ende alles auf einmal zu
  /// zeigen.
  Future<Testbericht> lauf({void Function(Schritt)? beiSchritt}) async {
    final schritte = <Schritt>[];

    void merke(Schritt s) {
      schritte.add(s);
      beiSchritt?.call(s);
    }

    // ── 1. Identitaet ──────────────────────────────────────────────────
    final ich = umgebung.eigeneAdresse;
    if (ich == null) {
      merke(const Schritt('pruefIdentitaet', Befund.schlecht,
          detail: 'keine Identitaet auf diesem Geraet'));
      return Testbericht(schritte);
    }
    merke(const Schritt('pruefIdentitaet', Befund.gut));

    // DER FUNK KOMMT VOR DEM AUSSTIEG FUER "NUR IN DER NAEHE".
    //
    // Er stand danach, und damit war er in genau dem Modus unsichtbar, in dem
    // er der EINZIGE Weg ist: der Ausstieg unten kehrt vorher um. Wer "nur in
    // der Naehe" einschaltet und dann wissen will, warum nichts ankommt, sah
    // eine Zeile "kein Server" und sonst nichts.
    //
    // Aufgefallen am 29.07.2026, und zwar teuer: aus der fehlenden Zeile habe
    // ich geschlossen, der Schalter stehe auf aus — er stand auf an, und beide
    // Telefone funkten laengst.
    // ── 2. Der Funk ───────────────────────────────────────────────────
    //
    // ER STAND HIER LANGE NICHT, und das hat einen Fehler gekostet: auf einem
    // Telefon war der Schalter an und das Geraet funkte trotzdem nicht, und
    // die App hatte keine einzige Stelle, an der man das sehen konnte. Ein
    // Diagnosebildschirm, der den halben Weg nicht kennt, sagt genau dann
    // nichts, wenn man ihn braucht.
    //
    // Drei Zahlen statt eines Hakens: laeuft er, wie viele Kontakte nehmen
    // teil, wie viele sind gerade da. Nur zusammen sagen sie, WO es klemmt —
    // "laeuft, 0 Kontakte" ist ein anderer Fehler als "laeuft nicht" und ein
    // dritter als "laeuft, 3 Kontakte, keiner in Reichweite" (das ist gar
    // keiner, da ist bloss niemand in der Naehe).
    // DIE ZEILE STEHT JETZT IMMER DA, AUCH WENN DER SCHALTER AUS IST.
    //
    // Vorher hing der ganze Schritt an `if (umgebung.naheAn)` — und damit
    // schwieg die Diagnose ausgerechnet in dem Fall, in dem man sie
    // aufschlaegt: der Schalter geht nicht an, und der Bildschirm, der sagen
    // soll warum, zeigt die Zeile gar nicht erst.
    //
    // Am 29.07.2026 hat mich genau das eine Stunde gekostet. Aus "die Zeile
    // fehlt" liess sich zwar rueckschliessen, dass naheAn falsch ist, aber
    // das ist ein Schluss fuer jemanden, der den Quelltext kennt — nicht die
    // Auskunft, fuer die dieser Bildschirm gebaut ist.
    if (umgebung.naheAn) {
      merke(Schritt(
        'pruefFunk',
        umgebung.naheLaeuft ? Befund.gut : Befund.schlecht,
        detail: umgebung.naheLaeuft
            ? '${umgebung.naheKontakte} Kontakte, '
                '${umgebung.naheInReichweite} in Reichweite'
            : 'der Schalter steht auf an, der Funk laeuft aber nicht',
      ));
    } else {
      merke(const Schritt(
        'pruefFunk',
        Befund.uebersprungen,
        detail: 'der Schalter steht auf aus',
      ));
    }


    // ── 3. Nur in der Naehe ────────────────────────────────────────────
    //
    // ZUERST, nicht zuletzt. Wer den Schalter an hat, soll nicht erst drei
    // rote Zeilen sehen und dann erfahren, dass er sie selbst verursacht hat.
    if (umgebung.nurNahbereich) {
      merke(const Schritt('pruefNahbereich', Befund.hinweis));
      for (final s in const ['pruefRelay', 'pruefAngemeldet', 'pruefLager']) {
        merke(Schritt(s, Befund.uebersprungen));
      }
      return Testbericht(schritte);
    }

    // ── 3. Relay: Verbindung ───────────────────────────────────────────
    final r = await _messen(() async {
      final c = umgebung.relayClient;
      if (c == null || !c.isConnected) {
        throw const RelayException('keine offene Verbindung zum Relay');
      }
    });
    merke(Schritt('pruefRelay', r.$1 == null ? Befund.gut : Befund.schlecht,
        detail: r.$1, dauer: r.$2));
    if (r.$1 != null) {
      for (final s in const ['pruefAngemeldet', 'pruefLager']) {
        merke(Schritt(s, Befund.uebersprungen));
      }
      return Testbericht(schritte);
    }

    // ── 4. Angemeldet? ─────────────────────────────────────────────────
    //
    // Das eigene Buendel abholen. Kommt es, kennt der Relay diese Adresse —
    // und das ist die Voraussetzung dafuer, dass jemand eine Sitzung mit ihr
    // aufbauen kann. Ein stiller Fehlschlag genau hier war der Grund, warum
    // die App nach einem Serverwechsel lautlos verstummte.
    final a = await _messen(() async {
      await umgebung.relayClient!.fetchBundle(ich);
    });
    merke(Schritt('pruefAngemeldet', a.$1 == null ? Befund.gut : Befund.schlecht,
        detail: a.$1, dauer: a.$2));

    // ── 5. Zwischenlager, den ganzen Weg ───────────────────────────────
    final l = await _messen(_lagerDurchstich);
    merke(Schritt('pruefLager', l.$1 == null ? Befund.gut : Befund.schlecht,
        detail: l.$1, dauer: l.$2));

    return Testbericht(schritte);
  }

  /// Marke holen, hochladen, herunterladen, vergleichen, wegwerfen.
  ///
  /// KEIN EINZIGER SCHRITT DAVON DARF FEHLEN. Eine Marke zu bekommen beweist
  /// nur, dass der Relay sein Geheimnis hat. Hochladen beweist, dass das Lager
  /// dasselbe Geheimnis hat und Platz. Herunterladen beweist, dass nginx den
  /// Weg kennt. Erst der Vergleich beweist, dass wirklich dieselben Bytes
  /// ankamen.
  Future<void> _lagerDurchstich() async {
    final kennung = _kennung();
    final probe = Uint8List.fromList(
        List<int>.generate(64, (_) => _zufall.nextInt(256)));

    final marke = await umgebung.relayClient!.holeMarke(kennung, probe.length);

    final lager = umgebung.lagerClient();
    try {
      await lager.lege(
        Marke(
          kennung: marke.kennung,
          groesse: marke.groesse,
          ablauf: marke.ablauf,
          marke: marke.marke,
        ),
        probe,
      );

      final zurueck =
          await lager.hole(kennung, erwarteteGroesse: probe.length);
      if (zurueck.length != probe.length) {
        throw LagerException(
            'zurueck kamen ${zurueck.length} statt ${probe.length} Byte');
      }
      for (var i = 0; i < probe.length; i++) {
        if (zurueck[i] != probe[i]) {
          throw const LagerException('die Bytes kamen veraendert zurueck');
        }
      }
    } finally {
      // AUFRAEUMEN AUCH IM FEHLERFALL. Sonst bleibt bei jedem Testlauf ein
      // Rest liegen, und irgendwann ist das Lager voll mit Proben.
      try {
        await lager.wirfWeg(kennung);
      } catch (_) {}
      lager.schliesse();
    }
  }

  String _kennung() {
    const zeichen = 'abcdefghijklmnopqrstuvwxyz234567';
    return List.generate(52, (_) => zeichen[_zufall.nextInt(32)]).join();
  }

  /// Fuehrt [was] aus und gibt (Fehlertext oder null, Dauer) zurueck.
  Future<(String?, Duration)> _messen(Future<void> Function() was) async {
    final start = DateTime.now();
    try {
      await was().timeout(zeitgrenze);
      return (null, DateTime.now().difference(start));
    } on TimeoutException {
      return (
        'keine Antwort innerhalb von ${zeitgrenze.inSeconds} Sekunden',
        DateTime.now().difference(start)
      );
    } catch (e) {
      return (_lesbar(e), DateTime.now().difference(start));
    }
  }

  /// Macht aus einer Ausnahme etwas, das man vorlesen kann.
  ///
  /// OHNE KENNUNGEN UND ADRESSEN: der Bericht wird abfotografiert und
  /// weitergeschickt. Was hier steht, soll den Fehler benennen und sonst
  /// nichts verraten.
  static String _lesbar(Object e) {
    if (e is LagerVoll) return 'das Zwischenlager ist voll';
    if (e is LagerException) {
      final s = e.status;
      return s == null ? e.grund : '${e.grund} (HTTP $s)';
    }
    if (e is RelayException) return e.grund;
    if (e is SocketException) {
      final o = e.osError;
      return o == null ? e.message : '${e.message}: ${o.message}';
    }
    if (e is HandshakeException) return 'TLS-Handschlag gescheitert';
    if (e is HttpException) return e.message;
    return e.runtimeType.toString();
  }
}
