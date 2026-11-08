// `ls send --speed eco|balanced|turbo` (docs/plans/inc4-speed.md section 3).
//
// Everything runs in one process through runCli(hooks), on loopback. The
// receiver is a plain `ls receive` (no speed option: receive-side speed is
// not negotiated). The sender's chunk concurrency is observed the same way as
// in core's speed_mode_engine_test: an HTTP proxy in front of the receiver
// counts the chunk PUTs in progress at once.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

final String sep = Platform.pathSeparator;

const String _loopback = '127.0.0.1';

/// 40 MiB = 10 chunks of 4 MiB.
const int _size = 40 * 1024 * 1024;
const int _chunks = 10;

/// Plain HTTP proxy in front of the receiver; counts chunk PUTs in progress.
class _InflightProxy {
  _InflightProxy._(this._server, this._target);

  static Future<_InflightProxy> start(int target) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final p = _InflightProxy._(server, target);
    server.listen(p._handle);
    return p;
  }

  final HttpServer _server;
  final int _target;
  final HttpClient _client = HttpClient();
  int get port => _server.port;
  int inFlight = 0;
  int peak = 0;
  int chunkPuts = 0;

  static const Set<String> _hop = {
    'host',
    'content-length',
    'transfer-encoding',
    'connection',
    'keep-alive',
    'accept-encoding',
  };

  Future<void> _handle(HttpRequest req) async {
    final isChunk = req.method == 'PUT' && req.uri.path.contains('/chunks/');
    if (isChunk) {
      chunkPuts++;
      inFlight++;
      if (inFlight > peak) peak = inFlight;
    }
    try {
      final body = <int>[];
      await for (final b in req) {
        body.addAll(b);
      }
      if (isChunk) await Future<void>.delayed(const Duration(milliseconds: 40));
      final out = await _client.openUrl(
        req.method,
        Uri(
          scheme: 'http',
          host: _loopback,
          port: _target,
          path: req.uri.path,
          query: req.uri.hasQuery ? req.uri.query : null,
        ),
      );
      req.headers.forEach((n, vs) {
        if (!_hop.contains(n)) {
          for (final v in vs) {
            out.headers.add(n, v);
          }
        }
      });
      out.contentLength = body.length;
      out.add(body);
      final resp = await out.close();
      final answer = <int>[];
      await for (final b in resp) {
        answer.addAll(b);
      }
      req.response.statusCode = resp.statusCode;
      resp.headers.forEach((n, vs) {
        if (!_hop.contains(n)) {
          for (final v in vs) {
            req.response.headers.add(n, v);
          }
        }
      });
      req.response.contentLength = answer.length;
      req.response.add(answer);
      await req.response.close();
    } on Object {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } on Object {
        // already closed
      }
    } finally {
      if (isChunk) inFlight--;
    }
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}

/// One runCli call with its output collected.
class _Run {
  _Run(this.code, this.out, this.err);
  final Future<int> code;
  final List<String> out;
  final List<String> err;
  String get stdout => out.join('\n');
  String get stderr => err.join('\n');
}

