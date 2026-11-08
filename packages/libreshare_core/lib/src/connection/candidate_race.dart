// Staggered candidate racing for Increment 5b (IPv6 > mapped IPv4 > Cloudflare > zrok > manual).

import 'dart:async';

import '../nat/origin_kind.dart';
import 'connection.dart';

final class OriginCandidateSpec {
  const OriginCandidateSpec({
    required this.kind,
    required this.host,
    required this.port,
    this.tlsPinHex,
  });

  final OriginKind kind;
  final String host;
  final int port;
  final String? tlsPinHex;

  int get priority => kind.priority;

  /// Parses `kind:host:port` string format.
  static OriginCandidateSpec? parse(String specStr, {String? tlsPinHex}) {
    final parts = specStr.split(':');
    if (parts.length < 3) return null;

    final kindStr = parts[0];
    final portStr = parts.last;
    final host = parts.sublist(1, parts.length - 1).join(':');

    final kind = OriginKind.fromWireName(kindStr);
    final port = int.tryParse(portStr);
    if (kind == null || port == null || port <= 0 || port > 65535) return null;

    return OriginCandidateSpec(
      kind: kind,
      host: host,
      port: port,
      tlsPinHex: tlsPinHex,
    );
  }

  @override
  String toString() => '${kind.wireName}:$host:$port';
}

class CandidateRace {
  CandidateRace({
    this.staggerDelay = const Duration(milliseconds: 250),
    this.candidateTimeout = const Duration(seconds: 3),
  });

  final Duration staggerDelay;
  final Duration candidateTimeout;

  /// Races a list of [candidates] in staggered order according to their priority.
  /// Launches each tier after [staggerDelay] stagger.
  /// Each dead/slow tier is bounded by [candidateTimeout] (<= 3 s).
  /// Returns the first candidate that successfully yields a non-null [Connection].
  Future<Connection?> raceCandidates({
    required List<OriginCandidateSpec> candidates,
    required Future<Connection?> Function(OriginCandidateSpec spec) connectFn,
  }) async {
    if (candidates.isEmpty) return null;

    // Sort strictly by priority: lowest number = highest priority
    final sorted = List<OriginCandidateSpec>.from(candidates)
      ..sort((a, b) => a.priority.compareTo(b.priority));

    final completer = Completer<Connection?>();
    final timers = <Timer>[];
    var activeAttempts = sorted.length;

    for (var i = 0; i < sorted.length; i++) {
      final spec = sorted[i];
      final delay = staggerDelay * i;

      void launchAttempt() {
        if (completer.isCompleted) return;

        Future.any<Connection?>([
              connectFn(spec),
              Future<Connection?>.delayed(candidateTimeout, () => null),
            ])
            .then((conn) {
              if (conn != null && !completer.isCompleted) {
                completer.complete(conn);
              } else {
                activeAttempts--;
                if (activeAttempts <= 0 && !completer.isCompleted) {
                  completer.complete(null);
                }
              }
            })
            .catchError((_) {
              activeAttempts--;
              if (activeAttempts <= 0 && !completer.isCompleted) {
                completer.complete(null);
              }
            });
      }

      if (delay == Duration.zero) {
        launchAttempt();
      } else {
        final timer = Timer(delay, launchAttempt);
        timers.add(timer);
      }
    }

    final winningConnection = await completer.future;

    for (final timer in timers) {
      timer.cancel();
    }

    return winningConnection;
  }
}
