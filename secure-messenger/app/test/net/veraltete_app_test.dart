// veraltete_app_test.dart — "Der Kontakt muss BitDM aktualisieren", am
// ECHTEN Kern.
//
// SEIT 2.0.0 baut die App nur noch PQXDH-Sitzungen. Hat ein Kontakt nur
// Geraete mit einer App vor 2.0.0, liegt beim Relay kein Buendel mit Kyber,
// und `_bauSitzungen` wirft GegenstelleOhneKyberException. Bis 17.10.2026
// stand die Nachricht dann stumm auf "wird gesendet": der Fall "HAT KEIN
// GERAET KYBER" in mehrgeraete_riegel_test.dart hielt das fest, und kein Weg
// reichte die Ausnahme nach oben durch.
//
// Jetzt traegt der Kontakt den Vermerk [Contact.brauchtNeuereApp]. Hier wird
// gemessen, wann er entsteht und wann er wieder faellt:
//   - beim Senden an eine alte App: gesetzt, EIN Ereignis, die Nachricht
//     bleibt im Nachversand,
//   - jeder weitere vergebliche Versuch: kein weiteres Ereignis,
//   - hat die Gegenstelle aktualisiert und liefert der Relay ein Buendel mit
//     Kyber: der Vermerk faellt, die Nachricht geht hinaus,
//   - schreibt die aktualisierte Gegenstelle zuerst: ihre Erstnachricht baut
//     die Sitzung, der Vermerk faellt, und die wartende Nachricht geht sofort
//     ueber diese Sitzung hinaus, ohne neues Buendel.
//
// MUTATIONSPROBE: `_merkeAppFassung` -> `return false` macht alle drei Faelle
// rot; ohne den Aufruf in `_nimmUmschlagJetzt` wird der dritte rot.

import 'dart:io';

import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/net/payload.dart';
import 'package:bitdm/core/net/relay_client.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/store/signal_store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/absender.dart';
import '../support/relay_attrappe.dart';
import '../support/signal_hilfe.dart';

/// Dieselbe Karte, wie sie eine App VOR 2.0.0 beim Relay hinterlaesst: die
/// Kyber-Felder fehlen ganz (relay_server.py laesst sie weg, nicht als null).
Map<String, Object?> ohneKyber(Map<String, Object?> karte) => Map.of(karte)
  ..removeWhere((k, _) => const [
        'kyber_prekey_id',
        'kyber_prekey',
        'kyber_prekey_sig',
        'kyber_einmal',
      ].contains(k));

