// app_state.dart — die Bruecke zwischen Oberflaeche und Kern.
//
// Die Oberflaeche hielt ihre Daten bisher in lokalen Variablen mit
// Beispieltexten. Diese Datei ersetzt sie durch das, was wirklich in der
// verschluesselten Datenbank steht — ohne dass an einer einzigen
// Gestaltungsentscheidung etwas geaendert werden muesste.
//
// Sie ist bewusst duenn. Sie haelt keinen eigenen Zustand, den der Kern nicht
// auch haette; sie merkt sich nur, was gerade angezeigt wird, und meldet
// Aenderungen. Alles, was mit Krypto, Netz oder Speichern zu tun hat, liegt im
// Kern und wird dort geprueft.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'core/anhang/anhang_empfang.dart';
import 'core/anhang/anhang_versand.dart';
import 'core/anhang/lager_client.dart';
import 'core/anhang/metadaten.dart';
import 'core/app_lock.dart';
import 'core/benachrichtigungen.dart';
import 'core/browser/browser_zugang.dart';
import 'core/dateien.dart';
import 'core/empfang.dart';
import 'core/fenster.dart';
import 'core/fido/client_pin.dart';
import 'core/fido/ctap.dart';
import 'core/fido/stick_zugang.dart';
import 'core/lock/geraete_fach.dart';
import 'core/lock/hardware_key_factor.dart';
import 'core/lock/key_vault.dart';
import 'core/lock/keystore_factor.dart';
import 'core/lock/unlock_factor.dart';
import 'core/lock/vault_store.dart';
import 'core/net/relay_client.dart' show RelayException;
import 'core/push.dart';
import 'core/messenger_core.dart';
import 'core/nah/funk.dart';
import 'core/real_messenger_core.dart';
import 'core/sprache.dart';
import 'core/verbindungstest.dart';
import 'data.dart' show shortId;

class AppState extends ChangeNotifier {
  AppState(this.core,
      {this.tresor,
      this.stickZugang,
      this.ablagen,
      this.dateien = const SystemDateiWahl()});

  /// Woher eine Datei kommt und wohin eine geht.
  ///
  /// Hereinreichbar, damit der Anhang-Weg OHNE Menschen pruefbar ist: der
  /// Auswahldialog gehoert Android, nicht BitDM. Siehe core/dateien.dart.
  final DateiWahl dateien;

  /// Woher der gesicherte Bereich des Geraets kommt, je Faktorart.
  ///
  /// Hereinreichbar, weil diese Faktoren sonst die EINZIGEN waeren, die
  /// ungeprueft bleiben — und auf sie faellt am Ende alles zurueck.
  ///
  /// GETRENNT JE ART, und das ist nicht Ordnungsliebe: die beiden Ablagen
  /// muessen verschiedene Namensraeume haben, sonst teilen sie sich den
  /// Schluessel im gesicherten Bereich. Siehe keystore_factor.dart.
  final SchluesselAblage Function(UnlockFactorKind)? ablagen;

  final _ablagenSpeicher = <UnlockFactorKind, SchluesselAblage>{};

  /// Erst beim Gebrauch gebaut: schon das Anlegen verlangt eine
  /// Bildschirmsperre, und beim Start gibt es die vielleicht noch nicht.
  SchluesselAblage ablageFuer(UnlockFactorKind art) {
    final vorhanden = _ablagenSpeicher[art];
    if (vorhanden != null) return vorhanden;
    final bauer = ablagen;
    if (bauer == null) {
      throw const LockUnavailableException(
          'Der Schluesselspeicher wurde nicht angebunden');
    }
    return _ablagenSpeicher[art] = bauer(art);
  }

  /// Was das Geraet ueber diese Anmeldeart sagt — BEVOR etwas passiert.
  ///
  /// Ohne diese Frage tippt der Nutzer und wartet dann auf einen Dialog, der
  /// nie kommt. Mit ihr steht vorher da, was fehlt: kein Fingerabdruck
  /// hinterlegt, keine Bildschirmsperre eingerichtet, keine Hardware.
  Future<GeraeteStand> geraetestand(UnlockFactorKind art) async {
    final ablage = ablageFuer(art);
    if (ablage is GeraeteFach) return ablage.verfuegbar();
    return const GeraeteStand(true, null);
  }

  KeystoreFactor _keystoreFaktor(UnlockFactorKind art) => KeystoreFactor(
        ablage: ablageFuer(art),
        kind: art,
        label: art == UnlockFactorKind.deviceCredential
            ? 'Geraetesperre'
            : 'Fingerabdruck',
      );

  /// Null in Tests — dort gibt es keinen Schluesselspeicher des Geraets.
  final VaultSecretStore? tresor;

  /// Wie ein Sicherheitsschluessel erreicht wird — per NFC oder per Kabel.
  ///
  /// Hereingereicht statt fest verdrahtet, damit der Zustand ohne Geraet
  /// pruefbar bleibt: die Plattformaufrufe fuer NFC und USB laufen in
  /// `flutter test` nicht.
  final Future<CtapTransport> Function(StickWeg)? stickZugang;

  final MessengerCore core;

  /// Wie viele Geraete auf dieser Identitaet sitzen — null, solange es
  /// niemand gefragt hat.
  ///
  /// UEBER EINE TYPPRUEFUNG UND NICHT UEBER DEN VERTRAG. `MessengerCore` ist
  /// ausdruecklich eingefroren und wird nur einvernehmlich geaendert; die
  /// Attrappe kennt gar keinen Relay und koennte diese Zahl nie kennen. Ein
  /// null von ihr ist die richtige Antwort, kein fehlendes Stueck.
  int? get geraeteZahl {
    final c = core;
    return c is RealMessengerCore ? c.geraeteZahl : null;
  }

  /// Ob der Relay dieses Geraet endgueltig abgewiesen hat (§6) — dieselbe
  /// Typpruefung und dieselbe Begruendung wie bei [geraeteZahl].
  bool get abgewiesen {
    final c = core;
    return c is RealMessengerCore && c.abgewiesen;
  }

  /// Ob [boot] durch ist. Vorher zeigt die App nichts an.
  bool bereit = false;

  bool hatIdentitaet = false;
  String meineAdresse = '';
  ConnectionState verbindung = ConnectionState.disconnected;

  List<Contact> kontakte = const [];

  /// Verlaeufe, nur fuer die Unterhaltungen, die schon geoeffnet wurden.
  /// Alles auf einmal zu laden waere bei vielen Kontakten Arbeit fuer nichts.
  final Map<String, List<Message>> verlaeufe = {};

  /// Die zwoelf Woerter — NUR direkt nach dem Anlegen einer Identitaet und
  /// solange der Nutzer sie noch nicht bestaetigt hat. Danach werden sie hier
  /// vergessen; wer sie spaeter sehen will, holt sie ueber
  /// [phraseAusEinstellungen] neu aus dem Schluesselspeicher.
  List<String>? frischePhrase;

  /// Was zuletzt schiefging, in einer Form, die man anzeigen kann.
  String? letzterFehler;

  /// Ob die App gerade auf eine Anmeldung wartet.
  ///
  /// Nicht dasselbe wie "noch nicht geladen": hier gibt es eine Identitaet,
  /// der gesicherte Bereich des Geraets ruecke sie nur noch nicht heraus.
  bool gesperrt = false;

  /// Die eingerichteten Faktoren, so wie sie in der Fachdatei stehen.
  ///
  /// Leer heisst: keine Sperre. Die App oeffnet dann ohne Rueckfrage, und die
  /// Entropie liegt im Schluesselspeicher des Geraets.
  List<KeySlot> faktoren = const [];

  final _abos = <StreamSubscription<Object?>>[];
  final _zufall = Random();

  Future<void> boot() async {
    await _ladeFaktoren();
    try {
      hatIdentitaet = await core.initialize();
      gesperrt = false;
    } on LockedException {
      // Es GIBT eine Identitaet, sie liegt nur in einem Fach, das noch
      // niemand geoeffnet hat. Das ist kein Fehler, sondern der Zweck.
      hatIdentitaet = true;
      gesperrt = true;
      bereit = true;
      notifyListeners();
      return;
    }
    if (hatIdentitaet) await _nachIdentitaet();
    bereit = true;
    notifyListeners();
  }

  Future<void> _ladeFaktoren() async {
    try {
      final v = await tresor?.faecher();
      faktoren = v?.slots ?? const [];
      // Ohne Fachdatei gilt die Werkseinstellung: alle 15 Minuten. Wer sie
      // ausschaltet, schreibt eine Datei mit 0 — die bleibt dann auch 0.
      empfangsTakt = EmpfangsTakt.vonMinuten(
          v?.empfangsTaktMinuten ?? KeyVault.empfangsTaktAbWerk);
      _nieSperren = (v?.sperrfristSekunden ?? 0) < 0;
      sperrfrist = _nieSperren ? Duration.zero : (v?.sperrfrist ?? Duration.zero);
    } catch (e) {
      // Eine unlesbare Fachdatei darf die App nicht am Starten hindern — sonst
      // kaeme man nicht einmal mehr an den Knopf, mit dem sich alles loeschen
      // laesst.
      letzterFehler = '$e';
      faktoren = const [];
    }
  }

  /// Die Faktoren OHNE das Panik-Fach — das, was die Einstellungen zeigen.
  ///
  /// Solange die App gesperrt ist, ist [AppPreferences.panikFach] nicht
  /// lesbar (es liegt in der Datenbank), und das Panik-Fach zaehlt als
  /// gewoehnliches Passwort. Genau das soll es: der Sperrbildschirm bietet
  /// dann ein Passwortfeld an, und wer es mit dem Panik-Passwort fuellt,
  /// loescht.
  List<KeySlot> get sichtbareFaktoren =>
      faktoren.where((s) => s.id != einstellungen.panikFach).toList();

  bool get hatPanikPasswort =>
      einstellungen.panikFach != null &&
      faktoren.any((s) => s.id == einstellungen.panikFach);

  /// Ob es ueberhaupt einen Faktor dieser Art gibt.
  bool hatFaktor(UnlockFactorKind art) =>
      sichtbareFaktoren.any((s) => s.kind == art);

  // ═══════════════════════════════════════════════════════════════ Entsperren

  /// Entsperrt mit dem Fingerabdruck oder dem Gesicht.
  ///
  /// Die App fragt nichts davon selbst ab und bekommt es nie zu sehen. Sie
  /// versucht nur, den Fachschluessel zu lesen; die Abfrage zeigt das System.
  Future<bool> entsperreMitBiometrie() =>
      _entsperreMit(_keystoreFaktor(UnlockFactorKind.biometric));

  /// Entsperrt mit der Sperre des Geraets — PIN, Muster oder Passwort.
  Future<bool> entsperreMitGeraetePin() =>
      _entsperreMit(_keystoreFaktor(UnlockFactorKind.deviceCredential));

  /// Entsperrt mit dem App-Passwort.
  ///
  /// [geraeteGebunden] ist hier false: dieses Fach haengt an nichts als dem
  /// Passwort. Wer die Fachdatei kopiert, kann in Ruhe auf eigener Hardware
  /// probieren — deshalb verlangt der Faktor beim Anlegen ein starkes
  /// Passwort und rechnet mit Argon2id.
  Future<bool> entsperreMitPasswort(String passwort) => _entsperreMit(
      PassphraseFactor(passwort, geraeteGebunden: false, label: 'Passwort'));

  /// Entsperrt mit einem Sicherheitsschluessel.
  ///
  /// [pin] ist die PIN DES STICKS. Null, solange sie nicht bekannt ist — der
  /// Faktor meldet dann [StickPinNoetigException], und die Oberflaeche fragt
  /// nach.
  Future<bool> entsperreMitStick({String? pin, StickWeg weg = StickWeg.usb}) =>
      _entsperreMit(HardwareKeyFactor(oeffne: _wegZum(weg), pin: pin));

  /// Der Weg zum Stick, oder ein klarer Fehler statt eines Absturzes.
  StickOeffner _wegZum(StickWeg weg) {
    final zugang = stickZugang;
    if (zugang == null) {
      throw const LockUnavailableException('kein Weg zum Stick');
    }
    return () => zugang(weg);
  }

