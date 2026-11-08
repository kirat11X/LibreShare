import 'dart:async';
import 'dart:typed_data';

import '../clock.dart';
import 'beacon_codec.dart';

enum VisibilityMode { hidden, contacts, everyone }

class VisibilityState {
  const VisibilityState({
    required this.mode,
    required this.activeEid,
    this.everyoneExpiresAt,
  });

  final VisibilityMode mode;
  final Uint8List? activeEid;
  final DateTime? everyoneExpiresAt;

  bool get isAdvertising => mode != VisibilityMode.hidden;
}

/// Manages BLE advertising visibility modes and the 10-minute Everyone time-box.
class VisibilityManager {
  VisibilityManager({
    required this.advKey,
    this.clock = const SystemClock(),
    this.everyoneDuration = const Duration(minutes: 10),
  }) {
    if (advKey.length != 32) {
      throw ArgumentError.value(
        advKey.length,
        'advKey',
        'advKey must be 32 bytes',
      );
    }
  }

  final Uint8List advKey;
  final Clock clock;
  final Duration everyoneDuration;

  VisibilityMode _mode = VisibilityMode.hidden;
  Uint8List? _activeEid;
  DateTime? _everyoneExpiresAt;
  Timer? _everyoneTimer;
  Timer? _epochTimer;

  final StreamController<VisibilityState> _controller =
      StreamController<VisibilityState>.broadcast();

  VisibilityState get currentState => VisibilityState(
    mode: _mode,
    activeEid: _activeEid != null ? Uint8List.fromList(_activeEid!) : null,
    everyoneExpiresAt: _everyoneExpiresAt,
  );

  Stream<VisibilityState> get stateChanges => _controller.stream;

  /// Sets visibility to Hidden (BLE advertising disabled).
  void setHidden() {
    _mode = VisibilityMode.hidden;
    _activeEid = null;
    _everyoneExpiresAt = null;
    _cancelTimers();
    _notify();
  }

  /// Sets visibility to Contacts (only trusted peers with our advKey can resolve our EID).
  void setContacts() {
    _mode = VisibilityMode.contacts;
    _everyoneExpiresAt = null;
    _everyoneTimer?.cancel();
    _everyoneTimer = null;
    _updateRotatingEid();
    _armEpochTimer();
    _notify();
  }

  /// Sets visibility to Everyone for a strictly time-boxed window (default 10 minutes).
  void setEveryone({Duration? duration}) {
    _mode = VisibilityMode.everyone;
    final dur = duration ?? everyoneDuration;
    final now = clock.now();
    _everyoneExpiresAt = now.add(dur);
    _activeEid = generateRandomEid();

    _everyoneTimer?.cancel();
    _everyoneTimer = Timer(dur, _onEveryoneExpired);

    _armEpochTimer();
    _notify();
  }

  void _onEveryoneExpired() {
    if (_mode == VisibilityMode.everyone) {
      // Revert to contacts mode upon expiration
      setContacts();
    }
  }

  void _updateRotatingEid() {
    if (_mode == VisibilityMode.contacts) {
      _activeEid = generateEidForTime(advKey, clock.now());
    } else if (_mode == VisibilityMode.everyone) {
      _activeEid = generateRandomEid();
    }
  }

  void _armEpochTimer() {
    _epochTimer?.cancel();
    final now = clock.now();
    final currentEpoch = epochForTime(now);
    final nextEpochSeconds = (currentEpoch + 1) * kEidEpochSeconds;
    final nextEpochTime = DateTime.fromMillisecondsSinceEpoch(
      nextEpochSeconds * 1000,
      isUtc: true,
    );
    final delay = nextEpochTime.difference(now.toUtc());
    _epochTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (_mode != VisibilityMode.hidden) {
        _updateRotatingEid();
        _notify();
        _armEpochTimer();
      }
    });
  }

  void _cancelTimers() {
    _everyoneTimer?.cancel();
    _everyoneTimer = null;
    _epochTimer?.cancel();
    _epochTimer = null;
  }

  void _notify() {
    _controller.add(currentState);
  }

  /// Disposes timers and streams.
  void dispose() {
    _cancelTimers();
    _controller.close();
  }
}
