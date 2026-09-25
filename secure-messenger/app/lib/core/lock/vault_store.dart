// vault_store.dart — die Entropie, verteilt auf Schluesselfaecher.
//
// WAS SICH GEGENUEBER app_lock.dart AENDERT
// Bisher lag die Entropie direkt im Schluesselspeicher des Geraets, entweder
// mit oder ohne Anmeldezwang. Das traegt genau einen Faktor. Sobald ein
// zweiter dazukommt, geht es nicht mehr: die Entropie laege an zwei Stellen,
// und die schwaechere entscheidet. Ein Hardware-Stick waere wertlos, wenn
// dieselbe Entropie daneben ohne ihn zu haben ist.
//
// Hier liegt sie deshalb NUR verschluesselt, in je einem Fach pro Faktor. Kein
// Fach oeffnet ein anderes, und es gibt kein Hauptpasswort. Wer keinen Faktor
// hat, hat kein Geheimnis, sondern Rauschen.
//
// DER UEBERGANG IST DIE HEIKLE STELLE
// Solange es kein Fach gibt, bleibt alles wie bisher — die Entropie liegt im
// Schluesselspeicher, die App oeffnet ohne Rueckfrage. Erst mit dem ERSTEN
// Fach wandert sie dorthin und wird aus dem Schluesselspeicher entfernt. Mit
// dem LETZTEN Fach wandert sie zurueck. Beide Wege sind so gebaut, dass ein
// Absturz mittendrin die Entropie nicht verliert: erst schreiben, dann
// loeschen. Ein Rest an der alten Stelle ist reparabel, ein fehlender nicht.
//
// WARUM read() SPERRT STATT ZU FRAGEN
// Ein Schluesselspeicher kann keine Oberflaeche zeigen — er weiss nicht, ob
// gerade ein Stick anliegt oder welche PIN der Nutzer eingeben will. Deshalb
// wirft [read] eine [LockedException], solange nicht entsperrt wurde, und die
// Oberflaeche entscheidet, mit welchem Faktor sie es versucht. Genau diesen
// Ablauf gibt es schon: die App kennt den Zustand "es gibt eine Identitaet,
// sie ist nur nicht zu haben".

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../app_lock.dart';
import '../errors.dart';
import '../secret_store.dart';
import 'fach_ablage.dart';
import 'key_vault.dart';
import 'keystore_factor.dart';
import 'unlock_factor.dart';

/// Jemand hat das PANIK-PASSWORT eingegeben. Der Aufrufer loescht jetzt
/// alles — ohne Rueckfrage, das ist der ganze Sinn.
class PanikAusgeloestException implements Exception {
  const PanikAusgeloestException();
  @override
  String toString() => 'PanikAusgeloestException';
}

class VaultSecretStore implements SecretStore {
  /// Was ein PANIK-FACH statt einer Identitaet enthaelt.
  ///
  /// SECHZEHN BYTE, wie eine echte Entropie, damit das Fach nach aussen genau
  /// so gross und genau so gebaut ist wie ein gewoehnliches Passwort-Fach.
  /// Wer die Fachdatei untersucht, sieht zwei Passwort-Faecher und kann nicht
  /// sagen, welches wohin fuehrt — so wie bei SimpleX' Selbstzerstoerungs-
  /// Passwort.
  ///
  /// Eine echte Entropie trifft diese Bytes mit Wahrscheinlichkeit 2^-128.
  static final Uint8List panikMarke =
      Uint8List.fromList(utf8.encode('BITDM-PANIK-v1!!'));

  static bool istPanik(Uint8List b) {
    if (b.length != panikMarke.length) return false;
    var unterschied = 0;
    for (var i = 0; i < b.length; i++) {
      unterschied |= b[i] ^ panikMarke[i];
    }
    return unterschied == 0;
  }

