/// [ReceiveController]: the one owner of Receive mode (design 01 section 1).
///
/// Three orthogonal inputs: *mode* (Off / For(N) / Always), *visibility*
/// (Everyone / Contacts) and the *environment* (network, battery,
/// permission). UI, tray, notification and CLI are thin views of [state].
///
/// Everything time-related goes through the injected [Clock] (display and
/// persistence) and [ReceiveScheduler] (monotonic expiry), so the whole state
/// machine is testable with a fake clock and no sockets. Public operations are
/// serialised: a second `turnOn` while the listener is opening waits for the
/// first, so there is exactly one bind and a `turnOff` issued meanwhile wins.
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../storage/receive_settings_store.dart';
import 'receive_gate.dart';
import 'receive_scheduler.dart';
import 'receive_settings.dart';
import 'receive_state.dart';

/// How an engine sets up its [ReceiveController].
class ReceiveConfig {
  const ReceiveConfig({
    this.initialMode = const ReceiveAlways(),
    this.store,
    this.caps = const ReceivePlatformCaps(),
    this.env,
    this.scheduler,
    this.exitHint = ExitHint.unknown,
  });

  /// Mode entered by `LibreShareEngine.start()` when nothing is restored:
  /// always without a [store]; with one, only when it holds no record yet
  /// (`Off(neverEnabled)`). `ReceiveOff()` keeps the engine silent until the
  /// user turns Receive on.
  final ReceiveMode initialMode;

  /// With a store, `start()` calls [ReceiveController.restore] (settings and
  /// crash recovery, design 01 section 1.5) instead of just entering
  /// [initialMode]. Null: an in-memory store.
  final ReceiveSettingsStore? store;
  final ReceivePlatformCaps caps;
  final Stream<EnvEvent>? env;

  /// Monotonic scheduler (default: [SystemReceiveScheduler]).
  final ReceiveScheduler? scheduler;

  /// Passed to `restore()` (Android: from `ApplicationExitInfo`).
  final ExitHint exitHint;
}

class ReceiveController {
  ReceiveController({
    required this._gate,
    required this._store,
    required this._clock,
    required this._scheduler,
    this._caps = const ReceivePlatformCaps(),
    Stream<EnvEvent>? env,
    this._settings = const ReceiveSettings(),
    this.drainGrace = const Duration(minutes: 5),
    this.expiryWarning = const Duration(minutes: 15),
    this.contactsSupported = false,
  }) {
    _envSub = env?.listen(
      (e) => _background(() => _onEnv(e)),
      onError: (Object e) => _log.fine('env stream error: $e'),
    );
  }

  static final Logger _log = Logger('libreshare.receive');

  final ReceiveGate _gate;
  final ReceiveSettingsStore _store;
  final Clock _clock;
  final ReceiveScheduler _scheduler;
  final ReceivePlatformCaps _caps;
  StreamSubscription<EnvEvent>? _envSub;

  /// How long a finished window waits for active sessions (design 01: 5 min).
  final Duration drainGrace;

  /// Lead time of [ExpiringSoon] (design 01: 15 min).
  final Duration expiryWarning;

  /// Whether [ReceiveVisibility.contacts] may be chosen: true when the owner
  /// runs the secure profile (it has a trust store to evaluate); false in the
  /// plaintext profile, where choosing it throws [UnsupportedError].
  final bool contactsSupported;

  ReceiveSettings _settings;
  ReceiveState _state = const Off(OffReason.neverEnabled);
  ReceiveMode? _mode; // last requested mode; what resume() repeats
  DateTime? _since;
  DateTime? _until;
  final Set<PauseReason> _envCauses = {};

  Timer? _expiryTimer;
  Timer? _warnTimer;
  Timer? _drainTimer;
  StreamSubscription<int>? _activeSub;
  int _windowGen = 0;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();

  final StreamController<ReceiveState> _states =
      StreamController<ReceiveState>.broadcast();
  final StreamController<ReceiveEvent> _events =
      StreamController<ReceiveEvent>.broadcast();

  // ----------------------------------------------------------------- views

  ReceiveState get state => _state;

