// E5 / R4b: forged `bye` datagrams must not starve legitimate ones (inc3.md section 12 "Known
// limits carried forward": "forged bye datagrams can consume the 5/s verify budget").
//
// Where the problem sits: `MulticastDiscovery._handleBye` (lib/src/discovery/multicast_discovery.dart)
// runs the cheap checks (window, listed with exactly this fingerprint, certificate held, replay
// memory) and then spends one of 5 signature verifications per second, GLOBAL across sources.
// A forger needs only public data (device id and fingerprint are in every announce) and a
// well-formed signature field to pass the cheap checks, so a flood of forged byes naming a listed
// peer burns the whole budget every second and a genuine bye from anyone else is dropped.
//
// What the tests demand (no API change, the harness is the existing P6bNode / in-memory bus):
//  * a source whose byes keep FAILING verification must be cut off from the verifier after a few
//    failures (per-source failure accounting before the verify), so that it cannot hold more
//    than a small share of the 5/s budget. A per-source cap on all byes is NOT acceptable: the
//    existing goodbye_test 'verification_budget_5_per_second' sends 7 valid byes from ONE source
//    and expects 5 verified, and 'the budget is global, not per source' stays true.
//  * the cheap pre-checks (unknown id, wrong fingerprint, no certificate) stay in front of the
//    budget: 1000 forgeries of those kinds do not touch the 5/s budget at all. There is no
//    verify counter seam; the budget itself is the oracle (all 5 slots must still be available).
//  * the flood source is not banned forever.
//
// Every test names the guard it targets ("GUARD ...") so a verifier can remove that guard and
// expect exactly that test to go red.
import 'dart:typed_data';

import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _forger = '10.0.0.66';

