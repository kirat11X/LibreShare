/// Picks the platform adapters for this OS. The UI never imports a concrete
/// adapter; `main.dart` calls [createPlatformServices] once and injects the
/// result (Riverpod override / constructor).
///
/// Construction has **no side effects** (no D-Bus connection, no native call, no
/// file access): everything is lazy, so creating the services in a widget test
/// on a developer machine touches nothing. Use [startPlatformShell] for the
/// start-up sequence (autostart self-heal, tray, window).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'android/multicast_lock_android.dart';
import 'autostart/autostart_common.dart';
import 'autostart/autostart_linux.dart';
import 'autostart/autostart_none.dart';
import 'autostart/autostart_windows.dart';
import 'autostart/registry_access_win32.dart';
import 'bonsoir_mdns_backend.dart';
import 'environment/polling_network_environment.dart';
import 'noop_platform.dart';
import 'platform_log.dart';
import 'platform_services.dart';
import 'tray/linux_tray_host_probe.dart';
import 'tray/native_tray_driver.dart';
import 'tray/tray_service_impl.dart';
import 'window/native_window_backend.dart';
import 'window/window_controller_impl.dart';

export 'autostart/autostart_common.dart'
    show kHiddenFlag, kRemoveAutostartFlag, AutostartException;
export 'window/window_controller_impl.dart'
    show startHidden, wantsRemoveAutostart, WindowControllerImpl;

const PlatformLog _log = PlatformLog('factory');

/// Android receive window cap (design 01 section 4.3: default 6 h, never
/// "Always"). Without the Increment 3 foreground service the app only receives
/// while it is open anyway.
const Duration kAndroidMaxContinuous = Duration(hours: 6);

enum PlatformKind { linux, windows, android, other }

PlatformKind currentPlatformKind() {
  if (Platform.isLinux) return PlatformKind.linux;
  if (Platform.isWindows) return PlatformKind.windows;
  if (Platform.isAndroid) return PlatformKind.android;
  return PlatformKind.other;
}

/// Real adapters for the OS the app runs on.
///
/// [args] is `main`'s argument list; it is accepted so callers pass it once,
/// but no adapter reads it at construction time - `--hidden` is applied by
/// [startPlatformShell] / `window.init(startHidden: startHidden(args), ...)`.
/// Never throws: on an unexpected error it logs and returns no-op services.
PlatformServices createPlatformServices({List<String> args = const []}) {
  try {
    return createPlatformServicesFor(currentPlatformKind());
  } on Object catch (e) {
    _log.severe('platform adapters unavailable; using no-ops', e);
    return PlatformServices.fake();
  }
}

/// [createPlatformServices] for an explicit OS (so the choice is testable on
/// any machine).
@visibleForTesting
PlatformServices createPlatformServicesFor(PlatformKind kind) {
  switch (kind) {
    case PlatformKind.linux:
    case PlatformKind.windows:
      final isLinux = kind == PlatformKind.linux;
      final tray = TrayServiceImpl(
        driver: NativeTrayDriver(),
        probe: isLinux ? LinuxTrayHostProbe() : const AlwaysPresentTrayHost(),
      );
      return PlatformServices(
        autostart: isLinux
            ? LinuxAutostart()
            : WindowsAutostart(registry: const Win32RegistryAccess()),
        tray: tray,
        window: WindowControllerImpl(
          backend: NativeWindowBackend(),
          trayAvailability: tray.availabilityChanges,
        ),
        multicastLock: const NoopMulticastLock(),
        environment: PollingNetworkEnvironment(),
        mdns: BonsoirMdnsBackend(),
        caps: const ReceivePlatformCaps(),
      );
    case PlatformKind.android:
      return PlatformServices(
        autostart: const NoAutostart(),
        tray: const NoopTrayService(),
        window: const NoopWindowController(),
        multicastLock: AndroidMulticastLock(),
        environment: PollingNetworkEnvironment(),
        mdns: BonsoirMdnsBackend(),
        // Foreground-only in Increment 2; a killed process comes back as
        // Paused(osStopped) and waits for a tap (design 01 section 4.3).
        caps: const ReceivePlatformCaps(
          maxContinuous: kAndroidMaxContinuous,
          resumeAfterCrash: false,
        ),
      );
    case PlatformKind.other:
      // macOS / unsupported: no tray, autostart or window control, but mDNS and
      // the interface poll are plain Dart/plugin and work.
      return PlatformServices(
        autostart: const NoAutostart(),
        tray: const NoopTrayService(),
        window: const NoopWindowController(),
        multicastLock: const NoopMulticastLock(),
        environment: PollingNetworkEnvironment(),
        mdns: BonsoirMdnsBackend(),
      );
  }
}

/// Handles one-shot launch commands. Returns `true` when `main` must exit now
/// without starting the UI (currently `--remove-autostart`, which the Windows
/// uninstaller runs).
Future<bool> runLaunchCommands(
  PlatformServices services,
  List<String> args,
) async {
  if (!wantsRemoveAutostart(args)) return false;
  try {
    await services.autostart.setEnabled(false);
  } on Object catch (e) {
    _log.warning('--remove-autostart failed', e);
  }
  return true;
}

/// The standard desktop start-up order, in one place:
///
/// 1. repair a stale autostart entry (AppImage moved) - only if one exists;
/// 2. create the tray (it decides whether a tray host exists);
/// 3. initialise the window with `startHidden(args)` and the real tray state.
///
/// [onOpen] defaults to showing the window; [onToggleReceive] flips Receive;
/// [onQuit] should stop the engine and then call `WindowControllerImpl.quit()`
/// (or `exit(0)`). Never throws.
Future<void> startPlatformShell(
  PlatformServices services, {
  required List<String> args,
  required void Function() onToggleReceive,
  required void Function() onQuit,
  void Function()? onOpen,
}) async {
  try {
    final autostart = services.autostart;
    if (autostart is SelfHealingAutostart) {
      await (autostart as SelfHealingAutostart).selfHeal();
    }
  } on Object catch (e) {
    _log.warning('autostart self-heal failed', e);
  }
  await services.tray.init(
    onOpen: onOpen ?? () => unawaited(services.window.show()),
    onToggleReceive: onToggleReceive,
    onQuit: onQuit,
  );
  await services.window.init(
    startHidden: startHidden(args),
    hasTray: services.tray.isAvailable,
  );
}
