// signal_errors_test.dart — nagelt die Fehlerbehandlung des Empfangspfads fest.
//
// Der Empfangspfad verarbeitet Bytes, die vom Server kommen und die ein
// Angreifer frei formen kann. Was hier durchrutscht, stuerzt die App ab oder
// laesst eine Sitzung in einem Zustand zurueck, den der Angreifer gewaehlt hat.
//
// Seit 2.0.0 meldet die offizielle libsignal JEDEN Protokollfehler als
// `LibSignalException` mit einem Code. Die eigenen Ausnahmeklassen der
// Dart-Nachbildung (DuplicateMessageException, InvalidMacException, ...) gibt
// es nicht mehr. ENTFALLEN sind damit auch zwei Faelle der alten Einteilung:
//  - `badMac`: einen falschen MAC meldet libsignal als `invalidMessage`, wie
//    jede andere unlesbare Nachricht; er landet in `unreadable`.
//  - `fatal`: Die Anbindung meldet Fehler in Rust als `internalError` bzw. als
//    PanicException; beides ist fuer den Empfangspfad "unlesbar, verwerfen".

import 'package:bitdm/core/crypto/signal_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal/libsignal.dart';

LibSignalException _code(LibSignalErrorCode c) =>
    LibSignalException(code: c, message: 'x');

