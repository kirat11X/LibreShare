// The CLI as users run it: real `ls` processes talking over loopback
// (FR-07..FR-11, FR-06), plus argument handling through runCli() in-process.
//
// The one-off `dart compile kernel` in setUpAll can take a while on a cold CI
// machine, hence the generous suite timeout; every test bounds itself.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_cli/ls_cli.dart';
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

/// A running `ls` process with its output collected line by line.
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

  /// First stdout line matching [re], waiting up to [timeout].
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

  /// Waits for the process to exit and for its output to be drained.
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

/// Runs `ls <args>` to completion.
Future<Ls> runLs(List<String> args) async {
  final p = await Ls.start(args);
  await p.process.stdin.close();
  await p.exit();
  return p;
}

File writeFile(String name, int size, int seed) {
  final r = Random(seed);
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = r.nextInt(256);
  }
  return File('${tmp.path}$sep$name')..writeAsBytesSync(bytes);
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

Future<int> closedPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
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
    buildDir = Directory.systemTemp.createTempSync('ls_cli_build_');
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
    tmp = Directory.systemTemp.createTempSync('ls_cli_test_');
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

  group('two real processes over loopback', () {
    test('receive --auto-accept --once, info --to, send 3 files: exit 0, byte-identical, success printed on both sides', () async {
      final files = [
        writeFile('empty.bin', 0, 1),
        writeFile('notes.txt', 1234, 2),
        writeFile('multi-chunk.bin', 4 * 1024 * 1024 + 500000, 3),
      ];
      final total = files.fold<int>(0, (s, f) => s + f.lengthSync());
      final rx = Directory('${tmp.path}${sep}rx');

      final receiver = await start([
        'receive',
        '--port',
        '0',
        '--dir',
        rx.path,
        '--auto-accept',
        '--once',
        '--alias',
        'cli-rx',
        '--insecure-plaintext',
      ]);
      final listening = await receiver.waitForLine(
        RegExp(r'^LISTENING .* port=(\d+) '),
      );
      final port = int.parse(listening.group(1)!);
      expect(port, greaterThan(0));

      // info --to
      final info = await runLs([
        'info',
        '--to',
        '$loopback:$port',
        '--insecure-plaintext',
      ]);
      expect(info.process.exitCode, completion(0));
      expect(info.stdout, contains('cli-rx'));
      expect(info.stdout, contains('v=1.0'));
      expect(info.stdout, matches(RegExp(r'id=[0-9a-f-]{36}')));

      // send --to
      final send = await runLs([
        'send',
        '--to',
        '$loopback:$port',
        '--insecure-plaintext',
        // Not in size order on purpose.
        files[2].path,
        files[0].path,
        files[1].path,
      ]);
      expect(await send.process.exitCode, 0, reason: send.stderr);
      expect(send.stdout, contains('status=COMPLETED'));
      expect(send.stdout, contains('SENT 3 file(s) $total bytes'));
      expect(send.stdoutLines.last, 'COMPLETED');
      expect(send.stdout, isNot(contains('FAILED')));
      expect(send.stderr, isEmpty);

      // The receiver exits by itself (--once) with 0.
      expect(await receiver.exit(), 0, reason: receiver.stderr);
      expect(
        receiver.stdout,
        matches(RegExp(r'^SESSION [0-9a-f-]{36}$', multiLine: true)),
      );
      for (final f in files) {
        final name = f.path.split(sep).last;
        expect(
          receiver.stdoutLines.where(
            (l) => l.startsWith('RECEIVED ') && l.endsWith('$sep$name'),
          ),
          hasLength(1),
          reason: 'one RECEIVED line for $name in:\n${receiver.stdout}',
        );
      }
      expect(receiver.stdoutLines.last, 'COMPLETED');
      expect(receiver.stderr, isNot(contains('Unhandled')));

      // Byte-identical, nothing else, no partial files.
      for (final f in files) {
        final dst = File('${rx.path}$sep${f.path.split(sep).last}');
        expect(dst.existsSync(), isTrue, reason: dst.path);
        expect(sameBytes(f, dst), isTrue, reason: 'bytes of ${dst.path}');
      }
      expect(rx.listSync(), hasLength(files.length));
      expect(leftovers(rx), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
      'sending to a closed port exits non-zero quickly with a clear message',
      () async {
        final port = await closedPort();
        final f = writeFile('lonely.bin', 100, 4);
        final sw = Stopwatch()..start();
        final send = await runLs([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          f.path,
        ]);
        sw.stop();

        expect(await send.process.exitCode, isNot(0));
        expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
        expect(send.stdout, contains('status=FAILED'));
        expect(send.stdout, isNot(contains('status=COMPLETED')));
        expect(send.stdoutLines.last, 'FAILED NO_CONNECTION');
        expect(send.stderr, contains('NO_CONNECTION'));
        expect(send.stderr, contains('cannot reach $loopback:$port'));
        expect(send.stderr, isNot(contains('Unhandled')));
      },
    );

    test('info --to a closed port exits non-zero with a message', () async {
      final port = await closedPort();
      final info = await runLs([
        'info',
        '--to',
        '$loopback:$port',
        '--insecure-plaintext',
      ]);
      expect(await info.process.exitCode, isNot(0));
      expect(info.stderr, contains('info failed'));
      expect(info.stderr, isNot(contains('Unhandled')));
    });

    test('receive without --auto-accept and no terminal rejects: sender FAILED(REJECTED)', () async {
      final f = writeFile('declined.bin', 5000, 5);
      final rx = Directory('${tmp.path}${sep}rx');
      final receiver = await start([
        'receive',
        '--port',
        '0',
        '--dir',
        rx.path,
        '--once',
        '--insecure-plaintext',
      ]);
      // stdin at EOF = not interactive.
      await receiver.process.stdin.close();
      final port = int.parse(
        (await receiver.waitForLine(RegExp(r'port=(\d+) '))).group(1)!,
      );

      final send = await runLs([
        'send',
        '--to',
        '$loopback:$port',
        '--insecure-plaintext',
        f.path,
      ]);
      expect(await send.process.exitCode, 1);
      expect(send.stdout, contains('status=FAILED reason=REJECTED'));
      expect(send.stdoutLines.last, 'FAILED REJECTED');

      expect(await receiver.exit(), 1);
      expect(receiver.stdout, contains('FAILED REJECTED'));
      expect(rx.listSync(), isEmpty);
    });
  });

  group('argument handling (runCli, in-process)', () {
    test('send without files -> 64', () async {
      expect(await runCli(['send', '--to', '$loopback:1']), 64);
    });

    test('send without --to -> 64', () async {
      final f = writeFile('x.bin', 10, 6);
      expect(await runCli(['send', f.path]), 64);
    });

    test('send with a malformed --to -> 64', () async {
      final f = writeFile('x.bin', 10, 6);
      for (final to in [
        'nonsense',
        '$loopback:',
        '$loopback:0',
        '$loopback:70000',
        ':53318',
      ]) {
        expect(await runCli(['send', '--to', to, f.path]), 64, reason: to);
      }
    });

    test('send of a nonexistent file -> 66 (before any connection)', () async {
      expect(
        await runCli([
          'send',
          '--to',
          '$loopback:1',
          '${tmp.path}${sep}no-such-file.bin',
        ]),
        66,
      );
      // One bad path among good ones still refuses the whole send.
      final f = writeFile('ok.bin', 10, 7);
      expect(
        await runCli([
          'send',
          '--to',
          '$loopback:1',
          f.path,
          '${tmp.path}${sep}missing',
        ]),
        66,
      );
    });

    test('unknown command, unknown option, no command -> 64', () async {
      expect(await runCli(['frobnicate']), 64);
      expect(await runCli(['--bogus']), 64);
      expect(await runCli(['send', '--nope']), 64);
      expect(await runCli(<String>[]), 64);
    });

    test('info without a usable --to -> 64; --help -> 0', () async {
      expect(await runCli(['info', '--to', 'bad']), 64);
      expect(await runCli(['--help']), 0);
    });

    test('receive with an invalid --port -> 64', () async {
      expect(await runCli(['receive', '--port', 'abc']), 64);
      expect(await runCli(['receive', '--port', '70000']), 64);
    });

    test('send to a closed port returns 1 without throwing', () async {
      final f = writeFile('y.bin', 10, 8);
      final port = await closedPort();
      expect(
        await runCli([
          'send',
          '--to',
          '$loopback:$port',
          '--insecure-plaintext',
          f.path,
        ]),
        1,
      );
    });
  });
}
