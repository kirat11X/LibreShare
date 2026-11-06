// Test verifying tools/loopback_smoke.sh in secure mode (--secure)
// and strict argument validation.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final repoRoot = () {
    var dir = Directory.current.absolute;
    while (true) {
      final f = File('${dir.path}/tools/loopback_smoke.sh');
      if (f.existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError('Could not find repo root');
      }
      dir = parent;
    }
  }();

  group('loopback_smoke.sh --secure', () {
    test(
      'running with --secure completes TLS transfer with SAS verification',
      () async {
        const port = 53930;
        final result = await Process.run('bash', [
          '$repoRoot/tools/loopback_smoke.sh',
          '1',
          '$port',
          '--secure',
        ]);
        expect(
          result.exitCode,
          equals(0),
          reason: 'stderr: ${result.stderr}\nstdout: ${result.stdout}',
        );
        expect(result.stdout, contains('LOOPBACK OK: 1 MiB byte-identical'));
        expect(result.stdout, contains('SAS '));
        expect(result.stdout, contains('v=1.1'));
        expect(result.stdout, isNot(contains('--insecure-plaintext')));
      },
    );

    test('rejects unrecognized third argument', () async {
      const port = 53931;
      final result = await Process.run('bash', [
        '$repoRoot/tools/loopback_smoke.sh',
        '1',
        '$port',
        '--bogus',
      ]);
      expect(result.exitCode, isNot(equals(0)));
    });
  });
}
