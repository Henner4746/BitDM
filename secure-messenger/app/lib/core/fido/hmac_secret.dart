// hmac_secret.dart — aus dem Stick ein gleichbleibendes Geheimnis holen.
//
// DAS IST DER KERN DER STICK-SPERRE.
//
// Der Stick kann rechnen, ohne zu verraten, womit: man schickt ihm ein Salz,
// er antwortet mit HMAC(sein interner Schluessel, Salz). Bei gleichem Salz
// kommt immer dasselbe heraus, und der interne Schluessel verlaesst den Stick
// nie — auch nicht auf Verlangen. Genau deshalb ist der Stick als Faktor so
// stark: sein Beitrag laesst sich nicht kopieren.
//
// ZWEI SCHRITTE, ZWEI GELEGENHEITEN
//   Einrichten:  makeCredential mit "hmac-secret": true legt auf dem Stick
//                einen Zugang an. Passiert genau einmal.
//   Entsperren:  getAssertion mit dem Salz holt das Geheimnis. Passiert bei
//                jedem Start.
//
// WAS AUF DEM STICK LANDET UND WAS NICHT
// Seit 25.09.2026: nichts. Der Zugang wird nicht auf dem Stick gespeichert;
// seine Kennung (die der Stick selbst wiedererkennt) steht im Fach der App.
// Aeltere Einrichtungen haben einen gespeicherten Zugang mit dem Namen
// "bitdm" hinterlassen — nicht die Identitaet, nicht die Nachrichten, nicht
// die Adresse; wer den Stick findet, sieht daran nur, dass jemand BitDM
// benutzt. Das Geheimnis selbst wird bei jeder Abfrage neu gerechnet und
// nirgends gespeichert.
//
// DIE SALZE SIND VERSCHLUESSELT UNTERWEGS
// Salz hin und Ergebnis zurueck laufen durch das gemeinsame Geheimnis aus
// pin_protocol.dart. Sonst koennte jemand, der den Funk oder das Kabel
// mitliest, die Antwort abfangen — und die IST der Schluessel zur Datenbank.

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import 'ctap.dart';
import 'ctap_cbor.dart';
import 'pin_protocol.dart';

/// Ein auf dem Stick angelegter Zugang.
class StickZugang {
  /// Die Kennung, die der Stick beim Abrufen wiedererkennt.
  final Uint8List credentialId;

  const StickZugang(this.credentialId);
}

class HmacSecret {
  HmacSecret(this.ctap);

  final Ctap2 ctap;

  /// Wofuer der Zugang gilt.
  ///
  /// Normalerweise eine Domain. BitDM hat keine — die App-Sperre hat mit dem
  /// Netz nichts zu tun, und eine Domain einzutragen wuerde nur eine
  /// Abhaengigkeit vortaeuschen, die es nicht gibt.
  static const String rpId = 'bitdm.local';
  static const String rpName = 'BitDM';

  /// Das Salz. Fest, weil dasselbe Geheimnis wieder herauskommen muss.
  ///
  /// Es ist kein Geheimnis und muss keins sein: der Schutz kommt daher, dass
  /// nur DIESER Stick daraus DIESES Ergebnis rechnen kann.
  static final Uint8List salz = Uint8List.fromList(
      const DartSha256().hashSync('bitdm app lock v1'.codeUnits).bytes);

