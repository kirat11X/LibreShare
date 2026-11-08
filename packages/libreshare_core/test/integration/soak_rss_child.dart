// Helper process for soak_stress_test.dart (NOT a test: no _test suffix).
// Runs a 1 GiB loopback transfer in this dedicated child process to measure
// RSS growth without interference from the parallel test runner VM.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';

Future<void> main(List<String> args) async {
  final tempDir = Directory.systemTemp.createTempSync('soak_rss_child_');
  try {
    // Force garbage collection / settle RSS
    for (var k = 0; k < 3; k++) {
      final junk = <Uint8List>[
        for (var i = 0; i < 32; i++) Uint8List(256 * 1024),
      ];
      junk.clear();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final rssBefore = ProcessInfo.currentRss;

    // Create 1 GiB sparse file
    final srcDir = Directory('${tempDir.path}${Platform.pathSeparator}src')
      ..createSync();
    final destDir = Directory('${tempDir.path}${Platform.pathSeparator}dest')
      ..createSync();

    final gigFile = File('${srcDir.path}${Platform.pathSeparator}one_gib.bin');
    final raf = gigFile.openSync(mode: FileMode.write);
    // Write 1 byte at start, 1 byte at 512MB, 1 byte at 1GB-1 to create 1 GiB file
    raf.writeByteSync(0xAA);
    raf.setPositionSync(512 * 1024 * 1024);
    raf.writeByteSync(0xBB);
    raf.setPositionSync(1024 * 1024 * 1024 - 1);
    raf.writeByteSync(0xCC);
    raf.closeSync();

    // Start receiver engine
    final rxEngine = LibreShareEngine(
      self: DeviceInfo(
        deviceId: 'device-soak-rx',
        alias: 'SoakRx',
        platform: 'linux',
      ),
      downloadDir: destDir,
      preferredPort: 0,
      autoAccept: true,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
    );
    await rxEngine.start();

    // Start sender engine
    final txEngine = LibreShareEngine(
      self: DeviceInfo(
        deviceId: 'device-soak-tx',
        alias: 'SoakTx',
        platform: 'linux',
      ),
      downloadDir: srcDir,
      preferredPort: 0,
      autoAccept: true,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
    );
    await txEngine.start();

    // Send 1 GiB file over loopback
    final result = await txEngine.sendFiles(
      [gigFile],
      host: '127.0.0.1',
      port: rxEngine.port,
      chunkConcurrency: 2,
    );

    await txEngine.stop();
    await rxEngine.stop();

    // Force garbage collection / settle RSS after transfer
    for (var k = 0; k < 3; k++) {
      final junk = <Uint8List>[
        for (var i = 0; i < 32; i++) Uint8List(256 * 1024),
      ];
      junk.clear();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final rssAfter = ProcessInfo.currentRss;
    final rssGrowth = rssAfter - rssBefore;
    final maxAllowedGrowth = 150 * 1024 * 1024; // 150 MB bound

    final pass =
        result.status == TransferStatus.completed &&
        rssGrowth < maxAllowedGrowth;

    // ignore: avoid_print
    print('RSS_BEFORE=$rssBefore');
    // ignore: avoid_print
    print('RSS_AFTER=$rssAfter');
    // ignore: avoid_print
    print('RSS_GROWTH=$rssGrowth');
    // ignore: avoid_print
    print('STATUS=${result.status.wire}');
    // ignore: avoid_print
    print('RESULT=${pass ? "PASS" : "FAIL"}');

    if (!pass) {
      exitCode = 1;
    }
  } finally {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
