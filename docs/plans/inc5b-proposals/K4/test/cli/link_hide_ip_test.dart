// CLI link --hide-ip flag and disclosure tests (Increment 5b Wave 4).
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File testFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cli_hide_ip_test_');
    testFile = File('${tempDir.path}/hello.txt');
    await testFile.writeAsString('Test file content for hide-ip disclosure');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('CLI ls link --hide-ip and disclosure', () {
    test(
      'ls link with --hide-ip emits HIDE-IP and generates tunnel-only link',
      () async {
        final fakeProvider = FakeTunnelProvider();
        final linkOut = <String>[];
        final linkErr = <String>[];
        final linkStop = Completer<void>();

        final linkFuture = runCli(
          [
            'link',
            testFile.path,
            '--provider',
            'fake',
            '--hide-ip',
            '--insecure-plaintext',
          ],
          hooks: CliHooks(
            out: linkOut.add,
            err: linkErr.add,
            stop: linkStop.future,
            handleSignals: false,
            tunnelProvider: fakeProvider,
          ),
        );

        String? linkUrl;
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final match = linkOut.firstWhere(
            (line) => line.startsWith('LINK '),
            orElse: () => '',
          );
          if (match.isNotEmpty) {
            linkUrl = match.substring('LINK '.length).trim();
            break;
          }
        }

        expect(linkUrl, isNotNull);
        expect(linkOut.any((l) => l.contains('HIDE-IP:')), isTrue);
        expect(linkOut.any((l) => l.contains('DISCLOSURE:')), isFalse);

        final shareLink = ShareLink.parse(linkUrl!, allowDeveloperHosts: true);
        expect(shareLink.candidates.isEmpty, isTrue);
        expect(shareLink.tlsPinHex, isNull);

        linkStop.complete();
        await linkFuture;
      },
    );

    test('ls link without --hide-ip prints DISCLOSURE line', () async {
      final fakeProvider = FakeTunnelProvider();
      final linkOut = <String>[];
      final linkErr = <String>[];
      final linkStop = Completer<void>();

      final linkFuture = runCli(
        ['link', testFile.path, '--provider', 'fake', '--insecure-plaintext'],
        hooks: CliHooks(
          out: linkOut.add,
          err: linkErr.add,
          stop: linkStop.future,
          handleSignals: false,
          tunnelProvider: fakeProvider,
        ),
      );

      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (linkOut.any((l) => l.startsWith('LINK '))) break;
      }

      expect(linkOut.any((l) => l.contains('DISCLOSURE:')), isTrue);
      expect(linkOut.any((l) => l.contains('HIDE-IP:')), isFalse);

      linkStop.complete();
      await linkFuture;
    });
  });
}
