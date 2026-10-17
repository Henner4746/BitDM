// rahmen.dart — Fenster, Telefonbreite, Schreibtischgeruest mit zwei Spalten.
//
// Teil von home.dart (part). Der Zustand (Felder) steht in _HomeState,
// und was beim Sperren vergessen wird, regelt _raeumeOberflaecheAuf dort.
part of '../home.dart';

/// Breiteste Darstellung des Inhalts. Darueber wird der Rest Rand.
///
/// Ein Desktop-Fenster ist leicht 1400 Pixel breit. Ein Eingabefeld dieser
/// Breite ist keins mehr, und eine Textzeile, die man von einem Bildrand zum
/// anderen lesen muss, liest niemand. Diese App ist fuer eine Hand
/// entworfen — in einem grossen Fenster bleibt sie das.
///
/// Genau das stand als Absicht schon in der README ("am Desktop im
/// Handy-Rahmen, am Handy im Vollbild"), war aber nie gebaut. Am 30.07.2026
/// im ersten Windows-Bau nachgemessen: das Feld auf dem Anmeldebildschirm
/// war 1430 Pixel breit.
///
const _telefonbreite = 460.0;

/// Laeuft die App in einem FENSTER, dessen Groesse jemand zieht?
///
/// AN DER PLATTFORM UND NICHT AN DER BREITE, und das war ein Fehler, den ich
/// erst gemessen habe. Zuerst hiess die Regel "ab 460 Pixel begrenzen". Die
/// trifft aber auch den 800x600-Bildschirm der Widget-Tests: der Inhalt
/// wurde dort schmaler und damit hoeher, und 16 Tests fielen mit
/// "RenderFlex overflowed by 22 pixels on the bottom" — 791 statt 807 gruen,
/// am 30.07.2026.
///
/// Auf einem echten Telefon passiert das nicht, weil ein Telefon hoch ist.
/// 800x600 ist weder Telefon noch Desktop, und eine Regel, die daran
/// haengenblieb, war am falschen Merkmal aufgehaengt.
///
/// So laesst sie Android vollstaendig unberuehrt, Tests eingeschlossen, und
/// sagt genauer, was gemeint ist: der Rahmen ist fuer Fenster da, nicht fuer
/// breite Telefone. Das Web ist mitgezaehlt — dort greift zusaetzlich die
/// Breitenpruefung, ein Telefonbrowser bleibt also im Vollbild.
bool get _imFenster =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Breite der Spalte in einem Fenster.
///
/// 460 war die Telefonbreite und im Fenster zu schmal: die Abfolgen —
/// Anmeldung, Phrase, Wiederherstellen — standen als duenner Streifen in
/// einer leeren Flaeche. 560 nimmt der Zeile die Enge, ohne sie so lang zu
/// machen, dass das Auge am Zeilenende den Anfang verliert.
const _fensterspalte = 560.0;

/// Genau die Bildschirme, die eine Abfolge sind — und keinen weiteren.
///
/// Die vier Schreibtisch-Bildschirme ('chats', 'chat', 'id', 'set') stehen
/// bewusst NICHT hier: die haben ihr eigenes Geruest und sind fertig. Der
/// Sperrbildschirm auch nicht, der ist ein eigener Fall.
const _abfolgeSchirme = {
  'onboard', 'creating', 'phrase', 'secure', 'restore', 'test', 'nahHilfe',
  'add',
};

/// Um diesen Faktor waechst die Schrift der Abfolgen im Fenster.
///
/// EIN FAKTOR AN EINER STELLE statt vierzig geaenderter Zahlen: die
/// Proportionen des Entwurfs bleiben damit erhalten, und die naechste
/// Aenderung muss nicht vierzig Stellen finden. Er greift in [_font], also
/// ueberall, wo diese App Text setzt.
///
/// 1.15 ist gemessen, nicht geraten: die kleinste Schrift der Abfolgen ist
/// `label6` mit 10 pt, und 10 pt sind auf 60 cm Abstand an der Grenze. 11.5
/// liest sich dort wie 10 pt in der Hand; mehr liess die Zeilen in der
/// Spalte umbrechen, die vorher in eine Zeile passten (30.07.2026, 984 px
/// Fenster, 24-Zoll-Schirm).
///
/// Die 36-pt-Ueberschrift auf 'onboard' waechst NICHT mit — sie ist dort
/// gegengerechnet kleiner gesetzt, siehe [onboardScreen].
const _schriftFaktor = 1.15;

