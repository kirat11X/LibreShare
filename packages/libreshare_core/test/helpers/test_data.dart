// Test-data helpers shared by the integration tests: deterministic random
// files, streaming comparison and SHA-256 of files.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Writes [size] bytes of deterministic pseudo-random data to [dir]/[name].
///
/// Every 1 MiB block uses its own seed, so no two chunks of a multi-chunk file
/// are equal (a reordering or duplication bug cannot hide). [mtime], if given,
/// is applied after writing.
File writeRandomFile(
  Directory dir,
  String name,
  int size, {
  int seed = 1,
  DateTime? mtime,
}) {
  dir.createSync(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  final raf = file.openSync(mode: FileMode.write);
  try {
    const block = 1024 * 1024;
    final bytes = Uint8List(block);
    final words = bytes.buffer.asUint32List();
    var written = 0;
    var blockNo = 0;
    while (written < size) {
      final r = Random(seed * 1000003 + blockNo++);
      for (var i = 0; i < words.length; i++) {
        words[i] = r.nextInt(0x100000000);
      }
      final n = min(block, size - written);
      raf.writeFromSync(bytes, 0, n);
      written += n;
    }
  } finally {
    raf.closeSync();
  }
  if (mtime != null) file.setLastModifiedSync(mtime);
  return file;
}

/// Lowercase hex SHA-256 of a file, streamed.
Future<String> sha256OfFileHex(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

/// Byte-for-byte comparison of two files, streamed in 1 MiB blocks.
Future<bool> filesIdentical(File a, File b) async {
  if (a.lengthSync() != b.lengthSync()) return false;
  final ra = await a.open();
  final rb = await b.open();
  try {
    const block = 1024 * 1024;
    while (true) {
      final x = await ra.read(block);
      final y = await rb.read(block);
      if (x.length != y.length) return false;
      if (x.isEmpty) return true;
      for (var i = 0; i < x.length; i++) {
        if (x[i] != y[i]) return false;
      }
    }
  } finally {
    await ra.close();
    await rb.close();
  }
}

/// Every `.lspart*` entry (partial file or resume sidecar) below [dir].
List<String> partialLeftovers(Directory dir) => dir.existsSync()
    ? [
        for (final e in dir.listSync(recursive: true, followLinks: false))
          if (e.uri.pathSegments.last.contains('.lspart')) e.path,
      ]
    : const [];
