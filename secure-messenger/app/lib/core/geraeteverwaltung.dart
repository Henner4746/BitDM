// geraeteverwaltung.dart — Geraeteliste, Abmeldung, Beitritt (Teil des Kerns).
//
// WAS HIER PASSIERT, in einem Absatz: jede Installation hat einen eigenen
// Geraeteschluessel, und die Identitaet fuehrt beim Relay eine signierte
// Liste ihrer Geraete. Wer nicht darin steht, kommt nicht durch die Anmeldung
// des Relays — und jede Gegenstelle verschluesselt nur an gelistete Geraete.
// Abmelden heisst: eine neue Fassung ohne das Geraet veroeffentlichen. Das
// abgemeldete Geraet sieht die signierte Liste, entfernt die zwoelf Woerter
// von sich und bleibt draussen. Der Vertrag steht in docs/GERAETEABMELDUNG.md
// §8; das Gegenstueck des Relays in relay_server.py (setze_geraeteliste).
//
// EIN TEIL VON real_messenger_core.dart (`part of`), weil hier fast alles am
// Zustand des Kerns haengt — Datenbank, Signal-Speicher, Relay, Kennung. Eine
// eigene Klasse braeuchte all das als Durchreiche.
//
// ALTE RELAYS UND DIE ATTRAPPEN DER TESTS kennen keine Geraeteliste. Fuer sie
// gilt alles wie vorher: ob der Relay Geraete ueberhaupt kennt, fragt der Kern
// mit `geraeteliste()` (das kennen alle), und nur wenn ja, fasst er die neuen
// Aufrufe an. Hat er fuer eine Adresse aber EINMAL eine Liste gesehen, faellt
// er fuer sie nie mehr zurueck — sonst koennte ein boeser Relay sich einfach
// als alt ausgeben.

part of 'real_messenger_core.dart';

/// Wie lange ein Beitrittscode gilt und wie lange ein neues Geraet wartet.
const Duration _beitrittsFrist = Duration(minutes: 10);

/// Wie oft das wartende Geraet nachsieht, ob es aufgenommen wurde, und wie
/// oft das bestaetigende nach Anfragen schaut (zusaetzlich zum Hinweis des
/// Relays).
const Duration _beitrittsTakt = Duration(seconds: 2);

/// Wie oft hoechstens die Liste einer Gegenstelle nachgeladen wird, weil
/// Post von einem unbekannten Geraet kam.
const Duration _listenNachfrage = Duration(minutes: 1);

extension Geraeteverwaltung on RealMessengerCore {
  // ═══════════════════════════════════════════════════════ fuer die Oberflaeche

  /// Wo dieses Geraet in der Liste seiner Identitaet steht.
  ListenStand get geraeteStand => _geraeteStand;

  /// Feuert bei jeder Aenderung an Stand, Liste oder laufendem Beitritt.
  Stream<ListenStand> get geraeteGeaendert => _geraeteCtl.stream;

  /// Ob die eigene Adresse eine Geraeteliste hat (und der Relay sie kennt).
  bool get hatGeraeteliste => _eigeneListeOderNull() != null;

  /// Die eigenen Geraete, dieses zuerst.
  List<GeraetAnzeige> get eigeneGeraete {
    final liste = _eigeneListeOderNull();
    final schluessel = _infoSchluessel;
    if (liste == null) return const [];
    final gs = _eigenerSchluesselOderNull();
    final alle = [
      for (final e in liste.geraete)
        () {
          final info = schluessel == null
              ? null
              : GeraeteInfo.entschluessle(schluessel, e.info);
          return GeraetAnzeige(
            id: e.id,
            istDieses: e.id == geraetId && gs != null && _gleicheBytes(e.schluessel, gs),
            name: info?.name,
            seit: info?.seit,
          );
        }(),
    ];
    alle.sort((a, b) => a.istDieses == b.istDieses
        ? a.id.compareTo(b.id)
        : (a.istDieses ? -1 : 1));
    return alle;
  }

