// signal_errors_test.dart — nagelt die Fehlerbehandlung des Empfangspfads fest.
//
// Der Empfangspfad verarbeitet Bytes, die vom Server kommen und die ein
// Angreifer frei formen kann. Was hier durchrutscht, stuerzt die App ab oder
// laesst eine Sitzung in einem Zustand zurueck, den der Angreifer gewaehlt hat.

import 'package:bitdm/core/crypto/signal_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  group('Zuordnung der Ausnahmen', () {
    test('doppelte Nachricht', () {
      expect(classify(DuplicateMessageException('x')), SignalFailure.duplicate);
    });

    test('keine Sitzung', () {
      expect(classify(NoSessionException('x')), SignalFailure.noSession);
    });

    test('kaputte Pruefsumme ist NICHT dasselbe wie keine Sitzung', () {
      // Der wichtigste Unterschied dieser Datei: bei noSession ist ein
      // Neuaufbau richtig, bei badMac waere er ein Angriffsvektor.
      expect(classify(InvalidMacException('x')), SignalFailure.badMac);
      expect(classify(InvalidMacException('x')),
          isNot(classify(NoSessionException('x'))));
    });

    test('fremder Identitaetsschluessel', () {
      // Der Konstruktor nimmt einen Namen als String, keine
      // SignalProtocolAddress — nachgelesen in untrusted_identity_exception.dart.
      expect(classify(UntrustedIdentityException('abc', null)),
          SignalFailure.untrusted);
    });

    test('verbrauchter Prekey', () {
      expect(classify(InvalidKeyIdException('x')), SignalFailure.missingKey);
    });

    test('unlesbare Nachricht', () {
      expect(classify(InvalidMessageException('x')), SignalFailure.unreadable);
      expect(classify(InvalidKeyException('x')), SignalFailure.unreadable);
      expect(classify(LegacyMessageException('x')), SignalFailure.unreadable);
    });
  });

  group('Was `on Exception` verpassen wuerde', () {
    test('AssertionError wird erfasst', () {
      // libsignal wirft sie an drei Stellen (pre_key_record.dart:32,
      // ratcheting_session.dart:83 und :115). Sie erbt von Error, nicht von
      // Exception — ein Empfangspfad mit `on Exception` wuerde daran
      // vorbeigreifen und abstuerzen.
      expect(classify(AssertionError('irgendein interner Fehler')),
          SignalFailure.unreadable);
    });

    test('AssertionError ist tatsaechlich KEINE Exception', () {
      // Beweis, warum classify Object nimmt und nicht Exception.
      expect(AssertionError('x'), isNot(isA<Exception>()));
      expect(AssertionError('x'), isA<Error>());
    });

    test('voellig unbekannte Werte fuehren nicht zum Absturz', () {
      for (final seltsam in <Object>[
        'eine Zeichenkette',
        42,
        StateError('x'),
        FormatException('x'),
        Object(),
      ]) {
        expect(() => classify(seltsam), returnsNormally);
        expect(classify(seltsam), isA<SignalFailure>());
      }
    });
  });

  group('Abgeleitetes Verhalten', () {
    test('nur eine doppelte Nachricht wird stillschweigend verworfen', () {
      expect(SignalFailure.duplicate.isSilent, isTrue);
      for (final f in SignalFailure.values.where((f) => f != SignalFailure.duplicate)) {
        expect(f.isSilent, isFalse, reason: '$f darf nicht still verworfen werden');
      }
    });

    test('NUR noSession loest einen Neuaufbau aus', () {
      // Wuerde badMac ebenfalls einen Neuaufbau ausloesen, koennte ein
      // Angreifer mit Muellnachrichten Sitzungen zuruecksetzen lassen und
      // damit Forward Secrecy untergraben.
      expect(SignalFailure.noSession.shouldRebuildSession, isTrue);
      expect(SignalFailure.badMac.shouldRebuildSession, isFalse);
      for (final f in SignalFailure.values.where((f) => f != SignalFailure.noSession)) {
        expect(f.shouldRebuildSession, isFalse, reason: '$f darf nichts neu aufbauen');
      }
    });

    test('nur ein fremder Identitaetsschluessel erreicht den Nutzer', () {
      expect(SignalFailure.untrusted.needsUserAttention, isTrue);
      for (final f in SignalFailure.values.where((f) => f != SignalFailure.untrusted)) {
        expect(f.needsUserAttention, isFalse);
      }
    });

    test('jeder Fall hat genau eine definierte Behandlung', () {
      // Kommt spaeter ein Wert dazu, faellt hier auf, dass sein Verhalten
      // noch nicht bedacht wurde.
      for (final f in SignalFailure.values) {
        expect([f.isSilent, f.shouldRebuildSession, f.needsUserAttention]
            .where((b) => b).length, lessThanOrEqualTo(1),
            reason: '$f traegt widerspruechliche Behandlung');
      }
    });
  });
}
