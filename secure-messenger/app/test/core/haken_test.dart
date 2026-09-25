// haken_test.dart — ein Haken darf nicht zurueckfallen.
//
// DER FEHLER, DEN ES HIERHER GEBRACHT HAT
//
// Die Zustaende einer Nachricht sind eine Reihenfolge:
//   sending -> sent -> delivered -> read
//
// `setzeStatus` schrieb bedingungslos. Damit konnte ein spaeter Aufruf einen
// frueheren Zustand zurueckschreiben — und genau das passiert im Betrieb:
//
//   Die Nachricht geht raus, die Gegenseite liest sie (read). Danach laeuft
//   der Nachversand noch einmal ueber dieselbe Nachricht — etwa weil sie
//   ueber beide Wege ging, Relay UND Naehe — und setzt "sent".
//
// Aus zwei Haken wird wieder einer. Der Nutzer sieht eine gelesene Nachricht
// ungelesen werden und hat dafuer keine Erklaerung; schlimmer noch, er
// schliesst daraus, dass sie NICHT angekommen ist.
//
// Es ist die Sorte Fehler, die niemand als Fehler meldet, weil er wie ein
// Zufall aussieht.

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/models.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

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
  late RealMessengerCore kern;

  final chat = 'b' * 56;
  const nachricht = 'm-1';

  setUp(() async {
    ordner = await Directory.systemTemp.createTemp('bitdm-haken');
    kern = RealMessengerCore(
      secretStore: SpeicherImKopf(),
      databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
      relayUri: Uri.parse('http://127.0.0.1:1'),
    );
    await kern.initialize();
    await kern.createIdentity();
    kern.ablageFuerTest.speichereEigene(Message(
      id: nachricht,
      chatId: chat,
      senderId: kern.myId,
      text: 'hallo',
      kind: MessageKind.text,
      isMine: true,
      timestamp: DateTime.now().toUtc(),
      status: MessageStatus.sending,
    ));
  });

  tearDown(() async {
    await kern.dispose();
    try {
      await ordner.delete(recursive: true);
    } catch (_) {}
  });

  MessageStatus stand() =>
      kern.ablageFuerTest.verlauf(chat).single.status;

  void setze(MessageStatus s) =>
      kern.ablageFuerTest.setzeStatus(chat, kern.myId, nachricht, s);

  test('EIN GELESENER HAKEN FAELLT NICHT AUF "GESENDET" ZURUECK', () {
    setze(MessageStatus.sent);
    setze(MessageStatus.delivered);
    setze(MessageStatus.read);
    expect(stand(), MessageStatus.read);

    // Der Nachversand laeuft ein zweites Mal ueber dieselbe Nachricht.
    setze(MessageStatus.sent);

    expect(stand(), MessageStatus.read,
        reason: 'aus zwei Haken wurde wieder einer — der Nutzer haelt eine '
            'gelesene Nachricht fuer nicht angekommen');
  });

  test('und auch "zugestellt" faellt nicht zurueck', () {
    setze(MessageStatus.delivered);
    setze(MessageStatus.sending);
    expect(stand(), MessageStatus.delivered);
  });

  test('VORWAERTS GEHT WEITERHIN, sonst waere nichts gewonnen', () {
    // Die Gegenprobe. Eine Sperre, die auch den Fortschritt aufhaelt, waere
    // schlimmer als der Fehler: dann bliebe jede Nachricht auf "wird
    // gesendet" stehen.
    setze(MessageStatus.sent);
    expect(stand(), MessageStatus.sent);
    setze(MessageStatus.delivered);
    expect(stand(), MessageStatus.delivered);
    setze(MessageStatus.read);
    expect(stand(), MessageStatus.read);
  });

  test('"gescheitert" laesst sich immer setzen — und wieder aufheben', () {
    // `failed` steht in der Reihenfolge hinten, ist aber kein Fortschritt,
    // sondern ein Abbruch. Beide Richtungen muessen gehen: sonst liesse sich
    // entweder eine gescheiterte Nachricht nicht kennzeichnen, oder eine, die
    // beim naechsten Anlauf doch rausging, bliebe fuer immer als gescheitert
    // stehen.
    setze(MessageStatus.read);
    setze(MessageStatus.failed);
    expect(stand(), MessageStatus.failed);

    setze(MessageStatus.sent);
    expect(stand(), MessageStatus.sent,
        reason: 'ein spaeter gelungener Versand muss das Scheitern aufheben');
  });

  test('die Wegmarke bleibt erhalten, auch wenn der Status stehenbleibt', () {
    // `ueber_naehe` sagt, WIE eine Nachricht ging, nicht WIE WEIT sie ist.
    // Sie darf auch dann noch nachgetragen werden, wenn der Status sich nicht
    // mehr bewegt — sonst verloere eine ueber die Naehe zugestellte Nachricht
    // ihr Zeichen, nur weil der Haken schon weiter war.
    setze(MessageStatus.read);
    kern.ablageFuerTest.setzeStatus(
        chat, kern.myId, nachricht, MessageStatus.sent,
        ueberNaehe: true);

    expect(stand(), MessageStatus.read);
    expect(kern.ablageFuerTest.verlauf(chat).single.ueberNaehe, isTrue,
        reason: 'das Zeichen "ohne Server gegangen" ging verloren');
  });

  test('Quittungen warten zufaellig 0,3 bis 2,5 s — gegen Zuordnung ueber die Zeit', () {
    final werte = [for (var i = 0; i < 40; i++) kern.quittungsVerzug().inMilliseconds];
    expect(werte.every((v) => v >= 300 && v < 2500), isTrue, reason: '$werte');
    expect(werte.toSet().length, greaterThan(10), reason: 'der Verzug ist nicht zufaellig');
  });

  test('ein Stern ueberlebt das Neulesen, eine zurueckgenommene faellt heraus', () {
    final ablage = kern.ablageFuerTest;
    expect(ablage.setzeStern(chat, nachricht, true), isTrue);
    expect(ablage.verlauf(chat).single.sternAm, isNotNull);
    expect(ablage.sterne().map((m) => m.id), [nachricht]);
    expect(ablage.setzeStern(chat, 'gibt-es-nicht', true), isFalse);
    ablage.setzeStern(chat, nachricht, false);
    expect(ablage.sterne(), isEmpty);
  });

  test('eine Lesebestaetigung fuer eine spaetere Nachricht verschickt keine fruehere',
      () {
    // m-1 (aus setUp) haengt noch auf "sending" — geplant oder im Funkloch.
    // m-2 ist draussen, m-3 ebenfalls; die Gegenseite liest bis m-3.
    final ablage = kern.ablageFuerTest;
    for (final id in ['m-2', 'm-3']) {
      ablage.speichereEigene(Message(
        id: id,
        chatId: chat,
        senderId: kern.myId,
        text: id,
        kind: MessageKind.text,
        isMine: true,
        timestamp: DateTime.now().toUtc(),
        status: MessageStatus.sending,
      ));
      ablage.setzeStatus(chat, kern.myId, id, MessageStatus.delivered);
    }
    ablage.markiereGelesenBis(chat, kern.myId, ablage.seqVon(chat, 'm-3', kern.myId)!);

    MessageStatus von(String id) =>
        ablage.verlauf(chat).singleWhere((m) => m.id == id).status;
    expect(von('m-1'), MessageStatus.sending,
        reason: 'eine nie verschickte Nachricht stand auf "gelesen" und waere '
            'nie mehr nachgeschickt worden');
    expect(ablage.unversandt().map((m) => m.id), contains('m-1'));
    expect(von('m-2'), MessageStatus.read);
    expect(von('m-3'), MessageStatus.read);
  });
}
