// VERIFIER test (not the tester's file): E5 R4b, written by the verifier agent 2026-11-06.
// Measures the residual limit of the per-source failed-verify cut-off, pins the exact 2-of-5
// share a single forging source can burn, and documents the spoofed-source side effect. (The
// failure-table bound test is in bye_flood_table_verifier_test.dart.)
import 'dart:typed_data';

import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

void main() {
  late P6bPeer receiver;
  late P6bPeer victim;
  late P6bPeer attacker;
  late List<P6bPeer> legit;

  setUpAll(() {
    receiver = P6bPeer('r4b-v-receiver');
    victim = P6bPeer('r4b-v-victim');
    attacker = P6bPeer('r4b-v-attacker');
    legit = [for (var i = 0; i < 8; i++) P6bPeer('r4b-v-legit-$i')];
  });

  late Uint8List wrongSig;
  setUp(() => wrongSig = attacker.key.sign('LSP1-BYE', [1, 2, 3]));

  Future<({InMemoryMulticastBus bus, ManualClock clock, P6bNode rx})>
  fresh() async {
    final bus = InMemoryMulticastBus();
    final clock = ManualClock();
    final rx = P6bNode(bus, receiver, clock: clock);
    await rx.discovery.start();
    await settle();
    return (bus: bus, clock: clock, rx: rx);
  }

  void prep(P6bNode rx, P6bPeer p) {
    rx.listPeer(p);
    expect(rx.registry.learnCertificate(p.certDer), isTrue);
  }

  Uint8List forged(ManualClock c, P6bPeer target, int i) =>
      rawBye(target, ts: tsOf(c.now()) + (i % 1000), sig: wrongSig);

  /// n distinct (non-spoofed) forging sources, each 20 forged byes (the packet limiter's cap
  /// per source and second) naming [victim]; then one genuine bye from another source in the
  /// same second. Returns true when the genuine bye was honoured.
  Future<bool> legitSurvives(int n) async {
    final t = await fresh();
    try {
      prep(t.rx, victim);
      prep(t.rx, legit[0]);
      for (var s = 0; s < n; s++) {
        for (var k = 0; k < 20; k++) {
          t.rx.hear(forged(t.clock, victim, s * 20 + k), from: '10.0.1.$s');
        }
      }
      t.rx.hear(rawBye(legit[0], ts: tsOf(t.clock.now())), from: '10.0.0.81');
      await settle();
      return t.rx.registry.byId(legit[0].id) == null;
    } finally {
      await t.rx.dispose();
    }
  }

  test('RESIDUAL-LIMIT measurement: how many distinct forging sources starve a genuine bye in the same second', () async {
    final results = <int, bool>{};
    for (var n = 1; n <= 6; n++) {
      results[n] = await legitSurvives(n);
    }
    // ignore: avoid_print
    print(
      'R4b residual limit (genuine bye honoured, by number of forging sources): $results',
    );
    // Budget 5/s, at most 2 burnt per source: 1 and 2 sources cannot starve, 3 can.
    expect(results[1], isTrue);
    expect(results[2], isTrue);
    expect(
      results[3],
      isFalse,
      reason: '3 sources x 2 verifications >= 5: documented residual limit',
    );
    expect(results[6], isFalse);
  });

  test('SHARE-EXACTLY-2: one flooding source burns exactly 2 of the 5 verifications, 3 stay available', () async {
    final t = await fresh();
    addTearDown(t.rx.dispose);
    prep(t.rx, victim);
    final peers = legit.take(4).toList();
    for (final p in peers) {
      prep(t.rx, p);
    }
    for (var i = 0; i < 100; i++) {
      t.rx.hear(forged(t.clock, victim, i), from: '10.0.0.66');
    }
    // each genuine bye from its own source
    for (var i = 0; i < peers.length; i++) {
      t.rx.hear(rawBye(peers[i], ts: tsOf(t.clock.now())), from: '10.0.0.8$i');
    }
    await settle();
    expect(peers.where((p) => t.rx.registry.byId(p.id) == null), hasLength(3));
  });

  test('SPOOFED-SOURCE side effect: 2 forged byes per second with the legitimate peer\'s source address mute that address\'s genuine byes (documented, no worse than the pre-patch flood)', () async {
    final t = await fresh();
    addTearDown(t.rx.dispose);
    prep(t.rx, victim);
    prep(t.rx, legit[0]);
    const spoofed = '10.0.0.81'; // the genuine source address of legit[0]
    // 3 seconds in which the spoofer sends 2 forged byes at the start of each second.
    for (var s = 0; s < 3; s++) {
      for (var k = 0; k < 2; k++) {
        t.rx.hear(forged(t.clock, victim, s * 2 + k), from: spoofed);
      }
      t.rx.hear(rawBye(legit[0], ts: tsOf(t.clock.now())), from: spoofed);
      await settle();
      expect(
        t.rx.registry.byId(legit[0].id),
        isNotNull,
        reason: 'second $s: the genuine bye was muted',
      );
      await t.clock.advance(const Duration(milliseconds: 1001));
    }
    // Once the spoofer stops, the address recovers after one second.
    t.rx.hear(rawBye(legit[0], ts: tsOf(t.clock.now())), from: spoofed);
    await settle();
    expect(t.rx.registry.byId(legit[0].id), isNull);
  });

  test('NO-FAILURE-RECORD-FOR-CHEAP-REJECTS: a source whose byes fail only the cheap checks is never cut off from the verifier', () async {
    final t = await fresh();
    addTearDown(t.rx.dispose);
    prep(t.rx, legit[0]);
    for (var i = 0; i < 15; i++) {
      // (15 + 1 <= 20 packets/s per source: stays under the packet limiter)
      // unknown device id: rejected before the verify, must not count as a failure
      t.rx.hear(
        rawBye(
          attacker,
          ts: tsOf(t.clock.now()),
          deviceId: 'ghost-$i',
          sig: wrongSig,
        ),
        from: '10.0.0.77',
      );
    }
    t.rx.hear(rawBye(legit[0], ts: tsOf(t.clock.now())), from: '10.0.0.77');
    await settle();
    expect(t.rx.registry.byId(legit[0].id), isNull);
  });
}