/// Hoechstbreite eines Knopfes im Fenster.
///
/// In der 560er Spalte bleiben 516 px Innenbreite. Ein Knopf darueber ist
/// ein Banner — er sieht aus wie eine Kopfzeile mit Rahmen. 320 ist an den
/// laengsten Knopfbeschriftungen gemessen ('CREATE IDENTITY',
/// 'WIEDERHERSTELLEN', 'ANFRAGE SENDEN' bei 13 pt mal 1.15): sie passen
/// ohne Umbruch hinein, und der Knopf sieht noch wie einer aus (30.07.2026).
const _knopfBreiteMax = 320.0;

/// Ab dieser Fensterbreite lohnen zwei Spalten.
///
/// Darunter ist die Telefonanordnung die bessere: 300 Pixel Liste plus einen
/// brauchbaren Unterhaltungsbereich gehen sich unter 900 nicht aus, und ein
/// gequetschtes Nebeneinander liest schlechter als ein klares Nacheinander.
const _zweiSpaltenAb = 900.0;

/// Nur diese Bildschirme haben zwei Spalten. Die Einrichtung nicht.
///
/// Anmeldung, Wiederherstellen und die Phrase sind Abfolgen — Schritt fuer
/// Schritt, ein Gedanke je Bild. Die gehoeren auch auf dem Desktop in eine
/// Spalte, sonst steht rechts eine leere Flaeche und fragt, was man dort
/// verpasst hat.
const _schreibtischSchirme = {'chats', 'chat', 'id', 'set'};

extension _Rahmen on _HomeState {
  /// Begrenzt [kind] auf [_telefonbreite], sobald mehr Platz da ist.
  ///
  /// Bewusst NUR um den Inhalt und nicht um das Scaffold: dessen Hintergrund
  /// soll das Fenster weiter ausfuellen. Die Ueberlagerungen daneben im Stack
  /// (Anmeldung, Bogen, Notfall) bleiben ebenfalls voll — sie bringen eigene
  /// Verdunkelung mit, und die muss bis an den Fensterrand reichen.
  Widget _aufTelefonbreite(Widget kind) => !_imFenster
      ? kind
      : LayoutBuilder(
          builder: (_, con) => con.maxWidth <= _telefonbreite
              ? kind
              : Center(
                  child: Container(
                    width: _fensterspalte,
                    // SEITENLINIEN, KEIN KASTEN. Ohne sie schwebt der Text im
                    // Fenster und sieht aus wie ein Fehler im Layout; mit einem
                    // ganzen Rahmen sieht er aus wie ein Dialog, der auf eine
                    // Antwort wartet. Zwei Linien sagen "hier ist die Spalte"
                    // und sonst nichts.
                    decoration: BoxDecoration(
                      border: Border.symmetric(
                        vertical: BorderSide(color: p.lineSoft),
                      ),
                    ),
                    child: kind,
                  ),
                ),
        );

  // ── Abfolgen im Fenster ─────────────────────────────────────────────────
  //
  // Die Bildschirme, die Schritt fuer Schritt durch etwas fuehren, sind fuer
  // eine Hand entworfen: senkrecht zentriert, Knoepfe ueber die ganze Breite,
  // Schrift fuer 30 cm Abstand. Am Schreibtisch sitzt man doppelt so weit weg,
  // das Fenster ist hoeher als jeder Inhalt, und ein Knopf ueber die ganze
  // Spalte ist kein Knopf mehr, sondern ein Banner. Henrik hat das am
  // 30.07.2026 an einem 984x1040 grossen Fenster beanstandet.

  bool get _abfolgeImFenster =>
      _imFenster && _abfolgeSchirme.contains(screen);

