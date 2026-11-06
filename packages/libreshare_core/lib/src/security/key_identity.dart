/// The production [IdentityProvider]: a certificate plus its P-256 private key, checked against
/// each other at construction (docs/plans/inc3.md D1, D3).
///
/// Signatures are deterministic ECDSA (RFC 6979) over `domain + NUL + message`, raw `r || s`.
/// Nothing here logs; exception messages and `toString` carry no key material and at most the
/// 16-character fingerprint prefix.
library;

import 'dart:typed_data';

import 'cert_factory.dart';
import 'contracts.dart';
import 'crypto_primitives.dart';

/// Why a [KeyIdentity] could not be built.
enum KeyIdentityProblem {
  /// The certificate is malformed, outside the profile, or its self-signature is wrong.
  badCertificate,

  /// The private key PEM is not a P-256 PKCS#8 key.
  badPrivateKey,

  /// The certificate belongs to a different key pair than the private key.
  keyMismatch,

  /// The certificate CN is not the device id the caller expects.
  deviceIdMismatch,
}

/// Thrown by the [KeyIdentity] constructor. The message is a fixed phrase per [problem].
class KeyIdentityException implements Exception {
  const KeyIdentityException(this.problem);

  final KeyIdentityProblem problem;

  String get message => switch (problem) {
    KeyIdentityProblem.badCertificate => 'identity certificate is not valid',
    KeyIdentityProblem.badPrivateKey => 'identity private key is not valid',
    KeyIdentityProblem.keyMismatch =>
      'identity certificate does not match the private key',
    KeyIdentityProblem.deviceIdMismatch =>
      'identity certificate belongs to a different device id',
  };

  @override
  String toString() => 'KeyIdentityException: $message';
}

final class KeyIdentity implements IdentityProvider {
  KeyIdentity._(this.identity, this._d, this._pem);

  /// Builds an identity from a certificate (DER, PEM or both, which must agree) and the
  /// PKCS#8 PEM of its key. Verifies, in order: the certificate against the strict profile
  /// including its self-signature, that its CN equals [deviceId], that the key parses, and that
  /// the key derives the certificate's public key. The fingerprint is always recomputed from the
  /// certificate bytes.
  factory KeyIdentity({
    required String deviceId,
    Uint8List? certDer,
    String? certPem,
    required Uint8List privateKeyPem,
  }) {
    if (certDer == null && certPem == null) {
      throw ArgumentError('certDer or certPem is required');
    }
    final Uint8List der;
    try {
      final fromPem = certPem == null
          ? null
          : pemDecode(certPem, 'CERTIFICATE');
      if (fromPem != null &&
          certDer != null &&
          !constantTimeEquals(fromPem, certDer)) {
        throw const KeyIdentityException(KeyIdentityProblem.badCertificate);
      }
      der = Uint8List.fromList((certDer ?? fromPem)!);
    } on FormatException {
      throw const KeyIdentityException(KeyIdentityProblem.badCertificate);
    }
    final ParsedCertificate cert;
    try {
      cert = parseCertificate(der, verifySelfSignature: true);
    } on CertificateFormatException {
      throw const KeyIdentityException(KeyIdentityProblem.badCertificate);
    }
    if (cert.subjectCn != deviceId) {
      throw const KeyIdentityException(KeyIdentityProblem.deviceIdMismatch);
    }
    final BigInt d;
    try {
      d = decodePkcs8PrivateKeyPem(privateKeyPem);
    } on KeyFormatException {
      throw const KeyIdentityException(KeyIdentityProblem.badPrivateKey);
    }
    if (!constantTimeEquals(p256PublicPoint(d), cert.publicPoint)) {
      throw const KeyIdentityException(KeyIdentityProblem.keyMismatch);
    }
    return KeyIdentity._(
      DeviceIdentity(
        deviceId: deviceId,
        fingerprint: cert.fingerprint,
        certDer: der,
        certPem: pemEncode(der, 'CERTIFICATE'),
      ),
      d,
      Uint8List.fromList(privateKeyPem),
    );
  }

  /// Wraps the output of `generateIdentity` (re-verifying it like any stored identity).
  factory KeyIdentity.fromGenerated(GeneratedIdentity g) => KeyIdentity(
    deviceId: g.identity.deviceId,
    certDer: g.identity.certDer,
    privateKeyPem: g.privateKeyPem,
  );

  @override
  final DeviceIdentity identity;
  final BigInt _d;
  final Uint8List _pem;

  /// ECDSA P-256 / SHA-256 over `domain + 0x00 + message`, raw `r || s` (64 bytes), deterministic.
  /// [domain] must be non-empty and contain no NUL ([ArgumentError] otherwise).
  @override
  Uint8List sign(String domain, List<int> message) =>
      p256SignRaw(_d, domainSeparate(domain, message));

  /// A fresh copy of the PKCS#8 PEM; only the TLS listener may call this. Never log or persist it.
  @override
  Uint8List privateKeyPem() => Uint8List.fromList(_pem);

  @override
  String toString() =>
      'KeyIdentity(deviceId: ${identity.deviceId}, fp: ${shortFp(identity.fingerprint)})';
}
