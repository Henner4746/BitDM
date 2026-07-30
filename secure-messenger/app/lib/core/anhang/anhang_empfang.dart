// anhang_empfang.dart — aus der Anleitung wieder eine Datei machen.
//
// Der Weg zurueck, und er ist misstrauischer als der Hinweg. Auf dem Hinweg
// stammt alles aus der eigenen App; hier stammt die Anleitung von der
// Gegenstelle und die Bytes von einem Server. Beide koennen luegen, und beide
// tun es auf verschiedene Weise:
//
//   DIE GEGENSTELLE koennte eine Anleitung schicken, die nicht aufgeht —
//   Stuecke, die die angekuendigte Groesse nicht ergeben, Kennungen, die
//   irgendwohin zeigen. Das faengt rezept.dart ab, beim Lesen.
//
//   DER SERVER koennte VERTAUSCHEN: unter der Kennung von Stueck 3 die Bytes
//   von Stueck 5 ausliefern. Faelschen kann er nichts — jedes Stueck ist mit
//   GCM beglaubigt —, aber vertauschen schon. Das faengt der beglaubigte
//   Zusatz ab (siehe stueck_krypto.dart), und die Pruefsumme ueber die ganze
//   Datei faengt ab, was dann noch uebrig ist.
//
// GESCHRIEBEN WIRD IN EINE NEBENDATEI und erst am Ende umbenannt. Bricht der
// Empfang ab — bei drei Gigabyte auf Mobilfunk der Normalfall —, liegt kein
// halbes Bild in der Galerie, das aussieht, als waere es ganz.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'lager_client.dart';
import 'rezept.dart';
import 'native_krypto.dart';
import 'stueck_krypto.dart';

class AnhangKaputt implements Exception {
  const AnhangKaputt(this.grund);
  final String grund;
  @override
  String toString() => 'AnhangKaputt: $grund';
}

