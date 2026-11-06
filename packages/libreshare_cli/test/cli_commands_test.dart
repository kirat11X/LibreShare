// FR-02..FR-04, FR-18: the CLI's discovery and Receive-mode commands.
//
// Most tests run several commands in one process through runCli(hooks): each
// "device" gets its own loopback alias (127.0.0.N) and a transport on a shared
// in-memory multicast bus, so no UDP 53318 and no real LAN is needed. The last
// group runs real `ls` processes over real multicast and skips itself when the
// host does not deliver it.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:libreshare_core/libreshare_core.dart';
// The in-memory bus is test infrastructure and not part of the public API.
// ignore: implementation_imports
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

final String sep = Platform.pathSeparator;

class _NoIfaces implements NetworkInterfaceProvider {
  const _NoIfaces();
  @override
  Future<List<LocalInterface>> list() async => const [];
}

Future<bool> _loopbackAliasesWork() async {
  try {
    final s = await ServerSocket.bind(InternetAddress('127.0.0.2'), 0);
    await s.close();
    return true;
  } on Object {
    return false;
  }
}

/// One `runCli` call with its output collected.
class Run {
  Run._(this.args, this._stop);

  final List<String> args;
  final Completer<void> _stop;
  final List<String> out = [];
  final List<String> err = [];
  late final Future<int> code;

