/// One logging pipeline for the whole app: every `package:logging` record
/// (the core's loggers, the platform adapters) ends up in `dart:developer`, so
/// it shows in DevTools and `flutter run`.
///
/// Rules (CLAUDE.md): nothing here, or anything that logs through it, may carry
/// file contents, keys, PINs or tunnel URL fragments. Records are passed on as
/// they are; callers keep secrets out of them.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:logging/logging.dart';

import '../platform/platform_log.dart';

/// Core and app loggers are all `libreshare.*`.
const String kPlatformLoggerPrefix = 'libreshare.platform';

Level _toLevel(PlatformLogLevel level) => switch (level) {
  PlatformLogLevel.fine => Level.FINE,
  PlatformLogLevel.info => Level.INFO,
  PlatformLogLevel.warning => Level.WARNING,
  PlatformLogLevel.severe => Level.SEVERE,
};

/// Forwards the platform adapters' records (`PlatformLog`) to
/// `Logger('libreshare.platform.<component>')`. Returns a function that puts
/// the previous sink back (tests, hot restart).
void Function() connectPlatformLog() {
  final previous = PlatformLog.sink;
  PlatformLog.sink = (name, level, message, error) =>
      Logger('$kPlatformLoggerPrefix.$name')
          .log(_toLevel(level), message, error);
  return () => PlatformLog.sink = previous;
}

/// Sets up logging once at start-up: the root level, the printer for every
/// record (default `dart:developer`; [onRecord] replaces it) and the bridge
/// from `PlatformLog`. Returns a function that undoes all three.
void Function() installAppLogging({
  Level level = Level.INFO,
  void Function(LogRecord record)? onRecord,
}) {
  final previousLevel = Logger.root.level;
  Logger.root.level = level;
  final sub = Logger.root.onRecord.listen(onRecord ?? _toDeveloperLog);
  final disconnect = connectPlatformLog();
  return () {
    disconnect();
    unawaited(sub.cancel());
    Logger.root.level = previousLevel;
  };
}

void _toDeveloperLog(LogRecord r) => developer.log(
  r.message,
  time: r.time,
  sequenceNumber: r.sequenceNumber,
  level: r.level.value,
  name: r.loggerName,
  error: r.error,
  stackTrace: r.stackTrace,
);
