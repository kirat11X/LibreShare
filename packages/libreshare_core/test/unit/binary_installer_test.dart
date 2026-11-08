import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/src/tunnel/binary_installer.dart';
import 'package:libreshare_core/src/tunnel/cloudflared_versions.dart';
import 'package:test/test.dart';

void main() {
  group('CloudflaredVersions & BinaryInstaller Tests', () {
    test('pinned cloudflared metadata contains valid SHA-256 and URLs for desktop targets', () {
      expect(kCloudflaredPins, isNotEmpty);
      for (final pin in kCloudflaredPins.values) {
        expect(pin.version, isNotEmpty);
        expect(
          pin.platform,
          isIn([
            'linux-amd64',
            'linux-arm64',
            'windows-amd64',
            'darwin-amd64',
            'darwin-arm64',
          ]),
        );
        expect(pin.sha256, matches(RegExp(r'^[0-9a-fA-F]{64}$')));
        expect(
          pin.url,
          startsWith(
            'https://github.com/cloudflare/cloudflared/releases/download/',
          ),
        );
        expect(pin.sizeBytes, isPositive);
      }
    });

    test('BinaryInstaller verifies SHA-256 and installs binary with executable permissions', () async {
      final tempDir = await Directory.systemTemp.createTemp('installer_test_');
      final installer = BinaryInstaller(binDirectory: tempDir);

      final fakePayload = utf8.encode(
        '#!/bin/sh\necho "fake cloudflared 2026.10.7"\n',
      );
      final validSha256 = sha256.convert(fakePayload).toString();

      final installedFile = await installer.installFromBytes(
        bytes: fakePayload,
        filename: 'cloudflared-test',
        expectedSha256: validSha256,
      );

      expect(await installedFile.exists(), isTrue);
      expect(installer.verifyBinary(installedFile, validSha256), isTrue);

      if (!Platform.isWindows) {
        final stat = await installedFile.stat();
        expect(stat.modeString(), contains('rwx'));
      }

      await tempDir.delete(recursive: true);
    });

    test(
      'BinaryInstaller rejects mismatched SHA-256 and deletes temporary file',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'installer_bad_test_',
        );
        final installer = BinaryInstaller(binDirectory: tempDir);

        final fakePayload = utf8.encode('corrupt payload');
        final wrongSha256 = '0' * 64;

        expect(
          () => installer.installFromBytes(
            bytes: fakePayload,
            filename: 'cloudflared-corrupt',
            expectedSha256: wrongSha256,
          ),
          throwsA(isA<BinaryVerificationException>()),
        );

        // Verify no binary was left
        expect(tempDir.listSync(), isEmpty);
        await tempDir.delete(recursive: true);
      },
    );
  });
}
