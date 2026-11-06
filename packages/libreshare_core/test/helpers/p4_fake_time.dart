// Deterministic time for the P4 receiver/pairing tests (Increment 3).
//
// The receiver's 120 s consent timer, the 30 s SAS reveal deadline and the 125 s pairing hold
// are `dart:async` timers created with the default constants, so the tests must see the real
// numbers without sleeping. [withFakeTime] runs a body in a zone whose timers are virtual;
// [FakeTime.advance] fires the due timers in order and moves the [ManualClock] wall clock by
// the same amount, so code that compares `clock.now()` instead of arming a timer behaves the
// same way. Everything that must really run (file I/O callbacks, event-queue pumping) is
// driven through the parent zone.
import 'dart:async';

import 'package:test/test.dart';

import 'manual_clock.dart';

class FakeTime {
  FakeTime._(this.clock, this._parent);

  final ManualClock clock;
  final Zone _parent;
  final List<_FakeTimer> _timers = [];
  int _seq = 0;
  Duration _now = Duration.zero;

  /// Virtual timers that are armed and have not fired.
  int get activeTimers => _timers.where((t) => t.isActive).length;

  /// Lets queued microtasks and real I/O completions run (real timers, parent zone).
  Future<void> pump() => _parent.run(() => pumpEventQueue());

  /// Moves virtual time forward by [d], firing every timer that falls due in order.
  Future<void> advance(Duration d) async {
    final target = _now + d;
    while (true) {
      final due = _timers.where((t) => t.isActive && t._at <= target).toList()
        ..sort((a, b) {
          final c = a._at.compareTo(b._at);
          return c != 0 ? c : a._seq.compareTo(b._seq);
        });
      if (due.isEmpty) break;
      final t = due.first;
      final delta = t._at - _now;
      if (delta > Duration.zero) {
        await _parent.run(() => clock.advance(delta));
      }
      _now = t._at;
      t._fire();
      await pump();
    }
    final rest = target - _now;
    if (rest > Duration.zero) {
      await _parent.run(() => clock.advance(rest));
    }
    _now = target;
    await pump();
  }

  Timer _createTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration duration,
    void Function() f,
  ) {
    final t = _FakeTimer(this, zone, _now + duration, _seq++, () => f());
    _timers.add(t);
    return t;
  }

  Timer _createPeriodic(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration period,
    void Function(Timer) f,
  ) {
    late final _FakeTimer t;
    t = _FakeTimer(
      this,
      zone,
      _now + period,
      _seq++,
      () => f(t),
      period: period,
    );
    _timers.add(t);
    return t;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(
    this._owner,
    this._zone,
    this._at,
    this._seq,
    this._callback, {
    this.period,
  });

  final FakeTime _owner;
  final Zone _zone;
  Duration _at;
  int _seq;
  final void Function() _callback;
  final Duration? period;
  bool _active = true;
  int _ticks = 0;

  void _fire() {
    if (!_active) return;
    _ticks++;
    final p = period;
    if (p == null) {
      _active = false;
      _owner._timers.remove(this);
    } else {
      _at = _at + p;
      _seq = _owner._seq++;
    }
    _zone.runGuarded(_callback);
  }

  @override
  void cancel() {
    _active = false;
    _owner._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}

/// Runs [body] with virtual timers. Create receivers, services and sessions INSIDE [body]:
/// only timers armed in this zone are virtual.
Future<T> withFakeTime<T>(
  ManualClock clock,
  Future<T> Function(FakeTime time) body,
) {
  final parent = Zone.current;
  final time = FakeTime._(clock, parent);
  final zone = parent.fork(
    specification: ZoneSpecification(
      createTimer: time._createTimer,
      createPeriodicTimer: time._createPeriodic,
    ),
  );
  return zone.run(() => body(time));
}
