// Fake time and a recording gate for Receive-mode tests (design 01 s1.6).
import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

/// One clock for both roles: [Clock] (wall time) and [ReceiveScheduler]
/// (monotonic timers). [advance] moves both and fires due timers in order;
/// [jumpWallClock] moves only the wall clock, like a user changing the date.
class ManualClock implements Clock, ReceiveScheduler {
  ManualClock([DateTime? start])
    : _wall = start ?? DateTime.utc(2026, 11, 3, 12);

  DateTime _wall;
  Duration _mono = Duration.zero;
  final List<_ManualTimer> _timers = [];
  int _seq = 0;

  @override
  DateTime now() => _wall;

  /// Monotonic time elapsed since construction.
  Duration get elapsed => _mono;

  /// Timers that are armed and have not fired.
  int get pending => _timers.where((t) => t.isActive).length;

  @override
  Timer once(Duration delay, void Function() callback) {
    final t = _ManualTimer(this, _mono + delay, callback, _seq++);
    _timers.add(t);
    return t;
  }

  /// Moves wall and monotonic time forward by [d], firing every timer that
  /// falls due (in order, each at its own instant) and letting the controller's
  /// queued work run after each one.
  Future<void> advance(Duration d) async {
    final target = _mono + d;
    while (true) {
      final due = _timers.where((t) => t.isActive && t.at <= target).toList()
        ..sort((a, b) {
          final c = a.at.compareTo(b.at);
          return c != 0 ? c : a.seq.compareTo(b.seq);
        });
      if (due.isEmpty) break;
      final t = due.first;
      _wall = _wall.add(t.at - _mono);
      _mono = t.at;
      t.fire();
      await pumpEventQueue();
    }
    _wall = _wall.add(target - _mono);
    _mono = target;
    await pumpEventQueue();
  }

  /// Wall clock only (NTP step, user edit). Timers do not notice.
  void jumpWallClock(Duration d) => _wall = _wall.add(d);
}

class _ManualTimer implements Timer {
  _ManualTimer(this._clock, this.at, this._callback, this.seq);

  final ManualClock _clock;
  final Duration at;
  final int seq;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// Records every call the controller makes; behaviour is scriptable.
class FakeGate implements ReceiveGate {
  /// Calls in order, e.g. `open`, `close(graceful)`, `announce(periodic)`.
  final List<String> calls = [];

  int boundPort = 53318;
  bool listening = false;
  AnnouncePolicy policy = AnnouncePolicy.none;
  bool accepting = true;

  /// Make the next [openListener] fail with this error.
  Object? failOpen;

  /// When set, [openListener] waits for it (to observe `Starting`).
  Completer<void>? holdOpen;

  int _active = 0;
  final StreamController<int> _counts = StreamController<int>.broadcast();

  int get opens => calls.where((c) => c == 'open').length;
  int get closes => calls.where((c) => c.startsWith('close')).length;

  @override
  Future<int> openListener() async {
    calls.add('open');
    final hold = holdOpen;
    if (hold != null) await hold.future;
    final err = failOpen;
    if (err != null) {
      failOpen = null;
      throw err;
    }
    listening = true;
    return boundPort;
  }

  @override
  Future<void> closeListener({required bool graceful}) async {
    calls.add('close(${graceful ? 'graceful' : 'forced'})');
    listening = false;
  }

  @override
  void setAnnounce(AnnouncePolicy policy) {
    calls.add('announce(${policy.name})');
    this.policy = policy;
  }

  @override
  void setAcceptingSessions(bool accepting) {
    calls.add('accepting($accepting)');
    this.accepting = accepting;
  }

  @override
  int get activeSessions => _active;

  @override
  Stream<int> get activeSessionCount => _counts.stream;

  /// Simulates sessions starting/finishing.
  void setActive(int n) {
    _active = n;
    _counts.add(n);
  }
}
