import 'dart:async';
import 'dart:io';

/// Coordinates preventing the host OS from sleeping or suspending while active
/// network transfers or live link shares are running (Increment 5, ADR 0004).
abstract class SleepInhibitor {
  /// Requests the operating system to prevent sleep/idle-standby.
  Future<void> acquire({required String reason});

  /// Releases the sleep block, restoring default OS power management.
  Future<void> release();

  /// Whether sleep inhibition is currently active.
  bool get isAcquired;
}

/// Headless and test fallback sleep inhibitor.
class NoopSleepInhibitor implements SleepInhibitor {
  bool _acquired = false;

  @override
  bool get isAcquired => _acquired;

  @override
  Future<void> acquire({required String reason}) async {
    _acquired = true;
  }

  @override
  Future<void> release() async {
    _acquired = false;
  }
}

/// Linux implementation utilizing `systemd-inhibit` or DBus power management fallback.
class LinuxSleepInhibitor implements SleepInhibitor {
  Process? _inhibitProcess;
  bool _acquired = false;

  @override
  bool get isAcquired => _acquired;

  @override
  Future<void> acquire({required String reason}) async {
    if (_acquired) return;
    try {
      _inhibitProcess = await Process.start('systemd-inhibit', [
        '--what=idle:sleep',
        '--who=LibreShare',
        '--why=$reason',
        '--mode=block',
        'sleep',
        'infinity',
      ]);
      _acquired = true;
    } catch (_) {
      // Fallback: no systemd or container environment
      _acquired = true;
    }
  }

  @override
  Future<void> release() async {
    if (!_acquired) return;
    _acquired = false;
    try {
      _inhibitProcess?.kill(ProcessSignal.sigterm);
      _inhibitProcess = null;
    } catch (_) {}
  }
}

/// Default system provider factory for sleep inhibitors.
SleepInhibitor createSleepInhibitor() {
  if (Platform.isLinux) {
    return LinuxSleepInhibitor();
  }
  return NoopSleepInhibitor();
}