  /// Every state change (no replay: read [state] for the present value).
  Stream<ReceiveState> get states => _states.stream;

  /// [StateChanged], [ExpiringSoon], [ExpiredWhileBusy].
  Stream<ReceiveEvent> get events => _events.stream;
  ReceiveSettings get settings => _settings;

  /// Wall-clock end of the current window (display only), null for "until
  /// turned off" or when not receiving.
  DateTime? get until => _until;

  /// The mode `resume()` would repeat.
  ReceiveMode get lastMode => _mode ?? _settings.defaultMode;

  /// True while the listener is open (On or Draining).
  bool get isReceiving => _state is On || _state is Draining;

  // ------------------------------------------------------------ operations

  /// Applies persisted settings and the crash-recovery rules (design 01
  /// section 1.5):
  ///
  /// * clean exit, or [ExitHint.userStopped] -> `Off(user)`;
  /// * died inside its window (or an unlimited one) -> On again with the time
  ///   left (desktop) or `Paused(osStopped)` (`caps.resumeAfterCrash == false`);
  /// * window already over -> `Off(expired)`;
  /// * nothing stored -> `Off(neverEnabled)`.
  Future<void> restore({ExitHint hint = ExitHint.unknown}) =>
      _enqueue(() => _restore(hint));

  /// Starts receiving. [mode] defaults to `settings.defaultMode`. While On,
  /// this re-arms the window (e.g. "Extend 6 h") without rebinding; a second
  /// call while the listener is opening joins the first.
  Future<void> turnOn([ReceiveMode? mode]) => _enqueue(
    () => _turnOn(mode ?? _settings.defaultMode, ReceiveCause.turnOn),
  );

  /// Stops receiving now (any state). Waits for a pending bind first.
  Future<void> turnOff() => _enqueue(() => _turnOff(ReceiveCause.turnOff));

  /// One-tap undo of `Paused` / `Off(expired)`: opens the listener with a
  /// fresh window of the last mode. No-op while already receiving.
  Future<void> resume() => _enqueue(() async {
    if (isReceiving || _state is Starting) return;
    await _turnOn(lastMode, ReceiveCause.resume);
  });

  /// Changes who sees this device. Only the announce policy changes: the
  /// listener and its port stay. Throws [UnsupportedError] for
  /// [ReceiveVisibility.contacts] until [contactsSupported].
  Future<void> setVisibility(ReceiveVisibility visibility) =>
      updateSettings(_settings.copyWith(visibility: visibility));

  /// Replaces the settings and persists them. A changed visibility is applied
  /// to a running listener without rebinding.
  Future<void> updateSettings(ReceiveSettings settings) => _enqueue(() async {
    if (settings.visibility == ReceiveVisibility.contacts &&
        !contactsSupported) {
      throw UnsupportedError(
        'Contacts-only visibility needs pairing (Increment 3)',
      );
    }
    final visibilityChanged = settings.visibility != _settings.visibility;
    _settings = settings;
    final s = _state;
    if (visibilityChanged && s is On) {
      _gate.setAnnounce(_policyFor(settings.visibility));
      _set(On(s.since, s.until, settings.visibility), ReceiveCause.visibility);
    }
    await _persist();
  });

  /// The OS stopped the receiving service (Android `onTimeout`): `Paused`,
  /// listener closed, timers off. [resume] starts a fresh window.
  Future<void> platformTimeout() => _enqueue(() async {
    final s = _state;
    if (s is! On && s is! Draining) return;
    _cancelWindow();
    _cancelDrain();
    await _pause(PauseReason.platformTimeout, ReceiveCause.platformTimeout);
  });

  /// Clean exit of the owner (engine `stop()`): timers off, the stored record
  /// marked `cleanStop`, the state reset to `Off(user)`. Touches neither the
  /// gate nor the settings (the owner closes its own listener) and keeps the
  /// controller usable, so an engine can be started again.
  Future<void> shutdown() => _enqueue(() async {
    _cancelWindow();
    _cancelDrain();
    final s = _state;
    final wasLive = s is On || s is Draining || s is Paused;
    if (wasLive) await _persist(cleanStop: true);
    _until = null;
    _envCauses.clear();
    if (s is! Off) _set(const Off(OffReason.user), ReceiveCause.shutdown);
  });

