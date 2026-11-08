import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:libreshare_core/src/tunnel/fake_tunnel_provider.dart';
import 'package:test/test.dart';

void main() {
  group('Hostile Provider & Wire Tampering Detection Tests', () {
    late TunnelOriginServer origin;
    late int originPort;
    final testToken = 'hostile_test_token';
    final testClaim = 'hostile_claim_123';
    late TunnelKeys keys;

    setUp(() async {
      keys = TunnelKeys.fromRootKey(List.filled(32, 9));
      origin = TunnelOriginServer();
      await origin.start();
      originPort = origin.port;

      final manifestBytes = keys.seal(
        TunnelPurpose.manifest,
        utf8.encode(
          jsonEncode({
            'files': [
              {'id': '0', 'name': 'data.bin', 'size': 200},
            ],
          }),
        ),
      );

      origin.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: manifestBytes,
          totalBytes: 200,
          maxReceivers: 1,
          getChunk: (fid, cid) async {
            final padding = 'A' * 50;
            final plain = utf8.encode(
              'Chunk data for fid=$fid cid=$cid: $padding',
            );
            return keys.seal(
              TunnelPurpose.chunk,
              plain,
              fileIndex: fid,
              chunkIndex: cid,
            );
          },
        ),
      );
    });

    tearDown(() async {
      await origin.stop();
    });

    test(
      'bit-flipped ciphertext on wire is rejected by AEAD authentication',
      () async {
        final fake = FakeTunnelProvider(hostileBitFlipChunkIndex: 0);
        final handle = await fake.open(originPort);

        final client = HttpClient();
        final req = await client.getUrl(
          handle.publicBase.resolve('/t/$testToken/f/0/c/0'),
        );
        req.headers.set('X-LS-Claim', testClaim);
        final resp = await req.close();
        expect(resp.statusCode, equals(HttpStatus.ok));

        final tamperedBytes = await resp.fold<List<int>>(
          [],
          (p, e) => p..addAll(e),
        );
        client.close();
        await handle.close();

        // Attempting to decrypt tampered bytes must throw authenticationFailed
        expect(
          () => keys.open(
            TunnelPurpose.chunk,
            tamperedBytes,
            fileIndex: 0,
            chunkIndex: 0,
          ),
          throwsA(
            isA<TunnelCryptoException>().having(
              (e) => e.error,
              'error',
              equals(TunnelCryptoError.authenticationFailed),
            ),
          ),
        );
      },
    );

    test('swapped chunks on wire are rejected by AAD verification', () async {
      final fake = FakeTunnelProvider(
        hostileSwapChunks: true, // swaps c/0 and c/1
      );
      final handle = await fake.open(originPort);

      final client = HttpClient();
      final req = await client.getUrl(
        handle.publicBase.resolve('/t/$testToken/f/0/c/0'),
      );
      req.headers.set('X-LS-Claim', testClaim);
      final resp = await req.close();
      expect(resp.statusCode, equals(HttpStatus.ok));

      final swappedBytes = await resp.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );
      client.close();
      await handle.close();

      // The receiver requested chunkIndex 0, but received chunk 1.
      // Trying to open it with chunkIndex 0 must fail AAD check!
      expect(
        () => keys.open(
          TunnelPurpose.chunk,
          swappedBytes,
          fileIndex: 0,
          chunkIndex: 0,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            equals(TunnelCryptoError.authenticationFailed),
          ),
        ),
      );
    });

    test('dropped chunk on wire is detected as network failure', () async {
      final fake = FakeTunnelProvider(hostileDropChunkIndex: 0);
      final handle = await fake.open(originPort);

      final client = HttpClient();
      final req = await client.getUrl(
        handle.publicBase.resolve('/t/$testToken/f/0/c/0'),
      );
      req.headers.set('X-LS-Claim', testClaim);

      bool droppedOrFailed = false;
      try {
        final resp = await req.close();
        if (resp.statusCode >= 500) {
          droppedOrFailed = true;
        } else {
          await resp.drain();
        }
      } catch (_) {
        droppedOrFailed = true;
      }

      client.close();
      await handle.close();
      expect(droppedOrFailed, isTrue);
    });

    test(
      'replayed ack under wrong index or purpose fails authentication',
      () async {
        // Seal an ack for chunk 0
        final validAck0 = keys.seal(
          TunnelPurpose.ack,
          utf8.encode(jsonEncode({'fid': 0, 'idx': 0})),
          fileIndex: 0,
          chunkIndex: 0,
        );

        // Verifying ack as chunk index 1 must fail
        expect(
          () => keys.open(
            TunnelPurpose.ack,
            validAck0,
            fileIndex: 0,
            chunkIndex: 1,
          ),
          throwsA(
            isA<TunnelCryptoException>().having(
              (e) => e.error,
              'error',
              equals(TunnelCryptoError.authenticationFailed),
            ),
          ),
        );

        // Verifying ack as chunk purpose must fail
        expect(
          () => keys.open(
            TunnelPurpose.chunk,
            validAck0,
            fileIndex: 0,
            chunkIndex: 0,
          ),
          throwsA(
            isA<TunnelCryptoException>().having(
              (e) => e.error,
              'error',
              equals(TunnelCryptoError.authenticationFailed),
            ),
          ),
        );
      },
    );
  });
}
