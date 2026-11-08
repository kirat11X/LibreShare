import 'dart:async';

import 'package:test/test.dart';
import 'package:libreshare_core/src/client/peer_client.dart';
import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:libreshare_core/src/connection/candidate_race.dart';
import 'package:libreshare_core/src/connection/connection.dart';
import 'package:libreshare_core/src/nat/origin_kind.dart';

class _FakeConn implements Connection {
  _FakeConn(this.name);
  final String name;

  @override
  Candidate get candidate => Candidate.create(
    kind: CandidateKind.manual,
    host: '127.0.0.1',
    port: 80,
    peerFingerprint: '',
  );

  @override
  ConnectionState get state => ConnectionState.connected;

  @override
  bool get isHealthy => true;

  @override
  Future<PeerClient> open({Duration? timeout}) async =>
      throw UnimplementedError();

  @override
  Duration? get latency => const Duration(milliseconds: 10);

  @override
  Future<void> close() async {}
}

void main() {
  group('CandidateRace Unit Tests', () {
    test('Strict priority ordering and stagger timing', () async {
      final racer = CandidateRace(
        staggerDelay: const Duration(milliseconds: 50),
        candidateTimeout: const Duration(milliseconds: 200),
      );

      final launchOrder = <String>[];

      final candidates = [
        const OriginCandidateSpec(
          kind: OriginKind.tunnelCloudflare,
          host: 'cf.example.com',
          port: 443,
        ),
        const OriginCandidateSpec(
          kind: OriginKind.directIpv6,
          host: '2001:db8::1',
          port: 53330,
        ),
        const OriginCandidateSpec(
          kind: OriginKind.mappedIpv4,
          host: '198.51.100.1',
          port: 53330,
        ),
      ];

      final winner = await racer.raceCandidates(
        candidates: candidates,
        connectFn: (spec) async {
          launchOrder.add(spec.kind.wireName);
          if (spec.kind == OriginKind.directIpv6) {
            // High priority succeeds after 10ms
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return _FakeConn(spec.kind.wireName);
          }
          return null;
        },
      );

      expect(winner, isNotNull);
      expect((winner as _FakeConn).name, 'ipv6');
      // Verify ipv6 was launched first (highest priority)
      expect(launchOrder.first, 'ipv6');
    });

    test('First tier fails -> fallback tier wins on stagger', () async {
      final racer = CandidateRace(
        staggerDelay: const Duration(milliseconds: 30),
        candidateTimeout: const Duration(milliseconds: 100),
      );

      final candidates = [
        const OriginCandidateSpec(
          kind: OriginKind.directIpv6,
          host: 'dead.ipv6',
          port: 53330,
        ),
        const OriginCandidateSpec(
          kind: OriginKind.mappedIpv4,
          host: 'alive.mapped',
          port: 53330,
        ),
      ];

      final winner = await racer.raceCandidates(
        candidates: candidates,
        connectFn: (spec) async {
          if (spec.kind == OriginKind.directIpv6) {
            // First tier dead
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return null;
          } else {
            // Second tier alive
            return _FakeConn('mapped4');
          }
        },
      );

      expect(winner, isNotNull);
      expect((winner as _FakeConn).name, 'mapped4');
    });

    test('All candidates fail returns null within candidateTimeout', () async {
      final racer = CandidateRace(
        staggerDelay: const Duration(milliseconds: 10),
        candidateTimeout: const Duration(milliseconds: 50),
      );

      final candidates = [
        const OriginCandidateSpec(
          kind: OriginKind.directIpv6,
          host: 'dead.ipv6',
          port: 53330,
        ),
        const OriginCandidateSpec(
          kind: OriginKind.tunnelZrok,
          host: 'dead.zrok',
          port: 443,
        ),
      ];

      final winner = await racer.raceCandidates(
        candidates: candidates,
        connectFn: (spec) async {
          await Future<void>.delayed(
            const Duration(milliseconds: 100),
          ); // times out
          return _FakeConn('slow');
        },
      );

      expect(winner, isNull);
    });
  });
}
