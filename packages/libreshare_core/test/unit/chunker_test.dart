import 'dart:io';

import 'package:libreshare_core/src/protocol.dart';
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:test/test.dart';

/// Asserts that [ranges] tile [0, size) exactly: contiguous, no gaps, no
/// overlap, every chunk full-sized except possibly the last one.
void expectTiles(Chunker chunker, int size, List<ChunkRange> ranges) {
  var expectedStart = 0;
  for (var i = 0; i < ranges.length; i++) {
    final r = ranges[i];
    expect(r.index, i, reason: 'index of chunk $i');
    expect(r.start, expectedStart, reason: 'start of chunk $i');
    expect(r.end, greaterThan(r.start), reason: 'chunk $i must be non-empty');
    if (i < ranges.length - 1) {
      expect(r.length, chunker.chunkSize, reason: 'non-last chunk $i is full');
    } else {
      expect(r.length, lessThanOrEqualTo(chunker.chunkSize));
    }
    expectedStart = r.end;
  }
  expect(expectedStart, size, reason: 'ranges must end exactly at size');
}

void main() {
  const chunker = Chunker();
  const cs = kChunkSize;

  group('Chunker.chunkCount (FR-08)', () {
    test('default chunk size is 4 MiB', () {
      expect(chunker.chunkSize, 4 * 1024 * 1024);
    });

    final cases = <String, List<int>>{
      // name: [size, expectedChunkCount]
      'size 0 -> 0 chunks': [0, 0],
      'size 1 -> 1 chunk': [1, 1],
      'size chunkSize-1 -> 1 chunk': [cs - 1, 1],
      'size chunkSize -> 1 chunk': [cs, 1],
      'size chunkSize+1 -> 2 chunks': [cs + 1, 2],
      'size 2*chunkSize -> 2 chunks': [2 * cs, 2],
      'size 2*chunkSize+1 -> 3 chunks': [2 * cs + 1, 3],
    };
    cases.forEach((name, c) {
      test(name, () {
        expect(chunker.chunkCount(c[0]), c[1]);
        final ranges = chunker.ranges(c[0]).toList();
        expect(ranges, hasLength(c[1]));
        expectTiles(chunker, c[0], ranges);
      });
    });

    test('negative size is treated as empty', () {
      expect(chunker.chunkCount(-5), 0);
    });

    test('custom chunk size', () {
      const small = Chunker(10);
      expect(small.chunkCount(0), 0);
      expect(small.chunkCount(9), 1);
      expect(small.chunkCount(10), 1);
      expect(small.chunkCount(11), 2);
      expect(small.chunkCount(100), 10);
      expect(small.chunkCount(101), 11);
    });
  });

  group('Chunker.range', () {
    test('first, middle and last chunk bounds', () {
      const size = 2 * cs + 5;
      expect(chunker.range(size, 0).start, 0);
      expect(chunker.range(size, 0).end, cs);
      expect(chunker.range(size, 1).start, cs);
      expect(chunker.range(size, 1).end, 2 * cs);
      final last = chunker.range(size, 2);
      expect(last.start, 2 * cs);
      expect(last.end, size);
      expect(last.length, 5);
    });

    test('out-of-range index throws RangeError', () {
      expect(() => chunker.range(0, 0), throwsRangeError);
      expect(() => chunker.range(cs, 1), throwsRangeError);
      expect(() => chunker.range(cs, -1), throwsRangeError);
    });

    test('ranges() of an empty file is empty', () {
      expect(chunker.ranges(0), isEmpty);
    });
  });

  group('Chunker.openChunk', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ls_chunker_');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('streams exactly the bytes of each chunk', () async {
      const small = Chunker(7);
      final bytes = List<int>.generate(30, (i) => i);
      final f = File('${tmp.path}/data.bin')..writeAsBytesSync(bytes);
      final collected = <int>[];
      for (final r in small.ranges(bytes.length)) {
        final chunk = <int>[];
        await for (final part in small.openChunk(f, r)) {
          chunk.addAll(part);
        }
        expect(chunk, bytes.sublist(r.start, r.end));
        collected.addAll(chunk);
      }
      expect(collected, bytes);
    });
  });

  group('5 GiB sparse file (64-bit offsets)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ls_chunker_big_');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('1280 chunks tile [0,size) exactly; last chunk readable', () async {
      const size = 5 * 1024 * 1024 * 1024; // 5 GiB
      final f = File('${tmp.path}/sparse5g.bin');
      final raf = await f.open(mode: FileMode.write);
      await raf.truncate(size);
      await raf.close();
      expect(await f.length(), size);

      expect(chunker.chunkCount(size), 1280);
      final ranges = chunker.ranges(size).toList();
      expect(ranges, hasLength(1280));
      expectTiles(chunker, size, ranges);

      // 64-bit: later chunks start beyond 2^32 and do not wrap.
      final beyond32 = ranges.where((r) => r.start > 0xFFFFFFFF).length;
      expect(beyond32, greaterThan(0));
      expect(ranges.last.start, 1279 * cs);
      expect(ranges.last.start, greaterThan(0xFFFFFFFF));
      expect(ranges.last.end, size);

      // Read only the last chunk (do not touch the rest of the file).
      var read = 0;
      await for (final part in chunker.openChunk(f, ranges.last)) {
        read += part.length;
      }
      expect(read, ranges.last.length);
    });

    test('5 GiB + 1 byte needs a 1-byte 1281st chunk', () {
      const size = 5 * 1024 * 1024 * 1024 + 1;
      expect(chunker.chunkCount(size), 1281);
      final last = chunker.range(size, 1280);
      expect(last.start, 5 * 1024 * 1024 * 1024);
      expect(last.length, 1);
    });
  });
}
