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

import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'encrypted_database.dart';
import 'signal_store.dart';
import 'signal_store_repository.dart';

class ChatRepository {
  ChatRepository(this.db, this.signalRepo);

  final EncryptedDatabase db;
  final SignalStoreRepository signalRepo;

  // ══════════════════════════════════════════════════════════════ Kontakte

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

  void speichereKontakt(Contact c) {
    db.transaction((raw) => _schreibeKontakt(raw, c));
  }

  static void _schreibeKontakt(Database raw, Contact c) {
    raw.execute(
      'INSERT INTO contacts (address, display_name, added_at, state, verified) '
      'VALUES (?,?,?,?,?) '
      'ON CONFLICT(address) DO UPDATE SET '
      '  display_name = excluded.display_name,'
      '  state        = excluded.state,'
      '  verified     = excluded.verified',
      [
        c.id,
        c.displayName,
        c.addedAt.toUtc().millisecondsSinceEpoch,
        c.state.index,
        c.verified ? 1 : 0,
      ],
    );
  }

  /// Entfernt einen Kontakt samt Unterhaltung.
  ///
  /// Die Sitzung wird mitgeloescht: bliebe sie stehen, koennte die Gegenstelle
  /// weiter Nachrichten schicken, die sich entschluesseln liessen, obwohl der
  /// Nutzer sie entfernt hat.
  void entferneKontakt(String adresse) {
    db.transaction((raw) {
      raw.execute('DELETE FROM messages WHERE chat_id = ?', [adresse]);
      raw.execute('DELETE FROM contacts WHERE address = ?', [adresse]);
    });
  }

  static Contact _zuKontakt(Row r) => Contact(
        id: r['address'] as String,
        displayName: r['display_name'] as String?,
        addedAt: DateTime.fromMillisecondsSinceEpoch(r['added_at'] as int,
            isUtc: true),
        state: ContactState.values[r['state'] as int],
        verified: (r['verified'] as int) != 0,
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
  void speichereEigene(Message m, {Duration? lebensdauer}) {
    db.transaction((raw) =>
        _schreibeNachricht(raw, m, empfangen: false, lebensdauer: lebensdauer));
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
      {Duration? lebensdauer}) {
    var neu = false;
    db.transaction((raw) {
      neu = _schreibeNachricht(raw, m, empfangen: true, lebensdauer: lebensdauer);
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
      BitdmSignalStore store, {Duration? lebensdauer}) {
    var neu = false;
    db.transaction((raw) {
      _schreibeKontakt(raw, c);
      neu = _schreibeNachricht(raw, m, empfangen: true, lebensdauer: lebensdauer);
      SignalStoreRepository.schreibeDelta(raw, store);
    });
    store.markClean();
    return neu;
  }

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

  static bool _schreibeNachricht(Database raw, Message m,
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
      '(id, chat_id, sender_id, body, kind, is_mine, sent_at, received_at, status, expires_at) '
      'VALUES (?,?,?,?,?,?,?,?,?,?)',
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
      ],
    );
    return raw.updatedRows > 0;
  }

  /// Loescht alles, dessen Zeit abgelaufen ist. Rueckgabe: Anzahl.
  ///
  /// Billig, wenn nichts zu tun ist — der Index auf expires_at deckt nur die
  /// Zeilen ab, die ueberhaupt einen Verfall haben.
  int loescheAbgelaufene() {
    var weg = 0;
    db.transaction((raw) {
      raw.execute('DELETE FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?',
          [DateTime.now().toUtc().millisecondsSinceEpoch]);
      weg = raw.updatedRows;
    });
    return weg;
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
      readReceipts: lies('read_receipts') != '0',
      messageLifetime:
          (dauer == null || dauer <= 0) ? null : Duration(seconds: dauer),
      blockScreenshots: lies('block_screenshots') != '0',
    );
  }

  void speichereEinstellungen(AppPreferences p) {
    db.transaction((raw) {
      void setze(String k, String v) => raw.execute(
          'INSERT INTO meta (key, value) VALUES (?,?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          ['$_praefix$k', v]);
      setze('read_receipts', p.readReceipts ? '1' : '0');
      setze('lifetime_seconds', '${p.messageLifetime?.inSeconds ?? 0}');
      setze('block_screenshots', p.blockScreenshots ? '1' : '0');
    });
  }

  void setzeStatus(String chatId, String senderId, String messageId,
      MessageStatus status) {
    db.transaction((raw) => raw.execute(
        'UPDATE messages SET status = ? WHERE chat_id=? AND sender_id=? AND id=?',
        [status.index, chatId, senderId, messageId]));
  }

  /// Setzt alle eigenen Nachrichten eines Gespraechs auf gelesen, sofern sie
  /// nicht schon weiter sind.
  ///
  /// Nur vorwaerts: eine bereits gelesene Nachricht faellt nicht auf
  /// "zugestellt" zurueck, wenn eine spaete Bestaetigung eintrudelt.
  void markiereGelesenBis(String chatId, String senderId, int bisSeq) {
    db.transaction((raw) => raw.execute(
        'UPDATE messages SET status = ? '
        'WHERE chat_id=? AND sender_id=? AND seq <= ? AND status < ?',
        [
          MessageStatus.read.index,
          chatId,
          senderId,
          bisSeq,
          MessageStatus.read.index
        ]));
  }

  /// Alle eigenen Nachrichten, die noch nicht beim Relay angekommen sind.
  ///
  /// Nach einem Verbindungsabbruch oder App-Neustart die Liste dessen, was
  /// wiederholt werden muss.
  List<Message> unversandt() => db.raw
      .select('SELECT * FROM messages WHERE is_mine = 1 AND status = ? '
          'ORDER BY seq', [MessageStatus.sending.index])
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
      );
}
