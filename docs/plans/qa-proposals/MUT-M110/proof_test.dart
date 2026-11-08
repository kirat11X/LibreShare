// Proof for mutant M110: matchesEid answers false (never throws) for a malformed advKey.
import 'package:libreshare_core/src/ble/beacon_codec.dart';
import 'package:test/test.dart';

void main() {
  test('short advKey or wrong-size EID -> false, no exception', () {
    final now = DateTime.utc(2026, 11, 1, 12);
    expect(
      matchesEid(List<int>.filled(8, 0), List<int>.filled(16, 9), now),
      isFalse,
    );
    expect(
      matchesEid(List<int>.filled(7, 0), List<int>.filled(32, 9), now),
      isFalse,
    );
    final okKey = List<int>.filled(32, 9);
    expect(
      matchesEid(generateEidForTime(okKey, now), okKey, now),
      isTrue,
      reason: 'positive control',
    );
  });
}
