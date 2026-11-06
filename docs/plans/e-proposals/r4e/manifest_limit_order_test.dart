// E5 / R4e: regression pin for the order of checks on `POST /sessions` in the secure profile
// (LSP-1 4.3 "Secure-profile order", steps 3 to 5; decision Q3 of docs/plans/questions.md,
// option 3). The 10,000-file limit is decided AFTER the proof verified:
//   * a manifest with more than kMaxFilesPerSession files and no valid proof -> 401 AUTH_INVALID
//     (nothing of the unauthenticated body is interpreted);
//   * the same body, correctly signed -> 413 TOO_LARGE, no session is created;
//   * exactly kMaxFilesPerSession files, correctly signed -> accepted (boundary twin).
// No lib change is needed or wanted: this test is green on the unchanged tree and goes red if
// somebody moves the file count before the proof (or drops the limit).
//
// Every test names the guard it targets ("GUARD ...") so a verifier can remove that guard and
// expect exactly that test to go red.
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
  final atLimit = p3SessionBody(alice, files: kMaxFilesPerSession);

  Future<P3Res> post(List<int> body, {P3Peer? signAs, String? authHeader}) =>
      rig.request(
        'POST',
        '/sessions',
        body: body,
        headers: _json,
        signAs: signAs,
        authHeader: authHeader,
      );

  test(
    'premise: the bodies are big enough to matter but below the 4 MiB body cap',
    () {
      expect(kMaxFilesPerSession, 10000);
      expect(tooMany.length, lessThan(kMaxSessionJsonBytes));
      expect(tooMany.length, greaterThan(kMaxJsonBytes));
    },
  );

  test('GUARD file-limit-after-auth-no-proof: more than 10,000 files without X-LS-Auth is 401 AUTH_INVALID, not 413', () async {
    final r = await post(tooMany);
    expect(r.status, 401, reason: r.text);
    expect(r.error['code'], 'AUTH_INVALID');
    expect(rig.handler.count('createAuthenticatedSession'), 0);
  });

  test('GUARD file-limit-after-auth-bad-proof: a proof signed for another body is 401, not 413', () async {
    final forged = rig.proof(alice, 'POST', '/sessions', atLimit);
    final r = await post(tooMany, authHeader: forged);
    expect(r.status, 401, reason: r.text);
    expect(r.error['code'], 'AUTH_INVALID');
    expect(rig.handler.count('createAuthenticatedSession'), 0);
  });

  test('GUARD file-limit-after-auth-garbage-proof: a malformed X-LS-Auth is 401, not 413', () async {
    final r = await post(tooMany, authHeader: 'v1.not.a.proof');
    expect(r.status, 401, reason: r.text);
    expect(r.error['code'], 'AUTH_INVALID');
  });

  test('GUARD file-limit-enforced: the same manifest correctly signed is 413 TOO_LARGE and creates no session', () async {
    final r = await post(tooMany, signAs: alice);
    expect(r.status, 413, reason: r.text);
    expect(r.error['code'], 'TOO_LARGE');
    expect(r.error['retryable'], isFalse);
    expect(rig.handler.count('createAuthenticatedSession'), 0);
  });

  test('GUARD file-limit-boundary: exactly 10,000 files correctly signed is accepted', () async {
    final r = await post(atLimit, signAs: alice);
    expect(r.status, 202, reason: r.text);
    expect(rig.handler.count('createAuthenticatedSession'), 1);
  });

  test('GUARD file-limit-after-auth-replay-not-spent: the 401 of an unsigned oversize manifest does not poison a later signed request', () async {
    expect((await post(tooMany)).status, 401);
    final r = await post(atLimit, signAs: alice);
    expect(r.status, 202, reason: r.text);
  });
}