class EmpfangsStand {
  const EmpfangsStand({
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

class AnhangEmpfang {
  AnhangEmpfang({
    required this.lager,
    StueckKrypto? krypto,
  }) : krypto = krypto ?? NativeStueckKrypto();

  final LagerClient lager;
  /// NATIV, mit Rueckfall auf Dart.
  ///
  /// Der Unterschied ist gemessen und gross: 16,6 MB/s in Dart gegen rund 90
  /// ueber javax.crypto. Bei einem 32-MiB-Stueck sind das zwei Sekunden gegen
  /// eine Drittelsekunde, bei einer grossen Datei Minuten gegen Sekunden.
  ///
  /// Wo es den Kanal nicht gibt — im Einheitentest, auf allem ausser Android —
  /// rechnet weiter Dart, und zwar bitgleich. Siehe native_krypto.dart.
  final StueckKrypto krypto;

  /// Holt alle Stuecke und schreibt die Datei nach [ziel].
  ///
  /// [ziel] wird vom Aufrufer bestimmt und muss schon gesaeubert sein — der
  /// Name aus der Anleitung kommt von der Gegenstelle und taugt nicht als
  /// Pfad. Siehe [sichererName].
  Future<File> hole(
    Rezept rezept,
    File ziel, {
    void Function(EmpfangsStand)? fortschritt,
    bool danachWegwerfen = true,
  }) async {
    final unfertig = File('${ziel.path}.teil');
    final schreiber = await unfertig.open(mode: FileMode.writeOnly);
    final summe = Sha256();
    final summeSink = summe.newHashSink();
    var fertigeBytes = 0;

    try {
      for (var i = 0; i < rezept.stuecke.length; i++) {
        final s = rezept.stuecke[i];

        final geheim = await _holeMitFortsetzen(
          s,
          i,
          // Gedeckelt auf die Klargroesse, aus demselben Grund wie beim
          // Versand: geholt wird das Stueck mit seinem
          // Beglaubigungsanhang, gemeint ist die Datei.
          (imStueck) => fortschritt?.call(EmpfangsStand(
                fertigeBytes:
                    fertigeBytes + (imStueck > s.klarGroesse ? s.klarGroesse : imStueck),
                gesamtBytes: rezept.gesamtGroesse,
                stueckNr: i + 1,
                stueckZahl: rezept.stuecke.length,
              )),
        );

        final Uint8List klar;
        try {
          klar = await krypto.entschluessle(
            geheim: geheim,
            schluessel: s.schluessel,
            nonce: s.nonce,
            nummer: i,
            vonWievielen: rezept.stuecke.length,
          );
        } on StueckKaputt {
          // Der aussagekraeftigste Fehler des ganzen Wegs: hier ist entweder
          // der Schluessel falsch (dann stimmt die Anleitung nicht) oder das
          // Stueck wurde vertauscht oder veraendert. Beides heisst: nicht
          // weitermachen.
          throw AnhangKaputt('Stueck ${i + 1} laesst sich nicht oeffnen');
        }

        // HIER STAND EINE PRUEFUNG AUF klar.length != s.klarGroesse.
        // Sie ist raus, weil sie nicht feuern KANN: [_holeMitFortsetzen]
        // nimmt genau s.lagerGroesse Byte entgegen und lehnt jede andere
        // Menge ab, und GCM macht aus n+16 Byte immer genau n. Eine Zeile,
        // die aussieht, als pruefe sie etwas, und es nicht tut, ist
        // schlimmer als keine — beim naechsten Lesen haelt man die Sache fuer
        // erledigt.
        //
        // Die Groesse wird also geprueft, nur eine Schicht tiefer. Was dort
        // fehlte, war die Stuecknummer in der Meldung; die steht jetzt da.

        summeSink.add(klar);
        await schreiber.writeFrom(klar);
        fertigeBytes += klar.length;
      }
    } finally {
      await schreiber.close();
    }

    summeSink.close();
    final ist = Uint8List.fromList((await summeSink.hash()).bytes);

    // DIE PRUEFSUMME ZUM SCHLUSS, obwohl jedes Stueck schon beglaubigt war.
    // Sie faengt das ab, was auf Stueck-Ebene niemand sieht: eine Anleitung,
    // in der ein Stueck fehlt oder die Reihenfolge eine andere ist als beim
    // Absender gemeint.
    if (!_gleich(ist, rezept.pruefsumme)) {
      await unfertig.delete();
      throw const AnhangKaputt('die Pruefsumme stimmt nicht');
    }

    // ERST JETZT umbenennen. Bis hierher heisst die Datei ".teil" und sieht
    // niemand fuer fertig an.
    final fertig = await unfertig.rename(ziel.path);

    if (danachWegwerfen) {
      // Ohne Warten und ohne Fehlerbehandlung — wirfWeg verschluckt selbst.
      // Je frueher ein Block aus dem Lager verschwindet, desto besser, aber
      // ein Empfang darf daran nicht haengen.
      unawaited(Future.wait(
          rezept.stuecke.map((s) => lager.wirfWeg(s.kennung))));
    }

    return fertig;
  }

  /// Holt ein Stueck und setzt fort, wenn die Uebertragung abreisst.
  ///
  /// DAS IST DER GRUND, warum nginx den Download direkt macht und nicht der
  /// Dienst: Bereichs-Anfragen kann es von sich aus. Ohne sie faengt jedes
  /// Funkloch das Stueck von vorne an — und bei 16 MiB auf einer schlechten
  /// Strecke waere das ein Empfang, der nie fertig wird.
  Future<Uint8List> _holeMitFortsetzen(
      Stueck s, int nr, void Function(int) fortschritt) async {
    const versuche = 4;
    final ganz = Uint8List(s.lagerGroesse);
    var habe = 0;

    for (var versuch = 0; versuch < versuche; versuch++) {
      try {
        final teil = await lager.hole(
          s.kennung,
          erwarteteGroesse: s.lagerGroesse,
          abByte: habe,
          fortschritt: (imTeil) => fortschritt(habe + imTeil),
        );
        ganz.setAll(habe, teil);
        return ganz;
      } on LagerLeer {
        // Weg ist weg. Ein weiterer Versuch bringt nichts — und die
        // Oberflaeche muss darauf etwas anderes sagen als bei einem
        // Netzfehler ("schon abgeholt oder abgelaufen" statt "noch einmal
        // versuchen"). Deshalb bleibt dieser Fehler, wie er ist.
        rethrow;
      } on LagerException catch (e) {
        // Wie weit sind wir gekommen? Steht in der Meldung nicht — deshalb
        // fragt der naechste Versuch mit demselben Stand noch einmal an. Das
        // ist der langsame, aber sichere Weg; der schnelle waere, sich auf
        // eine Zahl aus einem Fehlertext zu verlassen.
        if (versuch == versuche - 1) {
          // MIT DER STUECKNUMMER. Ohne sie heisst es bei einer Datei aus 192
          // Stuecken nur "mehr Daten als angekuendigt", und niemand weiss,
          // welches gemeint ist.
          throw AnhangKaputt('Stueck ${nr + 1}: ${e.grund}');
        }
        await Future<void>.delayed(Duration(seconds: 1 << versuch));
      }
    }
    throw const AnhangKaputt('unerreichbar');
  }

  static bool _gleich(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var unterschied = 0;
    for (var i = 0; i < a.length; i++) {
      unterschied |= a[i] ^ b[i];
    }
    return unterschied == 0;
  }

  /// Macht aus einem Namen der Gegenstelle einen, der als Dateiname taugt.
  ///
  /// DER NAME KOMMT VON DRAUSSEN. Wer ihn ungeprueft nimmt, laedt sich
  /// "../../shared_prefs/irgendwas" ein — der Anhang landet dann nicht im
  /// Ordner, sondern ueberschreibt etwas. Deshalb bleibt hier nur, was
  /// zweifelsfrei harmlos ist, und im Zweifel gar nichts.
  static String sichererName(String roh) {
    final nurHarmlos = roh.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

    // Fuehrende Punkte weg: ".." waere sonst nach dem Ersetzen immer noch
    // "..", und ".irgendwas" versteckt die Datei nur.
    final ohnePunkte = nurHarmlos.replaceAll(RegExp(r'^\.+'), '');

    final gekuerzt =
        ohnePunkte.length > 120 ? ohnePunkte.substring(0, 120) : ohnePunkte;

    return gekuerzt.isEmpty ? 'anhang' : gekuerzt;
  }
}