void main() {
  group('Zuordnung der Codes', () {
    test('doppelte Nachricht', () {
      expect(classify(_code(LibSignalErrorCode.duplicatedMessage)),
          SignalFailure.duplicate);
    });

    test('keine Sitzung', () {
      expect(classify(_code(LibSignalErrorCode.sessionNotFound)),
          SignalFailure.noSession);
    });

    test('ein falscher MAC ist NICHT dasselbe wie keine Sitzung', () {
      // Der wichtigste Unterschied dieser Datei: bei noSession ist ein
      // Neuaufbau richtig, bei einer verfaelschten Nachricht waere er ein
      // Angriffsvektor. libsignal meldet den falschen MAC als invalidMessage
      // (gemessen in signal_bibliothek_test.dart, LS-2).
      final mac = classify(_code(LibSignalErrorCode.invalidMessage));
      expect(mac, SignalFailure.unreadable);
      expect(mac, isNot(classify(_code(LibSignalErrorCode.sessionNotFound))));
      expect(mac.shouldRebuildSession, isFalse);
    });

    test('fremder Identitaetsschluessel', () {
      expect(classify(_code(LibSignalErrorCode.untrustedIdentity)),
          SignalFailure.untrusted);
    });

    test('verbrauchter Prekey', () {
      expect(classify(_code(LibSignalErrorCode.invalidKeyIdentifier)),
          SignalFailure.missingKey);
    });

    test('unlesbare Nachricht', () {
      for (final c in [
        LibSignalErrorCode.invalidMessage,
        LibSignalErrorCode.protobufError,
        LibSignalErrorCode.invalidKey,
        LibSignalErrorCode.invalidSignature,
        LibSignalErrorCode.legacyCiphertextVersion,
        LibSignalErrorCode.unknownCiphertextVersion,
        LibSignalErrorCode.unrecognizedMessageVersion,
        LibSignalErrorCode.invalidSession,
        LibSignalErrorCode.internalError,
      ]) {
        expect(classify(_code(c)), SignalFailure.unreadable, reason: '$c');
      }
    });

    test('JEDER uebrige Code ist unlesbar — auch einer, den es erst spaeter '
        'gibt', () {
      // Die Anbindung fuegt Codes nur in einer Hauptfassung hinzu. Kommt einer
      // dazu, darf er nicht versehentlich in duplicate (still verworfen) oder
      // noSession (Neuaufbau) landen. Der `default`-Zweig in classify sorgt
      // dafuer; dieser Test haelt fest, dass es bei genau vier Ausnahmen
      // bleibt.
      const besonders = {
        LibSignalErrorCode.duplicatedMessage: SignalFailure.duplicate,
        LibSignalErrorCode.sessionNotFound: SignalFailure.noSession,
        LibSignalErrorCode.untrustedIdentity: SignalFailure.untrusted,
        LibSignalErrorCode.invalidKeyIdentifier: SignalFailure.missingKey,
      };
      for (final c in LibSignalErrorCode.values) {
        expect(classify(_code(c)), besonders[c] ?? SignalFailure.unreadable,
            reason: '$c');
      }
    });

    test('classify liest den Code, nicht den Text', () {
      // Der Text kann sich in jeder Fassung aendern ("in libsignal's wording"),
      // der Code nur in einer Hauptfassung.
      expect(
          classify(const LibSignalException(
              code: LibSignalErrorCode.invalidMessage,
              message: 'message with old counter 1 / 0')),
          SignalFailure.unreadable,
          reason: 'ein Text, der nach Duplikat klingt, macht noch keines');
      expect(
          classify(const LibSignalException(
              code: LibSignalErrorCode.duplicatedMessage, message: '')),
          SignalFailure.duplicate);
    });
  });

  group('ErneutEingespielt', () {
    test('zaehlt als Duplikat — still verwerfen', () {
      // Der Empfangspfad wirft es, wenn kyberWiederholungen gestiegen ist
      // (signal_store.dart, Abschnitt KyberPreKeyStore). Fuer den Nutzer ist
      // das dasselbe wie eine doppelt zugestellte Nachricht.
      expect(classify(const ErneutEingespielt()), SignalFailure.duplicate);
      expect(classify(const ErneutEingespielt()).isSilent, isTrue);
      expect(classify(const ErneutEingespielt()).shouldRebuildSession, isFalse,
          reason: 'eine Wiederholung darf keine Sitzung zuruecksetzen');
    });
  });

  group('Was nicht aus libsignal kommt', () {
    test('AssertionError wird erfasst', () {
      // Error, nicht Exception — ein Empfangspfad mit `on Exception` wuerde
      // daran vorbeigreifen und abstuerzen.
      expect(classify(AssertionError('irgendein interner Fehler')),
          SignalFailure.unreadable);
    });

    test('AssertionError ist tatsaechlich KEINE Exception', () {
      // Beweis, warum classify Object nimmt und nicht Exception.
      expect(AssertionError('x'), isNot(isA<Exception>()));
      expect(AssertionError('x'), isA<Error>());
    });

    test('voellig unbekannte Werte gelten als unlesbar und fuehren nicht zum '
        'Absturz', () {
      // Darunter, was die Anbindung selbst ausserhalb von LibSignalException
      // wirft: ArgumentError und StateError fuer Pruefungen in Dart. Eine
      // echte PanicException prueft signal_bibliothek_test.dart.
      for (final seltsam in <Object>[
        'eine Zeichenkette',
        42,
        StateError('x'),
        ArgumentError('x'),
        const FormatException('x'),
        Exception('x'),
        Object(),
      ]) {
        expect(() => classify(seltsam), returnsNormally);
        expect(classify(seltsam), SignalFailure.unreadable,
            reason: '${seltsam.runtimeType}');
      }
    });
  });

  group('Abgeleitetes Verhalten', () {
    test('nur eine doppelte Nachricht wird stillschweigend verworfen', () {
      expect(SignalFailure.duplicate.isSilent, isTrue);
      for (final f
          in SignalFailure.values.where((f) => f != SignalFailure.duplicate)) {
        expect(f.isSilent, isFalse,
            reason: '$f darf nicht still verworfen werden');
      }
    });

    test('NUR noSession loest einen Neuaufbau aus', () {
      // Wuerde eine unlesbare Nachricht ebenfalls einen Neuaufbau ausloesen,
      // koennte ein Angreifer mit Muellnachrichten Sitzungen zuruecksetzen
      // lassen und damit Forward Secrecy untergraben.
      expect(SignalFailure.noSession.shouldRebuildSession, isTrue);
      expect(SignalFailure.unreadable.shouldRebuildSession, isFalse);
      for (final f
          in SignalFailure.values.where((f) => f != SignalFailure.noSession)) {
        expect(f.shouldRebuildSession, isFalse,
            reason: '$f darf nichts neu aufbauen');
      }
    });

    test('nur ein fremder Identitaetsschluessel erreicht den Nutzer', () {
      expect(SignalFailure.untrusted.needsUserAttention, isTrue);
      for (final f
          in SignalFailure.values.where((f) => f != SignalFailure.untrusted)) {
        expect(f.needsUserAttention, isFalse);
      }
    });

    test('jeder Fall hat hoechstens eine definierte Behandlung', () {
      // Kommt spaeter ein Wert dazu, faellt hier auf, dass sein Verhalten
      // noch nicht bedacht wurde.
      for (final f in SignalFailure.values) {
        expect(
            [f.isSilent, f.shouldRebuildSession, f.needsUserAttention]
                .where((b) => b)
                .length,
            lessThanOrEqualTo(1),
            reason: '$f traegt widerspruechliche Behandlung');
      }
    });

    test('die Einteilung kennt genau fuenf Faelle', () {
      // badMac und fatal sind mit 2.0.0 entfallen (Kopf dieser Datei). Kommt
      // ein Fall dazu, muss er hier und im Empfangspfad bedacht werden.
      expect(SignalFailure.values, [
        SignalFailure.duplicate,
        SignalFailure.noSession,
        SignalFailure.untrusted,
        SignalFailure.missingKey,
        SignalFailure.unreadable,
      ]);
    });
  });
}
