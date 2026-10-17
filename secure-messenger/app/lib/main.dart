import 'dart:async';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'core/nah/funk.dart';
import 'core/real_messenger_core.dart';
import 'core/fido/stick_zugang.dart';
import 'core/lock/geraete_fach.dart';
import 'core/lock/key_vault.dart';
import 'core/lock/vault_store.dart';
import 'core/secret_store.dart';
import 'core/browser/browser_zugang.dart';
import 'core/benachrichtigungen.dart';
import 'core/empfang.dart';
import 'core/push.dart';
import 'themen.dart';
import 'oberflaeche/app_thema.dart';
import 'oberflaeche/home.dart';

export 'oberflaeche/app_thema.dart' show anzeigeThema, bitThema;
export 'oberflaeche/einbrennschutz.dart';
export 'oberflaeche/home.dart' show Home, zugriffsZeilen, zeilenArt;

/// Wohin sich die App verbindet.
///
/// Ueberschreibbar beim Bauen:
///   flutter build apk --dart-define=BITDM_RELAY=https://relay.example.org
///
/// Der Relay darf NIE hinter einem Proxy wie Cloudflare stehen — der saehe
/// sonst zu jeder Verbindung, wer wann mit wem spricht. Genau die Angabe, die
/// diese App vermeiden soll.
const String relayBasis = String.fromEnvironment(
  'BITDM_RELAY',
  defaultValue: 'https://relay.bitdm.net',
);

/// Wo die Anhaenge liegen, wenn es nicht aus dem Relay folgt.
///
/// Leer heisst: aus dem Relay ableiten (relay.X -> dateien.X), wie in jeder
/// Freigabe. Gebraucht wird es fuer den Emulatorlauf gegen den eigenen
/// Rechner: dort laufen Relay (8080) und Lager (8099) unter derselben Adresse
/// auf zwei Ports, und aus 10.0.2.2:8080 laesst sich 8099 nicht erraten.
///   flutter build apk --dart-define=BITDM_RELAY=http://10.0.2.2:8080
///                     --dart-define=BITDM_LAGER=http://10.0.2.2:8099
const String lagerBasis = String.fromEnvironment('BITDM_LAGER');

/// Der Relay als Onion-Dienst — benutzt, wenn "Ueber Tor verbinden" an ist.
///
/// Nur fuer den eingebauten Relay: wer mit einem eigenen BITDM_RELAY baut,
/// bekommt nicht stillschweigend die Onion-Adresse von bitdm.net, sondern
/// gibt seine eigene mit BITDM_RELAY_ONION an (oder keine — dann geht es
/// ueber einen Tor-Ausgang zur normalen Adresse).
const String relayOnion = String.fromEnvironment('BITDM_RELAY_ONION');
// HTTPS SEIT 1.8.1: auch im Onion-Dienst TLS mit dem Zertifikat von
// relay.bitdm.net (Netzweg.zertifikatsName) — der Weg bis Orbot ist sonst ein
// Klartext-Socket, den eine andere App belegen koennte.
const String _relayOnionStandard =
    'https://tpbryhlguq6bhrxzv3qlcqk2ogkrv4hot7auqa54pnmeksaoiwsnuqqd.onion';
Uri? get relayTorUri => relayOnion.isNotEmpty
    ? Uri.parse(relayOnion)
    : (relayBasis == 'https://relay.bitdm.net' ? Uri.parse(_relayOnionStandard) : null);

