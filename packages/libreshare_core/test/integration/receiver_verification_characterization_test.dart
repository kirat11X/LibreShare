// CHARACTERIZATION (speed wave S2): behaviour 6 of docs/plans/inc4-speed-seams.md
// as it holds TODAY with the default pure-Dart provider. Uses no S2 symbol and
// must keep passing unchanged after the native SHA-256 change.
import 'package:test/test.dart';

import '../helpers/s2_verification_scenarios.dart';

void main() {
  group('receiver verification (default provider)', () {
    defineReceiverVerificationTests();
  });

  test(
    'engine -> engine 24 MiB (6 chunks) arrives byte-identical',
    engineRoundTrip24MiB,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
