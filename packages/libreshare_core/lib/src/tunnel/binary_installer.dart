import 'dart:io';

import 'package:crypto/crypto.dart';

class BinaryVerificationException implements Exception {
  final String message;
  const BinaryVerificationException(this.message);
  @override
  String toString() => 'BinaryVerificationException: $message';
}

class BinaryInstaller {
  final Directory binDirectory;

  BinaryInstaller({required this.binDirectory});

  File fileFor(String filename) => File('${binDirectory.path}/$filename');

  bool verifyBinary(File file, String expectedSha256) {
    if (!file.existsSync()) return false;
    final bytes = file.readAsBytesSync();
    final actual = sha256.convert(bytes).toString().toLowerCase();
    return actual == expectedSha256.toLowerCase();
  }

  Future<File> installFromBytes({
    required List<int> bytes,
    required String filename,
    required String expectedSha256,
  }) async {
    final actualSha = sha256.convert(bytes).toString().toLowerCase();
    if (actualSha != expectedSha256.toLowerCase()) {
      throw BinaryVerificationException(
        'SHA-256 mismatch for binary $filename: expected $expectedSha256, actual $actualSha',
      );
    }

    if (!await binDirectory.exists()) {
      await binDirectory.create(recursive: true);
    }

    final targetFile = fileFor(filename);
    final tempFile = File(
      '${binDirectory.path}/.$filename.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );

    try {
      await tempFile.writeAsBytes(bytes, flush: true);

      // Set user-executable permissions (chmod 0700) on POSIX
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['0700', tempFile.path]);
        } catch (_) {}
      }

      await tempFile.rename(targetFile.path);
      return targetFile;
    } catch (e) {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }
  }
}