  /// [shutdown], then the controller is finished: streams close and later
  /// operations are ignored.
  Future<void> dispose() async {
    if (_disposed) return;
    await shutdown();
    _disposed = true;
    await _envSub?.cancel();
    _envSub = null;
    await _states.close();
    await _events.close();
  }

  // ------------------------------------------------------------ plumbing

  /// Serialises operations; ignored once the controller is disposed.
  Future<void> _enqueue(Future<void> Function() op) {
    final c = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        if (!_disposed) await op();
        c.complete();
      } on Object catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  /// Fire-and-forget operation (timer, env event): errors are logged.
  void _background(Future<void> Function() op) {
    if (_disposed) return;
    unawaited(
      _enqueue(op).catchError((Object e) {
        _log.warning('receive operation failed: ${e.runtimeType}');
      }),
    );
  }

  void _set(ReceiveState next, ReceiveCause cause) {
    final prev = _state;
    if (prev == next) return;
    _state = next;
    if (_disposed) return;
    if (!_states.isClosed) _states.add(next);
    if (!_events.isClosed) _events.add(StateChanged(prev, next, cause));
  }

  void _emit(ReceiveEvent e) {
    if (!_disposed && !_events.isClosed) _events.add(e);
  }

  AnnouncePolicy _policyFor(ReceiveVisibility v) => switch (v) {
    ReceiveVisibility.everyone => AnnouncePolicy.periodic,
    ReceiveVisibility.contacts => AnnouncePolicy.replyToTrusted,
  };

  // ------------------------------------------------------------- windows

  void _cancelWindow() {
    _windowGen++;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _warnTimer?.cancel();
    _warnTimer = null;
  }

  void _cancelDrain() {
    _drainTimer?.cancel();
    _drainTimer = null;
    unawaited(_activeSub?.cancel());
    _activeSub = null;
  }

  /// Arms the expiry (and T-15 min warning) timers for [mode], clamped by the
  /// platform cap. [remaining] replaces the window (crash recovery).
  void _armWindow(ReceiveMode mode, {Duration? remaining}) {
    _cancelWindow();
    var window =
        remaining ??
        switch (mode) {
          ReceiveFor(:final duration) => duration,
          ReceiveAlways() || ReceiveOff() => null,
        };
    final cap = _caps.maxContinuous;
    if (cap != null && (window == null || window > cap)) window = cap;
    if (window == null) {
      _until = null;
      return;
    }
    if (window <= Duration.zero) window = Duration.zero;
    final gen = _windowGen;
    _until = _clock.now().add(window);
    _expiryTimer = _scheduler.once(window, () {
      if (gen == _windowGen) _background(_expire);
    });
    if (window > expiryWarning) {
      _warnTimer = _scheduler.once(window - expiryWarning, () {
        if (gen == _windowGen && _state is On) {
          _emit(ExpiringSoon(expiryWarning));
        }
      });
    }
  }

  // ----------------------------------------------------------- transitions

  Future<void> _turnOn(
    ReceiveMode mode,
    ReceiveCause cause, {
    Duration? remaining,
  }) async {
    if (mode is ReceiveOff) {
      await _turnOff(ReceiveCause.turnOff);
      return;
    }
    _mode = mode;
    final visibility = _settings.visibility;
    switch (_state) {
      case On(:final since):
        _armWindow(mode, remaining: remaining);
        _set(On(since, _until, visibility), cause);
        await _persist();
        return;
      case Draining():
        _cancelDrain();
        _gate.setAcceptingSessions(true);
        _gate.setAnnounce(_policyFor(visibility));
        _armWindow(mode, remaining: remaining);
        _since ??= _clock.now();
        _set(On(_since!, _until, visibility), cause);
        await _persist();
        return;
      case Starting():
        return;
      case Off() || Paused() || Failed():
        break;
    }

    _set(const Starting(), cause);
    try {
      await _gate.openListener();
    } on Object catch (e) {
      _cancelWindow();
      _gate.setAnnounce(AnnouncePolicy.none);
      _until = null;
      _set(Failed(e), ReceiveCause.bindFailed);
      await _persist();
      return;
    }
    _gate.setAcceptingSessions(true);
    _gate.setAnnounce(_policyFor(visibility));
    _since = _clock.now();
    _armWindow(mode, remaining: remaining);
    _set(On(_since!, _until, visibility), cause);
    await _persist();
  }

