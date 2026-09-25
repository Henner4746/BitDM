// chat_repository.dart — Kontakte und Nachrichten in der verschluesselten
// Datenbank.
//
// Anders als signal_store_repository.dart schreibt diese Schicht sofort. Der
// Grund ist der Unterschied im Schadensbild: geht eine Sitzung halb verloren,
// koennen sich zwei Leute dauerhaft nicht mehr erreichen, ohne dass ein Fehler
// gemeldet wird. Geht eine Nachricht verloren, fehlt eine Nachricht — aergerlich,
// aber sichtbar und behebbar. Der Aufwand einer Nachbuchschicht lohnt hier
// nicht.
//
// Was trotzdem gilt: eine EMPFANGENE Nachricht und der Sitzungsfortschritt, der
// beim Entschluesseln entstanden ist, gehoeren in dieselbe Transaktion. Sonst
// ist der Ratchet weitergerueckt, die Nachricht aber nicht gespeichert — und
// sie ist unwiederbringlich weg, weil sie sich kein zweites Mal entschluesseln
// laesst. Dafuer gibt es [speichereEmpfangen].

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';

import '../models.dart';
import 'encrypted_database.dart';
import 'signal_store.dart';
import 'signal_store_repository.dart';

/// Was beim Aufraeumen weggefallen ist.
///
/// [dateien] sind lokale Pfade, die der AUFRUFER loeschen muss. Diese Schicht
/// fasst nur die Datenbank an: Dateien liegen woanders, das Loeschen ist
/// asynchron, und ein fehlgeschlagenes Loeschen darf keine Transaktion
/// zurueckrollen, die schon richtig war.
class Aufgeraeumt {
  const Aufgeraeumt(this.nachrichten, this.dateien);
  final int nachrichten;
  final List<String> dateien;
}

class ChatRepository {
  ChatRepository(this.db, this.signalRepo);

  final EncryptedDatabase db;
  final SignalStoreRepository signalRepo;

  // ══════════════════════════════════════════════════════════════ Kontakte

  /// WAS ZWISCHEN ZWEI EIGENEN GERAETEN NICHT ABGEGLICHEN WIRD.
  ///
  /// Es gibt keinen Listenabgleich. Kontakte entstehen auf dem zweiten Geraet
  /// beilaeufig: eingehend ohnehin (die Gegenstelle faechert an beide Geraete),
  /// ausgehend ueber den Spiegel. Nicht mitkommen deshalb Kontakte, die nur
  /// angelegt und nie beschrieben wurden, sowie [Contact.displayName] und
  /// [Contact.verified].
  ///
  /// Das ist die faule Fassung von "dieselben Kontakte" und trifft den
  /// vereinbarten Umfang: wer alte Verlaeufe nicht uebertraegt, darf auch mit
  /// einer leeren Kontaktliste anfangen, die sich ab dann mitfuehrt.
  /// ponytail: kein Kontaktabgleich, nur Mitfuehren ab dem Koppeln. Ausbau
  /// erst, wenn jemandem die fehlenden Anzeigenamen wirklich auffallen.
  List<Contact> alleKontakte() {
    return db.raw
        .select('SELECT * FROM contacts ORDER BY added_at DESC')
        .map(_zuKontakt)
        .toList();
  }

  Contact? kontakt(String adresse) {
    final r = db.raw
        .select('SELECT * FROM contacts WHERE address = ?', [adresse]);
    return r.isEmpty ? null : _zuKontakt(r.first);
  }

  bool kennt(String adresse) => db.raw
      .select('SELECT 1 FROM contacts WHERE address = ?', [adresse]).isNotEmpty;

  /// Wann zuletzt nachgesehen wurde, welche Geraete dieser Kontakt hat.
  ///
  /// 0 fuer "nie" — und ebenso fuer eine Adresse, die gar kein Kontakt ist.
  /// Beides bedeutet dasselbe: nachsehen.
  int geraeteGeprueft(String adresse) {
    final r = db.raw.select(
        'SELECT geraete_geprueft FROM contacts WHERE address = ?', [adresse]);
    return r.isEmpty ? 0 : r.first['geraete_geprueft'] as int;
  }

  /// Haelt fest, wann zuletzt nachgesehen wurde. 0 setzt die Frist zurueck.
  ///
  /// Zurueckgesetzt wird, wenn der Relay ein Zielgeraet nicht mehr kennt: dann
  /// stimmt die Liste nachweislich nicht mehr, und auf das Sechs-Stunden-
  /// Fenster zu warten hiesse, sechs Stunden lang gegen ein totes Geraet zu
  /// senden.
  void setzeGeraeteGeprueft(String adresse, int wann) {
    db.transaction((raw) => raw.execute(
        'UPDATE contacts SET geraete_geprueft = ? WHERE address = ?',
        [wann, adresse]));
  }

  void speichereKontakt(Contact c) {
    db.transaction((raw) => _schreibeKontakt(raw, c));
  }

  static void _schreibeKontakt(CommonDatabase raw, Contact c) {
    raw.execute(
      'INSERT INTO contacts '
      '(address, display_name, added_at, state, verified, zeigt_anwesenheit, '
      ' angeheftet, archiviert, stumm, frist) '
      'VALUES (?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(address) DO UPDATE SET '
      '  display_name      = excluded.display_name,'
      '  state             = excluded.state,'
      '  verified          = excluded.verified,'
      '  zeigt_anwesenheit = excluded.zeigt_anwesenheit,'
      '  angeheftet        = excluded.angeheftet,'
      '  archiviert        = excluded.archiviert,'
      '  stumm             = excluded.stumm,'
      '  frist             = excluded.frist',
      [
        c.id,
        c.displayName,
        c.addedAt.toUtc().millisecondsSinceEpoch,
        c.state.index,
        c.verified ? 1 : 0,
        c.zeigtAnwesenheit ? 1 : 0,
        c.angeheftet ? 1 : 0,
        c.archiviert ? 1 : 0,
        c.stumm ? 1 : 0,
        c.fristSekunden,
      ],
    );
  }

  /// Entfernt einen Kontakt samt Unterhaltung.
  ///
  /// Die Sitzung wird mitgeloescht: bliebe sie stehen, koennte die Gegenstelle
  /// weiter Nachrichten schicken, die sich entschluesseln liessen, obwohl der
  /// Nutzer sie entfernt hat.
  ///
  /// Rueckgabe: die lokalen Dateien der Anhaenge. Der Aufrufer muss sie
  /// loeschen — siehe [loescheAbgelaufene].
  Aufgeraeumt entferneKontakt(String adresse) {
    var dateien = <String>[];
    db.transaction((raw) {
      dateien = _anhangDateien(
          raw, 'SELECT pfad FROM anhaenge WHERE chat_id = ?', [adresse]);
      raw.execute('DELETE FROM anhaenge WHERE chat_id = ?', [adresse]);
      raw.execute('DELETE FROM messages WHERE chat_id = ?', [adresse]);
      raw.execute('DELETE FROM reaktionen WHERE chat_id = ?', [adresse]);
      raw.execute('DELETE FROM stimmen WHERE chat_id = ?', [adresse]);
      // Was noch an diesen Kontakt hinaus wollte, will jetzt nirgendwohin
      // mehr: eine Reaktion an jemanden, der nicht mehr in der Liste steht,
      // waere ein Lebenszeichen, das der Nutzer gerade abgestellt hat.
      raw.execute('DELETE FROM ausgang WHERE chat_id = ?', [adresse]);
      raw.execute('DELETE FROM contacts WHERE address = ?', [adresse]);
    });
    return Aufgeraeumt(0, dateien);
  }

