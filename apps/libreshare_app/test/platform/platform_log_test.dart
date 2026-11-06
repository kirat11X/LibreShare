import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_log.dart';

void main() {
  tearDown(() => PlatformLog.sink = null);

  test(
    'records reach the installed sink with logger name, level and error',
    () {
      final records = <(String, PlatformLogLevel, String, Object?)>[];
      PlatformLog.sink = (logger, level, message, error) =>
          records.add((logger, level, message, error));
      const log = PlatformLog('x');
      final boom = StateError('boom');
      log.fine('f');
      log.info('i');
      log.warning('w', boom);
      log.severe('s');
      expect(records.map((r) => r.$2), PlatformLogLevel.values);
      expect(records.every((r) => r.$1 == 'x'), isTrue);
      expect(records[2].$4, boom);
    },
  );

  test('logging never throws, with or without a sink', () {
    const log = PlatformLog('x');
    log.warning('default sink (dart:developer)');
    PlatformLog.sink = (_, _, _, _) => throw StateError('sink bug');
    log.warning('throwing sink'); // must not propagate
  });

  test('levels use the package:logging numeric scale', () {
    expect(PlatformLogLevel.fine.value, 500);
    expect(PlatformLogLevel.info.value, 800);
    expect(PlatformLogLevel.warning.value, 900);
    expect(PlatformLogLevel.severe.value, 1000);
  });
}
