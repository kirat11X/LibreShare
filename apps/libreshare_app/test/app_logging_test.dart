// The app's logging pipeline: the core's loggers and the platform adapters'
// PlatformLog end up in the same place (lib/services/app_logging.dart, called
// first thing in main()).
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_log.dart';
import 'package:libreshare_app/services/app_logging.dart';
import 'package:logging/logging.dart';

void main() {
  late List<LogRecord> records;
  late void Function() undo;
  late PlatformLogSink? sinkBefore;
  late Level levelBefore;

  setUp(() {
    sinkBefore = PlatformLog.sink;
    levelBefore = Logger.root.level;
    records = [];
    undo = installAppLogging(level: Level.ALL, onRecord: records.add);
  });

  tearDown(() {
    undo();
    PlatformLog.sink = sinkBefore;
    Logger.root.level = levelBefore;
  });

  test('platform adapter records reach the app logger', () {
    const PlatformLog('autostart').info('autostart enabled');

    expect(records, hasLength(1));
    expect(records.single.loggerName, 'libreshare.platform.autostart');
    expect(records.single.level, Level.INFO);
    expect(records.single.message, 'autostart enabled');
  });

  test('levels and the error object are kept', () {
    final cause = StateError('boom');
    const log = PlatformLog('window');
    log.fine('f');
    log.info('i');
    log.warning('w', cause);
    log.severe('s', cause);

    expect(records.map((r) => r.level), [
      Level.FINE,
      Level.INFO,
      Level.WARNING,
      Level.SEVERE,
    ]);
    expect(records[2].error, same(cause));
    expect(records[3].error, same(cause));
    expect(records.map((r) => r.loggerName).toSet(), {
      'libreshare.platform.window',
    });
  });

  test('core loggers share the same pipeline', () {
    Logger('libreshare.FileSender').warning('session failed');

    expect(records.single.loggerName, 'libreshare.FileSender');
    expect(records.single.message, 'session failed');
  });

  test('the root level filters what is recorded', () {
    Logger.root.level = Level.WARNING;
    const PlatformLog('mdns').info('quiet');
    const PlatformLog('mdns').warning('loud');

    expect(records.map((r) => r.message), ['loud']);
  });

  test('undoing puts the previous sink and level back', () {
    expect(PlatformLog.sink, isNotNull);
    undo();
    expect(PlatformLog.sink, same(sinkBefore));
    expect(Logger.root.level, levelBefore);

    // After the undo nothing is forwarded any more.
    const PlatformLog('tray').info('after');
    expect(records, isEmpty);
    undo = () {};
  });
}
