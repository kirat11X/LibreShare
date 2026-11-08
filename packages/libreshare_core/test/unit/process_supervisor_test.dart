import 'dart:io';

import 'package:libreshare_core/src/tunnel/cloudflared_provider.dart';
import 'package:libreshare_core/src/tunnel/manual_url_provider.dart';
import 'package:libreshare_core/src/tunnel/process_supervisor.dart';
import 'package:libreshare_core/src/tunnel/tunnel_provider.dart';
import 'package:libreshare_core/src/tunnel/zrok_provider.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessSupervisor & Tunnel Providers Tests', () {
    test('parses public trycloudflare.com URL from stderr output', () {
      const sampleStderr = '''
2026-11-06T12:00:00Z INF Thank you for trying Cloudflare Tunnel. Doing quick setup...
2026-11-06T12:00:03Z INF +--------------------------------------------------------------------------------------------+
2026-11-06T12:00:03Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
2026-11-06T12:00:03Z INF |  https://quiet-lamp-demo-wolf.trycloudflare.com                                            |
2026-11-06T12:00:03Z INF +--------------------------------------------------------------------------------------------+
2026-11-06T12:00:05Z INF Registered tunnel connection
''';
      final parsedUrl = ProcessSupervisor.extractTunnelUrl(sampleStderr);
      expect(
        parsedUrl,
        equals(Uri.parse('https://quiet-lamp-demo-wolf.trycloudflare.com')),
      );
    });

    test(
      'argv construction never contains --allowed-mail (security invariant)',
      () {
        final argv = ProcessSupervisor.buildCloudflaredArgv(
          localPort: 53318,
          tempConfigPath: '/tmp/empty.yml',
        );
        expect(argv.contains('--allowed-mail'), isFalse);
        expect(argv.any((arg) => arg.contains('allowed-mail')), isFalse);
        expect(argv, contains('--url'));
        expect(argv, contains('http://127.0.0.1:53318'));
        expect(argv, contains('--no-autoupdate'));
      },
    );

    test('stale pidfile cleanup cleans orphan pidfile at startup', () async {
      final tempRunDir = await Directory.systemTemp.createTemp('run_dir_test_');
      final pidFile = File('${tempRunDir.path}/tunnel.pid');
      await pidFile.writeAsString('999999999\n'); // Non-existent PID

      await ProcessSupervisor.cleanStalePidfile(pidFile);
      expect(await pidFile.exists(), isFalse);

      await tempRunDir.delete(recursive: true);
    });

    test(
      'ManualUrlProvider accepts valid HTTPS URL and yields TunnelHandle',
      () async {
        final provider = ManualUrlProvider(
          url: Uri.parse('https://my-custom-proxy.example.com'),
        );
        expect(provider.id, equals('manual-url'));
        expect(await provider.isAvailable(), isTrue);

        final handle = await provider.open(53318);
        expect(
          handle.publicBase,
          equals(Uri.parse('https://my-custom-proxy.example.com')),
        );

        final events = <TunnelEvent>[];
        final sub = handle.events.listen(events.add);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events.any((e) => e is TunnelUpEvent), isTrue);

        await handle.close();
        await sub.cancel();
      },
    );

    test('ManualUrlProvider rejects non-HTTPS or invalid URLs', () {
      expect(
        () => ManualUrlProvider(url: Uri.parse('http://insecure.example.com')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('CloudflaredProvider spawns supervisor, discovers URL and shuts down cleanly', () async {
      final tempDir = await Directory.systemTemp.createTemp('cf_test_');
      final fakeScript = File('${tempDir.path}/fake_cloudflared.sh');
      await fakeScript.writeAsString(
        '#!/bin/sh\n'
        'echo "INF https://test-fake-cf.trycloudflare.com" >&2\n'
        'while true; do sleep 1; done\n',
      );
      await Process.run('chmod', ['+x', fakeScript.path]);

      final provider = CloudflaredProvider(
        appSupportDirectory: tempDir,
        customBinaryPath: fakeScript.path,
      );

      final handle = await provider.open(53318);
      expect(
        handle.publicBase,
        equals(Uri.parse('https://test-fake-cf.trycloudflare.com')),
      );

      await handle.close();
      await tempDir.delete(recursive: true);
    });

    test(
      'ZrokProvider spawns supervisor, discovers URL and shuts down cleanly',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('zrok_test_');
        final fakeScript = File('${tempDir.path}/fake_zrok.sh');
        await fakeScript.writeAsString(
          '#!/bin/sh\n'
          'echo "INF https://test-fake.share.zrok.io" \n'
          'while true; do sleep 1; done\n',
        );
        await Process.run('chmod', ['+x', fakeScript.path]);

        final provider = ZrokProvider(
          accountToken: 'test-token',
          zrokBinaryPath: fakeScript.path,
        );

        final handle = await provider.open(53318);
        expect(
          handle.publicBase,
          equals(Uri.parse('https://test-fake.share.zrok.io')),
        );

        await handle.close();
        await tempDir.delete(recursive: true);
      },
    );
  });
}