  /// Der Code, den dieses Geraet gerade fuer einen Beitritt zeigt — oder null.
  String? get beitrittscode {
    final c = _hinzufuegeCode;
    if (c == null) return null;
    if (DateTime.now().isAfter(_hinzufuegeBis!)) return null;
    return Beitrittscode.zeige(c);
  }

  /// Die Kennung des Geraets, das zuletzt ueber einen Code hinzukam.
  int? get zuletztHinzugefuegt => _zuletztHinzugefuegt;

  /// Wann und von welchem Geraet dieses abgemeldet wurde — nur im laufenden
  /// Prozess (die Woerter, und mit ihnen die Datenbank, sind danach weg).
  ({DateTime zeit, String? von})? get abmeldung => _abmeldung;

  // ═══════════════════════════════════════════════════════ Aktionen

  /// Nimmt ein anderes eigenes Geraet aus der Liste. Der Relay trennt es
  /// sofort; es sieht die neue Fassung und entfernt die Woerter von sich.
  Future<void> meldeGeraetAb(int id) async {
    if (id == geraetId) return meldeDiesesGeraetAb();
    await _veroeffentliche((alt) => [
          for (final e in alt.geraete)
            if (e.id != id) e,
        ]);
  }

  /// Nur noch dieses Geraet bleibt.
  Future<void> meldeAlleAnderenAb() async {
    await _veroeffentliche((alt) => [
          for (final e in alt.geraete)
            if (e.id == geraetId) e,
        ]);
  }

  /// Dieses Geraet geht — etwa vor dem Verkauf. Danach ist es abgemeldet wie
  /// jedes andere: die Woerter sind weg, die Datenbank bleibt verschluesselt.
  Future<void> meldeDiesesGeraetAb() async {
    final neu = await _veroeffentliche((alt) => [
          for (final e in alt.geraete)
            if (e.id != geraetId) e,
        ]);
    await _wirdAbgemeldet(neu);
  }

  /// Zeigt einen Beitrittscode fuer ein neues Geraet (§8.5). Wer ihn auf dem
  /// neuen Geraet eintippt, wird aufgenommen — und nur der.
  Future<String> starteHinzufuegen() async {
    if (_geraeteStand != ListenStand.mitglied) {
      throw StateError('nur ein Geraet der Liste kann Geraete hinzufuegen');
    }
    beendeHinzufuegen();
    _hinzufuegeCode = Beitrittscode.neu();
    _hinzufuegeBis = DateTime.now().add(_beitrittsFrist);
    _zuletztHinzugefuegt = null;
    _hinzufuegeTakt =
        Timer.periodic(_beitrittsTakt, (_) => unawaited(_pruefeBeitritte()));
    unawaited(_pruefeBeitritte());
    _meldeGeraete();
    return Beitrittscode.zeige(_hinzufuegeCode!);
  }

  void beendeHinzufuegen() {
    _hinzufuegeTakt?.cancel();
    _hinzufuegeTakt = null;
    final c = _hinzufuegeCode;
    if (c != null) c.fillRange(0, c.length, 0);
    _hinzufuegeCode = null;
    _hinzufuegeBis = null;
    _meldeGeraete();
  }

  /// Dieses Geraet bittet mit dem Code eines anderen um Aufnahme.
  ///
  /// Wirft [FormatException], wenn [eingabe] kein Code ist. Danach wartet es
  /// ([ListenStand.wartetAufBestaetigung]) und verbindet sich von selbst,
  /// sobald es in der Liste steht.
  Future<void> trittBei(String eingabe) async {
    final code = Beitrittscode.lies(eingabe);
    if (code == null) throw const FormatException('kein Beitrittscode');
    final store = _store;
    if (store == null) throw const NotInitializedException();
    final relay = _httpRelay();
    final liste = _nimmListe(myId, await relay.holeGeraeteliste(myId));
    if (liste == null) throw const RelayException('keine Geraeteliste');
    await _sorgeFuerFreieKennung(relay, liste);
    final anfrage = Beitrittsanfrage.unterschreibe(
      identitaet: store.identity,
      geraeteschluessel: await _gibGeraeteschluessel(),
      deviceId: geraetId,
      info: _eigeneInfo(),
      code: code,
    );
    code.fillRange(0, code.length, 0);
    await relay.beantrageBeitritt(anfrage);
    _beitrittBis = DateTime.now().add(_beitrittsFrist);
    _setzeListenStand(ListenStand.wartetAufBestaetigung);
    _beitrittsTimer?.cancel();
    _beitrittsTimer = Timer.periodic(
        _beitrittsTakt, (_) => unawaited(_schaueObAufgenommen()));
  }

