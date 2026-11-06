/// Signature verification and the `X-LS-Auth` request proof (docs/plans/inc3.md D1, D9 and
/// section 3 item 3).
///
/// Header grammar (all parts are strict ASCII):
///
///     v1.<cert b64url>.<ts ms>.<nonce b64url>.<sig b64url>
///
///  * `cert`  DER certificate of the sender, at most 2 KiB;
///  * `ts`    Unix milliseconds in canonical decimal (no sign, no leading zeros, at most 16 digits);
///  * `nonce` 16 random bytes, 22 characters;
///  * `sig`   raw `r || s`, 64 bytes, 86 characters.
///
/// The signature covers `SigDomain.auth` + NUL + the UTF-8 text
///
///     METHOD \n pathAndQuery \n hex(SHA-256(body)) \n ts \n nonce \n serverFp \n clientFp
///
/// with `METHOD` upper-cased, `hex` lowercase, both fingerprints uppercase hex, `serverFp` the
/// fingerprint of the certificate the client saw in the TLS handshake and `clientFp` the SHA-256
/// of `cert`. (The plan writes the label with a trailing LF; the contract in contracts.dart makes
/// the separator after the label a NUL for every signature, so the label is not repeated.)
///
/// Verification order is cheapest first and a nonce is recorded only after the signature
/// verified, so forged headers can neither burn nonces nor evict real ones.
///
/// Nothing here logs or puts header, certificate or signature bytes into an exception or
/// `toString`; fingerprints appear at most as their 16-character prefix.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../protocol.dart' show kAuthWindow;
import 'cert_factory.dart';
import 'contracts.dart';
import 'crypto_primitives.dart';

/// Version tag of the header grammar.
const String kAuthVersion = 'v1';

/// Maximum accepted header length (docs/plans/inc3.md D9).
const int kMaxAuthHeaderBytes = 4096;

/// How long a nonce is remembered, and how many are kept.
const Duration kNonceCacheTtl = Duration(minutes: 5);
const int kNonceCacheCapacity = 8192;

const int _kNonceBytes = 16;
const int _kMaxPathChars = 2048;
// base64url length of a 2048-byte certificate, unpadded.
const int _kMaxCertChars = 2731;

final RegExp _methodToken = RegExp(r'^[A-Za-z]{1,16}$');
final RegExp _target = RegExp(r'^/[\x21-\x7E]*$');
final RegExp _fp64 = RegExp(r'^[0-9A-Fa-f]{64}$');
final RegExp _timestamp = RegExp(r'^(0|[1-9][0-9]{0,15})$');

/// Why a proof was refused.
enum AuthFailure {
  /// No header.
  missing,

  /// The header violates the grammar or a size cap.
  malformed,

  /// The timestamp is outside the accepted window.
  stale,

  /// The nonce was already used.
  replayed,

  /// The signature does not verify over the signed text. This also covers a proof that names a
  /// different server fingerprint (channel binding): the header does not carry the server
  /// fingerprint, so that case cannot be told apart from a forged signature.
  badSignature,

  /// Reserved. The v1 grammar cannot distinguish it from [badSignature]; verifiers never return it.
  serverFingerprintMismatch,

  /// The certificate is malformed, too large, a CA certificate or not an acceptable P-256 key.
  certInvalid,
}

sealed class AuthResult {
  const AuthResult();
}

/// The proof verified: [peer] is who signed.
final class AuthOk extends AuthResult {
  const AuthOk(this.peer);
  final AuthenticatedPeer peer;
  @override
  String toString() => 'AuthOk(fp: ${shortFp(peer.fingerprint)})';
}

final class AuthFailed extends AuthResult {
  const AuthFailed(this.reason);
  final AuthFailure reason;
  @override
  String toString() => 'AuthFailed(${reason.name})';
}

