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
//
// SEIT 25.09.2026 (Befunde der Sicherheitspruefung)
//   - Der PLATZHALTER: gibt es genau ein Passwort-Fach, steht daneben immer
//     ein zweites, das kein Passwort oeffnet. Vorher verrieten zwei
//     Passwort-Faecher ein Panik-Passwort (es darf nur ein echtes geben).
//     Jetzt sind es immer zwei — echtes plus Panik oder echtes plus
//     Platzhalter —, und beide sehen gleich aus. Siehe [_gleicheAttrappenAus].
//   - Die EINSTELLUNGEN tragen eine Pruefsumme, die nur mit offenem Tresor zu
//     rechnen ist (siehe KeyVault.einstellungsMac und
//     [_pflegeNachDemOeffnen]).
//   - Das LETZTE Fach zu entfernen verlangt einen frischen Nachweis
//     ([weiseNach], [FrischerNachweis]).
//   - Die offene Entropie wird beim Sperren ueberschrieben, und [read] gibt
//     eine Kopie heraus.
//   - Das Panik-Loeschen nimmt die Fachschluessel im Geraet mit.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../app_lock.dart';
import '../errors.dart';
import '../secret_store.dart';
import 'fach_ablage.dart';
import 'geraete_fach.dart';
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

/// Das letzte Fach sollte entfernt werden, ohne dass gerade ein Faktor
/// vorgelegt wurde.
///
/// Die Oberflaeche reagiert darauf, indem sie einen Faktor abfragt
/// ([VaultSecretStore.weiseNach]) und es mit dem Nachweis erneut versucht.
class NachweisNoetigException implements Exception {
  const NachweisNoetigException();
  @override
  String toString() => 'NachweisNoetigException: zum Abschalten der Sperre '
      'muss ein Faktor frisch vorgelegt werden';
}

/// Beleg, dass gerade eben ein Faktor erfolgreich vorgelegt wurde.
///
/// WARUM ES DAS BRAUCHT: mit dem letzten Fach wandert die Entropie zurueck in
/// den Schluesselspeicher, ohne Anmeldezwang — die Sperre ist dann AUS. Bis
/// 25.09.2026 genuegte dafuer ein offener Tresor. Wer das Telefon entsperrt
/// in die Hand bekam (Sperrfrist "nie", oder einfach im richtigen Moment),
/// konnte die Sperre mit zwei Tipps dauerhaft abschalten und spaeter in Ruhe
/// wiederkommen.
///
/// Nur [VaultSecretStore.weiseNach] stellt ihn aus. Er gilt fuer diesen
/// Tresor, EINMAL, hoechstens [VaultSecretStore.nachweisGueltigkeit] lang
/// und nur bis zum naechsten Sperren.
class FrischerNachweis {
  FrischerNachweis._(this._aussteller, this._epoche, this._um);

  final VaultSecretStore _aussteller;
  final int _epoche;
  final int _um;
  bool _verbraucht = false;
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

  static bool istPanik(Uint8List b) => gleichInKonstanterZeit(b, panikMarke);

  /// Wie lange ein [FrischerNachweis] gilt.
  static const Duration nachweisGueltigkeit = Duration(minutes: 2);

  /// Die Beschriftung des Platzhalters. Dieselbe, die app_state.dart dem
  /// Panik-Fach gibt — die Beschriftung darf den Unterschied nicht verraten.
  static const String attrappenLabel = 'Passwort';

  /// [datei] ODER [ablage]: die Datei ist der Normalfall auf dem Geraet (und
  /// in allen Tests), die Ablage der Weg fuer den Browser, der keine Dateien
  /// kennt (core/browser/browser_zugang_web.dart).
  ///
  /// [geraeteAufraeumen] raeumt beim Panik-Loeschen die Fachschluessel im
  /// Geraet weg. Ohne Angabe und bei einer Datei auf der Platte:
  /// [GeraeteFach.loescheAlles] im Ordner der Fachdatei — dort legt main.dart
  /// auch die Fachschluessel ab.
  VaultSecretStore({
    File? datei,
    FachAblage? ablage,
    required this.basis,
    required this.jetzt,
    this.geraeteAufraeumen,
  })  : assert(datei != null || ablage != null,
            'VaultSecretStore braucht eine Datei oder eine Ablage'),
        ablage = ablage ?? DateiFachAblage(datei!);

