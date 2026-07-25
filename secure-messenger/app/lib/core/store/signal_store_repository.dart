// signal_store_repository.dart — die Bruecke zwischen Arbeitsspeicher und Datei.
//
// signal_store.dart haelt den Zustand und merkt sich, was sich geaendert hat.
// Diese Datei laedt ihn beim Start und schreibt ihn zurueck — und zwar in
// genau EINER Transaktion, weil das Entschluesseln einer einzigen Nachricht
// mehrere Speicher gleichzeitig veraendert. Die Begruendung steht ausfuehrlich
// im Kopf von signal_store.dart.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../crypto/key_derivation.dart';
import '../crypto/signal_identity.dart';
import 'encrypted_database.dart';
import 'signal_store.dart';

class SignalStoreRepository {
  SignalStoreRepository(this.db);

  final EncryptedDatabase db;

  static const _metaRegistrationId = 'registration_id';

  /// Laedt den gesamten Zustand aus der Datei.
  ///
  /// Bewusst vollstaendig statt bei Bedarf. Nachladen waehrend einer laufenden
  /// Transaktion waere schwer richtig zu bekommen, und die Datenmengen sind
  /// klein: eine Sitzung liegt im Bereich weniger Kilobyte, Prekeys darunter.
  /// Erst bei einigen tausend Kontakten waere das neu zu bewerten — dann waere
  /// aber ohnehin ein anderer Zuschnitt faellig.
  SignalStoreState loadState() {
    final raw = db.raw;
    final state = SignalStoreState();

    for (final row in raw.select('SELECT address, key FROM identities')) {
      state.identities[row['address'] as String] = _blob(row['key']);
    }
    for (final row in raw.select('SELECT id, record FROM pre_keys')) {
      state.preKeys[row['id'] as int] = _blob(row['record']);
    }
    for (final row in raw.select('SELECT id, record FROM signed_pre_keys')) {
      state.signedPreKeys[row['id'] as int] = _blob(row['record']);
    }
    for (final row in raw.select('SELECT address, record FROM sessions')) {
      state.sessions[row['address'] as String] = _blob(row['record']);
    }
    return state;
  }

  /// Die Registrierungsnummer dieses Geraets, beim ersten Aufruf erzeugt.
  ///
  /// Sie wird NICHT aus der Seed-Phrase abgeleitet, obwohl es naheliegt. Sie
  /// bezeichnet ein GERAET, nicht eine Identitaet: wer dieselbe Seed-Phrase auf
  /// einem zweiten Telefon einspielt, soll dort eine andere Nummer bekommen.
  /// Aus der Seed abgeleitet waeren beide gleich, und der Sinn der Nummer —
  /// bemerken, dass die Gegenstelle neu aufgesetzt wurde — waere weg.
  int registrationId() {
    final vorhanden = db.meta(_metaRegistrationId);
    if (vorhanden != null) {
      final n = int.tryParse(vorhanden);
      if (n != null) return n;
      // Unbrauchbarer Eintrag: neu erzeugen statt abstuerzen.
    }
    final neu = SignalIdentityBridge.newRegistrationId();
    db.transaction((raw) {
      raw.execute(
        'INSERT INTO meta (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [_metaRegistrationId, '$neu'],
      );
    });
    return neu;
  }

  /// Baut den Speicher aus Seed-Schluesseln und dem Inhalt der Datei auf.
  BitdmSignalStore openStore(DerivedKeys derived) {
    final identity = SignalIdentityBridge.fromDerived(
      derived,
      registrationId: registrationId(),
    );
    return BitdmSignalStore(identity: identity, state: loadState());
  }

  /// Schreibt alle offenen Aenderungen — alles oder nichts.
  ///
  /// Ein aufgefuehrter Schluessel bedeutet "angefasst". Ob daraus ein Schreiben
  /// oder ein Loeschen wird, entscheidet sich hier daran, ob er im Zustand noch
  /// vorkommt. Anlegen, Aendern und Loeschen sind damit derselbe Handgriff, und
  /// es gibt keinen Weg, bei dem ein Loeschen vergessen wird.
  ///
  /// [BitdmSignalStore.markClean] wird erst NACH dem Festschreiben gerufen.
  /// Schlaegt die Transaktion fehl, bleibt der Merkzettel stehen und der
  /// naechste Versuch schreibt dasselbe noch einmal.
  void commit(BitdmSignalStore store) {
    if (store.delta.isEmpty) return;
    db.transaction((raw) => schreibeDelta(raw, store));
    store.markClean();
  }

