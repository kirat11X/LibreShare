// ignore_for_file: depend_on_referenced_packages
import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:test/test.dart';

void main() {
  group('CandidateKind', () {
    test('wire serialization round-trips all kinds', () {
      for (final kind in CandidateKind.values) {
        expect(CandidateKind.fromWire(kind.wire), equals(kind));
      }
    });

    test('fromWire throws on unknown wire values', () {
      expect(
        () => CandidateKind.fromWire('unknown'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('isLocal correctly identifies local vs relayed', () {
      expect(CandidateKind.wifi.isLocal, isTrue);
      expect(CandidateKind.lan.isLocal, isTrue);
      expect(CandidateKind.manual.isLocal, isTrue);
      expect(CandidateKind.loopback.isLocal, isTrue);
      expect(CandidateKind.tunnel.isLocal, isFalse);
    });

    test('defaultCostHint assigns expected tier priorities', () {
      expect(CandidateKind.loopback.defaultCostHint, equals(5));
      expect(CandidateKind.wifi.defaultCostHint, equals(10));
      expect(CandidateKind.lan.defaultCostHint, equals(20));
      expect(CandidateKind.manual.defaultCostHint, equals(30));
      expect(CandidateKind.tunnel.defaultCostHint, equals(100));
    });
  });

  group('Candidate model', () {
    const pinnedFp =
        'a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0';

    test('constructs with valid parameters', () {
      final c = Candidate(
        id: 'wifi:192.168.1.50:45454',
        kind: CandidateKind.wifi,
        host: '192.168.1.50',
        port: 45454,
        peerFingerprint: pinnedFp,
        costHint: 10,
        lastSuccess: DateTime.utc(2026, 11, 6, 12, 0, 0),
        rtt: const Duration(milliseconds: 15),
      );

      expect(c.id, equals('wifi:192.168.1.50:45454'));
      expect(c.kind, equals(CandidateKind.wifi));
      expect(c.host, equals('192.168.1.50'));
      expect(c.port, equals(45454));
      expect(c.peerFingerprint, equals(pinnedFp));
      expect(c.costHint, equals(10));
      expect(c.lastSuccess, equals(DateTime.utc(2026, 11, 6, 12, 0, 0)));
      expect(c.rtt, equals(const Duration(milliseconds: 15)));
    });

    test('Candidate.create sets default id and costHint', () {
      final c = Candidate.create(
        kind: CandidateKind.lan,
        host: '10.0.0.5',
        port: 45454,
        peerFingerprint: pinnedFp,
      );

      expect(c.id, equals('lan:10.0.0.5:45454'));
      expect(c.costHint, equals(CandidateKind.lan.defaultCostHint));
      expect(c.lastSuccess, isNull);
      expect(c.rtt, isNull);
    });

    test('JSON serialization round-trip', () {
      final now = DateTime.utc(2026, 11, 6, 10, 30, 0);
      final c1 = Candidate(
        id: 'c1',
        kind: CandidateKind.wifi,
        host: '192.168.1.20',
        port: 50000,
        peerFingerprint: pinnedFp,
        costHint: 10,
        lastSuccess: now,
        rtt: const Duration(milliseconds: 22),
      );

      final json = c1.toJson();
      final c2 = Candidate.fromJson(json);

      expect(c2.id, equals(c1.id));
      expect(c2.kind, equals(c1.kind));
      expect(c2.host, equals(c1.host));
      expect(c2.port, equals(c1.port));
      expect(c2.peerFingerprint, equals(c1.peerFingerprint));
      expect(c2.costHint, equals(c1.costHint));
      expect(c2.lastSuccess, equals(now));
      expect(c2.rtt, equals(const Duration(milliseconds: 22)));
      expect(c2, equals(c1));
    });

    test('JSON serialization with null optional fields', () {
      final c1 = Candidate.create(
        kind: CandidateKind.manual,
        host: '192.168.1.100',
        port: 45454,
        peerFingerprint: pinnedFp,
      );

      final json = c1.toJson();
      expect(json.containsKey('lastSuccess'), isFalse);
      expect(json.containsKey('rttMs'), isFalse);

      final c2 = Candidate.fromJson(json);
      expect(c2.lastSuccess, isNull);
      expect(c2.rtt, isNull);
      expect(c2, equals(c1));
    });

    group('Security Invariant: matchesFingerprint', () {
      final candidate = Candidate.create(
        kind: CandidateKind.wifi,
        host: '192.168.1.1',
        port: 45454,
        peerFingerprint: 'A1:B2:C3:D4:E5:F6:78:90:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0',
      );

      test('matches normalized lowercase without colons', () {
        expect(
          candidate.matchesFingerprint(
            'a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0',
          ),
          isTrue,
        );
      });

      test('matches formatted uppercase with colons', () {
        expect(
          candidate.matchesFingerprint(
            'A1:B2:C3:D4:E5:F6:78:90:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0:12:34:56:78:9A:BC:DE:F0',
          ),
          isTrue,
        );
      });

      test('rejects mismatched fingerprint', () {
        expect(
          candidate.matchesFingerprint(
            '0000000000000000000000000000000000000000000000000000000000000000',
          ),
          isFalse,
        );
      });

      test('rejects empty fingerprint', () {
        expect(candidate.matchesFingerprint(''), isFalse);
        expect(candidate.matchesFingerprint('   '), isFalse);
      });
    });

    group('Ranking and Comparable', () {
      test('ranks lower costHint first', () {
        final wifi = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.1',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
        );
        final lan = Candidate.create(
          kind: CandidateKind.lan,
          host: '10.0.0.2',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 20,
        );

        expect(wifi.compareTo(lan), isNegative);
        expect(lan.compareTo(wifi), isPositive);
      });

      test('equal costHint ranks more recent success first', () {
        final earlier = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.1',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
          lastSuccess: DateTime.utc(2026, 11, 6, 10, 0, 0),
        );
        final later = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.2',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
          lastSuccess: DateTime.utc(2026, 11, 6, 11, 0, 0),
        );

        // Later (more recent) should come first (-1)
        expect(later.compareTo(earlier), isNegative);
        expect(earlier.compareTo(later), isPositive);
      });

      test('equal costHint and success ranks lower RTT first', () {
        final fast = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.1',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
          rtt: const Duration(milliseconds: 5),
        );
        final slow = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.2',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
          rtt: const Duration(milliseconds: 40),
        );

        expect(fast.compareTo(slow), isNegative);
        expect(slow.compareTo(fast), isPositive);
      });

      test('measured RTT ranks ahead of unmeasured RTT', () {
        final measured = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.1',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
          rtt: const Duration(milliseconds: 100),
        );
        final unmeasured = Candidate.create(
          kind: CandidateKind.wifi,
          host: '10.0.0.2',
          port: 45454,
          peerFingerprint: pinnedFp,
          costHint: 10,
        );

        expect(measured.compareTo(unmeasured), isNegative);
        expect(unmeasured.compareTo(measured), isPositive);
      });
    });

    test('copyWith updates specified fields', () {
      final initial = Candidate.create(
        kind: CandidateKind.wifi,
        host: '10.0.0.1',
        port: 45454,
        peerFingerprint: pinnedFp,
      );

      final updated = initial.copyWith(
        rtt: const Duration(milliseconds: 12),
        costHint: 15,
      );

      expect(updated.id, equals(initial.id));
      expect(updated.rtt, equals(const Duration(milliseconds: 12)));
      expect(updated.costHint, equals(15));
      expect(updated.host, equals(initial.host));
    });
  });
}
