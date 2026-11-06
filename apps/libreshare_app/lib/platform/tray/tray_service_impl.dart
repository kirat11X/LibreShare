/// System-tray service (design 01 section 2.2).
///
/// The tray is progressive enhancement: it is only reported as available once
/// the icon was really created on a desktop that has a host for it
/// ([TrayHostProbe]). Everything native sits behind [TrayDriver]
/// (`native_tray_driver.dart` is the `tray_manager` adapter), so this class is
/// plain Dart and unit-tested with a fake driver. **No method throws**: a
/// missing native library, a missing D-Bus host or a failing menu update is
/// logged and turns into "tray unavailable".
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform_log.dart';
import '../platform_services.dart';
import 'linux_tray_host_probe.dart';

/// Bundled icon assets (pubspec `flutter: assets:`).
const String kTrayIconIdleAsset = 'assets/tray/tray_idle.png';
const String kTrayIconActiveAsset = 'assets/tray/tray_active.png';

/// What the tray shows for one receive state. Pure data, golden-tested.
@immutable
class TrayMenuModel {
  const TrayMenuModel({required this.receiving, required this.tooltip});

  final bool receiving;

  /// e.g. "Receiving - visible to everyone".
  final String tooltip;

  static const String openLabel = 'Open LibreShare';
  static const String quitLabel = 'Quit';

  String get toggleLabel => receiving ? 'Turn Receive off' : 'Turn Receive on';

  /// First (disabled) menu line.
  String get statusLabel => tooltip.isNotEmpty
      ? tooltip
      : (receiving ? 'Receiving' : 'Not receiving');

  String get iconAsset => receiving ? kTrayIconActiveAsset : kTrayIconIdleAsset;

  @override
  bool operator ==(Object other) =>
      other is TrayMenuModel &&
      other.receiving == receiving &&
      other.tooltip == tooltip;

  @override
  int get hashCode => Object.hash(receiving, tooltip);
}

/// Callbacks the menu fires.
class TrayCallbacks {
  const TrayCallbacks({
    required this.onOpen,
    required this.onToggleReceive,
    required this.onQuit,
  });

  final void Function() onOpen;
  final void Function() onToggleReceive;
  final void Function() onQuit;
}

/// The native tray icon + menu. Methods may throw; [TrayServiceImpl] catches.
abstract interface class TrayDriver {
  /// The native side can show a tray icon at all (plugin library present).
  bool get isSupported;

  /// Shows the icon with the menu: status line (disabled), separator, Open,
  /// Receive toggle, separator, Quit.
  Future<void> create(TrayMenuModel model, TrayCallbacks callbacks);

  /// Updates tooltip, status line, toggle label and icon in place.
  Future<void> update(TrayMenuModel model);

  /// Removes the icon and frees the native handles. Safe to call twice.
  Future<void> destroy();
}

class TrayServiceImpl implements TrayService {
  /// [pollInterval] (`null` = never) is how often the host probe is re-run when
  /// it [TrayHostProbe.needsPolling]; tests call [checkHostNow] by hand.
  TrayServiceImpl({
    required this._driver,
    required this._probe,
    this.pollInterval = const Duration(seconds: 10),
  });

  static const PlatformLog _log = PlatformLog('tray');

  final TrayDriver _driver;
  final TrayHostProbe _probe;
  final Duration? pollInterval;

  final StreamController<bool> _availability =
      StreamController<bool>.broadcast();
  TrayCallbacks? _callbacks;
  TrayMenuModel _model = const TrayMenuModel(receiving: false, tooltip: '');
  bool _available = false;
  bool _initialized = false;
  bool _disposed = false;
  Timer? _timer;
  Future<void> _tail = Future<void>.value();

  @override
  bool get isAvailable => _available;

  /// Emits whenever [isAvailable] flips (a GNOME extension was enabled after
  /// start-up, or the shell restarted). [WindowControllerImpl] listens so the
  /// close button switches between hide-to-tray and minimize.
  Stream<bool> get availabilityChanges => _availability.stream;

  @override
  Future<void> init({
    required void Function() onOpen,
    required void Function() onToggleReceive,
    required void Function() onQuit,
  }) async {
    if (_disposed || _initialized) return;
    _initialized = true;
    _callbacks = TrayCallbacks(
      onOpen: () => _guard('open', onOpen),
      onToggleReceive: () => _guard('toggle receive', onToggleReceive),
      onQuit: () => _guard('quit', onQuit),
    );
    bool supported;
    try {
      supported = _driver.isSupported;
    } on Object catch (e) {
      _log.info('tray plugin not usable here', e);
      supported = false;
    }
    if (!supported) {
      _log.info('tray unsupported on this platform; close will minimize');
      return;
    }
    await checkHostNow();
    final period = pollInterval;
    if (_probe.needsPolling && period != null && !_disposed) {
      _timer = Timer.periodic(period, (_) => unawaited(checkHostNow()));
    }
  }

  /// Re-runs the host probe and creates / removes the icon accordingly.
  @visibleForTesting
  Future<void> checkHostNow() {
    final next = _tail.then((_) async {
      if (_disposed || !_initialized || _callbacks == null) return;
      final present = await _probe.isHostPresent();
      if (_disposed) return;
      if (present && !_available) {
        await _show();
      } else if (!present && _available) {
        _log.info('tray host disappeared');
        await _hide();
      }
    });
    _tail = next.catchError((Object e) {
      _log.warning('tray host check failed', e);
    });
    return _tail;
  }

  Future<void> _show() async {
    try {
      await _driver.create(_model, _callbacks!);
      _setAvailable(true);
      _log.info('tray icon shown');
    } on Object catch (e) {
      _log.warning('cannot create the tray icon', e);
      await _destroyQuietly();
      _setAvailable(false);
    }
  }

  Future<void> _hide() async {
    await _destroyQuietly();
    _setAvailable(false);
  }

  Future<void> _destroyQuietly() async {
    try {
      await _driver.destroy();
    } on Object catch (e) {
      _log.fine('tray destroy failed', e);
    }
  }

  void _setAvailable(bool value) {
    if (_available == value) return;
    _available = value;
    if (!_availability.isClosed) _availability.add(value);
  }

  @override
  Future<void> setStatus({
    required bool receiving,
    required String tooltip,
  }) async {
    final model = TrayMenuModel(receiving: receiving, tooltip: tooltip);
    if (model == _model) return;
    _model = model;
    if (!_available || _disposed) return;
    final next = _tail.then((_) async {
      if (!_available || _disposed) return;
      try {
        await _driver.update(_model);
      } on Object catch (e) {
        _log.warning('cannot update the tray', e);
      }
    });
    _tail = next.catchError((Object _) {});
    await _tail;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _tail;
    await _destroyQuietly();
    _available = false;
    try {
      await _probe.dispose();
    } on Object catch (e) {
      _log.fine('probe dispose failed', e);
    }
    await _availability.close();
  }

  void _guard(String what, void Function() action) {
    try {
      action();
    } on Object catch (e) {
      _log.warning('tray "$what" handler threw', e);
    }
  }
}
