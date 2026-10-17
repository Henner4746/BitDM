// geraeteliste_stufe2_test.dart — die App prueft die Geraeteliste selbst.
//
// Stufe 1 der Geraeteabmeldung sitzt im Relay: er laesst ein abgemeldetes
// Geraet nicht mehr herein (test_relay.py, geraeteabmeldung_test.dart). Stufe 2
// sitzt hier: auch ein Relay, der luegt, bekommt keine Kopie fuer ein Geraet,
// das nicht in der SIGNIERTEN Liste steht — weder von einer Gegenstelle noch
// als Spiegel von uns selbst. Die Liste faelschen kann er nicht, sie ist vom
// Identitaetsschluessel unterschrieben; zuruecknehmen auch nicht, die App geht
// nie hinter eine gesehene Epoche zurueck.
//
// GEGEN DIE ATTRAPPE, weil genau das gebraucht wird: ein Relay, der etwas
// anderes ausliefert, als er sollte. Der echte relay_server.py tut das nicht.

import 'dart:convert';
import 'dart:io';

import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/envelope.dart';
import 'package:bitdm/core/net/geraeteliste.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/absender.dart';
import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 10)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return fertig();
  }

  setUp(() async {
    await signalBereit();
    ordner = await Directory.systemTemp.createTemp('bitdm-stufe2');
    lage = Relaylage()
      // EIN RELAY MIT GERAETELISTE: `geraeteliste()` antwortet (sonst bliebe
      // der Kern beim alten Verhalten), und Listen werden abgelegt.
      ..liste = []
      ..kenntListen = true;
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}k.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = ZaehlRelay(id, lage);
        lage.gebaut.add(r);
        return r;
      },
    );
    await kern.initialize();
    woerter = await kern.createIdentity();
    await kern.connect();
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  ZaehlRelay relay() => lage.gebaut.last as ZaehlRelay;

  Future<SignalIdentity> ich() async => SignalIdentityBridge.fromDerived(
      await KeyDerivation.fromMnemonic(woerter),
      registrationId: 1);

  Future<BitdmSignalStore> eigenerSpeicher() async =>
      SignalStoreRepository(kern.datenbankFuerTest)
          .openStore(await KeyDerivation.fromMnemonic(woerter));

  PrivateKey meinGeraeteschluessel() => PrivateKey.deserialize(
      bytes: base64.decode(kern.datenbankFuerTest.meta('geraeteschluessel')!));

  Geraeteliste eigeneListe() =>
      Geraeteliste.pruefe(lage.listen[kern.myId], adresse: kern.myId);

  List<String> sitzungen() => kern.datenbankFuerTest.raw
      .select('SELECT address FROM sessions')
      .map((r) => r['address']! as String)
      .toList();

  test('beim ersten Verbinden legt die App ihre Liste an und steht darin',
      () async {
    expect(kern.geraeteStand, ListenStand.mitglied);
    final l = eigeneListe();
    expect(l.epoche, 1);
    expect(l.kennungen, {kern.geraetId});
    expect(relay().geraeteSchluessel, isNotNull,
        reason: 'mit Liste unterschreibt die Anmeldung auch der Geraeteschluessel');
    expect(kern.eigeneGeraete.single.istDieses, isTrue);
    expect(kern.eigeneGeraete.single.name, isNotNull,
        reason: 'der Name steht verschluesselt in der Liste und ist lesbar');
  });

  test(
      'EIN EIGENES GERAET AUSSERHALB DER LISTE BEKOMMT KEINEN SPIEGEL — auch '
      'mit echtem, von uns unterschriebenem Prekey', () async {
    // So saehe das Buendel eines abgemeldeten Zweitgeraets aus, das ein Relay
    // weiter ausliefert: der signierte Prekey ist ECHT, mit unserem
    // Identitaetsschluessel unterschrieben, als das Geraet noch dazugehoerte.
    // Der Reflexionsriegel (§12.1) greift hier nicht — es ist nicht unser
    // eigener Prekey, sondern der eines anderen Geraets. Nur die Liste hilft.
    final speicher = await eigenerSpeicher();
    final spk = neuerSpk(speicher.identity.keyPair, 55);
    final kyber = neuerKyber(speicher.identity.keyPair, 55);
    final otk = neuerPreKey(5500);
    Map<String, Object?> geraet5() => {
          'device_id': 5,
          'registration_id': 99,
          'signed_prekey_id': spk.id(),
          'signed_prekey': base64.encode(spk.publicKey()),
          'signed_prekey_sig': base64.encode(spk.signature()),
          'one_time_prekey': {
            'key_id': otk.id(),
            'public_key': base64.encode(otk.publicKey()),
          },
          'kyber_prekey_id': kyber.id(),
          'kyber_prekey': base64.encode(kyber.getPublicKey().serialize()),
          'kyber_prekey_sig': base64.encode(kyber.signature()),
        };
    lage.liste = [kern.geraetId, 5];
    lage.buendel = (wen) => wen == kern.myId
        ? {
            'user_id': kern.myId,
            'identity_key': base64.encode(speicher.identity.rawPublicKey),
            ...geraet5(),
            'geraete': [geraet5()],
          }
        : <String, Object?>{};

    await kern.disconnect();
    await kern.connect();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(sitzungen().where((s) => s.endsWith(':5')), isEmpty,
        reason: 'Geraet 5 steht nicht in der signierten Liste');

    // Ein Mitglied (wir) nimmt Geraet 5 auf: Fassung 2.
    final gs5 = PrivateKey.generate();
    final eins = eigeneListe();
    final zwei = Geraeteliste.unterschreibe(
      identitaet: await ich(),
      geraeteschluessel: meinGeraeteschluessel(),
      epoche: 2,
      geraete: [...eins.geraete, GeraeteEintrag(5, rohOeffentlich(gs5), '')],
      unterzeichner: kern.geraetId,
    );
    lage.listen[kern.myId] = zwei.alsJson();
    relay().herein(const RelayGeraetelisteNeu(2));
    expect(await warteBis(() => sitzungen().any((s) => s.endsWith(':5'))), isTrue,
        reason: 'GEGENPROBE: in der Liste bekommt Geraet 5 seine Sitzung');

    // Und wieder abgemeldet: Fassung 3 ohne Geraet 5.
    final drei = Geraeteliste.unterschreibe(
      identitaet: await ich(),
      geraeteschluessel: meinGeraeteschluessel(),
      epoche: 3,
      geraete: eins.geraete,
      unterzeichner: kern.geraetId,
    );
    lage.listen[kern.myId] = drei.alsJson();
    relay().herein(const RelayGeraetelisteNeu(3));
    expect(await warteBis(() => !sitzungen().any((s) => s.endsWith(':5'))), isTrue,
        reason: 'mit der Abmeldung geht die Sitzung zum abgemeldeten Geraet');

    // EIN RELAY, DER DIE ALTE FASSUNG WIEDER EINSPIELT, holt es nicht zurueck.
    lage.listen[kern.myId] = zwei.alsJson();
    relay().herein(const RelayGeraetelisteNeu(2));
    await kern.disconnect();
    await kern.connect();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(sitzungen().where((s) => s.endsWith(':5')), isEmpty,
        reason: 'nie zurueck hinter eine gesehene Epoche');
  });

  test(
      'AN EIN GERAET AUSSERHALB DER LISTE EINER GEGENSTELLE GEHT NICHTS — '
      'auch wenn der Relay es anbietet', () async {
    final fremd = await Fremder.mitGeraeten([1, 7]);
    final gs1 = PrivateKey.generate();
    final gs7 = PrivateKey.generate();
    final e1 = GeraeteEintrag(1, rohOeffentlich(gs1), '');
    final e7 = GeraeteEintrag(7, rohOeffentlich(gs7), '');
    Geraeteliste fassung(int epoche, List<GeraeteEintrag> g) =>
        Geraeteliste.unterschreibe(
            identitaet: fremd.identitaet,
            geraeteschluessel: gs1,
            epoche: epoche,
            geraete: g,
            unterzeichner: 1);
    final eins = fassung(1, [e1, e7]);
    final zwei = fassung(2, [e1]); // Geraet 7 abgemeldet

    // Der Relay liefert die Fassung, die wir ihm geben — und IMMER beide
    // Geraete, als haette es keine Abmeldung gegeben.
    var gezeigt = eins;
    lage.listen[fremd.adresse] = eins.alsJson();
    lage.liste = [1, 7];
    lage.buendel = (wen) => wen == fremd.adresse
        ? {...fremd.karte(), 'geraeteliste': gezeigt.alsJson()}
        : <String, Object?>{};
    kern.ablageFuerTest.speichereKontakt(Contact(
        id: fremd.adresse,
        addedAt: DateTime.now().toUtc(),
        state: ContactState.active));

    Set<int> geraeteVon(int ab) => {
          for (final s in lage.gesendet.skip(ab))
            if (s.an == fremd.adresse) s.geraet,
        };

    await kern.sendMessage(fremd.adresse, 'vorher');
    expect(await warteBis(() => geraeteVon(0).length == 2), isTrue);
    expect(geraeteVon(0), {1, 7}, reason: 'GEGENPROBE: beide stehen in Fassung 1');

    // Geraet 7 wird abgemeldet. Der Relay zeigt die neue Fassung (wie
    // bei der Auffrischung), bietet Geraet 7 aber weiter an.
    gezeigt = zwei;
    lage.listen[fremd.adresse] = zwei.alsJson();
    kern.ablageFuerTest.setzeGeraeteGeprueft(fremd.adresse, 0);
    var ab = lage.gesendet.length;
    await kern.sendMessage(fremd.adresse, 'nachher');
    expect(await warteBis(() => geraeteVon(ab).isNotEmpty), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(geraeteVon(ab), {1}, reason: 'Geraet 7 steht nicht mehr in der Liste');

    // DER RELAY SPIELT FASSUNG 1 WIEDER EIN — mit Geraet 7.
    gezeigt = eins;
    lage.listen[fremd.adresse] = eins.alsJson();
    kern.ablageFuerTest.setzeGeraeteGeprueft(fremd.adresse, 0);
    ab = lage.gesendet.length;
    await kern.sendMessage(fremd.adresse, 'wiedereingespielt');
    expect(await warteBis(() => geraeteVon(ab).isNotEmpty), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(geraeteVon(ab), {1}, reason: 'nie zurueck hinter eine gesehene Epoche');
  });

  /// Eine fremde Adresse mit Geraeten [1, 7], als aktiver Kontakt, und ein
  /// Relay, der beide anbietet — mit der Liste, die [gezeigt] liefert.
  Future<({Fremder fremd, PrivateKey gs1, GeraeteEintrag e1, GeraeteEintrag e7})>
      fremderMitZwei(Map<String, Object?>? Function() gezeigt,
          {Map<String, Object?> Function()? karte}) async {
    final fremd = await Fremder.mitGeraeten([1, 7]);
    final gs1 = PrivateKey.generate();
    final gs7 = PrivateKey.generate();
    lage.liste = [1, 7];
    lage.buendel = (wen) {
      if (wen != fremd.adresse) return <String, Object?>{};
      final l = gezeigt();
      return {...(karte?.call() ?? fremd.karte()), 'geraeteliste': ?l};
    };
    kern.ablageFuerTest.speichereKontakt(Contact(
        id: fremd.adresse,
        addedAt: DateTime.now().toUtc(),
        state: ContactState.active));
    return (
      fremd: fremd,
      gs1: gs1,
      e1: GeraeteEintrag(1, rohOeffentlich(gs1), ''),
      e7: GeraeteEintrag(7, rohOeffentlich(gs7), ''),
    );
  }

  Set<int> geraeteAn(String adresse, int ab) => {
        for (final s in lage.gesendet.skip(ab))
          if (s.an == adresse) s.geraet,
      };

  test(
      'DIE ERSTE NACHRICHT AN EINE GEGENSTELLE MIT LISTE geht nur an gelistete '
      'Geraete', () async {
    // Der Sitzungsaufbau aus dem vollen Buendel: der Relay bietet 1 und 7,
    // die signierte Liste kennt nur 1.
    Map<String, Object?>? liste;
    final f = await fremderMitZwei(() => liste);
    liste = Geraeteliste.unterschreibe(
            identitaet: f.fremd.identitaet,
            geraeteschluessel: f.gs1,
            epoche: 1,
            geraete: [f.e1],
            unterzeichner: 1)
        .alsJson();
    lage.listen[f.fremd.adresse] = liste;
    await kern.sendMessage(f.fremd.adresse, 'erste Nachricht');
    expect(await warteBis(() => geraeteAn(f.fremd.adresse, 0).isNotEmpty), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(geraeteAn(f.fremd.adresse, 0), {1});
    expect(sitzungen().where((s) => s.endsWith(':7')), isEmpty);
  });

  test(
      'ALTE SITZUNGEN, DANN DIE ERSTE LISTE: an ein nicht gelistetes Geraet geht '
      'trotz bestehender Sitzung nichts', () async {
    // Eine Gegenstelle mit alter App (ohne Liste): Sitzungen zu 1 und 7
    // entstehen. Dann aktualisiert sie und legt ihre Liste an — Geraet 7 ist
    // (noch) nicht beigetreten. Die Sitzung zu 7 besteht weiter, darf aber
    // nicht mehr benutzt werden.
    Map<String, Object?>? liste;
    final f = await fremderMitZwei(() => liste);
    await kern.sendMessage(f.fremd.adresse, 'ohne Liste');
    expect(await warteBis(() => geraeteAn(f.fremd.adresse, 0).length == 2), isTrue);

    liste = Geraeteliste.unterschreibe(
            identitaet: f.fremd.identitaet,
            geraeteschluessel: f.gs1,
            epoche: 1,
            geraete: [f.e1],
            unterzeichner: 1)
        .alsJson();
    lage.listen[f.fremd.adresse] = liste;
    kern.ablageFuerTest.setzeGeraeteGeprueft(f.fremd.adresse, 0);
    final ab = lage.gesendet.length;
    await kern.sendMessage(f.fremd.adresse, 'mit Liste');
    expect(await warteBis(() => geraeteAn(f.fremd.adresse, ab).isNotEmpty), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(geraeteAn(f.fremd.adresse, ab), {1});
  });

  test(
      'NEUER SCHLUESSEL UNTER ALTER KENNUNG: die alte Sitzung geht, eine neue '
      'entsteht', () async {
    // Geraet 7 wird abgemeldet und ein ANDERES Geraet tritt unter derselben
    // Kennung bei. Bliebe die alte Sitzung stehen, verschluesselte die App
    // weiter an die Schluessel des abgemeldeten Geraets — der Filter nach
    // Kennung allein saehe das nicht.
    Map<String, Object?>? liste;
    Map<String, Object?>? neuesBuendel;
    final f = await fremderMitZwei(() => liste, karte: () => neuesBuendel ?? {});
    final gs7neu = PrivateKey.generate();
    neuesBuendel = f.fremd.karte();
    Geraeteliste fassung(int e, List<GeraeteEintrag> g) => Geraeteliste.unterschreibe(
        identitaet: f.fremd.identitaet,
        geraeteschluessel: f.gs1,
        epoche: e,
        geraete: g,
        unterzeichner: 1);
    liste = fassung(1, [f.e1, f.e7]).alsJson();
    lage.listen[f.fremd.adresse] = liste;
    await kern.sendMessage(f.fremd.adresse, 'an das alte Geraet 7');
    expect(await warteBis(() => geraeteAn(f.fremd.adresse, 0).length == 2), isTrue);
    /// Gegen welchen signierten Prekey der letzte Umschlag an Geraet 7 gebaut
    /// ist. Solange keine Antwort kam, traegt jeder Umschlag das noch mit.
    int spkVonGeraet7() {
      final u = lage.gesendet
          .lastWhere((s) => s.an == f.fremd.adresse && s.geraet == 7)
          .umschlag;
      final env = Envelope.fromBytes(u);
      expect(env.startetSitzung, isTrue);
      return PreKeySignalMessage.deserialize(data: env.ciphertext).signedPreKeyId();
    }
    final alt = spkVonGeraet7();

    // Das neue Geraet 7: eigenes Buendel, eigener Geraeteschluessel.
    final speicher7 = BitdmSignalStore(identity: f.fremd.identitaet);
    final karte7 = await legePrekeysAb(speicher7,
        spkId: 77, kyberId: 770, preKeyId: 7700);
    neuesBuendel = {
      ...f.fremd.karte(),
      'geraete': [
        f.fremd.geraetekarte(1),
        {'device_id': 7, ...karte7},
      ],
    };
    liste = fassung(2, [f.e1, GeraeteEintrag(7, rohOeffentlich(gs7neu), '')]).alsJson();
    lage.listen[f.fremd.adresse] = liste;
    kern.ablageFuerTest.setzeGeraeteGeprueft(f.fremd.adresse, 0);
    final ab = lage.gesendet.length;
    await kern.sendMessage(f.fremd.adresse, 'an das neue Geraet 7');
    expect(await warteBis(() => geraeteAn(f.fremd.adresse, ab).length == 2), isTrue);
    expect(alt, isNot(77));
    expect(spkVonGeraet7(), 77,
        reason: 'die Sitzung zum abgemeldeten Geraet 7 darf nicht weiterlaufen — '
            'an das neue Geraet geht ein frischer Aufbau gegen SEINEN Prekey');
  });

  test('POST VON EINEM GERAET AUSSERHALB DER LISTE WIRD NICHT EINMAL '
      'ENTSCHLUESSELT', () async {
    final a = await Absender.neu();
    final gsA = PrivateKey.generate();
    lage.listen[a.adresse] = Geraeteliste.unterschreibe(
      identitaet: a.store.identity,
      geraeteschluessel: gsA,
      epoche: 1,
      geraete: [GeraeteEintrag(1, rohOeffentlich(gsA), '')],
      unterzeichner: 1,
    ).alsJson();
    // EIN KONTAKT: fuer ihn gilt Stufe 2. (Bei einem Fremden, der zum
    // ersten Mal schreibt, gibt es nichts zu schuetzen — dort fragt die App
    // den Relay gar nicht erst.)
    kern.ablageFuerTest.speichereKontakt(Contact(
        id: a.adresse,
        addedAt: DateTime.now().toUtc(),
        state: ContactState.active));
    final angekommen = <Message>[];
    final abo = kern.incomingMessages.listen(angekommen.add);
    final buendel = await buendelAusSpeicher(await eigenerSpeicher());

    // Der Relay behauptet Geraet 7 — die Liste des Absenders kennt es nicht.
    relay().herein(RelayMessage(
        from: a.adresse,
        vonGeraet: 7,
        ciphertext: await a.an(kern.myId, buendel,
            Payload.text('m-7', 'von einem abgemeldeten Geraet', DateTime.now().toUtc())),
        at: DateTime.now().toUtc(),
        q: 701));
    expect(await warteBis(() => relay().bestaetigt.contains(701)), isTrue,
        reason: 'quittiert, damit es nicht bei jedem Verbinden wiederkommt');
    expect(angekommen, isEmpty);
    expect(sitzungen().where((s) => s.startsWith(a.adresse)), isEmpty,
        reason: 'nicht entschluesselt — sonst stuende jetzt eine Sitzung da');

    // GEGENPROBE: derselbe Absender von Geraet 1 kommt an.
    relay().herein(RelayMessage(
        from: a.adresse,
        vonGeraet: 1,
        ciphertext: await a.an(kern.myId, buendel,
            Payload.text('m-1', 'von Geraet 1', DateTime.now().toUtc())),
        at: DateTime.now().toUtc(),
        q: 702));
    expect(await warteBis(() => angekommen.any((m) => m.id == 'm-1')), isTrue);
    expect(angekommen.where((m) => m.id == 'm-7'), isEmpty);
    await abo.cancel();
  });

  test('EIN ALTER RELAY OHNE LISTEN: alles wie bisher, nichts angelegt',
      () async {
    final alt = Relaylage()..liste = [];
    final k = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}alt.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) {
        final r = RelayAttrappe(id, alt);
        alt.gebaut.add(r);
        return r;
      },
    );
    await k.initialize();
    await k.createIdentity();
    await k.connect();
    expect(k.connectionState, ConnectionState.online);
    expect(k.geraeteStand, ListenStand.unbekannt);
    expect(alt.gebaut.last.geraeteSchluessel, isNull);
    expect(alt.listen, isEmpty);
    await k.dispose();
  });
}
