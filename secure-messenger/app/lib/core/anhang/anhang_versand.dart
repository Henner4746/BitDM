// anhang_versand.dart — eine Datei ins Zwischenlager bringen.
//
// Der Ablauf, von oben:
//
//   1. Datei in Stuecke teilen (16 MiB)
//   2. je Stueck: Zufallsschluessel, verschluesseln
//   3. je Stueck: Marke beim Relay holen, ablegen
//   4. Anleitung als gewoehnliche Nachricht schicken
//
// ═══════════════════════════════════ WARUM UEBERHAUPT STUECKE
//
// Ein PUT ist ganz oder gar nicht. Bricht die Uebertragung bei 80 Prozent ab
// — auf Mobilfunk bei drei Gigabyte der Normalfall, nicht die Ausnahme —,
// faengt sie von vorne an. In Stuecken kostet ein Abbruch ein Stueck.
//
// Nebenbei fallen zwei Dinge ab, die sonst eigene Arbeit waeren: der
// Fortschritt ist echt und nicht geschaetzt, und ein Versand laesst sich
// fortsetzen, weil die schon abgelegten Stuecke abgelegt bleiben.
//
// ═════════════════════════════ WARUM VERSCHLUESSELN UND HOCHLADEN INEINANDER
//
// Die reine Dart-Umsetzung von AES-GCM schafft rund 12 MB/s (gemessen am
// 25.07.2026). Nacheinander gerechnet waere die Gesamtzeit die SUMME aus
// Rechnen und Senden. Weil Stueck N+1 verschluesselt wird, waehrend Stueck N
// unterwegs ist, ist sie stattdessen das MAXIMUM der beiden — und ueber jede
// Mobilfunkstrecke ist das Senden ohnehin langsamer. Der Unterschied ist bei
// einem Gigabyte ueber WLAN gut anderthalb Minuten.
//
// Genau EIN Stueck im Voraus, nicht mehr: jedes weitere kostet 16 MiB
// Arbeitsspeicher und bringt nichts, weil ohnehin nur eine Uebertragung
// gleichzeitig laeuft.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../net/relay_client.dart';
import 'lager_client.dart';
import 'rezept.dart';
import 'stueck_krypto.dart';

class AnhangZuGross implements Exception {
  const AnhangZuGross(this.groesse, this.grenze);
  final int groesse;
  final int grenze;
  @override
  String toString() => 'AnhangZuGross: $groesse Byte, erlaubt sind $grenze';
}

/// Wie weit der Versand ist. Fuer den Fortschrittsbalken.
class VersandStand {
  const VersandStand({
    required this.fertigeBytes,
    required this.gesamtBytes,
    required this.stueckNr,
    required this.stueckZahl,
  });

  final int fertigeBytes;
  final int gesamtBytes;
  final int stueckNr;
  final int stueckZahl;

  double get anteil => gesamtBytes == 0 ? 0 : fertigeBytes / gesamtBytes;
}

class AnhangVersand {
  AnhangVersand({
    required this.relay,
    required this.lager,
    this.krypto = const GcmStueckKrypto(),
    Random? zufall,
    this.stueckGroesse = standardStueckGroesse,
  }) : _zufall = zufall ?? Random.secure();

  final RelayClient relay;
  final LagerClient lager;
  final StueckKrypto krypto;
  final Random _zufall;
  final int stueckGroesse;

  /// 16 MiB.
  ///
  /// Die Zahl steht zwischen zwei Grenzen. NACH UNTEN: je kleiner die
  /// Stuecke, desto mehr Zeilen in der Anleitung — und die muss in einen
  /// 64-KiB-Umschlag passen. NACH OBEN: ein Stueck liegt beim Verschluesseln
  /// ganz im Arbeitsspeicher, zweimal sogar (Klartext und Chiffretext), und
  /// ein abgebrochenes Stueck ist verlorene Uebertragung.
  ///
  /// Bei 16 MiB braucht die groesste erlaubte Datei (3 GiB) 192 Stuecke — das
  /// passt in 256 (siehe [Rezept.hoechstStueckzahl]) und kostet rund 23 KB
  /// Anleitung.
  static const int standardStueckGroesse = 16 * 1024 * 1024;