  /// [datei] ODER [ablage]: die Datei ist der Normalfall auf dem Geraet (und
  /// in allen Tests), die Ablage der Weg fuer den Browser, der keine Dateien
  /// kennt (core/browser/browser_zugang_web.dart).
  VaultSecretStore({
    File? datei,
    FachAblage? ablage,
    required this.basis,
    required this.jetzt,
  })  : assert(datei != null || ablage != null,
            'VaultSecretStore braucht eine Datei oder eine Ablage'),
        ablage = ablage ?? DateiFachAblage(datei!);

  /// Die Fachdatei. Liegt UNVERSCHLUESSELT neben der Datenbank — sie muss
  /// lesbar sein, bevor irgendetwas aufgeschlossen ist. Geheim ist nur die
  /// Nutzlast in den Faechern.
  final FachAblage ablage;

  /// Wo die Entropie liegt, solange es kein einziges Fach gibt.
  final SecretStore basis;

  /// Injizierbar, damit Tests keine echte Uhr brauchen.
  final int Function() jetzt;

  KeyVault? _faecher;
  Uint8List? _offen;

  /// Ob die Faecher schon eingelesen wurden.
  bool _geladen = false;

  /// Liest die Fachdatei, einmal je Sitzung.
  ///
  /// Gibt sie AUCH DANN zurueck, wenn kein einziges Fach darin steht. Sie
  /// enthaelt naemlich mehr als Faecher: die Sperrfrist und den Empfangstakt.
  /// Eine leere Datei als "keine Datei" zu behandeln hiesse, diese
  /// Einstellungen zu verlieren, sobald der letzte Faktor entfernt wird — und
  /// zwar still. Ob es eine SPERRE gibt, sagt [hatFaecher].
  Future<KeyVault?> faecher() async {
    if (_geladen) return _faecher;
    _geladen = true;
    if (!ablage.existiert()) return _faecher = null;
    try {
      return _faecher = KeyVault.fromJsonString(await ablage.lies());
    } on VaultFormatException {
      rethrow;
    } catch (e) {
      throw VaultFormatException('Fachdatei nicht lesbar (${e.runtimeType})');
    }
  }

  /// Ob die App ueberhaupt gesperrt ist.
  ///
  /// Nicht dasselbe wie "es gibt eine Fachdatei": die kann auch nur
  /// Einstellungen enthalten.
  Future<bool> hatFaecher() async => (await faecher())?.isEmpty == false;

  /// Ob gerade offen. Nach einem Neustart wieder false.
  bool get istOffen => _offen != null;

  @override
  Future<Uint8List?> read() async {
    final v = await faecher();
    if (v == null || v.isEmpty) return basis.read();
    final o = _offen;
    if (o == null) throw const LockedException();
    return o;
  }

  @override
  Future<void> write(Uint8List entropy) async {
    if (entropy.length != 16) {
      throw ArgumentError('Entropie muss 16 Bytes haben, hat ${entropy.length}');
    }
    final v = await faecher();
    if (v != null && !v.isEmpty) {
      // Neue Entropie bei bestehenden Faechern hiesse: JEDES Fach neu
      // versiegeln, also jeden Faktor vorlegen. Das passiert im Ablauf der App
      // nie — eine Identitaet entsteht genau einmal, vor der ersten Sperre.
      // Lieber ein klarer Fehler als ein Tresor, in dem die Haelfte der
      // Faecher auf eine alte Identitaet zeigt.
      throw StateError('Es gibt bereits Faecher — erst alle Faktoren '
          'entfernen, dann eine neue Identitaet anlegen');
    }
    await basis.write(entropy);
  }

  @override
  Future<void> delete() async {
    _offen = null;
    // ERST die Faecher, dann die Basis: bei einem Abbruch dazwischen bleibt
    // eine unlesbare Fachdatei zurueck, keine lesbare Entropie.
    try {
      ablage.loesche();
    } catch (_) {}
    _faecher = null;
    _geladen = true;
    await basis.delete();
  }

