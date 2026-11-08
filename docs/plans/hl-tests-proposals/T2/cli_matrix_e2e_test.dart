@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

const String loopback = '127.0.0.1';
final String sep = Platform.pathSeparator;

late Directory tmp;
late Directory buildDir;
late String dill;

String? _findCliEntry() {
  var dir = Directory.current.absolute;
  while (true) {
    for (final rel in [
      ['bin', 'ls.dart'],
      ['packages', 'libreshare_cli', 'bin', 'ls.dart'],
    ]) {
      final f = File([dir.path, ...rel].join(sep));
      if (f.existsSync()) return f.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

class Ls {
  Ls._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stdoutLines.add, onDone: _outDone.complete);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add, onDone: _errDone.complete);
  }

  final Process process;
  final List<String> stdoutLines = [];
  final List<String> stderrLines = [];
  final Completer<void> _outDone = Completer<void>();
  final Completer<void> _errDone = Completer<void>();

  static Future<Ls> start(List<String> args) async =>
      Ls._(await Process.start(Platform.resolvedExecutable, [dill, ...args]));

  String get stdout => stdoutLines.join('\n');
  String get stderr => stderrLines.join('\n');

  Future<RegExpMatch> waitForLine(
    RegExp re, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      for (final l in stdoutLines) {
        final m = re.firstMatch(l);
        if (m != null) return m;
      }
      if (sw.elapsed > timeout) {
        throw TimeoutException(
          'no stdout line matching $re within $timeout.\n'
          'stdout:\n$stdout\nstderr:\n$stderr',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<int> exit([Duration timeout = const Duration(seconds: 30)]) async {
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          'process did not exit within $timeout.\n'
          'stdout:\n$stdout\nstderr:\n$stderr',
        );
      },
    );
    await _outDone.future.timeout(const Duration(seconds: 5));
    await _errDone.future.timeout(const Duration(seconds: 5));
    return code;
  }

  void kill() => process.kill();
}

File writeFile(String name, int size, int seed) {
  final r = Random(seed);
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = r.nextInt(256);
  }
  final f = File('${tmp.path}$sep$name');
  f.parent.createSync(recursive: true);
  return f..writeAsBytesSync(bytes);
}

