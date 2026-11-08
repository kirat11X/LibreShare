// Proof for mutant M97: a replayed probe nonce with a fresh, higher seq is rejected.
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  test('duplicate probe nonce rejected', () {
    final now = DateTime.utc(2026, 11, 1, 12);
    final ms = now.millisecondsSinceEpoch;
    final g = ReplayGuard();
    g.validate(ProbeRecord(seq: 1, issuedAt: ms, nonce: 'n1'), channelIdHex: 'c', now: now);
    expect(
      () => g.validate(ProbeRecord(seq: 2, issuedAt: ms, nonce: 'n1'), channelIdHex: 'c', now: now),
      throwsA(isA<ReplayException>().having((e) => e.violation, 'violation', ReplayViolation.duplicateNonce)),
    );
    g.validate(ProbeRecord(seq: 3, issuedAt: ms, nonce: 'n2'), channelIdHex: 'c', now: now);
  });
}