  Future<bool> _entsperreMit(UnlockFactor faktor) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    _amFaktor = true;
    try {
      await t.entsperreMit(faktor);
    } on PanikAusgeloestException {
      // KEIN DIALOG, KEINE MELDUNG. Wer unter Zwang das Panik-Passwort
      // eingibt, soll danach eine App sehen, die aussieht wie frisch
      // installiert — und nicht eine, die "Alles geloescht" ruft.
      _amFaktor = false;
      await allesLoeschen();
      gesperrt = false;
      notifyListeners();
      return false;
    } finally {
      _amFaktor = false;
    }
    return _nachDemOeffnen();
  }

  // ══════════════════════════════════════════════ Frisch bestaetigen

  /// Ob eine folgenreiche Aenderung eine FRISCHE Anmeldung verlangt.
  ///
  /// Nur mit Faktor: ohne Sperre gibt es nichts, womit man sich ausweisen
  /// koennte, und die Oberflaeche fragt dann hoechstens nach.
  bool get brauchtFrischeAnmeldung => sichtbareFaktoren.isNotEmpty;

  /// Weist sich mit dem Fingerabdruck aus — ohne neu zu entsperren.
  Future<bool> bestaetigeMitBiometrie() =>
      _bestaetigeMit(_keystoreFaktor(UnlockFactorKind.biometric));

  Future<bool> bestaetigeMitGeraetePin() =>
      _bestaetigeMit(_keystoreFaktor(UnlockFactorKind.deviceCredential));

  Future<bool> bestaetigeMitPasswort(String passwort) => _bestaetigeMit(
      PassphraseFactor(passwort, geraeteGebunden: false, label: 'Passwort'));

  Future<bool> bestaetigeMitStick({String? pin, StickWeg weg = StickWeg.usb}) =>
      _bestaetigeMit(HardwareKeyFactor(oeffne: _wegZum(weg), pin: pin));

  /// Legt einen Faktor erneut vor, NUR als Beweis ([VaultSecretStore.weiseNach]):
  /// Kern, Datenbank und Tresor bleiben, wie sie sind. Ein offener Bildschirm
  /// allein ist kein Ausweis — wer das entsperrte Telefon in der Hand hat,
  /// soll damit nicht die Sperre, die Fernloeschung oder die zwoelf Woerter
  /// erreichen.
  ///
  /// Der Beleg wird fuer [entferneFaktor] aufgehoben: den LETZTEN Faktor
  /// nimmt der Tresor nur mit frischem Nachweis heraus.
  ///
  /// Das Panik-Passwort wirkt hier genauso wie am Sperrbildschirm.
  Future<bool> _bestaetigeMit(UnlockFactor faktor) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    _amFaktor = true;
    try {
      _nachweis = await t.weiseNach(faktor);
      return true;
    } on PanikAusgeloestException {
      _amFaktor = false;
      await allesLoeschen();
      notifyListeners();
      return false;
    } on UnlockFailedException {
      return false;
    } finally {
      _amFaktor = false;
    }
  }

  /// Der Beleg der letzten frischen Anmeldung — einmal verwendbar, nur kurz
  /// gueltig (das prueft der Tresor selbst).
  FrischerNachweis? _nachweis;

  /// Richtet das PANIK-PASSWORT ein oder ersetzt es.
  ///
  /// Wirft [PanikGleichException], wenn es ein echtes Passwort oeffnet — dann
  /// haette dasselbe Wort zwei Bedeutungen, und welche gilt, hinge an der
  /// Reihenfolge der Faecher. Wirft [WeakPassphraseException] wie beim
  /// echten Passwort: auch dieses Fach haengt an nichts als dem Passwort.
  Future<void> setzePanikPasswort(String passwort) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    final faktor =
        PassphraseFactor(passwort, geraeteGebunden: false, label: 'Passwort');
    // DIE PROBE: oeffnet dieses Wort schon ein echtes Fach? Nur gegen die
    // echten — das alte Panik-Fach loeste sonst hier schon das Loeschen aus.
    for (final s in sichtbareFaktoren
        .where((s) => s.kind == UnlockFactorKind.passphrase)) {
      try {
        await faktor.unlock(s);
        throw const PanikGleichException();
      } on UnlockFailedException {
        // Gut so: es oeffnet dieses Fach nicht.
      }
    }
    final alt = einstellungen.panikFach;
    final slot = await t.fuegePanikHinzu(faktor);
    if (alt != null && faktoren.any((s) => s.id == alt)) {
      await t.entferne(alt);
    }
    await setzeEinstellungen(einstellungen.copyWith(panikFach: slot.id));
    await _ladeFaktoren();
    notifyListeners();
  }

  Future<void> entfernePanikPasswort() async {
    final t = tresor;
    final alt = einstellungen.panikFach;
    if (t == null || alt == null) return;
    if (faktoren.any((s) => s.id == alt)) await t.entferne(alt);
    await setzeEinstellungen(einstellungen.copyWith(loeschePanikFach: true));
    await _ladeFaktoren();
    notifyListeners();
  }

  /// Zweiter Anlauf, ohne einen Faktor zu wechseln.
  Future<bool> entsperren() async {
    if (tresor != null && !(tresor!.istOffen)) {
      // Ohne offenen Tresor gaebe es nichts zu holen. Welcher Faktor es sein
      // soll, entscheidet die Oberflaeche.
      return false;
    }
    return _nachDemOeffnen();
  }

  Future<bool> _nachDemOeffnen() async {
    try {
      hatIdentitaet = await core.initialize();
      gesperrt = false;
      _weggelegtUm = null;
      if (hatIdentitaet) {
        await _nachIdentitaet();
        // DIE OFFENE UNTERHALTUNG GANZ. `_ladeVorschauen` holt je Chat nur die
        // letzte Nachricht — nach Sperren und Entsperren stand im offenen Chat
        // sonst genau eine.
        final offen = offeneUnterhaltung;
        if (offen != null) {
          try {
            await unterhaltungOeffnen(offen);
          } on MessengerException {
            // Die Unterhaltung gibt es nicht mehr — dann bleibt sie leer.
          }
        }
        await _holeEinmalNach();
      }
      notifyListeners();
      return true;
    } on LockedException {
      gesperrt = true;
      notifyListeners();
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════ Faktoren pflegen

  /// Nimmt den Fingerabdruck als Faktor auf.
  ///
  /// Wirft [LockUnavailableException], wenn das Telefon gar keine
  /// Bildschirmsperre hat — dann gibt es nichts, woran sich etwas binden
  /// liesse.
  Future<void> fuegeBiometrieHinzu() =>
      _fuegeHinzu(_keystoreFaktor(UnlockFactorKind.biometric));

  /// Nimmt die Sperre des Geraets als Faktor auf.
  Future<void> fuegeGeraetePinHinzu() =>
      _fuegeHinzu(_keystoreFaktor(UnlockFactorKind.deviceCredential));

  /// Nimmt ein App-Passwort als Faktor auf.
  ///
  /// Wirft [WeakPassphraseException], wenn das Passwort zu wenig hergibt. Das
  /// ist keine Schikane: dieses Fach haengt an nichts als dem Passwort, und
  /// wer die Fachdatei kopiert, probiert auf eigener Hardware, so lange er
  /// will. Argon2id verteuert jeden Versuch, aber gegen eine vierstellige PIN
  /// reicht das nicht.
  Future<void> fuegePasswortHinzu(String passwort) => _fuegeHinzu(
      PassphraseFactor(passwort, geraeteGebunden: false, label: 'Passwort'));

  /// Nimmt einen Sicherheitsschluessel als Faktor auf.
  ///
  /// Verlangt ZWEI Beruehrungen: einmal, um den Zugang anzulegen, einmal, um
  /// das Geheimnis dazu zu holen. Das ist kein Fehler — anders geht es nicht.
  Future<void> fuegeStickHinzu(
      {String? pin, String? name, StickWeg weg = StickWeg.usb}) async {
    await _fuegeHinzu(HardwareKeyFactor(
      oeffne: _wegZum(weg),
      pin: pin,
      label: (name == null || name.trim().isEmpty)
          ? 'Sicherheitsschluessel'
          : name.trim(),
    ));
  }

  Future<void> _fuegeHinzu(UnlockFactor faktor) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    _amFaktor = true;
    try {
      await t.fuegeHinzu(faktor);
    } finally {
      _amFaktor = false;
      // Auch nach einem Fehlschlag neu einlesen: beim Stick kann der Zugang
      // schon angelegt sein, wenn erst das Holen des Geheimnisses scheitert.
      await _ladeFaktoren();
      notifyListeners();
    }
  }

  /// Entfernt einen Faktor.
  ///
  /// Beim LETZTEN ist die App danach wieder ungesperrt, und die Entropie liegt
  /// wieder im Schluesselspeicher. Das ist Absicht: eine App, die sich nach
  /// dem Entfernen des letzten Faktors gar nicht mehr oeffnen liesse, waere
  /// eine Falle.
  /// Entfernt einen Kontakt samt Verlauf.
  ///
  /// ES GAB DAFUER KEINEN WEG IN DER OBERFLAECHE. `removeContact` steht seit
  /// jeher im Kern, gerufen hat es niemand — wer eine falsche Adresse
  /// eintippte, wurde sie nie wieder los. Bei 56 Zeichen ist das kein
  /// Randfall.
  Future<void> entferneKontakt(String id) async {
    await core.removeContact(id);
    kontakte.removeWhere((k) => k.id == id);
    verlaeufe.remove(id);
    notifyListeners();
  }

  Future<void> entferneFaktor(String slotId) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    // DER LETZTE ECHTE FAKTOR NIMMT DAS PANIK-FACH MIT. Bliebe es allein
    // stehen, waere die App gesperrt, und der einzige Schluessel, der noch
    // passt, loescht alles.
    final echte = sichtbareFaktoren;
    if (hatPanikPasswort && echte.length == 1 && echte.single.id == slotId) {
      await entfernePanikPasswort();
    }
    final slot = faktoren.where((s) => s.id == slotId).firstOrNull;
    // Beim Schluesselspeicher-Fach muss der Fachschluessel im gesicherten
    // Bereich mit weg. Beim Stick und beim Passwort gibt es nichts
    // aufzuraeumen: der Stick behaelt seinen Zugang, und das Passwort steht
    // nirgends.
    final art = slot?.kind;
    final nachweis = _nachweis;
    _nachweis = null;
    await t.entferne(
      slotId,
      faktor: (art == UnlockFactorKind.biometric ||
              art == UnlockFactorKind.deviceCredential)
          ? _keystoreFaktor(art!)
          : null,
      // Die Oberflaeche verlangt vorher `frischBestaetigt` — dessen Beleg.
      nachweis: nachweis,
    );
    await _ladeFaktoren();
    notifyListeners();
  }

  /// Wie viele Fehlversuche der Stick noch zulaesst.
  ///
  /// Zum Anzeigen, BEVOR jemand die PIN raet: nach acht Fehlversuchen sperrt
  /// sich der Stick endgueltig, und alle Zugaenge darauf sind verloren.
  Future<int?> stickVersuche({StickWeg weg = StickWeg.usb}) async {
    if (stickZugang == null) return null;
    final transport = await _wegZum(weg)();
    await transport.verbinde();
    try {
      return await ClientPin(Ctap2(transport)).verbleibendeVersuche();
    } finally {
      try {
        await transport.trenne();
      } catch (_) {}
    }
  }

  /// Traegt den Anstoss-Endpunkt erneut ein, sobald die Verbindung steht.
  ///
  /// NOETIG, WEIL DER RELAY IHN VERLIEREN KANN: bei einem Serverumzug oder
  /// einem Zuruecksetzen der Datenbank stuende dort nichts mehr, und die App
  /// wuerde nie wieder angestossen — ohne dass irgendwo ein Fehler erschiene.
  void _traegePushEndpunktEin() {
    final e = pushEndpunkt;
    if (e == null || !empfangsTakt.angestossen) return;
    unawaited(core.setPushEndpoint(e));
  }

  Future<void> _nachIdentitaet() async {
    meineAdresse = core.myId;
    await _ladeEinstellungen();
    await raeumeAbgelaufeneWeg();
    kontakte = await core.getContacts();
    // AUCH DIE GRUPPEN UND JE EINE VORSCHAU. Bis 25.09.2026 lud der Start nur
    // die Kontakte: nach jedem Neustart fehlten alle Gruppen in der Liste,
    // bis zufaellig ein Kontaktereignis sie nachlud, und jede Zeile sagte
    // "Neuer Kontakt" statt der letzten Nachricht (Emulatorlauf).
    gruppen = await core.getGruppen();
    await _ladeVorschauen();
    await _ladeUngelesen();
    await _ladeVerteiler();
    await _ladeFernloeschung();
    _hoereZu();
    _planeVerfall();
    // EINE UEBERFAELLIGE FERNLOESCHUNG verbindet nicht mehr. Sie laeuft in
    // ihre Nachfrist (siehe [_planeFernloeschung]); erst wenn jemand sie
    // abbricht, geht die App wieder ins Netz.
    if (_fernNachfrist) {
      _verbindeNachAbbruch = true;
      return;
    }
    // Nicht abwarten: der Kern wirft bei Netzproblemen nicht, er meldet den
    // Zustand. Die Oberflaeche soll sofort da sein, auch im Funkloch.
    unawaited(core.connect());
  }

  // ═══════════════════════════════════════════════════════ Wiederverbinden
  //
  // BEWUSST NUR IM VORDERGRUND. Solange die App sichtbar ist, wartet ein
  // Mensch auf seine Nachricht — da lohnt jeder Versuch. Im Hintergrund
  // weiterzuprobieren waere dagegen der schnellste Weg, den Akku zu leeren,
  // und gehoert an den Vordergrunddienst, den es noch nicht gibt.
  //
  // Ohne das hier faellt die App beim ersten Funkloch stumm und kommt nie
  // zurueck: RelayClient meldet den Abbruch und ueberlaesst die Entscheidung
  // ausdruecklich dieser Schicht.

  Timer? _wiederverbindung;
  int _fehlversuche = 0;
  bool _imVordergrund = true;

  /// Wie viele Nachrichten seit dem letzten Hinsehen gekommen sind.
  int _ungelesen = 0;

  /// Die Texte kommen von aussen: der Kern kennt die Sprache des Nutzers
  /// nicht, und Uebersetzungen gehoeren nicht in eine Datei, die auch ohne
  /// Oberflaeche laufen soll.
  String einNeuText = 'Neue Nachricht';
  String Function(int) mehrereNeuText = (n) => '$n neue Nachrichten';

  /// Groesster Abstand zwischen zwei Versuchen.
  ///
  /// 30 Sekunden und nicht mehr: wer die App offen hat, soll nicht minutenlang
  /// auf eine Verbindung warten, die laengst wieder da waere.
  static const Duration maxAbstand = Duration(seconds: 30);

  /// Wird von der Oberflaeche gemeldet, wenn die App in den Vorder- oder
  /// Hintergrund geht.
  void vordergrund(bool sichtbar) {
    if (_imVordergrund == sichtbar) return;
    _imVordergrund = sichtbar;
    if (sichtbar) {
      unawaited(_beendeHintergrundempfang());
      // Zurueck aus der App, die einen Anhang geoeffnet hat: deren
      // Klartextkopie hat ausgedient ([anhangOeffnen]).
      unawaited(_gibExterneFrei());
      // DIE MELDUNGEN ZUERST, auch wenn gleich gesperrt wird: sonst blieb die
      // Benachrichtigung nach dem Zurueckkommen stehen, und der Zaehler zaehlte
      // beim naechsten Weglegen von der alten Zahl weiter.
      _ungelesen = 0;
      unawaited(Benachrichtigungen.instanz.raeumeAuf());
      if (_sollWiederSperren()) {
        unawaited(sperreWieder());
        return;
      }
      // Was im Hintergrund in die offene Unterhaltung kam, ist jetzt gesehen.
      final offen = offeneUnterhaltung;
      if (offen != null && ungelesen.remove(offen) != null) {
        unawaited(core.markRead(offen));
      }
      unawaited(raeumeAbgelaufeneWeg());
      _fehlversuche = 0;
      if (verbindung != ConnectionState.online && !_fernNachfrist) {
        unawaited(_versucheVerbindung());
      }
    } else {
      _weggelegtUm = DateTime.now();
      _verfallTakt?.cancel();
      _verfallTakt = null;
      // AM RECHNER UND IM BROWSER BLEIBT DIE LEITUNG. Dort gibt es weder
      // Akku-Noete noch einen Vordergrunddienst; ein verstecktes Fenster, das
      // die Verbindung kappt und nur alle 15 Minuten nachsieht, kam einfach
      // zu spaet an.
      if (verbindungImHintergrund) return;
      _wiederverbindung?.cancel();
      _wiederverbindung = null;
      unawaited(_starteHintergrundempfang());
    }
  }

  /// Ob die Verbindung stehen bleibt, wenn die App verdeckt ist — am Rechner
  /// und im Browser. Nur Android trennt und uebergibt an den Hintergrundempfang.
  bool verbindungImHintergrund = false;

  // ═══════════════════════════════════════════════════ Empfang im Hintergrund

  /// Der Vordergrunddienst. Null in Tests.
  EmpfangsDienst? empfangsDienst;

  /// Wie oft im Hintergrund nachgesehen wird.
  ///
  /// Steht in der Fachdatei neben der Sperrfrist und NICHT in den
  /// Einstellungen: die liegen in der verschluesselten Datenbank, und die ist
  /// beim Sperren zu.
  EmpfangsTakt empfangsTakt = EmpfangsTakt.aus;

  /// Texte fuer die dauerhafte Benachrichtigung. Der Kern kennt keine Sprache.
  String empfangTitelText = 'BitDM';
  String empfangLaeuftText = 'Empfangsbereit';

  Timer? _empfangsTimer;

  /// Ob der Hintergrundempfang gerade ueberhaupt etwas ausrichten KANN.
  ///
  /// Bei eingeschalteter Sperre und abgelaufener Frist ist die Entropie weg —
  /// und ohne sie gibt es keinen Identitaetsschluessel, ohne den der Relay
  /// nicht einmal die Frage beantwortet, ob etwas anliegt.
  bool get empfangMoeglich =>
      empfangsTakt.an && hatIdentitaet && !gesperrt && !_sperrtGleich;

  /// Ob die App beim naechsten Weglegen sofort zusperrt.
  bool get _sperrtGleich =>
      faktoren.isNotEmpty && !_nieSperren && sperrfrist == Duration.zero;

  /// Die Anbindung an den Verteiler auf dem Telefon.
  ///
  /// Ersetzbar, weil der Verteiler eine ANDERE App auf demselben Telefon ist —
  /// nachbauen laesst er sich nicht, und ohne Ersatz bliebe der Fall
  /// "Verteiler weigert sich" ungeprueft. Genau der ist der haeufigste.
  PushAnbindung? push;

  /// Der zuletzt vom Verteiler genannte Endpunkt.
  String? pushEndpunkt;

  Future<void> setzeEmpfangsTakt(EmpfangsTakt takt) async {
    final vorher = empfangsTakt;

    // ERST DAS, WAS FEHLSCHLAGEN KANN. Waere die Einstellung schon
    // gespeichert, wenn sich der Verteiler weigert, stuende in der App
    // "Anstoss" — und es liefe nichts. Ein Zustand, den der Nutzer nicht von
    // einem echten unterscheiden kann und der erst auffaellt, wenn tagelang
    // keine Nachricht kommt.
    if (takt.angestossen && !vorher.angestossen) {
      await _startePush();
    }

    final t = tresor;
    if (t != null) await t.setzeEmpfangsTakt(takt.minuten);
    empfangsTakt = takt;
    if (!takt.an) await _beendeHintergrundempfang();

    // Beim Wegwechseln erst danach abmelden: waere es davor, und das
    // Speichern schluege fehl, waere der Verteiler weg und die Einstellung
    // stuende weiter auf Anstoss.
    if (vorher.angestossen && !takt.angestossen) {
      await _beendePush();
    }
    notifyListeners();
  }

  /// Meldet BitDM beim Verteiler an. Der Endpunkt kommt spaeter ueber den
  /// Rueckruf, nicht von hier.
  Future<void> _startePush({String? verteiler}) async {
    final p = push;
    if (p == null) throw const PushException(PushHindernis.keinVerteiler);
    await p.melde(verteilerName: verteiler);
  }

  Future<void> _beendePush() async {
    pushEndpunkt = null;
    // ERST beim Relay loeschen, DANN beim Verteiler abmelden. Andersherum
    // bliebe ein Endpunkt eingetragen, an den niemand mehr horcht — der Relay
    // klopfte dann ins Leere und wuesste es nicht.
    try {
      await core.setPushEndpoint(null);
    } catch (_) {
      // Nicht verbunden. Der Endpunkt bleibt eingetragen, bis die App das
      // naechste Mal online ist; angestossen wird dann ins Leere, was nichts
      // kaputtmacht.
    }
    await push?.melde_ab();
  }

  /// Der Verteiler nennt einen Endpunkt — beim Einrichten und immer dann, wenn
  /// er ihn von sich aus wechselt.
  ///
  /// DASS ER WECHSELN KANN, ist der Grund, warum das ein Rueckruf ist: ntfy
  /// vergibt nach einer Neuinstallation ein neues Thema. Wer den alten
  /// Endpunkt beim Relay stehen laesst, wird nie wieder angestossen und merkt
  /// es nicht.
  Future<void> nimmPushEndpunkt(String endpunkt) async {
    if (!PushAnbindung.eigenerServer(endpunkt)) {
      // Ein fremder Server wuerde vom Relay ohnehin abgelehnt. Hier faellt es
      // frueher auf, und die Meldung kann sagen, WARUM.
      // Als Schluessel, nicht als Satz: die Oberflaeche uebersetzt ihn, und
      // der Endpunkt selbst gehoert in keine Bildschirmaufnahme.
      letzterFehler = 'pushFremd';
      notifyListeners();
      return;
    }
    pushEndpunkt = endpunkt;
    await core.setPushEndpoint(endpunkt);
    notifyListeners();
  }

  /// Ein Anstoss ist angekommen: verbinden, abholen, wieder trennen.
  ///
  /// Was NICHT im Anstoss steht: Absender, Inhalt, Anzahl. Er sagt nur, dass
  /// etwas anliegt.
  Future<void> beiAnstoss() async {
    if (!empfangMoeglich) return;
    await core.connect();
    // Der Relay leert seine Warteschlange gleich nach der Anmeldung. Kurz
    // offen lassen, damit das durchlaeuft.
    await Future<void>.delayed(const Duration(seconds: 20));
    if (!_imVordergrund) await core.disconnect();
  }

  Future<void> _starteHintergrundempfang() async {
    if (!empfangMoeglich) return;

    // BEIM ANSTOSSEN LAEUFT NICHTS. Das ist der ganze Vorteil: kein Dienst,
    // keine dauerhafte Benachrichtigung, kein Akkuverbrauch. Der Verteiler auf
    // dem Telefon haelt die Verbindung, und die weckt BitDM, wenn etwas
    // anliegt.
    if (empfangsTakt.angestossen) return;

    final dienst = empfangsDienst;
    if (dienst == null) return;

    await dienst.starte(titel: empfangTitelText, text: empfangLaeuftText);

    if (empfangsTakt.dauerhaft) {
      // Die bestehende Verbindung bleibt einfach offen. Der Kern verbindet
      // von sich aus nach, wenn sie abreisst — dieselbe Logik wie im
      // Vordergrund, statt einer zweiten daneben.
      if (verbindung != ConnectionState.online) {
        unawaited(core.connect());
      }
      return;
    }

    // Im Takt: verbinden, abholen, wieder trennen. Eine offene Verbindung
    // kostet dauerhaft Funk; ein kurzer Griff alle 15 Minuten deutlich
    // weniger.
    await core.disconnect();
    _empfangsTimer?.cancel();
    _empfangsTimer = Timer.periodic(empfangsTakt.abstand, (_) async {
      if (!empfangMoeglich) {
        await _beendeHintergrundempfang();
        return;
      }
      await core.connect();
      // Kurz offen lassen, damit der Relay seine Warteschlange leeren kann.
      // Er schickt alles Wartende gleich nach der Anmeldung.
      await Future<void>.delayed(const Duration(seconds: 20));
      if (!_imVordergrund) await core.disconnect();
    });
  }

  Future<void> _beendeHintergrundempfang() async {
    _empfangsTimer?.cancel();
    _empfangsTimer = null;
    final dienst = empfangsDienst;
    if (dienst != null && dienst.laeuft) await dienst.stoppe();
  }

  // ═══════════════════════════════════════════════════════ Von selbst zusperren

  /// Wann die App zuletzt weggelegt wurde. Null heisst: sie war nicht weg.
  DateTime? _weggelegtUm;

  /// Wie lange die App zu bleiben darf, ohne wieder zu verriegeln.
  ///
  /// STANDARD IST SOFORT. Wer eine Sperre einrichtet, will gefragt werden —
  /// und nicht manchmal. Laenger geht auch, aber das muss man wollen und
  /// einstellen; siehe [setzeSperrfrist].
  ///
  /// Die Zahl steht in der Fachdatei, nicht in den Einstellungen: die liegen
  /// in der verschluesselten Datenbank, und die ist beim Sperren zu — die
  /// Frist waere dann genau in dem Moment nicht lesbar, in dem sie gebraucht
  /// wird.
  Duration sperrfrist = Duration.zero;

  /// Die Auswahl, die die Oberflaeche anbietet. -1 heisst: gar nicht sperren.
  static const List<int> sperrfristAuswahl = [0, 60, 300, -1];

  /// Ob gerade ein Faktor bedient wird.
  ///
  /// WICHTIG BEI "SOFORT": das Freigeben eines USB-Sticks zeigt Android als
  /// eigenen Dialog, und die App geht dabei in den Hintergrund. Wuerde sie
  /// dann zusperren, liesse sich ein Stick nie einrichten — man kaeme immer
  /// nur bis zur Freigabe.
  bool _amFaktor = false;

  Future<void> setzeSperrfrist(int sekunden) async {
    final t = tresor;
    if (t == null) throw const LockUnavailableException('nicht verfuegbar');
    await t.setzeSperrfrist(sekunden < 0 ? -1 : sekunden);
    sperrfrist = sekunden < 0 ? Duration.zero : Duration(seconds: sekunden);
    _nieSperren = sekunden < 0;
    notifyListeners();
  }

  bool _nieSperren = false;

  /// Die Frist als Zahl, wie die Oberflaeche sie anzeigt. -1 heisst nie.
  int get sperrfristAlsZahl => _nieSperren ? -1 : sperrfrist.inSeconds;

  bool _sollWiederSperren() {
    if (faktoren.isEmpty) return false; // ohne Faktor gibt es nichts zu sperren
    if (gesperrt || _nieSperren || _amFaktor) return false;
    final weg = _weggelegtUm;
    if (weg == null) return false;
    return DateTime.now().difference(weg) >= sperrfrist;
  }

  /// Verriegelt wieder: Datenbank zu, Schluessel aus dem Speicher.
  ///
  /// Nicht bloss ein Bildschirm davor. Ein Vorhang liesse die Datenbank offen
  /// und die Schluessel im Arbeitsspeicher — wer den Prozess lesen kann, kaeme
  /// daran vorbei.
  Future<void> sperreWieder() async {
    if (faktoren.isEmpty) return;
    _weggelegtUm = null;
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    for (final a in _abos) {
      unawaited(a.cancel());
    }
    _abos.clear();

    tresor?.sperre();
    await core.lock();

    // Auch das, was die Oberflaeche schon geholt hat, muss weg. Die Verlaeufe
    // stehen hier IM KLARTEXT — sie kamen ja entschluesselt aus der Datenbank.
    // Die Datenbank zu schliessen und den Text daneben liegen zu lassen waere
    // halbe Arbeit.
    verlaeufe.clear();
    reaktionen.clear();
    stimmen.clear();
    suchTreffer = const [];
    kontakte = const [];
    gruppen = const [];
    meineAdresse = '';
    frischePhrase = null;
    // UND ALLES ANDERE, WAS AUS DER DATENBANK KAM: markierte Nachrichten
    // (Klartext), Anhaenge samt Pfaden und Namen, der Suchtext, die
    // Verteilerlisten, wer gerade tippt. Die Fernloeschung selbst laeuft
    // weiter — ihr Wecker haengt nicht an der Anzeige (siehe
    // [_planeFernloeschung]); nur ihr Stand wird hier vergessen.
    _vergissAngezeigtes();
    fernloeschung = const Fernloeschung();

    gesperrt = true;
    notifyListeners();
  }

  /// Vergisst alles, was die Oberflaeche aus der Datenbank geholt hat — beim
  /// Sperren und beim Loeschen.
  void _vergissAngezeigtes() {
    sterne = const [];
    anhaenge.clear();
    // Entschluesselte Vorschaubilder — Klartext wie die Verlaeufe. Die
    // Klartextdateien raeumt der Kern beim Sperren selbst weg.
    _vergissVorschau();
    _extern.clear();
    fortschritt.clear();
    suchText = '';
    suchTreffer = const [];
    verteiler = const [];
    _tipptBis.clear();
    ungelesen = {};
    frischeNachrichten.clear();
    _fruehStatus.clear();
    _verfallTakt?.cancel();
    _verfallTakt = null;
    _nachweis = null;
  }

  /// Ob gerade jemand eine Verbindung will: im Vordergrund immer, verdeckt nur
  /// dort, wo sie stehen bleibt ([verbindungImHintergrund]). Nie waehrend der
  /// Nachfrist einer Fernloeschung und nie gesperrt.
  bool get _leitungGewollt =>
      (_imVordergrund || verbindungImHintergrund) && !gesperrt && !_fernNachfrist;

  Future<void> _versucheVerbindung() async {
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    if (!hatIdentitaet || !_leitungGewollt) return;
    await core.connect();
  }

  void _planeWiederverbindung() {
    if (!_leitungGewollt || _wiederverbindung != null) return;
    // Kein Wiederverbinden gegen den Willen des Nutzers. Ohne diese Zeile
    // versuchte der Zeitgeber im Hintergrund weiter, sich zu verbinden — der
    // Kern lehnte jedes Mal ab, aber es waere ein Wecker, der alle paar
    // Sekunden gegen eine verschlossene Tuer laeuft.
    if (einstellungen.nurNahbereich) return;

    // UND NICHT GEGEN EIN ENDGUELTIGES NEIN. Der Relay antwortet einem Geraet
    // ueber der Obergrenze mit 507 und nicht mit 429, gerade weil das keine
    // Bremse ist, die nachgibt (Spezifikation §6). Weiterzuklopfen aendert
    // daran nichts — es kostet nur Akku und laesst den Nutzer glauben, sein
    // Netz sei schuld. Der naechste ausdrueckliche Versuch (Vordergrund,
    // Einstellungen) fragt ohnehin neu.
    if (abgewiesen) return;

    // Verdoppeln mit Zufallsanteil. Der Zufall ist nicht Zierrat: ohne ihn
    // kaemen nach einem Ausfall des Relays alle Clients gleichzeitig zurueck
    // und legten ihn erneut lahm.
    final stufe = _fehlversuche.clamp(0, 5);
    final basis = Duration(seconds: 1 << stufe);
    final gedeckelt = basis > maxAbstand ? maxAbstand : basis;
    final streuung = Duration(
        milliseconds: _zufall.nextInt(gedeckelt.inMilliseconds ~/ 2 + 1));
    _fehlversuche++;

    _wiederverbindung = Timer(gedeckelt + streuung, () {
      _wiederverbindung = null;
      unawaited(_versucheVerbindung());
    });
  }

  void _hoereZu() {
    if (_abos.isNotEmpty) return;
    _abos
      ..add(core.connectionStateChanges.listen((s) {
        verbindung = s;
        if (s == ConnectionState.online) {
          _fehlversuche = 0;
          _wiederverbindung?.cancel();
          _wiederverbindung = null;
          _traegePushEndpunktEin();
        } else if (s == ConnectionState.disconnected ||
            s == ConnectionState.error) {
          _planeWiederverbindung();
        }
        notifyListeners();
      }))
      ..add(core.incomingMessages.listen((m) {
        // Neue Liste statt `.add` — siehe [senden]: die Liste kann vom Kern
        // stammen und unveraenderlich sein.
        verlaeufe[m.chatId] = [...?verlaeufe[m.chatId], m];
        // Fuer den Entschluesselungs-Effekt: diese Nachricht hat noch niemand
        // gesehen. Gedeckelt, damit ein langer Offline-Nachschub die Menge
        // nicht endlos wachsen laesst.
        if (!m.isMine) {
          if (frischeNachrichten.length > 200) frischeNachrichten.clear();
          frischeNachrichten.add(m.id);
          // WER GERADE HINSIEHT, HAT SIE GELESEN. Bis 25.09.2026 galt nur das
          // Oeffnen als Lesen: eine Nachricht, die in die offene Unterhaltung
          // kam, blieb "ungelesen" und bekam keine Lesebestaetigung.
          if (m.chatId == offeneUnterhaltung && _imVordergrund) {
            unawaited(core.markRead(m.chatId));
          } else {
            ungelesen[m.chatId] = (ungelesen[m.chatId] ?? 0) + 1;
          }
        }
        // Nur melden, wenn niemand hinsieht. Eine Benachrichtigung fuer eine
        // Nachricht, die gerade auf dem Bildschirm erscheint, waere Laerm.
        //
        // UND NIE FUER EINE EIGENE. Seit dem Spiegel (§5) traegt dieser Strom
        // auch das, was man selbst auf dem ANDEREN Geraet geschrieben hat —
        // `_nimmSpiegel` legt es mit `isMine: true` ab und wirft es hier ein.
        // Ohne diese Bedingung meldete das Tablet "eine neue Nachricht" fuer
        // jeden Satz, den man gerade auf dem Handy getippt hat.
        // UND NICHT FUER STUMMGESCHALTETE. Die Nachricht kommt trotzdem an
        // und steht im Verlauf; nur das Telefon meldet sich nicht.
        // UND NICHT IN DER RUHEZEIT — ausser fuer angeheftete Unterhaltungen:
        // die hat der Nutzer selbst als die wichtigen ausgewaehlt.
        final ruhe = einstellungen.inRuhezeit(DateTime.now()) && !_istAngeheftet(m.chatId);
        // EINE ERWAEHNUNG KOMMT DURCH — durch Stumm und Ruhezeit. Wer in
        // einer lauten Gruppe gezielt angesprochen wird, soll es merken.
        final erwaehnt = erwaehntMich(m);
        if (!_imVordergrund && !m.isMine && (erwaehnt || (!_istStumm(m.chatId) && !ruhe))) {
          _ungelesen++;
          unawaited(Benachrichtigungen.instanz.zeigeNeueNachricht(
              anzahl: _ungelesen,
              text: _ungelesen == 1 ? einNeuText : mehrereNeuText(_ungelesen)));
        }
        unawaited(_ladeKontakteNeu());
        // Sie kann eine kuerzere Frist haben als alles, was schon da war.
        _planeVerfall();
      }))
      ..add(core.contactEvents.listen((_) => unawaited(_ladeKontakteNeu())))
      // Bearbeitet, widerrufen, Reaktion gesetzt: die ganze Unterhaltung neu
      // lesen statt einzelne Felder nachzuziehen. Eine Unterhaltung sind ein
      // paar Dutzend Zeilen; drei Sonderwege fuer drei Arten Aenderung waeren
      // drei Stellen, an denen die Anzeige vom Speicher abweichen kann.
      ..add(core.verlaufGeaendert.listen((chat) => unawaited(_ladeNeu(chat))))
      ..add(core.tippen.listen(_nimmTippen))
      ..add(core.gruppenGeaendert.listen((_) => unawaited(_ladeGruppenNeu())))
      ..add(core.fernloeschungAusgeloest.listen((f) {
        fernloeschung = f;
        _planeFernloeschung();
      }))
      ..add(core.messageStatusUpdates.listen(_uebernehmeStatus))
      ..add(core.anhangAenderungen.listen((a) {
        anhaenge.putIfAbsent(a.chatId, () => {})[a.messageId] = a;
        // Ist er da, ist der Fortschritt erledigt und soll weg — sonst
        // stuende unter der fertigen Datei noch ein Balken.
        if (a.zustand != AnhangZustand.laedt) fortschritt.remove(a.messageId);
        notifyListeners();
      }))
      ..add(core.anhangFortschritt.listen((f) {
        fortschritt[f.messageId] = f;
        // OHNE DROSSEL waere das mehrmals je Sekunde ein kompletter Neubau
        // des Bildschirms — bei einer 3-GB-Datei minutenlang. Gezeichnet wird
        // hoechstens alle 100 ms; die Zahl selbst ist immer die aktuelle.
        final jetzt = DateTime.now();
        if (_letzterBalken == null ||
            jetzt.difference(_letzterBalken!).inMilliseconds >= 100 ||
            f.fertigeBytes >= f.gesamtBytes) {
          _letzterBalken = jetzt;
          notifyListeners();
        }
      }));
  }

  DateTime? _letzterBalken;

  void _uebernehmeStatus(MessageStatusUpdate u) {
    final liste = verlaeufe[u.chatId];
    final i = liste?.indexWhere((m) => m.id == u.messageId) ?? -1;
    if (i < 0) {
      // DER STATUS KANN VOR DER NACHRICHT DA SEIN. Bei den Notizen setzt der
      // Kern "sent" noch innerhalb von `sendMessage`, also bevor [senden] die
      // Nachricht in den Verlauf haengt — ohne diesen Merkzettel verpuffte
      // das Ereignis, und die Notiz stand bis zum Neuoeffnen auf ◷
      // (gefunden am 25.09.2026 im Emulatorlauf).
      _fruehStatus[u.messageId] = u.status;
      if (_fruehStatus.length > 64) _fruehStatus.remove(_fruehStatus.keys.first);
      return;
    }
    liste![i] = liste[i].copyWith(status: u.status);
    notifyListeners();
  }

  /// Ungelesene fremde Nachrichten je Unterhaltung (nur die mit welchen).
  Map<String, int> ungelesen = {};

  int ungelesenIn(String chatId) => ungelesen[chatId] ?? 0;

  /// Welche Unterhaltung die Oberflaeche gerade zeigt, oder null. Die
  /// Oberflaeche setzt das beim Zeichnen.
  String? offeneUnterhaltung;

  Future<Set<String>> zugestelltAn(String gruppe, String messageId) =>
      core.zugestelltAn(gruppe, messageId);

  // ═══════════════════════════════════════════ Fernloeschung (k von n)

  Fernloeschung fernloeschung = const Fernloeschung();
  Timer? _fernTakt;

  Future<void> _ladeFernloeschung() async {
    try {
      fernloeschung = await core.getFernloeschung();
    } on MessengerException {
      return;
    }
    _planeFernloeschung();
  }

  Future<void> setzeFernloeschung(Fernloeschung f) async {
    await core.setzeFernloeschung(f);
    fernloeschung = await core.getFernloeschung();
    notifyListeners();
  }

  /// Bricht einen laufenden Countdown ab und vergisst die Anfragen.
  ///
  /// Die Oberflaeche verlangt vorher eine frische Anmeldung (main.dart,
  /// `frischBestaetigt`) — sonst koennte jeder mit dem entsperrten Telefon
  /// die Loeschung aufhalten, die gerade wegen ihm laeuft.
  Future<void> brichFernloeschungAb() async {
    _fernTakt?.cancel();
    unawaited(Benachrichtigungen.instanz.nimmWarnungWeg());
    fernFrist = null;
    _fernNachfrist = false;
    await setzeFernloeschung(fernloeschung.copyWith(anfragen: const {}, ohneFaellig: true));
    if (_verbindeNachAbbruch) {
      _verbindeNachAbbruch = false;
      unawaited(core.connect());
    }
  }

  Future<void> sendeLoeschanfrage(String contactId) => core.sendeLoeschanfrage(contactId);

  /// Stellt den Wecker auf die Faelligkeit.
  ///
  /// NICHT SOFORT, WENN SIE SCHON VORBEI IST. Lief der Countdown ab, waehrend
  /// die App zu war oder gesperrt, bekommt der Nutzer nach dem Oeffnen eine
  /// kurze letzte Frist ([fernNachfrist]) mit dem Balken — und die App geht
  /// solange nicht ins Netz (siehe [_nachIdentitaet]).
  void _planeFernloeschung() {
    _fernTakt?.cancel();
    final f = fernloeschung.faellig;
    if (f == null) {
      fernFrist = null;
      _fernNachfrist = false;
      return;
    }
    final jetzt = DateTime.now().toUtc();
    var ziel = f;
    _fernNachfrist = !f.isAfter(jetzt);
    if (_fernNachfrist) ziel = jetzt.add(fernNachfrist);
    fernFrist = ziel;
    unawaited(Benachrichtigungen.instanz.zeigeWarnung(text: fernWarnText));
    _fernTakt = Timer(ziel.difference(jetzt), () => unawaited(allesLoeschen()));
    notifyListeners();
  }

  /// Die letzte Frist fuer eine Fernloeschung, die schon faellig war.
  static const Duration fernNachfrist = Duration(seconds: 60);

  /// Wann wirklich geloescht wird — die Faelligkeit oder das Ende der
  /// Nachfrist. Null, solange nichts laeuft. Fuer den Balken.
  DateTime? fernFrist;

  /// Ob gerade die Nachfrist laeuft.
  bool _fernNachfrist = false;

  /// Ob nach einem Abbruch noch verbunden werden muss (die Nachfrist hat das
  /// Verbinden beim Start ausgelassen).
  bool _verbindeNachAbbruch = false;

  /// Text der Warnung — von der Oberflaeche uebersetzt gesetzt. NEUTRAL: die
  /// Benachrichtigung sieht auch, wer das Telefon gerade nicht haben sollte.
  String fernWarnText = 'BitDM needs your attention.';

  /// Verteilerlisten (siehe [Verteiler]).
  List<Verteiler> verteiler = const [];

  Future<void> _ladeVerteiler() async {
    try {
      verteiler = await core.getVerteiler();
    } on MessengerException {
      return;
    }
  }

  Future<void> legeVerteilerAn(String name, List<String> mitglieder) async {
    final v = Verteiler(
        id: 'v-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        mitglieder: mitglieder.take(Verteiler.maxMitglieder).toList());
    verteiler = [...verteiler, v];
    await core.speichereVerteiler(verteiler);
    notifyListeners();
  }

  Future<void> loescheVerteiler(String id) async {
    verteiler = verteiler.where((v) => v.id != id).toList();
    await core.speichereVerteiler(verteiler);
    notifyListeners();
  }

  /// Schickt [text] an jedes Mitglied einzeln. Rueckgabe: an wie viele es
  /// ging und bei wie vielen es scheiterte.
  ///
  /// NACHEINANDER, nicht gleichzeitig: jede Nachricht geht durch die Sitzung
  /// ihres Empfaengers, und fuenfzig parallele Versuche beim Wiederverbinden
  /// waeren fuenfzig Last auf einmal.
  ///
  /// JE MITGLIED GEFANGEN. Vorher brach der erste Fehler die Schleife ab: die
  /// Haelfte der Liste bekam die Nachricht, der Rest nicht, und die Meldung
  /// sagte nichts davon.
  Future<({int gesendet, int fehlgeschlagen})> sendeAnVerteiler(
      String id, String text) async {
    final v = verteiler.where((x) => x.id == id).firstOrNull;
    if (v == null || text.trim().isEmpty) return (gesendet: 0, fehlgeschlagen: 0);
    var gesendet = 0;
    var fehlgeschlagen = 0;
    for (final m in v.mitglieder) {
      if (!aktiveKontakte.any((k) => k.id == m)) continue;
      final fehlerVorher = letzterFehler;
      try {
        letzterFehler = null;
        await senden(m, text);
        // [senden] faengt "zu lang" selbst und merkt es sich nur.
        if (letzterFehler == 'zuLang') {
          fehlgeschlagen++;
        } else {
          gesendet++;
          letzterFehler = fehlerVorher;
        }
      } catch (e) {
        fehlgeschlagen++;
        _merkeTechnisch(e);
        letzterFehler = fehlerVorher;
      }
    }
    return (gesendet: gesendet, fehlgeschlagen: fehlgeschlagen);
  }

  Future<void> _ladeUngelesen() async {
    try {
      ungelesen = await core.ungelesenJeChat();
    } on MessengerException {
      return;
    }
    notifyListeners();
  }

  /// Eingetroffene Nachrichten, deren Blase noch nicht erschienen ist — sie
  /// entschluesseln sich beim ersten Erscheinen sichtbar (siehe Oberflaeche).
  final Set<String> frischeNachrichten = {};

  /// Status, die eintrafen, bevor ihre Nachricht im Verlauf stand.
  final Map<String, MessageStatus> _fruehStatus = {};

  /// Haengt eine EIGENE, gerade verschickte Nachricht an — mit dem Status,
  /// der ihr womoeglich schon vorausgelaufen ist.
  ///
  /// Eine neue Liste statt `.add`: die Liste kann vom Kern stammen und
  /// unveraenderlich sein (siehe [senden]).
  void _haengeEigeneAn(String chatId, Message m) {
    final frueh = _fruehStatus.remove(m.id);
    final mit = frueh == null || frueh.index <= m.status.index
        ? m
        : m.copyWith(status: frueh);
    verlaeufe[chatId] = [...?verlaeufe[chatId], mit];
    _planeVerfall();
  }

  Future<void> _ladeKontakteNeu() async {
    kontakte = await core.getContacts();
    gruppen = await core.getGruppen();
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════════════ Gruppen

  List<Gruppe> gruppen = const [];

  Gruppe? gruppeZu(String id) => gruppen.where((g) => g.id == id).firstOrNull;

  Future<void> _ladeGruppenNeu() async {
    gruppen = await core.getGruppen();
    notifyListeners();
  }

  Future<String> legeGruppeAn(String name, List<String> mitglieder) async {
    final g = await core.legeGruppeAn(name, mitglieder);
    await _ladeGruppenNeu();
    return g.id;
  }

  Future<void> fuegeZuGruppeHinzu(String id, List<String> neue) =>
      _versuche(() => core.fuegeZuGruppeHinzu(id, neue));
  Future<void> entferneAusGruppe(String id, String mitglied) =>
      _versuche(() => core.entferneAusGruppe(id, mitglied));
  Future<void> benenneGruppe(String id, String name) =>
      _versuche(() => core.benenneGruppe(id, name));
  Future<void> verlasseGruppe(String id) =>
      _versuche(() => core.verlasseGruppe(id));

  // ═══════════════════════════════════════════════════════════════ Identitaet

  /// Legt eine Identitaet an und haelt die zwoelf Woerter zum Anzeigen bereit.
  Future<void> identitaetAnlegen() async {
    frischePhrase = await core.createIdentity();
    hatIdentitaet = true;
    await _nachIdentitaet();
    notifyListeners();
  }

  Future<bool> identitaetWiederherstellen(List<String> woerter) async {
    if (!core.isValidRecoveryPhrase(woerter)) {
      letzterFehler = 'phraseUngueltig';
      notifyListeners();
      return false;
    }
    try {
      await core.restoreIdentity(woerter);
      hatIdentitaet = true;
      // Eine alte Meldung vom Fehlversuch davor gehoert nicht mehr hierher.
      if (letzterFehler == 'phraseUngueltig') letzterFehler = null;
      await _nachIdentitaet();
      notifyListeners();
      return true;
    } on MessengerException {
      letzterFehler = 'phraseUngueltig';
      notifyListeners();
      return false;
    }
  }

  /// Der Nutzer hat bestaetigt, dass er die Woerter notiert hat.
  void phraseBestaetigt() {
    frischePhrase = null;
    notifyListeners();
  }

  Future<List<String>> phraseAusEinstellungen() => core.getRecoveryPhrase();

  // ═════════════════════════════════════════════════════════════════ Kontakte

  List<Contact> get aktiveKontakte =>
      kontakte.where((c) => c.state == ContactState.active).toList();

  List<Contact> get offeneAnfragen => kontakte
      .where((c) => c.state == ContactState.incomingPending)
      .toList();

  List<Contact> get eigeneAnfragen => kontakte
      .where((c) => c.state == ContactState.outgoingPending)
      .toList();

  bool adresseGueltig(String a) => core.isValidAddress(a);

  /// Gibt true zurueck, wenn die Anfrage rausging.
  Future<bool> kontaktHinzufuegen(String adresse) async {
    try {
      await core.addContact(adresse);
      if (letzterFehler == 'adresseUngueltig') letzterFehler = null;
      await _ladeKontakteNeu();
      return true;
    } on InvalidAddressException {
      letzterFehler = 'adresseUngueltig';
      notifyListeners();
      return false;
    }
  }

  Future<void> anfrageAnnehmen(String id) async {
    await core.acceptRequest(id);
    await _ladeKontakteNeu();
  }

  Future<void> anfrageAblehnen(String id) async {
    await core.declineRequest(id);
    verlaeufe.remove(id);
    await _ladeKontakteNeu();
  }

  // ══════════════════════════════════════════════════════════════ Nachrichten

  List<Message> verlaufVon(String id) => verlaeufe[id] ?? const [];

  /// Die letzte Nachricht jeder Unterhaltung, fuer die Zeilen der Chatliste.
  ///
  /// NUR EINE je Unterhaltung, nicht der Verlauf: den holt erst das Oeffnen
  /// ([unterhaltungOeffnen]). Und KEIN `markRead` — eine Vorschau ist kein
  /// Lesen, und eine Lesebestaetigung beim App-Start waere gelogen.
  Future<void> _ladeVorschauen() async {
    for (final id in [
      ...aktiveKontakte.map((k) => k.id),
      ...gruppen.map((g) => g.id),
    ]) {
      if (verlaeufe.containsKey(id)) continue;
      try {
        final letzte = await core.getMessages(id, limit: 1);
        if (letzte.isNotEmpty) verlaeufe[id] = letzte;
      } on MessengerException {
        // Eine Zeile ohne Vorschau ist kein Grund, den Start abzubrechen.
      }
    }
  }

  Future<void> unterhaltungOeffnen(String id) async {
    verlaeufe[id] = await core.getMessages(id);
    // In EINEM Zug fuer die ganze Unterhaltung. Je Nachricht zu fragen hiesse
    // bei fuenfzig Anhaengen fuenfzig Abfragen beim Zeichnen einer Liste.
    anhaenge[id] = await core.getAnhaenge(id);
    reaktionen[id] = await core.getReaktionen(id);
    stimmen[id] = await core.getStimmen(id);
    ungelesen.remove(id);
    notifyListeners();
    unawaited(core.markRead(id));
  }

  // ═══════════════════════════ Antworten, Reaktionen, Bearbeiten, Loeschen

  /// chatId → messageId → wer → Zeichen.
  final Map<String, Map<String, Reaktionen>> reaktionen = {};

  Reaktionen reaktionenZu(String chatId, String messageId) =>
      reaktionen[chatId]?[messageId] ?? const {};

  /// Wie diese App eine Adresse in einer Erwaehnung schreibt: "@XLLW…S7JD"
  /// — dieselbe Kurzform, unter der jedes Mitglied ohnehin angezeigt wird.
  /// Keine Namen, kein neues Feld auf der Leitung: eine aeltere Fassung zeigt
  /// einfach den Text.
  static String erwaehnungVon(String adresse) => '@${shortId(adresseFormatiert(adresse))}';

  /// Ob [m] eine Gruppennachricht ist, die mich erwaehnt.
  bool erwaehntMich(Message m) =>
      meineAdresse.isNotEmpty &&
      Gruppe.istGruppenId(m.chatId) &&
      !m.isMine &&
      m.text.contains(erwaehnungVon(meineAdresse));

  bool _istAngeheftet(String chatId) =>
      kontakte.any((k) => k.id == chatId && k.angeheftet) ||
      gruppen.any((g) => g.id == chatId && g.angeheftet);

  bool _istStumm(String chatId) =>
      kontakte.any((k) => k.id == chatId && k.stumm) ||
      gruppen.any((g) => g.id == chatId && g.stumm);

  /// Liest eine Unterhaltung neu, aber nur, wenn sie schon geladen war —
  /// sonst holte jede Reaktion in einer nie geoeffneten Unterhaltung deren
  /// ganzen Verlauf in den Speicher.
  Future<void> _ladeNeu(String chat) async {
    if (!verlaeufe.containsKey(chat)) return;
    verlaeufe[chat] = await core.getMessages(chat);
    reaktionen[chat] = await core.getReaktionen(chat);
    stimmen[chat] = await core.getStimmen(chat);
    anhaenge[chat] = await core.getAnhaenge(chat);
    notifyListeners();
  }

  /// Die Nachricht, auf die [m] antwortet, aus dem geladenen Verlauf — oder
  /// null, wenn sie hier nicht (mehr) steht.
  Message? bezugVon(Message m) {
    final ziel = m.antwortAuf;
    if (ziel == null) return null;
    for (final x in verlaeufe[m.chatId] ?? const <Message>[]) {
      if (x.id == ziel) return x;
    }
    return null;
  }

  /// Ob die Oberflaeche "Bearbeiten" anbieten darf — dieselben Regeln wie der
  /// Kern, damit kein Menuepunkt erscheint, der dann scheitert.
  static bool bearbeitbar(Message m) =>
      m.isMine &&
      m.kind == MessageKind.text &&
      !m.widerrufen &&
      DateTime.now().toUtc().difference(m.timestamp) <= kBearbeitungsFrist;

  static bool widerrufbar(Message m) =>
      m.isMine &&
      !m.widerrufen &&
      DateTime.now().toUtc().difference(m.timestamp) <= kWiderrufsFrist;

  Future<void> reagiere(String chatId, String messageId, String? zeichen) =>
      _versuche(() => core.reagiere(chatId, messageId, zeichen));

  Future<void> bearbeite(String chatId, String messageId, String text) async {
    final sauber = text.trim();
    if (sauber.isEmpty) return;
    await _versuche(() => core.bearbeite(chatId, messageId, sauber));
  }

  Future<void> widerrufe(String chatId, String messageId) =>
      _versuche(() => core.widerrufe(chatId, messageId));

  /// chatId → umfrageId → wer → Auswahl.
  final Map<String, Map<String, Stimmen>> stimmen = {};

  Stimmen stimmenZu(String chatId, String umfrageId) =>
      stimmen[chatId]?[umfrageId] ?? const {};

  Future<void> sendeUmfrage(String chatId, Umfrage u) async {
    final m = await core.sendeUmfrage(chatId, u);
    _haengeEigeneAn(chatId, m);
    notifyListeners();
  }

  Future<void> stimme(String chatId, String umfrageId, List<int> auswahl) =>
      _versuche(() => core.stimme(chatId, umfrageId, auswahl));

  Future<void> hefteAn(String chatId, String messageId, bool an) =>
      _versuche(() => core.hefteAn(chatId, messageId, an));

  /// Die angehefteten Nachrichten einer Unterhaltung, zuletzt angeheftete
  /// zuerst.
  List<Message> angeheftete(String chatId) =>
      verlaufVon(chatId).where((m) => m.angeheftetAm != null).toList()
        ..sort((a, b) => b.angeheftetAm!.compareTo(a.angeheftetAm!));

  Future<void> loescheFuerMich(String chatId, String messageId) =>
      _versuche(() => core.loescheFuerMich(chatId, messageId));

  /// Markierte Nachrichten ueber alle Unterhaltungen — fuer den Filter "★".
  List<Message> sterne = const [];

  Future<void> setzeStern(String chatId, String messageId, bool an) async {
    await _versuche(() => core.setzeStern(chatId, messageId, an));
    await ladeSterne();
  }

  Future<void> ladeSterne() async {
    sterne = await core.sterne();
    notifyListeners();
  }

  /// Fuehrt eine Aenderung aus und zeigt ein Scheitern an, statt es zu
  /// verschlucken. Die Anzeige selbst zieht [_ladeNeu] nach, ausgeloest vom
  /// Kern — nicht diese Stelle.
  Future<void> _versuche(Future<Object?> Function() tun) async {
    try {
      await tun();
    } on BearbeitungNichtMoeglichException {
      letzterFehler = 'nichtMehrMoeglich';
      notifyListeners();
    } on MessageTooLargeException {
      letzterFehler = 'zuLang';
      notifyListeners();
    }
  }

  // ═══════════════════════════════════════════════════ Ordnung und Suche

  // ═══════════════════════════════════════════════════════ Tipp-Anzeige

  /// Wer gerade tippt: Kontakt → wann die Meldung verfaellt.
  final Map<String, DateTime> _tipptBis = {};

  /// Eine Meldung "tippt" gilt so lange. Kommt keine neue, hat die Gegenstelle
  /// aufgehoert oder die Verbindung verloren — beides soll nicht als "tippt
  /// noch" stehen bleiben.
  static const Duration tippDauer = Duration(seconds: 8);

  bool tipptGerade(String chatId) {
    final bis = _tipptBis[chatId];
    return bis != null && DateTime.now().isBefore(bis);
  }

  void _nimmTippen(TippMeldung t) {
    if (t.tippt) {
      _tipptBis[t.chatId] = DateTime.now().add(tippDauer);
      // Nach Ablauf einmal neu zeichnen, damit die Anzeige verschwindet.
      Timer(tippDauer, notifyListeners);
    } else {
      _tipptBis.remove(t.chatId);
    }
    notifyListeners();
  }

  DateTime? _letzteTippMeldung;
  String? _tipptIn;

  /// Vom Eingabefeld bei jeder Aenderung gerufen. Gedrosselt: hoechstens eine
  /// Meldung alle [tippAbstand], und ein "aufgehoert", wenn das Feld leer wird.
  ///
  /// DIE DROSSEL IST KEIN KOMFORT. Jede Meldung rueckt den Ratchet weiter, und
  /// jede, die der Relay verwirft, hinterlaesst beim Empfaenger eine Luecke,
  /// die libsignal ueberspringen muss — das geht, aber nur begrenzt oft.
  static const Duration tippAbstand = Duration(seconds: 5);

  void eingabeGeaendert(String chatId, String text) {
    if (!einstellungen.tippAnzeige) return;
    final jetzt = DateTime.now();
    if (text.isEmpty) {
      if (_tipptIn == chatId) {
        _tipptIn = null;
        _letzteTippMeldung = null;
        unawaited(core.meldeTippen(chatId, false));
      }
      return;
    }
    if (_tipptIn == chatId &&
        _letzteTippMeldung != null &&
        jetzt.difference(_letzteTippMeldung!) < tippAbstand) {
      return;
    }
    _tipptIn = chatId;
    _letzteTippMeldung = jetzt;
    unawaited(core.meldeTippen(chatId, true));
  }

  /// Die Frist, die fuer das gilt, was man in [chatId] schreibt — dieselbe
  /// Rechnung wie im Kern (`_fristFuer`), fuer die Anzeige.
  Duration? fristFuer(String chatId) {
    final eigen = Gruppe.istGruppenId(chatId)
        ? gruppeZu(chatId)?.fristSekunden
        : kontakte.where((k) => k.id == chatId).firstOrNull?.fristSekunden;
    if (eigen == null) return einstellungen.messageLifetime;
    return eigen == 0 ? null : Duration(seconds: eigen);
  }

  Future<void> setzeChatFrist(String chatId, Duration? frist) async {
    await core.setzeChatFrist(chatId, frist);
    await _ladeKontakteNeu();
  }

  /// Erstellt die Sicherung und laesst den Nutzer einen Ort waehlen.
  /// Rueckgabe: wo sie liegt, oder null, wenn abgebrochen.
  Future<String?> sichere({bool mitDateien = false}) async {
    final daten = await core.erstelleSicherung(mitDateien: mitDateien);
    final heute = DateTime.now();
    final name = 'bitdm-sicherung-'
        '${heute.year}-${heute.month.toString().padLeft(2, '0')}-'
        '${heute.day.toString().padLeft(2, '0')}.bitdm';
    // IM BROWSER ALS DOWNLOAD. Es gibt dort weder ein Zwischenverzeichnis
    // (path_provider hat keine Web-Umsetzung) noch den Speichern-Kanal. Und
    // gerade dort zaehlt die Sicherung: ohne App-Passwort ist die Identitaet
    // nach dem Neuladen weg, und der Verlauf kommt nur mit den zwoelf
    // Woertern UND einer Datenbank oder Sicherung zurueck.
    if (kIsWeb) {
      await browserDownload(daten, name);
      return name;
    }
    final tmp = await getTemporaryDirectory();
    final datei = File('${tmp.path}${Platform.pathSeparator}$name');
    await datei.writeAsBytes(daten, flush: true);
    try {
      return await dateien.speichere(datei.path, name);
    } finally {
      // Die Kopie im Zwischenspeicher ist verschluesselt, aber sie hat dort
      // nichts verloren, sobald sie ihren Ort hat.
      try {
        await datei.delete();
      } catch (_) {}
    }
  }

  /// Laesst eine Sicherung waehlen und spielt sie ein. Rueckgabe: wie viele
  /// Nachrichten dazukamen, oder null, wenn abgebrochen.
  Future<int?> spieleSicherungEin() async {
    // Im Browser ueber ein <input type=file>; der Kanal bitdm/dateien fehlt
    // dort (browser_zugang_web.dart).
    if (kIsWeb) {
      final daten = await browserDateiLesen();
      if (daten == null) return null;
      return _spieleEin(daten);
    }
    final gewaehlt = await dateien.waehlen();
    if (gewaehlt == null) return null;
    try {
      return await _spieleEin(await gewaehlt.datei.readAsBytes());
    } finally {
      await dateien.gibFrei(gewaehlt.zettel);
    }
  }

  Future<int?> _spieleEin(Uint8List daten) async {
    try {
      final n = await core.spieleSicherungEin(daten);
      await _ladeKontakteNeu();
      for (final id in verlaeufe.keys.toList()) {
        await _ladeNeu(id);
      }
      return n;
    } on SicherungPasstNichtException {
      letzterFehler = 'sicherungPasstNicht';
      notifyListeners();
      return null;
    }
  }

  /// Oeffnet die Notizen (legt sie beim ersten Mal an) und gibt ihre
  /// Kennung zurueck.
  Future<String> notizenOeffnen() async {
    final id = await core.oeffneNotizen();
    await _ladeKontakteNeu();
    return id;
  }

  bool istNotizen(String id) => id == meineAdresse;

  /// Ob dieses Geraet Sprachnachrichten aufnehmen kann — nur Android.
  bool spracheMoeglich = false;

  Future<void> pruefeSprache() async {
    spracheMoeglich = await Sprache.verfuegbar();
    notifyListeners();
  }

  /// Schickt eine fertige Aufnahme als Anhang.
  ///
  /// DIE AUFNAHME GEHT DANACH WEG, auch wenn der Versand scheitert. Sie liegt
  /// unverschluesselt im Speicher der App; der Kern legt sich fuer den
  /// eigenen Verlauf eine eigene Kopie an (bei einer Einmal-Ansicht gerade
  /// nicht) und liest die Quelle nur, solange `sendeAnhang` laeuft —
  /// spaetere Wiederholungen schicken nur die Anleitung, nicht die Datei
  /// (real_messenger_core.dart, `sendeAnhang`).
  Future<void> sendeSprachnachricht(String chatId, Aufnahme a, {bool einmal = false}) async {
    final datei = File(a.pfad);
    try {
      await anhangSenden(chatId, datei,
          name: sprachDateiname(DateTime.now()), groesse: await datei.length(), einmal: einmal);
    } finally {
      try {
        await datei.delete();
      } catch (_) {}
    }
  }

  /// Eine Einmal-Ansicht wurde angesehen — die Datei geht, die Blase bleibt.
  ///
  /// AUCH WENN INZWISCHEN GESPERRT WURDE. Dann ist der Kern zu; die Datei
  /// selbst ([pfad]) geht trotzdem sofort, und der Eintrag wird nach dem
  /// naechsten Entsperren nachgeholt ([_holeEinmalNach]).
  Future<void> verbraucheEinmal(String chatId, String messageId, {String? pfad}) async {
    try {
      if (gesperrt) throw StateError('gesperrt');
      await core.verbraucheEinmal(chatId, messageId);
      anhaenge[chatId] = await core.getAnhaenge(chatId);
      notifyListeners();
    } catch (_) {
      _einmalNachholen.add((chatId, messageId));
      if (pfad != null) {
        try {
          await File(pfad).delete();
        } catch (_) {}
      }
    }
  }

  /// Einmal-Ansichten, die angesehen wurden, waehrend der Kern zu war.
  final Set<(String, String)> _einmalNachholen = {};

  Future<void> _holeEinmalNach() async {
    for (final (chat, id) in _einmalNachholen.toList()) {
      try {
        await core.verbraucheEinmal(chat, id);
        _einmalNachholen.remove((chat, id));
        if (anhaenge.containsKey(chat)) anhaenge[chat] = await core.getAnhaenge(chat);
      } catch (_) {
        // Beim naechsten Entsperren wieder.
      }
    }
  }

  Future<void> setzeOrdnung(String chatId,
      {bool? angeheftet, bool? archiviert, bool? stumm}) async {
    await core.setzeOrdnung(chatId,
        angeheftet: angeheftet, archiviert: archiviert, stumm: stumm);
    await _ladeKontakteNeu();
  }

  /// Was die letzte Suche gefunden hat. Leer, solange nicht gesucht wird.
  List<Message> suchTreffer = const [];
  String suchText = '';

  Future<void> suche(String text) async {
    suchText = text;
    suchTreffer = text.trim().isEmpty ? const [] : await core.suche(text);
    // Eine langsamere, aeltere Suche darf die Treffer einer neueren nicht
    // ueberschreiben, wenn jemand schnell weitertippt.
    if (suchText != text) return;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════ Anhaenge

  /// chatId → messageId → Eintrag.
  final Map<String, Map<String, AnhangEintrag>> anhaenge = {};

  /// Was gerade laeuft, nach Nachrichtenkennung. Leer, sobald es fertig ist.
  final Map<String, AnhangFortschritt> fortschritt = {};

  AnhangEintrag? anhangZu(String chatId, String messageId) =>
      anhaenge[chatId]?[messageId];

  // ─────────────────────────────────────── Anhaenge lesen (seit 25.09.2026)
  //
  // Die Dateien unter anhaenge/ sind verschluesselt (core/anhang/
  // ruhe_datei.dart). [AnhangEintrag.pfad] taugt deshalb nicht mehr zum
  // Anzeigen — alles, was den Inhalt braucht, geht ueber die Methoden hier:
  //   * Vorschaubilder und Vollbild bis [vorschauGrenze]: im Speicher,
  //     ohne Datei ([anhangVorschau], [anhangBytes]);
  //   * alles andere: eine kurzlebige Klartextdatei ([anhangAlsDatei]), die
  //     der Aufrufer mit [gibAnhangFrei] zurueckgibt.

  /// Bis zu dieser Groesse werden Bilder im Speicher entschluesselt.
  static const int vorschauGrenze = 20 * 1024 * 1024;

  /// Wie viel entschluesselte Vorschau hoechstens im Speicher bleibt.
  static const int _vorschauSpeicher = 64 * 1024 * 1024;

  /// Die Vorschaubilder, aelteste zuerst (Dart-Maps behalten die
  /// Einfuegereihenfolge — das ist die LRU-Liste). Es liegt die ZUKUNFT
  /// darin und nicht die Bytes: ein FutureBuilder, der beim naechsten Aufbau
  /// dieselbe Zukunft bekommt, faengt nicht von vorne an und flackert nicht.
  final Map<String, Future<Uint8List?>> _vorschau = {};
  final Map<String, int> _vorschauBytes = {};
  static final Future<Uint8List?> _keineVorschau = Future.value(null);

  /// Klartextdateien, die an eine andere App gingen ("Oeffnen").
  final List<File> _extern = [];

  /// Das Bild eines geholten Anhangs, entschluesselt im Speicher — oder null
  /// (zu gross, unlesbar, gesperrt). Fuer die Vorschau in der Blase.
  ///
  /// Gibt fuer denselben Anhang dieselbe Zukunft zurueck, solange sie im
  /// Speicher liegt. Beim Sperren und Loeschen ist alles weg.
  Future<Uint8List?> anhangVorschau(String chatId, AnhangEintrag a) {
    if (kIsWeb || a.pfad == null || a.einmal || a.groesse > vorschauGrenze) {
      return _keineVorschau;
    }
    final schluessel = '$chatId|${a.senderId}|${a.messageId}|${a.pfad}';
    final da = _vorschau.remove(schluessel);
    if (da != null) {
      _vorschau[schluessel] = da; // wieder ans Ende: zuletzt benutzt
      return da;
    }
    final neu = _ladeVorschau(schluessel, chatId, a.messageId);
    _vorschau[schluessel] = neu;
    return neu;
  }

  Future<Uint8List?> _ladeVorschau(String schluessel, String chatId, String messageId) async {
    try {
      final b = await core.anhangInhalt(chatId, messageId, grenze: vorschauGrenze);
      // Inzwischen gesperrt (Liste geleert) oder verdraengt: nicht merken.
      if (_vorschau.containsKey(schluessel)) {
        _vorschauBytes[schluessel] = b.length;
        _kuerzeVorschau(schluessel);
      }
      return b;
    } catch (_) {
      // Bleibt als "keine Vorschau" gemerkt — sonst versuchte es jeder
      // Neuaufbau der Liste noch einmal.
      return null;
    }
  }

  void _kuerzeVorschau(String behalte) {
    var summe = _vorschauBytes.values.fold<int>(0, (a, b) => a + b);
    for (final k in _vorschau.keys.toList()) {
      if (summe <= _vorschauSpeicher) break;
      if (k == behalte) continue;
      _vorschau.remove(k);
      summe -= _vorschauBytes.remove(k) ?? 0;
    }
  }

  void _vergissVorschau() {
    _vorschau.clear();
    _vorschauBytes.clear();
  }

  /// Der Inhalt eines Anhangs im Speicher, OHNE ihn zu merken — fuer die
  /// Einmal-Ansicht, deren Bytes nach dem Ansehen nirgends bleiben sollen.
  Future<Uint8List?> anhangBytes(String chatId, String messageId,
      {int grenze = vorschauGrenze}) async {
    if (kIsWeb) return null;
    try {
      return await core.anhangInhalt(chatId, messageId, grenze: grenze);
    } catch (_) {
      return null;
    }
  }

  /// Der Klartext eines Anhangs als kurzlebige Datei, oder null (dann steht
  /// der Grund in [letzterFehler]). Zurueckgeben mit [gibAnhangFrei].
  Future<File?> anhangAlsDatei(String chatId, String messageId) async {
    if (kIsWeb) return null;
    try {
      return await core.entschluesselterAnhang(chatId, messageId);
    } on AnhangFehltException {
      // Der Kern hat den Zustand schon berichtigt — neu laden, damit die
      // Blase "holen" bzw. "nicht mehr da" zeigt statt eines toten "Oeffnen".
      letzterFehler = 'anhangFehlt';
      anhaenge[chatId] = await core.getAnhaenge(chatId);
      notifyListeners();
      return null;
    } catch (e) {
      letzterFehler = 'anhangUnlesbar';
      _merkeTechnisch(e);
      notifyListeners();
      return null;
    }
  }

  /// Loescht eine Klartextdatei aus [anhangAlsDatei]. Wirft nie.
  Future<void> gibAnhangFrei(File datei) async {
    try {
      await core.gibAnhangFrei(datei);
    } catch (_) {
      // Spaetestens beim Sperren oder naechsten Start weg.
    }
  }

  /// Reicht einen Anhang an die App des Systems weiter, die ihn oeffnen kann.
  ///
  /// Rueckgabe: ob eine App ihn nahm; null, wenn er sich nicht entschluesseln
  /// liess.
  ///
  /// DIE KLARTEXTKOPIE BLEIBT DANN LIEGEN — die andere App liest sie ueber
  /// den FileProvider, womoeglich erst nach einer Weile, und wann sie fertig
  /// ist, sagt sie nicht. Weg ist sie, sobald BitDM wieder in den
  /// Vordergrund kommt ([vordergrund]: wer zurueck ist, hat fertig
  /// angesehen), spaetestens beim Sperren oder beim naechsten Start.
  Future<bool?> anhangOeffnen(AnhangEintrag a) async {
    final klar = await anhangAlsDatei(a.chatId, a.messageId);
    if (klar == null) return null;
    final ging = await dateien.oeffne(klar.path, name: a.name);
    if (ging) {
      _extern.add(klar);
    } else {
      await gibAnhangFrei(klar);
    }
    return ging;
  }

  Future<void> _gibExterneFrei() async {
    final alle = _extern.toList();
    _extern.clear();
    for (final f in alle) {
      await gibAnhangFrei(f);
    }
  }

  /// Schickt eine Datei.
  ///
  /// Laeuft bei drei Gigabyte minutenlang. Der Verlauf bekommt die Nachricht
  /// erst, wenn alles oben ist — bis dahin traegt [fortschritt] den Stand
  /// unter [schwebendeKennung].
  Future<void> anhangSenden(String chatId, File datei,
      {String? name, int? groesse, bool einmal = false}) async {
    if (schwebendeKennung != null) {
      // EINER NACH DEM ANDEREN. Zwei gleichzeitige Uploads teilen sich die
      // Leitung, verdoppeln den Speicherbedarf und machen den Fortschritt
      // unlesbar. Der Nutzer merkt davon nur, dass der Knopf wartet.
      letzterFehler = 'anhangLaeuft';
      notifyListeners();
      return;
    }
    schwebendeKennung = '${DateTime.now().microsecondsSinceEpoch}';
    schwebenderName = name ?? datei.uri.pathSegments.last;
    schwebenderChat = chatId;
    notifyListeners();
    File? bereinigt;
    try {
      // METADATEN RAUS, bevor irgendetwas das Geraet verlaesst: GPS, Kamera,
      // Aufnahmezeit, Kommentare (siehe core/anhang/metadaten.dart). Der
      // Kern bekommt die bereinigte Kopie und einen neutralen Namen.
      //
      // Eine Sprachnachricht behaelt ihren Namen: an ihm erkennt der
      // Empfaenger, dass er einen Abspielknopf zeigen soll (sprache.dart).
      final sprache = name != null && sprachName.hasMatch(name);
      final pruefung = await _ohneMetadaten(datei);
      if (pruefung.datei != null) {
        bereinigt = pruefung.datei;
        datei = pruefung.datei!;
        groesse = await datei.length();
      }
      if (pruefung.name != null && !sprache) {
        // IMMER UNTER NEUTRALEM NAMEN, sobald es ein Bild oder Video ist —
        // auch wenn nichts zu entfernen war. "PXL_20260925_123456.jpg"
        // verraet Telefon und Sekunde der Aufnahme ohne ein einziges Byte
        // EXIF.
        name = pruefung.name;
        schwebenderName = name;
      }
      // NICHT STILL WEITER, WENN DIE METADATEN BLEIBEN. Vorher ging eine
      // Datei, die sich nicht bereinigen liess, einfach so hinaus — mit Ort
      // und Kamera. Jetzt entscheidet der Nutzer, und ohne Rueckfrage (etwa
      // ohne Oberflaeche) geht sie gar nicht.
      final warnung = pruefung.warnung;
      if (warnung != null && !sprache) {
        final frage = frageOhneBereinigung;
        final trotzdem = frage != null && await frage(warnung);
        if (!trotzdem) {
          if (frage == null) letzterFehler = 'metaNichtEntfernt';
          return;
        }
      }
      final m = await core.sendeAnhang(chatId, datei,
          name: name, groesse: groesse, einmal: einmal);
      // EINE NEUE LISTE, KEIN `.add`: dieselbe Falle wie in [senden] — die
      // Liste kommt vom Kern, und ob sie wachsen darf, entscheidet er. Der
      // Entwurfskern gibt eine unveraenderliche zurueck; das `.add` warf dort,
      // und der Anhang stand als "Fehler" da, obwohl er verschickt war
      // (gefunden am 25.09.2026 beim Test der Sprachnachrichten).
      _haengeEigeneAn(chatId, m);
      anhaenge[chatId] = await core.getAnhaenge(chatId);
    } on AnhangZuGross catch (e) {
      letzterFehler = 'anhangZuGross:${e.groesse}:${e.grenze}';
    } on LagerVoll {
      letzterFehler = 'lagerVoll';
    } catch (e) {
      letzterFehler = _anhangFehler(e);
      _merkeTechnisch(e);
    } finally {
      // Die bereinigte Kopie hat ihren Zweck erfuellt — der Kern hat sie
      // gelesen und verschluesselt.
      if (bereinigt != null) {
        try {
          await bereinigt.delete();
        } catch (_) {}
      }
      fortschritt.remove(schwebendeKennung);
      schwebendeKennung = null;
      schwebenderName = null;
      schwebenderChat = null;
      notifyListeners();
    }
  }

  /// Fragt, ob eine Datei trotz verbliebener Metadaten hinausgehen soll.
  /// [grund] ist 'metaZuGross' oder 'metaFehler'. Von der Oberflaeche gesetzt;
  /// ohne sie geht eine solche Datei nicht hinaus.
  Future<bool> Function(String grund)? frageOhneBereinigung;

  /// Groesste Datei, die als Bild bereinigt wird — sie liegt dafuer einmal
  /// ganz im Speicher.
  static const int bildGrenze = 40 * 1024 * 1024;

  /// Groesstes Video: dort wird an Ort und Stelle ueberschrieben (`vorOrt`),
  /// es liegt also auch nur EINE Kopie im Speicher, nicht zwei.
  static const int videoGrenze = 300 * 1024 * 1024;

  /// Prueft [datei] auf Metadaten.
  ///
  /// Rueckgabe:
  ///   * `datei` — eine bereinigte Kopie, oder null, wenn es keine braucht;
  ///   * `name`  — ein neutraler Name, sobald es ein Bild oder Video ist;
  ///   * `warnung` — 'metaZuGross' oder 'metaFehler', wenn es ein Bild oder
  ///     Video ist, dessen Metadaten NICHT entfernt werden konnten.
  ///
  /// Ueber [bereinige] und nicht mehr ueber `ohneMetadaten`: das gab null
  /// zurueck, sowohl wenn nichts zu tun war als auch wenn sich die Datei
  /// nicht zerlegen liess — und im zweiten Fall ging sie still MIT Ort und
  /// Kamera hinaus.
  Future<({File? datei, String? name, String? warnung})> _ohneMetadaten(File datei) async {
    const nichts = (datei: null, name: null, warnung: null);
    Uint8List kopf;
    int laenge;
    try {
      laenge = await datei.length();
      final zugriff = await datei.open();
      try {
        kopf = await zugriff.read(256);
      } finally {
        await zugriff.close();
      }
    } catch (_) {
      // Nicht einmal der Anfang ist lesbar — dann scheitert gleich der
      // Versand selbst mit einer eigenen Meldung.
      return nichts;
    }
    if (!istBereinigbar(kopf)) return nichts;
    final zufall = Random.secure().nextInt(0x10000);
    final neutral = neutralerBildname(kopf, zufall);
    final video = istVideo(kopf);
    if (laenge > (video ? videoGrenze : bildGrenze)) {
      return (datei: null, name: neutral, warnung: 'metaZuGross');
    }
    try {
      final bytes = await datei.readAsBytes();
      switch (bereinige(bytes, vorOrt: true)) {
        case Bereinigt(bytes: final sauber):
          final name = neutralerBildname(sauber, zufall);
          final ordner = await getTemporaryDirectory();
          final ziel = File('${ordner.path}${Platform.pathSeparator}'
              'bitdm-rein-${DateTime.now().microsecondsSinceEpoch}-$name');
          await ziel.writeAsBytes(sauber, flush: true);
          return (datei: ziel, name: name, warnung: null);
        case NichtsZuTun():
          // Schon sauber: das Original geht, aber unter neutralem Namen.
          return (datei: null, name: neutral, warnung: null);
        case Unlesbar():
          // Bekanntes Format, nicht sicher zerlegbar: die Metadaten koennen
          // noch drin sein. Das entscheidet der Nutzer, nicht diese Stelle.
          return (datei: null, name: neutral, warnung: 'metaFehler');
        case NichtUnterstuetzt():
          // Der Kopf sah nach Bild oder Video aus, die ganze Datei nicht.
          return nichts;
      }
    } catch (_) {
      // Lesen oder Schreiben der Kopie scheiterte — bereinigt ist dann nichts.
      return (datei: null, name: neutral, warnung: 'metaFehler');
    }
  }

  /// Holt einen angekuendigten Anhang.
  Future<void> anhangHolen(String chatId, String messageId) async {
    try {
      await core.holeAnhang(chatId, messageId);
    } on LagerLeer {
      // Kein Fehler zum Anzeigen: der Zustand steht jetzt auf "weg", und die
      // Blase sagt es selbst. Eine zweite Meldung darueber waere Laerm.
    } catch (e) {
      letzterFehler = _anhangFehler(e);
      _merkeTechnisch(e);
    } finally {
      anhaenge[chatId] = await core.getAnhaenge(chatId);
      notifyListeners();
    }
  }

  /// Waehrend eines Versands: die Ersatzkennung, unter der der Fortschritt
  /// laeuft, bevor es die Nachricht gibt.
  ///
  /// Die Nachricht entsteht erst, wenn ALLES oben ist — bei drei Gigabyte also
  /// nach Minuten. Ohne diese drei Felder saehe der Nutzer waehrenddessen eine
  /// unveraenderte Unterhaltung und wuesste nicht, ob ueberhaupt etwas
  /// passiert.
  String? schwebendeKennung;
  String? schwebenderName;
  String? schwebenderChat;

  /// Der laufende Verbindungstest: was bisher geprueft wurde.
  ///
  /// Waechst waehrend des Laufs, damit der Nutzer sieht, dass etwas passiert —
  /// bei einer Zeitgrenze von zwoelf Sekunden je Schritt waere ein Bildschirm,
  /// der eine halbe Minute nichts tut, nicht von einem haengengebliebenen zu
  /// unterscheiden.
  final List<Schritt> testSchritte = [];
  bool testLaeuft = false;

  Future<void> verbindungPruefen() async {
    if (testLaeuft) return;
    testLaeuft = true;
    testSchritte.clear();
    notifyListeners();

    final k = core;
    if (k is! RealMessengerCore) {
      testLaeuft = false;
      notifyListeners();
      return;
    }
    try {
      await Verbindungstest(k.testUmgebung).lauf(beiSchritt: (s) {
        testSchritte.add(s);
        notifyListeners();
      });
    } finally {
      testLaeuft = false;
      notifyListeners();
    }
  }

  /// Was zuletzt technisch schiefging — unuebersetzt, zum Weitergeben.
  ///
  /// WARUM DAS GEBRAUCHT WIRD: die uebersetzten Meldungen fassen sehr
  /// verschiedene Ursachen zu einem Satz zusammen. "That did not go through"
  /// steht sowohl fuer einen Verbindungsabbruch als auch fuer einen Fehler
  /// beim Lesen der Datei. Der Nutzer soll den einen Satz sehen; wer den
  /// Fehler beheben will, braucht den Rest. Er steht im Verbindungstest.
  ///
  /// NUR DIE ART UND DIE MELDUNG, keine Kennungen, keine Adressen, keine
  /// Dateinamen: der Bildschirm wird abfotografiert und weitergeschickt.
  String? letzteTechnischeMeldung;

  void _merkeTechnisch(Object e) {
    final art = e.runtimeType.toString();
    var text = e.toString();
    if (text.startsWith('$art: ')) text = text.substring(art.length + 2);
    if (text.length > 160) text = '${text.substring(0, 160)}…';
    letzteTechnischeMeldung = '$art — $text';
  }

  /// Bringt einen Fehler in eine Form, die die Oberflaeche uebersetzen kann.
  ///
  /// Die Meldung der Ausnahme selbst NICHT durchreichen: sie ist auf Englisch,
  /// technisch, und im Fall des Lagers traegt sie eine Kennung — also etwas,
  /// das in keiner Bildschirmaufnahme stehen soll.
  static String _anhangFehler(Object e) {
    if (e is NurNahbereichException) return 'nurNahbereich';
    // Im Browser: der Anhang-Weg braucht Dateien (dart:io), und die werfen
    // dort UnsupportedError. Kein Netzfehler — "pruef die Verbindung" waere
    // die falsche Auskunft.
    if (e is UnsupportedError) return 'anhangWeb';
    final t = e.toString();
    if (t.contains('Tagesmenge')) return 'tagesmenge';
    if (e is AnhangKaputt) return 'anhangKaputt';
    if (e is LagerException || e is RelayException) return 'anhangNetz';
    return 'anhangFehler';
  }

  Future<void> senden(String id, String text,
      {String? antwortAuf, DateTime? um, bool geheim = false}) async {
    final sauber = text.trim();
    if (sauber.isEmpty) return;
    try {
      final m =
          await core.sendMessage(id, sauber, antwortAuf: antwortAuf, um: um, geheim: geheim);
      // NICHT `.add(...)` AUF DIE LISTE DES KERNS.
      //
      // Was in `verlaeufe` liegt, kommt aus `core.history(...)` — und ob das
      // eine wachsende Liste ist, entscheidet der Kern, nicht diese Stelle.
      // Gibt er eine unveraendlerliche zurueck (was ein Kern durchaus tun
      // darf, und die Attrappe tut es), scheitert das Anhaengen mit einem
      // Fehler, der weder gefangen noch angezeigt wird: die Nachricht ist
      // gesendet, aber der Verlauf zeigt sie nicht.
      //
      // Eine neue Liste zu bauen kostet bei Chatlaengen nichts und macht die
      // Annahme ueberfluessig.
      _haengeEigeneAn(id, m);
      notifyListeners();
    } on MessageTooLargeException {
      letzterFehler = 'zuLang';
      notifyListeners();
    }
  }

  /// Setzt eine Meldung, die die Oberflaeche uebersetzen kann.
  ///
  /// Nimmt einen SCHLUESSEL und keinen fertigen Satz: die Sprache waehlt die
  /// Oberflaeche, und ein hier zusammengebauter deutscher Text stuende auch
  /// in der englischen Fassung.
  void setzeFehler(String schluessel) {
    letzterFehler = schluessel;
    notifyListeners();
  }

  /// Vergisst die letzte Fehlermeldung.
  ///
  /// Damit eine Meldung verschwindet, sobald der Nutzer etwas dagegen tut —
  /// eine, die stehen bleibt, waehrend man sie schon behoben hat, verwirrt
  /// mehr als sie hilft.
  void vergissFehler() {
    if (letzterFehler == null) return;
    letzterFehler = null;
    notifyListeners();
  }

  /// Setzt eine Fehlermeldung, die nicht aus einem Kernaufruf kommt — etwa
  /// "Dateien gehen im Browser nicht", bevor ueberhaupt etwas versucht wird.
  void meldeFehler(String schluessel) {
    letzterFehler = schluessel;
    notifyListeners();
  }

  Future<SafetyNumber> pruefnummer(String id) => core.getSafetyNumber(id);

  // ══════════════════════════════════════════════════════════ Einstellungen

  AppPreferences einstellungen = const AppPreferences();

  Future<void> _ladeEinstellungen() async {
    einstellungen = await core.getPreferences();
    // Die Sperre wird beim Start in MainActivity.onCreate gesetzt, bevor
    // ueberhaupt gezeichnet wird. Hier wird sie nur an die gespeicherte
    // Einstellung angeglichen — moeglicherweise also geloest.
    await _wendeSchutzAn();
  }

  Future<void> setzeEinstellungen(AppPreferences neu) async {
    await core.setPreferences(neu);
    einstellungen = neu;
    await _wendeSchutzAn();
  }

  // ══════════════════════════════════════════════════ Screenshot-Schutz

  /// Ob der Schutz WIRKLICH greift — also ob die Plattform "gesetzt" gemeldet
  /// hat. Am Rechner ohne Gegenseite bleibt das false, und der Hinweis
  /// "Screenshot-Schutz aktiv" erscheint dort nicht mehr, nur weil der
  /// Schalter an ist.
  bool screenshotSchutzAktiv = false;

  /// Wie viele geheime Ansichten gerade offen sind (Woerter, Teile,
  /// Einmal-Bild). Solange es eine gibt, gilt der Schutz — gleich, was in den
  /// Einstellungen steht.
  int _geheimOffen = 0;

  /// Meldet eine geheime Ansicht an ([sichtbar] true) oder ab.
  ///
  /// GEZAEHLT, nicht geschaltet: ein Einmal-Bild, das waehrend der offenen
  /// Woerter geschlossen wird, darf den Schutz nicht fuer die Woerter
  /// mitloesen.
  Future<void> geheimnisSichtbar(bool sichtbar) async {
    _geheimOffen = max(0, _geheimOffen + (sichtbar ? 1 : -1));
    await _wendeSchutzAn();
  }

  Future<void> _wendeSchutzAn() async {
    final soll = einstellungen.blockScreenshots || _geheimOffen > 0;
    final ok = await Fenster.screenshotSperre(soll);
    screenshotSchutzAktiv = soll && ok;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════ In der Naehe

  /// Null in Tests und ueberall dort, wo es kein Bluetooth gibt.
  ///
  /// Nachtraeglich gesetzt statt im Konstruktor verlangt: `flutter test` hat
  /// keine Plattformkanaele, und ein Pflichtfeld haette jeden Zustandstest an
  /// Bluetooth gebunden.
  Nahfunk? funk;

  /// Was das Geraet ueber Bluetooth sagt. Null, solange nicht gefragt wurde.
  ///
  /// Wird bei jedem Oeffnen der Einstellungen neu geholt: Bluetooth laesst
  /// sich ausserhalb der App umschalten, und eine gemerkte Antwort waere
  /// spaetestens beim zweiten Hinsehen falsch.
  Funkzustand? funkzustand;

  /// Ob Android die Rechteabfrage dauerhaft dichtgemacht hat.
  ///
  /// Getrennt vom Zustand, weil es sich nur durch eine ABFRAGE herausfinden
  /// laesst — `checkSelfPermission` sagt bloss "fehlt", nicht "fehlt und wird
  /// nie wieder gefragt". Die Oberflaeche muss den Unterschied kennen, sonst
  /// bietet sie einen Knopf an, bei dem sichtbar nichts passiert.
  bool rechteEndgueltigWeg = false;

  Future<void> pruefeFunk() async {
    final f = funk;
    if (f == null) return;
    try {
      funkzustand = await f.zustand();
    } on FunkFehler {
      funkzustand = null;
    }
    notifyListeners();
  }

  /// Fragt die Bluetooth-Rechte ab und aktualisiert den Zustand.
  ///
  /// Gibt zurueck, ob es jetzt geht — der Aufrufer schaltet nur dann den
  /// Schalter um. Einen Schalter umzulegen, dessen Voraussetzung fehlt, waere
  /// eine Einstellung ohne Wirkung.
  Future<bool> erlaubeFunk() async {
    final f = funk;
    if (f == null) return false;
    try {
      final lage = await f.fordereRechte();
      rechteEndgueltigWeg = lage == Rechtelage.dauerhaftAbgelehnt;
      await pruefeFunk();
      return lage == Rechtelage.erteilt;
    } on FunkFehler {
      return false;
    }
  }

  /// Ob dieser Kontakt einen sieht — und man ihn.
  Future<void> setzeAnwesenheit(String kontaktId, bool zeigen) async {
    await core.setContactPresence(kontaktId, zeigen);
    // Die Liste selbst neu holen statt den einen Eintrag zu ersetzen: sonst
    // stehen hier zwei Wahrheiten, und beim naechsten Nachladen gewinnt die
    // aus der Datenbank ohnehin.
    kontakte = await core.getContacts();
    notifyListeners();
  }

  Future<void> oeffneSystemeinstellungen() async {
    try {
      await funk?.oeffneEinstellungen();
    } on FunkFehler {
      // Kein Grund, irgendetwas anzuhalten: es gibt Geraete ohne diesen
      // Bildschirm, und der Nutzer findet ihn dann von Hand.
    }
  }

  /// Raeumt Abgelaufenes weg und meldet, ob sich etwas geaendert hat.
  ///
  /// Wird beim Start und bei jedem Zurueckkommen in den Vordergrund gerufen —
  /// sonst saehe der Nutzer nach dem Aufwachen noch Nachrichten, die laengst
  /// haetten verschwinden sollen.
  Future<void> raeumeAbgelaufeneWeg() async {
    if (!hatIdentitaet || gesperrt) return;
    final int weg;
    try {
      weg = await core.purgeExpiredMessages();
    } on MessengerException {
      return;
    }
    _planeVerfall();
    if (weg == 0) return;
    // Betroffene Verlaeufe neu laden statt zu raten, welche es traf.
    for (final id in verlaeufe.keys.toList()) {
      verlaeufe[id] = await core.getMessages(id);
    }
    // UND ALLES, WAS DIE VERSCHWUNDENEN NOCH ZEIGEN KOENNTE: der Zaehler, die
    // Sterne (Klartext!) und die Suchtreffer. Vorher standen verschwundene
    // Nachrichten in der Suche und unter ★ weiter da.
    await _ladeUngelesen();
    if (sterne.isNotEmpty) sterne = await core.sterne();
    if (suchText.trim().isNotEmpty) {
      suchTreffer = await core.suche(suchText);
    }
    notifyListeners();
  }

  // ═══════════════════════════════════════ Verschwinden im Vordergrund

  Timer? _verfallTakt;

  /// Woher die naechste Faelligkeit kommt. Nur der echte Kern kennt sie
  /// (`naechsterVerfall` steht nicht im eingefrorenen Vertrag); in Tests
  /// hereinreichbar.
  @visibleForTesting
  DateTime? Function()? verfallsQuelle;

  DateTime? get _naechsterVerfall {
    final quelle = verfallsQuelle;
    if (quelle != null) return quelle();
    final c = core;
    return c is RealMessengerCore ? c.naechsterVerfall : null;
  }

  /// Stellt einen Wecker auf die naechste Nachricht, die verschwinden soll.
  ///
  /// BIS HIERHER RAEUMTE NUR DER START UND DAS ZURUECKKOMMEN AUF. Wer die App
  /// offen liess, sah eine Nachricht mit "1 Stunde" auch nach drei Stunden
  /// noch — bis er die App einmal weglegte.
  void _planeVerfall() {
    _verfallTakt?.cancel();
    _verfallTakt = null;
    if (!hatIdentitaet || gesperrt || !_imVordergrund) return;
    final DateTime? naechster;
    try {
      naechster = _naechsterVerfall;
    } catch (_) {
      return;
    }
    if (naechster == null) return;
    var rest = naechster.toUtc().difference(DateTime.now().toUtc());
    // Eine Sekunde Luft: der Kern loescht erst, was WIRKLICH vorbei ist.
    if (rest < Duration.zero) rest = Duration.zero;
    _verfallTakt = Timer(rest + const Duration(seconds: 1), () {
      _verfallTakt = null;
      unawaited(raeumeAbgelaufeneWeg());
    });
  }

  // ══════════════════════════════════════════════════════════════════ Loeschen

  /// Loescht alles. Unwiderruflich, ausser man hat die zwoelf Woerter.
  ///
  /// Bis zum 25.07.2026 hat der Knopf in der Oberflaeche nur Anzeigewerte
  /// zurueckgesetzt. Solange die App ein Entwurf war, fiel das nicht auf;
  /// sobald echte Nachrichten dahinterliegen, ist ein Knopf, der "alles
  /// geloescht" sagt und es nicht tut, schlimmer als gar keiner.
  Future<void> allesLoeschen() async {
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    _fehlversuche = 0;
    unawaited(Benachrichtigungen.instanz.nimmWarnungWeg());

    await core.wipeEverything();
    // DIE FACHDATEI AUCH HIER, nicht nur im Kern. Der echte Kern loescht sie
    // ueber seinen Schluesselspeicher mit — aber "alles loeschen" ist genau
    // die Stelle, an der ein vergessener Rest am teuersten ist: eine Fachdatei
    // nach dem Panik-Passwort verriete, dass hier eine gesperrte Identitaet
    // war. Doppelt geloescht schadet nicht.
    await tresor?.delete();
    faktoren = const [];

    hatIdentitaet = false;
    // Nach dem Loeschen gibt es nichts mehr, das gesperrt sein koennte — auch
    // wenn die Fernloeschung waehrend der Sperre ablief.
    gesperrt = false;
    meineAdresse = '';
    kontakte = const [];
    gruppen = const [];
    verlaeufe.clear();
    reaktionen.clear();
    stimmen.clear();
    frischePhrase = null;
    letzterFehler = null;
    letzteTechnischeMeldung = null;
    verbindung = ConnectionState.disconnected;
    // ALLES, WAS DIE OBERFLAECHE NOCH IM KLARTEXT HIELT. Vorher blieben
    // Sterne, Suchtreffer, Verteilerlisten und die Einstellungen der alten
    // Identitaet stehen — nach dem Panik-Passwort sah die "frisch
    // installierte" App dann die Themenwahl und die Sterne von vorher.
    _vergissAngezeigtes();
    _fernTakt?.cancel();
    _fernTakt = null;
    fernloeschung = const Fernloeschung();
    fernFrist = null;
    _fernNachfrist = false;
    _verbindeNachAbbruch = false;
    _einmalNachholen.clear();
    offeneUnterhaltung = null;
    schwebendeKennung = null;
    schwebenderName = null;
    schwebenderChat = null;
    _ungelesen = 0;
    _weggelegtUm = null;
    _tipptIn = null;
    _letzteTippMeldung = null;
    unawaited(Benachrichtigungen.instanz.raeumeAuf());
    einstellungen = const AppPreferences();
    await _wendeSchutzAn();
    notifyListeners();
  }

  /// Ob [dispose] schon lief. Ein Kernereignis, das danach noch ankommt
  /// (ein Nachladen, das vor dem Abbau begann), soll ins Leere laufen und
  /// nicht mit "used after being disposed" werfen.
  bool _entsorgt = false;

  @override
  void notifyListeners() {
    if (_entsorgt) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _entsorgt = true;
    _wiederverbindung?.cancel();
    _wiederverbindung = null;
    _verfallTakt?.cancel();
    _empfangsTimer?.cancel();
    _fernTakt?.cancel();
    for (final a in _abos) {
      unawaited(a.cancel());
    }
    _abos.clear();
    unawaited(core.dispose());
    super.dispose();
  }
}

/// Formatiert eine 56-stellige Adresse in Vierergruppen — dieselbe
/// Darstellung, die der Entwurf schon benutzt hat.
/// Ein Beispiel im GENAU SELBEN Format, in dem die App Adressen zeigt und
/// kopiert.
///
/// Es stand hier als fester Text "B3XK-7QMD-2FTV-…" — mit Strichen, waehrend
/// die Zwischenablage die rohe Adresse ohne Striche lieferte. Wer kopierte und
/// einfuegte, sah etwas anderes als das Beispiel und hielt die eingefuegte
/// Adresse fuer falsch. Jetzt kommt es durch dieselbe Funktion wie alles
/// andere und kann nicht mehr auseinanderlaufen.
final String beispielAdresse =
    '${adresseFormatiert('b3xk7qmd2ftv9sln4hrw6jyc8pzb5nkq7wdm3xrv')}…';

String adresseFormatiert(String a) {
  final sb = StringBuffer();
  for (var i = 0; i < a.length; i += 4) {
    if (i > 0) sb.write('-');
    sb.write(a.substring(i, i + 4 > a.length ? a.length : i + 4).toUpperCase());
  }
  return sb.toString();
}
