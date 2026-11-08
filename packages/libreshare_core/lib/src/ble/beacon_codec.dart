import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Epoch duration for rotating Ephemeral Identifiers (15 minutes).
const Duration kEidEpochDuration = Duration(minutes: 15);
const int kEidEpochSeconds = 900;
const int kEidLength = 8;
const String kEidHmacPrefix = 'LSBLE1-EID';

/// Derives an 8-byte Ephemeral ID for a given epoch using HMAC-SHA256 (design 03 section 3.3).
Uint8List deriveEid(List<int> advKey, int epoch) {
  if (advKey.length != 32) {
    throw ArgumentError.value(
      advKey.length,
      'advKey',
      'advKey must be exactly 32 bytes',
    );
  }
  final prefixBytes = kEidHmacPrefix.codeUnits;
  final buffer = ByteData(prefixBytes.length + 8);
  final uint8 = buffer.buffer.asUint8List();
  uint8.setRange(0, prefixBytes.length, prefixBytes);
  // Big-endian 64-bit uint for epoch
  buffer.setUint64(prefixBytes.length, epoch, Endian.big);

  final hmac = Hmac(sha256, advKey);
  final digest = hmac.convert(uint8);
  return Uint8List.fromList(digest.bytes.sublist(0, kEidLength));
}

/// Computes the 15-minute epoch index for a given timestamp.
int epochForTime(DateTime time) {
  final seconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
  return seconds ~/ kEidEpochSeconds;
}

/// Derives the current rotating EID for [advKey] at the specified [time].
Uint8List generateEidForTime(List<int> advKey, DateTime time) {
  return deriveEid(advKey, epochForTime(time));
}

/// Verifies whether [candidateEid] matches [advKey] at [time] within +/- [tolerance] epochs.
bool matchesEid(
  List<int> candidateEid,
  List<int> advKey,
  DateTime time, {
  int tolerance = 1,
}) {
  if (candidateEid.length != kEidLength || advKey.length != 32) return false;
  final currentEpoch = epochForTime(time);
  for (var delta = -tolerance; delta <= tolerance; delta++) {
    final expected = deriveEid(advKey, currentEpoch + delta);
    if (_bytesEqual(candidateEid, expected)) {
      return true;
    }
  }
  return false;
}

/// Generates a cryptographically secure random 8-byte EID for unpaired / OPEN mode.
Uint8List generateRandomEid([Random? random]) {
  final rnd = random ?? Random.secure();
  final bytes = Uint8List(kEidLength);
  for (var i = 0; i < kEidLength; i++) {
    bytes[i] = rnd.nextInt(256);
  }
  return bytes;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
