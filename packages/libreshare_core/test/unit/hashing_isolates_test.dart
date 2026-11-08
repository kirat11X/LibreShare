// CHARACTERIZATION (speed wave S2), behaviour 5 of docs/plans/inc4-speed-seams.md:
// sha256OfFile / sha256OfChunk (spawned isolates) keep their digests, their
// FileSystemException and their exact "File shorter than expected" message.
// Uses no S2 symbol: green today, must stay green after the native change.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:libreshare_core/src/transfer/hashing.dart';
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ls_s2_iso_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String name, Uint8List bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('sha256OfFile equals package:crypto', () {
    for (final (label, size) in [
      ('0-byte file', 0),
      ('4 MiB + 1 file', 4 * mib + 1),
      ('20 MiB file', 20 * mib),
    ]) {
      test(label, () async {
        final data = seeded(size, size + 1);
        final f = write('f.bin', data);
        expect(await sha256OfFile(f), ref(data));
      });
    }

    test('missing file -> FileSystemException', () async {
      await expectLater(
        sha256OfFile(File('${tmp.path}/nope.bin')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('sha256OfChunk equals package:crypto', () {
    test('every 4 MiB chunk of a 4 MiB + 1 file (isolate path)', () async {
      final data = seeded(4 * mib + 1, 3);
      final f = write('f.bin', data);
      const c = Chunker(4 * mib);
      final ranges = c.ranges(data.length).toList();
      expect(ranges, hasLength(2));
      for (final r in ranges) {
        expect(
          await sha256OfChunk(f, r),
          ref(Uint8List.sublistView(data, r.start, r.end)),
          reason: '$r',
        );
      }
    });

    test('every chunk of a 20 MiB file, 4 MiB chunks', () async {
      final data = seeded(20 * mib, 4);
      final f = write('f.bin', data);
      for (final r in const Chunker(4 * mib).ranges(data.length)) {
        expect(
          await sha256OfChunk(f, r),
          ref(Uint8List.sublistView(data, r.start, r.end)),
          reason: '$r',
        );
      }
    });

    test(
      'small chunks (inline path, 64 KiB) and a 1-byte tail chunk',
      () async {
        final data = seeded(3 * 65536 + 1, 5);
        final f = write('f.bin', data);
        for (final r in const Chunker(65536).ranges(data.length)) {
          expect(
            await sha256OfChunk(f, r),
            ref(Uint8List.sublistView(data, r.start, r.end)),
            reason: '$r',
          );
        }
      },
    );

    test('0-byte file: an empty range hashes to the empty digest', () async {
      final f = write('empty.bin', Uint8List(0));
      expect(await sha256OfChunk(f, const ChunkRange(0, 0, 0)), kSha256Empty);
    });

    test(
      'missing file -> FileSystemException (inline and isolate size)',
      () async {
        final f = File('${tmp.path}/nope.bin');
        await expectLater(
          sha256OfChunk(f, const ChunkRange(0, 0, 65536)),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          sha256OfChunk(f, const ChunkRange(0, 0, 4 * mib)),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('short file, inline size: exact message', () async {
      final f = write('short.bin', seeded(65536 + 10, 6));
      final r = const Chunker(65536).range(2 * 65536, 1);
      await expectLater(
        sha256OfChunk(f, r),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'File shorter than expected: chunk 1 has 10 of 65536 bytes',
          ),
        ),
      );
    });

    test('short file, isolate size (4 MiB chunk): exact message', () async {
      final f = write('short.bin', seeded(4 * mib + 100, 7));
      final r = const Chunker(4 * mib).range(8 * mib, 1);
      await expectLater(
        sha256OfChunk(f, r),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'File shorter than expected: chunk 1 has 100 of 4194304 bytes',
          ),
        ),
      );
    });

    test('file entirely before the range start: has 0 of N bytes', () async {
      final f = write('tiny.bin', seeded(10, 8));
      final r = const Chunker(4 * mib).range(8 * mib, 1);
      await expectLater(
        sha256OfChunk(f, r),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'File shorter than expected: chunk 1 has 0 of 4194304 bytes',
          ),
        ),
      );
    });
  });
}
