/// Glue between the Receive state and the desktop shell: tray icon, tooltip,
/// window visibility. Started once by the app root.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../platform/platform_factory.dart'
    show WindowControllerImpl, startHidden, startPlatformShell;
import 'engine_provider.dart';
import 'platform_providers.dart';
import 'receive_provider.dart';
import 'transfers_provider.dart';

/// Text for the tray tooltip and similar one-liners.
String receiveTooltip(ReceiveState s) => switch (s) {
  On(until: null) => tr('tray.receivingAlways'),
  On() => tr('tray.receiving'),
  Draining() => tr('tray.finishing'),
  Paused() => tr('tray.paused'),
  Starting() => tr('tray.starting'),
  Failed() => tr('tray.failed'),
  Off() => tr('tray.off'),
};

bool isReceivingState(ReceiveState s) => s is On || s is Draining;

class ShellBridge {
  ShellBridge(this._ref) {
    _ref.listen<ReceiveState>(
      receiveStatusProvider,
      (_, next) => unawaited(_syncTray(next)),
    );
  }

  final Ref _ref;
  bool _started = false;

  /// Runs the platform start-up sequence once (autostart self-heal, tray,
  /// window) and shows the first tray status.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final services = _ref.read(platformServicesProvider);
    // Closing the window keeps the app alive only while it has a job: Receive
    // is on or a transfer is running. An idle app exits on close.
    final window = services.window;
    if (window is WindowControllerImpl) {
      window.keepRunningOnClose = () =>
          isReceivingState(_ref.read(receiveStatusProvider)) ||
          _ref.read(transfersProvider).any((t) => t.isActive);
    }
    final args = _ref.read(launchArgsProvider);
    try {
      await startPlatformShell(
        services,
        args: args,
        onToggleReceive: () =>
            unawaited(_ref.read(receiveActionsProvider).toggle()),
        onQuit: () => unawaited(quit()),
      );
    } on Object {
      // The shell is a convenience: the app works without tray and window
      // control.
    }
    await _syncTray(_ref.read(receiveStatusProvider));
    // `--hidden` (the autostart entry) leaves the window unmapped. Settings >
    // "Start minimized" off means the user wants to see it at sign-in anyway.
    if (startHidden(args) && !await _startMinimizedSetting()) {
      try {
        await services.window.show();
      } on Object {
        // the window is a convenience
      }
    }
  }

  /// The saved "Start minimized" choice. If the engine cannot start the answer
  /// is "no": a hidden window would hide the error page too.
  Future<bool> _startMinimizedSetting() async {
    try {
      final engine = await _ref.read(engineProvider.future);
      return engine.receive.settings.startHidden;
    } on Object {
      return false;
    }
  }

  Future<void> _syncTray(ReceiveState s) async {
    final tray = _ref.read(platformServicesProvider).tray;
    if (!tray.isAvailable) return;
    try {
      await tray.setStatus(
        receiving: isReceivingState(s),
        tooltip: receiveTooltip(s),
      );
    } on Object {
      // the tray is a convenience
    }
  }

  Future<void>? _quitting;

  /// Stops the engine, the tray and the process. A second call (a double
  /// click on the tray item) waits for the first instead of starting another.
  Future<void> quit() => _quitting ??= _quit();

  Future<void> _quit() async {
    try {
      await _ref.read(engineProvider.notifier).shutdown();
      await _ref.read(platformServicesProvider).tray.dispose();
    } on Object {
      // leaving anyway
    }
    await _ref.read(quitHandlerProvider)();
  }
}

final shellBridgeProvider = Provider<ShellBridge>(ShellBridge.new);
