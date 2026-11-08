import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../security/tunnel_crypto.dart';

class TunnelOriginShare {
  final String token;
  final TunnelKeys keys;
  final Uint8List sealedManifest;
  final int totalBytes;
  final int maxReceivers; // 1 default, 0 = anyone, N = up to N
  final DateTime? expiresAt;
  final Future<Uint8List> Function(int fileIndex, int chunkIndex) getChunk;
  final void Function(String claim)? onCompleted;
  final void Function(String reason)? onRevoked;

  bool isRevoked = false;
  bool isCompleted = false;
  final Set<String> boundClaims = {};
  int bytesServed = 0;
  int concurrentRequests = 0;

  TunnelOriginShare({
    required this.token,
    required this.keys,
    required this.sealedManifest,
    required this.totalBytes,
    this.maxReceivers = 1,
    this.expiresAt,
    required this.getChunk,
    this.onCompleted,
    this.onRevoked,
  });

  int get maxAllowedBytes {
    final factor = maxReceivers == 0 ? 10 : maxReceivers;
    return 2 * totalBytes * factor;
  }
}

class TunnelOriginServer {
  final int maxConcurrentPerToken;
  final int maxConcurrentTotal;
  final Duration writeTimeout;

  HttpServer? _server;
  final Map<String, TunnelOriginShare> _shares = {};
  int _totalInFlight = 0;

  TunnelOriginServer({
    this.maxConcurrentPerToken = 8,
    this.maxConcurrentTotal = 32,
    this.writeTimeout = const Duration(seconds: 60),
  });