bool sameBytes(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

List<String> leftovers(Directory dir) => [
  for (final e in dir.listSync(recursive: true, followLinks: false))
    if (e.path.split(sep).last.contains('.lspart')) e.path,
];

void main() {
  final running = <Ls>[];

  setUpAll(() async {
    final entry =
        _findCliEntry() ??
        (throw StateError('packages/libreshare_cli/bin/ls.dart not found'));
    buildDir = Directory.systemTemp.createTempSync('ls_cli_matrix_build_');
    dill = '${buildDir.path}${sep}ls.dill';
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      entry,
      '-o',
      dill,
    ]);
    if (r.exitCode != 0) {
      fail(
        'dart compile kernel failed (${r.exitCode}):\n${r.stdout}\n${r.stderr}',
      );
    }
  });

  tearDownAll(() => buildDir.deleteSync(recursive: true));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_cli_matrix_test_');
  });

  tearDown(() {
    for (final p in running) {
      p.kill();
    }
    running.clear();
    tmp.deleteSync(recursive: true);
  });

  Future<Ls> start(List<String> args) async {
    final p = await Ls.start(args);
    running.add(p);
    return p;
  }

  group('Card T2: CLI End-to-End Matrix', () {
    test(
      'matrix 1: 0-byte file, 1 KiB, 4 MiB-1, 4 MiB+1 chunk boundary files',
      () async {
        final f0 = writeFile('zero.txt', 0, 1);
        final f1k = writeFile('one_kib.bin', 1024, 2);
        final f4mM1 = writeFile('chunk_minus_1.bin', 4 * 1024 * 1024 - 1, 3);
        final f4mP1 = writeFile('chunk_plus_1.bin', 4 * 1024 * 1024 + 1, 4);

        final rx = Directory('${tmp.path}${sep}rx1');

        final receiver = await start([
          'receive',
          '--port',
          '0',
          '--dir',
          rx.path,
          '--auto-accept',
          '--once',
          '--alias',
          'rx1',
          '--insecure-plaintext',
        ]);

        final listening = await receiver.waitForLine(
          RegExp(r'^LISTENING .* port=(\d+) '),
        );
        final port = int.parse(listening.group(1)!);

        final sender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          f0.path,
          f1k.path,
          f4mM1.path,
          f4mP1.path,
        ]);

        expect(await sender.exit(), equals(0));
        expect(await receiver.exit(), equals(0));

        expect(sameBytes(f0, File('${rx.path}${sep}zero.txt')), isTrue);
        expect(sameBytes(f1k, File('${rx.path}${sep}one_kib.bin')), isTrue);
        expect(
          sameBytes(f4mM1, File('${rx.path}${sep}chunk_minus_1.bin')),
          isTrue,
        );
        expect(
          sameBytes(f4mP1, File('${rx.path}${sep}chunk_plus_1.bin')),
          isTrue,
        );
        expect(leftovers(rx), isEmpty);
      },
    );

    test(
      'matrix 2: nested directory tree with unicode and emoji names',
      () async {
        final subDir = Directory(
          '${tmp.path}${sep}src_tree$sep📁_fotos${sep}2026_日本語',
        )..createSync(recursive: true);
        final file1 = File('${subDir.path}$sep富士山.txt')
          ..writeAsStringSync('Mt Fuji report');
        final file2 = File('${tmp.path}${sep}src_tree$sepالعربية.pdf')
          ..writeAsStringSync('Arabic document');

        final rx = Directory('${tmp.path}${sep}rx2');

        final receiver = await start([
          'receive',
          '--port',
          '0',
          '--dir',
          rx.path,
          '--auto-accept',
          '--once',
          '--alias',
          'rx2',
          '--insecure-plaintext',
        ]);

        final listening = await receiver.waitForLine(
          RegExp(r'^LISTENING .* port=(\d+) '),
        );
        final port = int.parse(listening.group(1)!);

        final sender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          file1.path,
          file2.path,
        ]);

        expect(await sender.exit(), equals(0));
        expect(await receiver.exit(), equals(0));

        final got1 = File('${rx.path}$sep富士山.txt');
        final got2 = File('${rx.path}$sepالعربية.pdf');

        expect(got1.existsSync(), isTrue);
        expect(got2.existsSync(), isTrue);
        expect(sameBytes(file1, got1), isTrue);
        expect(sameBytes(file2, got2), isTrue);
      },
    );

    test(
      'matrix 3: filename collision handling (receiver preserves both)',
      () async {
        final rx = Directory('${tmp.path}${sep}rx3')
          ..createSync(recursive: true);
        // Pre-create existing file
        final preExisting = File('${rx.path}${sep}conflict.txt')
          ..writeAsStringSync('version_A');

        final fileToSend = writeFile('conflict.txt', 128, 42);

        final receiver = await start([
          'receive',
          '--port',
          '0',
          '--dir',
          rx.path,
          '--auto-accept',
          '--once',
          '--alias',
          'rx3',
          '--insecure-plaintext',
        ]);

        final listening = await receiver.waitForLine(
          RegExp(r'^LISTENING .* port=(\d+) '),
        );
        final port = int.parse(listening.group(1)!);

        final sender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          fileToSend.path,
        ]);

        expect(await sender.exit(), equals(0));
        expect(await receiver.exit(), equals(0));

        // Both versions must exist
        expect(preExisting.readAsStringSync(), equals('version_A'));
        final second = File('${rx.path}${sep}conflict (1).txt');
        expect(second.existsSync(), isTrue);
        expect(sameBytes(fileToSend, second), isTrue);
      },
    );

    test(
      'matrix 4: Windows reserved names and trailing dots sanitized safely',
      () async {
        final reservedFile = writeFile('CON.txt', 256, 7);
        final dotsFile = writeFile('foo...   ', 512, 8);

        final rx = Directory('${tmp.path}${sep}rx4');

        final receiver = await start([
          'receive',
          '--port',
          '0',
          '--dir',
          rx.path,
          '--auto-accept',
          '--once',
          '--alias',
          'rx4',
          '--insecure-plaintext',
        ]);

        final listening = await receiver.waitForLine(
          RegExp(r'^LISTENING .* port=(\d+) '),
        );
        final port = int.parse(listening.group(1)!);

        final sender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          reservedFile.path,
          dotsFile.path,
        ]);

        expect(await sender.exit(), equals(0));
        expect(await receiver.exit(), equals(0));

        // Assert CON.txt sanitized to _CON.txt and foo... sanitized to foo
        final receivedReserved = File('${rx.path}${sep}_CON.txt');
        final receivedDots = File('${rx.path}${sep}foo');

        expect(receivedReserved.existsSync(), isTrue);
        expect(receivedDots.existsSync(), isTrue);
        expect(sameBytes(reservedFile, receivedReserved), isTrue);
        expect(sameBytes(dotsFile, receivedDots), isTrue);
      },
    );

    test(
      'matrix 5: PIN authentication (wrong PIN exits 82; right PIN exits 0)',
      () async {
        final f = writeFile('secret.txt', 100, 99);
        final rx = Directory('${tmp.path}${sep}rx5');

        final receiver = await start([
          'receive',
          '--port',
          '0',
          '--dir',
          rx.path,
          '--auto-accept',
          '--pin',
          '481920',
          '--insecure-tofu',
          '--alias',
          'rx5',
        ]);

        final listening = await receiver.waitForLine(
          RegExp(r'^LISTENING .* port=(\d+) '),
        );
        final port = int.parse(listening.group(1)!);

        // Attempt 1: Wrong PIN -> exit 82
        final wrongSender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--pin',
          '000000',
          '--insecure-tofu',
          f.path,
        ]);
        expect(await wrongSender.exit(), equals(82));

        // Attempt 2: Right PIN -> exit 0
        final rightSender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--pin',
          '481920',
          '--insecure-tofu',
          f.path,
        ]);
        expect(await rightSender.exit(), equals(0));

        receiver.kill();
      },
    );

    test(
      'matrix 6: receiver without auto-accept declines when unattended',
      () async {
        final f = writeFile('unattended.txt', 100, 101);
        final rx = Directory('${tmp.path}${sep}rx6');

        final receiver = await start([
          'receive',
          '--port',
          '0',
          '--dir',
          rx.path,
          '--once',
          '--alias',
          'rx6',
          '--insecure-plaintext',
        ]);

        final listening = await receiver.waitForLine(
          RegExp(r'^LISTENING .* port=(\d+) '),
        );
        final port = int.parse(listening.group(1)!);

        // Close receiver stdin immediately so terminal prompt declines
        await receiver.process.stdin.close();

        final sender = await start([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          f.path,
        ]);

        // Sender fails with rejection
        final sendCode = await sender.exit();
        expect(sendCode, isNot(equals(0)));

        await receiver.exit();
      },
    );
  });
}
