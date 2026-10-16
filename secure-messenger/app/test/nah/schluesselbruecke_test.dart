// schluesselbruecke_test.dart — rechnen beide Bibliotheken dasselbe?
//
// DIE FRAGE, AN DER DER GANZE NAHEBEREICH HAENGT
//
// Das Leuchtfeuer braucht ein gemeinsames Geheimnis aus X25519. Es gibt im
// Projekt aber ZWEI Wege dorthin:
//
//   libsignal    `PrivateKey.agree(publicKey: fremderOeffentlicher)`
//                — das ist der Schluessel, den die App ohnehin hat
//                (real_messenger_core `_nahGeheimnis`).
//   cryptography `X25519().sharedSecretKey(...)`
//                — das benutzt leuchtfeuer.dart.
//
// Beide sind X25519 nach RFC 7748 und muessen dieselben 32 Byte liefern.
// "Muessen" ist hier aber genau die Sorte Annahme, die dieses Projekt schon
// zweimal Tage gekostet hat: die 33-gegen-32-Byte-Falle bei libsignal
// (ein vorangestelltes Typbyte) und `Ecdh.p256`, das UnimplementedError wirft.
//
// Waeren die Ergebnisse verschieden, wuerde nichts abstuerzen und nichts
// scheitern. Zwei Telefone wuerden nur nie voneinander Notiz nehmen — der
// unangenehmste denkbare Fehler, weil er wie "Bluetooth ist halt unzuverlaessig"
// aussieht.
//
// SEIT 2.0.0 rechnet die libsignal-Seite ueber Signals offizielle Bibliothek
// (Rust) statt ueber die Dart-Nachbildung. Die Frage ist dieselbe geblieben,
// die Antwort musste neu gemessen werden. Neu dazu kommt eine Eigenheit der
// offiziellen Bibliothek: sie wirft bei einem Schluessel niedriger Ordnung,
// statt 32 Nullbytes zu liefern (Gruppe darunter).

import 'dart:io';
import 'dart:typed_data';

import 'package:bitdm/core/crypto/address.dart';
import 'package:bitdm/core/crypto/bip39.dart';
import 'package:bitdm/core/crypto/key_derivation.dart';
import 'package:bitdm/core/crypto/signal_identity.dart';
import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/nah/leuchtfeuer.dart';
import 'package:bitdm/core/nah/nahbereich.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

import '../support/funk_attrappe.dart';
import '../support/relay_attrappe.dart' show SpeicherImKopf;
import '../support/signal_hilfe.dart';

/// Eine Identitaet, genau so gebaut wie in der App.
///
/// Nicht mit `IdentityKeyPair.generate()` abgekuerzt: der Weg ueber die Phrase
/// ist der einzige, den die App wirklich geht, und ein Test, der einen
/// anderen nimmt, prueft einen Schluessel, den es nie gibt.
Future<SignalIdentity> neueIdentitaet() async {
  final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
  return SignalIdentityBridge.fromDerived(keys,
      registrationId: SignalIdentityBridge.newRegistrationId());
}

/// Der Weg ueber libsignal, Schritt fuer Schritt so, wie `_nahGeheimnis` im
/// Kern ihn geht.
///
/// AUS DER ADRESSE und nicht aus den rohen Bytes: genau das tut der Kern, und
/// `publicKeyOfAddress` stellt dabei das Typbyte 0x05 voran. `BitdmAddress.
/// decode` liefert 32 nackte Bytes, libsignal will 33 — die Falle aus dem
/// Dateikopf von signal_identity.dart. Ein Test, der das Typbyte selbst
/// davorsetzte, wuerde an der Stelle vorbeimessen, an der der Kern es tut.
Uint8List ueberLibsignal(SignalIdentity eigene, String fremdeAdresse) {
  final eigen = PrivateKey.deserialize(bytes: eigene.keyPair.privateKey);
  return Uint8List.fromList(eigen.agree(
      publicKey: SignalIdentityBridge.publicKeyOfAddress(fremdeAdresse)));
}

/// Der Weg ueber das cryptography-Paket, wie ihn leuchtfeuer.dart geht.
Future<Uint8List> ueberCryptography(
    Uint8List eigenerPrivater, Uint8List fremderOeffentlicher) async {
  final paar = await X25519().newKeyPairFromSeed(eigenerPrivater);
  return Leuchtfeuer.gemeinsamesGeheimnis(
      eigenerSchluessel: paar, fremderOeffentlicher: fremderOeffentlicher);
}

