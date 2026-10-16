import 'dart:typed_data';

import 'package:optional/optional.dart';

import '../ecc/curve.dart';
import '../ecc/ec_public_key.dart';
import '../identity_key.dart';
import '../invalid_key_exception.dart';
import '../invalid_message_exception.dart';
import '../legacy_message_exception.dart';
import '../state/whisper_text_protocol.pb.dart' as signal_protos;
import '../util/byte_util.dart';
import 'ciphertext_message.dart';
import 'signal_message.dart';

class PreKeySignalMessage extends CiphertextMessage {
  PreKeySignalMessage(Uint8List serialized) {
    try {
      if (serialized.isEmpty) {
        throw InvalidMessageException('Empty message.');
      }

      _version = ByteUtil.highBitsToInt(serialized[0]);

      // BITDM (LS-1): Die Fassung MUSS geprueft werden, und zwar hier.
      //
      // Das obere Nibble des ersten Bytes ist die Protokollfassung. Dieses
      // Byte deckt kein MAC — der MAC der inneren SignalMessage laeuft nur
      // ueber die innere Nachricht. Die Duplikaterkennung in
      // SessionBuilder.processV3 vergleicht aber genau diese Fassung mit der
      // Fassung der gespeicherten Sitzung. Ohne Pruefung genuegt es, das Byte
      // von 0x33 auf 0x43 zu setzen: hasSessionState findet die laufende
      // Sitzung nicht mehr, die Bibliothek baut aus denselben X3DH-Eingaben
      // eine zweite Anfangssitzung, ARCHIVIERT dafuer die laufende und
      // entschluesselt die Erstnachricht ein zweites Mal. Die Gegenstelle
      // kann danach nichts mehr lesen, was dieses Geraet sendet.
      //
      // SignalMessage.fromSerialized prueft das seit immer (siehe dort);
      // der Erstnachricht fehlte die Pruefung. Die offizielle libsignal
      // lehnt beides beim Parsen ab (LegacyCiphertextVersion /
      // UnrecognizedCiphertextVersion in rust/protocol/src/protocol.rs).
      if (_version < CiphertextMessage.currentVersion) {
        throw LegacyMessageException('Legacy message: $_version');
      }
      if (_version > CiphertextMessage.currentVersion) {
        throw InvalidMessageException('Unknown version: $_version');
      }

      final preKeyWhisperMessage =
          signal_protos.PreKeySignalMessage.fromBuffer(serialized.sublist(1));

      if (!preKeyWhisperMessage.hasSignedPreKeyId() ||
          !preKeyWhisperMessage.hasBaseKey() ||
          !preKeyWhisperMessage.hasIdentityKey() ||
          !preKeyWhisperMessage.hasMessage()) {
        throw InvalidMessageException('Incomplete message.');
      }

      this.serialized = serialized;
      registrationId = preKeyWhisperMessage.registrationId;
      preKeyId = preKeyWhisperMessage.hasPreKeyId()
          ? Optional.of(preKeyWhisperMessage.preKeyId)
          : const Optional.empty();
      signedPreKeyId = preKeyWhisperMessage.hasSignedPreKeyId()
          ? preKeyWhisperMessage.signedPreKeyId
          : -1;
      baseKey = Curve.decodePoint(
          Uint8List.fromList(preKeyWhisperMessage.baseKey), 0);
      identityKey = IdentityKey(Curve.decodePoint(
          Uint8List.fromList(preKeyWhisperMessage.identityKey), 0));
      message = SignalMessage.fromSerialized(
          Uint8List.fromList(preKeyWhisperMessage.message));
    } on InvalidMessageException {
      rethrow;
    } on InvalidKeyException catch (e) {
      throw InvalidMessageException(e.detailMessage);
    } on LegacyMessageException catch (e) {
      throw InvalidMessageException(e.detailMessage);
    } on RangeError catch (_) {
      // BITDM (FZ-2): abgeschnittene Nachrichten und aufgeblasene
      // Protobuf-Laengen ergaben einen RangeError. Der erbt von Error, nicht
      // von Exception, und ein Aufrufer mit `on InvalidMessageException`
      // greift daran vorbei. Die Meldung traegt bewusst keinen Inhalt der
      // Nachricht.
      throw InvalidMessageException('Truncated or malformed message.');
    } on Exception catch (_) {
      // Dasselbe fuer alles, was die Protobuf-Schicht wirft
      // (InvalidProtocolBufferException) und fuer die nackte Exception aus
      // ByteUtil.split. Die offizielle libsignal meldet all das als
      // InvalidMessageException.
      throw InvalidMessageException('Malformed message.');
    }
  }

  PreKeySignalMessage.from(this._version, this.registrationId, this.preKeyId,
      this.signedPreKeyId, this.baseKey, this.identityKey, this.message) {
    final builder = signal_protos.PreKeySignalMessage.create()
      ..signedPreKeyId = signedPreKeyId
      ..baseKey = baseKey.serialize()
      ..identityKey = identityKey.serialize()
      ..message = message.serialize()
      ..registrationId = registrationId;

    if (preKeyId.isPresent) {
      builder.preKeyId = preKeyId.value;
    }

    final versionBytes = [
      ByteUtil.intsToByteHighAndLow(_version, CiphertextMessage.currentVersion)
    ];

    final messageBytes = builder.toBuilder().writeToBuffer();
    serialized = Uint8List.fromList(versionBytes + messageBytes);
  }

  late int _version;
  late int registrationId;
  late Optional<int> preKeyId;
  late int signedPreKeyId;
  late ECPublicKey baseKey;
  late IdentityKey identityKey;
  late SignalMessage message;
  late Uint8List serialized;

  int getMessageVersion() => _version;

  IdentityKey getIdentityKey() => identityKey;

  int getRegistrationId() => registrationId;

  Optional<int> getPreKeyId() => preKeyId;

  int getSignedPreKeyId() => signedPreKeyId;

  ECPublicKey getBaseKey() => baseKey;

  SignalMessage getWhisperMessage() => message;

  @override
  int getType() => CiphertextMessage.prekeyType;

  @override
  Uint8List serialize() => serialized;
}