  void brichBeitrittAb() {
    _beitrittsTimer?.cancel();
    _beitrittsTimer = null;
    if (_geraeteStand == ListenStand.wartetAufBestaetigung) {
      _setzeListenStand(ListenStand.beitrittNoetig);
    }
  }

  /// "Alle anderen Geraete abmelden" auf einem Geraet, das nicht in der Liste
  /// steht — der Weg, wenn das Telefon weg ist und kein anderes Geraet mehr
  /// da. Dafuer genuegen die Woerter; es ist laut: jedes andere Geraet faellt
  /// heraus und merkt es.
  ///
  /// EHRLICH: wer die zwoelf Woerter kennt, kann genau dasselbe tun. Dann
  /// hilft nur eine neue Identitaet (docs/GERAETEABMELDUNG.md §4).
  Future<void> setzeZurueck() async {
    final store = _store;
    if (store == null) throw const NotInitializedException();
    final relay = _httpRelay();
    brichBeitrittAb();
    for (var versuch = 0; versuch < 2; versuch++) {
      final alt = _nimmListe(myId, await relay.holeGeraeteliste(myId));
      if (alt != null) await _sorgeFuerFreieKennung(relay, alt);
      final gs = await _gibGeraeteschluessel();
      final neu = Geraeteliste.unterschreibe(
        identitaet: store.identity,
        geraeteschluessel: gs,
        epoche: (alt?.epoche ?? 0) + 1,
        geraete: [GeraeteEintrag(geraetId, rohOeffentlich(gs), _eigeneInfo())],
        unterzeichner: geraetId,
      );
      try {
        await relay.setzeGeraeteliste(neu);
      } on RelayException catch (e) {
        if (e.statusCode == 409 && versuch == 0) continue;
        rethrow;
      }
      _uebernimmEigeneListe(neu);
      _wirdMitglied(neu);
      _abgewiesen = false;
      unawaited(connect());
      return;
    }
  }

  // ═══════════════════════════════════════════════════════ beim Verbinden

  /// Die eigene Liste, VOR der Anmeldung (§8.7). Rueckgabe: ob es weitergeht.
  ///
  /// Ohne Liste beim Relay: anlegen, mit sich allein. Kennt der Relay keine
  /// Listen: weiter wie bisher. Steht dieses Geraet drin: weiter, mit
  /// Geraeteschluessel. Steht es nicht drin: abgemeldet (wenn es schon einmal
  /// drin stand und die Liste neuer ist) oder Beitritt noetig.
  Future<bool> _pruefeEigeneListe(RelayClient relay) async {
    // Wer seine Liste schon kennt, weiss, dass dieser Relay Listen fuehrt —
    // die Vorfrage unten kostete dann nur einen Umlauf und eine Marke der
    // Herkunftsbremse je Verbindung.
    if (_listeVon(myId) != null || _relayKenntGeraete) {
      return _mitRelayMitGeraeten(relay);
    }
    // KENNT DER RELAY GERAETE UEBERHAUPT? Die Frage kennt jeder Relay-Client,
    // auch jede Attrappe. Null heisst nein — dann kennt er erst recht keine
    // Geraeteliste, und die neuen Aufrufe bleiben unberuehrt.
    final List<int>? ids;
    try {
      ids = await relay.geraeteliste(myId);
    } on RelayException catch (e) {
      if (e.statusCode != 404) rethrow;
      return _mitRelayMitGeraeten(relay);
    }
    if (ids == null) return _ohneListe();
    return _mitRelayMitGeraeten(relay);
  }

