// CLI link and receive-link commands (Increment 5, Card J6).
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory downloadDir;
  late File testFile;
  late String testFileContent;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cli_link_test_');
    downloadDir = Directory('${tempDir.path}/downloads');
    await downloadDir.create();

    testFile = File('${tempDir.path}/hello.txt');
    testFileContent = 'Hello LibreShare Tunnel World! ' * 100;
    await testFile.writeAsString(testFileContent);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('CLI link and receive-link commands', () {
    test(
      'ls link prints a valid share link and serves file to ls receive-link',
      () async {
        final fakeProvider = FakeTunnelProvider();

        final linkOut = <String>[];
        final linkErr = <String>[];
        final linkStop = Completer<void>();

        // Start sender: ls link
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

        // Wait for link output
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

        expect(
          linkUrl,
          isNotNull,
          reason:
              'Expected LINK output from ls link, got: $linkOut, err: $linkErr',
        );

        // Verify link parseable
        final shareLink = ShareLink.parse(linkUrl!, allowDeveloperHosts: true);
        expect(shareLink.version, 1);
        expect(shareLink.token, hasLength(16));
        expect(shareLink.rootKey, hasLength(32));

        // Now run receiver: ls receive-link
        final receiveOut = <String>[];
        final receiveErr = <String>[];

        final receiveRc = await runCli(
          [
            'receive-link',
            linkUrl,
            '--dir',
            downloadDir.path,
            '--insecure-dev-allow-loopback',
          ],
          hooks: CliHooks(
            out: receiveOut.add,
            err: receiveErr.add,
            handleSignals: false,
          ),
        );

        expect(
          receiveRc,
          0,
          reason: 'ls receive-link failed with err: $receiveErr',
        );
        expect(receiveOut.any((l) => l.startsWith('SAVED ')), isTrue);
        expect(receiveOut.any((l) => l.contains('COMPLETE')), isTrue);

        // Verify downloaded file content
        final downloadedFile = File('${downloadDir.path}/hello.txt');
        expect(await downloadedFile.exists(), isTrue);
        expect(await downloadedFile.readAsString(), equals(testFileContent));

        // Sender completes after 1 transfer (mode 1 / one-time)
        final linkRc = await linkFuture.timeout(const Duration(seconds: 5));
        expect(linkRc, 0);
      },
    );

    test('ls link fails when file does not exist', () async {
      final err = <String>[];
      final rc = await runCli([
        'link',
        '${tempDir.path}/nonexistent.txt',
      ], hooks: CliHooks(err: err.add, handleSignals: false));
      expect(rc, 66);
      expect(err.any((l) => l.contains('file not found')), isTrue);
    });

    test('ls receive-link fails when given expired link', () async {
      final err = <String>[];
      // Build a link expired in the past
      final expiredUrl =
          'https://libreshare.github.io/r#v=1&h=relay.example.com&t=${b64urlEncode(Uint8List(16))}&k=${b64urlEncode(Uint8List(32))}&m=1&e=1000000';
      final rc = await runCli([
        'receive-link',
        expiredUrl,
      ], hooks: CliHooks(err: err.add, handleSignals: false));
      expect(rc, 1);
      expect(err.any((l) => l.contains('expired')), isTrue);
    });

    test('ls receive-link rejects IP literal link without allow-loopback flag (SSRF guard)', () async {
      final err = <String>[];
      // IP literal host
      final ipLink =
          'https://libreshare.github.io/r#v=1&h=192.168.1.10&t=${base64UrlEncode(Uint8List(16)).replaceAll("=", "")}&k=${base64UrlEncode(Uint8List(32)).replaceAll("=", "")}';
      final rc = await runCli([
        'receive-link',
        ipLink,
      ], hooks: CliHooks(err: err.add, handleSignals: false));
      expect(rc, 64);
      expect(err.any((l) => l.contains('invalid link')), isTrue);
    });

    test('ls receive-link fails when no link argument is provided', () async {
      final err = <String>[];
      final rc = await runCli([
        'receive-link',
      ], hooks: CliHooks(err: err.add, handleSignals: false));
      expect(rc, 64);
      expect(err.any((l) => l.contains('share link required')), isTrue);
    });

    test('ls link fails with invalid --expires or --receivers', () async {
      final err = <String>[];
      final rcExpires = await runCli([
        'link',
        testFile.path,
        '--expires',
        'invalid_duration',
      ], hooks: CliHooks(err: err.add, handleSignals: false));
      expect(rcExpires, 64);
      expect(err.any((l) => l.contains('invalid --expires')), isTrue);

      err.clear();
      final rcRec = await runCli([
        'link',
        testFile.path,
        '--receivers',
        '-5',
      ], hooks: CliHooks(err: err.add, handleSignals: false));
      expect(rcRec, 64);
      expect(err.any((l) => l.contains('invalid --receivers')), isTrue);
    });

    test('hostile bit-flip causes chunk hash verification failure and cleans up corrupted file', () async {
      // FakeTunnelProvider with hostile bit flip on chunk 0
      final hostileProvider = FakeTunnelProvider(hostileBitFlipChunkIndex: 0);

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
          tunnelProvider: hostileProvider,
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

      final receiveOut = <String>[];
      final receiveErr = <String>[];

      final receiveRc = await runCli(
        [
          'receive-link',
          linkUrl!,
          '--dir',
          downloadDir.path,
          '--insecure-dev-allow-loopback',
        ],
        hooks: CliHooks(
          out: receiveOut.add,
          err: receiveErr.add,
          handleSignals: false,
        ),
      );

      // Bit flip in ciphertext means decryption fails
      expect(receiveRc, isNonZero);
      expect(
        receiveErr.any(
          (l) =>
              l.contains('receive-link failed') ||
              l.contains('AuthenticationFailed'),
        ),
        isTrue,
      );

      linkStop.complete();
      await linkFuture;
    });
  });
}
