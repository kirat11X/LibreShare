// Proof for mutant M47: an EMPTY X-LS-Claim header is refused (401), like a missing one.
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:libreshare_core/src/server/tunnel_origin_server.dart';
import 'package:test/test.dart';

void main() {
  test('empty claim -> 401; real claim -> 200', () async {
    final keys = TunnelKeys.fromRootKey(List.filled(32, 1));
    final server = TunnelOriginServer();
    await server.start();
    addTearDown(() => server.stop());
    server.registerShare(
      TunnelOriginShare(
        token: 'token_abc_1234567890',
        keys: keys,
        sealedManifest: keys.seal(TunnelPurpose.manifest, utf8.encode('{}')),
        totalBytes: 1000,
        maxReceivers: 1,
        getChunk: (f, c) async =>
            keys.seal(TunnelPurpose.chunk, [0], fileIndex: f, chunkIndex: c),
      ),
    );
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    Future<int> get(String? claim) async {
      final r = await http.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/t/token_abc_1234567890/manifest',
        ),
      );
      if (claim != null) r.headers.set('X-LS-Claim', claim);
      final resp = await r.close();
      await resp.drain<void>();
      return resp.statusCode;
    }

    expect(await get(null), HttpStatus.unauthorized, reason: 'missing header');
    expect(await get(''), HttpStatus.unauthorized, reason: 'empty header');
    expect(
      await get('claim_1234567890123456'),
      HttpStatus.ok,
      reason: 'positive control',
    );
  });
}
