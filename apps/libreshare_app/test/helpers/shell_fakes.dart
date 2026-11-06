// Fakes for the desktop shell: a window backend that records what the app asks
// of the native window, a tray that remembers its callbacks, and OS adapters
// that fail on purpose. They plug into PlatformServices (the contracts stay the
// platform agent's; only fakes live here).
import 'package:libreshare_app/platform/autostart/autostart_common.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/platform/window/window_controller_impl.dart';

/// The native window as the real `WindowControllerImpl` sees it.
class RecordingWindowBackend implements WindowBackend {
  bool visible = true;
  final List<String> calls = [];
  bool Function()? _closeHandler;

  @override
  bool attach() {
    calls.add('attach');
    return true;
  }

  @override
  bool get isVisible => visible;

  @override
  void show() {
    calls.add('show');
    visible = true;
  }

  @override
  void hide() {
    calls.add('hide');
    visible = false;
  }

  @override
  void minimize() => calls.add('minimize');

  @override
  bool close() {
    calls.add('close');
    return !(_closeHandler?.call() ?? false);
  }

  @override
  set onCloseRequested(bool Function()? handler) => _closeHandler = handler;

  @override
  void dispose() {}

  /// The user presses the window's close button. `true` means the app vetoed
  /// it (hid or minimized instead); `false` means the window really closes.
  bool userClicksClose() => _closeHandler?.call() ?? false;

  /// Calls since the last [clear], without the initial attach.
  List<String> get actions => [
    for (final c in calls)
      if (c != 'attach') c,
  ];

  void clear() => calls.clear();
}

/// A tray that remembers what the app registered, so a test can press its
/// menu items.
class CapturingTray extends FakeTray {
  CapturingTray({super.available});

  void Function()? onOpen;
  void Function()? onToggleReceive;
  void Function()? onQuit;
  int initCalls = 0;
  bool disposed = false;

  @override
  Future<void> init({
    required void Function() onOpen,
    required void Function() onToggleReceive,
    required void Function() onQuit,
  }) async {
    initCalls++;
    this.onOpen = onOpen;
    this.onToggleReceive = onToggleReceive;
    this.onQuit = onQuit;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// Autostart whose writes fail like a read-only config dir or a registry
/// policy would.
class FailingAutostart implements AutostartService {
  FailingAutostart({this.enabled = false});

  bool enabled;
  int attempts = 0;

  @override
  bool get isSupported => true;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    attempts++;
    throw const AutostartException('cannot write the autostart entry');
  }
}

/// A MulticastLock that cannot be taken (no Wi-Fi permission, no WifiManager).
class FailingMulticastLock implements MulticastLockService {
  int acquireCalls = 0;
  int releaseCalls = 0;

  @override
  Future<void> acquire() async {
    acquireCalls++;
    throw StateError('no multicast lock');
  }

  @override
  Future<void> release() async => releaseCalls++;
}

/// Desktop-like services around a real [WindowControllerImpl] on [backend].
PlatformServices desktopShellServices({
  required RecordingWindowBackend backend,
  required CapturingTray tray,
  AutostartService? autostart,
  FakeMulticastLock? lock,
  void Function(int code)? exitProcess,
}) => PlatformServices(
  autostart: autostart ?? FakeAutostart(),
  tray: tray,
  window: WindowControllerImpl(backend: backend, exitProcess: exitProcess),
  multicastLock: lock ?? FakeMulticastLock(),
  environment: FakeEnvironment(),
);

/// All-fake services (like `PlatformServices.fake`) around any [autostart],
/// which `fake()` only accepts as a `FakeAutostart`.
PlatformServices servicesWithAutostart(AutostartService autostart) =>
    PlatformServices(
      autostart: autostart,
      tray: FakeTray(),
      window: FakeWindow(),
      multicastLock: FakeMulticastLock(),
      environment: FakeEnvironment(),
    );