  int get port => _server?.port ?? 0;

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handleRequest);
  }

  void registerShare(TunnelOriginShare share) {
    _shares[share.token] = share;
  }

  void revokeShare(String token) {
    final share = _shares[token];
    if (share != null) {
      share.isRevoked = true;
      share.onRevoked?.call('manual revocation');
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
    // Apply required security headers on every response
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.headers.set('Referrer-Policy', 'no-referrer');
    req.response.headers.set('X-Content-Type-Options', 'nosniff');

    final segments = req.uri.pathSegments;

    // Route: /t/{token}
    if (segments.length == 2 && segments[0] == 't') {
      // Static HTML landing page (for browser/bot clicks, no claim required, no side effect)
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
        ..write(
          '<!DOCTYPE html><html><head><title>LibreShare</title>'
          '<meta name=referrer content=no-referrer></head>'
          '<body><p>Open this link in LibreShare to download the shared files.</p></body></html>',
        );
      await req.response.close();
      return;
    }

    // Must be /t/{token}/...
    if (segments.length < 3 || segments[0] != 't') {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await req.response.close();
      return;
    }

    final token = segments[1];
    final share = _shares[token];

    if (share == null) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('Share Not Found');
      await req.response.close();
      return;
    }

    // Check expiration and revocation
    final now = DateTime.now();
    if (share.isRevoked ||
        (share.expiresAt != null && share.expiresAt!.isBefore(now))) {
      req.response
        ..statusCode = HttpStatus.gone
        ..write('Share Expired or Revoked');
      await req.response.close();
      return;
    }

    // If one-time completed, subsequent requests return 401 Unauthorized
    if (share.isCompleted) {
      req.response
        ..statusCode = HttpStatus.unauthorized
        ..write('Share Already Completed');
      await req.response.close();
      return;
    }

    // Concurrency limit checks
    if (_totalInFlight >= maxConcurrentTotal) {
      req.response
        ..statusCode = HttpStatus.tooManyRequests
        ..headers.set('Retry-After', '5')
        ..write('Server Concurrency Limit Reached');
      await req.response.close();
      return;
    }

    if (share.concurrentRequests >= maxConcurrentPerToken) {
      req.response
        ..statusCode = HttpStatus.tooManyRequests
        ..headers.set('Retry-After', '5')
        ..write('Token Concurrency Limit Reached');
      await req.response.close();
      return;
    }

    // Validate X-LS-Claim header
    final claim = req.headers.value('X-LS-Claim');
    if (claim == null || claim.isEmpty) {
      req.response
        ..statusCode = HttpStatus.unauthorized
        ..write('Missing X-LS-Claim Header');
      await req.response.close();
      return;
    }

    // Claim binding logic
    if (share.maxReceivers == 1) {
      if (share.boundClaims.isEmpty) {
        share.boundClaims.add(claim);
      } else if (!share.boundClaims.contains(claim)) {
        req.response
          ..statusCode = HttpStatus.conflict
          ..write('Share Bound to Another Claimant');
        await req.response.close();
        return;
      }
    } else if (share.maxReceivers > 1) {
      if (share.boundClaims.length < share.maxReceivers) {
        share.boundClaims.add(claim);
      } else if (!share.boundClaims.contains(claim)) {
        req.response
          ..statusCode = HttpStatus.conflict
          ..write('Max Claimants Reached');
        await req.response.close();
        return;
      }
    } else {
      // maxReceivers == 0 (anyone)
      share.boundClaims.add(claim);
    }

    _totalInFlight++;
    share.concurrentRequests++;

    try {
      final action = segments[2];

      if (action == 'manifest' && req.method == 'GET') {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..add(share.sealedManifest);
        await req.response.close();
        return;
      }

      if (action == 'f' &&
          req.method == 'GET' &&
          segments.length == 6 &&
          segments[4] == 'c') {
        final fid = int.tryParse(segments[3]);
        final cid = int.tryParse(segments[5]);

        if (fid == null || cid == null) {
          req.response
            ..statusCode = HttpStatus.badRequest
            ..write('Invalid file or chunk index');
          await req.response.close();
          return;
        }

        // Byte budget check
        if (share.bytesServed >= share.maxAllowedBytes) {
          share.isRevoked = true;
          share.onRevoked?.call('Byte budget exceeded');
          req.response
            ..statusCode = HttpStatus.gone
            ..write('Byte budget exceeded');
          await req.response.close();
          return;
        }

        final chunkData = await share.getChunk(fid, cid);
        share.bytesServed += chunkData.length;

        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream');

        // Write with writeTimeout
        try {
          await req.response.addStream(
            Stream.value(chunkData).timeout(writeTimeout),
          );
          await req.response.close();
        } catch (_) {
          // Timeout or connection closed by client
        }
        return;
      }

      if (action == 'ack' && req.method == 'POST') {
        final bodyBytes = await req.fold<List<int>>([], (p, e) => p..addAll(e));
        if (bodyBytes.isEmpty || bodyBytes.length > 2048) {
          req.response
            ..statusCode = HttpStatus.badRequest
            ..write('Invalid ack payload');
          await req.response.close();
          return;
        }

        // Try decrypting ack
        Uint8List? decryptedAck;
        bool isFinal = false;

        // Try final ack first (fileIndex: 0xFFFFFFFF, chunkIndex: 0)
        try {
          decryptedAck = share.keys.open(
            TunnelPurpose.ack,
            bodyBytes,
            fileIndex: kTunnelManifestFileIndex,
            chunkIndex: 0,
          );
          isFinal = true;
        } catch (_) {
          // If not final ack, check header hints or try (0, 0)
          final headerFid =
              int.tryParse(req.headers.value('X-LS-File-Index') ?? '0') ?? 0;
          final headerCid =
              int.tryParse(req.headers.value('X-LS-Chunk-Index') ?? '0') ?? 0;
          try {
            decryptedAck = share.keys.open(
              TunnelPurpose.ack,
              bodyBytes,
              fileIndex: headerFid,
              chunkIndex: headerCid,
            );
          } catch (_) {
            // Decryption failed
            req.response
              ..statusCode = HttpStatus.unauthorized
              ..write('Invalid ack signature');
            await req.response.close();
            return;
          }
        }

        try {
          final ackMap =
              jsonDecode(utf8.decode(decryptedAck)) as Map<String, dynamic>;
          if (ackMap['final'] == true || isFinal) {
            share.isCompleted = true;
            share.onCompleted?.call(claim);
          }
        } catch (_) {
          // Ignore JSON decode error if not final
        }

        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      }

      req.response
        ..statusCode = HttpStatus.notFound
        ..write('Unknown action');
      await req.response.close();
    } finally {
      _totalInFlight--;
      share.concurrentRequests--;
    }
  }
}