  /// Begrenzt einen Knopf im Fenster und schlaegt ihn links an.
  ///
  /// LINKS UND NICHT MITTIG, weil aller Text dieser Bildschirme links
  /// anschlaegt (`CrossAxisAlignment.start`). Ein mittiger Knopf unter linkem
  /// Text sieht aus wie ein Knopf, der zu einem anderen Abschnitt gehoert.
  Widget _knopfBreite(Widget knopf) => !_imFenster
      ? knopf
      : Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _knopfBreiteMax),
            child: knopf,
          ),
        );

  /// Ein Gitter mit ZWEI Kaesten je Zeile, gerechnet aus dem Platz, den es HIER
  /// gibt — nicht aus der Fensterbreite.
  ///
  /// EIN BAUSTEIN FUER BEIDE STELLEN: die zwoelf Woerter auf 'phrase' und die
  /// vierzehn Vierergruppen der Adresse auf 'id'. Vorher stand in beiden
  /// `MediaQuery.of(context).size.width`, und behoben wurde nur die erste — die
  /// zweite fiel dem Gegenlesen am 30.07.2026 auf. Mit einer Stelle kann das
  /// nicht mehr passieren.
  ///
  /// WAS DIE FENSTERBREITE FALSCH MACHT: die Spalte, in der diese Bildschirme
  /// stehen, ist begrenzt — die Abfolgen auf [_fensterspalte] (560 minus zwei
  /// Seitenlinien minus 44 px Rand = 514 px innen), die rechte
  /// Schreibtischspalte auf 720 (676 px innen, im Test nachgemessen). Die alte
  /// Rechnung `(Fensterbreite - 44 - 6) / 2` ergab bei 984 px Fenster 467 px je
  /// Kasten: in 514 px passte davon nur EINER je Zeile. Ab 1078 px Fenster
  /// (bzw. 1402 px bei 676 px Innenbreite) ist der Kasten sogar breiter als der
  /// Platz — RenderWrap klemmt ihn dann auf die Spaltenbreite, also wieder
  /// einer je Zeile. Beides fiel genau die Lesehilfe zusammen, deren Zweck das
  /// Vergleichen ist.
  ///
  /// `con.maxWidth` ist der Platz INNERHALB des Randes, die 44 sind darin also
  /// schon abgezogen — auf Android kommt dasselbe heraus wie vorher.
  Widget _zweiSpaltenGitter(int anzahl, Widget Function(int i) bau) =>
      LayoutBuilder(
        builder: (_, con) => Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < anzahl; i++)
            SizedBox(width: (con.maxWidth - 6) / 2, child: bau(i)),
        ]),
      );

  // ── Schreibtisch ────────────────────────────────────────────────────────
  //
  // WARUM UEBERHAUPT EIN ZWEITES GERUEST. Zuerst habe ich die Telefon-
  // Oberflaeche nur auf 460 Pixel begrenzt und mittig gestellt. Das behob den
  // 1430 Pixel breiten Eingabekasten, sah aber aus wie eine Telefon-App in
  // einem zu grossen Fenster — ein schmaler Streifen mit viel Leere daneben.
  // Henrik hat das am 30.07.2026 genau so beanstandet, und er hatte recht: das
  // war ein Kompromiss, keine Desktop-App.
  //
  // NEU IST NUR DIE ANORDNUNG. Die Bildschirme selbst bleiben, wie sie sind —
  // `chatsScreen()` links, der Rest rechts. Kein zweiter Satz Oberflaeche, der
  // getrennt gepflegt werden muesste, und kein zweiter Ort, an dem ein Fehler
  // behoben werden muss.

  bool get _zweiSpalten =>
      _imFenster && MediaQuery.sizeOf(context).width >= _zweiSpaltenAb;

  bool get _amSchreibtisch =>
      _zweiSpalten &&
      st.bereit &&
      !st.gesperrt &&
      _schreibtischSchirme.contains(screen);

  /// Liste links, Inhalt rechts.
  Widget schreibtischGeruest() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: Column(children: [
              Expanded(child: chatsScreen()),
              buildNav(),
            ]),
          ),
          Container(width: 1, color: p.lineSoft),
          Expanded(child: _rechteSpalte()),
        ],
      );

  /// Was rechts steht, haengt am gewaehlten Bildschirm.
  ///
  /// 'chats' heisst hier NICHT "die Liste nochmal", sondern "es ist nichts
  /// ausgewaehlt" — links steht sie ja schon.
  Widget _rechteSpalte() {
    final inhalt = switch (screen) {
      'chat' => chatScreen(),
      'id' => idScreen(),
      'set' => settingsScreen(),
      _ => _nichtsGewaehlt(),
    };
    // Auch rechts nicht unbegrenzt: eine Textzeile ueber 1200 Pixel liest
    // niemand, und die Einstellungen sind fuer eine Spalte entworfen.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: inhalt,
      ),
    );
  }

  Widget _nichtsGewaehlt() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            t('noChats'),
            textAlign: TextAlign.center,
            style: mono(size: 12, color: p.dim, height: 1.6),
          ),
        ),
      );
}
