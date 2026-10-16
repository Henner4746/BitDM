import 'package:optional/optional.dart';

import 'ecc/curve.dart';
import 'ecc/ec_key_pair.dart';
import 'invalid_key_exception.dart';
import 'protocol/pre_key_signal_message.dart';
import 'ratchet/alice_signal_protocol_parameters.dart';
import 'ratchet/bob_signal_protocol_parameters.dart';
import 'ratchet/ratcheting_session.dart';
import 'signal_protocol_address.dart';
import 'state/identity_key_store.dart';
import 'state/pre_key_bundle.dart';
import 'state/pre_key_store.dart';
import 'state/session_record.dart';
import 'state/session_store.dart';
import 'state/signal_protocol_store.dart';
import 'state/signed_pre_key_store.dart';
import 'untrusted_identity_exception.dart';
import 'util/log.dart' as $log;

class SessionBuilder {
  SessionBuilder(this._sessionStore, this._preKeyStore, this._signedPreKeyStore,
      this._identityKeyStore, this._remoteAddress);

  SessionBuilder.fromSignalStore(
      SignalProtocolStore store, SignalProtocolAddress remoteAddress)
      : this(store, store, store, store, remoteAddress);

  static const String tag = 'SessionBuilder';

  SessionStore _sessionStore;
  PreKeyStore _preKeyStore;
  SignedPreKeyStore _signedPreKeyStore;
  IdentityKeyStore _identityKeyStore;
  SignalProtocolAddress _remoteAddress;

  Future<Optional<int>> process(
      SessionRecord sessionRecord, PreKeySignalMessage message) async {
    final theirIdentityKey = message.getIdentityKey();

    if (!await _identityKeyStore.isTrustedIdentity(
        _remoteAddress, theirIdentityKey, Direction.receiving)) {
      throw UntrustedIdentityException(
          _remoteAddress.getName(), theirIdentityKey);
    }

    // BITDM (FZ-1): `await` und die Reihenfolge.
    //
    // Hier stand `final unsignedPreKeyId = processV3(...)` ohne await, und
    // saveIdentity lief davor zu Ende. Zwei Fehler in einem:
    //  * Scheiterte processV3 — etwa weil die Nummer des Prekeys unbekannt
    //    ist —, hing in diesem Moment niemand an dem Future. Dart meldete
    //    den Fehler deshalb ZUSAETZLICH als unbehandelt an die Zone, an
    //    jedem try/catch des Aufrufers vorbei. In einem Programm mit
    //    runZonedGuarded, das bei Fehlern beendet, ist das ein Absturz von
    //    aussen.
    //  * Die Identitaet der Gegenstelle wurde gespeichert, bevor feststand,
    //    ob der Sitzungsaufbau gelingt. Die offizielle libsignal speichert
    //    sie erst danach.
    final unsignedPreKeyId = await processV3(sessionRecord, message);

    await _identityKeyStore.saveIdentity(_remoteAddress, theirIdentityKey);

    return unsignedPreKeyId;
  }

