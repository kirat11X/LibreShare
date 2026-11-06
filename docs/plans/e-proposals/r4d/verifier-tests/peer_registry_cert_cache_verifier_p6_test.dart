// VERIFIER regression test for finding F1 (R4d): fingerprint borrowing. EXPECTED RED against the
// current patch.diff (documents a real bypass of the per-source cap); it should go green when the
// attribution of a certificate can no longer be steered by a peer entry that merely CLAIMS the
// fingerprint. Names the guard: "source attribution cannot be hijacked".
@Timeout(Duration(minutes: 3))
library;

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

void main() {
  late PeerRegistry reg;
  setUp(() => reg = PeerRegistry(selfDeviceId: 'self', clock: ManualClock()));
  tearDown(() => reg.dispose());

  test('GUARD source-attribution-not-hijackable: a listed peer that claims the victim fingerprint must not let 65 attacker certs evict the victim cert', () {
    final victim = P6bPeer('r4d-v6-victim');
    final flood = [for (var i = 0; i < 70; i++) P6bPeer('r4d-v6-att-$i')];
    // The attacker announces first, under its own deviceId, with the victim's (public) fingerprint.
    reg.seen(
      flood[0].info(fingerprint: victim.fp),
      '10.66.6.6',
      DiscoverySource.multicast,
    );
    // The genuine victim is heard and its certificate learned (engine order).
    reg.seen(victim.info(), '10.1.0.1', DiscoverySource.multicast);
    expect(reg.learnCertificate(victim.certDer), isTrue);
    // The attacker then announces 65 more peers from its single address (own certs).
    for (var i = 1; i < 70; i++) {
      reg.seen(flood[i].info(), '10.66.6.6', DiscoverySource.multicast);
      reg.learnCertificate(flood[i].certDer);
    }
    expect(
      reg.certificateFor(victim.fp),
      isNotNull,
      reason: 'the victim certificate must survive a single-address flood',
    );
  });
}
