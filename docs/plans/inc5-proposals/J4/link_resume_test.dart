import 'dart:convert';

import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:libreshare_core/src/connection/tunnel_connection.dart';
import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:libreshare_core/src/tunnel/fake_tunnel_provider.dart';
import 'package:libreshare_core/src/tunnel/tunnel_provider.dart';
import 'package:test/test.dart';

void main() {
  group('Link Resume Integration Tests', () {
    late TunnelOriginServer origin;
    late int originPort;
    late FakeTunnelProvider fakeProvider;
    late TunnelHandle tunnelHandle;
    late TunnelKeys keys;
    final testToken = 'resume_token';
    final testClaim = 'resume_claim_123';

    final chunk0Data = 'CHUNK_ZERO_PAYLOAD_' * 10;
    final chunk1Data = 'CHUNK_ONE_PAYLOAD__' * 10;

    setUp(() async {
      keys = TunnelKeys.fromRootKey(List.filled(32, 23));
      origin = TunnelOriginServer();
      await origin.start();
      originPort = origin.port;

      fakeProvider = FakeTunnelProvider();
      tunnelHandle = await fakeProvider.open(originPort);

      final manifestBytes = keys.seal(
        TunnelPurpose.manifest,
        utf8.encode(
          jsonEncode({
            'sessionId': 'session_resume',
            'files': [
              {
                'id': '0',
                'name': 'multi_chunk.bin',
                'size': chunk0Data.length + chunk1Data.length,
              },
            ],
          }),
        ),
      );

      origin.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: manifestBytes,
          totalBytes: chunk0Data.length + chunk1Data.length,
          maxReceivers: 1,
          getChunk: (fid, cid) async {
            final data = cid == 0 ? chunk0Data : chunk1Data;
            return keys.seal(
              TunnelPurpose.chunk,
              utf8.encode(data),
              fileIndex: fid,
              chunkIndex: cid,
            );
          },
        ),
      );
    });

    tearDown(() async {
      await tunnelHandle.close();
      await origin.stop();
    });

    test('receiver killed after chunk 0 resumes with same key and fetches only missing chunk 1', () async {
      final cand = Candidate.create(
        kind: CandidateKind.tunnel,
        host: tunnelHandle.publicBase.host,
        port: tunnelHandle.publicBase.port,
        peerFingerprint: 'TUNNEL_FP',
      );

      // Phase 1: First receiver instance connects and gets chunk 0
      final conn1 = TunnelConnection(
        candidate: cand,
        originBase: tunnelHandle.publicBase,
        token: testToken,
        keys: keys,
        claim: testClaim,
      );

      final client1 = await conn1.open();
      final chunk0 = await client1.getChunkRaw(0, 0);
      expect(utf8.decode(chunk0), equals(chunk0Data));
      await client1.sendChunkAck(0, 0);

      // Receiver process killed/closed abruptly
      await conn1.close();

      // Phase 2: Receiver resumes (persisted state knows chunk 0 is present, requests only chunk 1)
      final conn2 = TunnelConnection(
        candidate: cand,
        originBase: tunnelHandle.publicBase,
        token: testToken,
        keys: keys,
        claim: testClaim,
      );

      final client2 = await conn2.open();
      // Skip chunk 0, fetch only missing chunk 1
      final chunk1 = await client2.getChunkRaw(0, 1);
      expect(utf8.decode(chunk1), equals(chunk1Data));
      await client2.sendChunkAck(0, 1);

      // Finish with final ack
      final done = await client2.sendFinalAck();
      expect(done, isTrue);

      await conn2.close();
    });
  });
}