  /// Schreibt die offenen Aenderungen INNERHALB einer bereits laufenden
  /// Transaktion — ohne [BitdmSignalStore.markClean] zu rufen.
  ///
  /// Dafuer gibt es einen bestimmten Grund. Beim Empfang einer Nachricht muss
  /// der Sitzungsfortschritt ZUSAMMEN mit der Nachricht selbst festgeschrieben
  /// werden. Der Ratchet ist beim Entschluesseln weitergerueckt; genau diese
  /// Nachricht laesst sich danach nie wieder entschluesseln. Wuerde der
  /// Fortschritt in einer eigenen Transaktion landen und das Speichern der
  /// Nachricht scheitern, waere sie fuer immer verloren — ohne dass jemand
  /// einen Fehler gesehen haette.
  ///
  /// Siehe ChatRepository.speichereEmpfangen.
  static void schreibeDelta(Database raw, BitdmSignalStore store) {
    final delta = store.delta;
    if (delta.isEmpty) return;
    final state = store.state;

    _schreibeText(raw, 'identities', 'address', 'key',
        delta.identities, state.identities);
    _schreibeZahl(raw, 'pre_keys', 'id', 'record',
        delta.preKeys, state.preKeys);
    _schreibeZahl(raw, 'signed_pre_keys', 'id', 'record',
        delta.signedPreKeys, state.signedPreKeys);
    _schreibeText(raw, 'sessions', 'address', 'record',
        delta.sessions, state.sessions);
  }

  static void _schreibeText(
    Database raw,
    String tabelle,
    String schluesselSpalte,
    String wertSpalte,
    Set<String> geaendert,
    Map<String, Uint8List> zustand,
  ) {
    if (geaendert.isEmpty) return;
    // Vorbereitete Anweisungen: bei 100 nachgefuellten Prekeys spart das 100
    // Uebersetzungen des SQL-Texts.
    final setzen = raw.prepare(
      'INSERT INTO $tabelle ($schluesselSpalte, $wertSpalte) VALUES (?, ?) '
      'ON CONFLICT($schluesselSpalte) DO UPDATE SET $wertSpalte = excluded.$wertSpalte',
    );
    final loeschen =
        raw.prepare('DELETE FROM $tabelle WHERE $schluesselSpalte = ?');
    try {
      for (final k in geaendert) {
        final wert = zustand[k];
        if (wert == null) {
          loeschen.execute([k]);
        } else {
          setzen.execute([k, wert]);
        }
      }
    } finally {
      setzen.close();
      loeschen.close();
    }
  }

  static void _schreibeZahl(
    Database raw,
    String tabelle,
    String schluesselSpalte,
    String wertSpalte,
    Set<int> geaendert,
    Map<int, Uint8List> zustand,
  ) {
    if (geaendert.isEmpty) return;
    final setzen = raw.prepare(
      'INSERT INTO $tabelle ($schluesselSpalte, $wertSpalte) VALUES (?, ?) '
      'ON CONFLICT($schluesselSpalte) DO UPDATE SET $wertSpalte = excluded.$wertSpalte',
    );
    final loeschen =
        raw.prepare('DELETE FROM $tabelle WHERE $schluesselSpalte = ?');
    try {
      for (final k in geaendert) {
        final wert = zustand[k];
        if (wert == null) {
          loeschen.execute([k]);
        } else {
          setzen.execute([k, wert]);
        }
      }
    } finally {
      setzen.close();
      loeschen.close();
    }
  }

  /// sqlite3 liefert BLOBs als Uint8List; die Umwandlung ist eine Absicherung
  /// gegen Zeilen, die anders in die Datei gekommen sind.
  static Uint8List _blob(Object? wert) {
    if (wert is Uint8List) return wert;
    if (wert is List<int>) return Uint8List.fromList(wert);
    throw StateError('Spalte enthaelt kein BLOB, sondern ${wert.runtimeType}');
  }
}
