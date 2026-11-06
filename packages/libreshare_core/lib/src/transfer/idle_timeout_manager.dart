// ignore_for_file: depend_on_referenced_packages
/// Chunk idle timeout management for active receiver sessions (Increment 4, P4-5).
///
/// Implements the 30-second chunk idle timeout window specified in LSP-1 and
/// Increment 4 Decision D4. If no chunk is received within 30 seconds for an active
/// session:
/// 1. Session state transitions to FAILED(TIMEOUT).
/// 2. Reserved filenames and ports are released.
/// 3. In-progress `.lspart` data and bitmap sidecars are preserved on disk for resume.
/// 4. A [SessionFinished] event is emitted with failure reason 'TIMEOUT'.
library;

import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';

final Logger _log = Logger('IdleTimeoutManager');

/// Default chunk idle timeout on LAN/Wi-Fi transfers (spec §6, Inc 4 Decision D4).
const Duration kDefaultChunkIdleTimeout = Duration(seconds: 30);

/// Action callback invoked when a session times out due to chunk inactivity.
typedef SessionTimeoutCallback = FutureOr<void> Function(String sessionId);

/// Timer factory function allowing injectable timers for unit testing.
typedef TimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

class _SessionIdleEntry {
  _SessionIdleEntry({
    required this.sessionId,
    required this.lastActivity,
    required this.timeout,
    this.onTimeout,
  });

  final String sessionId;
  DateTime lastActivity;
  final Duration timeout;
  final SessionTimeoutCallback? onTimeout;
  Timer? timer;
  bool isTimedOut = false;
}

