// E5 / R4e VERIFIER tests (not the tester's file): extra pins around LSP-1 4.3 secure-profile order
// steps 3-5, written to kill the survivors of the mutation table in verifier-report.md.
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';

const _json = {'content-type': 'application/json'};

void main() {
  late P3Rig rig;

  setUp(() async => rig = await P3Rig.start());
  tearDown(() => rig.stop());

  final alice = p3Alice;
  final tooMany = p3SessionBody(alice, files: kMaxFilesPerSession + 1);

  Future<P3Res> post(List<int> body, {P3Peer? signAs, String? authHeader}) =>
      rig.request(
        'POST',
        '/sessions',
        body: body,
        headers: _json,
        signAs: signAs,
        authHeader: authHeader,
      );

  test('VERIFIER bytes-before-auth: > 4 MiB without proof is 413 TOO_LARGE (step 3), nothing created', () async {
    final r = await post(
      p3SessionBody(alice, length: kMaxSessionJsonBytes + 1),
    );
    expect(r.status, 413, reason: r.text);
    expect(r.error['code'], 'TOO_LARGE');
    expect(rig.handler.count('createAuthenticatedSession'), 0);
  });

  test('VERIFIER invalid-json-unauth: invalid JSON without proof is 401, not 400 (step 4 before step 5)', () async {
    final r = await post([0x7b, 0x6e, 0x6f, 0x70, 0x65]);
    expect(r.status, 401, reason: r.text);
    expect(r.error['code'], 'AUTH_INVALID');
    expect(rig.handler.count('createAuthenticatedSession'), 0);
  });

  test('VERIFIER invalid-json-signed: invalid JSON with a valid proof is 400 (step 5)', () async {
    final r = await post([0x7b, 0x6e, 0x6f, 0x70, 0x65], signAs: alice);
    expect(r.status, 400, reason: r.text);
    expect(r.error['code'], 'BAD_REQUEST');
  });

  test('VERIFIER proof-for-other-server: oversize manifest with a proof naming another server is 401', () async {
    final forged = rig.proof(
      alice,
      'POST',
      '/sessions',
      tooMany,
      serverFp: 'AB' * 32,
    );
    final r = await post(tooMany, authHeader: forged);
    expect(r.status, 401, reason: r.text);
    expect(rig.handler.count('createAuthenticatedSession'), 0);
  });

  test('VERIFIER replay: the proof of a 413 manifest is spent; replaying it is 401', () async {
    final h = rig.proof(alice, 'POST', '/sessions', tooMany);
    final first = await post(tooMany, authHeader: h);
    expect(first.status, 413, reason: first.text);
    final again = await post(tooMany, authHeader: h);
    expect(again.status, 401, reason: again.text);
  });

  test('VERIFIER oversize-bad-shape-signed: signed manifest with 10,001 files is 413 even when later checks would fail', () async {
    // 10,001 identical-looking files are valid; the count (step 5) precedes consistency (step 7).
    final r = await post(tooMany, signAs: alice);
    expect(r.status, 413, reason: r.text);
  });
}
