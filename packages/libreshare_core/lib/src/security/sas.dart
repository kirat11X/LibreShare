/// Short Authentication String with commit-then-reveal (docs/plans/inc3.md D4).
///
///  * `commit = b64url(SHA-256("LSP1-SAS-C" 0x00 || Ns || fpS || fpR'))` where `Ns` is the sender's
///    16 random bytes, `fpS` its own fingerprint and `fpR'` the receiver certificate fingerprint
///    **as the sender saw it** in the TLS handshake.
///  * `code = u32_be(SHA-256("LSP1-SAS-V" 0x00 || Ns || Nr || min(fp) || max(fp))[0..4]) mod 10^6`,
///    six digits with leading zeros, shown as `482 913`.
///
/// Fingerprints enter every hash as their 64 ASCII characters in uppercase hex (the LSP-1 section
/// 0.2 form); `min`/`max` compare those strings. All fields have fixed lengths, so the
/// concatenations are unambiguous. Nothing here logs; nonces and fingerprints are secrets until
/// the reveal.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'contracts.dart';
import 'crypto_primitives.dart';

/// Length of `Ns` and `Nr` in bytes.
const int kSasNonceBytes = 16;

final RegExp _fp64 = RegExp(r'^[0-9A-Fa-f]{64}$');

String _fp(String fingerprint) {
  if (!_fp64.hasMatch(fingerprint)) {
    throw ArgumentError.value('invalid', 'fingerprint');
  }
  return fingerprint.toUpperCase();
}

void _nonce(List<int> n, String name) {
  if (n.length != kSasNonceBytes) {
    throw ArgumentError.value('must be $kSasNonceBytes bytes', name);
  }
}

Uint8List _commitBytes(List<int> ns, String senderFp, String receiverFp) =>
    sha256Bytes(
      domainSeparate(SigDomain.sasCommit, [
        ...ns,
        ...ascii.encode(_fp(senderFp)),
        ...ascii.encode(_fp(receiverFp)),
      ]),
    );

/// The commitment the sender puts in `POST /sessions`: 43 base64url characters.
/// Throws [ArgumentError] for a nonce that is not 16 bytes or a malformed fingerprint.
String sasCommit({
  required List<int> ns,
  required String senderFingerprint,
  required String receiverFingerprintSeenBySender,
}) {
  _nonce(ns, 'ns');
  return b64urlEncode(
    _commitBytes(ns, senderFingerprint, receiverFingerprintSeenBySender),
  );
}

/// Receiver-side check of a revealed `Ns` against the stored [commit], using the receiver's **own**
/// fingerprint as [receiverFingerprintSeenBySender]. Every input is attacker-controlled: any
/// malformed value (bad commit text, wrong nonce length, bad fingerprint) yields false, never an
/// exception. The comparison is constant time.
bool sasCommitMatches({
  required String commit,
  required List<int> ns,
  required String senderFingerprint,
  required String receiverFingerprintSeenBySender,
}) {
  try {
    if (ns.length != kSasNonceBytes) return false;
    final expected = _commitBytes(
      ns,
      senderFingerprint,
      receiverFingerprintSeenBySender,
    );
    final given = b64urlDecode(commit);
    return constantTimeEquals(expected, given);
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// The six-digit code both screens show. Symmetric in [fingerprintA] and [fingerprintB].
/// Throws [ArgumentError] for a nonce that is not 16 bytes or a malformed fingerprint.
String sasCode({
  required List<int> ns,
  required List<int> nr,
  required String fingerprintA,
  required String fingerprintB,
}) {
  _nonce(ns, 'ns');
  _nonce(nr, 'nr');
  final a = _fp(fingerprintA);
  final b = _fp(fingerprintB);
  final lo = a.compareTo(b) <= 0 ? a : b;
  final hi = a.compareTo(b) <= 0 ? b : a;
  final h = sha256Bytes(
    domainSeparate(SigDomain.sasValue, [
      ...ns,
      ...nr,
      ...ascii.encode(lo),
      ...ascii.encode(hi),
    ]),
  );
  final v = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
  return (v % 1000000).toString().padLeft(6, '0');
}

/// `482913` -> `482 913` for display. Throws [ArgumentError] unless [code] is six digits.
String sasCodeDisplay(String code) {
  if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
    throw ArgumentError.value('not six digits', 'code');
  }
  return '${code.substring(0, 3)} ${code.substring(3)}';
}
