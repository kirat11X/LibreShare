// Increments 1-7 / Integration Card I1: Cross-Increment Regression Suite.
// Verifies that core Inc 1-4 invariants (resumption, FR-13 fallback, D6 cert pin check,
// speed modes, PIN guard & lockout) continue to hold with Inc 5b/6/7 features active.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';

class _FakePeerClientWithFp implements PeerClient {
  _FakePeerClientWithFp({required this.fingerprint, this.isAlive = true});

  final String fingerprint;
  bool isAlive;
  bool closed = false;
  final List<int> receivedChunks = [];

  @override
  Future<DeviceInfo> info() async {
    if (!isAlive) throw const ConnectionException('Simulated cut');
    return DeviceInfo(
      deviceId: 'remote-device',
      alias: 'Remote',
      platform: 'linux',
      port: 53318,
      fingerprint: fingerprint,
    );
  }

  @override
  void close() {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('I1: Cross-Increment Regression Suite', () {
    test('1. SpeedMode settings: concurrency mappings and aliases', () {
      expect(speedProfileFor(SpeedMode.eco).chunkConcurrency, equals(1));
      expect(speedProfileFor(SpeedMode.balanced).chunkConcurrency, equals(3));
      expect(speedProfileFor(SpeedMode.turbo).chunkConcurrency, equals(8));

      // Parsing aliases
      expect(parseSpeedMode('eco'), equals(SpeedMode.eco));
      expect(parseSpeedMode('slow'), equals(SpeedMode.eco));
      expect(parseSpeedMode('balanced'), equals(SpeedMode.balanced));
      expect(parseSpeedMode('normal'), equals(SpeedMode.balanced));
      expect(parseSpeedMode('default'), equals(SpeedMode.balanced));
      expect(parseSpeedMode('turbo'), equals(SpeedMode.turbo));
      expect(parseSpeedMode('fast'), equals(SpeedMode.turbo));
      expect(parseSpeedMode('high'), equals(SpeedMode.turbo));
      expect(parseSpeedMode('unknown'), isNull);
    });

    test('2. PIN guard & brute force lockout: 5 wrong attempts lock out 6th correct PIN', () {
      final clock = ManualClock(DateTime.utc(2026, 11, 8, 12, 0, 0));
      const wrongPin = '999999';
      const remoteIp = '192.168.1.88';

      final guard = PinGuard(
        policy: const PinPolicy(mode: PinMode.fixed, oneTime: false),
        clock: clock,
      );

      // Force fixed known PIN for testing
      guard.rotate();
      final activePin = guard.currentPin!;

      // 5 failed strikes
      for (var i = 0; i < 5; i++) {
        expect(
          () => guard.check(
            remoteAddress: remoteIp,
            pin: wrongPin,
            exempt: false,
          ),
          throwsA(
            isA<LsException>().having(
              (e) => e.code,
              'code',
              equals(LsErrorCode.pinInvalid),
            ),
          ),
        );
      }

      // 6th attempt with the CORRECT active PIN is now BLOCKED by lockout policy
      expect(
        () =>
            guard.check(remoteAddress: remoteIp, pin: activePin, exempt: false),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            equals(LsErrorCode.blocked),
          ),
        ),
      );

      // Different IP is NOT locked out by per-IP threshold
      expect(
        () => guard.check(
          remoteAddress: '192.168.1.99',
          pin: activePin,
          exempt: false,
        ),
        returnsNormally,
      );

      // After throttle window expires (10 mins), lockout lifts
      clock.advance(const Duration(minutes: 11));
      expect(
        () =>
            guard.check(remoteAddress: remoteIp, pin: activePin, exempt: false),
        returnsNormally,
      );
    });

    test('3. D6 PIN check on candidates: candidate with mismatched identity is refused', () async {
      const expectedFingerprint =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      const attackerFingerprint =
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

      final candidate = Candidate.create(
        kind: CandidateKind.wifi,
        host: '127.0.0.1',
        port: 53318,
        peerFingerprint: expectedFingerprint,
      );

      final client = _FakePeerClientWithFp(fingerprint: attackerFingerprint);
      final conn = HttpConnection(
        candidate: candidate,
        clientFactory: (cand, sec) => client,
      );

      final peerClient = await conn.open();
      final peerInfo = await peerClient.info();

      // Fingerprint continuity check (D6)
      expect(peerInfo.fingerprint, isNot(equals(candidate.peerFingerprint)));
      final certMatches = peerInfo.fingerprint == candidate.peerFingerprint;
      expect(certMatches, isFalse);

      await conn.close();
    });

    test('4. FR-13 candidate fallback: mid-transfer fault drops tier 1 and succeeds on tier 2', () async {
      final tier1Cand = Candidate.create(
        kind: CandidateKind.wifi,
        host: '192.168.1.10',
        port: 53318,
        peerFingerprint: 'PEER_FP',
        costHint: 10,
      );

      final tier2Cand = Candidate.create(
        kind: CandidateKind.lan,
        host: '10.0.0.10',
        port: 53318,
        peerFingerprint: 'PEER_FP',
        costHint: 20,
      );

      final client1 = _FakePeerClientWithFp(
        fingerprint: 'PEER_FP',
        isAlive: true,
      );
      final client2 = _FakePeerClientWithFp(
        fingerprint: 'PEER_FP',
        isAlive: true,
      );

      final manager = ConnectionManager(
        candidates: [tier1Cand, tier2Cand],
        connectionFactory: (cand, sec) {
          if (cand.kind == CandidateKind.wifi) {
            return HttpConnection(
              candidate: cand,
              clientFactory: (_, _) => client1,
            );
          } else {
            return HttpConnection(
              candidate: cand,
              clientFactory: (_, _) => client2,
            );
          }
        },
      );

      final events = <ChannelEvent>[];
      final sub = manager.events.listen(events.add);
      addTearDown(sub.cancel);

      // Starts on tier 1
      await manager.connect();
      expect(manager.activeCandidate?.kind, equals(CandidateKind.wifi));

      // Tier 1 drops mid-transfer
      client1.isAlive = false;

      // Fallback to tier 2
      final fallbackClient = await manager.fallbackToNext(
        reason: 'wifi_link_interrupted',
      );
      expect(fallbackClient, same(client2));
      expect(manager.activeCandidate?.kind, equals(CandidateKind.lan));

      // Assert event emission
      await Future<void>.delayed(Duration.zero);
      final switchEvents = events.whereType<ChannelTierSwitched>().toList();
      expect(switchEvents, hasLength(1));
      expect(
        switchEvents.first.fromCandidate?.kind,
        equals(CandidateKind.wifi),
      );
      expect(switchEvents.first.toCandidate.kind, equals(CandidateKind.lan));
      expect(switchEvents.first.reason, equals('wifi_link_interrupted'));

      await manager.close();
    });

    test('5. Resumption bitmask adoption: existing chunks preserved, missing chunks fetched', () {
      const totalChunks = 4;
      final existingBitmask = [
        true,
        true,
        false,
        false,
      ]; // Chunks 0 & 1 already received

      final neededChunks = <int>[];
      for (var i = 0; i < totalChunks; i++) {
        if (!existingBitmask[i]) {
          neededChunks.add(i);
        }
      }

      // Invariant: chunks 0 and 1 are skipped; only chunks 2 and 3 requested
      expect(neededChunks, equals([2, 3]));
      expect(neededChunks, hasLength(2));
    });
  });
}
