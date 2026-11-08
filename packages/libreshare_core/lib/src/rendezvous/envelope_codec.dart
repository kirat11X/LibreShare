// EnvelopeCodec implementation for discrete bucketing and AES-256-GCM envelope encryption.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'records.dart';

/// Supported padding bucket boundaries in bytes per LSP-R1 Section 3.1.
const List<int> kRendezvousBuckets = [512, 1024, 2048, 4096];

/// Nonce length for AES-GCM in bytes.
const int kRendezvousNonceBytes = 12;

/// Authentication tag length for AES-GCM in bytes.
const int kRendezvousTagBytes = 16;

/// Total encryption overhead (nonce + tag).
const int kRendezvousOverheadBytes =
    kRendezvousNonceBytes + kRendezvousTagBytes;

/// Handles padding bucketing, AAD authentication, and AES-256-GCM envelope sealing.
abstract interface class EnvelopeCodec {
  /// Encrypts and pads [record] using [envelopeKey] bound to [channelIdHex].
  Uint8List seal({
    required RendezvousRecord record,
    required Uint8List envelopeKey,
    required String channelIdHex,
    Random? nonceSource,
  });

  /// Decrypts, verifies AAD, depads, and deserializes [payload] using [envelopeKey].
  RendezvousRecord unseal({
    required Uint8List payload,
    required Uint8List envelopeKey,
    required String channelIdHex,
  });
}

/// Production implementation of [EnvelopeCodec] using pointycastle AES-256-GCM.
class EnvelopeCodecImpl implements EnvelopeCodec {
  const EnvelopeCodecImpl();

  @override
  Uint8List seal({
    required RendezvousRecord record,
    required Uint8List envelopeKey,
    required String channelIdHex,
    Random? nonceSource,
  }) {
    if (envelopeKey.length != 32) {
      throw ArgumentError('envelopeKey must be 32 bytes');
    }

    final jsonBytes = utf8.encode(jsonEncode(record.toJson()));
    final innerLen = jsonBytes.length;

    // Format: 2 bytes length prefix (u16be) + jsonBytes + zero padding
    final totalUnpadded = 2 + innerLen;
    int targetBucket = -1;
    for (final b in kRendezvousBuckets) {
      if (totalUnpadded <= b) {
        targetBucket = b;
        break;
      }
    }

    if (targetBucket < 0) {
      throw FormatException(
        'Record exceeds max bucket size (4096 bytes): $totalUnpadded',
      );
    }

    final plaintext = Uint8List(targetBucket);
    final bd = ByteData.sublistView(plaintext);
    bd.setUint16(0, innerLen);
    plaintext.setRange(2, 2 + innerLen, jsonBytes);
    // Remaining bytes in plaintext are already 0

    // Nonce (12 bytes)
    final rand = nonceSource ?? Random.secure();
    final nonce = Uint8List(kRendezvousNonceBytes);
    for (var i = 0; i < kRendezvousNonceBytes; i++) {
      nonce[i] = rand.nextInt(256);
    }

    // AAD: "LSP-R1:" + channelIdHex
    final aad = ascii.encode('LSP-R1:$channelIdHex');

    // AES-GCM Encrypt
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(envelopeKey), 128, nonce, aad);
    cipher.init(true, params);

    final out = Uint8List(cipher.getOutputSize(plaintext.length));
    final len = cipher.processBytes(plaintext, 0, plaintext.length, out, 0);
    final finalLen = cipher.doFinal(out, len);
    final totalCiphertextLen = len + finalLen;

    final result = Uint8List(kRendezvousNonceBytes + totalCiphertextLen);
    result.setRange(0, kRendezvousNonceBytes, nonce);
    result.setRange(
      kRendezvousNonceBytes,
      result.length,
      Uint8List.sublistView(out, 0, totalCiphertextLen),
    );

    return result;
  }

  @override
  RendezvousRecord unseal({
    required Uint8List payload,
    required Uint8List envelopeKey,
    required String channelIdHex,
  }) {
    if (envelopeKey.length != 32) {
      throw ArgumentError('envelopeKey must be 32 bytes');
    }
    if (payload.length < kRendezvousOverheadBytes + 2) {
      throw const FormatException('Payload too short for rendezvous envelope');
    }

    final nonce = Uint8List.sublistView(payload, 0, kRendezvousNonceBytes);
    final ciphertextWithTag = Uint8List.sublistView(
      payload,
      kRendezvousNonceBytes,
    );
    final aad = ascii.encode('LSP-R1:$channelIdHex');

    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(envelopeKey), 128, nonce, aad);
    cipher.init(false, params);

    final out = Uint8List(cipher.getOutputSize(ciphertextWithTag.length));
    final int len;
    try {
      final processed = cipher.processBytes(
        ciphertextWithTag,
        0,
        ciphertextWithTag.length,
        out,
        0,
      );
      final finalLen = cipher.doFinal(out, processed);
      len = processed + finalLen;
    } catch (e) {
      throw FormatException(
        'Envelope decryption failed or authentication tag mismatch: $e',
      );
    }

    final plaintext = Uint8List.sublistView(out, 0, len);
    if (plaintext.length < 2) {
      throw const FormatException('Decrypted plaintext too short');
    }

    final bd = ByteData.sublistView(plaintext);
    final innerLen = bd.getUint16(0);

    if (2 + innerLen > plaintext.length) {
      throw FormatException(
        'Invalid inner payload length: $innerLen in plaintext of ${plaintext.length}',
      );
    }

    final jsonBytes = plaintext.sublist(2, 2 + innerLen);
    final jsonMap = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

    return RendezvousRecord.fromJson(jsonMap);
  }
}
