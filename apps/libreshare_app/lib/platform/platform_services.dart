/// Platform-adapter contracts (orchestrator-owned; spec §3 "PLAT"). The UI layer
/// depends only on these; real implementations live next to this file under
/// lib/platform/**, fakes below are for widget tests.
library;

import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';

/// Start-with-OS (design 01 §2/§3). Linux: XDG autostart .desktop; Windows: HKCU Run.
abstract interface class AutostartService {
  /// False on platforms without an implementation (e.g. Android, tests).
  bool get isSupported;
  Future<bool> isEnabled();
  Future<void> setEnabled(bool enabled);
}

/// System tray (design 01 §2). May be unavailable (GNOME without an AppIndicator host).
abstract interface class TrayService {
  bool get isAvailable;

  /// [onOpen] shows the window, [onToggleReceive] flips Receive on/off, [onQuit] exits.
  Future<void> init({
    required void Function() onOpen,
    required void Function() onToggleReceive,
    required void Function() onQuit,
  });

  /// Tooltip/menu text, e.g. "Receiving — visible to everyone".
  Future<void> setStatus({required bool receiving, required String tooltip});
  Future<void> dispose();
}

/// Window show/hide, close-to-tray and `--hidden` start.
abstract interface class WindowController {
  Future<void> init({required bool startHidden, required bool hasTray});
  Future<void> show();
  Future<void> hide();
}

/// Android WifiManager.MulticastLock (spec §15). No-op elsewhere.
abstract interface class MulticastLockService {
  Future<void> acquire();
  Future<void> release();
}

/// Network / battery / permission signals for ReceiveController (core `EnvEvent`).
abstract interface class PlatformEnvironment {
  Stream<EnvEvent> get events;
  Future<void> dispose();
}

/// Everything the app needs from the OS, bundled for dependency injection.
class PlatformServices {
  const PlatformServices({
    required this.autostart,
    required this.tray,
    required this.window,
    required this.multicastLock,
    required this.environment,
    this.mdns,
    this.caps = const ReceivePlatformCaps(),
  });

  final AutostartService autostart;
  final TrayService tray;
  final WindowController window;
  final MulticastLockService multicastLock;
  final PlatformEnvironment environment;

  /// bonsoir-backed mDNS, or null where unavailable.
  final MdnsBackend? mdns;

  /// Receive-window limits for this OS (Android: 6 h cap, desktop: unlimited).
  final ReceivePlatformCaps caps;

  /// All no-ops; used by tests and as the safe fallback.
  factory PlatformServices.fake({
    FakeAutostart? autostart,
    FakeTray? tray,
    FakeEnvironment? environment,
    MdnsBackend? mdns,
  }) => PlatformServices(
    autostart: autostart ?? FakeAutostart(),
    tray: tray ?? FakeTray(),
    window: FakeWindow(),
    multicastLock: FakeMulticastLock(),
    environment: environment ?? FakeEnvironment(),
    mdns: mdns,
  );
}

class FakeAutostart implements AutostartService {
  FakeAutostart({this.supported = true, this.enabled = false});
  final bool supported;
  bool enabled;
  @override
  bool get isSupported => supported;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> setEnabled(bool value) async => enabled = value;
}

class FakeTray implements TrayService {
  FakeTray({this.available = false});
  final bool available;
  String lastTooltip = '';
  bool lastReceiving = false;
  @override
  bool get isAvailable => available;
  @override
  Future<void> init({
    required void Function() onOpen,
    required void Function() onToggleReceive,
    required void Function() onQuit,
  }) async {}
  @override
  Future<void> setStatus({
    required bool receiving,
    required String tooltip,
  }) async {
    lastReceiving = receiving;
    lastTooltip = tooltip;
  }

  @override
  Future<void> dispose() async {}
}

class FakeWindow implements WindowController {
  bool visible = true;
  @override
  Future<void> init({required bool startHidden, required bool hasTray}) async =>
      visible = !startHidden;
  @override
  Future<void> show() async => visible = true;
  @override
  Future<void> hide() async => visible = false;
}

class FakeMulticastLock implements MulticastLockService {
  int held = 0;
  @override
  Future<void> acquire() async => held++;
  @override
  Future<void> release() async => held = held > 0 ? held - 1 : 0;
}

class FakeEnvironment implements PlatformEnvironment {
  final StreamController<EnvEvent> _c = StreamController<EnvEvent>.broadcast();
  void emit(EnvEvent e) => _c.add(e);
  @override
  Stream<EnvEvent> get events => _c.stream;
  @override
  Future<void> dispose() => _c.close();
}
