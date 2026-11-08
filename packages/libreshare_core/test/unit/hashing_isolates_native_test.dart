// Speed wave S2 (tester): behaviour 5 + M9 of docs/plans/inc4-speed-seams.md.
// sha256OfFile / sha256OfChunk run in spawned isolates (fresh globals): they
// must pick up the best provider INSIDE the isolate, and stay correct.
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:libreshare_core/src/transfer/hashing.dart';
import 'package:libreshare_core/src/transfer/native_sha256.dart';
import 'package:test/test.dart';

const int mib = 1024 * 1024;

Uint8List seeded(int n, int seed) {
  final r = Random(seed);
  final b = Uint8List(n);
  final w = b.buffer.asUint32List(0, n ~/ 4);
  for (var i = 0; i < w.length; i++) {
    w[i] = r.nextInt(0x100000000);
  }
  for (var i = w.length * 4; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

String ref(List<int> b) => crypto.sha256.convert(b).toString();

/// Pure-Dart reference timing, independent of the code under test.
Future<(String, int)> timedPureFile(File f, [int? start, int? end]) async {
  final sw = Stopwatch()..start();
  final d = await crypto.sha256.bind(f.openRead(start, end)).first;
  return (d.toString(), sw.elapsedMicroseconds);
}

String _freshIsolateBest() {
  final p = installBestSha256Provider();
  return p.runtimeType.toString();
}

void main() {
  final original = activeSha256Provider;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ls_s2_isoN_'));
  tearDown(() {
    activeSha256Provider = original;
    tmp.deleteSync(recursive: true);
  });

  final native = tryLoadNativeSha256();

  for (final allowNative in [true, false]) {
    group('provider installed in the caller: allowNative=$allowNative', () {
      setUp(() => installBestSha256Provider(allowNative: allowNative));

      test('sha256OfFile digests: 0-byte, 4 MiB + 1, 20 MiB', () async {
        for (final size in [0, 4 * mib + 1, 20 * mib]) {
          final data = seeded(size, size + 1);
          final f = File('${tmp.path}/f$size.bin')..writeAsBytesSync(data);
          expect(await sha256OfFile(f), ref(data), reason: 'size $size');
        }
      });

      test(
        'sha256OfChunk digests (4 MiB chunks of 4 MiB + 1 and 20 MiB)',
        () async {
          for (final size in [4 * mib + 1, 20 * mib]) {
            final data = seeded(size, size + 2);
            final f = File('${tmp.path}/c$size.bin')..writeAsBytesSync(data);
            for (final r in const Chunker(4 * mib).ranges(size)) {
              expect(
                await sha256OfChunk(f, r),
                ref(Uint8List.sublistView(data, r.start, r.end)),
                reason: '$r',
              );
            }
          }
        },
      );

      test('missing file and short file keep their exceptions', () async {
        await expectLater(
          sha256OfFile(File('${tmp.path}/nope')),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          sha256OfChunk(
            File('${tmp.path}/nope'),
            const ChunkRange(0, 0, 4 * mib),
          ),
          throwsA(isA<FileSystemException>()),
        );
        final f = File('${tmp.path}/short.bin')
          ..writeAsBytesSync(seeded(4 * mib + 100, 7));
        await expectLater(
          sha256OfChunk(f, const Chunker(4 * mib).range(8 * mib, 1)),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.message,
              'message',
              'File shorter than expected: chunk 1 has 100 of 4194304 bytes',
            ),
          ),
        );
      });
    });
  }

  test('a fresh isolate (new globals) can install the best provider', () async {
    final name = await Isolate.run(_freshIsolateBest);
    if (native != null) {
      expect(name, isNot('PureDartSha256Provider'));
    }
    expect(
      name,
      Platform.environment['LS_NO_NATIVE_SHA'] == '1' || native == null
          ? 'PureDartSha256Provider'
          : isNot('PureDartSha256Provider'),
    );
  });

  group('M9 speed guard: isolate functions use the best provider', () {
    test('sha256OfFile on 64 MiB is >= 3x faster than package:crypto '
        '(or pure Dart is the best provider)', () async {
      final f = File('${tmp.path}/big.bin')
        ..writeAsBytesSync(seeded(64 * mib, 31));
      final best = installBestSha256Provider();
      final (want, pureMicros) = await timedPureFile(f);
      if (native == null) {
        expect(best, isA<PureDartSha256Provider>());
        expect(await sha256OfFile(f), want);
        return;
      }
      var bestMicros = 1 << 62;
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        expect(await sha256OfFile(f), want);
        bestMicros = min(bestMicros, sw.elapsedMicroseconds);
      }
      final ratio = pureMicros / bestMicros;
      expect(
        ratio,
        greaterThanOrEqualTo(3),
        reason:
            'sha256OfFile: ${(64e6 / bestMicros).toStringAsFixed(0)} MiB/s vs '
            'pure ${(64e6 / pureMicros).toStringAsFixed(0)} MiB/s '
            '(ratio ${ratio.toStringAsFixed(1)}); the isolate keeps using '
            'pure Dart?',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('sha256OfChunk on a 32 MiB range at offset 1 MiB is >= 3x faster '
        'than package:crypto (or pure Dart is the best provider)', () async {
      final data = seeded(40 * mib, 32);
      final f = File('${tmp.path}/big2.bin')..writeAsBytesSync(data);
      final best = installBestSha256Provider();
      final (want, pureMicros) = await timedPureFile(f, mib, 33 * mib);
      expect(want, ref(Uint8List.sublistView(data, mib, 33 * mib)));
      final range = ChunkRange(1, mib, 33 * mib);
      if (native == null) {
        expect(best, isA<PureDartSha256Provider>());
        expect(await sha256OfChunk(f, range), want);
        return;
      }
      var bestMicros = 1 << 62;
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        expect(await sha256OfChunk(f, range), want);
        bestMicros = min(bestMicros, sw.elapsedMicroseconds);
      }
      final ratio = pureMicros / bestMicros;
      expect(
        ratio,
        greaterThanOrEqualTo(3),
        reason:
            'sha256OfChunk ratio ${ratio.toStringAsFixed(1)} (need >= 3); the '
            'isolate keeps using pure Dart?',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
