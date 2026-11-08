// Speed modes on the engine (docs/plans/inc4-speed.md section 3). The mode is
// a LOCAL setting of the sending engine: it picks how many chunks of one file
// are PUT in parallel, when the caller does not pass `chunkConcurrency`.
//
// How concurrency is observed: an HTTP proxy in front of the receiver
// (InflightProxy below) counts the chunk PUTs that are in progress at once
// and holds each PUT for a fixed delay, so the peak is a property of the
// sender and not of timing luck. An explicit `chunkConcurrency` still wins.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/test_data.dart';

const String _loopback = '127.0.0.1';

/// 40 MiB = 10 chunks of kChunkSize (4 MiB): enough for turbo (8) to show.
const int _fileSize = 40 * 1024 * 1024;
const int _chunks = 10;

/// Plain HTTP proxy in front of a receiver. Counts chunk PUTs in progress
/// (request arrived, response not yet sent) and holds each one for [hold].
class InflightProxy {
  InflightProxy._(this._server, this._target, this.hold);

  static Future<InflightProxy> start({
    required int targetPort,
    Duration hold = const Duration(milliseconds: 40),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = InflightProxy._(server, targetPort, hold);
    server.listen(proxy._handle);
    return proxy;
  }

  final HttpServer _server;
  final int _target;
  final Duration hold;
  final HttpClient _client = HttpClient();

  int get port => _server.port;

  /// Chunk PUTs in progress right now.
  int inFlight = 0;

  /// Highest [inFlight] seen since the last [resetPeak].
  int peak = 0;

  /// Chunk PUTs seen since the start.
  int chunkPuts = 0;

  void resetPeak() => peak = 0;

  static const Set<String> _hopByHop = {
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
      if (isChunk) await Future<void>.delayed(hold);
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
      req.headers.forEach((name, values) {
        if (!_hopByHop.contains(name)) {
          for (final v in values) {
            out.headers.add(name, v);
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
      resp.headers.forEach((name, values) {
        if (!_hopByHop.contains(name)) {
          for (final v in values) {
            req.response.headers.add(name, v);
          }
        }
      });
      req.response.contentLength = answer.length;
      req.response.add(answer);
      await req.response.close();
    } on Object {
      // A torn request is the sender's problem; the test sees it as a failure.
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

LibreShareEngine _engine(String name, Directory dl, {SpeedMode? mode}) =>
    LibreShareEngine(
      self: DeviceInfo(
        deviceId: 'device-$name',
        alias: 'Engine-$name',
        platform: 'linux',
      ),
      downloadDir: dl,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
      speedMode: mode ?? kDefaultSpeedMode,
    );

void main() {
  late Directory sandbox;
  late LibreShareEngine tx;
  late LibreShareEngine rx;
  late InflightProxy proxy;
  late Directory rxDir;
  late Directory srcDir;
  var seq = 0;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('ls_speed_engine_');
    rxDir = Directory(p.join(sandbox.path, 'rx'));
    srcDir = Directory(p.join(sandbox.path, 'src'));
    tx = _engine('tx', Directory(p.join(sandbox.path, 'tx-dl')));
    rx = _engine('rx', rxDir);
    await tx.start();
    await rx.start();
    proxy = await InflightProxy.start(targetPort: rx.port);
  });

  tearDown(() async {
    await proxy.close();
    await tx.dispose(force: true);
    await rx.dispose(force: true);
    sandbox.deleteSync(recursive: true);
  });

  /// A fresh many-chunk source file; each test gets its own name.
  File bigFile() {
    seq++;
    return writeRandomFile(srcDir, 'big-$seq.bin', _fileSize, seed: seq);
  }

  /// Sends [f] from [sender] through the proxy and checks the bytes at the
  /// receiver. Returns the peak number of chunk PUTs in progress.
  Future<int> sendAndCheck(
    LibreShareEngine sender,
    File f, {
    int? chunkConcurrency,
  }) async {
    proxy.resetPeak();
    final before = proxy.chunkPuts;
    final res = await sender.sendFiles(
      [f],
      host: _loopback,
      port: proxy.port,
      chunkConcurrency: chunkConcurrency ?? kChunkConcurrencyFromProfile,
    );
    expect(res.status, TransferStatus.completed, reason: 'send result');
    expect(
      proxy.chunkPuts - before,
      _chunks,
      reason: 'the proxy must see every chunk of the file',
    );
    final got = File(p.join(rxDir.path, p.basename(f.path)));
    expect(got.existsSync(), isTrue, reason: 'received file exists');
    expect(
      await sha256OfFileHex(got),
      await sha256OfFileHex(f),
      reason: 'byte-identical in every mode',
    );
    expect(await filesIdentical(f, got), isTrue);
    return proxy.peak;
  }

  group('speedMode option and accessors', () {
    test('an engine without the option runs balanced', () async {
      final e = _engine('defaults', Directory(p.join(sandbox.path, 'd')));
      addTearDown(() => e.dispose(force: true));
      expect(e.speedMode, SpeedMode.balanced);
    });

    test('the constructor option is read back', () async {
      final e = _engine(
        'turbo-opt',
        Directory(p.join(sandbox.path, 't')),
        mode: SpeedMode.turbo,
      );
      addTearDown(() => e.dispose(force: true));
      expect(e.speedMode, SpeedMode.turbo);
    });

    test('the setter changes the mode of a running engine', () {
      expect(tx.speedMode, SpeedMode.balanced);
      tx.speedMode = SpeedMode.eco;
      expect(tx.speedMode, SpeedMode.eco);
      tx.speedMode = SpeedMode.turbo;
      expect(tx.speedMode, SpeedMode.turbo);
    });
  });

  group('the mode sets chunk concurrency when the caller passes none', () {
    test('eco: never more than one chunk in flight', () async {
      final e = _engine(
        'eco',
        Directory(p.join(sandbox.path, 'eco-dl')),
        mode: SpeedMode.eco,
      );
      await e.start();
      addTearDown(() => e.dispose(force: true));
      final peak = await sendAndCheck(e, bigFile());
      expect(peak, lessThanOrEqualTo(1));
      expect(peak, 1, reason: 'eco is sequential, the proxy saw 1 at a time');
    });

    test(
      'balanced (default): at most three, and really parallel (>= 2)',
      () async {
        final peak = await sendAndCheck(tx, bigFile());
        expect(peak, lessThanOrEqualTo(3));
        expect(peak, greaterThanOrEqualTo(2));
      },
    );

    test(
      'turbo: really exceeds balanced (>= 4 in flight, at most 8)',
      () async {
        tx.speedMode = SpeedMode.turbo;
        final peak = await sendAndCheck(tx, bigFile());
        expect(peak, greaterThanOrEqualTo(4));
        expect(peak, lessThanOrEqualTo(8));
      },
    );
  });

  group('an explicit chunkConcurrency still wins over the mode', () {
    test('turbo engine, chunkConcurrency: 2 -> at most 2 in flight', () async {
      tx.speedMode = SpeedMode.turbo;
      final peak = await sendAndCheck(tx, bigFile(), chunkConcurrency: 2);
      expect(peak, lessThanOrEqualTo(2));
      expect(peak, greaterThanOrEqualTo(1));
    });

    test('eco engine, chunkConcurrency: 4 -> more than eco allows', () async {
      tx.speedMode = SpeedMode.eco;
      final peak = await sendAndCheck(tx, bigFile(), chunkConcurrency: 4);
      expect(
        peak,
        greaterThanOrEqualTo(2),
        reason: 'an explicit 4 must not be clamped to the eco profile',
      );
    });
  });

  group('changing the mode affects the NEXT send only', () {
    test('turbo send, then eco send on the same engine', () async {
      tx.speedMode = SpeedMode.turbo;
      final first = await sendAndCheck(tx, bigFile());
      expect(first, greaterThanOrEqualTo(4), reason: 'first send is turbo');

      tx.speedMode = SpeedMode.eco;
      final second = await sendAndCheck(tx, bigFile());
      expect(second, lessThanOrEqualTo(1), reason: 'second send is eco');
    });

    test('a mode change while a send runs does not break that send', () async {
      tx.speedMode = SpeedMode.turbo;
      final f = bigFile();
      proxy.resetPeak();
      final running = tx.beginSendFiles([f], host: _loopback, port: proxy.port);
      final sw = Stopwatch()..start();
      while (proxy.inFlight < 4 && sw.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      tx.speedMode = SpeedMode.eco;
      final res = await running.result;
      expect(res.status, TransferStatus.completed);
      expect(
        proxy.peak,
        greaterThanOrEqualTo(4),
        reason: 'the running turbo send keeps its parallelism',
      );
      final got = File(p.join(rxDir.path, p.basename(f.path)));
      expect(await sha256OfFileHex(got), await sha256OfFileHex(f));
    });
  });
}
