// Direct TLS Origin Server for Increment 5b with ephemeral certificate pinning.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../security/cert_factory.dart';
import '../security/crypto_primitives.dart';
import '../server/tunnel_origin_server.dart';

class DirectOriginServer {
  DirectOriginServer({
    this.maxConcurrentPerToken = 8,
    this.maxConcurrentTotal = 32,
    this.writeTimeout = const Duration(seconds: 60),
    String? deviceId,
  }) : _deviceId = deviceId ?? 'ls-direct-${hexOf(secureRandomBytes(8))}';

  final int maxConcurrentPerToken;
  final int maxConcurrentTotal;
  final Duration writeTimeout;
  final String _deviceId;

  HttpServer? _server;
  late final GeneratedIdentity _ephemeralIdentity;
  late final String _tlsPinHex;
  final Map<String, TunnelOriginShare> _shares = {};
  int _totalInFlight = 0;

  String get tlsPinHex => _tlsPinHex;
  int get port => _server?.port ?? 0;

  Future<void> start({int port = 0, InternetAddress? bindAddress}) async {
    _ephemeralIdentity = generateIdentity(deviceId: _deviceId);
    _tlsPinHex = _ephemeralIdentity.identity.fingerprint.toLowerCase();

    final secContext = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(
        utf8.encode(_ephemeralIdentity.identity.certPem),
      )
      ..usePrivateKeyBytes(_ephemeralIdentity.privateKeyPem);

    final addr = bindAddress ?? InternetAddress.anyIPv4;
    _server = await HttpServer.bindSecure(addr, port, secContext);
    _server!.listen(_handleRequest);
  }

  void registerShare(TunnelOriginShare share) {
    _shares[share.token] = share;
  }

  void revokeShare(String token) {
    final share = _shares[token];
    if (share != null) {
      share.isRevoked = true;
      share.onRevoked?.call('direct share revoked');
    }
  }

  Future<void> stop() async {
    for (final share in _shares.values) {
      share.isRevoked = true;
    }
    _shares.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    // Security headers per design 04
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.headers.set('Referrer-Policy', 'no-referrer');
    req.response.headers.set('X-Content-Type-Options', 'nosniff');

    final segments = req.uri.pathSegments;
    if (segments.length < 3 || segments[0] != 't') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final token = segments[1];
    final route = segments[2];

    final share = _shares[token];
    if (share == null) {
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }

    final now = DateTime.now();
    if (share.isRevoked ||
        (share.expiresAt != null && share.expiresAt!.isBefore(now))) {
      req.response.statusCode = HttpStatus.gone;
      await req.response.close();
      return;
    }

    if (_totalInFlight >= maxConcurrentTotal) {
      req.response.statusCode = HttpStatus.tooManyRequests;
      await req.response.close();
      return;
    }

    _totalInFlight++;
    try {
      if (route == 'healthz' && req.method == 'GET') {
        req.response.statusCode = HttpStatus.ok;
        req.response.write('OK');
        await req.response.close();
        return;
      }

      // Claim binding check
      final clientClaim = req.headers.value('X-LS-Claim');
      if (clientClaim == null || clientClaim.isEmpty) {
        req.response.statusCode = HttpStatus.unauthorized;
        await req.response.close();
        return;
      }

      if (share.boundClaims.isEmpty) {
        share.boundClaims.add(clientClaim);
      } else if (!share.boundClaims.contains(clientClaim)) {
        req.response.statusCode = HttpStatus.conflict;
        await req.response.close();
        return;
      }

      if (route == 'manifest' && req.method == 'GET') {
        req.response.headers.contentType = ContentType.binary;
        req.response.add(share.sealedManifest);
        await req.response.close();
        return;
      }

      if (route == 'f' &&
          req.method == 'GET' &&
          segments.length == 6 &&
          segments[4] == 'c') {
        final fid = int.tryParse(segments[3]);
        final cid = int.tryParse(segments[5]);

        if (fid == null || cid == null) {
          req.response.statusCode = HttpStatus.badRequest;
          await req.response.close();
          return;
        }

        final chunkData = await share.getChunk(fid, cid);
        req.response.headers.contentType = ContentType.binary;
        req.response.add(chunkData);
        await req.response.close();
        return;
      }

      if (route == 'ack' && req.method == 'POST') {
        share.onCompleted?.call(clientClaim);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } finally {
      _totalInFlight--;
    }
  }
}
