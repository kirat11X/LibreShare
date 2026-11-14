import 'dart:async';
import 'dart:io';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:test/test.dart';

void main() {
  group('CLI web command', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('ls_web_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Starts Web Portal, announces active URI, and stops on signal', () async {
      final stopCompleter = Completer<void>();
      final outLines = <String>[];
      final errLines = <String>[];

      final hooks = CliHooks(
        out: (l) => outLines.add(l),
        err: (l) => errLines.add(l),
        bindAddress: InternetAddress.loopbackIPv4,
        stop: stopCompleter.future,
        handleSignals: false,
      );

      final exitCodeFuture = runCli(
        [
          'web',
          '--port',
          '0',
          '--dir',
          tempDir.path,
          '--pin',
          '4321',
          '--alias',
          'TestWebNode',
        ],
        hooks: hooks,
      );

      // Wait for WEB_PORTAL_ACTIVE to appear in outLines
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!outLines.any((l) => l.startsWith('WEB_PORTAL_ACTIVE')) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(outLines.any((l) => l.startsWith('WEB_PORTAL_ACTIVE')), isTrue);
      expect(outLines.contains('WEB_PORTAL_PIN 4321'), isTrue);

      // Trigger stop
      stopCompleter.complete();
      final code = await exitCodeFuture;

      expect(code, equals(0));
      expect(outLines.contains('WEB_PORTAL_STOPPED'), isTrue);
    });
  });
}