  /// Legt auf dem Stick einen Zugang an. Genau einmal beim Einrichten.
  ///
  /// Der Nutzer muss den Stick dabei beruehren — der Stick verlangt das, nicht
  /// die App. Ohne diese Beruehrung koennte Schadsoftware im Hintergrund
  /// Zugaenge anlegen, solange der Stick nur steckt.
  /// [pinToken] ist null, wenn auf dem Stick keine PIN gesetzt ist. Dann
  /// entfallen die Felder 8 und 9; der Stick verlangt statt dessen nur die
  /// Beruehrung. Ein Stick MIT PIN wuerde dieselbe Anfrage mit 0x27 ablehnen.
  Future<StickZugang> legeZugangAn({
    required PinProtocolV1 pin,
    required Uint8List? pinToken,
  }) async {
    // clientDataHash ist normalerweise ein Hash ueber die Anfrage des Browsers.
    // Hier gibt es keinen Browser; er muss aber 32 Byte sein und wird
    // mitbeglaubigt, also nehmen wir etwas Festes und Nachvollziehbares.
    final clientDataHash = Uint8List.fromList(
        const DartSha256().hashSync('bitdm-make-credential-v1'.codeUnits).bytes);

    final parameter = <int, Object>{
      1: clientDataHash,
      2: {'id': rpId, 'name': rpName},
      3: {
        // Die Nutzerkennung ist bewusst NICHT die BitDM-Adresse. Wer den Stick
        // findet, soll daran nicht ablesen koennen, wer man ist.
        //
        // UND SIE IST JEDES MAL NEU. Bis 25.09.2026 stand hier fest
        // "bitdm-lock", zusammen mit rk: true. Ein Stick fuehrt je Dienst und
        // Nutzerkennung aber nur EINEN gespeicherten Zugang — wer denselben
        // Stick ein zweites Mal einrichtete (zweite Installation, zweites
        // Telefon, nach einem Zuruecksetzen der App), ueberschrieb damit den
        // ersten, und dessen Fach ging nie wieder auf.
        'id': _zufallsKennung(),
        'name': 'BitDM',
        'displayName': 'BitDM',
      },
      4: [
        {'alg': -7, 'type': 'public-key'}, // ES256
      ],
      6: {'hmac-secret': true}, // die Erweiterung, um die es geht
      // KEIN "rk" MEHR (also: nicht auf dem Stick speichern). Die App braucht
      // den gespeicherten Zugang nicht — sie legt die Zugangskennung ohnehin
      // im Fach ab und nennt sie beim Abrufen ausdruecklich. Ein nicht
      // gespeicherter Zugang belegt keinen der wenigen Speicherplaetze des
      // Sticks und kann von keinem spaeteren Einrichten ueberschrieben
      // werden. Faecher mit altem, gespeichertem Zugang gehen weiter auf:
      // abgerufen wird in beiden Faellen ueber die Kennung.
      if (pinToken != null) ...{
        8: await pin.pinUvAuthParam(pinToken, clientDataHash),
        9: 1, // pinUvAuthProtocol
      },
    };

    final antwort = await ctap.befehl(0x01, CtapCbor.kodiere(parameter));

    // Feld 2 ist authData. Darin steht ab Byte 37 die Kennung des Zugangs:
    // 16 Byte AAGUID, dann zwei Byte Laenge, dann die Kennung selbst.
    final authData = _bytes(antwort[2]);
    if (authData.length < 55) {
      throw const FormatException('authData zu kurz — kein Zugang angelegt');
    }
    final laenge = (authData[53] << 8) | authData[54];
    if (authData.length < 55 + laenge) {
      throw const FormatException('authData kuerzer als angekuendigt');
    }
    return StickZugang(
        Uint8List.fromList(authData.sublist(55, 55 + laenge)));
  }

  static final _zufall = Random.secure();

  /// 16 zufaellige Bytes als Nutzerkennung — ohne Bezug zu irgendetwas.
  static Uint8List _zufallsKennung() =>
      Uint8List.fromList(List.generate(16, (_) => _zufall.nextInt(256)));

  /// Holt das Geheimnis. Bei jedem Entsperren.
  ///
  /// Wieder mit Beruehrung: ein steckengelassener Stick soll nicht ausreichen,
  /// um die App zu oeffnen.
  ///
  /// [pinToken] null heisst OHNE Nutzerpruefung — auch bei einem Stick, der
  /// eine PIN hat. CTAP2 erlaubt das fuer getAssertion; der Stick rechnet
  /// dann mit seinem Schluessel fuer "ohne Pruefung". Genau so muss ein Fach
  /// geoeffnet werden, das angelegt wurde, bevor der Stick eine PIN bekam
  /// (siehe KeySlot.uv).
  Future<Uint8List> holeGeheimnis({
    required StickZugang zugang,
    required PinProtocolV1 pin,
    required Uint8List? pinToken,
  }) async {
    final clientDataHash = Uint8List.fromList(
        const DartSha256().hashSync('bitdm-get-assertion-v1'.codeUnits).bytes);

    final salzVerschluesselt = await pin.verschluessele(salz);
    final salzBeglaubigt = await PinProtocolV1.beglaubige(
        pin.gemeinsamesGeheimnis, salzVerschluesselt);

    final parameter = <int, Object>{
      1: rpId,
      2: clientDataHash,
      3: [
        {'id': zugang.credentialId, 'type': 'public-key'},
      ],
      4: {
        'hmac-secret': {
          1: pin.eigenerCoseKey,
          2: salzVerschluesselt,
          3: salzBeglaubigt,
        },
      },
      if (pinToken != null) ...{
        6: await pin.pinUvAuthParam(pinToken, clientDataHash),
        7: 1,
      },
    };

    final antwort = await ctap.befehl(0x02, CtapCbor.kodiere(parameter));

    // Das Ergebnis steckt in authData, im Erweiterungsteil — verschluesselt.
    final authData = _bytes(antwort[2]);
    final roh = _findeHmacAusgabe(authData);
    final klar = await pin.entschluessele(roh);

    if (klar.length < 32) {
      throw const FormatException('Der Stick lieferte zu wenige Bytes');
    }
    // Bei einem Salz kommen 32 Byte zurueck. Nur die werden gebraucht.
    return Uint8List.fromList(klar.sublist(0, 32));
  }

