// pc_kontakt_test.dart — der PC als echter BitDM-Kontakt (Nahbereich, Richtung 2).
//
// SEIT 26.09.2026. Bisher war nur bewiesen, dass eine fremde Gegenstelle ins
// Postfach eines Telefons schreiben kann (ESP32, Richtung 1). Offen war: das
// Telefon schickt VON SICH AUS eine verschluesselte Nachricht ueber Bluetooth.
// Dafuer braucht es eine Gegenstelle, die BitDM wirklich spricht — Identitaet,
// Signal-Sitzung, Leuchtfeuer. Das ist hier der echte Kern, nur mit
// [PcFunk] (Python-Bruecke, Windows-Bluetooth) statt des Kotlin-Kanals.
//
// KEIN NORMALER TEST: liegt ausserhalb von test/ und laeuft nur von Hand.
//
//   flutter test test_manuell/pc_kontakt_test.dart
//
// Umgebungsvariablen:
//   BITDM_GEGENUEBER  Adresse des Telefons (einmal: Kontaktanfrage)
//   BITDM_MINUTEN     wie lange der Kontakt lauscht (Vorgabe 20)
//   BITDM_NUR_NAH     1 = der PC selbst benutzt keinen Server (Antworten nur per Funk)
//
// Ablage (Identitaet, Datenbank, Protokoll): %LOCALAPPDATA%\bitdm-pc-kontakt
// Die Identitaet bleibt ueber Laeufe erhalten; es ist ein Testkontakt.
//
// Jede ankommende Nachricht wird beantwortet ("Antwort vom PC"), damit auch
// der Rueckweg sichtbar wird.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:bitdm/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pc_funk.dart';

/// Schluesselspeicher in einer Datei — der Testkontakt soll einen Neustart
/// ueberleben, sonst muesste das Telefon ihn jedes Mal neu annehmen.
class DateiSpeicher implements SecretStore {
  DateiSpeicher(this.datei);
  final File datei;
  @override
  Future<Uint8List?> read() async => datei.existsSync() ? datei.readAsBytesSync() : null;
  @override
  Future<void> write(Uint8List e) async => datei.writeAsBytesSync(e, flush: true);
  @override
  Future<void> delete() async {
    if (datei.existsSync()) datei.deleteSync();
  }
}

void main() {
  test('PC-KONTAKT: lauscht per Bluetooth und antwortet', () async {
    final umg = Platform.environment;
    final ordner = Directory('${umg['LOCALAPPDATA']}\\bitdm-pc-kontakt')..createSync(recursive: true);
    final protokollDatei = File('${ordner.path}\\protokoll.txt');
    void p(String s) {
      final z = '${DateTime.now().toIso8601String().substring(11, 19)} $s';
      // ignore: avoid_print
      print(z);
      protokollDatei.writeAsStringSync('$z\n', mode: FileMode.append, flush: true);
    }

    final minuten = int.tryParse(umg['BITDM_MINUTEN'] ?? '') ?? 20;
    final gegenueber = (umg['BITDM_GEGENUEBER'] ?? '').trim().toLowerCase();
    final nurNah = umg['BITDM_NUR_NAH'] == '1';

    final skript = File('../tools/pc_kontakt/pc_funk_bruecke.py').absolute.path;
    final bruecke = await FunkBruecke.starte(skript, protokoll: p);
    addTearDown(bruecke.beende);

    final core = RealMessengerCore(
      secretStore: DateiSpeicher(File('${ordner.path}\\identitaet.bin')),
      databasePath: '${ordner.path}\\pc.db',
      relayUri: Uri.parse('https://relay.bitdm.net'),
      nahFactory: () {
        final n = Nahbereich(funk: PcFunk(bruecke, protokoll: p));
        // Wen der Nahbereich als Kontakt in Reichweite erkennt — der Beweis,
        // dass die Leuchtfeuer beider Seiten zueinander passen.
        n.neuInReichweite.listen((a) => p('IN REICHWEITE: ${a.substring(0, 8)}…'));
        return n;
      },
    );
    addTearDown(core.dispose);

    core.contactEvents.listen((e) => p('KONTAKT: ${e.type.name} ${e.contactId.substring(0, 8)}…'));
    core.messageStatusUpdates.listen((s) => p('STATUS: ${s.messageId} -> ${s.status.name}'));
    core.connectionStateChanges.listen((c) => p('RELAY: ${c.name}'));
    core.incomingMessages.listen((m) async {
      p('NACHRICHT von ${m.senderId.substring(0, 8)}…: "${m.text}"'
          '${m.ueberNaehe ? '  (UEBER BLUETOOTH)' : '  (ueber Relay)'}');
      try {
        final a = await core.sendMessage(m.chatId,
            'Antwort vom PC auf "${m.text}" (${DateTime.now().toIso8601String().substring(11, 19)})');
        p('ANTWORT verschickt: ${a.id}');
      } catch (e) {
        p('ANTWORT gescheitert: $e');
      }
    });

    await core.initialize();
    if (!core.hasIdentity) {
      final woerter = await core.createIdentity();
      p('neue Testidentitaet angelegt (${woerter.length} Woerter)');
    }
    p('PC-ADRESSE: ${core.myId}');
    File('${ordner.path}\\adresse.txt').writeAsStringSync(core.myId);

    final vorher = await core.getPreferences();
    await core.setPreferences(vorher.copyWith(naheAn: true, nurNahbereich: nurNah));
    p('Nahbereich an${nurNah ? ', nur in der Naehe' : ''}');

    if (!nurNah) await core.connect();

    if (gegenueber.isNotEmpty) {
      final bekannt = (await core.getContacts()).any((k) => k.id == gegenueber);
      if (!bekannt) {
        await core.addContact(gegenueber);
        p('Kontaktanfrage an ${gegenueber.substring(0, 8)}… geschickt — bitte auf dem Telefon annehmen');
      } else {
        p('Telefon ist schon Kontakt');
      }
    }

    final ende = DateTime.now().add(Duration(minutes: minuten));
    p('lausche bis ${ende.toIso8601String().substring(11, 19)}');
    while (DateTime.now().isBefore(ende)) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (File('${ordner.path}\\stopp').existsSync()) {
        File('${ordner.path}\\stopp').deleteSync();
        p('Stopp-Datei gefunden');
        break;
      }
    }
    p('Ende');
  }, timeout: const Timeout(Duration(hours: 2)));
}