  Future<Optional<int>> processV3(
      SessionRecord sessionRecord, PreKeySignalMessage message) async {
    if (sessionRecord.hasSessionState(
        message.getMessageVersion(), message.getBaseKey().serialize())) {
      $log.log(
          "We've already setup a session for this V3 message, letting bundled message fall through...");
      return const Optional.empty();
    }

    // BITDM (FZ-1): sofort abwarten.
    //
    // Hier stand ein nicht abgewartetes Future, das erst weiter unten bei
    // den Parametern eingesammelt wurde. Scheiterte vorher ein anderer
    // Schritt, blieb es verwaist liegen und meldete seinen Fehler an die
    // Zone. Nebenwirkung des Umbaus, und zwar eine gewollte: eine unbekannte
    // Nummer des signierten Prekeys schlaegt jetzt fehl, BEVOR
    // archiveCurrentState die laufende Sitzung beiseitelegt.
    final ourSignedPreKey = (await _signedPreKeyStore
            .loadSignedPreKey(message.getSignedPreKeyId()))
        .getKeyPair();

    late final Optional<ECKeyPair> ourOneTimePreKey;
    if (message.getPreKeyId().isPresent) {
      ourOneTimePreKey = Optional.of(await _preKeyStore
          .loadPreKey(message.getPreKeyId().value)
          .then((value) => value.getKeyPair()));
    } else {
      ourOneTimePreKey = const Optional<ECKeyPair>.empty();
    }

    if (!sessionRecord.isFresh()) sessionRecord.archiveCurrentState();

    final parameters = BobSignalProtocolParameters(
      theirBaseKey: message.getBaseKey(),
      theirIdentityKey: message.getIdentityKey(),
      ourIdentityKey: await _identityKeyStore.getIdentityKeyPair(),
      ourSignedPreKey: ourSignedPreKey,
      ourRatchetKey: ourSignedPreKey,
      ourOneTimePreKey: ourOneTimePreKey,
    );

    RatchetingSession.initializeSessionBob(
        sessionRecord.sessionState, parameters);

    sessionRecord.sessionState.localRegistrationId =
        await _identityKeyStore.getLocalRegistrationId();
    sessionRecord.sessionState.remoteRegistrationId =
        message.getRegistrationId();
    sessionRecord.sessionState.aliceBaseKey = message.getBaseKey().serialize();

    if (message.getPreKeyId().isPresent) {
      return message.getPreKeyId();
    } else {
      return const Optional.empty();
    }
  }

  Future<void> processPreKeyBundle(PreKeyBundle preKey) async {
    if (!await _identityKeyStore.isTrustedIdentity(
        _remoteAddress, preKey.getIdentityKey(), Direction.sending)) {
      throw UntrustedIdentityException(
          _remoteAddress.getName(), preKey.getIdentityKey());
    }

    if (preKey.getSignedPreKey() != null &&
        !Curve.verifySignature(
            preKey.getIdentityKey().publicKey,
            preKey.getSignedPreKey()!.serialize(),
            preKey.getSignedPreKeySignature())) {
      throw InvalidKeyException('Invalid signature on device key!');
    }

    if (preKey.getSignedPreKey() == null) {
      throw InvalidKeyException('No signed prekey!');
    }

    final sessionRecord = await _sessionStore.loadSession(_remoteAddress);
    final ourBaseKey = Curve.generateKeyPair();
    final theirSignedPreKey = preKey.getSignedPreKey();
    final theirOneTimePreKey = Optional.ofNullable(preKey.getPreKey());
    final theirOneTimePreKeyId = theirOneTimePreKey.isPresent
        ? Optional.ofNullable(preKey.getPreKeyId())
        : const Optional<int>.empty();

    final parameters = AliceSignalProtocolParameters(
      ourBaseKey: ourBaseKey,
      ourIdentityKey: await _identityKeyStore.getIdentityKeyPair(),
      theirIdentityKey: preKey.getIdentityKey(),
      theirSignedPreKey: theirSignedPreKey!,
      theirRatchetKey: theirSignedPreKey,
      theirOneTimePreKey: theirOneTimePreKey,
    );

    if (!sessionRecord.isFresh()) sessionRecord.archiveCurrentState();

    RatchetingSession.initializeSessionAlice(
        sessionRecord.sessionState, parameters);

    sessionRecord.sessionState.setUnacknowledgedPreKeyMessage(
        theirOneTimePreKeyId, preKey.getSignedPreKeyId(), ourBaseKey.publicKey);
    sessionRecord.sessionState.localRegistrationId =
        await _identityKeyStore.getLocalRegistrationId();
    sessionRecord.sessionState.remoteRegistrationId =
        preKey.getRegistrationId();
    sessionRecord.sessionState.aliceBaseKey = ourBaseKey.publicKey.serialize();

    await _identityKeyStore.saveIdentity(
        _remoteAddress, preKey.getIdentityKey());
    await _sessionStore.storeSession(_remoteAddress, sessionRecord);
  }
}
