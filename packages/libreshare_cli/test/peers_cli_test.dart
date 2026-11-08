// CLI peers command test (Increment 6 Wave 3).
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cli_peers_test_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('CLI ls peers', () {
    test('ls peers reports No paired peers when trust store has no paired contacts', () async {
      final out = <String>[];
      final err = <String>[];

      final code = await runCli([
        'peers',
        '--identity-dir',
        tempDir.path,
      ], hooks: CliHooks(out: out.add, err: err.add, handleSignals: false));

      expect(code, equals(0));
      expect(out.join('\n'), contains('No paired peers.'));
    });

    test('ls peers lists only contacts that have pair keys', () async {
      final w = await SecurityWiring.open(directory: tempDir);

      // Add a regular contact without pair key
      await w.trust.pin(
        deviceId: 'regular-contact-uuid',
        fingerprint: 'A' * 64,
        alias: 'Regular Contact',
        trust: PeerTrust.known,
      );

      // Add a paired contact with pair key
      await w.trust.pin(
        deviceId: 'paired-peer-uuid',
        fingerprint: 'B' * 64,
        alias: 'Paired Peer',
        trust: PeerTrust.trusted,
      );
      await w.trust.setPairKey('paired-peer-uuid', true);
      await w.close();

      final out = <String>[];
      final err = <String>[];

      final code = await runCli([
        'peers',
        '--identity-dir',
        tempDir.path,
      ], hooks: CliHooks(out: out.add, err: err.add, handleSignals: false));

      expect(code, equals(0));
      final fullOut = out.join('\n');
      expect(fullOut, contains('PEER paired-peer-uuid alias="Paired Peer"'));
      expect(fullOut, isNot(contains('regular-contact-uuid')));
    });
  });
}
