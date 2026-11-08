// DirectConnection implementation for Increment 5b with ephemeral TLS certificate pinning.

import 'dart:convert';
import 'dart:io';

import '../security/crypto_primitives.dart';
import 'origin_pull_connection.dart';

class TlsPinMismatchException implements Exception {
  final String expectedPin;
  final String actualPin;
  TlsPinMismatchException({required this.expectedPin, required this.actualPin});

  @override
  String toString() =>
      'TlsPinMismatchException(expected: $expectedPin, got: $actualPin)';
}

class DirectConnection extends OriginPullConnection {
  final String expectedPinHex;

  DirectConnection({
    required super.candidate,
    required super.originBase,
    required super.token,
    required super.keys,
    required super.claim,
    required this.expectedPinHex,
  });

  /// Validates that the server's DER certificate SHA-256 fingerprint matches [expectedPinHex].
  bool validateCertificate(X509Certificate cert) {
    final der = cert.der;
    final digest = sha256Bytes(der);
    final actualFingerprint = hexOf(digest).toLowerCase();
    final expected = expectedPinHex.toLowerCase();

    return constantTimeEquals(
      utf8.encode(actualFingerprint),
      utf8.encode(expected),
    );
  }

  @override
  HttpClient createHttpClient() => createPinnedClient();

  /// Creates a pinned HttpClient configured specifically for this DirectConnection.
  HttpClient createPinnedClient() {
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
          final isValid = validateCertificate(cert);
          if (!isValid) {
            final actual = hexOf(sha256Bytes(cert.der)).toLowerCase();
            throw TlsPinMismatchException(
              expectedPin: expectedPinHex,
              actualPin: actual,
            );
          }
          return true;
        };
    return client;
  }
}
