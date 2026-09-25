// Der Zweig fuer den Browser. Warum es ihn gibt: browser_zugang.dart.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../lock/fach_ablage.dart';

/// Die Fachdatei der App-Sperre in localStorage.
///
/// WAS DARIN STEHT, IST NICHT GEHEIM — genau wie die Datei auf der Platte:
/// die Nutzlast jedes Fachs ist mit einem Schluessel aus dem Passwort
/// (Argon2id) verschluesselt, der Rest sind Einstellungen. localStorage ist
/// fuer jedes Skript derselben Herkunft lesbar, und das ist hier in Ordnung,
/// weil es fuer die Datei auf der Platte genauso gilt: wer sie hat, hat
/// Rauschen, solange er das Passwort nicht hat.
///
/// localStorage und nicht IndexedDB: synchron, und `setItem` ersetzt den
/// Wert als Ganzes — die Zusage "kein halber Inhalt" haelt der Browser
/// selbst, ohne Nebendatei.
FachAblage browserFachAblage(String schluessel) => _LokalAblage(schluessel);

class _LokalAblage implements FachAblage {
  _LokalAblage(this._schluessel);

  final String _schluessel;

  web.Storage get _speicher => web.window.localStorage;

  @override
  bool existiert() => _speicher.getItem(_schluessel) != null;

  @override
  Future<String> lies() async {
    final wert = _speicher.getItem(_schluessel);
    if (wert == null) throw StateError('keine Fachdatei im Browser');
    return wert;
  }

  @override
  Future<void> schreibe(String inhalt) async =>
      _speicher.setItem(_schluessel, inhalt);

  @override
  void loesche() => _speicher.removeItem(_schluessel);
}

/// Bietet [daten] als Download unter [name] an.
///
/// Der Browser entscheidet, wohin — meist ins Download-Verzeichnis, ohne
/// Rueckfrage. Die Sicherung ist mit einem Schluessel aus den zwoelf Woertern
/// verschluesselt (store/sicherung.dart); was hier hinausgeht, ist also
/// dasselbe, was die App auf dem Telefon in einen gewaehlten Ordner legt.
Future<void> browserDownload(Uint8List daten, String name) async {
  final blob = web.Blob(
    [daten.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final adresse = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = adresse
    ..download = name
    ..style.display = 'none';
  web.document.body!.append(a);
  a.click();
  a.remove();
  // Nicht sofort freigeben: manche Browser lesen den Blob erst nach dem
  // Klick. Eine Minute ist grosszuegig und haelt nichts Geheimes fest — der
  // Inhalt ist verschluesselt.
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(adresse));
}

/// Laesst eine Datei waehlen und liefert ihren Inhalt, oder null bei Abbruch.
Future<Uint8List?> browserDateiLesen() async {
  final wahl = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = '.bitdm'
    ..style.display = 'none';
  web.document.body!.append(wahl);
  final fertig = Completer<Uint8List?>();
  wahl.onchange = ((web.Event _) {
    final datei = wahl.files?.item(0);
    if (datei == null) {
      if (!fertig.isCompleted) fertig.complete(null);
      return;
    }
    datei.arrayBuffer().toDart.then(
      (puffer) {
        if (!fertig.isCompleted) fertig.complete(puffer.toDart.asUint8List());
      },
      onError: (Object e) {
        if (!fertig.isCompleted) fertig.completeError(e);
      },
    );
  }).toJS;
  // "cancel" kennen Chrome und Firefox seit 2023; ein Browser ohne es laesst
  // den Future offen — das haelt nichts fest ausser diesem einen Aufruf.
  wahl.oncancel = ((web.Event _) {
    if (!fertig.isCompleted) fertig.complete(null);
  }).toJS;
  wahl.click();
  try {
    return await fertig.future;
  } finally {
    wahl.remove();
  }
}