  Future<void> _turnOff(ReceiveCause cause) async {
    final s = _state;
    if (s is Off) {
      if (s.reason == OffReason.neverEnabled) {
        _set(const Off(OffReason.user), cause);
        await _persist();
      }
      return;
    }
    _cancelWindow();
    _cancelDrain();
    _gate.setAnnounce(AnnouncePolicy.none);
    if (s is On || s is Draining) {
      await _closeListener(graceful: _gate.activeSessions == 0);
    }
    _gate.setAcceptingSessions(true);
    _until = null;
    _set(const Off(OffReason.user), cause);
    await _persist();
  }

  /// The window ended (expiry timer).
  Future<void> _expire() async {
    final s = _state;
    if (s is Paused && _envCauses.contains(s.reason)) {
      // Waiting for the network/battery/permission when the window ended: it
      // will not come back by itself.
      _cancelWindow();
      _until = null;
      _set(const Off(OffReason.expired), ReceiveCause.expired);
      await _persist();
      return;
    }
    if (s is! On) return;
    _cancelWindow();
    _gate.setAnnounce(AnnouncePolicy.none);
    final active = _gate.activeSessions;
    if (active == 0) {
      await _closeListener(graceful: true);
      _until = null;
      _set(const Off(OffReason.expired), ReceiveCause.expired);
      await _persist();
      return;
    }

    // Transfers in flight: stop taking new ones and let these finish.
    _gate.setAcceptingSessions(false);
    final now = _clock.now();
    var wait = drainGrace;
    final os = _caps.osTimeout;
    final since = _since;
    if (os != null && since != null) {
      final hardStop = since.add(os).subtract(_caps.hardStopMargin);
      final room = hardStop.difference(now);
      if (room < wait) wait = room > Duration.zero ? room : Duration.zero;
    }
    _set(Draining(now.add(wait)), ReceiveCause.expired);
    _emit(ExpiredWhileBusy(active));
    _drainTimer = _scheduler.once(
      wait,
      () => _background(() => _finishDrain(forced: true)),
    );
    _activeSub = _gate.activeSessionCount.listen((n) {
      if (n == 0) _background(() => _finishDrain(forced: false));
    });
    await _persist();
  }

  Future<void> _finishDrain({required bool forced}) async {
    if (_state is! Draining) return;
    _cancelDrain();
    await _closeListener(graceful: !forced && _gate.activeSessions == 0);
    _gate.setAcceptingSessions(true);
    _until = null;
    _set(
      const Off(OffReason.expired),
      forced ? ReceiveCause.drainTimeout : ReceiveCause.drained,
    );
    await _persist();
  }

  Future<void> _pause(PauseReason reason, ReceiveCause cause) async {
    _gate.setAnnounce(AnnouncePolicy.none);
    await _closeListener(graceful: false);
    _gate.setAcceptingSessions(true);
    _set(Paused(reason), cause);
    await _persist();
  }

  Future<void> _closeListener({required bool graceful}) async {
    try {
      await _gate.closeListener(graceful: graceful);
    } on Object catch (e) {
      _log.warning('closing the listener failed: ${e.runtimeType}');
    }
  }

  // --------------------------------------------------------- environment

  static const Set<PauseReason> _envReasons = {
    PauseReason.noNetwork,
    PauseReason.batteryLow,
    PauseReason.permissionMissing,
  };