  /// Oeffnet den Tresor mit einem Faktor.
  ///
  /// Wirft weiter, was der Faktor wirft — bei einem Stick sind die Gruende
  /// sichtbar, bei einem Passwort nicht. Siehe hardware_key_factor.dart.
  Future<Uint8List> entsperreMit(UnlockFactor faktor, {String? slotId}) async {
    final v = await faecher();
    if (v == null || v.isEmpty) {
      throw StateError('Es gibt keine Faecher zu oeffnen');
    }

    final passende = slotId != null
        ? [v.slotById(slotId)].whereType<KeySlot>().toList()
        : v.slotsOf(faktor.kind);
    if (passende.isEmpty) {
      throw const UnlockFailedException();
    }

    // Mehrere Faecher derselben Sorte kommen vor: zwei Sticks, oder ein Stick
    // und ein Ersatzstick. Der Reihe nach probieren, statt den Nutzer waehlen
    // zu lassen, welchen er gerade in der Hand haelt.
    Object? letzter;
    for (final slot in passende) {
      try {
        final entropie = await faktor.unlock(slot);
        // SOFORT UND OHNE WEITERZUPROBIEREN. Die Schleife faengt Fehler, um
        // das naechste Fach zu versuchen — dieser hier darf nicht gefangen
        // werden, sonst oeffnete ein zweites Fach mit demselben Passwort am
        // Ende doch noch.
        if (istPanik(entropie)) throw const PanikAusgeloestException();
        if (entropie.length != 16) {
          throw const StorageException(
              'Das Fach enthielt etwas anderes als eine Identitaet');
        }
        _offen = entropie;
        return entropie;
      } on PanikAusgeloestException {
        rethrow;
      } catch (e) {
        letzter = e;
      }
    }
    throw letzter ?? const UnlockFailedException();
  }

  /// Legt ein PANIK-FACH an: [faktor] (ein Passwort) oeffnet dann kein
  /// Geheimnis, sondern loest das Loeschen aus.
  ///
  /// Nur bei offenem Tresor und nur, wenn es schon einen echten Faktor gibt:
  /// ein Panik-Fach allein waere eine Sperre, deren einziger Schluessel alles
  /// vernichtet.
  Future<KeySlot> fuegePanikHinzu(UnlockFactor faktor) async {
    final alt = await faecher();
    if (alt == null || alt.isEmpty) {
      throw StateError('Ein Panik-Passwort braucht eine eingerichtete Sperre');
    }
    if (!istOffen) throw const LockedException();
    final slot = await faktor.createSlot(panikMarke, createdAt: jetzt());
    await _schreibe(alt.mitSlot(slot));
    return slot;
  }

  /// Schliesst wieder ab, ohne etwas zu loeschen. Fuer die Bildschirmsperre.
  void sperre() => _offen = null;

  /// Nimmt einen Faktor auf.
  ///
  /// Beim ERSTEN Faktor wandert die Entropie aus dem Schluesselspeicher in das
  /// Fach und wird dort entfernt. Ab da ist die App gesperrt.
  Future<KeySlot> fuegeHinzu(UnlockFactor faktor) async {
    final entropie = _offen ?? await basis.read();
    if (entropie == null) {
      throw StateError('Ohne Identitaet gibt es nichts zu verschliessen');
    }

    final slot = await faktor.createSlot(entropie, createdAt: jetzt());
    final alt = await faecher();
    final neu = (alt ?? const KeyVault(slots: [])).mitSlot(slot);
    await _schreibe(neu);
    _offen = entropie;

    if (alt == null || alt.isEmpty) {
      // Der Punkt ohne Rueckweg — ab jetzt gibt es die Entropie nur noch im
      // Fach. Nach dem Schreiben, damit ein Absturz dazwischen sie nicht
      // vernichtet.
      await basis.delete();
    }
    return slot;
  }