/// Remembers recently seen nonces: entries live [ttl], at most [capacity] are kept, and the
/// oldest entry goes first when the bound is hit. The clock is injectable for tests.
class NonceCache {
  NonceCache({
    this.ttl = kNonceCacheTtl,
    this.capacity = kNonceCacheCapacity,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }

  final Duration ttl;
  final int capacity;
  final DateTime Function() _clock;
  // Insertion-ordered: the first entry is the oldest.
  final Map<String, DateTime> _seen = <String, DateTime>{};

  void _purge() {
    final cutoff = _clock().subtract(ttl);
    while (_seen.isNotEmpty) {
      final first = _seen.entries.first;
      if (first.value.isAfter(cutoff)) break;
      _seen.remove(first.key);
    }
  }

  int get length {
    _purge();
    return _seen.length;
  }

  bool contains(String key) {
    _purge();
    return _seen.containsKey(key);
  }

  /// Records [key]; returns false when it was already present (a replay).
  bool add(String key) {
    _purge();
    if (_seen.containsKey(key)) return false;
    _seen[key] = _clock();
    while (_seen.length > capacity) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }
}

/// `path` plus `?query` exactly as encoded on the request line (origin form); `/` for an empty
/// path. Use this on both ends so the signed target is byte-identical.
String pathAndQueryOf(Uri uri) {
  final p = uri.path.isEmpty ? '/' : uri.path;
  return uri.hasQuery ? '$p?${uri.query}' : p;
}

String _normalizeFp(String fp) {
  if (!_fp64.hasMatch(fp)) throw ArgumentError.value('invalid', 'fingerprint');
  return fp.toUpperCase();
}

/// The exact UTF-8 text the proof signature covers (before domain separation). Exposed for the
/// published test vectors.
Uint8List buildAuthMessage({
  required String method,
  required String pathAndQuery,
  required List<int> body,
  required int timestampMs,
  required String nonceB64,
  required String serverFingerprint,
  required String clientFingerprint,
}) => Uint8List.fromList(
  utf8.encode(
    [
      method.toUpperCase(),
      pathAndQuery,
      sha256Hex(body),
      '$timestampMs',
      nonceB64,
      _normalizeFp(serverFingerprint),
      _normalizeFp(clientFingerprint),
    ].join('\n'),
  ),
);

/// Builds the `X-LS-Auth` value for one request. [serverFingerprint] is the fingerprint of the
/// certificate the client observed in the TLS handshake with the peer it is about to send to.
/// [now] and [nonce] (16 bytes) default to the wall clock and fresh randomness; tests inject them.
/// Throws [ArgumentError] for an unusable method, target, fingerprint or nonce.
String buildAuthHeader({
  required IdentityProvider identity,
  required String method,
  required String pathAndQuery,
  required List<int> body,
  required String serverFingerprint,
  DateTime? now,
  Uint8List? nonce,
}) {
  if (!_methodToken.hasMatch(method)) {
    throw ArgumentError.value('invalid', 'method');
  }
  if (pathAndQuery.length > _kMaxPathChars || !_target.hasMatch(pathAndQuery)) {
    throw ArgumentError.value('invalid', 'pathAndQuery');
  }
  final serverFp = _normalizeFp(serverFingerprint);
  final n = nonce ?? secureRandomBytes(_kNonceBytes);
  if (n.length != _kNonceBytes) {
    throw ArgumentError.value('must be $_kNonceBytes bytes', 'nonce');
  }
  final cert = identity.identity.certDer;
  if (cert.length > kMaxCertDerBytes) {
    throw ArgumentError.value('too large', 'identity.certDer');
  }
  final ts = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  final nonceB64 = b64urlEncode(n);
  final message = buildAuthMessage(
    method: method,
    pathAndQuery: pathAndQuery,
    body: body,
    timestampMs: ts,
    nonceB64: nonceB64,
    serverFingerprint: serverFp,
    clientFingerprint: fingerprintHex(cert),
  );
  final sig = identity.sign(SigDomain.auth, message);
  return [
    kAuthVersion,
    b64urlEncode(cert),
    '$ts',
    nonceB64,
    b64urlEncode(sig),
  ].join('.');
}

/// Verifies an `X-LS-Auth` header against the request the server actually received.
/// [ownFingerprint] is the server's own certificate fingerprint (channel binding), [nonces] its
/// replay cache, [now] its clock. Never throws on attacker-controlled input; every refusal is an
/// [AuthFailed] with the first reason in the order: missing, malformed, stale, replayed,
/// certInvalid, badSignature. [ownFingerprint] must be a valid fingerprint ([ArgumentError]).
AuthResult verifyAuthHeader({
  required String? header,
  required String method,
  required String pathAndQuery,
  required List<int> body,
  required String ownFingerprint,
  required DateTime now,
  required NonceCache nonces,
  Duration window = kAuthWindow,
}) {
  final ownFp = _normalizeFp(ownFingerprint);
  try {
    if (header == null || header.isEmpty) {
      return const AuthFailed(AuthFailure.missing);
    }
    if (header.length > kMaxAuthHeaderBytes ||
        !_methodToken.hasMatch(method) ||
        pathAndQuery.length > _kMaxPathChars ||
        !_target.hasMatch(pathAndQuery)) {
      return const AuthFailed(AuthFailure.malformed);
    }
    final p = header.split('.');
    if (p.length != 5 || p[0] != kAuthVersion) {
      return const AuthFailed(AuthFailure.malformed);
    }
    final certText = p[1];
    if (certText.isEmpty ||
        !_timestamp.hasMatch(p[2]) ||
        p[3].length != 22 ||
        p[4].length != 86) {
      return const AuthFailed(AuthFailure.malformed);
    }
    final Uint8List sig;
    final Uint8List nonce;
    final Uint8List certDer;
    try {
      sig = b64urlDecode(p[4]);
      nonce = b64urlDecode(p[3]);
      if (certText.length > _kMaxCertChars) {
        // Still must be valid base64url to be "a certificate that is too large".
        b64urlDecode(certText);
        return const AuthFailed(AuthFailure.certInvalid);
      }
      certDer = b64urlDecode(certText);
    } on FormatException {
      return const AuthFailed(AuthFailure.malformed);
    }
    if (sig.length != 64 || nonce.length != _kNonceBytes) {
      return const AuthFailed(AuthFailure.malformed);
    }
    final ts = int.parse(p[2]);
    final skew = (now.toUtc().millisecondsSinceEpoch - ts).abs();
    if (skew > window.inMilliseconds) {
      return const AuthFailed(AuthFailure.stale);
    }
    final ParsedCertificate cert;
    try {
      cert = parseCertificate(certDer);
    } on CertificateFormatException {
      return const AuthFailed(AuthFailure.certInvalid);
    }
    final clientFp = cert.fingerprint;
    final key = '$clientFp/${p[3]}';
    if (nonces.contains(key)) {
      return const AuthFailed(AuthFailure.replayed);
    }
    final message = buildAuthMessage(
      method: method,
      pathAndQuery: pathAndQuery,
      body: body,
      timestampMs: ts,
      nonceB64: p[3],
      serverFingerprint: ownFp,
      clientFingerprint: clientFp,
    );
    if (!p256VerifyRaw(
      cert.publicPoint,
      domainSeparate(SigDomain.auth, message),
      sig,
    )) {
      return const AuthFailed(AuthFailure.badSignature);
    }
    nonces.add(key);
    return AuthOk(
      AuthenticatedPeer(
        fingerprint: clientFp,
        certDer: certDer,
        deviceId: cert.subjectCn,
      ),
    );
  } catch (_) {
    // Trust boundary: a bug or a surprising input must refuse, never throw or accept.
    return const AuthFailed(AuthFailure.malformed);
  }
}

/// Verifies a raw `r || s` signature made by the key in [certDer] over [domain] + NUL + [message].
/// Returns false for r or s outside `[1, n-1]`, wrong lengths, certificates that are oversize,
/// malformed, CA certificates or not on P-256, and for any invalid [domain]. Never throws.
bool verifySignature({
  required Uint8List certDer,
  required String domain,
  required List<int> message,
  required List<int> signature,
}) {
  try {
    if (signature.length != 64) return false;
    final cert = parseCertificate(certDer);
    return p256VerifyRaw(
      cert.publicPoint,
      domainSeparate(domain, message),
      signature,
    );
  } catch (_) {
    return false;
  }
}
