// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import 'idle_timeout_manager.dart';

class FakeClock implements Clock {
  FakeClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}

void main() {
  group('IdleTimeoutManager Unit Tests', () {
    late FakeClock fakeClock;
    late IdleTimeoutManager manager;
    late List<String> timedOutSessions;

    setUp(() {
      fakeClock = FakeClock(DateTime.utc(2026, 11, 6, 12, 0, 0));
      timedOutSessions = [];
      manager = IdleTimeoutManager(
        defaultTimeout: const Duration(seconds: 30),
        clock: fakeClock,
        onTimeout: (sid) => timedOutSessions.add(sid),
      );
    });

    tearDown(() {
      manager.dispose();
    });

    test('Session tracks correctly on registration', () {
      manager.registerSession('session-1');

      expect(manager.isTracking('session-1'), isTrue);
      expect(manager.activeTrackedCount, equals(1));
      expect(manager.lastActivity('session-1'), equals(fakeClock.now()));
      expect(
        manager.remainingTime('session-1'),
        equals(const Duration(seconds: 30)),
      );
    });

    test('Timeout boundary: strictly fires at 30s, not at 29s', () {
      manager.registerSession('session-boundary');

      // 10s elapsed
      fakeClock.advance(const Duration(seconds: 10));
      expect(manager.checkTimeouts(), isEmpty);
      expect(timedOutSessions, isEmpty);
      expect(
        manager.remainingTime('session-boundary'),
        equals(const Duration(seconds: 20)),
      );

      // 29s elapsed (1s before timeout)
      fakeClock.advance(const Duration(seconds: 19));
      expect(manager.checkTimeouts(), isEmpty);
      expect(timedOutSessions, isEmpty);
      expect(
        manager.remainingTime('session-boundary'),
        equals(const Duration(seconds: 1)),
      );

      // Exactly 30s elapsed -> fires
      fakeClock.advance(const Duration(seconds: 1));
      final triggered = manager.checkTimeouts();
      expect(triggered, equals(['session-boundary']));
      expect(timedOutSessions, equals(['session-boundary']));
      expect(manager.isTracking('session-boundary'), isFalse);
      expect(manager.remainingTime('session-boundary'), isNull);
    });

    test('Custom timeout boundary is respected', () {
      manager.registerSession(
        'session-custom',
        timeout: const Duration(seconds: 15),
      );

      fakeClock.advance(const Duration(seconds: 14));
      expect(manager.checkTimeouts(), isEmpty);

      fakeClock.advance(const Duration(seconds: 1));
      expect(manager.checkTimeouts(), equals(['session-custom']));
      expect(timedOutSessions, equals(['session-custom']));
    });

    test('Chunk arrival resets idle countdown', () {
      manager.registerSession('session-reset');

      // 20s elapse: 10s remaining
      fakeClock.advance(const Duration(seconds: 20));
      expect(
        manager.remainingTime('session-reset'),
        equals(const Duration(seconds: 10)),
      );

      // Chunk arrives at t=20s
      final resetSuccess = manager.onChunkReceived('session-reset');
      expect(resetSuccess, isTrue);
      expect(manager.lastActivity('session-reset'), equals(fakeClock.now()));
      expect(
        manager.remainingTime('session-reset'),
        equals(const Duration(seconds: 30)),
      );

      // Advance 15s more (t=35s since start, but 15s since chunk)
      fakeClock.advance(const Duration(seconds: 15));
      expect(manager.checkTimeouts(), isEmpty);
      expect(timedOutSessions, isEmpty);
      expect(
        manager.remainingTime('session-reset'),
        equals(const Duration(seconds: 15)),
      );

      // Advance another 15s (t=50s since start, 30s since chunk) -> times out
      fakeClock.advance(const Duration(seconds: 15));
      expect(manager.checkTimeouts(), equals(['session-reset']));
      expect(timedOutSessions, equals(['session-reset']));
    });

    test('Multiple consecutive chunks keep session alive indefinitely', () {
      manager.registerSession('session-stream');

      // Stream 5 chunks, 10s apart
      for (var i = 0; i < 5; i++) {
        fakeClock.advance(const Duration(seconds: 10));
        manager.onChunkReceived('session-stream');
        expect(manager.checkTimeouts(), isEmpty);
      }

      // Total 50s elapsed, but session is still active
      expect(manager.isTracking('session-stream'), isTrue);
      expect(timedOutSessions, isEmpty);

      // Now pause for 30s -> times out
      fakeClock.advance(const Duration(seconds: 30));
      expect(manager.checkTimeouts(), equals(['session-stream']));
      expect(timedOutSessions, equals(['session-stream']));
    });

    test('Chunk arrival for untracked session is safely ignored', () {
      final res = manager.onChunkReceived('non-existent');
      expect(res, isFalse);
    });

    test('Session termination (cancellation/completion) stops timer', () {
      manager.registerSession('session-cancelled');

      fakeClock.advance(const Duration(seconds: 10));
      manager.cancelSession('session-cancelled');

      expect(manager.isTracking('session-cancelled'), isFalse);
      expect(manager.remainingTime('session-cancelled'), isNull);

      // Advance past 30s
      fakeClock.advance(const Duration(seconds: 25));
      expect(manager.checkTimeouts(), isEmpty);
      expect(timedOutSessions, isEmpty);
    });

    test('Multiple concurrent sessions maintain isolated timers', () {
      manager.registerSession('session-A');
      fakeClock.advance(const Duration(seconds: 10));
      manager.registerSession('session-B');

      // t=30: session-A has reached 30s, session-B has only reached 20s
      fakeClock.advance(const Duration(seconds: 20));
      final round1 = manager.checkTimeouts();
      expect(round1, equals(['session-A']));
      expect(manager.isTracking('session-A'), isFalse);
      expect(manager.isTracking('session-B'), isTrue);
      expect(
        manager.remainingTime('session-B'),
        equals(const Duration(seconds: 10)),
      );

      // t=40: session-B reaches 30s
      fakeClock.advance(const Duration(seconds: 10));
      final round2 = manager.checkTimeouts();
      expect(round2, equals(['session-B']));
      expect(manager.isTracking('session-B'), isFalse);
      expect(timedOutSessions, equals(['session-A', 'session-B']));
    });

    test('Per-session timeout callback takes priority and triggers', () {
      final localCallbackLog = <String>[];
      manager.registerSession(
        'session-callback',
        onSessionTimeout: (sid) => localCallbackLog.add('local:$sid'),
      );

      fakeClock.advance(const Duration(seconds: 30));
      manager.checkTimeouts();

      expect(localCallbackLog, equals(['local:session-callback']));
      expect(timedOutSessions, equals(['session-callback']));
    });

    test(
      'executeTimeoutTermination fulfills canonical receiver contract',
      () async {
        TransferStatus? finalStatus;
        FailureReason? finalReason;
        var resourcesReleased = false;
        var sidecarsFlushed = false;
        SessionFinished? emittedEvent;

        await IdleTimeoutManager.executeTimeoutTermination(
          sessionId: 'session-contract',
          onSetStatus: (st, reason) {
            finalStatus = st;
            finalReason = reason;
          },
          onReleaseResources: () {
            resourcesReleased = true;
          },
          onFlushPartialFiles: () async {
            sidecarsFlushed = true;
          },
          onEmitEvent: (event) {
            emittedEvent = event;
          },
        );

        // 1. Session state transitions to FAILED(TIMEOUT)
        expect(finalStatus, equals(TransferStatus.failed));
        expect(finalReason, equals(FailureReason.timeout));

        // 2. Reserved resources/names/ports released
        expect(resourcesReleased, isTrue);

        // 3. Partial .lspart and bitmap sidecars flushed/preserved on disk
        expect(sidecarsFlushed, isTrue);

        // 4. SessionFinished emitted with failure reason 'TIMEOUT'
        expect(emittedEvent, isNotNull);
        expect(emittedEvent!.sessionId, equals('session-contract'));
        expect(emittedEvent!.success, isFalse);
        expect(emittedEvent!.reason, equals(FailureReason.timeout.wire));
        expect(emittedEvent!.reason, equals('TIMEOUT'));
      },
    );

    test(
      'Real-time asynchronous timer triggers without manual check',
      () async {
        final asyncCompleter = Completer<String>();
        final asyncManager = IdleTimeoutManager(
          defaultTimeout: const Duration(milliseconds: 40),
          onTimeout: (sid) {
            if (!asyncCompleter.isCompleted) {
              asyncCompleter.complete(sid);
            }
          },
        );

        asyncManager.registerSession('async-session');
        final result = await asyncCompleter.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => 'timed_out_test_waiting',
        );

        expect(result, equals('async-session'));
        asyncManager.dispose();
      },
    );
  });
}