  /// Entfernt einen Faktor.
  ///
  /// Beim LETZTEN wandert die Entropie zurueck in den Schluesselspeicher — die
  /// App ist dann wieder ungesperrt. Das verlangt, dass der Tresor offen ist:
  /// sonst waere die Sperre mit einem Fingertipp abzuschalten.
  Future<void> entferne(String slotId, {UnlockFactor? faktor}) async {
    final v = await faecher();
    if (v == null || v.isEmpty) throw StateError('Es gibt keine Faecher');
    final slot = v.slotById(slotId);
    if (slot == null) throw ArgumentError('kein Fach mit der Kennung $slotId');

    final entropie = _offen;
    if (entropie == null) {
      throw const LockedException();
    }

    if (v.slots.length == 1) {
      // ERST zurueckschreiben, dann das Fach entfernen. Andersherum waere die
      // Entropie bei einem Absturz dazwischen weg.
      await basis.write(entropie);
      // Die Datei bleibt LIEGEN, nur ohne Faecher: darin stehen auch die
      // Sperrfrist und der Empfangstakt. Sie mitzuloeschen hiesse, dem Nutzer
      // still zwei Einstellungen zurueckzusetzen, weil er einen Faktor
      // entfernt hat.
      await _schreibe(KeyVault(
        version: v.version,
        slots: const [],
        sperrfristSekunden: v.sperrfristSekunden,
        empfangsTaktMinuten: v.empfangsTaktMinuten,
      ));
    } else {
      await _schreibe(v.ohneSlot(slotId));
    }

    if (faktor is KeystoreFactor) await faktor.entferne(slotId);
  }

  /// Wie lange die App im Hintergrund offen bleiben darf.
  ///
  /// Steht in der Fachdatei und nicht in den Einstellungen: die liegen in der
  /// verschluesselten Datenbank, und die ist beim Sperren zu.
  Future<Duration> sperrfrist() async =>
      (await faecher())?.sperrfrist ?? Duration.zero;

  /// Stellt die Frist um. Verlangt einen offenen Tresor — sonst koennte jemand
  /// mit dem entsperrten Telefon die Sperre praktisch abschalten.
  Future<void> setzeSperrfrist(int sekunden) async {
    final v = await faecher();
    if (v == null) throw StateError('Es gibt keine Faecher');
    if (!istOffen) throw const LockedException();
    await _schreibe(v.mitSperrfrist(sekunden));
  }

  /// Wie oft im Hintergrund nach Nachrichten gesehen wird.
  ///
  /// Liegt aus demselben Grund hier wie die Sperrfrist: die Einstellungen
  /// stehen in der verschluesselten Datenbank, und die ist beim Sperren zu.
  /// Ohne Faecher ist die Datei leer — dann gibt es auch keine Sperre, und der
  /// Takt wird beim ersten Faktor mitgeschrieben.
  Future<void> setzeEmpfangsTakt(int minuten) async {
    final v = await faecher();
    if (v == null) {
      await _schreibe(const KeyVault(slots: []).mitEmpfangsTakt(minuten));
      return;
    }
    await _schreibe(v.mitEmpfangsTakt(minuten));
  }

  /// Benennt ein Fach um. Aendert nichts an seinem Inhalt.
  Future<void> benenneUm(String slotId, String label) async {
    final v = await faecher();
    if (v == null) throw StateError('Es gibt keine Faecher');
    final slot = v.slotById(slotId);
    if (slot == null) throw ArgumentError('kein Fach mit der Kennung $slotId');
    await _schreibe(KeyVault(
      version: v.version,
      sperrfristSekunden: v.sperrfristSekunden,
      slots: v.slots.map((s) => s.id == slotId ? s.mitLabel(label) : s).toList(),
    ));
  }

  Future<void> _schreibe(KeyVault v) async {
    // Als Ganzes ersetzen — wie, entscheidet die Ablage (auf der Platte ueber
    // eine Nebendatei und Umbenennen, siehe DateiFachAblage).
    await ablage.schreibe(v.toJsonString());
    _faecher = v;
    _geladen = true;
  }

  /// Zum Ablegen in Protokollen — ohne irgendetwas Geheimes.
  @override
  String toString() =>
      'VaultSecretStore(${_faecher?.slots.length ?? 0} Faecher, '
      '${_offen == null ? "zu" : "offen"})';
}

/// Der Name der Fachdatei neben der Datenbank.
const String vaultDateiname = 'bitdm-faecher.json';

File vaultDateiIn(String verzeichnis) =>
    File('$verzeichnis${Platform.pathSeparator}$vaultDateiname');