  Future<void> _onEnv(EnvEvent e) async {
    switch (e) {
      case NetworkDown():
        await _envDown(PauseReason.noNetwork, ReceiveCause.network);
      case NetworkUp():
        await _envUp(PauseReason.noNetwork, ReceiveCause.network);
      case BatteryLow():
        await _envDown(PauseReason.batteryLow, ReceiveCause.battery);
      case BatteryOk():
        await _envUp(PauseReason.batteryLow, ReceiveCause.battery);
      case PermissionLost():
        await _envDown(PauseReason.permissionMissing, ReceiveCause.permission);
      case PermissionGranted():
        await _envUp(PauseReason.permissionMissing, ReceiveCause.permission);
      case ScreenOn() || ScreenOff():
        break;
    }
  }

  Future<void> _envDown(PauseReason reason, ReceiveCause cause) async {
    _envCauses.add(reason);
    final s = _state;
    if (s is On) {
      // The window keeps running while paused.
      await _pause(reason, cause);
    } else if (s is Paused &&
        _envReasons.contains(s.reason) &&
        s.reason != reason) {
      // Several causes at once: the newest one is shown.
      _set(Paused(reason), cause);
      await _persist();
    }
  }

  Future<void> _envUp(PauseReason reason, ReceiveCause cause) async {
    _envCauses.remove(reason);
    final s = _state;
    if (s is! Paused || !_envReasons.contains(s.reason)) return;
    if (_envCauses.isNotEmpty) {
      _set(Paused(_envCauses.last), cause);
      await _persist();
      return;
    }
    // The window is still running (an expired one would be Off by now).
    _set(const Starting(), cause);
    try {
      await _gate.openListener();
    } on Object catch (e) {
      _cancelWindow();
      _until = null;
      _set(Failed(e), ReceiveCause.bindFailed);
      await _persist();
      return;
    }
    _gate.setAcceptingSessions(true);
    _gate.setAnnounce(_policyFor(_settings.visibility));
    _since ??= _clock.now();
    _set(On(_since!, _until, _settings.visibility), cause);
    await _persist();
  }

  // ---------------------------------------------------------- persistence

  Future<void> _restore(ExitHint hint) async {
    final data = await _store.load();
    _settings = data.settings;
    final rt = data.runtime;
    _mode = rt.mode;
    final now = _clock.now();

    switch (rt.state) {
      case ReceiveRuntimeState.off:
        _set(Off(rt.offReason), ReceiveCause.restore);
        return;
      case ReceiveRuntimeState.on:
      case ReceiveRuntimeState.paused:
        break;
    }

    if (rt.cleanStop || hint == ExitHint.userStopped) {
      _set(const Off(OffReason.user), ReceiveCause.restore);
      await _persist();
      return;
    }
    final until = rt.until;
    if (until != null && !until.isAfter(now)) {
      _set(const Off(OffReason.expired), ReceiveCause.restore);
      await _persist();
      return;
    }
    if (!_caps.resumeAfterCrash) {
      _until = until;
      _set(const Paused(PauseReason.osStopped), ReceiveCause.restore);
      await _persist();
      return;
    }
    final mode = rt.mode ?? _settings.defaultMode;
    await _turnOn(
      mode,
      ReceiveCause.restore,
      remaining: until?.difference(now),
    );
  }

  Future<void> _persist({bool? cleanStop}) async {
    final s = _state;
    final ReceiveRuntime runtime;
    switch (s) {
      case Starting():
        return;
      case On() || Draining():
        runtime = ReceiveRuntime(
          state: ReceiveRuntimeState.on,
          mode: _mode,
          until: _until,
          cleanStop: cleanStop ?? false,
        );
      case Paused(:final reason):
        runtime = ReceiveRuntime(
          state: ReceiveRuntimeState.paused,
          pauseReason: reason,
          mode: _mode,
          until: _until,
          cleanStop: cleanStop ?? false,
        );
      case Off(:final reason):
        runtime = ReceiveRuntime(offReason: reason, mode: _mode);
      case Failed():
        runtime = ReceiveRuntime(offReason: OffReason.user, mode: _mode);
    }
    try {
      await _store.save(
        ReceivePersisted(settings: _settings, runtime: runtime),
      );
    } on Object catch (e) {
      _log.warning('saving receive settings failed: ${e.runtimeType}');
    }
  }
}
