import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

class _FakePeerClient implements PeerClient {
  bool closed = false;

  @override
  Future<DeviceInfo> info() async =>
      const DeviceInfo(deviceId: 'peer-1', alias: 'Peer 1', platform: 'linux');

  @override
  void close() {
    closed = true;
  }

  @override
  Future<void> cancel(String sessionId) async {}
  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async => const FileVerification(verified: true, sha256: '');
  @override
  Future<SessionStatus> createSession(SessionRequest request) async =>
      const SessionStatus(sessionId: 's1', status: TransferStatus.completed);
  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async => const FileState(chunkCount: 1, receivedRanges: []);
  @override
  Future<SessionStatus> finish(String sessionId) async =>
      const SessionStatus(sessionId: 's1', status: TransferStatus.completed);
  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) async {}
  @override
  Future<DeviceInfo> register(DeviceInfo self) async => info();
  @override
  Future<SessionStatus> waitSession(
    String sessionId, {
    int waitSeconds = 25,
  }) async =>
      const SessionStatus(sessionId: 's1', status: TransferStatus.completed);
}

class _FakeConnection implements Connection {
  _FakeConnection({required this.candidate, this.shouldFail = false});

  @override
  final Candidate candidate;
  final bool shouldFail;
  final Duration latencyDuration = const Duration(milliseconds: 15);

  ConnectionState _state = ConnectionState.disconnected;
  _FakePeerClient? client;

  @override
  ConnectionState get state => _state;
  @override
  bool get isHealthy => _state == ConnectionState.connected;
  @override
  Duration? get latency => latencyDuration;

  @override
  Future<PeerClient> open({Duration? timeout}) async {
    if (shouldFail) {
      _state = ConnectionState.failed;
      throw ConnectionException(
        'Simulated probe failure',
        candidate: candidate,
      );
    }
    _state = ConnectionState.connected;
    return client = _FakePeerClient();
  }

  @override
  Future<void> close() async {
    _state = ConnectionState.closed;
    client?.close();
  }
}

void main() {
  group('ConnectionManager & Connection Ladder', () {
    const pin =
        'ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234';

    test(
      'sorts candidates by priority and connects to top viable candidate',
      () async {
        final cLan = Candidate.create(
          kind: CandidateKind.lan,
          host: '10.0.0.5',
          port: 5000,
          peerFingerprint: pin,
        );
        final cWifi = Candidate.create(
          kind: CandidateKind.wifi,
          host: '192.168.1.5',
          port: 5000,
          peerFingerprint: pin,
        );

        final manager = ConnectionManager(
          candidates: [cLan, cWifi],
          connectionFactory: (candidate, sec) =>
              _FakeConnection(candidate: candidate),
        );

        // wifi has lower costHint (10) than lan (20), so wifi is tried first
        expect(manager.candidates.first.kind, equals(CandidateKind.wifi));

        final client = await manager.connect();
        expect(client, isNotNull);
        expect(manager.activeCandidate?.kind, equals(CandidateKind.wifi));
        expect(manager.activeConnection?.isHealthy, isTrue);

        await manager.close();
      },
    );

    test('falls back to next tier when primary candidate fails', () async {
      final cWifi = Candidate.create(
        kind: CandidateKind.wifi,
        host: '192.168.1.5',
        port: 5000,
        peerFingerprint: pin,
      );
      final cLan = Candidate.create(
        kind: CandidateKind.lan,
        host: '10.0.0.5',
        port: 5000,
        peerFingerprint: pin,
      );

      final events = <ChannelEvent>[];
      final manager = ConnectionManager(
        candidates: [cWifi, cLan],
        connectionFactory: (candidate, sec) => _FakeConnection(
          candidate: candidate,
          shouldFail: candidate.kind == CandidateKind.wifi,
        ),
      );
      manager.events.listen(events.add);

      final client = await manager.connect();
      expect(client, isNotNull);
      expect(manager.activeCandidate?.kind, equals(CandidateKind.lan));
      await Future<void>.delayed(Duration.zero);

      // WiFi failed, LAN active
      expect(events.whereType<ChannelFailed>().length, equals(1));
      expect(events.whereType<ChannelActive>().length, equals(1));

      await manager.close();
    });

    test('fallbackToNext switches active tier mid-transfer', () async {
      final cWifi = Candidate.create(
        kind: CandidateKind.wifi,
        host: '192.168.1.5',
        port: 5000,
        peerFingerprint: pin,
      );
      final cLan = Candidate.create(
        kind: CandidateKind.lan,
        host: '10.0.0.5',
        port: 5000,
        peerFingerprint: pin,
      );

      final events = <ChannelEvent>[];
      final manager = ConnectionManager(
        candidates: [cWifi, cLan],
        connectionFactory: (candidate, sec) =>
            _FakeConnection(candidate: candidate),
      );
      manager.events.listen(events.add);

      await manager.connect();
      expect(manager.activeCandidate?.kind, equals(CandidateKind.wifi));

      // Trigger fallback to next tier
      final client2 = await manager.fallbackToNext(reason: 'wifi packet loss');
      expect(client2, isNotNull);
      expect(manager.activeCandidate?.kind, equals(CandidateKind.lan));
      await Future<void>.delayed(Duration.zero);

      final switched = events.whereType<ChannelTierSwitched>().first;
      expect(switched.fromCandidate?.kind, equals(CandidateKind.wifi));
      expect(switched.toCandidate.kind, equals(CandidateKind.lan));
      expect(switched.reason, equals('wifi packet loss'));

      await manager.close();
    });

    test('Security Invariant (D6): rejects candidates with mismatched peerFingerprint', () {
      final cValid = Candidate.create(
        kind: CandidateKind.wifi,
        host: '192.168.1.5',
        port: 5000,
        peerFingerprint: pin,
      );
      final cSpoofed = Candidate.create(
        kind: CandidateKind.lan,
        host: '10.0.0.5',
        port: 5000,
        peerFingerprint:
            'EVIL9999EVIL9999EVIL9999EVIL9999EVIL9999EVIL9999EVIL9999EVIL9999',
      );

      expect(
        () => ConnectionManager(
          candidates: [cValid, cSpoofed],
          pinnedFingerprint: pin,
        ),
        throwsA(isA<FingerprintMismatchException>()),
      );
    });
  });
}
