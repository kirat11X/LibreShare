/// Time for Receive mode: a monotonic one-shot scheduler (so moving the wall
/// clock can neither extend nor cut a window) and the platform limits.
library;

import 'dart:async';

abstract interface class ReceiveScheduler {
  /// Runs [callback] once after [delay] of monotonic time.
  Timer once(Duration delay, void Function() callback);
}

/// [ReceiveScheduler] on `dart:async` timers (which do not follow wall-clock
/// changes).
class SystemReceiveScheduler implements ReceiveScheduler {
  const SystemReceiveScheduler();

  @override
  Timer once(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}

/// Per-platform limits (design 01 sections 1.4 and 4).
class ReceivePlatformCaps {
  const ReceivePlatformCaps({
    this.maxContinuous,
    this.osTimeout,
    this.hardStopMargin = const Duration(seconds: 8),
    this.resumeAfterCrash = true,
  });

  /// Longest window ever granted, including "Always" (Android: 6 h; desktop:
  /// null = unlimited).
  final Duration? maxContinuous;

  /// The OS's own limit for the receiving service, when it has one (the
  /// Android `dataSync` fallback). A drain never outlives it by more than
  /// [hardStopMargin].
  final Duration? osTimeout;

  /// How long before [osTimeout] the listener must be gone.
  final Duration hardStopMargin;

  /// `true` (desktop): a process that died inside its window re-enters On with
  /// the remaining time. `false` (Android): it enters `Paused(osStopped)` and
  /// waits for a tap, because a background start may not be allowed.
  final bool resumeAfterCrash;
}