  /// Was das Lager annimmt. Muss zu MAX_BYTES in blob_server.py passen.
  static const int hoechstGroesse = 3 * 1024 * 1024 * 1024;

  /// Schickt [datei] und gibt die fertige Anleitung zurueck.
  ///
  /// Die Anleitung selbst wird hier NICHT verschickt — das macht der Aufrufer
  /// als gewoehnliche Nachricht. So bleibt dieser Weg unabhaengig davon, wie
  /// eine Nachricht verpackt und verschluesselt wird.
  Future<Rezept> schicke(
    File datei, {
    String? name,
    int? groesse,
    void Function(VersandStand)? fortschritt,
  }) async {
    // HEREINREICHBAR, weil der Pfad nicht immer einer ist. Der Dateiwaehler
    // liefert /proc/self/fd/<nr> — einen Zeiger des Kerns auf eine offene
    // Datei. Dort nach der Laenge zu fragen, hiesse sich auf die Semantik
    // eines Sonderdateisystems zu verlassen; der Anbieter hat die Zahl
    // ohnehin schon genannt.
    final gesamt = groesse ?? await datei.length();
    if (gesamt <= 0) {
      throw const AnhangZuGross(0, hoechstGroesse);
    }
    if (gesamt > hoechstGroesse) {
      throw AnhangZuGross(gesamt, hoechstGroesse);
    }

    final zahl = (gesamt / stueckGroesse).ceil();
    if (zahl > Rezept.hoechstStueckzahl) {
      // Kann mit den aktuellen Zahlen nicht vorkommen (3 GiB / 16 MiB = 192).
      // Steht trotzdem hier: wer eines Tages die Stueckgroesse verkleinert,
      // soll es HIER merken und nicht daran, dass der letzte Umschlag beim
      // Relay abprallt — nach der ganzen Uebertragung.
      throw StateError('$zahl Stuecke bei ${stueckGroesse}B je Stueck — '
          'mehr als ${Rezept.hoechstStueckzahl}');
    }

    final leser = await datei.open();
    final summe = Sha256();
    final summeSink = summe.newHashSink();
    final fertige = <Stueck>[];
    var fertigeBytes = 0;

    // Das erste Stueck vorbereiten, bevor die Schleife laeuft. Danach wird
    // in der Schleife immer das NAECHSTE vorbereitet, waehrend das aktuelle
    // hochlaedt.
    //
    // Steht AUSSERHALB des try, damit das finally daran herankommt. Das ist
    // kein Schoenheitsfehler: bricht der Versand ab — Netz weg, Tagesmenge
    // erschoepft —, liest diese Zukunft noch, und ein close() auf eine Datei
    // mit laufendem Lesevorgang wirft "An async operation is currently
    // pending". Diese Ausnahme wuerde die ECHTE ueberdecken, und in der
    // Oberflaeche stuende sie statt "Tagesmenge erschoepft". Genau so war es,
    // bis der Test am 25.07.2026 danebengriff.
    Future<_Vorbereitet>? naechstes = _bereiteVor(leser, 0, zahl, gesamt);

    try {
      for (var i = 0; i < zahl; i++) {
        final jetzt = await naechstes!;
        // ANSTOSSEN, NICHT ABWARTEN. Das ist die ganze Verschraenkung: der
        // await auf `naechstes` steht am Anfang des naechsten Durchlaufs,
        // nicht hier.
        naechstes = i + 1 < zahl ? _bereiteVor(leser, i + 1, zahl, gesamt) : null;

        summeSink.add(jetzt.klar!);
        // Den Klartext SOFORT loslassen. Er wird nur noch fuer die Pruefsumme
        // gebraucht, und die hat ihn jetzt. Ohne diese Zeile liegen waehrend
        // des Hochladens vier Puffer gleichzeitig herum (Klartext und
        // Chiffretext von diesem und vom naechsten Stueck) — bei 16 MiB je
        // Stueck sind das 64 MiB statt 48.
        jetzt.klar = null;

        final marke = await relay.holeMarke(
            jetzt.stueck.kennung, jetzt.geheim.length);
        await lager.lege(
          Marke(
            kennung: marke.kennung,
            groesse: marke.groesse,
            ablauf: marke.ablauf,
            marke: marke.marke,
          ),
          jetzt.geheim,
          // GEDECKELT auf die Klargroesse. Hochgeladen wird das Stueck MIT
          // seinem 16-Byte-Beglaubigungsanhang; gemeint ist aber die Datei,
          // die der Nutzer sieht. Ohne den Deckel zaehlt der Balken bei 25
          // Stuecken 400 Byte ueber das Ziel hinaus und steht am Ende bei
          // 100,004 Prozent.
          fortschritt: (imStueck) => fortschritt?.call(VersandStand(
                fertigeBytes:
                    fertigeBytes + min(imStueck, jetzt.stueck.klarGroesse),
                gesamtBytes: gesamt,
                stueckNr: i + 1,
                stueckZahl: zahl,
              )),
        );

        fertige.add(jetzt.stueck);
        fertigeBytes += jetzt.stueck.klarGroesse;
      }

      summeSink.close();
      final pruefsumme = Uint8List.fromList((await summeSink.hash()).bytes);

      return Rezept(
        name: name ?? datei.uri.pathSegments.last,
        gesamtGroesse: gesamt,
        pruefsumme: pruefsumme,
        stuecke: fertige,
      );
    } finally {
      // Erst das laufende Vorbereiten zu Ende kommen lassen, dann schliessen.
      // Sein Ergebnis wird weggeworfen und sein Fehler verschluckt: es ist
      // Arbeit fuer ein Stueck, das nie abgeschickt wird, und ein Fehler
      // daraus wuerde den Grund verdecken, aus dem wir ueberhaupt hier sind.
      try {
        await naechstes;
      } catch (_) {
        // absichtlich still
      }
      await leser.close();
    }
  }

