// Speed wave S2 (tester): behaviours 6, 7 (receiver disposes) and 8 of
// docs/plans/inc4-speed-seams.md, with the new provider machinery active.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/transfer/native_sha256.dart';
import 'package:test/test.dart';

import '../helpers/s2_verification_scenarios.dart';

/// Wraps a real incremental provider and counts start / dispose of every
/// incremental the receiver (or anyone) creates.
class CountingProvider implements IncrementalSha256Provider {
  CountingProvider(this.inner);
  final IncrementalSha256Provider inner;
  int started = 0;
  int disposed = 0;
  int finished = 0;

  @override
  String hashBytes(List<int> bytes) => inner.hashBytes(bytes);

  @override
  Future<String> hashStream(Stream<List<int>> input) => inner.hashStream(input);

  @override
  Sha256Incremental startIncremental() {
    started++;
    return _Counted(inner.startIncremental(), this);
  }
}

class _Counted implements Sha256Incremental {
  _Counted(this._inner, this._owner);
  final Sha256Incremental _inner;
  final CountingProvider _owner;
  bool _disposed = false;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  String finishHex() {
    _owner.finished++;
    return _inner.finishHex();
  }

  @override
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _owner.disposed++;
    }
    _inner.dispose();
  }
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  final original = activeSha256Provider;
  tearDown(() => activeSha256Provider = original);

  final nativeExpected =
      Platform.environment['LS_NO_NATIVE_SHA'] != '1' &&
      tryLoadNativeSha256() != null;

  for (final allowNative in [true, false]) {
    group('receiver verification, installBestSha256Provider(allowNative: '
        '$allowNative)', () {
      setUp(() => installBestSha256Provider(allowNative: allowNative));
      defineReceiverVerificationTests();
    });

    test(
      'engine -> engine 24 MiB (6 x 4 MiB) arrives byte-identical, '
      'allowNative=$allowNative',
      () => engineRoundTrip24MiB(
        beforeSend: () => installBestSha256Provider(allowNative: allowNative),
      ),
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  group('behaviour 8: the engine installs the best provider', () {
    test(
      'constructing LibreShareEngine replaces the default provider',
      () async {
        activeSha256Provider = const PureDartSha256Provider();
        final tmp = Directory.systemTemp.createTempSync('ls_s2_eng8_');
        final eng = newLoopbackEngine('e', tmp);
        try {
          if (nativeExpected) {
            expect(
              activeSha256Provider,
              isNot(isA<PureDartSha256Provider>()),
              reason:
                  'a native provider loads here, the engine must install it',
            );
            expect(activeSha256Provider, isA<NativeSha256Provider>());
          } else {
            expect(activeSha256Provider, isA<IncrementalSha256Provider>());
          }
          final first = activeSha256Provider;
          final eng2 = newLoopbackEngine('e2', tmp);
          expect(activeSha256Provider.runtimeType, first.runtimeType);
          await eng2.dispose(force: true);
        } finally {
          await eng.dispose(force: true);
          tmp.deleteSync(recursive: true);
        }
      },
    );
  });

  group('behaviour 6/7: the receiver hashes through newSha256Incremental() '
      'and disposes every incremental', () {
    late CountingProvider counting;
    final rig = RxRig();

    setUp(() {
      counting = CountingProvider(const PureDartSha256Provider());
      activeSha256Provider = counting;
      rig.setUp();
    });
    tearDown(rig.tearDown);

    test(
      'in-order transfer: >= 1 incremental per chunk, all disposed',
      () async {
        final rx = rig.newReceiver();
        final (sid, tok) = await rig.open(rx);
        for (var i = 0; i < Content.big.chunkCount; i++) {
          await rig.sendChunk(rx, sid, tok, i);
        }
        await rx.completeFile(sid, 'f', token: tok);
        await rx.finish(sid);
        await settle();
        expect(
          counting.started,
          greaterThanOrEqualTo(Content.big.chunkCount),
          reason: 'the per-chunk digest must come from newSha256Incremental()',
        );
        expect(counting.disposed, counting.started, reason: 'leaked contexts');
      },
    );

    test('tampered chunk (error path) leaks no incremental', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      await rig.sendChunk(rx, sid, tok, 0);
      final bad = Uint8List.fromList(Content.big.chunk(1))..[12345] ^= 1;
      await expectLater(
        rig.sendChunk(rx, sid, tok, 1, body: bad),
        throwsA(isA<LsException>()),
      );
      await settle();
      expect(counting.started, greaterThan(0));
      // the running whole-file hasher may legitimately be open until the file
      // ends or the session is torn down: finish the transfer, then compare
      for (var i = 1; i < Content.big.chunkCount; i++) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      await rx.completeFile(sid, 'f', token: tok);
      await rx.finish(sid);
      await settle();
      expect(counting.disposed, counting.started, reason: 'leaked contexts');
    });

    test('body stream that throws mid-chunk leaks no incremental', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      Stream<List<int>> boom() async* {
        yield Uint8List.sublistView(Content.big.chunk(0), 0, 100000);
        throw StateError('connection died');
      }

      await expectLater(
        rx.putChunk(
          sid,
          'f',
          0,
          boom(),
          token: tok,
          chunkSha256: Content.big.chunkHashes[0],
        ),
        throwsA(anything),
      );
      for (var i = 0; i < Content.big.chunkCount; i++) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      await rx.completeFile(sid, 'f', token: tok);
      await rx.finish(sid);
      await settle();
      expect(counting.disposed, counting.started, reason: 'leaked contexts');
    });

    test('too-short body leaks no incremental', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      await expectLater(
        rig.sendChunk(
          rx,
          sid,
          tok,
          0,
          body: Uint8List.sublistView(Content.big.chunk(0), 0, 4096),
        ),
        throwsA(isA<LsException>()),
      );
      for (var i = 0; i < Content.big.chunkCount; i++) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      await rx.completeFile(sid, 'f', token: tok);
      await rx.finish(sid);
      await settle();
      expect(counting.disposed, counting.started, reason: 'leaked contexts');
    });

    test('wrong whole-file hash (FAILED) leaks no incremental', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx, manifestSha: 'b' * 64);
      for (var i = 0; i < Content.big.chunkCount; i++) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      await expectLater(
        rx.completeFile(sid, 'f', token: tok),
        throwsA(isA<LsException>()),
      );
      await settle();
      expect(counting.disposed, counting.started, reason: 'leaked contexts');
    });

    test('out-of-order transfer completes and leaks no incremental', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      for (final i in [3, 0, 1, 2, 5, 4]) {
        await rig.sendChunk(rx, sid, tok, i);
      }
      final v = await rx.completeFile(sid, 'f', token: tok);
      expect(v.sha256, Content.big.wholeHash);
      await rx.finish(sid);
      await settle();
      expect(counting.disposed, counting.started, reason: 'leaked contexts');
    });

    test('session cancelled mid-file (running whole-file hasher open) leaks '
        'no incremental', () async {
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx);
      await rig.sendChunk(rx, sid, tok, 0);
      await rig.sendChunk(rx, sid, tok, 1);
      await rx.cancel(sid);
      await settle();
      expect(counting.started, greaterThan(0));
      expect(counting.disposed, counting.started, reason: 'leaked contexts');
    });
  });

  group('M9 (receiver): the out-of-order whole-file re-hash uses the best '
      'provider inside its isolate', () {
    final rig = RxRig();
    setUp(rig.setUp);
    tearDown(rig.tearDown);

    test('completeFile on 96 MiB (running hash disabled) is faster than '
        'package:crypto over the same bytes (or pure Dart is the best '
        'provider)', () async {
      final best = installBestSha256Provider();
      final content = Content.of(seededBytes(96 * 1024 * 1024, 77));
      final rx = rig.newReceiver();
      final (sid, tok) = await rig.open(rx, content: content);
      final order = [1, 0, for (var i = 2; i < content.chunkCount; i++) i];
      for (final i in order) {
        await rig.sendChunk(rx, sid, tok, i, content: content);
      }
      final sw = Stopwatch()..start();
      final v = await rx.completeFile(sid, 'f', token: tok);
      final completeMicros = sw.elapsedMicroseconds;
      expect(v.sha256, content.wholeHash);
      expect(rig.finalFile('big.bin').lengthSync(), content.data.length);
      sw
        ..reset()
        ..start();
      crypto.sha256.convert(content.data);
      final pureMicros = sw.elapsedMicroseconds;
      if (tryLoadNativeSha256() == null) {
        expect(best, isA<PureDartSha256Provider>());
      } else if (Platform.environment['LS_NO_NATIVE_SHA'] != '1') {
        expect(
          pureMicros / completeMicros,
          greaterThanOrEqualTo(1.5),
          reason:
              'completeFile took ${completeMicros ~/ 1000} ms, pure Dart '
              'needs ${pureMicros ~/ 1000} ms for the same bytes: the '
              'fallback isolate still hashes in pure Dart?',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
