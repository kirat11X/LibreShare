/// [PlatformEnvironment] that needs no plugin: it polls the interface list.
///
/// Emits [NetworkUp] / [NetworkDown] when "is there a usable IPv4 address on a
/// non-loopback, non-virtual interface" flips, plus the initial state once the
/// first listener attaches. Works on every OS `dart:io` runs on.
///
/// Heuristics, deliberately simple: an interface counts as virtual (and is
/// ignored) when its name starts with one of [virtualInterfacePrefixes]
/// (Docker/libvirt/VMware/VirtualBox bridges, Hyper-V `vEthernet`), because a
/// laptop with Docker installed would otherwise never report "down". Link-local
/// (169.254/16) addresses are ignored too: they mean "DHCP failed".
///
/// TODO(Inc 3): Android battery / screen / permission events ([BatteryLow],
/// [ScreenOff], [PermissionLost] ...) need a Kotlin `EventChannel`; Increment 2
/// is foreground-only on Android so none are emitted here.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../platform_log.dart';
import '../platform_services.dart';

/// Lists the local interfaces; [SystemNetworkInterfaceProvider] in production.
typedef NetworkProbe = Future<bool> Function();

class PollingNetworkEnvironment implements PlatformEnvironment {
  /// [probe] answers "is a network available" (override in tests);
  /// [interval] is the poll period, `null` disables the timer so tests can
  /// call [pollOnce] by hand.
  PollingNetworkEnvironment({
    this.interval = const Duration(seconds: 4),
    NetworkProbe? probe,
    NetworkInterfaceProvider provider = const SystemNetworkInterfaceProvider(),
  }) : _probe = probe ?? (() => _hasUsableInterface(provider)) {
    _controller = StreamController<EnvEvent>.broadcast(
      onListen: _onListen,
      onCancel: _onCancel,
    );
  }

  static const PlatformLog _log = PlatformLog('network');

  /// Interface-name prefixes (lower case) that never carry LAN peers.
  static const List<String> virtualInterfacePrefixes = [
    'docker',
    'br-',
    'veth',
    'virbr',
    'vmnet',
    'vboxnet',
    'vethernet',
  ];

  final Duration? interval;
  final NetworkProbe _probe;
  late final StreamController<EnvEvent> _controller;
  Timer? _timer;
  bool? _up;
  bool _polling = false;
  bool _disposed = false;

  /// Last observed state; `null` before the first successful poll.
  bool? get isUp => _up;

  @override
  Stream<EnvEvent> get events => _controller.stream;

  void _onListen() {
    // Initial state first (so a device that boots offline pauses Receive), then
    // periodic checks.
    unawaited(pollOnce());
    final period = interval;
    if (period != null) {
      _timer = Timer.periodic(period, (_) => unawaited(pollOnce()));
    }
  }

  void _onCancel() {
    _timer?.cancel();
    _timer = null;
    // Forget the state: the next listener gets a fresh initial event.
    _up = null;
  }

  /// One poll; emits an event only when the state changed (or on the first
  /// poll after a listener attached). Never throws.
  @visibleForTesting
  Future<void> pollOnce() async {
    if (_disposed || _polling || !_controller.hasListener) return;
    _polling = true;
    try {
      final up = await _probe();
      if (_disposed || !_controller.hasListener) return;
      if (up != _up) {
        final first = _up == null;
        _up = up;
        _log.fine('network ${up ? 'up' : 'down'}${first ? ' (initial)' : ''}');
        _controller.add(up ? const NetworkUp() : const NetworkDown());
      }
    } on Object catch (e) {
      // Keep the previous state: a transient enumeration error must not pause
      // Receive.
      _log.warning('interface enumeration failed', e);
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }

  static Future<bool> _hasUsableInterface(
    NetworkInterfaceProvider provider,
  ) async {
    final interfaces = await provider.list();
    return interfaces.any(
      (i) => !isVirtualInterface(i.name) && !_isLinkLocal(i.address),
    );
  }

  /// Whether [name] looks like a loopback or virtual/bridge interface (see
  /// class doc).
  @visibleForTesting
  static bool isVirtualInterface(String name) {
    final n = name.toLowerCase();
    // Loopback is `lo` (Linux) or `lo0` (BSD/macOS), not any name starting "lo".
    if (n == 'lo' || RegExp(r'^lo\d+$').hasMatch(n)) return true;
    return virtualInterfacePrefixes.any(n.startsWith);
  }

  static bool _isLinkLocal(InternetAddress a) => a.isLinkLocal;
}