/// Eine Adresse, deren Schluessel ein Punkt NIEDRIGER ORDNUNG ist.
///
/// u = 0 ist der einfachste: X25519 mit ihm ergibt fuer JEDEN privaten
/// Schluessel 32 Nullbytes. Die Adresse ist trotzdem formal gueltig — die
/// Pruefsumme wird ueber die Bytes gerechnet, nicht ueber die Kurve. Genau
/// deshalb kann sie per QR-Code oder Einfuegen in die Kontaktliste kommen.
String adresseNiedrigerOrdnung([int u = 0]) =>
    BitdmAddress.encode(Uint8List(32)..[0] = u);

void main() {
  setUpAll(signalBereit);

  test('BEIDE WEGE LIEFERN DASSELBE GEHEIMNIS', () async {
    final anna = await neueIdentitaet();
    final bert = await neueIdentitaet();

    final ueberSignal = ueberLibsignal(anna, bert.address);
    final ueberPaket = await ueberCryptography(
        anna.keyPair.privateKey, BitdmAddress.decode(bert.address));

    expect(ueberSignal, ueberPaket,
        reason: 'sonst rechnen die beiden Seiten verschiedene Leuchtfeuer und '
            'zwei Telefone sehen einander nie — ohne dass irgendwo ein Fehler '
            'auftaucht');
    expect(ueberSignal.length, 32);

    // Und die Gegenrichtung: was Bert rechnet, muss dasselbe sein.
    final andersherum = ueberLibsignal(bert, anna.address);
    expect(andersherum, ueberSignal,
        reason: 'ein gemeinsames Geheimnis ist gemeinsam oder keines');
  });

  test('der private Schluessel ist fuer beide Bibliotheken derselbe', () async {
    // DIE VORAUSSETZUNG DES ERSTEN FALLS, eigens gemessen. Die Gegenstelle
    // gibt dem cryptography-Paket `keyPair.privateKey` als Seed; das sind die
    // 32 Byte, die libsignal fuehrt. Gaebe libsignal sie in einer anderen
    // Form heraus (mit Typbyte, ungeklammert), rechnete der erste Fall mit
    // zwei verschiedenen Schluesseln — und koennte trotzdem gruen sein, wenn
    // beide Seiten denselben Fehler machten. Deshalb hier gegen die
    // Ableitung, die von libsignal nichts weiss.
    final keys = await KeyDerivation.fromMnemonic(Bip39.generate());
    final wer = SignalIdentityBridge.fromDerived(keys, registrationId: 1);
    expect(wer.keyPair.privateKey, keys.identityPrivateKey);
    final paar = await X25519().newKeyPairFromSeed(wer.keyPair.privateKey);
    expect((await paar.extractPublicKey()).bytes, wer.rawPublicKey,
        reason: 'aus demselben Seed muss das cryptography-Paket denselben '
            'oeffentlichen Schluessel rechnen, der in der Adresse steht');
  });

  test('die Adresse traegt wirklich den Identitaetsschluessel', () async {
    // Der Entwurf des Nahbereichs steht darauf: aus einer Adresse allein
    // laesst sich der oeffentliche Schluessel gewinnen, ohne Server.
    final wer = await neueIdentitaet();
    expect(BitdmAddress.decode(wer.address), wer.rawPublicKey);
  });

  test('ein fremder Schluessel ergibt ein ANDERES Geheimnis', () async {
    // Die Gegenprobe. Ohne sie koennte der erste Test auch dann bestehen,
    // wenn beide Wege dieselbe Konstante zurueckgaeben.
    final anna = await neueIdentitaet();
    final bert = await neueIdentitaet();
    final fremd = await neueIdentitaet();

    final mitBert = ueberLibsignal(anna, bert.address);
    final mitFremd = ueberLibsignal(anna, fremd.address);
    expect(mitBert, isNot(mitFremd));
  });

  group('Ein Schluessel niedriger Ordnung', () {
    // WARUM ES DIESE GRUPPE GIBT
    //
    // Die Dart-Nachbildung gab fuer einen Punkt niedriger Ordnung still 32
    // Nullbytes zurueck. Die offizielle libsignal lehnt das ab und WIRFT
    // (Dokumentation von `PrivateKey.agree`: "rejected in constant time and
    // surfaces as a thrown error"). Das ist das richtige Verhalten — ein
    // Null-Geheimnis waere fuer jeden ausrechenbar, das Leuchtfeuer damit fuer
    // jeden nachzumachen.
    //
    // ABER: `_nahGeheimnis` wird fuer JEDEN Kontakt der Liste gerufen, in
    // einer einzigen Schleife (`_nahKontakte`). Ein Wurf dort risse den ganzen
    // Nahbereich um — eine einzige praeparierte Adresse in der Kontaktliste
    // (ein QR-Code genuegt, die Pruefsumme ist gueltig) schaltete die
    // Ausfallsicherung fuer ALLE Kontakte ab. Deshalb faengt `_nahGeheimnis`
    // den Wurf und gibt null; der Kontakt nimmt dann einfach nicht teil.

    test('libsignal WIRFT, statt 32 Nullbytes zu liefern', () async {
      // Die Voraussetzung fuer den Fall darunter, eigens gemessen: wuerde
      // libsignal hier Nullbytes liefern, waere das Abfangen im Kern toter
      // Code — und ein Leuchtfeuer aus einem fuer jeden bekannten Geheimnis
      // ginge hinaus.
      final anna = await neueIdentitaet();
      for (final u in [0, 1]) {
        final adresse = adresseNiedrigerOrdnung(u);
        expect(BitdmAddress.isValid(adresse), isTrue,
            reason: 'die Adresse ist formal gueltig — sonst kaeme sie gar '
                'nicht erst in die Kontaktliste, und der Fall maesse nichts');
        expect(() => ueberLibsignal(anna, adresse), throwsA(anything),
            reason: 'u=$u: ein Null-Geheimnis darf nicht still herauskommen');
      }
    });

    test('EIN SOLCHER KONTAKT REISST DEN NAHBEREICH NICHT UM', () async {
      // DURCH DEN ECHTEN KERN, mit einem echten Nahbereich ueber der
      // Funk-Attrappe. `_nahGeheimnis` ist privat; gemessen wird deshalb das,
      // wofuer es da ist: fuer wen geworben wird.
      //
      // OHNE DAS ABFANGEN in `_nahGeheimnis` wirft `_nahKontakte` aus
      // `_setzeNaheAuf` heraus: `setPreferences` scheitert mit dem Fehler
      // aus libsignal, und es wird fuer niemanden geworben. (Hergeleitet aus
      // dem Ablauf, nicht als Mutation gelaufen.)
      final ordner = await Directory.systemTemp.createTemp('bitdm-niedrig');
      final funk = FunkAttrappe();
      final kern = RealMessengerCore(
        secretStore: SpeicherImKopf(),
        databasePath: '${ordner.path}${Platform.pathSeparator}t.db',
        relayUri: Uri.parse('http://127.0.0.1:1'),
        nahFactory: () => Nahbereich(funk: funk),
      );
      addTearDown(() async {
        await kern.dispose();
        await funk.dispose();
        try {
          await ordner.delete(recursive: true);
        } catch (_) {
          // Windows gibt Handles verzoegert frei.
        }
      });
      await kern.initialize();
      await kern.createIdentity();

      final anna = await neueIdentitaet();
      final jetzt = DateTime.now().toUtc();
      // An der App vorbei in die Ablage: `addContact` schickte eine
      // Kontaktanfrage, und um die geht es hier nicht.
      kern.ablageFuerTest
        ..speichereKontakt(Contact(id: anna.address, addedAt: jetzt))
        ..speichereKontakt(
            Contact(id: adresseNiedrigerOrdnung(), addedAt: jetzt));

      await kern.setPreferences(const AppPreferences(naheAn: true));
      await kern.nahRuhtFuerTest;

      expect(funk.werbungen, isNotEmpty,
          reason: 'der Funk muss trotz des kaputten Kontakts laufen — sonst '
              'nimmt EINE praeparierte Adresse allen anderen die Naehe');
      expect(funk.werbungen.last, hasLength(1),
          reason: 'geworben wird fuer Anna und NICHT fuer den Schluessel '
              'niedriger Ordnung: dessen Leuchtfeuer liesse sich von jedem '
              'ausrechnen');
    });
  });
}
