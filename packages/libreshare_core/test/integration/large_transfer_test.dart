// Large end-to-end transfers between two engines in one process.
//
//  * 64 MiB of random content (tag `slow`, runs by default).
//  * 5 GiB sparse file (tag `very-slow`, only with LS_SLOW=1; set LS_SLOW_DIR
//    to a directory with >= 6 GiB free if the system temp dir is a small tmpfs).
@Tags(['slow'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/test_data.dart';

const String loopback = '127.0.0.1';

LibreShareEngine newEngine(String name, Directory rx) => LibreShareEngine(
  self: DeviceInfo(
    deviceId: 'device-$name',
    alias: 'Engine-$name',
    platform: 'linux',
  ),
  downloadDir: rx,
  preferredPort: 0,
  bindAddress: InternetAddress.loopbackIPv4,
  enableRateLimit: false,
);

void main() {
  late Directory sandbox;
  late LibreShareEngine tx;
  late LibreShareEngine rx;
  late Directory rxDir;
  final fileSaved = <FileSaved>[];
  final finished = <SessionFinished>[];

  Future<void> startPair(Directory root) async {
    sandbox = root;
    rxDir = Directory(p.join(sandbox.path, 'rx'));
    tx = newEngine('tx', Directory(p.join(sandbox.path, 'tx-dl')));
    rx = newEngine('rx', rxDir);
    fileSaved.clear();
    finished.clear();
    rx.events.listen((e) {
      if (e is FileSaved) fileSaved.add(e);
      if (e is SessionFinished) finished.add(e);
    });
    await tx.start();
    await rx.start();
  }

  tearDown(() async {
    await tx.dispose(force: true);
    await rx.dispose(force: true);
    sandbox.deleteSync(recursive: true);
  });

  test(
    '64 MiB of random content arrives byte-identical (SHA-256 compared)',
    () async {
      await startPair(Directory.systemTemp.createTempSync('ls_large_'));
      const size = 64 * 1024 * 1024 + 12345; // 16 full chunks + a short one
      final mtime = DateTime.utc(2023, 11, 5, 8, 30, 15);
      final src = writeRandomFile(
        Directory(p.join(sandbox.path, 'src')),
        'random-64mib.bin',
        size,
        seed: 7,
        mtime: mtime,
      );

      final res = await tx.sendFiles([src], host: loopback, port: rx.port);
      final mibPerSec = size / 1048576 / (res.elapsed.inMicroseconds / 1e6);
      // ignore: avoid_print
      print(
        '64 MiB loopback transfer: ${res.elapsed.inMilliseconds} ms '
        '(${mibPerSec.toStringAsFixed(1)} MiB/s incl. hashing both ends)',
      );

      expect(res.status, TransferStatus.completed, reason: '$res');
      expect(res.bytesSent, size);

      final dst = File(p.join(rxDir.path, 'random-64mib.bin'));
      expect(dst.lengthSync(), size);
      expect(await sha256OfFileHex(dst), await sha256OfFileHex(src));
      expect(await filesIdentical(src, dst), isTrue);
      expect(
        dst.lastModifiedSync().millisecondsSinceEpoch,
        mtime.millisecondsSinceEpoch,
      );
      expect(partialLeftovers(rxDir), isEmpty);
      expect(rxDir.listSync(), hasLength(1));

      await Future<void>.delayed(Duration.zero);
      expect(fileSaved.single.path, dst.path);
      expect(finished.single.success, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  final slowEnabled = Platform.environment['LS_SLOW'] == '1';
  test(
    '5 GiB sparse file: 1280 chunks, 64-bit offsets, ends match',
    () async {
      final base = Platform.environment['LS_SLOW_DIR'];
      final root = base == null
          ? Directory.systemTemp.createTempSync('ls_5gib_')
          : Directory(base).createTempSync('ls_5gib_');
      await startPair(root);

      const size = 5 * 1024 * 1024 * 1024;
      final src = File(p.join(sandbox.path, 'sparse-5gib.bin'));
      // Marker bytes at the start, at a 64-bit offset in the middle (beyond
      // 2 GiB and 4 GiB boundaries) and in the very last chunk.
      final markers = <int, List<int>>{
        0: [1, 2, 3, 4],
        size ~/ 2 + 12345: [9, 8, 7, 6],
        3 * 1024 * 1024 * 1024 + 7: [5, 5, 5, 5],
        size - 4: [0xDE, 0xAD, 0xBE, 0xEF],
      };
      final raf = src.openSync(mode: FileMode.write);
      try {
        raf.truncateSync(size);
        markers.forEach((offset, bytes) {
          raf
            ..setPositionSync(offset)
            ..writeFromSync(bytes);
        });
      } finally {
        raf.closeSync();
      }
      expect(src.lengthSync(), size);

      final res = await tx.sendFiles([src], host: loopback, port: rx.port);
      // ignore: avoid_print
      print(
        '5 GiB sparse transfer: ${res.elapsed.inSeconds} s '
        '(${(size / 1048576 / (res.elapsed.inMicroseconds / 1e6)).toStringAsFixed(1)} MiB/s)',
      );
      expect(res.status, TransferStatus.completed, reason: '$res');
      expect(res.bytesSent, size);

      final dst = File(p.join(rxDir.path, 'sparse-5gib.bin'));
      expect(dst.lengthSync(), size);
      final r = dst.openSync();
      try {
        markers.forEach((offset, bytes) {
          r.setPositionSync(offset);
          expect(
            Uint8List.fromList(r.readSync(bytes.length)),
            Uint8List.fromList(bytes),
            reason: 'marker at $offset',
          );
        });
      } finally {
        r.closeSync();
      }
      expect(partialLeftovers(rxDir), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(finished.single.success, isTrue);
    },
    tags: ['very-slow'],
    timeout: const Timeout(Duration(minutes: 45)),
    skip: slowEnabled ? false : 'set LS_SLOW=1 to run (5 GiB, takes minutes)',
  );
}