void main() {
  late Directory ordner;
  late Relaylage lage;
  late RealMessengerCore kern;
  late List<String> woerter;
  late ZaehlRelay relay;
  late List<ContactEvent> ereignisse;

  Future<bool> warteBis(bool Function() fertig,
      {Duration frist = const Duration(seconds: 5)}) async {
    final ende = DateTime.now().add(frist);
    while (!fertig() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return fertig();
  }

  setUpAll(signalBereit);

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-veraltete-app');
    lage = Relaylage();
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
      relayFactory: (uri, id) => relay = ZaehlRelay(id, lage),
    );
    kern.quittungsVerzug = () => Duration.zero;
    await kern.initialize();
    woerter = await kern.createIdentity();
    await kern.connect();
    ereignisse = <ContactEvent>[];
    final abo = kern.contactEvents.listen(ereignisse.add);
    addTearDown(abo.cancel);
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Windows gibt Handles verzoegert frei.
    }
  });

  void kontakt(String adresse) =>
      kern.ablageFuerTest.speichereKontakt(Contact(
          id: adresse,
          addedAt: DateTime.now().toUtc(),
          state: ContactState.active));

  bool vermerkt(String adresse) =>
      kern.ablageFuerTest.kontakt(adresse)!.brauchtNeuereApp;

  int wechsel(String adresse) => ereignisse
      .where((e) =>
          e.type == ContactEventType.needsUpdateChanged &&
          e.contactId == adresse)
      .length;

  bool wartet(String id) =>
      kern.ablageFuerTest.unversandt().any((u) => u.id == id);

  bool ging(String adresse) => lage.gesendet.any((g) => g.an == adresse);

  Future<void> neuVerbinden() async {
    await kern.disconnect();
    await kern.connect();
  }

  test('EINE ALTE APP: DER KONTAKT BEKOMMT DEN VERMERK, DIE NACHRICHT WARTET',
      () async {
    final dora = await Absender.neu();
    kontakt(dora.adresse);
    lage.buendel = (_) => ohneKyber(dora.karte());
    expect(vermerkt(dora.adresse), isFalse, reason: 'die Ausgangslage');

    final m = await kern.sendMessage(dora.adresse, 'kommt erst nach dem Update');
    expect(await warteBis(() => vermerkt(dora.adresse)), isTrue,
        reason: 'DIE LUECKE: ohne Vermerk stand die Nachricht stumm auf '
            '"wird gesendet"');
    expect(wechsel(dora.adresse), 1,
        reason: 'die Oberflaeche laedt die Kontakte nur auf ein Ereignis neu');
    expect(wartet(m.id), isTrue,
        reason: 'liegengeblieben, nicht gescheitert — der Nachversand holt sie');
    expect(ging(dora.adresse), isFalse);

    // EIN ZWEITER VERGEBLICHER VERSUCH meldet nichts Neues. Jedes Verbinden
    // holt das Buendel wieder (IST-Verhalten, mehrgeraete_riegel_test); ein
    // Ereignis je Versuch liesse die Oberflaeche jedes Mal neu laden.
    final abrufe = lage.buendelAbrufe;
    await neuVerbinden();
    expect(await warteBis(() => lage.buendelAbrufe > abrufe), isTrue,
        reason: 'ohne zweiten Versuch misst das nichts');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(vermerkt(dora.adresse), isTrue);
    expect(wechsel(dora.adresse), 1);
  });

  test('HAT DIE GEGENSTELLE AKTUALISIERT, FAELLT DER VERMERK, UND DIE '
      'NACHRICHT GEHT HINAUS', () async {
    final dora = await Absender.neu();
    kontakt(dora.adresse);
    lage.buendel = (_) => ohneKyber(dora.karte());
    final m = await kern.sendMessage(dora.adresse, 'wartet auf das Update');
    expect(await warteBis(() => vermerkt(dora.adresse)), isTrue);

    // DORA AKTUALISIERT: derselbe Schluessel, jetzt mit Kyber beim Relay.
    lage.buendel = (_) => dora.karte();
    await neuVerbinden();

    expect(await warteBis(() => ging(dora.adresse)), isTrue,
        reason: 'der Nachversand muss sie nach dem Update hinausschicken');
    expect(await warteBis(() => !wartet(m.id)), isTrue);
    expect(vermerkt(dora.adresse), isFalse,
        reason: 'mit einer Sitzung stimmt der Hinweis nicht mehr');
    expect(wechsel(dora.adresse), 2, reason: 'gesetzt und wieder geloescht');
  });

  test('SCHREIBT DIE AKTUALISIERTE GEGENSTELLE ZUERST, FAELLT DER VERMERK '
      'SOFORT — UND WAS WARTET, GEHT UEBER IHRE SITZUNG', () async {
    final dora = await Absender.neu();
    kontakt(dora.adresse);
    lage.buendel = (_) => ohneKyber(dora.karte());
    final m = await kern.sendMessage(dora.adresse, 'wartet auf Doras Zeile');
    expect(await warteBis(() => vermerkt(dora.adresse)), isTrue);
    final abrufe = lage.buendelAbrufe;

    // Dora hat aktualisiert und schreibt, BEVOR wir wieder verbinden. Ihre
    // Erstnachricht ist PQXDH — sonst entschluesselte libsignal sie nicht.
    final eigenes = await buendelAusSpeicher(
        SignalStoreRepository(kern.datenbankFuerTest)
            .openStore(await KeyDerivation.fromMnemonic(woerter)));
    final umschlag = await dora.an(kern.myId, eigenes,
        Payload.text('d-1', 'ich habe aktualisiert', DateTime.now().toUtc()));
    relay.herein(RelayMessage(
        from: dora.adresse,
        ciphertext: umschlag,
        at: DateTime.now().toUtc(),
        q: 77));

    expect(await warteBis(() => relay.bestaetigt.contains(77)), isTrue,
        reason: 'Doras Erstnachricht muss ankommen, sonst misst das nichts');
    expect(vermerkt(dora.adresse), isFalse,
        reason: 'wer mit Kyber schreibt, hat aktualisiert');
    expect(wechsel(dora.adresse), 2);
    // NICHT "ging etwas an Dora": die Empfangsquittung fuer ihre Zeile geht
    // ohnehin hinaus. Gefragt ist, ob die WARTENDE Nachricht draussen ist.
    expect(await warteBis(() => !wartet(m.id)), isTrue,
        reason: 'die wartende Nachricht soll nicht bis zum naechsten '
            'Verbinden liegen bleiben');
    expect(lage.buendelAbrufe, abrufe,
        reason: 'die Sitzung steht schon — ein neues Buendel braeuchte es '
            'nicht, und es zoege beim Relay einen Einmalschluessel');
  });
}
