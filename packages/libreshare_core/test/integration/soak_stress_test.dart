@Tags(['slow'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('soak_stress_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Card T5: Soak & Reliability Stress Suite', () {
    test('1. 1,000 tiny files transferred in a single session', () async {
      final srcDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}src_1000',
      )..createSync();
      final destDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}dest_1000',
      )..createSync();

      // Create 1,000 tiny files
      final files = <File>[];
      for (var i = 0; i < 1000; i++) {
        final f = File(
          '${srcDir.path}${Platform.pathSeparator}file_${i.toString().padLeft(4, '0')}.txt',
        )..writeAsStringSync('LibreShare tiny file payload content number $i');
        files.add(f);
      }
      expect(files.length, equals(1000));

      final rx = LibreShareEngine(
        self: DeviceInfo(
          deviceId: 'dev-rx-1000',
          alias: 'Rx1000',
          platform: 'linux',
        ),
        downloadDir: destDir,
        preferredPort: 0,
        autoAccept: true,
        bindAddress: InternetAddress.loopbackIPv4,
        enableRateLimit: false,
      );
      await rx.start();

      final tx = LibreShareEngine(
        self: DeviceInfo(
          deviceId: 'dev-tx-1000',
          alias: 'Tx1000',
          platform: 'linux',
        ),
        downloadDir: srcDir,
        preferredPort: 0,
        autoAccept: true,
        bindAddress: InternetAddress.loopbackIPv4,
        enableRateLimit: false,
      );
      await tx.start();

      final sendResult = await tx.sendFiles(
        files,
        host: '127.0.0.1',
        port: rx.port,
        chunkConcurrency: 2,
      );

      expect(sendResult.status, equals(TransferStatus.completed));

      // Assert all 1,000 files arrived
      final receivedFiles = destDir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList();
      expect(receivedFiles.length, equals(1000));

      // Assert sample files byte identity
      for (final idx in [0, 100, 500, 999]) {
        final orig = files[idx].readAsBytesSync();
        final rec = File(
          '${destDir.path}${Platform.pathSeparator}file_${idx.toString().padLeft(4, '0')}.txt',
        ).readAsBytesSync();
        expect(rec, equals(orig));
      }

      // Assert 0 leftover .part or temporary files
      final leftovers = destDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.part') || f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);

      await tx.stop();
      await rx.stop();
    });

    test('2. Concurrent fan-in: 10 senders to 1 receiver', () async {
      final destDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}dest_fanin',
      )..createSync();

      final rxEvents = <LsEvent>[];
      final rx = LibreShareEngine(
        self: DeviceInfo(
          deviceId: 'dev-rx-fanin',
          alias: 'RxFanIn',
          platform: 'linux',
        ),
        downloadDir: destDir,
        preferredPort: 0,
        autoAccept: true,
        bindAddress: InternetAddress.loopbackIPv4,
        enableRateLimit: false,
      );
      rx.events.listen(rxEvents.add);
      await rx.start();

      // Spin up 10 distinct sender engines
      final senders = <LibreShareEngine>[];
      final sendFutures = <Future<SendResult>>[];

      for (var i = 0; i < 10; i++) {
        final txDir = Directory('${tempDir.path}${Platform.pathSeparator}tx_$i')
          ..createSync();
        final testFile = File(
          '${txDir.path}${Platform.pathSeparator}sender_$i.bin',
        )..writeAsBytesSync(List.generate(1024 * 10, (b) => (b + i) % 256));

        final tx = LibreShareEngine(
          self: DeviceInfo(
            deviceId: 'dev-tx-$i',
            alias: 'Sender-$i',
            platform: 'linux',
          ),
          downloadDir: txDir,
          preferredPort: 0,
          autoAccept: true,
          bindAddress: InternetAddress.loopbackIPv4,
          enableRateLimit: false,
        );
        await tx.start();
        senders.add(tx);

        sendFutures.add(
          tx.sendFiles(
            [testFile],
            host: '127.0.0.1',
            port: rx.port,
            chunkConcurrency: 1,
          ),
        );
      }

      final results = await Future.wait(sendFutures);

      for (var i = 0; i < 10; i++) {
        expect(
          results[i].status,
          equals(TransferStatus.completed),
          reason: 'Sender $i failed',
        );
      }

      // Assert receiver got all 10 files
      final receivedFiles = destDir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList();
      expect(receivedFiles.length, equals(10));

      // Assert event stream sanity: every session ended with SessionFinished
      final finishedEvents = rxEvents.whereType<SessionFinished>().toList();
      expect(finishedEvents.length, equals(10));
      for (final event in finishedEvents) {
        expect(event.success, isTrue);
      }

      for (final tx in senders) {
        await tx.stop();
      }
      await rx.stop();
    });

    test('3. 50 sequential sessions of 10 files (bounded soak)', () async {
      final destDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}dest_soak50',
      )..createSync();
      final srcDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}src_soak50',
      )..createSync();

      final rx = LibreShareEngine(
        self: DeviceInfo(
          deviceId: 'dev-rx-soak50',
          alias: 'RxSoak50',
          platform: 'linux',
        ),
        downloadDir: destDir,
        preferredPort: 0,
        autoAccept: true,
        bindAddress: InternetAddress.loopbackIPv4,
        enableRateLimit: false,
      );
      await rx.start();

      final tx = LibreShareEngine(
        self: DeviceInfo(
          deviceId: 'dev-tx-soak50',
          alias: 'TxSoak50',
          platform: 'linux',
        ),
        downloadDir: srcDir,
        preferredPort: 0,
        autoAccept: true,
        bindAddress: InternetAddress.loopbackIPv4,
        enableRateLimit: false,
      );
      await tx.start();

      for (var sessionIdx = 0; sessionIdx < 50; sessionIdx++) {
        final sessionFiles = <File>[];
        for (var f = 0; f < 10; f++) {
          final file = File(
            '${srcDir.path}${Platform.pathSeparator}s${sessionIdx}_f$f.dat',
          )..writeAsBytesSync([sessionIdx % 256, f % 256, 42]);
          sessionFiles.add(file);
        }

        final res = await tx.sendFiles(
          sessionFiles,
          host: '127.0.0.1',
          port: rx.port,
          chunkConcurrency: 2,
        );

        expect(
          res.status,
          equals(TransferStatus.completed),
          reason: 'Session $sessionIdx failed',
        );
      }

      // Assert total 500 files received
      final receivedFiles = destDir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList();
      expect(receivedFiles.length, equals(500));

      await tx.stop();
      await rx.stop();
    });

    test('4. Child process RSS growth bound (< 150 MB over 1 GiB transfer)', () async {
      // Find soak_rss_child.dart path
      final scriptCandidates = [
        File('test/integration/soak_rss_child.dart'),
        File('../../.toolchain/scratch/t5-work/soak_rss_child.dart'),
        File('.toolchain/scratch/t5-work/soak_rss_child.dart'),
      ];

      File? scriptFile;
      for (final candidate in scriptCandidates) {
        if (candidate.existsSync()) {
          scriptFile = candidate;
          break;
        }
      }
      expect(scriptFile, isNotNull, reason: 'soak_rss_child.dart not found');

      final result = await Process.run(Platform.resolvedExecutable, [
        scriptFile!.path,
      ]);

      final stdoutText = result.stdout as String;
      final stderrText = result.stderr as String;

      expect(
        result.exitCode,
        equals(0),
        reason:
            'Child failed with exit ${result.exitCode}\nSTDOUT:\n$stdoutText\nSTDERR:\n$stderrText',
      );
      expect(stdoutText, contains('RESULT=PASS'));
      expect(stdoutText, contains('STATUS=COMPLETED'));

      final growthMatch = RegExp(r'RSS_GROWTH=(-?\d+)').firstMatch(stdoutText);
      expect(growthMatch, isNotNull);
      final growth = int.parse(growthMatch!.group(1)!);
      expect(
        growth,
        lessThan(150 * 1024 * 1024),
        reason: 'RSS grew by $growth bytes (>= 150 MB)',
      );
    });
  });
}
