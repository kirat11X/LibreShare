/// TLS contexts for the secure profile (docs/plans/inc3.md D1, D8).
///
///  * Server: the device identity certificate and key, TLS 1.3 only, no trusted roots, and no
///    client-certificate request (clients authenticate with `X-LS-Auth`, because `dart:io` cannot
///    complete a handshake with an unknown self-signed client certificate; spike S-A).
///  * Client: nothing is trusted, so every server certificate reaches `badCertificateCallback`,
///    where [certificateMatchesPin] decides. TLS 1.3 only.
///
/// The key PEM is handed to the TLS stack and is never logged or retained here.
library;

import 'dart:convert';
import 'dart:io';

import 'contracts.dart';
import 'crypto_primitives.dart';

/// Server-side context for `HttpServer.bindSecure` / `SecureServerSocket.bind`: identity
/// certificate and key from [identity], TLS 1.3 minimum, no trusted roots, no ALPN. Bind it
/// without `requestClientCertificate`.
SecurityContext buildServerContext(IdentityProvider identity) {
  return SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
    ..useCertificateChainBytes(utf8.encode(identity.identity.certPem))
    ..usePrivateKeyBytes(identity.privateKeyPem());
}

/// Client-side context: no system or bundled roots (every peer certificate must pass the pin
/// check), TLS 1.3 minimum. Pair it with an `HttpClient.badCertificateCallback` that returns
/// [certificateMatchesPin] (or, for an unpinned first contact, records the fingerprint and lets
/// the SAS flow decide).
SecurityContext buildClientContext() =>
    SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;

final RegExp _fp64 = RegExp(r'^[0-9A-Fa-f]{64}$');

/// True when SHA-256 of [cert]'s DER equals [expectedFingerprint] (64 hex characters, any case).
/// Constant-time comparison; false for an empty DER or a malformed expected value.
bool certificateMatchesPin(X509Certificate cert, String expectedFingerprint) {
  if (!_fp64.hasMatch(expectedFingerprint)) return false;
  final der = cert.der;
  if (der.isEmpty) return false;
  return constantTimeEquals(
    utf8.encode(fingerprintHex(der)),
    utf8.encode(expectedFingerprint.toUpperCase()),
  );
}
