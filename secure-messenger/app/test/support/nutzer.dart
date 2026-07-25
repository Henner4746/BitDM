// nutzer.dart — ein vollstaendiger BitDM-Nutzer fuer Tests.
//
// Echter Kern, echte verschluesselte Datenbank, echter Relay. Nur der
// Schluesselspeicher des Geraets ist ersetzt: er ist ein Plattform-Plugin und
// laeuft ausserhalb eines Telefons nicht. Genau dafuer gibt es die
// Schnittstelle in secret_store.dart.
//
// [neustart] macht, was Android macht: alles schliessen und aus der Datei neu
// aufbauen.

import 'dart:async';

import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';

/// Ein Nutzer mit seinem Geraet. [neustart] wirft alles weg und baut den Kern
/// aus dem auf, was auf der Platte liegt.
class Nutzer {
  Nutzer(this.name, this.pfad, this.relayUri) : tresor = InMemorySecretStore();

  final String name;
  final String pfad;
  final Uri relayUri;
  final InMemorySecretStore tresor;

  late RealMessengerCore core;

  final eingang = <Message>[];
  final kontaktEreignisse = <ContactEvent>[];
  final statusEreignisse = <MessageStatusUpdate>[];
  final _abos = <StreamSubscription<Object?>>[];

  RealMessengerCore _neuerKern() => RealMessengerCore(
        secretStore: tresor,
        databasePath: pfad,
        relayUri: relayUri,
      );

  void _hoere() {
    _abos
      ..add(core.incomingMessages.listen(eingang.add))
      ..add(core.contactEvents.listen(kontaktEreignisse.add))
      ..add(core.messageStatusUpdates.listen(statusEreignisse.add));
  }

  Future<void> starten() async {
    core = _neuerKern();
    _hoere();
    await core.initialize();
  }

  Future<void> neustart() async {
    for (final a in _abos) {
      await a.cancel();
    }
    _abos.clear();
    await core.dispose();
    eingang.clear();
    kontaktEreignisse.clear();
    statusEreignisse.clear();
    core = _neuerKern();
    _hoere();
    final geladen = await core.initialize();
    if (!geladen) throw StateError('$name: Identitaet ueberlebte den Neustart nicht');
  }

  Future<void> aufraeumen() async {
    for (final a in _abos) {
      await a.cancel();
    }
    _abos.clear();
    await core.dispose();
  }

  /// Wartet, bis [pruefung] zutrifft, statt blind zu schlafen.
  static Future<bool> warteBis(bool Function() pruefung,
      {Duration frist = const Duration(seconds: 20)}) async {
    final ende = DateTime.now().add(frist);
    while (!pruefung() && DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return pruefung();
  }
}