void main() {
  late Directory tmp;
  late Directory rxDir;
  late Directory srcDir;
  late _InflightProxy proxy;
  late Completer<void> stopReceiver;
  late Future<int> receiverCode;
  var seq = 0;

  CliHooks hooks(List<String> out, List<String> err, {Future<void>? stop}) =>
      CliHooks(
        out: out.add,
        err: err.add,
        handleSignals: false,
        stop: stop,
        bindAddress: InternetAddress.loopbackIPv4,
        discovery: DiscoveryConfig.disabled,
      );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ls_speed_cli_');
    rxDir = Directory('${tmp.path}${sep}rx');
    srcDir = Directory('${tmp.path}${sep}src');
    seq = 0;
    stopReceiver = Completer<void>();
    final rxOut = <String>[];
    final rxErr = <String>[];
    // A plain receiver: no speed option at all.
    receiverCode = runCli([
      'receive',
      '--port',
      '0',
      '--dir',
      rxDir.path,
      '--auto-accept',
      '--no-discovery',
      '--insecure-plaintext',
    ], hooks: hooks(rxOut, rxErr, stop: stopReceiver.future));
    final sw = Stopwatch()..start();
    int? port;
    while (port == null) {
      for (final l in rxOut) {
        final m = RegExp(r'^LISTENING .* port=(\d+) ').firstMatch(l);
        if (m != null) port = int.parse(m.group(1)!);
      }
      if (port != null) break;
      if (sw.elapsed > const Duration(seconds: 10)) {
        fail(
          'receiver did not listen:\n${rxOut.join('\n')}\n${rxErr.join('\n')}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    proxy = await _InflightProxy.start(port);
  });

  tearDown(() async {
    await proxy.close();
    if (!stopReceiver.isCompleted) stopReceiver.complete();
    await receiverCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('receiver did not end after stop()'),
    );
    tmp.deleteSync(recursive: true);
  });

  File bigFile() {
    seq++;
    final rnd = Random(seq);
    final bytes = Uint8List(_size);
    for (var i = 0; i < _size; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    srcDir.createSync(recursive: true);
    return File('${srcDir.path}${sep}s$seq.bin')..writeAsBytesSync(bytes);
  }

  /// `ls send --to <proxy> --insecure-plaintext [args] <file>`; returns the
  /// run plus the peak of chunk PUTs in progress during it.
  Future<(_Run, int, File)> send(List<String> args, {File? file}) async {
    final f = file ?? bigFile();
    proxy.peak = 0;
    proxy.chunkPuts = 0;
    final out = <String>[];
    final err = <String>[];
    final code = runCli([
      'send',
      '--to',
      '$_loopback:${proxy.port}',
      '--insecure-plaintext',
      ...args,
      f.path,
    ], hooks: hooks(out, err));
    final run = _Run(code, out, err);
    final rc = await code.timeout(const Duration(seconds: 60));
    expect(rc, 0, reason: 'exit code; stderr:\n${run.stderr}');
    expect(run.out.last, 'COMPLETED', reason: 'stdout:\n${run.stdout}');
    expect(proxy.chunkPuts, _chunks, reason: 'the proxy saw every chunk');
    final got = File('${rxDir.path}$sep${f.uri.pathSegments.last}');
    expect(got.existsSync(), isTrue, reason: 'received copy exists');
    expect(
      got.readAsBytesSync(),
      f.readAsBytesSync(),
      reason: 'byte-identical in every mode',
    );
    return (run, proxy.peak, f);
  }

  group('ls send --speed (accepted values, observable effect)', () {
    test('eco: accepted, one chunk in flight', () async {
      final (_, peak, _) = await send(['--speed', 'eco']);
      expect(peak, lessThanOrEqualTo(1));
      expect(peak, 1, reason: 'eco is sequential');
    });

    test('slow is an alias of eco: one chunk in flight', () async {
      final (_, peak, _) = await send(['--speed', 'slow']);
      expect(peak, lessThanOrEqualTo(1));
    });

    test('balanced: at most three, really parallel', () async {
      final (_, peak, _) = await send(['--speed', 'balanced']);
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThanOrEqualTo(2));
    });

    test('turbo: really exceeds balanced (>= 4 in flight)', () async {
      final (_, peak, _) = await send(['--speed', 'turbo']);
      expect(peak, greaterThanOrEqualTo(4));
      expect(peak, lessThanOrEqualTo(8));
    });

    test('fast is an alias of turbo: >= 4 in flight', () async {
      final (_, peak, _) = await send(['--speed', 'fast']);
      expect(peak, greaterThanOrEqualTo(4));
    });

    test('the value is case-insensitive', () async {
      final (_, peak, _) = await send(['--speed', 'TURBO']);
      expect(peak, greaterThanOrEqualTo(4));
    });
  });

  group('ls send --speed defaults and precedence', () {
    test(
      'no --speed flag means balanced (at most 3, at least 2 in flight)',
      () async {
        final (_, peak, _) = await send([]);
        expect(peak, lessThanOrEqualTo(3));
        expect(peak, greaterThanOrEqualTo(2));
      },
    );

    test('an explicit --concurrency 2 wins over --speed turbo', () async {
      final (_, peak, _) = await send([
        '--speed',
        'turbo',
        '--concurrency',
        '2',
      ]);
      expect(peak, lessThanOrEqualTo(2));
    });

    test('an explicit --concurrency 3 wins over --speed eco', () async {
      final (_, peak, _) = await send(['--speed', 'eco', '--concurrency', '3']);
      expect(
        peak,
        greaterThanOrEqualTo(2),
        reason: '--concurrency must not be clamped to the eco profile',
      );
    });
  });

  group('ls send --speed usage errors', () {
    test(
      'an unknown value exits 64 and names the valid values on stderr',
      () async {
        final f = bigFile();
        final out = <String>[];
        final err = <String>[];
        final rc = await runCli([
          'send',
          '--to',
          '$_loopback:${proxy.port}',
          '--insecure-plaintext',
          '--speed',
          'warp',
          f.path,
        ], hooks: hooks(out, err));
        expect(rc, 64);
        final text = err.join('\n').toLowerCase();
        for (final name in ['eco', 'balanced', 'turbo']) {
          expect(text, contains(name), reason: 'stderr must name "$name"');
        }
        expect(proxy.chunkPuts, 0, reason: 'nothing is sent on a usage error');
        expect(
          File('${rxDir.path}$sep${f.uri.pathSegments.last}').existsSync(),
          isFalse,
        );
      },
    );

    test('--speed is listed in ls send --help, with its values', () async {
      final out = <String>[];
      final err = <String>[];
      final rc = await runCli(['send', '--help'], hooks: hooks(out, err));
      expect(rc, 0, reason: 'stderr:\n${err.join('\n')}');
      final text = out.join('\n');
      expect(text, contains('--speed'));
      expect(text, contains('turbo'));
      expect(text, contains('eco'));
    });
  });

  group('ls send --concurrency must be a whole number of 1 or more', () {
    for (final bad in ['0', 'abc']) {
      test('--concurrency $bad exits 64 and says so on stderr', () async {
        final f = bigFile();
        final out = <String>[];
        final err = <String>[];
        final rc = await runCli([
          'send',
          '--to',
          '$_loopback:${proxy.port}',
          '--insecure-plaintext',
          '--concurrency',
          bad,
          f.path,
        ], hooks: hooks(out, err));
        expect(rc, 64);
        expect(err.join('\n').toLowerCase(), contains('concurrency'));
        expect(proxy.chunkPuts, 0, reason: 'nothing is sent on a usage error');
      });
    }
  });

  group('receive needs no speed option', () {
    test('a default receiver takes a turbo send byte-identical', () async {
      // The receiver above has no speed option; only the sender chose turbo.
      final (_, peak, _) = await send(['--speed', 'turbo']);
      expect(peak, greaterThanOrEqualTo(4));
    });
  });
}
