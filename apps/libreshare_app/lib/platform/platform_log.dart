/// Tiny logging shim for the platform adapters.
///
/// `package:logging` is not a direct dependency of the app, so the adapters
/// log through this class instead. By default records go to `dart:developer`
/// (visible in DevTools / `flutter run`); the app can forward them to
/// `package:logging` once, at start-up:
///
/// ```dart
/// PlatformLog.sink = (logger, level, message, error) =>
///     Logger('libreshare.platform.$logger').log(...);
/// ```
///
/// Rules (CLAUDE.md): never pass file contents, keys, PINs or tunnel URL
/// fragments here. Adapters only log OS-level facts (paths of their own
/// config files, exception types, availability changes).
library;

import 'dart:developer' as developer;

enum PlatformLogLevel {
  fine(500),
  info(800),
  warning(900),
  severe(1000);

  const PlatformLogLevel(this.value);

  /// Same numeric scale as `package:logging` / `dart:developer`.
  final int value;
}

typedef PlatformLogSink = void Function(
  String logger,
  PlatformLogLevel level,
  String message,
  Object? error,
);

class PlatformLog {
  const PlatformLog(this.name);

  /// Short component name, e.g. `autostart` or `mdns`.
  final String name;

  /// Replaceable sink (tests capture records here; the app may forward them to
  /// its own logger). `null` means `dart:developer`.
  static PlatformLogSink? sink;

  void fine(String message, [Object? error]) =>
      _emit(PlatformLogLevel.fine, message, error);

  void info(String message, [Object? error]) =>
      _emit(PlatformLogLevel.info, message, error);

  void warning(String message, [Object? error]) =>
      _emit(PlatformLogLevel.warning, message, error);

  void severe(String message, [Object? error]) =>
      _emit(PlatformLogLevel.severe, message, error);

  void _emit(PlatformLogLevel level, String message, Object? error) {
    final custom = sink;
    try {
      if (custom != null) {
        custom(name, level, message, error);
        return;
      }
      developer.log(
        message,
        name: 'libreshare.platform.$name',
        level: level.value,
        error: error,
      );
    } on Object {
      // Logging must never break the caller.
    }
  }
}
