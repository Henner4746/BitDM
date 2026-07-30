// anwesenheit_test.dart — die zwei neuen Spalten, ueber einen Neustart hinweg.
//
// Warum das einen eigenen Test verdient: beide Felder haben einen Standardwert,
// und ein Feld mit Standardwert, das nie gelesen wird, sieht im Betrieb genau
// so aus wie eines, das richtig funktioniert. `zeigtAnwesenheit` waere immer
// true, `ueberNaehe` immer false — also genau das, was auch ohne jede
// Speicherung herauskaeme. Erst der Neustart trennt beides.

import 'dart:io';

import 'package:bitdm/core/errors.dart';
import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

class SpeicherImKopf implements SecretStore {
  Uint8List? _i;
  @override
  Future<Uint8List?> read() async => _i;
  @override
  Future<void> write(Uint8List e) async => _i = e;
  @override
  Future<void> delete() async => _i = null;
}

void main() {
  late Directory ordner;
  late SpeicherImKopf speicher;
  late String db;

  /// Oeffnet denselben Bestand noch einmal — wie ein App-Neustart.
  Future<RealMessengerCore> kern() async {
    final k = RealMessengerCore(
      secretStore: speicher,
      databasePath: db,
      relayUri: Uri.parse('http://127.0.0.1:1'),
    );
    await k.initialize();
    return k;
  }

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-anwesenheit');
    speicher = SpeicherImKopf();
    db = '${ordner.path}${Platform.pathSeparator}t.db';
    final k = await kern();
    await k.createIdentity();
    await k.dispose();
  });

  tearDown(() async {
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  /// Eine gueltige fremde Adresse — addContact prueft die Pruefsumme.
  Future<String> fremdeAdresse() async {
    final o = await Directory.systemTemp.createTemp('bitdm-fremd');
    final k = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${o.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
    );
    await k.initialize();
    await k.createIdentity();
    final id = k.myId;
    await k.dispose();
    try {
      await o.delete(recursive: true);
    } catch (_) {}
    return id;
  }

  test('ANWESENHEIT UEBERLEBT DEN NEUSTART', () async {
    final wer = await fremdeAdresse();

    var k = await kern();
    await k.addContact(wer);
    expect((await k.getContacts()).single.zeigtAnwesenheit, isTrue,
        reason: 'ab Werk sieht man sich — eine Ausfallsicherung, die man erst '
            'je Kontakt einschalten muss, waere keine');

    await k.setContactPresence(wer, false);
    expect((await k.getContacts()).single.zeigtAnwesenheit, isFalse);
    await k.dispose();

    // DER PUNKT: neu geoeffnet.
    k = await kern();
    expect((await k.getContacts()).single.zeigtAnwesenheit, isFalse,
        reason: 'sonst zeigt man sich nach jedem App-Start wieder jemandem, '
            'vor dem man sich ausdruecklich verborgen hat');
    await k.setContactPresence(wer, true);
    await k.dispose();

    k = await kern();
    expect((await k.getContacts()).single.zeigtAnwesenheit, isTrue);
    await k.dispose();
  });

  test('ein unbekannter Kontakt wird abgewiesen', () async {
    final k = await kern();
    await expectLater(k.setContactPresence('gibtesnicht', false),
        throwsA(isA<MessengerException>()));
    await k.dispose();
  });

  test('zweimal dasselbe setzen aendert nichts und wirft nicht', () async {
    final wer = await fremdeAdresse();
    final k = await kern();
    await k.addContact(wer);
    await k.setContactPresence(wer, true); // war schon true
    expect((await k.getContacts()).single.zeigtAnwesenheit, isTrue);
    await k.dispose();
  });

  test('DAS ZEICHEN AN EINER NACHRICHT UEBERLEBT DEN NEUSTART', () async {
    // Bis die Wegwahl am Nachrichtenweg haengt, setzt noch niemand
    // `ueberNaehe` — der Weg dorthin muss aber schon jetzt tragen, sonst
    // faellt beim Anschliessen nicht auf, dass die Spalte nie gelesen wird.
    final wer = await fremdeAdresse();
    var k = await kern();
    await k.addContact(wer);
    await k.dispose();

    // Direkt in die Ablage schreiben, wie es der Empfang tun wird.
    k = await kern();
    k.ablageFuerTest.speichereEigene(Message(
      id: 'abc123',
      chatId: wer,
      senderId: 'ich',
      text: 'direkt',
      isMine: true,
      timestamp: DateTime.now().toUtc(),
      ueberNaehe: true,
    ));
    await k.dispose();

    k = await kern();
    final m = (await k.getMessages(wer)).single;
    expect(m.ueberNaehe, isTrue,
        reason: 'ohne das bliebe das Zeichen nach dem naechsten Start weg, '
            'und dieselbe Nachricht saehe ploetzlich aus, als waere sie ueber '
            'den Server gegangen');
    await k.dispose();
  });
}