  Future<bool> _mitRelayMitGeraeten(RelayClient relay) async {
    var roh = await relay.holeGeraeteliste(myId);
    if (roh == null) {
      final angelegt = await _legeListeAn(relay);
      if (angelegt == null) return _ohneListe();
      if (angelegt) return true;
      roh = await relay.holeGeraeteliste(myId);
      if (roh == null) return _ohneListe();
    }
    final liste = _nimmListe(myId, roh);
    if (liste == null) {
      // Kaputt oder zurueckgedreht — weder abmelden noch anmelden. Die
      // Verbindung scheitert und wird spaeter neu versucht.
      throw const RelayException('Geraeteliste nicht pruefbar');
    }
    final gs = _eigenerSchluesselOderNull();
    if (gs != null && liste.enthaelt(geraetId, gs)) {
      _wirdMitglied(liste);
      relay.geraeteSchluessel = await _gibGeraeteschluessel();
      return true;
    }
    final warMitglied = int.tryParse(_db!.meta('geraeteliste_mitglied') ?? '');
    if (warMitglied != null && liste.epoche > warMitglied) {
      await _wirdAbgemeldet(liste);
      return false;
    }
    if (_geraeteStand != ListenStand.wartetAufBestaetigung) {
      _setzeListenStand(ListenStand.beitrittNoetig);
    }
    // KEIN WIEDERVERBINDEN IN SCHLEIFE: wer nicht in der Liste steht, kommt
    // auch beim naechsten Versuch nicht durch. Dieselbe Sperre wie beim
    // vollen Geraetedeckel; ein ausdruecklicher Versuch hebt sie auf.
    _abgewiesen = true;
    return false;
  }

  /// Ohne Geraeteliste (alter Relay, Attrappe): alles wie vorher.
  bool _ohneListe() {
    if (_geraeteStand != ListenStand.unbekannt) {
      _setzeListenStand(ListenStand.unbekannt);
    }
    return true;
  }

  /// Legt Fassung 1 mit diesem Geraet an. true: angelegt (und Mitglied),
  /// false: jemand war schneller (409), null: der Relay kennt keine Listen.
  Future<bool?> _legeListeAn(RelayClient relay) async {
    final store = _store!;
    final gs = await _gibGeraeteschluessel();
    final neu = Geraeteliste.unterschreibe(
      identitaet: store.identity,
      geraeteschluessel: gs,
      epoche: 1,
      geraete: [GeraeteEintrag(geraetId, rohOeffentlich(gs), _eigeneInfo())],
      unterzeichner: geraetId,
    );
    try {
      await relay.setzeGeraeteliste(neu);
    } on RelayException catch (e) {
      if (e.statusCode == 409) return false;
      // Ein Relay ohne den Pfad antwortet 404 (FastAPI) oder 405.
      if (e.statusCode == 404 || e.statusCode == 405) return null;
      rethrow;
    }
    _uebernimmEigeneListe(neu);
    _wirdMitglied(neu);
    relay.geraeteSchluessel = gs;
    return true;
  }

