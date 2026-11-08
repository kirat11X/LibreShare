import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:libreshare_core/src/tunnel/fake_tunnel_provider.dart';
import 'package:test/test.dart';

void main() {
  group('NFR-04 End-to-End Ciphertext Verification', () {
    late TunnelOriginServer origin;
    late int originPort;
    late FakeTunnelProvider fakeProvider;
    late TunnelKeys keys;
    final testToken = 'nfr04_token_e2e';
    final testClaim = 'nfr04_claim_123';

    const secretMarkerString =
        'TOP_SECRET_HIGH_ENTROPY_MARKER_FOR_NFR04_VERIFICATION_998877665544332211';
    final secretMarkerBytes = utf8.encode(secretMarkerString);

    setUp(() async {
      keys = TunnelKeys.fromRootKey(List.filled(32, 13));
      origin = TunnelOriginServer();
      await origin.start();
      originPort = origin.port;

      fakeProvider = FakeTunnelProvider();

      final manifestJson = jsonEncode({
        'files': [
          {'id': '0', 'name': 'secret.txt', 'size': secretMarkerBytes.length},
        ],
      });

      origin.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: keys.seal(
            TunnelPurpose.manifest,
            utf8.encode(manifestJson),
          ),
          totalBytes: secretMarkerBytes.length,
          maxReceivers: 1,
          getChunk: (fid, cid) async {
            return keys.seal(
              TunnelPurpose.chunk,
              secretMarkerBytes,
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

    test('capture buffer never contains plaintext marker; wire traffic is 100% ciphertext', () async {
      final handle = await fakeProvider.open(originPort);
      final client = HttpClient();

      // 1. Fetch manifest
      final reqMan = await client.getUrl(
        handle.publicBase.resolve('/t/$testToken/manifest'),
      );
      reqMan.headers.set('X-LS-Claim', testClaim);
      final respMan = await reqMan.close();
      expect(respMan.statusCode, equals(HttpStatus.ok));
      final sealedManifestBytes = await respMan.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );

      // 2. Open manifest
      final openedManifest = keys.open(
        TunnelPurpose.manifest,
        sealedManifestBytes,
      );
      final manifestObj =
          jsonDecode(utf8.decode(openedManifest)) as Map<String, dynamic>;
      expect(manifestObj['files'], isNotEmpty);

      // 3. Fetch chunk 0
      final reqChunk = await client.getUrl(
        handle.publicBase.resolve('/t/$testToken/f/0/c/0'),
      );
      reqChunk.headers.set('X-LS-Claim', testClaim);
      final respChunk = await reqChunk.close();
      expect(respChunk.statusCode, equals(HttpStatus.ok));
      final sealedChunkBytes = await respChunk.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );

      // 4. Open chunk
      final decryptedChunk = keys.open(
        TunnelPurpose.chunk,
        sealedChunkBytes,
        fileIndex: 0,
        chunkIndex: 0,
      );
      expect(utf8.decode(decryptedChunk), equals(secretMarkerString));

      // 5. Send final ack
      final finalAckSealed = keys.seal(
        TunnelPurpose.ack,
        utf8.encode(jsonEncode({'final': true, 'verified': true})),
        fileIndex: kTunnelManifestFileIndex,
        chunkIndex: 0,
      );
      final reqAck = await client.postUrl(
        handle.publicBase.resolve('/t/$testToken/ack'),
      );
      reqAck.headers.set('X-LS-Claim', testClaim);
      reqAck.headers.contentType = ContentType.binary;
      reqAck.add(finalAckSealed);
      final respAck = await reqAck.close();
      expect(respAck.statusCode, isIn([HttpStatus.ok, HttpStatus.noContent]));

      client.close();
      await handle.close();

      // 6. Inspect fake provider capture buffer (NFR-04 verification)
      expect(fakeProvider.captureBuffer, isNotEmpty);

      // Plaintext marker MUST NOT appear anywhere in the captured frames!
      expect(
        fakeProvider.containsPlaintext(secretMarkerBytes),
        isFalse,
        reason: 'NFR-04 Violation: Plaintext marker was captured in cleartext on the wire proxy!',
      );

      // Plaintext string representation also must not appear in any header or URL
      for (final frame in fakeProvider.captureBuffer) {
        expect(frame.uri.toString().contains(secretMarkerString), isFalse);
        for (final headerVal in frame.headers.values) {
          expect(headerVal.contains(secretMarkerString), isFalse);
        }
      }
    });
  });
}