void main() {
  late P6bPeer receiver;
  late P6bPeer victim;
  late P6bPeer attacker;
  late List<P6bPeer> legit;

  late InMemoryMulticastBus bus;
  late ManualClock clock;
  late P6bNode rx;

  setUpAll(() {
    receiver = P6bPeer('r4b-receiver');
    victim = P6bPeer('r4b-victim');
    attacker = P6bPeer('r4b-attacker');
    legit = [for (var i = 0; i < 8; i++) P6bPeer('r4b-legit-$i')];
  });

  setUp(() async {
    bus = InMemoryMulticastBus();
    clock = ManualClock();
    rx = P6bNode(bus, receiver, clock: clock);
    await rx.discovery.start();
    await settle();
  });

  tearDown(() => rx.dispose());

  int now() => tsOf(clock.now());
  bool listed(P6bPeer p) => rx.registry.byId(p.id) != null;

  /// Lists [p] and gives the registry its certificate (as a handshake would).
  void prep(P6bPeer p, {bool cert = true}) {
    rx.listPeer(p);
    if (cert) expect(rx.registry.learnCertificate(p.certDer), isTrue);
  }

  // A well-formed signature that is wrong for every message it is attached to.
  late final Uint8List wrongSig = attacker.key.sign('LSP1-BYE', [1, 2, 3]);

  /// Forged bye naming [target] (public id + fingerprint, fresh ts, bad signature).
  Uint8List forged(P6bPeer target, int i) =>
      rawBye(target, ts: now() + (i % 1000), sig: wrongSig);

  /// 10 datagrams of the 1000/s flood, then 10 ms of simulated time.
  Future<void> floodStep(int step) async {
    for (var k = 0; k < 10; k++) {
      rx.hear(forged(victim, step * 10 + k), from: _forger);
    }
    await clock.advance(const Duration(milliseconds: 10));
  }

  /// Sends [p]'s genuine bye from [source] while the flood continues; true when it is processed
  /// (the peer disappears) within 1 s of simulated time.
  Future<bool> genuineByeWithin1s(
    P6bPeer p,
    String source,
    int firstStep,
  ) async {
    rx.hear(rawBye(p, ts: now()), from: source);
    for (var s = 0; s < 100; s++) {
      if (!listed(p)) return true;
      await floodStep(firstStep + s);
    }
    return !listed(p);
  }

  test('GUARD per-source-failed-verify-limit: 1000 forged byes/s for 3 s from one source do not stop genuine byes from other sources', () async {
    prep(victim);
    for (final p in legit.take(3)) {
      prep(p);
    }
    var step = 0;
    // Flood at 1000/s; genuine byes from three different sources at 0.5 s, 1.5 s and 2.5 s.
    for (; step < 50; step++) {
      await floodStep(step);
    }
    expect(
      await genuineByeWithin1s(legit[0], '10.0.0.81', step),
      isTrue,
      reason: 'genuine bye at 0.5 s of the flood',
    );
    step += 100;
    for (; step < 150; step++) {
      await floodStep(step);
    }
    expect(
      await genuineByeWithin1s(legit[1], '10.0.0.82', step),
      isTrue,
      reason: 'genuine bye at 1.5 s of the flood',
    );
    step += 100;
    for (; step < 250; step++) {
      await floodStep(step);
    }
    expect(
      await genuineByeWithin1s(legit[2], '10.0.0.83', step),
      isTrue,
      reason: 'genuine bye at 2.5 s of the flood',
    );
    expect(listed(victim), isTrue, reason: 'a forged bye must never remove');
  });

  test('GUARD per-source-failed-verify-limit-same-second: the genuine bye arrives in the very second the flood starts', () async {
    prep(victim);
    prep(legit[0]);
    // 200 forged byes arrive first (all in one simulated second, as a burst), then the genuine one.
    for (var i = 0; i < 200; i++) {
      rx.hear(forged(victim, i), from: _forger);
    }
    rx.hear(rawBye(legit[0], ts: now()), from: '10.0.0.81');
    await settle();
    expect(listed(legit[0]), isFalse, reason: 'verified within the second');
    expect(listed(victim), isTrue);
  });

  test('GUARD pre-verify-checks-stay-cheap: 1000 forgeries of unknown id / wrong fingerprint / no certificate leave all 5 verifications of the second free', () async {
    prep(victim);
    prep(
      legit[7],
      cert: false,
    ); // listed, right fingerprint, but no certificate held
    final five = legit.take(5).toList();
    five.forEach(prep);
    // 1000 datagrams from 1000 different sources (so no per-source rule can be what saves
    // the budget): only the three cheap rejections below are exercised.
    for (var i = 0; i < 1000; i++) {
      final src = '10.${1 + i ~/ 250}.${i % 250}.9';
      final ts = now() + (i % 1000);
      final Uint8List d;
      switch (i % 3) {
        case 0: // not listed at all
          d = rawBye(attacker, ts: ts, deviceId: 'ghost-$i', sig: wrongSig);
        case 1: // listed id, fingerprint of somebody else
          d = rawBye(victim, ts: ts, fingerprint: attacker.fp, sig: wrongSig);
        default: // listed, right fingerprint, no certificate held
          d = rawBye(legit[7], ts: ts, sig: wrongSig);
      }
      rx.hear(d, from: src);
    }
    await settle();
    for (final p in five) {
      rx.hear(rawBye(p, ts: now()), from: '10.0.0.77');
    }
    await settle();
    expect(
      five.where(listed),
      isEmpty,
      reason: 'all 5 verifications must still be available',
    );
    expect(listed(victim), isTrue);
    expect(listed(legit[7]), isTrue);
  });

  test('GUARD global-budget-unchanged: genuine byes from one source are still limited to 5 per second (existing rule stays)', () async {
    final peers = [for (var i = 0; i < 7; i++) legit[i]];
    peers.forEach(prep);
    for (final p in peers) {
      rx.hear(rawBye(p, ts: now()), from: '10.0.0.77');
    }
    await settle();
    expect(peers.where((p) => !listed(p)), hasLength(5));
  });

  test('GUARD flood-source-not-banned-forever: after the flood stops and 10 s pass the same source is served again', () async {
    prep(victim);
    prep(legit[0]);
    for (var step = 0; step < 200; step++) {
      await floodStep(step);
    }
    await clock.advance(const Duration(seconds: 10));
    rx.hear(rawBye(legit[0], ts: now()), from: _forger);
    await settle();
    expect(listed(legit[0]), isFalse);
  });

  test('GUARD forged-bye-never-honoured: a flood naming every listed peer removes nobody', () async {
    final all = [victim, ...legit.take(4)];
    all.forEach(prep);
    for (var step = 0; step < 100; step++) {
      for (var k = 0; k < 10; k++) {
        final p = all[(step * 10 + k) % all.length];
        rx.hear(forged(p, step * 10 + k), from: _forger);
      }
      await clock.advance(const Duration(milliseconds: 10));
    }
    expect([for (final p in all) listed(p)], everyElement(isTrue));
  });
}
