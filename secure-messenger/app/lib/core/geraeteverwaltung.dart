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

/// Wie oft hoechstens die eigene Liste an dieselbe Adresse nachgeschickt wird,
/// weil sie mit einer veralteten Epoche schrieb (§12.3 Regel 4).
const Duration _nachschickAbstand = Duration(minutes: 10);

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

  /// Die Epoche der eigenen Liste, die der Relay NICHT ausliefert — oder
  /// null, wenn er liefert, was dieses Geraet kennt (docs/GERAETEABMELDUNG.md
  /// §12.4). Dann erfahren Kontakte die Aenderung nur ueber unsere
  /// Nachrichten; "Geraete verwalten" sagt das.
  int? get relayVerschweigtListe => _relayVerschweigt;

  /// Ob es von [adresse] zwei verschiedene Fassungen derselben Epoche gibt
  /// (§12.3 Regel 5). Ein ehrlicher Relay kann das nicht erzeugen.
  bool geraetelisteWiderspruch(String adresse) =>
      _db?.meta('geraeteliste_widerspruch:$adresse') != null;

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
    // DIE VERTEILUNG ABWARTEN (§12.3 Regel 1): danach ist die Datenbank zu,
    // und was noch im Ausgang laege, ginge nie mehr hinaus. Hoechstens zehn
    // Sekunden — die anderen eigenen Geraete heilen den Rest.
    final neu = await _veroeffentliche(
        (alt) => [
              for (final e in alt.geraete)
                if (e.id != geraetId) e,
            ],
        verteilungAbwarten: true);
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
      // Laut, und zwar Ende-zu-Ende (§12.3): jedes andere Geraet und jeder
      // Kontakt erfaehrt es, auch wenn der Relay es verschwiege. Ueber den
      // Ausgang — die Nachrichten gehen nach dem Verbinden hinaus.
      unawaited(_verbreiteListe(neu, alt: alt));
      unawaited(_pruefeWasDerRelayLiefert(relay));
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
    _vergleicheMitRelay(roh);
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
      final roh = await relay.holeGeraeteliste(myId);
      final liste = _nimmListe(myId, roh);
      if (liste == null) return;
      _vergleicheMitRelay(roh);
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
    _vergissListenZustand();
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
  ///
  /// Danach geht sie Ende-zu-Ende an Kontakte und Geraete (§12.3 Regel 1),
  /// und es wird nachgesehen, ob der Relay sie auch ausliefert (§12.4).
  Future<Geraeteliste> _veroeffentliche(
      List<GeraeteEintrag> Function(Geraeteliste alt) aendere,
      {bool verteilungAbwarten = false}) async {
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
      final verteilung = _verbreiteListe(neu, alt: alt);
      if (verteilungAbwarten) {
        await verteilung.timeout(const Duration(seconds: 10), onTimeout: () {});
      } else {
        unawaited(verteilung);
        unawaited(_pruefeSpaeterWasDerRelayLiefert(relay, neu.epoche));
      }
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
      // Die erste, die wir gesehen haben, gilt — und der Nutzer erfaehrt,
      // dass es zwei gibt (§12.3 Regel 5).
      if (neu.epoche == vorige.epoche && neu.roh != vorige.roh) {
        _merkeWiderspruch(adresse, neu.epoche);
      }
      return vorige;
    }
    _speichereListe(adresse, neu);
    // WAS ANGEKUENDIGT WAR, IST DA (§12.3) — oder eine andere Fassung
    // derselben Epoche. Dann bleibt die Liste veraltet, und es gibt zwei.
    final ank = _ankuendigungVon(adresse);
    if (ank != null) {
      if (neu.epoche > ank.epoche ||
          (neu.epoche == ank.epoche && neu.kurzHash == ank.hash)) {
        _setzeAnkuendigung(adresse, null);
      } else if (neu.epoche == ank.epoche) {
        _merkeWiderspruch(adresse, neu.epoche);
      }
    }
    final w = int.tryParse(_db?.meta('geraeteliste_widerspruch:$adresse') ?? '');
    if (w != null && neu.epoche > w) _loescheMeta('geraeteliste_widerspruch:$adresse');
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

  void _loescheMeta(String key) =>
      _db?.transaction((raw) => raw.execute('DELETE FROM meta WHERE key = ?', [key]));

  void _setzeMeta(String key, String wert) => _db?.transaction((raw) => raw.execute(
      'INSERT INTO meta (key, value) VALUES (?,?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, wert]));

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

  // ═══════════════════════════════════════════ Verschweigen (GERAETEABMELDUNG §12)
  //
  // Stufe 2 oben glaubt der Liste, die der Relay ausliefert, und weist nur
  // eine AELTERE ab. Verschweigt der Relay eine neue Fassung, merkt sie
  // nichts: Kontakte verschluesselten weiter an ein abgemeldetes Geraet, und
  // es schrieb weiter als Besitzer. Deshalb reist die Liste auch
  // Ende-zu-Ende — als eigene Nachricht nach jeder Aenderung (Art 20) und als
  // Stempel in jeder Nutzlast. Wer einen Stempel sieht, der mehr kennt als er,
  // weiss, DASS ihm etwas fehlt, und schickt bis dahin nur an Geraete, die
  // es nachweislich haben.

  void _vergissListenZustand() {
    _listen.clear();
    _ankuendigungen.clear();
    _listenAbrufe.clear();
    _stempelGefragt.clear();
    _listeNachgeschickt.clear();
    _relayKenntNicht.clear();
    _relayVerschweigt = null;
    _verglichenBis = null;
  }

  /// Die Stempel fuer eine Nutzlast an [an] (§12.3): die eigene Epoche samt
  /// Kurzhash, wenn dieses Geraet in der eigenen Liste steht, und welche
  /// Epoche der Liste von [an] wir kennen. Ohne Listen (alter Relay) keine
  /// Stempel — die Nutzlast ist dann Zeichen fuer Zeichen die von 2.0.0.
  ({int? le, String? lh, int? ke}) _stempelFuer(String an) {
    int? le;
    String? lh;
    final eigene = _eigeneListeOderNull();
    final gs = _eigenerSchluesselOderNull();
    if (_geraeteStand == ListenStand.mitglied &&
        eigene != null &&
        gs != null &&
        eigene.enthaelt(geraetId, gs)) {
      le = eigene.epoche;
      lh = eigene.kurzHash;
    }
    final ihre = an == myId ? null : _listeVon(an);
    final ke = an == myId || (le == null && ihre == null) ? null : (ihre?.epoche ?? 0);
    return (le: le, lh: lh, ke: ke);
  }

  Ankuendigung? _ankuendigungVon(String adresse) {
    if (_ankuendigungen.containsKey(adresse)) return _ankuendigungen[adresse];
    final db = _db;
    if (db == null) return null;
    Ankuendigung? a;
    final roh = db.meta('geraeteliste_ank:$adresse');
    if (roh != null) {
      try {
        a = Ankuendigung.lies(jsonDecode(roh));
      } on FormatException {
        a = null;
      }
    }
    _ankuendigungen[adresse] = a;
    return a;
  }

  void _setzeAnkuendigung(String adresse, Ankuendigung? a) {
    _ankuendigungen[adresse] = a;
    if (a == null) {
      _loescheMeta('geraeteliste_ank:$adresse');
    } else {
      _setzeMeta('geraeteliste_ank:$adresse', jsonEncode(a.alsJson()));
    }
  }

  /// Liegt die bekannte Liste von [adresse] hinter dem, was Stempel
  /// angekuendigt haben (§12.3 Regel 3)? Kleinere Epoche, keine Liste, oder
  /// dieselbe Epoche mit anderen Zeichen.
  bool _listeVeraltet(String adresse) {
    final ank = _ankuendigungVon(adresse);
    if (ank == null) return false;
    final l = _listeVon(adresse);
    if (l == null || ank.epoche > l.epoche) return true;
    return ank.epoche == l.epoche && ank.hash != l.kurzHash;
  }

  /// Nur an diese Geraete von [adresse] — oder null, wenn die Liste nicht
  /// veraltet ist und sie allein entscheidet.
  Set<int>? _nurAn(String adresse) =>
      _listeVeraltet(adresse) ? _ankuendigungVon(adresse)!.geraete : null;

  void _merkeAnkuendigung(String von, int epoche, String hash, int geraet) {
    final ank = _ankuendigungVon(von);
    if (ank == null || epoche > ank.epoche) {
      _setzeAnkuendigung(von, Ankuendigung(epoche, hash, {geraet}));
    } else if (epoche == ank.epoche) {
      if (hash != ank.hash) {
        _merkeWiderspruch(von, epoche);
      } else if (!ank.geraete.contains(geraet)) {
        _setzeAnkuendigung(von, Ankuendigung(epoche, hash, {...ank.geraete, geraet}));
      }
    }
  }

  /// Zwei Fassungen derselben Epoche (§12.3 Regel 5). Gemerkt bis zu einer
  /// hoeheren Fassung; der Chat zeigt einen Hinweis.
  void _merkeWiderspruch(String adresse, int epoche) {
    if (_db?.meta('geraeteliste_widerspruch:$adresse') != null) return;
    _setzeMeta('geraeteliste_widerspruch:$adresse', '$epoche');
    _contacts.add(ContactEvent(
      type: ContactEventType.deviceListConflict,
      contactId: adresse,
      at: DateTime.now().toUtc(),
    ));
    if (adresse == myId) _meldeGeraete();
  }

  /// Nimmt die Stempel einer entschluesselten Nutzlast (§12.3). Rueckgabe:
  /// ob sie weiter verarbeitet wird. SYNCHRON — siehe [_darfEmpfangenSofort],
  /// warum der Empfang hier nicht warten darf; Nachladen und Nachschicken
  /// laufen nebenher.
  bool _nimmStempel(String von, int vonGeraet, Payload p) {
    if (_db == null) return true;
    final le = p.listenEpoche;
    final lh = p.listenHash;
    if (le != null && lh != null) {
      final bekannt = _listeVon(von);
      if (bekannt != null && le == bekannt.epoche) {
        // Dieselbe Epoche mit anderen Zeichen: zwei Fassungen (Regel 5). Der
        // Stempel gilt trotzdem als Ankuendigung — versandt wird nach Regel 3.
        if (lh != bekannt.kurzHash) {
          _merkeWiderspruch(von, le);
          _merkeAnkuendigung(von, le, lh, vonGeraet);
        }
      } else if (bekannt == null || le > bekannt.epoche) {
        _merkeAnkuendigung(von, le, lh, vonGeraet);
        // EIN FREMDER (erste Kontaktanfrage) kostet keine Anfrage — wie in
        // [_darfEmpfangenSofort]. Die Ankuendigung steht trotzdem, und
        // spaetestens die erste Antwort laedt nach (`_sendePayload`). Die
        // Art 20 bringt die Liste selbst mit.
        if (p.kind != PayloadKind.geraeteliste &&
            (von == myId || _chats?.kontakt(von) != null)) {
          unawaited(_holeListeNach(von));
        }
      }
    }

    // HEILEN (Regel 4): wer mit einer aelteren Fassung unserer Liste
    // schreibt, hat die Verteilung verpasst — vielleicht, weil der Relay sie
    // verschluckt hat. Er bekommt sie nachgeschickt.
    final eigene = _eigeneListeOderNull();
    if (eigene != null && _geraeteStand == ListenStand.mitglied) {
      if (von == myId) {
        if (le != null && le < eigene.epoche) unawaited(_schickeListeNach(myId));
      } else {
        final ke = p.kenntEpoche;
        if (ke != null && ke < eigene.epoche) unawaited(_schickeListeNach(von));
        // Er kennt eine neuere als wir: dann fehlt UNS etwas.
        if (ke != null && ke > eigene.epoche) unawaited(_holeListeNach(myId));
      }
    }

    // DIE LISTE SELBST traegt ihre Beweise — von wem auch immer.
    if (p.kind == PayloadKind.geraeteliste) return true;
    if (!_listeVeraltet(von)) return true;
    // VERALTET: nur wer die angekuendigte Fassung selbst nennt, spricht noch
    // fuer diese Adresse. Ein abgemeldetes Geraet, das der Relay weiter
    // beliefert, kennt sie nicht.
    final ank = _ankuendigungVon(von)!;
    return le != null &&
        (le > ank.epoche || (le == ank.epoche && lh == ank.hash));
  }

  /// Laedt die Liste von [adresse] beim Relay nach — hoechstens eine Anfrage
  /// zur Zeit und eine je [_listenNachfrage].
  ///
  /// EIGENE BREMSE, nicht `_listeGefragt`: die gehoert [_darfEmpfangen], und
  /// die Post eines eben beigetretenen Geraets braucht ihren Abruf. Teilten
  /// sich beide eine, verbrauchte der erste Stempel einer Kontaktanfrage die
  /// Minute — und ein Geraet, das in dieser Minute zuruecksetzte, kam nicht
  /// mehr durch (test/net/sicherung_test.dart, Gesamtlauf vom 18.10.2026).
  ///
  /// Umgekehrt zaehlt ein Abruf von dort auch hier: er hat die Liste eben
  /// geholt, und jeder Abruf kostet eine Marke der Herkunftsbremse des Relays
  /// (dieselbe wie `/prekey`).
  Future<void> _holeListeNach(String adresse) {
    final laeuft = _listenAbrufe[adresse];
    if (laeuft != null) return laeuft;
    final jetzt = DateTime.now();
    final naechste = _stempelGefragt[adresse];
    final stufe2 = _listeGefragt[adresse];
    if ((naechste != null && jetzt.isBefore(naechste)) ||
        (stufe2 != null && jetzt.isBefore(stufe2))) {
      return Future<void>.value();
    }
    _stempelGefragt[adresse] = jetzt.add(_listenNachfrage);
    // `Future(...)` und nicht sofort: der Eintrag muss stehen, bevor der
    // Abruf ihn im `finally` wieder entfernt.
    final abruf = Future<void>(() async {
      try {
        if (adresse == myId) {
          await _frischeEigeneListeAuf();
          return;
        }
        final relay = _relay;
        if (relay == null) return;
        _nimmListe(adresse, await relay.holeGeraeteliste(adresse));
      } catch (_) {
        // Dann eben mit dem naechsten Stempel oder der Verteilung.
      } finally {
        _listenAbrufe.remove(adresse);
      }
    });
    _listenAbrufe[adresse] = abruf;
    return abruf;
  }

  /// Schickt die eigene Liste an [an] nach (Regel 4). Best effort.
  Future<void> _schickeListeNach(String an) async {
    final eigene = _eigeneListeOderNull();
    if (eigene == null || _geraeteStand != ListenStand.mitglied) return;
    final jetzt = DateTime.now();
    final zuletzt = _listeNachgeschickt[an];
    if (zuletzt != null && jetzt.difference(zuletzt) < _nachschickAbstand) return;
    _listeNachgeschickt[an] = jetzt;
    try {
      await _sendePayload(
          an, Payload.geraeteliste(_neueId(), eigene.alsJson(), jetzt.toUtc()),
          spiegeln: false);
    } catch (_) {
      // Die naechste Nachricht von dort fragt wieder.
    }
  }

  /// Verteilt eine eben veroeffentlichte Fassung Ende-zu-Ende (Regel 1).
  ///
  /// 1. ABSCHIED an jedes Geraet, das in [alt] stand und jetzt fehlt —
  ///    solange die Sitzung noch steht. Es prueft die Liste und entfernt die
  ///    Woerter, auch wenn der Relay es nie trennt.
  /// 2. An die eigenen Geraete der neuen Liste.
  /// 3. An alle Kontakte (ausser offenen fremden Anfragen) und Mitglieder
  ///    aktiver Gruppen — ueber den Ausgang, damit nichts verloren geht.
  Future<void> _verbreiteListe(Geraeteliste neu, {Geraeteliste? alt}) async {
    final p = Payload.geraeteliste(_neueId(), neu.alsJson(), DateTime.now().toUtc());
    if (alt != null) {
      for (final e in alt.geraete) {
        if (e.id == geraetId || neu.enthaelt(e.id, e.schluessel)) continue;
        try {
          await _schickeAnGeraet(myId, e.id, p);
        } catch (_) {
          // Der Relay kennt es schon nicht mehr — dann hat er es getrennt.
        }
      }
    }
    // An die eigenen Geraete, die schon in der vorigen Fassung standen. Ein
    // eben beigetretenes hat die Liste gerade selbst geholt — und haette noch
    // keine Sitzung, also kostete es nur einen Buendelabruf.
    if (neu.kennungen
        .any((g) => g != geraetId && (alt == null || alt.kennungen.contains(g)))) {
      try {
        await _sendePayload(myId, p, spiegeln: false);
      } catch (_) {
        // Sie heilen sich mit der naechsten eigenen Nachricht (Regel 4).
      }
    }
    for (final an in _listenEmpfaenger()) {
      if (_store == null) return;
      try {
        await _sendeSteuerung(an, p);
      } catch (_) {
        // Bleibt im Ausgang.
      }
    }
  }

  /// Wer Nachrichten an uns verschluesselt und deshalb die Liste braucht.
  Set<String> _listenEmpfaenger() {
    final chats = _chats;
    if (chats == null) return const {};
    final an = <String>{
      for (final k in chats.alleKontakte())
        if (k.state != ContactState.incomingPending) k.id,
      for (final g in chats.alleGruppen())
        if (g.aktiv) ...g.mitglieder,
    };
    an.remove(myId);
    return an;
  }

  /// Eine Nutzlast an GENAU EIN Geraet, an jedem Filter vorbei — fuer den
  /// Abschied an ein Geraet, das in keiner Liste mehr steht.
  Future<void> _schickeAnGeraet(String an, int g, Payload p) async {
    final store = _store;
    final relay = _relay;
    if (store == null || relay == null || !relay.isConnected) return;
    final ziel = ProtocolAddress(name: an, deviceId: g);
    if (!await store.containsSession(ziel)) return;
    final ct = await _signalExklusiv(() async {
      final ct = await _chiffre(store).encrypt(ziel, p.toBytes());
      _signalRepo!.commit(store);
      return ct;
    });
    await _RelayAusgang(relay, g).schicke(an, Envelope.of(ct).toBytes());
  }

  /// Eine Liste, die Ende-zu-Ende kam (Art 20). Bei der eigenen Adresse auch
  /// die Folgen: weiter Mitglied, oder abgemeldet — dann gibt sie die Fassung
  /// zurueck, und der Empfang meldet ab, sobald er fertig ist.
  Geraeteliste? _nimmListeEndeZuEnde(String von, Payload p) {
    final roh = p.geraetelisteRoh;
    if (roh == null) return null;
    final vorige = _listeVon(von);
    final l = _nimmListe(von, roh);
    if (von != myId || l == null || identical(l, vorige)) return null;
    final gs = _eigenerSchluesselOderNull();
    if (gs != null && l.enthaelt(geraetId, gs)) {
      if (_geraeteStand == ListenStand.mitglied) _wirdMitglied(l);
      unawaited(_frischeEigeneGeraeteAuf());
      // Ob der Relay sie auch ausliefert, prueft das Geraet, das sie
      // veroeffentlicht hat (§12.4) — hier kostete es nur eine Marke der
      // Herkunftsbremse mehr. Dieses vergleicht beim naechsten Verbinden.
      return null;
    }
    final warMitglied = int.tryParse(_db?.meta('geraeteliste_mitglied') ?? '');
    if (warMitglied != null && l.epoche > warMitglied) return l;
    return null;
  }

  /// Liefert der Relay die eigene Liste, die wir kennen (§12.4)? [roh] ist
  /// das, was er eben auf `/geraeteliste` oder `/prekey` ausgeliefert hat.
  void _vergleicheMitRelay(Map<String, Object?>? roh) {
    final eigene = _listeVon(myId);
    if (eigene == null) return;
    Geraeteliste? geliefert;
    if (roh != null) {
      try {
        geliefert = Geraeteliste.pruefe(roh, adresse: myId);
      } on GeraetelisteUngueltig {
        geliefert = null;
      }
    }
    final stimmt = geliefert != null &&
        (geliefert.epoche > eigene.epoche || geliefert.roh == eigene.roh);
    _verglichenBis = eigene.epoche;
    final neu = stimmt ? null : eigene.epoche;
    if (neu != _relayVerschweigt) {
      _relayVerschweigt = neu;
      _meldeGeraete();
    }
  }

  Future<void> _pruefeWasDerRelayLiefert(RelayClient relay) async {
    try {
      _vergleicheMitRelay(await relay.holeGeraeteliste(myId));
    } catch (_) {
      // Beim naechsten Verbinden wird ohnehin verglichen.
    }
  }

  /// Nach dem Veroeffentlichen von [epoche]: nur, wenn bis dahin keiner
  /// verglichen hat. Ein ehrlicher Relay meldet die neue Fassung allen
  /// Geraeten der Liste, dem veroeffentlichenden auch, und dessen Auffrischung
  /// vergleicht ohnehin; ein zweiter Abruf kostete nur eine Marke der
  /// Herkunftsbremse. Unterdrueckt der Relay die Meldung, greift dieser.
  Future<void> _pruefeSpaeterWasDerRelayLiefert(
      RelayClient relay, int epoche) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final bis = _verglichenBis;
    if (_store == null || (bis != null && bis >= epoche)) return;
    await _pruefeWasDerRelayLiefert(relay);
  }

  /// Gehoert das Buendel zum Geraet der Liste (§12.5 a)? Ohne Liste: ja.
  /// Eine FALSCHE Signatur nie; eine FEHLENDE nur ohne
  /// [RealMessengerCore.geraeteNachweisPflicht].
  bool _buendelPasstZurListe(
      String an, RelayBundleResponse b, Geraeteliste? liste) {
    if (liste == null) return true;
    final sig = b.spkGeraeteSig;
    if (sig == null) return !RealMessengerCore.geraeteNachweisPflicht;
    final schluessel = liste.schluesselVon(b.deviceId);
    if (schluessel == null) return false;
    try {
      return signaturGilt(
          schluessel,
          spkNachricht(BitdmAddress.normalize(an), b.deviceId, b.signedPreKeyId,
              b.signedPreKey),
          base64.decode(sig));
    } on FormatException {
      return false;
    }
  }

  /// Traegt eine Erstnachricht den Nachweis des Geraets, unter dessen
  /// Kennung sie kam (§12.5 b)? Ohne Liste des Absenders: ja. Eine
  /// Nutzlast, die sich nicht lesen laesst, entscheidet der Aufrufer.
  bool _sitzungsNachweisGilt(
      String von, int vonGeraet, Uint8List basis, Uint8List klar) {
    final liste = _listeVon(von);
    if (liste == null) return true;
    final String? gs;
    try {
      gs = Payload.fromBytes(klar).sitzungsNachweis;
    } on PayloadFormatException {
      return true;
    }
    if (gs == null) return !RealMessengerCore.geraeteNachweisPflicht;
    final schluessel = liste.schluesselVon(vonGeraet);
    if (schluessel == null) return false;
    return signaturGilt(
        schluessel,
        sitzungsNachricht(
          absender: BitdmAddress.normalize(von),
          absenderGeraet: vonGeraet,
          empfaenger: myId,
          empfaengerGeraet: geraetId,
          basisschluessel: basis,
        ),
        base64.decode(gs));
  }

  /// Der Klartext fuer [ziel]: der gemeinsame — oder, solange libsignal fuer
  /// diese Sitzung noch PreKey-Nachrichten schickt, derselbe mit dem
  /// Sitzungsnachweis (§12.5 b). Nur mit eigenem Geraeteschluessel.
  Future<Uint8List> _klartextFuer(BitdmSignalStore store, ProtocolAddress ziel,
      Payload gestempelt, Uint8List klartext) async {
    if (_geraeteStand != ListenStand.mitglied) return klartext;
    if (_eigenerSchluesselOderNull() == null) return klartext;
    final datensatz = await store.loadSession(ziel);
    if (datensatz == null) return klartext;
    final basis = offenerBasisschluessel(datensatz.serialize());
    if (basis == null) return klartext;
    final sig = _geraeteSchluessel!.sign(
        message: sitzungsNachricht(
      absender: myId,
      absenderGeraet: geraetId,
      empfaenger: BitdmAddress.normalize(ziel.name()),
      empfaengerGeraet: ziel.deviceId(),
      basisschluessel: basis,
    ));
    return gestempelt
        .gestempelt(
          listenEpoche: gestempelt.listenEpoche,
          listenHash: gestempelt.listenHash,
          kenntEpoche: gestempelt.kenntEpoche,
          sitzungsNachweis: base64.encode(sig),
        )
        .toBytes();
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
