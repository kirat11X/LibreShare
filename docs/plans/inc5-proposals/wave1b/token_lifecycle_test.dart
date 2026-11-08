import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:test/test.dart';

void main() {
  group('Token Lifecycle & Claim Binding Integration Tests', () {
    late TunnelOriginServer server;
    late int serverPort;
    final testToken = 'token_lifecycle_123';
    late TunnelKeys keys;
    late Uint8List sealedManifest;

    setUp(() async {
      keys = TunnelKeys.fromRootKey(List.filled(32, 7));
      sealedManifest = keys.seal(
        TunnelPurpose.manifest,
        utf8.encode(
          jsonEncode({
            'files': [
              {'id': '0', 'name': 'test.bin', 'size': 500},
            ],
          }),
        ),
      );

      server = TunnelOriginServer();
      await server.start();
      serverPort = server.port;
    });

    tearDown(() async {
      await server.stop();
    });

    test('static landing page GET /t/{token} returns 200 HTML with security headers', () async {
      server.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: 500,
          maxReceivers: 1,
          getChunk: (fid, cid) async => Uint8List(100),
        ),
      );

      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$testToken'),
      );
      final resp = await req.close();

      expect(resp.statusCode, equals(HttpStatus.ok));
      expect(resp.headers.contentType?.mimeType, equals('text/html'));
      expect(resp.headers.value('cache-control'), equals('no-store'));
      expect(resp.headers.value('referrer-policy'), equals('no-referrer'));
      expect(resp.headers.value('x-content-type-options'), equals('nosniff'));

      final body = await resp.transform(utf8.decoder).join();
      expect(body, contains('LibreShare'));
      client.close();
    });

    test(
      'Mode 1 claim binding: first claimant binds, second gets 409',
      () async {
        server.registerShare(
          TunnelOriginShare(
            token: testToken,
            keys: keys,
            sealedManifest: sealedManifest,
            totalBytes: 500,
            maxReceivers: 1,
            getChunk: (fid, cid) async => Uint8List(100),
          ),
        );

        final client = HttpClient();

        // First request without claim header -> 401
        final reqNoClaim = await client.getUrl(
          Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/manifest'),
        );
        final respNoClaim = await reqNoClaim.close();
        expect(respNoClaim.statusCode, equals(HttpStatus.unauthorized));

        // First claimant with claim-A -> 200 OK (binds share)
        final req1 = await client.getUrl(
          Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/manifest'),
        );
        req1.headers.set('X-LS-Claim', 'claim_AAAA_123456');
        final resp1 = await req1.close();
        expect(resp1.statusCode, equals(HttpStatus.ok));
        await resp1.drain();

        // Repeat request with same claim-A -> 200 OK
        final req1b = await client.getUrl(
          Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/manifest'),
        );
        req1b.headers.set('X-LS-Claim', 'claim_AAAA_123456');
        final resp1b = await req1b.close();
        expect(resp1b.statusCode, equals(HttpStatus.ok));
        await resp1b.drain();

        // Second claimant with claim-B -> 409 Conflict
        final req2 = await client.getUrl(
          Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/manifest'),
        );
        req2.headers.set('X-LS-Claim', 'claim_BBBB_654321');
        final resp2 = await req2.close();
        expect(resp2.statusCode, equals(HttpStatus.conflict));

        client.close();
      },
    );

    test('Mode N allows up to N claimants; Mode 0 allows anyone', () async {
      final tokenN = 'token_mode_n';
      server.registerShare(
        TunnelOriginShare(
          token: tokenN,
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: 500,
          maxReceivers: 2, // Mode N with N=2
          getChunk: (fid, cid) async => Uint8List(100),
        ),
      );

      final client = HttpClient();

      // Claim 1
      final req1 = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$tokenN/manifest'),
      );
      req1.headers.set('X-LS-Claim', 'claim_1');
      final resp1 = await req1.close();
      expect(resp1.statusCode, equals(HttpStatus.ok));
      await resp1.drain();

      // Claim 2
      final req2 = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$tokenN/manifest'),
      );
      req2.headers.set('X-LS-Claim', 'claim_2');
      final resp2 = await req2.close();
      expect(resp2.statusCode, equals(HttpStatus.ok));
      await resp2.drain();

      // Claim 3 (exceeds N=2) -> 409
      final req3 = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$tokenN/manifest'),
      );
      req3.headers.set('X-LS-Claim', 'claim_3');
      final resp3 = await req3.close();
      expect(resp3.statusCode, equals(HttpStatus.conflict));

      // Anyone mode (maxReceivers = 0)
      final tokenAnyone = 'token_anyone';
      server.registerShare(
        TunnelOriginShare(
          token: tokenAnyone,
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: 500,
          maxReceivers: 0,
          getChunk: (fid, cid) async => Uint8List(100),
        ),
      );

      for (var i = 1; i <= 5; i++) {
        final reqA = await client.getUrl(
          Uri.parse('http://127.0.0.1:$serverPort/t/$tokenAnyone/manifest'),
        );
        reqA.headers.set('X-LS-Claim', 'claim_anyone_$i');
        final respA = await reqA.close();
        expect(respA.statusCode, equals(HttpStatus.ok));
        await respA.drain();
      }

      client.close();
    });

    test('one-time completion: final ack transitions token to COMPLETED (subsequent 401)', () async {
      bool completedCalled = false;
      server.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: 500,
          maxReceivers: 1,
          getChunk: (fid, cid) async => Uint8List(100),
          onCompleted: (claim) {
            completedCalled = true;
          },
        ),
      );

      final client = HttpClient();

      // First bind claim
      final req1 = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/manifest'),
      );
      req1.headers.set('X-LS-Claim', 'claim_final_ack');
      final resp1 = await req1.close();
      expect(resp1.statusCode, equals(HttpStatus.ok));
      await resp1.drain();

      // Send intermediate chunk ack
      final chunkAckPlaintext = jsonEncode({
        'fid': 0,
        'idx': 0,
        'final': false,
      });
      final chunkAckSealed = keys.seal(
        TunnelPurpose.ack,
        utf8.encode(chunkAckPlaintext),
        fileIndex: 0,
        chunkIndex: 0,
      );

      final reqAck = await client.postUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/ack'),
      );
      reqAck.headers.set('X-LS-Claim', 'claim_final_ack');
      reqAck.headers.contentType = ContentType.binary;
      reqAck.add(chunkAckSealed);
      final respAck = await reqAck.close();
      expect(respAck.statusCode, isIn([HttpStatus.ok, HttpStatus.noContent]));

      // Send final ack (fileIndex: 0xFFFFFFFF, chunkIndex: 0)
      final finalAckPlaintext = jsonEncode({'final': true, 'verified': true});
      final finalAckSealed = keys.seal(
        TunnelPurpose.ack,
        utf8.encode(finalAckPlaintext),
        fileIndex: kTunnelManifestFileIndex,
        chunkIndex: 0,
      );

      final reqFinalAck = await client.postUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/ack'),
      );
      reqFinalAck.headers.set('X-LS-Claim', 'claim_final_ack');
      reqFinalAck.headers.contentType = ContentType.binary;
      reqFinalAck.add(finalAckSealed);
      final respFinalAck = await reqFinalAck.close();
      expect(
        respFinalAck.statusCode,
        isIn([HttpStatus.ok, HttpStatus.noContent]),
      );
      expect(completedCalled, isTrue);

      // Now token is completed: any further chunk or manifest request returns 401
      final reqAfter = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$testToken/manifest'),
      );
      reqAfter.headers.set('X-LS-Claim', 'claim_final_ack');
      final respAfter = await reqAfter.close();
      expect(respAfter.statusCode, equals(HttpStatus.unauthorized));

      client.close();
    });

    test('revocation and expiry return 410 Gone', () async {
      final expiredToken = 'expired_token';
      server.registerShare(
        TunnelOriginShare(
          token: expiredToken,
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: 500,
          maxReceivers: 1,
          expiresAt: DateTime.now().subtract(
            const Duration(seconds: 10),
          ), // Expired
          getChunk: (fid, cid) async => Uint8List(100),
        ),
      );

      final client = HttpClient();

      // Expired share -> 410 Gone
      final reqExp = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/$expiredToken/manifest'),
      );
      reqExp.headers.set('X-LS-Claim', 'claim_exp');
      final respExp = await reqExp.close();
      expect(respExp.statusCode, equals(HttpStatus.gone));

      // Active share revoked dynamically
      server.registerShare(
        TunnelOriginShare(
          token: 'revocable_token',
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: 500,
          maxReceivers: 1,
          getChunk: (fid, cid) async => Uint8List(100),
        ),
      );

      // Verify active
      final reqActive = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/revocable_token/manifest'),
      );
      reqActive.headers.set('X-LS-Claim', 'claim_rev');
      final respActive = await reqActive.close();
      expect(respActive.statusCode, equals(HttpStatus.ok));
      await respActive.drain();

      // Revoke share
      server.revokeShare('revocable_token');

      // Now revoked -> 410 Gone
      final reqRev = await client.getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/t/revocable_token/manifest'),
      );
      reqRev.headers.set('X-LS-Claim', 'claim_rev');
      final respRev = await reqRev.close();
      expect(respRev.statusCode, equals(HttpStatus.gone));

      client.close();
    });
  });
}
