// Concrete ChannelDeriver for daily epoch channels and envelope keys.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../security/crypto_primitives.dart';

/// Converts a 64-bit integer to 8 big-endian bytes.
Uint8List int64ToBe(int value) {
  final bd = ByteData(8);
  bd.setInt64(0, value);
  return bd.buffer.asUint8List();
}

/// Derives ephemeral daily channels and envelope encryption keys from pairwise secret.
abstract interface class ChannelDeriver {
  /// Computes the current 24-hour UTC epoch number.
  int currentEpoch({DateTime? now});

  /// Computes the 64-hex channel identifier for [peerDeviceId] during [epoch].
  String deriveChannelId({
    required Uint8List pairKey,
    required String peerDeviceId,
    int? epoch,
  });

  /// Derives the 32-byte AES-256-GCM envelope encryption key for [epoch].
  Uint8List deriveEnvelopeKey({required Uint8List pairKey, int? epoch});
}

/// Standard production implementation of [ChannelDeriver] (LSP-R1 Section 2).
class ChannelDeriverImpl implements ChannelDeriver {
  const ChannelDeriverImpl();

  @override
  int currentEpoch({DateTime? now}) {
    final utc = (now ?? DateTime.now()).toUtc();
    return utc.millisecondsSinceEpoch ~/ (86400 * 1000);
  }

  @override
  String deriveChannelId({
    required Uint8List pairKey,
    required String peerDeviceId,
    int? epoch,
  }) {
    if (pairKey.length != 32) {
      throw ArgumentError('pairKey must be exactly 32 bytes');
    }
    final ep = epoch ?? currentEpoch();
    final bytes = BytesBuilder(copy: false);
    bytes.add(ascii.encode('LSP-R1-CHAN'));
    bytes.add(int64ToBe(ep));
    bytes.add(utf8.encode(peerDeviceId));

    return hexOf(hmacSha256(pairKey, bytes.takeBytes())).toLowerCase();
  }

  @override
  Uint8List deriveEnvelopeKey({required Uint8List pairKey, int? epoch}) {
    if (pairKey.length != 32) {
      throw ArgumentError('pairKey must be exactly 32 bytes');
    }
    final ep = epoch ?? currentEpoch();
    return hkdfSha256(
      ikm: pairKey,
      salt: int64ToBe(ep),
      info: ascii.encode('LSP-R1-ENV'),
      length: 32,
    );
  }
}