  void _wirdMitglied(Geraeteliste liste) {
    _db!.transaction((raw) => raw.execute(
        'INSERT INTO meta (key, value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['geraeteliste_mitglied', '${liste.epoche}']));
    _beitrittsTimer?.cancel();
    _beitrittsTimer = null;
    _setzeListenStand(ListenStand.mitglied);
  }

  // ═══════════════════════════════════════════════════════ Ereignisse

  /// Der Relay meldet eine neue Fassung der eigenen Liste, eine Abmeldung
  /// oder einen 4410. Was davon stimmt, sagt nur die signierte Liste.
  Future<void> _frischeEigeneListeAuf() async {
    final relay = _relay ?? (_store == null ? null : _httpRelay());
    if (relay == null || _store == null) return;
    try {
      final liste = _nimmListe(myId, await relay.holeGeraeteliste(myId));
      if (liste == null) return;
      final gs = _eigenerSchluesselOderNull();
      if (gs != null && liste.enthaelt(geraetId, gs)) {
        _meldeGeraete();
        unawaited(_frischeEigeneGeraeteAuf());
        return;
      }
      final warMitglied = int.tryParse(_db?.meta('geraeteliste_mitglied') ?? '');
      if (warMitglied != null && liste.epoche > warMitglied) {
        await _wirdAbgemeldet(liste);
      }
    } catch (_) {
      // Beim naechsten Verbinden wird ohnehin nachgesehen.
    }
  }

  // ═══════════════════════════════════════════════════════ Abmeldung

  /// Dieses Geraet ist abgemeldet — nach einer GEPRUEFTEN Liste ohne es.
  ///
  /// Was hier passiert, und warum genau das:
  ///   * Sitzungen, Geraeteschluessel, Kennung und Anmeldevermerke gehen aus
  ///     der Datenbank: kehrt der Besitzer mit den Woertern zurueck, tritt
  ///     dieses Geraet als neues bei, mit neuer Kennung und frischen
  ///     Sitzungen. Alte Sitzungen passten zu keiner Gegenstelle mehr.
  ///   * Danach die Entropie aus dem Schluesselspeicher. Die Datenbank BLEIBT
  ///     — verschluesselt mit einem Schluessel aus den Woertern. Ein Dieb
  ///     liest nichts mehr; der Besitzer bekommt seinen Verlauf mit den
  ///     Woertern zurueck. So kann auch niemand, der ein fremdes Geraet der
  ///     Liste hat, mit einer Abmeldung den Verlauf des Besitzers vernichten.
  Future<void> _wirdAbgemeldet(Geraeteliste liste) async {
    if (_geraeteStand == ListenStand.abgemeldet) return;
    final db = _db;
    if (db == null) return;
    final schluessel = _infoSchluessel;
    final von = liste.schluesselVon(liste.unterzeichner);
    String? name;
    if (schluessel != null && von != null) {
      for (final e in liste.geraete) {
        if (e.id == liste.unterzeichner) {
          name = GeraeteInfo.entschluessle(schluessel, e.info)?.name;
        }
      }
    }
    _beitrittsTimer?.cancel();
    _beitrittsTimer = null;
    beendeHinzufuegen();
    _geraeuschTakt?.cancel();
    await _raeumeVerbindungAb();
    await _haltNahe();
    _nahGeheimnisse.clear();

    db.transaction((raw) {
      raw.execute('DELETE FROM sessions');
      raw.execute("DELETE FROM meta WHERE key IN ('geraeteschluessel', "
          "'device_id', 'geraeteliste_mitglied', 'relay_prekey_count', "
          "'relay_angemeldet_bei', 'prekey_gemeldet_bis', 'kyber_gemeldet_bis')");
      raw.execute(
          'INSERT INTO meta (key, value) VALUES (?,?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          ['geraete_abgemeldet', jsonEncode({'epoche': liste.epoche, 'zeit': liste.zeit})]);
    });
    db.close();
    _db = null;
    _store = null;
    _chats = null;
    _signalRepo = null;
    _vergissRuheSchluessel();
    _raeumeKlartextAuf();
    final i = _infoSchluessel;
    if (i != null) i.fillRange(0, i.length, 0);
    _infoSchluessel = null;
    _geraeteSchluessel = null;
    _listen.clear();
    _geraetId = null;

    await secretStore.delete();
    _hatIdentitaet = false;
    _abmeldung = (
      zeit: DateTime.fromMillisecondsSinceEpoch(liste.zeit * 1000, isUtc: true),
      von: name,
    );
    _abgewiesen = true;
    _setzeListenStand(ListenStand.abgemeldet);
    _setzeVerbindung(ConnectionState.disconnected);
  }

  // ═══════════════════════════════════════════════════════ Beitritt

  Future<void> _schaueObAufgenommen() async {
    if (_beitrittBis != null && DateTime.now().isAfter(_beitrittBis!)) {
      brichBeitrittAb();
      return;
    }
    if (_store == null) return brichBeitrittAb();
    try {
      final liste = _nimmListe(myId, await _httpRelay().holeGeraeteliste(myId));
      final gs = _eigenerSchluesselOderNull();
      if (liste != null && gs != null && liste.enthaelt(geraetId, gs)) {
        _wirdMitglied(liste);
        _abgewiesen = false;
        unawaited(connect());
      }
    } catch (_) {
      // Naechster Takt.
    }
  }

  /// Auf dem bestaetigenden Geraet: passt eine Anfrage zum gezeigten Code?
  Future<void> _pruefeBeitritte() async {
    final code = _hinzufuegeCode;
    if (code == null || _pruefeLaeuft) return;
    if (DateTime.now().isAfter(_hinzufuegeBis!)) return beendeHinzufuegen();
    final relay = _relay;
    if (relay == null || _store == null) return;
    _pruefeLaeuft = true;
    try {
      final liste = _eigeneListeOderNull();
      if (liste == null) return;
      for (final roh in await relay.holeBeitritte(myId)) {
        final Beitrittsanfrage a;
        try {
          a = Beitrittsanfrage.pruefe(roh, adresse: myId);
        } on GeraetelisteUngueltig {
          continue;
        }
        // NUR DIE ANFRAGE MIT DEM RICHTIGEN NACHWEIS. Jede andere kann jeder
        // mit den Woertern gestellt haben.
        if (!a.passtZu(code)) continue;
        if (liste.kennungen.contains(a.deviceId)) continue;
        await _veroeffentliche((alt) => [...alt.geraete, a.eintrag]);
        _zuletztHinzugefuegt = a.deviceId;
        beendeHinzufuegen();
        unawaited(_frischeEigeneGeraeteAuf());
        return;
      }
    } catch (_) {
      // Naechster Takt.
    } finally {
      _pruefeLaeuft = false;
    }
  }

  // ═══════════════════════════════════════════════════════ Veroeffentlichen

  /// Baut aus der aktuellen Fassung die naechste, unterschreibt sie und
  /// reicht sie ein. Bei 409 (jemand war schneller) einmal neu.
  Future<Geraeteliste> _veroeffentliche(
      List<GeraeteEintrag> Function(Geraeteliste alt) aendere) async {
    final store = _store;
    if (store == null) throw const NotInitializedException();
    final relay = _relay ?? _httpRelay();
    for (var versuch = 0;; versuch++) {
      final alt = _nimmListe(myId, await relay.holeGeraeteliste(myId));
      if (alt == null) throw const RelayException('keine Geraeteliste');
      final neu = Geraeteliste.unterschreibe(
        identitaet: store.identity,
        geraeteschluessel: await _gibGeraeteschluessel(),
        epoche: alt.epoche + 1,
        geraete: aendere(alt),
        unterzeichner: geraetId,
      );
      try {
        await relay.setzeGeraeteliste(neu);
      } on RelayException catch (e) {
        if (e.statusCode == 409 && versuch == 0) continue;
        rethrow;
      }
      _uebernimmEigeneListe(neu);
      if (neu.kennungen.contains(geraetId)) _wirdMitglied(neu);
      _meldeGeraete();
      return neu;
    }
  }

  // ═══════════════════════════════════════════════════════ Listen merken

  /// Prueft eine Fassung fuer [adresse] und merkt sie sich, wenn sie neuer ist.
  ///
  /// Rueckgabe: die Fassung, die jetzt gilt — die neue, oder die bisherige,
  /// wenn die neue kaputt, gefaelscht oder AELTER ist. Nie zurueck hinter eine
  /// gesehene Epoche: sonst koennte ein Relay eine alte Fassung wieder
  /// einspielen und ein abgemeldetes Geraet zurueckholen.
  ///
  /// Bei einer neueren Fassung gehen die Sitzungen zu Geraeten, die fehlen
  /// oder einen anderen Schluessel haben (dieselbe Kennung, anderes Geraet).
  Geraeteliste? _nimmListe(String adresse, Map<String, Object?>? roh) {
    final vorige = _listeVon(adresse);
    if (roh == null) return vorige;
    final Geraeteliste neu;
    try {
      neu = Geraeteliste.pruefe(roh, adresse: adresse, vorige: vorige);
    } on GeraetelisteUngueltig {
      return vorige;
    }
    if (vorige != null && neu.epoche <= vorige.epoche) {
      // Gleiche Epoche, andere Zeichen: zwei Fassungen derselben Nummer.
      // Die erste, die wir gesehen haben, gilt.
      return vorige;
    }
    _speichereListe(adresse, neu);
    final store = _store;
    if (store != null && vorige != null) {
      var weg = false;
      for (final e in vorige.geraete) {
        if (adresse == myId && e.id == geraetId) continue;
        if (!neu.enthaelt(e.id, e.schluessel)) {
          unawaited(store.deleteSession(ProtocolAddress(name: adresse, deviceId: e.id)));
          weg = true;
        }
      }
      if (weg) _signalRepo?.commit(store);
    }
    if (adresse == myId) _meldeGeraete();
    return neu;
  }

  /// Fuer die EIGENE Liste nach einer eigenen Aenderung: die eben selbst
  /// unterschriebene Fassung gilt sofort.
  void _uebernimmEigeneListe(Geraeteliste neu) {
    final vorige = _listeVon(myId);
    if (vorige != null && neu.epoche <= vorige.epoche) {
      // Nur nach einem Zuruecksetzen eines verlorenen Relays (Epoche 1 neu
      // angelegt) — dann gilt, was wir selbst gerade gesetzt haben.
      if (neu.epoche != 1) return;
    }
    _speichereListe(myId, neu);
    _meldeGeraete();
  }

  void _speichereListe(String adresse, Geraeteliste l) {
    _listen[adresse] = l;
    _db?.transaction((raw) => raw.execute(
        'INSERT INTO meta (key, value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['geraeteliste:$adresse', jsonEncode(l.alsJson())]));
  }

  /// Die gemerkte, gepruefte Fassung fuer [adresse] — oder null.
  Geraeteliste? _listeVon(String adresse) {
    if (_listen.containsKey(adresse)) return _listen[adresse];
    final db = _db;
    if (db == null) return null;
    Geraeteliste? l;
    final roh = db.meta('geraeteliste:$adresse');
    if (roh != null) {
      try {
        l = Geraeteliste.pruefe(jsonDecode(roh), adresse: adresse);
      } catch (_) {
        l = null;
      }
    }
    _listen[adresse] = l;
    return l;
  }

  Geraeteliste? _eigeneListeOderNull() => _store == null ? null : _listeVon(myId);

  // ═══════════════════════════════════════════════════════ Stufe 2

  /// Darf Post von diesem Geraet ueberhaupt entschluesselt werden?
  ///
  /// Hat die Adresse eine Liste und steht das Geraet nicht darin, wird sie
  /// einmal nachgeladen — ein frisch beigetretenes Geraet schreibt oft, bevor
  /// die Gegenstelle die neue Fassung kennt. Steht es danach immer noch nicht
  /// darin, nein. Ohne Liste (Gegenstelle mit alter App): ja, wie bisher.
  ///
  /// SYNCHRON IM NORMALFALL ([_darfEmpfangenSofort]): eine Wartestelle vor
  /// jedem Entschluesseln verschob den ganzen Empfang um eine Runde der
  /// Ereignisschleife — und ein Sperren genau dazwischen liess den Rest des
  /// Empfangs gegen einen schon geschlossenen Kern laufen. Gewartet wird nur,
  /// wenn wirklich eine Liste nachzuladen ist.
  bool? _darfEmpfangenSofort(String von, int geraet) {
    final l = _listeVon(von);
    if (l != null && l.kennungen.contains(geraet)) return true;
    // Ohne gemerkte Liste und ohne Relay, der Listen kennt: wie bisher.
    if (l == null && !hatGeraeteliste) return true;
    // EIN FREMDER (erste Kontaktanfrage): keine Nachfrage. Stufe 2 schuetzt
    // Kontakte und die eigenen Geraete vor abgemeldeten Geraeten; bei
    // jemandem, den man noch gar nicht kennt, gibt es nichts zu schuetzen —
    // und jede erste Nachricht kostete sonst eine Anfrage beim Relay.
    if (l == null && von != myId && _chats?.kontakt(von) == null) return true;
    final naechste = _listeGefragt[von];
    if (_relay == null || (naechste != null && !DateTime.now().isAfter(naechste))) {
      return l == null;
    }
    return null;
  }

  Future<bool> _darfEmpfangen(String von, int geraet) async {
    final sofort = _darfEmpfangenSofort(von, geraet);
    if (sofort != null) return sofort;
    final l = _listeVon(von);
    final relay = _relay;
    if (relay != null) {
      try {
        final roh = await relay.holeGeraeteliste(von);
        final neu = _nimmListe(von, roh);
        // Eine Gegenstelle ohne Liste (alte App) fragen wir nur alle sechs
        // Stunden wieder — sonst kostete jede ihrer Nachrichten eine Anfrage.
        _listeGefragt[von] = DateTime.now()
            .add(neu == null ? RealMessengerCore.geraeteFenster : _listenNachfrage);
        if (neu == null) return true;
        return neu.kennungen.contains(geraet);
      } catch (_) {
        // Nicht erreichbar: dann gilt die Liste, die wir haben.
        _listeGefragt[von] = DateTime.now().add(_listenNachfrage);
      }
    }
    return l == null;
  }

  // ═══════════════════════════════════════════════════════ Hilfen

  /// Sucht eine Kennung, die weder in der Liste noch beim Relay belegt ist —
  /// falls die bisherige in der Liste einem anderen Geraet gehoert.
  Future<void> _sorgeFuerFreieKennung(RelayClient relay, Geraeteliste liste) async {
    if (_geraetId != null && !liste.kennungen.contains(_geraetId)) return;
    List<int> zeilen;
    try {
      zeilen = await relay.geraeteliste(myId) ?? const [];
    } on RelayException {
      zeilen = const [];
    }
    final neu = _neueGeraetId([...liste.kennungen, ...zeilen]);
    _setzeGeraetId(neu);
    _vergissAnmeldung();
    relay.geraeteKennung = neu == 1 ? null : neu;
  }

  /// Ein Relay-Client nur fuer HTTP — etwa fuer ein Geraet, das (noch) nicht
  /// in der Liste steht und deshalb keine WebSocket bekommt.
  RelayClient _httpRelay() {
    final r = _relay;
    if (r != null) return r;
    final neu = _neuerRelay(_store!.identity);
    if (geraetId != 1) neu.geraeteKennung = geraetId;
    return neu;
  }

  Uint8List? _eigenerSchluesselOderNull() {
    final k = _geraeteSchluessel;
    if (k != null) return rohOeffentlich(k);
    final roh = _db?.meta('geraeteschluessel');
    if (roh == null) return null;
    try {
      _geraeteSchluessel = PrivateKey.deserialize(bytes: base64.decode(roh));
      return rohOeffentlich(_geraeteSchluessel!);
    } catch (_) {
      return null;
    }
  }

  /// Der Geraeteschluessel — beim ersten Bedarf erzeugt und gespeichert.
  /// NIE aus den Woertern: sonst haetten alle Geraete denselben.
  Future<PrivateKey> _gibGeraeteschluessel() async {
    if (_eigenerSchluesselOderNull() != null) return _geraeteSchluessel!;
    final k = PrivateKey.generate();
    _db!.transaction((raw) => raw.execute(
        'INSERT INTO meta (key, value) VALUES (?,?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        ['geraeteschluessel', base64.encode(k.serialize())]));
    _geraeteSchluessel = k;
    return k;
  }

  /// Name und Einrichtungszeit dieses Geraets, verschluesselt.
  String _eigeneInfo() {
    final s = _infoSchluessel;
    if (s == null) return '';
    return GeraeteInfo(_plattformName(), DateTime.now()).verschluessle(s);
  }

  void _setzeListenStand(ListenStand s) {
    _geraeteStand = s;
    _meldeGeraete();
  }

  void _meldeGeraete() {
    if (!_geraeteCtl.isClosed) _geraeteCtl.add(_geraeteStand);
  }
}

String _plattformName() {
  if (RealMessengerCore._imBrowser) return 'Browser';
  try {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'Mac';
  } catch (_) {
    // kein dart:io
  }
  return 'BitDM';
}

bool _gleicheBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