/// Manages chunk idle timers for active sessions with an injectable [Clock].
class IdleTimeoutManager {
  IdleTimeoutManager({
    this.defaultTimeout = kDefaultChunkIdleTimeout,
    this.clock = const SystemClock(),
    this.onTimeout,
    TimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? ((d, cb) => Timer(d, cb));

  /// Default idle timeout duration applied to registered sessions (default: 30s).
  final Duration defaultTimeout;

  /// Injected clock for deterministic testing and monotonic time tracking.
  final Clock clock;

  /// Global callback triggered whenever any registered session times out.
  final SessionTimeoutCallback? onTimeout;

  final TimerFactory _timerFactory;
  final Map<String, _SessionIdleEntry> _sessions = {};
  bool _disposed = false;

  /// Number of sessions currently monitored for idle timeout.
  int get activeTrackedCount => _sessions.length;

  /// Checks if a session is currently being tracked.
  bool isTracking(String sessionId) => _sessions.containsKey(sessionId);

  /// Returns the timestamp of the last chunk activity for [sessionId], or null.
  DateTime? lastActivity(String sessionId) =>
      _sessions[sessionId]?.lastActivity;

  /// Returns the remaining duration before [sessionId] times out, or null if not tracked.
  Duration? remainingTime(String sessionId) {
    final entry = _sessions[sessionId];
    if (entry == null || entry.isTimedOut) return null;
    final elapsed = clock.now().difference(entry.lastActivity);
    final remaining = entry.timeout - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Registers an active session to monitor for chunk arrivals.
  ///
  /// If the session is already tracked, its timer is reset.
  void registerSession(
    String sessionId, {
    Duration? timeout,
    SessionTimeoutCallback? onSessionTimeout,
  }) {
    if (_disposed) return;

    final existing = _sessions[sessionId];
    if (existing != null) {
      existing.timer?.cancel();
    }

    final effectiveTimeout = timeout ?? defaultTimeout;
    final now = clock.now();
    final entry = _SessionIdleEntry(
      sessionId: sessionId,
      lastActivity: now,
      timeout: effectiveTimeout,
      onTimeout: onSessionTimeout,
    );

    entry.timer = _timerFactory(effectiveTimeout, () {
      _handleTimerFired(sessionId);
    });

    _sessions[sessionId] = entry;
    _log.finer(
      'Registered idle timeout for session $sessionId '
      '(${effectiveTimeout.inSeconds}s)',
    );
  }

  /// Records that a chunk arrived for [sessionId], resetting the idle timeout countdown.
  ///
  /// Returns `true` if the session was actively tracked and reset, `false` otherwise.
  bool onChunkReceived(String sessionId) {
    if (_disposed) return false;

    final entry = _sessions[sessionId];
    if (entry == null || entry.isTimedOut) {
      _log.fine('Ignored chunk activity for untracked session $sessionId');
      return false;
    }

    entry.lastActivity = clock.now();
    entry.timer?.cancel();
    entry.timer = _timerFactory(entry.timeout, () {
      _handleTimerFired(sessionId);
    });

    _log.finest('Reset idle timer for session $sessionId');
    return true;
  }

  /// Cancels idle timeout monitoring for [sessionId] (e.g. on complete, cancel, or reject).
  void cancelSession(String sessionId) {
    final entry = _sessions.remove(sessionId);
    if (entry != null) {
      entry.timer?.cancel();
      entry.timer = null;
      _log.finer('Cancelled idle timeout for session $sessionId');
    }
  }

  /// Deterministically checks all tracked sessions against [now] (or [clock.now()]).
  ///
  /// Any session whose inactivity meets or exceeds its timeout is triggered and evicted.
  /// Returns the list of session IDs that timed out during this sweep.
  List<String> checkTimeouts([DateTime? now]) {
    if (_disposed) return const [];
    final current = now ?? clock.now();
    final timedOut = <String>[];

    final entries = _sessions.values.toList();
    for (final entry in entries) {
      if (entry.isTimedOut) continue;
      final elapsed = current.difference(entry.lastActivity);
      if (elapsed >= entry.timeout) {
        timedOut.add(entry.sessionId);
        _triggerTimeout(entry);
      }
    }

    return timedOut;
  }

  void _handleTimerFired(String sessionId) {
    final entry = _sessions[sessionId];
    if (entry == null || entry.isTimedOut) return;

    final elapsed = clock.now().difference(entry.lastActivity);
    if (elapsed >= entry.timeout) {
      _triggerTimeout(entry);
    } else {
      // Re-schedule for remaining time in case of clock skew
      final remaining = entry.timeout - elapsed;
      entry.timer = _timerFactory(remaining, () {
        _handleTimerFired(sessionId);
      });
    }
  }

  void _triggerTimeout(_SessionIdleEntry entry) {
    entry.isTimedOut = true;
    entry.timer?.cancel();
    entry.timer = null;
    _sessions.remove(entry.sessionId);

    _log.warning('Session ${entry.sessionId} chunk idle timeout triggered');

    try {
      entry.onTimeout?.call(entry.sessionId);
    } catch (e, st) {
      _log.severe(
        'Session timeout callback threw for ${entry.sessionId}',
        e,
        st,
      );
    }

    try {
      onTimeout?.call(entry.sessionId);
    } catch (e, st) {
      _log.severe(
        'Global timeout callback threw for ${entry.sessionId}',
        e,
        st,
      );
    }
  }

  /// Executes canonical session termination on idle timeout:
  /// 1. Updates status to `FAILED(TIMEOUT)`.
  /// 2. Releases reserved filenames and network ports.
  /// 3. Preserves and flushes `.lspart` data and bitmap sidecars.
  /// 4. Emits a [SessionFinished] event with `reason: 'TIMEOUT'`.
  static Future<void> executeTimeoutTermination({
    required String sessionId,
    required void Function(TransferStatus status, FailureReason? reason)
    onSetStatus,
    required void Function() onReleaseResources,
    required Future<void> Function() onFlushPartialFiles,
    required void Function(SessionFinished event) onEmitEvent,
  }) async {
    // 1. Transition state to FAILED(TIMEOUT)
    onSetStatus(TransferStatus.failed, FailureReason.timeout);

    // 2. Release reserved paths and ports
    onReleaseResources();

    // 3. Preserve partial state on disk (flush sidecars)
    await onFlushPartialFiles();

    // 4. Emit SessionFinished event
    onEmitEvent(
      SessionFinished(
        sessionId,
        success: false,
        reason: FailureReason.timeout.wire,
      ),
    );
  }

  /// Cancels all active timers and clears tracked sessions.
  void dispose() {
    _disposed = true;
    for (final entry in _sessions.values) {
      entry.timer?.cancel();
      entry.timer = null;
    }
    _sessions.clear();
  }
}