  /// Die Fachdatei. Liegt UNVERSCHLUESSELT neben der Datenbank — sie muss
  /// lesbar sein, bevor irgendetwas aufgeschlossen ist. Geheim ist nur die
  /// Nutzlast in den Faechern.
  final FachAblage ablage;

  /// Wo die Entropie liegt, solange es kein einziges Fach gibt.
  final SecretStore basis;

  /// Injizierbar, damit Tests keine echte Uhr brauchen. Millisekunden.
  final int Function() jetzt;

  /// Siehe Konstruktor. Null heisst: die Voreinstellung fuer die Ablage.
  final Future<void> Function()? geraeteAufraeumen;

  /// So, wie die Faecher in der Datei stehen — MIT Platzhalter.
  KeyVault? _faecher;

  /// Die offene Entropie. GEHOERT DIESEM OBJEKT ALLEIN: heraus gehen nur
  /// Kopien, damit [sperre] sie wirklich ueberschreiben kann.
  Uint8List? _offen;

  /// Zaehlt jedes Sperren mit. Ein [FrischerNachweis] aus einer frueheren
  /// Epoche gilt nicht mehr.
  int _epoche = 0;

  /// Ob die Faecher schon eingelesen wurden.
  bool _geladen = false;

  /// Liest die Fachdatei, einmal je Sitzung.
  Future<KeyVault?> _roh() async {
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

  /// Die Faecher, so wie die Oberflaeche sie sehen soll.
  ///
  /// Gibt die Datei AUCH DANN zurueck, wenn kein einziges Fach darin steht.
  /// Sie enthaelt naemlich mehr als Faecher: die Sperrfrist und den
  /// Empfangstakt. Eine leere Datei als "keine Datei" zu behandeln hiesse,
  /// diese Einstellungen zu verlieren, sobald der letzte Faktor entfernt wird
  /// — und zwar still. Ob es eine SPERRE gibt, sagt [hatFaecher].
  ///
  /// ZWEI UNTERSCHIEDE ZUR DATEI:
  ///   - Bei OFFENEM Tresor fehlt der Platzhalter. Er ist kein Faktor und
  ///     soll in den Einstellungen nicht als zweites Passwort auftauchen.
  ///     Bei zugem Tresor ist er nicht zu erkennen (das ist sein Zweck) und
  ///     steht wie jedes Passwort-Fach da — der Sperrbildschirm bietet dann
  ///     ein Passwortfeld an, genau wie beim Panik-Fach.
  ///   - Bei ZUGEM Tresor gilt "nie sperren" (-1) nicht: die Pruefsumme der
  ///     Einstellungen laesst sich erst nach dem Entsperren nachrechnen, und
  ///     bis dahin gilt der sichere Wert "sofort". Wer nach dem Entsperren
  ///     erneut liest, bekommt den geprueften Wert.
  Future<KeyVault?> faecher() async {
    final v = await _roh();
    if (v == null || v.isEmpty) return v;
    final offen = _offen;
    if (offen == null) {
      return v.sperrfristSekunden < 0 ? v.mitSperrfrist(0) : v;
    }
    final sichtbar = <KeySlot>[];
    for (final s in v.slots) {
      if (!await _istAttrappe(s, offen)) sichtbar.add(s);
    }
    return sichtbar.length == v.slots.length ? v : v.mitSlots(sichtbar);
  }

  /// Ob die App ueberhaupt gesperrt ist.
  ///
  /// Nicht dasselbe wie "es gibt eine Fachdatei": die kann auch nur
  /// Einstellungen enthalten.
  Future<bool> hatFaecher() async => (await _roh())?.isEmpty == false;

  /// Ob gerade offen. Nach einem Neustart wieder false.
  bool get istOffen => _offen != null;

  /// Gibt eine KOPIE der Entropie heraus.
  ///
  /// Bis 25.09.2026 kam hier derselbe Puffer heraus, der auch intern lag —
  /// ihn beim Sperren zu ueberschreiben haette dem Aufrufer die Daten unter
  /// den Haenden geloescht, und nicht zu ueberschreiben liess die Entropie
  /// im Speicher liegen. Kein Aufrufer verlaesst sich auf die Identitaet des
  /// Puffers (real_messenger_core.dart liest, leitet ab, vergisst).
  @override
  Future<Uint8List?> read() async {
    final v = await _roh();
    if (v == null || v.isEmpty) return basis.read();
    final o = _offen;
    if (o == null) throw const LockedException();
    return Uint8List.fromList(o);
  }

  @override
  Future<void> write(Uint8List entropy) async {
    if (entropy.length != 16) {
      throw ArgumentError('Entropie muss 16 Bytes haben, hat ${entropy.length}');
    }
    final v = await _roh();
    if (v != null && !v.isEmpty) {
      // Neue Entropie bei bestehenden Faechern hiesse: JEDES Fach neu
      // versiegeln, also jeden Faktor vorlegen. Das passiert im Ablauf der App
      // nie — eine Identitaet entsteht genau einmal, vor der ersten Sperre.
      // Lieber ein klarer Fehler als ein Tresor, in dem die Haelfte der
      // Faecher auf eine alte Identitaet zeigt.
      throw StateError('Es gibt bereits Faecher — erst alle Faktoren '
          'entfernen, dann eine neue Identitaet anlegen');
    }
    await basis.write(Uint8List.fromList(entropy));
  }

  @override
  Future<void> delete() async {
    _vergiss();
    // ERST die Faecher, dann die Basis: bei einem Abbruch dazwischen bleibt
    // eine unlesbare Fachdatei zurueck, keine lesbare Entropie.
    try {
      ablage.loesche();
    } catch (_) {}
    _faecher = null;
    _geladen = true;
    await basis.delete();
    // UND DIE FACHSCHLUESSEL IM GERAET. Ohne Faecher oeffnen sie nichts mehr
    // — aber sie verrieten, dass hier eine Sperre war. Nach dem
    // Panik-Passwort soll die App aussehen wie frisch installiert.
    final aufraeumen = geraeteAufraeumen ?? _standardAufraeumen(ablage);
    if (aufraeumen != null) {
      try {
        await aufraeumen();
      } catch (_) {
        // Loeschen darf an einem Rest nicht scheitern.
      }
    }
  }

  static Future<void> Function()? _standardAufraeumen(FachAblage a) =>
      a is DateiFachAblage
          ? () => GeraeteFach.loescheAlles(verzeichnis: a.datei.parent.path)
          : null;

  /// Oeffnet den Tresor mit einem Faktor.
  ///
  /// Wirft weiter, was der Faktor wirft — bei einem Stick sind die Gruende
  /// sichtbar, bei einem Passwort nicht. Siehe hardware_key_factor.dart.
  ///
  /// Nach dem Oeffnen pflegt der Tresor die Datei (siehe
  /// [_pflegeNachDemOeffnen]): altes Fach neu versiegeln, Pruefsumme der
  /// Einstellungen pruefen, Platzhalter ergaenzen. Wer die Einstellungen
  /// danach anzeigt, sollte [faecher] NEU lesen — erst jetzt sind sie
  /// geprueft.
  Future<Uint8List> entsperreMit(UnlockFactor faktor, {String? slotId}) async {
    final (slot, oeffnung) = await _oeffneMit(faktor, slotId: slotId);
    _vergiss();
    _offen = oeffnung.geheimnis;
    await _pflegeNachDemOeffnen(slot, oeffnung);
    return Uint8List.fromList(oeffnung.geheimnis);
  }

  /// Legt einen Faktor noch einmal vor, OHNE etwas zu veraendern, und stellt
  /// dafuer einen [FrischerNachweis] aus.
  ///
  /// Verlangt einen offenen Tresor, und das Fach muss DIESELBE Entropie
  /// enthalten. Das Panik-Passwort loest auch hier [PanikAusgeloestException]
  /// aus: wer unter Zwang "zum Abschalten bitte das Passwort" hoert, soll
  /// genau das eingeben koennen.
  Future<FrischerNachweis> weiseNach(UnlockFactor faktor,
      {String? slotId}) async {
    if (_offen == null) throw const LockedException();
    final epoche = _epoche;
    final (_, oeffnung) = await _oeffneMit(faktor, slotId: slotId);
    final offen = _offen;
    final passt = offen != null &&
        epoche == _epoche &&
        gleichInKonstanterZeit(oeffnung.geheimnis, offen);
    _ueberschreibe(oeffnung.geheimnis);
    if (!passt) throw const UnlockFailedException();
    return FrischerNachweis._(this, _epoche, jetzt());
  }

  /// Probiert die Faecher, die zu [faktor] passen.
  ///
  /// Mehrere Faecher derselben Sorte kommen vor: zwei Sticks, oder ein Stick
  /// und ein Ersatzstick. Der Reihe nach probieren, statt den Nutzer waehlen
  /// zu lassen, welchen er gerade in der Hand haelt.
  ///
  /// BEI PASSWOERTERN IMMER ALLE: auch nach einem Treffer geht es weiter.
  /// Sonst dauerte das Entsperren je nach Platz des echten Fachs ein oder
  /// zwei Argon2id-Laeufe lang, und wer die Zeit misst, erfuehre, welches
  /// der beiden Passwort-Faecher das echte ist. So kostet jedes Entsperren
  /// mit Passwort gleich viel. Bei Stick und Fingerabdruck geht das nicht —
  /// jeder weitere Versuch waere eine weitere Beruehrung oder Abfrage.
  Future<(KeySlot, FachOeffnung)> _oeffneMit(UnlockFactor faktor,
      {String? slotId}) async {
    final v = await _roh();
    if (v == null || v.isEmpty) {
      throw StateError('Es gibt keine Faecher zu oeffnen');
    }

    final passende = slotId != null
        ? [v.slotById(slotId)].whereType<KeySlot>().toList()
        : v.slotsOf(faktor.kind);
    if (passende.isEmpty) {
      throw const UnlockFailedException();
    }
    final alleProbieren = faktor.kind == UnlockFactorKind.passphrase;
    final erneuernd = faktor is ErneuerndesOeffnen
        ? faktor as ErneuerndesOeffnen
        : null;

    (KeySlot, FachOeffnung)? treffer;
    Object? letzter;
    for (final slot in passende) {
      try {
        final oeffnung = erneuernd != null
            ? await erneuernd.oeffne(slot)
            : FachOeffnung(await faktor.unlock(slot), warAktuell: false);
        // SOFORT UND OHNE WEITERZUPROBIEREN. Die Schleife faengt Fehler, um
        // das naechste Fach zu versuchen — dieser hier darf nicht gefangen
        // werden, sonst oeffnete ein zweites Fach mit demselben Passwort am
        // Ende doch noch.
        if (istPanik(oeffnung.geheimnis)) {
          if (treffer != null) _ueberschreibe(treffer.$2.geheimnis);
          throw const PanikAusgeloestException();
        }
        if (oeffnung.geheimnis.length != 16) {
          throw const StorageException(
              'Das Fach enthielt etwas anderes als eine Identitaet');
        }
        if (treffer == null) {
          treffer = (slot, oeffnung);
        } else {
          _ueberschreibe(oeffnung.geheimnis);
        }
        if (!alleProbieren) break;
      } on PanikAusgeloestException {
        rethrow;
      } catch (e) {
        letzter = e;
      }
    }
    if (treffer != null) return treffer;
    throw letzter ?? const UnlockFailedException();
  }

  /// Was nach jedem erfolgreichen Entsperren an der Datei zu tun ist.
  ///
  /// 1. DAS ALTE FACH NEU VERSIEGELN, falls der Faktor eines geliefert hat
  ///    (Fassung 1, alte Passwort-Ableitung, fehlende Stick-Angabe; siehe
  ///    [FachOeffnung.erneuert]). Derselbe Platz, dieselbe Kennung.
  /// 2. DIE PRUEFSUMME DER EINSTELLUNGEN. Stimmt sie nicht, hat jemand an
  ///    der Datei gedreht — Sperrfrist und Empfangstakt gehen auf die
  ///    Werkseinstellung (sofort / 15 Minuten). FEHLT sie, kommt es darauf
  ///    an: bei einem Fach von vor dem Update ist das normal, und die Werte
  ///    werden uebernommen (einmalig, ohne Pruefung — mehr gibt eine alte
  ///    Datei nicht her). Bei einem aktuellen Fach oder einer Datei in
  ///    Fassung 2 wurde sie entfernt, und das zaehlt wie eine falsche.
  /// 3. DER PLATZHALTER, fuer Nutzer von vor dem Update.
  ///
  /// Scheitert das Schreiben, bleibt das Entsperren trotzdem gelungen; die
  /// Pflege laeuft beim naechsten Mal erneut. Im Speicher gilt der gepflegte
  /// Stand sofort — auch die zurueckgesetzten Einstellungen.
  Future<void> _pflegeNachDemOeffnen(KeySlot slot, FachOeffnung o) async {
    final roh = await _roh();
    final e = _offen;
    if (roh == null || e == null) return;

    var v = roh;
    final erneuert = o.erneuert;
    if (erneuert != null && v.slotById(slot.id) != null) {
      v = v.mitErsetztemSlot(erneuert);
    }

    final bool zuruecksetzen;
    if (v.einstellungsMac == null) {
      zuruecksetzen = o.warAktuell || roh.version >= 2;
    } else {
      zuruecksetzen = !await v.einstellungenEcht(e);
    }
    if (zuruecksetzen) {
      v = v.mitSperrfrist(0).mitEmpfangsTakt(KeyVault.empfangsTaktAbWerk);
    }

    v = await _gleicheAttrappenAus(v, e);

    final fertig = await _mitPruefsumme(v, e);
    if (fertig.toJsonString() == roh.toJsonString()) return;
    try {
      await _schreibeFertig(fertig);
    } catch (_) {
      _faecher = fertig;
    }
  }

  /// Legt ein PANIK-FACH an: [faktor] (ein Passwort) oeffnet dann kein
  /// Geheimnis, sondern loest das Loeschen aus.
  ///
  /// Nur bei offenem Tresor und nur, wenn es schon einen echten Faktor gibt:
  /// ein Panik-Fach allein waere eine Sperre, deren einziger Schluessel alles
  /// vernichtet.
  ///
  /// DAS PANIK-FACH NIMMT DEN PLATZ DES PLATZHALTERS EIN — dieselbe Stelle in
  /// der Liste, derselbe Anlagezeitpunkt. Wer die Datei vorher und nachher
  /// nebeneinanderlegt, sieht an Reihenfolge und Zeitstempel nicht, dass sich
  /// etwas an der Bedeutung geaendert hat.
  Future<KeySlot> fuegePanikHinzu(UnlockFactor faktor) async {
    final alt = await _roh();
    if (alt == null || alt.isEmpty) {
      throw StateError('Ein Panik-Passwort braucht eine eingerichtete Sperre');
    }
    final e = _offen;
    if (e == null) throw const LockedException();
    var slot = await faktor.createSlot(panikMarke, createdAt: jetzt());

    final liste = [...alt.slots];
    var stelle = -1;
    if (slot.kind == UnlockFactorKind.passphrase) {
      for (var i = 0; i < liste.length; i++) {
        if (await _istAttrappe(liste[i], e)) {
          stelle = i;
          break;
        }
      }
    }
    if (stelle >= 0) {
      slot = slot.mitCreatedAt(liste[stelle].createdAt);
      liste[stelle] = slot;
    } else {
      liste.add(slot);
    }
    await _schreibe(await _gleicheAttrappenAus(alt.mitSlots(liste), e), e);
    return slot;
  }

  /// Schliesst wieder ab, ohne etwas zu loeschen. Fuer die Bildschirmsperre.
  ///
  /// Die Entropie wird dabei UEBERSCHRIEBEN, nicht nur losgelassen. Wann der
  /// Speicherbereiniger den Puffer wegraeumt, entscheidet er — bis dahin
  /// laege sie sonst lesbar im Arbeitsspeicher, obwohl die App "gesperrt"
  /// anzeigt.
  void sperre() => _vergiss();

  void _vergiss() {
    final o = _offen;
    if (o != null) _ueberschreibe(o);
    _offen = null;
    _epoche++;
  }

  static void _ueberschreibe(Uint8List b) => b.fillRange(0, b.length, 0);

  /// Nimmt einen Faktor auf.
  ///
  /// Beim ERSTEN Faktor wandert die Entropie aus dem Schluesselspeicher in das
  /// Fach und wird dort entfernt. Ab da ist die App gesperrt.
  Future<KeySlot> fuegeHinzu(UnlockFactor faktor) async {
    final offen = _offen;
    final entropie =
        offen != null ? Uint8List.fromList(offen) : await basis.read();
    if (entropie == null) {
      throw StateError('Ohne Identitaet gibt es nichts zu verschliessen');
    }

    final slot = await faktor.createSlot(entropie, createdAt: jetzt());
    final alt = await _roh();
    final neu = await _gleicheAttrappenAus(
        (alt ?? const KeyVault(slots: [])).mitSlot(slot), entropie);
    await _schreibe(neu, entropie);
    _offen ??= Uint8List.fromList(entropie);

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
  /// App ist dann wieder ungesperrt. Das verlangt zweierlei:
  ///   - einen offenen Tresor, sonst waere die Sperre mit einem Fingertipp
  ///     abzuschalten;
  ///   - einen [nachweis] aus [weiseNach], hoechstens
  ///     [nachweisGueltigkeit] alt. Sonst [NachweisNoetigException]. Ein
  ///     offener Tresor allein genuegt nicht: offen ist er auch, wenn jemand
  ///     anderes das entsperrte Telefon in der Hand haelt.
  ///
  /// Der Platzhalter zaehlt dabei nicht als Faktor.
  Future<void> entferne(String slotId,
      {UnlockFactor? faktor, FrischerNachweis? nachweis}) async {
    final v = await _roh();
    if (v == null || v.isEmpty) throw StateError('Es gibt keine Faecher');
    final slot = v.slotById(slotId);
    if (slot == null) throw ArgumentError('kein Fach mit der Kennung $slotId');

    final entropie = _offen;
    if (entropie == null) {
      throw const LockedException();
    }

    final stelle = v.slots.indexOf(slot);
    final rest = v.slots.where((s) => s.id != slotId).toList();
    var echteRest = 0;
    for (final s in rest) {
      if (!await _istAttrappe(s, entropie)) echteRest++;
    }

    if (echteRest == 0) {
      _loeseEin(nachweis);
      // ERST zurueckschreiben, dann das Fach entfernen. Andersherum waere die
      // Entropie bei einem Absturz dazwischen weg. Als Kopie: die Basis darf
      // den Puffer behalten, und [sperre] ueberschreibt nur den eigenen.
      await basis.write(Uint8List.fromList(entropie));
      // Die Datei bleibt LIEGEN, nur ohne Faecher (auch ohne Platzhalter):
      // darin stehen auch die Sperrfrist und der Empfangstakt. Sie
      // mitzuloeschen hiesse, dem Nutzer still zwei Einstellungen
      // zurueckzusetzen, weil er einen Faktor entfernt hat.
      await _schreibe(v.mitSlots(const []), entropie);
    } else {
      // Wird ein Passwort-Fach zum Platzhalter (etwa das Panik-Fach), rueckt
      // der neue Platzhalter an dieselbe Stelle, mit derselben Anlagezeit.
      await _schreibe(
          await _gleicheAttrappenAus(v.mitSlots(rest), entropie,
              stelle: stelle, erstelltAm: slot.createdAt),
          entropie);
    }

    if (faktor is KeystoreFactor) await faktor.entferne(slotId);
  }

  void _loeseEin(FrischerNachweis? n) {
    if (n == null ||
        !identical(n._aussteller, this) ||
        n._verbraucht ||
        n._epoche != _epoche) {
      throw const NachweisNoetigException();
    }
    final alter = jetzt() - n._um;
    if (alter < 0 || alter > nachweisGueltigkeit.inMilliseconds) {
      throw const NachweisNoetigException();
    }
    n._verbraucht = true;
  }

  /// Wie lange die App im Hintergrund offen bleiben darf.
  ///
  /// Steht in der Fachdatei und nicht in den Einstellungen: die liegen in der
  /// verschluesselten Datenbank, und die ist beim Sperren zu.
  Future<Duration> sperrfrist() async =>
      (await faecher())?.sperrfrist ?? Duration.zero;

  /// Stellt die Frist um. Verlangt einen offenen Tresor — sonst koennte jemand
  /// mit dem entsperrten Telefon die Sperre praktisch abschalten.
  ///
  /// Nur Werte, die aus der App stammen koennen (-1 oder 0 bis
  /// [KeyVault.maxSperrfristSekunden]).
  Future<void> setzeSperrfrist(int sekunden) async {
    if (!KeyVault.sperrfristGueltig(sekunden)) {
      throw ArgumentError.value(sekunden, 'sekunden', 'keine gueltige Frist');
    }
    final v = await _roh();
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
  ///
  /// MIT Faechern nur bei offenem Tresor: sonst liesse sich die Pruefsumme
  /// nicht nachrechnen, und die Einstellung ginge beim naechsten Entsperren
  /// als "manipuliert" verloren.
  Future<void> setzeEmpfangsTakt(int minuten) async {
    if (!KeyVault.empfangsTaktGueltig(minuten)) {
      throw ArgumentError.value(minuten, 'minuten', 'kein gueltiger Takt');
    }
    final v = await _roh();
    if (v == null) {
      await _schreibe(const KeyVault(slots: []).mitEmpfangsTakt(minuten));
      return;
    }
    if (!v.isEmpty && !istOffen) throw const LockedException();
    await _schreibe(v.mitEmpfangsTakt(minuten));
  }

  /// Benennt ein Fach um. Aendert nichts an seinem Inhalt — und, seit
  /// 25.09.2026, auch nichts mehr am Empfangstakt (der ging hier vorher
  /// still auf 15 Minuten zurueck).
  Future<void> benenneUm(String slotId, String label) async {
    final v = await _roh();
    if (v == null) throw StateError('Es gibt keine Faecher');
    final slot = v.slotById(slotId);
    if (slot == null) throw ArgumentError('kein Fach mit der Kennung $slotId');
    await _schreibe(v.mitSlots(
        v.slots.map((s) => s.id == slotId ? s.mitLabel(label) : s).toList()));
  }

  // ═══════════════════════════════════════════════════════════ Platzhalter

  /// DER PLATZHALTER: ein Passwort-Fach, das kein Passwort oeffnet.
  ///
  /// Gibt es genau EIN echtes Passwort-Fach (das Passwort, oder ohne Passwort
  /// das Panik-Fach), steht genau ein Platzhalter daneben; bei zwei oder
  /// mehr keiner. Damit sind es immer null oder zwei Passwort-Faecher, und
  /// wer die Datei liest, kann nicht unterscheiden:
  ///   Passwort + Platzhalter  von  Passwort + Panik-Passwort,
  ///   Fingerabdruck + Panik + Platzhalter  von  Fingerabdruck + Passwort +
  ///   Platzhalter.
  ///
  /// GLEICH GEBAUT WIE EIN PANIK-FACH: Art, Beschriftung, Argon2id-Werte,
  /// 16 Byte Nutzlast (zufaellig, mit einem zufaelligen Schluessel
  /// verschlossen, der sofort vergessen wird). Kein Passwort der Welt fuehrt
  /// zu diesem Schluessel.
  ///
  /// WIEDERERKENNEN kann ihn nur, wer die Entropie hat: seine Kennung ist
  /// HMAC(Entropie, Salz) statt Zufall. Ohne Entropie sieht sie aus wie jede
  /// andere zufaellige Kennung. Deshalb braucht es keinen Vermerk in der
  /// Datei — der waere genau der Hinweis, den es zu vermeiden gilt.
  Future<KeyVault> _gleicheAttrappenAus(KeyVault v, Uint8List geheimnis,
      {int? stelle, int? erstelltAm}) async {
    final attrappen = <String>[];
    var echte = 0;
    for (final s in v.slotsOf(UnlockFactorKind.passphrase)) {
      if (await _istAttrappe(s, geheimnis)) {
        attrappen.add(s.id);
      } else {
        echte++;
      }
    }
    final soll = echte == 1 ? 1 : 0;
    if (attrappen.length == soll) return v;
    if (attrappen.length > soll) {
      final weg = attrappen.skip(soll).toSet();
      return v.mitSlots(v.slots.where((s) => !weg.contains(s.id)).toList());
    }
    final neu = await _neueAttrappe(geheimnis, createdAt: erstelltAm);
    final liste = [...v.slots];
    liste.insert(
        stelle == null ? liste.length : stelle.clamp(0, liste.length), neu);
    return v.mitSlots(liste);
  }

  Future<KeySlot> _neueAttrappe(Uint8List geheimnis, {int? createdAt}) async {
    final kdf = Argon2Params.owasp();
    return KeyVault.sealSlot(
      secret: zufallsBytes(16),
      kek: zufallsBytes(32),
      kind: UnlockFactorKind.passphrase,
      label: attrappenLabel,
      kdf: kdf,
      createdAt: createdAt ?? jetzt(),
      id: await _attrappenKennung(geheimnis, kdf.salt),
    );
  }

  static Future<bool> _istAttrappe(KeySlot s, Uint8List geheimnis) async {
    final kdf = s.kdf;
    if (s.kind != UnlockFactorKind.passphrase || kdf == null) return false;
    return s.id == await _attrappenKennung(geheimnis, kdf.salt);
  }

  static Future<String> _attrappenKennung(
      Uint8List geheimnis, Uint8List salz) async {
    final mac = await Hmac.sha256().calculateMac(
        [...utf8.encode('bitdm-attrappe-v1|'), ...salz],
        secretKey: SecretKey(geheimnis));
    // 12 Byte, wie bei jeder anderen Kennung (base64Url von 12 Zufallsbytes).
    return base64Url.encode(mac.bytes.sublist(0, 12));
  }

  // ═════════════════════════════════════════════════════════════ Schreiben

  /// Schreibt [v] mit frischer Pruefsumme — sofern die Entropie da ist.
  ///
  /// Ohne Entropie (Tresor zu) bleibt die alte Pruefsumme stehen. Das ist
  /// richtig, solange sich die Einstellungen nicht aendern (Umbenennen), und
  /// faellt beim naechsten Entsperren auf, wenn doch.
  Future<void> _schreibe(KeyVault v, [Uint8List? geheimnis]) async =>
      _schreibeFertig(await _mitPruefsumme(v, geheimnis ?? _offen));

  Future<KeyVault> _mitPruefsumme(KeyVault v, Uint8List? geheimnis) async {
    final aktuell = v.inAktuellerFassung();
    if (aktuell.isEmpty) return aktuell.mitEinstellungsMac(null);
    if (geheimnis == null) return aktuell;
    return aktuell
        .mitEinstellungsMac(await aktuell.berechneEinstellungsMac(geheimnis));
  }

  Future<void> _schreibeFertig(KeyVault v) async {
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