  String get stdout => out.join('\n');
  String get stderr => err.join('\n');

  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }

  Future<RegExpMatch> waitForLine(
    RegExp re, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      for (final l in out) {
        final m = re.firstMatch(l);
        if (m != null) return m;
      }
      if (sw.elapsed > timeout) {
        fail('no output line matching $re in $timeout.\n$stdout\n--\n$stderr');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

Future<void> main() async {
  final aliases = await _loopbackAliasesWork();
  late Directory tmp;
  late InMemoryMulticastBus bus;
  final runs = <Run>[];
  var nextHost = 2;

  /// Starts `ls <args>` as the device on the next loopback alias.
  Run cli(List<String> args, {String? ip, bool discovery = true}) {
    final address = ip ?? '127.0.0.${nextHost++}';
    final stop = Completer<void>();
    final run = Run._(args, stop);
    run.code = runCli(
      [...args, '--insecure-plaintext'],
      hooks: CliHooks(
        out: run.out.add,
        err: run.err.add,
        handleSignals: false,
        stop: stop.future,
        bindAddress: InternetAddress(address),
        discovery: discovery
            ? DiscoveryConfig(
                multicastTransport: () => bus.createTransport(address: address),
                interfaces: const _NoIfaces(),
                autoScan: false,
                announceSchedule: const [],
                announceInterval: const Duration(hours: 1),
                interfacePoll: const Duration(hours: 1),
              )
            : DiscoveryConfig.disabled,
      ),
    );
    runs.add(run);
    return run;
  }

  /// Runs a short command to completion.
  Future<Run> finish(List<String> args, {String? ip}) async {
    final r = cli(args, ip: ip);
    await r.code.timeout(const Duration(seconds: 30));
    return r;
  }

  /// A receiver that keeps running until the test ends; returns its port.
  Future<(Run, int)> receiver(
    String alias, {
    List<String> extra = const [],
  }) async {
    final r = cli([
      'receive',
      '--port',
      '0',
      '--dir',
      '${tmp.path}${sep}rx-$alias',
      '--auto-accept',
      '--alias',
      alias,
      ...extra,
    ]);
    final m = await r.waitForLine(RegExp(r'^LISTENING .* port=(\d+) '));
    return (r, int.parse(m.group(1)!));
  }

  File randomFile(String name, int size, int seed) {
    final rnd = Random(seed);
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return File('${tmp.path}$sep$name')..writeAsBytesSync(bytes);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_cli_cmd_');
    bus = InMemoryMulticastBus();
    nextHost = 2;
  });

  tearDown(() async {
    for (final r in runs) {
      r.stop();
    }
    for (final r in runs) {
      await r.code.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('${r.args} did not end after stop()'),
      );
    }
    runs.clear();
    tmp.deleteSync(recursive: true);
  });

  group('in one process, one loopback alias (127.0.0.N) per device', () {
    group('ls info', () {
      test('without --to prints this device, nothing is bound', () async {
        final r = await finish(['info', '--alias', 'me'], ip: '127.0.0.1');
        expect(await r.code, 0, reason: r.stderr);
        expect(
          r.out.first,
          matches(RegExp(r'^me \(\w+\) id=[0-9a-f-]{36} port=0 v=1\.0$')),
        );
        expect(r.out, contains('ADDR 127.0.0.1 unknown'));
        expect(r.stderr, isEmpty);
      });

      test('an unusable --to is still a usage error', () async {
        expect(await runCli(['info', '--to', 'bad']), 64);
      });
    });

    group('ls devices (FR-02)', () {
      test('lists a receiver: text, then the count', () async {
        final (rx, port) = await receiver('rx-text');
        final d = await finish(['devices', '--timeout', '1']);
        expect(await d.code, 0, reason: d.stderr);
        expect(
          d.out.where((l) => l.startsWith('DEVICE ')).single,
          matches(
            RegExp(
              '^DEVICE [0-9a-f-]{36} rx-text \\(\\w+\\) '
              '127\\.0\\.0\\.2:$port via=multicast\$',
            ),
          ),
        );
        expect(d.out.last, 'DEVICES 1');
        rx.stop();
      });

      test('--json is one JSON array and nothing else', () async {
        final (_, port) = await receiver('rx-json');
        final d = await finish(['devices', '--timeout', '1', '--json']);
        expect(await d.code, 0);
        expect(d.out, hasLength(1));
        final list = jsonDecode(d.out.single) as List;
        expect(list, hasLength(1));
        final dev = list.single as Map<String, Object?>;
        expect(dev['alias'], 'rx-json');
        expect(dev['port'], port);
        expect(dev['address'], '127.0.0.2');
        expect(dev['source'], 'multicast');
        expect(dev['id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(dev['lastSeen'], isA<String>());
      });

      test('nobody around: DEVICES 0 / [] and exit 0', () async {
        final text = await finish(['devices', '--timeout', '0.3']);
        expect(await text.code, 0);
        expect(text.out, ['DEVICES 0']);
        final json = await finish(['devices', '--timeout', '0.3', '--json']);
        expect(json.out, ['[]']);
      });

      test('a receiver started with --no-discovery is not listed', () async {
        final (_, port) = await receiver(
          'rx-hidden',
          extra: ['--no-discovery'],
        );
        expect(port, greaterThan(0), reason: 'it still receives');
        final d = await finish(['devices', '--timeout', '0.5']);
        expect(d.out, ['DEVICES 0']);
      });

      test('a send-only device (devices itself) is never listed', () async {
        final listening = cli(['devices', '--listen', '--alias', 'watcher']);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final other = await finish(['devices', '--timeout', '0.5']);
        expect(other.out, ['DEVICES 0']);
        listening.stop();
        expect(await listening.code, 0);
        expect(listening.out, isEmpty);
      });

      test('--listen prints a device as it appears and ends on stop', () async {
        final watcher = cli(['devices', '--listen']);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await receiver('rx-late');
        final m = await watcher.waitForLine(
          RegExp(r'^FOUND ([0-9a-f-]{36}) rx-late '),
        );
        expect(m.group(1), isNotEmpty);
        watcher.stop();
        expect(await watcher.code, 0);
      });

      test('--listen --json prints one JSON object per line', () async {
        final watcher = cli(['devices', '--listen', '--json']);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await receiver('rx-ndjson');
        final m = await watcher.waitForLine(RegExp(r'^\{"event":"found"'));
        final obj = jsonDecode(m.input) as Map<String, Object?>;
        expect((obj['device'] as Map)['alias'], 'rx-ndjson');
        watcher.stop();
        expect(await watcher.code, 0);
      });

      test('--timeout must be a non-negative number', () async {
        for (final bad in ['abc', '-1', 'NaN']) {
          expect(await runCli(['devices', '--timeout', bad]), 64, reason: bad);
        }
      });
    });

    group('ls peer-link', () {
      test('without an argument prints a valid link to this device', () async {
        final r = await finish([
          'peer-link',
          '--alias',
          'linker',
        ], ip: '127.0.0.1');
        expect(await r.code, 0, reason: r.stderr);
        expect(r.out, hasLength(1));
        final link = PeerLink.parse(r.out.single);
        expect(link.ip, '127.0.0.1');
        expect(link.port, greaterThanOrEqualTo(kDefaultPort));
        expect(link.alias, 'linker');
      });

      test('with a link: resolves it through the device and prints it', () async {
        final (rx, port) = await receiver('rx-peer');
        final link = (await rx.waitForLine(
          RegExp(r'^PEER-LINK (libreshare://\S+)$'),
        )).group(1)!;
        final r = await finish(['peer-link', link]);
        expect(await r.code, 0, reason: r.stderr);
        expect(
          r.out.single,
          matches(
            RegExp(
              '^DEVICE [0-9a-f-]{36} rx-peer \\(\\w+\\) 127\\.0\\.0\\.2:$port via=qr\$',
            ),
          ),
        );
      });

      test('a link pinning another device id is refused (exit 1)', () async {
        final (rx, _) = await receiver('rx-pinned');
        final real = PeerLink.parse(
          (await rx.waitForLine(RegExp(r'^PEER-LINK (libreshare://\S+)$')))
              .group(1)!,
        );
        final forged = PeerLink(
          ip: real.ip,
          port: real.port,
          deviceId: '11111111-2222-4333-8444-555555555555',
          alias: 'rx-pinned',
        );
        final r = await finish(['peer-link', forged.toUri()]);
        expect(await r.code, 1);
        expect(r.stderr, contains('DeviceIdMismatch'));
        expect(r.out, isEmpty);
      });

      test('an unreachable device and garbage are told apart', () async {
        final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = gone.port;
        await gone.close();
        final unreachable = await finish([
          'peer-link',
          PeerLink(ip: '127.0.0.1', port: port).toUri(),
        ]);
        expect(await unreachable.code, 1);
        expect(unreachable.stderr, contains('PeerUnreachable'));

        final junk = await finish(['peer-link', 'http://example.com']);
        expect(await junk.code, 64);
        expect(junk.stderr, contains('not a valid'));
        expect(await runCli(['peer-link', 'a', 'b']), 64);
        expect(await runCli(['peer-link', '--port', 'x']), 64);
        expect(await runCli(['peer-link', '--ip', 'not-an-ip']), 64);
      });

      test('receive prints the same kind of link while it serves', () async {
        final (rx, port) = await receiver('rx-prints');
        final link = PeerLink.parse(
          (await rx.waitForLine(RegExp(r'^PEER-LINK (libreshare://\S+)$')))
              .group(1)!,
        );
        expect(link.port, port);
        expect(link.ip, '127.0.0.2');
        expect(link.alias, 'rx-prints');
      });
    });

    group('ls receive modes (FR-18)', () {
      test('default: no window, runs until stopped, exits 0', () async {
        final (rx, _) = await receiver('rx-always');
        expect(rx.out.where((l) => l.startsWith('WINDOW')), isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(rx.out.where((l) => l == 'EXPIRED'), isEmpty);
        rx.stop();
        expect(await rx.code, 0);
      });

      test(
        '--for 2s: WINDOW line, ends by itself with EXPIRED, port closed',
        () async {
          final start = DateTime.now().toUtc();
          final (rx, port) = await receiver('rx-for', extra: ['--for', '2s']);
          final w = await rx.waitForLine(RegExp(r'^WINDOW until=(\S+)$'));
          final until = DateTime.parse(w.group(1)!);
          expect(
            until.difference(start).inMilliseconds,
            inInclusiveRange(1500, 4000),
          );
          expect(await rx.code.timeout(const Duration(seconds: 10)), 0);
          expect(rx.out.last, 'EXPIRED');
          await expectLater(
            Socket.connect(
              '127.0.0.2',
              port,
              timeout: const Duration(seconds: 1),
            ),
            throwsA(isA<SocketException>()),
            reason: 'the listener is closed once the window is over',
          );
        },
      );

      test(
        '--for takes minutes, hours and combinations; --always is the default',
        () async {
          for (final ok in ['30m', '2h', '90s', '1h30m', '15']) {
            final (rx, _) = await receiver(
              'rx-$ok'.replaceAll(RegExp('[^a-z0-9-]'), ''),
              extra: ['--for', ok],
            );
            expect(
              rx.out.any((l) => l.startsWith('WINDOW until=')),
              isTrue,
              reason: ok,
            );
            rx.stop();
            expect(await rx.code, 0, reason: ok);
          }
          final (rx, _) = await receiver('rx-explicit', extra: ['--always']);
          expect(rx.out.where((l) => l.startsWith('WINDOW')), isEmpty);
        },
      );

      test(
        'bad windows and impossible combinations are usage errors',
        () async {
          for (final args in [
            ['--for', 'abc'],
            ['--for', '0'],
            ['--for', '0m'],
            ['--for', '-5m'],
            ['--for', '5x'],
            ['--for', '5m', '--always'],
            ['--visibility', 'contacts'],
            ['--visibility', 'bogus'],
          ]) {
            final r = cli([
              'receive',
              '--port',
              '0',
              '--dir',
              '${tmp.path}${sep}x',
              ...args,
            ]);
            expect(await r.code, 64, reason: '$args');
          }
        },
      );

      test('--visibility contacts says why', () async {
        final r = cli([
          'receive',
          '--visibility',
          'contacts',
          '--dir',
          '${tmp.path}${sep}x',
        ]);
        expect(await r.code, 64);
        expect(r.stderr, contains('pairing'));
      });

      test(
        'a transfer inside the window completes; the window then ends',
        () async {
          final rxDir = '${tmp.path}${sep}rx-window';
          final rx = cli([
            'receive',
            '--port',
            '0',
            '--dir',
            rxDir,
            '--alias',
            'rx-window',
            '--for',
            '3s',
            '--auto-accept',
          ]);
          final port = int.parse(
            (await rx.waitForLine(RegExp(r'port=(\d+) '))).group(1)!,
          );
          final f = randomFile('big.bin', 3 * 1024 * 1024, 11);
          final send = await finish([
            'send',
            '--to',
            '127.0.0.2:$port',
            f.path,
          ]);
          expect(await send.code, 0, reason: '${send.stdout}\n${send.stderr}');
          expect(await rx.code.timeout(const Duration(seconds: 10)), 0);
          expect(rx.out, containsAllInOrder(['COMPLETED', 'EXPIRED']));
          expect(
            File('$rxDir${sep}big.bin').readAsBytesSync(),
            f.readAsBytesSync(),
          );
        },
      );

      test('a port nobody can bind is reported, not thrown', () async {
        final blockers = <ServerSocket>[];
        try {
          for (var p = kDefaultPort; p <= kPortFallbackMax; p++) {
            blockers.add(
              await ServerSocket.bind(InternetAddress('127.0.0.2'), p),
            );
          }
        } on SocketException {
          for (final b in blockers) {
            await b.close();
          }
          markTestSkipped('ports $kDefaultPort..$kPortFallbackMax are in use');
          return;
        }
        addTearDown(() async {
          for (final b in blockers) {
            await b.close();
          }
        });
        final r = cli([
          'receive',
          '--dir',
          '${tmp.path}${sep}x',
        ], ip: '127.0.0.2');
        expect(await r.code, 1);
        expect(r.stderr, contains('receive failed'));
        expect(r.out.where((l) => l.startsWith('LISTENING')), isEmpty);
      });
    });

    group('ls send --device (FR-04)', () {
      test('by alias: found by discovery, sent, byte-identical', () async {
        final (rx, _) = await receiver('rx-target');
        final f = randomFile('hello.bin', 2 * 1024 * 1024 + 123, 21);
        final s = await finish(['send', '--device', 'rx-target', f.path]);
        expect(await s.code, 0, reason: '${s.stdout}\n${s.stderr}');
        expect(s.out.last, 'COMPLETED');
        expect(s.out.any((l) => l.contains('status=COMPLETED')), isTrue);
        expect(
          File('${tmp.path}${sep}rx-rx-target${sep}hello.bin')
              .readAsBytesSync(),
          f.readAsBytesSync(),
        );
        expect(rx.out.where((l) => l.startsWith('RECEIVED ')), hasLength(1));
      });

      test(
        'alias match ignores case; an id prefix of 4+ characters works',
        () async {
          await receiver('Rx-Mixed');
          final f = randomFile('a.bin', 10, 22);
          final byAlias = await finish([
            'send',
            '--device',
            'rX-mIxEd',
            f.path,
          ]);
          expect(await byAlias.code, 0, reason: byAlias.stderr);

          final list = await finish(['devices', '--timeout', '1', '--json']);
          final id =
              ((jsonDecode(list.out.single) as List).single as Map)['id']
                  as String;
          final byPrefix = await finish([
            'send',
            '--device',
            id.substring(0, 6),
            f.path,
          ]);
          expect(await byPrefix.code, 0, reason: byPrefix.stderr);
          final tooShort = await finish([
            'send',
            '--device',
            id.substring(0, 3),
            '--find-timeout',
            '0.5',
            f.path,
          ]);
          expect(await tooShort.code, 1);
        },
      );

      test(
        'an unknown device: exit 1 within the find timeout, nothing sent',
        () async {
          await receiver('rx-other');
          final f = randomFile('b.bin', 10, 23);
          final sw = Stopwatch()..start();
          final s = await finish([
            'send',
            '--device',
            'nobody',
            '--find-timeout',
            '0.6',
            f.path,
          ]);
          expect(await s.code, 1);
          expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
          expect(s.stderr, contains('no device matching "nobody"'));
          expect(s.out.where((l) => l.startsWith('SENT')), isEmpty);
        },
      );

      test(
        'two devices with the same alias: ambiguous (64), the ids are listed',
        () async {
          await receiver('twin');
          await receiver('twin');
          final f = randomFile('c.bin', 10, 24);
          final s = await finish(['send', '--device', 'twin', f.path]);
          expect(await s.code, 64);
          expect(s.stderr, contains('matches 2 devices'));
          expect(
            s.err.where((l) => RegExp(r'^\s+[0-9a-f-]{36} twin ').hasMatch(l)),
            hasLength(2),
          );
        },
      );

      test('a libreshare://peer link works without any discovery', () async {
        final (rx, _) = await receiver('rx-linked');
        final link = (await rx.waitForLine(
          RegExp(r'^PEER-LINK (libreshare://\S+)$'),
        )).group(1)!;
        final f = randomFile('d.bin', 5000, 25);
        final s = await finish(['send', '--device', link, f.path]);
        expect(await s.code, 0, reason: '${s.stdout}\n${s.stderr}');
        expect(s.out.last, 'COMPLETED');
      });

      test(
        '--to and --device together, or neither, are usage errors',
        () async {
          final f = randomFile('e.bin', 10, 26);
          expect(
            await runCli([
              'send',
              '--to',
              '127.0.0.1:1',
              '--device',
              'x',
              f.path,
            ]),
            64,
          );
          expect(await runCli(['send', f.path]), 64);
          expect(
            await runCli(['send', '--device', 'x']),
            64,
            reason: 'no files',
          );
          expect(
            await runCli([
              'send',
              '--device',
              'x',
              '--find-timeout',
              'abc',
              f.path,
            ]),
            64,
          );
        },
      );
    });
  }, skip: aliases ? false : '127.0.0.2 cannot be bound on this host');

  group('real processes over real multicast', () {
    late Directory build;
    late String dill;

    setUpAll(() async {
      var dir = Directory.current.absolute;
      String? entry;
      while (entry == null) {
        for (final rel in [
          ['bin', 'ls.dart'],
          ['packages', 'libreshare_cli', 'bin', 'ls.dart'],
        ]) {
          final f = File([dir.path, ...rel].join(sep));
          if (f.existsSync()) entry = f.path;
        }
        if (dir.parent.path == dir.path) break;
        dir = dir.parent;
      }
      if (entry == null) throw StateError('bin/ls.dart not found');
      build = Directory.systemTemp.createTempSync('ls_cli_cmd_build_');
      dill = '${build.path}${sep}ls.dill';
      final r = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        entry,
        '-o',
        dill,
      ]);
      if (r.exitCode != 0) fail('compile failed:\n${r.stdout}\n${r.stderr}');
    });
    tearDownAll(() => build.deleteSync(recursive: true));

    Future<(int, String, String)> ls(List<String> args) async {
      final p = await Process.run(Platform.resolvedExecutable, [dill, ...args]);
      return (p.exitCode, '${p.stdout}', '${p.stderr}');
    }

    test(
      'devices finds a running receiver and send --device delivers to it',
      () async {
        final rxDir = Directory('${tmp.path}${sep}proc-rx');
        final receiver = await Process.start(Platform.resolvedExecutable, [
          dill,
          'receive',
          '--port',
          '0',
          '--dir',
          rxDir.path,
          '--auto-accept',
          '--once',
          '--alias',
          'proc-rx-e2e',
          '--insecure-plaintext',
        ]);
        final lines = <String>[];
        receiver.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(lines.add);
        unawaited(receiver.stderr.drain<void>());
        addTearDown(receiver.kill);
        final sw = Stopwatch()..start();
        while (!lines.any((l) => l.startsWith('LISTENING'))) {
          if (sw.elapsed > const Duration(seconds: 15)) {
            fail('receiver did not start:\n${lines.join('\n')}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        final (code, out, err) = await ls([
          'devices',
          '--timeout',
          '3',
          '--json',
          '--insecure-plaintext',
        ]);
        expect(code, 0, reason: err);
        final found = (jsonDecode(out) as List)
            .cast<Map<String, Object?>>()
            .where((d) => d['alias'] == 'proc-rx-e2e')
            .toList();
        if (found.isEmpty) {
          markTestSkipped(
            'multicast is not delivered on this host (the in-process tests cover the logic)',
          );
          return;
        }
        expect(found.single['source'], 'multicast');

        final f = randomFile('proc.bin', 1024 * 1024 + 7, 31);
        final (sendCode, sendOut, sendErr) = await ls([
          'send',
          '--device',
          'proc-rx-e2e',
          '--insecure-plaintext',
          f.path,
        ]);
        expect(sendCode, 0, reason: '$sendOut\n$sendErr');
        expect(await receiver.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(
          File('${rxDir.path}${sep}proc.bin').readAsBytesSync(),
          f.readAsBytesSync(),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
