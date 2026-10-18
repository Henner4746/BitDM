// sitzungsdatensatz.dart — ein Feld aus libsignals Sitzungsdatensatz lesen.
//
// WOZU: der Sitzungsnachweis (docs/GERAETEABMELDUNG.md §12.5 b) bindet die
// erste Nutzlast einer neuen Sitzung an deren Basisschluessel. Den kennt der
// Absender, bevor er verschluesselt — er steht im gespeicherten Datensatz —,
// aber die Anbindung (libsignal 8.0.0) reicht ihn nicht heraus. Also wird er
// hier gelesen.
//
// DAS FORMAT ist libsignals `storage.proto`, seit Jahren unveraendert:
//
//   RecordStructure   { SessionStructure current_session = 1; ... }
//   SessionStructure  { ... PendingPreKey pending_pre_key = 9; ... }
//   PendingPreKey     { uint32 pre_key_id = 1; bytes base_key = 2; ... }
//
// `pending_pre_key` steht genau so lange da, wie libsignal fuer diese Sitzung
// noch PreKey-Nachrichten schickt — bis die Gegenstelle zum ersten Mal
// geantwortet hat. Ob die Nummern stimmen, prueft
// test/crypto/sitzungsdatensatz_test.dart gegen `PreKeySignalMessage.baseKey()`
// einer echten Nachricht. Aendert libsignal das Format, wird dieser Test rot,
// nicht still die Sicherheit schwaecher.
//
// NIE EIN WURF: ein unlesbarer Datensatz heisst "kein offener Basisschluessel".

import 'dart:typed_data';

/// Der Basisschluessel (33 Byte, mit Typbyte) der aktuellen Sitzung, solange
/// sie noch unbestaetigt ist — sonst null.
Uint8List? offenerBasisschluessel(List<int> datensatz) {
  final sitzung = _feld(datensatz, 1);
  if (sitzung == null) return null;
  final offen = _feld(sitzung, 9);
  if (offen == null) return null;
  final basis = _feld(offen, 2);
  if (basis == null || basis.isEmpty) return null;
  return Uint8List.fromList(basis);
}

/// Das erste laengenbegrenzte Feld [nummer] einer Protobuf-Nachricht.
List<int>? _feld(List<int> b, int nummer) {
  var i = 0;
  while (i < b.length) {
    final (schluessel, n1) = _varint(b, i);
    if (n1 < 0) return null;
    i = n1;
    final art = schluessel & 7;
    final feld = schluessel >> 3;
    switch (art) {
      case 0:
        final (_, n2) = _varint(b, i);
        if (n2 < 0) return null;
        i = n2;
      case 1:
        i += 8;
      case 5:
        i += 4;
      case 2:
        final (laenge, n2) = _varint(b, i);
        if (n2 < 0 || laenge < 0 || n2 + laenge > b.length) return null;
        if (feld == nummer) return b.sublist(n2, n2 + laenge);
        i = n2 + laenge;
      default:
        return null;
    }
  }
  return null;
}

/// (Wert, naechste Stelle) — oder (0, -1), wenn die Zahl abbricht oder fuer
/// diesen Zweck unsinnig gross ist.
(int, int) _varint(List<int> b, int i) {
  var wert = 0;
  for (var stelle = 0; stelle < 35; stelle += 7) {
    if (i >= b.length) return (0, -1);
    final c = b[i++];
    wert |= (c & 0x7f) << stelle;
    if (c & 0x80 == 0) return (wert, i);
  }
  return (0, -1);
}
