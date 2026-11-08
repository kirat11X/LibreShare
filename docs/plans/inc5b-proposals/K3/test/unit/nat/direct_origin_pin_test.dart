import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:libreshare_core/src/connection/direct_connection.dart';
import 'package:libreshare_core/src/nat/direct_origin_server.dart';
import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';

void main() {
  group('DirectOriginServer & DirectConnection Pin Tests', () {
    late DirectOriginServer server;
    late TunnelKeys keys;
    const token = 'test-token-12345';
    const claim = 'test-claim-abcde';

    setUp(() async {
      server = DirectOriginServer();
      await server.start(bindAddress: InternetAddress.loopbackIPv4);

      final rootKey = Uint8List(32)..fillRange(0, 32, 7);
      keys = TunnelKeys.fromRootKey(rootKey);

      final share = TunnelOriginShare(
        token: token,
        keys: keys,
        sealedManifest: Uint8List.fromList([1, 2, 3, 4]),
        totalBytes: 4,
        getChunk: (f, c) async => Uint8List(0),
      );
      server.registerShare(share);
    });

    tearDown(() async {
      await server.stop();
    });

    test('DirectConnection with valid pinned cert succeeds', () async {
      final originBase = Uri.parse('https://127.0.0.1:${server.port}');
      final candidate = Candidate.create(
        kind: CandidateKind.manual,
        host: '127.0.0.1',
        port: server.port,
        peerFingerprint: server.tlsPinHex,
      );

      final conn = DirectConnection(
        candidate: candidate,
        originBase: originBase,
        token: token,
        keys: keys,
        claim: claim,
        expectedPinHex: server.tlsPinHex,
      );

      final client = conn.createPinnedClient();
      final req = await client.getUrl(originBase.resolve('/t/$token/healthz'));
      final resp = await req.close();

      expect(resp.statusCode, HttpStatus.ok);
      client.close();
    });

    test('DirectConnection with wrong pin throws TlsPinMismatchException and refuses connection', () async {
      final originBase = Uri.parse('https://127.0.0.1:${server.port}');
      final candidate = Candidate.create(
        kind: CandidateKind.manual,
        host: '127.0.0.1',
        port: server.port,
        peerFingerprint: server.tlsPinHex,
      );

      // Mutate one hex character of the expected pin
      final corruptedPin = server.tlsPinHex.startsWith('a')
          ? 'b${server.tlsPinHex.substring(1)}'
          : 'a${server.tlsPinHex.substring(1)}';

      final conn = DirectConnection(
        candidate: candidate,
        originBase: originBase,
        token: token,
        keys: keys,
        claim: claim,
        expectedPinHex: corruptedPin,
      );

      final client = conn.createPinnedClient();

      expect(() async {
        final req = await client.getUrl(
          originBase.resolve('/t/$token/healthz'),
        );
        await req.close();
      }, throwsA(isA<TlsPinMismatchException>()));

      client.close();
    });
  });
}
