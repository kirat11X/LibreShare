// VERIFIER test (round 2, no dart:mirrors): E5 R4b, verifier agent 2026-11-06. The per-source
// failure table stays bounded (cap 256); uses MulticastDiscovery.byeFailureSourceCount.
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

void main() {
  test('FAILURE-TABLE-BOUNDED (white box): 5 verified failures per second from ever-new sources for 80 s keep the table <= 256 entries', () async {
    final receiver = P6bPeer('r4b-v-receiver');
    final victim = P6bPeer('r4b-v-victim');
    final attacker = P6bPeer('r4b-v-attacker');
    final wrongSig = attacker.key.sign('LSP1-BYE', [1, 2, 3]);
    final bus = InMemoryMulticastBus();
    final clock = ManualClock();
    final rx = P6bNode(bus, receiver, clock: clock);
    await rx.discovery.start();
    await settle();
    addTearDown(rx.dispose);
    rx.listPeer(victim);
    expect(rx.registry.learnCertificate(victim.certDer), isTrue);
    var maxLen = 0;
    var src = 0;
    for (var sec = 0; sec < 80; sec++) {
      for (var k = 0; k < 5; k++, src++) {
        rx.hear(
          rawBye(victim, ts: tsOf(clock.now()) + (src % 1000), sig: wrongSig),
          from: '10.${2 + src ~/ 60000}.${(src ~/ 250) % 250}.${src % 250}',
        );
      }
      await clock.advance(const Duration(milliseconds: 1001));
      final len = rx.discovery.byeFailureSourceCount;
      if (len > maxLen) maxLen = len;
    }
    // ignore: avoid_print
    print('R4b failure table: sources seen=$src, max table length=$maxLen');
    expect(maxLen, lessThanOrEqualTo(256));
  });
}
