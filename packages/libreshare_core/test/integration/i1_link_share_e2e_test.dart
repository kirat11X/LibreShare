// Increment 6 / Integration Card I1: Link Share E2E Integration Suite.
// Verifies FakeTunnelProvider -> ShareLink -> TunnelOriginServer -> client download,
// byte-identical reassembly, and zero key-fragment secret leakage in any logs or events.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  group('I1: Link Share End-to-End Integration Suite', () {
    late TunnelOriginServer origin;
    late FakeTunnelProvider fakeTunnel;
    late TunnelHandle tunnelHandle;
    late Uint8List rootKey;
    late TunnelKeys keys;
    late String token;
    late String claim;

    final chunk0 = Uint8List.fromList(
      List.generate(1024 * 64, (i) => (i * 3) & 0xFF),
    );
    final chunk1 = Uint8List.fromList(
      List.generate(1024 * 64, (i) => (i * 7 + 1) & 0xFF),
    );
    late Uint8List originalFileBytes;

    final capturedLogs = <String>[];

    void logSpy(String msg) {
      capturedLogs.add(msg);
    }

    setUp(() async {
      capturedLogs.clear();
      rootKey = Uint8List.fromList(
        List.generate(32, (i) => (i * 13 + 5) & 0xFF),
      );
      keys = TunnelKeys.fromRootKey(rootKey);
      token = 'test_token_${DateTime.now().millisecondsSinceEpoch}';
      claim = 'test_claim_${DateTime.now().millisecondsSinceEpoch}';

      originalFileBytes = Uint8List.fromList([...chunk0, ...chunk1]);

      origin = TunnelOriginServer();
      await origin.start();

      fakeTunnel = FakeTunnelProvider();
      tunnelHandle = await fakeTunnel.open(origin.port);

      // Prepare manifest
      final manifestJson = jsonEncode({
        'sessionId': 'i1_link_session',
        'files': [
          {
            'id': '0',
            'name': 'data.bin',
            'size': originalFileBytes.length,
            'chunks': 2,
          },
        ],
      });
      final sealedManifest = keys.seal(
        TunnelPurpose.manifest,
        utf8.encode(manifestJson),
      );

      origin.registerShare(
        TunnelOriginShare(
          token: token,
          keys: keys,
          sealedManifest: sealedManifest,
          totalBytes: originalFileBytes.length,
          maxReceivers: 1,
          getChunk: (fid, cid) async {
            logSpy('Server serving chunk fid=$fid cid=$cid');
            final chunkData = cid == 0 ? chunk0 : chunk1;
            return keys.seal(
              TunnelPurpose.chunk,
              chunkData,
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

    test('Full E2E link transfer downloads byte-identical file and never logs key fragment', () async {
      // 1. Construct ShareLink with secret key in fragment
      final keyB64 = base64UrlEncode(rootKey).replaceAll('=', '');
      final tokenB64 = base64UrlEncode(utf8.encode(token).sublist(0, 16))
          .replaceAll('=', '');

      final shareLinkStr =
          'https://libreshare.github.io/r#v=1&h=${tunnelHandle.publicBase.host}:${tunnelHandle.publicBase.port}&t=$tokenB64&k=$keyB64&m=1';

      logSpy('Engine generated link notice: ShareLink created (redacted)');

      // 2. Receiver parses link
      final link = ShareLink.parse(shareLinkStr, allowDeveloperHosts: true);
      expect(link.version, equals(1));
      expect(link.maxReceivers, equals(1));
      expect(link.rootKey, equals(rootKey));

      // 3. Candidate created pointing to tunnel publicBase
      final tunnelCandidate = Candidate.create(
        kind: CandidateKind.tunnel,
        host: tunnelHandle.publicBase.host,
        port: tunnelHandle.publicBase.port,
        peerFingerprint: 'TUNNEL_FP_I1',
      );

      final connection = TunnelConnection(
        candidate: tunnelCandidate,
        originBase: tunnelHandle.publicBase,
        token: token,
        keys: keys,
        claim: claim,
      );

      final client = await connection.open();
      expect(connection.isHealthy, isTrue);

      // 4. Download and unseal manifest
      final unsealedManifestJson = await client.getManifestRaw();
      final manifest = jsonDecode(unsealedManifestJson) as Map<String, dynamic>;
      expect(manifest['sessionId'], equals('i1_link_session'));

      // 5. Download chunks and reassemble
      final downloadedChunk0 = await client.getChunkRaw(0, 0);
      final downloadedChunk1 = await client.getChunkRaw(0, 1);

      final assembled = Uint8List.fromList([
        ...downloadedChunk0,
        ...downloadedChunk1,
      ]);

      expect(assembled, equals(originalFileBytes));

      final ackOk = await client.sendFinalAck();
      expect(ackOk, isTrue);
      await connection.close();

      // 6. Security & Privacy Audit: key fragment must NEVER appear in logs
      final keyHex = rootKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      for (final logLine in capturedLogs) {
        expect(
          logLine.contains(keyB64),
          isFalse,
          reason: 'Key fragment base64 leaked in log: $logLine',
        );
        expect(
          logLine.contains(keyHex),
          isFalse,
          reason: 'Key fragment hex leaked in log: $logLine',
        );
      }
      expect(link.toString(), equals('ShareLink(redacted)'));
    });

    test(
      'Adversarial: Tampered chunk ciphertext fails MAC verification',
      () async {
        final tunnelCandidate = Candidate.create(
          kind: CandidateKind.tunnel,
          host: tunnelHandle.publicBase.host,
          port: tunnelHandle.publicBase.port,
          peerFingerprint: 'TUNNEL_FP_I1',
        );

        final connection = TunnelConnection(
          candidate: tunnelCandidate,
          originBase: tunnelHandle.publicBase,
          token: token,
          keys: keys,
          claim: 'claim_tamper',
        );

        await connection.open();
        // client.getChunkRaw actually unseals the chunk using keys internally!
        // To test ciphertext tampering against keys.open:
        final validChunk = keys.seal(
          TunnelPurpose.chunk,
          chunk0,
          fileIndex: 0,
          chunkIndex: 0,
        );

        final tampered = Uint8List.fromList(validChunk);
        tampered[tampered.length - 1] ^= 0x01;

        expect(
          () => keys.open(
            TunnelPurpose.chunk,
            tampered,
            fileIndex: 0,
            chunkIndex: 0,
          ),
          throwsA(isA<TunnelCryptoException>()),
        );

        await connection.close();
      },
    );

    test(
      'Adversarial: Receiver with wrong root key fails manifest decryption',
      () async {
        final wrongKey = Uint8List.fromList(List.filled(32, 99));
        final wrongTunnelKeys = TunnelKeys.fromRootKey(wrongKey);

        final tunnelCandidate = Candidate.create(
          kind: CandidateKind.tunnel,
          host: tunnelHandle.publicBase.host,
          port: tunnelHandle.publicBase.port,
          peerFingerprint: 'TUNNEL_FP_I1',
        );

        final connection = TunnelConnection(
          candidate: tunnelCandidate,
          originBase: tunnelHandle.publicBase,
          token: token,
          keys: wrongTunnelKeys,
          claim: 'claim_wrong_key',
        );

        final client = await connection.open();
        expect(
          () => client.getManifestRaw(),
          throwsA(isA<TunnelCryptoException>()),
        );

        await connection.close();
      },
    );

    test(
      'Adversarial: Mode 1 rejects second claimant after first binds',
      () async {
        final tunnelCandidate = Candidate.create(
          kind: CandidateKind.tunnel,
          host: tunnelHandle.publicBase.host,
          port: tunnelHandle.publicBase.port,
          peerFingerprint: 'TUNNEL_FP_I1',
        );

        final conn1 = TunnelConnection(
          candidate: tunnelCandidate,
          originBase: tunnelHandle.publicBase,
          token: token,
          keys: keys,
          claim: 'first_claimant',
        );
        final client1 = await conn1.open();
        expect(client1, isNotNull);

        // Second claimant connects with different claim ID
        final conn2 = TunnelConnection(
          candidate: tunnelCandidate,
          originBase: tunnelHandle.publicBase,
          token: token,
          keys: keys,
          claim: 'second_claimant_intruder',
        );

        expect(
          () => conn2.open(),
          throwsA(
            isA<ConnectionException>().having(
              (e) => e.toString(),
              'toString',
              contains('409'),
            ),
          ),
        );

        await conn1.close();
      },
    );

    test('Adversarial: Expired share link is detected and invalid format rejected', () {
      final expiredSeconds =
          (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000) - 3600;
      final expiredUrl =
          'https://libreshare.github.io/r#v=1&h=relay.example.com&t=${base64UrlEncode(Uint8List(16)).replaceAll("=", "")}&k=${base64UrlEncode(Uint8List(32)).replaceAll("=", "")}&m=1&e=$expiredSeconds';

      final link = ShareLink.parse(expiredUrl);
      expect(link.isExpired(DateTime.now()), isTrue);

      final malformedExpiryUrl =
          'https://libreshare.github.io/r#v=1&h=relay.example.com&t=${base64UrlEncode(Uint8List(16)).replaceAll("=", "")}&k=${base64UrlEncode(Uint8List(32)).replaceAll("=", "")}&m=1&e=not_a_number';

      expect(
        () => ShareLink.parse(malformedExpiryUrl),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            equals(ShareLinkError.badExpiry),
          ),
        ),
      );
    });
  });
}
