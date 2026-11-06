import 'dart:async';

import 'package:logging/logging.dart';

import '../client/peer_client.dart';
import '../monitor/channel_event.dart';
import '../monitor/event_log.dart';
import '../security/contracts.dart';
import 'candidate.dart';
import 'connection.dart';
import 'http_connection.dart';

final Logger _log = Logger('ConnectionManager');

/// Connection ladder manager for Increment 4 (ADR 0002).
///
/// Orchestrates candidate selection, health monitoring, tier transitions,
/// and fallback while enforcing pin continuity across all network paths.
class ConnectionManager {
  ConnectionManager({
    required List<Candidate> candidates,
    this.security = const SecurityConfig.plaintext(),
    this.tierBudget = const Duration(seconds: 8),
    this.connectionFactory,
    this.eventLog,
    this.pinnedFingerprint,
    this.enableFallback = true,
  }) {
    _candidates = List<Candidate>.of(candidates)..sort();
    if (_candidates.isEmpty) {
      throw ArgumentError.value(candidates, 'candidates', 'Must not be empty');
    }
    // Verify pin continuity across candidates if pinnedFingerprint is specified
    final pin = pinnedFingerprint;
    if (pin != null && pin.isNotEmpty) {
      for (final c in _candidates) {
        if (!c.matchesFingerprint(pin)) {
          throw FingerprintMismatchException(
            expectedFingerprint: pin,
            presentedFingerprint: c.peerFingerprint,
            candidate: c,
          );
        }
      }
    }
  }

  final SecurityConfig security;
  final Duration tierBudget;
  final Connection Function(Candidate candidate, SecurityConfig security)?
  connectionFactory;
  final EventLog? eventLog;
  final String? pinnedFingerprint;
  final bool enableFallback;

  late final List<Candidate> _candidates;
  int _currentIndex = 0;
  Connection? _activeConnection;
  PeerClient? _activeClient;
  final _eventController = StreamController<ChannelEvent>.broadcast();

  List<Candidate> get candidates => List.unmodifiable(_candidates);
  Candidate? get activeCandidate => _activeConnection?.candidate;
  Connection? get activeConnection => _activeConnection;
  PeerClient? get activeClient => _activeClient;
  Stream<ChannelEvent> get events => _eventController.stream;

  /// Connects to the highest priority viable candidate within the ladder.
  Future<PeerClient> connect({Duration? timeout}) async {
    final failures = <Object>[];

    for (var i = 0; i < _candidates.length; i++) {
      _currentIndex = i;
      final candidate = _candidates[i];

      final conn = connectionFactory != null
          ? connectionFactory!(candidate, security)
          : HttpConnection(candidate: candidate, security: security);

      final budget = timeout ?? tierBudget;
      try {
        _log.info(
          'Attempting ladder connection to candidate: ${candidate.id} (cost: ${candidate.costHint})',
        );
        final client = await conn.open(timeout: budget);

        _activeConnection = conn;
        _activeClient = client;

        final event = ChannelActive(
          candidate: candidate,
          rtt: conn.latency ?? Duration.zero,
          timestamp: DateTime.now().toUtc(),
        );
        _eventController.add(event);
        unawaited(eventLog?.logChannel(event));

        return client;
      } on Object catch (e) {
        failures.add(e);
        _log.warning('Candidate ${candidate.id} failed: $e');

        final failedEvent = ChannelFailed(
          candidate: candidate,
          reason: e.toString(),
          error: e,
          consecutiveFailures: 1,
          timestamp: DateTime.now().toUtc(),
        );
        _eventController.add(failedEvent);
        unawaited(eventLog?.logChannel(failedEvent));
        await conn.close();
        if (!enableFallback) {
          throw ConnectionException(
            'Candidate ${candidate.id} failed and fallback is disabled: $e',
          );
        }
      }
    }

    throw ConnectionException(
      'All ${_candidates.length} candidates failed in connection ladder: $failures',
    );
  }

  /// Falls back to the next candidate in the ladder after a connection degradation or failure.
  Future<PeerClient> fallbackToNext({String reason = 'fallback'}) async {
    final prevCandidate = activeCandidate;
    if (_activeConnection != null) {
      await _activeConnection!.close();
      _activeConnection = null;
      _activeClient = null;
    }

    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _candidates.length) {
      throw ConnectionException(
        'No more fallback candidates available in ladder',
      );
    }

    for (var i = nextIndex; i < _candidates.length; i++) {
      _currentIndex = i;
      final candidate = _candidates[i];

      final conn = connectionFactory != null
          ? connectionFactory!(candidate, security)
          : HttpConnection(candidate: candidate, security: security);

      try {
        final client = await conn.open(timeout: tierBudget);
        _activeConnection = conn;
        _activeClient = client;

        final switchedEvent = ChannelTierSwitched(
          fromCandidate: prevCandidate,
          toCandidate: candidate,
          reason: reason,
          timestamp: DateTime.now().toUtc(),
        );
        _eventController.add(switchedEvent);
        unawaited(eventLog?.logChannel(switchedEvent));

        return client;
      } catch (e) {
        await conn.close();
      }
    }

    throw ConnectionException('All remaining fallback candidates failed');
  }

  Future<void> close() async {
    if (_activeConnection != null) {
      await _activeConnection!.close();
      _activeConnection = null;
      _activeClient = null;
    }
    await _eventController.close();
  }
}