  Future<_Vorbereitet> _bereiteVor(
      RandomAccessFile leser, int nr, int zahl, int gesamt) async {
    final ab = nr * stueckGroesse;
    final laenge = min(stueckGroesse, gesamt - ab);

    // Der Lesevorgang ist NICHT nebenlaeufig zu sich selbst: RandomAccessFile
    // hat einen Zeiger, und zwei gleichzeitige Leser wuerden sich gegenseitig
    // die Stelle verschieben. Deshalb wird hier ausdruecklich positioniert
    // und die Vorbereitung des naechsten Stuecks erst angestossen, wenn diese
    // hier gelesen hat.
    await leser.setPosition(ab);
    final klar = await leser.read(laenge);
    if (klar.length != laenge) {
      throw StateError('Datei hat sich waehrend des Sendens geaendert');
    }

    final schluessel = _zufallsBytes(32);
    final nonce = _zufallsBytes(12);
    final geheim = await krypto.verschluessle(
      klar: klar,
      schluessel: schluessel,
      nonce: nonce,
      nummer: nr,
      vonWievielen: zahl,
    );

    return _Vorbereitet(
      klar: klar,
      geheim: geheim,
      stueck: Stueck(
        kennung: neueKennung(_zufall),
        schluessel: schluessel,
        nonce: nonce,
        klarGroesse: laenge,
      ),
    );
  }

  Uint8List _zufallsBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _zufall.nextInt(256)));

  /// 32 Byte Zufall in Base32 ohne Auffuellung: 52 Zeichen.
  ///
  /// Sie ist zugleich die Adresse im Lager UND die Erlaubnis, den Block zu
  /// holen. Deshalb Random.secure() und nichts anderes: eine erratbare
  /// Kennung waere ein oeffentlicher Block.
  static String neueKennung(Random zufall) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final b = StringBuffer();
    for (var i = 0; i < 52; i++) {
      b.write(alphabet[zufall.nextInt(32)]);
    }
    return b.toString();
  }
}

class _Vorbereitet {
  _Vorbereitet({
    required this.klar,
    required this.geheim,
    required this.stueck,
  });

  /// Wird auf null gesetzt, sobald die Pruefsumme ihn gesehen hat. Siehe
  /// oben: es geht um 16 MiB, die sonst waehrend des ganzen Hochladens
  /// herumliegen.
  Uint8List? klar;

  final Uint8List geheim;
  final Stueck stueck;
}
