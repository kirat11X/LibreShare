/// Window show/hide, close-to-tray and `--hidden` start (design 01 sections
/// 2.2 and 3).
///
/// Policy:
/// * `--hidden` start: the native runner never maps the window (see
///   `linux/runner/my_application.cc`, `windows/runner/flutter_window.cpp`), so
///   there is no flash. With a tray the window stays hidden; without one it is
///   shown *minimized* so the app stays reachable from the dash / taskbar.
/// * Close button: with a tray, hide to tray; without one, minimize. If the app
///   decides nothing needs to keep running ([keepRunningOnClose] returns
///   `false`, e.g. Receive is Off and no transfer is active) the close goes
///   through and the app exits.
/// * [quit] really closes (tray "Quit", app menu).
///
/// Everything native sits behind [WindowBackend] (`native_window_backend.dart`
/// is the `window_manager` adapter). **No method throws**: with the native side
/// missing the controller degrades to a no-op.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../autostart/autostart_common.dart';
import '../platform_log.dart';
import '../platform_services.dart';

/// `true` when the process was started with `--hidden` (autostart entry). Pass
/// the `main(List<String> args)` arguments: Flutter desktop runners forward the
/// command line there ([Platform.executableArguments] holds VM flags only).
bool startHidden(List<String> args) => args.contains(kHiddenFlag);

/// `true` for the Windows uninstaller's `libreshare.exe --remove-autostart`.
bool wantsRemoveAutostart(List<String> args) =>
    args.contains(kRemoveAutostartFlag);

/// The app's one native window.
abstract interface class WindowBackend {
  /// Binds to the window; `false` when there is none / the plugin is missing.
  bool attach();

  bool get isVisible;

  /// Maps the window, restores it from minimized and focuses it.
  void show();
  void hide();
  void minimize();

  /// Asks the window to close (goes through [onCloseRequested]); `false` if it
  /// could not.
  bool close();

  /// Called when the user (or `close()`) requests a close; return `true` to
  /// veto it.
  set onCloseRequested(bool Function()? handler);

  void dispose();
}

class WindowControllerImpl implements WindowController {
  /// [trayAvailability] (e.g. `TrayServiceImpl.availabilityChanges`) keeps the
  /// close behaviour in step with a tray that appears or vanishes later.
  /// [exitProcess] is injectable for tests.
  WindowControllerImpl({
    required this._backend,
    this._trayAvailability,
    void Function(int code)? exitProcess,
  }) : _exit = exitProcess ?? exit;

  static const PlatformLog _log = PlatformLog('window');

  final WindowBackend _backend;
  final Stream<bool>? _trayAvailability;
  final void Function(int) _exit;
  StreamSubscription<bool>? _traySub;
  bool _attached = false;
  bool _hasTray = false;
  bool _quitting = false;

  /// Consulted on every close request; `null` or `true` keeps the app running
  /// in the background. The app wires this to "Receive is on or a transfer is
  /// active" so that closing an idle app exits instead of hiding forever.
  bool Function()? keepRunningOnClose;

  /// Whether the native window could be bound (false in tests, on Android).
  @visibleForTesting
  bool get isAttached => _attached;

  @override
  Future<void> init({required bool startHidden, required bool hasTray}) async {
    _hasTray = hasTray;
    try {
      _attached = _backend.attach();
    } on Object catch (e) {
      _log.info('native window unavailable; window control disabled', e);
      _attached = false;
    }
    if (!_attached) return;
    _backend.onCloseRequested = _onCloseRequested;
    _traySub ??= _trayAvailability?.listen(_onTrayAvailability);
    if (!startHidden) return; // The runner shows the window on the first frame.
    _run('start hidden', () {
      if (hasTray) {
        _backend.hide();
      } else {
        // Nothing to click to bring the window back: start minimized instead.
        _backend.show();
        _backend.minimize();
      }
    });
  }

  @override
  Future<void> show() async {
    if (!_attached) return;
    _run('show', _backend.show);
  }

  @override
  Future<void> hide() async {
    if (!_attached) return;
    _run('hide', _backend.hide);
  }

  /// Closes for real (tray "Quit"). Falls back to ending the process when the
  /// native window cannot be closed.
  Future<void> quit() async {
    _quitting = true;
    var closed = false;
    if (_attached) {
      try {
        closed = _backend.close();
      } on Object catch (e) {
        _log.warning('window close failed', e);
      }
    }
    if (!closed) _exit(0);
  }

  Future<void> dispose() async {
    await _traySub?.cancel();
    _traySub = null;
    if (_attached) {
      try {
        _backend.onCloseRequested = null;
        _backend.dispose();
      } on Object catch (e) {
        _log.fine('window backend dispose failed', e);
      }
    }
    _attached = false;
  }

  bool _onCloseRequested() {
    try {
      if (_quitting) return false;
      if (!(keepRunningOnClose?.call() ?? true)) return false;
      if (_hasTray) {
        _backend.hide();
      } else {
        _backend.minimize();
      }
      return true;
    } on Object catch (e) {
      // If our handler fails, do not trap the user: let the close through.
      _log.warning('close handler failed', e);
      return false;
    }
  }

  void _onTrayAvailability(bool available) {
    _hasTray = available;
    if (!available && _attached) {
      // The icon is gone; a hidden window would be unreachable.
      _run('reveal window', () {
        if (!_backend.isVisible) _backend.show();
      });
    }
  }

  void _run(String what, void Function() action) {
    try {
      action();
    } on Object catch (e) {
      _log.warning('window "$what" failed', e);
    }
  }
}