  /// Sucht die verschluesselte hmac-secret-Ausgabe in authData.
  ///
  /// authData ist: rpIdHash(32) flags(1) counter(4), danach — sofern das
  /// Erweiterungsbit gesetzt ist — eine CBOR-Karte mit den Ergebnissen.
  static Uint8List _findeHmacAusgabe(Uint8List authData) {
    if (authData.length < 37) {
      throw const FormatException('authData zu kurz');
    }
    final flags = authData[32];
    final hatErweiterungen = (flags & 0x80) != 0;
    if (!hatErweiterungen) {
      throw const FormatException(
          'Der Stick lieferte kein hmac-secret — kennt er die Erweiterung?');
    }

    // Ein angehaengter Zugang (Bit 6) steht VOR den Erweiterungen und ist
    // unterschiedlich lang. Beim Abrufen ist er normalerweise nicht dabei;
    // faellt er doch an, waere das Ueberspringen ohne CBOR-Parser nicht
    // moeglich — deshalb hier ein klarer Fehler statt eines Ratespiels.
    if ((flags & 0x40) != 0) {
      throw const FormatException(
          'Unerwarteter Zugang in der Antwort — nicht behandelt');
    }

    final karte = CtapCborLeser.lies(authData, 37);
    final hmac = karte['hmac-secret'];
    if (hmac == null) {
      throw const FormatException('hmac-secret fehlt in der Antwort');
    }
    return _bytes(hmac);
  }

  static Uint8List _bytes(Object? o) {
    if (o is Uint8List) return o;
    if (o is List<int>) return Uint8List.fromList(o);
    throw FormatException('erwartete Bytes, bekam ${o.runtimeType}');
  }
}

/// Liest eine CBOR-Karte, die MITTEN in einem groesseren Puffer beginnt.
///
/// package:cbor kann nur einen ganzen Puffer lesen. In authData steht die
/// Karte aber hinter 37 Byte Kopf — und ein Ausschneiden ginge nur, wenn man
/// ihre Laenge schon kennte.
class CtapCborLeser {
  static Map<Object?, Object?> lies(Uint8List daten, int ab) {
    final rest = Uint8List.sublistView(daten, ab);
    final ergebnis = _lies(rest, 0);
    final wert = ergebnis.$1;
    if (wert is! Map) {
      throw const FormatException('erwartete eine CBOR-Karte');
    }
    return wert;
  }

  static (Object?, int) _lies(Uint8List d, int i) {
    if (i >= d.length) throw const FormatException('CBOR zu kurz');
    final b = d[i];
    final typ = b >> 5;
    final kurz = b & 0x1F;

    var pos = i + 1;
    var wert = kurz;
    if (kurz == 24) {
      wert = d[pos++];
    } else if (kurz == 25) {
      wert = (d[pos] << 8) | d[pos + 1];
      pos += 2;
    } else if (kurz == 26) {
      wert = (d[pos] << 24) | (d[pos + 1] << 16) | (d[pos + 2] << 8) | d[pos + 3];
      pos += 4;
    } else if (kurz > 26) {
      throw const FormatException('CBOR-Form kommt in CTAP2 nicht vor');
    }

    switch (typ) {
      case 0:
        return (wert, pos);
      case 1:
        return (-wert - 1, pos);
      case 2:
        return (Uint8List.sublistView(d, pos, pos + wert), pos + wert);
      case 3:
        return (
          String.fromCharCodes(d.sublist(pos, pos + wert)),
          pos + wert
        );
      case 4:
        final liste = <Object?>[];
        for (var n = 0; n < wert; n++) {
          final (e, p) = _lies(d, pos);
          liste.add(e);
          pos = p;
        }
        return (liste, pos);
      case 5:
        final karte = <Object?, Object?>{};
        for (var n = 0; n < wert; n++) {
          final (k, p1) = _lies(d, pos);
          final (v, p2) = _lies(d, p1);
          karte[k] = v;
          pos = p2;
        }
        return (karte, pos);
      case 7:
        if (kurz == 20) return (false, pos);
        if (kurz == 21) return (true, pos);
        if (kurz == 22) return (null, pos);
        throw const FormatException('unbekannter einfacher Wert');
      default:
        throw FormatException('CBOR-Typ $typ kommt in CTAP2 nicht vor');
    }
  }
}