/// Laeuft die App als Android-App (nicht im Browser auf einem Telefon)?
bool get _aufAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ein Verzeichnis, das dem Betriebssystem gehoert und nicht in Sicherungen
  // oder in den Dateimanager wandert.
  //
  // IM BROWSER GIBT ES DAS NICHT, und der Versuch war bis zum 30.07.2026 der
  // Grund, warum die Web-Fassung nur eine weisse Seite war. path_provider hat
  // keine Web-Umsetzung — path_provider_web steht nicht in pubspec.lock —, und
  // in Chrome kam an dieser Zeile wortwoertlich:
  //   MissingPluginException(No implementation found for method
  //   getApplicationSupportDirectory on channel plugins.flutter.io/path_provider)
  // Gemessen war zu dem Zeitpunkt: <flutter-view> stand da, aber 0 <canvas>,
  // kein <flt-scene-host>, `indexedDB.databases()` leer und sqlite3mc.wasm nie
  // angefragt — main() starb vor dem ersten Bildaufbau.
  //
  // Der leere Weg ist im Browser kein Notbehelf, sondern das Richtige: der
  // Datenbankpfad ist dort nur ein NAME im virtuellen Dateisystem von
  // package:sqlite3 (siehe Kopf von core/store/sqlite_zugang_web.dart — das
  // VFS liegt in IndexedDB, nicht auf einer Platte).
  final String ablageWeg =
      kIsWeb ? '' : (await getApplicationSupportDirectory()).path;

  // Solange kein Faktor eingerichtet ist, liegt die Entropie im
  // Schluesselspeicher des Geraets und die App oeffnet ohne Rueckfrage. Mit
  // dem ersten Faktor wandert sie in ein Schluesselfach und ist ohne ihn nicht
  // mehr zu haben — auch nicht mit Root, auch nicht mit der Datei in der Hand.
  final tresor = VaultSecretStore(
    // IM BROWSER GIBT ES KEINE FACHDATEI, sondern einen Eintrag in
    // localStorage. Bis 25.09.2026 stand hier `File(vaultDateiname)` — das
    // uebersetzt, aber schon das erste `existsSync()` wirft im Browser
    // UnsupportedError (io_patch.dart), und `VaultSecretStore.write` fragt
    // genau das zuerst. "Identitaet erstellen" konnte im Browser also nie
    // gelingen. Was im Eintrag steht, ist so wenig geheim wie die Datei: die
    // Faecher sind mit dem Passwort verschluesselt (browser_zugang_web.dart).
    datei: kIsWeb ? null : vaultDateiIn(ablageWeg),
    ablage: kIsWeb ? browserFachAblage(vaultDateiname) : null,
    // IM BROWSER LIEGT DIE ENTROPIE OHNE APP-PASSWORT NUR IM ARBEITSSPEICHER.
    //
    // Das ist eine Entscheidung, keine Luecke. flutter_secure_storage legt
    // sie im Browser zwar AES-GCM-verschluesselt in localStorage ab — aber
    // den AES-Schluessel gleich daneben, im selben localStorage (nachgelesen
    // in flutter_secure_storage_web-2.1.1/lib/flutter_secure_storage_web.dart:
    // generateKey, exportKey('raw'), dann unter "publicKey" abgelegt). Wer
    // das Browserprofil hat, hat damit die zwoelf Woerter, und mit ihnen den
    // Schluessel der Datenbank. "Verschluesselt im Browser gespeichert" waere
    // in dieser Form eine Behauptung, die nichts traegt.
    //
    // Also: ohne Passwort ueberlebt die Identitaet das Neuladen der Seite
    // NICHT, und die Oberflaeche sagt das dauerhaft an (_WebHinweis). Die
    // Datenbank bleibt verschluesselt in IndexedDB liegen und geht mit den
    // zwoelf Woertern wieder auf. MIT App-Passwort wandert die Entropie wie
    // auf dem Rechner in ein Fach, das nur das Passwort oeffnet (Argon2id),
    // und dann bleibt alles ueber den Neustart erhalten — verschluesselt.
    basis: kIsWeb ? InMemorySecretStore() : DeviceSecretStore(),
    jetzt: () => DateTime.now().millisecondsSinceEpoch,
  );

  final core = RealMessengerCore(
    secretStore: tresor,
    databasePath: kIsWeb ? 'bitdm.db' : '$ablageWeg/bitdm.db',
    relayUri: Uri.parse(relayBasis),
    relayUriTor: relayTorUri,
    lagerUri: lagerBasis.isEmpty ? null : Uri.parse(lagerBasis),
  );

  // Benachrichtigungen vorbereiten. Die ERLAUBNIS wird bewusst nicht hier
  // abgefragt: eine App, die vor dem ersten Bildschirm danach fragt, bekommt
  // meistens ein Nein. Gefragt wird, wenn die erste Unterhaltung zustande
  // kommt — dann ist klar, wofuer.
  await Benachrichtigungen.instanz.starte();

  final zustand = AppState(
    core,
    tresor: tresor,
    stickZugang: (weg) => stickOeffner(weg)(),
    // Die Fachschluessel liegen neben der Fachdatei, verschluesselt mit
    // einem Schluessel aus dem gesicherten Bereich des Geraets.
    //
    // Im Browser bleibt der Weg leer und dieser Rueckruf ungenutzt: er gilt nur
    // fuer Geraetesperre und Biometrie, und [_faktorGehtHier] laesst dort nur
    // 'pw' durch — beide Faktoren sind an [_nurAufAndroid] gebunden.
    ablagen: (art) => GeraeteFach(
      art == UnlockFactorKind.deviceCredential
          ? GeraeteArt.geraetesperre
          : GeraeteArt.biometrie,
      verzeichnis: ablageWeg,
    ),
  )
    // DER HINTERGRUNDEMPFANG IST ANDROID. Am Rechner und im Browser gibt es
    // den Kanal bitdm/empfang nicht; mit dem Dienst hier trennte das
    // Verdecken des Fensters die Verbindung und sah danach nur alle 15
    // Minuten nach. Dort bleibt die Leitung einfach stehen.
    ..empfangsDienst = _aufAndroid ? EmpfangsDienst() : null
    ..verbindungImHintergrund = !_aufAndroid
    // Die Bluetooth-Strecke. Hier angehaengt und nicht im Konstruktor
    // verlangt, weil sie in Tests fehlt: `flutter test` hat keine
    // Plattformkanaele, und ein Pflichtfeld haette jeden Zustandstest an
    // Bluetooth gebunden.
    //
    // IM BROWSER GAR NICHT: `horcheAuf()` legt sich auf den EventChannel
    // bitdm/nahfunk_ereignisse, und den gibt es dort nicht. Gemessen am
    // 30.07.2026 in Chrome, wortwoertlich in der Konsole bei jedem Start:
    // "MissingPluginException(No implementation found for method listen on
    // channel bitdm/nahfunk_ereignisse)". Toedlich war das nicht — der Wurf
    // kommt aus einem unbeobachteten Future und die App baute trotzdem auf —,
    // aber nachbaubar ist Nahfunk im Browser eben auch nicht: Web Bluetooth
    // kennt kein Werben und kein Lauschen. `funk` bleibt also null, und alle
    // Aufrufer pruefen darauf (app_state.dart:1129, 1145, 1169).
    //
    // AUF DEM DESKTOP EBENSO NICHT (seit 25.09.2026): der Kanal existiert nur in
    // NahfunkKanal.kt, und die Windows-Fassung schrieb bei jedem Start dieselbe
    // MissingPluginException ins Protokoll.
    ..funk = _aufAndroid ? (Nahfunk()..horcheAuf()) : null;

  // Die Rueckrufe des Verteilers MUESSEN bei jedem Start stehen, nicht erst
  // wenn der Nutzer etwas einstellt: ein Anstoss kann kommen, bevor er die App
  // ueberhaupt angefasst hat.
  zustand.push = PushAnbindung(
    beiEndpunkt: (e) => unawaited(zustand.nimmPushEndpunkt(e)),
    beiAnstoss: () => unawaited(zustand.beiAnstoss()),
    beiAbmeldung: () => unawaited(zustand.setzeEmpfangsTakt(EmpfangsTakt.aus)),
  );
  if (zustand.empfangsTakt.angestossen) {
    unawaited(zustand.push!.starte());
  }

  runApp(BitApp(state: zustand));
}

class BitApp extends StatelessWidget {
  const BitApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Thema>(
      valueListenable: anzeigeThema,
      builder: (_, thema, _) => MaterialApp(
        title: 'BitDM',
        debugShowCheckedModeBanner: false,
        theme: bitThema(thema.pal,
            dunkel: thema.dunkel, mono: thema.monoSchrift, text: thema.textSchrift),
        home: Home(state: state),
      ),
    );
  }
}
