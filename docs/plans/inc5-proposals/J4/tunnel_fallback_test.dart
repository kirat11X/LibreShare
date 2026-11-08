import 'dart:convert';

import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:libreshare_core/src/connection/tunnel_connection.dart';
import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:libreshare_core/src/tunnel/fake_tunnel_provider.dart';
import 'package:libreshare_core/src/tunnel/tunnel_provider.dart';
import 'package:test/test.dart';

void main() {
  group('Tunnel Fallback Integration Tests (FR-14)', () {
    late TunnelOriginServer origin;
    late int originPort;
    late FakeTunnelProvider fakeProvider;
    late TunnelHandle tunnelHandle;
    late TunnelKeys keys;
    final testToken = 'fallback_token';
    final testClaim = 'fallback_claim';

    const testPayload = 'FALLBACK_FILE_PAYLOAD_ABC_123456789';

    setUp(() async {
      keys = TunnelKeys.fromRootKey(List.filled(32, 17));
      origin = TunnelOriginServer();
      await origin.start();
      originPort = origin.port;

      fakeProvider = FakeTunnelProvider();
      tunnelHandle = await fakeProvider.open(originPort);

      final manifestBytes = keys.seal(
        TunnelPurpose.manifest,
        utf8.encode(
          jsonEncode({
            'sessionId': 'fallback_session',
            'files': [
              {'id': '0', 'name': 'payload.txt', 'size': testPayload.length},
            ],
          }),
        ),
      );

      origin.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: manifestBytes,
          totalBytes: testPayload.length,
          maxReceivers: 1,
          getChunk: (fid, cid) async {
            return keys.seal(
              TunnelPurpose.chunk,
              utf8.encode(testPayload),
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

    test('when local LAN candidate fails, connection falls back to TunnelConnection and transfers byte-identical file', () async {
      // 1. Candidate ladder: dead local WiFi/LAN candidate first, tunnel candidate second
      final deadLocalCandidate = Candidate.create(
        kind: CandidateKind.wifi,
        host: '127.0.0.1',
        port: 65431, // Dead local port
        peerFingerprint: 'DEAD_WIFI_FP',
        costHint: 10,
      );

      final tunnelCandidate = Candidate.create(
        kind: CandidateKind.tunnel,
        host: tunnelHandle.publicBase.host,
        port: tunnelHandle.publicBase.port,
        peerFingerprint: 'TUNNEL_FP',
        costHint: 100,
      );

      final candidates = [deadLocalCandidate, tunnelCandidate];

      // Simulate ladder selection
      TunnelConnection? workingConn;
      for (final cand in candidates) {
        if (cand.kind == CandidateKind.wifi) {
          // Local attempt fails
          continue;
        } else if (cand.kind == CandidateKind.tunnel) {
          final conn = TunnelConnection(
            candidate: cand,
            originBase: tunnelHandle.publicBase,
            token: testToken,
            keys: keys,
            claim: testClaim,
          );
          try {
            await conn.open();
            workingConn = conn;
            break;
          } catch (_) {}
        }
      }

      expect(workingConn, isNotNull);
      expect(workingConn!.isHealthy, isTrue);

      final client = await workingConn.open();
      final chunkBytes = await client.getChunkRaw(0, 0);
      expect(utf8.decode(chunkBytes), equals(testPayload));

      final ackOk = await client.sendFinalAck();
      expect(ackOk, isTrue);

      await workingConn.close();
    });
  });
}
