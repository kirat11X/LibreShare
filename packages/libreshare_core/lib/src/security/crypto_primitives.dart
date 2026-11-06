/// Hash, MAC, KDF, constant-time compare, randomness and base64url helpers shared by every
/// security module (docs/plans/inc3.md D2-D5, D9). Pure Dart, no Flutter.
///
/// Nothing here logs or includes inputs in exception text: keys, nonces and tokens pass through
/// these functions.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// SHA-256 of [data] as 32 raw bytes.
Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(c.sha256.convert(data).bytes);

/// SHA-256 of [data] as 64 **lowercase** hex characters (file and chunk hashes, LSP-1 section 0.2).
String sha256Hex(List<int> data) => c.sha256.convert(data).toString();

/// Certificate fingerprint: **uppercase** hex SHA-256 of the DER certificate (64 characters,
/// LSP-1 section 0.2).
String fingerprintHex(List<int> der) => sha256Hex(der).toUpperCase();

/// HMAC-SHA-256 (RFC 2104). Keys longer than the block size are hashed first by the primitive.
Uint8List hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

/// Largest output [hkdfSha256] can produce: 255 blocks of the 32-byte hash (RFC 5869 section 2.3).
const int kHkdfSha256MaxLength = 255 * 32;

/// HKDF-SHA-256 (RFC 5869): extract with [salt] (empty means 32 zero bytes, as the RFC says),
/// expand with [info] to [length] bytes (1..[kHkdfSha256MaxLength]).
Uint8List hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) {
  if (length < 1 || length > kHkdfSha256MaxLength) {
    throw ArgumentError.value(length, 'length', 'must be in 1..8160');
  }
  final prk = hmacSha256(salt.isEmpty ? Uint8List(32) : salt, ikm);
  final out = BytesBuilder(copy: false);
  var previous = Uint8List(0);
  var counter = 1;
  while (out.length < length) {
    final block = BytesBuilder(copy: false)
      ..add(previous)
      ..add(info)
      ..addByte(counter++);
    previous = hmacSha256(prk, block.takeBytes());
    out.add(previous);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// Compares [a] and [b] without exiting at the first differing byte. Different lengths are
/// unequal (the length itself is not treated as secret). Best effort: Dart gives no hard
/// constant-time guarantee, but there is no data-dependent branch or early exit.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    diff |= x ^ y;
  }
  return diff == 0;
}

final Random _secure = Random.secure();

/// [n] bytes from the operating system's CSPRNG (`Random.secure`).
Uint8List secureRandomBytes(int n) {
  if (n < 0) {
    throw ArgumentError.value(n, 'n', 'must not be negative');
  }
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}

/// Uniform integer in `[0, max)` by rejection sampling over 32 random bits, so that PIN digits
/// carry no modulo bias. [max] must be in 1..2^32. [random] exists for tests; production uses
/// `Random.secure`.
int randomIntBelow(int max, {Random? random}) {
  if (max < 1 || max > 0x100000000) {
    throw ArgumentError.value(max, 'max', 'must be in 1..2^32');
  }
  final rnd = random ?? _secure;
  // Largest multiple of max not above 2^32: draws at or above it would favour small results.
  final limit = 0x100000000 - (0x100000000 % max);
  while (true) {
    var v = 0;
    for (var i = 0; i < 4; i++) {
      v = (v << 8) | rnd.nextInt(256);
    }
    if (v < limit) return v % max;
  }
}

/// base64url without padding (RFC 4648 section 5).
String b64urlEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

final RegExp _b64urlAlphabet = RegExp(r'^[A-Za-z0-9_-]*$');

/// Strict base64url decoder: no padding, only `A-Za-z0-9_-`, length not 1 mod 4, and the encoding
/// must be canonical (re-encoding gives the same text, so stray trailing bits are refused).
/// Throws [FormatException] with a fixed message that never echoes [s].
Uint8List b64urlDecode(String s) {
  if (!_b64urlAlphabet.hasMatch(s) || s.length % 4 == 1) {
    throw const FormatException('invalid base64url');
  }
  final padded = s + '=' * ((4 - s.length % 4) % 4);
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(padded);
  } on FormatException {
    throw const FormatException('invalid base64url');
  }
  if (b64urlEncode(bytes) != s) {
    throw const FormatException('non-canonical base64url');
  }
  return bytes;
}

/// The bytes every signature and MAC in the protocol covers: UTF-8 [domain], one NUL byte, then
/// [message] (docs/plans/inc3.md D1; `SigDomain` in contracts.dart). [domain] must be non-empty and
/// contain no NUL, so no domain can be a spliced prefix of another.
Uint8List domainSeparate(String domain, List<int> message) {
  if (domain.isEmpty || domain.contains('\u0000')) {
    throw ArgumentError.value('invalid', 'domain');
  }
  final label = utf8.encode(domain);
  final out = Uint8List(label.length + 1 + message.length);
  out.setRange(0, label.length, label);
  out[label.length] = 0;
  out.setRange(label.length + 1, out.length, message);
  return out;
}

/// Big-endian unsigned bytes to [BigInt] (empty input is zero).
BigInt bigIntFromBytes(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// [v] (non-negative) as exactly [length] big-endian bytes. Throws [ArgumentError] if it does not fit.
Uint8List bigIntToBytes(BigInt v, int length) {
  if (v.isNegative || v.bitLength > length * 8) {
    throw ArgumentError.value(length, 'length', 'value does not fit');
  }
  final out = Uint8List(length);
  var x = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x >>= 8;
  }
  return out;
}

/// Lowercase hex of [bytes]. Only for tests, vectors and non-secret data.
String hexOf(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