  static Contact _zuKontakt(Row r) => Contact(
        id: r['address'] as String,
        displayName: r['display_name'] as String?,
        addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int,
            isUtc: true),
        state: ContactState.values[r['state'] as int],
        verified: (r['verified'] as int) != 0,
        // Kein `?? true` als Rueckfall: die Spalte ist NOT NULL DEFAULT 1,
        // und ein stiller Rueckfall wuerde einen Lesefehler in ein
        // "zeigt sich allen" verwandeln — die falsche Richtung.
        zeigtAnwesenheit: (r['zeigt_anwesenheit'] as int) != 0,
        angeheftet: (r['angeheftet'] as int) != 0,
        archiviert: (r['archiviert'] as int) != 0,
        stumm: (r['stumm'] as int) != 0,
        fristSekunden: r['frist'] as int?,
      );

  // ═══════════════════════════════════════════════════════════ Nachrichten

  /// Verlauf einer Unterhaltung, aelteste zuerst.
  ///
  /// [before] blaettert rueckwaerts und meint die lokale Reihenfolge, nicht die
  /// Uhrzeit — siehe die Begruendung zu `seq` im Schema.
  List<Message> verlauf(String chatId, {int limit = 50, int? beforeSeq}) {
    final zeilen = beforeSeq == null
        ? db.raw.select(
            'SELECT * FROM messages WHERE chat_id = ? '
            'ORDER BY seq DESC LIMIT ?',
            [chatId, limit])
        : db.raw.select(
            'SELECT * FROM messages WHERE chat_id = ? AND seq < ? '
            'ORDER BY seq DESC LIMIT ?',
            [chatId, beforeSeq, limit]);
    // Rueckwaerts geholt, damit LIMIT die NEUESTEN nimmt; fuer die Anzeige
    // wieder umgedreht.
    return zeilen.map(_zuNachricht).toList().reversed.toList();
  }

  int? seqVon(String chatId, String messageId, String senderId) {
    final r = db.raw.select(
        'SELECT seq FROM messages WHERE chat_id=? AND sender_id=? AND id=?',
        [chatId, senderId, messageId]);
    return r.isEmpty ? null : r.first['seq'] as int;
  }

  /// Legt eine eigene Nachricht an, noch bevor sie verschickt ist.
  ///
  /// [anhang] und [rezept] gehoeren zusammen und werden in DERSELBEN
  /// Transaktion geschrieben wie die Nachricht. Auseinander waere die
  /// Nachricht da und der Anhang unauffindbar — oder umgekehrt eine Anleitung
  /// ohne Nachricht, die niemand je zu Gesicht bekommt.
  void speichereEigene(Message m,
      {Duration? lebensdauer, AnhangEintrag? anhang, String? rezept}) {
    db.transaction((raw) {
      _schreibeNachricht(raw, m, empfangen: false, lebensdauer: lebensdauer);
      if (anhang != null) _schreibeAnhang(raw, anhang, rezept!);
    });
  }

  /// Speichert eine empfangene Nachricht UND den Sitzungsfortschritt in
  /// derselben Transaktion.
  ///
  /// Das ist der Kern dieser Datei. Beim Entschluesseln rueckt der Ratchet
  /// weiter; genau diese Nachricht laesst sich danach nie wieder
  /// entschluesseln. Wuerde der Sitzungsfortschritt festgeschrieben und das
  /// Speichern der Nachricht scheitern, waere sie fuer immer verloren — und
  /// niemand haette einen Fehler gesehen.
  ///
  /// Rueckgabe: false, wenn die Nachricht schon vorlag (doppelt zugestellt).
  /// Der Sitzungsfortschritt wird trotzdem geschrieben.
  bool speichereEmpfangen(Message m, BitdmSignalStore store,
      {Duration? lebensdauer, AnhangEintrag? anhang, String? rezept}) {
    var neu = false;
    db.transaction((raw) {
      neu = _schreibeNachricht(raw, m, empfangen: true, lebensdauer: lebensdauer);
      // Ohne `neu &&`: die Vorsicht gegen doppelt zugestellte Nachrichten
      // sitzt im ON CONFLICT von [_schreibeAnhang] und gehoert dorthin — an
      // die Ablage, wo sie fuer JEDEN Aufrufer gilt. Sie hier ein zweites Mal
      // zu bauen, hiesse zwei Schutzwaelle fuer dieselbe Sache: eine
      // Mutationsprobe kann dann keinen von beiden mehr sehen, weil der
      // andere einspringt.
      if (anhang != null) _schreibeAnhang(raw, anhang, rezept!);
      SignalStoreRepository.schreibeDelta(raw, store);
    });
    store.markClean();
    return neu;
  }

  /// Wie [speichereEmpfangen], zusaetzlich mit einem Kontakt.
  ///
  /// Der Fall: eine Nachricht von jemandem, den es lokal noch nicht gibt. Der
  /// Kontakt entsteht dabei und muss zusammen mit der Nachricht bestehen —
  /// sonst laege eine Nachricht ohne Unterhaltung in der Datenbank.
  bool speichereEmpfangenMitKontakt(Message m, Contact c,
      BitdmSignalStore store,
      {Duration? lebensdauer, AnhangEintrag? anhang, String? rezept}) {
    var neu = false;
    db.transaction((raw) {
      _schreibeKontakt(raw, c);
      neu = _schreibeNachricht(raw, m, empfangen: true, lebensdauer: lebensdauer);
      if (anhang != null) _schreibeAnhang(raw, anhang, rezept!);
      SignalStoreRepository.schreibeDelta(raw, store);
    });
    store.markClean();
    return neu;
  }

  // ═══════════════════════════════════════════════════════════════ Anhaenge

  /// Alle Anhaenge einer Unterhaltung, nach Nachrichtenkennung.
  ///
  /// In EINER Abfrage und nicht je Nachricht: eine Unterhaltung mit fuenfzig
  /// Anhaengen ergaebe sonst fuenfzig Abfragen beim Zeichnen einer einzigen
  /// Liste.
  Map<String, AnhangEintrag> anhaenge(String chatId) {
    final zeilen =
        db.raw.select('SELECT * FROM anhaenge WHERE chat_id = ?', [chatId]);
    return {
      for (final r in zeilen) r['message_id'] as String: _zuAnhang(r),
    };
  }

  AnhangEintrag? anhang(String chatId, String senderId, String messageId) {
    final r = db.raw.select(
        'SELECT * FROM anhaenge WHERE chat_id=? AND sender_id=? AND message_id=?',
        [chatId, senderId, messageId]);
    return r.isEmpty ? null : _zuAnhang(r.first);
  }

  /// Die Anleitung — erst hier, nicht schon beim Anzeigen der Liste.
  ///
  /// Bei einer grossen Datei sind das rund 23 KB, und gebraucht werden sie
  /// genau einmal: wenn jemand herunterlaedt.
  String? rezeptText(String chatId, String senderId, String messageId) {
    final r = db.raw.select(
        'SELECT rezept FROM anhaenge WHERE chat_id=? AND sender_id=? AND message_id=?',
        [chatId, senderId, messageId]);
    return r.isEmpty ? null : r.first['rezept'] as String;
  }

  void setzeAnhangZustand(
    String chatId,
    String senderId,
    String messageId,
    AnhangZustand zustand, {
    String? pfad,
  }) {
    db.transaction((raw) => raw.execute(
        'UPDATE anhaenge SET zustand=?, pfad=COALESCE(?, pfad) '
        'WHERE chat_id=? AND sender_id=? AND message_id=?',
        [zustand.index, pfad, chatId, senderId, messageId]));
  }

  /// Setzt alle "laedt gerade" auf "gescheitert" zurueck.
  ///
  /// BEIM START AUFZURUFEN. Wird die App waehrend eines Downloads
  /// weggewischt, bleibt der Zustand sonst fuer immer auf "laedt", und die
  /// Oberflaeche zeigt einen Fortschritt, hinter dem nichts mehr laeuft.
  int raeumeHaengendeAnhaengeAuf() {
    var betroffen = 0;
    db.transaction((raw) {
      raw.execute('UPDATE anhaenge SET zustand=? WHERE zustand=?',
          [AnhangZustand.gescheitert.index, AnhangZustand.laedt.index]);
      betroffen = raw.updatedRows;
    });
    return betroffen;
  }

  static void _schreibeAnhang(
      CommonDatabase raw, AnhangEintrag a, String rezept) {
    raw.execute(
      'INSERT INTO anhaenge '
      '(chat_id, sender_id, message_id, name, groesse, rezept, zustand, pfad) '
      'VALUES (?,?,?,?,?,?,?,?) '
      // Bei einer doppelt zugestellten Nachricht darf der oertliche Zustand
      // NICHT zurueckfallen — sonst boete die Oberflaeche an, eine Datei noch
      // einmal zu holen, die schon dasteht.
      'ON CONFLICT(chat_id, sender_id, message_id) DO NOTHING',
      [
        a.chatId,
        a.senderId,
        a.messageId,
        a.name,
        a.groesse,
        rezept,
        a.zustand.index,
        a.pfad,
      ],
    );
  }

  static AnhangEintrag _zuAnhang(Row r) => AnhangEintrag(
        messageId: r['message_id'] as String,
        chatId: r['chat_id'] as String,
        senderId: r['sender_id'] as String,
        name: r['name'] as String,
        groesse: r['groesse'] as int,
        zustand: AnhangZustand.values[r['zustand'] as int],
        pfad: r['pfad'] as String?,
      );

  /// Legt einen Kontakt an und schreibt den Sitzungsfortschritt zusammen.
  ///
  /// Fuer eine Kontaktanfrage OHNE Text: sie legt nichts in den Verlauf — ein
  /// leerer Gespraechsbeitrag waere in der Oberflaeche eine leere Blase —, aber
  /// der Kontakt und der Ratchet-Fortschritt gehoeren trotzdem zusammen
  /// festgeschrieben.
  void speichereKontaktUndSitzung(Contact c, BitdmSignalStore store) {
    db.transaction((raw) {
      _schreibeKontakt(raw, c);
      SignalStoreRepository.schreibeDelta(raw, store);
    });
    store.markClean();
  }

  /// Schreibt nur den Sitzungsfortschritt — fuer Steuernachrichten, die nichts
  /// in den Verlauf legen (Bestaetigungen, Kontaktantworten).
  void speichereNurSitzung(BitdmSignalStore store) {
    if (!store.isDirty) return;
    db.transaction((raw) => SignalStoreRepository.schreibeDelta(raw, store));
    store.markClean();
  }

  static bool _schreibeNachricht(CommonDatabase raw, Message m,
      {required bool empfangen, Duration? lebensdauer}) {
    // Der Verfallszeitpunkt wird EINMAL beim Speichern festgelegt, nicht bei
    // jeder Abfrage aus Alter plus Frist gerechnet. Sonst wuerde eine spaeter
    // geaenderte Einstellung rueckwirkend Nachrichten loeschen — oder, noch
    // schlimmer, geglaubt-geloeschte wieder auftauchen lassen.
    final verfall = lebensdauer == null
        ? null
        : DateTime.now().toUtc().add(lebensdauer).millisecondsSinceEpoch;

    raw.execute(
      'INSERT OR IGNORE INTO messages '
      '(id, chat_id, sender_id, body, kind, is_mine, sent_at, received_at, '
      ' status, expires_at, ueber_naehe, schon_beim_relay, antwort_auf, '
      ' faellig) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        m.id,
        m.chatId,
        m.senderId,
        m.text,
        m.kind.index,
        m.isMine ? 1 : 0,
        m.timestamp.toUtc().millisecondsSinceEpoch,
        empfangen ? DateTime.now().toUtc().millisecondsSinceEpoch : null,
        m.status.index,
        verfall,
        m.ueberNaehe ? 1 : 0,
        m.schonBeimRelay ? 1 : 0,
        m.antwortAuf,
        m.geplantFuer?.toUtc().millisecondsSinceEpoch,
      ],
    );
    return raw.updatedRows > 0;
  }

  /// Loescht alles, dessen Zeit abgelaufen ist.
  ///
  /// Billig, wenn nichts zu tun ist — der Index auf expires_at deckt nur die
  /// Zeilen ab, die ueberhaupt einen Verfall haben.
  ///
  /// GIBT DIE DATEIEN ZURUECK, statt sie zu loeschen. Diese Schicht fasst nur
  /// die Datenbank an; Dateien liegen woanders und werden asynchron
  /// weggeraeumt. Der Aufrufer MUSS das tun — eine verschwundene Nachricht,
  /// deren Anhang weiter im Speicher des Telefons liegt, ist genau die Sorte
  /// gebrochene Zusage, wegen der es die Verfallsfrist ueberhaupt gibt.
  Aufgeraeumt loescheAbgelaufene() {
    var weg = 0;
    var dateien = <String>[];
    db.transaction((raw) {
      final jetzt = DateTime.now().toUtc().millisecondsSinceEpoch;
      // Erst die Anhaenge einsammeln, DANN die Nachrichten loeschen — danach
      // liesse sich nicht mehr feststellen, welche es waren.
      dateien = _anhangDateien(
          raw,
          'SELECT a.pfad FROM anhaenge a JOIN messages m '
          '  ON a.chat_id=m.chat_id AND a.sender_id=m.sender_id '
          ' AND a.message_id=m.id '
          'WHERE m.expires_at IS NOT NULL AND m.expires_at <= ?',
          [jetzt]);
      raw.execute(
          'DELETE FROM anhaenge WHERE (chat_id, sender_id, message_id) IN ('
          '  SELECT chat_id, sender_id, id FROM messages '
          '  WHERE expires_at IS NOT NULL AND expires_at <= ?)',
          [jetzt]);
      raw.execute(
          'DELETE FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?',
          [jetzt]);
      weg = raw.updatedRows;
      // Reaktionen auf eine verschwundene Nachricht verschwinden mit ihr —
      // sonst verriete die Tabelle noch Wochen spaeter, dass es sie gab.
      if (weg > 0) _raeumeReaktionenAuf(raw);
    });
    return Aufgeraeumt(weg, dateien);
  }

  static List<String> _anhangDateien(
          CommonDatabase raw, String abfrage, List<Object?> werte) =>
      raw
          .select(abfrage, werte)
          .map((r) => r['pfad'] as String?)
          .whereType<String>()
          .toList();

  /// Wann die naechste geplante Nachricht faellig wird, oder null.
  DateTime? naechsteGeplante() {
    final r = db.raw.select(
        'SELECT MIN(faellig) v FROM messages WHERE faellig > ? AND status = ?',
        [
          DateTime.now().toUtc().millisecondsSinceEpoch,
          MessageStatus.sending.index,
        ]);
    final v = r.isEmpty ? null : r.first['v'] as int?;
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
  }

  /// Wann die naechste Nachricht ablaeuft — damit der Aufrufer einen Wecker
  /// stellen kann, statt im Sekundentakt nachzusehen.
  DateTime? naechsterVerfall() {
    final r = db.raw.select(
        'SELECT MIN(expires_at) v FROM messages WHERE expires_at IS NOT NULL');
    final v = r.isEmpty ? null : r.first['v'] as int?;
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
  }

  // ══════════════════════════════════════════════════════════ Einstellungen

  static const _praefix = 'pref_';

  AppPreferences ladeEinstellungen() {
    String? lies(String k) => db.meta('$_praefix$k');
    final dauer = int.tryParse(lies('lifetime_seconds') ?? '');
    return AppPreferences(
      thema: (lies('thema') ?? '').isEmpty ? 'nocturne' : lies('thema')!,
      themaWandern: int.tryParse(lies('thema_wandern') ?? '') ?? 0,
      sprache: (lies('sprache') ?? '').isEmpty ? null : lies('sprache'),
      entschluesseln: lies('entschluesseln') != '0',
      readReceipts: lies('read_receipts') != '0',
      messageLifetime:
          (dauer == null || dauer <= 0) ? null : Duration(seconds: dauer),
      blockScreenshots: lies('block_screenshots') != '0',
      // Ab Werk AUS. Ein Messenger, der beim ersten Start nichts zustellt,
      // waere kaputt und nicht vorsichtig.
      nurNahbereich: lies('nur_nahbereich') == '1',
      // Ebenfalls ab Werk aus, aber aus einem anderen Grund: Funk kostet Akku
      // und zeigt Anwesenheit. Das schaltet man ein, wenn man es will.
      naheAn: lies('nahe_an') == '1',
      // `!= '0'` und nicht `== '1'`: dieser ist ab Werk AN, ein fehlender
      // Eintrag muss also true ergeben. Bei den beiden darueber ist es
      // umgekehrt, und die Schreibweise ist der einzige Unterschied.
      autoScroll: lies('auto_scroll') != '0',
      tippAnzeige: lies('tipp_anzeige') == '1',
      panikFach: (lies('panik_fach') ?? '').isEmpty ? null : lies('panik_fach'),
    );
  }

  void speichereEinstellungen(AppPreferences p) {
    db.transaction((raw) {
      void setze(String k, String v) => raw.execute(
          'INSERT INTO meta (key, value) VALUES (?,?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          ['$_praefix$k', v]);
      setze('thema', p.thema);
      setze('thema_wandern', '${p.themaWandern}');
      setze('sprache', p.sprache ?? '');
      setze('entschluesseln', p.entschluesseln ? '1' : '0');
      setze('read_receipts', p.readReceipts ? '1' : '0');
      setze('lifetime_seconds', '${p.messageLifetime?.inSeconds ?? 0}');
      setze('block_screenshots', p.blockScreenshots ? '1' : '0');
      setze('nur_nahbereich', p.nurNahbereich ? '1' : '0');
      setze('nahe_an', p.naheAn ? '1' : '0');
      setze('auto_scroll', p.autoScroll ? '1' : '0');
      setze('tipp_anzeige', p.tippAnzeige ? '1' : '0');
      setze('panik_fach', p.panikFach ?? '');
    });
  }

  /// [ueberNaehe] wird nur geschrieben, wenn es dasteht.
  ///
  /// Das COALESCE ist kein Zierrat: den Weg kennt genau EIN Aufrufer, naemlich
  /// der, der gerade gesendet hat. Alle anderen — die eintreffenden
  /// Quittungen etwa — setzen nur den Status. Stuende hier ein schlichtes
  /// `ueber_naehe = ?` mit einem Standardwert, loeschte die erste eintreffende
  /// Zustellbestaetigung das Zeichen wieder, das die Nachricht sich verdient
  /// hat. Derselbe Kniff wie bei `pfad` in [setzeAnhangZustand].
  void setzeStatus(String chatId, String senderId, String messageId,
      MessageStatus status, {bool? ueberNaehe}) {
    // NUR VORWAERTS, NIE ZURUECK.
    //
    // Die Zustaende sind eine Reihenfolge: sending -> sent -> delivered ->
    // read. Geschrieben wurde bisher bedingungslos, und das laesst ein
    // Haekchen zurueckfallen:
    //
    //   Die Nachricht ist raus, die Gegenseite hat sie gelesen (read). Danach
    //   laeuft der Nachversand noch einmal ueber dieselbe Nachricht — etwa
    //   weil sie ueber beide Wege ging — und setzt "sent". Aus zwei Haken wird
    //   wieder einer. Der Nutzer sieht eine gelesene Nachricht ungelesen
    //   werden und hat keine Erklaerung dafuer.
    //
    // `failed` steht in der Reihenfolge zwar hinten, ist aber kein
    // Fortschritt, sondern ein Abbruch — und umgekehrt darf ein spaeter doch
    // gelungener Versand ein `failed` wieder ueberschreiben. Beide Richtungen
    // sind hier also erlaubt; die Sperre gilt allein zwischen den vier
    // Fortschrittsstufen.
    //
    // IN DERSELBEN TRANSAKTION GELESEN UND GESCHRIEBEN. Zwei getrennte
    // Zugriffe waeren ein Wettlauf: zwischen Lesen und Schreiben koennte ein
    // Lesehaken eintreffen, den der zweite Zugriff dann ueberschriebe — genau
    // der Fehler, der hier behoben wird, nur seltener und schwerer zu finden.
    db.transaction((raw) {
      final vorher = raw.select(
          'SELECT status FROM messages WHERE chat_id=? AND sender_id=? AND id=?',
          [chatId, senderId, messageId]);
      if (vorher.isEmpty) return;
      final alt = MessageStatus.values[vorher.first['status'] as int];

      final beideFortschritt =
          alt != MessageStatus.failed && status != MessageStatus.failed;
      final neu = beideFortschritt && status.index < alt.index ? alt : status;

      raw.execute(
          'UPDATE messages SET status = ?, '
          'ueber_naehe = COALESCE(?, ueber_naehe) '
          'WHERE chat_id=? AND sender_id=? AND id=?',
          [
            neu.index,
            ueberNaehe == null ? null : (ueberNaehe ? 1 : 0),
            chatId,
            senderId,
            messageId
          ]);
    });
  }

  /// Haelt fest, dass dieser Umschlag schon einmal beim Relay war.
  ///
  /// EIGENE METHODE UND KEIN WEITERES FELD AN [setzeStatus]: der Vermerk faellt
  /// genau dann an, wenn der Status sich NICHT aendert — die Nachricht bleibt
  /// auf "sending" liegen, nur ihr Weg hat sich verengt. Ihn an eine
  /// Statusaenderung zu haengen hiesse, ihn im wichtigsten Fall nicht zu
  /// schreiben.
  ///
  /// NUR VORWAERTS. Die Spalte faellt nie auf 0 zurueck; was einmal beim Relay
  /// war, war es.
  void merkeBeimRelay(String chatId, String senderId, String messageId) {
    db.transaction((raw) => raw.execute(
        'UPDATE messages SET schon_beim_relay = 1 '
        'WHERE chat_id=? AND sender_id=? AND id=?',
        [chatId, senderId, messageId]));
  }

  /// Dasselbe fuer den anderen Weg — siehe [merkeBeimRelay].
  void merkeInDerNaehe(String chatId, String senderId, String messageId) {
    db.transaction((raw) => raw.execute(
        'UPDATE messages SET schon_in_der_naehe = 1 '
        'WHERE chat_id=? AND sender_id=? AND id=?',
        [chatId, senderId, messageId]));
  }

  /// Setzt alle eigenen Nachrichten eines Gespraechs auf gelesen, sofern sie
  /// nicht schon weiter sind.
  ///
  /// Nur vorwaerts: eine bereits gelesene Nachricht faellt nicht auf
  /// "zugestellt" zurueck, wenn eine spaete Bestaetigung eintrudelt.
  ///
  /// NUR WAS DRAUSSEN IST. Bis 25.09.2026 hiess die Bedingung `status <
  /// read` — und darunter liegt auch `sending`. Eine Lesebestaetigung fuer
  /// eine SPAETERE Nachricht setzte damit jede fruehere, die noch gar nicht
  /// verschickt war, auf "gelesen": eine geplante Nachricht (im Emulatorlauf
  /// fuer 12:57 geplant, um 12:11 schon mit zwei Haken) ebenso wie eine, die
  /// im Funkloch haengengeblieben war. Der Nachversand sucht nur nach
  /// `sending` — beide waeren nie mehr hinausgegangen.
  void markiereGelesenBis(String chatId, String senderId, int bisSeq) {
    db.transaction((raw) => raw.execute(
        'UPDATE messages SET status = ? '
        'WHERE chat_id=? AND sender_id=? AND seq <= ? AND status IN (?, ?)',
        [
          MessageStatus.read.index,
          chatId,
          senderId,
          bisSeq,
          MessageStatus.sent.index,
          MessageStatus.delivered.index,
        ]));
  }

  // ═══════════════════════════════════ Antworten, Bearbeiten, Widerrufen

  /// Eine einzelne Nachricht, oder null.
  Message? nachricht(String chatId, String senderId, String id) {
    final r = db.raw.select(
        'SELECT * FROM messages WHERE chat_id=? AND sender_id=? AND id=?',
        [chatId, senderId, id]);
    return r.isEmpty ? null : _zuNachricht(r.first);
  }

  /// Ersetzt den Text einer Textnachricht, wenn die Regeln es zulassen.
  ///
  /// DIE REGELN STEHEN IN DER ABFRAGE, nicht davor. Eine Pruefung mit
  /// anschliessendem Schreiben liesse zwischen beidem Platz; hier ist beides
  /// ein Schritt:
  ///
  /// * nur [senderId] — der Absender der BEARBEITUNG muss der der Nachricht
  ///   sein; der Aufrufer setzt dafuer die Adresse ein, von der sie kam,
  /// * nur Text, nie ein Anhang (dessen `body` ist ein Dateiname),
  /// * nicht nach einem Widerruf,
  /// * hoechstens [hoechstens] Mal,
  /// * nur neuere als die zuletzt uebernommene ([am]) — zwei Wege koennen
  ///   die Reihenfolge vertauschen,
  /// * nur innerhalb von [frist] nach dem Absenden, gerechnet in der Uhr des
  ///   ABSENDERS auf beiden Seiten; die Uhr des Empfaengers kommt nicht vor.
  ///
  /// [store] ist der Sitzungsfortschritt beim Empfang — dieselbe
  /// Transaktion, aus demselben Grund wie in [speichereEmpfangen].
  bool bearbeite(String chatId, String senderId, String id, String text,
      DateTime am,
      {required int hoechstens,
      required Duration frist,
      BitdmSignalStore? store}) {
    var ging = false;
    final t = am.toUtc().millisecondsSinceEpoch;
    db.transaction((raw) {
      raw.execute(
          'UPDATE messages SET body = ?, bearbeitet_zahl = bearbeitet_zahl + 1,'
          ' bearbeitet_at = ? '
          'WHERE chat_id = ? AND sender_id = ? AND id = ? AND kind = ? '
          '  AND widerrufen = 0 AND bearbeitet_zahl < ? '
          '  AND (bearbeitet_at IS NULL OR bearbeitet_at < ?) '
          '  AND ? - sent_at BETWEEN 0 AND ?',
          [
            text,
            t,
            chatId,
            senderId,
            id,
            MessageKind.text.index,
            hoechstens,
            t,
            t,
            frist.inMilliseconds,
          ]);
      ging = raw.updatedRows > 0;
      if (store != null) SignalStoreRepository.schreibeDelta(raw, store);
    });
    store?.markClean();
    return ging;
  }

  /// "Fuer alle loeschen": leert eine Nachricht und laesst die Stelle stehen.
  ///
  /// Dieselben Regeln fuer den Absender wie bei [bearbeite]; die Frist
  /// ([frist]) gilt, gerechnet in der Uhr des Absenders. Anhang und
  /// Reaktionen fallen mit weg.
  ///
  /// Rueckgabe: die lokalen Dateien — der Aufrufer muss sie loeschen, sonst
  /// laege der "geloeschte" Anhang weiter im Speicher. Null, wenn nichts
  /// passiert ist.
  Aufgeraeumt? widerrufe(String chatId, String senderId, String id,
      DateTime am,
      {required Duration frist, BitdmSignalStore? store}) {
    Aufgeraeumt? ergebnis;
    final t = am.toUtc().millisecondsSinceEpoch;
    db.transaction((raw) {
      raw.execute(
          "UPDATE messages SET body = '', widerrufen = 1, angeheftet = NULL "
          'WHERE chat_id = ? AND sender_id = ? AND id = ? AND widerrufen = 0 '
          '  AND ? - sent_at BETWEEN 0 AND ?',
          [chatId, senderId, id, t, frist.inMilliseconds]);
      if (raw.updatedRows > 0) {
        final dateien = _anhangDateien(
            raw,
            'SELECT pfad FROM anhaenge '
            'WHERE chat_id = ? AND sender_id = ? AND message_id = ?',
            [chatId, senderId, id]);
        raw.execute(
            'DELETE FROM anhaenge '
            'WHERE chat_id = ? AND sender_id = ? AND message_id = ?',
            [chatId, senderId, id]);
        raw.execute(
            'DELETE FROM reaktionen WHERE chat_id = ? AND message_id = ?',
            [chatId, id]);
        raw.execute(
            'DELETE FROM stimmen WHERE chat_id = ? AND umfrage_id = ?',
            [chatId, id]);
        ergebnis = Aufgeraeumt(1, dateien);
      }
      if (store != null) SignalStoreRepository.schreibeDelta(raw, store);
    });
    store?.markClean();
    return ergebnis;
  }

  /// Wie viele Nachrichten je Unterhaltung angeheftet sein duerfen — Signals
  /// Zahl.
  static const int maxAngeheftet = 3;

  /// Heftet eine Nachricht an ([an]) oder loest sie, wenn [am] neuer ist als
  /// alles, was dieser Nachricht bisher widerfahren ist.
  ///
  /// Beim vierten Anheften faellt die am laengsten angeheftete heraus, wie
  /// bei Signal — und zwar auf beiden Seiten gleich, weil beide dieselben
  /// Zeitpunkte sehen.
  bool hefteAn(String chatId, String messageId, bool an, DateTime am,
      {BitdmSignalStore? store}) {
    var ging = false;
    final t = am.toUtc().millisecondsSinceEpoch;
    db.transaction((raw) {
      raw.execute(
          'UPDATE messages SET angeheftet = ? '
          'WHERE chat_id = ? AND id = ? AND widerrufen = 0 '
          '  AND (angeheftet IS NULL OR abs(angeheftet) < ?)',
          [an ? t : -t, chatId, messageId, t]);
      ging = raw.updatedRows > 0;
      if (ging && an) {
        raw.execute(
            'UPDATE messages SET angeheftet = -angeheftet '
            'WHERE chat_id = ? AND angeheftet > 0 AND seq NOT IN ('
            '  SELECT seq FROM messages WHERE chat_id = ? AND angeheftet > 0 '
            '  ORDER BY angeheftet DESC LIMIT ?)',
            [chatId, chatId, maxAngeheftet]);
      }
      if (store != null) SignalStoreRepository.schreibeDelta(raw, store);
    });
    store?.markClean();
    return ging;
  }

  /// Setzt oder nimmt den Stern einer Nachricht. false = keine solche.
  bool setzeStern(String chatId, String messageId, bool an) {
    var ging = false;
    db.transaction((raw) {
      raw.execute(
          'UPDATE messages SET stern = ? WHERE chat_id = ? AND id = ? AND widerrufen = 0',
          [an ? DateTime.now().toUtc().millisecondsSinceEpoch : null, chatId, messageId]);
      ging = raw.updatedRows > 0;
    });
    return ging;
  }

  /// Alle markierten Nachrichten ueber alle Unterhaltungen, zuletzt markierte
  /// zuerst. Eine zurueckgenommene faellt heraus, auch wenn sie markiert war.
  List<Message> sterne({int limit = 200}) => db.raw
      .select(
          'SELECT * FROM messages WHERE stern IS NOT NULL AND widerrufen = 0 '
          'ORDER BY stern DESC LIMIT ?',
          [limit])
      .map(_zuNachricht)
      .toList();

  /// "Fuer mich loeschen": nur auf diesem Geraet, ohne Frist, fuer jede
  /// Nachricht — auch fremde. Die Gegenstelle erfaehrt nichts.
  Aufgeraeumt loescheNachricht(String chatId, String senderId, String id) {
    var dateien = <String>[];
    var weg = 0;
    db.transaction((raw) {
      dateien = _anhangDateien(
          raw,
          'SELECT pfad FROM anhaenge '
          'WHERE chat_id = ? AND sender_id = ? AND message_id = ?',
          [chatId, senderId, id]);
      raw.execute(
          'DELETE FROM anhaenge '
          'WHERE chat_id = ? AND sender_id = ? AND message_id = ?',
          [chatId, senderId, id]);
      raw.execute(
          'DELETE FROM messages WHERE chat_id = ? AND sender_id = ? AND id = ?',
          [chatId, senderId, id]);
      weg = raw.updatedRows;
      if (weg > 0) _raeumeReaktionenAuf(raw);
    });
    return Aufgeraeumt(weg, dateien);
  }

  /// Textnachrichten, die [nadel] enthalten — neueste zuerst.
  ///
  /// `instr(lower(..))` statt LIKE: LIKE deutet `%` und `_` in der Eingabe
  /// als Platzhalter, und wer nach "50%" sucht, bekaeme alles mit einer 50
  /// darin. Die Datenbank ist verschluesselt, ein Volltextindex laege
  /// ebenso verschluesselt darin — aber fuer ein Telefon voller Chats reicht
  /// das Durchgehen, und es gibt keine zweite Kopie der Texte.
  ///
  /// `lower()` von SQLite kennt nur ASCII. Deshalb wird in Dart verglichen,
  /// nachdem SQLite grob vorsortiert hat: "Übung" soll auch "übung" finden.
  List<Message> suche(String nadel, {String? chatId, int limit = 100}) {
    final n = nadel.trim().toLowerCase();
    if (n.isEmpty) return const [];
    final zeilen = db.raw.select(
        'SELECT * FROM messages WHERE kind = ? AND widerrufen = 0 '
        '${chatId == null ? '' : 'AND chat_id = ? '}'
        'ORDER BY sent_at DESC',
        [MessageKind.text.index, ?chatId]);
    final treffer = <Message>[];
    for (final r in zeilen) {
      if ((r['body'] as String).toLowerCase().contains(n)) {
        treffer.add(_zuNachricht(r));
        if (treffer.length >= limit) break;
      }
    }
    return treffer;
  }

  /// Wie [loescheNachricht], aber fuer JEDEN Absender dieser Kennung in
  /// der Unterhaltung — im Einzelchat ich oder die Gegenstelle, in einer
  /// Gruppe irgendein Mitglied. Nur oertlich, also harmlos, wenn eine
  /// Gegenstelle ihre Kennung absichtlich gleich gewaehlt hat.
  Aufgeraeumt loescheNachrichtJeder(String chatId, String id) {
    var dateien = <String>[];
    var weg = 0;
    db.transaction((raw) {
      dateien = _anhangDateien(raw,
          'SELECT pfad FROM anhaenge WHERE chat_id = ? AND message_id = ?',
          [chatId, id]);
      raw.execute('DELETE FROM anhaenge WHERE chat_id = ? AND message_id = ?',
          [chatId, id]);
      raw.execute('DELETE FROM messages WHERE chat_id = ? AND id = ?',
          [chatId, id]);
      weg = raw.updatedRows;
      if (weg > 0) _raeumeReaktionenAuf(raw);
    });
    return Aufgeraeumt(weg, dateien);
  }

  // ════════════════════════════════════════════════════════════ Reaktionen

  /// Setzt oder entfernt ([zeichen] leer) die Reaktion von [von].
  ///
  /// NUR AUF EINE NACHRICHT, DIE ES HIER GIBT. Sonst liesse sich die Tabelle
  /// mit Reaktionen auf erfundene Kennungen fuellen, die nie jemand sieht und
  /// nie jemand aufraeumt. Kommt die Reaktion vor der Nachricht an (zwei
  /// Wege), geht sie verloren — der Preis dafuer, keine Waisen zu sammeln.
  ///
  /// Neuere schlagen aeltere, nie umgekehrt ([am], Uhr des Reagierenden).
  bool setzeReaktion(String chatId, String messageId, String von,
      String zeichen, DateTime am,
      {BitdmSignalStore? store}) {
    var ging = false;
    final t = am.toUtc().millisecondsSinceEpoch;
    db.transaction((raw) {
      final gibt = raw.select(
          'SELECT 1 FROM messages WHERE chat_id = ? AND id = ? '
          'AND widerrufen = 0 LIMIT 1',
          [chatId, messageId]).isNotEmpty;
      final alt = raw.select(
          'SELECT at FROM reaktionen WHERE chat_id=? AND message_id=? AND von=?',
          [chatId, messageId, von]);
      final neuer = alt.isEmpty || (alt.first['at'] as int) < t;
      if (gibt && neuer) {
        if (zeichen.isEmpty) {
          raw.execute(
              'DELETE FROM reaktionen WHERE chat_id=? AND message_id=? AND von=?',
              [chatId, messageId, von]);
        } else {
          raw.execute(
              'INSERT INTO reaktionen (chat_id, message_id, von, zeichen, at) '
              'VALUES (?,?,?,?,?) '
              'ON CONFLICT(chat_id, message_id, von) DO UPDATE SET '
              '  zeichen = excluded.zeichen, at = excluded.at',
              [chatId, messageId, von, zeichen, t]);
        }
        ging = true;
      }
      if (store != null) SignalStoreRepository.schreibeDelta(raw, store);
    });
    store?.markClean();
    return ging;
  }

  /// Alle Reaktionen einer Unterhaltung: Nachrichtenkennung → wer → Zeichen.
  ///
  /// In EINER Abfrage, aus demselben Grund wie [anhaenge].
  Map<String, Reaktionen> reaktionen(String chatId) {
    final aus = <String, Reaktionen>{};
    for (final r in db.raw.select(
        'SELECT message_id, von, zeichen FROM reaktionen WHERE chat_id = ? '
        'ORDER BY at',
        [chatId])) {
      aus.putIfAbsent(r['message_id'] as String, () => {})[r['von'] as String] =
          r['zeichen'] as String;
    }
    return aus;
  }

  static void _raeumeReaktionenAuf(CommonDatabase raw) {
    raw.execute(
        'DELETE FROM reaktionen WHERE NOT EXISTS ('
        '  SELECT 1 FROM messages m '
        '  WHERE m.chat_id = reaktionen.chat_id AND m.id = reaktionen.message_id)');
    raw.execute(
        'DELETE FROM stimmen WHERE NOT EXISTS ('
        '  SELECT 1 FROM messages m '
        '  WHERE m.chat_id = stimmen.chat_id AND m.id = stimmen.umfrage_id)');
  }

  // ═══════════════════════════════════════════════════════════════ Umfragen

  /// Setzt oder zieht ([auswahl] leer) die Stimme von [von] zurueck.
  ///
  /// GEPRUEFT GEGEN DIE UMFRAGE IM EIGENEN VERLAUF: gibt es sie, sind die
  /// Stellen gueltig, ist bei Einzelwahl hoechstens eine gewaehlt. Eine
  /// Stimme fuer Antwort 7 einer Umfrage mit drei Antworten waere sonst ein
  /// Balken, der ins Nichts zeigt. Neuere schlagen aeltere.
  bool setzeStimme(String chatId, String umfrageId, String von,
      List<int> auswahl, DateTime am,
      {BitdmSignalStore? store}) {
    var ging = false;
    final t = am.toUtc().millisecondsSinceEpoch;
    db.transaction((raw) {
      final zeile = raw.select(
          'SELECT body FROM messages WHERE chat_id = ? AND id = ? AND kind = ? '
          'AND widerrufen = 0 LIMIT 1',
          [chatId, umfrageId, MessageKind.umfrage.index]);
      final umfrage =
          zeile.isEmpty ? null : Umfrage.lies(zeile.first['body'] as String);
      final alt = raw.select(
          'SELECT at FROM stimmen WHERE chat_id=? AND umfrage_id=? AND von=?',
          [chatId, umfrageId, von]);
      final neuer = alt.isEmpty || (alt.first['at'] as int) < t;
      if (umfrage != null && umfrage.gueltig(auswahl) && neuer) {
        if (auswahl.isEmpty) {
          raw.execute(
              'DELETE FROM stimmen WHERE chat_id=? AND umfrage_id=? AND von=?',
              [chatId, umfrageId, von]);
        } else {
          raw.execute(
              'INSERT INTO stimmen (chat_id, umfrage_id, von, auswahl, at) '
              'VALUES (?,?,?,?,?) '
              'ON CONFLICT(chat_id, umfrage_id, von) DO UPDATE SET '
              '  auswahl = excluded.auswahl, at = excluded.at',
              [chatId, umfrageId, von, jsonEncode(auswahl), t]);
        }
        ging = true;
      }
      if (store != null) SignalStoreRepository.schreibeDelta(raw, store);
    });
    store?.markClean();
    return ging;
  }

  /// Umfrage → wer → Auswahl, fuer eine ganze Unterhaltung.
  Map<String, Stimmen> stimmen(String chatId) {
    final aus = <String, Stimmen>{};
    for (final r in db.raw.select(
        'SELECT umfrage_id, von, auswahl FROM stimmen WHERE chat_id = ?',
        [chatId])) {
      aus.putIfAbsent(r['umfrage_id'] as String, () => {})[r['von'] as String] =
          (jsonDecode(r['auswahl'] as String) as List).cast<int>();
    }
    return aus;
  }

  // ═══════════════════════════════════════════════════════════════ Ausgang

  /// Legt eine Steuernachricht in den Ausgang, BEVOR sie verschickt wird.
  ///
  /// Dieselbe Reihenfolge wie bei [speichereEigene]: erst speichern, dann
  /// senden. Rueckgabe ist die Kennung zum Austragen.
  int legeInAusgang(String chatId, Uint8List nutzlast) {
    db.raw.execute(
        'INSERT INTO ausgang (chat_id, nutzlast, angelegt) VALUES (?,?,?)',
        [chatId, nutzlast, DateTime.now().toUtc().millisecondsSinceEpoch]);
    return db.raw.lastInsertRowId;
  }

  /// Was im Ausgang liegt, aelteste zuerst.
  List<({int seq, String chatId, Uint8List nutzlast})> ausgang() => [
        for (final r in db.raw
            .select('SELECT seq, chat_id, nutzlast FROM ausgang ORDER BY seq'))
          (
            seq: r['seq'] as int,
            chatId: r['chat_id'] as String,
            nutzlast: Uint8List.fromList(r['nutzlast'] as List<int>),
          ),
      ];

  void trageAusDemAusgang(int seq) =>
      db.raw.execute('DELETE FROM ausgang WHERE seq = ?', [seq]);

  // ═══════════════════════════════════════════════════════════════ Gruppen

  Gruppe? gruppe(String id) {
    final r = db.raw.select('SELECT * FROM gruppen WHERE id = ?', [id]);
    return r.isEmpty ? null : _zuGruppe(r.first);
  }

  List<Gruppe> alleGruppen() => db.raw
      .select('SELECT * FROM gruppen ORDER BY angelegt')
      .map(_zuGruppe)
      .toList();

  void speichereGruppe(Gruppe g, {BitdmSignalStore? store}) {
    db.transaction((raw) {
      raw.execute(
          'INSERT INTO gruppen (id, name, admin, mitglieder, version, aktiv, '
          ' angeheftet, archiviert, stumm, frist, angelegt) '
          'VALUES (?,?,?,?,?,?,?,?,?,?,?) '
          // `admin` MIT: er aendert sich, wenn der alte austritt
          // (Gruppe.nachfolger). Fehlte er hier, rueckte der Nachfolger nur im
          // Speicher nach und nach dem naechsten Lesen wieder heraus.
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          ' admin = excluded.admin, '
          ' mitglieder = excluded.mitglieder, version = excluded.version, '
          ' aktiv = excluded.aktiv, angeheftet = excluded.angeheftet, '
          ' archiviert = excluded.archiviert, stumm = excluded.stumm, '
          ' frist = excluded.frist',
          [
            g.id, g.name, g.admin, jsonEncode(g.mitglieder), g.version,
            g.aktiv ? 1 : 0, g.angeheftet ? 1 : 0, g.archiviert ? 1 : 0,
            g.stumm ? 1 : 0, g.fristSekunden,
            DateTime.now().toUtc().millisecondsSinceEpoch,
          ]);
      if (store != null) SignalStoreRepository.schreibeDelta(raw, store);
    });
    store?.markClean();
  }

  static Gruppe _zuGruppe(Row r) => Gruppe(
        id: r['id'] as String,
        name: r['name'] as String,
        admin: r['admin'] as String,
        mitglieder:
            (jsonDecode(r['mitglieder'] as String) as List).cast<String>(),
        version: r['version'] as int,
        aktiv: (r['aktiv'] as int) != 0,
        angeheftet: (r['angeheftet'] as int) != 0,
        archiviert: (r['archiviert'] as int) != 0,
        stumm: (r['stumm'] as int) != 0,
        fristSekunden: r['frist'] as int?,
      );

  // ══════════════════════════════════════════════════════════ Sicherung

  /// Die Spalten, die in eine Sicherung gehen — ausdruecklich aufgezaehlt
  /// statt `SELECT *`: eine kuenftige Spalte mit etwas Ortsgebundenem (ein
  /// Pfad, ein Relay-Vermerk) soll nicht unbemerkt in fremde Dateien wandern.
  static const _kontaktSpalten = [
    'address', 'added_at', 'state', 'verified', 'zeigt_anwesenheit',
    'angeheftet', 'archiviert', 'stumm', 'frist',
  ];
  static const _nachrichtSpalten = [
    'id', 'chat_id', 'sender_id', 'body', 'kind', 'is_mine', 'sent_at',
    'status', 'expires_at', 'ueber_naehe', 'antwort_auf', 'bearbeitet_zahl',
    'bearbeitet_at', 'widerrufen', 'angeheftet',
  ];

  /// Alles, was in eine Sicherung gehoert — siehe sicherung.dart, was nicht.
  Map<String, Object?> sicherungsInhalt() {
    final jetzt = DateTime.now().toUtc().millisecondsSinceEpoch;
    List<Map<String, Object?>> zeilen(String sql, [List<Object?> w = const []]) =>
        [for (final r in db.raw.select(sql, w)) Map<String, Object?>.from(r)];
    return {
      'v': 1,
      'kontakte': zeilen('SELECT ${_kontaktSpalten.join(',')} FROM contacts'),
      // Was schon abgelaufen ist, gehoert nicht mehr dazu — es verschwaende
      // sonst hier und tauchte in der Sicherung wieder auf.
      'nachrichten': zeilen(
          'SELECT ${_nachrichtSpalten.join(',')} FROM messages '
          'WHERE expires_at IS NULL OR expires_at > ? ORDER BY seq',
          [jetzt]),
      'reaktionen': zeilen('SELECT * FROM reaktionen'),
      'stimmen': zeilen('SELECT * FROM stimmen'),
      // Die Anleitung ja, der Ort auf diesem Telefon nein.
      'anhaenge': zeilen(
          'SELECT chat_id, sender_id, message_id, name, groesse, rezept '
          'FROM anhaenge'),
    };
  }

  /// Spielt eine Sicherung ein, OHNE Vorhandenes zu ueberschreiben.
  ///
  /// `INSERT OR IGNORE` ueberall: was schon hier ist, ist neuer als die
  /// Sicherung oder dasselbe. Rueckgabe: wie viele Nachrichten dazukamen.
  int spieleSicherungEin(Map<String, Object?> inhalt) {
    var neu = 0;
    List<Map<String, Object?>> liste(String k) =>
        ((inhalt[k] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, Object?>())
            .toList();
    void einfuegen(CommonDatabase raw, String tabelle, List<String> spalten,
        Map<String, Object?> z) {
      raw.execute(
          'INSERT OR IGNORE INTO $tabelle (${spalten.join(',')}) '
          'VALUES (${List.filled(spalten.length, '?').join(',')})',
          [for (final s in spalten) z[s]]);
    }

    db.transaction((raw) {
      for (final z in liste('kontakte')) {
        einfuegen(raw, 'contacts', _kontaktSpalten, z);
      }
      for (final z in liste('nachrichten')) {
        // EINE EIGENE, DIE NIE HINAUSGING, BLEIBT LIEGEN — als gescheitert,
        // nicht als unterwegs. Sonst schickte ein frisch eingerichtetes
        // Telefon Nachrichten los, die jemand vor Wochen getippt und
        // vielleicht laengst verworfen hat.
        final zeile = Map<String, Object?>.from(z);
        if (zeile['status'] == MessageStatus.sending.index) {
          zeile['status'] = MessageStatus.failed.index;
        }
        einfuegen(raw, 'messages', _nachrichtSpalten, zeile);
        neu += raw.updatedRows;
      }
      for (final z in liste('reaktionen')) {
        einfuegen(raw, 'reaktionen',
            ['chat_id', 'message_id', 'von', 'zeichen', 'at'], z);
      }
      for (final z in liste('stimmen')) {
        einfuegen(raw, 'stimmen',
            ['chat_id', 'umfrage_id', 'von', 'auswahl', 'at'], z);
      }
      for (final z in liste('anhaenge')) {
        einfuegen(
            raw,
            'anhaenge',
            ['chat_id', 'sender_id', 'message_id', 'name', 'groesse', 'rezept',
             'zustand'],
            {...z, 'zustand': AnhangZustand.angekuendigt.index});
      }
    });
    return neu;
  }

  /// Alle eigenen Nachrichten, die noch nicht beim Relay angekommen sind.
  ///
  /// Nach einem Verbindungsabbruch oder App-Neustart die Liste dessen, was
  /// wiederholt werden muss.
  List<Message> unversandt() => db.raw
      .select('SELECT * FROM messages WHERE is_mine = 1 AND status = ? '
          // Eine zurueckgenommene Nachricht wird nicht nachgeschickt. Der
          // Widerruf selbst geht trotzdem hinaus — falls sie beim ersten
          // Versuch doch schon draussen war.
          'AND widerrufen = 0 '
          // Geplante erst, wenn ihre Zeit da ist.
          'AND (faellig IS NULL OR faellig <= ?) '
          'ORDER BY seq', [
        MessageStatus.sending.index,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ])
      .map(_zuNachricht)
      .toList();

  static Message _zuNachricht(Row r) => Message(
        id: r['id'] as String,
        chatId: r['chat_id'] as String,
        senderId: r['sender_id'] as String,
        text: r['body'] as String,
        kind: MessageKind.values[r['kind'] as int],
        isMine: (r['is_mine'] as int) != 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int,
            isUtc: true),
        status: MessageStatus.values[r['status'] as int],
        ueberNaehe: (r['ueber_naehe'] as int) != 0,
        schonInDerNaehe: (r['schon_in_der_naehe'] as int) != 0,
        schonBeimRelay: (r['schon_beim_relay'] as int) != 0,
        antwortAuf: r['antwort_auf'] as String?,
        bearbeitet: (r['bearbeitet_zahl'] as int) > 0,
        widerrufen: (r['widerrufen'] as int) != 0,
        angeheftetAm: ((r['angeheftet'] as int?) ?? 0) > 0
            ? DateTime.fromMillisecondsSinceEpoch(r['angeheftet'] as int,
                isUtc: true)
            : null,
        sternAm: r['stern'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['stern'] as int, isUtc: true),
        geplantFuer: r['faellig'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['faellig'] as int,
                isUtc: true),
      );
}
