import 'dart:convert';

import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:libreshare_core/src/connection/connection.dart';
import 'package:libreshare_core/src/connection/tunnel_connection.dart';
import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:libreshare_core/src/tunnel/fake_tunnel_provider.dart';
import 'package:libreshare_core/src/tunnel/tunnel_provider.dart';
import 'package:test/test.dart';

void main() {
  group('OriginPullConnection & TunnelConnection Unit Tests', () {
    late TunnelOriginServer origin;
    late int originPort;
    late FakeTunnelProvider fakeProvider;
    late TunnelHandle tunnelHandle;
    late TunnelKeys keys;
    final testToken = 'pull_token_123';
    final testClaim = 'pull_claim_abc';

    setUp(() async {
      keys = TunnelKeys.fromRootKey(List.filled(32, 42));
      origin = TunnelOriginServer();
      await origin.start();
      originPort = origin.port;

      fakeProvider = FakeTunnelProvider();
      tunnelHandle = await fakeProvider.open(originPort);

      final manifestBytes = keys.seal(
        TunnelPurpose.manifest,
        utf8.encode(
          jsonEncode({
            'sessionId': 'session_pull_1',
            'files': [
              {'id': '0', 'name': 'test.txt', 'size': 500},
            ],
          }),
        ),
      );

      origin.registerShare(
        TunnelOriginShare(
          token: testToken,
          keys: keys,
          sealedManifest: manifestBytes,
          totalBytes: 500,
          maxReceivers: 1,
          getChunk: (fid, cid) async {
            return keys.seal(
              TunnelPurpose.chunk,
              utf8.encode('Chunk data for fid=$fid cid=$cid'),
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

    test('TunnelConnection opens path, yields PeerClient and fetches manifest and chunks', () async {
      final candidate = Candidate.create(
        kind: CandidateKind.tunnel,
        host: tunnelHandle.publicBase.host,
        port: tunnelHandle.publicBase.port,
        peerFingerprint: 'TUNNEL_PEER_FP',
      );

      final connection = TunnelConnection(
        candidate: candidate,
        originBase: tunnelHandle.publicBase,
        token: testToken,
        keys: keys,
        claim: testClaim,
      );

      expect(connection.state, equals(ConnectionState.disconnected));
      final client = await connection.open();
      expect(connection.state, equals(ConnectionState.connected));
      expect(connection.isHealthy, isTrue);

      // 1. Fetch manifest
      final manifestJson = await client.getManifestRaw();
      final manifestMap = jsonDecode(manifestJson) as Map<String, dynamic>;
      expect(manifestMap['sessionId'], equals('session_pull_1'));

      // 2. Fetch chunk 0
      final chunkBytes = await client.getChunkRaw(0, 0);
      expect(utf8.decode(chunkBytes), equals('Chunk data for fid=0 cid=0'));

      // 3. Send chunk ack
      final ackSuccess = await client.sendChunkAck(0, 0);
      expect(ackSuccess, isTrue);

      // 4. Send final ack
      final finalAckSuccess = await client.sendFinalAck();
      expect(finalAckSuccess, isTrue);

      // 5. Subsequent request throws ConnectionException because token is now COMPLETED
      await expectLater(
        client.getManifestRaw(),
        throwsA(isA<ConnectionException>()),
      );

      await connection.close();
      expect(connection.state, equals(ConnectionState.closed));
    });

    test('Connection failure when origin is unreachable throws ConnectionException', () async {
      final deadCandidate = Candidate.create(
        kind: CandidateKind.tunnel,
        host: '127.0.0.1',
        port: 65432, // Closed port
        peerFingerprint: 'DEAD_FP',
      );

      final deadConn = TunnelConnection(
        candidate: deadCandidate,
        originBase: Uri.parse('http://127.0.0.1:65432'),
        token: testToken,
        keys: keys,
        claim: testClaim,
      );

      await expectLater(
        deadConn.open(timeout: const Duration(milliseconds: 500)),
        throwsA(isA<ConnectionException>()),
      );
      expect(deadConn.state, equals(ConnectionState.failed));
    });
  });
}
